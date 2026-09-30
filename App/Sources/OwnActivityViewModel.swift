import Combine
import Foundation

/// Logged-in activity is deliberately memory-only and belongs to an exact login revision.
@MainActor
final class OwnActivityViewModel: ObservableObject {
  static let pageSize = 20
  static let maximumPageCount = 100
  static let maximumRetainedItems = 2_000

  let kind: OwnActivityKind
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var replies: [BrowseUserReply] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isSignedOut = false
  @Published private(set) var isHidden = false
  @Published private(set) var accountUserID: Int64?
  @Published private(set) var hasMore = false

  private let service: any AccountService
  private let vault: any AccountVault
  private var lease: AccountSessionLease?
  private var currentPage = 0
  private var epoch = 0
  private var task: Task<Void, Never>?

  init(kind: OwnActivityKind, service: any AccountService, vault: any AccountVault) {
    self.kind = kind
    self.service = service
    self.vault = vault
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    // An existing reload is coalesced. Refreshing during pagination replaces that request.
    if state == .loading, task != nil { return }
    invalidate()
    clearSnapshot()
    load(page: 1)
  }

  func refresh() async {
    reload()
    await task?.value
  }

  func loadMore() {
    guard state == .loaded, hasMore, !isHidden, task == nil, loadMoreError == nil else { return }
    load(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard state == .loaded, hasMore, task == nil, loadMoreError != nil else { return }
    load(page: currentPage + 1)
  }

  func accountSessionDidChange(loadImmediately: Bool = true) {
    cancel()
    if loadImmediately { load(page: 1) }
  }

  func cancel() {
    invalidate()
    clearSnapshot()
    state = .idle
  }

  func suspend() { cancel() }

  private func invalidate() {
    epoch &+= 1
    task?.cancel()
    task = nil
  }

  private func clearSnapshot() {
    threads = []
    replies = []
    lease = nil
    accountUserID = nil
    currentPage = 0
    isLoadingMore = false
    loadMoreError = nil
    isSignedOut = false
    isHidden = false
    hasMore = false
  }

  private func load(page: Int) {
    guard task == nil else { return }
    let replacing = page == 1
    guard (1...Self.maximumPageCount).contains(page) else {
      hasMore = false
      loadMoreError = "已达到本人动态的读取上限，请刷新后查看最新内容。"
      return
    }
    epoch &+= 1
    let requestEpoch = epoch
    if replacing { state = .loading } else { isLoadingMore = true }
    loadMoreError = nil
    task = Task {
      defer {
        if requestEpoch == epoch {
          task = nil
          isLoadingMore = false
        }
      }
      do {
        let session = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let session else {
          clearSnapshot()
          isSignedOut = true
          state = .loaded
          return
        }
        guard session.id > 0, session.credentials != nil else {
          clearSnapshot()
          state = .failed("此账户需要重新登录，才能安全读取本人帖子和回复。")
          return
        }
        let requestedLease = AccountSessionLease(session)
        guard replacing || lease == requestedLease else {
          cancel()
          state = .failed("登录账户已变化，请重新加载本人动态。")
          return
        }

        let outcome: OwnActivityOutcome
        do {
          outcome = .success(
            try await service.ownActivity(
              session: session, kind: kind, page: page, pageSize: Self.pageSize
            ))
        } catch {
          outcome = .failure(error)
        }
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        let currentSession = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let currentSession, requestedLease.matches(currentSession) else {
          cancel()
          isSignedOut = currentSession == nil
          state = currentSession == nil ? .loaded : .failed("登录账户已变化，请重新加载本人动态。")
          return
        }
        switch outcome {
        case .success(let response):
          do { try apply(response, page: page, requestedLease: requestedLease) } catch {
            fail(error, replacing: replacing)
          }
        case .failure(let error):
          if error is CancellationError {
            fail(BrowseError.unavailable("本人动态读取已取消，请重新加载后再试。"), replacing: replacing)
          } else {
            fail(error, replacing: replacing)
          }
        }
      } catch is CancellationError {
        guard requestEpoch == epoch else { return }
        // A cancelled/unavailable vault read cannot reattribute cached private activity.
        clearSnapshot()
        state = .failed("本人动态读取已取消，请重新加载后再试。")
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        clearSnapshot()
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func apply(
    _ response: OwnActivityPageData, page: Int, requestedLease: AccountSessionLease
  ) throws {
    guard response.accountUserID == requestedLease.userID, response.currentPage == page,
      response.threads.count <= 100, response.replies.count <= 10_000,
      kind == .threads ? response.replies.isEmpty : response.threads.isEmpty,
      response.threads.allSatisfy({ $0.id > 0 }),
      response.replies.allSatisfy({ $0.threadID > 0 && $0.postID > 0 })
    else {
      throw BrowseError.unavailable("贴吧返回的本人动态与当前账户或请求页码不匹配。")
    }
    if response.isHidden {
      threads = []
      replies = []
      isHidden = true
      hasMore = false
    } else {
      let previousCount = threads.count + replies.count
      if kind == .threads {
        var ids = Set(threads.map(\.id))
        threads += response.threads.filter { ids.insert($0.id).inserted }
      } else {
        var ids = Set(replies.map(\.id))
        replies += response.replies.filter { ids.insert($0.id).inserted }
      }
      let count = threads.count + replies.count
      hasMore =
        response.hasMore && count > previousCount
        && page < Self.maximumPageCount && count < Self.maximumRetainedItems
      if count > Self.maximumRetainedItems {
        threads = Array(threads.prefix(Self.maximumRetainedItems))
        replies = Array(replies.prefix(Self.maximumRetainedItems))
      }
    }
    lease = requestedLease
    accountUserID = requestedLease.userID
    currentPage = page
    state = .loaded
  }

  private func fail(_ error: Error, replacing: Bool) {
    if replacing {
      state = .failed(error.localizedDescription)
    } else {
      loadMoreError = error.localizedDescription
    }
  }
}

private enum OwnActivityOutcome {
  case success(OwnActivityPageData)
  case failure(Error)
}
