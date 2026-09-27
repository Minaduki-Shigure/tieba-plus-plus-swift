import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class InboxNotificationCoordinatorTests: XCTestCase {
  func testDefaultOffAndDeniedPermissionNeverReadAccountOrNetwork() async {
    let fixture = InboxNotificationFixture()
    let disabled = await fixture.coordinator.runRefresh()
    XCTAssertFalse(disabled)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.authorized = false
    let denied = await fixture.coordinator.runRefresh()
    XCTAssertFalse(denied)
    let requests = await fixture.service.requestCount
    let vaultReads = await fixture.vault.readCount
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(vaultReads, 0)
    XCTAssertEqual(fixture.coordinator.lastOutcome, .notAuthorized)
  }

  func testFirstSnapshotIsSilentAndIncreaseDecreaseZeroAndRelaunchDeduplicate() async {
    let fixture = InboxNotificationFixture()
    fixture.coordinator.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 3, mentions: 2, fans: 99))
    let first = await fixture.coordinator.runRefresh()
    XCTAssertTrue(first)
    XCTAssertEqual(fixture.coordinator.lastOutcome, .baselineEstablished)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
    XCTAssertEqual(fixture.delivery.badge, 5)

    await fixture.service.append(fixture.summary(replies: 5, mentions: 2, fans: 100))
    let increase = await fixture.coordinator.runRefresh()
    XCTAssertTrue(increase)
    XCTAssertEqual(fixture.delivery.attempts.map(\.kind), [.replies])
    XCTAssertEqual(fixture.delivery.attempts.first?.count, 5)
    XCTAssertEqual(fixture.delivery.badge, 7)

    let relaunched = fixture.makeCoordinator()
    relaunched.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 5, mentions: 2, fans: 101))
    let repeatRefresh = await relaunched.runRefresh()
    XCTAssertTrue(repeatRefresh)
    XCTAssertEqual(fixture.delivery.attempts.count, 1)

    await fixture.service.append(fixture.summary(replies: 1, mentions: 0))
    let decrease = await relaunched.runRefresh()
    XCTAssertTrue(decrease)
    XCTAssertEqual(fixture.store.snapshot?.replies, 1)
    XCTAssertEqual(fixture.store.snapshot?.mentions, 0)
    XCTAssertEqual(fixture.delivery.badge, 1)
    XCTAssertTrue(fixture.delivery.cleared.contains(.mentions))
    XCTAssertNil(fixture.delivery.visible[.replies])

    await fixture.service.append(fixture.summary(replies: 0, mentions: 1))
    let mention = await relaunched.runRefresh()
    XCTAssertTrue(mention)
    XCTAssertEqual(fixture.delivery.attempts.map(\.kind), [.replies, .mentions])
    XCTAssertNil(fixture.delivery.visible[.replies])
    XCTAssertEqual(fixture.delivery.badge, 1)
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 5)
  }

  func testFailedSecondDeliveryRetriesOnlyThatChannel() async {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.failKinds = [.mentions]
    await fixture.service.append(fixture.summary(replies: 2, mentions: 3))
    let failed = await fixture.coordinator.runRefresh()
    XCTAssertFalse(failed)
    XCTAssertEqual(fixture.store.snapshot?.replies, 2)
    XCTAssertEqual(fixture.store.snapshot?.mentions, 1)
    XCTAssertNil(fixture.delivery.visible[.mentions])

    fixture.delivery.failKinds = []
    await fixture.service.append(fixture.summary(replies: 2, mentions: 3))
    let retry = await fixture.coordinator.runRefresh()
    XCTAssertTrue(retry)
    XCTAssertEqual(fixture.delivery.attempts.map(\.kind), [.replies, .mentions, .mentions])
    XCTAssertEqual(fixture.store.snapshot?.mentions, 3)
  }

  func testMalformedUIDOrCountsCannotNotifyOrOverwriteBaseline() async {
    let fixture = InboxNotificationFixture(replies: 2, mentions: 3)
    fixture.coordinator.setEnabled(true)
    let before = fixture.store.snapshot
    let invalid = [
      InboxUnreadSummary(userID: 99, replyCount: 10, mentionCount: 10, fanCount: nil),
      fixture.summary(replies: -1, mentions: 4),
      fixture.summary(replies: 4, mentions: Int(Int32.max) + 1),
    ]
    for response in invalid {
      await fixture.service.append(response)
      let result = await fixture.coordinator.runRefresh()
      XCTAssertFalse(result)
      XCTAssertEqual(fixture.coordinator.lastOutcome, .invalidResponse)
      XCTAssertEqual(fixture.store.snapshot, before)
    }
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
  }

  func testMalformedPersistedSnapshotAndCredentialRotationStartSilentBaseline() async {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.store.snapshot = InboxNotificationSnapshot(
      userID: fixture.session.id, sessionRevision: fixture.session.sessionRevision,
      replies: 1, mentions: 1, version: 99
    )
    fixture.coordinator.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 10, mentions: 5))
    let first = await fixture.coordinator.runRefresh()
    XCTAssertTrue(first)
    XCTAssertEqual(fixture.store.snapshot?.version, 1)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)

    let rotated = inboxNotificationSession(userID: fixture.session.id)
    await fixture.vault.replace(rotated)
    await fixture.service.append(fixture.summary(replies: 12, mentions: 6))
    let next = await fixture.coordinator.runRefresh()
    XCTAssertTrue(next)
    XCTAssertEqual(fixture.store.snapshot?.sessionRevision, rotated.sessionRevision)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
  }

  func testLockedVaultAndStoreErrorsDoNotInventZeroOrNotify() async {
    let fixture = InboxNotificationFixture(replies: 4, mentions: 5)
    fixture.coordinator.setEnabled(true)
    let before = fixture.store.snapshot
    await fixture.vault.setFailure(true)
    let locked = await fixture.coordinator.runRefresh()
    XCTAssertFalse(locked)
    XCTAssertEqual(fixture.store.snapshot, before)
    let requestsBefore = await fixture.service.requestCount
    XCTAssertEqual(requestsBefore, 0)

    await fixture.vault.setFailure(false)
    fixture.store.failLoads = true
    let loadFailed = await fixture.coordinator.runRefresh()
    XCTAssertFalse(loadFailed)
    fixture.store.failLoads = false
    fixture.store.failSaves = true
    await fixture.service.append(fixture.summary(replies: 5, mentions: 6))
    let saveFailed = await fixture.coordinator.runRefresh()
    XCTAssertFalse(saveFailed)
    XCTAssertEqual(fixture.store.snapshot, before)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
  }

  func testFailedBaselineDeletionCannotReusePriorCounts() async {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.store.failSaves = true
    fixture.coordinator.accountSessionDidChange()
    let failed = await fixture.coordinator.runRefresh()
    XCTAssertFalse(failed)
    let requestsBefore = await fixture.service.requestCount
    XCTAssertEqual(requestsBefore, 0)
    fixture.store.failSaves = false
    await fixture.service.append(fixture.summary(replies: 9, mentions: 9))
    let next = await fixture.coordinator.runRefresh()
    XCTAssertTrue(next)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 9)
  }

  func testPersistenceFailureAfterDeliveryClearsAlertAndAllowsRetry() async {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.store.failSaveAt = 2
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let failed = await fixture.coordinator.runRefresh()
    XCTAssertFalse(failed)
    XCTAssertEqual(fixture.store.snapshot?.replies, 1)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertEqual(fixture.delivery.badge, 2)
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let retried = await fixture.coordinator.runRefresh()
    XCTAssertTrue(retried)
    XCTAssertEqual(fixture.delivery.visible[.replies], 2)
    XCTAssertEqual(fixture.store.snapshot?.replies, 2)
  }

  func testPermissionRevokedWhileReadingPreventsDeliveryAndBaselineAdvance() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1), suspended: true)
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { await fixture.service.isSuspended }
    fixture.delivery.authorized = false
    await fixture.service.release()
    let denied = await refresh.value
    XCTAssertFalse(denied)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 1)
  }

  func testNoActiveAccountClearsKnownPriorSnapshotWithoutNetworkRequest() async {
    let fixture = InboxNotificationFixture(replies: 4, mentions: 5)
    fixture.coordinator.setEnabled(true)
    await fixture.vault.replace(nil)
    let result = await fixture.coordinator.runRefresh()
    XCTAssertFalse(result)
    XCTAssertNil(fixture.store.snapshot)
    XCTAssertEqual(fixture.delivery.badge, 0)
    XCTAssertEqual(fixture.coordinator.lastOutcome, .noAccount)
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 0)
  }

  func testSwitchWhileReadIsSuspendedDiscardsOldResponse() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 9, mentions: 9), suspended: true)
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { await fixture.service.isSuspended }
    let nextSession = inboxNotificationSession(userID: 8)
    await fixture.vault.replace(nextSession)
    fixture.coordinator.accountSessionDidChange()
    XCTAssertNil(fixture.store.snapshot)
    await fixture.service.release()
    let result = await refresh.value
    XCTAssertFalse(result)
    XCTAssertNil(fixture.store.snapshot)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
  }

  func testSessionChangeWithoutNotificationIsDetectedAfterDeliveryAndCleared() async {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    let nextSession = inboxNotificationSession(userID: 8)
    fixture.delivery.onDelivery = { await fixture.vault.replace(nextSession) }
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let result = await fixture.coordinator.runRefresh()
    XCTAssertFalse(result)
    XCTAssertNil(fixture.store.snapshot)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertEqual(fixture.delivery.badge, 0)
  }

  func testVaultFailureAfterDeliveryRemovesUnverifiedAlertWithoutReplacingCountsWithZero() async {
    let fixture = InboxNotificationFixture(replies: 2, mentions: 3)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.onDelivery = { await fixture.vault.setFailure(true) }
    await fixture.service.append(fixture.summary(replies: 9, mentions: 3))
    let result = await fixture.coordinator.runRefresh()
    XCTAssertFalse(result)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 2)
    XCTAssertEqual(fixture.store.snapshot?.mentions, 3)
    XCTAssertEqual(fixture.delivery.badge, 5)
  }

  func testCancelledNoncooperativeDeliveryRetainsExclusiveGateUntilCleanup() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.suspends = true
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { fixture.delivery.isSuspended }
    refresh.cancel()
    fixture.coordinator.cancelRefresh()
    let concurrent = await fixture.coordinator.runRefresh()
    XCTAssertFalse(concurrent)
    XCTAssertTrue(fixture.coordinator.isRunning)
    fixture.delivery.release()
    let cancelled = await refresh.value
    XCTAssertFalse(cancelled)
    XCTAssertFalse(fixture.coordinator.isRunning)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 1)

    fixture.delivery.suspends = false
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let retry = await fixture.coordinator.runRefresh()
    XCTAssertTrue(retry)
    XCTAssertEqual(fixture.delivery.visible[.replies], 2)
    let requests = await fixture.service.requestCount
    XCTAssertEqual(requests, 2)
  }

  func testCallerCancellationPropagatesToActualNetworkTask() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1), suspended: true)
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { await fixture.service.isSuspended }
    refresh.cancel()
    await fixture.service.release()
    let result = await refresh.value
    let observedCancellation = await fixture.service.observedCancellation
    XCTAssertFalse(result)
    XCTAssertTrue(observedCancellation)
    XCTAssertTrue(fixture.delivery.attempts.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 1)
  }

  func testDisableAndReenableCannotPublishLateDeliveryOrAnnounceBacklog() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.suspends = true
    await fixture.service.append(fixture.summary(replies: 2, mentions: 1))
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { fixture.delivery.isSuspended }
    fixture.coordinator.setEnabled(false)
    XCTAssertNil(fixture.store.snapshot)
    XCTAssertEqual(fixture.delivery.badge, 0)
    fixture.coordinator.setEnabled(true)
    let busy = await fixture.coordinator.runRefresh()
    XCTAssertFalse(busy)
    fixture.delivery.release()
    let old = await refresh.value
    XCTAssertFalse(old)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertNil(fixture.store.snapshot)

    fixture.delivery.suspends = false
    await fixture.service.append(fixture.summary(replies: 5, mentions: 6))
    let baseline = await fixture.coordinator.runRefresh()
    XCTAssertTrue(baseline)
    XCTAssertEqual(fixture.delivery.attempts.count, 1)
    XCTAssertEqual(fixture.delivery.badge, 11)
  }

  func testForegroundSummaryWinsOverPendingBackgroundDeliveryAndRestoresBadge() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    fixture.delivery.suspends = true
    await fixture.service.append(fixture.summary(replies: 9, mentions: 9))
    let refresh = Task { await fixture.coordinator.runRefresh() }
    try await waitForInboxNotification { fixture.delivery.isSuspended }
    await fixture.coordinator.observeForeground(
      summary: fixture.summary(replies: 0, mentions: 2),
      sessionRevision: fixture.session.sessionRevision
    )
    XCTAssertEqual(fixture.store.snapshot?.replies, 0)
    XCTAssertEqual(fixture.delivery.badge, 2)
    fixture.delivery.release()
    let old = await refresh.value
    XCTAssertFalse(old)
    XCTAssertTrue(fixture.delivery.visible.isEmpty)
    XCTAssertEqual(fixture.store.snapshot?.replies, 0)
    XCTAssertEqual(fixture.store.snapshot?.mentions, 2)
    XCTAssertEqual(fixture.delivery.badge, 2)
  }

  func testNewestForegroundObservationWinsReorderedVaultReads() async throws {
    let fixture = InboxNotificationFixture(replies: 1, mentions: 1)
    fixture.coordinator.setEnabled(true)
    await fixture.vault.suspendNextRead()
    let earlier = Task {
      await fixture.coordinator.observeForeground(
        summary: fixture.summary(replies: 9, mentions: 9),
        sessionRevision: fixture.session.sessionRevision
      )
    }
    try await waitForInboxNotification { await fixture.vault.isSuspended }
    await fixture.coordinator.observeForeground(
      summary: fixture.summary(replies: 0, mentions: 0),
      sessionRevision: fixture.session.sessionRevision
    )
    await fixture.vault.release()
    await earlier.value
    XCTAssertEqual(fixture.store.snapshot?.replies, 0)
    XCTAssertEqual(fixture.store.snapshot?.mentions, 0)
    XCTAssertEqual(fixture.delivery.badge, 0)
    await fixture.coordinator.observeForeground(
      summary: fixture.summary(replies: 20, mentions: 20), sessionRevision: UUID()
    )
    XCTAssertEqual(fixture.store.snapshot?.replies, 0)
  }

  func testSnapshotRoundTripAndLimits() throws {
    let snapshot = InboxNotificationSnapshot(
      userID: 7, sessionRevision: UUID(), replies: Int(Int32.max), mentions: 0
    )
    XCTAssertTrue(snapshot.isValid)
    XCTAssertEqual(try JSONDecoder().decode(
      InboxNotificationSnapshot.self, from: JSONEncoder().encode(snapshot)
    ), snapshot)
    XCTAssertFalse(InboxNotificationSnapshot(
      userID: 7, sessionRevision: UUID(), replies: -1, mentions: 0
    ).isValid)
  }
}

@MainActor
private final class InboxNotificationFixture {
  let session = inboxNotificationSession(userID: 7)
  let service = InboxNotificationServiceSpy()
  let store = InboxNotificationStateSpy()
  let delivery = InboxNotificationDeliverySpy()
  let vault: InboxNotificationVaultSpy
  lazy var coordinator = makeCoordinator()

  init(replies: Int? = nil, mentions: Int = 0) {
    vault = InboxNotificationVaultSpy(session: session)
    if let replies {
      store.snapshot = InboxNotificationSnapshot(
        userID: session.id, sessionRevision: session.sessionRevision,
        replies: replies, mentions: mentions
      )
    }
  }

  func makeCoordinator() -> InboxNotificationCoordinator {
    InboxNotificationCoordinator(service: service, vault: vault, store: store, delivery: delivery)
  }

  func summary(replies: Int, mentions: Int, fans: Int? = nil) -> InboxUnreadSummary {
    InboxUnreadSummary(
      userID: session.id, replyCount: replies, mentionCount: mentions, fanCount: fans
    )
  }
}

private func inboxNotificationSession(userID: Int64) -> StoredAccountSession {
  StoredAccountSession(
    id: userID, username: "test", displayName: "test", portrait: "",
    bduss: String(repeating: "b", count: 192),
    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
  )
}

private enum InboxNotificationTestError: Error { case failed }

@MainActor
private final class InboxNotificationStateSpy: InboxNotificationStateStoring {
  var snapshot: InboxNotificationSnapshot?
  var failLoads = false
  var failSaves = false
  var failSaveAt: Int?
  var saveCount = 0
  func load() throws -> InboxNotificationSnapshot? {
    if failLoads { throw InboxNotificationTestError.failed }
    return snapshot
  }
  func save(_ snapshot: InboxNotificationSnapshot?) throws {
    saveCount += 1
    if failSaves || failSaveAt == saveCount { throw InboxNotificationTestError.failed }
    self.snapshot = snapshot
  }
}

@MainActor
private final class InboxNotificationDeliverySpy: InboxNotificationDelivering {
  struct Attempt {
    let kind: InboxKind
    let count: Int
    let sessionRevision: UUID
  }
  var authorized = true
  var suspends = false
  var failKinds: Set<InboxKind> = []
  var onDelivery: (@MainActor () async -> Void)?
  var attempts: [Attempt] = []
  var visible: [InboxKind: Int] = [:]
  var cleared: [InboxKind] = []
  var badge = 0
  private var continuation: CheckedContinuation<Void, Never>?
  var isSuspended: Bool { continuation != nil }

  func isAuthorized() async -> Bool { authorized }
  func deliver(kind: InboxKind, count: Int, totalCount: Int, sessionRevision: UUID) async throws {
    attempts.append(Attempt(kind: kind, count: count, sessionRevision: sessionRevision))
    if suspends { await withCheckedContinuation { continuation = $0 } }
    visible[kind] = count
    badge = totalCount
    await onDelivery?()
    if failKinds.contains(kind) { throw InboxNotificationTestError.failed }
  }
  func release() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
  func clear(kind: InboxKind) { cleared.append(kind); visible[kind] = nil }
  func clearAll() { visible.removeAll(); badge = 0 }
  func setBadgeCount(_ count: Int) { badge = count }
}

private actor InboxNotificationServiceSpy: AccountService {
  private var scripts: [(InboxUnreadSummary, Bool)] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var requestCount = 0
  private(set) var observedCancellation = false
  var isSuspended: Bool { continuation != nil }

  func append(_ summary: InboxUnreadSummary, suspended: Bool = false) {
    scripts.append((summary, suspended))
  }
  func inboxUnreadSummary(session: StoredAccountSession) async throws -> InboxUnreadSummary {
    requestCount += 1
    guard !scripts.isEmpty else { throw InboxNotificationTestError.failed }
    let (summary, suspended) = scripts.removeFirst()
    if suspended { await withCheckedContinuation { continuation = $0 } }
    observedCancellation = Task.isCancelled
    return summary
  }
  func release() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw InboxNotificationTestError.failed
  }
  func followedForums(
    session: StoredAccountSession, page: Int, pageSize: Int
  ) async throws -> FollowedForumPageData { throw InboxNotificationTestError.failed }
  func forumMembership(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumMembershipData { throw InboxNotificationTestError.failed }
  func forumAccountState(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumAccountStateData { throw InboxNotificationTestError.failed }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData { throw InboxNotificationTestError.failed }
  func checkInToForum(
    session: StoredAccountSession, forumID: Int64, forumName: String
  ) async throws -> ForumAccountStateData { throw InboxNotificationTestError.failed }
}

private actor InboxNotificationVaultSpy: AccountVault {
  var session: StoredAccountSession?
  var fails = false
  private var suspendsNext = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var readCount = 0
  var isSuspended: Bool { continuation != nil }
  init(session: StoredAccountSession?) { self.session = session }
  func replace(_ session: StoredAccountSession?) { self.session = session }
  func setFailure(_ value: Bool) { fails = value }
  func suspendNextRead() { suspendsNext = true }
  func release() {
    let pending = continuation
    continuation = nil
    pending?.resume()
  }
  func activeSession() async throws -> StoredAccountSession? {
    readCount += 1
    if suspendsNext {
      suspendsNext = false
      await withCheckedContinuation { continuation = $0 }
    }
    if fails { throw InboxNotificationTestError.failed }
    return session
  }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws { throw InboxNotificationTestError.failed }
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

@MainActor
private func waitForInboxNotification(
  _ predicate: @MainActor () async -> Bool
) async throws {
  for _ in 0..<200 {
    if await predicate() { return }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  throw InboxNotificationTestError.failed
}
