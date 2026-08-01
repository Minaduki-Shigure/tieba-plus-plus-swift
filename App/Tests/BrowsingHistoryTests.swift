import Foundation
import XCTest

@testable import TiebaPlusPlus

final class BrowsingHistoryTests: XCTestCase {
  func testArchivePersistsAcrossStoreInstances() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let visitedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let firstStore = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await firstStore.record(
      .thread(
        ThreadHistorySnapshot(
          threadID: 42,
          forumID: 7,
          forumName: "swift",
          title: "A persisted thread",
          excerpt: "excerpt",
          authorName: "author"
        )
      ),
      at: visitedAt
    )
    try await firstStore.setRecordingEnabled(false)

    let secondStore = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let entries = try await secondStore.entries(kind: nil)
    let recordingEnabled = try await secondStore.isRecordingEnabled()

    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.lastVisitedAt, visitedAt)
    XCTAssertEqual(entry.visitCount, 1)
    XCTAssertEqual(entry.id, "thread:42")
    XCTAssertFalse(recordingEnabled)
    guard case .thread(let snapshot) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(snapshot.browseThread.id, 42)
    XCTAssertEqual(snapshot.browseThread.forumName, "swift")

    let archive = try String(contentsOf: location.fileURL, encoding: .utf8)
    XCTAssertTrue(archive.contains("\"schemaVersion\":1"))
  }

  func testUpsertDeduplicatesAndRefreshesMetadata() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await store.record(
      .forum(ForumHistorySnapshot(forumID: 1, name: " Swift ", displayName: "Old name")),
      at: Date(timeIntervalSince1970: 100)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(forumID: 2, name: "swift", displayName: "New name")),
      at: Date(timeIntervalSince1970: 200)
    )

    let entries = try await store.entries(kind: .forum)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.id, "forum:swift")
    XCTAssertEqual(entry.visitCount, 2)
    XCTAssertEqual(entry.lastVisitedAt, Date(timeIntervalSince1970: 200))
    guard case .forum(let forum) = entry.target else {
      return XCTFail("Expected a forum history entry")
    }
    XCTAssertEqual(forum.forumID, 2)
    XCTAssertEqual(forum.displayName, "New name")
  }

  func testConcurrentRecordsAreSerializedWithoutLosingVisits() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...12 {
        group.addTask {
          try await store.record(
            .thread(ThreadHistorySnapshot(threadID: 88, title: "thread")),
            at: Date(timeIntervalSince1970: TimeInterval(index))
          )
        }
      }
      try await group.waitForAll()
    }

    let entries = try await FileBrowsingHistoryStore(fileURL: location.fileURL)
      .entries(kind: .thread)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.visitCount, 12)
  }

  func testCorruptedArchiveReturnsExplicitErrorAndIsNotOverwritten() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let damagedData = Data("{not valid json".utf8)
    try damagedData.write(to: location.fileURL)
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(kind: nil)
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .corruptedArchive)
    }

    do {
      try await store.record(
        .forum(ForumHistorySnapshot(name: "swift")),
        at: Date(timeIntervalSince1970: 100)
      )
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), damagedData)
  }

  func testUnsupportedArchiveVersionIsReportedBeforePayloadDecoding() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    try Data("{\"schemaVersion\":2}".utf8).write(to: location.fileURL)
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(kind: nil)
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .unsupportedSchemaVersion(2))
    }
  }

  func testMaximumEntryCountIsAppliedIndependentlyToEachKind() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(
      fileURL: location.fileURL,
      maximumEntriesPerKind: 2
    )

    for index in 1...3 {
      try await store.record(
        .thread(ThreadHistorySnapshot(threadID: Int64(index), title: "thread-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
      try await store.record(
        .forum(ForumHistorySnapshot(forumID: Int64(index), name: "forum-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index + 10))
      )
    }

    let threads = try await store.entries(kind: .thread)
    let forums = try await store.entries(kind: .forum)
    let allEntries = try await store.entries(kind: nil)

    XCTAssertEqual(threads.map(\.id), ["thread:3", "thread:2"])
    XCTAssertEqual(forums.map(\.id), ["forum:forum-3", "forum:forum-2"])
    XCTAssertEqual(allEntries.count, 4)
  }

  func testRecordingSwitchSingleDeleteAndClear() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await store.setRecordingEnabled(false)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "ignored")),
      at: Date(timeIntervalSince1970: 1)
    )
    var entries = try await store.entries(kind: nil)
    XCTAssertTrue(entries.isEmpty)

    try await store.setRecordingEnabled(true)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "thread")),
      at: Date(timeIntervalSince1970: 2)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 3)
    )

    try await store.delete(id: "thread:1")
    entries = try await store.entries(kind: nil)
    XCTAssertEqual(entries.map(\.id), ["forum:swift"])

    try await store.deleteAll(kind: nil)
    entries = try await store.entries(kind: nil)
    let recordingEnabled = try await store.isRecordingEnabled()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertTrue(recordingEnabled)
  }

  func testProgressUpdatePreservesVisitCountAndResumeState() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 12, title: "thread")),
      at: Date(timeIntervalSince1970: 10)
    )

    try await store.updateThreadProgress(
      threadID: 12,
      postID: 99,
      floor: 18,
      options: ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true),
      at: Date(timeIntervalSince1970: 20)
    )

    let threadEntries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(threadEntries.first)
    XCTAssertEqual(entry.visitCount, 1)
    XCTAssertEqual(entry.lastVisitedAt, Date(timeIntervalSince1970: 20))
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(thread.lastPostID, 99)
    XCTAssertEqual(thread.lastFloor, 18)
    XCTAssertEqual(thread.browseOptions.sort, .descending)
    XCTAssertTrue(thread.browseOptions.onlyThreadAuthor)
  }

  func testHotProgressPersistsModeWithoutAnUnstableResumePosition() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 13, title: "hot thread")),
      at: Date(timeIntervalSince1970: 10)
    )

    try await store.updateThreadProgress(
      threadID: 13,
      postID: 100,
      floor: 0,
      options: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false),
      at: Date(timeIntervalSince1970: 20)
    )

    let entries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(entries.first)
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(thread.browseOptions.sort, .hot)
    XCTAssertNil(thread.lastPostID)
    XCTAssertNil(thread.lastFloor)
  }

  @MainActor
  func testViewModelGroupsTodayAndEarlierForSelectedKind() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let now = Date(timeIntervalSince1970: 1_704_110_400)

    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "earlier")),
      at: now.addingTimeInterval(-86_400)
    )
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 2, title: "today")),
      at: now.addingTimeInterval(-60)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: now
    )

    let viewModel = BrowsingHistoryViewModel(repository: store)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    let sections = viewModel.sections(now: now, calendar: calendar)

    XCTAssertEqual(sections.today.map(\.id), ["thread:2"])
    XCTAssertEqual(sections.earlier.map(\.id), ["thread:1"])
  }
}

private struct HistoryTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("browsing-history.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private struct HistoryWaitTimeout: Error {}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw HistoryWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
