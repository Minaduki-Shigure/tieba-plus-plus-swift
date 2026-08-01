import Combine
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
  @Published private(set) var submittedQuery: String
  @Published private(set) var exactForum: ForumSearchItem?
  @Published private(set) var relatedForums: [ForumSearchItem] = []
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?

  private let service: any SearchService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(query: String, service: any SearchService) {
    self.submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    submit(submittedQuery)
  }

  func submit(_ rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      state = .failed("请输入搜索关键词。")
      return
    }

    invalidateCurrentLoad()
    submittedQuery = query
    exactForum = nil
    relatedForums = []
    threads = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    state = .loading

    loadGeneration &+= 1
    let generation = loadGeneration
    let service = service
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          loadTask = nil
        }
      }
      do {
        async let forumRequest = service.searchForums(query: query)
        async let threadRequest = service.searchThreads(query: query, page: 1, pageSize: 20)
        let (forumResponse, threadResponse) = try await (forumRequest, threadRequest)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        exactForum = forumResponse.exactMatch
        relatedForums = forumResponse.related
        threads = threadResponse.threads
        currentPage = threadResponse.currentPage
        hasMore = threadResponse.hasMore
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  func refresh() async {
    submit(submittedQuery)
    await loadTask?.value
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadMore()
  }

  func retryLoadMore() {
    guard loadMoreError != nil, hasMore, !isLoadingMore, state == .loaded else { return }
    loadMore()
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    if state == .loading {
      state = hasResults ? .loaded : .idle
    }
  }

  var hasResults: Bool {
    exactForum != nil || !relatedForums.isEmpty || !threads.isEmpty
  }

  private func loadMore() {
    let page = currentPage + 1
    let query = submittedQuery
    let service = service
    loadGeneration &+= 1
    let generation = loadGeneration
    loadMoreError = nil
    isLoadingMore = true
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.searchThreads(query: query, page: page, pageSize: 20)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        threads = merge(threads, response.threads)
        currentPage = response.currentPage
        hasMore = response.hasMore
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
