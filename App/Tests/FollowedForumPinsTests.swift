import XCTest

@testable import TiebaPlusPlus

final class FollowedForumPinsTests: XCTestCase {
  func testRoundTripNormalizesNamesIsolatesAccountsAndSetsStorageAttributes() async throws {
    let location = try FollowedForumPinsTestLocation()
    defer { location.remove() }
    let store = FileFollowedForumPinsStore(fileURL: location.fileURL)

    try await store.setPin(
      accountID: 7,
      forumID: 1,
      forumName: "  Cafe\u{301}  ",
      pinnedAt: Date(timeIntervalSince1970: 10)
    )
    try await store.setPin(
      accountID: 8,
      forumID: 1,
      forumName: "SWIFT",
      pinnedAt: Date(timeIntervalSince1970: 20)
    )

    let restartedStore = FileFollowedForumPinsStore(fileURL: location.fileURL)
    let firstAccountPins = try await restartedStore.pins(accountID: 7)
    let secondAccountPins = try await restartedStore.pins(accountID: 8)
    XCTAssertEqual(firstAccountPins.map(\.forumName), ["caf\u{E9}"])
    XCTAssertEqual(firstAccountPins.map(\.forumID), [1])
    XCTAssertEqual(secondAccountPins.map(\.forumName), ["swift"])
    XCTAssertEqual(secondAccountPins.map(\.forumID), [1])
    let values = try location.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
#if os(iOS) && !targetEnvironment(simulator)
    let attributes = try FileManager.default.attributesOfItem(atPath: location.fileURL.path)
    XCTAssertEqual(
      attributes[.protectionKey] as? FileProtectionType,
      .completeUntilFirstUserAuthentication
    )
#endif
  }

  func testUpsertDeduplicatesAndUsesNewestPinnedAtOrder() async throws {
    let location = try FollowedForumPinsTestLocation()
    defer { location.remove() }
    let store = FileFollowedForumPinsStore(fileURL: location.fileURL)

    try await store.setPin(
      accountID: 7,
      forumID: 1,
      forumName: "old",
      pinnedAt: Date(timeIntervalSince1970: 10)
    )
    try await store.setPin(
      accountID: 7,
      forumID: 2,
      forumName: "second",
      pinnedAt: Date(timeIntervalSince1970: 20)
    )
    try await store.setPin(
      accountID: 7,
      forumID: 1,
      forumName: "updated",
      pinnedAt: Date(timeIntervalSince1970: 30)
    )

    var pins = try await store.pins(accountID: 7)
    XCTAssertEqual(pins.map(\.forumID), [1, 2])
    XCTAssertEqual(pins.map(\.forumName), ["updated", "second"])
    XCTAssertEqual(pins.map(\.pinnedAt), [
      Date(timeIntervalSince1970: 30),
      Date(timeIntervalSince1970: 20),
    ])

    try await store.removePin(accountID: 7, forumID: 1)
    pins = try await store.pins(accountID: 7)
    XCTAssertEqual(pins.map(\.forumID), [2])
  }

  func testInvalidIdentityAndCapacityAreRejected() async throws {
    let location = try FollowedForumPinsTestLocation()
    defer { location.remove() }
    let store = FileFollowedForumPinsStore(
      fileURL: location.fileURL,
      maximumPinsPerAccount: 1,
      maximumTotalPins: 2
    )

    do {
      _ = try await store.pins(accountID: 0)
      XCTFail("Expected invalidAccount")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .invalidAccount)
    }
    do {
      try await store.setPin(accountID: 7, forumID: 0, forumName: "swift")
      XCTFail("Expected invalidForum")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .invalidForum)
    }
    try await store.setPin(accountID: 7, forumID: 1, forumName: "swift")
    do {
      try await store.setPin(accountID: 7, forumID: 2, forumName: "apple")
      XCTFail("Expected tooManyPins")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .tooManyPins)
    }
  }

  func testCorruptedAndFutureArchivesAreNeverOverwritten() async throws {
    let location = try FollowedForumPinsTestLocation()
    defer { location.remove() }
    let corrupted = Data("{not valid json".utf8)
    try corrupted.write(to: location.fileURL)
    let corruptedStore = FileFollowedForumPinsStore(fileURL: location.fileURL)

    do {
      _ = try await corruptedStore.pins(accountID: 7)
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .corruptedArchive)
    }
    do {
      try await corruptedStore.setPin(accountID: 7, forumID: 1, forumName: "swift")
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), corrupted)

    let future = Data("{\"schemaVersion\":99,\"pins\":[]}".utf8)
    try future.write(to: location.fileURL)
    let futureStore = FileFollowedForumPinsStore(fileURL: location.fileURL)
    do {
      _ = try await futureStore.pins(accountID: 7)
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .unsupportedSchemaVersion(99))
    }
    do {
      try await futureStore.removePin(accountID: 7, forumID: 1)
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(error as? FollowedForumPinsStoreError, .unsupportedSchemaVersion(99))
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), future)
  }

  func testProjectionUsesOnlyLoadedExactMatchesAndPreservesServerOrderForOthers() throws {
    let forums = [
      forum(id: 1, name: "one"),
      forum(id: 2, name: "two"),
      forum(id: 3, name: "three"),
      forum(id: 2, name: "duplicate"),
      forum(id: 4, name: "four"),
    ]
    let pins = [
      try XCTUnwrap(pin(accountID: 7, forumID: 3, name: "THREE", at: 30)),
      try XCTUnwrap(pin(accountID: 7, forumID: 1, name: "one", at: 20)),
      try XCTUnwrap(pin(accountID: 7, forumID: 2, name: "renamed", at: 40)),
      try XCTUnwrap(pin(accountID: 7, forumID: 99, name: "not-loaded", at: 50)),
      try XCTUnwrap(pin(accountID: 8, forumID: 4, name: "four", at: 60)),
    ]

    let projection = FollowedForumPinProjection.make(
      forums: forums,
      pins: pins,
      accountID: 7
    )

    XCTAssertEqual(projection.pinned.map(\.id), [3, 1])
    XCTAssertEqual(projection.unpinned.map(\.id), [2, 4])
    XCTAssertEqual(projection.all.map(\.id), [3, 1, 2, 4])
  }

  func testProjectionDeduplicatesPinsAndHasStableTieOrder() throws {
    let forums = [
      forum(id: 3, name: "three"),
      forum(id: 1, name: "one"),
      forum(id: 2, name: "two"),
    ]
    let pins = [
      try XCTUnwrap(pin(accountID: 7, forumID: 1, name: "one", at: 20)),
      try XCTUnwrap(pin(accountID: 7, forumID: 1, name: "one", at: 10)),
      try XCTUnwrap(pin(accountID: 7, forumID: 2, name: "two", at: 20)),
    ]

    let projection = FollowedForumPinProjection.make(
      forums: forums,
      pins: pins,
      accountID: 7
    )

    XCTAssertEqual(projection.pinned.map(\.id), [1, 2])
    XCTAssertEqual(projection.unpinned.map(\.id), [3])
  }

  private func forum(id: Int64, name: String) -> FollowedForumItem {
    FollowedForumItem(id: id, name: name, level: 1, experience: 1)
  }

  private func pin(
    accountID: Int64,
    forumID: Int64,
    name: String,
    at timestamp: TimeInterval
  ) -> FollowedForumPin? {
    FollowedForumPin(
      accountID: accountID,
      forumID: forumID,
      forumName: name,
      pinnedAt: Date(timeIntervalSince1970: timestamp)
    )
  }
}

private struct FollowedForumPinsTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("followed-forum-pins.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
