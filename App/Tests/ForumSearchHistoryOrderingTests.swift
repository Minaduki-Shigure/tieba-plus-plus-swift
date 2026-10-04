import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumSearchHistoryOrderingTests: XCTestCase {
  @MainActor
  func testInitialSnapshotCannotRestoreHistoryAfterClear() async throws {
    let repository = makeRepository(suspendedOperation: .read)
    let model = makeModel(repository)
    let load = Task { await model.loadHistoryIfNeeded() }
    try await wait { await repository.isSuspended }
    let clear = Task { await model.deleteAllHistory() }
    await drain()

    await repository.resume()
    await load.value
    await clear.value

    XCTAssertTrue(model.history.isEmpty)
    XCTAssertFalse(model.isHistoryLoading)
    let stored = await repository.snapshot(forumName: "swift")
    XCTAssertTrue(stored.isEmpty)
    let events = await repository.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "read:completed")),
      try XCTUnwrap(events.firstIndex(of: "clear:requested")))
  }

  @MainActor
  func testClearBeforeSubmissionPreservesNewVisitAndOtherForumWithoutBlockingSearch() async throws {
    let repository = makeRepository(suspendedOperation: .clear)
    let service = HistoryOrderingSearchService()
    let model = makeModel(repository, service: service)
    await model.loadHistoryIfNeeded()
    let clear = Task { await model.deleteAllHistory() }
    try await wait { await repository.isSuspended }

    model.submit(" new search ")
    try await wait { model.state == .loaded }
    let searches = await service.queries
    XCTAssertEqual(searches, ["new search"])
    let duringClear = await repository.events
    XCTAssertFalse(duringClear.contains("record:new search"))

    await repository.resume()
    await clear.value
    await model.retryHistory()

    XCTAssertEqual(model.history.map(\.query), ["new search"])
    let stored = await repository.snapshot(forumName: "swift")
    let otherForum = await repository.snapshot(forumName: "kotlin")
    XCTAssertEqual(model.history, stored)
    XCTAssertEqual(otherForum.map(\.query), ["other forum"])
    let events = await repository.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "clear:completed")),
      try XCTUnwrap(events.firstIndex(of: "record:new search")))
  }

  @MainActor
  func testOldDeletionCannotDeleteAResubmittedVisitOfTheSameTerm() async throws {
    let repository = makeRepository(suspendedOperation: .delete)
    let model = makeModel(repository)
    await model.loadHistoryIfNeeded()
    let oldEntry = try XCTUnwrap(model.history.first)
    let deletion = Task { await model.deleteHistory(id: oldEntry.id) }
    try await wait { await repository.isSuspended }

    model.submit(oldEntry.query)
    await drain()
    await repository.resume()
    await deletion.value
    await model.retryHistory()

    let stored = await repository.snapshot(forumName: "swift")
    XCTAssertEqual(stored.map(\.query), [oldEntry.query])
    XCTAssertEqual(model.history, stored)
    XCTAssertGreaterThan(try XCTUnwrap(stored.first?.searchedAt), oldEntry.searchedAt)
  }

  @MainActor
  func testCancelledCallerAndSearchCancellationDoNotDropAcceptedHistoryClear() async throws {
    let repository = makeRepository(suspendedOperation: .clear)
    let model = makeModel(repository)
    await model.loadHistoryIfNeeded()
    let clear = Task { await model.deleteAllHistory() }
    try await wait { await repository.isSuspended }

    clear.cancel()
    model.cancel()
    await repository.resume()
    await clear.value

    // The repository checks cancellation immediately before mutating storage.
    let stored = await repository.snapshot(forumName: "swift")
    XCTAssertTrue(stored.isEmpty)
    XCTAssertTrue(model.history.isEmpty)
    XCTAssertNil(model.historyError)
  }

  @MainActor
  func testConcurrentInitialLoadsShareOneReadIncludingACancelledWaiter() async throws {
    let repository = makeRepository(suspendedOperation: .read)
    let service = HistoryOrderingSearchService()
    let model = makeModel(repository, service: service)
    let first = Task { await model.loadHistoryIfNeeded() }
    try await wait { await repository.isSuspended }
    let second = Task { await model.loadHistoryIfNeeded() }
    await drain()
    first.cancel()
    let pendingEvents = await repository.events
    XCTAssertEqual(pendingEvents.filter { $0 == "read:requested" }.count, 1)

    await repository.resume()
    await first.value
    await second.value
    await model.loadHistoryIfNeeded()

    XCTAssertEqual(model.history.map(\.query), ["old search"])
    XCTAssertFalse(model.isHistoryLoading)
    let events = await repository.events
    let searches = await service.queries
    XCTAssertEqual(events.filter { $0 == "read:requested" }.count, 1)
    XCTAssertTrue(searches.isEmpty)
  }

  @MainActor
  func testFailedClearDoesNotPoisonTheNextQueuedRecord() async throws {
    let repository = makeRepository(suspendedOperation: .clear, failingOperation: .clear)
    let model = makeModel(repository)
    await model.loadHistoryIfNeeded()
    let clear = Task { await model.deleteAllHistory() }
    try await wait { await repository.isSuspended }
    model.submit("after failure")

    await repository.resume()
    await clear.value
    await model.retryHistory()

    XCTAssertEqual(model.history.map(\.query), ["after failure", "old search"])
    XCTAssertNil(model.historyError)
    let stored = await repository.snapshot(forumName: "swift")
    XCTAssertEqual(model.history, stored)
    let events = await repository.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "clear:failed")),
      try XCTUnwrap(events.firstIndex(of: "record:after failure")))
  }

  @MainActor
  func testRetrySnapshotThenResetCompleteBeforeTheNextSubmittedSearch() async throws {
    let repository = makeRepository()
    let model = makeModel(repository)
    await model.loadHistoryIfNeeded()
    await repository.suspendNext(.read)
    let retry = Task { await model.retryHistory() }
    try await wait { await repository.isSuspended }
    var resetAccepted = false
    let reset = Task {
      resetAccepted = true
      await model.resetHistory()
    }
    try await wait { resetAccepted }
    await drain()
    model.submit("after reset")

    await repository.resume()
    await retry.value
    await reset.value
    await model.retryHistory()

    XCTAssertEqual(model.history.map(\.query), ["after reset"])
    let stored = await repository.snapshot(forumName: "swift")
    let otherForum = await repository.snapshot(forumName: "kotlin")
    XCTAssertEqual(model.history, stored)
    XCTAssertTrue(otherForum.isEmpty)
    let events = await repository.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "reset:completed")),
      try XCTUnwrap(events.firstIndex(of: "record:after reset")))
  }

  @MainActor
  private func makeRepository(
    suspendedOperation: OrderedForumHistoryRepository.Operation? = nil,
    failingOperation: OrderedForumHistoryRepository.Operation? = nil
  ) -> OrderedForumHistoryRepository {
    let repository = OrderedForumHistoryRepository(
      suspendedOperation: suspendedOperation,
      failingOperation: failingOperation
    )
    addTeardownBlock { await repository.resume() }
    return repository
  }

  @MainActor
  private func makeModel(
    _ repository: OrderedForumHistoryRepository,
    service: HistoryOrderingSearchService = HistoryOrderingSearchService()
  ) -> ForumPostSearchViewModel {
    ForumPostSearchViewModel(
      forumName: "swift", service: service, historyRepository: repository)
  }

  @MainActor
  private func wait(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
      guard Date() < deadline else { throw ForumHistoryOrderingError.timeout }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  @MainActor
  private func drain() async {
    for _ in 0..<40 { await Task<Never, Never>.yield() }
  }
}

private enum ForumHistoryOrderingError: Error { case timeout, writeFailed }

/// Captures a read before suspending its return, modeling a completed archive
/// read whose MainActor publication is delayed while another action arrives.
private actor OrderedForumHistoryRepository: ForumSearchHistoryRepository {
  enum Operation: String, Sendable { case read, clear, delete, reset }
  private var suspension: Operation?
  private var failure: Operation?
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var events: [String] = []
  private var stored = [
    ForumSearchHistoryEntry(
      forumName: "swift", query: "old search", searchedAt: Date(timeIntervalSince1970: 1)),
    ForumSearchHistoryEntry(
      forumName: "kotlin", query: "other forum", searchedAt: Date(timeIntervalSince1970: 2)),
  ]

  init(suspendedOperation: Operation?, failingOperation: Operation?) {
    suspension = suspendedOperation
    failure = failingOperation
  }

  var isSuspended: Bool { continuation != nil }

  func entries(forumName: String) async throws -> [ForumSearchHistoryEntry] {
    let captured = snapshot(forumName: forumName)
    try await begin(.read)
    events.append("read:completed")
    return captured
  }

  func record(query: String, forumName: String, at date: Date) async throws {
    try Task.checkCancellation()
    events.append("record:\(query)")
    let entry = ForumSearchHistoryEntry(forumName: forumName, query: query, searchedAt: date)
    stored.removeAll { $0.id == entry.id }
    stored.append(entry)
  }

  func delete(id: String) async throws {
    try await begin(.delete)
    stored.removeAll { $0.id == id }
    events.append("delete:completed")
  }

  func deleteAll(forumName: String) async throws {
    try await begin(.clear)
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    stored.removeAll { ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key }
    events.append("clear:completed")
  }

  func reset() async throws {
    try await begin(.reset)
    stored = []
    events.append("reset:completed")
  }

  func snapshot(forumName: String) -> [ForumSearchHistoryEntry] {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    return stored.filter {
      ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key
    }.sorted { $0.searchedAt > $1.searchedAt }
  }

  func suspendNext(_ operation: Operation) { suspension = operation }

  func resume() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }

  private func begin(_ operation: Operation) async throws {
    events.append("\(operation.rawValue):requested")
    if suspension == operation {
      suspension = nil
      await withCheckedContinuation { continuation = $0 }
    }
    try Task.checkCancellation()
    if failure == operation {
      failure = nil
      events.append("\(operation.rawValue):failed")
      throw ForumHistoryOrderingError.writeFailed
    }
  }
}

private actor HistoryOrderingSearchService: ForumPostSearchService {
  private(set) var queries: [String] = []

  func searchForumPosts(
    query: String,
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) async throws -> ForumPostSearchPageData {
    queries.append(query)
    return ForumPostSearchPageData(results: [], currentPage: page, hasMore: false)
  }
}
