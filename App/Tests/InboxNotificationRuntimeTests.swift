import Foundation
import XCTest

@testable import TiebaPlusPlus

final class InboxNotificationRouteTests: XCTestCase {
  func testOnlyExactOwnedChannelAndSessionPayloadCanOpenInbox() {
    let revision = UUID()
    for kind in InboxKind.allCases {
      let identifier = InboxNotificationRoute.notificationIdentifier(for: kind)
      let info = ["kind": kind.rawValue, "sessionRevision": revision.uuidString]
      let route = InboxNotificationRoute(identifier: identifier, userInfo: info)
      XCTAssertEqual(route?.kind, kind)
      XCTAssertEqual(route?.sessionRevision, revision)
      XCTAssertNil(InboxNotificationRoute(identifier: "foreign.\(identifier)", userInfo: info))
      XCTAssertNil(InboxNotificationRoute(
        identifier: identifier,
        userInfo: ["kind": kind.rawValue, "sessionRevision": "not-a-session"]
      ))
      XCTAssertNil(InboxNotificationRoute(
        identifier: identifier,
        userInfo: ["kind": kind.rawValue, "sessionRevision": revision.uuidString, "url": "https://example.com"]
      ))
      XCTAssertNil(InboxNotificationRoute(identifier: identifier, userInfo: [:]))
    }
    XCTAssertNil(InboxNotificationRoute(
      identifier: InboxNotificationRoute.notificationIdentifier(for: .replies),
      userInfo: ["kind": "mentions", "sessionRevision": revision.uuidString]
    ))
  }
}

@MainActor
final class DefaultsInboxNotificationStateStoreTests: XCTestCase {
  func testRelaunchReadsOnlyValidatedCountsAndLeaseAndDisableClearsThem() throws {
    let suite = "InboxNotificationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = InboxNotificationSnapshot(
      userID: 42, sessionRevision: UUID(), replies: 7, mentions: 3
    )
    let store = DefaultsInboxNotificationStateStore(defaults: defaults)
    XCTAssertNil(try store.load())
    try store.save(snapshot)
    let relaunched = DefaultsInboxNotificationStateStore(defaults: defaults)
    XCTAssertEqual(try relaunched.load(), snapshot)
    let bytes = try XCTUnwrap(defaults.data(forKey: DefaultsInboxNotificationStateStore.key))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["version", "userID", "sessionRevision", "replies", "mentions"])
    try relaunched.save(nil)
    XCTAssertNil(try store.load())
  }

  func testUnreadableFutureInvalidAndOversizedStateIsPreservedAndRejected() throws {
    let suite = "InboxNotificationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DefaultsInboxNotificationStateStore(defaults: defaults)
    for value in [
      InboxNotificationSnapshot(userID: 42, sessionRevision: UUID(), replies: 1, mentions: 1, version: 2),
      InboxNotificationSnapshot(userID: 0, sessionRevision: UUID(), replies: 1, mentions: 1),
      InboxNotificationSnapshot(userID: 42, sessionRevision: UUID(), replies: -1, mentions: 1),
      InboxNotificationSnapshot(userID: 42, sessionRevision: UUID(), replies: 1, mentions: Int.max),
    ] {
      let bytes = try JSONEncoder().encode(value)
      defaults.set(bytes, forKey: DefaultsInboxNotificationStateStore.key)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(defaults.data(forKey: DefaultsInboxNotificationStateStore.key), bytes)
      XCTAssertThrowsError(try store.save(value))
    }
    for bytes in [Data("not json".utf8), Data(repeating: 0, count: 2_049)] {
      defaults.set(bytes, forKey: DefaultsInboxNotificationStateStore.key)
      XCTAssertThrowsError(try store.load())
      XCTAssertEqual(defaults.data(forKey: DefaultsInboxNotificationStateStore.key), bytes)
    }
    defaults.set("wrong type", forKey: DefaultsInboxNotificationStateStore.key)
    XCTAssertThrowsError(try store.load())
  }
}

@MainActor
final class InboxBackgroundRefreshRunTests: XCTestCase {
  func testExpirationCompletesOnceAndCancelsActualWorkEvenIfItLaterReportsSuccess() async {
    var results: [Bool] = []
    var cancellationCount = 0
    let run = InboxBackgroundRefreshRun(completion: { results.append($0) }) {
      cancellationCount += 1
    }
    let task = Task { @MainActor in
      while !Task.isCancelled { await Task.yield() }
      run.finish(success: true)
    }
    run.work = task
    run.cancel()
    run.cancel()
    await task.value
    XCTAssertTrue(task.isCancelled)
    XCTAssertEqual(results, [false])
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertNil(run.work)
  }

  func testSuccessBeforeExpirationDoesNotCancelOrCompleteTwice() {
    var results: [Bool] = []
    var cancellationCount = 0
    let run = InboxBackgroundRefreshRun(completion: { results.append($0) }) {
      cancellationCount += 1
    }
    run.finish(success: true)
    run.cancel()
    run.finish(success: false)
    XCTAssertEqual(results, [true])
    XCTAssertEqual(cancellationCount, 0)
  }
}
