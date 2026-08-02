import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumSearchHistoryTests: XCTestCase {
  func testArchivePersistsAcrossInstancesWithSchemaMarker() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let searchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await FileForumSearchHistoryStore(fileURL: location.fileURL).record(
      query: " Async/Await ",
      forumName: " Swift ",
      at: searchedAt
    )
    let entries = try await FileForumSearchHistoryStore(fileURL: location.fileURL)
      .entries(forumName: "swift")

    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.forumName, "Swift")
    XCTAssertEqual(entry.query, "Async/Await")
    XCTAssertEqual(entry.searchedAt, searchedAt)

    let archive = try String(contentsOf: location.fileURL, encoding: .utf8)
    XCTAssertTrue(archive.contains("\"schemaVersion\":1"))
  }

  func testPerForumIsolationUsesTrimmedCaseInsensitiveCanonicalNames() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: "Concurrency", forumName: " Cafe\u{301} ", at: date(1))
    try await store.record(query: "SwiftUI", forumName: "IOS", at: date(2))

    let cafeEntries = try await store.entries(forumName: "  CAFÉ\n")
    let iosEntries = try await store.entries(forumName: " ios ")

    XCTAssertEqual(cafeEntries.map(\.query), ["Concurrency"])
    XCTAssertEqual(iosEntries.map(\.query), ["SwiftUI"])
  }

  func testRecordDeduplicatesNormalizedQueryAndRefreshesDisplayAndRecency() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: " async ", forumName: "swift", at: date(1))
    let originalEntries = try await store.entries(forumName: "swift")
    let originalID = try XCTUnwrap(originalEntries.first?.id)
    try await store.record(query: "ASYNC", forumName: "SWIFT", at: date(3))
    try await store.record(query: "actors", forumName: "swift", at: date(2))

    let entries = try await store.entries(forumName: "Swift")
    XCTAssertEqual(entries.map(\.query), ["ASYNC", "actors"])
    XCTAssertEqual(entries.map(\.searchedAt), [date(3), date(2)])
    XCTAssertEqual(entries.first?.forumName, "SWIFT")
    XCTAssertEqual(entries.first?.id, originalID)
  }

  func testDelayedOlderRecordCannotOverwriteNewerEquivalentQuery() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: "NEW DISPLAY", forumName: "SWIFT", at: date(3))
    try await store.record(query: "new display", forumName: "swift", at: date(1))

    let entries = try await store.entries(forumName: "swift")
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.query, "NEW DISPLAY")
    XCTAssertEqual(entries.first?.forumName, "SWIFT")
    XCTAssertEqual(entries.first?.searchedAt, date(3))
  }

  func testMaximumEntryCountIsAppliedIndependentlyPerForum() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(
      fileURL: location.fileURL,
      maximumEntriesPerForum: 2
    )

    for index in 1...3 {
      try await store.record(
        query: "swift-\(index)",
        forumName: "swift",
        at: date(index)
      )
      try await store.record(
        query: "ios-\(index)",
        forumName: "ios",
        at: date(index + 10)
      )
    }

    let swiftEntries = try await store.entries(forumName: "swift")
    let iosEntries = try await store.entries(forumName: "ios")
    XCTAssertEqual(swiftEntries.map(\.query), ["swift-3", "swift-2"])
    XCTAssertEqual(iosEntries.map(\.query), ["ios-3", "ios-2"])
  }

  func testDeleteAndDeleteAllOnlyAffectTheRequestedEntries() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    try await store.record(query: "one", forumName: "swift", at: date(1))
    try await store.record(query: "two", forumName: "swift", at: date(2))
    try await store.record(query: "three", forumName: "ios", at: date(3))

    var swiftEntries = try await store.entries(forumName: "swift")
    let entryToDelete = try XCTUnwrap(swiftEntries.first { $0.query == "one" })
    try await store.delete(id: entryToDelete.id)
    swiftEntries = try await store.entries(forumName: "swift")
    var iosEntries = try await store.entries(forumName: "ios")
    XCTAssertEqual(swiftEntries.map(\.query), ["two"])
    XCTAssertEqual(iosEntries.map(\.query), ["three"])

    try await store.deleteAll(forumName: " SWIFT ")
    swiftEntries = try await store.entries(forumName: "swift")
    iosEntries = try await store.entries(forumName: "ios")
    XCTAssertTrue(swiftEntries.isEmpty)
    XCTAssertEqual(iosEntries.map(\.query), ["three"])
  }

  func testEmptyForumOrQueryIsRejectedWithoutCreatingAnArchive() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    await assertInvalidEntry {
      try await store.record(query: "\n", forumName: "swift", at: date(1))
    }
    await assertInvalidEntry {
      try await store.record(query: "async", forumName: " \t", at: date(1))
    }
    await assertInvalidEntry {
      _ = try await store.entries(forumName: "  ")
    }
    await assertInvalidEntry {
      try await store.deleteAll(forumName: "\n")
    }
    await assertInvalidEntry {
      try await store.delete(id: " ")
    }
    await assertInvalidEntry {
      try await store.record(
        query: String(repeating: "a", count: 101),
        forumName: "swift",
        at: date(1)
      )
    }
    await assertInvalidEntry {
      _ = try await store.entries(forumName: String(repeating: "a", count: 101))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
  }

  func testCorruptedArchiveIsReportedAndPreservedOnMutation() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let damagedData = Data("{not valid json".utf8)
    try damagedData.write(to: location.fileURL)
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(forumName: "swift")
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? ForumSearchHistoryStoreError, .corruptedArchive)
    }
    do {
      try await store.record(query: "async", forumName: "swift", at: date(1))
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? ForumSearchHistoryStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), damagedData)

    try await store.reset()
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
    try await store.record(query: "recovered", forumName: "swift", at: date(2))
    let recovered = try await store.entries(forumName: "swift")
    XCTAssertEqual(recovered.map(\.query), ["recovered"])
  }

  func testUnsupportedVersionIsCheckedBeforePayloadAndPreserved() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let unsupportedData = Data("{\"schemaVersion\":2}".utf8)
    try unsupportedData.write(to: location.fileURL)
    let store = FileForumSearchHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(forumName: "swift")
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(
        error as? ForumSearchHistoryStoreError,
        .unsupportedSchemaVersion(2)
      )
    }
    do {
      try await store.deleteAll(forumName: "swift")
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(
        error as? ForumSearchHistoryStoreError,
        .unsupportedSchemaVersion(2)
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), unsupportedData)
  }

  func testOversizedArchiveIsRejectedAndPreserved() async throws {
    let location = try ForumSearchHistoryTestLocation()
    defer { location.remove() }
    let oversizedData = Data(repeating: 0x20, count: 1_025)
    try oversizedData.write(to: location.fileURL)
    let store = FileForumSearchHistoryStore(
      fileURL: location.fileURL,
      maximumArchiveBytes: 1_024
    )

    do {
      try await store.record(query: "async", forumName: "swift", at: date(1))
      XCTFail("Expected archiveTooLarge")
    } catch {
      XCTAssertEqual(error as? ForumSearchHistoryStoreError, .archiveTooLarge)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), oversizedData)
  }
}

private struct ForumSearchHistoryTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("forum-search-history.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private func date(_ value: Int) -> Date {
  Date(timeIntervalSince1970: TimeInterval(value))
}

private func assertInvalidEntry(
  _ operation: @Sendable () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected invalidEntry", file: file, line: line)
  } catch {
    XCTAssertEqual(
      error as? ForumSearchHistoryStoreError,
      .invalidEntry,
      file: file,
      line: line
    )
  }
}
