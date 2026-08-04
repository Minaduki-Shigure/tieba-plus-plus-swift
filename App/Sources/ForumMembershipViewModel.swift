import Combine
import Foundation

enum ForumMembershipState: Equatable {
  case idle
  case signedOut
  case loading
  case ready(isFollowed: Bool)
  case mutating(previouslyFollowed: Bool, targetFollowed: Bool)
  case failed(previouslyFollowed: Bool?)
}

@MainActor
final class ForumMembershipViewModel: ObservableObject {
  @Published private(set) var state: ForumMembershipState = .idle
  @Published private(set) var errorMessage: String?

  let forumID: Int64
  let forumName: String

  private let access: AccountAccess
  private var generation = 0
  private var isMutationRunning = false
  private var currentLease: SessionLease?
  private var lastKnownFollowed: Bool?

  init(forumID: Int64, forumName: String, access: AccountAccess) {
    self.forumID = forumID
    self.forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.access = access
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      break
    default:
      return
    }
    await reload()
  }

  func reload() async {
    generation &+= 1
    let requestGeneration = generation
    let previousLease = currentLease
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
        lastKnownFollowed = nil
        state = .signedOut
        return
      }
      let lease = SessionLease(session)
      if let previousLease, previousLease != lease {
        lastKnownFollowed = nil
      }
      currentLease = lease
      let membership = try await access.service.forumMembership(
        session: session,
        forumID: forumID,
        forumName: forumName
      )
      try Task.checkCancellation()
      guard membership.userID == lease.userID, membership.forumID == forumID else {
        throw BrowseError.unavailable("贴吧返回了不匹配的关注状态，请重新加载后再试。")
      }
      guard requestGeneration == generation else { return }
      switch await sessionLeaseState(lease) {
      case .current:
        lastKnownFollowed = membership.isFollowed
        state = .ready(isFollowed: membership.isFollowed)
      case .changed:
        currentLease = nil
        lastKnownFollowed = nil
        state = .idle
      case .unavailable:
        failForUnreadableAccount(previouslyFollowed: lastKnownFollowed)
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .failed(previouslyFollowed: lastKnownFollowed)
      errorMessage = error.localizedDescription
    }
  }

  func setFollowed(_ isFollowed: Bool) async {
    guard
      !isMutationRunning,
      case .ready(let previouslyFollowed) = state,
      let expectedLease = currentLease,
      previouslyFollowed != isFollowed,
      validForum
    else { return }

    isMutationRunning = true
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .mutating(
      previouslyFollowed: previouslyFollowed,
      targetFollowed: isFollowed
    )
    defer { isMutationRunning = false }

    do {
      guard
        let session = try await access.vault.activeSession(),
        SessionLease(session) == expectedLease
      else {
        await reload()
        return
      }
      let membership = try await access.service.setForumFollowed(
        session: session,
        forumID: forumID,
        forumName: forumName,
        isFollowed: isFollowed
      )

      guard
        membership.userID == expectedLease.userID,
        membership.forumID == forumID,
        membership.isFollowed == isFollowed
      else {
        throw BrowseError.unavailable("贴吧没有确认新的关注状态，请重新加载后再试。")
      }

      let change = ForumMembershipChange(
        accountID: expectedLease.userID,
        forumID: forumID,
        isFollowed: membership.isFollowed
      )
      if requestGeneration == generation {
        switch await sessionLeaseState(expectedLease) {
        case .current:
          lastKnownFollowed = membership.isFollowed
          state = .ready(isFollowed: membership.isFollowed)
        case .changed:
          currentLease = nil
          lastKnownFollowed = nil
          state = .idle
        case .unavailable:
          failForUnreadableAccount(previouslyFollowed: previouslyFollowed)
        }
      }
      AccountChangeNotifications.postForumMembershipChange(change)
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      await reconcileAfterMutationFailure(
        lease: expectedLease,
        previouslyFollowed: previouslyFollowed,
        message: "贴吧未能确认关注操作结果，已重新读取当前状态。"
      )
    } catch {
      guard requestGeneration == generation else { return }
      await reconcileAfterMutationFailure(
        lease: expectedLease,
        previouslyFollowed: previouslyFollowed,
        message: error.localizedDescription
      )
    }
  }

  func accountSessionDidChange() async {
    lastKnownFollowed = nil
    await reload()
  }

  func forumMembershipDidChange(_ change: ForumMembershipChange) async {
    guard
      change.forumID == forumID,
      change.accountID == currentLease?.userID
    else { return }
    if case .ready(let isFollowed) = state, isFollowed == change.isFollowed {
      return
    }
    await reload()
  }

  func dismissError() {
    errorMessage = nil
  }

  private var validForum: Bool {
    forumID > 0 && !forumName.isEmpty
  }

  private func sessionLeaseState(_ lease: SessionLease) async -> SessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease == SessionLease(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func failForUnreadableAccount(previouslyFollowed: Bool?) {
    state = .failed(previouslyFollowed: previouslyFollowed)
    errorMessage = "无法读取当前账户，请稍后重试。"
  }

  private func reconcileAfterMutationFailure(
    lease: SessionLease,
    previouslyFollowed: Bool,
    message: String
  ) async {
    switch await sessionLeaseState(lease) {
    case .current:
      break
    case .changed:
      await reload()
      return
    case .unavailable:
      failForUnreadableAccount(previouslyFollowed: previouslyFollowed)
      return
    }

    generation &+= 1
    let reconciliationGeneration = generation
    do {
      guard
        let session = try await access.vault.activeSession(),
        SessionLease(session) == lease
      else {
        await reload()
        return
      }
      let membership = try await access.service.forumMembership(
        session: session,
        forumID: forumID,
        forumName: forumName
      )
      guard
        membership.userID == lease.userID,
        membership.forumID == forumID
      else {
        throw BrowseError.unavailable("贴吧返回了不匹配的关注状态，请重新加载后再试。")
      }
      guard reconciliationGeneration == generation else { return }
      switch await sessionLeaseState(lease) {
      case .current:
        lastKnownFollowed = membership.isFollowed
        state = .ready(isFollowed: membership.isFollowed)
        errorMessage = message
        AccountChangeNotifications.postForumMembershipChange(
          ForumMembershipChange(
            accountID: lease.userID,
            forumID: forumID,
            isFollowed: membership.isFollowed
          )
        )
      case .changed:
        await reload()
      case .unavailable:
        failForUnreadableAccount(previouslyFollowed: previouslyFollowed)
      }
    } catch {
      guard reconciliationGeneration == generation else { return }
      switch await sessionLeaseState(lease) {
      case .current:
        lastKnownFollowed = previouslyFollowed
        state = .ready(isFollowed: previouslyFollowed)
        errorMessage = message
      case .changed:
        await reload()
      case .unavailable:
        failForUnreadableAccount(previouslyFollowed: previouslyFollowed)
      }
    }
  }
}

private enum SessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct SessionLease: Equatable, Sendable {
  let userID: Int64
  let updatedAt: Date

  init(_ session: StoredAccountSession) {
    userID = session.id
    updatedAt = session.updatedAt
  }
}
