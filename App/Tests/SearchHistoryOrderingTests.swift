import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SearchHistoryOrderingTests: XCTestCase {
  @MainActor
  func testInitialSnapshotCannotRestoreHistoryAfterClear() async throws {
    let repository = OrderedSearchHistoryRepository(suspendedOperation: .read)
    let model = GlobalSearchHistoryViewModel(repository: repository)
    let load = Task { await model.loadIfNeeded() }
    try await wait { await repository.isSuspended }
    let clear = Task { await model.deleteAll() }
    await drain()
    await repository.resume()
    await load.value
    await clear.value
    XCTAssertTrue(model.entries.isEmpty)
    let stored = await repository.snapshot()
    XCTAssertTrue(stored.isEmpty)
    XCTAssertFalse(model.isLoading)
  }

  @MainActor
  func testSearchSubmittedAfterClearIsRecordedAfterThatClear() async throws {
    let repository = OrderedSearchHistoryRepository(suspendedOperation: .clear)
    let model = GlobalSearchHistoryViewModel(repository: repository)
    await model.loadIfNeeded()
    let clear = Task { await model.deleteAll() }
    try await wait { await repository.isSuspended }
    model.record("new search")
    await drain()
    let duringClear = await repository.events
    XCTAssertFalse(duringClear.contains("record:new search"))
    await repository.resume()
    await clear.value
    // Queue a read after both user actions; it must see their final order.
    await model.retry()
    let stored = await repository.snapshot()
    XCTAssertEqual(stored.map(\.query), ["new search"])
    XCTAssertEqual(model.entries.map(\.query), ["new search"])
    let events = await repository.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "clear:committed")),
      try XCTUnwrap(events.firstIndex(of: "record:new search")))
  }

  @MainActor
  func testSearchingDeletedTermAgainKeepsTheNewVisit() async throws {
    let repository = OrderedSearchHistoryRepository(suspendedOperation: .delete)
    let model = GlobalSearchHistoryViewModel(repository: repository)
    await model.loadIfNeeded()
    let entry = try XCTUnwrap(model.entries.first)
    let delete = Task { await model.delete(id: entry.id) }
    try await wait { await repository.isSuspended }
    model.record(entry.query)
    await drain()
    await repository.resume()
    await delete.value
    await model.retry()
    let stored = await repository.snapshot()
    XCTAssertEqual(stored.map(\.query), [entry.query])
    XCTAssertEqual(model.entries, stored)
    XCTAssertGreaterThan(try XCTUnwrap(stored.first?.searchedAt), entry.searchedAt)
  }

  @MainActor
  private func wait(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
      guard Date() < deadline else { throw OrderingTestError.timeout }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  @MainActor
  private func drain() async {
    for _ in 0..<40 { await Task<Never, Never>.yield() }
  }
}

private enum OrderingTestError: Error { case timeout }

/// Hold an operation between its request and completion. Reads return the
/// snapshot captured when requested, just as a completed file read may wait
/// for its MainActor caller while another action updates the archive.
private actor OrderedSearchHistoryRepository: GlobalSearchHistoryRepository {
  enum Operation { case read, clear, delete }
  private var suspension: Operation?
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var events: [String] = []
  private var stored = [
    GlobalSearchHistoryEntry(query: "old search", searchedAt: Date(timeIntervalSince1970: 1))
  ]

  init(suspendedOperation: Operation) { suspension = suspendedOperation }
  var isSuspended: Bool { continuation != nil }

  func entries() async throws -> [GlobalSearchHistoryEntry] {
    let snapshot = stored
    events.append("read")
    await suspendIfNeeded(.read)
    return snapshot
  }

  func record(query: String, at date: Date) async throws {
    events.append("record:\(query)")
    let entry = GlobalSearchHistoryEntry(query: query, searchedAt: date)
    stored.removeAll { $0.id == entry.id }
    stored.insert(entry, at: 0)
  }

  func delete(id: String) async throws {
    events.append("delete:requested")
    await suspendIfNeeded(.delete)
    stored.removeAll { $0.id == id }
    events.append("delete:committed")
  }

  func deleteAll() async throws {
    events.append("clear:requested")
    await suspendIfNeeded(.clear)
    stored = []
    events.append("clear:committed")
  }

  func reset() async throws { stored = [] }
  func snapshot() -> [GlobalSearchHistoryEntry] { stored }

  func resume() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }

  private func suspendIfNeeded(_ operation: Operation) async {
    guard suspension == operation else { return }
    suspension = nil
    await withCheckedContinuation { continuation = $0 }
  }
}
