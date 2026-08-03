import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ForumPostSearchViewModelTests: XCTestCase {
  func testCoreMapperKeepsThreadAndImmediateCommentContextsSeparate() throws {
    let mainPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 100,
      title: "Opening topic",
      excerpt: "Opening content",
      authorID: 1,
      authorName: "topic author",
      authorUsername: "topic-account",
      authorPortraitURL: nil,
      replyCount: 89,
      likeCount: 12,
      shareCount: 3
    )
    let parentPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 202,
      title: "Parent floor",
      excerpt: "Parent content",
      authorID: 2,
      authorName: "parent author",
      authorUsername: "parent-account",
      authorPortraitURL: nil
    )
    let coreResult = TiebaThreadSearchResult(
      threadID: 42,
      firstPostID: 202,
      forumID: 7,
      forumName: "swift",
      title: "Nested match",
      excerpt: "Matched comment",
      authorID: 3,
      authorName: "matched author",
      authorUsername: "matched-account",
      authorPortraitURL: URL(string: "https://himg.bdimg.com/avatar.png"),
      replyCount: 8,
      likeCount: 4,
      shareCount: 2,
      createdAt: Date(timeIntervalSince1970: 100),
      images: [],
      target: .comment(postID: 202, commentID: 301),
      mainPost: mainPost,
      postInfo: parentPost
    )

    let mapped = TiebaCoreBrowseService.mapForumPostSearchResult(coreResult)

    XCTAssertEqual(mapped.id, "42:comment:202:301")
    XCTAssertEqual(mapped.target, .comment(postID: 202, commentID: 301))
    XCTAssertEqual(mapped.thread.title, "Opening topic")
    XCTAssertEqual(mapped.thread.excerpt, "Opening content")
    XCTAssertEqual(mapped.thread.authorName, "topic author")
    XCTAssertEqual(mapped.thread.authorUsername, "topic-account")
    XCTAssertEqual(mapped.thread.authorID, 1)
    XCTAssertEqual(mapped.thread.replyCount, 89)
    XCTAssertEqual(mapped.replyCount, 8)
    XCTAssertEqual(mapped.context?.postID, 202)
    XCTAssertEqual(mapped.context?.title, "Parent floor")
    XCTAssertEqual(mapped.context?.authorUsername, "parent-account")
    XCTAssertEqual(mapped.matchedTitle, "Nested match")
    XCTAssertEqual(mapped.matchedAuthorUsername, "matched-account")
    XCTAssertEqual(
      mapped.matchedAuthorPortraitURL?.absoluteString,
      "https://himg.bdimg.com/avatar.png"
    )
  }

  func testCoreMapperDoesNotPairMatchedUsernameWithContextAuthorName() {
    let mainPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 100,
      title: "Opening topic",
      excerpt: "Opening content",
      authorID: 1,
      authorName: "topic author",
      authorPortraitURL: nil
    )
    let coreResult = TiebaThreadSearchResult(
      threadID: 42,
      firstPostID: 202,
      forumID: 7,
      forumName: "swift",
      title: "Reply match",
      excerpt: "Matched reply",
      authorID: 2,
      authorName: "reply author",
      authorUsername: "reply-account",
      authorPortraitURL: nil,
      replyCount: 1,
      likeCount: 0,
      shareCount: 0,
      createdAt: nil,
      images: [],
      target: .post(postID: 202),
      mainPost: mainPost
    )

    let mapped = TiebaCoreBrowseService.mapForumPostSearchResult(coreResult)

    XCTAssertEqual(mapped.thread.authorName, "topic author")
    XCTAssertEqual(mapped.thread.authorUsername, "")
    XCTAssertEqual(mapped.matchedAuthorUsername, "reply-account")
  }

  @MainActor
  func testHistoryLoadsWithoutIssuingSearchAndSubmissionIsRecorded() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await history.seed(
      ForumSearchHistoryEntry(
        forumName: "swift",
        query: "actors",
        searchedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let result = ForumPostSearchFixtures.item(threadID: 10, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [result], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: " swift ",
      service: service,
      historyRepository: history
    )

    await viewModel.loadHistoryIfNeeded()

    XCTAssertEqual(viewModel.history.map(\.query), ["actors"])
    XCTAssertTrue(viewModel.isShowingHistory)
    let initialRequests = await service.requestSnapshot()
    XCTAssertEqual(initialRequests, [])

    viewModel.submit(" async ")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    try await forumPostSearchWaitUntil { viewModel.history.first?.query == "async" }

    XCTAssertEqual(viewModel.submittedQuery, "async")
    XCTAssertEqual(viewModel.results, [result])
    let submittedRequests = await service.requestSnapshot()
    XCTAssertEqual(
      submittedRequests,
      [
        ForumPostSearchRequest(
          query: "async",
          forumName: "swift",
          page: 1,
          pageSize: 20,
          sort: .newest,
          filter: .all
        )
      ]
    )
  }

  @MainActor
  func testExplicitHistoryResetClearsTheRepository() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await history.seed(
      ForumSearchHistoryEntry(
        forumName: "swift",
        query: "actors",
        searchedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    await viewModel.loadHistoryIfNeeded()

    await viewModel.resetHistory()

    let stored = try await history.entries(forumName: "swift")
    XCTAssertTrue(viewModel.history.isEmpty)
    XCTAssertNil(viewModel.historyError)
    XCTAssertTrue(stored.isEmpty)
  }

  @MainActor
  func testSameThreadReplyMatchesRemainDistinctAndPaginationDeduplicatesByTarget() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let topic = ForumPostSearchFixtures.item(threadID: 10, target: .thread)
    let reply = ForumPostSearchFixtures.item(threadID: 10, target: .post(101))
    let comment = ForumPostSearchFixtures.item(
      threadID: 10,
      target: .comment(postID: 101, commentID: 1_001)
    )
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [topic, reply],
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [reply, comment],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("actor")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: reply)
    try await forumPostSearchWaitUntil { viewModel.results.count == 3 }

    XCTAssertEqual(viewModel.results.map(\.id), [topic.id, reply.id, comment.id])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testOptionChangeRejectsStaleResponseAndForwardsNewOptions() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(.suspended(101))
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { await service.requestSnapshot().count == 1 }

    let relevant = ForumPostSearchFixtures.item(threadID: 20, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [relevant], currentPage: 1, hasMore: false))
    )
    viewModel.setSort(.relevance)
    try await forumPostSearchWaitUntil { viewModel.results == [relevant] }

    let stale = ForumPostSearchFixtures.item(threadID: 99, target: .thread)
    let resumed = await service.resume(
      id: 101,
      returning: ForumPostSearchPageData(results: [stale], currentPage: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.results, [relevant])
    XCTAssertEqual(viewModel.sort, .relevance)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.sort), [.newest, .relevance])
    XCTAssertEqual(requests.map(\.filter), [.all, .all])
  }

  @MainActor
  func testFilterChangeRestartsFirstPage() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [ForumPostSearchFixtures.item(threadID: 1, target: .post(11))],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let topic = ForumPostSearchFixtures.item(threadID: 2, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [topic], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    viewModel.setFilter(.threadsOnly)
    try await forumPostSearchWaitUntil { viewModel.results == [topic] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.filter), [.all, .threadsOnly])
  }

  @MainActor
  func testPaginationFailureCanRetryAndDuplicateOnlyPageStopsFurtherRequests() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 1, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(.failure(ForumPostSearchFailure(message: "page failed")))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 2, hasMore: true))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil {
      viewModel.loadMoreError == "page failed" && !viewModel.isLoadingMore
    }
    viewModel.retryLoadMore()
    try await forumPostSearchWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 3 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: first)
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.results, [first])
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  @MainActor
  func testRefreshFailurePreservesResultsAndClearsPaginationState() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 1, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(.failure(ForumPostSearchFailure(message: "refresh failed")))
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.results, [first])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testClearingQueryCancelsPendingSearchAndReturnsToHistory() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(.suspended(202))
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { await service.requestSnapshot().count == 1 }

    viewModel.clearSearch()
    XCTAssertTrue(viewModel.isShowingHistory)
    XCTAssertEqual(viewModel.state, .idle)

    let resumed = await service.resume(
      id: 202,
      returning: ForumPostSearchPageData(
        results: [ForumPostSearchFixtures.item(threadID: 99, target: .thread)],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await forumPostSearchDrainMainActor()

    XCTAssertTrue(viewModel.results.isEmpty)
    XCTAssertTrue(viewModel.isShowingHistory)
  }

  @MainActor
  func testOverlongQueryIsRejectedBeforeHistoryOrNetworkMutation() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit(String(repeating: "a", count: 101))
    viewModel.retry()
    viewModel.setSort(.relevance)
    viewModel.setFilter(.threadsOnly)
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.state, .failed("搜索关键词不能超过 100 个字符。"))
    let requests = await service.requestSnapshot()
    let historyEntries = try await history.entries(forumName: "swift")
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(historyEntries.isEmpty)
  }
}

private struct ForumPostSearchRequest: Equatable, Sendable {
  let query: String
  let forumName: String
  let page: Int
  let pageSize: Int
  let sort: ForumPostSearchSort
  let filter: ForumPostSearchFilter
}

private struct ForumPostSearchFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum ForumPostSearchStub: Sendable {
  case value(ForumPostSearchPageData)
  case failure(ForumPostSearchFailure)
  case suspended(Int)
}

private actor ScriptedForumPostSearchService: ForumPostSearchService {
  private var stubs: [ForumPostSearchStub] = []
  private var requests: [ForumPostSearchRequest] = []
  private var pending: [Int: CheckedContinuation<ForumPostSearchPageData, any Error>] = [:]

  func enqueue(_ stub: ForumPostSearchStub) {
    stubs.append(stub)
  }

  func searchForumPosts(
    query: String,
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) async throws -> ForumPostSearchPageData {
    requests.append(
      ForumPostSearchRequest(
        query: query,
        forumName: forumName,
        page: page,
        pageSize: pageSize,
        sort: sort,
        filter: filter
      )
    )
    guard !stubs.isEmpty else {
      throw ForumPostSearchFailure(message: "Unexpected search request")
    }
    switch stubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pending[identifier] = continuation
      }
    }
  }

  func requestSnapshot() -> [ForumPostSearchRequest] {
    requests
  }

  func resume(id: Int, returning value: ForumPostSearchPageData) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }
}

private actor MemoryForumSearchHistoryRepository: ForumSearchHistoryRepository {
  private var storedEntries: [ForumSearchHistoryEntry] = []

  func seed(_ entry: ForumSearchHistoryEntry) {
    storedEntries.append(entry)
  }

  func entries(forumName: String) async throws -> [ForumSearchHistoryEntry] {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    return storedEntries
      .filter {
        ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key
      }
      .sorted { $0.searchedAt > $1.searchedAt }
  }

  func record(query: String, forumName: String, at date: Date) async throws {
    let entry = ForumSearchHistoryEntry(forumName: forumName, query: query, searchedAt: date)
    storedEntries.removeAll { $0.id == entry.id }
    storedEntries.append(entry)
  }

  func delete(id: String) async throws {
    storedEntries.removeAll { $0.id == id }
  }

  func deleteAll(forumName: String) async throws {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    storedEntries.removeAll {
      ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key
    }
  }

  func reset() async throws {
    storedEntries = []
  }
}

private enum ForumPostSearchFixtures {
  static func item(
    threadID: Int64,
    target: ForumPostSearchTarget
  ) -> ForumPostSearchItem {
    ForumPostSearchItem(
      thread: BrowseThread(
        id: threadID,
        forumID: 7,
        forumName: "swift",
        title: "Thread \(threadID)",
        excerpt: "Thread excerpt",
        authorName: "thread author",
        replyCount: 3,
        viewCount: 0,
        createdAt: Date(timeIntervalSince1970: 100),
        lastReplyAt: nil,
        contents: []
      ),
      target: target,
      matchedTitle: "Match",
      matchedExcerpt: "Matched excerpt",
      matchedAuthorID: 8,
      matchedAuthorName: "matched author",
      matchedAuthorPortraitURL: nil,
      matchedAt: Date(timeIntervalSince1970: 100),
      replyCount: 3,
      likeCount: 2,
      shareCount: 1,
      matchedContents: [],
      context: nil
    )
  }
}

@MainActor
private func forumPostSearchWaitUntil(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    if Date() >= deadline {
      XCTFail("Timed out waiting for forum post search state")
      return
    }
    await Task.yield()
  }
}

@MainActor
private func forumPostSearchDrainMainActor() async {
  for _ in 0..<20 {
    await Task.yield()
  }
}
