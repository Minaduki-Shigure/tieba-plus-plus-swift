import Combine
import Foundation

enum ForumCheckInState: Equatable {
  case idle
  case signedOut
  case loading
  case requiresFollow
  case unavailable
  case ready
  case signedToday(consecutiveDays: Int, rank: Int)
  case checking
  case failed
}

@MainActor
final class ForumCheckInViewModel: ObservableObject {
  @Published private(set) var state: ForumCheckInState = .idle
  @Published private(set) var errorMessage: String?

  let forumID: Int64
  let forumName: String

  private let access: AccountAccess
  private var generation = 0
  private var activeOperation: ForumCheckInOperation?
  private var currentLease: ForumCheckInSessionLease?

  init(forumID: Int64, forumName: String, access: AccountAccess) {
    self.forumID = forumID
    self.forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.access = access
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    default:
      return
    }
  }

  func reload() async {
    generation &+= 1
    let requestGeneration = generation
    currentLease = nil
    errorMessage = nil

    guard validForum else {
      state = .idle
      return
    }

    state = .loading
    do {
      guard let session = try await access.vault.activeSession() else {
        guard requestGeneration == generation else { return }
        state = .signedOut
        return
      }
      let lease = ForumCheckInSessionLease(session)
      currentLease = lease
      let accountState = try await access.service.forumAccountState(
        session: session,
        forumID: forumID,
        forumName: forumName
      )
      try Task.checkCancellation()
      let resolvedState = try resolve(accountState, lease: lease)
      guard requestGeneration == generation else { return }

      switch await sessionLeaseState(lease) {
      case .current:
        state = resolvedState
      case .changed:
        currentLease = nil
        state = .idle
      case .unavailable:
        failForUnreadableAccount()
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      currentLease = nil
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      currentLease = nil
      state = .failed
      errorMessage = error.localizedDescription
    }
  }

  func checkIn() async {
    guard
      state == .ready,
      let expectedLease = currentLease,
      validForum
    else { return }
    guard activeOperation?.lease != expectedLease else { return }

    let operation = ForumCheckInOperation(lease: expectedLease)
    activeOperation = operation
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .checking
    defer {
      if activeOperation?.id == operation.id {
        activeOperation = nil
      }
    }

    let session: StoredAccountSession
    do {
      guard
        let activeSession = try await access.vault.activeSession(),
        ForumCheckInSessionLease(activeSession) == expectedLease
      else {
        guard requestGeneration == generation, activeOperation?.id == operation.id else {
          return
        }
        currentLease = nil
        state = .idle
        return
      }
      session = activeSession
    } catch is CancellationError {
      guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
      state = .ready
      errorMessage = "未能读取当前账户，尚未开始签到。"
      return
    } catch {
      guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
      failForUnreadableAccount()
      return
    }
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }

    do {
      let accountState = try await access.service.checkInToForum(
        session: session,
        forumID: forumID,
        forumName: forumName
      )
      let resolvedState = try resolveConfirmedCheckIn(accountState, lease: expectedLease)
      let change = try checkInChange(from: resolvedState, lease: expectedLease)

      guard requestGeneration == generation, activeOperation?.id == operation.id else {
        await postIfLeaseCurrent(change, lease: expectedLease)
        return
      }
      let leaseState = await sessionLeaseState(expectedLease)
      guard requestGeneration == generation, activeOperation?.id == operation.id else {
        await postIfLeaseCurrent(change, lease: expectedLease)
        return
      }
      switch leaseState {
      case .current:
        state = resolvedState
        AccountChangeNotifications.postForumCheckInChange(change)
      case .changed:
        currentLease = nil
        state = .idle
      case .unavailable:
        failForUnreadableAccount()
      }
    } catch is CancellationError {
      await reconcileAfterCheckInFailure(
        operation: operation,
        lease: expectedLease,
        requestGeneration: requestGeneration,
        message: "贴吧未能确认签到结果，已重新读取当前状态。"
      )
    } catch {
      await reconcileAfterCheckInFailure(
        operation: operation,
        lease: expectedLease,
        requestGeneration: requestGeneration,
        message: error.localizedDescription
      )
    }
  }

  func accountSessionDidChange() async {
    activeOperation = nil
    currentLease = nil
    await reload()
  }

  func forumMembershipDidChange(_ change: ForumMembershipChange) async {
    guard
      change.forumID == forumID,
      change.accountID == currentLease?.userID
    else { return }
    await reload()
  }

  func forumCheckInDidChange(_ change: ForumCheckInChange) async {
    guard
      let expectedLease = currentLease,
      change.forumID == forumID,
      change.accountID == expectedLease.userID,
      change.sessionRevision == expectedLease.sessionRevision,
      change.consecutiveDays >= 0,
      change.rank >= 0
    else { return }
    guard
      case .current = await sessionLeaseState(expectedLease),
      currentLease == expectedLease
    else { return }
    let updatedState = ForumCheckInState.signedToday(
      consecutiveDays: change.consecutiveDays,
      rank: change.rank
    )
    guard state != updatedState else { return }
    generation &+= 1
    errorMessage = nil
    state = updatedState
  }

  func dismissError() {
    errorMessage = nil
  }

  private var validForum: Bool {
    forumID > 0 && !forumName.isEmpty
  }

  private func resolve(
    _ accountState: ForumAccountStateData,
    lease: ForumCheckInSessionLease
  ) throws -> ForumCheckInState {
    let membership = accountState.membership
    guard membership.userID == lease.userID, membership.forumID == forumID else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户状态，请重新加载后再试。")
    }
    guard membership.isFollowed else { return .requiresFollow }
    guard let checkIn = accountState.checkIn else { return .unavailable }
    guard checkIn.consecutiveDays >= 0, checkIn.rank >= 0 else {
      throw BrowseError.unavailable("贴吧返回了无效的签到状态，请稍后重试。")
    }
    if checkIn.isCheckedIn {
      return .signedToday(
        consecutiveDays: checkIn.consecutiveDays,
        rank: checkIn.rank
      )
    }
    return .ready
  }

  private func resolveConfirmedCheckIn(
    _ accountState: ForumAccountStateData,
    lease: ForumCheckInSessionLease
  ) throws -> ForumCheckInState {
    let resolvedState = try resolve(accountState, lease: lease)
    guard case .signedToday = resolvedState else {
      throw BrowseError.unavailable("贴吧没有确认签到结果，请重新加载后再试。")
    }
    return resolvedState
  }

  private func checkInChange(
    from state: ForumCheckInState,
    lease: ForumCheckInSessionLease
  ) throws -> ForumCheckInChange {
    guard case .signedToday(let consecutiveDays, let rank) = state else {
      throw BrowseError.unavailable("贴吧没有确认签到结果，请重新加载后再试。")
    }
    return ForumCheckInChange(
      accountID: lease.userID,
      sessionRevision: lease.sessionRevision,
      forumID: forumID,
      consecutiveDays: consecutiveDays,
      rank: rank
    )
  }

  private func sessionLeaseState(
    _ lease: ForumCheckInSessionLease
  ) async -> ForumCheckInSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease == ForumCheckInSessionLease(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func failForUnreadableAccount() {
    currentLease = nil
    state = .failed
    errorMessage = "无法读取当前账户，请稍后重试。"
  }

  private func postIfLeaseCurrent(
    _ change: ForumCheckInChange,
    lease: ForumCheckInSessionLease
  ) async {
    guard case .current = await sessionLeaseState(lease) else { return }
    AccountChangeNotifications.postForumCheckInChange(change)
  }

  private func reconcileAfterCheckInFailure(
    operation: ForumCheckInOperation,
    lease: ForumCheckInSessionLease,
    requestGeneration: Int,
    message: String
  ) async {
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
    let initialLeaseState = await sessionLeaseState(lease)
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
    switch initialLeaseState {
    case .current:
      break
    case .changed:
      currentLease = nil
      await reload()
      return
    case .unavailable:
      failForUnreadableAccount()
      return
    }
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }

    let session: StoredAccountSession
    do {
      guard
        let activeSession = try await access.vault.activeSession(),
        ForumCheckInSessionLease(activeSession) == lease
      else {
        currentLease = nil
        await reload()
        return
      }
      session = activeSession
    } catch {
      guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
      failForUnreadableAccount()
      return
    }
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }

    let service = access.service
    let forumID = self.forumID
    let forumName = self.forumName
    let reconciliation = Task.detached {
      try await service.forumAccountState(
        session: session,
        forumID: forumID,
        forumName: forumName
      )
    }

    let result = await reconciliation.result
    guard requestGeneration == generation, activeOperation?.id == operation.id else { return }

    switch result {
    case .success(let accountState):
      do {
        let resolvedState = try resolve(accountState, lease: lease)
        let leaseState = await sessionLeaseState(lease)
        guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
        switch leaseState {
        case .current:
          state = resolvedState
          if case .signedToday = resolvedState {
            errorMessage = nil
            AccountChangeNotifications.postForumCheckInChange(
              try checkInChange(from: resolvedState, lease: lease)
            )
          } else {
            errorMessage = message
          }
        case .changed:
          currentLease = nil
          state = .idle
          errorMessage = nil
        case .unavailable:
          failForUnreadableAccount()
        }
      } catch {
        let leaseState = await sessionLeaseState(lease)
        guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
        switch leaseState {
        case .current:
          state = .failed
          errorMessage = message
        case .changed:
          currentLease = nil
          state = .idle
          errorMessage = nil
        case .unavailable:
          failForUnreadableAccount()
        }
      }
    case .failure:
      let leaseState = await sessionLeaseState(lease)
      guard requestGeneration == generation, activeOperation?.id == operation.id else { return }
      switch leaseState {
      case .current:
        state = .failed
        errorMessage = message
      case .changed:
        currentLease = nil
        state = .idle
        errorMessage = nil
      case .unavailable:
        failForUnreadableAccount()
      }
    }
  }
}

private enum ForumCheckInSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct ForumCheckInSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

private struct ForumCheckInOperation: Equatable, Sendable {
  let id: UUID
  let lease: ForumCheckInSessionLease

  init(id: UUID = UUID(), lease: ForumCheckInSessionLease) {
    self.id = id
    self.lease = lease
  }
}
