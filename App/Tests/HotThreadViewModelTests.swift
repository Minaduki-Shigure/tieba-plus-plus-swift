import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class HotThreadViewModelTests: XCTestCase {
  @MainActor
  func testInitialAllLoadsOnceAndBoundsServerCategoriesWithFirstCodeWinning() async throws {
    let service = ScriptedHotThreadService()
    let future = HotThreadFixtures.category(serverID: 37, code: "future-37", title: " Future ")
    let boundedCategories = (0..<25).map {
      HotThreadFixtures.category(serverID: Int32($0), code: "category-\($0)", title: "分类 \($0)")
    }
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(
          categories: [
            HotThreadFixtures.category(serverID: 99, code: "all", title: "服务端总榜"),
            future,
            HotThreadFixtures.category(serverID: 38, code: future.code, title: "重复"),
            HotThreadFixtures.category(serverID: 39, code: "", title: "空键"),
            HotThreadFixtures.category(serverID: 40, code: " padded", title: "空格键"),
            HotThreadFixtures.category(
              serverID: 41,
              code: String(repeating: "x", count: 65),
              title: "过长键"
            ),
            HotThreadFixtures.category(serverID: 42, code: "empty-title", title: "   "),
          ] + boundedCategories,
          items: [
            HotThreadFixtures.item(id: 1, rank: 1),
            HotThreadFixtures.item(id: 1, rank: 2),
          ] + (2...110).map { HotThreadFixtures.item(id: Int64($0), rank: $0) }
        )
      )
    )
    let viewModel = HotThreadListViewModel(service: service)

    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }
    viewModel.loadIfNeeded()
    await hotThreadDrainMainActor()

    XCTAssertTrue(viewModel.hasLoadedInitialSnapshot)
    XCTAssertEqual(viewModel.categories.first, .all)
    XCTAssertEqual(viewModel.categories.count, 21)
    XCTAssertEqual(viewModel.categories[1], HotThreadFixtures.category(
      serverID: future.serverID,
      code: future.code,
      title: "Future"
    ))
    XCTAssertEqual(viewModel.categories.last?.code, "category-18")
    XCTAssertEqual(viewModel.items.count, 100)
    XCTAssertEqual(viewModel.items.first?.id, 1)
    XCTAssertEqual(viewModel.items.last?.id, 100)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all"])
  }

  @MainActor
  func testUnknownAdvertisedCategoryIsForwardedAndReplacesTheRanking() async throws {
    let service = ScriptedHotThreadService()
    let unknown = HotThreadFixtures.category(serverID: 37, code: "future-37", title: "未知分类")
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(
          categories: [unknown],
          items: [HotThreadFixtures.item(id: 1, rank: 1)]
        )
      )
    )
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 2, rank: 9)])
      )
    )
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }

    viewModel.selectCategory(unknown)
    XCTAssertTrue(viewModel.items.isEmpty)
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }

    XCTAssertEqual(viewModel.selectedCategory, unknown)
    XCTAssertEqual(viewModel.items.map(\.rank), [9])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "future-37"])
  }

  @MainActor
  func testEmptyInitialSuccessIsLoadedAndCanRefresh() async throws {
    let service = ScriptedHotThreadService()
    await service.enqueue(.value(HotThreadFixtures.feed()))
    await service.enqueue(.suspended(301))
    let viewModel = HotThreadListViewModel(service: service)

    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }
    XCTAssertTrue(viewModel.hasLoadedInitialSnapshot)
    XCTAssertTrue(viewModel.items.isEmpty)

    let refreshTask = Task { await viewModel.refresh() }
    try await hotThreadWaitUntil { await service.requestCount() == 2 }
    viewModel.cancel()
    XCTAssertEqual(viewModel.state, .idle)
    let resumed = await service.resume(
      id: 301,
      returning: HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 1)])
    )
    XCTAssertTrue(resumed)
    await refreshTask.value
    await hotThreadDrainMainActor()

    XCTAssertTrue(viewModel.items.isEmpty)
    await service.enqueue(
      .value(HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 2)]))
    )
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }

    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "all", "all"])
  }

  @MainActor
  func testInitialFailureCanRetryCurrentCategory() async throws {
    let service = ScriptedHotThreadService()
    await service.enqueue(.failure(HotThreadStubFailure(message: "initial failed")))
    await service.enqueue(
      .value(HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 2)]))
    )
    let viewModel = HotThreadListViewModel(service: service)

    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .failed("initial failed") }
    XCTAssertFalse(viewModel.hasLoadedInitialSnapshot)

    viewModel.retry()
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }

    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "all"])
  }

  @MainActor
  func testSameAndUnadvertisedCategoriesDoNotRequest() async throws {
    let service = ScriptedHotThreadService()
    let sports = HotThreadFixtures.category(serverID: 2, code: "sports", title: "体育")
    await service.enqueue(.value(HotThreadFixtures.feed(categories: [sports])))
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }

    viewModel.selectCategory(.all)
    viewModel.selectCategory(
      HotThreadFixtures.category(serverID: 999, code: "not-advertised", title: "伪造")
    )
    await hotThreadDrainMainActor()

    XCTAssertEqual(viewModel.selectedCategory, .all)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all"])
  }

  @MainActor
  func testRapidCategoryChangeRejectsLateResponse() async throws {
    let service = ScriptedHotThreadService()
    let first = HotThreadFixtures.category(serverID: 1, code: "first", title: "第一类")
    let second = HotThreadFixtures.category(serverID: 2, code: "second", title: "第二类")
    await service.enqueue(.value(HotThreadFixtures.feed(categories: [first, second])))
    await service.enqueue(.suspended(101))
    await service.enqueue(
      .value(HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 20)]))
    )
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }

    viewModel.selectCategory(first)
    try await hotThreadWaitUntil { await service.requestCount() == 2 }
    viewModel.selectCategory(second)
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [20] }

    let resumed = await service.resume(
      id: 101,
      returning: HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 10)])
    )
    XCTAssertTrue(resumed)
    await hotThreadDrainMainActor()

    XCTAssertEqual(viewModel.selectedCategory, second)
    XCTAssertEqual(viewModel.items.map(\.id), [20])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "first", "second"])
  }

  @MainActor
  func testCategoryFailureKeepsTabsAndRetriesThatCategory() async throws {
    let service = ScriptedHotThreadService()
    let sports = HotThreadFixtures.category(serverID: 2, code: "sports", title: "体育")
    await service.enqueue(.value(HotThreadFixtures.feed(categories: [sports])))
    await service.enqueue(.failure(HotThreadStubFailure(message: "category failed")))
    await service.enqueue(
      .value(HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 2)]))
    )
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }
    let originalCategories = viewModel.categories

    viewModel.selectCategory(sports)
    try await hotThreadWaitUntil { viewModel.state == .failed("category failed") }

    XCTAssertEqual(viewModel.categories, originalCategories)
    XCTAssertEqual(viewModel.selectedCategory, sports)
    XCTAssertTrue(viewModel.items.isEmpty)
    viewModel.retry()
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }

    XCTAssertEqual(viewModel.categories, originalCategories)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "sports", "sports"])
  }

  @MainActor
  func testRefreshUsesCurrentCategoryAndPreservesSnapshotOnFailure() async throws {
    let service = ScriptedHotThreadService()
    let sports = HotThreadFixtures.category(serverID: 2, code: "sports", title: "体育")
    let ignored = HotThreadFixtures.category(serverID: 3, code: "ignored", title: "不得覆盖")
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(
          categories: [sports],
          items: [HotThreadFixtures.item(id: 1)]
        )
      )
    )
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(
          categories: [ignored],
          items: [HotThreadFixtures.item(id: 2)]
        )
      )
    )
    await service.enqueue(
      .value(
        HotThreadFixtures.feed(
          categories: [ignored],
          items: [HotThreadFixtures.item(id: 3)]
        )
      )
    )
    await service.enqueue(.failure(HotThreadStubFailure(message: "refresh failed")))
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }
    let originalCategories = viewModel.categories

    viewModel.selectCategory(sports)
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }
    XCTAssertEqual(viewModel.categories, originalCategories)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.items.map(\.id), [3])
    XCTAssertEqual(viewModel.categories, originalCategories)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.items.map(\.id), [3])
    XCTAssertEqual(viewModel.categories, originalCategories)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    viewModel.clearRefreshError()
    XCTAssertNil(viewModel.refreshError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "sports", "sports", "sports"])
  }

  @MainActor
  func testAllRefreshUpdatesAdvertisedCategories() async throws {
    let service = ScriptedHotThreadService()
    let old = HotThreadFixtures.category(serverID: 1, code: "old", title: "旧分类")
    let fresh = HotThreadFixtures.category(serverID: 2, code: "fresh", title: "新分类")
    await service.enqueue(.value(HotThreadFixtures.feed(categories: [old])))
    await service.enqueue(.value(HotThreadFixtures.feed(categories: [fresh])))
    let viewModel = HotThreadListViewModel(service: service)
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.categories, [.all, fresh])
    XCTAssertEqual(viewModel.selectedCategory, .all)
  }

  @MainActor
  func testCancelRejectsLateResponseAndAllowsReload() async throws {
    let service = ScriptedHotThreadService()
    await service.enqueue(.suspended(201))
    let viewModel = HotThreadListViewModel(service: service)

    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { await service.requestCount() == 1 }
    viewModel.cancel()
    XCTAssertEqual(viewModel.state, .idle)
    let resumed = await service.resume(
      id: 201,
      returning: HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 1)])
    )
    XCTAssertTrue(resumed)
    await hotThreadDrainMainActor()
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertFalse(viewModel.hasLoadedInitialSnapshot)

    await service.enqueue(
      .value(HotThreadFixtures.feed(items: [HotThreadFixtures.item(id: 2)]))
    )
    viewModel.loadIfNeeded()
    try await hotThreadWaitUntil { viewModel.items.map(\.id) == [2] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["all", "all"])
  }

  func testCoreAdapterPreservesUnknownCategoryRankAndAppliesBoundsAndFilter() {
    let category = TiebaHotThreadCategory(serverID: 37, code: "future-37", title: "未知分类")
    let mappedCategory = TiebaCoreBrowseService.mapHotThreadCategory(category)
    XCTAssertEqual(
      mappedCategory,
      HotThreadCategory(serverID: 37, code: "future-37", title: "未知分类")
    )

    let coreThread = TiebaThread(
      id: 42,
      firstPostID: 43,
      forumID: 7,
      forumName: "swift",
      title: "blocked ranking thread",
      content: TiebaContent(fragments: [.text("body")]),
      author: nil,
      kind: .article,
      tabID: 0,
      viewCount: 10,
      replyCount: 3,
      shareCount: 2,
      agreeCount: 4,
      disagreeCount: 1,
      createdAt: nil,
      lastReplyAt: nil,
      isPinned: false,
      isFeatured: false,
      isShared: false,
      isHidden: false,
      isLive: false
    )
    let filter = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked", list: .block)]
    )

    let mappedItem = TiebaCoreBrowseService.mapHotThreadRankItem(
      TiebaHotThreadRankItem(rank: 9, hotScore: -100, thread: coreThread),
      applying: filter
    )

    XCTAssertEqual(mappedItem.rank, 9)
    XCTAssertEqual(mappedItem.hotScore, 0)
    XCTAssertEqual(mappedItem.thread.id, 42)
    XCTAssertEqual(mappedItem.thread.localVisibility, .placeholder)
  }
}

private struct HotThreadStubFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum HotThreadStub: Sendable {
  case value(HotThreadFeedData)
  case failure(HotThreadStubFailure)
  case suspended(Int)
}

private actor ScriptedHotThreadService: HotThreadService {
  private var stubs: [HotThreadStub] = []
  private var requests: [String] = []
  private var pending: [Int: CheckedContinuation<HotThreadFeedData, any Error>] = [:]

  func enqueue(_ stub: HotThreadStub) {
    stubs.append(stub)
  }

  func hotThreads(categoryCode: String) async throws -> HotThreadFeedData {
    requests.append(categoryCode)
    guard !stubs.isEmpty else {
      throw HotThreadStubFailure(message: "Unexpected hot-thread request")
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
  func requestSnapshot() -> [String] { requests }

  func resume(id: Int, returning value: HotThreadFeedData) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }
}

private enum HotThreadFixtures {
  static func category(serverID: Int32, code: String, title: String) -> HotThreadCategory {
    HotThreadCategory(serverID: serverID, code: code, title: title)
  }

  static func feed(
    categories: [HotThreadCategory] = [],
    items: [HotThreadRankItem] = []
  ) -> HotThreadFeedData {
    HotThreadFeedData(categories: categories, items: items)
  }

  static func item(
    id: Int64,
    rank: Int = 1,
    hotScore: Int = 100
  ) -> HotThreadRankItem {
    HotThreadRankItem(
      rank: rank,
      hotScore: hotScore,
      thread: thread(id: id)
    )
  }

  static func thread(id: Int64) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 7,
      forumName: "swift",
      title: "Thread \(id)",
      excerpt: "Excerpt \(id)",
      authorName: "Author \(id)",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("Content \(id)")]
    )
  }
}

private struct HotThreadWaitTimeout: Error {}

@MainActor
private func hotThreadWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw HotThreadWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func hotThreadDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
