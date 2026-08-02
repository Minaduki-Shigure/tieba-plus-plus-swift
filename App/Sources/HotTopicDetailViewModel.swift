import Combine
import Foundation

@MainActor
final class HotTopicDetailViewModel: ObservableObject {
  @Published private(set) var topic: HotTopicItem
  @Published private(set) var relatedForums: [ForumSearchItem] = []
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var hasLoadedDetails = false
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var refreshError: String?

  private let service: any HotTopicService
  private var currentPage = 0
  private var hasMore = true
  private var nextPageCursor: Int64?
  private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(topic: HotTopicItem, service: any HotTopicService) {
    self.topic = topic
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    restart(preservingResults: false)
  }

  func retry() {
    restart(preservingResults: false)
  }

  func refresh() async {
    restart(preservingResults: state == .loaded)
    await loadTask?.value
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      hasMore,
      nextPageCursor != nil,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadMore()
  }

  func retryLoadMore() {
    guard
      hasMore,
      nextPageCursor != nil,
      !isLoadingMore,
      loadMoreError != nil,
      state == .loaded
    else { return }
    loadMore()
  }

  func cancel() {
    invalidateLoad()
    isLoadingMore = false
    if state == .loading {
      state = hasLoadedDetails ? .loaded : .idle
    }
  }

  private func restart(preservingResults: Bool) {
    invalidateLoad()
    if !preservingResults {
      relatedForums = []
      threads = []
      hasLoadedDetails = false
      currentPage = 0
      hasMore = true
      nextPageCursor = nil
    }
    isLoadingMore = false
    loadMoreError = nil
    refreshError = nil
    state = .loading
    let topicID = topic.id
    let topicName = topic.name
    let service = service
    generation &+= 1
    let requestGeneration = generation
    loadTask = Task {
      defer { finishTask(generation: requestGeneration) }
      do {
        let response = try await service.hotTopic(
          id: topicID,
          name: topicName,
          page: 1,
          pageSize: 10,
          lastID: nil
        )
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        topic = response.topic
        relatedForums = uniqueForums(response.relatedForums)
        threads = uniqueThreads(response.threads)
        currentPage = max(1, response.currentPage)
        nextPageCursor = response.nextPageCursor
        hasMore = response.hasMore && !threads.isEmpty && nextPageCursor != nil
        hasLoadedDetails = true
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        if preservingResults {
          refreshError = error.localizedDescription
          state = .loaded
        } else {
          state = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func loadMore() {
    guard let cursor = nextPageCursor else { return }
    let page = currentPage + 1
    let topicID = topic.id
    let topicName = topic.name
    let service = service
    generation &+= 1
    let requestGeneration = generation
    isLoadingMore = true
    loadMoreError = nil
    loadTask = Task {
      defer {
        if generation == requestGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.hotTopic(
          id: topicID,
          name: topicName,
          page: page,
          pageSize: 10,
          lastID: cursor
        )
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        let mergedThreads = mergeThreads(threads, response.threads)
        let addedItems = mergedThreads.count - threads.count
        topic = response.topic
        relatedForums = mergeForums(relatedForums, response.relatedForums)
        threads = mergedThreads
        currentPage = max(page, response.currentPage)
        nextPageCursor = response.nextPageCursor
        hasMore = response.hasMore && addedItems > 0 && nextPageCursor != nil
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func finishTask(generation requestGeneration: Int) {
    guard generation == requestGeneration else { return }
    loadTask = nil
  }

  private func invalidateLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func uniqueThreads(_ items: [BrowseThread]) -> [BrowseThread] {
    mergeThreads([], items)
  }

  private func mergeThreads(
    _ existing: [BrowseThread],
    _ newItems: [BrowseThread]
  ) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }

  private func uniqueForums(_ items: [ForumSearchItem]) -> [ForumSearchItem] {
    mergeForums([], items)
  }

  private func mergeForums(
    _ existing: [ForumSearchItem],
    _ newItems: [ForumSearchItem]
  ) -> [ForumSearchItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
