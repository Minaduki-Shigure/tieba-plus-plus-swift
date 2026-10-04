import Combine
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ForumSectionsViewModelTests: XCTestCase {
  func testPageConstructionIsLazyAndSwitchingBackRetainsIdentityAndLoadedRows() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    let latest = coordinator.currentModel
    let featured = try XCTUnwrap(coordinator.model(for: .featured))
    XCTAssertEqual(featured.state, .idle)
    XCTAssertNil(coordinator.model(for: .channel(99)))
    await drain()
    let beforeActivation = await service.requests
    XCTAssertTrue(beforeActivation.isEmpty)

    coordinator.activate()
    try await loaded(latest)
    XCTAssertEqual(
      coordinator.sections.map(\.id), [.latest, .featured, .channel(71), .channel(72)])
    let channel = try XCTUnwrap(coordinator.model(for: .channel(71)))
    await drain()
    let afterConstruction = await service.requests
    XCTAssertEqual(afterConstruction.count, 1)
    XCTAssertEqual(channel.state, .idle)
    let latestRows = latest.threads

    coordinator.select(.channel(71))
    try await loaded(channel)
    XCTAssertEqual(channel.selectedChannelSort.rawValue, 37)
    let channelRows = channel.threads
    coordinator.select(.featured)
    try await loaded(featured)
    let featuredRows = featured.threads
    for selection: ForumSectionID in [.latest, .channel(71), .featured, .featured] {
      coordinator.select(selection)
    }
    await drain()
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.section), [.latest, .channel(71), .featured])
    XCTAssertTrue(coordinator.model(for: .latest) === latest)
    XCTAssertTrue(coordinator.model(for: .featured) === featured)
    XCTAssertTrue(coordinator.model(for: .channel(71)) === channel)
    XCTAssertEqual(latest.threads, latestRows)
    XCTAssertEqual(channel.threads, channelRows)
    XCTAssertEqual(featured.threads, featuredRows)
    XCTAssertTrue(featured.options.featuredOnly)
    XCTAssertFalse(latest.options.featuredOnly)
  }

  func testFixedChannelStartsWithChannelRequestAndNeverFallsBackToLatest() async throws {
    let service = ForumSectionService()
    let channel = ForumViewModel(
      forumName: "Swift", service: service, sectionID: .channel(71),
      metadata: ForumSectionFixtures.metadata())
    channel.loadIfNeeded()
    try await loaded(channel)
    let requests = await service.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.section, .channel(71))
    XCTAssertEqual(requests.first?.forumID, 123)
    XCTAssertNil(requests.first?.cursor)

    let unavailable = ForumViewModel(
      forumName: "Swift", service: service, sectionID: .channel(999),
      metadata: ForumSectionFixtures.metadata())
    unavailable.loadIfNeeded()
    try await waitUntil { if case .failed = unavailable.state { true } else { false } }
    let finalRequests = await service.requests
    XCTAssertEqual(finalRequests.count, 1)
    XCTAssertTrue(unavailable.threads.isEmpty)
  }

  func testPaginationAndChannelCursorResumeIndependentlyAfterSwitching() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    latest.loadMoreIfNeeded(current: try XCTUnwrap(latest.threads.last))
    try await waitUntil { latest.threads.count == 4 }
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await loaded(channel)
    let originalTail = try XCTUnwrap(channel.threads.last)
    coordinator.select(.latest)
    coordinator.select(.channel(71))
    channel.loadMoreIfNeeded(current: originalTail)
    try await waitUntil { channel.threads.count == 4 }
    coordinator.select(.latest)
    XCTAssertEqual(latest.threads.count, 4)
    latest.loadMoreIfNeeded(current: try XCTUnwrap(latest.threads.last))
    await drain()
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.page), [1, 2, 1, 2])
    XCTAssertEqual(requests.map(\.section), [.latest, .latest, .channel(71), .channel(71)])
    XCTAssertEqual(requests.last?.cursor, originalTail.id)
  }

  func testFeaturedClassificationAndAllThreeSortChoicesAreIndependent() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    latest.setSort(.creationTime)
    try await loaded(latest)
    coordinator.select(.featured)
    let featured = coordinator.currentModel
    try await loaded(featured)
    featured.setFeaturedClassificationID(5)
    try await loaded(featured)
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await loaded(channel)
    channel.setChannelSort(.replyTime)
    try await loaded(channel)
    let count = await service.requests.count
    coordinator.select(.latest)
    XCTAssertEqual(latest.options.sort, .creationTime)
    XCTAssertFalse(latest.options.featuredOnly)
    XCTAssertNil(latest.options.featuredClassificationID)
    coordinator.select(.featured)
    XCTAssertTrue(featured.options.featuredOnly)
    XCTAssertEqual(featured.options.featuredClassificationID, 5)
    coordinator.select(.channel(71))
    XCTAssertEqual(channel.selectedChannelSort, .replyTime)
    await drain()
    let finalCount = await service.requests.count
    XCTAssertEqual(finalCount, count)
  }

  func testInitialFailureAndPaginationFailureSurviveSwitchUntilExplicitRetry() async throws {
    let service = ForumSectionService()
    await service.enqueue(.failure("initial failure"), for: .featured)
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    try await loaded(coordinator.currentModel)
    coordinator.select(.featured)
    let featured = coordinator.currentModel
    try await waitUntil { featured.state == .failed("initial failure") }
    coordinator.select(.latest)
    coordinator.select(.featured)
    await drain()
    XCTAssertEqual(featured.state, .failed("initial failure"))
    var requests = await service.requests
    XCTAssertEqual(requests.filter { $0.section == .featured }.count, 1)
    coordinator.reload()
    try await loaded(featured)
    await service.enqueue(.failure("page two failed"), for: .featured)
    featured.loadMoreIfNeeded(current: try XCTUnwrap(featured.threads.last))
    try await waitUntil { featured.loadMoreError == "page two failed" }
    let retainedRows = featured.threads
    coordinator.select(.latest)
    coordinator.select(.featured)
    await drain()
    XCTAssertEqual(featured.threads, retainedRows)
    XCTAssertEqual(featured.loadMoreError, "page two failed")
    featured.retryLoadMore()
    try await waitUntil { featured.threads.count == 4 }
    requests = await service.requests
    XCTAssertEqual(requests.filter { $0.section == .featured }.map(\.page), [1, 1, 2, 2])
  }

  func testContentFilterInvalidatesEveryCacheButLoadsOnlyActiveSection() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.featured)
    let featured = coordinator.currentModel
    try await loaded(featured)
    featured.setFeaturedClassificationID(5)
    try await loaded(featured)
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await loaded(channel)
    let previousCount = await service.requests.count
    coordinator.invalidateContentFilters()
    XCTAssertEqual(latest.state, .idle)
    XCTAssertTrue(latest.threads.isEmpty)
    XCTAssertEqual(featured.state, .idle)
    XCTAssertTrue(featured.threads.isEmpty)
    XCTAssertEqual(featured.options.featuredClassificationID, 5)
    try await loaded(channel)
    var requests = await service.requests
    XCTAssertEqual(requests.count, previousCount + 1)
    XCTAssertEqual(requests.last?.section, .channel(71))
    XCTAssertEqual(requests.last?.page, 1)
    XCTAssertNil(requests.last?.cursor)
    coordinator.select(.featured)
    try await loaded(featured)
    requests = await service.requests
    XCTAssertEqual(requests.last?.options?.featuredClassificationID, 5)
    XCTAssertTrue(coordinator.model(for: .featured) === featured)
    XCTAssertTrue(coordinator.model(for: .latest) === latest)
    coordinator.deactivate()
    let inactiveCount = requests.count
    coordinator.invalidateContentFilters()
    coordinator.select(.latest)
    await drain()
    let afterInactiveInvalidation = await service.requests.count
    XCTAssertEqual(afterInactiveInvalidation, inactiveCount)
    coordinator.activate()
    try await loaded(latest)
  }

  func testLateCancelledResponseCannotRestoreRowsOrObsoleteMetadata() async throws {
    let service = ForumSectionService()
    await service.enqueue(.suspended(1), for: .latest)
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await waitUntil { await service.isPending(1) }
    coordinator.select(.featured)
    try await loaded(coordinator.currentModel)
    XCTAssertEqual(latest.state, .idle)
    coordinator.select(.latest)
    try await loaded(latest)
    let currentRows = latest.threads
    let currentMetadata = coordinator.metadata
    await service.resume(
      1,
      with: .threads(
        ForumSectionFixtures.page(
          threads: [ForumSectionFixtures.thread(9999)], channels: [])))
    try await waitUntil { await service.completedCount == 3 }
    await drain()
    XCTAssertEqual(latest.threads, currentRows)
    XCTAssertEqual(coordinator.metadata, currentMetadata)
  }

  func testInvalidatingContentsRejectsOldPaginationAndReloadsOnlyVisiblePage() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await loaded(channel)
    await service.enqueue(.suspended(5), for: .channel(71))
    channel.loadMoreIfNeeded(current: try XCTUnwrap(channel.threads.last))
    try await waitUntil { await service.isPending(5) }
    coordinator.invalidateContents()
    try await loaded(channel)
    let replacementRows = channel.threads
    XCTAssertTrue(latest.threads.isEmpty)
    XCTAssertEqual(latest.state, .idle)
    await service.resume(
      5,
      with: .channel(
        ForumChannelPageData(
          threads: [ForumSectionFixtures.thread(9995)], currentPage: 2,
          hasMore: false, nextPageCursor: 9995)))
    try await waitUntil { await service.completedCount == 4 }
    await drain()
    XCTAssertEqual(channel.threads, replacementRows)
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.section), [.latest, .channel(71), .channel(71), .channel(71)])
    XCTAssertEqual(requests.map(\.page), [1, 1, 2, 1])
    XCTAssertNil(requests.last?.cursor)
  }

  func testParentDeactivationCancelsLoadsAndReturningOnlyResumesAnIdlePage() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    try await loaded(coordinator.currentModel)
    await service.enqueue(.suspended(2), for: .channel(71))
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await waitUntil { await service.isPending(2) }
    coordinator.deactivate()
    XCTAssertEqual(channel.state, .idle)
    await service.resume(
      2,
      with: .channel(
        ForumChannelPageData(
          threads: [ForumSectionFixtures.thread(9998)], currentPage: 1,
          hasMore: true, nextPageCursor: 9998)))
    try await waitUntil { await service.completedCount == 2 }
    await drain()
    XCTAssertTrue(channel.threads.isEmpty)
    XCTAssertEqual(channel.state, .idle)
    coordinator.activate()
    try await loaded(channel)
    XCTAssertFalse(channel.threads.contains { $0.id == 9998 })
    let previousCount = await service.requests.count
    coordinator.deactivate()
    coordinator.activate()
    await drain()
    let count = await service.requests.count
    XCTAssertEqual(count, previousCount)
  }

  func testCatalogReorderAndRenameKeepModelsAndFeaturedCannotEraseDirectory() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    let first = try XCTUnwrap(coordinator.model(for: .channel(71)))
    let second = try XCTUnwrap(coordinator.model(for: .channel(72)))
    let renamed = ForumSectionFixtures.channel(71, name: "更名频道")
    await service.setChannels([ForumSectionFixtures.channel(72), renamed, renamed])
    await coordinator.refresh()
    XCTAssertEqual(
      coordinator.sections.map(\.id), [.latest, .featured, .channel(72), .channel(71)])
    XCTAssertEqual(coordinator.sections.last?.title, "更名频道")
    XCTAssertTrue(coordinator.model(for: .channel(71)) === first)
    XCTAssertTrue(coordinator.model(for: .channel(72)) === second)
    let catalog = coordinator.metadata
    await service.enqueue(
      .threads(ForumSectionFixtures.page(channels: [])), for: .featured)
    coordinator.select(.featured)
    try await loaded(coordinator.currentModel)
    XCTAssertEqual(coordinator.metadata, catalog)
  }

  func testRemovingSelectedChannelFallsBackAndRejectsRemovedPageResponse() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.channel(71))
    let removed = coordinator.currentModel
    try await loaded(removed)
    await service.enqueue(.suspended(3), for: .channel(71))
    removed.loadMoreIfNeeded(current: try XCTUnwrap(removed.threads.last))
    try await waitUntil { await service.isPending(3) }
    await service.setChannels([ForumSectionFixtures.channel(72)])
    // Exercise an authoritative directory update while a different page is
    // active, without publishing separately observable forum/channel values.
    await latest.refresh()
    XCTAssertEqual(coordinator.selectedSectionID, .latest)
    XCTAssertTrue(coordinator.currentModel === latest)
    XCTAssertNil(coordinator.model(for: .channel(71)))
    let rowsBeforeCompletion = removed.threads
    await service.resume(
      3,
      with: .channel(
        ForumChannelPageData(
          threads: [ForumSectionFixtures.thread(9997)], currentPage: 2,
          hasMore: false, nextPageCursor: 9997)))
    try await waitUntil { await service.completedCount == 4 }
    await drain()
    XCTAssertEqual(removed.threads, rowsBeforeCompletion)
    XCTAssertEqual(coordinator.sections.map(\.id), [.latest, .featured, .channel(72)])
  }

  func testRemovingOtherChannelPreservesCurrentSelectionSortAndRows() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.channel(71))
    let retained = coordinator.currentModel
    try await loaded(retained)
    retained.setChannelSort(.replyTime)
    try await loaded(retained)
    let rows = retained.threads
    await service.setChannels([
      ForumSectionFixtures.channel(90), ForumSectionFixtures.channel(71, name: "更名后"),
    ])
    await latest.refresh()
    XCTAssertEqual(coordinator.selectedSectionID, .channel(71))
    XCTAssertTrue(coordinator.currentModel === retained)
    XCTAssertEqual(retained.selectedChannelSort, .replyTime)
    XCTAssertEqual(retained.threads, rows)
    XCTAssertNil(coordinator.model(for: .channel(72)))
    let added = try XCTUnwrap(coordinator.model(for: .channel(90)))
    XCTAssertEqual(added.state, .idle)
    await drain()
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.section), [.latest, .channel(71), .channel(71), .latest])
  }

  func testInvalidatedChannelSortResetsOnlyThatPageAndDoesNotLoadItWhileOffscreen() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.channel(71))
    let first = coordinator.currentModel
    try await loaded(first)
    first.setChannelSort(.replyTime)
    try await loaded(first)
    first.loadMoreIfNeeded(current: try XCTUnwrap(first.threads.last))
    try await waitUntil { first.threads.count == 4 }
    coordinator.select(.channel(72))
    let second = coordinator.currentModel
    try await loaded(second)
    let retainedSecondRows = second.threads
    coordinator.select(.latest)
    let updated = BrowseForumChannel(
      id: 71, name: "新排序菜单", isDefault: false,
      sortOptions: [BrowseForumChannelSortOption(id: 88, title: "新综合")])
    await service.setChannels([updated, ForumSectionFixtures.channel(72)])
    await coordinator.refresh()
    XCTAssertEqual(first.state, .idle)
    XCTAssertTrue(first.threads.isEmpty)
    XCTAssertEqual(first.selectedChannelSort.rawValue, 88)
    XCTAssertEqual(second.threads, retainedSecondRows)
    XCTAssertEqual(second.state, .loaded)
    let beforeSelection = await service.requests.count
    coordinator.select(.channel(71))
    try await loaded(first)
    let requests = await service.requests
    XCTAssertEqual(requests.count, beforeSelection + 1)
    XCTAssertEqual(requests.last?.channelSort, 88)
    XCTAssertEqual(requests.last?.page, 1)
    XCTAssertNil(requests.last?.cursor)
    XCTAssertTrue(coordinator.model(for: .channel(71)) === first)
  }

  func testActiveInvalidatedSortRejectsOldResponseAndLoadsOnlyNewSort() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    let latest = coordinator.currentModel
    try await loaded(latest)
    coordinator.select(.channel(71))
    let channel = coordinator.currentModel
    try await loaded(channel)
    await service.enqueue(.suspended(4), for: .channel(71))
    channel.loadMoreIfNeeded(current: try XCTUnwrap(channel.threads.last))
    try await waitUntil { await service.isPending(4) }
    let updated = BrowseForumChannel(
      id: 71, name: "新菜单", isDefault: false,
      sortOptions: [BrowseForumChannelSortOption(id: 88, title: "新排序")])
    await service.setChannels([updated, ForumSectionFixtures.channel(72)])
    await latest.refresh()
    try await loaded(channel)
    let newRows = channel.threads
    await service.resume(
      4,
      with: .channel(
        ForumChannelPageData(
          threads: [ForumSectionFixtures.thread(9996)], currentPage: 2,
          hasMore: false, nextPageCursor: 9996)))
    try await waitUntil { await service.completedCount == 5 }
    await drain()
    XCTAssertEqual(coordinator.selectedSectionID, .channel(71))
    XCTAssertEqual(channel.threads, newRows)
    let channelRequests = await service.requests.filter { $0.section == .channel(71) }
    XCTAssertEqual(channelRequests.map(\.channelSort), [37, 37, 88])
    XCTAssertEqual(channelRequests.map(\.page), [1, 2, 1])
    XCTAssertNil(channelRequests.last?.cursor)
  }

  func testAtomicMetadataSnapshotNeverPairsNewForumWithOldChannelCatalog() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    var snapshots: [ForumMetadataSnapshot] = []
    let observation = coordinator.$metadata.sink { snapshots.append($0) }
    defer { observation.cancel() }
    coordinator.activate()
    try await loaded(coordinator.currentModel)
    let replacementForum = ForumSectionFixtures.forum(id: 456, classifications: [])
    let replacementChannels = [ForumSectionFixtures.channel(90)]
    await service.enqueue(
      .threads(ForumSectionFixtures.page(forum: replacementForum, channels: replacementChannels)),
      for: .latest)
    await coordinator.refresh()
    XCTAssertEqual(snapshots.count, 3)
    XCTAssertEqual(snapshots[1].forum.id, 123)
    XCTAssertEqual(snapshots[1].channels.map(\.id), [71, 72])
    XCTAssertEqual(
      snapshots[2],
      ForumMetadataSnapshot(
        forum: replacementForum, channels: replacementChannels))
    XCTAssertEqual(coordinator.currentModel.state, .loaded)
    let requests = await service.requests
    XCTAssertEqual(requests.count, 2, "Metadata synchronization must not reread latest")
  }

  func testRemovedFeaturedClassificationInvalidatesOnlyFeaturedContents() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    try await loaded(coordinator.currentModel)
    coordinator.select(.featured)
    let featured = coordinator.currentModel
    try await loaded(featured)
    featured.setFeaturedClassificationID(5)
    try await loaded(featured)
    coordinator.select(.latest)
    await service.enqueue(
      .threads(ForumSectionFixtures.page(forum: ForumSectionFixtures.forum(classifications: []))),
      for: .latest)
    await coordinator.refresh()
    XCTAssertEqual(featured.state, .idle)
    XCTAssertNil(featured.options.featuredClassificationID)
    XCTAssertTrue(featured.options.featuredOnly)
    XCTAssertTrue(featured.threads.isEmpty)
    XCTAssertEqual(coordinator.currentModel.state, .loaded)
  }

  func testParentObservesOnlyCurrentModelAndDoesNotDropOffscreenModelObservation() async throws {
    let service = ForumSectionService()
    let coordinator = makeCoordinator(service)
    coordinator.activate()
    try await loaded(coordinator.currentModel)
    let featured = try XCTUnwrap(coordinator.model(for: .featured))
    var parentChanges = 0
    var pageChanges = 0
    let parentObservation = coordinator.objectWillChange.sink { parentChanges += 1 }
    let pageObservation = featured.objectWillChange.sink { pageChanges += 1 }
    defer {
      parentObservation.cancel()
      pageObservation.cancel()
    }
    featured.invalidateContents()
    XCTAssertEqual(parentChanges, 0)
    XCTAssertGreaterThan(pageChanges, 0)
    coordinator.select(.featured)
    try await loaded(featured)
    parentChanges = 0
    featured.invalidateContents()
    XCTAssertGreaterThan(parentChanges, 0)
  }

  private func makeCoordinator(_ service: ForumSectionService) -> ForumSectionsViewModel {
    ForumSectionsViewModel(forumName: "Swift", service: service)
  }

  private func loaded(_ model: ForumViewModel) async throws {
    try await waitUntil { model.state == .loaded }
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
      guard Date() < deadline else { throw ForumSectionTestError.timeout }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func drain() async {
    for _ in 0..<20 { await Task<Never, Never>.yield() }
  }
}

private enum ForumSectionTestError: Error {
  case timeout
  case unexpectedRequest
}

private struct ForumSectionRequest: Equatable, Sendable {
  let section: ForumSectionID
  let page: Int
  var forumID: Int64? = nil
  var options: ForumBrowseOptions? = nil
  var channelSort: Int32? = nil
  var cursor: Int64? = nil
}

private enum ForumSectionStub: Sendable {
  case threads(ThreadPageData)
  case channel(ForumChannelPageData)
  case failure(String)
  case suspended(Int)
}

private actor ForumSectionService: BrowseService {
  private(set) var requests: [ForumSectionRequest] = []
  private(set) var completedCount = 0
  private var channels = ForumSectionFixtures.metadata().channels
  private var stubs: [ForumSectionID: [ForumSectionStub]] = [:]
  private var pending: [Int: CheckedContinuation<ForumSectionStub, any Error>] = [:]

  func enqueue(_ stub: ForumSectionStub, for section: ForumSectionID) {
    stubs[section, default: []].append(stub)
  }

  func setChannels(_ channels: [BrowseForumChannel]) { self.channels = channels }
  func isPending(_ identifier: Int) -> Bool { pending[identifier] != nil }
  func resume(_ identifier: Int, with response: ForumSectionStub) {
    pending.removeValue(forKey: identifier)?.resume(returning: response)
  }

  func threads(
    forumName: String, page: Int, pageSize: Int, options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    let section: ForumSectionID = options.featuredOnly ? .featured : .latest
    requests.append(ForumSectionRequest(section: section, page: page, options: options))
    defer { completedCount += 1 }
    let start: Int64 = (options.featuredOnly ? 20_000 : 10_000) + Int64(page * 10)
    let defaultResponse = ThreadPageData(
      forum: ForumSectionFixtures.forum(),
      threads: [ForumSectionFixtures.thread(start), ForumSectionFixtures.thread(start + 1)],
      currentPage: page, hasMore: page < 2, channels: channels)
    let reply = try await response(for: section, fallback: .threads(defaultResponse))
    guard case .threads(let result) = reply else { throw ForumSectionTestError.unexpectedRequest }
    return result
  }

  func forumChannelThreads(
    forumID: Int64, forumName: String, channel: BrowseForumChannel,
    page: Int, pageSize: Int, sort: ForumChannelSort, lastThreadID: Int64?
  ) async throws -> ForumChannelPageData {
    let section = ForumSectionID.channel(channel.id)
    requests.append(
      ForumSectionRequest(
        section: section, page: page, forumID: forumID, channelSort: sort.rawValue,
        cursor: lastThreadID))
    defer { completedCount += 1 }
    let start = Int64(channel.id * 1000 + page * 10)
    let defaultResponse = ForumChannelPageData(
      threads: [ForumSectionFixtures.thread(start), ForumSectionFixtures.thread(start + 1)],
      currentPage: page, hasMore: page < 2, nextPageCursor: start + 1)
    let reply = try await response(for: section, fallback: .channel(defaultResponse))
    guard case .channel(let result) = reply else { throw ForumSectionTestError.unexpectedRequest }
    return result
  }

  private func response(for section: ForumSectionID, fallback: ForumSectionStub) async throws
    -> ForumSectionStub
  {
    var reply = stubs[section]?.isEmpty == false ? stubs[section]!.removeFirst() : fallback
    if case .suspended(let identifier) = reply {
      // Deliberately ignore cancellation so tests exercise generation rejection
      // when a transport delivers a response after its page has been cancelled.
      reply = try await withCheckedThrowingContinuation { pending[identifier] = $0 }
    }
    if case .failure(let message) = reply { throw BrowseError.unavailable(message) }
    return reply
  }

  func posts(
    threadID: Int64, page: Int, pageSize: Int,
    options: ThreadBrowseOptions, location: ThreadPostLocation?
  ) async throws -> PostPageData { throw ForumSectionTestError.unexpectedRequest }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    throw ForumSectionTestError.unexpectedRequest
  }

  func comments(
    threadID: Int64, postID: Int64, aroundCommentID: Int64, page: Int
  ) async throws -> CommentPageData { throw ForumSectionTestError.unexpectedRequest }

  func comments(threadID: Int64, resolvingCommentID: Int64) async throws -> CommentPageData {
    throw ForumSectionTestError.unexpectedRequest
  }
}

private enum ForumSectionFixtures {
  static func channel(_ id: Int, name: String? = nil) -> BrowseForumChannel {
    BrowseForumChannel(
      id: id, name: name ?? "频道\(id)", isDefault: false,
      sortOptions: [
        BrowseForumChannelSortOption(id: 37, title: "综合"),
        BrowseForumChannelSortOption(id: 0, title: "回复"),
      ])
  }

  static func forum(
    id: Int64 = 123,
    classifications: [BrowseForumClassification] = [BrowseForumClassification(id: 5, name: "精选")]
  ) -> BrowseForum {
    BrowseForum(
      id: id, name: "Swift", category: "", subcategory: "", memberCount: 1,
      threadCount: 5, postCount: 10, avatarURL: nil, slogan: "", hasModerators: false,
      hasRules: false, featuredClassifications: classifications)
  }

  static func metadata() -> ForumMetadataSnapshot {
    ForumMetadataSnapshot(forum: forum(), channels: [channel(71), channel(72)])
  }

  static func thread(_ id: Int64) -> BrowseThread {
    BrowseThread(
      id: id, forumID: 123, forumName: "Swift", title: "帖子\(id)", excerpt: "内容",
      authorName: "用户", replyCount: 0, viewCount: 0, createdAt: nil,
      lastReplyAt: nil, contents: [.text("内容")])
  }

  static func page(
    forum: BrowseForum = ForumSectionFixtures.forum(), threads: [BrowseThread] = [thread(100)],
    channels: [BrowseForumChannel] = [channel(71), channel(72)]
  ) -> ThreadPageData {
    ThreadPageData(
      forum: forum, threads: threads, currentPage: 1, hasMore: false, channels: channels)
  }
}
