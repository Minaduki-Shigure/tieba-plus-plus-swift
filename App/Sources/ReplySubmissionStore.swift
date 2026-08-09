import Combine
import Foundation

enum TextReplySubmissionState: Equatable {
  case inactive
  case loading
  case signedOut
  case ready
  case submitting(UUID)
  case challengeRequired
  case outcomeUnknown
  case acceptedAwaitingVisibility(TextReplyReceipt)
  case confirmed(CreatedTextReply)
  case failed(TextReplySubmissionError)
  case accountChanged
}

@MainActor
final class TextReplySubmissionEntry: ObservableObject {
  let target: TextReplyTarget
  @Published private(set) var state: TextReplySubmissionState = .inactive
  @Published private(set) var draft: TextReplyDraft?

  fileprivate var lease: TextReplySessionLease?
  fileprivate var epoch: UInt64 = 0

  init(target: TextReplyTarget) {
    self.target = target
  }

  var isSubmitting: Bool {
    if case .submitting = state { return true }
    return false
  }

  fileprivate func apply(
    state: TextReplySubmissionState,
    draft: TextReplyDraft?
  ) {
    self.draft = draft
    self.state = state
  }
}

struct TextReplySessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

@MainActor
final class TextReplySubmissionStore {
  private struct SubmissionFlight {
    let id: UUID
    let lease: TextReplySessionLease
    let submission: TextReplySubmission
    let task: Task<TextReplyResult, Error>
  }

  private enum DraftMutation: Sendable {
    case save(TextReplyDraft)
    case delete(TextReplyDraftKey)
  }

  private struct DraftMutationTail {
    let id: UUID
    let task: Task<Void, Error>
  }

  private let access: AccountAccess
  private let drafts: any TextReplyDraftRepository
  private var entries: [TextReplyTarget: TextReplySubmissionEntry] = [:]
  private var scopeTargets: [UUID: TextReplyTarget] = [:]
  private var submissionFlights: [TextReplyTarget: SubmissionFlight] = [:]
  private var draftMutationTails: [TextReplyDraftKey: DraftMutationTail] = [:]
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(
    access: AccountAccess,
    drafts: any TextReplyDraftRepository = FileTextReplyDraftStore.live()
  ) {
    self.access = access
    self.drafts = drafts
    observeAccountSessionChanges()
  }

  init(
    access: AccountAccess,
    drafts: any TextReplyDraftRepository,
    observesAccountSessionChanges: Bool
  ) {
    self.access = access
    self.drafts = drafts
    if observesAccountSessionChanges {
      observeAccountSessionChanges()
    }
  }

  func entry(for target: TextReplyTarget) -> TextReplySubmissionEntry {
    if let entry = entries[target] { return entry }
    let entry = TextReplySubmissionEntry(target: target)
    entries[target] = entry
    return entry
  }

  func activate(_ target: TextReplyTarget, for scope: UUID) async {
    let previousTarget = scopeTargets.updateValue(target, forKey: scope)
    if let previousTarget, previousTarget != target {
      removeEntryIfInactive(previousTarget)
    }

    let entry = entry(for: target)
    // A view may be recreated while an app-owned submission is still running.
    // Register the new scope without replacing the flight's lease or state.
    if submissionFlights[target] != nil { return }
    let operationGeneration = generation
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.lease = nil
    entry.apply(state: .loading, draft: nil)

    do {
      guard let session = try await access.vault.activeSession() else {
        guard activationIsCurrent(
          target: target,
          scope: scope,
          entry: entry,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else { return }
        entry.apply(state: .signedOut, draft: nil)
        return
      }
      let lease = TextReplySessionLease(session)
      guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
        throw TextReplySubmissionError.invalidSubmission
      }
      await waitForDraftMutations(for: key)
      let draft = try await drafts.draft(for: key)
      guard try await leaseIsCurrent(lease) else {
        guard activationIsCurrent(
          target: target,
          scope: scope,
          entry: entry,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else { return }
        entry.apply(state: .accountChanged, draft: draft)
        return
      }
      guard activationIsCurrent(
        target: target,
        scope: scope,
        entry: entry,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { return }
      entry.lease = lease
      if session.credentials == nil {
        entry.apply(state: .failed(.fullCredentialsRequired), draft: draft)
      } else {
        applyLoadedDraft(draft, lease: lease, to: entry)
      }
    } catch is CancellationError {
      return
    } catch let error as TextReplySubmissionError {
      guard activationIsCurrent(
        target: target,
        scope: scope,
        entry: entry,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { return }
      entry.apply(state: .failed(error), draft: entry.draft)
    } catch {
      guard activationIsCurrent(
        target: target,
        scope: scope,
        entry: entry,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { return }
      entry.apply(state: .failed(.unavailable), draft: entry.draft)
    }
  }

  func deactivate(_ scope: UUID) {
    guard let target = scopeTargets.removeValue(forKey: scope) else { return }
    removeEntryIfInactive(target)
  }

  @discardableResult
  func saveDraft(
    _ content: String,
    for target: TextReplyTarget,
    at updatedAt: Date = Date()
  ) async throws -> TextReplyDraft? {
    let entry = entry(for: target)
    guard stateAllowsDraftEditing(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    if entry.state == .challengeRequired {
      let disposition = challengeDisposition(for: entry, lease: lease)
      guard let draft = TextReplyDraft(
        key: key,
        content: content,
        disposition: disposition,
        updatedAt: updatedAt
      ) else {
        throw TextReplySubmissionError.invalidSubmission
      }
      do {
        try await performDraftMutation(.save(draft), for: key)
      } catch {
        guard await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else {
          applyAccountChangedIfOwned(
            entry,
            lease: lease,
            draft: draft,
            generation: operationGeneration,
            epoch: operationEpoch
          )
          throw TextReplySubmissionError.accountChanged
        }
        throw TextReplySubmissionError.unavailable
      }
      try await ensureOperationIsCurrent(
        entry,
        lease: lease,
        draft: draft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      entry.apply(state: .challengeRequired, draft: draft)
      return draft
    }
    if content.isEmpty {
      do {
        try await performDraftMutation(.delete(key), for: key)
      } catch {
        guard await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else {
          applyAccountChangedIfOwned(
            entry,
            lease: lease,
            draft: entry.draft,
            generation: operationGeneration,
            epoch: operationEpoch
          )
          throw TextReplySubmissionError.accountChanged
        }
        throw TextReplySubmissionError.unavailable
      }
      try await ensureOperationIsCurrent(
        entry,
        lease: lease,
        draft: nil,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      let retainedState: TextReplySubmissionState = entry.state == .challengeRequired
        ? .challengeRequired
        : .ready
      entry.apply(state: retainedState, draft: nil)
      return nil
    }
    guard let draft = TextReplyDraft(key: key, content: content, updatedAt: updatedAt) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    do {
      try await performDraftMutation(.save(draft), for: key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: draft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      throw TextReplySubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    entry.apply(state: entry.state, draft: draft)
    return draft
  }

  func discardDraft(for target: TextReplyTarget) async throws {
    let entry = entry(for: target)
    guard stateAllowsDraftEditing(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    if entry.state == .challengeRequired {
      guard let tombstone = TextReplyDraft(
        key: key,
        content: "",
        disposition: challengeDisposition(for: entry, lease: lease)
      ) else {
        throw TextReplySubmissionError.invalidSubmission
      }
      do {
        try await performDraftMutation(.save(tombstone), for: key)
      } catch {
        guard await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else {
          applyAccountChangedIfOwned(
            entry,
            lease: lease,
            draft: tombstone,
            generation: operationGeneration,
            epoch: operationEpoch
          )
          throw TextReplySubmissionError.accountChanged
        }
        throw TextReplySubmissionError.unavailable
      }
      try await ensureOperationIsCurrent(
        entry,
        lease: lease,
        draft: tombstone,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      entry.apply(state: .challengeRequired, draft: tombstone)
      return
    }
    do {
      try await performDraftMutation(.delete(key), for: key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: entry.draft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      throw TextReplySubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: nil,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    let retainedState: TextReplySubmissionState = entry.state == .challengeRequired
      ? .challengeRequired
      : .ready
    entry.apply(state: retainedState, draft: nil)
  }

  @discardableResult
  func submit(
    _ content: String,
    for target: TextReplyTarget,
    submissionID: UUID = UUID()
  ) async throws -> TextReplyResult {
    guard let submission = TextReplySubmission(
      id: submissionID,
      target: target,
      content: content
    ) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    if let flight = submissionFlights[target] {
      guard flight.submission == submission else {
        throw TextReplySubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let entry = entry(for: target)
    guard stateAllowsSubmission(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard let draftKey = TextReplyDraftKey(userID: lease.userID, target: target),
      let editingDraft = TextReplyDraft(key: draftKey, content: content)
    else {
      throw TextReplySubmissionError.invalidSubmission
    }

    let operationGeneration = generation
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.apply(state: .submitting(submissionID), draft: editingDraft)
    let flightID = UUID()
    let task = Task { @MainActor [weak self] () throws -> TextReplyResult in
      guard let self else { throw CancellationError() }
      defer { finishSubmissionFlight(target: target, id: flightID) }
      return try await performSubmission(
        submission,
        editingDraft: editingDraft,
        entry: entry,
        lease: lease,
        operationGeneration: operationGeneration,
        operationEpoch: operationEpoch
      )
    }
    submissionFlights[target] = SubmissionFlight(
      id: flightID,
      lease: lease,
      submission: submission,
      task: task
    )
    return try await task.value
  }

  @discardableResult
  func confirmVisibility(
    _ confirmation: TextReplyVisibilityConfirmation,
    matching receipt: TextReplyReceipt,
    for target: TextReplyTarget
  ) async throws -> TextReplyResult {
    let created = confirmation.created
    guard
      created.belongs(to: target),
      receipt.belongs(to: target),
      created.receipt == receipt
    else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let entry = entry(for: target)
    guard
      case .acceptedAwaitingVisibility(let stateReceipt) = entry.state,
      stateReceipt == receipt,
      let draft = entry.draft,
      case .acceptedAwaitingVisibility(let submissionID, let draftReceipt) = draft.disposition,
      draftReceipt == receipt,
      let lease = entry.lease,
      draft.key.userID == lease.userID
    else {
      throw stateError(entry.state)
    }
    guard
      confirmation.authorUserID == lease.userID,
      confirmation.content == draft.content
    else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    guard try await leaseIsCurrent(lease) else {
      entry.lease = nil
      entry.apply(state: .accountChanged, draft: draft)
      throw TextReplySubmissionError.accountChanged
    }
    do {
      try await performDraftMutation(.delete(draft.key), for: draft.key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        try? await performDraftMutation(.save(draft), for: draft.key)
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: draft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      throw TextReplySubmissionError.unavailable
    }
    guard
      await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
    else {
      try? await performDraftMutation(.save(draft), for: draft.key)
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: draft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.accountChanged
    }
    guard let result = TextReplyResult(
      submissionID: submissionID,
      userID: lease.userID,
      target: target,
      outcome: .confirmed(created)
    ) else {
      do {
        try await performDraftMutation(.save(draft), for: draft.key)
      } catch {
        entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
        throw TextReplySubmissionError.unavailable
      }
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
      throw TextReplySubmissionError.outcomeUnknown
    }
    entry.apply(state: .confirmed(created), draft: nil)
    return result
  }

  func accountSessionDidChange() {
    generation &+= 1
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.apply(state: .accountChanged, draft: entry.draft)
    }
  }

  private func observeAccountSessionChanges() {
    sessionChangeCancellable = NotificationCenter.default.publisher(for: .accountSessionDidChange)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.accountSessionDidChange()
        }
      }
  }

  private func performSubmission(
    _ submission: TextReplySubmission,
    editingDraft: TextReplyDraft,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    do {
      try await performDraftMutation(.save(editingDraft), for: editingDraft.key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: editingDraft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      applyFailureIfCurrent(
        .unavailable,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.unavailable
    }

    let session: StoredAccountSession
    do {
      guard let activeSession = try await access.vault.activeSession() else {
        throw TextReplySubmissionError.signedOut
      }
      guard TextReplySessionLease(activeSession) == lease else {
        throw TextReplySubmissionError.accountChanged
      }
      guard activeSession.credentials != nil else {
        throw TextReplySubmissionError.fullCredentialsRequired
      }
      session = activeSession
    } catch let error as TextReplySubmissionError {
      applyFailureIfCurrent(
        error,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw error
    } catch {
      applyFailureIfCurrent(
        .unavailable,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.unavailable
    }

    guard let dispatchPendingDraft = TextReplyDraft(
      key: editingDraft.key,
      content: editingDraft.content,
      disposition: .submissionPending(submissionID: submission.id),
      updatedAt: Date()
    ) else {
      applyFailureIfCurrent(
        .invalidSubmission,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.invalidSubmission
    }
    do {
      try await performDraftMutation(.save(dispatchPendingDraft), for: dispatchPendingDraft.key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: editingDraft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      applyFailureIfCurrent(
        .unavailable,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.unavailable
    }
    guard await operationIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else {
      // No write was dispatched, so restoring the editable draft is safe.
      try? await performDraftMutation(.save(editingDraft), for: editingDraft.key)
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: editingDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.accountChanged
    }

    let result: TextReplyResult
    do {
      result = try await access.service.submitTextReply(
        session: session,
        submission: submission
      )
    } catch {
      return try await finishSubmissionFailure(
        error,
        submission: submission,
        editingDraft: editingDraft,
        dispatchPendingDraft: dispatchPendingDraft,
        entry: entry,
        lease: lease,
        operationGeneration: operationGeneration,
        operationEpoch: operationEpoch
      )
    }

    guard
      result.submissionID == submission.id,
      result.userID == lease.userID,
      result.target == submission.target
    else {
      return try await finishSubmissionFailure(
        TextReplySubmissionError.outcomeUnknown,
        submission: submission,
        editingDraft: editingDraft,
        dispatchPendingDraft: dispatchPendingDraft,
        entry: entry,
        lease: lease,
        operationGeneration: operationGeneration,
        operationEpoch: operationEpoch
      )
    }

    switch result.outcome {
    case .confirmed(let created):
      guard created.belongs(to: submission.target) else {
        return try await finishSubmissionFailure(
          TextReplySubmissionError.outcomeUnknown,
          submission: submission,
          editingDraft: editingDraft,
          dispatchPendingDraft: dispatchPendingDraft,
          entry: entry,
          lease: lease,
          operationGeneration: operationGeneration,
          operationEpoch: operationEpoch
        )
      }
      guard let pending = pendingDraft(
        from: editingDraft,
        submissionID: submission.id,
        receipt: created.receipt
      ) else {
        return try await finishSubmissionFailure(
          TextReplySubmissionError.outcomeUnknown,
          submission: submission,
          editingDraft: editingDraft,
          dispatchPendingDraft: dispatchPendingDraft,
          entry: entry,
          lease: lease,
          operationGeneration: operationGeneration,
          operationEpoch: operationEpoch
        )
      }
      do {
        try await performDraftMutation(.save(pending), for: pending.key)
      } catch {
        if await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) {
          entry.apply(state: .acceptedAwaitingVisibility(created.receipt), draft: pending)
          throw TextReplySubmissionError.unavailable
        }
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      do {
        try await performDraftMutation(.delete(editingDraft.key), for: editingDraft.key)
      } catch {
        if await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) {
          entry.apply(state: .acceptedAwaitingVisibility(created.receipt), draft: pending)
          throw TextReplySubmissionError.unavailable
        }
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        try? await performDraftMutation(.save(pending), for: pending.key)
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      entry.apply(state: .confirmed(created), draft: nil)
    case .acceptedAwaitingVisibility(let receipt):
      guard receipt.belongs(to: submission.target),
        let pending = pendingDraft(
          from: editingDraft,
          submissionID: submission.id,
          receipt: receipt
        )
      else {
        return try await finishSubmissionFailure(
          TextReplySubmissionError.outcomeUnknown,
          submission: submission,
          editingDraft: editingDraft,
          dispatchPendingDraft: dispatchPendingDraft,
          entry: entry,
          lease: lease,
          operationGeneration: operationGeneration,
          operationEpoch: operationEpoch
        )
      }
      do {
        try await performDraftMutation(.save(pending), for: pending.key)
      } catch {
        if await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) {
          entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: pending)
          throw TextReplySubmissionError.unavailable
        }
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else {
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw TextReplySubmissionError.accountChanged
      }
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: pending)
    }
    return result
  }

  private func finishSubmissionFailure(
    _ source: Error,
    submission: TextReplySubmission,
    editingDraft: TextReplyDraft,
    dispatchPendingDraft: TextReplyDraft,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    let error: TextReplySubmissionError
    if source is CancellationError {
      error = .outcomeUnknown
    } else if let typed = source as? TextReplySubmissionError {
      error = typed
    } else {
      error = .outcomeUnknown
    }

    let retainedDraft: TextReplyDraft
    let retainedError: TextReplySubmissionError
    if error == .outcomeUnknown,
      let unknownDraft = TextReplyDraft(
        key: editingDraft.key,
        content: editingDraft.content,
        disposition: .outcomeUnknown(submissionID: submission.id),
        updatedAt: Date()
      )
    {
      do {
        try await performDraftMutation(.save(unknownDraft), for: unknownDraft.key)
        retainedDraft = unknownDraft
      } catch {
        retainedDraft = dispatchPendingDraft
      }
      retainedError = .outcomeUnknown
    } else if error == .challengeRequired,
      let blockedDraft = TextReplyDraft(
        key: editingDraft.key,
        content: editingDraft.content,
        disposition: .challengeRequired(
          submissionID: submission.id,
          sessionRevision: lease.sessionRevision
        ),
        updatedAt: Date()
      )
    {
      do {
        try await performDraftMutation(.save(blockedDraft), for: blockedDraft.key)
        retainedDraft = blockedDraft
        retainedError = .challengeRequired
      } catch {
        retainedDraft = dispatchPendingDraft
        retainedError = .outcomeUnknown
      }
    } else if canRestoreEditing(after: error) {
      do {
        try await performDraftMutation(.save(editingDraft), for: editingDraft.key)
        retainedDraft = editingDraft
        retainedError = error
      } catch {
        retainedDraft = dispatchPendingDraft
        retainedError = .outcomeUnknown
      }
    } else {
      retainedDraft = dispatchPendingDraft
      retainedError = .outcomeUnknown
    }

    let current = await operationIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    guard current else {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: retainedDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.accountChanged
    }
    applyFailure(retainedError, draft: retainedDraft, to: entry)
    throw retainedError
  }

  private func canRestoreEditing(after error: TextReplySubmissionError) -> Bool {
    switch error {
    case .signedOut, .fullCredentialsRequired, .invalidSubmission, .submissionConflict,
      .accountChanged, .server:
      true
    case .submissionInProgress, .challengeRequired, .outcomeUnknown, .unavailable:
      false
    }
  }

  private func applyFailureIfCurrent(
    _ error: TextReplySubmissionError,
    draft: TextReplyDraft,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) {
    guard
      operationGeneration == generation,
      entry.epoch == operationEpoch,
      entry.lease == lease
    else { return }
    applyFailure(error, draft: draft, to: entry)
  }

  private func applyFailure(
    _ error: TextReplySubmissionError,
    draft: TextReplyDraft,
    to entry: TextReplySubmissionEntry
  ) {
    if error == .accountChanged {
      entry.lease = nil
    }
    let state: TextReplySubmissionState = switch error {
    case .signedOut:
      .signedOut
    case .challengeRequired:
      .challengeRequired
    case .outcomeUnknown:
      .outcomeUnknown
    case .accountChanged:
      .accountChanged
    default:
      .failed(error)
    }
    entry.apply(state: state, draft: draft)
  }

  private func applyAccountChangedIfOwned(
    _ entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    draft: TextReplyDraft?,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) {
    guard
      generation == operationGeneration,
      entry.epoch == operationEpoch,
      entry.lease == lease
    else { return }
    entry.lease = nil
    entry.apply(state: .accountChanged, draft: draft)
  }

  private func applyLoadedDraft(
    _ draft: TextReplyDraft?,
    lease: TextReplySessionLease,
    to entry: TextReplySubmissionEntry
  ) {
    guard let draft else {
      entry.apply(state: .ready, draft: nil)
      return
    }
    switch draft.disposition {
    case .editing:
      entry.apply(state: .ready, draft: draft)
    case .submissionPending:
      entry.apply(state: .outcomeUnknown, draft: draft)
    case .challengeRequired(_, let blockedRevision):
      let state: TextReplySubmissionState = blockedRevision == lease.sessionRevision
        ? .challengeRequired
        : .ready
      entry.apply(state: state, draft: draft)
    case .acceptedAwaitingVisibility(_, let receipt):
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
    case .outcomeUnknown:
      entry.apply(state: .outcomeUnknown, draft: draft)
    }
  }

  private func pendingDraft(
    from draft: TextReplyDraft,
    submissionID: UUID,
    receipt: TextReplyReceipt
  ) -> TextReplyDraft? {
    TextReplyDraft(
      key: draft.key,
      content: draft.content,
      disposition: .acceptedAwaitingVisibility(
        submissionID: submissionID,
        receipt: receipt
      ),
      updatedAt: Date()
    )
  }

  private func challengeDisposition(
    for entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease
  ) -> TextReplyDraftDisposition {
    if
      let draft = entry.draft,
      case .challengeRequired(let submissionID, let blockedRevision) = draft.disposition,
      blockedRevision == lease.sessionRevision
    {
      return .challengeRequired(
        submissionID: submissionID,
        sessionRevision: blockedRevision
      )
    }
    return .challengeRequired(
      submissionID: UUID(),
      sessionRevision: lease.sessionRevision
    )
  }

  private func stateAllowsDraftEditing(_ state: TextReplySubmissionState) -> Bool {
    switch state {
    case .ready, .challengeRequired, .failed:
      true
    default:
      false
    }
  }

  private func stateAllowsSubmission(_ state: TextReplySubmissionState) -> Bool {
    switch state {
    case .ready, .failed:
      true
    default:
      false
    }
  }

  private func stateError(_ state: TextReplySubmissionState) -> TextReplySubmissionError {
    switch state {
    case .signedOut:
      .signedOut
    case .submitting:
      .submissionInProgress
    case .challengeRequired:
      .challengeRequired
    case .outcomeUnknown:
      .outcomeUnknown
    case .acceptedAwaitingVisibility, .confirmed:
      .outcomeUnknown
    case .accountChanged:
      .accountChanged
    case .failed(let error):
      error
    default:
      .invalidSubmission
    }
  }

  private func ensureOperationIsCurrent(
    _ entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    draft: TextReplyDraft?,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) async throws {
    guard await operationIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: draft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.accountChanged
    }
  }

  private func operationIsCurrent(
    _ entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) async -> Bool {
    guard entryIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else { return false }
    guard (try? await leaseIsCurrent(lease)) == true else { return false }
    return entryIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    )
  }

  private func entryIsCurrent(
    _ entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) -> Bool {
    operationGeneration == generation
      && entry.epoch == operationEpoch
      && entry.lease == lease
  }

  private func activationIsCurrent(
    target: TextReplyTarget,
    scope: UUID,
    entry: TextReplySubmissionEntry,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) -> Bool {
    operationGeneration == generation
      && scopeTargets[scope] == target
      && entry.epoch == operationEpoch
  }

  private func leaseIsCurrent(_ lease: TextReplySessionLease) async throws -> Bool {
    guard let session = try await access.vault.activeSession() else { return false }
    return TextReplySessionLease(session) == lease
  }

  private func finishSubmissionFlight(target: TextReplyTarget, id: UUID) {
    guard submissionFlights[target]?.id == id else { return }
    submissionFlights.removeValue(forKey: target)
    removeEntryIfInactive(target)
  }

  private func waitForDraftMutations(for key: TextReplyDraftKey) async {
    while let tail = draftMutationTails[key] {
      _ = try? await tail.task.value
      clearDraftMutationTail(for: key, id: tail.id)
      await Task.yield()
    }
  }

  private func performDraftMutation(
    _ mutation: DraftMutation,
    for key: TextReplyDraftKey
  ) async throws {
    let previous = draftMutationTails[key]?.task
    let repository = drafts
    let id = UUID()
    let task = Task {
      if let previous { _ = try? await previous.value }
      switch mutation {
      case .save(let draft):
        try await repository.save(draft)
      case .delete(let key):
        try await repository.delete(for: key)
      }
    }
    draftMutationTails[key] = DraftMutationTail(id: id, task: task)
    do {
      try await task.value
      clearDraftMutationTail(for: key, id: id)
    } catch {
      clearDraftMutationTail(for: key, id: id)
      throw error
    }
  }

  private func clearDraftMutationTail(for key: TextReplyDraftKey, id: UUID) {
    guard draftMutationTails[key]?.id == id else { return }
    draftMutationTails.removeValue(forKey: key)
  }

  private func removeEntryIfInactive(_ target: TextReplyTarget) {
    guard
      !scopeTargets.values.contains(target),
      submissionFlights[target] == nil
    else { return }
    entries.removeValue(forKey: target)
  }

  private func nextEpoch() -> UInt64 {
    epoch &+= 1
    return epoch
  }
}
