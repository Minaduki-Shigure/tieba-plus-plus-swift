import Foundation
import XCTest

@testable import TiebaPlusPlus

final class GlobalSearchHistoryTests: XCTestCase {
  func testArchivePersistsAcrossInstancesWithSchemaMarker() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let searchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await FileGlobalSearchHistoryStore(fileURL: location.fileURL).record(
      query: " Async/Await ",
      at: searchedAt
    )
    let entries = try await FileGlobalSearchHistoryStore(fileURL: location.fileURL).entries()

    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.query, "Async/Await")
    XCTAssertEqual(entry.searchedAt, searchedAt)

    let archive = try String(contentsOf: location.fileURL, encoding: .utf8)
    XCTAssertTrue(archive.contains("\"schemaVersion\":1"))
  }

  func testRecordDeduplicatesCanonicalQueryAndKeepsNewestDisplay() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: " Cafe\u{301} ", at: globalHistoryDate(1))
    let originalEntries = try await store.entries()
    let originalID = try XCTUnwrap(originalEntries.first?.id)
    try await store.record(query: "CAFÉ", at: globalHistoryDate(3))
    try await store.record(query: "actors", at: globalHistoryDate(2))

    let entries = try await store.entries()
    XCTAssertEqual(entries.map(\.query), ["CAFÉ", "actors"])
    XCTAssertEqual(entries.map(\.searchedAt), [globalHistoryDate(3), globalHistoryDate(2)])
    XCTAssertEqual(entries.first?.id, originalID)
  }

  func testDelayedOlderRecordCannotOverwriteNewerEquivalentQuery() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: "NEW DISPLAY", at: globalHistoryDate(3))
    try await store.record(query: "new display", at: globalHistoryDate(1))

    let entries = try await store.entries()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.query, "NEW DISPLAY")
    XCTAssertEqual(entries.first?.searchedAt, globalHistoryDate(3))
  }

  func testMaximumEntryCountKeepsOnlyNewestEntries() async throws {
    XCTAssertEqual(FileGlobalSearchHistoryStore.defaultMaximumEntries, 20)
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileGlobalSearchHistoryStore(
      fileURL: location.fileURL,
      maximumEntries: 2
    )

    for index in 1...3 {
      try await store.record(query: "query-\(index)", at: globalHistoryDate(index))
    }

    let entries = try await store.entries()
    XCTAssertEqual(entries.map(\.query), ["query-3", "query-2"])
  }

  func testDeleteAndDeleteAllAffectOnlyRequestedState() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: "one", at: globalHistoryDate(1))
    try await store.record(query: "two", at: globalHistoryDate(2))

    var entries = try await store.entries()
    let entryToDelete = try XCTUnwrap(entries.first { $0.query == "one" })
    try await store.delete(id: entryToDelete.id)
    entries = try await store.entries()
    XCTAssertEqual(entries.map(\.query), ["two"])

    try await store.deleteAll()
    let clearedEntries = try await store.entries()
    XCTAssertTrue(clearedEntries.isEmpty)
  }

  func testInvalidQueriesAreRejectedWithoutCreatingArchive() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    await assertInvalidGlobalSearchEntry {
      try await store.record(query: "\n", at: globalHistoryDate(1))
    }
    await assertInvalidGlobalSearchEntry {
      try await store.record(
        query: String(repeating: "a", count: 101),
        at: globalHistoryDate(1)
      )
    }
    await assertInvalidGlobalSearchEntry {
      try await store.delete(id: " ")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
  }

  func testCorruptedArchiveIsPreservedUntilExplicitReset() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let damagedData = Data("{not valid json".utf8)
    try damagedData.write(to: location.fileURL)
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries()
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? GlobalSearchHistoryStoreError, .corruptedArchive)
    }
    do {
      try await store.record(query: "async", at: globalHistoryDate(1))
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? GlobalSearchHistoryStoreError, .corruptedArchive)
    }
    do {
      try await store.deleteAll()
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? GlobalSearchHistoryStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), damagedData)

    try await store.reset()
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
    try await store.record(query: "recovered", at: globalHistoryDate(2))
    let recoveredEntries = try await store.entries()
    XCTAssertEqual(recoveredEntries.map(\.query), ["recovered"])
  }

  func testUnsupportedVersionIsCheckedBeforePayloadAndPreserved() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let unsupportedData = Data("{\"schemaVersion\":2}".utf8)
    try unsupportedData.write(to: location.fileURL)
    let store = FileGlobalSearchHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries()
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(
        error as? GlobalSearchHistoryStoreError,
        .unsupportedSchemaVersion(2)
      )
    }
    do {
      try await store.deleteAll()
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(
        error as? GlobalSearchHistoryStoreError,
        .unsupportedSchemaVersion(2)
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), unsupportedData)
  }

  func testOversizedArchiveIsRejectedAndPreserved() async throws {
    let location = try GlobalSearchHistoryTestLocation()
    defer { location.remove() }
    let oversizedData = Data(repeating: 0x20, count: 1_025)
    try oversizedData.write(to: location.fileURL)
    let store = FileGlobalSearchHistoryStore(
      fileURL: location.fileURL,
      maximumArchiveBytes: 1_024
    )

    do {
      try await store.record(query: "async", at: globalHistoryDate(1))
      XCTFail("Expected archiveTooLarge")
    } catch {
      XCTAssertEqual(error as? GlobalSearchHistoryStoreError, .archiveTooLarge)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), oversizedData)
  }
}

private struct GlobalSearchHistoryTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("global-search-history.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private func globalHistoryDate(_ value: Int) -> Date {
  Date(timeIntervalSince1970: TimeInterval(value))
}

private func assertInvalidGlobalSearchEntry(
  _ operation: @Sendable () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected invalidEntry", file: file, line: line)
  } catch {
    XCTAssertEqual(
      error as? GlobalSearchHistoryStoreError,
      .invalidEntry,
      file: file,
      line: line
    )
  }
}
