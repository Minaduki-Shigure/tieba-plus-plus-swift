import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ThreadSummaryAgreementMenuTests: XCTestCase {
  func testSummaryTargetRequiresExplicitFirstFloorAndCompleteForumIdentity() throws {
    // The same row is used by discovery, forum and public-profile topic lists.
    for thread in [
      makeSummary(firstPostID: 100, contentPostID: 100),
      makeSummary(firstPostID: 100, contentPostID: 0),
      makeSummary(firstPostID: 100, contentPostID: 999),
    ] {
      let target = try XCTUnwrap(ThreadSummaryAgreementPolicy.target(for: thread))
      XCTAssertEqual(target.kind, .topic)
      XCTAssertEqual(target.objectID, 100)
      XCTAssertEqual(target.threadID, thread.id)
      XCTAssertEqual(target.forumID, thread.forumID)
      // An added long-press action must not replace ordinary thread navigation.
      XCTAssertEqual(ThreadSummaryNavigationPolicy.primaryRequest(for: thread)?.thread, thread)
    }

    XCTAssertNil(
      ThreadSummaryAgreementPolicy.target(for: makeSummary(firstPostID: 0, contentPostID: 999)))
    XCTAssertNil(ThreadSummaryAgreementPolicy.target(for: makeSummary(firstPostID: -1)))
    XCTAssertNil(ThreadSummaryAgreementPolicy.target(for: makeSummary(forumID: 0)))
    XCTAssertNil(ThreadSummaryAgreementPolicy.target(for: makeSummary(forumName: " \n")))
    XCTAssertNil(ThreadSummaryAgreementPolicy.target(for: makeSummary(id: 0)))
    XCTAssertNil(ThreadSummaryAgreementPolicy.target(for: makeSummary(isServerHidden: true)))
    XCTAssertNil(
      ThreadSummaryAgreementPolicy.target(
        for: makeSummary().withLocalVisibility(.placeholder)
      )
    )
  }

  func testUnknownMenuOffersExplicitIntentsInsteadOfGuessingToggleDirection() {
    XCTAssertEqual(ThreadSummaryAgreementPolicy.offeredStates(for: .unknown), [true, false])
    XCTAssertEqual(
      ThreadSummaryAgreementPolicy.offeredStates(for: .failed(previous: nil)), [])
    XCTAssertEqual(
      ThreadSummaryAgreementPolicy.offeredStates(
        for: .ready(.init(isAgreed: true, agreeScore: 75))),
      [false]
    )
    for state: ContentAgreementEntryState in [
      .signedOut, .loading(previous: nil),
      .mutating(previous: .init(isAgreed: false, agreeScore: 75), targetAgreed: true),
      .reconciling(.init(isAgreed: false, agreeScore: 75)),
    ] {
      XCTAssertTrue(ThreadSummaryAgreementPolicy.offeredStates(for: state).isEmpty)
    }
  }

  func testCompactMetricsReactToAuthoritativeZeroToPositiveAndAccountResetWithoutEmptyRow() {
    XCTAssertFalse(
      ThreadSummaryAgreementPolicy.showsSecondaryMetrics(
        snapshot: nil, fallbackScore: 0, shareCount: 0
      )
    )
    XCTAssertTrue(
      ThreadSummaryAgreementPolicy.showsSecondaryMetrics(
        snapshot: .init(isAgreed: true, agreeScore: 1), fallbackScore: 0, shareCount: 0
      )
    )
    // A confirmed zero is meaningful after unliking, but an unknown zero must
    // not leave an empty second row after an account change or cache eviction.
    XCTAssertTrue(
      ThreadSummaryAgreementPolicy.showsSecondaryMetrics(
        snapshot: .init(isAgreed: false, agreeScore: 0), fallbackScore: 0, shareCount: 0
      )
    )
    XCTAssertFalse(
      ThreadSummaryAgreementPolicy.showsSecondaryMetrics(
        snapshot: nil, fallbackScore: 0, shareCount: 0
      )
    )
  }

  func testExplicitActionReadsFirstAndUsesAuthoritativeResultThenAvoidsDuplicateWrite() async throws
  {
    let harness = makeHarness()
    try await perform(true, using: harness)

    XCTAssertEqual(
      harness.store.entry(for: harness.target).displayedSnapshot,
      ContentAgreementSnapshot(isAgreed: true, agreeScore: 777)
    )
    try await perform(true, using: harness)
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read", "write:true", "read"])
    XCTAssertTrue(requests.allSatisfy { $0.userID == 7 && $0.target == harness.target })

    harness.store.accountSessionDidChange()
    XCTAssertNil(harness.store.entry(for: harness.target).displayedSnapshot)
  }

  func testUnknownExplicitUnlikeDoesNotAccidentallyLikeAnUnlikedThread() async throws {
    let harness = makeHarness()
    try await perform(false, using: harness)
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
  }

  func testUnlikeUsesServerResultInsteadOfSubtractingFromPriorDisplayedCount() async throws {
    let harness = makeHarness()
    try await perform(true, using: harness)
    try await perform(false, using: harness)

    XCTAssertEqual(
      harness.store.entry(for: harness.target).displayedSnapshot,
      ContentAgreementSnapshot(isAgreed: false, agreeScore: 74)
    )
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read", "write:true", "read", "write:false"])
  }

  func testLoggedOutActionDoesNotMakeAnAuthenticatedRequest() async {
    let harness = makeHarness(session: nil)
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testReadFailureNeverDispatchesWrite() async {
    let harness = makeHarness(failsRead: true)
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
    XCTAssertNil(harness.store.entry(for: harness.target).displayedSnapshot)
  }

  func testAccountSwitchBeforeReloadCannotWriteAsNewAccount() async {
    let harness = makeHarness()
    await harness.vault.switchAfterRead(1, to: makeSession(userID: 8))
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
    XCTAssertEqual(requests.first?.userID, 8)
  }

  func testSameUserNewSessionBeforeReloadCannotWriteUsingReplacementCredential() async {
    let harness = makeHarness()
    await harness.vault.switchAfterRead(1, to: makeSession(userID: 7))
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
  }

  func testAccountSwitchDuringReloadCannotApplyOldAccountSnapshotOrWrite() async {
    let harness = makeHarness()
    await harness.vault.switchAfterRead(2, to: makeSession(userID: 8))
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
    XCTAssertEqual(requests.first?.userID, 7)
    XCTAssertNil(harness.store.entry(for: harness.target).displayedSnapshot)
  }

  func testReloadLeaseForDifferentAccountCannotBeUsedEvenWhenOuterVaultReadsMatch() async {
    let original = makeSession(userID: 7)
    let replacement = makeSession(userID: 8)
    let harness = makeHarness(session: original)
    await harness.vault.enqueueSessionReads([
      original, replacement, replacement, original, replacement,
    ])

    await expectFailure { try await self.perform(true, using: harness) }

    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
    XCTAssertEqual(requests.first?.userID, replacement.id)
  }

  func testAccountSwitchAfterActionRevalidationIsStillRejectedByStoreWriteLease() async {
    let harness = makeHarness()
    // Expected session, reload session, reload lease check, action revalidation.
    // Switch just after that fourth read; the store must recheck before writing.
    await harness.vault.switchAfterRead(4, to: makeSession(userID: 8))
    await expectFailure { try await self.perform(true, using: harness) }
    let requests = await harness.service.requests()
    XCTAssertEqual(requests.map(\.operation), ["read"])
  }

  private func perform(_ isAgreed: Bool, using harness: Harness) async throws {
    try await ThreadSummaryAgreementAction.perform(
      isAgreed: isAgreed,
      target: harness.target,
      access: harness.access,
      store: harness.store
    )
  }

  private func expectFailure(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected the operation to stop before writing")
    } catch {}
  }

  private struct Harness {
    let target: ContentAgreementTarget
    let vault: SummaryAgreementVault
    let service: SummaryAgreementService
    let access: AccountAccess
    let store: ContentAgreementStore
  }

  private func makeHarness(
    session: StoredAccountSession? = makeSession(),
    failsRead: Bool = false
  ) -> Harness {
    let target = ThreadSummaryAgreementPolicy.target(for: makeSummary())!
    let vault = SummaryAgreementVault(session: session)
    let service = SummaryAgreementService(failsRead: failsRead)
    let access = AccountAccess(vault: vault, service: service)
    return Harness(
      target: target,
      vault: vault,
      service: service,
      access: access,
      store: ContentAgreementStore(access: access, observesAccountSessionChanges: false)
    )
  }
}

private func makeSummary(
  id: Int64 = 10,
  forumID: Int64 = 42,
  forumName: String = "swift",
  firstPostID: Int64 = 100,
  contentPostID: Int64 = 0,
  isServerHidden: Bool = false
) -> BrowseThread {
  BrowseThread(
    id: id,
    forumID: forumID,
    forumName: forumName,
    title: "A topic",
    excerpt: "A summary",
    authorName: "Author",
    replyCount: 3,
    viewCount: 10,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [],
    firstPostID: firstPostID,
    contentPostID: contentPostID,
    agreeCount: 75,
    isServerHidden: isServerHidden
  )
}

private func makeSession(userID: Int64 = 7) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester-\(userID)",
    displayName: "Tester",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID()
  )
}

private actor SummaryAgreementVault: AccountVault {
  private var session: StoredAccountSession?
  private var readCount = 0
  private var scheduledSwitch: (read: Int, session: StoredAccountSession)?
  private var scriptedSessions: [StoredAccountSession] = []

  init(session: StoredAccountSession?) { self.session = session }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? {
    readCount += 1
    if !scriptedSessions.isEmpty {
      return scriptedSessions.removeFirst()
    }
    let captured = session
    if let scheduledSwitch, scheduledSwitch.read == readCount {
      session = scheduledSwitch.session
      self.scheduledSwitch = nil
    }
    return captured
  }
  func switchAfterRead(_ count: Int, to session: StoredAccountSession) {
    scheduledSwitch = (count, session)
  }
  func enqueueSessionReads(_ sessions: [StoredAccountSession]) {
    scriptedSessions = sessions
  }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

private struct SummaryAgreementFailure: Error {}

private actor SummaryAgreementService: AccountService {
  struct Request: Sendable {
    let operation: String
    let userID: Int64
    let target: ContentAgreementTarget
  }

  private let failsRead: Bool
  private var isAgreed = false
  private var capturedRequests: [Request] = []

  init(failsRead: Bool) { self.failsRead = failsRead }
  func requests() -> [Request] { capturedRequests }

  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData {
    capturedRequests.append(Request(operation: "read", userID: session.id, target: target))
    if failsRead { throw SummaryAgreementFailure() }
    return ContentAgreementData(
      userID: session.id,
      target: target,
      isAgreed: isAgreed,
      agreeScore: isAgreed ? 777 : 75
    )
  }

  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData {
    capturedRequests.append(
      Request(operation: "write:\(isAgreed)", userID: session.id, target: target)
    )
    self.isAgreed = isAgreed
    return ContentAgreementData(
      userID: session.id,
      target: target,
      isAgreed: isAgreed,
      agreeScore: isAgreed ? 777 : 74
    )
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw SummaryAgreementFailure()
  }
  func followedForums(session: StoredAccountSession, page: Int, pageSize: Int) async throws
    -> FollowedForumPageData
  { throw SummaryAgreementFailure() }
  func forumMembership(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws
    -> ForumMembershipData
  { throw SummaryAgreementFailure() }
  func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws
    -> ForumAccountStateData
  { throw SummaryAgreementFailure() }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData { throw SummaryAgreementFailure() }
  func checkInToForum(session: StoredAccountSession, forumID: Int64, forumName: String) async throws
    -> ForumAccountStateData
  { throw SummaryAgreementFailure() }
}
