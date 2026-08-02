import Foundation
import XCTest

@testable import TiebaPlusPlus

final class GlobalSearchHistoryViewModelTests: XCTestCase {
  @MainActor
  func testRapidRecordsAreSerializedInSubmissionOrder() async throws {
    let repository = SerialGlobalSearchHistoryRepository(suspendFirstRecord: true)
    let viewModel = GlobalSearchHistoryViewModel(repository: repository)

    viewModel.record("first")
    viewModel.record("second")

    try await globalHistoryWaitUntil { await repository.recordRequestCount() == 1 }
    let firstRecordedQueries = await repository.recordedQueries()
    XCTAssertEqual(firstRecordedQueries, ["first"])
    let resumed = await repository.resumeFirstRecord()
    XCTAssertTrue(resumed)

    try await globalHistoryWaitUntil {
      viewModel.entries.map(\.query) == ["second", "first"]
    }
    let requests = await repository.recordRequestsSnapshot()
    XCTAssertEqual(requests.map(\.query), ["first", "second"])
    guard requests.count == 2 else { return }
    XCTAssertLessThan(requests[0].date, requests[1].date)
    XCTAssertNil(viewModel.errorMessage)
  }

  @MainActor
  func testInvalidQueriesAreNotSentToRepository() async {
    let repository = SerialGlobalSearchHistoryRepository()
    let viewModel = GlobalSearchHistoryViewModel(repository: repository)

    viewModel.record(" \n")
    viewModel.record(String(repeating: "a", count: 101))
    await globalHistoryDrainMainActor()

    let requestCount = await repository.recordRequestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(viewModel.entries.isEmpty)
  }

  @MainActor
  func testLoadDeleteAndClearKeepPublishedEntriesInSync() async throws {
    let repository = SerialGlobalSearchHistoryRepository(
      initialEntries: [
        GlobalSearchHistoryEntry(query: "second", searchedAt: globalViewModelDate(2)),
        GlobalSearchHistoryEntry(query: "first", searchedAt: globalViewModelDate(1)),
      ]
    )
    let viewModel = GlobalSearchHistoryViewModel(repository: repository)

    await viewModel.loadIfNeeded()
    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.entries.map(\.query), ["second", "first"])
    let entriesRequestCount = await repository.entriesRequestCount()
    XCTAssertEqual(entriesRequestCount, 1)

    let firstID = try XCTUnwrap(viewModel.entries.last?.id)
    await viewModel.delete(id: firstID)
    XCTAssertEqual(viewModel.entries.map(\.query), ["second"])

    await viewModel.deleteAll()
    XCTAssertTrue(viewModel.entries.isEmpty)
    let storedEntries = await repository.storedEntries()
    XCTAssertTrue(storedEntries.isEmpty)
  }

  @MainActor
  func testCorruptedArchiveCanBeRecoveredOnlyThroughReset() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directoryURL.appendingPathComponent("global-search-history.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    try Data("{damaged".utf8).write(to: fileURL)
    let viewModel = GlobalSearchHistoryViewModel(
      repository: FileGlobalSearchHistoryStore(fileURL: fileURL)
    )

    await viewModel.loadIfNeeded()
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    await viewModel.reset()
    XCTAssertNil(viewModel.errorMessage)
    XCTAssertTrue(viewModel.entries.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }
}

private struct GlobalSearchRecordRequest: Sendable {
  let query: String
  let date: Date
}

private actor SerialGlobalSearchHistoryRepository: GlobalSearchHistoryRepository {
  private var stored: [GlobalSearchHistoryEntry]
  private var requests: [GlobalSearchRecordRequest] = []
  private var entriesRequests = 0
  private var shouldSuspendFirstRecord: Bool
  private var firstRecordContinuation: CheckedContinuation<Void, Never>?

  init(
    initialEntries: [GlobalSearchHistoryEntry] = [],
    suspendFirstRecord: Bool = false
  ) {
    stored = initialEntries
    shouldSuspendFirstRecord = suspendFirstRecord
  }

  func entries() async throws -> [GlobalSearchHistoryEntry] {
    entriesRequests += 1
    return stored.sorted { $0.searchedAt > $1.searchedAt }
  }

  func record(query: String, at date: Date) async throws {
    requests.append(GlobalSearchRecordRequest(query: query, date: date))
    if shouldSuspendFirstRecord {
      shouldSuspendFirstRecord = false
      await withCheckedContinuation { continuation in
        firstRecordContinuation = continuation
      }
    }
    let entry = GlobalSearchHistoryEntry(query: query, searchedAt: date)
    stored.removeAll { $0.id == entry.id }
    stored.append(entry)
  }

  func delete(id: String) async throws {
    stored.removeAll { $0.id == id }
  }

  func deleteAll() async throws {
    stored = []
  }

  func reset() async throws {
    stored = []
  }

  func recordRequestCount() -> Int { requests.count }
  func recordedQueries() -> [String] { requests.map(\.query) }
  func recordRequestsSnapshot() -> [GlobalSearchRecordRequest] { requests }
  func entriesRequestCount() -> Int { entriesRequests }
  func storedEntries() -> [GlobalSearchHistoryEntry] { stored }

  func resumeFirstRecord() -> Bool {
    guard let continuation = firstRecordContinuation else { return false }
    firstRecordContinuation = nil
    continuation.resume()
    return true
  }
}

private struct GlobalHistoryWaitTimeout: Error {}

@MainActor
private func globalHistoryWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw GlobalHistoryWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func globalHistoryDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}

private func globalViewModelDate(_ value: Int) -> Date {
  Date(timeIntervalSince1970: TimeInterval(value))
}
