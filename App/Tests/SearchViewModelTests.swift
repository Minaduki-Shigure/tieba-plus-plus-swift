import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SearchViewModelTests: XCTestCase {
  @MainActor
  func testInitialSearchLoadsForumsAndThreads() async throws {
    let service = ScriptedSearchService()
    let exact = SearchFixtures.forum(id: 1, name: "swift")
    let related = SearchFixtures.forum(id: 2, name: "swiftui")
    let threads = [SearchFixtures.thread(id: 11), SearchFixtures.thread(id: 12)]
    await service.enqueueForums(
      .value(ForumSearchData(exactMatch: exact, related: [related]))
    )
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: threads, currentPage: 1, hasMore: false))
    )
    let viewModel = SearchViewModel(query: " swift ", service: service)

    viewModel.loadIfNeeded()

    try await searchWaitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.submittedQuery, "swift")
    XCTAssertEqual(viewModel.exactForum, exact)
    XCTAssertEqual(viewModel.relatedForums, [related])
    XCTAssertEqual(viewModel.threads, threads)
    let forumQueries = await service.forumQuerySnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(forumQueries, ["swift"])
    XCTAssertEqual(threadRequests, [SearchThreadRequest(query: "swift", page: 1, pageSize: 20)])
  }

  @MainActor
  func testPaginationDeduplicatesAndRetriesFailedPage() async throws {
    let service = ScriptedSearchService()
    let first = [SearchFixtures.thread(id: 21), SearchFixtures.thread(id: 22)]
    await service.enqueueForums(.value(ForumSearchData(exactMatch: nil, related: [])))
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: first, currentPage: 1, hasMore: true))
    )
    await service.enqueueThreads(.failure(SearchStubFailure(message: "search page failed")))
    let viewModel = SearchViewModel(query: "swift", service: service)
    viewModel.loadIfNeeded()
    try await searchWaitUntil { viewModel.state == .loaded }

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
  func testNewSubmissionCannotBeOverwrittenByOldResponses() async throws {
    let service = ScriptedSearchService()
    await service.enqueueForums(.suspended(101))
    await service.enqueueThreads(.suspended(102))
    let viewModel = SearchViewModel(query: "old", service: service)
    viewModel.loadIfNeeded()
    try await searchWaitUntil {
      let forumCount = await service.forumRequestCount()
      let threadCount = await service.threadRequestCount()
      return forumCount == 1 && threadCount == 1
    }

    let freshForum = SearchFixtures.forum(id: 8, name: "fresh")
    let freshThread = SearchFixtures.thread(id: 81, title: "fresh")
    await service.enqueueForums(
      .value(ForumSearchData(exactMatch: freshForum, related: []))
    )
    await service.enqueueThreads(
      .value(ThreadSearchPageData(threads: [freshThread], currentPage: 1, hasMore: false))
    )
    viewModel.submit("fresh")
    try await searchWaitUntil { viewModel.threads.first?.title == "fresh" }

    let resumedForums = await service.resumeForums(
      id: 101,
      returning: ForumSearchData(
        exactMatch: SearchFixtures.forum(id: 9, name: "stale"),
        related: []
      )
    )
    let resumedThreads = await service.resumeThreads(
      id: 102,
      returning: ThreadSearchPageData(
        threads: [SearchFixtures.thread(id: 91, title: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumedForums)
    XCTAssertTrue(resumedThreads)
    await searchDrainMainActor()

    XCTAssertEqual(viewModel.submittedQuery, "fresh")
    XCTAssertEqual(viewModel.exactForum?.name, "fresh")
    XCTAssertEqual(viewModel.threads.map(\.title), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testEmptySubmissionDoesNotIssueRequests() async {
    let service = ScriptedSearchService()
    let viewModel = SearchViewModel(query: "", service: service)

    viewModel.submit("   ")

    XCTAssertEqual(viewModel.state, .failed("请输入搜索关键词。"))
    let forumCount = await service.forumRequestCount()
    let threadCount = await service.threadRequestCount()
    XCTAssertEqual(forumCount, 0)
    XCTAssertEqual(threadCount, 0)
  }
}

private struct SearchThreadRequest: Equatable, Sendable {
  let query: String
  let page: Int
  let pageSize: Int
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
  private var forumQueries: [String] = []
  private var threadRequests: [SearchThreadRequest] = []
  private var pendingForums: [Int: CheckedContinuation<ForumSearchData, any Error>] = [:]
  private var pendingThreads: [Int: CheckedContinuation<ThreadSearchPageData, any Error>] = [:]

  func enqueueForums(_ stub: SearchStub<ForumSearchData>) {
    forumStubs.append(stub)
  }

  func enqueueThreads(_ stub: SearchStub<ThreadSearchPageData>) {
    threadStubs.append(stub)
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

  func forumQuerySnapshot() -> [String] { forumQueries }
  func threadRequestSnapshot() -> [SearchThreadRequest] { threadRequests }
  func forumRequestCount() -> Int { forumQueries.count }
  func threadRequestCount() -> Int { threadRequests.count }
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
