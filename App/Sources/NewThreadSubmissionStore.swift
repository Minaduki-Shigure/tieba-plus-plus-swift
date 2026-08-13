import Combine
import Foundation

enum NewThreadSubmissionState: Equatable {
  case inactive
  case loading
  case signedOut
  case ready
  case submitting(UUID)
  case challengeRequired
  case outcomeUnknown
  case acceptedAwaitingVisibility(NewThreadReceipt)
  case confirmed(NewThreadReceipt)
  case failed(NewThreadSubmissionError)
  case accountChanged
}

@MainActor
final class NewThreadSubmissionEntry: ObservableObject {
  let target: NewThreadTarget
  @Published private(set) var state: NewThreadSubmissionState = .inactive
  @Published private(set) var draft: NewThreadDraft?

  fileprivate var lease: NewThreadSessionLease?
  fileprivate var epoch: UInt64 = 0

  init(target: NewThreadTarget) {
    self.target = target
  }

  var isSubmitting: Bool {
    if case .submitting = state { return true }
    return false
  }

  fileprivate func apply(state: NewThreadSubmissionState, draft: NewThreadDraft?) {
    self.draft = draft
    self.state = state
  }
}

struct NewThreadSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

@MainActor
final class NewThreadSubmissionStore {
  private struct SubmissionFlight {
    let id: UUID
    let lease: NewThreadSessionLease
    let submission: NewThreadSubmission
    let task: Task<NewThreadResult, Error>
  }

  private enum DraftMutation: Sendable {
    case save(NewThreadDraft)
    case delete(NewThreadDraftKey)
  }

  private struct DraftMutationTail {
    let id: UUID
    let task: Task<Void, Error>
  }

  private let access: AccountAccess
  private let drafts: any NewThreadDraftRepository
  private var entries: [NewThreadTarget: NewThreadSubmissionEntry] = [:]
  private var scopeTargets: [UUID: NewThreadTarget] = [:]
  private var submissionFlights: [NewThreadTarget: SubmissionFlight] = [:]
  private var draftMutationTails: [NewThreadDraftKey: DraftMutationTail] = [:]
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(
    access: AccountAccess,
    drafts: any NewThreadDraftRepository = FileNewThreadDraftStore.live()
  ) {
    self.access = access
    self.drafts = drafts
    observeAccountSessionChanges()
  }

  init(
    access: AccountAccess,
    drafts: any NewThreadDraftRepository,
    observesAccountSessionChanges: Bool
  ) {
    self.access = access
    self.drafts = drafts
    if observesAccountSessionChanges {
      observeAccountSessionChanges()
    }
  }

  func entry(for target: NewThreadTarget) -> NewThreadSubmissionEntry {
    if let entry = entries[target] { return entry }
    let entry = NewThreadSubmissionEntry(target: target)
    entries[target] = entry
    return entry
  }

  func activate(_ target: NewThreadTarget, for scope: UUID) async {
    let previousTarget = scopeTargets.updateValue(target, forKey: scope)
    if let previousTarget, previousTarget != target {
      removeEntryIfInactive(previousTarget)
    }

    let entry = entry(for: target)
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
      let lease = NewThreadSessionLease(session)
      guard let key = NewThreadDraftKey(userID: lease.userID, target: target) else {
        throw NewThreadSubmissionError.invalidSubmission
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
    } catch let error as NewThreadSubmissionError {
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
    title: String?,
    content: String,
    for target: NewThreadTarget,
    at updatedAt: Date = Date()
  ) async throws -> NewThreadDraft? {
    let entry = entry(for: target)
    guard stateAllowsDraftEditing(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard let key = NewThreadDraftKey(userID: lease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let normalizedTitle = NewThreadTitlePolicy.normalized(title)
    guard NewThreadTitlePolicy.isValid(normalizedTitle) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch

    if normalizedTitle == nil, content.isEmpty {
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
          throw NewThreadSubmissionError.accountChanged
        }
        throw NewThreadSubmissionError.unavailable
      }
      try await ensureOperationIsCurrent(
        entry,
        lease: lease,
        draft: nil,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      entry.apply(state: .ready, draft: nil)
      return nil
    }

    guard let draft = NewThreadDraft(
      key: key,
      title: normalizedTitle,
      content: content,
      updatedAt: updatedAt
    ) else {
      throw NewThreadSubmissionError.invalidSubmission
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
        throw NewThreadSubmissionError.accountChanged
      }
      throw NewThreadSubmissionError.unavailable
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

  func discardDraft(for target: NewThreadTarget) async throws {
    let entry = entry(for: target)
    guard stateAllowsDraftDiscard(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard let key = NewThreadDraftKey(userID: lease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
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
        throw NewThreadSubmissionError.accountChanged
      }
      throw NewThreadSubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: nil,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    entry.apply(state: .ready, draft: nil)
  }

  @discardableResult
  func submit(
    title: String?,
    content: String,
    for target: NewThreadTarget,
    submissionID: UUID = UUID()
  ) async throws -> NewThreadResult {
    try Task.checkCancellation()
    guard let submission = NewThreadSubmission(
      id: submissionID,
      target: target,
      title: title,
      content: content
    ) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    if let flight = submissionFlights[target] {
      guard flight.submission == submission else {
        throw NewThreadSubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let entry = entry(for: target)
    guard stateAllowsSubmission(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard
      let draftKey = NewThreadDraftKey(userID: lease.userID, target: target),
      let editingDraft = NewThreadDraft(
        key: draftKey,
        title: submission.title,
        content: submission.content
      )
    else {
      throw NewThreadSubmissionError.invalidSubmission
    }

    let operationGeneration = generation
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.apply(state: .submitting(submissionID), draft: editingDraft)
    let flightID = UUID()
    let task = Task { @MainActor [weak self] () throws -> NewThreadResult in
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
    _ confirmation: NewThreadVisibilityConfirmation,
    matching receipt: NewThreadReceipt,
    for target: NewThreadTarget
  ) async throws -> NewThreadResult {
    guard
      receipt.isValid,
      confirmation.receipt == receipt,
      confirmation.target == target
    else {
      throw NewThreadSubmissionError.invalidSubmission
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
      draft.title == nil || confirmation.title == draft.title,
      confirmation.content.utf8.elementsEqual(draft.content.utf8)
    else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    guard try await leaseIsCurrent(lease) else {
      entry.lease = nil
      entry.apply(state: .accountChanged, draft: draft)
      throw NewThreadSubmissionError.accountChanged
    }
    guard let confirmedDraft = confirmedDraft(
      from: draft,
      submissionID: submissionID,
      receipt: receipt
    ) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    do {
      try await performDraftMutation(.save(confirmedDraft), for: confirmedDraft.key)
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
        throw NewThreadSubmissionError.accountChanged
      }
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
      throw NewThreadSubmissionError.unavailable
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
        draft: confirmedDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.accountChanged
    }
    guard let result = NewThreadResult(
      submissionID: submissionID,
      userID: lease.userID,
      target: target,
      outcome: .confirmed(receipt)
    ) else {
      entry.apply(state: .confirmed(receipt), draft: confirmedDraft)
      throw NewThreadSubmissionError.outcomeUnknown
    }
    entry.apply(state: .confirmed(receipt), draft: confirmedDraft)
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
    _ submission: NewThreadSubmission,
    editingDraft: NewThreadDraft,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
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
        throw NewThreadSubmissionError.accountChanged
      }
      applyFailureIfCurrent(
        .unavailable,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.unavailable
    }

    let session: StoredAccountSession
    do {
      guard let activeSession = try await access.vault.activeSession() else {
        throw NewThreadSubmissionError.signedOut
      }
      guard NewThreadSessionLease(activeSession) == lease else {
        throw NewThreadSubmissionError.accountChanged
      }
      guard activeSession.credentials != nil else {
        throw NewThreadSubmissionError.fullCredentialsRequired
      }
      session = activeSession
    } catch let error as NewThreadSubmissionError {
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
      throw NewThreadSubmissionError.unavailable
    }

    guard let dispatchPendingDraft = NewThreadDraft(
      key: editingDraft.key,
      title: editingDraft.title,
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
      throw NewThreadSubmissionError.invalidSubmission
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
        throw NewThreadSubmissionError.accountChanged
      }
      applyFailureIfCurrent(
        .unavailable,
        draft: editingDraft,
        entry: entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.unavailable
    }
    guard await operationIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else {
      try? await performDraftMutation(.save(editingDraft), for: editingDraft.key)
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: editingDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.accountChanged
    }

    let result: NewThreadResult
    do {
      result = try await access.service.submitNewThread(
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
        NewThreadSubmissionError.outcomeUnknown,
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
    case .confirmed(let receipt):
      guard let confirmedDraft = confirmedDraft(
        from: editingDraft,
        submissionID: submission.id,
        receipt: receipt
      ) else {
        return try await finishSubmissionFailure(
          NewThreadSubmissionError.outcomeUnknown,
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
        try await performDraftMutation(.save(confirmedDraft), for: confirmedDraft.key)
      } catch {
        if await operationIsCurrent(
          entry,
          lease: lease,
          generation: operationGeneration,
          epoch: operationEpoch
        ) {
          entry.apply(state: .outcomeUnknown, draft: dispatchPendingDraft)
          throw NewThreadSubmissionError.outcomeUnknown
        }
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: dispatchPendingDraft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw NewThreadSubmissionError.accountChanged
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
          draft: confirmedDraft,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw NewThreadSubmissionError.accountChanged
      }
      entry.apply(state: .confirmed(receipt), draft: confirmedDraft)
    case .acceptedAwaitingVisibility(let receipt):
      guard let pending = pendingDraft(
        from: editingDraft,
        submissionID: submission.id,
        receipt: receipt
      ) else {
        return try await finishSubmissionFailure(
          NewThreadSubmissionError.outcomeUnknown,
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
          throw NewThreadSubmissionError.unavailable
        }
        applyAccountChangedIfOwned(
          entry,
          lease: lease,
          draft: pending,
          generation: operationGeneration,
          epoch: operationEpoch
        )
        throw NewThreadSubmissionError.accountChanged
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
        throw NewThreadSubmissionError.accountChanged
      }
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: pending)
    }
    return result
  }

  private func finishSubmissionFailure(
    _ source: Error,
    submission: NewThreadSubmission,
    editingDraft: NewThreadDraft,
    dispatchPendingDraft: NewThreadDraft,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    let error: NewThreadSubmissionError
    if source is CancellationError {
      error = .outcomeUnknown
    } else if let typed = source as? NewThreadSubmissionError {
      error = typed
    } else {
      error = .outcomeUnknown
    }

    let retainedDraft: NewThreadDraft
    let retainedError: NewThreadSubmissionError
    if error == .outcomeUnknown,
      let unknownDraft = NewThreadDraft(
        key: editingDraft.key,
        title: editingDraft.title,
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
      let blockedDraft = NewThreadDraft(
        key: editingDraft.key,
        title: editingDraft.title,
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

    guard await operationIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: retainedDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.accountChanged
    }
    applyFailure(retainedError, draft: retainedDraft, to: entry)
    throw retainedError
  }

  private func canRestoreEditing(after error: NewThreadSubmissionError) -> Bool {
    switch error {
    case .signedOut, .fullCredentialsRequired, .invalidSubmission, .submissionConflict,
      .accountChanged, .server:
      true
    case .submissionInProgress, .challengeRequired, .outcomeUnknown, .unavailable:
      false
    }
  }

  private func applyFailureIfCurrent(
    _ error: NewThreadSubmissionError,
    draft: NewThreadDraft,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
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
    _ error: NewThreadSubmissionError,
    draft: NewThreadDraft,
    to entry: NewThreadSubmissionEntry
  ) {
    if error == .accountChanged { entry.lease = nil }
    let state: NewThreadSubmissionState = switch error {
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
    _ entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    draft: NewThreadDraft?,
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
    _ draft: NewThreadDraft?,
    lease: NewThreadSessionLease,
    to entry: NewThreadSubmissionEntry
  ) {
    guard let draft else {
      entry.apply(state: .ready, draft: nil)
      return
    }
    switch draft.disposition {
    case .editing:
      entry.apply(state: .ready, draft: draft)
    case .submissionPending, .outcomeUnknown:
      entry.apply(state: .outcomeUnknown, draft: draft)
    case .challengeRequired(_, let blockedRevision):
      let state: NewThreadSubmissionState = blockedRevision == lease.sessionRevision
        ? .challengeRequired
        : .ready
      entry.apply(state: state, draft: draft)
    case .acceptedAwaitingVisibility(_, let receipt):
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
    case .confirmed(_, let receipt):
      entry.apply(state: .confirmed(receipt), draft: draft)
    }
  }

  private func pendingDraft(
    from draft: NewThreadDraft,
    submissionID: UUID,
    receipt: NewThreadReceipt
  ) -> NewThreadDraft? {
    NewThreadDraft(
      key: draft.key,
      title: draft.title,
      content: draft.content,
      disposition: .acceptedAwaitingVisibility(
        submissionID: submissionID,
        receipt: receipt
      ),
      updatedAt: Date()
    )
  }

  private func confirmedDraft(
    from draft: NewThreadDraft,
    submissionID: UUID,
    receipt: NewThreadReceipt
  ) -> NewThreadDraft? {
    NewThreadDraft(
      key: draft.key,
      title: draft.title,
      content: draft.content,
      disposition: .confirmed(submissionID: submissionID, receipt: receipt),
      updatedAt: Date()
    )
  }

  private func stateAllowsDraftEditing(_ state: NewThreadSubmissionState) -> Bool {
    switch state {
    case .ready, .failed:
      true
    default:
      false
    }
  }

  private func stateAllowsDraftDiscard(_ state: NewThreadSubmissionState) -> Bool {
    if case .confirmed = state { return true }
    return stateAllowsDraftEditing(state)
  }

  private func stateAllowsSubmission(_ state: NewThreadSubmissionState) -> Bool {
    switch state {
    case .ready:
      true
    case .failed(let error):
      error != .fullCredentialsRequired
    default:
      false
    }
  }

  private func stateError(_ state: NewThreadSubmissionState) -> NewThreadSubmissionError {
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
    _ entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    draft: NewThreadDraft?,
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
      throw NewThreadSubmissionError.accountChanged
    }
  }

  private func operationIsCurrent(
    _ entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
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
    _ entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) -> Bool {
    operationGeneration == generation
      && entry.epoch == operationEpoch
      && entry.lease == lease
  }

  private func activationIsCurrent(
    target: NewThreadTarget,
    scope: UUID,
    entry: NewThreadSubmissionEntry,
    generation operationGeneration: UInt64,
    epoch operationEpoch: UInt64
  ) -> Bool {
    operationGeneration == generation
      && scopeTargets[scope] == target
      && entry.epoch == operationEpoch
  }

  private func leaseIsCurrent(_ lease: NewThreadSessionLease) async throws -> Bool {
    guard let session = try await access.vault.activeSession() else { return false }
    return NewThreadSessionLease(session) == lease
  }

  private func finishSubmissionFlight(target: NewThreadTarget, id: UUID) {
    guard submissionFlights[target]?.id == id else { return }
    submissionFlights.removeValue(forKey: target)
    removeEntryIfInactive(target)
  }

  private func waitForDraftMutations(for key: NewThreadDraftKey) async {
    while let tail = draftMutationTails[key] {
      _ = try? await tail.task.value
      clearDraftMutationTail(for: key, id: tail.id)
      await Task.yield()
    }
  }

  private func performDraftMutation(
    _ mutation: DraftMutation,
    for key: NewThreadDraftKey
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

  private func clearDraftMutationTail(for key: NewThreadDraftKey, id: UUID) {
    guard draftMutationTails[key]?.id == id else { return }
    draftMutationTails.removeValue(forKey: key)
  }

  private func removeEntryIfInactive(_ target: NewThreadTarget) {
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
