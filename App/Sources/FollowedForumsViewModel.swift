import Combine
import Foundation

@MainActor
final class FollowedForumsViewModel: ObservableObject {
  @Published private(set) var forums: [FollowedForumItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isSignedOut = false

  private let service: any AccountService
  private let vault: any AccountVault
  private var loadedLease: FollowedForumsSessionLease?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var epoch = 0
  private var fullListSurfaceIDs = Set<UUID>()

  init(service: any AccountService, vault: any AccountVault) {
    self.service = service
    self.vault = vault
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  var hasActiveFullListSurface: Bool {
    !fullListSurfaceIDs.isEmpty
  }

  func fullListSurfaceDidAppear(id: UUID) {
    fullListSurfaceIDs.insert(id)
    loadIfNeeded()
  }

  func fullListSurfaceDidDisappear(id: UUID) {
    fullListSurfaceIDs.remove(id)
  }

  func reload() {
    beginNewEpoch(loadImmediately: true)
  }

  func refresh() async {
    reload()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange(loadImmediately: Bool = true) {
    // Clear synchronously so the prior account cannot remain on the home screen.
    beginNewEpoch(loadImmediately: loadImmediately)
  }

  func forumMembershipDidChange(
    _ change: ForumMembershipChange,
    loadImmediately: Bool = true
  ) {
    if let loadedLease, loadedLease.userID != change.accountID { return }
    beginNewEpoch(loadImmediately: loadImmediately)
  }

  func loadMoreIfNeeded(current forum: FollowedForumItem) {
    guard
      forum.id == forums.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard loadMoreError != nil, hasMore, !isLoadingMore else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func cancel() {
    invalidateLoad()
    isLoadingMore = false
    if state == .loading {
      state = forums.isEmpty ? .idle : .loaded
    }
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateLoad()
    currentPage = 0
    hasMore = true
    loadedLease = nil
    forums = []
    isLoadingMore = false
    loadMoreError = nil
    isSignedOut = false
    state = loadImmediately ? .loading : .idle
    if loadImmediately {
      load(page: 1, replacing: true)
    }
  }

  private func load(page: Int, replacing: Bool) {
    guard page > 0 else { return }
    let service = service
    let vault = vault
    epoch &+= 1
    let requestEpoch = epoch
    if !replacing {
      isLoadingMore = true
      loadMoreError = nil
    }
    loadTask = Task {
      defer {
        if requestEpoch == epoch {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        guard let sessionBeforeRequest = try await vault.activeSession() else {
          discardResultsFromMissingSession(requestEpoch: requestEpoch)
          return
        }
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        let lease = FollowedForumsSessionLease(sessionBeforeRequest)
        guard replacing || loadedLease == lease else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        let response = try await service.followedForums(
          session: sessionBeforeRequest,
          page: page,
          pageSize: 50
        )
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        try Self.validate(
          response,
          requestedPage: page,
          replacing: replacing,
          currentPage: currentPage
        )
        let priorCount = replacing ? 0 : forums.count
        let mergedForums = merge(replacing ? [] : forums, response.forums)
        currentPage = response.currentPage
        hasMore = response.hasMore
          && !response.forums.isEmpty
          && (replacing || mergedForums.count > priorCount)
        loadedLease = lease
        forums = mergedForums
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func discardResultsFromChangedSession(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    beginNewEpoch(loadImmediately: false)
  }

  private func discardResultsFromMissingSession(requestEpoch: Int) {
    guard requestEpoch == epoch, !Task.isCancelled else { return }
    beginNewEpoch(loadImmediately: false)
    isSignedOut = true
    state = .failed("请先登录账户。")
  }

  private func invalidateLoad() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func merge(
    _ existing: [FollowedForumItem],
    _ newItems: [FollowedForumItem]
  ) -> [FollowedForumItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }

  private static func validate(
    _ page: FollowedForumPageData,
    requestedPage: Int,
    replacing: Bool,
    currentPage: Int
  ) throws {
    let expectedPage = replacing ? 1 : currentPage + 1
    guard requestedPage == expectedPage, page.currentPage == requestedPage else {
      throw BrowseError.unavailable("贴吧返回了异常的关注贴吧页码，请重新加载后再试。")
    }
  }
}

struct FollowedForumsSessionLease: Equatable, Sendable {
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

enum FollowedForumsHomeProjection {
  static let maximumForumCount = 6

  static func visibleForums(from forums: [FollowedForumItem]) -> [FollowedForumItem] {
    Array(forums.prefix(maximumForumCount))
  }
}
