import Foundation
import XCTest

@testable import TiebaPlusPlus

final class LocalFavoritesTests: XCTestCase {
  func testSchemaOneArchiveWithoutPinnedAtDecodesAndThreadsCannotBePinned() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let legacyArchive = Data(
      """
      {
        "schemaVersion": 1,
        "entries": [
          {
            "target": {"kind": "forum", "forum": {"name": "swift"}},
            "savedAt": 10000,
            "updatedAt": 20000
          },
          {
            "target": {"kind": "thread", "thread": {"threadID": 7, "title": "旧帖子"}},
            "savedAt": 30000,
            "updatedAt": 30000,
            "pinnedAt": 30000
          }
        ]
      }
      """.utf8
    )
    try legacyArchive.write(to: location.fileURL)

    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    let entries = try await store.entries(kind: nil)
    let forum = try XCTUnwrap(entries.first { $0.id == "forum:swift" })
    let thread = try XCTUnwrap(entries.first { $0.id == "thread:7" })
    XCTAssertNil(forum.pinnedAt)
    XCTAssertFalse(forum.isPinned)
    XCTAssertNil(thread.pinnedAt)
    XCTAssertFalse(thread.isPinned)

    let constructedThread = LocalFavoriteEntry(
      target: .thread(ThreadHistorySnapshot(threadID: 8, title: "新帖子")),
      savedAt: Date(timeIntervalSince1970: 40),
      updatedAt: Date(timeIntervalSince1970: 40),
      pinnedAt: Date(timeIntervalSince1970: 40)
    )
    XCTAssertNil(constructedThread.pinnedAt)
    XCTAssertFalse(constructedThread.isPinned)
  }

  func testArchivePersistsAndUpsertsWithoutChangingSavedOrder() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)

    try await store.save(
      .forum(ForumHistorySnapshot(forumID: 1, name: " Swift ", displayName: "旧名称")),
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(forumID: 2, name: "swift", displayName: "新名称")),
      at: Date(timeIntervalSince1970: 20)
    )

    let secondStore = FileLocalFavoritesStore(fileURL: location.fileURL)
    let entries = try await secondStore.entries(kind: .forum)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.id, "forum:swift")
    XCTAssertEqual(entry.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 20))
    let containsForum = try await secondStore.contains(id: "forum:swift")
    XCTAssertTrue(containsForum)
    guard case .forum(let forum) = entry.target else {
      return XCTFail("Expected a forum favorite")
    }
    XCTAssertEqual(forum.forumID, 2)
    XCTAssertEqual(forum.displayName, "新名称")
    let archive = try String(contentsOf: location.fileURL, encoding: .utf8)
    XCTAssertTrue(archive.contains("\"schemaVersion\":1"))
  }

  func testPinnedForumRoundTripsAcrossStoreRestart() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 20)
    )

    let restartedStore = FileLocalFavoritesStore(fileURL: location.fileURL)
    let restartedEntries = try await restartedStore.entries(kind: .forum)
    let entry = try XCTUnwrap(restartedEntries.first)
    XCTAssertEqual(entry.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 20))
    XCTAssertEqual(entry.pinnedAt, Date(timeIntervalSince1970: 20))
    XCTAssertTrue(entry.isPinned)
  }

  func testPinUnpinRejectsStaleIdempotentMissingAndThreadChanges() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 10)
    )

    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 10)
    )
    var forumEntries = try await store.entries(kind: .forum)
    var forum = try XCTUnwrap(forumEntries.first)
    XCTAssertEqual(forum.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(forum.updatedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(forum.pinnedAt, Date(timeIntervalSince1970: 10))

    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: false,
      at: Date(timeIntervalSince1970: 9)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 30)
    )
    forumEntries = try await store.entries(kind: .forum)
    forum = try XCTUnwrap(forumEntries.first)
    XCTAssertEqual(forum.updatedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(forum.pinnedAt, Date(timeIntervalSince1970: 10))

    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: false,
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: false,
      at: Date(timeIntervalSince1970: 50)
    )
    forumEntries = try await store.entries(kind: .forum)
    forum = try XCTUnwrap(forumEntries.first)
    XCTAssertEqual(forum.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(forum.updatedAt, Date(timeIntervalSince1970: 10))
    XCTAssertNil(forum.pinnedAt)
    XCTAssertFalse(forum.isPinned)

    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 42, title: "帖子")),
      at: Date(timeIntervalSince1970: 60)
    )
    try await store.setForumPinned(
      id: "thread:42",
      isPinned: true,
      at: Date(timeIntervalSince1970: 70)
    )
    try await store.setForumPinned(
      id: "forum:missing",
      isPinned: true,
      at: Date(timeIntervalSince1970: 80)
    )
    let threadEntries = try await store.entries(kind: .thread)
    let thread = try XCTUnwrap(threadEntries.first)
    XCTAssertEqual(thread.updatedAt, Date(timeIntervalSince1970: 60))
    XCTAssertNil(thread.pinnedAt)
    let allEntries = try await store.entries(kind: nil)
    XCTAssertEqual(allEntries.count, 2)
  }

  func testPinChangeNotifiesOnceWhileNoOpsDoNotNotify() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 42, title: "帖子")),
      at: Date(timeIntervalSince1970: 10)
    )

    let notification = XCTNSNotificationExpectation(name: .localFavoritesDidChange)
    notification.expectedFulfillmentCount = 1
    notification.assertForOverFulfill = true

    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: false,
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 9)
    )
    try await store.setForumPinned(
      id: "forum:missing",
      isPinned: true,
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.setForumPinned(
      id: "thread:42",
      isPinned: true,
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 20)
    )

    await fulfillment(of: [notification], timeout: 1)
    let restartedStore = FileLocalFavoritesStore(fileURL: location.fileURL)
    let entries = try await restartedStore.entries(kind: .forum)
    XCTAssertTrue(try XCTUnwrap(entries.first).isPinned)
  }

  func testSavingUpdatedForumPreservesPinnedStateAndOriginalSavedAt() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(forumID: 1, name: "swift", displayName: "旧名称")),
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(forumID: 2, name: "swift", displayName: "新名称")),
      at: Date(timeIntervalSince1970: 30)
    )

    let entries = try await store.entries(kind: .forum)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 30))
    XCTAssertEqual(entry.pinnedAt, Date(timeIntervalSince1970: 20))
    guard case .forum(let forum) = entry.target else {
      return XCTFail("Expected a forum favorite")
    }
    XCTAssertEqual(forum.forumID, 2)
    XCTAssertEqual(forum.displayName, "新名称")
  }

  func testThreadProgressOptionsAndStaleWrites() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .thread(
        ThreadHistorySnapshot(
          threadID: 42,
          title: "收藏帖子",
          authorUsername: "author-account"
        )
      ),
      at: Date(timeIntervalSince1970: 10)
    )

    let newestOptions = ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    try await store.updateThreadProgress(
      threadID: 42,
      postID: 420,
      floor: 18,
      options: newestOptions,
      at: Date(timeIntervalSince1970: 30)
    )
    try await store.updateThreadProgress(
      threadID: 42,
      postID: 410,
      floor: 8,
      options: ThreadBrowseOptions(),
      at: Date(timeIntervalSince1970: 20)
    )

    var threadEntries = try await store.entries(kind: .thread)
    var entry = try XCTUnwrap(threadEntries.first)
    XCTAssertEqual(entry.savedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 30))
    XCTAssertNil(entry.pinnedAt)
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread favorite")
    }
    XCTAssertEqual(thread.lastPostID, 420)
    XCTAssertEqual(thread.lastFloor, 18)
    XCTAssertEqual(thread.browseOptions, newestOptions)
    XCTAssertEqual(thread.authorUsername, "author-account")

    try await store.updateThreadOptions(
      threadID: 42,
      options: ThreadBrowseOptions(sort: .hot),
      at: Date(timeIntervalSince1970: 40)
    )
    threadEntries = try await store.entries(kind: .thread)
    entry = try XCTUnwrap(threadEntries.first)
    guard case .thread(let updatedThread) = entry.target else {
      return XCTFail("Expected a thread favorite")
    }
    XCTAssertEqual(updatedThread.browseOptions.sort, .hot)
    XCTAssertNil(updatedThread.lastPostID)
    XCTAssertNil(updatedThread.lastFloor)
    XCTAssertEqual(updatedThread.authorUsername, "author-account")
    XCTAssertEqual(updatedThread.browseThread.authorUsername, "author-account")
    XCTAssertNil(entry.pinnedAt)
  }

  func testEntriesUseStablePinnedThenSavedPresentationOrder() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(name: "a")),
      at: Date(timeIntervalSince1970: 100)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "b")),
      at: Date(timeIntervalSince1970: 100)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "c")),
      at: Date(timeIntervalSince1970: 200)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "z")),
      at: Date(timeIntervalSince1970: 500)
    )
    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "one")),
      at: Date(timeIntervalSince1970: 500)
    )
    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 2, title: "two")),
      at: Date(timeIntervalSince1970: 500)
    )
    try await store.setForumPinned(
      id: "forum:a",
      isPinned: true,
      at: Date(timeIntervalSince1970: 300)
    )
    try await store.setForumPinned(
      id: "forum:c",
      isPinned: true,
      at: Date(timeIntervalSince1970: 300)
    )
    try await store.setForumPinned(
      id: "forum:b",
      isPinned: true,
      at: Date(timeIntervalSince1970: 400)
    )

    let expectedAll = [
      "forum:b", "forum:c", "forum:a", "forum:z", "thread:1", "thread:2",
    ]
    let allEntries = try await store.entries(kind: nil)
    let forumEntries = try await store.entries(kind: .forum)
    XCTAssertEqual(allEntries.map(\.id), expectedAll)
    XCTAssertEqual(
      forumEntries.map(\.id),
      ["forum:b", "forum:c", "forum:a", "forum:z"]
    )

    let restartedStore = FileLocalFavoritesStore(fileURL: location.fileURL)
    let restartedEntries = try await restartedStore.entries(kind: nil)
    XCTAssertEqual(restartedEntries.map(\.id), expectedAll)
  }

  func testCapacityStillEvictsOldPinnedForumBySavedAt() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(
      fileURL: location.fileURL,
      maximumEntriesPerKind: 2
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "old-pinned")),
      at: Date(timeIntervalSince1970: 1)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "middle")),
      at: Date(timeIntervalSince1970: 2)
    )
    try await store.setForumPinned(
      id: "forum:old-pinned",
      isPinned: true,
      at: Date(timeIntervalSince1970: 3)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "newest")),
      at: Date(timeIntervalSince1970: 4)
    )

    let entries = try await store.entries(kind: .forum)
    let containsOldPinned = try await store.contains(id: "forum:old-pinned")
    XCTAssertEqual(entries.map(\.id), ["forum:newest", "forum:middle"])
    XCTAssertFalse(containsOldPinned)
  }

  func testDeleteClearAndPerKindLimits() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(
      fileURL: location.fileURL,
      maximumEntriesPerKind: 2
    )

    for index in 1...3 {
      try await store.save(
        .thread(ThreadHistorySnapshot(threadID: Int64(index), title: "thread-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
      try await store.save(
        .forum(ForumHistorySnapshot(name: "forum-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index + 10))
      )
    }

    var threads = try await store.entries(kind: .thread)
    var forums = try await store.entries(kind: .forum)
    XCTAssertEqual(threads.map(\.id), ["thread:3", "thread:2"])
    XCTAssertEqual(forums.map(\.id), ["forum:forum-3", "forum:forum-2"])

    try await store.delete(id: "thread:3")
    threads = try await store.entries(kind: .thread)
    XCTAssertEqual(threads.map(\.id), ["thread:2"])
    try await store.deleteAll(kind: .forum)
    forums = try await store.entries(kind: .forum)
    XCTAssertTrue(forums.isEmpty)
    try await store.deleteAll(kind: nil)
    let allEntries = try await store.entries(kind: nil)
    XCTAssertTrue(allEntries.isEmpty)
  }

  func testCorruptedAndUnsupportedArchivesAreNotOverwritten() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let damaged = Data("{not valid json".utf8)
    try damaged.write(to: location.fileURL)
    let damagedStore = FileLocalFavoritesStore(fileURL: location.fileURL)

    do {
      _ = try await damagedStore.entries(kind: nil)
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? LocalFavoritesStoreError, .corruptedArchive)
    }
    do {
      try await damagedStore.save(.forum(ForumHistorySnapshot(name: "swift")))
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? LocalFavoritesStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), damaged)

    try Data("{\"schemaVersion\":2}".utf8).write(to: location.fileURL)
    let unsupportedStore = FileLocalFavoritesStore(fileURL: location.fileURL)
    do {
      _ = try await unsupportedStore.entries(kind: nil)
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(error as? LocalFavoritesStoreError, .unsupportedSchemaVersion(2))
    }
  }

  func testClearingBrowsingHistoryDoesNotRemoveFavorites() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let favorites = FileLocalFavoritesStore(fileURL: location.fileURL)
    let history = FileBrowsingHistoryStore(
      fileURL: location.directoryURL.appendingPathComponent("browsing-history.json")
    )
    let forum = ForumHistorySnapshot(name: "swift")

    try await favorites.save(.forum(forum))
    try await history.record(.forum(forum))
    try await history.deleteAll(kind: nil)

    let favoriteEntries = try await favorites.entries(kind: nil)
    let historyEntries = try await history.entries(kind: nil)
    XCTAssertEqual(favoriteEntries.map(\.id), ["forum:swift"])
    XCTAssertTrue(historyEntries.isEmpty)
  }

  @MainActor
  func testViewModelLoadsForumShortcutsAndMutatesEntries() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 10)
    )
    try await store.save(
      .forum(ForumHistorySnapshot(name: "apple")),
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.setForumPinned(
      id: "forum:swift",
      isPinned: true,
      at: Date(timeIntervalSince1970: 30)
    )
    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 9, title: "thread")),
      at: Date(timeIntervalSince1970: 40)
    )

    let viewModel = LocalFavoritesViewModel(repository: store)
    viewModel.loadIfNeeded()
    try await waitForFavorites { viewModel.state == .loaded }
    XCTAssertEqual(
      viewModel.favoriteForumEntries.map(\.id),
      ["forum:swift", "forum:apple"]
    )
    XCTAssertEqual(
      viewModel.favoriteForumEntries.compactMap { entry in
        guard case .forum(let forum) = entry.target else { return nil }
        return forum.name
      },
      ["swift", "apple"]
    )
    XCTAssertEqual(viewModel.visibleEntries.map(\.id), ["thread:9"])

    let pinnedForum = try XCTUnwrap(viewModel.favoriteForumEntries.first)
    viewModel.setForumPinned(pinnedForum, isPinned: false)
    try await waitForFavorites {
      viewModel.favoriteForumEntries.map(\.id) == ["forum:apple", "forum:swift"]
        && viewModel.favoriteForumEntries.allSatisfy { !$0.isPinned }
    }

    viewModel.delete(try XCTUnwrap(viewModel.visibleEntries.first))
    try await waitForFavorites { viewModel.visibleEntries.isEmpty }
    viewModel.clearAll()
    try await waitForFavorites { viewModel.entries.isEmpty }
  }
}

private struct FavoritesTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("local-favorites.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private struct FavoritesWaitTimeout: Error {}

@MainActor
private func waitForFavorites(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw FavoritesWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
