import Foundation
import XCTest

@testable import TiebaPlusPlus

final class LocalFavoritesTests: XCTestCase {
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

  func testThreadProgressOptionsAndStaleWrites() async throws {
    let location = try FavoritesTestLocation()
    defer { location.remove() }
    let store = FileLocalFavoritesStore(fileURL: location.fileURL)
    try await store.save(
      .thread(ThreadHistorySnapshot(threadID: 42, title: "收藏帖子")),
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
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread favorite")
    }
    XCTAssertEqual(thread.lastPostID, 420)
    XCTAssertEqual(thread.lastFloor, 18)
    XCTAssertEqual(thread.browseOptions, newestOptions)

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
    try await store.save(.forum(ForumHistorySnapshot(name: "swift")))
    try await store.save(.thread(ThreadHistorySnapshot(threadID: 9, title: "thread")))

    let viewModel = LocalFavoritesViewModel(repository: store)
    viewModel.loadIfNeeded()
    try await waitForFavorites { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.favoriteForums.map(\.name), ["swift"])
    XCTAssertEqual(viewModel.visibleEntries.map(\.id), ["thread:9"])

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
