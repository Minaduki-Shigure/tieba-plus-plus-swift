import Foundation
import XCTest

@testable import TiebaPlusPlus

final class HotTopicViewModelTests: XCTestCase {
  @MainActor
  func testTopicListLoadsOnceAndDeduplicates() async throws {
    let service = ScriptedHotTopicService()
    let first = HotTopicFixtures.topic(id: 1, name: "First")
    let second = HotTopicFixtures.topic(id: 2, name: "Second")
    await service.enqueueTopics(.value([first, first, second]))
    let viewModel = HotTopicListViewModel(service: service)

    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }
    viewModel.loadIfNeeded()
    await hotTopicDrainMainActor()

    XCTAssertEqual(viewModel.topics.map(\.id), [1, 2])
    let requestCount = await service.topicRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  @MainActor
  func testTopicListRefreshFailurePreservesExistingTopics() async throws {
    let service = ScriptedHotTopicService()
    let topic = HotTopicFixtures.topic(id: 1, name: "First")
    await service.enqueueTopics(.value([topic]))
    await service.enqueueTopics(.failure(HotTopicStubFailure(message: "refresh failed")))
    let viewModel = HotTopicListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.topics, [topic])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    viewModel.clearRefreshError()
    XCTAssertNil(viewModel.refreshError)
  }

  @MainActor
  func testTopicListStaleResponseCannotOverwriteRetry() async throws {
    let service = ScriptedHotTopicService()
    await service.enqueueTopics(.suspended(101))
    let viewModel = HotTopicListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { await service.topicRequestCount() == 1 }

    let fresh = HotTopicFixtures.topic(id: 2, name: "Fresh")
    await service.enqueueTopics(.value([fresh]))
    viewModel.retry()
    try await hotTopicWaitUntil { viewModel.topics == [fresh] }

    let resumed = await service.resumeTopics(
      id: 101,
      returning: [HotTopicFixtures.topic(id: 1, name: "Stale")]
    )
    XCTAssertTrue(resumed)
    await hotTopicDrainMainActor()
    XCTAssertEqual(viewModel.topics, [fresh])
  }

  @MainActor
  func testTopicDetailLoadsInitialPageAndRecordsCursorRequest() async throws {
    let service = ScriptedHotTopicService()
    let initial = HotTopicFixtures.topic(id: 7, name: "Initial")
    let updated = HotTopicFixtures.topic(id: 7, name: "Updated")
    let forum = HotTopicFixtures.forum(id: 70)
    let thread = HotTopicFixtures.thread(id: 71)
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: updated,
          relatedForums: [forum],
          threads: [thread],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 700
        )
      )
    )
    let viewModel = HotTopicDetailViewModel(topic: initial, service: service)

    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    XCTAssertTrue(viewModel.hasLoadedDetails)
    XCTAssertEqual(viewModel.topic, updated)
    XCTAssertEqual(viewModel.relatedForums, [forum])
    XCTAssertEqual(viewModel.threads, [thread])
    let requests = await service.pageRequestSnapshot()
    XCTAssertEqual(
      requests,
      [HotTopicPageRequest(id: 7, name: "Initial", page: 1, pageSize: 10, lastID: nil)]
    )
  }

  @MainActor
  func testTopicDetailPaginationDeduplicatesAndRetriesFailure() async throws {
    let service = ScriptedHotTopicService()
    let topic = HotTopicFixtures.topic(id: 7, name: "Topic")
    let first = [HotTopicFixtures.thread(id: 71), HotTopicFixtures.thread(id: 72)]
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: first,
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 720
        )
      )
    )
    await service.enqueuePage(.failure(HotTopicStubFailure(message: "page failed")))
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [HotTopicFixtures.thread(id: 72), HotTopicFixtures.thread(id: 73)],
          currentPage: 2,
          hasMore: false,
          nextPageCursor: 730
        )
      )
    )
    let viewModel = HotTopicDetailViewModel(topic: topic, service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: first[1])
    try await hotTopicWaitUntil {
      viewModel.loadMoreError == "page failed" && !viewModel.isLoadingMore
    }
    viewModel.retryLoadMore()
    try await hotTopicWaitUntil { viewModel.threads.map(\.id) == [71, 72, 73] }

    let requests = await service.pageRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
    XCTAssertEqual(requests.map(\.lastID), [nil, 720, 720])
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testTopicDetailRefreshFailurePreservesPaginationCursor() async throws {
    let service = ScriptedHotTopicService()
    let topic = HotTopicFixtures.topic(id: 7, name: "Topic")
    let first = HotTopicFixtures.thread(id: 71)
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [first],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 710
        )
      )
    )
    await service.enqueuePage(.failure(HotTopicStubFailure(message: "refresh failed")))
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [HotTopicFixtures.thread(id: 72)],
          currentPage: 2,
          hasMore: false,
          nextPageCursor: 720
        )
      )
    )
    let viewModel = HotTopicDetailViewModel(topic: topic, service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads, [first])
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    viewModel.loadMoreIfNeeded(current: first)
    try await hotTopicWaitUntil { viewModel.threads.map(\.id) == [71, 72] }
    let requests = await service.pageRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2])
    XCTAssertEqual(requests.last?.lastID, 710)
  }

  @MainActor
  func testTopicDetailDuplicateOnlyPageStopsPagination() async throws {
    let service = ScriptedHotTopicService()
    let topic = HotTopicFixtures.topic(id: 7, name: "Topic")
    let thread = HotTopicFixtures.thread(id: 71)
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [thread],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 710
        )
      )
    )
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [thread],
          currentPage: 2,
          hasMore: true,
          nextPageCursor: 720
        )
      )
    )
    let viewModel = HotTopicDetailViewModel(topic: topic, service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: thread)
    try await hotTopicWaitUntil {
      let requests = await service.pageRequestSnapshot()
      return requests.count == 2 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: thread)
    await hotTopicDrainMainActor()

    XCTAssertEqual(viewModel.threads, [thread])
    let requests = await service.pageRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testTopicDetailRefreshCancelsLoadingPageWithoutStaleWrite() async throws {
    let service = ScriptedHotTopicService()
    let topic = HotTopicFixtures.topic(id: 7, name: "Topic")
    let initial = HotTopicFixtures.thread(id: 71)
    let refreshed = HotTopicFixtures.thread(id: 81)
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [initial],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 710
        )
      )
    )
    await service.enqueuePage(.suspended(401))
    await service.enqueuePage(
      .value(
        HotTopicPageData(
          topic: topic,
          relatedForums: [],
          threads: [refreshed],
          currentPage: 1,
          hasMore: false,
          nextPageCursor: nil
        )
      )
    )
    let viewModel = HotTopicDetailViewModel(topic: topic, service: service)
    viewModel.loadIfNeeded()
    try await hotTopicWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: initial)
    try await hotTopicWaitUntil {
      let requests = await service.pageRequestSnapshot()
      return requests.count == 2 && viewModel.isLoadingMore
    }
    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads, [refreshed])
    XCTAssertFalse(viewModel.isLoadingMore)
    let resumed = await service.resumePage(
      id: 401,
      returning: HotTopicPageData(
        topic: topic,
        relatedForums: [],
        threads: [HotTopicFixtures.thread(id: 99)],
        currentPage: 2,
        hasMore: false,
        nextPageCursor: nil
      )
    )
    XCTAssertTrue(resumed)
    await hotTopicDrainMainActor()
    XCTAssertEqual(viewModel.threads, [refreshed])
    XCTAssertFalse(viewModel.isLoadingMore)
  }
}

private struct HotTopicPageRequest: Equatable, Sendable {
  let id: Int64
  let name: String
  let page: Int
  let pageSize: Int
  let lastID: Int64?
}

private struct HotTopicStubFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum HotTopicStub<Value: Sendable>: Sendable {
  case value(Value)
  case failure(HotTopicStubFailure)
  case suspended(Int)
}

private actor ScriptedHotTopicService: HotTopicService {
  private var topicStubs: [HotTopicStub<[HotTopicItem]>] = []
  private var pageStubs: [HotTopicStub<HotTopicPageData>] = []
  private var topicRequests = 0
  private var pageRequests: [HotTopicPageRequest] = []
  private var pendingTopics: [Int: CheckedContinuation<[HotTopicItem], any Error>] = [:]
  private var pendingPages: [Int: CheckedContinuation<HotTopicPageData, any Error>] = [:]

  func enqueueTopics(_ stub: HotTopicStub<[HotTopicItem]>) {
    topicStubs.append(stub)
  }

  func enqueuePage(_ stub: HotTopicStub<HotTopicPageData>) {
    pageStubs.append(stub)
  }

  func hotTopics() async throws -> [HotTopicItem] {
    topicRequests += 1
    guard !topicStubs.isEmpty else {
      throw HotTopicStubFailure(message: "Unexpected hot topic list request")
    }
    switch topicStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingTopics[identifier] = continuation
      }
    }
  }

  func hotTopic(
    id: Int64,
    name: String,
    page: Int,
    pageSize: Int,
    lastID: Int64?
  ) async throws -> HotTopicPageData {
    pageRequests.append(
      HotTopicPageRequest(id: id, name: name, page: page, pageSize: pageSize, lastID: lastID)
    )
    guard !pageStubs.isEmpty else {
      throw HotTopicStubFailure(message: "Unexpected hot topic page request")
    }
    switch pageStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingPages[identifier] = continuation
      }
    }
  }

  func resumeTopics(id: Int, returning value: [HotTopicItem]) -> Bool {
    guard let continuation = pendingTopics.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumePage(id: Int, returning value: HotTopicPageData) -> Bool {
    guard let continuation = pendingPages.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func topicRequestCount() -> Int { topicRequests }
  func pageRequestSnapshot() -> [HotTopicPageRequest] { pageRequests }
}

private enum HotTopicFixtures {
  static func topic(id: Int64, name: String) -> HotTopicItem {
    HotTopicItem(
      id: id,
      name: name,
      summary: "Summary \(name)",
      imageURL: nil,
      discussionCount: 100,
      rank: Int(clamping: id),
      tag: 0
    )
  }

  static func forum(id: Int64) -> ForumSearchItem {
    ForumSearchItem(
      id: id,
      name: "forum-\(id)",
      displayName: "Forum \(id)",
      avatarURL: nil,
      postCount: 10,
      memberCount: 20,
      summary: "Forum summary"
    )
  }

  static func thread(id: Int64) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 100,
      forumName: "forum",
      title: "Thread \(id)",
      excerpt: "Excerpt \(id)",
      authorName: "Author \(id)",
      replyCount: 3,
      viewCount: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastReplyAt: nil,
      contents: [.text("Content")]
    )
  }
}

private struct HotTopicWaitTimeout: Error {}

@MainActor
private func hotTopicWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw HotTopicWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func hotTopicDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
