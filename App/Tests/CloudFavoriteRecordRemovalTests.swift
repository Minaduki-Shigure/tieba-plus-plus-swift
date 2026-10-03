import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class CloudFavoriteRecordRemovalTests: XCTestCase {
  func testAcknowledgementAndAbsenceAreSeparateAndReleaseOrdinaryWriter() async throws {
    let session = cleanupSession()
    let vault = CleanupVault(session)
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(ledger: ledger, outcome: .acceptedAwaitingVerification)
    let gate = CloudFavoriteMutationGate(ledger: ledger)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: gate, cloudFavoriteVault: vault
    )
    let target = try cleanupTarget(session)

    let result = try await service.removeCloudFavoriteRecord(session: session, target: target)
    XCTAssertEqual(result.phase, .acceptedAwaitingVerification)
    XCTAssertTrue(result.receiptAcknowledged)
    XCTAssertTrue(result.requiresVerification)
    let stored = try await ledger.record(for: target.key)
    XCTAssertEqual(stored?.phase, .acceptedAwaitingVerification)
    do {
      _ = try await service.setThreadCloudFavorite(
        session: session, target: cleanupNormalTarget(), markedPostID: 99
      )
      XCTFail("Pending removal must block add, update and ordinary removal")
    } catch {}
    let blockedWrites = await client.ordinaryWrites
    XCTAssertEqual(blockedWrites, 0)

    await client.setObservation(.observedAbsent)
    let observed = try await service.verifyCloudFavoriteRecordRemoval(
      session: session, target: target)
    XCTAssertEqual(observed.phase, .observedAbsent)
    XCTAssertTrue(observed.receiptAcknowledged)
    _ = try await service.setThreadCloudFavorite(
      session: session, target: cleanupNormalTarget(), markedPostID: 99
    )
    let writes = await client.ordinaryWrites
    let removals = await client.dispatches
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(removals, 1)
  }

  func testUnknownSurvivesCoordinatorRecreationAndCredentialRotationWithoutRedispatch() async throws
  {
    let original = cleanupSession()
    let vault = CleanupVault(original)
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(ledger: ledger, outcome: .unknown)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger), cloudFavoriteVault: vault
    )
    let initial = try await service.removeCloudFavoriteRecord(
      session: original, target: cleanupTarget(original)
    )
    XCTAssertEqual(initial.phase, .outcomeUnknown)
    XCTAssertFalse(initial.receiptAcknowledged)
    let rotated = cleanupSession()
    await vault.upsert(rotated)
    let restored = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger), cloudFavoriteVault: vault
    )
    let statuses = try await restored.cloudFavoriteRecordRemovalStatuses(session: rotated)
    XCTAssertEqual(statuses.map(\.phase), [.outcomeUnknown])
    let again = try await restored.removeCloudFavoriteRecord(
      session: rotated, target: cleanupTarget(rotated)
    )
    XCTAssertEqual(again.phase, .outcomeUnknown)
    let dispatchCount = await client.dispatches
    XCTAssertEqual(dispatchCount, 1, "Restoring or confirming again is read-only")

    await client.setObservation(.observedAbsent)
    let observed = try await restored.verifyCloudFavoriteRecordRemoval(
      session: rotated, target: cleanupTarget(rotated)
    )
    XCTAssertEqual(observed.phase, .observedAbsent)
    XCTAssertFalse(observed.receiptAcknowledged, "Read-back must never manufacture an ACK")
  }

  func testDispatchPendingRestoresAsUnknownAndCanOnlyVerify() async throws {
    let session = cleanupSession()
    let target = try cleanupTarget(session)
    let ledger = TransientCloudFavoriteMutationLedger()
    _ = try await ledger.prepare(
      key: target.key, operationID: UUID(), sessionRevision: session.sessionRevision, now: Date()
    )
    let client = CleanupClient(ledger: ledger, observation: .observedAbsent)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let restored = try await service.cloudFavoriteRecordRemovalStatuses(session: session)
    XCTAssertEqual(restored.map(\.phase), [.outcomeUnknown])
    let verified = try await service.removeCloudFavoriteRecord(session: session, target: target)
    XCTAssertEqual(verified.phase, .observedAbsent)
    let count = await client.dispatches
    XCTAssertEqual(count, 0)
  }

  func testSameUIDRevisionChangesBeforeDispatchRemovePendingAndSendNothing() async throws {
    let session = cleanupSession()
    let vault = CleanupVault(session)
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(ledger: ledger, beforeHook: { await vault.upsert(cleanupSession()) })
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger), cloudFavoriteVault: vault
    )
    do {
      _ = try await service.removeCloudFavoriteRecord(
        session: session, target: cleanupTarget(session))
      XCTFail("Old lease must not dispatch")
    } catch CloudFavoriteRecordRemovalError.sessionChanged {} catch { XCTFail("\(error)") }
    let count = await client.dispatches
    let records = try await ledger.records()
    XCTAssertEqual(count, 0)
    XCTAssertTrue(records.isEmpty)
  }

  func testAccountChangeAfterDispatchStillPersistsReceiptButDoesNotPublishResult() async throws {
    let session = cleanupSession()
    let vault = CleanupVault(session)
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(
      ledger: ledger, afterHook: { await vault.upsert(cleanupSession(userID: 8)) }
    )
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger), cloudFavoriteVault: vault
    )
    do {
      _ = try await service.removeCloudFavoriteRecord(
        session: session, target: cleanupTarget(session))
      XCTFail("Previous account must not update the UI")
    } catch CloudFavoriteRecordRemovalError.sessionChanged {} catch { XCTFail("\(error)") }
    let records = try await ledger.records()
    XCTAssertEqual(records.map(\.phase), [.acceptedAwaitingVerification])
    let reads = await client.verifications
    XCTAssertEqual(reads, 0)
  }

  func testDefinitelyRejectedRequestReleasesOnlyItsPendingRecord() async throws {
    let session = cleanupSession()
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(
      ledger: ledger, outcome: .rejected(code: 4, message: "private response"))
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    do {
      _ = try await service.removeCloudFavoriteRecord(
        session: session, target: cleanupTarget(session))
      XCTFail("Rejection must not appear accepted")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains("private response"))
      XCTAssertTrue(error.localizedDescription.contains("4"))
    }
    let records = try await ledger.records()
    XCTAssertTrue(records.isEmpty)
    let reads = await client.verifications
    XCTAssertEqual(reads, 0)
  }

  func testLedgerPrepareFailureSendsNoWriteAndBlocksOrdinaryMutation() async throws {
    let session = cleanupSession()
    let ledger = CleanupFailingLedger()
    let client = CleanupClient(ledger: ledger)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    do {
      _ = try await service.removeCloudFavoriteRecord(
        session: session, target: cleanupTarget(session))
      XCTFail("Unreadable ledger must fail closed")
    } catch {}
    do {
      _ = try await service.setThreadCloudFavorite(
        session: session, target: cleanupNormalTarget(), markedPostID: nil
      )
      XCTFail("The old removal path must use the same ledger gate")
    } catch {}
    let cleanupWrites = await client.dispatches
    let ordinaryWrites = await client.ordinaryWrites
    XCTAssertEqual(cleanupWrites, 0)
    XCTAssertEqual(ordinaryWrites, 0)
  }

  func testSharedUIDTIDGateIncludesDifferentForumIDsAndPermitsOtherAccounts() async throws {
    let ledger = TransientCloudFavoriteMutationLedger()
    let gate = CloudFavoriteMutationGate(ledger: ledger)
    let key = try XCTUnwrap(CloudFavoriteMutationLedgerKey(userID: 7, threadID: 84))
    let held = try await gate.acquire(key, allowsVerification: true)
    let client = CleanupClient(ledger: ledger)
    let service = TiebaCoreAccountService(client: client, cloudFavoriteMutationGate: gate)
    for forumID: Int64 in [42, 43] {
      do {
        _ = try await service.setThreadCloudFavorite(
          session: cleanupSession(),
          target: XCTUnwrap(
            ThreadCloudFavoriteTarget(forumID: forumID, forumName: "swift", threadID: 84)),
          markedPostID: nil
        )
        XCTFail("FID must not bypass the UID/TID gate")
      } catch {}
    }
    _ = try await service.setThreadCloudFavorite(
      session: cleanupSession(userID: 8), target: cleanupNormalTarget(), markedPostID: 99
    )
    let count = await client.ordinaryWrites
    XCTAssertEqual(count, 1)
    await gate.release(key, token: held)
  }

  func testCancellationOfCallerAfterDispatchStillPersistsFinalReceipt() async throws {
    let session = cleanupSession()
    let ledger = CleanupCancellationAwareLedger()
    let pause = CleanupTestGate()
    let client = CleanupClient(ledger: ledger, afterHook: { await pause.wait() })
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let task = Task {
      try await service.removeCloudFavoriteRecord(session: session, target: cleanupTarget(session))
    }
    for _ in 0..<1_000 {
      if await client.dispatches == 1 { break }
      await Task.yield()
    }
    let count = await client.dispatches
    XCTAssertEqual(count, 1)
    task.cancel()
    await pause.release()
    do {
      _ = try await task.value
      XCTFail("Cancelled presentation must not receive a success result")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let records = try await ledger.records()
    XCTAssertEqual(records.map(\.phase), [.acceptedAwaitingVerification])
  }

  func testCancellationAfterDefiniteRejectionClearsPendingInsteadOfLeavingUnknownLock() async throws
  {
    let session = cleanupSession()
    let ledger = CleanupCancellationAwareLedger()
    let pause = CleanupTestGate()
    let client = CleanupClient(
      ledger: ledger, outcome: .rejected(code: 4, message: "Rejected"),
      afterHook: { await pause.wait() }
    )
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let task = Task {
      try await service.removeCloudFavoriteRecord(session: session, target: cleanupTarget(session))
    }
    for _ in 0..<1_000 {
      if await client.dispatches == 1 { break }
      await Task.yield()
    }
    let count = await client.dispatches
    XCTAssertEqual(count, 1)
    task.cancel()
    await pause.release()
    do {
      _ = try await task.value
      XCTFail("Cancelled presentation must not receive a result")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let records = try await ledger.records()
    XCTAssertTrue(records.isEmpty, "A definite rejection is safe to retry after fresh confirmation")
    _ = try await service.setThreadCloudFavorite(
      session: session, target: cleanupNormalTarget(), markedPostID: 99
    )
    let ordinary = await client.ordinaryWrites
    XCTAssertEqual(ordinary, 1)
  }

  func testCancellationAfterPendingPersistenceButBeforeDispatchRemovesIntent() async throws {
    let session = cleanupSession()
    let pause = CleanupTestGate()
    let ledger = CleanupCancellationAwareLedger(afterPrepare: { await pause.wait() })
    let client = CleanupClient(ledger: ledger)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let task = Task {
      try await service.removeCloudFavoriteRecord(session: session, target: cleanupTarget(session))
    }
    for _ in 0..<1_000 {
      let pending = try await ledger.records()
      if !pending.isEmpty { break }
      await Task.yield()
    }
    let before = try await ledger.records()
    XCTAssertEqual(before.map(\.phase), [.dispatchPending])
    task.cancel()
    await pause.release()
    do {
      _ = try await task.value
      XCTFail("Cancelled preflight must never send")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let after = try await ledger.records()
    let writes = await client.dispatches
    XCTAssertTrue(after.isEmpty)
    XCTAssertEqual(writes, 0)
  }

  func testRecoverableLedgerFailureAllowsReadOnlyVerificationButNeverAnotherDispatch() async throws
  {
    let session = cleanupSession()
    let ledger = CleanupTransitionFaultLedger()
    let client = CleanupClient(ledger: ledger)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let target = try cleanupTarget(session)
    do {
      _ = try await service.removeCloudFavoriteRecord(session: session, target: target)
      XCTFail("Failed receipt persistence must not appear confirmed")
    } catch {}
    let pending = try await ledger.record(for: target.key)
    XCTAssertEqual(pending?.phase, .dispatchPending)
    await client.setObservation(.observedAbsent)
    let verified = try await service.verifyCloudFavoriteRecordRemoval(
      session: session, target: target)
    XCTAssertEqual(verified.phase, .observedAbsent)
    XCTAssertFalse(
      verified.receiptAcknowledged, "An unpersisted ACK must not be invented on recovery")
    let count = await client.dispatches
    XCTAssertEqual(count, 1)
    _ = try await service.setThreadCloudFavorite(
      session: session, target: cleanupNormalTarget(), markedPostID: 99
    )
    let ordinary = await client.ordinaryWrites
    XCTAssertEqual(ordinary, 1)
  }

  func testPreviouslyObservedAbsenceCannotHideAReaddedFavorite() async throws {
    let session = cleanupSession()
    let ledger = TransientCloudFavoriteMutationLedger()
    let client = CleanupClient(ledger: ledger, observation: .observedAbsent)
    let service = TiebaCoreAccountService(
      client: client, cloudFavoriteMutationGate: .init(ledger: ledger),
      cloudFavoriteVault: CleanupVault(session)
    )
    let target = try cleanupTarget(session)
    let first = try await service.removeCloudFavoriteRecord(session: session, target: target)
    XCTAssertEqual(first.phase, .observedAbsent)
    await client.setObservation(.observedPresent)
    do {
      _ = try await service.verifyCloudFavoriteRecordRemoval(session: session, target: target)
      XCTFail("Old absence must not be returned for newly observed presence")
    } catch CloudFavoriteRecordRemovalError.verificationCompleted {} catch { XCTFail("\(error)") }
    let count = await client.dispatches
    XCTAssertEqual(count, 1)
  }
}

private func cleanupSession(userID: Int64 = 7) -> StoredAccountSession {
  StoredAccountSession(
    id: userID, username: "user", displayName: "User", portrait: "portrait",
    bduss: String(repeating: "b", count: 192), stoken: String(repeating: "s", count: 64),
    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)
  )
}

private func cleanupTarget(_ session: StoredAccountSession) throws -> CloudFavoriteRecordTarget {
  try XCTUnwrap(
    CloudFavoriteRecordTarget(
      userID: session.id, threadID: 84, sessionRevision: session.sessionRevision
    ))
}

private func cleanupNormalTarget() throws -> ThreadCloudFavoriteTarget {
  try XCTUnwrap(ThreadCloudFavoriteTarget(forumID: 42, forumName: "swift", threadID: 84))
}

private actor CleanupVault: AccountVault {
  private var session: StoredAccountSession?
  init(_ session: StoredAccountSession) { self.session = session }
  func activeSession() async throws -> StoredAccountSession? { session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

private actor CleanupTestGate {
  private var released = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuations.append($0) }
  }
  func release() {
    released = true
    continuations.forEach { $0.resume() }
    continuations.removeAll()
  }
}

private actor CleanupClient: TiebaAuthenticatedAccountClient {
  let ledger: any CloudFavoriteMutationLedgerRepository
  let outcome: TiebaCloudFavoriteRecordCleanupOutcome
  var observation: TiebaCloudFavoriteRecordObservation
  let beforeHook: @Sendable () async -> Void
  let afterHook: @Sendable () async -> Void
  private(set) var dispatches = 0
  private(set) var verifications = 0
  private(set) var ordinaryWrites = 0

  init(
    ledger: any CloudFavoriteMutationLedgerRepository,
    outcome: TiebaCloudFavoriteRecordCleanupOutcome = .acceptedAwaitingVerification,
    observation: TiebaCloudFavoriteRecordObservation = .observedPresent,
    beforeHook: @escaping @Sendable () async -> Void = {},
    afterHook: @escaping @Sendable () async -> Void = {}
  ) {
    self.ledger = ledger
    self.outcome = outcome
    self.observation = observation
    self.beforeHook = beforeHook
    self.afterHook = afterHook
  }

  func setObservation(_ value: TiebaCloudFavoriteRecordObservation) { observation = value }

  func cleanupCloudFavoriteRecord(
    credential: TiebaSessionCredential, expectedUserID: Int64, threadID: Int64,
    beforeDispatch: @escaping @Sendable () async throws -> Void
  ) async throws -> TiebaCloudFavoriteRecordCleanupReceipt {
    await beforeHook()
    try await beforeDispatch()
    let key = try XCTUnwrap(
      CloudFavoriteMutationLedgerKey(userID: expectedUserID, threadID: threadID))
    let record = try await ledger.record(for: key)
    XCTAssertEqual(record?.phase, .dispatchPending, "Persistence must precede dispatch")
    dispatches += 1
    await afterHook()
    return .init(target: .init(userID: expectedUserID, threadID: threadID), outcome: outcome)
  }

  func verifyCloudFavoriteRecordAbsence(
    credential: TiebaSessionCredential, expectedUserID: Int64, threadID: Int64
  ) async throws -> TiebaCloudFavoriteRecordObservation {
    verifications += 1
    return observation
  }

  func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential, expectedUserID: Int64,
    forumID: Int64, threadID: Int64, markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    ordinaryWrites += 1
    return .init(
      userID: expectedUserID, forumID: forumID, threadID: threadID, markedPostID: markedPostID)
  }

  func validateAccount(credential: TiebaBDUSSCredential) async throws -> TiebaAuthenticatedAccount {
    throw CloudFavoriteRecordRemovalError.unavailable
  }
  func getFollowedForums(
    credential: TiebaBDUSSCredential, userID: Int64, page: Int, pageSize: Int
  ) async throws -> TiebaFollowedForumPage { throw CloudFavoriteRecordRemovalError.unavailable }
  func getForumMembership(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumMembership { throw CloudFavoriteRecordRemovalError.unavailable }
  func getForumAccountState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw CloudFavoriteRecordRemovalError.unavailable }
  func setForumFollowState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64,
    forumName: String, isFollowed: Bool
  ) async throws -> TiebaForumMembership { throw CloudFavoriteRecordRemovalError.unavailable }
  func checkInToForum(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw CloudFavoriteRecordRemovalError.unavailable }
}

private actor CleanupFailingLedger: CloudFavoriteMutationLedgerRepository {
  func records() async throws -> [CloudFavoriteMutationLedgerRecord] {
    throw CloudFavoriteMutationLedgerError.readFailed
  }
  func record(for key: CloudFavoriteMutationLedgerKey) async throws
    -> CloudFavoriteMutationLedgerRecord?
  {
    throw CloudFavoriteMutationLedgerError.readFailed
  }
  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    throw CloudFavoriteMutationLedgerError.writeFailed
  }
  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    throw CloudFavoriteMutationLedgerError.writeFailed
  }
  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    async throws
  {
    throw CloudFavoriteMutationLedgerError.writeFailed
  }
}

private actor CleanupTransitionFaultLedger: CloudFavoriteMutationLedgerRepository {
  private let storage = TransientCloudFavoriteMutationLedger()
  private var failsNextTransition = true
  func records() async throws -> [CloudFavoriteMutationLedgerRecord] { try await storage.records() }
  func record(for key: CloudFavoriteMutationLedgerKey) async throws
    -> CloudFavoriteMutationLedgerRecord?
  {
    try await storage.record(for: key)
  }
  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try await storage.prepare(
      key: key, operationID: operationID, sessionRevision: sessionRevision, now: now)
  }
  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    if failsNextTransition {
      failsNextTransition = false
      throw CloudFavoriteMutationLedgerError.writeFailed
    }
    return try await storage.transition(key: key, operationID: operationID, phase: phase, now: now)
  }
  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    async throws
  {
    try await storage.removeAfterDefiniteFailure(key: key, operationID: operationID)
  }
}

/// Mirrors the production file journal's cancellable lock acquisition. A plain
/// transient ledger would not catch accidentally persisting on a cancelled task.
private actor CleanupCancellationAwareLedger: CloudFavoriteMutationLedgerRepository {
  private let storage = TransientCloudFavoriteMutationLedger()
  private let afterPrepare: @Sendable () async -> Void
  init(afterPrepare: @escaping @Sendable () async -> Void = {}) { self.afterPrepare = afterPrepare }
  func records() async throws -> [CloudFavoriteMutationLedgerRecord] {
    try Task.checkCancellation()
    return await storage.records()
  }
  func record(for key: CloudFavoriteMutationLedgerKey) async throws
    -> CloudFavoriteMutationLedgerRecord?
  {
    try Task.checkCancellation()
    return try await storage.record(for: key)
  }
  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try Task.checkCancellation()
    let record = try await storage.prepare(
      key: key, operationID: operationID, sessionRevision: sessionRevision, now: now)
    await afterPrepare()
    return record
  }
  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try Task.checkCancellation()
    return try await storage.transition(key: key, operationID: operationID, phase: phase, now: now)
  }
  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    async throws
  {
    try Task.checkCancellation()
    try await storage.removeAfterDefiniteFailure(key: key, operationID: operationID)
  }
}
