import Combine
import Foundation

@MainActor
final class InboxUnreadSummaryViewModel: ObservableObject {
  @Published private(set) var summary: InboxUnreadSummary?
  @Published private(set) var state: LoadState = .idle

  private let service: any AccountService
  private let vault: any AccountVault
  private var loadedLease: InboxUnreadSummarySessionLease?
  private var loadTask: Task<Void, Never>?
  private var epoch = 0

  init(service: any AccountService, vault: any AccountVault) {
    self.service = service
    self.vault = vault
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    startLoad()
  }

  func reload() {
    startLoad()
  }

  func refresh() async {
    let task = startLoad()
    await task.value
  }

  func accountSessionDidChange() {
    // Account notifications include credential rotation, so even an unchanged UID must clear.
    invalidateLoad()
    clearSnapshot()
    state = .idle
    startLoad()
  }

  func cancel() {
    invalidateLoad()
    state = summary == nil ? .idle : .loaded
  }

  @discardableResult
  private func startLoad() -> Task<Void, Never> {
    if let loadTask { return loadTask }

    epoch &+= 1
    let requestEpoch = epoch
    let service = service
    let vault = vault
    state = .loading

    let task = Task {
      defer { finishLoad(requestEpoch: requestEpoch) }

      do {
        guard let sessionBeforeRequest = try await vault.activeSession() else {
          guard requestEpoch == epoch else { return }
          clearSnapshot()
          state = .idle
          return
        }
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard
          sessionBeforeRequest.id > 0,
          AccountCredentialFormat.isValidBDUSS(sessionBeforeRequest.bduss)
        else {
          clearSnapshot()
          state = .failed("此账户需要重新登录，才能读取未读消息。")
          return
        }

        let lease = InboxUnreadSummarySessionLease(sessionBeforeRequest)
        if let loadedLease, loadedLease != lease {
          clearSnapshot()
        }

        let outcome: InboxUnreadSummaryRequestOutcome
        do {
          let response = try await service.inboxUnreadSummary(session: sessionBeforeRequest)
          try Task.checkCancellation()
          outcome = .success(response)
        } catch is CancellationError {
          settleUnrequestedCancellation(requestEpoch: requestEpoch)
          return
        } catch {
          outcome = .failure(error.localizedDescription)
        }

        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }

        switch outcome {
        case .success(let response):
          do {
            try Self.validate(response, lease: lease)
            loadedLease = lease
            summary = response
            state = .loaded
          } catch {
            state = .failed(error.localizedDescription)
          }
        case .failure(let message):
          state = .failed(message)
        }
      } catch is CancellationError {
        settleUnrequestedCancellation(requestEpoch: requestEpoch)
        return
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        // Without a post-request vault read the prior account cannot remain attributable.
        clearSnapshot()
        state = .failed(error.localizedDescription)
      }
    }
    loadTask = task
    return task
  }

  private func finishLoad(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    loadTask = nil
  }

  private func settleUnrequestedCancellation(requestEpoch: Int) {
    guard requestEpoch == epoch, !Task.isCancelled else { return }
    state = summary == nil ? .idle : .loaded
  }

  private func discardResultsFromChangedSession(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    invalidateLoad()
    clearSnapshot()
    state = .idle
  }

  private func invalidateLoad() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func clearSnapshot() {
    loadedLease = nil
    summary = nil
  }

  private static func validate(
    _ summary: InboxUnreadSummary,
    lease: InboxUnreadSummarySessionLease
  ) throws {
    guard summary.userID == lease.userID else {
      throw BrowseError.unavailable("贴吧返回了不匹配的未读消息摘要，请重新加载后再试。")
    }
    let requiredCounts = [summary.replyCount, summary.mentionCount]
    guard
      requiredCounts.allSatisfy({ (0...Int(Int32.max)).contains($0) }),
      summary.fanCount.map({ (0...Int(Int32.max)).contains($0) }) ?? true
    else {
      throw BrowseError.unavailable("贴吧返回了无效的未读消息计数，请重新加载后再试。")
    }
  }
}

private enum InboxUnreadSummaryRequestOutcome: Sendable {
  case success(InboxUnreadSummary)
  case failure(String)
}

private struct InboxUnreadSummarySessionLease: Equatable, Sendable {
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
