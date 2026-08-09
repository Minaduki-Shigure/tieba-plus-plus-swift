import Foundation
import XCTest

@testable import TiebaPlusPlus

final class PersonalizedFeedViewModelTests: XCTestCase {
  @MainActor
  func testInitialLoadRequestsFirstPageOnceAndNormalizesItems() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(id: 0),
            PersonalizedFeedFixtures.item(id: 1, title: "First"),
            PersonalizedFeedFixtures.item(id: 1, title: "Duplicate"),
            PersonalizedFeedFixtures.item(id: 2),
          ],
          page: 1,
          hasMore: true
        )
      )
    )
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.state, .loading)
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }
    viewModel.loadIfNeeded()
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items.map(\.id), [1, 2])
    XCTAssertEqual(viewModel.items.first?.thread.title, "First")
    XCTAssertTrue(viewModel.hasMore)
    XCTAssertFalse(viewModel.isRefreshing)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.refreshError)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1])
  }

  @MainActor
  func testInitialPageMismatchFailsAndRetryRequestsFirstPageAgain() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [90], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil {
      viewModel.state == .failed("推荐流返回了错误的页码。")
    }

    XCTAssertTrue(viewModel.items.isEmpty)
    viewModel.retry()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testLoadMorePageMismatchPreservesSnapshotAndRetriesSamePage() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [99], page: 3, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 2, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == "推荐流返回了错误的页码。"
        && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertTrue(viewModel.hasMore)
    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }

    XCTAssertNil(viewModel.loadMoreError)
    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 2])
  }

  @MainActor
  func testPaginationDeduplicatesAndStopsAfterTwoDuplicateOnlyPages() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2, 3, 3], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 3], page: 3, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 3], page: 4, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.items.map(\.id) == [1, 2, 3] && !viewModel.isLoadingMore
    }
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 3 && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.items.map(\.id), [1, 2, 3])
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 4 && !viewModel.isLoadingMore
    }
    XCTAssertFalse(viewModel.hasMore)

    viewModel.loadMore()
    await personalizedFeedDrainMainActor()
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4])
  }

  @MainActor
  func testRefreshCanPassOneOldDuplicatePageAndReachLaterNewItems() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [3, 1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 3], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [4], page: 3, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()
    XCTAssertEqual(viewModel.items.map(\.id), [3, 1, 2])

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 3 && !viewModel.isLoadingMore
    }
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [3, 1, 2, 4] }
    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 2, 3])
  }

  @MainActor
  func testRefreshAfterSeveralPagesTraversesOldFrontierBeforeDuplicateStop() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [3], page: 3, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [4, 1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [5, 4, 1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 4, 5], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 3, 4, 5], page: 3, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [6], page: 4, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }
    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2, 3] }

    await viewModel.refresh()
    XCTAssertEqual(viewModel.items.map(\.id), [4, 1, 2, 3])
    await viewModel.refresh()
    XCTAssertEqual(viewModel.items.map(\.id), [5, 4, 1, 2, 3])

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 6 && !viewModel.isLoadingMore
    }
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 7 && !viewModel.isLoadingMore
    }
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [5, 4, 1, 2, 3, 6] }

    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 1, 1, 2, 3, 4])
  }

  @MainActor
  func testEmptyRefreshPreservesExistingPaginationState() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [], page: 1, hasMore: false))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 2, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()
    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertTrue(viewModel.hasMore)

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }
    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 2])
  }

  @MainActor
  func testRefreshPrependsNewItemsDeduplicatesAndPreservesOlderItems() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(id: 1, title: "Old one"),
            PersonalizedFeedFixtures.item(id: 2, title: "Old two"),
          ],
          page: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(id: 3, title: "New three"),
            PersonalizedFeedFixtures.item(id: 1, title: "Refreshed one"),
            PersonalizedFeedFixtures.item(id: 3, title: "Duplicate three"),
          ],
          page: 1,
          hasMore: true
        )
      )
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.items.map(\.id), [3, 1, 2])
    XCTAssertEqual(viewModel.items.map(\.thread.title), ["New three", "Refreshed one", "Old two"])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(viewModel.hasMore)
    XCTAssertFalse(viewModel.isRefreshing)
    XCTAssertNil(viewModel.refreshError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testInitialAndLoadMoreFailuresCanRetryWithoutLeakingErrorState() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.failure(PersonalizedFeedStubFailure(message: "initial failed")))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await service.enqueue(.failure(PersonalizedFeedStubFailure(message: "page failed")))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 2, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .failed("initial failed") }
    viewModel.retry()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == "page failed" && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.items.map(\.id), [1])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertNil(viewModel.refreshError)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 2, 2])
  }

  @MainActor
  func testRefreshFailurePreservesSnapshotAndCanRetryByRefreshingAgain() async throws {
    let service = ScriptedPersonalizedFeedService()
    let original = PersonalizedFeedFixtures.item(id: 1, title: "Original")
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(items: [original], page: 1, hasMore: true))
    )
    await service.enqueue(.failure(PersonalizedFeedStubFailure(message: "refresh failed")))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.items, [original])
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    XCTAssertFalse(viewModel.isRefreshing)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.items.map(\.id), [2, 1])
    XCTAssertNil(viewModel.refreshError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 1])
  }

  @MainActor
  func testLateReplacementCannotOverwriteSuccessfulRetry() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.suspended(101))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { await service.requestCount() == 1 }
    viewModel.retry()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    let resumed = await service.resume(
      id: 101,
      returning: PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true)
    )
    XCTAssertTrue(resumed)
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items.map(\.id), [2])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testCancelingInitialLoadRejectsLateResponseAndAllowsReload() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.suspended(201))
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { await service.requestCount() == 1 }
    viewModel.cancel()

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.items.isEmpty)
    let resumed = await service.resume(
      id: 201,
      returning: PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true)
    )
    XCTAssertTrue(resumed)
    await personalizedFeedDrainMainActor()
    XCTAssertTrue(viewModel.items.isEmpty)

    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testCancelingRefreshPreservesSnapshotAndRejectsLateResponse() async throws {
    let service = ScriptedPersonalizedFeedService()
    let original = PersonalizedFeedFixtures.item(id: 1)
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(items: [original], page: 1, hasMore: true))
    )
    await service.enqueue(.suspended(301))
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    let refreshTask = Task { await viewModel.refresh() }
    try await personalizedFeedWaitUntil {
      await service.requestCount() == 2 && viewModel.isRefreshing
    }
    viewModel.cancel()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.items, [original])
    XCTAssertFalse(viewModel.isRefreshing)
    let resumed = await service.resume(
      id: 301,
      returning: PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await refreshTask.value
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items, [original])
    XCTAssertTrue(viewModel.hasMore)
    XCTAssertNil(viewModel.refreshError)
  }
}

private struct PersonalizedFeedStubFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum PersonalizedFeedStub: Sendable {
  case value(PersonalizedFeedPageData)
  case failure(PersonalizedFeedStubFailure)
  case suspended(Int)
}

private actor ScriptedPersonalizedFeedService: PersonalizedFeedService {
  private var stubs: [PersonalizedFeedStub] = []
  private var requests: [Int] = []
  private var pending: [Int: CheckedContinuation<PersonalizedFeedPageData, any Error>] = [:]

  func enqueue(_ stub: PersonalizedFeedStub) {
    stubs.append(stub)
  }

  func personalizedThreads(page: Int) async throws -> PersonalizedFeedPageData {
    requests.append(page)
    guard !stubs.isEmpty else {
      throw PersonalizedFeedStubFailure(message: "Unexpected personalized-feed request")
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

  func requestCount() -> Int { requests.count }
  func requestSnapshot() -> [Int] { requests }

  func resume(id: Int, returning value: PersonalizedFeedPageData) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }
}

private enum PersonalizedFeedFixtures {
  static func page(
    ids: [Int64],
    page: Int,
    hasMore: Bool
  ) -> PersonalizedFeedPageData {
    self.page(items: ids.map { item(id: $0) }, page: page, hasMore: hasMore)
  }

  static func page(
    items: [PersonalizedFeedItem],
    page: Int,
    hasMore: Bool
  ) -> PersonalizedFeedPageData {
    PersonalizedFeedPageData(items: items, currentPage: page, hasMore: hasMore)
  }

  static func item(
    id: Int64,
    title: String? = nil
  ) -> PersonalizedFeedItem {
    PersonalizedFeedItem(
      thread: BrowseThread(
        id: id,
        forumID: 7,
        forumName: "swift",
        title: title ?? "Thread \(id)",
        excerpt: "Excerpt \(id)",
        authorName: "Author \(id)",
        replyCount: 3,
        viewCount: 10,
        createdAt: nil,
        lastReplyAt: nil,
        contents: [.text("Content \(id)")]
      ),
      feedbackReasons: [
        PersonalizedFeedbackReason(id: UInt32(clamping: id), title: "Reason \(id)", extra: "")
      ]
    )
  }
}

private struct PersonalizedFeedWaitTimeout: Error {}

@MainActor
private func personalizedFeedWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw PersonalizedFeedWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func personalizedFeedDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
