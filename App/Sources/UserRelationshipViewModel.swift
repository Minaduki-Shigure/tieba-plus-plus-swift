import Combine
import Foundation

enum UserRelationshipState: Equatable {
  case idle
  case hidden
  case signedOut
  case loading
  case ready(isFollowed: Bool)
  case mutating(previouslyFollowed: Bool, targetFollowed: Bool)
  case failed(previouslyFollowed: Bool?)
}

@MainActor
final class UserRelationshipViewModel: ObservableObject {
  @Published private(set) var state: UserRelationshipState = .idle
  @Published private(set) var errorMessage: String?

  let targetUserID: Int64

  private let access: AccountAccess
  private var generation = 0
  private var activeOperation: UserRelationshipOperation?
  private var currentLease: UserRelationshipSessionLease?
  private var lastKnownFollowed: Bool?

  init(targetUserID: Int64, access: AccountAccess) {
    self.targetUserID = targetUserID
    self.access = access
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    case .hidden, .signedOut, .loading, .ready, .mutating:
      return
    }
  }

  func reload() async {
    generation &+= 1
    let requestGeneration = generation
    let previousLease = currentLease
    currentLease = nil
    errorMessage = nil

    guard targetUserID > 0 else {
      clearSnapshot()
      state = .hidden
      return
    }

    state = .loading
    do {
      let activeSession = try await access.vault.activeSession()
      guard requestGeneration == generation else { return }
      guard let session = activeSession else {
        clearSnapshot()
        state = .signedOut
        return
      }
      guard session.id != targetUserID else {
        clearSnapshot()
        state = .hidden
        return
      }

      let lease = UserRelationshipSessionLease(session)
      if previousLease != lease {
        lastKnownFollowed = nil
      }
      currentLease = lease
      guard session.credentials != nil else {
        state = .failed(previouslyFollowed: lastKnownFollowed)
        errorMessage = "此账户需要重新登录，才能读取用户关注状态。"
        return
      }

      let outcome: UserRelationshipReadOutcome
      do {
        let relationship = try await access.service.userRelationship(
          session: session,
          targetUserID: targetUserID
        )
        try Task.checkCancellation()
        outcome = .success(relationship)
      } catch is CancellationError {
        guard requestGeneration == generation else { return }
        guard !Task.isCancelled else {
          clearSnapshot()
          state = .idle
          return
        }
        outcome = .failure("贴吧未能确认用户关注状态，请重新加载后再试。")
      } catch {
        outcome = .failure(error.localizedDescription)
      }

      let sessionAfterRequest = try await access.vault.activeSession()
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
        clearSnapshot()
        state = .idle
        return
      }

      switch outcome {
      case .success(let relationship):
        do {
          let isFollowed = try resolve(relationship, lease: lease)
          lastKnownFollowed = isFollowed
          state = .ready(isFollowed: isFollowed)
        } catch {
          state = .failed(previouslyFollowed: lastKnownFollowed)
          errorMessage = error.localizedDescription
        }
      case .failure(let message):
        state = .failed(previouslyFollowed: lastKnownFollowed)
        errorMessage = message
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      clearSnapshot()
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      clearSnapshot()
      state = .failed(previouslyFollowed: nil)
      errorMessage = "无法读取当前账户，请稍后重试。"
    }
  }

  func setFollowed(_ isFollowed: Bool) async {
    guard
      activeOperation == nil,
      case .ready(let previouslyFollowed) = state,
      previouslyFollowed != isFollowed,
      let expectedLease = currentLease,
      targetUserID > 0,
      targetUserID != expectedLease.userID
    else { return }

    let operation = UserRelationshipOperation(lease: expectedLease)
    activeOperation = operation
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .mutating(
      previouslyFollowed: previouslyFollowed,
      targetFollowed: isFollowed
    )
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
      state = .ready(isFollowed: previouslyFollowed)
      errorMessage = "未能读取当前账户，尚未开始用户关注操作。"
      return
    } catch {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      currentLease = nil
      lastKnownFollowed = previouslyFollowed
      state = .failed(previouslyFollowed: previouslyFollowed)
      errorMessage = "无法读取当前账户，请稍后重试。"
      return
    }
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    do {
      let relationship = try await access.service.setUserFollowed(
        session: session,
        targetUserID: targetUserID,
        isFollowed: isFollowed
      )
      let confirmedFollowed = try resolve(relationship, lease: expectedLease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }

      let leaseState = await sessionLeaseState(expectedLease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      switch leaseState {
      case .current:
        lastKnownFollowed = confirmedFollowed
        state = .ready(isFollowed: confirmedFollowed)
        if confirmedFollowed != isFollowed {
          errorMessage = "贴吧没有确认新的用户关注状态，请重新加载后再试。"
        }
      case .changed:
        clearSnapshot()
        state = .idle
      case .unavailable:
        currentLease = nil
        lastKnownFollowed = previouslyFollowed
        state = .failed(previouslyFollowed: previouslyFollowed)
        errorMessage = "无法读取当前账户，请稍后重试。"
      }
    } catch is CancellationError {
      await publishMutationFailure(
        operation: operation,
        generation: requestGeneration,
        lease: expectedLease,
        previouslyFollowed: previouslyFollowed,
        message: "贴吧未能确认用户关注操作结果，请重新加载后再试。"
      )
    } catch {
      let message = error.localizedDescription
      await publishMutationFailure(
        operation: operation,
        generation: requestGeneration,
        lease: expectedLease,
        previouslyFollowed: previouslyFollowed,
        message: message
      )
    }
  }

  func accountSessionDidChange() async {
    generation &+= 1
    let token = generation
    clearSnapshot()
    errorMessage = nil
    state = .idle
    guard token == generation else { return }
    await reload()
  }

  func dismissError() {
    errorMessage = nil
  }

  func cancel() {
    generation &+= 1
    clearSnapshot()
    errorMessage = nil
    state = .idle
  }

  private func resolve(
    _ relationship: UserRelationshipData,
    lease: UserRelationshipSessionLease
  ) throws -> Bool {
    guard
      relationship.userID == lease.userID,
      relationship.targetUserID == targetUserID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的用户关注状态，请重新加载后再试。")
    }
    return relationship.isFollowed
  }

  private func operationIsCurrent(
    _ operation: UserRelationshipOperation,
    generation requestGeneration: Int
  ) -> Bool {
    requestGeneration == generation && activeOperation?.id == operation.id
  }

  private func sessionLeaseState(
    _ lease: UserRelationshipSessionLease
  ) async -> UserRelationshipSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease.matches(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func publishMutationFailure(
    operation: UserRelationshipOperation,
    generation requestGeneration: Int,
    lease: UserRelationshipSessionLease,
    previouslyFollowed: Bool,
    message: String
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    let leaseState = await sessionLeaseState(lease)
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    switch leaseState {
    case .current:
      lastKnownFollowed = previouslyFollowed
      state = .failed(previouslyFollowed: previouslyFollowed)
      errorMessage = message
    case .changed:
      clearSnapshot()
      state = .idle
    case .unavailable:
      currentLease = nil
      lastKnownFollowed = previouslyFollowed
      state = .failed(previouslyFollowed: previouslyFollowed)
      errorMessage = "无法读取当前账户，请稍后重试。"
    }
  }

  private func clearSnapshot() {
    currentLease = nil
    lastKnownFollowed = nil
  }
}

private enum UserRelationshipReadOutcome: Sendable {
  case success(UserRelationshipData)
  case failure(String)
}

private enum UserRelationshipSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct UserRelationshipSessionLease: Equatable, Sendable {
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

private struct UserRelationshipOperation: Sendable {
  let id = UUID()
  let lease: UserRelationshipSessionLease
}
