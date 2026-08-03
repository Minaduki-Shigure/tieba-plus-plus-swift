import Combine
import Foundation

@MainActor
final class ThreadViewModel: ObservableObject {
  @Published private(set) var thread: BrowseThread
  @Published private(set) var originThread: BrowseThread?
  @Published private(set) var poll: BrowsePoll?
  @Published private(set) var posts: [BrowsePost] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var canLoadPrevious = false
  @Published private(set) var isLoadingPrevious = false
  @Published private(set) var loadPreviousError: String?
  @Published private(set) var prependRestorePostID: Int64?
  @Published private(set) var prependRestoreSequence = 0
  @Published private(set) var isRestoringPrependPosition = false
  @Published private(set) var options = ThreadBrowseOptions()
  @Published private(set) var currentPage = 0
  @Published private(set) var totalPages = 0
  @Published private(set) var isJumping = false
  @Published private(set) var jumpError: String?
  @Published private(set) var positionNotice: String?
  @Published private(set) var scrollTargetPostID: Int64?

  private let service: any BrowseService
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var initialLocation: ThreadPostLocation?
  private var failedJumpPage: Int?
  private var lowestLoadedPage = 0
  private var previousLoadAnchorPostID: Int64?
  private var nextPagePostID: Int64?
  private var descendingFallbackPage: Int?

  init(
    thread: BrowseThread,
    service: any BrowseService,
    options: ThreadBrowseOptions = ThreadBrowseOptions(),
    initialLocation: ThreadPostLocation? = nil
  ) {
    self.thread = thread
    self.originThread = nil
    self.poll = nil
    self.service = service
    self.options = options
    self.initialLocation = options.sort == .hot ? nil : initialLocation
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload(location: initialLocation)
  }

  func waitForCurrentLoad() async {
    await loadTask?.value
  }

  func reload() {
    reload(location: initialLocation)
  }

  private func reload(location: ThreadPostLocation?) {
    invalidateCurrentLoad()
    currentPage = 0
    totalPages = 0
    hasMore = true
    lowestLoadedPage = 0
    canLoadPrevious = false
    isLoadingMore = false
    isLoadingPrevious = false
    loadMoreError = nil
    loadPreviousError = nil
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    jumpError = nil
    positionNotice = nil
    failedJumpPage = nil
    nextPagePostID = nil
    descendingFallbackPage = nil
    scrollTargetPostID = nil
    posts = []
    state = .loading
    load(page: 1, replacing: true, location: location, jumping: false)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func setSort(_ sort: ThreadPostSort) {
    guard options.sort != sort else { return }
    options.sort = sort
    if sort == .hot {
      initialLocation = nil
    }
    reload()
  }

  func setOnlyThreadAuthor(_ onlyThreadAuthor: Bool) {
    guard options.onlyThreadAuthor != onlyThreadAuthor else { return }
    options.onlyThreadAuthor = onlyThreadAuthor
    reload()
  }

  func prepareResume(options: ThreadBrowseOptions, postID: Int64?) {
    guard state == .idle else { return }
    self.options = options
    if options.sort != .hot, let postID, postID > 0 {
      initialLocation = .postID(postID)
    }
  }

  func jump(toPage page: Int) {
    guard page > 0, totalPages == 0 || page <= totalPages else {
      failedJumpPage = nil
      jumpError = totalPages > 0 ? "请输入 1 到 \(totalPages) 之间的页码。" : "页码必须大于 0。"
      return
    }
    invalidateCurrentLoad()
    isLoadingMore = false
    isLoadingPrevious = false
    loadMoreError = nil
    loadPreviousError = nil
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    jumpError = nil
    failedJumpPage = nil
    initialLocation = nil
    isJumping = true
    load(page: page, replacing: true, location: .pageNumber, jumping: true)
  }

  func retryJump() {
    guard let page = failedJumpPage, !isJumping else { return }
    jump(toPage: page)
  }

  var canRetryJump: Bool { failedJumpPage != nil }

  func dismissJumpError() {
    jumpError = nil
    failedJumpPage = nil
  }

  func dismissPositionNotice() {
    positionNotice = nil
  }

  func consumeScrollTarget() {
    scrollTargetPostID = nil
  }

  func consumePrependRestoreTarget() {
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    isLoadingPrevious = false
    isJumping = false
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    if state == .loading {
      state = posts.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current post: BrowsePost) {
    guard
      post.id == posts.last?.id,
      hasMore,
      !isLoadingMore,
      !isAdjustingPrependPosition,
      !isJumping,
      loadMoreError == nil,
      state == .loaded
    else {
      return
    }
    let request = nextLoadMoreRequest()
    load(
      page: request.page,
      replacing: false,
      location: request.location,
      jumping: false
    )
  }

  func retryLoadMore() {
    guard
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      !isAdjustingPrependPosition,
      !isJumping,
      state == .loaded
    else { return }
    let request = nextLoadMoreRequest()
    load(
      page: request.page,
      replacing: false,
      location: request.location,
      jumping: false
    )
  }

  func loadPrevious(anchorPostID: Int64? = nil) {
    guard
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isAdjustingPrependPosition,
      !isLoadingMore,
      !isJumping,
      loadPreviousError == nil,
      state == .loaded,
      options.sort == .ascending
    else { return }
    previousLoadAnchorPostID = anchorPostID.flatMap { candidate in
      posts.first(where: { $0.id == candidate && $0.localVisibility != .hidden })?.id
    }
    load(
      page: lowestLoadedPage - 1,
      replacing: false,
      location: .pageNumber,
      jumping: false,
      prepending: true
    )
  }

  func retryLoadPrevious() {
    guard
      loadPreviousError != nil,
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isAdjustingPrependPosition,
      !isLoadingMore,
      !isJumping,
      state == .loaded,
      options.sort == .ascending
    else { return }
    load(
      page: lowestLoadedPage - 1,
      replacing: false,
      location: .pageNumber,
      jumping: false,
      prepending: true
    )
  }

  var isAdjustingPrependPosition: Bool {
    isLoadingPrevious || isRestoringPrependPosition
  }

  private func load(
    page: Int,
    replacing: Bool,
    location: ThreadPostLocation?,
    jumping: Bool,
    prepending: Bool = false
  ) {
    let threadID = thread.id
    let service = service
    let options = options
    loadGeneration &+= 1
    let generation = loadGeneration
    if prepending {
      loadPreviousError = nil
      isLoadingPrevious = true
    } else if !replacing {
      loadMoreError = nil
      isLoadingMore = true
    }
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          isLoadingPrevious = false
          isJumping = false
          loadTask = nil
        }
      }
      do {
        var response = try await service.posts(
          threadID: threadID,
          page: page,
          pageSize: 30,
          options: options,
          location: location
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        try validatePostPage(response, threadID: threadID)

        var resolvedScrollTarget: Int64?
        var effectiveLocation = location
        var didFallBackFromMissingPosition = false
        var didHideRequestedPosition = false
        if case .postID(let postID) = location {
          if let target = response.posts.first(where: { $0.id == postID }) {
            if target.localVisibility == .hidden {
              didHideRequestedPosition = true
            } else {
              resolvedScrollTarget = postID
            }
          } else {
            didFallBackFromMissingPosition = true
            let locationResponse = response
            do {
              response = try await service.posts(
                threadID: threadID,
                page: 1,
                pageSize: 30,
                options: options,
                location: nil
              )
              effectiveLocation = nil
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              response = locationResponse
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            try validatePostPage(response, threadID: threadID)
            resolvedScrollTarget = response.posts.first(where: {
              $0.localVisibility != .hidden
            })?.id
          }
        } else if replacing && jumping {
          resolvedScrollTarget = response.posts.first(where: {
            $0.localVisibility != .hidden
          })?.id
        }

        if prepending {
          guard
            options.sort == .ascending,
            response.currentPage == page,
            page == lowestLoadedPage - 1
          else {
            throw BrowseError.unavailable("贴吧返回的上一页页码异常，未合并该响应。")
          }
          let newItems = uniqueValidPosts(response.posts, excluding: posts, threadID: threadID)
          guard !newItems.isEmpty else {
            canLoadPrevious = false
            previousLoadAnchorPostID = nil
            state = .loaded
            return
          }
          let restorePostID = previousLoadAnchorPostID
          isRestoringPrependPosition = true
          thread = response.thread
          if let responseOriginThread = response.originThread {
            originThread = responseOriginThread
          }
          if let responsePoll = response.poll {
            poll = responsePoll
          }
          posts = newItems + posts
          lowestLoadedPage = response.currentPage
          totalPages = max(totalPages, response.totalPages)
          canLoadPrevious = response.hasPrevious && lowestLoadedPage > 1
          prependRestorePostID = restorePostID
          prependRestoreSequence &+= 1
          state = .loaded
          return
        }

        let previousPosts = posts
        let previousPage = currentPage
        let requestedCursor: Int64?
        if case .pageCursor(let cursor) = effectiveLocation {
          requestedCursor = cursor
        } else {
          requestedCursor = nil
        }
        let mergedPosts = replacing ? response.posts : merge(previousPosts, response.posts)
        if replacing, jumping, effectiveLocation == .pageNumber, response.currentPage != page {
          throw BrowseError.unavailable("贴吧返回的跳转页码异常，未显示该响应。")
        }
        if !replacing {
          switch effectiveLocation {
          case .pageNumber:
            guard response.currentPage == page else {
              throw BrowseError.unavailable("贴吧返回的下一页页码异常，未合并该响应。")
            }
          case .pageCursor(let cursor):
            let didAdvanceCursorPage: Bool
            if options.sort == .ascending {
              didAdvanceCursorPage = response.currentPage > previousPage
                || (response.currentPage == previousPage && response.nextPagePostID != cursor)
            } else {
              didAdvanceCursorPage = response.currentPage != previousPage
                || response.nextPagePostID != cursor
            }
            guard didAdvanceCursorPage else {
              throw BrowseError.unavailable("贴吧返回的分页游标未前进，未合并该响应。")
            }
          case .postID(_), nil:
            break
          }
        }
        thread = response.thread
        if replacing {
          originThread = response.originThread
        } else if let responseOriginThread = response.originThread {
          originThread = responseOriginThread
        }
        if replacing {
          poll = response.poll
        } else if let responsePoll = response.poll {
          poll = responsePoll
        }
        currentPage = response.currentPage
        totalPages = response.totalPages
        nextPagePostID = response.nextPagePostID
        updateDescendingFallbackPage(
          requestedPage: page,
          replacing: replacing,
          location: effectiveLocation,
          currentPage: response.currentPage,
          totalPages: response.totalPages
        )
        let addedPosts = mergedPosts.count > previousPosts.count
        let exhaustedFallbackPage =
          !replacing && options.sort == .descending
          && effectiveLocation == .pageNumber && page == 1
        let noDescendingContinuation =
          options.sort == .descending && response.nextPagePostID == nil
          && descendingFallbackPage == nil
        let stalledDescendingPage =
          !replacing && options.sort == .descending && !addedPosts
        let canAdvancePastDuplicateAscendingPage =
          !replacing && options.sort == .ascending && !addedPosts && response.hasMore
          && (response.currentPage > previousPage
            || (response.nextPagePostID != nil && response.nextPagePostID != requestedCursor))
        let stalledAscendingPage =
          !replacing && options.sort == .ascending && !addedPosts
          && !canAdvancePastDuplicateAscendingPage
        let stalledHotPage =
          !replacing && options.sort == .hot && !addedPosts
        hasMore = response.hasMore
          && !exhaustedFallbackPage
          && !noDescendingContinuation
          && !stalledDescendingPage
          && !stalledAscendingPage
          && !stalledHotPage
        posts = mergedPosts
        if replacing {
          lowestLoadedPage = max(response.currentPage, 1)
          canLoadPrevious = options.sort == .ascending
            && response.currentPage > 1
            && response.hasPrevious
          loadPreviousError = nil
          prependRestorePostID = nil
        }
        if replacing, let resolvedScrollTarget {
          scrollTargetPostID = resolvedScrollTarget
        }
        if replacing {
          if didHideRequestedPosition {
            positionNotice = "目标楼层已按本地规则隐藏。"
          } else if didFallBackFromMissingPosition {
            positionNotice = "上次阅读位置已失效或不符合当前筛选，已显示当前可用内容。"
          } else {
            positionNotice = nil
          }
          initialLocation = nil
        }
        jumpError = nil
        failedJumpPage = nil
        state = .loaded
        if canAdvancePastDuplicateAscendingPage {
          let request = nextLoadMoreRequest()
          load(
            page: request.page,
            replacing: false,
            location: request.location,
            jumping: false
          )
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if prepending {
          loadPreviousError = error.localizedDescription
        } else if jumping {
          failedJumpPage = page
          jumpError = error.localizedDescription
          state = posts.isEmpty ? .failed(error.localizedDescription) : .loaded
        } else if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func nextLoadMoreRequest() -> (page: Int, location: ThreadPostLocation) {
    if options.sort == .descending {
      if let nextPagePostID {
        return (
          page: max(totalPages - currentPage, 0),
          location: .pageCursor(nextPagePostID)
        )
      }
      return (
        page: descendingFallbackPage ?? max(totalPages - 1, 1),
        location: .pageNumber
      )
    }
    if options.sort == .ascending, let nextPagePostID {
      return (
        page: max(currentPage, 1) + 1,
        location: .pageCursor(nextPagePostID)
      )
    }
    return (page: max(currentPage, 1) + 1, location: .pageNumber)
  }

  private func updateDescendingFallbackPage(
    requestedPage: Int,
    replacing: Bool,
    location: ThreadPostLocation?,
    currentPage: Int,
    totalPages: Int
  ) {
    guard options.sort == .descending else {
      descendingFallbackPage = nil
      return
    }
    if replacing {
      switch location {
      case nil:
        descendingFallbackPage = totalPages > 1 ? totalPages - 1 : nil
      case .pageNumber:
        descendingFallbackPage = requestedPage > 1 ? requestedPage - 1 : nil
      case .postID(_), .pageCursor(_):
        descendingFallbackPage = currentPage > 1 ? currentPage - 1 : nil
      }
    } else if location == .pageNumber {
      descendingFallbackPage = requestedPage > 1 ? requestedPage - 1 : nil
    } else if let page = descendingFallbackPage {
      descendingFallbackPage = page > 1 ? page - 1 : nil
    }
  }

  private func merge(_ existing: [BrowsePost], _ newItems: [BrowsePost]) -> [BrowsePost] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }

  private func validatePostPage(_ page: PostPageData, threadID: Int64) throws {
    guard page.thread.id == threadID else {
      throw BrowseError.unavailable("贴吧返回的主题归属异常，未显示该响应。")
    }
    var seen = Set<Int64>()
    guard page.posts.allSatisfy({ post in
      post.id > 0 && post.threadID == threadID && seen.insert(post.id).inserted
    }) else {
      throw BrowseError.unavailable("贴吧返回的楼层标识或归属异常，未显示该响应。")
    }
  }

  private func uniqueValidPosts(
    _ newItems: [BrowsePost],
    excluding existing: [BrowsePost],
    threadID: Int64
  ) -> [BrowsePost] {
    var seen = Set(existing.map(\.id))
    return newItems.filter {
      $0.id > 0 && $0.threadID == threadID && seen.insert($0.id).inserted
    }
  }
}
