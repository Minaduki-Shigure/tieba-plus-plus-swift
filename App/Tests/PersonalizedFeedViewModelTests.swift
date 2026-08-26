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
  func testHiddenContentFilterChangeDefersExactlyOneReloadUntilActivation() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.contentFilterDidChange(reloadIfActive: false)
    viewModel.contentFilterDidChange(reloadIfActive: false)
    await personalizedFeedDrainMainActor()
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1])

    viewModel.reloadDeferredContentFilterIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }
    viewModel.reloadDeferredContentFilterIfNeeded()
    await personalizedFeedDrainMainActor()
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testRowPrefetchStartsWithinLastThreeItemsOnly() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2, 3, 4, 5], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [6], page: 2, hasMore: false))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(currentItemID: 2)
    await personalizedFeedDrainMainActor()
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1])

    viewModel.loadMoreIfNeeded(currentItemID: 3)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2, 3, 4, 5, 6] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2])
    XCTAssertFalse(viewModel.hasMore)
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
  func testPaginationCrossesMappedEmptyRawNonemptyPage() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [], page: 2, hasMore: true))
    )
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 3, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }

    XCTAssertTrue(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3])
  }

  @MainActor
  func testInitialMappedEmptyScanCanContinueAfterBoundedPause() async throws {
    let service = ScriptedPersonalizedFeedService()
    for page in 1...PersonalizedFeedViewModel.maximumAutomaticMappedEmptyPages {
      await service.enqueue(
        .value(PersonalizedFeedFixtures.page(ids: [], page: page, hasMore: true))
      )
    }
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [6], page: 6, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertTrue(viewModel.hasMore)
    XCTAssertEqual(
      viewModel.loadMoreError,
      PersonalizedFeedViewModel.mappedEmptyScanPausedMessage
    )
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5])

    viewModel.loadMore()
    await personalizedFeedDrainMainActor()
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [6] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6])
    XCTAssertTrue(viewModel.hasMore)
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testRefreshMappedEmptyPauseKeepsCursorForContinuation() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    for page in 1...PersonalizedFeedViewModel.maximumAutomaticMappedEmptyPages {
      await service.enqueue(
        .value(PersonalizedFeedFixtures.page(ids: [], page: page, hasMore: true))
      )
    }
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 6, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertEqual(
      viewModel.loadMoreError,
      PersonalizedFeedViewModel.mappedEmptyScanPausedMessage
    )
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 2, 3, 4, 5])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 2, 3, 4, 5, 6])
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testLoadMoreMappedEmptyPauseBlocksAutomaticContinuation() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    for page in 2...6 {
      await service.enqueue(
        .value(PersonalizedFeedFixtures.page(ids: [], page: page, hasMore: true))
      )
    }
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [7], page: 7, hasMore: true))
    )
    let viewModel = PersonalizedFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == PersonalizedFeedViewModel.mappedEmptyScanPausedMessage
        && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6])
    viewModel.loadMore()
    await personalizedFeedDrainMainActor()
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 7] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6, 7])
    XCTAssertNil(viewModel.loadMoreError)
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

  @MainActor
  func testWaitingAndEmptyFollowedForumScopesNeverRequestFeed() async {
    let service = ScriptedPersonalizedFeedService()
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.setScope(.waitingForFollowedForumIndex, loadIfNeeded: true)
    XCTAssertEqual(viewModel.scope, .waitingForFollowedForumIndex)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.items.isEmpty)

    let emptyScope = PersonalizedFeedFixtures.followedScope(forumIDs: [])
    viewModel.setScope(emptyScope, loadIfNeeded: true)
    XCTAssertEqual(viewModel.scope, emptyScope)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertFalse(viewModel.hasMore)

    await personalizedFeedDrainMainActor()
    let requests = await service.requestSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor
  func testFollowedForumScopeWithoutAccountVaultFailsBeforeTransport() async throws {
    let service = ScriptedPersonalizedFeedService()
    let viewModel = PersonalizedFeedViewModel(service: service)

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil {
      if case .failed = viewModel.state { return true }
      return false
    }

    let requests = await service.requestSnapshot()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(viewModel.items.isEmpty)
  }

  @MainActor
  func testFollowedForumScopeMatchesStableForumIDInsteadOfName() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(
              id: 1,
              forumID: 7,
              forumName: "renamed-forum"
            ),
            PersonalizedFeedFixtures.item(
              id: 2,
              forumID: 8,
              forumName: "renamed-forum"
            ),
          ],
          page: 1,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertEqual(viewModel.items.first?.thread.forumName, "renamed-forum")
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1])
  }

  @MainActor
  func testAccountPersonaRejectsAnotherAccountsFollowedForumIndexBeforeTransport()
    async throws
  {
    let service = ScriptedPersonalizedFeedService()
    let lookup = MultiAccountSessionLookup(
      sessions: [personalizedFeedbackSession(userID: 7)]
    )
    let viewModel = PersonalizedFeedViewModel(
      service: service,
      accountSessionLookup: lookup
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [8], userID: 8),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil {
      if case .failed = viewModel.state { return true }
      return false
    }

    let requests = await service.requestSnapshot()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(viewModel.items.isEmpty)
  }

  @MainActor
  func testInitialLoadAutomaticallyCrossesFilteredPages() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 8)],
          page: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 2, forumID: 9)],
          page: 2,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(id: 3, forumID: 7),
            PersonalizedFeedFixtures.item(id: 4, forumID: 8),
          ],
          page: 3,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [3] }

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.hasMore)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3])
  }

  @MainActor
  func testLoadMoreAutomaticallyCrossesFilteredPages() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 7)],
          page: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 2, forumID: 8)],
          page: 2,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 3, forumID: 9)],
          page: 3,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 4, forumID: 7)],
          page: 4,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 4] }

    XCTAssertFalse(viewModel.hasMore)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4])
  }

  @MainActor
  func testFilteredLoadMorePausesAfterFivePagesAndRetryContinuesAtNextPage() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 7)],
          page: 1,
          hasMore: true
        )
      )
    )
    for page in 2...6 {
      await service.enqueue(
        .value(
          PersonalizedFeedFixtures.page(
            items: [PersonalizedFeedFixtures.item(id: Int64(page), forumID: 8)],
            page: page,
            hasMore: true
          )
        )
      )
    }
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 7, forumID: 7)],
          page: 7,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == PersonalizedFeedViewModel.filteredScanPausedMessage
        && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertTrue(viewModel.hasMore)
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 7] }

    XCTAssertNil(viewModel.loadMoreError)
    XCTAssertFalse(viewModel.hasMore)
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5, 6, 7])
  }

  @MainActor
  func testFilteredScanRequiresExplicitContinueAfterFiftyRawPages() async throws {
    let service = ScriptedPersonalizedFeedService()
    for page in 1...51 {
      await service.enqueue(
        .value(
          PersonalizedFeedFixtures.page(
            items: [PersonalizedFeedFixtures.item(id: Int64(page), forumID: 7)],
            page: page,
            hasMore: page < 51
          )
        )
      )
    }
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    for page in 2...50 {
      viewModel.loadMore()
      try await personalizedFeedWaitUntil {
        await service.requestCount() == page && !viewModel.isLoadingMore
      }
    }

    XCTAssertEqual(viewModel.items.map(\.id), (1...50).map(Int64.init))
    XCTAssertTrue(viewModel.hasMore)
    viewModel.loadMore()
    XCTAssertEqual(
      viewModel.loadMoreError,
      PersonalizedFeedViewModel.filteredScanPausedMessage
    )
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, Array(1...50))

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.last?.id == 51 }

    XCTAssertFalse(viewModel.hasMore)
    XCTAssertNil(viewModel.loadMoreError)
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, Array(1...51))
  }

  @MainActor
  func testFilteredScanPausesAtOneThousandRawItemIDsBeforeFifthPage() async throws {
    let service = ScriptedPersonalizedFeedService()
    for page in 1...4 {
      let firstID = Int64((page - 1) * 250 + 1)
      let items = (firstID..<(firstID + 250)).map {
        PersonalizedFeedFixtures.item(id: $0, forumID: 8)
      }
      await service.enqueue(
        .value(
          PersonalizedFeedFixtures.page(items: items, page: page, hasMore: true)
        )
      )
    }
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1_001, forumID: 7)],
          page: 5,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == PersonalizedFeedViewModel.filteredScanPausedMessage
        && !viewModel.isLoadingMore
    }

    XCTAssertTrue(viewModel.items.isEmpty)
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4])

    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1_001] }

    XCTAssertFalse(viewModel.hasMore)
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 4, 5])
  }

  @MainActor
  func testFilteredLoadMoreNetworkFailureRetriesSamePage() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 7)],
          page: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 2, forumID: 8)],
          page: 2,
          hasMore: true
        )
      )
    )
    await service.enqueue(.failure(PersonalizedFeedStubFailure(message: "network offline")))
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 3, forumID: 7)],
          page: 3,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      viewModel.loadMoreError == "network offline" && !viewModel.isLoadingMore
    }
    viewModel.retryLoadMore()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 3] }

    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2, 3, 3])
  }

  @MainActor
  func testSwitchingFromAllToFollowedClearsItemsAndRejectsLateAllResponse() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 8)],
          page: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(.suspended(401))
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 2, forumID: 7)],
          page: 1,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    let refreshTask = Task { await viewModel.refresh() }
    try await personalizedFeedWaitUntil {
      await service.requestCount() == 2 && viewModel.isRefreshing
    }

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    XCTAssertFalse(viewModel.isRefreshing)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    let resumed = await service.resume(
      id: 401,
      returning: PersonalizedFeedFixtures.page(
        items: [PersonalizedFeedFixtures.item(id: 3, forumID: 8)],
        page: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await refreshTask.value
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items.map(\.id), [2])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1, 1])
  }

  @MainActor
  func testSameForumIDsWithDifferentLeaseReloadsFeed() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 1, forumID: 7)],
          page: 1,
          hasMore: false
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 2, forumID: 7)],
          page: 1,
          hasMore: false
        )
      )
    )
    let firstRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let secondRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let firstSession = personalizedFeedbackSession(revision: firstRevision)
    let vault = PersonalizedFilterVault(sessions: [firstSession], activeUserID: firstSession.id)
    let viewModel = PersonalizedFeedViewModel(
      service: service,
      accountSessionLookup: vault,
      accountVault: vault
    )

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(
        forumIDs: [7],
        sessionRevision: firstRevision
      ),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    try await vault.upsert(personalizedFeedbackSession(revision: secondRevision))

    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(
        forumIDs: [7],
        sessionRevision: secondRevision
      ),
      loadIfNeeded: true
    )
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 1])
  }

  @MainActor
  func testLocalVisibilityDoesNotAffectForumMatchingOrRawProgress() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [
            PersonalizedFeedFixtures.item(
              id: 1,
              forumID: 7,
              localVisibility: .hidden
            ),
            PersonalizedFeedFixtures.item(
              id: 10,
              forumID: 8,
              localVisibility: .placeholder
            ),
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
            PersonalizedFeedFixtures.item(
              id: 10,
              forumID: 8,
              localVisibility: .visible
            )
          ],
          page: 2,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        PersonalizedFeedFixtures.page(
          items: [PersonalizedFeedFixtures.item(id: 11, forumID: 7)],
          page: 3,
          hasMore: false
        )
      )
    )
    let viewModel = personalizedFilteredFeedViewModel(service: service)
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(forumIDs: [7]),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.loadMore()
    try await personalizedFeedWaitUntil {
      await service.requestCount() == 2 && !viewModel.isLoadingMore
    }
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items.map(\.id), [1])
    XCTAssertEqual(viewModel.items.first?.thread.localVisibility, .hidden)
    XCTAssertTrue(viewModel.hasMore)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [1, 2])
  }

  @MainActor
  func testFeedbackSubmissionIsSingleFlightAndConfirmedSuccessSuppressesTheThread()
    async throws
  {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2], page: 1, hasMore: true))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.suspended(1)])
    let vault = PersonalizedFeedbackVault(session: personalizedFeedbackSession())
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: vault
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1, 2] }

    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1_723_456_789_012
    )
    try await personalizedFeedWaitUntil { await feedbackService.requestCount() == 1 }
    XCTAssertEqual(viewModel.feedbackSubmittingThreadIDs, [1])

    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1_723_456_789_012
    )
    await personalizedFeedDrainMainActor()
    let requestCountBeforeCompletion = await feedbackService.requestCount()
    XCTAssertEqual(requestCountBeforeCompletion, 1)

    let resumed = await feedbackService.resume(id: 1)
    XCTAssertTrue(resumed)
    try await personalizedFeedWaitUntil {
      viewModel.items.map(\.id) == [2] && viewModel.feedbackSubmittingThreadIDs.isEmpty
    }
    XCTAssertNil(viewModel.feedbackFailure)
    let requests = await feedbackService.requestSnapshot()
    XCTAssertEqual(requests.map(\.sessionID), [7])
    XCTAssertEqual(requests.first?.submission.threadID, 1)
    XCTAssertEqual(requests.first?.submission.forumID, 7)
    XCTAssertEqual(requests.first?.submission.reasons.map(\.id), [1])
  }

  @MainActor
  func testPersonaSwitchUsesExactAccountAndDiscardsThePreviousAccountResponse() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.suspended(71))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    let lookup = MultiAccountSessionLookup(
      sessions: [
        personalizedFeedbackSession(userID: 7),
        personalizedFeedbackSession(
          userID: 8,
          revision: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        ),
      ]
    )
    let viewModel = PersonalizedFeedViewModel(
      service: service,
      accountSessionLookup: lookup
    )

    viewModel.setPersona(.account(userID: 7), loadIfNeeded: true)
    try await personalizedFeedWaitUntil { await service.accountSessionIDSnapshot() == [7] }
    viewModel.setPersona(.account(userID: 8), loadIfNeeded: true)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    let resumed = await service.resume(
      id: 71,
      returning: PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.persona, .account(userID: 8))
    XCTAssertEqual(viewModel.items.map(\.id), [2])
    let accountSessionIDs = await service.accountSessionIDSnapshot()
    XCTAssertEqual(accountSessionIDs, [7, 8])
  }

  @MainActor
  func testSameAccountSessionRotationDiscardsThePreviousRevisionResponse() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.suspended(72))
    await service.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    let lookup = MultiAccountSessionLookup(
      sessions: [personalizedFeedbackSession(userID: 7)]
    )
    let viewModel = PersonalizedFeedViewModel(
      service: service,
      accountSessionLookup: lookup
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: true)
    try await personalizedFeedWaitUntil { await service.requestCount() == 1 }

    await lookup.setSession(
      personalizedFeedbackSession(
        userID: 7,
        revision: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
      )
    )
    viewModel.accountSessionDidChange(reloadIfActive: true)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }

    let resumed = await service.resume(
      id: 72,
      returning: PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await personalizedFeedDrainMainActor()

    XCTAssertEqual(viewModel.items.map(\.id), [2])
    let accountSessionIDs = await service.accountSessionIDSnapshot()
    XCTAssertEqual(accountSessionIDs, [7, 7])
  }

  @MainActor
  func testAnonymousFilteredResponseCannotPublishAfterActiveAccountChanges() async throws {
    let service = ScriptedPersonalizedFeedService()
    await service.enqueue(.suspended(73))
    let first = personalizedFeedbackSession(userID: 7)
    let second = personalizedFeedbackSession(
      userID: 8,
      revision: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    )
    let vault = PersonalizedFilterVault(sessions: [first, second], activeUserID: 7)
    let viewModel = PersonalizedFeedViewModel(
      service: service,
      accountSessionLookup: vault,
      accountVault: vault
    )
    viewModel.setScope(
      PersonalizedFeedFixtures.followedScope(
        forumIDs: [7],
        userID: 7,
        sessionRevision: first.sessionRevision
      ),
      loadIfNeeded: true
    )
    try await personalizedFeedWaitUntil { await service.requestCount() == 1 }

    try await vault.switchActive(to: 8)
    let resumed = await service.resume(
      id: 73,
      returning: PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    try await personalizedFeedWaitUntil {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertTrue(viewModel.items.isEmpty)
  }

  @MainActor
  func testAnonymousPersonaNeverFallsBackToAnAccountForFeedback() async throws {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.success])
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: PersonalizedFeedbackVault(
        session: personalizedFeedbackSession()
      )
    )
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )

    XCTAssertEqual(viewModel.feedbackFailure, .accountPersonaRequired)
    let feedbackRequestCount = await feedbackService.requestCount()
    XCTAssertEqual(feedbackRequestCount, 0)
    XCTAssertEqual(viewModel.items.map(\.id), [1])
  }

  @MainActor
  func testFeedbackCannotUseNewCredentialsForRowsLoadedByAnOlderSessionRevision()
    async throws
  {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.success])
    let lookup = MultiAccountSessionLookup(
      sessions: [personalizedFeedbackSession(userID: 7)]
    )
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: lookup
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: true)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    await lookup.setSession(
      personalizedFeedbackSession(
        userID: 7,
        revision: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
      )
    )
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { viewModel.feedbackFailure != nil }

    XCTAssertEqual(
      viewModel.feedbackFailure,
      .unavailable("推荐内容对应的账户会话已变化，请刷新后再提交反馈。")
    )
    let requestCount = await feedbackService.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(viewModel.items.map(\.id), [1])
  }

  @MainActor
  func testConfirmedFeedbackCannotBeReinsertedByLaterPagination() async throws {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: true))
    )
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1, 2], page: 2, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.success])
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: PersonalizedFeedbackVault(session: personalizedFeedbackSession())
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { viewModel.items.isEmpty }

    viewModel.reloadForContentFilterChange()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }
    XCTAssertFalse(viewModel.hasMore)
    let pageRequests = await feedService.requestSnapshot()
    XCTAssertEqual(pageRequests, [1, 1, 2])
  }

  @MainActor
  func testKnownFeedbackFailureRetainsThreadWhileUnknownOutcomeSuppressesIt() async throws {
    let knownFeed = ScriptedPersonalizedFeedService()
    await knownFeed.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let knownFeedback = ScriptedPersonalizedFeedbackService(
      stubs: [.failure(.unavailable("明确拒绝"))]
    )
    let session = personalizedFeedbackSession()
    let knownViewModel = PersonalizedFeedViewModel(
      service: knownFeed,
      feedbackService: knownFeedback,
      accountSessionLookup: PersonalizedFeedbackVault(session: session)
    )
    knownViewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    knownViewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { knownViewModel.items.map(\.id) == [1] }
    knownViewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { knownViewModel.feedbackFailure != nil }
    XCTAssertEqual(knownViewModel.items.map(\.id), [1])
    XCTAssertEqual(knownViewModel.feedbackFailure, .unavailable("明确拒绝"))

    let unknownFeed = ScriptedPersonalizedFeedService()
    await unknownFeed.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let unknownViewModel = PersonalizedFeedViewModel(
      service: unknownFeed,
      feedbackService: ScriptedPersonalizedFeedbackService(stubs: [.failure(.outcomeUnknown)]),
      accountSessionLookup: PersonalizedFeedbackVault(session: session)
    )
    unknownViewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    unknownViewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { unknownViewModel.items.map(\.id) == [1] }
    unknownViewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { unknownViewModel.feedbackFailure == .outcomeUnknown }
    XCTAssertTrue(unknownViewModel.items.isEmpty)
    XCTAssertTrue(unknownViewModel.feedbackSubmittingThreadIDs.isEmpty)
  }

  @MainActor
  func testFeedbackRequiresCurrentFullSessionAndRejectsStaleReason() async throws {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.success])
    let vault = PersonalizedFeedbackVault(session: personalizedFeedbackSession())
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: vault
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }

    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [999],
      clickTimeMilliseconds: 1
    )
    XCTAssertEqual(viewModel.feedbackFailure, .invalidSelection)
    var feedbackRequestCount = await feedbackService.requestCount()
    XCTAssertEqual(feedbackRequestCount, 0)

    viewModel.clearFeedbackFailure()
    await vault.setSession(nil)
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { viewModel.feedbackFailure == .loginRequired }
    XCTAssertEqual(viewModel.items.map(\.id), [1])
    feedbackRequestCount = await feedbackService.requestCount()
    XCTAssertEqual(feedbackRequestCount, 0)

    await vault.setSession(personalizedFeedbackSession(stoken: nil))
    viewModel.clearFeedbackFailure()
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil {
      viewModel.feedbackFailure == .fullCredentialsRequired
    }
    feedbackRequestCount = await feedbackService.requestCount()
    XCTAssertEqual(feedbackRequestCount, 0)
  }

  @MainActor
  func testLateFeedbackCompletionAfterSessionRotationCannotMutateTheFeed() async throws {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [2], page: 1, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(stubs: [.suspended(9)])
    let vault = PersonalizedFeedbackVault(session: personalizedFeedbackSession())
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: vault
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { await feedbackService.requestCount() == 1 }

    await vault.setSession(
      personalizedFeedbackSession(
        userID: 7,
        revision: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
      )
    )
    viewModel.accountSessionDidChange(reloadIfActive: false)
    XCTAssertTrue(viewModel.feedbackSubmittingThreadIDs.isEmpty)
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
    let resumed = await feedbackService.resume(id: 9)
    XCTAssertTrue(resumed)
    await personalizedFeedDrainMainActor()

    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertNil(viewModel.feedbackFailure)

    viewModel.setScope(.all, loadIfNeeded: true)
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [2] }
    let pageRequests = await feedService.requestSnapshot()
    XCTAssertEqual(pageRequests, [1, 1])
  }

  @MainActor
  func testAccountSwitchCancelsFeedbackCallerBeforeDispatch() async throws {
    let feedService = ScriptedPersonalizedFeedService()
    await feedService.enqueue(
      .value(PersonalizedFeedFixtures.page(ids: [1], page: 1, hasMore: false))
    )
    let feedbackService = ScriptedPersonalizedFeedbackService(
      stubs: [.cancellationAwareSuspended(10)]
    )
    let viewModel = PersonalizedFeedViewModel(
      service: feedService,
      feedbackService: feedbackService,
      accountSessionLookup: PersonalizedFeedbackVault(session: personalizedFeedbackSession())
    )
    viewModel.setPersona(.account(userID: 7), loadIfNeeded: false)
    viewModel.loadIfNeeded()
    try await personalizedFeedWaitUntil { viewModel.items.map(\.id) == [1] }
    viewModel.submitFeedback(
      threadID: 1,
      selectedReasonIDs: [1],
      clickTimeMilliseconds: 1
    )
    try await personalizedFeedWaitUntil { await feedbackService.requestCount() == 1 }

    viewModel.accountSessionDidChange(reloadIfActive: false)
    try await personalizedFeedWaitUntil {
      await feedbackService.cancelledRequestCount() == 1
    }

    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.feedbackSubmittingThreadIDs.isEmpty)
    XCTAssertNil(viewModel.feedbackFailure)
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
  private var accountSessionIDs: [Int64] = []
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

  func personalizedThreads(
    page: Int,
    session: StoredAccountSession
  ) async throws -> PersonalizedFeedPageData {
    accountSessionIDs.append(session.id)
    return try await personalizedThreads(page: page)
  }

  func requestCount() -> Int { requests.count }
  func requestSnapshot() -> [Int] { requests }
  func accountSessionIDSnapshot() -> [Int64] { accountSessionIDs }

  func resume(id: Int, returning value: PersonalizedFeedPageData) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }
}

private actor MultiAccountSessionLookup: AccountSessionLookup {
  private var sessions: [Int64: StoredAccountSession]

  init(sessions: [StoredAccountSession]) {
    self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
  }

  func session(userID: Int64) async throws -> StoredAccountSession? {
    sessions[userID]
  }

  func setSession(_ session: StoredAccountSession?) {
    guard let session else { return }
    sessions[session.id] = session
  }
}

private actor PersonalizedFilterVault: AccountVault, AccountSessionLookup {
  private var sessions: [Int64: StoredAccountSession]
  private var activeUserID: Int64?

  init(sessions: [StoredAccountSession], activeUserID: Int64?) {
    self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    self.activeUserID = activeUserID
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? {
    activeUserID.flatMap { sessions[$0] }
  }
  func session(userID: Int64) async throws -> StoredAccountSession? { sessions[userID] }
  func upsert(_ session: StoredAccountSession) async throws {
    sessions[session.id] = session
    activeUserID = session.id
  }
  func switchActive(to userID: Int64) async throws {
    guard sessions[userID] != nil else { throw AccountVaultError.accountNotFound }
    activeUserID = userID
  }
  func remove(userID: Int64) async throws {
    sessions.removeValue(forKey: userID)
    if activeUserID == userID { activeUserID = nil }
  }
  func removeAll() async throws {
    sessions.removeAll()
    activeUserID = nil
  }
}

private struct PersonalizedFeedbackServiceRequest: Sendable {
  let sessionID: Int64
  let submission: PersonalizedFeedbackSubmission
}

private enum ScriptedPersonalizedFeedbackStub: Sendable {
  case success
  case failure(PersonalizedFeedbackSubmissionError)
  case suspended(Int)
  case cancellationAwareSuspended(Int)
}

private actor ScriptedPersonalizedFeedbackService: PersonalizedFeedbackService {
  private var stubs: [ScriptedPersonalizedFeedbackStub]
  private var requests: [PersonalizedFeedbackServiceRequest] = []
  private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var cancelledRequestIDs = Set<Int>()

  init(stubs: [ScriptedPersonalizedFeedbackStub]) {
    self.stubs = stubs
  }

  func submitPersonalizedFeedback(
    session: StoredAccountSession,
    submission: PersonalizedFeedbackSubmission
  ) async throws {
    requests.append(
      PersonalizedFeedbackServiceRequest(sessionID: session.id, submission: submission)
    )
    guard !stubs.isEmpty else {
      throw PersonalizedFeedbackSubmissionError.unavailable("Unexpected feedback request")
    }
    switch stubs.removeFirst() {
    case .success:
      return
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      try await withCheckedThrowingContinuation { pending[identifier] = $0 }
    case .cancellationAwareSuspended(let identifier):
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { pending[identifier] = $0 }
      } onCancel: {
        Task { await self.cancelPendingRequest(id: identifier) }
      }
    }
  }

  func requestCount() -> Int { requests.count }
  func requestSnapshot() -> [PersonalizedFeedbackServiceRequest] { requests }
  func cancelledRequestCount() -> Int { cancelledRequestIDs.count }

  func resume(id: Int) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume()
    return true
  }

  private func cancelPendingRequest(id: Int) {
    cancelledRequestIDs.insert(id)
    pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}

private actor PersonalizedFeedbackVault: AccountVault, AccountSessionLookup {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? { session }
  func session(userID: Int64) async throws -> StoredAccountSession? {
    session?.id == userID ? session : nil
  }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {
    if session?.id == userID { session = nil }
  }
  func removeAll() async throws { session = nil }

  func setSession(_ session: StoredAccountSession?) {
    self.session = session
  }
}

@MainActor
private func personalizedFilteredFeedViewModel(
  service: any PersonalizedFeedService,
  sessionRevision: UUID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000100"
  )!
) -> PersonalizedFeedViewModel {
  let session = personalizedFeedbackSession(revision: sessionRevision)
  let vault = PersonalizedFilterVault(sessions: [session], activeUserID: session.id)
  return PersonalizedFeedViewModel(
    service: service,
    accountSessionLookup: vault,
    accountVault: vault
  )
}

private func personalizedFeedbackSession(
  userID: Int64 = 7,
  stoken: String? = String(repeating: "s", count: 64),
  revision: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "user-\(userID)",
    displayName: "User \(userID)",
    portrait: "portrait-\(userID)",
    bduss: String(repeating: "b", count: 192),
    stoken: stoken,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
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
    title: String? = nil,
    forumID: Int64 = 7,
    forumName: String = "swift",
    localVisibility: LocalContentVisibility = .visible
  ) -> PersonalizedFeedItem {
    PersonalizedFeedItem(
      thread: BrowseThread(
        id: id,
        forumID: forumID,
        forumName: forumName,
        title: title ?? "Thread \(id)",
        excerpt: "Excerpt \(id)",
        authorName: "Author \(id)",
        replyCount: 3,
        viewCount: 10,
        createdAt: nil,
        lastReplyAt: nil,
        contents: [.text("Content \(id)")],
        localVisibility: localVisibility
      ),
      feedbackReasons: [
        PersonalizedFeedbackReason(id: UInt32(clamping: id), title: "Reason \(id)", extra: "")
      ]
    )
  }

  static func followedScope(
    forumIDs: Set<Int64>,
    userID: Int64 = 7,
    sessionRevision: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
  ) -> PersonalizedFeedScope {
    let session = StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      sessionRevision: sessionRevision
    )
    return .followedForums(
      FollowedForumIndexSnapshot(
        lease: FollowedForumsSessionLease(session),
        forumIDs: forumIDs
      )
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
