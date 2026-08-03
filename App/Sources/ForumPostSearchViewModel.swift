import Combine
import Foundation

@MainActor
final class ForumPostSearchViewModel: ObservableObject {
  @Published private(set) var submittedQuery = ""
  @Published private(set) var results: [ForumPostSearchItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var sort: ForumPostSearchSort = .newest
  @Published private(set) var filter: ForumPostSearchFilter = .all
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var refreshError: String?
  @Published private(set) var resultPaginationEpoch = 0
  @Published private(set) var history: [ForumSearchHistoryEntry] = []
  @Published private(set) var isHistoryLoading = false
  @Published private(set) var historyError: String?

  let forumName: String

  private let service: any ForumPostSearchService
  private let historyRepository: any ForumSearchHistoryRepository
  private var currentPage = 0
  private var hasMore = true
  private var searchTask: Task<Void, Never>?
  private var historyRecordTask: Task<Void, Never>?
  private var searchGeneration = 0
  private var hasLoadedHistory = false
  private var lastHistoryTimestamp: Date?

  init(
    forumName: String,
    service: any ForumPostSearchService,
    historyRepository: any ForumSearchHistoryRepository
  ) {
    self.forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.service = service
    self.historyRepository = historyRepository
  }

  var hasResults: Bool { !results.isEmpty }
  var displayableResults: [ForumPostSearchItem] {
    results.filter { $0.localVisibility != .hidden }
  }
  var hasDisplayableResults: Bool { !displayableResults.isEmpty }
  var isShowingHistory: Bool { submittedQuery.isEmpty }

  func loadHistoryIfNeeded() async {
    guard !hasLoadedHistory else { return }
    await reloadHistory()
  }

  func submit(_ rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      clearSearch()
      return
    }

    guard query.count <= 100 else {
      invalidateSearch()
      submittedQuery = query
      results = []
      currentPage = 0
      hasMore = false
      isLoadingMore = false
      loadMoreError = nil
      refreshError = nil
      state = .failed("搜索关键词不能超过 100 个字符。")
      return
    }

    invalidateSearch()
    submittedQuery = query
    results = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    refreshError = nil
    state = .loading
    recordHistory(query, at: nextHistoryTimestamp())
    load(page: 1, replacing: true, preservingResults: false)
  }

  func clearSearch() {
    guard !submittedQuery.isEmpty || state != .idle || !results.isEmpty else { return }
    invalidateSearch()
    submittedQuery = ""
    results = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    refreshError = nil
    state = .idle
  }

  func retry() {
    restart(preservingResults: false)
  }

  func refresh() async {
    restart(preservingResults: hasResults)
    await searchTask?.value
  }

  func setSort(_ sort: ForumPostSearchSort) {
    guard self.sort != sort else { return }
    self.sort = sort
    restart(preservingResults: false)
  }

  func setFilter(_ filter: ForumPostSearchFilter) {
    guard self.filter != filter else { return }
    self.filter = filter
    restart(preservingResults: false)
  }

  func reloadAfterContentFilterChange() {
    guard !submittedQuery.isEmpty, submittedQuery.count <= 100 else { return }
    restart(preservingResults: false)
  }

  func loadMoreIfNeeded(current result: ForumPostSearchItem) {
    guard
      result.id == results.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    load(page: currentPage + 1, replacing: false, preservingResults: true)
  }

  func retryLoadMore() {
    guard hasMore, !isLoadingMore, loadMoreError != nil, state == .loaded else { return }
    load(page: currentPage + 1, replacing: false, preservingResults: true)
  }

  func deleteHistory(id: String) async {
    await historyRecordTask?.value
    do {
      try await historyRepository.delete(id: id)
      history.removeAll { $0.id == id }
      historyError = nil
    } catch is CancellationError {
      return
    } catch {
      historyError = error.localizedDescription
    }
  }

  func deleteAllHistory() async {
    await historyRecordTask?.value
    do {
      try await historyRepository.deleteAll(forumName: forumName)
      history = []
      historyError = nil
    } catch is CancellationError {
      return
    } catch {
      historyError = error.localizedDescription
    }
  }

  func retryHistory() async {
    await historyRecordTask?.value
    await reloadHistory()
  }

  func resetHistory() async {
    await historyRecordTask?.value
    do {
      try await historyRepository.reset()
      history = []
      hasLoadedHistory = true
      historyError = nil
    } catch is CancellationError {
      return
    } catch {
      historyError = error.localizedDescription
    }
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func cancel() {
    let shouldRearmPagination = !results.isEmpty && (state == .loading || isLoadingMore)
    invalidateSearch()
    isLoadingMore = false
    if shouldRearmPagination {
      resultPaginationEpoch &+= 1
    }
    if state == .loading {
      state = results.isEmpty ? .idle : .loaded
    }
  }

  private func restart(preservingResults: Bool) {
    guard !submittedQuery.isEmpty else { return }
    guard submittedQuery.count <= 100 else {
      invalidateSearch()
      results = []
      currentPage = 0
      hasMore = false
      isLoadingMore = false
      loadMoreError = nil
      refreshError = nil
      state = .failed("搜索关键词不能超过 100 个字符。")
      return
    }
    invalidateSearch()
    if !preservingResults {
      results = []
      currentPage = 0
      hasMore = true
    }
    isLoadingMore = false
    loadMoreError = nil
    refreshError = nil
    state = .loading
    load(
      page: 1,
      replacing: true,
      preservingResults: preservingResults
    )
  }

  private func load(
    page: Int,
    replacing: Bool,
    preservingResults: Bool
  ) {
    let query = submittedQuery
    let forumName = forumName
    let sort = sort
    let filter = filter
    let service = service
    searchGeneration &+= 1
    let generation = searchGeneration
    if !replacing {
      loadMoreError = nil
      isLoadingMore = true
    }

    searchTask = Task {
      defer {
        if generation == searchGeneration {
          isLoadingMore = false
          searchTask = nil
        }
      }
      do {
        let response = try await service.searchForumPosts(
          query: query,
          forumName: forumName,
          page: page,
          pageSize: 20,
          sort: sort,
          filter: filter
        )
        try Task.checkCancellation()
        guard isCurrent(generation: generation, query: query, sort: sort, filter: filter)
        else { return }

        let merged = replacing ? merge([], response.results) : merge(results, response.results)
        let addedCount = merged.count - (replacing ? 0 : results.count)
        results = merged
        currentPage = max(page, response.currentPage)
        hasMore = response.hasMore && addedCount > 0
        loadMoreError = nil
        refreshError = nil
        state = .loaded
        if replacing {
          resultPaginationEpoch &+= 1
        }
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent(generation: generation, query: query, sort: sort, filter: filter)
        else { return }
        if !replacing {
          loadMoreError = error.localizedDescription
          state = .loaded
        } else if preservingResults, !results.isEmpty {
          resultPaginationEpoch &+= 1
          refreshError = error.localizedDescription
          state = .loaded
        } else {
          state = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func recordHistory(_ query: String, at date: Date) {
    let previousTask = historyRecordTask
    let historyRepository = historyRepository
    let forumName = forumName
    historyRecordTask = Task { [weak self] in
      await previousTask?.value
      do {
        try await historyRepository.record(
          query: query,
          forumName: forumName,
          at: date
        )
        await self?.reloadHistory()
      } catch is CancellationError {
        return
      } catch {
        self?.historyError = error.localizedDescription
      }
    }
  }

  private func nextHistoryTimestamp() -> Date {
    let now = Date()
    let timestamp: Date
    if let lastHistoryTimestamp,
      now.timeIntervalSince(lastHistoryTimestamp) < 0.001
    {
      timestamp = lastHistoryTimestamp.addingTimeInterval(0.001)
    } else {
      timestamp = now
    }
    lastHistoryTimestamp = timestamp
    return timestamp
  }

  private func reloadHistory() async {
    isHistoryLoading = true
    defer { isHistoryLoading = false }
    do {
      history = try await historyRepository.entries(forumName: forumName)
      hasLoadedHistory = true
      historyError = nil
    } catch is CancellationError {
      return
    } catch {
      historyError = error.localizedDescription
    }
  }

  private func invalidateSearch() {
    searchGeneration &+= 1
    searchTask?.cancel()
    searchTask = nil
  }

  private func isCurrent(
    generation: Int,
    query: String,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) -> Bool {
    generation == searchGeneration
      && query == submittedQuery
      && sort == self.sort
      && filter == self.filter
      && !Task.isCancelled
  }

  private func merge(
    _ existing: [ForumPostSearchItem],
    _ newItems: [ForumPostSearchItem]
  ) -> [ForumPostSearchItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
