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
  private var currentLease: AccountSessionLease?
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
      let lease = AccountSessionLease(session)
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

    let outcome = await access.forumMembershipMutator.setFollowed(
      ForumMembershipMutationRequest(
        forumID: forumID,
        forumName: forumName,
        previouslyFollowed: previouslyFollowed,
        targetFollowed: isFollowed,
        expectedLease: expectedLease,
        verifiesCurrentState: false
      )
    )
    guard requestGeneration == generation else { return }

    switch outcome {
    case .confirmed(let confirmation):
      switch confirmation.leaseState {
      case .current:
        lastKnownFollowed = confirmation.change.isFollowed
        state = .ready(isFollowed: confirmation.change.isFollowed)
        errorMessage = confirmation.warning
      case .changed:
        currentLease = nil
        lastKnownFollowed = nil
        state = .idle
      case .unavailable:
        lastKnownFollowed = confirmation.change.isFollowed
        state = .failed(previouslyFollowed: confirmation.change.isFollowed)
        errorMessage = confirmation.warning ?? "无法读取当前账户，请稍后重试。"
      }
    case .unchanged(let isFollowed, let message):
      lastKnownFollowed = isFollowed
      state = .ready(isFollowed: isFollowed)
      errorMessage = message
    case .sessionChanged:
      await reload()
    case .unavailable(let retainedFollowed, let message):
      lastKnownFollowed = retainedFollowed
      state = .failed(previouslyFollowed: retainedFollowed)
      errorMessage = message
    case .rejected(let message):
      lastKnownFollowed = previouslyFollowed
      state = .ready(isFollowed: previouslyFollowed)
      errorMessage = message
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
    if
      case .mutating(_, let targetFollowed) = state,
      targetFollowed == change.isFollowed,
      change.sessionRevision == currentLease?.sessionRevision
    {
      return
    }
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

  private func sessionLeaseState(_ lease: AccountSessionLease) async -> AccountSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease.matches(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func failForUnreadableAccount(previouslyFollowed: Bool?) {
    state = .failed(previouslyFollowed: previouslyFollowed)
    errorMessage = "无法读取当前账户，请稍后重试。"
  }
}
