import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class InboxNotificationRoutingTests: XCTestCase {
  func testExactSessionRoutesEachChannelWithoutRegisteringOrRequestingAuthorization() async throws {
    let fixture = makeFixture()
    let initialReads = await fixture.vault.readCount
    XCTAssertEqual(initialReads, 0)
    XCTAssertEqual(fixture.delivery.authorizationChecks, 0)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
    XCTAssertEqual(fixture.delivery.clearAllCount, 0)

    for kind in InboxKind.allCases {
      let route = try makeRoute(kind: kind, revision: fixture.session.sessionRevision)
      fixture.runtime.receive(route)
      XCTAssertEqual(fixture.runtime.pendingRoute, route)

      let destination = await fixture.runtime.consume(route)

      XCTAssertEqual(destination, kind)
      XCTAssertNil(fixture.runtime.pendingRoute)
    }

    XCTAssertEqual(fixture.delivery.cleared, InboxKind.allCases)
    XCTAssertEqual(fixture.delivery.authorizationChecks, 0)
    XCTAssertEqual(fixture.delivery.deliveryCount, 0)
    let switches = await fixture.vault.switchRequests
    XCTAssertTrue(switches.isEmpty)
  }

  func testDisabledPreferenceIgnoresNotificationWithoutReadingAccount() async throws {
    let fixture = makeFixture(enabled: false)
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    fixture.runtime.receive(route)

    let destination = await fixture.runtime.consume(route)

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertNil(destination)
    let reads = await fixture.vault.readCount
    XCTAssertEqual(reads, 0)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
  }

  func testOldRevisionAfterSameAccountReloginIsDiscarded() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    await fixture.vault.replace(makeSession(id: fixture.session.id))
    fixture.runtime.receive(route)

    let destination = await fixture.runtime.consume(route)

    XCTAssertNil(destination)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
    let switches = await fixture.vault.switchRequests
    XCTAssertTrue(switches.isEmpty)
  }

  func testNotificationForAnotherAccountNeverSwitchesActiveAccount() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    let replacement = makeSession(id: 200)
    await fixture.vault.replace(replacement)
    fixture.runtime.receive(route)

    let destination = await fixture.runtime.consume(route)

    XCTAssertNil(destination)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
    let switches = await fixture.vault.switchRequests
    let activeID = await fixture.vault.currentSessionID
    XCTAssertTrue(switches.isEmpty)
    XCTAssertEqual(activeID, replacement.id)
  }

  func testLoggedOutAccountDiscardsNotification() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    await fixture.vault.replace(nil)
    fixture.runtime.receive(route)

    let destination = await fixture.runtime.consume(route)

    XCTAssertNil(destination)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
    let switches = await fixture.vault.switchRequests
    XCTAssertTrue(switches.isEmpty)
  }

  func testRouteMustBePendingBeforeAccountRead() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)

    let destination = await fixture.runtime.consume(route)

    XCTAssertNil(destination)
    let reads = await fixture.vault.readCount
    XCTAssertEqual(reads, 0)
  }

  func testConcurrentDuplicateConsumptionNavigatesOnlyOnce() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    fixture.runtime.receive(route)
    await fixture.vault.suspendNextRead()
    let first = Task { await fixture.runtime.consume(route) }
    try await waitUntilSuspended(fixture.vault)

    let secondResult = await fixture.runtime.consume(route)
    await fixture.vault.release()
    let firstResult = await first.value
    let repeatedResult = await fixture.runtime.consume(route)

    XCTAssertEqual(secondResult, .replies)
    XCTAssertNil(firstResult)
    XCTAssertNil(repeatedResult)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertEqual(fixture.delivery.cleared, [.replies])
  }

  func testSuspendedOldRouteCannotClearNewerNotification() async throws {
    let fixture = makeFixture()
    let firstRoute = try makeRoute(revision: fixture.session.sessionRevision)
    let newerRoute = try makeRoute(kind: .mentions, revision: fixture.session.sessionRevision)
    fixture.runtime.receive(firstRoute)
    await fixture.vault.suspendNextRead()
    let first = Task { await fixture.runtime.consume(firstRoute) }
    try await waitUntilSuspended(fixture.vault)

    fixture.runtime.receive(newerRoute)
    await fixture.vault.release()
    let firstResult = await first.value

    XCTAssertNil(firstResult)
    XCTAssertEqual(fixture.runtime.pendingRoute, newerRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)

    let newerResult = await fixture.runtime.consume(newerRoute)
    XCTAssertEqual(newerResult, .mentions)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertEqual(fixture.delivery.cleared, [.mentions])
  }

  func testAccountChangeInvalidatesSuspendedMatchingSessionSnapshot() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    fixture.runtime.receive(route)
    await fixture.vault.suspendNextRead()
    let consumption = Task { await fixture.runtime.consume(route) }
    try await waitUntilSuspended(fixture.vault)

    await fixture.vault.replace(makeSession(id: 200))
    fixture.runtime.accountSessionDidChange()
    await fixture.vault.release()
    let destination = await consumption.value

    XCTAssertNil(destination)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
    XCTAssertEqual(fixture.delivery.clearAllCount, 1)
    let switches = await fixture.vault.switchRequests
    XCTAssertTrue(switches.isEmpty)
  }

  func testUnavailableVaultDiscardsRouteWithoutNavigation() async throws {
    let fixture = makeFixture()
    let route = try makeRoute(revision: fixture.session.sessionRevision)
    await fixture.vault.setFailure(true)
    fixture.runtime.receive(route)

    let destination = await fixture.runtime.consume(route)

    XCTAssertNil(destination)
    XCTAssertNil(fixture.runtime.pendingRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
  }

  func testUnavailableOldReadCannotClearNewerNotification() async throws {
    let fixture = makeFixture()
    let firstRoute = try makeRoute(revision: fixture.session.sessionRevision)
    let newerRoute = try makeRoute(kind: .mentions, revision: fixture.session.sessionRevision)
    fixture.runtime.receive(firstRoute)
    await fixture.vault.suspendNextRead()
    let consumption = Task { await fixture.runtime.consume(firstRoute) }
    try await waitUntilSuspended(fixture.vault)

    fixture.runtime.receive(newerRoute)
    await fixture.vault.setFailure(true)
    await fixture.vault.release()
    let destination = await consumption.value

    XCTAssertNil(destination)
    XCTAssertEqual(fixture.runtime.pendingRoute, newerRoute)
    XCTAssertTrue(fixture.delivery.cleared.isEmpty)
  }

  private func makeFixture(enabled: Bool = true) -> InboxRoutingFixture {
    let suiteName = "InboxNotificationRoutingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(enabled, forKey: InboxNotificationRuntime.enabledKey)
    addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let session = makeSession()
    let vault = InboxRoutingVaultSpy(session: session)
    let delivery = InboxRoutingDeliverySpy()
    return InboxRoutingFixture(
      runtime: InboxNotificationRuntime(defaults: defaults, delivery: delivery, vault: vault),
      delivery: delivery,
      vault: vault,
      session: session
    )
  }

  private func makeRoute(kind: InboxKind = .replies, revision: UUID) throws
    -> InboxNotificationRoute
  {
    try XCTUnwrap(InboxNotificationRoute(
      identifier: InboxNotificationRoute.notificationIdentifier(for: kind),
      userInfo: ["kind": kind.rawValue, "sessionRevision": revision.uuidString]
    ))
  }

  private func makeSession(id: Int64 = 100) -> StoredAccountSession {
    StoredAccountSession(
      id: id,
      username: "notification-test",
      displayName: "消息测试",
      portrait: "",
      bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
      createdAt: Date(timeIntervalSince1970: 1_000),
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )
  }

  private func waitUntilSuspended(_ vault: InboxRoutingVaultSpy) async throws {
    for _ in 0..<200 {
      if await vault.isSuspended { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    await vault.release()
    throw InboxRoutingTestError.suspensionTimedOut
  }
}

@MainActor
private struct InboxRoutingFixture {
  let runtime: InboxNotificationRuntime
  let delivery: InboxRoutingDeliverySpy
  let vault: InboxRoutingVaultSpy
  let session: StoredAccountSession
}

@MainActor
private final class InboxRoutingDeliverySpy: InboxNotificationDelivering {
  private(set) var authorizationChecks = 0
  private(set) var deliveryCount = 0
  private(set) var cleared: [InboxKind] = []
  private(set) var clearAllCount = 0

  func isAuthorized() async -> Bool {
    authorizationChecks += 1
    return true
  }

  func deliver(kind: InboxKind, count: Int, totalCount: Int, sessionRevision: UUID) async throws {
    deliveryCount += 1
  }

  func clear(kind: InboxKind) { cleared.append(kind) }
  func clearAll() { clearAllCount += 1 }
  func setBadgeCount(_ count: Int) {}
}

private enum InboxRoutingTestError: Error {
  case unavailable
  case unexpectedMutation
  case suspensionTimedOut
}

private actor InboxRoutingVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var fails = false
  private var suspendsNext = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var readCount = 0
  private(set) var switchRequests: [Int64] = []
  var currentSessionID: Int64? { session?.id }
  var isSuspended: Bool { continuation != nil }

  init(session: StoredAccountSession) { self.session = session }
  func replace(_ session: StoredAccountSession?) { self.session = session }
  func setFailure(_ fails: Bool) { self.fails = fails }
  func suspendNextRead() { suspendsNext = true }

  func release() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }

  func activeSession() async throws -> StoredAccountSession? {
    readCount += 1
    // Return the snapshot from before suspension to exercise stale async completions.
    let snapshot = session
    if suspendsNext {
      suspendsNext = false
      await withCheckedContinuation { continuation = $0 }
    }
    if fails { throw InboxRoutingTestError.unavailable }
    return snapshot
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws {
    throw InboxRoutingTestError.unexpectedMutation
  }
  func switchActive(to userID: Int64) async throws {
    switchRequests.append(userID)
    throw InboxRoutingTestError.unexpectedMutation
  }
  func remove(userID: Int64) async throws { throw InboxRoutingTestError.unexpectedMutation }
  func removeAll() async throws { throw InboxRoutingTestError.unexpectedMutation }
}
