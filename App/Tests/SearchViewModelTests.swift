import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SearchViewModelTests: XCTestCase {
  @MainActor
  func testInitialSearchLoadsOnlyDefaultForumScope() async throws {
    let service = ScriptedSearchService()
    let exact = SearchFixtures.forum(id: 1, name: "swift")
    let related = SearchFixtures.forum(id: 2, name: "swiftui")
    await service.enqueueForums(
      .value(ForumSearchData(exactMatch: exact, related: [related]))
    )
    let viewModel = SearchViewModel(query: " swift ", service: service)

    viewModel.loadIfNeeded()

    try await searchWaitUntil { viewModel.forumState == .loaded }
    XCTAssertEqual(viewModel.submittedQuery, "swift")
    XCTAssertEqual(viewModel.exactForum, exact)
    XCTAssertEqual(viewModel.relatedForums, [related])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(viewModel.hasResults)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 1, threads: 0, users: 0))
  }

  @MainActor
  func testScopesLoadLazilyOnceAndPreserveTheirResults() async throws {
    let service = ScriptedSearchService()
    let forum = SearchFixtures.forum(id: 1, name: "swift")
    let thread = SearchFixtures.thread(id: 11)
    let exactUser = SearchFixtures.user(id: 21, username: "swift")
    let relatedUser = SearchFixtures.user(id: 22, username: "swift-user")
    await service.enqueueForums(.value(ForumSearchData(exactMatch: forum, related: [])))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [thread], currentPage: 1, hasMore: false))
    )
    await service.enqueueUsers(
      .value(UserSearchData(exactMatch: exactUser, related: [relatedUser]))
    )
    let viewModel = SearchViewModel(query: "swift", service: service)

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.forumState == .loaded }
    viewModel.selectScope(.threads)
    try await searchWaitUntil { viewModel.threadState == .loaded }
    viewModel.selectScope(.users)
    try await searchWaitUntil { viewModel.userState == .loaded }
    viewModel.selectScope(.forums)
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.exactForum, forum)
    XCTAssertEqual(viewModel.threads, [thread])
    XCTAssertEqual(viewModel.exactUser, exactUser)
    XCTAssertEqual(viewModel.relatedUsers, [relatedUser])
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 1, threads: 1, users: 1))
  }

  @MainActor
  func testScopeFailureDoesNotDiscardAnotherScopesResults() async throws {
    let service = ScriptedSearchService()
    let forum = SearchFixtures.forum(id: 1, name: "swift")
    await service.enqueueForums(.value(ForumSearchData(exactMatch: forum, related: [])))
    await service.enqueueUsers(.failure(SearchStubFailure(message: "user search failed")))
    let viewModel = SearchViewModel(query: "swift", service: service)

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.forumState == .loaded }
    viewModel.selectScope(.users)
    try await searchWaitUntil { viewModel.userState == .failed("user search failed") }

    XCTAssertEqual(viewModel.exactForum, forum)
    viewModel.selectScope(.forums)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.exactForum, forum)
  }

  @MainActor
  func testThreadPaginationDeduplicatesAndRetriesFailedPage() async throws {
    let service = ScriptedSearchService()
    let first = [SearchFixtures.thread(id: 21), SearchFixtures.thread(id: 22)]
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: first, currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(.failure(SearchStubFailure(message: "search page failed")))
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads,
      threadSort: .relevance
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }

    viewModel.loadMoreIfNeeded(current: first[1])
    try await searchWaitUntil {
      viewModel.loadMoreError == "search page failed" && !viewModel.isLoadingMore
    }
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 22), SearchFixtures.thread(id: 23)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    viewModel.retryLoadMore()

    try await searchWaitUntil { viewModel.threads.map(\.id) == [21, 22, 23] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
    XCTAssertEqual(requests.map(\.sort), [.relevance, .relevance, .relevance])
  }

  @MainActor
  func testThreadPaginationStopsAfterDuplicateOnlyPage() async throws {
    let service = ScriptedSearchService()
    let first = [SearchFixtures.thread(id: 31), SearchFixtures.thread(id: 32)]
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: first, currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 32)],
          currentPage: 2,
          hasMore: true
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }

    viewModel.loadMoreIfNeeded(current: first[1])
    try await searchWaitUntil {
      let requests = await service.threadRequestSnapshot()
      return requests.count == 2 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: first[1])
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.threads.map(\.id), [31, 32])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testHiddenRawTailCanTriggerNextThreadPage() async throws {
    let service = ScriptedSearchService()
    let visible = SearchFixtures.thread(id: 33)
    let hiddenTail = SearchFixtures.thread(id: 34, localVisibility: .hidden)
    let next = SearchFixtures.thread(id: 35)
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [visible, hiddenTail],
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [next], currentPage: 2, hasMore: false))
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }
    viewModel.loadMoreIfNeeded(current: hiddenTail)

    try await searchWaitUntil { viewModel.threads.map(\.id) == [33, 34, 35] }
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testAllHiddenThreadPagesCanAdvanceUntilDisplayableResult() async throws {
    let service = ScriptedSearchService()
    let first = SearchFixtures.thread(id: 41, localVisibility: .hidden)
    let second = SearchFixtures.thread(id: 42, localVisibility: .hidden)
    let visible = SearchFixtures.thread(id: 43)
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [second], currentPage: 2, hasMore: true))
    )
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [visible], currentPage: 3, hasMore: false))
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }
    XCTAssertFalse(viewModel.hasDisplayableThreads)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await searchWaitUntil { viewModel.threads.map(\.id) == [41, 42] }
    XCTAssertFalse(viewModel.hasDisplayableThreads)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await searchWaitUntil { viewModel.threads.map(\.id) == [41, 42, 43] }
    XCTAssertTrue(viewModel.hasDisplayableThreads)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3])
  }

  @MainActor
  func testSameHiddenTailRefreshAdvancesPaginationEpoch() async throws {
    let service = ScriptedSearchService()
    let visible = SearchFixtures.thread(id: 51)
    let hiddenTail = SearchFixtures.thread(id: 52, localVisibility: .hidden)
    let firstPage = ThreadSearchPageData(
      threads: [visible, hiddenTail],
      currentPage: 1,
      hasMore: true
    )
    await service.enqueueThreads(.value(firstPage))
    await service.enqueueThreads(.value(firstPage))
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 53)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }
    let firstEpoch = viewModel.threadPaginationEpoch

    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads.map(\.id), [51, 52])
    XCTAssertGreaterThan(viewModel.threadPaginationEpoch, firstEpoch)
    viewModel.loadMoreIfNeeded(current: hiddenTail)
    try await searchWaitUntil { viewModel.threads.map(\.id) == [51, 52, 53] }
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2])
  }

  @MainActor
  func testThreadRefreshClearsPreviousPaginationFailure() async throws {
    let service = ScriptedSearchService()
    let initial = [SearchFixtures.thread(id: 21), SearchFixtures.thread(id: 22)]
    let refreshed = SearchFixtures.thread(id: 31)
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: initial, currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(.failure(SearchStubFailure(message: "page failed")))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [refreshed], currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 32)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads,
      threadSort: .oldest
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }

    viewModel.loadMoreIfNeeded(current: initial[1])
    try await searchWaitUntil { viewModel.loadMoreError == "page failed" }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads.map(\.id), [31])
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    viewModel.loadMoreIfNeeded(current: refreshed)
    try await searchWaitUntil { viewModel.threads.map(\.id) == [31, 32] }
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 1, 2])
    XCTAssertEqual(requests.map(\.sort), [.oldest, .oldest, .oldest, .oldest])
  }

  @MainActor
  func testThreadSortDefaultsToNewestAndReloadsOnlyThreadScope() async throws {
    let service = ScriptedSearchService()
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 61)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 62)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threads.map(\.id) == [61] }
    XCTAssertEqual(viewModel.threadSort, .newest)

    viewModel.setThreadSort(.oldest)
    try await searchWaitUntil { viewModel.threads.map(\.id) == [62] }

    XCTAssertEqual(viewModel.threadSort, .oldest)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.sort), [.newest, .oldest])
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 0, threads: 2, users: 0))
  }

  @MainActor
  func testLateThreadResponseCannotOverwriteNewSort() async throws {
    let service = ScriptedSearchService()
    await service.enqueueThreads(.suspended(501))
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 72)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )

    viewModel.loadIfNeeded()
    try await searchWaitUntil {
      let requests = await service.threadRequestSnapshot()
      return requests.count == 1
    }
    viewModel.setThreadSort(.relevance)
    try await searchWaitUntil { viewModel.threads.map(\.id) == [72] }

    let resumed = await service.resumeThreads(
      id: 501,
      returning: ThreadSearchPageData(
        threads: [SearchFixtures.thread(id: 71)],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.threadSort, .relevance)
    XCTAssertEqual(viewModel.threads.map(\.id), [72])
    XCTAssertEqual(viewModel.threadState, .loaded)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.sort), [.newest, .relevance])
  }

  @MainActor
  func testThreadSortChangeKeepsEmptyQueryFailureWithoutRequest() async {
    let service = ScriptedSearchService()
    let viewModel = SearchViewModel(
      query: "",
      service: service,
      selectedScope: .threads
    )

    viewModel.submit("   ")
    viewModel.setThreadSort(.oldest)

    XCTAssertEqual(viewModel.threadSort, .oldest)
    XCTAssertEqual(viewModel.threadState, .failed("请输入搜索关键词。"))
    XCTAssertFalse(viewModel.hasResults)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 0, threads: 0, users: 0))
  }

  @MainActor
  func testThreadRefreshCancelsLoadingPageWithoutLeavingSpinner() async throws {
    let service = ScriptedSearchService()
    let initial = SearchFixtures.thread(id: 41)
    let refreshed = SearchFixtures.thread(id: 51)
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [initial], currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(.suspended(401))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [refreshed], currentPage: 1, hasMore: false))
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threadState == .loaded }

    viewModel.loadMoreIfNeeded(current: initial)
    try await searchWaitUntil {
      let requests = await service.threadRequestSnapshot()
      return requests.count == 2 && viewModel.isLoadingMore
    }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads.map(\.id), [51])
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    let resumed = await service.resumeThreads(
      id: 401,
      returning: ThreadSearchPageData(
        threads: [SearchFixtures.thread(id: 99)],
        currentPage: 2,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await searchDrainMainActor()
    XCTAssertEqual(viewModel.threads.map(\.id), [51])
    XCTAssertFalse(viewModel.isLoadingMore)
  }

  @MainActor
  func testContentFilterChangeOutsideThreadScopeResetsOnlyThreadResults() async throws {
    let service = ScriptedSearchService()
    let forum = SearchFixtures.forum(id: 81, name: "swift")
    let thread = SearchFixtures.thread(id: 82)
    let user = SearchFixtures.user(id: 83, username: "swift-user")
    await service.enqueueForums(.value(ForumSearchData(exactMatch: forum, related: [])))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [thread], currentPage: 1, hasMore: false))
    )
    await service.enqueueUsers(.value(UserSearchData(exactMatch: user, related: [])))
    let viewModel = SearchViewModel(query: "swift", service: service)

    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.forumState == .loaded }
    viewModel.selectScope(.threads)
    try await searchWaitUntil { viewModel.threadState == .loaded }
    viewModel.selectScope(.users)
    try await searchWaitUntil { viewModel.userState == .loaded }

    viewModel.reloadThreadsAfterContentFilterChange()

    XCTAssertEqual(viewModel.selectedScope, .users)
    XCTAssertEqual(viewModel.exactForum, forum)
    XCTAssertEqual(viewModel.forumState, .loaded)
    XCTAssertEqual(viewModel.exactUser, user)
    XCTAssertEqual(viewModel.userState, .loaded)
    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.threadState, .idle)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 1, threads: 1, users: 1))
  }

  @MainActor
  func testContentFilterChangeReloadsCurrentThreadScopeFromFirstPage() async throws {
    let service = ScriptedSearchService()
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 91)],
          currentPage: 4,
          hasMore: true
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadSearchPageData(
          threads: [SearchFixtures.thread(id: 92, localVisibility: .placeholder)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads,
      threadSort: .relevance
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threads.map(\.id) == [91] }

    viewModel.reloadThreadsAfterContentFilterChange()

    try await searchWaitUntil { viewModel.threads.map(\.id) == [92] }
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertTrue(viewModel.hasDisplayableThreads)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.sort), [.relevance, .relevance])
  }

  @MainActor
  func testContentFilterChangeSupersedesRefreshAndIgnoresItsLateResponse() async throws {
    let service = ScriptedSearchService()
    let initial = SearchFixtures.thread(id: 101)
    let filtered = SearchFixtures.thread(id: 102, localVisibility: .hidden)
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [initial], currentPage: 1, hasMore: false))
    )
    await service.enqueueThreads(.suspended(601))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [filtered], currentPage: 1, hasMore: false))
    )
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .threads
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.threads == [initial] }

    let refreshTask = Task { @MainActor in await viewModel.refresh() }
    try await searchWaitUntil {
      let requests = await service.threadRequestSnapshot()
      return requests.count == 2 && viewModel.threadState == .loading
    }
    XCTAssertEqual(viewModel.threads, [initial])

    viewModel.reloadThreadsAfterContentFilterChange()
    XCTAssertTrue(viewModel.threads.isEmpty)
    try await searchWaitUntil { viewModel.threads == [filtered] }
    XCTAssertFalse(viewModel.hasDisplayableThreads)

    let resumed = await service.resumeThreads(
      id: 601,
      returning: ThreadSearchPageData(
        threads: [SearchFixtures.thread(id: 103)],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await refreshTask.value
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.threads, [filtered])
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertNil(viewModel.refreshError)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 1])
  }

  @MainActor
  func testContentFilterChangeKeepsEmptyThreadQueryFailureWithoutRequest() async {
    let service = ScriptedSearchService()
    let viewModel = SearchViewModel(query: "", service: service)
    viewModel.submit("   ")
    viewModel.selectScope(.users)

    viewModel.reloadThreadsAfterContentFilterChange()

    XCTAssertEqual(viewModel.threadState, .failed("请输入搜索关键词。"))
    XCTAssertEqual(viewModel.userState, .failed("请输入搜索关键词。"))
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 0, threads: 0, users: 0))
  }

  @MainActor
  func testNewSubmissionCannotBeOverwrittenByOldResponse() async throws {
    let service = ScriptedSearchService()
    await service.enqueueForums(.suspended(101))
    let viewModel = SearchViewModel(query: "old", service: service)
    viewModel.loadIfNeeded()
    try await searchWaitUntil { await service.forumRequestCount() == 1 }

    let freshForum = SearchFixtures.forum(id: 8, name: "fresh")
    await service.enqueueForums(
      .value(ForumSearchData(exactMatch: freshForum, related: []))
    )
    viewModel.submit("fresh")
    try await searchWaitUntil { viewModel.exactForum?.name == "fresh" }

    let resumed = await service.resumeForums(
      id: 101,
      returning: ForumSearchData(
        exactMatch: SearchFixtures.forum(id: 9, name: "stale"),
        related: []
      )
    )
    XCTAssertTrue(resumed)
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.submittedQuery, "fresh")
    XCTAssertEqual(viewModel.exactForum?.name, "fresh")
    XCTAssertEqual(viewModel.forumState, .loaded)
  }

  @MainActor
  func testEmptySubmissionCancelsPendingResponse() async throws {
    let service = ScriptedSearchService()
    await service.enqueueForums(.suspended(201))
    let viewModel = SearchViewModel(query: "old", service: service)
    viewModel.loadIfNeeded()
    try await searchWaitUntil { await service.forumRequestCount() == 1 }

    viewModel.submit("   ")
    XCTAssertEqual(viewModel.submittedQuery, "")
    XCTAssertEqual(viewModel.state, .failed("请输入搜索关键词。"))

    let resumed = await service.resumeForums(
      id: 201,
      returning: ForumSearchData(
        exactMatch: SearchFixtures.forum(id: 9, name: "stale"),
        related: []
      )
    )
    XCTAssertTrue(resumed)
    await searchDrainMainActor()

    XCTAssertNil(viewModel.exactForum)
    XCTAssertEqual(viewModel.state, .failed("请输入搜索关键词。"))
    for scope in SearchScope.allCases {
      viewModel.selectScope(scope)
      XCTAssertEqual(viewModel.state, .failed("请输入搜索关键词。"))
    }
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 1, threads: 0, users: 0))
  }

  @MainActor
  func testUserRefreshFailurePreservesExistingResults() async throws {
    let service = ScriptedSearchService()
    let user = SearchFixtures.user(id: 17_596_400_272_242, username: "large-uid")
    await service.enqueueUsers(.value(UserSearchData(exactMatch: user, related: [])))
    await service.enqueueUsers(.failure(SearchStubFailure(message: "refresh failed")))
    let viewModel = SearchViewModel(
      query: "swift",
      service: service,
      selectedScope: .users
    )
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.userState == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.exactUser, user)
    XCTAssertEqual(viewModel.userState, .loaded)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    viewModel.clearRefreshError()
    XCTAssertNil(viewModel.refreshError)
  }

  @MainActor
  func testEmptyInitialSubmissionDoesNotIssueRequests() async {
    let service = ScriptedSearchService()
    let viewModel = SearchViewModel(query: "", service: service)

    viewModel.submit("   ")

    XCTAssertEqual(viewModel.state, .failed("请输入搜索关键词。"))
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, SearchRequestCounts(forums: 0, threads: 0, users: 0))
  }
}

private struct SearchThreadRequest: Equatable, Sendable {
  let query: String
  let page: Int
  let pageSize: Int
  let sort: GlobalThreadSearchSort
}

private struct SearchRequestCounts: Equatable, Sendable {
  let forums: Int
  let threads: Int
  let users: Int
}

private struct SearchStubFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum SearchStub<Value: Sendable>: Sendable {
  case value(Value)
  case failure(SearchStubFailure)
  case suspended(Int)
}

private actor ScriptedSearchService: SearchService {
  private var forumStubs: [SearchStub<ForumSearchData>] = []
  private var threadStubs: [SearchStub<ThreadSearchPageData>] = []
  private var userStubs: [SearchStub<UserSearchData>] = []
  private var forumQueries: [String] = []
  private var threadRequests: [SearchThreadRequest] = []
  private var userQueries: [String] = []
  private var pendingForums: [Int: CheckedContinuation<ForumSearchData, any Error>] = [:]
  private var pendingThreads: [Int: CheckedContinuation<ThreadSearchPageData, any Error>] = [:]
  private var pendingUsers: [Int: CheckedContinuation<UserSearchData, any Error>] = [:]

  func enqueueForums(_ stub: SearchStub<ForumSearchData>) {
    forumStubs.append(stub)
  }

  func enqueueThreads(_ stub: SearchStub<ThreadSearchPageData>) {
    threadStubs.append(stub)
  }

  func enqueueUsers(_ stub: SearchStub<UserSearchData>) {
    userStubs.append(stub)
  }

  func searchForums(query: String) async throws -> ForumSearchData {
    forumQueries.append(query)
    guard !forumStubs.isEmpty else {
      throw SearchStubFailure(message: "Unexpected forum search")
    }
    switch forumStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingForums[identifier] = continuation
      }
    }
  }

  func searchThreads(
    query: String,
    page: Int,
    pageSize: Int,
    sort: GlobalThreadSearchSort
  ) async throws
    -> ThreadSearchPageData
  {
    threadRequests.append(
      SearchThreadRequest(query: query, page: page, pageSize: pageSize, sort: sort)
    )
    guard !threadStubs.isEmpty else {
      throw SearchStubFailure(message: "Unexpected thread search")
    }
    switch threadStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingThreads[identifier] = continuation
      }
    }
  }

  func searchUsers(query: String) async throws -> UserSearchData {
    userQueries.append(query)
    guard !userStubs.isEmpty else {
      throw SearchStubFailure(message: "Unexpected user search")
    }
    switch userStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingUsers[identifier] = continuation
      }
    }
  }

  func resumeForums(id: Int, returning value: ForumSearchData) -> Bool {
    guard let continuation = pendingForums.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumeThreads(id: Int, returning value: ThreadSearchPageData) -> Bool {
    guard let continuation = pendingThreads.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumeUsers(id: Int, returning value: UserSearchData) -> Bool {
    guard let continuation = pendingUsers.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func requestCounts() -> SearchRequestCounts {
    SearchRequestCounts(
      forums: forumQueries.count,
      threads: threadRequests.count,
      users: userQueries.count
    )
  }

  func threadRequestSnapshot() -> [SearchThreadRequest] { threadRequests }
  func forumRequestCount() -> Int { forumQueries.count }
}

private enum SearchFixtures {
  static func forum(id: Int64, name: String) -> ForumSearchItem {
    ForumSearchItem(
      id: id,
      name: name,
      displayName: name,
      avatarURL: nil,
      postCount: 10,
      memberCount: 20,
      summary: "summary"
    )
  }

  static func thread(
    id: Int64,
    title: String? = nil,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 100,
      forumName: "swift",
      title: title ?? "thread-\(id)",
      excerpt: "excerpt-\(id)",
      authorName: "author-\(id)",
      replyCount: 3,
      viewCount: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastReplyAt: nil,
      contents: [.text("content")],
      localVisibility: localVisibility
    )
  }

  static func user(id: Int64, username: String) -> UserSearchItem {
    UserSearchItem(
      id: id,
      username: username,
      displayName: "Display \(username)",
      portraitURL: nil,
      introduction: "Introduction \(username)"
    )
  }
}

private struct SearchWaitTimeout: Error {}

@MainActor
private func searchWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw SearchWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func searchDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
