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
      selectedScope: .threads
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
      selectedScope: .threads
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

  func searchThreads(query: String, page: Int, pageSize: Int) async throws
    -> ThreadSearchPageData
  {
    threadRequests.append(SearchThreadRequest(query: query, page: page, pageSize: pageSize))
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

  static func thread(id: Int64, title: String? = nil) -> BrowseThread {
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
      contents: [.text("content")]
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
