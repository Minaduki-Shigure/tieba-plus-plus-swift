import Combine
import Foundation

struct UserLikedForumsPageBinding: Equatable, Sendable {
  let accountUserID: Int64
  let sessionRevision: UUID
  let targetUserID: Int64
  let page: Int

  init(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int
  ) {
    accountUserID = session.id
    sessionRevision = session.sessionRevision
    self.targetUserID = targetUserID
    self.page = page
  }

  func matches(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int
  ) -> Bool {
    accountUserID == session.id
      && sessionRevision == session.sessionRevision
      && self.targetUserID == targetUserID
      && self.page == page
  }
}

@MainActor
final class UserLikedForumsViewModel: ObservableObject {
  static let pageSize = 50
  static let maximumCatalogPageCount = 100
  static let maximumRetainedForums = 5_000

  let targetUserID: Int64

  @Published private(set) var forums: [FollowedForumItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isSignedOut = false

  private let service: any AccountService
  private let vault: any AccountVault
  private var loadedBinding: UserLikedForumsPageBinding?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var epoch = 0

  init(
    targetUserID: Int64,
    service: any AccountService,
    vault: any AccountVault
  ) {
    self.targetUserID = targetUserID
    self.service = service
    self.vault = vault
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    beginNewEpoch(loadImmediately: true)
  }

  func refresh() async {
    reload()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange() {
    // Clear synchronously so another account never sees the prior session's result.
    beginNewEpoch(loadImmediately: true)
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
    guard loadMoreError != nil, !isLoadingMore else { return }
    if hasMore {
      load(page: currentPage + 1, replacing: false)
    } else {
      reload()
    }
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
    loadedBinding = nil
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
    guard targetUserID > 0 else {
      state = .failed("无法读取无效用户的喜欢贴吧。")
      return
    }
    guard (1...Self.maximumCatalogPageCount).contains(page) else {
      failPaginationLimit(replacing: replacing)
      return
    }

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
        guard
          replacing
            || loadedBinding?.matches(
              session: sessionBeforeRequest,
              targetUserID: targetUserID,
              page: currentPage
            ) == true
        else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }

        let requestBinding = UserLikedForumsPageBinding(
          session: sessionBeforeRequest,
          targetUserID: targetUserID,
          page: page
        )
        let response = try await service.likedForums(
          session: sessionBeforeRequest,
          targetUserID: targetUserID,
          page: page,
          pageSize: Self.pageSize
        )
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let sessionAfterRequest else {
          discardResultsFromMissingSession(requestEpoch: requestEpoch)
          return
        }
        guard
          requestBinding.matches(
            session: sessionAfterRequest,
            targetUserID: targetUserID,
            page: page
          )
        else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }

        try apply(
          response,
          binding: requestBinding,
          requestedPage: page,
          replacing: replacing
        )
      } catch is CancellationError {
        return
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        let message = error.localizedDescription
        if replacing {
          state = .failed(message)
        } else {
          loadMoreError = message
        }
      }
    }
  }

  private func apply(
    _ response: UserLikedForumPageData,
    binding: UserLikedForumsPageBinding,
    requestedPage: Int,
    replacing: Bool
  ) throws {
    try Self.validate(
      response,
      binding: binding,
      requestedPage: requestedPage,
      replacing: replacing,
      currentPage: currentPage
    )

    let existing = replacing ? [] : forums
    let merged = Self.merge(existing, response.forums)
    let madeProgress = merged.count > existing.count
    currentPage = response.currentPage
    loadedBinding = binding
    forums = Array(merged.prefix(Self.maximumRetainedForums))
    state = .loaded

    if merged.count > Self.maximumRetainedForums {
      failPaginationLimit(replacing: replacing)
      return
    }

    guard response.hasMore else {
      hasMore = false
      loadMoreError = nil
      return
    }

    if response.forums.isEmpty || !madeProgress {
      failIncompletePagination(
        message: "喜欢贴吧分页未取得进展，请重新加载后再试。",
        replacing: replacing
      )
      return
    }
    if currentPage >= Self.maximumCatalogPageCount
      || merged.count >= Self.maximumRetainedForums
    {
      failPaginationLimit(replacing: replacing)
      return
    }

    hasMore = true
  }

  private func failPaginationLimit(replacing: Bool) {
    failIncompletePagination(
      message: "喜欢贴吧数量超过当前安全读取上限，请稍后重新加载。",
      replacing: replacing
    )
  }

  private func failIncompletePagination(message: String, replacing: Bool) {
    hasMore = false
    if replacing, forums.isEmpty {
      state = .failed(message)
    } else {
      loadMoreError = message
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

  static func merge(
    _ existing: [FollowedForumItem],
    _ newItems: [FollowedForumItem]
  ) -> [FollowedForumItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }

  static func validate(
    _ page: UserLikedForumPageData,
    binding: UserLikedForumsPageBinding,
    requestedPage: Int,
    replacing: Bool,
    currentPage: Int
  ) throws {
    let expectedPage = replacing ? 1 : currentPage + 1
    guard requestedPage == expectedPage, page.currentPage == requestedPage else {
      throw BrowseError.unavailable("贴吧返回了异常的喜欢贴吧页码，请重新加载后再试。")
    }
    guard
      page.accountUserID == binding.accountUserID,
      page.targetUserID == binding.targetUserID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的喜欢贴吧数据，请重新加载后再试。")
    }
    guard
      page.forums.count <= 100,
      page.forums.allSatisfy({
        $0.id > 0
          && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw BrowseError.unavailable("贴吧返回了异常的喜欢贴吧数据，请重新加载后再试。")
    }
  }
}
