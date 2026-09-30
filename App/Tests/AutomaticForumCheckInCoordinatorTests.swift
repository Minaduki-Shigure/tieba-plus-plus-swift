import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AutomaticForumCheckInCoordinatorTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_790_818_200)  // Fixed, independent of device time.
  private let policy = ForumBatchCheckInExecutionPolicy(
    delayMode: .fast, usesOfficialBatch: true, stopsAfterSingleFailure: false
  )

  func testCompletedDaySurvivesCoordinatorRecreationAndSameAccountRelogin() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20])
    let journal = AutomaticCheckInJournal()
    let first = coordinator(vault, service, journal)
    let firstOutcome = await first.run(policy: policy, authorization: { true })
    XCTAssertEqual(firstOutcome, .finishedForToday)
    try await vault.upsert(automaticSession())  // Same UID, new credential revision.
    let second = coordinator(vault, service, journal)
    let secondOutcome = await second.run(policy: policy, authorization: { true })
    XCTAssertEqual(secondOutcome, .finishedForToday)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10, 20])
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.confirmedCount, 2)
    XCTAssertEqual(record?.state, .completed)
  }

  func testCancellationKeepsGateAndLateReceiptThenResumesOnlyUnclaimedTargets() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20], suspendedID: 10)
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let first = Task { await subject.run(policy: policy, authorization: { true }) }
    try await waitUntil { await service.singleCalls == [10] }
    let pending = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(pending?.entries.map(\.forumID), [10])
    XCTAssertEqual(pending?.unconfirmedCount, 1)
    first.cancel()
    subject.cancel()
    XCTAssertTrue(subject.isRunning)
    let overlapping = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(overlapping, .needsResume)
    await service.releaseSingle()
    let firstOutcome = await first.value
    XCTAssertEqual(firstOutcome, .needsResume)
    XCTAssertFalse(subject.isRunning)
    let next = coordinator(vault, service, journal)
    let nextOutcome = await next.run(policy: policy, authorization: { true })
    XCTAssertEqual(nextOutcome, .finishedForToday)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10, 20])
  }

  func testAccountSwitchSettlesOriginalAccountWithoutPublishingItsOldRows() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20], suspendedID: 10)
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let task = Task { await subject.run(policy: policy, authorization: { true }) }
    try await waitUntil { await service.singleCalls == [10] }
    try await vault.upsert(automaticSession(userID: 2))
    subject.accountSessionDidChange()
    await service.releaseSingle()
    _ = await task.value
    let original = try await journal.load(userID: 1, day: day())
    let next = try await journal.load(userID: 2, day: day())
    XCTAssertEqual(original?.confirmedCount, 1)
    XCTAssertNil(next)
    XCTAssertTrue(subject.entries.isEmpty)
    XCTAssertNil(subject.summary)
    XCTAssertNil(subject.resultDay)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  #if canImport(Darwin)
    func testCancelledCallerPersistsLateReceiptInActualFileLedger() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("automatic-check-in-coordinator-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appendingPathComponent("ledger.json")
      let key = Data(repeating: 0x71, count: 32)
      let journal = FileAutomaticForumCheckInLedger(fileURL: file, testingKey: key)
      let vault = AutomaticCheckInVault(session: automaticSession())
      let service = AutomaticCheckInService(ids: [10, 20], suspendedID: 10)
      let subject = coordinator(vault, service, journal)
      let task = Task { await subject.run(policy: policy, authorization: { true }) }
      try await waitUntil { await service.singleCalls == [10] }
      task.cancel()
      subject.cancel()
      await service.releaseSingle()
      let outcome = await task.value
      XCTAssertEqual(outcome, .needsResume)
      let reopened = FileAutomaticForumCheckInLedger(fileURL: file, testingKey: key)
      let persisted = try await reopened.load(userID: 1, day: day())
      XCTAssertEqual(persisted?.confirmedCount, 1)
      XCTAssertEqual(persisted?.unconfirmedCount, 0)
      XCTAssertEqual(persisted?.entries.map(\.forumID), [10])
      let resumed = coordinator(vault, service, reopened)
      let resumedOutcome = await resumed.run(policy: policy, authorization: { true })
      XCTAssertEqual(resumedOutcome, .finishedForToday)
      let calls = await service.singleCalls
      XCTAssertEqual(calls, [10, 20])
    }
  #endif

  func testUnknownResultCannotResendAfterReloginAndExplicitReconcileNeverWrites() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20], failedSingleIDs: [10])
    let journal = AutomaticCheckInJournal()
    let first = coordinator(vault, service, journal)
    let firstOutcome = await first.run(policy: policy, authorization: { true })
    XCTAssertEqual(firstOutcome, .needsReview)
    try await vault.upsert(automaticSession())
    let second = coordinator(vault, service, journal)
    let secondOutcome = await second.run(policy: policy, authorization: { true })
    XCTAssertEqual(secondOutcome, .needsReview)
    var calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
    await service.setReadbackSigned([10])
    let readOnly = await second.reconcile()
    XCTAssertEqual(readOnly, .needsResume)
    calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
    let resumed = await second.run(policy: policy, authorization: { true })
    XCTAssertEqual(resumed, .finishedForToday)
    calls = await service.singleCalls
    XCTAssertEqual(calls, [10, 20])
  }

  func testDisablingWhileDurableClaimSuspendsReleasesOnlyUndispatchedClaim() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10])
    let journal = AutomaticCheckInJournal(suspendClaim: true)
    let subject = coordinator(vault, service, journal)
    let task = Task { await subject.run(policy: policy, authorization: { true }) }
    try await waitUntil { await journal.hasSuspendedClaim }
    task.cancel()
    subject.cancel()
    await journal.releaseClaim()
    let outcome = await task.value
    XCTAssertEqual(outcome, .needsResume)
    let record = try await journal.load(userID: 1, day: day())
    let calls = await service.singleCalls
    XCTAssertEqual(record?.entries.count, 0)
    XCTAssertTrue(calls.isEmpty)
  }

  func testMidnightStopsOldDayDispatchButPreservesItsLateResult() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20], suspendedID: 10)
    let journal = AutomaticCheckInJournal()
    let clock = AutomaticCheckInClock(date)
    let subject = AutomaticForumCheckInCoordinator(
      access: AccountAccess(vault: vault, service: service), journal: journal,
      now: { clock.date }, interRequestDelay: { _ in }
    )
    let task = Task { await subject.run(policy: policy, authorization: { true }) }
    try await waitUntil { await service.singleCalls == [10] }
    clock.date = date.addingTimeInterval(86_400)
    await service.releaseSingle()
    let outcome = await task.value
    XCTAssertEqual(outcome, .needsResume)
    let old = try await journal.load(userID: 1, day: day())
    let new = try await journal.load(userID: 1, day: day(clock.date))
    XCTAssertEqual(old?.confirmedCount, 1)
    XCTAssertNil(new)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  func testClaimStorageFailurePreventsEveryNetworkWrite() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20])
    let journal = AutomaticCheckInJournal(failClaim: true)
    let subject = coordinator(vault, service, journal)
    let outcome = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(outcome, .needsReview)
    let singles = await service.singleCalls
    let batches = await service.batchCalls
    XCTAssertTrue(singles.isEmpty)
    XCTAssertTrue(batches.isEmpty)
  }

  func testReadOnlyInspectionOnNextDayClearsPriorDayRows() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10])
    let journal = AutomaticCheckInJournal()
    let clock = AutomaticCheckInClock(date)
    let subject = AutomaticForumCheckInCoordinator(
      access: AccountAccess(vault: vault, service: service), journal: journal,
      now: { clock.date }, interRequestDelay: { _ in }
    )
    let initial = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(initial, .finishedForToday)
    XCTAssertEqual(subject.summary?.succeeded, 1)
    XCTAssertEqual(subject.resultDay, day())
    clock.date = date.addingTimeInterval(86_400)
    XCTAssertEqual(subject.resultDay, day())
    let inspection = await subject.reconcile()
    XCTAssertEqual(inspection, .needsResume)
    XCTAssertTrue(subject.entries.isEmpty)
    XCTAssertNil(subject.summary)
    XCTAssertEqual(subject.resultDay, day(clock.date))
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  func testSettlementStorageFailureLeavesUnknownAndStopsRemainingTargets() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20])
    let journal = AutomaticCheckInJournal(failSettlement: true)
    let subject = coordinator(vault, service, journal)
    let outcome = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(outcome, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.unconfirmedCount, 1)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  func testLockedAccountCanRetryAfterUnlockWithoutConsumingTheDay() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    await vault.setUnreadable(true)
    let service = AutomaticCheckInService(ids: [10])
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let locked = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(locked, .needsResume)
    let untouched = try await journal.load(userID: 1, day: day())
    XCTAssertNil(untouched)
    await vault.setUnreadable(false)
    let unlocked = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(unlocked, .finishedForToday)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  func testSuccessfulBatchReleasesServerOmissionsForALaterFreshRun() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(
      ids: [10, 20, 30], officialIDs: [10, 20], batchBehaviors: [.success([10])]
    )
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let first = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(first, .needsResume)
    let partial = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(Set(partial?.entries.map(\.forumID) ?? []), [10, 30])
    let second = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(second, .finishedForToday)
    let batches = await service.batchCalls
    let singles = await service.singleCalls
    XCTAssertEqual(batches, [[10, 20], [20]])
    XCTAssertEqual(singles, [30])
  }

  func testUnknownBatchKeepsExactDispatchedSubsetAndReleasesTheRest() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(
      ids: [10, 20, 30], officialIDs: [10, 20], batchBehaviors: [.unknown([10])]
    )
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let first = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(first, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.entries.map(\.forumID), [10])
    XCTAssertEqual(record?.unconfirmedCount, 1)
    var singles = await service.singleCalls
    XCTAssertTrue(singles.isEmpty)
    await service.setReadbackSigned([10])
    let second = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(second, .finishedForToday)
    let batches = await service.batchCalls
    singles = await service.singleCalls
    XCTAssertEqual(batches, [[10, 20], [20]])
    XCTAssertEqual(singles, [30])
  }

  func testGenericBatchErrorCannotReleasePotentiallyDispatchedTargets() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(
      ids: [10, 20, 30], officialIDs: [10, 20], batchBehaviors: [.failure]
    )
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let outcome = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(outcome, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(Set(record?.entries.map(\.forumID) ?? []), [10, 20])
    XCTAssertEqual(record?.unconfirmedCount, 2)
    let singles = await service.singleCalls
    XCTAssertTrue(singles.isEmpty)
  }

  func testUnrelatedBatchResultKeepsEveryAuthorizedClaimUnknown() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(
      ids: [10, 20, 30], officialIDs: [10, 20], batchBehaviors: [.success([999])]
    )
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let outcome = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(outcome, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(Set(record?.entries.map(\.forumID) ?? []), [10, 20])
    XCTAssertEqual(record?.unconfirmedCount, 2)
    let singles = await service.singleCalls
    XCTAssertTrue(singles.isEmpty)
  }

  func testRejectedBatchPausesDayEvenWhenManualFailurePolicyAllowsContinuation() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(
      ids: [10, 20], officialIDs: [10], batchBehaviors: [.rejected]
    )
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    let first = await subject.run(policy: policy, authorization: { true })
    let second = await subject.run(policy: policy, authorization: { true })
    XCTAssertEqual(first, .needsReview)
    XCTAssertEqual(second, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.state, .paused)
    let singles = await service.singleCalls
    let batches = await service.batchCalls
    XCTAssertTrue(singles.isEmpty)
    XCTAssertEqual(batches, [[10]])
  }

  func testDefinitiveSingleFailurePausesAcrossRestartWithoutWritingRemainingForums() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10, 20], unsignedSingleIDs: [10])
    let journal = AutomaticCheckInJournal()
    let first = await coordinator(vault, service, journal).run(
      policy: policy, authorization: { true })
    let second = await coordinator(vault, service, journal).run(
      policy: policy, authorization: { true })
    XCTAssertEqual(first, .needsReview)
    XCTAssertEqual(second, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.state, .paused)
    XCTAssertEqual(record?.failedCount, 1)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  func testSignedReadbackForWrongIdentityCannotClearUnknownClaim() async throws {
    let vault = AutomaticCheckInVault(session: automaticSession())
    let service = AutomaticCheckInService(ids: [10], failedSingleIDs: [10])
    let journal = AutomaticCheckInJournal()
    let subject = coordinator(vault, service, journal)
    _ = await subject.run(policy: policy, authorization: { true })
    await service.setReadbackSigned([10], userID: 999)
    let outcome = await subject.reconcile()
    XCTAssertEqual(outcome, .needsReview)
    let record = try await journal.load(userID: 1, day: day())
    XCTAssertEqual(record?.unconfirmedCount, 1)
    let calls = await service.singleCalls
    XCTAssertEqual(calls, [10])
  }

  private func coordinator(
    _ vault: AutomaticCheckInVault, _ service: AutomaticCheckInService,
    _ journal: any AutomaticForumCheckInLedgerRepository
  ) -> AutomaticForumCheckInCoordinator {
    let date = date
    return AutomaticForumCheckInCoordinator(
      access: AccountAccess(vault: vault, service: service), journal: journal,
      now: { date }, interRequestDelay: { _ in }
    )
  }

  private func day(_ date: Date? = nil) -> String {
    AutomaticForumCheckInSchedule.dayKey(at: date ?? self.date)!
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
      guard Date() < deadline else { throw AutomaticCheckInTestError.failed }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }
}

@MainActor
private final class AutomaticCheckInClock {
  var date: Date
  init(_ date: Date) { self.date = date }
}

private enum AutomaticCheckInTestError: Error { case failed }

private func automaticSession(userID: Int64 = 1) -> StoredAccountSession {
  StoredAccountSession(
    id: userID, username: "u", displayName: "User", portrait: "portrait",
    bduss: String(repeating: "a", count: AccountCredentialFormat.bdussLength),
    stoken: String(repeating: "b", count: AccountCredentialFormat.stokenLength),
    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID()
  )
}

private actor AutomaticCheckInVault: AccountVault {
  private var session: StoredAccountSession?
  private var unreadable = false
  init(session: StoredAccountSession?) { self.session = session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? {
    if unreadable { throw AutomaticCheckInTestError.failed }
    return session
  }
  func setUnreadable(_ value: Bool) { unreadable = value }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

private actor AutomaticCheckInService: AccountService {
  enum BatchBehavior: Sendable {
    case success([Int64])
    case unknown([Int64])
    case rejected, failure
  }
  let ids: [Int64]
  let officialIDs: Set<Int64>
  let failedSingleIDs: Set<Int64>
  let unsignedSingleIDs: Set<Int64>
  var suspendedID: Int64?
  var singleWaiter: CheckedContinuation<Void, Never>?
  var signedReadbackIDs = Set<Int64>()
  var readbackUserID: Int64?
  var batchBehaviors: [BatchBehavior]
  private(set) var singleCalls: [Int64] = []
  private(set) var batchCalls: [[Int64]] = []

  init(
    ids: [Int64], officialIDs: Set<Int64> = [], suspendedID: Int64? = nil,
    failedSingleIDs: Set<Int64> = [], unsignedSingleIDs: Set<Int64> = [],
    batchBehaviors: [BatchBehavior] = []
  ) {
    self.ids = ids
    self.officialIDs = officialIDs
    self.suspendedID = suspendedID
    self.failedSingleIDs = failedSingleIDs
    self.unsignedSingleIDs = unsignedSingleIDs
    self.batchBehaviors = batchBehaviors
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw AutomaticCheckInTestError.failed
  }
  func followedForums(session: StoredAccountSession, page: Int, pageSize: Int) async throws
    -> FollowedForumPageData
  { throw AutomaticCheckInTestError.failed }
  func forumMembership(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws
    -> ForumMembershipData
  { throw AutomaticCheckInTestError.failed }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData { throw AutomaticCheckInTestError.failed }

  func checkInCatalog(session: StoredAccountSession) async throws -> ForumCheckInCatalogData {
    ForumCheckInCatalogData(
      userID: session.id,
      targets: ids.map {
        ForumCheckInCatalogTarget(
          forumID: $0, forumName: "F\($0)", level: officialIDs.contains($0) ? 5 : 1,
          status: .pending, isForbidden: false
        )
      },
      officialBatchPolicy: officialIDs.isEmpty
        ? nil
        : ForumOfficialBatchCheckInPolicy(
          minimumLevel: 4, maximumForumCount: 100
        )
    )
  }

  func checkInToForum(session: StoredAccountSession, forumID: Int64, forumName: String) async throws
    -> ForumAccountStateData
  {
    singleCalls.append(forumID)
    if suspendedID == forumID { await withCheckedContinuation { singleWaiter = $0 } }
    if failedSingleIDs.contains(forumID) { throw AutomaticCheckInTestError.failed }
    return state(
      userID: session.id, forumID: forumID, forumName: forumName,
      signed: !unsignedSingleIDs.contains(forumID)
    )
  }

  func batchCheckIn(session: StoredAccountSession, authorizedTargets: [ForumBatchCheckInTarget])
    async throws -> ForumBatchCheckInData
  {
    let ids = authorizedTargets.map(\.forumID)
    batchCalls.append(ids)
    let behavior = batchBehaviors.isEmpty ? .success(ids) : batchBehaviors.removeFirst()
    switch behavior {
    case .success(let confirmed):
      return ForumBatchCheckInData(
        userID: session.id,
        results: confirmed.map {
          .init(forumID: $0, forumName: "F\($0)", outcome: .confirmedSigned)
        }
      )
    case .unknown(let dispatched):
      throw ForumBatchCheckInError.outcomeUnknown(
        dispatchedTargets: dispatched.map { .init(forumID: $0, forumName: "F\($0)") }
      )
    case .rejected:
      return ForumBatchCheckInData(
        userID: session.id,
        results: ids.map {
          .init(forumID: $0, forumName: "F\($0)", outcome: .rejected(message: "请完成验证"))
        }
      )
    case .failure: throw AutomaticCheckInTestError.failed
    }
  }

  func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws
    -> ForumAccountStateData
  {
    state(
      userID: readbackUserID ?? session.id, forumID: forumID, forumName: forumName,
      signed: signedReadbackIDs.contains(forumID)
    )
  }

  func releaseSingle() {
    suspendedID = nil
    singleWaiter?.resume()
    singleWaiter = nil
  }
  func setReadbackSigned(_ ids: Set<Int64>, userID: Int64? = nil) {
    signedReadbackIDs = ids
    readbackUserID = userID
  }

  private func state(userID: Int64, forumID: Int64, forumName: String, signed: Bool)
    -> ForumAccountStateData
  {
    ForumAccountStateData(
      membership: .init(userID: userID, forumID: forumID, forumName: forumName, isFollowed: true),
      checkIn: .init(isCheckedIn: signed, consecutiveDays: signed ? 1 : 0, rank: signed ? 1 : 0)
    )
  }
}

/// Uses the actual journal state machine, while injecting disk failure/suspension
/// at the boundary to exercise dispatch ordering and recovery deterministically.
private actor AutomaticCheckInJournal: AutomaticForumCheckInLedgerRepository {
  private var archive = AutomaticForumCheckInLedgerArchive.empty
  private let failClaim: Bool
  private let failSettlement: Bool
  private var suspendClaim: Bool
  private var claimWaiter: CheckedContinuation<Void, Never>?
  private(set) var hasSuspendedClaim = false

  init(failClaim: Bool = false, failSettlement: Bool = false, suspendClaim: Bool = false) {
    self.failClaim = failClaim
    self.failSettlement = failSettlement
    self.suspendClaim = suspendClaim
  }

  func load(userID: Int64, day: String) async throws -> AutomaticForumCheckInDayRecord? {
    try AutomaticForumCheckInLedgerModel.load(archive, userID: userID, day: day)
  }
  func claimTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    if failClaim { throw AutomaticCheckInTestError.failed }
    let record = try AutomaticForumCheckInLedgerModel.claim(
      &archive, userID: userID, day: day, runID: runID, targets: targets, at: date
    )
    if suspendClaim {
      hasSuspendedClaim = true
      await withCheckedContinuation { claimWaiter = $0 }
    }
    return record
  }
  func settleResults(
    userID: Int64, day: String, runID: UUID, results: [AutomaticForumCheckInTargetResult],
    at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try Task.checkCancellation()
    if failSettlement { throw AutomaticCheckInTestError.failed }
    return try AutomaticForumCheckInLedgerModel.settle(
      &archive, userID: userID, day: day, runID: runID, results: results, at: date
    )
  }
  func releaseUndispatchedTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try Task.checkCancellation()
    return try AutomaticForumCheckInLedgerModel.releaseUndispatched(
      &archive, userID: userID, day: day, runID: runID, targets: targets, at: date
    )
  }
  func confirmReadBack(
    userID: Int64, day: String, targets: [ForumBatchCheckInTarget], at date: Date
  )
    async throws -> AutomaticForumCheckInDayRecord
  {
    try AutomaticForumCheckInLedgerModel.confirmReadBack(
      &archive, userID: userID, day: day, targets: targets, at: date
    )
  }
  func finishDay(
    userID: Int64, day: String, runID: UUID, state: AutomaticForumCheckInDayState,
    pausedReason: String?, at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try AutomaticForumCheckInLedgerModel.finishDay(
      &archive, userID: userID, day: day, runID: runID, state: state,
      pausedReason: pausedReason, at: date
    )
  }
  func releaseClaim() {
    suspendClaim = false
    claimWaiter?.resume()
    claimWaiter = nil
  }
}
