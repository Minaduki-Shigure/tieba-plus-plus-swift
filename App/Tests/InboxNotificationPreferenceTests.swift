import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class InboxNotificationPreferenceTests: XCTestCase {
  func testDeniedPermissionLeavesPreferenceOffWithoutReadingAccountOrNetwork() async {
    let fixture = makeFixture()
    fixture.permission.granted = false

    await fixture.runtime.setEnabled(true)

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertFalse(fixture.runtime.isChangingPreference)
    XCTAssertFalse(fixture.defaults.bool(forKey: InboxNotificationRuntime.enabledKey))
    let reads = await fixture.vault.readCount
    let requests = await fixture.service.requestCount
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(requests, 0)
  }

  func testDisableWhilePermissionPromptIsPendingRejectsLateGrant() async throws {
    let fixture = makeFixture()
    fixture.permission.suspends = true
    let enable = Task { await fixture.runtime.setEnabled(true) }
    try await waitUntil { fixture.permission.pendingCount == 1 }
    XCTAssertTrue(fixture.runtime.isChangingPreference)

    await fixture.runtime.setEnabled(false)
    fixture.permission.resolve(at: 0, granted: true)
    await enable.value

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertFalse(fixture.runtime.isChangingPreference)
    XCTAssertFalse(fixture.defaults.bool(forKey: InboxNotificationRuntime.enabledKey))
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 0)
  }

  func testDisableWhileInitialBaselineIsSlowTakesEffectImmediately() async throws {
    let fixture = makeFixture()
    await fixture.service.setSuspended(true)
    let enable = Task { await fixture.runtime.setEnabled(true) }
    try await waitUntil { await fixture.service.isSuspended }
    XCTAssertTrue(fixture.runtime.isEnabled)
    // The UI must permit turning the feature back off while the count request is pending.
    XCTAssertFalse(fixture.runtime.isChangingPreference)

    await fixture.runtime.setEnabled(false)

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertFalse(fixture.defaults.bool(forKey: InboxNotificationRuntime.enabledKey))
    XCTAssertEqual(fixture.delivery.badge, 0)
    XCTAssertNil(fixture.defaults.object(forKey: DefaultsInboxNotificationStateStore.key))
    await fixture.service.release()
    await enable.value
    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertEqual(fixture.delivery.deliveryCount, 0)
    XCTAssertNil(fixture.defaults.object(forKey: DefaultsInboxNotificationStateStore.key))
  }

  func testOldPermissionCompletionCannotUnlockNewEnableAttempt() async throws {
    let fixture = makeFixture()
    fixture.permission.suspends = true
    let oldEnable = Task { await fixture.runtime.setEnabled(true) }
    try await waitUntil { fixture.permission.pendingCount == 1 }
    await fixture.runtime.setEnabled(false)
    let newEnable = Task { await fixture.runtime.setEnabled(true) }
    try await waitUntil { fixture.permission.pendingCount == 2 }

    fixture.permission.resolve(at: 0, granted: true)
    await oldEnable.value

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertTrue(fixture.runtime.isChangingPreference)
    fixture.permission.resolve(at: 1, granted: false)
    await newEnable.value
    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertFalse(fixture.runtime.isChangingPreference)
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 0)
  }

  func testAccountChangeDuringPermissionPromptPreventsLateEnable() async throws {
    let fixture = makeFixture()
    fixture.permission.suspends = true
    let enable = Task { await fixture.runtime.setEnabled(true) }
    try await waitUntil { fixture.permission.pendingCount == 1 }

    fixture.runtime.accountSessionDidChange()
    XCTAssertFalse(fixture.runtime.isChangingPreference)
    fixture.permission.resolve(at: 0, granted: true)
    await enable.value

    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertFalse(fixture.runtime.isChangingPreference)
    XCTAssertFalse(fixture.defaults.bool(forKey: InboxNotificationRuntime.enabledKey))
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 0)
  }

  func testAccountNotificationInvalidatesRouteBeforePostingReturns() throws {
    let fixture = makeFixture(enabled: true)
    let route = try XCTUnwrap(InboxNotificationRoute(
      identifier: InboxNotificationRoute.notificationIdentifier(for: .replies),
      userInfo: ["kind": "replies", "sessionRevision": UUID().uuidString]
    ))
    fixture.runtime.receive(route)
    XCTAssertEqual(fixture.runtime.pendingRoute, route)

    AccountChangeNotifications.postSessionChange(.switchAccount, accountID: 200)

    XCTAssertNil(fixture.runtime.pendingRoute)
  }

  func testOlderStatusLookupCannotOverwriteNewerRevokedPermission() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.delivery.suspendsAuthorization = true
    let older = Task { await fixture.runtime.refreshStatus() }
    try await waitUntil { fixture.delivery.pendingAuthorizationCount == 1 }
    let newer = Task { await fixture.runtime.refreshStatus() }
    try await waitUntil { fixture.delivery.pendingAuthorizationCount == 2 }

    fixture.delivery.resolveAuthorization(at: 1, authorized: false)
    await newer.value
    let deniedMessage = fixture.runtime.statusMessage
    XCTAssertEqual(deniedMessage, "系统通知权限未开启，请前往系统设置允许通知。")

    fixture.delivery.resolveAuthorization(at: 0, authorized: true)
    await older.value

    XCTAssertEqual(fixture.runtime.statusMessage, deniedMessage)
  }

  private func makeFixture(enabled: Bool = false) -> InboxPreferenceFixture {
    let suite = "InboxNotificationPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(enabled, forKey: InboxNotificationRuntime.enabledKey)
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return InboxPreferenceFixture(defaults: defaults)
  }

  private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw InboxPreferenceTestError.didNotSuspend
  }
}

@MainActor
private final class InboxPreferenceFixture {
  let defaults: UserDefaults
  let permission = InboxPreferencePermissionSpy()
  let delivery = InboxPreferenceDeliverySpy()
  let service = InboxPreferenceServiceSpy()
  let vault = InboxPreferenceVaultSpy()
  let runtime: InboxNotificationRuntime

  init(defaults: UserDefaults) {
    self.defaults = defaults
    let permission = permission
    let scheduling = InboxNotificationScheduling(
      enabled: defaults.bool(forKey: InboxNotificationRuntime.enabledKey),
      isBackgroundRefreshAvailable: { false },
      isAuthorized: { true },
      submit: { _ in XCTFail("Preference tests must not submit a background job") },
      cancel: {}
    )
    runtime = InboxNotificationRuntime(
      defaults: defaults, delivery: delivery, vault: vault, scheduling: scheduling,
      requestAuthorization: { await permission.request() }
    )
    runtime.configure(service: service, vault: vault)
  }
}

@MainActor
private final class InboxPreferencePermissionSpy {
  var granted = true
  var suspends = false
  private var continuations: [CheckedContinuation<Bool, Never>?] = []
  var pendingCount: Int { continuations.count }

  func request() async -> Bool {
    guard suspends else { return granted }
    return await withCheckedContinuation { continuations.append($0) }
  }

  func resolve(at index: Int, granted: Bool) {
    let continuation = continuations[index]
    continuations[index] = nil
    continuation?.resume(returning: granted)
  }
}

@MainActor
private final class InboxPreferenceDeliverySpy: InboxNotificationDelivering {
  var badge = 0
  var deliveryCount = 0
  var suspendsAuthorization = false
  private var authorizations: [CheckedContinuation<Bool, Never>?] = []
  var pendingAuthorizationCount: Int { authorizations.count }

  func isAuthorized() async -> Bool {
    guard suspendsAuthorization else { return true }
    return await withCheckedContinuation { authorizations.append($0) }
  }

  func resolveAuthorization(at index: Int, authorized: Bool) {
    let continuation = authorizations[index]
    authorizations[index] = nil
    continuation?.resume(returning: authorized)
  }
  func deliver(kind: InboxKind, count: Int, totalCount: Int, sessionRevision: UUID) async throws {
    deliveryCount += 1
    badge = totalCount
  }
  func clear(kind: InboxKind) {}
  func clearAll() { badge = 0 }
  func setBadgeCount(_ count: Int) { badge = count }
}

private actor InboxPreferenceServiceSpy: AccountService {
  private var shouldSuspend = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var requestCount = 0
  var isSuspended: Bool { continuation != nil }
  func setSuspended(_ suspended: Bool) { shouldSuspend = suspended }
  func release() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
  func inboxUnreadSummary(session: StoredAccountSession) async throws -> InboxUnreadSummary {
    requestCount += 1
    if shouldSuspend { await withCheckedContinuation { continuation = $0 } }
    return InboxUnreadSummary(userID: session.id, replyCount: 7, mentionCount: 3, fanCount: nil)
  }
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw InboxPreferenceTestError.unexpectedRequest
  }
  func followedForums(
    session: StoredAccountSession, page: Int, pageSize: Int
  ) async throws -> FollowedForumPageData { throw InboxPreferenceTestError.unexpectedRequest }
  func forumMembership(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumMembershipData { throw InboxPreferenceTestError.unexpectedRequest }
  func forumAccountState(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumAccountStateData { throw InboxPreferenceTestError.unexpectedRequest }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData { throw InboxPreferenceTestError.unexpectedRequest }
  func checkInToForum(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumAccountStateData { throw InboxPreferenceTestError.unexpectedRequest }
}

private actor InboxPreferenceVaultSpy: AccountVault {
  private(set) var readCount = 0
  private let session = StoredAccountSession(
    id: 100, username: "notification-test", displayName: "消息测试", portrait: "",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
  )
  func activeSession() async throws -> StoredAccountSession? { readCount += 1; return session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws {
    throw InboxPreferenceTestError.unexpectedRequest
  }
  func switchActive(to userID: Int64) async throws { throw InboxPreferenceTestError.unexpectedRequest }
  func remove(userID: Int64) async throws { throw InboxPreferenceTestError.unexpectedRequest }
  func removeAll() async throws { throw InboxPreferenceTestError.unexpectedRequest }
}

private enum InboxPreferenceTestError: Error {
  case didNotSuspend, unexpectedRequest
}
