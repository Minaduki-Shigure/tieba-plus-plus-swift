import Combine
import Foundation

enum UserInteractionRestrictionsState: Equatable {
  case idle
  case hidden
  case signedOut
  case loading(previous: UserInteractionPermissions?)
  case ready(UserInteractionPermissions)
  case mutating(
    previous: UserInteractionPermissions,
    requested: UserInteractionPermissions
  )
  case failed(previous: UserInteractionPermissions?)
  case outcomeUnknown(previous: UserInteractionPermissions)
}

@MainActor
final class UserInteractionRestrictionsViewModel: ObservableObject {
  @Published private(set) var state: UserInteractionRestrictionsState = .idle
  @Published private(set) var draft: UserInteractionPermissions = .unrestricted
  @Published private(set) var pendingConfirmation: UserInteractionPermissions?
  @Published private(set) var errorMessage: String?

  let targetUserID: Int64

  private let access: AccountAccess
  private var generation = 0
  private var currentLease: UserInteractionRestrictionsSessionLease?
  private var authoritative: UserInteractionPermissions?
  private var activeOperation: UserInteractionRestrictionsOperation?
  private var saveTask: Task<Void, Never>?
  private var allowsMutationAfterFailure = false
  private var outcomeUnknownLocked = false

  init(targetUserID: Int64, access: AccountAccess) {
    self.targetUserID = targetUserID
    self.access = access
  }

  var isMutating: Bool {
    if case .mutating = state { return true }
    return false
  }

  var isEditingEnabled: Bool {
    guard pendingConfirmation == nil, currentLease != nil, !outcomeUnknownLocked else {
      return false
    }
    switch state {
    case .ready:
      return true
    case .failed:
      return allowsMutationAfterFailure && authoritative != nil
    case .idle, .hidden, .signedOut, .loading, .mutating, .outcomeUnknown:
      return false
    }
  }

  var hasUnsavedChanges: Bool {
    guard let authoritative else { return false }
    return draft != authoritative
  }

  var canRequestSave: Bool {
    isEditingEnabled && hasUnsavedChanges && saveTask == nil
  }

  var preventsInteractiveDismiss: Bool { isMutating }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    case .hidden, .signedOut, .loading, .ready, .mutating, .outcomeUnknown:
      return
    }
  }

  func reload() async {
    guard activeOperation == nil else { return }
    generation &+= 1
    let requestGeneration = generation
    let previousLease = currentLease
    let previous = authoritative
    currentLease = nil
    draft = previous ?? .unrestricted
    pendingConfirmation = nil
    errorMessage = nil
    allowsMutationAfterFailure = false

    guard targetUserID > 0 else {
      clearSnapshot()
      state = .hidden
      return
    }

    state = .loading(previous: previous)
    do {
      let activeSession = try await access.vault.activeSession()
      guard requestGeneration == generation else { return }
      guard let session = activeSession else {
        clearSnapshot()
        state = .signedOut
        return
      }
      guard session.id > 0, session.id != targetUserID else {
        clearSnapshot()
        state = .hidden
        return
      }

      let lease = UserInteractionRestrictionsSessionLease(session)
      if previousLease != lease {
        authoritative = nil
        draft = .unrestricted
      }
      currentLease = lease
      guard session.credentials != nil else {
        authoritative = nil
        draft = .unrestricted
        state = .failed(previous: nil)
        errorMessage = UserInteractionPermissionError.fullCredentialsRequired.localizedDescription
        return
      }

      let data = try await access.service.userInteractionPermissions(
        session: session,
        targetUserID: targetUserID
      )
      try Task.checkCancellation()
      let permissions = try resolve(data, lease: lease)
      guard requestGeneration == generation else { return }

      switch await sessionLeaseState(lease) {
      case .current:
        guard requestGeneration == generation else { return }
        authoritative = permissions
        draft = permissions
        outcomeUnknownLocked = false
        state = .ready(permissions)
      case .changed:
        clearSnapshot()
        state = .idle
      case .unavailable:
        currentLease = nil
        publishReadFailure(
          previous: authoritative,
          message: "无法读取当前账户，请稍后重试。"
        )
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      clearSnapshot()
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      publishReadFailure(previous: authoritative, message: error.localizedDescription)
    }
  }

  func setBlocksFollow(_ value: Bool) {
    guard isEditingEnabled else { return }
    draft.blocksFollow = value
  }

  func setBlocksInteraction(_ value: Bool) {
    guard isEditingEnabled else { return }
    draft.blocksInteraction = value
  }

  func setBlocksChat(_ value: Bool) {
    guard isEditingEnabled else { return }
    draft.blocksChat = value
  }

  func requestSaveConfirmation() {
    guard canRequestSave else { return }
    pendingConfirmation = draft
  }

  func cancelSaveConfirmation() {
    pendingConfirmation = nil
  }

  func confirmSave() async {
    guard let task = startSaveIfPossible() else { return }
    await task.value
  }

  func beginConfirmedSave() {
    _ = startSaveIfPossible()
  }

  @discardableResult
  func invalidateForAccountSessionChange() -> Int {
    cancelSaveTask()
    generation &+= 1
    clearSnapshot()
    state = .idle
    return generation
  }

  func presentationDidDisappear() {
    cancelSaveTask()
    generation &+= 1
    clearSnapshot()
    state = .idle
  }

  func dismissError() {
    errorMessage = nil
  }

  private func startSaveIfPossible() -> Task<Void, Never>? {
    guard
      saveTask == nil,
      activeOperation == nil,
      let requested = pendingConfirmation,
      requested == draft,
      canSaveConfirmedDraft(requested),
      let previous = authoritative,
      let lease = currentLease
    else {
      pendingConfirmation = nil
      return nil
    }

    pendingConfirmation = nil
    let operation = UserInteractionRestrictionsOperation(lease: lease, requested: requested)
    activeOperation = operation
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .mutating(previous: previous, requested: requested)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSave(
        operation: operation,
        previous: previous,
        requestGeneration: requestGeneration
      )
    }
    saveTask = task
    return task
  }

  private func performSave(
    operation: UserInteractionRestrictionsOperation,
    previous: UserInteractionPermissions,
    requestGeneration: Int
  ) async {
    defer {
      if activeOperation?.id == operation.id {
        activeOperation = nil
        saveTask = nil
      }
    }

    let session: StoredAccountSession
    do {
      let activeSession = try await access.vault.activeSession()
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      guard
        let activeSession,
        operation.lease.matches(activeSession),
        activeSession.credentials != nil
      else {
        clearSnapshot()
        state = .idle
        return
      }
      session = activeSession
    } catch is CancellationError {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      state = .ready(previous)
      errorMessage = "未能读取当前账户，尚未开始保存互动权限。"
      return
    } catch {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      currentLease = nil
      authoritative = previous
      draft = operation.requested
      allowsMutationAfterFailure = true
      state = .failed(previous: previous)
      errorMessage = "无法读取当前账户，请稍后重试。"
      return
    }
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    do {
      let data = try await access.service.setUserInteractionPermissions(
        session: session,
        targetUserID: targetUserID,
        permissions: operation.requested
      )
      let confirmed = try resolve(data, lease: operation.lease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }

      switch await sessionLeaseState(operation.lease) {
      case .current:
        guard operationIsCurrent(operation, generation: requestGeneration) else { return }
        authoritative = confirmed
        draft = confirmed
        if confirmed == operation.requested {
          outcomeUnknownLocked = false
          allowsMutationAfterFailure = false
          state = .ready(confirmed)
        } else {
          allowsMutationAfterFailure = true
          state = .failed(previous: confirmed)
          errorMessage = "贴吧没有确认所选互动权限，请重新检查后再试。"
        }
      case .changed:
        clearSnapshot()
        state = .idle
      case .unavailable:
        publishOutcomeUnknown(previous: previous)
      }
    } catch is CancellationError {
      await publishOutcomeUnknownIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous
      )
    } catch let error as UserInteractionPermissionError where error == .outcomeUnknown {
      await publishOutcomeUnknownIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous
      )
    } catch {
      await publishKnownSaveFailureIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous,
        message: error.localizedDescription
      )
    }
  }

  private func canSaveConfirmedDraft(_ requested: UserInteractionPermissions) -> Bool {
    guard
      !outcomeUnknownLocked,
      let authoritative,
      requested != authoritative,
      currentLease != nil
    else { return false }
    switch state {
    case .ready:
      return true
    case .failed:
      return allowsMutationAfterFailure
    case .idle, .hidden, .signedOut, .loading, .mutating, .outcomeUnknown:
      return false
    }
  }

  private func resolve(
    _ data: UserInteractionPermissionData,
    lease: UserInteractionRestrictionsSessionLease
  ) throws -> UserInteractionPermissions {
    guard data.userID == lease.userID, data.targetUserID == targetUserID else {
      throw UserInteractionPermissionError.unavailable(
        "贴吧返回了不匹配的互动权限，请重新加载后再试。"
      )
    }
    return data.permissions
  }

  private func operationIsCurrent(
    _ operation: UserInteractionRestrictionsOperation,
    generation requestGeneration: Int
  ) -> Bool {
    requestGeneration == generation && activeOperation?.id == operation.id
  }

  private func sessionLeaseState(
    _ lease: UserInteractionRestrictionsSessionLease
  ) async -> UserInteractionRestrictionsSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease.matches(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func publishReadFailure(
    previous: UserInteractionPermissions?,
    message: String
  ) {
    if outcomeUnknownLocked, let previous {
      authoritative = previous
      draft = previous
      state = .outcomeUnknown(previous: previous)
    } else {
      state = .failed(previous: previous)
    }
    errorMessage = message
  }

  private func publishOutcomeUnknownIfCurrent(
    operation: UserInteractionRestrictionsOperation,
    generation requestGeneration: Int,
    previous: UserInteractionPermissions
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch await sessionLeaseState(operation.lease) {
    case .current, .unavailable:
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      publishOutcomeUnknown(previous: previous)
    case .changed:
      clearSnapshot()
      state = .idle
    }
  }

  private func publishKnownSaveFailureIfCurrent(
    operation: UserInteractionRestrictionsOperation,
    generation requestGeneration: Int,
    previous: UserInteractionPermissions,
    message: String
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch await sessionLeaseState(operation.lease) {
    case .current:
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      authoritative = previous
      draft = operation.requested
      allowsMutationAfterFailure = true
      state = .failed(previous: previous)
      errorMessage = message
    case .changed:
      clearSnapshot()
      state = .idle
    case .unavailable:
      publishOutcomeUnknown(previous: previous)
    }
  }

  private func publishOutcomeUnknown(previous: UserInteractionPermissions) {
    authoritative = previous
    draft = previous
    allowsMutationAfterFailure = false
    outcomeUnknownLocked = true
    state = .outcomeUnknown(previous: previous)
    errorMessage = UserInteractionPermissionError.outcomeUnknown.localizedDescription
  }

  private func clearSnapshot() {
    currentLease = nil
    authoritative = nil
    draft = .unrestricted
    pendingConfirmation = nil
    errorMessage = nil
    allowsMutationAfterFailure = false
    outcomeUnknownLocked = false
  }

  private func cancelSaveTask() {
    let task = saveTask
    saveTask = nil
    activeOperation = nil
    task?.cancel()
  }
}

private enum UserInteractionRestrictionsSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct UserInteractionRestrictionsSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }
}

private struct UserInteractionRestrictionsOperation: Sendable {
  let id = UUID()
  let lease: UserInteractionRestrictionsSessionLease
  let requested: UserInteractionPermissions
}
