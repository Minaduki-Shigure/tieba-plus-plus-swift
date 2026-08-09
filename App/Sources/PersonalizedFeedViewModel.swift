import Combine
import Foundation

@MainActor
final class PersonalizedFeedViewModel: ObservableObject {
  @Published private(set) var items: [PersonalizedFeedItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isRefreshing = false
  @Published private(set) var isLoadingMore = false
  @Published private(set) var hasMore = true
  @Published private(set) var refreshError: String?
  @Published private(set) var loadMoreError: String?

  private static let maximumRetainedItems = 300
  private static let maximumConsecutiveDuplicatePages = 2

  private let service: any PersonalizedFeedService
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var currentPage = 0
  private var refreshOverlapFrontier = 0
  private var consecutiveDuplicatePages = 0
  private var activeRequestKind: RequestKind?

  init(service: any PersonalizedFeedService) {
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    startRequest(.replacement)
  }

  func retry() {
    startRequest(.replacement)
  }

  func refresh() async {
    guard state == .loaded, !isLoadingMore else { return }
    startRequest(.refresh)
    await loadTask?.value
  }

  func reloadForContentFilterChange() {
    guard state == .loaded else { return }
    startRequest(.replacement)
  }

  func loadMore() {
    guard
      state == .loaded,
      !isRefreshing,
      !isLoadingMore,
      loadMoreError == nil,
      hasMore,
      currentPage < Int(Int32.max)
    else { return }
    startRequest(.loadMore(page: currentPage + 1))
  }

  func retryLoadMore() {
    guard loadMoreError != nil else { return }
    loadMoreError = nil
    loadMore()
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func cancel() {
    let kind = activeRequestKind
    invalidateCurrentRequest()
    isRefreshing = false
    isLoadingMore = false
    if state == .loading {
      state = kind == .replacement && items.isEmpty ? .idle : .loaded
    }
  }

  private func startRequest(_ kind: RequestKind) {
    invalidateCurrentRequest()
    activeRequestKind = kind
    refreshError = nil
    loadMoreError = nil

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
    case .refresh:
      requestedPage = 1
      isRefreshing = true
    case .loadMore(let page):
      requestedPage = page
      isLoadingMore = true
    }

    let requestGeneration = generation
    let service = service
    loadTask = Task {
      defer { finishRequest(generation: requestGeneration, kind: kind) }
      do {
        let response = try await service.personalizedThreads(page: requestedPage)
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        guard response.currentPage == requestedPage else {
          throw BrowseError.unavailable("推荐流返回了错误的页码。")
        }
        apply(response, kind: kind)
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        apply(error: error, kind: kind)
      }
    }
  }

  private func apply(_ response: PersonalizedFeedPageData, kind: RequestKind) {
    let responseItems = unique(response.items)
    switch kind {
    case .replacement:
      items = Array(responseItems.prefix(Self.maximumRetainedItems))
      currentPage = 1
      refreshOverlapFrontier = 0
      consecutiveDuplicatePages = 0
      hasMore = response.hasMore && !responseItems.isEmpty
      state = .loaded
    case .refresh:
      if !responseItems.isEmpty {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        items = merged(responseItems, followedBy: items)
        currentPage = 1
        consecutiveDuplicatePages = 0
        hasMore = response.hasMore && items.count < Self.maximumRetainedItems
      }
    case .loadMore(let requestedPage):
      let knownIDs = Set(items.map(\.id))
      let additions = responseItems.filter { !knownIDs.contains($0.id) }
      currentPage = requestedPage
      if responseItems.isEmpty {
        hasMore = false
      } else if additions.isEmpty {
        if requestedPage <= refreshOverlapFrontier {
          consecutiveDuplicatePages = 0
          hasMore = response.hasMore && items.count < Self.maximumRetainedItems
        } else {
          consecutiveDuplicatePages += 1
          hasMore = response.hasMore
            && consecutiveDuplicatePages < Self.maximumConsecutiveDuplicatePages
            && items.count < Self.maximumRetainedItems
        }
      } else {
        items = Array((items + additions).prefix(Self.maximumRetainedItems))
        consecutiveDuplicatePages = 0
        hasMore = response.hasMore && items.count < Self.maximumRetainedItems
      }
    }
  }

  private func apply(error: Error, kind: RequestKind) {
    switch kind {
    case .replacement:
      state = .failed(error.localizedDescription)
    case .refresh:
      refreshError = error.localizedDescription
    case .loadMore:
      loadMoreError = error.localizedDescription
    }
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

  private func finishRequest(generation requestGeneration: Int, kind: RequestKind) {
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

private enum RequestKind: Equatable, Sendable {
  case replacement
  case refresh
  case loadMore(page: Int)
}
