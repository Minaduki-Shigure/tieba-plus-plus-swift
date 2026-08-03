import Combine
import Foundation

enum SearchScope: String, CaseIterable, Hashable, Identifiable, Sendable {
  case forums
  case threads
  case users

  var id: Self { self }

  var title: String {
    switch self {
    case .forums:
      "贴吧"
    case .threads:
      "帖子"
    case .users:
      "用户"
    }
  }
}

@MainActor
final class SearchViewModel: ObservableObject {
  @Published private(set) var submittedQuery: String
  @Published private(set) var selectedScope: SearchScope
  @Published private(set) var threadSort: GlobalThreadSearchSort
  @Published private(set) var exactForum: ForumSearchItem?
  @Published private(set) var relatedForums: [ForumSearchItem] = []
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var exactUser: UserSearchItem?
  @Published private(set) var relatedUsers: [UserSearchItem] = []
  @Published private(set) var forumState: LoadState = .idle
  @Published private(set) var threadState: LoadState = .idle
  @Published private(set) var userState: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var threadPaginationEpoch = 0
  @Published private var refreshErrors: [SearchScope: String] = [:]

  private let service: any SearchService
  private var currentPage = 0
  private var hasMoreThreads = true
  private var tasks: [SearchScope: Task<Void, Never>] = [:]
  private var generations: [SearchScope: Int] = [:]

  init(
    query: String,
    service: any SearchService,
    selectedScope: SearchScope = .forums,
    threadSort: GlobalThreadSearchSort = .newest
  ) {
    self.submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.service = service
    self.selectedScope = selectedScope
    self.threadSort = threadSort
  }

  var state: LoadState {
    state(for: selectedScope)
  }

  var hasResults: Bool {
    hasResults(for: selectedScope)
  }

  var refreshError: String? {
    refreshErrors[selectedScope]
  }

  var displayableThreads: [BrowseThread] {
    threads.filter { $0.localVisibility != .hidden }
  }

  var hasDisplayableThreads: Bool {
    !displayableThreads.isEmpty
  }

  func loadIfNeeded() {
    guard !submittedQuery.isEmpty else {
      submit(submittedQuery)
      return
    }
    loadIfNeeded(selectedScope)
  }

  func selectScope(_ scope: SearchScope) {
    guard selectedScope != scope else { return }
    selectedScope = scope
    loadIfNeeded(scope)
  }

  func submit(_ rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    invalidateAllLoads()
    resetAllResults()
    submittedQuery = query

    guard !query.isEmpty else {
      for scope in SearchScope.allCases {
        setState(.failed("请输入搜索关键词。"), for: scope)
      }
      return
    }
    loadIfNeeded(selectedScope)
  }

  func setThreadSort(_ sort: GlobalThreadSearchSort) {
    guard threadSort != sort else { return }
    threadSort = sort
    invalidateLoad(.threads)
    resetResults(for: .threads)
    guard !submittedQuery.isEmpty else {
      setState(.failed("请输入搜索关键词。"), for: .threads)
      return
    }
    guard selectedScope == .threads else { return }
    start(.threads, query: submittedQuery, preservingResults: false)
  }

  func retry() {
    restart(selectedScope, preservingResults: false)
  }

  func refresh() async {
    let scope = selectedScope
    restart(scope, preservingResults: hasResults(for: scope))
    await tasks[scope]?.value
  }

  func clearRefreshError() {
    refreshErrors[selectedScope] = nil
  }

  func reloadThreadsAfterContentFilterChange() {
    invalidateLoad(.threads)
    resetResults(for: .threads)
    guard !submittedQuery.isEmpty else {
      setState(.failed("请输入搜索关键词。"), for: .threads)
      return
    }
    guard selectedScope == .threads else { return }
    start(.threads, query: submittedQuery, preservingResults: false)
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      selectedScope == .threads,
      thread.id == threads.last?.id,
      hasMoreThreads,
      !isLoadingMore,
      loadMoreError == nil,
      threadState == .loaded
    else { return }
    loadMoreThreads()
  }

  func retryLoadMore() {
    guard
      hasMoreThreads,
      !isLoadingMore,
      loadMoreError != nil,
      threadState == .loaded
    else { return }
    loadMoreThreads()
  }

  func cancel() {
    let shouldAdvanceThreadPaginationEpoch =
      !threads.isEmpty && (threadState == .loading || isLoadingMore)
    invalidateAllLoads()
    isLoadingMore = false
    for scope in SearchScope.allCases where state(for: scope) == .loading {
      setState(hasResults(for: scope) ? .loaded : .idle, for: scope)
    }
    if shouldAdvanceThreadPaginationEpoch {
      threadPaginationEpoch &+= 1
    }
  }

  private func loadIfNeeded(_ scope: SearchScope) {
    guard !submittedQuery.isEmpty, state(for: scope) == .idle else { return }
    start(scope, query: submittedQuery, preservingResults: false)
  }

  private func start(
    _ scope: SearchScope,
    query: String,
    preservingResults: Bool
  ) {
    switch scope {
    case .forums:
      loadForums(query: query, preservingResults: preservingResults)
    case .threads:
      loadThreads(query: query, preservingResults: preservingResults)
    case .users:
      loadUsers(query: query, preservingResults: preservingResults)
    }
  }

  private func restart(_ scope: SearchScope, preservingResults: Bool) {
    guard !submittedQuery.isEmpty else {
      setState(.failed("请输入搜索关键词。"), for: scope)
      return
    }
    invalidateLoad(scope)
    if !preservingResults {
      resetResults(for: scope)
    }
    refreshErrors[scope] = nil
    start(scope, query: submittedQuery, preservingResults: preservingResults)
  }

  private func loadForums(query: String, preservingResults: Bool) {
    setState(.loading, for: .forums)
    let generation = nextGeneration(for: .forums)
    let service = service
    tasks[.forums] = Task {
      defer { finishTask(for: .forums, generation: generation) }
      do {
        let response = try await service.searchForums(query: query)
        try Task.checkCancellation()
        guard isCurrent(.forums, generation: generation, query: query) else { return }
        exactForum = response.exactMatch
        relatedForums = response.related
        refreshErrors[.forums] = nil
        forumState = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent(.forums, generation: generation, query: query) else { return }
        handleFailure(error, for: .forums, preservingResults: preservingResults)
      }
    }
  }

  private func loadThreads(query: String, preservingResults: Bool) {
    isLoadingMore = false
    loadMoreError = nil
    setState(.loading, for: .threads)
    let generation = nextGeneration(for: .threads)
    let sort = threadSort
    let service = service
    tasks[.threads] = Task {
      defer { finishTask(for: .threads, generation: generation) }
      do {
        let response = try await service.searchThreads(
          query: query,
          page: 1,
          pageSize: 20,
          sort: sort
        )
        try Task.checkCancellation()
        guard isCurrentThread(generation: generation, query: query, sort: sort) else { return }
        threads = merge([], response.threads)
        currentPage = max(1, response.currentPage)
        hasMoreThreads = response.hasMore && !threads.isEmpty
        refreshErrors[.threads] = nil
        threadState = .loaded
        threadPaginationEpoch &+= 1
      } catch is CancellationError {
        return
      } catch {
        guard isCurrentThread(generation: generation, query: query, sort: sort) else { return }
        handleFailure(error, for: .threads, preservingResults: preservingResults)
        if threadState == .loaded, !threads.isEmpty {
          threadPaginationEpoch &+= 1
        }
      }
    }
  }

  private func loadUsers(query: String, preservingResults: Bool) {
    setState(.loading, for: .users)
    let generation = nextGeneration(for: .users)
    let service = service
    tasks[.users] = Task {
      defer { finishTask(for: .users, generation: generation) }
      do {
        let response = try await service.searchUsers(query: query)
        try Task.checkCancellation()
        guard isCurrent(.users, generation: generation, query: query) else { return }
        exactUser = response.exactMatch
        relatedUsers = response.related
        refreshErrors[.users] = nil
        userState = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent(.users, generation: generation, query: query) else { return }
        handleFailure(error, for: .users, preservingResults: preservingResults)
      }
    }
  }

  private func loadMoreThreads() {
    let page = currentPage + 1
    let query = submittedQuery
    let sort = threadSort
    let generation = nextGeneration(for: .threads)
    let service = service
    loadMoreError = nil
    isLoadingMore = true
    tasks[.threads] = Task {
      defer {
        if generations[.threads] == generation {
          isLoadingMore = false
          tasks[.threads] = nil
        }
      }
      do {
        let response = try await service.searchThreads(
          query: query,
          page: page,
          pageSize: 20,
          sort: sort
        )
        try Task.checkCancellation()
        guard isCurrentThread(generation: generation, query: query, sort: sort) else { return }
        let merged = merge(threads, response.threads)
        let addedItems = merged.count - threads.count
        threads = merged
        currentPage = max(page, response.currentPage)
        hasMoreThreads = response.hasMore && addedItems > 0
      } catch is CancellationError {
        return
      } catch {
        guard isCurrentThread(generation: generation, query: query, sort: sort) else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func resetAllResults() {
    for scope in SearchScope.allCases {
      resetResults(for: scope)
    }
  }

  private func resetResults(for scope: SearchScope) {
    refreshErrors[scope] = nil
    switch scope {
    case .forums:
      exactForum = nil
      relatedForums = []
      forumState = .idle
    case .threads:
      threads = []
      currentPage = 0
      hasMoreThreads = true
      isLoadingMore = false
      loadMoreError = nil
      threadState = .idle
    case .users:
      exactUser = nil
      relatedUsers = []
      userState = .idle
    }
  }

  private func handleFailure(
    _ error: Error,
    for scope: SearchScope,
    preservingResults: Bool
  ) {
    if preservingResults && hasResults(for: scope) {
      refreshErrors[scope] = error.localizedDescription
      setState(.loaded, for: scope)
    } else {
      setState(.failed(error.localizedDescription), for: scope)
    }
  }

  private func state(for scope: SearchScope) -> LoadState {
    switch scope {
    case .forums:
      forumState
    case .threads:
      threadState
    case .users:
      userState
    }
  }

  private func setState(_ state: LoadState, for scope: SearchScope) {
    switch scope {
    case .forums:
      forumState = state
    case .threads:
      threadState = state
    case .users:
      userState = state
    }
  }

  private func hasResults(for scope: SearchScope) -> Bool {
    switch scope {
    case .forums:
      exactForum != nil || !relatedForums.isEmpty
    case .threads:
      !threads.isEmpty
    case .users:
      exactUser != nil || !relatedUsers.isEmpty
    }
  }

  private func nextGeneration(for scope: SearchScope) -> Int {
    let generation = (generations[scope] ?? 0) &+ 1
    generations[scope] = generation
    return generation
  }

  private func isCurrent(_ scope: SearchScope, generation: Int, query: String) -> Bool {
    generations[scope] == generation && submittedQuery == query && !Task.isCancelled
  }

  private func isCurrentThread(
    generation: Int,
    query: String,
    sort: GlobalThreadSearchSort
  ) -> Bool {
    isCurrent(.threads, generation: generation, query: query) && threadSort == sort
  }

  private func finishTask(for scope: SearchScope, generation: Int) {
    guard generations[scope] == generation else { return }
    tasks[scope] = nil
  }

  private func invalidateLoad(_ scope: SearchScope) {
    generations[scope] = (generations[scope] ?? 0) &+ 1
    tasks.removeValue(forKey: scope)?.cancel()
  }

  private func invalidateAllLoads() {
    for scope in SearchScope.allCases {
      invalidateLoad(scope)
    }
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
