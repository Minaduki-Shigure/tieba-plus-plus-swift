import Combine
import Foundation
import TiebaCore

enum NewThreadSubmissionState: Equatable {
  case inactive
  case loading
  case signedOut
  case ready
  case submitting(UUID)
  case imageRecovery(ComposerImageSubmissionRecoveryState)
  case imageRecoveryUnavailable
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
  private struct LoadedDraftResolution {
    let state: NewThreadSubmissionState
    let draft: NewThreadDraft?
  }

  private struct SubmissionFlight {
    let id: UUID
    let lease: NewThreadSessionLease
    let submission: NewThreadSubmission
    let draftKey: NewThreadDraftKey
    let sealID: UUID
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

  private struct DraftOperationWaiter {
    let id: UUID
    let isDrain: Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private let access: AccountAccess
  private let drafts: any NewThreadDraftRepository
  private let imagePipeline: (any ComposerImageSubmissionPipelining)?
  private let attachmentDeletionScheduler:
    (any ComposerImageAttachmentDeletionScheduling)?
  private var entries: [NewThreadTarget: NewThreadSubmissionEntry] = [:]
  private var scopeTargets: [UUID: NewThreadTarget] = [:]
  private var submissionFlights: [NewThreadTarget: SubmissionFlight] = [:]
  private var draftMutationTails: [NewThreadDraftKey: DraftMutationTail] = [:]
  private var draftOperationOwners: [NewThreadDraftKey: UUID] = [:]
  private var draftOperationWaiters: [NewThreadDraftKey: [DraftOperationWaiter]] = [:]
  private var sealedDraftOperations: [NewThreadDraftKey: UUID] = [:]
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(
    access: AccountAccess,
    drafts: any NewThreadDraftRepository = FileNewThreadDraftStore.live(),
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
    drafts: any NewThreadDraftRepository,
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

  func draftOwnerUserID(for target: NewThreadTarget) -> Int64? {
    entries[target]?.lease?.userID
  }

  func removeUnreferencedAttachments(
    _ candidates: [ComposerImageAttachment],
    userID: Int64,
    for target: NewThreadTarget
  ) async {
    guard
      !candidates.isEmpty,
      let attachmentDeletionScheduler,
      let key = NewThreadDraftKey(userID: userID, target: target)
    else { return }
    guard let seal = try? sealDraftOperation(for: key) else { return }
    let permit = await acquireDraftOperationPermit(for: key)
    defer {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
    }
    await waitForDraftMutations(for: key)
    let persistedDraft: NewThreadDraft?
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
    title: String?,
    content: String,
    for target: NewThreadTarget,
    at updatedAt: Date = Date()
  ) async throws -> NewThreadDraft? {
    let initialEntry = entry(for: target)
    guard stateAllowsDraftEditing(initialEntry.state), let lease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = NewThreadDraftKey(userID: lease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let permit = try await acquireUnsealedDraftOperationPermit(for: key)
    defer { releaseDraftOperationPermit(permit, for: key) }
    try Task.checkCancellation()
    return try await saveDraftWithPermit(
      title: title,
      content: content,
      attachments: nil,
      imageWatermark: nil,
      for: target,
      at: updatedAt
    )
  }

  @discardableResult
  func saveDraft(
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment]?,
    imageWatermark: TiebaStaticImageWatermark?,
    for target: NewThreadTarget,
    at updatedAt: Date = Date()
  ) async throws -> NewThreadDraft? {
    let initialEntry = entry(for: target)
    guard stateAllowsDraftEditing(initialEntry.state), let lease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = NewThreadDraftKey(userID: lease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let permit = try await acquireUnsealedDraftOperationPermit(for: key)
    defer { releaseDraftOperationPermit(permit, for: key) }
    try Task.checkCancellation()
    return try await saveDraftWithPermit(
      title: title,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark,
      for: target,
      at: updatedAt
    )
  }

  private func saveDraftWithPermit(
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment]?,
    imageWatermark: TiebaStaticImageWatermark?,
    for target: NewThreadTarget,
    at updatedAt: Date
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
    let persistedDraft: NewThreadDraft?
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
        throw NewThreadSubmissionError.accountChanged
      }
      throw NewThreadSubmissionError.unavailable
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: persistedDraft ?? entry.draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    if let persistedDraft, case .editing = persistedDraft.disposition {
      // Editing drafts may be replaced after the canonical key permit is acquired.
    } else if persistedDraft != nil {
      throw NewThreadSubmissionError.outcomeUnknown
    }
    let previousDraft = persistedDraft ?? entry.draft
    let attachments = attachments ?? previousDraft?.attachments ?? []
    let imageWatermark = imageWatermark ?? previousDraft?.imageWatermark ?? .forumName

    if normalizedTitle == nil, content.isEmpty, attachments.isEmpty {
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
      await removeObsoleteEditingAttachments(
        from: previousDraft,
        retaining: []
      )
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
      attachments: attachments,
      imageWatermark: imageWatermark,
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
    await removeObsoleteEditingAttachments(
      from: previousDraft,
      retaining: draft.attachments
    )
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
    let initialEntry = entry(for: target)
    guard stateAllowsDraftDiscard(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = NewThreadDraftKey(userID: initialLease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    defer {
      releaseDraftOperationPermit(permit, for: key)
      unsealDraftOperation(seal, for: key)
    }
    try Task.checkCancellation()
    let entry = entry(for: target)
    guard stateAllowsDraftDiscard(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    guard NewThreadDraftKey(userID: lease.userID, target: target) == key else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let operationGeneration = generation
    let operationEpoch = entry.epoch
    let persistedDraft: NewThreadDraft?
    do {
      persistedDraft = try await drafts.draft(for: key)
    } catch {
      guard await operationIsCurrent(
        entry,
        lease: lease,
        generation: operationGeneration,
        epoch: operationEpoch
      ) else { throw NewThreadSubmissionError.accountChanged }
      throw NewThreadSubmissionError.unavailable
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
      case .confirmed, .imageConfirmed:
        guard entry.state == .confirmed else {
          throw NewThreadSubmissionError.outcomeUnknown
        }
      case .challengeRequired:
        throw NewThreadSubmissionError.challengeRequired
      case .submissionPending, .imagePreparationPending, .imagePipeline,
        .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility, .outcomeUnknown:
        throw NewThreadSubmissionError.outcomeUnknown
      }
    }
    let discardedDraft = persistedDraft ?? entry.draft
    if let discardedDraft,
      case .imageConfirmed = discardedDraft.disposition
    {
      guard
        let imagePipeline,
        let context = ComposerImageUploadContext(newThread: target)
      else { throw NewThreadSubmissionError.unavailable }
      do {
        guard try await imagePipeline.blockingRecoveryState(
          for: context,
          userID: lease.userID
        ) == nil else {
          throw NewThreadSubmissionError.unavailable
        }
      } catch let error as NewThreadSubmissionError {
        throw error
      } catch {
        throw pipelineSubmissionError(error)
      }
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
        throw NewThreadSubmissionError.accountChanged
      }
      throw NewThreadSubmissionError.unavailable
    }
    await removeDiscardedDraftAttachments(discardedDraft)
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
    if let flight = submissionFlights[target] {
      let currentDraft = entry(for: target).draft
      guard
        let submission = NewThreadSubmission(
          id: submissionID,
          target: target,
          title: title,
          content: content,
          attachments: currentDraft?.attachments ?? [],
          imageWatermark: currentDraft?.imageWatermark ?? .forumName
        ),
        flight.submission == submission
      else { throw NewThreadSubmissionError.submissionInProgress }
      return try await flight.task.value
    }

    let initialEntry = entry(for: target)
    guard stateAllowsSubmission(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = NewThreadDraftKey(userID: initialLease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    let task: Task<NewThreadResult, Error>
    do {
      try Task.checkCancellation()
      let currentDraft = entry(for: target).draft
      guard
        let submission = NewThreadSubmission(
          id: submissionID,
          target: target,
          title: title,
          content: content,
          attachments: currentDraft?.attachments ?? [],
          imageWatermark: currentDraft?.imageWatermark ?? .forumName
        )
      else { throw NewThreadSubmissionError.invalidSubmission }
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
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment],
    imageWatermark: TiebaStaticImageWatermark,
    for target: NewThreadTarget,
    submissionID: UUID = UUID()
  ) async throws -> NewThreadResult {
    try Task.checkCancellation()
    guard let submission = NewThreadSubmission(
      id: submissionID,
      target: target,
      title: title,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    ) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    if let flight = submissionFlights[target] {
      guard flight.submission == submission else {
        throw NewThreadSubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let initialEntry = entry(for: target)
    guard stateAllowsSubmission(initialEntry.state), let initialLease = initialEntry.lease else {
      throw stateError(initialEntry.state)
    }
    guard let key = NewThreadDraftKey(userID: initialLease.userID, target: target) else {
      throw NewThreadSubmissionError.invalidSubmission
    }
    let seal = try sealDraftOperation(for: key)
    let permit = await acquireDraftOperationPermit(for: key)
    let task: Task<NewThreadResult, Error>
    do {
      try Task.checkCancellation()
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
    _ submission: NewThreadSubmission,
    for target: NewThreadTarget,
    draftKey: NewThreadDraftKey,
    sealID: UUID
  ) throws -> Task<NewThreadResult, Error> {
    guard submissionFlights[target] == nil else {
      throw NewThreadSubmissionError.submissionInProgress
    }
    let entry = entry(for: target)
    guard stateAllowsSubmission(entry.state), let lease = entry.lease else {
      throw stateError(entry.state)
    }
    let previousDraft = entry.draft
    guard
      NewThreadDraftKey(userID: lease.userID, target: target) == draftKey,
      let editingDraft = NewThreadDraft(
        key: draftKey,
        title: submission.title,
        content: submission.content,
        attachments: submission.attachments,
        imageWatermark: submission.imageWatermark
      )
    else {
      throw NewThreadSubmissionError.invalidSubmission
    }

    let operationGeneration = generation
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.apply(state: .submitting(submission.id), draft: editingDraft)
    let flightID = UUID()
    let task = Task { @MainActor [weak self] () throws -> NewThreadResult in
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
  func resumeImageSubmission(for target: NewThreadTarget) async throws -> NewThreadResult {
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
        throw NewThreadSubmissionError.submissionInProgress
      }
      return try await flight.task.value
    }

    let seal = try sealDraftOperation(for: draft.key)
    let permit = await acquireDraftOperationPermit(for: draft.key)
    let task: Task<NewThreadResult, Error>
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
      let flightTask = Task { @MainActor [weak self] () throws -> NewThreadResult in
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

  @discardableResult
  func verifyVisibility(for target: NewThreadTarget) async throws -> NewThreadResult? {
    let entry = entry(for: target)
    guard
      case .acceptedAwaitingVisibility(let receipt) = entry.state,
      let draft = entry.draft,
      let lease = entry.lease,
      draft.key.userID == lease.userID
    else {
      throw stateError(entry.state)
    }

    let submission: NewThreadSubmission
    let imageUploads: [ComposerImageUploadResult]
    switch draft.disposition {
    case .acceptedAwaitingVisibility(let submissionID, let draftReceipt):
      guard
        draftReceipt == receipt,
        let value = NewThreadSubmission(
          id: submissionID,
          target: target,
          title: draft.title,
          content: draft.content
        )
      else { throw NewThreadSubmissionError.invalidSubmission }
      submission = value
      imageUploads = []
    case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt):
      guard
        draftReceipt == receipt,
        let imagePipeline,
        let value = imageSubmission(from: draft, target: target, reference: reference)
      else { throw NewThreadSubmissionError.invalidSubmission }
      submission = value
      do {
        imageUploads = try await imagePipeline.recoverNewThreadUploadsForVisibility(
          submission: value,
          reference: reference
        )
      } catch {
        throw pipelineSubmissionError(error)
      }
      guard imageUploadsMatchDraft(imageUploads, draft: draft, lease: lease) else {
        throw NewThreadSubmissionError.outcomeUnknown
      }
    default:
      throw stateError(entry.state)
    }

    let operationGeneration = generation
    let operationEpoch = entry.epoch
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
      throw error
    } catch {
      throw NewThreadSubmissionError.unavailable
    }

    let confirmation = try await access.service.verifyNewThreadVisibility(
      session: session,
      submission: submission,
      receipt: receipt,
      imageUploads: imageUploads
    )
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: draft,
      generation: operationGeneration,
      epoch: operationEpoch
    )
    guard let confirmation else { return nil }
    return try await confirmVisibility(confirmation, matching: receipt, for: target)
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
      let lease = entry.lease,
      draft.key.userID == lease.userID
    else {
      throw stateError(entry.state)
    }
    guard
      confirmation.authorUserID == lease.userID,
      draft.title == nil || confirmation.title == draft.title,
      confirmation.content.utf8.elementsEqual(draft.content.utf8),
      confirmation.attachments == draft.attachments,
      confirmation.imageWatermark == draft.imageWatermark
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

    let submissionID: UUID
    let imageTerminal: (NewThreadSubmission, ComposerImageSubmissionReference)?
    let terminalDraft: NewThreadDraft
    switch draft.disposition {
    case .acceptedAwaitingVisibility(let id, let draftReceipt):
      guard
        draftReceipt == receipt,
        draft.attachments.isEmpty,
        let confirmed = confirmedDraft(from: draft, submissionID: id, receipt: receipt)
      else { throw NewThreadSubmissionError.invalidSubmission }
      submissionID = id
      imageTerminal = nil
      terminalDraft = confirmed
    case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt):
      guard
        draftReceipt == receipt,
        let imagePipeline,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let confirmed = imageDraft(
          from: draft,
          disposition: .imageConfirmed(reference: reference, receipt: receipt)
        )
      else { throw NewThreadSubmissionError.invalidSubmission }
      let uploads: [ComposerImageUploadResult]
      do {
        uploads = try await imagePipeline.recoverNewThreadUploadsForVisibility(
          submission: submission,
          reference: reference
        )
      } catch {
        throw pipelineSubmissionError(error)
      }
      guard imageUploadsMatchDraft(uploads, draft: draft, lease: lease) else {
        throw NewThreadSubmissionError.outcomeUnknown
      }
      submissionID = reference.submissionID
      imageTerminal = (submission, reference)
      terminalDraft = confirmed
    default:
      throw stateError(entry.state)
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
        throw NewThreadSubmissionError.accountChanged
      }
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: draft)
      throw NewThreadSubmissionError.unavailable
    }

    if let (submission, reference) = imageTerminal {
      let didComplete = await markImageSubmissionCompleted(
        submission: submission,
        reference: reference
      )
      if didComplete {
        await cleanupCompletedImageSubmission(
          submission: submission,
          reference: reference,
          userID: lease.userID
        )
      }
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
        draft: terminalDraft,
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
      entry.apply(state: .confirmed(receipt), draft: terminalDraft)
      throw NewThreadSubmissionError.outcomeUnknown
    }
    entry.apply(state: .confirmed(receipt), draft: terminalDraft)
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

  private func performInitialImageSubmission(
    _ submission: NewThreadSubmission,
    editingDraft: NewThreadDraft,
    previousDraft: NewThreadDraft?,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    guard
      !submission.attachments.isEmpty,
      let imagePipeline,
      let reference = ComposerImageSubmissionReference(
        submissionID: submission.id,
        sessionRevision: lease.sessionRevision
      ),
      let intent = ComposerImageSubmissionIntent(newThread: submission)
    else {
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
      throw NewThreadSubmissionError.unavailable
    }
    await removeObsoleteEditingAttachments(
      from: previousDraft,
      retaining: editingDraft.attachments
    )
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
        throw NewThreadSubmissionError.outcomeUnknown
      }
    } catch let error as NewThreadSubmissionError {
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
      throw NewThreadSubmissionError.invalidSubmission
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
      throw NewThreadSubmissionError.unavailable
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
      preparedState = try await imagePipeline.prepareNewThread(
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
      throw NewThreadSubmissionError.outcomeUnknown
    }
    do {
      try await performDraftMutation(.save(pipelineDraft), for: pipelineDraft.key)
    } catch {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw NewThreadSubmissionError.unavailable
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
    _ submission: NewThreadSubmission,
    pipelineDraft: NewThreadDraft,
    reference: ComposerImageSubmissionReference,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    guard
      let imagePipeline,
      reference.submissionID == submission.id,
      reference.sessionRevision == lease.sessionRevision,
      pipelineDraft.attachments == submission.attachments,
      pipelineDraft.imageWatermark == submission.imageWatermark
    else {
      entry.apply(state: .imageRecoveryUnavailable, draft: pipelineDraft)
      throw NewThreadSubmissionError.invalidSubmission
    }
    try await ensureOperationIsCurrent(
      entry,
      lease: lease,
      draft: pipelineDraft,
      generation: operationGeneration,
      epoch: operationEpoch
    )

    let result: NewThreadResult
    do {
      result = try await imagePipeline.executeNewThread(
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
    editingDraft: NewThreadDraft,
    preparationDraft: NewThreadDraft,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    guard let imagePipeline else {
      entry.apply(state: .imageRecoveryUnavailable, draft: preparationDraft)
      throw NewThreadSubmissionError.unavailable
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

    let retainedDraft: NewThreadDraft
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
        if retainedDraft == editingDraft {
          applyFailure(pipelineSubmissionError(source), draft: retainedDraft, to: entry)
        } else {
          entry.apply(state: .imageRecoveryUnavailable, draft: retainedDraft)
        }
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
    throw pipelineSubmissionError(source)
  }

  private func finishImageExecutionFailure(
    _ source: Error,
    submission: NewThreadSubmission,
    pipelineDraft: NewThreadDraft,
    reference: ComposerImageSubmissionReference,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    let recoveryState: ComposerImageSubmissionRecoveryState?
    if let imagePipeline,
      let intent = ComposerImageSubmissionIntent(newThread: submission)
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
      throw NewThreadSubmissionError.accountChanged
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
    _ result: NewThreadResult,
    submission: NewThreadSubmission,
    pipelineDraft: NewThreadDraft,
    reference: ComposerImageSubmissionReference,
    entry: NewThreadSubmissionEntry,
    lease: NewThreadSessionLease,
    operationGeneration: UInt64,
    operationEpoch: UInt64
  ) async throws -> NewThreadResult {
    guard
      result.submissionID == submission.id,
      result.userID == lease.userID,
      result.target == submission.target,
      let terminalDraft: NewThreadDraft = switch result.outcome {
      case .confirmed(let receipt):
        imageDraft(
          from: pipelineDraft,
          disposition: .imageConfirmed(reference: reference, receipt: receipt)
        )
      case .acceptedAwaitingVisibility(let receipt):
        imageDraft(
          from: pipelineDraft,
          disposition: .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt)
        )
      }
    else {
      entry.apply(state: .imageRecoveryUnavailable, draft: pipelineDraft)
      throw NewThreadSubmissionError.outcomeUnknown
    }
    do {
      try await performDraftMutation(.save(terminalDraft), for: terminalDraft.key)
    } catch {
      entry.apply(state: .outcomeUnknown, draft: pipelineDraft)
      throw NewThreadSubmissionError.outcomeUnknown
    }

    let didComplete = await markImageSubmissionCompleted(
      submission: submission,
      reference: reference
    )
    if case .confirmed = result.outcome, didComplete {
      await cleanupCompletedImageSubmission(
        submission: submission,
        reference: reference,
        userID: lease.userID
      )
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
        draft: terminalDraft,
        generation: operationGeneration,
        epoch: operationEpoch
      )
      throw NewThreadSubmissionError.accountChanged
    }
    switch result.outcome {
    case .confirmed(let receipt):
      entry.apply(state: .confirmed(receipt), draft: terminalDraft)
    case .acceptedAwaitingVisibility(let receipt):
      entry.apply(state: .acceptedAwaitingVisibility(receipt), draft: terminalDraft)
    }
    return result
  }

  private func performSubmission(
    _ submission: NewThreadSubmission,
    editingDraft: NewThreadDraft,
    previousDraft: NewThreadDraft?,
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

    await removeObsoleteEditingAttachments(
      from: previousDraft,
      retaining: editingDraft.attachments
    )

    if let imagePipeline,
      let context = ComposerImageUploadContext(newThread: submission.target)
    {
      do {
        if try await imagePipeline.blockingRecoveryState(
          for: context,
          userID: lease.userID
        ) != nil {
          entry.apply(state: .imageRecoveryUnavailable, draft: editingDraft)
          throw NewThreadSubmissionError.outcomeUnknown
        }
      } catch let error as NewThreadSubmissionError {
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

  private func resolveLoadedDraft(
    _ draft: NewThreadDraft?,
    target: NewThreadTarget,
    lease: NewThreadSessionLease,
    hasFullCredentials: Bool
  ) async throws -> LoadedDraftResolution {
    guard
      let imagePipeline,
      let context = ComposerImageUploadContext(newThread: target)
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
        let intent = ComposerImageSubmissionIntent(newThread: submission),
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
        let intent = ComposerImageSubmissionIntent(newThread: submission),
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
        let intent = ComposerImageSubmissionIntent(newThread: submission),
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

    case .imageConfirmed(let reference, let receipt):
      guard let blockingState else {
        return LoadedDraftResolution(state: .confirmed(receipt), draft: draft)
      }
      guard
        blockingState.reference == reference,
        let submission = imageSubmission(from: draft, target: target, reference: reference),
        let intent = ComposerImageSubmissionIntent(newThread: submission),
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
      if didComplete {
        await cleanupCompletedImageSubmission(
          submission: submission,
          reference: reference,
          userID: lease.userID
        )
      }
      return LoadedDraftResolution(state: .confirmed(receipt), draft: draft)

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
        let intent = ComposerImageSubmissionIntent(newThread: submission),
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

    case .submissionPending, .challengeRequired, .acceptedAwaitingVisibility, .confirmed,
      .outcomeUnknown:
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
    _ draft: NewThreadDraft?,
    lease: NewThreadSessionLease,
    hasFullCredentials: Bool
  ) -> LoadedDraftResolution {
    guard hasFullCredentials else {
      return LoadedDraftResolution(state: .failed(.fullCredentialsRequired), draft: draft)
    }
    guard let draft else {
      return LoadedDraftResolution(state: .ready, draft: nil)
    }
    let state: NewThreadSubmissionState = switch draft.disposition {
    case .editing:
      .ready
    case .submissionPending, .outcomeUnknown:
      .outcomeUnknown
    case .challengeRequired(_, let blockedRevision):
      blockedRevision == lease.sessionRevision ? .challengeRequired : .ready
    case .acceptedAwaitingVisibility(_, let receipt):
      .acceptedAwaitingVisibility(receipt)
    case .confirmed(_, let receipt):
      .confirmed(receipt)
    case .imagePreparationPending, .imagePipeline, .imageAcceptedAwaitingVisibility,
      .imageConfirmed:
      .imageRecoveryUnavailable
    }
    return LoadedDraftResolution(state: state, draft: draft)
  }

  private func loadedImageRecoveryResolution(
    _ recoveryState: ComposerImageSubmissionRecoveryState,
    draft: NewThreadDraft,
    lease: NewThreadSessionLease
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

  private func removeObsoleteEditingAttachments(
    from previousDraft: NewThreadDraft?,
    retaining attachments: [ComposerImageAttachment]
  ) async {
    guard
      let previousDraft,
      case .editing = previousDraft.disposition
    else { return }
    let retainedIDs = Set(attachments.map(\.id))
    await removeAttachmentsBestEffort(
      previousDraft.attachments.filter { !retainedIDs.contains($0.id) }
    )
  }

  private func removeDiscardedDraftAttachments(_ draft: NewThreadDraft?) async {
    guard let draft else { return }
    switch draft.disposition {
    case .editing, .confirmed, .imageConfirmed:
      await removeAttachmentsBestEffort(draft.attachments)
    case .submissionPending, .imagePreparationPending, .imagePipeline, .challengeRequired,
      .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility, .outcomeUnknown:
      return
    }
  }

  private func removeAttachmentsBestEffort(
    _ attachments: [ComposerImageAttachment]
  ) async {
    guard let attachmentDeletionScheduler else { return }
    _ = try? await attachmentDeletionScheduler.scheduleDeletion(of: attachments)
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
    from draft: NewThreadDraft,
    target: NewThreadTarget,
    reference: ComposerImageSubmissionReference
  ) -> NewThreadSubmission? {
    guard
      draft.key.forumID == target.forumID,
      draft.key.forumName == target.forumName,
      !draft.attachments.isEmpty
    else { return nil }
    return NewThreadSubmission(
      id: reference.submissionID,
      target: target,
      title: draft.title,
      content: draft.content,
      attachments: draft.attachments,
      imageWatermark: draft.imageWatermark
    )
  }

  private func imageDraft(
    from draft: NewThreadDraft,
    disposition: NewThreadDraftDisposition
  ) -> NewThreadDraft? {
    NewThreadDraft(
      key: draft.key,
      title: draft.title,
      content: draft.content,
      attachments: draft.attachments,
      imageWatermark: draft.imageWatermark,
      disposition: disposition,
      updatedAt: Date()
    )
  }

  private func imageUploadsMatchDraft(
    _ uploads: [ComposerImageUploadResult],
    draft: NewThreadDraft,
    lease: NewThreadSessionLease
  ) -> Bool {
    uploads.count == draft.attachments.count
      && uploads.map(\.attachment) == draft.attachments
      && uploads.allSatisfy {
        $0.sessionRevision == lease.sessionRevision
          && $0.watermark == draft.imageWatermark
      }
  }

  private func markImageSubmissionCompleted(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async -> Bool {
    guard
      let imagePipeline,
      let intent = ComposerImageSubmissionIntent(newThread: submission)
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
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async {
    guard
      let imagePipeline,
      let intent = ComposerImageSubmissionIntent(newThread: submission)
    else { return }
    do {
      try await imagePipeline.removeAttachments(intent: intent, reference: reference)
      try await imagePipeline.deleteCompleted(
        intent: intent,
        reference: reference,
        userID: userID
      )
    } catch {
      // The imageConfirmed tombstone keeps cleanup recoverable on the next activation.
    }
  }

  private func pipelineSubmissionError(_ source: Error) -> NewThreadSubmissionError {
    if source is CancellationError { return .outcomeUnknown }
    if let error = source as? NewThreadSubmissionError { return error }
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
    guard let flight = submissionFlights[target], flight.id == id else { return }
    submissionFlights.removeValue(forKey: target)
    unsealDraftOperation(flight.sealID, for: flight.draftKey)
    removeEntryIfInactive(target)
  }

  private func ensureDraftOperationIsUnsealed(for key: NewThreadDraftKey) throws {
    guard sealedDraftOperations[key] == nil else {
      throw NewThreadSubmissionError.submissionInProgress
    }
  }

  private func sealDraftOperation(for key: NewThreadDraftKey) throws -> UUID {
    try ensureDraftOperationIsUnsealed(for: key)
    let id = UUID()
    sealedDraftOperations[key] = id
    return id
  }

  private func unsealDraftOperation(_ id: UUID, for key: NewThreadDraftKey) {
    guard sealedDraftOperations[key] == id else { return }
    sealedDraftOperations.removeValue(forKey: key)
  }

  private func acquireDraftOperationPermit(
    for key: NewThreadDraftKey,
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

  private func acquireUnsealedDraftOperationPermit(for key: NewThreadDraftKey) async throws
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

  private func acquireDrainedDraftOperationPermit(for key: NewThreadDraftKey) async -> UUID {
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

  private func releaseDraftOperationPermit(_ id: UUID, for key: NewThreadDraftKey) {
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
