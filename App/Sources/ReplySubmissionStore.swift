import Combine
import Foundation
import TiebaCore

enum TextReplySubmissionState: Equatable {
  case inactive
  case loading
  case signedOut
  case ready
  case submitting(UUID)
  case imageRecovery(ComposerImageSubmissionRecoveryState)
  case imageRecoveryUnavailable
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
  fileprivate var pendingActivationLease: TextReplySessionLease?
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
  private struct LoadedDraftResolution {
    let state: TextReplySubmissionState
    let draft: TextReplyDraft?
  }

  private struct SubmissionFlight {
    let id: UUID
    let lease: TextReplySessionLease
    let submission: TextReplySubmission
    let draftKey: TextReplyDraftKey
    let sealID: UUID
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

  private struct DraftOperationWaiter {
    let id: UUID
    let isDrain: Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private let access: AccountAccess
  private let drafts: any TextReplyDraftRepository
  private let imagePipeline: (any ComposerImageSubmissionPipelining)?
  private let attachmentDeletionScheduler:
    (any ComposerImageAttachmentDeletionScheduling)?
  private var entries: [TextReplyTarget: TextReplySubmissionEntry] = [:]
  private var scopeTargets: [UUID: TextReplyTarget] = [:]
  private var submissionFlights: [TextReplyTarget: SubmissionFlight] = [:]
  private var draftMutationTails: [TextReplyDraftKey: DraftMutationTail] = [:]
  private var draftOperationOwners: [TextReplyDraftKey: UUID] = [:]
  private var draftOperationWaiters: [TextReplyDraftKey: [DraftOperationWaiter]] = [:]
  private var sealedDraftOperations: [TextReplyDraftKey: UUID] = [:]
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(
    access: AccountAccess,
    drafts: any TextReplyDraftRepository = FileTextReplyDraftStore.live(),
    imagePipeline: (any ComposerImageSubmissionPipelining)? = nil,
    attachmentStore _: ComposerImageAttachmentStore? = nil,
    attachmentDeletionScheduler: (any ComposerImageAttachmentDeletionScheduling)? = nil
  ) {
    self.access = access
    self.drafts = drafts
    self.imagePipeline = imagePipeline
    self.attachmentDeletionScheduler = attachmentDeletionScheduler
    observeAccountSessionChanges()
  }

  init(
    access: AccountAccess,
    drafts: any TextReplyDraftRepository,
    imagePipeline: (any ComposerImageSubmissionPipelining)? = nil,
    attachmentStore _: ComposerImageAttachmentStore? = nil,
    attachmentDeletionScheduler: (any ComposerImageAttachmentDeletionScheduling)? = nil,
    observesAccountSessionChanges: Bool
  ) {
    self.access = access
    self.drafts = drafts
    self.imagePipeline = imagePipeline
    self.attachmentDeletionScheduler = attachmentDeletionScheduler
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
    entry.pendingActivationLease = nil
    entry.apply(state: .loading, draft: nil)
    defer {
      if entry.epoch == operationEpoch {
        entry.pendingActivationLease = nil
      }
    }

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
      guard activationIsCurrent(
        target: target,
        scope: scope,
        entry: entry,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { return }
      entry.pendingActivationLease = lease
      guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
        throw TextReplySubmissionError.invalidSubmission
      }
      if
        let (flightTarget, flight) = submissionFlights.first(where: { $0.value.draftKey == key }),
        flight.lease == lease
      {
        guard activationIsCurrent(
          target: target,
          scope: scope,
          entry: entry,
          generation: operationGeneration,
          epoch: operationEpoch
        ) else { return }
        let owner = self.entry(for: flightTarget)
        entry.pendingActivationLease = nil
        entry.lease = lease
        entry.apply(state: owner.state, draft: owner.draft)
        return
      }
      let permit = await acquireDrainedDraftOperationPermit(for: key)
      defer { releaseDraftOperationPermit(permit, for: key) }
      guard !Task.isCancelled else { return }
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
      let resolution = try await resolveLoadedDraft(
        draft,
        target: target,
        lease: lease,
        hasFullCredentials: session.credentials != nil
      )
      guard
        try await leaseIsCurrent(lease),
        activationIsCurrent(
          target: target,
          scope: scope,
          entry: entry,
          generation: operationGeneration,
          epoch: operationEpoch
        )
      else {
        entry.lease = nil
        entry.apply(state: .accountChanged, draft: resolution.draft)
        return
      }
      if resolution.state == .accountChanged {
        entry.lease = nil
      } else {
        entry.lease = lease
      }
      entry.apply(state: resolution.state, draft: resolution.draft)
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

  func draftOwnerUserID(for target: TextReplyTarget) -> Int64? {
    entries[target]?.lease?.userID
  }

  func removeUnreferencedAttachments(
    _ candidates: [ComposerImageAttachment],
    userID: Int64,
    for target: TextReplyTarget
  ) async {
    guard
      !candidates.isEmpty,
      let attachmentDeletionScheduler,
      let key = TextReplyDraftKey(userID: userID, target: target)
    else { return }
    guard let seal = try? sealDraftOperation(for: key) else { return }
    let permit = await acquireDraftOperationPermit(for: key)
    defer {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
    }
    await waitForDraftMutations(for: key)
    let persistedDraft: TextReplyDraft?
    do {
      persistedDraft = try await drafts.draft(for: key)
    } catch {
      return
    }

    var referencedIDs = Set(persistedDraft?.attachments.map(\.id) ?? [])
    for inMemoryDraft in entries.values.compactMap(\.draft) where inMemoryDraft.key == key {
      referencedIDs.formUnion(inMemoryDraft.attachments.map(\.id))
    }
    for flight in submissionFlights.values where flight.draftKey == key {
      referencedIDs.formUnion(flight.submission.attachments.map(\.id))
    }
    let unreferenced = candidates.filter { !referencedIDs.contains($0.id) }
    _ = try? await attachmentDeletionScheduler.scheduleDeletion(of: unreferenced)
  }

  @discardableResult
  func saveDraft(
    _ content: String,
    for target: TextReplyTarget,
    at updatedAt: Date = Date()
  ) async throws -> TextReplyDraft? {
    let initialEntry = entry(for: target)
    guard stateAllowsDraftEditing(initialEntry.state), let lease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let permit = try await acquireUnsealedDraftOperationPermit(for: key)
    defer { releaseDraftOperationPermit(permit, for: key) }
    try Task.checkCancellation()
    return try await saveDraftWithPermit(
      content,
      attachments: nil,
      imageWatermark: nil,
      for: target,
      at: updatedAt
    )
  }

  @discardableResult
  func saveDraft(
    _ content: String,
    attachments: [ComposerImageAttachment]?,
    imageWatermark: TiebaStaticImageWatermark?,
    for target: TextReplyTarget,
    at updatedAt: Date = Date()
  ) async throws -> TextReplyDraft? {
    let initialEntry = entry(for: target)
    guard stateAllowsDraftEditing(initialEntry.state), let lease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = TextReplyDraftKey(userID: lease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let permit = try await acquireUnsealedDraftOperationPermit(for: key)
    defer { releaseDraftOperationPermit(permit, for: key) }
    try Task.checkCancellation()
    return try await saveDraftWithPermit(
      content,
      attachments: attachments,
      imageWatermark: imageWatermark,
      for: target,
      at: updatedAt
    )
  }

  private func saveDraftWithPermit(
    _ content: String,
    attachments: [ComposerImageAttachment]?,
    imageWatermark: TiebaStaticImageWatermark?,
    for target: TextReplyTarget,
    at updatedAt: Date
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
    let persistedDraft: TextReplyDraft?
    do {
      persistedDraft = try await drafts.draft(for: key)
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
      draft: persistedDraft ?? entry.draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    if let persistedDraft {
      switch persistedDraft.disposition {
      case .editing:
        break
      case .challengeRequired:
        guard
          entry.state == .challengeRequired,
          entry.draft?.disposition == persistedDraft.disposition
        else { throw TextReplySubmissionError.challengeRequired }
      case .submissionPending, .imagePreparationPending, .imagePipeline,
        .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility, .imageConfirmed,
        .outcomeUnknown:
        throw TextReplySubmissionError.outcomeUnknown
      }
    }
    let previousDraft = persistedDraft ?? entry.draft
    let attachments = attachments ?? previousDraft?.attachments ?? []
    let imageWatermark = imageWatermark ?? previousDraft?.imageWatermark ?? .forumName
    if entry.state == .challengeRequired {
      let disposition = challengeDisposition(for: entry, lease: lease)
      guard let draft = TextReplyDraft(
        key: key,
        content: content,
        attachments: attachments,
        imageWatermark: imageWatermark,
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
    if content.isEmpty, attachments.isEmpty {
      do {
        try await performDraftMutation(.delete(key), for: key)
        await cleanupReplacedEditingAttachments(previous: previousDraft, keeping: nil)
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
    guard
      let draft = TextReplyDraft(
        key: key,
        content: content,
        attachments: attachments,
        imageWatermark: imageWatermark,
        updatedAt: updatedAt
      )
    else {
      throw TextReplySubmissionError.invalidSubmission
    }
    do {
      try await performDraftMutation(.save(draft), for: key)
      await cleanupReplacedEditingAttachments(previous: previousDraft, keeping: draft)
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
    let initialEntry = entry(for: target)
    guard stateAllowsDraftEditing(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = TextReplyDraftKey(userID: initialLease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    defer {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
    }
    try Task.checkCancellation()
    let entry = entry(for: target)
    guard stateAllowsDraftEditing(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard TextReplyDraftKey(userID: lease.userID, target: target) == key else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    let persistedDraft: TextReplyDraft?
    do {
      persistedDraft = try await drafts.draft(for: key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { throw TextReplySubmissionError.accountChanged }
      throw TextReplySubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: persistedDraft ?? entry.draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    if let persistedDraft {
      switch persistedDraft.disposition {
      case .editing:
        break
      case .challengeRequired:
        guard
          entry.state == .challengeRequired,
          entry.draft?.disposition == persistedDraft.disposition
        else { throw TextReplySubmissionError.challengeRequired }
      case .submissionPending, .imagePreparationPending, .imagePipeline,
        .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility, .imageConfirmed,
        .outcomeUnknown:
        throw TextReplySubmissionError.outcomeUnknown
      }
    }
    let previousDraft = persistedDraft ?? entry.draft
    if case .challengeRequired = previousDraft?.disposition {
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
      await cleanupReplacedEditingAttachments(previous: previousDraft, keeping: nil)
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
    try Task.checkCancellation()
    if let flight = submissionFlights[target] {
      let currentDraft = entry(for: target).draft
      guard
        let submission = TextReplySubmission(
          id: submissionID,
          target: target,
          content: content,
          attachments: currentDraft?.attachments ?? [],
          imageWatermark: currentDraft?.imageWatermark ?? .forumName
        ),
        flight.submission == submission
      else { throw TextReplySubmissionError.submissionInProgress }
      return try await flight.task.value
    }

    let initialEntry = entry(for: target)
    guard stateAllowsSubmission(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = TextReplyDraftKey(userID: initialLease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    let task: Task<TextReplyResult, Error>
    do {
      try Task.checkCancellation()
      try await ensurePersistedDraftAllowsNewSubmission(
        for: key,
        entry: entry(for: target),
        lease: initialLease
      )
      let currentDraft = entry(for: target).draft
      guard
        let submission = TextReplySubmission(
          id: submissionID,
          target: target,
          content: content,
          attachments: currentDraft?.attachments ?? [],
          imageWatermark: currentDraft?.imageWatermark ?? .forumName
        )
      else { throw TextReplySubmissionError.invalidSubmission }
      task = try submissionTaskWithPermit(
        submission,
        for: target,
        draftKey: key,
        sealID: seal
      )
    } catch {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
      throw error
    }
    releaseDraftOperationPermit(permit, for: key)
    return try await task.value
  }

  @discardableResult
  func submit(
    _ content: String,
    attachments: [ComposerImageAttachment],
    imageWatermark: TiebaStaticImageWatermark,
    for target: TextReplyTarget,
    submissionID: UUID = UUID()
  ) async throws -> TextReplyResult {
    try Task.checkCancellation()
    guard let submission = TextReplySubmission(
      id: submissionID,
      target: target,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    ) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    if let flight = submissionFlights[target] {
      guard flight.submission == submission else {
        throw TextReplySubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let initialEntry = entry(for: target)
    guard stateAllowsSubmission(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = TextReplyDraftKey(userID: initialLease.userID, target: target) else {
      throw TextReplySubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    let task: Task<TextReplyResult, Error>
    do {
      try Task.checkCancellation()
      try await ensurePersistedDraftAllowsNewSubmission(
        for: key,
        entry: entry(for: target),
        lease: initialLease
      )
      task = try submissionTaskWithPermit(
        submission,
        for: target,
        draftKey: key,
        sealID: seal
      )
    } catch {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
      throw error
    }
    releaseDraftOperationPermit(permit, for: key)
    return try await task.value
  }

  private func submissionTaskWithPermit(
    _ submission: TextReplySubmission,
    for target: TextReplyTarget,
    draftKey: TextReplyDraftKey,
    sealID: UUID
  ) throws -> Task<TextReplyResult, Error> {
    guard submissionFlights[target] == nil else {
      throw TextReplySubmissionError.submissionInProgress
    }
    let entry = entry(for: target)
    guard stateAllowsSubmission(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    let previousDraft = entry.draft
    guard
      TextReplyDraftKey(userID: lease.userID, target: target) == draftKey,
      let editingDraft = TextReplyDraft(
        key: draftKey,
        content: submission.content,
        attachments: submission.attachments,
        imageWatermark: submission.imageWatermark
      )
    else {
      throw TextReplySubmissionError.invalidSubmission
    }

    let operationGeneration = generation
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.apply(state: .submitting(submission.id), draft: editingDraft)
    let flightID = UUID()
    let task = Task { @MainActor [weak self] () throws -> TextReplyResult in
      guard let self else { throw CancellationError() }
      defer { finishSubmissionFlight(target: target, id: flightID) }
      if submission.attachments.isEmpty {
        return try await performSubmission(
          submission,
          editingDraft: editingDraft,
          previousDraft: previousDraft,
          entry: entry,
          lease: lease,
          operationGeneration: operationGeneration,
          operationEpoch: operationEpoch
        )
      }
      return try await performInitialImageSubmission(
        submission,
        editingDraft: editingDraft,
        previousDraft: previousDraft,
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
      draftKey: draftKey,
      sealID: sealID,
      task: task
    )
    return task
  }

  @discardableResult
  func resumeImageSubmission(for target: TextReplyTarget) async throws -> TextReplyResult {
    try Task.checkCancellation()
    let entry = entry(for: target)
    guard
      case .imageRecovery(let recoveryState) = entry.state,
      recoveryAllowsExplicitResume(recoveryState),
      let draft = entry.draft,
      case .imagePipeline(let reference) = draft.disposition,
      recoveryState.reference == reference,
      let lease = entry.lease,
      lease.userID == draft.key.userID,
      lease.sessionRevision == reference.sessionRevision,
      let submission = imageSubmission(from: draft, target: target, reference: reference)
    else {
      throw stateError(entry.state)
    }
    if let flight = submissionFlights[target] {
      guard flight.submission == submission else {
        throw TextReplySubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let seal = try sealDraftOperation(for: draft.key)
    let permit = await acquireDraftOperationPermit(for: draft.key)
    let task: Task<TextReplyResult, Error>
    do {
      try Task.checkCancellation()
      guard
        entry.draft == draft,
        entry.lease == lease,
        case .imageRecovery(let currentRecoveryState) = entry.state,
        currentRecoveryState == recoveryState,
        submissionFlights[target] == nil
      else { throw stateError(entry.state) }
      let operationGeneration = generation
      let operationEpoch = nextEpoch()
      entry.epoch = operationEpoch
      entry.apply(state: .submitting(submission.id), draft: draft)
      let flightID = UUID()
      let flightTask = Task { @MainActor [weak self] () throws -> TextReplyResult in
        guard let self else { throw CancellationError() }
        defer { finishSubmissionFlight(target: target, id: flightID) }
        return try await performResumedImageSubmission(
          submission,
          pipelineDraft: draft,
          reference: reference,
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
        draftKey: draft.key,
        sealID: seal,
        task: flightTask
      )
      task = flightTask
    } catch {
      releaseDraftOperationPermit(permit, for: draft.key)
      unsealDraftOperation(seal, for: draft.key)
      throw error
    }
    releaseDraftOperationPermit(permit, for: draft.key)
    return try await task.value
  }

  func visibilityImageUploads(
    for target: TextReplyTarget
  ) async throws -> [ComposerImageUploadResult] {
    let entry = entry(for: target)
    guard
      case .acceptedAwaitingVisibility(let receipt) = entry.state,
      let draft = entry.draft,
      case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt) = draft.disposition,
      receipt == draftReceipt,
      let lease = entry.lease,
      lease.userID == draft.key.userID,
      lease.sessionRevision == reference.sessionRevision,
      let imagePipeline,
      let submission = imageSubmission(from: draft, target: target, reference: reference)
    else { throw stateError(entry.state) }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    let uploads: [ComposerImageUploadResult]
    do {
      uploads = try await imagePipeline.recoverDirectTopicReplyUploadsForVisibility(
        submission: submission,
        reference: reference
      )
    } catch {
      throw pipelineSubmissionError(error)
    }
    guard imageUploadsMatchDraft(uploads, draft: draft, lease: lease) else {
      throw TextReplySubmissionError.outcomeUnknown
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    return uploads
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
      let lease = entry.lease,
      draft.key.userID == lease.userID
    else {
      throw stateError(entry.state)
    }
    if case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt) = draft.disposition {
      guard draftReceipt == receipt else {
        throw TextReplySubmissionError.invalidSubmission
      }
      return try await confirmImageVisibility(
        confirmation,
        reference: reference,
        receipt: receipt,
        target: target,
        draft: draft,
        entry: entry,
        lease: lease
      )
    }
    guard
      case .acceptedAwaitingVisibility(let submissionID, let draftReceipt) = draft.disposition,
      draftReceipt == receipt
    else { throw stateError(entry.state) }
    guard
      confirmation.authorUserID == lease.userID,
      confirmation.content.utf8.elementsEqual(draft.content.utf8),
      confirmation.attachments == draft.attachments
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

  private func confirmImageVisibility(
    _ confirmation: TextReplyVisibilityConfirmation,
    reference: ComposerImageSubmissionReference,
    receipt: TextReplyReceipt,
    target: TextReplyTarget,
    draft: TextReplyDraft,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease
  ) async throws -> TextReplyResult {
    let created = confirmation.created
    guard
      reference.sessionRevision == lease.sessionRevision,
      confirmation.authorUserID == lease.userID,
      confirmation.content.utf8.elementsEqual(draft.content.utf8),
      confirmation.attachments == draft.attachments,
      confirmation.imageWatermark == draft.imageWatermark,
      let imagePipeline,
      let submission = imageSubmission(from: draft, target: target, reference: reference),
      let terminalDraft = imageDraft(
        from: draft,
        disposition: .imageConfirmed(reference: reference, created: created)
      ),
      let result = TextReplyResult(
        submissionID: reference.submissionID,
        userID: lease.userID,
        target: target,
        outcome: .confirmed(created)
      )
    else { throw TextReplySubmissionError.invalidSubmission }

    let uploads: [ComposerImageUploadResult]
    do {
      uploads = try await imagePipeline.recoverDirectTopicReplyUploadsForVisibility(
        submission: submission,
        reference: reference
      )
    } catch {
      throw pipelineSubmissionError(error)
    }
    guard imageUploadsMatchDraft(uploads, draft: draft, lease: lease) else {
      throw TextReplySubmissionError.outcomeUnknown
    }

    let operationGeneration = generation
    let operationEpoch = entry.epoch
    guard try await leaseIsCurrent(lease) else {
      entry.lease = nil
      entry.apply(state: .accountChanged, draft: draft)
      throw TextReplySubmissionError.accountChanged
    }
    do {
      try await performDraftMutation(.save(terminalDraft), for: terminalDraft.key)
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
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
      throw TextReplySubmissionError.unavailable
    }

    let didComplete = await markImageSubmissionCompleted(
      submission: submission,
      reference: reference
    )
    var retainedDraft: TextReplyDraft? = terminalDraft
    if didComplete {
      let didClean = await cleanupCompletedImageSubmission(
        submission: submission,
        terminalDraft: terminalDraft,
        reference: reference,
        userID: lease.userID
      )
      if didClean { retainedDraft = nil }
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
      throw TextReplySubmissionError.accountChanged
    }
    entry.apply(state: .confirmed(created), draft: retainedDraft)
    return result
  }

  func accountSessionDidChange() {
    generation &+= 1
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.pendingActivationLease = nil
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

  private func performInitialImageSubmission(
    _ submission: TextReplySubmission,
    editingDraft: TextReplyDraft,
    previousDraft: TextReplyDraft?,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    guard
      !submission.attachments.isEmpty,
      let imagePipeline,
      let reference = ComposerImageSubmissionReference(
        submissionID: submission.id,
        sessionRevision: lease.sessionRevision
      ),
      let intent = ComposerImageSubmissionIntent(directTopicReply: submission)
    else {
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
      try await performDraftMutation(.save(editingDraft), for: editingDraft.key)
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
    await cleanupReplacedEditingAttachments(previous: previousDraft, keeping: editingDraft)
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: editingDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )

    do {
      if try await imagePipeline.blockingRecoveryState(
        for: intent.context,
        userID: lease.userID
      ) != nil {
        entry.apply(state: .imageRecoveryUnavailable, draft: editingDraft)
        throw TextReplySubmissionError.outcomeUnknown
      }
    } catch let error as TextReplySubmissionError {
      throw error
    } catch {
      entry.apply(state: .imageRecoveryUnavailable, draft: editingDraft)
      throw pipelineSubmissionError(error)
    }

    guard
      let preparationDraft = imageDraft(
        from: editingDraft,
        disposition: .imagePreparationPending(reference: reference)
      )
    else {
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
      try await performDraftMutation(.save(preparationDraft), for: preparationDraft.key)
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
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: preparationDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )

    let preparedState: ComposerImageSubmissionRecoveryState
    do {
      preparedState = try await imagePipeline.prepareDirectTopicReply(
        submission: submission,
        reference: reference
      )
    } catch {
      return try await finishImagePreparationFailure(
        error,
        intent: intent,
        editingDraft: editingDraft,
        preparationDraft: preparationDraft,
        entry: entry,
        lease: lease,
        operationGeneration: operationGeneration,
        operationEpoch: operationEpoch
      )
    }
    guard
      case .uploadResumeRequired(let preparedReference, let successfulCount, let totalCount) =
        preparedState,
      preparedReference == reference,
      successfulCount == 0,
      totalCount == submission.attachments.count,
      let pipelineDraft = imageDraft(
        from: editingDraft,
        disposition: .imagePipeline(reference: reference)
      )
    else {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw TextReplySubmissionError.outcomeUnknown
    }
    do {
      try await performDraftMutation(.save(pipelineDraft), for: pipelineDraft.key)
    } catch {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw TextReplySubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: pipelineDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    return try await performResumedImageSubmission(
      submission,
      pipelineDraft: pipelineDraft,
      reference: reference,
      entry: entry,
      lease: lease,
      operationGeneration: operationGeneration,
      operationEpoch: operationEpoch
    )
  }

  private func performResumedImageSubmission(
    _ submission: TextReplySubmission,
    pipelineDraft: TextReplyDraft,
    reference: ComposerImageSubmissionReference,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    guard
      let imagePipeline,
      reference.submissionID == submission.id,
      reference.sessionRevision == lease.sessionRevision,
      pipelineDraft.attachments == submission.attachments,
      pipelineDraft.imageWatermark == submission.imageWatermark
    else {
      entry.apply(state: .imageRecoveryUnavailable, draft: pipelineDraft)
      throw TextReplySubmissionError.invalidSubmission
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: pipelineDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )

    let result: TextReplyResult
    do {
      result = try await imagePipeline.executeDirectTopicReply(
        submission: submission,
        reference: reference
      )
    } catch {
      return try await finishImageExecutionFailure(
        error,
        submission: submission,
        pipelineDraft: pipelineDraft,
        reference: reference,
        entry: entry,
        lease: lease,
        operationGeneration: operationGeneration,
        operationEpoch: operationEpoch
      )
    }
    return try await finishImageSubmissionSuccess(
      result,
      submission: submission,
      pipelineDraft: pipelineDraft,
      reference: reference,
      entry: entry,
      lease: lease,
      operationGeneration: operationGeneration,
      operationEpoch: operationEpoch
    )
  }

  private func finishImagePreparationFailure(
    _ source: Error,
    intent: ComposerImageSubmissionIntent,
    editingDraft: TextReplyDraft,
    preparationDraft: TextReplyDraft,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    guard let imagePipeline else {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw TextReplySubmissionError.unavailable
    }
    let blockingState: ComposerImageSubmissionRecoveryState?
    do {
      blockingState = try await imagePipeline.blockingRecoveryState(
        for: intent.context,
        userID: lease.userID
      )
    } catch {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw pipelineSubmissionError(source)
    }

    let retainedDraft: TextReplyDraft
    if blockingState == nil {
      do {
        try await performDraftMutation(.save(editingDraft), for: editingDraft.key)
        retainedDraft = editingDraft
      } catch {
        retainedDraft = preparationDraft
      }
      if entryIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) {
        entry.apply(
          state: retainedDraft == editingDraft
            ? .failed(pipelineSubmissionError(source))
            : .imageRecoveryUnavailable,
          draft: retainedDraft
        )
      }
    } else {
      retainedDraft = preparationDraft
      if entryIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) {
        entry.apply(state: .imageRecoveryUnavailable, draft: retainedDraft)
      }
    }
    let mappedError = pipelineSubmissionError(source)
    if mappedError == .accountChanged {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: retainedDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
    }
    throw mappedError
  }

  private func finishImageExecutionFailure(
    _ source: Error,
    submission: TextReplySubmission,
    pipelineDraft: TextReplyDraft,
    reference: ComposerImageSubmissionReference,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    let recoveryState: ComposerImageSubmissionRecoveryState?
    if let imagePipeline,
      let intent = ComposerImageSubmissionIntent(directTopicReply: submission)
    {
      recoveryState = try? await imagePipeline.recoveryState(
        for: intent,
        reference: reference,
        userID: lease.userID
      )
    } else {
      recoveryState = nil
    }

    guard entryIsCurrent(
      entry,
      lease: lease,
      generation: operationGeneration,
      epoch: operationEpoch
    ) else {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: pipelineDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw TextReplySubmissionError.accountChanged
    }
    let mappedError = pipelineSubmissionError(source)
    if mappedError == .accountChanged {
      applyAccountChangedIfOwned(
        entry,
        lease: lease,
        draft: pipelineDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw mappedError
    }
    if let recoveryState {
      entry.apply(state: .imageRecovery(recoveryState), draft: pipelineDraft)
    } else {
      entry.apply(state: .imageRecoveryUnavailable, draft: pipelineDraft)
    }
    throw mappedError
  }

  private func finishImageSubmissionSuccess(
    _ result: TextReplyResult,
    submission: TextReplySubmission,
    pipelineDraft: TextReplyDraft,
    reference: ComposerImageSubmissionReference,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> TextReplyResult {
    guard
      result.submissionID == submission.id,
      result.userID == lease.userID,
      result.target == submission.target,
      let terminalDraft: TextReplyDraft = switch result.outcome {
      case .confirmed(let created):
        imageDraft(
          from: pipelineDraft,
          disposition: .imageConfirmed(reference: reference, created: created)
        )
      case .acceptedAwaitingVisibility(let receipt):
        imageDraft(
          from: pipelineDraft,
          disposition: .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt)
        )
      }
    else {
      entry.apply(state: .imageRecoveryUnavailable, draft: pipelineDraft)
      throw TextReplySubmissionError.outcomeUnknown
    }
    do {
      try await performDraftMutation(.save(terminalDraft), for: terminalDraft.key)
    } catch {
      entry.apply(state: .outcomeUnknown, draft: pipelineDraft)
      throw TextReplySubmissionError.outcomeUnknown
    }

    let didComplete = await markImageSubmissionCompleted(
      submission: submission,
      reference: reference
    )
    var retainedDraft: TextReplyDraft? = terminalDraft
    if case .confirmed = result.outcome, didComplete {
      let didClean = await cleanupCompletedImageSubmission(
        submission: submission,
        terminalDraft: terminalDraft,
        reference: reference,
        userID: lease.userID
      )
      if didClean { retainedDraft = nil }
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
      throw TextReplySubmissionError.accountChanged
    }
    switch result.outcome {
    case .confirmed(let created):
      entry.apply(state: .confirmed(created), draft: retainedDraft)
    case .acceptedAwaitingVisibility(let receipt):
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: terminalDraft)
    }
    return result
  }

  private func performSubmission(
    _ submission: TextReplySubmission,
    editingDraft: TextReplyDraft,
    previousDraft: TextReplyDraft?,
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

    await cleanupReplacedEditingAttachments(previous: previousDraft, keeping: editingDraft)

    if let imagePipeline,
      let context = ComposerImageUploadContext(directTopicReply: submission.target)
    {
      do {
        if try await imagePipeline.blockingRecoveryState(
          for: context,
          userID: lease.userID
        ) != nil {
          entry.apply(state: .imageRecoveryUnavailable, draft: editingDraft)
          throw TextReplySubmissionError.outcomeUnknown
        }
      } catch let error as TextReplySubmissionError {
        throw error
      } catch {
        entry.apply(state: .imageRecoveryUnavailable, draft: editingDraft)
        throw pipelineSubmissionError(error)
      }
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: editingDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )

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

  private func resolveLoadedDraft(
    _ draft: TextReplyDraft?,
    target: TextReplyTarget,
    lease: TextReplySessionLease,
    hasFullCredentials: Bool
  ) async throws -> LoadedDraftResolution {
    guard
      let imagePipeline,
      let context = ComposerImageUploadContext(directTopicReply: target)
    else {
      if draft?.disposition.imageSubmissionReference != nil {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      return plainLoadedDraftResolution(
        draft,
        lease: lease,
        hasFullCredentials: hasFullCredentials
      )
    }

    let blockingState: ComposerImageSubmissionRecoveryState?
    do {
      blockingState = try await imagePipeline.blockingRecoveryState(
        for: context,
        userID: lease.userID
      )
    } catch {
      return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
    }

    guard let draft else {
      if blockingState != nil {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: nil)
      }
      return plainLoadedDraftResolution(
        nil,
        lease: lease,
        hasFullCredentials: hasFullCredentials
      )
    }

    switch draft.disposition {
    case .imagePreparationPending(let reference):
      guard let blockingState else {
        guard
          let editingDraft = imageDraft(from: draft, disposition: .editing),
          (try? await performDraftMutation(.save(editingDraft), for: editingDraft.key)) != nil
        else {
          return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
        }
        return plainLoadedDraftResolution(
          editingDraft,
          lease: lease,
          hasFullCredentials: hasFullCredentials
        )
      }
      guard blockingState.reference == reference else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      guard
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(directTopicReply: submission),
        let exactState = try? await imagePipeline.recoveryState(
          for: intent,
          reference: reference,
          userID: lease.userID
        ),
        exactState == blockingState,
        let pipelineDraft = imageDraft(
          from: draft,
          disposition: .imagePipeline(reference: reference)
        ),
        (try? await performDraftMutation(.save(pipelineDraft), for: pipelineDraft.key)) != nil
      else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      return loadedImageRecoveryResolution(
        exactState,
        draft: pipelineDraft,
        lease: lease
      )

    case .imagePipeline(let reference):
      guard
        let blockingState,
        blockingState.reference == reference,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(directTopicReply: submission),
        let exactState = try? await imagePipeline.recoveryState(
          for: intent,
          reference: reference,
          userID: lease.userID
        ),
        exactState == blockingState
      else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      return loadedImageRecoveryResolution(exactState, draft: draft, lease: lease)

    case .imageAcceptedAwaitingVisibility(let reference, let receipt):
      guard
        reference.sessionRevision == lease.sessionRevision,
        let blockingState,
        blockingState.reference == reference,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(directTopicReply: submission),
        let exactState = try? await imagePipeline.recoveryState(
          for: intent,
          reference: reference,
          userID: lease.userID
        ),
        exactState == blockingState,
        recoveryIsFinalSubmissionTerminal(exactState)
      else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      _ = await markImageSubmissionCompleted(
        submission: submission,
        reference: reference
      )
      return LoadedDraftResolution(
        state: .acceptedAwaitingVisibility(receipt),
        draft: draft
      )

    case .imageConfirmed(let reference, let created):
      guard created.belongs(to: target) else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      guard let blockingState else {
        do {
          try await performDraftMutation(.delete(draft.key), for: draft.key)
          return LoadedDraftResolution(state: .confirmed(created), draft: nil)
        } catch {
          return LoadedDraftResolution(state: .confirmed(created), draft: draft)
        }
      }
      guard
        blockingState.reference == reference,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(directTopicReply: submission),
        let exactState = try? await imagePipeline.recoveryState(
          for: intent,
          reference: reference,
          userID: lease.userID
        ),
        exactState == blockingState,
        recoveryIsFinalSubmissionTerminal(exactState)
      else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      let didComplete = await markImageSubmissionCompleted(
        submission: submission,
        reference: reference
      )
      var didClean = false
      if didComplete {
        didClean = await cleanupCompletedImageSubmission(
          submission: submission,
          terminalDraft: draft,
          reference: reference,
          userID: lease.userID
        )
      }
      return LoadedDraftResolution(
        state: .confirmed(created),
        draft: didClean ? nil : draft
      )

    case .editing:
      guard let blockingState else {
        return plainLoadedDraftResolution(
          draft,
          lease: lease,
          hasFullCredentials: hasFullCredentials
        )
      }
      let reference = blockingState.reference
      guard
        !draft.attachments.isEmpty,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(directTopicReply: submission),
        let exactState = try? await imagePipeline.recoveryState(
          for: intent,
          reference: reference,
          userID: lease.userID
        ),
        exactState == blockingState,
        let pipelineDraft = imageDraft(
          from: draft,
          disposition: .imagePipeline(reference: reference)
        ),
        (try? await performDraftMutation(.save(pipelineDraft), for: pipelineDraft.key)) != nil
      else {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      return loadedImageRecoveryResolution(
        exactState,
        draft: pipelineDraft,
        lease: lease
      )

    case .submissionPending, .challengeRequired, .acceptedAwaitingVisibility, .outcomeUnknown:
      if blockingState != nil {
        return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
      }
      return plainLoadedDraftResolution(
        draft,
        lease: lease,
        hasFullCredentials: hasFullCredentials
      )
    }
  }

  private func plainLoadedDraftResolution(
    _ draft: TextReplyDraft?,
    lease: TextReplySessionLease,
    hasFullCredentials: Bool
  ) -> LoadedDraftResolution {
    guard hasFullCredentials else {
      return LoadedDraftResolution(state: .failed(.fullCredentialsRequired), draft: draft)
    }
    guard let draft else {
      return LoadedDraftResolution(state: .ready, draft: nil)
    }
    let state: TextReplySubmissionState = switch draft.disposition {
    case .editing:
      .ready
    case .submissionPending, .outcomeUnknown:
      .outcomeUnknown
    case .challengeRequired(_, let blockedRevision):
      blockedRevision == lease.sessionRevision ? .challengeRequired : .ready
    case .acceptedAwaitingVisibility(_, let receipt):
      .acceptedAwaitingVisibility(receipt)
    case .imagePreparationPending, .imagePipeline, .imageAcceptedAwaitingVisibility,
      .imageConfirmed:
      .imageRecoveryUnavailable
    }
    return LoadedDraftResolution(state: state, draft: draft)
  }

  private func loadedImageRecoveryResolution(
    _ recoveryState: ComposerImageSubmissionRecoveryState,
    draft: TextReplyDraft,
    lease: TextReplySessionLease
  ) -> LoadedDraftResolution {
    guard recoveryState.reference.sessionRevision == lease.sessionRevision else {
      return LoadedDraftResolution(state: .accountChanged, draft: draft)
    }
    switch recoveryState {
    case .uploadResumeRequired, .finalSubmissionResumeRequired, .locked:
      return LoadedDraftResolution(state: .imageRecovery(recoveryState), draft: draft)
    case .completed:
      return LoadedDraftResolution(state: .imageRecoveryUnavailable, draft: draft)
    }
  }

  private func recoveryAllowsExplicitResume(
    _ recoveryState: ComposerImageSubmissionRecoveryState
  ) -> Bool {
    switch recoveryState {
    case .uploadResumeRequired, .finalSubmissionResumeRequired:
      true
    case .locked, .completed:
      false
    }
  }

  private func recoveryIsFinalSubmissionTerminal(
    _ recoveryState: ComposerImageSubmissionRecoveryState
  ) -> Bool {
    switch recoveryState {
    case .locked(_, let operation):
      operation == .finalSubmission
    case .completed:
      true
    case .uploadResumeRequired, .finalSubmissionResumeRequired:
      false
    }
  }

  private func imageSubmission(
    from draft: TextReplyDraft,
    target: TextReplyTarget,
    reference: ComposerImageSubmissionReference
  ) -> TextReplySubmission? {
    guard
      let expectedKey = TextReplyDraftKey(userID: draft.key.userID, target: target),
      expectedKey == draft.key,
      !draft.attachments.isEmpty
    else { return nil }
    return TextReplySubmission(
      id: reference.submissionID,
      target: target,
      content: draft.content,
      attachments: draft.attachments,
      imageWatermark: draft.imageWatermark
    )
  }

  private func imageDraft(
    from draft: TextReplyDraft,
    disposition: TextReplyDraftDisposition
  ) -> TextReplyDraft? {
    TextReplyDraft(
      key: draft.key,
      content: draft.content,
      attachments: draft.attachments,
      imageWatermark: draft.imageWatermark,
      disposition: disposition,
      updatedAt: Date()
    )
  }

  private func imageUploadsMatchDraft(
    _ uploads: [ComposerImageUploadResult],
    draft: TextReplyDraft,
    lease: TextReplySessionLease
  ) -> Bool {
    uploads.count == draft.attachments.count
      && uploads.map(\.attachment) == draft.attachments
      && uploads.allSatisfy {
        $0.sessionRevision == lease.sessionRevision
          && $0.watermark == draft.imageWatermark
      }
  }

  private func markImageSubmissionCompleted(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async -> Bool {
    guard
      let imagePipeline,
      let intent = ComposerImageSubmissionIntent(directTopicReply: submission)
    else { return false }
    do {
      return try await imagePipeline.markCompleted(
        intent: intent,
        reference: reference
      ) == .completed(reference: reference)
    } catch {
      return false
    }
  }

  private func cleanupCompletedImageSubmission(
    submission: TextReplySubmission,
    terminalDraft: TextReplyDraft,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async -> Bool {
    guard
      case .imageConfirmed(let storedReference, _) = terminalDraft.disposition,
      storedReference == reference,
      let imagePipeline,
      let intent = ComposerImageSubmissionIntent(directTopicReply: submission)
    else { return false }
    do {
      try await imagePipeline.removeAttachments(intent: intent, reference: reference)
      try await imagePipeline.deleteCompleted(
        intent: intent,
        reference: reference,
        userID: userID
      )
      try await performDraftMutation(.delete(terminalDraft.key), for: terminalDraft.key)
      return true
    } catch {
      return false
    }
  }

  private func pipelineSubmissionError(_ source: Error) -> TextReplySubmissionError {
    if source is CancellationError { return .outcomeUnknown }
    if let error = source as? TextReplySubmissionError { return error }
    guard let error = source as? ComposerImageSubmissionPipelineError else {
      return .unavailable
    }
    switch error {
    case .signedOut:
      return .signedOut
    case .fullCredentialsRequired:
      return .fullCredentialsRequired
    case .accountChanged:
      return .accountChanged
    case .invalidIntent, .referenceMismatch, .intentMismatch:
      return .invalidSubmission
    case .locked, .outcomeUnknown, .activeRecordExists:
      return .outcomeUnknown
    case .recordNotFound, .uploadResumeRequired, .finalSubmissionResumeRequired, .completed,
      .attachmentUnavailable, .preparationFailed, .ledgerUnavailable, .invalidState,
      .unavailable:
      return .unavailable
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
    case .imageRecovery(let recoveryState):
      switch recoveryState {
      case .locked, .completed:
        .outcomeUnknown
      case .uploadResumeRequired, .finalSubmissionResumeRequired:
        .unavailable
      }
    case .imageRecoveryUnavailable:
      .unavailable
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

  private func ensurePersistedDraftAllowsNewSubmission(
    for key: TextReplyDraftKey,
    entry: TextReplySubmissionEntry,
    lease: TextReplySessionLease
  ) async throws {
    guard
      entry.lease == lease,
      stateAllowsSubmission(entry.state),
      TextReplyDraftKey(userID: lease.userID, target: entry.target) == key
    else { throw stateError(entry.state) }

    await waitForDraftMutations(for: key)
    let persistedDraft: TextReplyDraft?
    do {
      persistedDraft = try await drafts.draft(for: key)
    } catch {
      throw TextReplySubmissionError.unavailable
    }
    guard entry.lease == lease else {
      throw TextReplySubmissionError.accountChanged
    }
    guard let persistedDraft else { return }

    switch persistedDraft.disposition {
    case .editing:
      return
    case .challengeRequired(_, let blockedRevision):
      guard blockedRevision == lease.sessionRevision else { return }
      entry.apply(state: .challengeRequired, draft: persistedDraft)
      throw TextReplySubmissionError.challengeRequired
    case .acceptedAwaitingVisibility(_, let receipt),
      .imageAcceptedAwaitingVisibility(_, let receipt):
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: persistedDraft)
      throw TextReplySubmissionError.outcomeUnknown
    case .imageConfirmed(_, let created):
      entry.apply(state: .confirmed(created), draft: persistedDraft)
      throw TextReplySubmissionError.outcomeUnknown
    case .imagePreparationPending, .imagePipeline:
      entry.apply(state: .imageRecoveryUnavailable, draft: persistedDraft)
      throw TextReplySubmissionError.outcomeUnknown
    case .submissionPending, .outcomeUnknown:
      entry.apply(state: .outcomeUnknown, draft: persistedDraft)
      throw TextReplySubmissionError.outcomeUnknown
    }
  }

  private func cleanupReplacedEditingAttachments(
    previous: TextReplyDraft?,
    keeping replacement: TextReplyDraft?
  ) async {
    guard
      let attachmentDeletionScheduler,
      let previous,
      case .editing = previous.disposition
    else { return }
    let retainedIDs = Set(replacement?.attachments.map(\.id) ?? [])
    let removed = previous.attachments.filter { !retainedIDs.contains($0.id) }
    _ = try? await attachmentDeletionScheduler.scheduleDeletion(of: removed)
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
    guard let flight = submissionFlights[target], flight.id == id else { return }
    synchronizeAliasEntries(after: flight, ownerTarget: target)
    submissionFlights.removeValue(forKey: target)
    unsealDraftOperation(flight.sealID, for: flight.draftKey)
    removeEntryIfInactive(target)
  }

  private func synchronizeAliasEntries(
    after flight: SubmissionFlight,
    ownerTarget: TextReplyTarget
  ) {
    let owner = entry(for: ownerTarget)
    let state: TextReplySubmissionState
    switch owner.state {
    case .challengeRequired, .outcomeUnknown, .acceptedAwaitingVisibility, .confirmed,
      .imageRecovery, .imageRecoveryUnavailable, .signedOut, .accountChanged:
      state = owner.state
    case .failed:
      state = owner.state
    case .submitting:
      state = .outcomeUnknown
      let draft = owner.draft
      owner.apply(state: state, draft: draft)
    case .inactive, .loading, .ready:
      return
    }

    for alias in Array(entries.values) where alias !== owner {
      guard
        TextReplyDraftKey(userID: flight.lease.userID, target: alias.target) == flight.draftKey
      else { continue }
      if case .failed = state {
        guard
          alias.lease == flight.lease,
          case .submitting(let submissionID) = alias.state,
          submissionID == flight.submission.id
        else { continue }
      } else {
        guard
          alias.lease == flight.lease
            || (
              alias.state == .loading
                && alias.pendingActivationLease == flight.lease
            )
        else { continue }
      }
      alias.epoch = nextEpoch()
      alias.pendingActivationLease = nil
      if state == .accountChanged {
        alias.lease = nil
      } else {
        alias.lease = flight.lease
      }
      alias.apply(state: state, draft: owner.draft)
    }
  }

  private func ensureDraftOperationIsUnsealed(for key: TextReplyDraftKey) throws {
    guard sealedDraftOperations[key] == nil else {
      throw TextReplySubmissionError.submissionInProgress
    }
  }

  private func sealDraftOperation(for key: TextReplyDraftKey) throws -> UUID {
    try ensureDraftOperationIsUnsealed(for: key)
    let id = UUID()
    sealedDraftOperations[key] = id
    return id
  }

  private func unsealDraftOperation(_ id: UUID, for key: TextReplyDraftKey) {
    guard sealedDraftOperations[key] == id else { return }
    sealedDraftOperations.removeValue(forKey: key)
  }

  private func acquireDraftOperationPermit(
    for key: TextReplyDraftKey,
    isDrain: Bool = false
  ) async -> UUID {
    let id = UUID()
    guard draftOperationOwners[key] != nil else {
      draftOperationOwners[key] = id
      return id
    }
    await withCheckedContinuation { continuation in
      draftOperationWaiters[key, default: []].append(
        DraftOperationWaiter(id: id, isDrain: isDrain, continuation: continuation)
      )
    }
    return id
  }

  private func acquireUnsealedDraftOperationPermit(for key: TextReplyDraftKey) async throws
    -> UUID
  {
    try ensureDraftOperationIsUnsealed(for: key)
    let id = UUID()
    guard draftOperationOwners[key] != nil else {
      draftOperationOwners[key] = id
      return id
    }
    await withCheckedContinuation { continuation in
      draftOperationWaiters[key, default: []].append(
        DraftOperationWaiter(id: id, isDrain: false, continuation: continuation)
      )
    }
    return id
  }

  private func acquireDrainedDraftOperationPermit(for key: TextReplyDraftKey) async -> UUID {
    while true {
      let id = await acquireDraftOperationPermit(for: key, isDrain: true)
      let hasPendingMutation = draftOperationWaiters[key]?.contains { !$0.isDrain } == true
      guard !hasPendingMutation else {
        releaseDraftOperationPermit(id, for: key)
        await Task.yield()
        continue
      }
      return id
    }
  }

  private func releaseDraftOperationPermit(_ id: UUID, for key: TextReplyDraftKey) {
    guard draftOperationOwners[key] == id else { return }
    guard var waiters = draftOperationWaiters[key], !waiters.isEmpty else {
      draftOperationOwners.removeValue(forKey: key)
      draftOperationWaiters.removeValue(forKey: key)
      return
    }
    let next = waiters.removeFirst()
    if waiters.isEmpty {
      draftOperationWaiters.removeValue(forKey: key)
    } else {
      draftOperationWaiters[key] = waiters
    }
    draftOperationOwners[key] = next.id
    next.continuation.resume()
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
