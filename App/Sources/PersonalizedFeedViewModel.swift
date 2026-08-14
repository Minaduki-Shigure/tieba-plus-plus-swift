import Combine
import Foundation

enum PersonalizedFeedScope: Equatable, Sendable {
  case all
  case waitingForFollowedForumIndex
  case followedForums(FollowedForumIndexSnapshot)

  var isReady: Bool {
    self != .waitingForFollowedForumIndex
  }

  var isFollowedForumsOnly: Bool {
    if case .followedForums = self { return true }
    return false
  }

  var hasNoAllowedForums: Bool {
    if case .followedForums(let snapshot) = self {
      return snapshot.forumIDs.isEmpty
    }
    return false
  }

  func filter(_ items: [PersonalizedFeedItem]) -> [PersonalizedFeedItem] {
    switch self {
    case .all:
      items
    case .waitingForFollowedForumIndex:
      []
    case .followedForums(let snapshot):
      items.filter { snapshot.forumIDs.contains($0.thread.forumID) }
    }
  }
}

@MainActor
final class PersonalizedFeedViewModel: ObservableObject {
  static let maximumRetainedItems = 300
  static let maximumConsecutiveDuplicatePages = 2
  static let maximumAutomaticMappedEmptyPages = 5
  static let maximumAutomaticFilteredPages = 5
  static let maximumFilteredPagesPerScanEpoch = 50
  static let maximumRawItemIDsPerScanEpoch = 1_000
  static let mappedEmptyScanPausedMessage = "连续多页没有可显示的推荐，可以继续加载。"
  static let filteredScanPausedMessage = "连续多页没有来自已关注贴吧的内容，可以继续查找。"

  @Published private(set) var items: [PersonalizedFeedItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isRefreshing = false
  @Published private(set) var isLoadingMore = false
  @Published private(set) var hasMore = true
  @Published private(set) var refreshError: String?
  @Published private(set) var loadMoreError: String?
  @Published private(set) var scope: PersonalizedFeedScope = .all

  private let service: any PersonalizedFeedService
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var currentPage = 0
  private var refreshOverlapFrontier = 0
  private var consecutiveDuplicatePages = 0
  private var activeRequestKind: PersonalizedFeedRequestKind?
  private var scannedRawItemIDs = Set<Int64>()
  private var scannedPageCount = 0
  private var filteredScanIsPaused = false
  private var failedLoadMorePage: Int?

  init(service: any PersonalizedFeedService) {
    self.service = service
  }

  func setScope(_ scope: PersonalizedFeedScope, loadIfNeeded: Bool) {
    guard self.scope != scope else {
      if loadIfNeeded { self.loadIfNeeded() }
      return
    }
    invalidateCurrentRequest()
    self.scope = scope
    resetSnapshot()
    if scope.hasNoAllowedForums {
      state = .loaded
      hasMore = false
    } else if loadIfNeeded {
      self.loadIfNeeded()
    }
  }

  func loadIfNeeded() {
    guard state == .idle, scope.isReady else { return }
    if scope.hasNoAllowedForums {
      state = .loaded
      hasMore = false
      return
    }
    startRequest(.replacement)
  }

  func retry() {
    guard scope.isReady else { return }
    if scope.hasNoAllowedForums {
      resetSnapshot()
      state = .loaded
      hasMore = false
      return
    }
    startRequest(.replacement)
  }

  func refresh() async {
    guard state == .loaded, !isLoadingMore, scope.isReady, !scope.hasNoAllowedForums else {
      return
    }
    startRequest(.refresh)
    await loadTask?.value
  }

  func reloadForContentFilterChange() {
    guard state == .loaded, scope.isReady, !scope.hasNoAllowedForums else { return }
    startRequest(.replacement)
  }

  func loadMore() {
    guard
      state == .loaded,
      !isRefreshing,
      !isLoadingMore,
      loadMoreError == nil,
      hasMore,
      currentPage < Int(Int32.max),
      scope.isReady,
      !scope.hasNoAllowedForums
    else { return }
    if scope.isFollowedForumsOnly, filteredScanEpochIsExhausted {
      pauseFilteredScan()
      return
    }
    startRequest(.loadMore(page: currentPage + 1))
  }

  func loadMoreIfNeeded(currentItemID: Int64) {
    guard
      let index = items.firstIndex(where: { $0.id == currentItemID }),
      index >= max(items.count - 3, 0)
    else { return }
    loadMore()
  }

  func retryLoadMore() {
    guard loadMoreError != nil else { return }
    if filteredScanIsPaused {
      resetFilteredScanEpoch()
    }
    if let failedLoadMorePage {
      loadMoreError = nil
      startRequest(.loadMore(page: failedLoadMorePage))
      return
    }
    loadMoreError = nil
    loadMore()
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func cancel() {
    let kind = activeRequestKind
    invalidateCurrentRequest()
    if state == .loading {
      state = kind == .replacement && items.isEmpty ? .idle : .loaded
    }
  }

  private var filteredScanEpochIsExhausted: Bool {
    scannedPageCount >= Self.maximumFilteredPagesPerScanEpoch
      || scannedRawItemIDs.count >= Self.maximumRawItemIDsPerScanEpoch
  }

  private func startRequest(_ kind: PersonalizedFeedRequestKind) {
    guard scope.isReady, !scope.hasNoAllowedForums else { return }
    invalidateCurrentRequest()
    activeRequestKind = kind
    refreshError = nil
    loadMoreError = nil
    filteredScanIsPaused = false
    failedLoadMorePage = nil

    let requestedPage: Int
    switch kind {
    case .replacement:
      requestedPage = 1
      state = .loading
      items = []
      currentPage = 0
      refreshOverlapFrontier = 0
      consecutiveDuplicatePages = 0
      hasMore = true
      resetFilteredScanEpoch()
    case .refresh:
      requestedPage = 1
      isRefreshing = true
      resetFilteredScanEpoch()
    case .loadMore(let page):
      requestedPage = page
      isLoadingMore = true
    }

    let requestGeneration = generation
    let requestScope = scope
    let service = service
    loadTask = Task {
      var page = requestedPage
      defer { finishRequest(generation: requestGeneration, kind: kind) }
      do {
        var pagesScannedForAction = 0
        while true {
          let response = try await service.personalizedThreads(page: page)
          try Task.checkCancellation()
          guard generation == requestGeneration else { return }
          guard response.currentPage == page else {
            throw BrowseError.unavailable("推荐流返回了错误的页码。")
          }

          let rawItems = unique(response.items)
          let madeRawProgress = recordRawProgress(rawItems)
          scannedPageCount &+= 1
          pagesScannedForAction &+= 1
          let eligibleItems = requestScope.filter(rawItems)
          let termination: PersonalizedFeedBatchTermination

          if !response.hasMore {
            termination = rawItems.isEmpty ? .rawEmpty : .serverEnd
          } else if !madeRawProgress {
            if rawItems.isEmpty,
               pagesScannedForAction < Self.maximumAutomaticMappedEmptyPages,
               page < Int(Int32.max)
            {
              page += 1
              continue
            }
            if rawItems.isEmpty {
              termination = page < Int(Int32.max) ? .mappedEmptyScanPaused : .serverEnd
            } else {
              termination = .duplicateOnly
            }
          } else if !requestScope.isFollowedForumsOnly || !eligibleItems.isEmpty {
            termination = .pageReady
          } else if pagesScannedForAction >= Self.maximumAutomaticFilteredPages
            || filteredScanEpochIsExhausted
          {
            termination = .filteredScanPaused
          } else if page >= Int(Int32.max) {
            termination = .serverEnd
          } else {
            page += 1
            continue
          }

          apply(
            PersonalizedFeedBatch(
              items: eligibleItems,
              currentPage: page,
              serverHasMore: response.hasMore,
              termination: termination
            ),
            kind: kind
          )
          return
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        apply(error: error, kind: kind, failedPage: page)
      }
    }
  }

  private func apply(_ batch: PersonalizedFeedBatch, kind: PersonalizedFeedRequestKind) {
    let responseItems = unique(batch.items)
    switch kind {
    case .replacement:
      items = Array(responseItems.prefix(Self.maximumRetainedItems))
      currentPage = batch.currentPage
      refreshOverlapFrontier = 0
      consecutiveDuplicatePages = 0
      hasMore = canContinue(after: batch, hasVisibleItems: !responseItems.isEmpty)
      state = .loaded
      if batch.termination == .filteredScanPaused {
        pauseFilteredScan()
      } else if batch.termination == .mappedEmptyScanPaused {
        pauseMappedEmptyScan()
      }
    case .refresh:
      if !responseItems.isEmpty {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        items = merged(responseItems, followedBy: items)
        currentPage = batch.currentPage
        consecutiveDuplicatePages = 0
        hasMore = canContinue(after: batch, hasVisibleItems: true)
      } else if batch.termination == .filteredScanPaused {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
        pauseFilteredScan()
      } else if batch.termination == .mappedEmptyScanPaused {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
        pauseMappedEmptyScan()
      } else if batch.termination == .duplicateOnly, batch.serverHasMore {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
      }
    case .loadMore:
      let knownIDs = Set(items.map(\.id))
      let additions = responseItems.filter { !knownIDs.contains($0.id) }
      currentPage = batch.currentPage
      switch batch.termination {
      case .rawEmpty:
        hasMore = false
      case .serverEnd:
        if !additions.isEmpty {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
        }
        consecutiveDuplicatePages = additions.isEmpty ? consecutiveDuplicatePages : 0
        hasMore = false
      case .filteredScanPaused:
        hasMore = items.count < Self.maximumRetainedItems
        pauseFilteredScan()
      case .mappedEmptyScanPaused:
        hasMore = items.count < Self.maximumRetainedItems
        pauseMappedEmptyScan()
      case .duplicateOnly:
        if additions.isEmpty {
          applyDuplicatePage(batch: batch)
        } else {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
          consecutiveDuplicatePages = 0
          hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
        }
      case .pageReady:
        if additions.isEmpty {
          applyDuplicatePage(batch: batch)
        } else {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
          consecutiveDuplicatePages = 0
          hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
        }
      }
    }
  }

  private func applyDuplicatePage(batch: PersonalizedFeedBatch) {
    if batch.currentPage <= refreshOverlapFrontier {
      consecutiveDuplicatePages = 0
      hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
    } else {
      consecutiveDuplicatePages += 1
      hasMore = batch.serverHasMore
        && consecutiveDuplicatePages < Self.maximumConsecutiveDuplicatePages
        && items.count < Self.maximumRetainedItems
    }
  }

  private func canContinue(
    after batch: PersonalizedFeedBatch,
    hasVisibleItems: Bool
  ) -> Bool {
    guard items.count < Self.maximumRetainedItems else { return false }
    switch batch.termination {
    case .serverEnd, .rawEmpty:
      return false
    case .filteredScanPaused, .mappedEmptyScanPaused:
      return true
    case .duplicateOnly:
      return batch.serverHasMore
    case .pageReady:
      return batch.serverHasMore && (scope.isFollowedForumsOnly || hasVisibleItems)
    }
  }

  private func apply(
    error: Error,
    kind: PersonalizedFeedRequestKind,
    failedPage: Int
  ) {
    switch kind {
    case .replacement:
      state = .failed(error.localizedDescription)
    case .refresh:
      refreshError = error.localizedDescription
    case .loadMore:
      failedLoadMorePage = failedPage
      loadMoreError = error.localizedDescription
    }
  }

  private func pauseFilteredScan() {
    filteredScanIsPaused = true
    loadMoreError = Self.filteredScanPausedMessage
  }

  private func pauseMappedEmptyScan() {
    loadMoreError = Self.mappedEmptyScanPausedMessage
  }

  private func resetSnapshot() {
    items = []
    state = .idle
    isRefreshing = false
    isLoadingMore = false
    hasMore = true
    refreshError = nil
    loadMoreError = nil
    currentPage = 0
    refreshOverlapFrontier = 0
    consecutiveDuplicatePages = 0
    filteredScanIsPaused = false
    failedLoadMorePage = nil
    resetFilteredScanEpoch()
  }

  private func resetFilteredScanEpoch() {
    scannedRawItemIDs = Set(items.map(\.id))
    scannedPageCount = 0
    filteredScanIsPaused = false
  }

  private func recordRawProgress(_ source: [PersonalizedFeedItem]) -> Bool {
    var madeProgress = false
    for item in source where item.id > 0 {
      if scannedRawItemIDs.insert(item.id).inserted {
        madeProgress = true
      }
    }
    return madeProgress
  }

  private func unique(_ source: [PersonalizedFeedItem]) -> [PersonalizedFeedItem] {
    var seen = Set<Int64>()
    return source.filter { $0.id > 0 && seen.insert($0.id).inserted }
  }

  private func merged(
    _ first: [PersonalizedFeedItem],
    followedBy second: [PersonalizedFeedItem]
  ) -> [PersonalizedFeedItem] {
    var seen = Set<Int64>()
    return Array(
      (first + second)
        .filter { $0.id > 0 && seen.insert($0.id).inserted }
        .prefix(Self.maximumRetainedItems)
    )
  }

  private func finishRequest(
    generation requestGeneration: Int,
    kind: PersonalizedFeedRequestKind
  ) {
    guard generation == requestGeneration else { return }
    loadTask = nil
    activeRequestKind = nil
    switch kind {
    case .replacement:
      break
    case .refresh:
      isRefreshing = false
    case .loadMore:
      isLoadingMore = false
    }
  }

  private func invalidateCurrentRequest() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    activeRequestKind = nil
    isRefreshing = false
    isLoadingMore = false
  }
}

private enum PersonalizedFeedRequestKind: Equatable, Sendable {
  case replacement
  case refresh
  case loadMore(page: Int)
}

private enum PersonalizedFeedBatchTermination: Equatable, Sendable {
  case pageReady
  case serverEnd
  case rawEmpty
  case duplicateOnly
  case filteredScanPaused
  case mappedEmptyScanPaused
}

private struct PersonalizedFeedBatch: Sendable {
  let items: [PersonalizedFeedItem]
  let currentPage: Int
  let serverHasMore: Bool
  let termination: PersonalizedFeedBatchTermination
}
