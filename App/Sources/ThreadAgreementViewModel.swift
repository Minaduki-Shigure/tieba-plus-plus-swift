import Combine
import Foundation

struct ThreadAgreementSnapshot: Equatable, Sendable {
  let isAgreed: Bool
  let agreeScore: Int
}

enum ThreadAgreementState: Equatable {
  case idle
  case signedOut
  case loading
  case ready(ThreadAgreementSnapshot)
  case mutating(previous: ThreadAgreementSnapshot, targetAgreed: Bool)
  case failed(previous: ThreadAgreementSnapshot?)
}

@MainActor
final class ThreadAgreementViewModel: ObservableObject {
  @Published private(set) var state: ThreadAgreementState = .idle
  @Published private(set) var errorMessage: String?

  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let firstPostID: Int64
  @Published private(set) var fallbackAgreeScore: Int

  private let access: AccountAccess
  private var generation = 0
  private var activeOperation: ThreadAgreementOperation?
  private var currentLease: ThreadAgreementSessionLease?
  private var lastKnownSnapshot: ThreadAgreementSnapshot?

  init(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    fallbackAgreeScore: Int,
    access: AccountAccess
  ) {
    self.forumID = forumID
    self.forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.threadID = threadID
    self.firstPostID = firstPostID
    self.fallbackAgreeScore = max(fallbackAgreeScore, 0)
    self.access = access
  }

  var displayedSnapshot: ThreadAgreementSnapshot? {
    switch state {
    case .ready(let snapshot), .mutating(let snapshot, _):
      snapshot
    case .failed(let snapshot):
      snapshot
    case .idle, .signedOut, .loading:
      lastKnownSnapshot
    }
  }

  var displayedAgreeScore: Int {
    displayedSnapshot?.agreeScore ?? fallbackAgreeScore
  }

  func updateFallbackAgreeScore(_ agreeScore: Int) {
    fallbackAgreeScore = max(agreeScore, 0)
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    case .signedOut, .loading, .ready, .mutating:
      return
    }
  }

  func reload() async {
    generation &+= 1
    let requestGeneration = generation
    currentLease = nil
    errorMessage = nil

    guard validTarget else {
      lastKnownSnapshot = nil
      state = .idle
      return
    }

    state = .loading
    do {
      let activeSession = try await access.vault.activeSession()
      guard requestGeneration == generation else { return }
      guard let session = activeSession else {
        lastKnownSnapshot = nil
        state = .signedOut
        return
      }
      let lease = ThreadAgreementSessionLease(session)
      currentLease = lease
      let agreement = try await access.service.threadAgreement(
        session: session,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID
      )
      try Task.checkCancellation()
      let snapshot = try resolve(agreement, lease: lease)
      guard requestGeneration == generation else { return }

      let leaseState = await sessionLeaseState(lease)
      guard requestGeneration == generation else { return }
      switch leaseState {
      case .current:
        lastKnownSnapshot = snapshot
        state = .ready(snapshot)
      case .changed:
        currentLease = nil
        lastKnownSnapshot = nil
        state = .idle
      case .unavailable:
        failForUnreadableAccount(previous: lastKnownSnapshot)
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      currentLease = nil
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .failed(previous: lastKnownSnapshot)
      errorMessage = error.localizedDescription
    }
  }

  func setAgreed(_ isAgreed: Bool) async {
    guard
      activeOperation == nil,
      case .ready(let previous) = state,
      previous.isAgreed != isAgreed,
      let expectedLease = currentLease,
      validTarget
    else { return }

    let operation = ThreadAgreementOperation(
      lease: expectedLease,
      targetAgreed: isAgreed
    )
    activeOperation = operation
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .mutating(previous: previous, targetAgreed: isAgreed)
    defer {
      if activeOperation?.id == operation.id {
        activeOperation = nil
      }
    }

    let session: StoredAccountSession
    do {
      let activeSession = try await access.vault.activeSession()
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      guard
        let activeSession,
        ThreadAgreementSessionLease(activeSession) == expectedLease
      else {
        currentLease = nil
        lastKnownSnapshot = nil
        state = .idle
        return
      }
      session = activeSession
    } catch is CancellationError {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      state = .ready(previous)
      errorMessage = "未能读取当前账户，尚未开始主题点赞操作。"
      return
    } catch {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      failForUnreadableAccount(previous: previous)
      return
    }
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    do {
      let agreement = try await access.service.setThreadAgreed(
        session: session,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: isAgreed
      )
      let snapshot = try resolve(agreement, lease: expectedLease)
      guard snapshot.isAgreed == isAgreed else {
        throw BrowseError.unavailable("贴吧没有确认新的主题点赞状态，请重新加载后再试。")
      }
      let change = makeChange(snapshot, lease: expectedLease)

      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      let leaseState = await sessionLeaseState(expectedLease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      switch leaseState {
      case .current:
        lastKnownSnapshot = snapshot
        state = .ready(snapshot)
        AccountChangeNotifications.postThreadAgreementChange(change)
      case .changed:
        currentLease = nil
        lastKnownSnapshot = nil
        state = .idle
      case .unavailable:
        failForUnreadableAccount(previous: previous)
      }
    } catch is CancellationError {
      await reconcileAfterMutationFailure(
        operation: operation,
        previous: previous,
        requestGeneration: requestGeneration,
        message: "贴吧未能确认主题点赞结果，已重新读取当前状态。"
      )
    } catch {
      await reconcileAfterMutationFailure(
        operation: operation,
        previous: previous,
        requestGeneration: requestGeneration,
        message: error.localizedDescription
      )
    }
  }

  func accountSessionDidChange() async {
    let token = invalidateForAccountSessionChange()
    await reloadAfterAccountSessionChange(ifCurrent: token)
  }

  @discardableResult
  func invalidateForAccountSessionChange() -> Int {
    generation &+= 1
    activeOperation = nil
    currentLease = nil
    lastKnownSnapshot = nil
    errorMessage = nil
    state = .idle
    return generation
  }

  func reloadAfterAccountSessionChange(ifCurrent token: Int) async {
    guard token == generation else { return }
    await reload()
  }

  func presentationDidDisappear() {
    generation &+= 1
    activeOperation = nil
    currentLease = nil
    lastKnownSnapshot = nil
    errorMessage = nil
    state = .idle
  }

  @discardableResult
  func threadAgreementDidChange(_ change: ThreadAgreementChange) async -> Bool {
    guard
      let expectedLease = currentLease,
      change.accountID == expectedLease.userID,
      change.sessionRevision == expectedLease.sessionRevision,
      change.forumID == forumID,
      change.threadID == threadID,
      change.firstPostID == firstPostID
    else { return false }
    let requestGeneration = generation
    let leaseState = await sessionLeaseState(expectedLease)
    guard
      requestGeneration == generation,
      case .current = leaseState,
      currentLease == expectedLease
    else { return false }

    let snapshot = ThreadAgreementSnapshot(
      isAgreed: change.isAgreed,
      agreeScore: change.agreeScore
    )
    if case .ready(let current) = state, current == snapshot { return true }
    generation &+= 1
    lastKnownSnapshot = snapshot
    errorMessage = nil
    state = .ready(snapshot)
    return true
  }

  func dismissError() {
    errorMessage = nil
  }

  private var validTarget: Bool {
    forumID > 0 && !forumName.isEmpty && threadID > 0 && firstPostID > 0
  }

  private func resolve(
    _ agreement: ThreadAgreementData,
    lease: ThreadAgreementSessionLease
  ) throws -> ThreadAgreementSnapshot {
    guard
      agreement.userID == lease.userID,
      agreement.forumID == forumID,
      agreement.threadID == threadID,
      agreement.firstPostID == firstPostID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的主题点赞状态，请重新加载后再试。")
    }
    return ThreadAgreementSnapshot(
      isAgreed: agreement.isAgreed,
      agreeScore: max(agreement.agreeScore, 0)
    )
  }

  private func makeChange(
    _ snapshot: ThreadAgreementSnapshot,
    lease: ThreadAgreementSessionLease
  ) -> ThreadAgreementChange {
    ThreadAgreementChange(
      accountID: lease.userID,
      sessionRevision: lease.sessionRevision,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: snapshot.isAgreed,
      agreeScore: snapshot.agreeScore
    )
  }

  private func operationIsCurrent(
    _ operation: ThreadAgreementOperation,
    generation requestGeneration: Int
  ) -> Bool {
    requestGeneration == generation && activeOperation?.id == operation.id
  }

  private func sessionLeaseState(
    _ lease: ThreadAgreementSessionLease
  ) async -> ThreadAgreementSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease == ThreadAgreementSessionLease(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func failForUnreadableAccount(previous: ThreadAgreementSnapshot?) {
    currentLease = nil
    lastKnownSnapshot = previous
    state = .failed(previous: previous)
    errorMessage = "无法读取当前账户，请稍后重试。"
  }

  private func reconcileAfterMutationFailure(
    operation: ThreadAgreementOperation,
    previous: ThreadAgreementSnapshot,
    requestGeneration: Int,
    message: String
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    let initialLeaseState = await sessionLeaseState(operation.lease)
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch initialLeaseState {
    case .current:
      break
    case .changed:
      currentLease = nil
      lastKnownSnapshot = nil
      state = .idle
      errorMessage = nil
      return
    case .unavailable:
      failForUnreadableAccount(previous: previous)
      return
    }

    let session: StoredAccountSession
    do {
      let activeSession = try await access.vault.activeSession()
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      guard
        let activeSession,
        ThreadAgreementSessionLease(activeSession) == operation.lease
      else {
        currentLease = nil
        lastKnownSnapshot = nil
        state = .idle
        errorMessage = nil
        return
      }
      session = activeSession
    } catch {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      failForUnreadableAccount(previous: previous)
      return
    }
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    let service = access.service
    let forumID = self.forumID
    let forumName = self.forumName
    let threadID = self.threadID
    let firstPostID = self.firstPostID
    let reconciliation = Task.detached {
      try await service.threadAgreement(
        session: session,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID
      )
    }
    let result = await reconciliation.result
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    switch result {
    case .success(let agreement):
      do {
        let snapshot = try resolve(agreement, lease: operation.lease)
        let leaseState = await sessionLeaseState(operation.lease)
        guard operationIsCurrent(operation, generation: requestGeneration) else { return }
        switch leaseState {
        case .current:
          lastKnownSnapshot = snapshot
          state = .ready(snapshot)
          if snapshot.isAgreed == operation.targetAgreed {
            errorMessage = nil
            AccountChangeNotifications.postThreadAgreementChange(
              makeChange(snapshot, lease: operation.lease)
            )
          } else {
            errorMessage = message
          }
        case .changed:
          currentLease = nil
          lastKnownSnapshot = nil
          state = .idle
          errorMessage = nil
        case .unavailable:
          failForUnreadableAccount(previous: previous)
        }
      } catch {
        await finishFailedReconciliation(
          operation: operation,
          previous: previous,
          requestGeneration: requestGeneration,
          message: message
        )
      }
    case .failure:
      await finishFailedReconciliation(
        operation: operation,
        previous: previous,
        requestGeneration: requestGeneration,
        message: message
      )
    }
  }

  private func finishFailedReconciliation(
    operation: ThreadAgreementOperation,
    previous: ThreadAgreementSnapshot,
    requestGeneration: Int,
    message: String
  ) async {
    let leaseState = await sessionLeaseState(operation.lease)
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch leaseState {
    case .current:
      lastKnownSnapshot = previous
      state = .ready(previous)
      errorMessage = message
    case .changed:
      currentLease = nil
      lastKnownSnapshot = nil
      state = .idle
      errorMessage = nil
    case .unavailable:
      failForUnreadableAccount(previous: previous)
    }
  }
}

private enum ThreadAgreementSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct ThreadAgreementSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

private struct ThreadAgreementOperation: Equatable, Sendable {
  let id: UUID
  let lease: ThreadAgreementSessionLease
  let targetAgreed: Bool

  init(
    id: UUID = UUID(),
    lease: ThreadAgreementSessionLease,
    targetAgreed: Bool
  ) {
    self.id = id
    self.lease = lease
    self.targetAgreed = targetAgreed
  }
}
