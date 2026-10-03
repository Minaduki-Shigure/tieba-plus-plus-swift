import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@MainActor
final class TiebaCloudFavoriteRecordCleanupTests: XCTestCase {
  private let userID: Int64 = 123
  private let threadID: Int64 = 456

  func testRecordRequestUsesNullForumAndExactTIDWithoutRelaxingNormalTargets() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID,
      tbs: String(repeating: "a", count: 26)
    )
    let fields = cleanupFields(request)
    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/post/rmstore")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), "123")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "fid", "stoken", "tbs", "tid", "user_id", "sign",
      ])
    XCTAssertEqual(fields["fid"], "null")
    XCTAssertEqual(fields["tid"], "456")
    XCTAssertEqual(fields["user_id"], "123")
    XCTAssertEqual(fields["tbs"], String(repeating: "a", count: 26))
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
      ))
    XCTAssertThrowsError(
      try factory.setThreadCloudFavoriteState(
        credential: cleanupCredential(), expectedUserID: userID, forumID: 0,
        threadID: threadID, tbs: String(repeating: "a", count: 26), markedPostID: nil
      ))
    for target in [(Int64(0), threadID), (userID, Int64(0))] {
      XCTAssertThrowsError(
        try factory.cleanupCloudFavoriteRecord(
          credential: cleanupCredential(), expectedUserID: target.0, threadID: target.1,
          tbs: String(repeating: "a", count: 26)
        ))
    }
    XCTAssertThrowsError(
      try factory.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID, tbs: "bad"
      ))
  }

  func testDeletedRecordUsesExactListPresenceFreshSessionAndOneDispatch() async throws {
    let transport = CleanupRecordTransport(pages: [[456]])
    let client = TiebaAuthenticatedClient(transport: transport)
    let hook = CleanupRecordHook()
    let receipt = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writes, 0)
      XCTAssertEqual(snapshot.offsets, [0])
      XCTAssertEqual(snapshot.appProbes, 2)
      XCTAssertEqual(snapshot.webProbes, 2)
      try await hook.call()
    }
    XCTAssertEqual(receipt.target, .init(userID: 123, threadID: 456))
    XCTAssertEqual(receipt.outcome, .acceptedAwaitingVerification)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
    XCTAssertEqual(snapshot.paths.last, "/c/c/post/rmstore")
    XCTAssertFalse(snapshot.paths.contains("/c/f/pb/page"))
    let calls = await hook.calls
    XCTAssertEqual(calls, 1)
    let repeated = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) { XCTFail("A retained receipt must not dispatch again") }
    XCTAssertEqual(repeated, receipt)
    let after = await transport.snapshot()
    XCTAssertEqual(after.writes, snapshot.writes)
    XCTAssertEqual(after.offsets, snapshot.offsets)
    XCTAssertEqual(after.appProbes, snapshot.appProbes + 1)
    XCTAssertEqual(after.webProbes, snapshot.webProbes + 1)
  }

  func testShortNonemptyPageCannotProveAbsenceAndContinuesUntilTargetAppears() async throws {
    let transport = CleanupRecordTransport(pages: [[789], [456]])
    let receipt = try await TiebaAuthenticatedClient(transport: transport)
      .cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) {}
    XCTAssertEqual(receipt.outcome, .acceptedAwaitingVerification)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets, [0, 20])
  }

  func testAbsentRecordStopsBeforeDispatchHook() async {
    let transport = CleanupRecordTransport(pages: [[], []])
    await assertPreflightError(.recordNotPresent, transport: transport)
  }

  func testFirstPageExactTargetCanDispatchWhenLaterPagesWouldFailOrExceedLimit() async throws {
    let laterPages: [[Int64]] = (0...100).map { index in
      let first = Int64(index) * 20 + 1_000
      return (0..<20).map { first + Int64($0) }
    }
    let veryLargeList: [[Int64]] = [[456]] + laterPages
    for transport in [
      CleanupRecordTransport(pages: [[456]], listFailureAfterPages: 1),
      CleanupRecordTransport(pages: veryLargeList),
    ] {
      let receipt = try await TiebaAuthenticatedClient(transport: transport)
        .cleanupCloudFavoriteRecord(
          credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
        ) {}
      XCTAssertEqual(receipt.outcome, .acceptedAwaitingVerification)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.offsets, [0])
      XCTAssertEqual(snapshot.writes, 1)
    }
  }

  func testVerificationReportsExactPresenceWithoutReadingUnavailableLaterPages() async throws {
    let transport = CleanupRecordTransport(pages: [[456]], listFailureAfterPages: 1)
    let observation = try await TiebaAuthenticatedClient(transport: transport)
      .verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      )
    XCTAssertEqual(observation, .observedPresent)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets, [0])
    XCTAssertEqual(snapshot.writes, 0)
  }

  func testShortNonemptyPagesStillRequireTwoEmptyTerminatorsToObserveAbsence() async throws {
    let transport = CleanupRecordTransport(pages: [[789], [], [789], []])
    let observation = try await TiebaAuthenticatedClient(transport: transport)
      .verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      )
    XCTAssertEqual(observation, .observedAbsent)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets, [0, 20, 0, 20])
  }

  func testTargetAppearingDuringSecondScanImmediatelyObservesPresence() async throws {
    let transport = CleanupRecordTransport(pages: [[789], [], [789], [456]])
    let observation = try await TiebaAuthenticatedClient(transport: transport)
      .verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      )
    XCTAssertEqual(observation, .observedPresent)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets, [0, 20, 0, 20])
  }

  func testDuplicateAndChangedScansNeverDispatch() async {
    let cases: [([[Int64]], TiebaCloudFavoriteRecordScanIssue)] = [
      ([[789, 789]], .duplicateRecord),
      ([[789], [789]], .duplicateRecord),
      ([[789], [], [999], []], .changedBetweenScans),
      ([[789, 999], [], [999, 789], []], .changedBetweenScans),
    ]
    for (pages, issue) in cases {
      await assertPreflightError(
        .inconclusive(issue), transport: CleanupRecordTransport(pages: pages))
    }
  }

  func testNonemptyPagePastLimitIsInconclusiveWhenTargetWasNotSeen() async {
    let pages = (0...100).map { index in [Int64(index) + 1_000] }
    let transport = CleanupRecordTransport(pages: pages)
    await assertPreflightError(.inconclusive(.limitExceeded), transport: transport)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets.count, 101)
    XCTAssertEqual(snapshot.offsets.last, 2_000)
  }

  func testMalformedListAndListFailureNeverEstablishAbsence() async throws {
    for data in [
      Data("{\"error_code\":0}".utf8),
      Data("{\"store_thread\":[]}".utf8),
      Data("{\"error_code\":7,\"store_thread\":[]}".utf8),
      Data("{\"error_code\":false,\"store_thread\":[]}".utf8),
    ] {
      let transport = CleanupRecordTransport(pages: [], listOverride: data)
      let observation = try await TiebaAuthenticatedClient(transport: transport)
        .verifyCloudFavoriteRecordAbsence(
          credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
        )
      XCTAssertEqual(observation, .inconclusive(.unreadablePage))
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writes, 0)
    }
  }

  func testMaximumCompleteListCanTerminateWithEmptyPageAtTheLimit() async throws {
    var pages: [[Int64]] = (0..<100).map { index in
      let first = Int64(index) * 20 + 1
      return (0..<20).map { first + Int64($0) }
    }
    pages.append([])
    let transport = CleanupRecordTransport(pages: pages + pages)
    let observation = try await TiebaAuthenticatedClient(transport: transport)
      .verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: userID, threadID: 2_001
      )
    XCTAssertEqual(observation, .observedAbsent)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets.count, 202)
    XCTAssertEqual(snapshot.offsets.last, 2_000)
    XCTAssertEqual(snapshot.writes, 0)
  }

  func testDeadlineReturnsAndCancelsTransportWithoutWaitingForItsCompletion() async throws {
    let gate = CleanupRecordResponseGate()
    let transport = CleanupRecordTransport(pages: [[456], [456]], listGates: [1: gate])
    let client = TiebaAuthenticatedClient(
      transport: transport, cloudFavoriteRecordScanTimeout: .milliseconds(100))
    let hook = CleanupRecordHook()
    let finished = CleanupRecordCompletion()
    let task = Task {
      defer { finished.finish() }
      return try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: 123, threadID: 456
      ) { try await hook.call() }
    }
    let completion = await finished.wait()
    let cancelled = await gate.waitUntilCancelled()
    let suspended = await gate.isSuspended
    let before = await transport.snapshot()
    let hookCalls = await hook.calls
    // Release on failure so a broken timeout cannot leave the test hanging.
    if !completion { await gate.release() }
    XCTAssertTrue(completion, "Deadline must finish while transport is suspended")
    XCTAssertTrue(cancelled)
    XCTAssertTrue(suspended)
    XCTAssertEqual(before.writes, 0)
    XCTAssertEqual(hookCalls, 0)
    switch await task.result {
    case .success: XCTFail("A response arriving after the deadline cannot authorize dispatch")
    case .failure(let error):
      XCTAssertEqual(
        error as? TiebaCloudFavoriteRecordCleanupError, .inconclusive(.deadlineExceeded))
    }
    let retry: TiebaCloudFavoriteRecordCleanupReceipt
    do {
      retry = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) { try await hook.call() }
    } catch {
      await gate.release()
      throw error
    }
    XCTAssertEqual(retry.outcome, .acceptedAwaitingVerification)
    // The replacement write must finish while the old transport is still held.
    let stillSuspended = await gate.isSuspended
    XCTAssertTrue(stillSuspended)
    await gate.release()
    let returned = await gate.waitUntilReturned()
    XCTAssertTrue(returned)
    await assertNormalWriteConflict(client)
    let after = await transport.snapshot()
    XCTAssertEqual(after.writes, 1)
  }

  func testVerificationDeadlineDoesNotStartFinalAccountProbes() async throws {
    let gate = CleanupRecordResponseGate()
    let transport = CleanupRecordTransport(pages: [[]], listGates: [1: gate])
    let client = TiebaAuthenticatedClient(
      transport: transport, cloudFavoriteRecordScanTimeout: .milliseconds(100))
    let finished = CleanupRecordCompletion()
    let task = Task {
      defer { finished.finish() }
      return try await client.verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: 123, threadID: 456)
    }
    let completed = await finished.wait()
    let cancelled = await gate.waitUntilCancelled()
    let before = await transport.snapshot()
    await gate.release()
    XCTAssertTrue(completed)
    XCTAssertTrue(cancelled)
    let observation = try await task.value
    XCTAssertEqual(observation, .inconclusive(.deadlineExceeded))
    XCTAssertEqual(before.appProbes, 1)
    XCTAssertEqual(before.webProbes, 1)
    XCTAssertEqual(before.offsets, [0])
    XCTAssertEqual(before.writes, 0)
    let returned = await gate.waitUntilReturned()
    XCTAssertTrue(returned)
    let after = await transport.snapshot()
    XCTAssertEqual(after.paths, before.paths)
  }

  func testParentCancellationReturnsWithoutWaitingForSuspendedTransport() async throws {
    let gate = CleanupRecordResponseGate()
    let transport = CleanupRecordTransport(pages: [[456], [456]], listGates: [1: gate])
    let client = TiebaAuthenticatedClient(transport: transport)
    let hook = CleanupRecordHook()
    let finished = CleanupRecordCompletion()
    let task = Task {
      defer { finished.finish() }
      return try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: 123, threadID: 456
      ) { try await hook.call() }
    }
    let entered = await gate.waitUntilEntered()
    task.cancel()
    let completion = await finished.wait()
    let cancelled = await gate.waitUntilCancelled()
    let suspended = await gate.isSuspended
    let before = await transport.snapshot()
    let hookCalls = await hook.calls
    if !completion { await gate.release() }
    XCTAssertTrue(completion, "Cancellation must finish while transport is suspended")
    XCTAssertTrue(entered)
    XCTAssertTrue(cancelled)
    XCTAssertTrue(suspended)
    XCTAssertEqual(before.writes, 0)
    XCTAssertEqual(hookCalls, 0)
    switch await task.result {
    case .success: XCTFail("Expected cancellation before dispatch")
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    }
    let retry: TiebaCloudFavoriteRecordCleanupReceipt
    do {
      retry = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) {}
    } catch {
      await gate.release()
      throw error
    }
    XCTAssertEqual(retry.outcome, .acceptedAwaitingVerification)
    let stillSuspended = await gate.isSuspended
    XCTAssertTrue(stillSuspended)
    await gate.release()
    let returned = await gate.waitUntilReturned()
    XCTAssertTrue(returned)
    await assertNormalWriteConflict(client)
    let after = await transport.snapshot()
    XCTAssertEqual(after.writes, 1)
  }

  func testSecondScanUsesRemainingBudgetFromFirstScan() async throws {
    let gate = CleanupRecordResponseGate()
    let transport = CleanupRecordTransport(pages: [[], []], listGates: [1: gate])
    let client = TiebaAuthenticatedClient(
      transport: transport, cloudFavoriteRecordScanTimeout: .seconds(2))
    let task = Task {
      try await client.verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: 123, threadID: 456)
    }
    let entered = await gate.waitUntilEntered()
    try? await Task.sleep(for: .milliseconds(150))
    await gate.release()
    let observation = try await task.value
    XCTAssertTrue(entered)
    XCTAssertEqual(observation, .observedAbsent)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.offsets, [0, 0])
    XCTAssertEqual(snapshot.listTimeouts.count, 2)
    if snapshot.listTimeouts.count == 2 {
      XCTAssertLessThan(snapshot.listTimeouts[1], snapshot.listTimeouts[0] - 0.1)
    }
    XCTAssertEqual(snapshot.writes, 0)
  }

  func testInitialAndFinalSessionMismatchAndMissingFreshTBSNeverDispatch() async {
    let transports = [
      CleanupRecordTransport(pages: [[456], [], [456], []], appIDs: [999]),
      CleanupRecordTransport(pages: [[456], [], [456], []], webIDs: [999]),
      CleanupRecordTransport(pages: [[456], [], [456], []], appIDs: [123, 999]),
      CleanupRecordTransport(pages: [[456], [], [456], []], webIDs: [123, 999]),
      CleanupRecordTransport(pages: [[456], [], [456], []], tbs: ""),
    ]
    for transport in transports {
      do {
        _ = try await TiebaAuthenticatedClient(transport: transport).cleanupCloudFavoriteRecord(
          credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
        ) { XCTFail("Invalid identity cannot reach dispatch hook") }
        XCTFail("Expected session validation failure")
      } catch {
        XCTAssertEqual(error as? TiebaClientError, .invalidAuthenticatedResponse)
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writes, 0)
    }
  }

  func testThrowingDispatchHookRemainsPreflightAndDoesNotCreateTerminal() async throws {
    let transport = CleanupRecordTransport(pages: [[456], [456]])
    let client = TiebaAuthenticatedClient(transport: transport)
    do {
      _ = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) { throw CleanupHookFailure.leaseChanged }
      XCTFail("Expected hook failure")
    } catch {
      XCTAssertEqual(error as? CleanupHookFailure, .leaseChanged)
    }
    let before = await transport.snapshot()
    XCTAssertEqual(before.writes, 0)
    let receipt = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {}
    XCTAssertEqual(receipt.outcome, .acceptedAwaitingVerification)
    let after = await transport.snapshot()
    XCTAssertEqual(after.writes, 1)
  }

  func testStrictACKDistinguishesServerRejectionFromEveryUncertainResponse() async throws {
    let cases: [(CleanupRecordTransport.WriteBehavior, TiebaCloudFavoriteRecordCleanupOutcome)] = [
      (.body(Data("{\"error_code\":0}".utf8)), .acceptedAwaitingVerification),
      (.body(Data("{\"error_code\":\"0\"}".utf8)), .acceptedAwaitingVerification),
      (
        .body(Data("{\"error_code\":4,\"error_msg\":\"denied\"}".utf8)),
        .rejected(code: 4, message: "denied")
      ),
      (.body(Data("{}".utf8)), .unknown),
      (.body(Data("{\"error_code\":false}".utf8)), .unknown),
      (.body(Data("{\"error_code\":0.5}".utf8)), .unknown),
      (.body(Data("{\"error_code\":0,\"errno\":4}".utf8)), .unknown),
      (.body(Data("garbage".utf8)), .unknown),
      (.network, .unknown),
      (.cancellation, .unknown),
      (.httpError, .unknown),
      (.oversized, .unknown),
    ]
    for (behavior, expected) in cases {
      let transport = CleanupRecordTransport(
        pages: [[456], [], [456], []], writeBehavior: behavior)
      let receipt = try await TiebaAuthenticatedClient(transport: transport)
        .cleanupCloudFavoriteRecord(
          credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
        ) {}
      XCTAssertEqual(receipt.outcome, expected)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writes, 1)
    }
  }

  func testUnknownCannotBeResentAndDoesNotBecomeAcknowledgedAfterAbsentReadback() async throws {
    let transport = CleanupRecordTransport(
      pages: [[456], [], []], writeBehavior: .network
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let receipt = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {}
    XCTAssertEqual(receipt.outcome, .unknown)
    let repeated = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) { XCTFail("Unknown dispatch must never be resent") }
    XCTAssertEqual(repeated.outcome, .unknown)
    await assertNormalWriteConflict(client)
    let observation = try await client.verifyCloudFavoriteRecordAbsence(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    )
    XCTAssertEqual(observation, .observedAbsent)
    XCTAssertEqual(receipt.outcome, .unknown)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
    // Terminal was cleared by absence: a new cleanup performs preflight rather
    // than returning the old unknown receipt, and cannot delete an absent record.
    do {
      _ = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) { XCTFail("Absent record cannot dispatch") }
      XCTFail("Expected absent record")
    } catch {
      XCTAssertEqual(error as? TiebaCloudFavoriteRecordCleanupError, .recordNotPresent)
    }
  }

  func testObservedPresentDoesNotReleaseUnknownTerminal() async throws {
    let transport = CleanupRecordTransport(
      pages: [[456], [456]], writeBehavior: .network
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    _ = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {}
    let observation = try await client.verifyCloudFavoriteRecordAbsence(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    )
    XCTAssertEqual(observation, .observedPresent)
    await assertNormalWriteConflict(client)
    let receipt = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) { XCTFail("Present is not authorization to retry an uncertain write") }
    XCTAssertEqual(receipt.outcome, .unknown)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
  }

  func testCancelledTaskAfterDispatchHookDoesNotDispatchAndAllowsNewConfirmation() async throws {
    let transport = CleanupRecordTransport(pages: [[456], [456]])
    let client = TiebaAuthenticatedClient(transport: transport)
    let credential = cleanupCredential()
    let task = Task {
      try await client.cleanupCloudFavoriteRecord(
        credential: credential, expectedUserID: 123, threadID: 456
      ) {
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    let receipt = try await task.value
    XCTAssertEqual(receipt.outcome, .notDispatched)
    let before = await transport.snapshot()
    XCTAssertEqual(before.writes, 0)
    let hook = CleanupRecordHook()
    let repeated = try await client.cleanupCloudFavoriteRecord(
      credential: credential, expectedUserID: 123, threadID: 456
    ) { try await hook.call() }
    XCTAssertEqual(repeated.outcome, .acceptedAwaitingVerification)
    let calls = await hook.calls
    XCTAssertEqual(calls, 1)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
  }

  func testIdentityChangeAtVerificationEndDoesNotReleaseUnknownTerminal() async throws {
    let transport = CleanupRecordTransport(
      pages: [[456], [], []], appIDs: [123, 123, 123, 999],
      writeBehavior: .network
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    _ = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {}
    do {
      _ = try await client.verifyCloudFavoriteRecordAbsence(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      )
      XCTFail("An identity mismatch cannot resolve pending intent")
    } catch {
      XCTAssertEqual(error as? TiebaClientError, .invalidAuthenticatedResponse)
    }
    await assertNormalWriteConflict(client)
  }

  func testCachedReceiptStillRequiresCurrentAppAndWebIdentity() async throws {
    let transport = CleanupRecordTransport(
      pages: [[456], [], [456], []], webIDs: [123, 123, 999]
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    _ = try await client.cleanupCloudFavoriteRecord(
      credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
    ) {}
    do {
      _ = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) { XCTFail("Cached receipt must never dispatch") }
      XCTFail("Expected account validation failure instead of a cached receipt")
    } catch {
      XCTAssertEqual(error as? TiebaClientError, .invalidAuthenticatedResponse)
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
  }

  func testExplicitRejectionReleasesDispatchLockForNewAuthorizedAttempt() async throws {
    let transport = CleanupRecordTransport(
      pages: [[456], [456]],
      writeBehavior: .body(Data("{\"error_code\":4}".utf8))
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    for _ in 0..<2 {
      let receipt = try await client.cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) {}
      guard case .rejected(code: 4, message: _) = receipt.outcome else {
        return XCTFail("Expected explicit rejection")
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 2)
  }

  func testCleanupHookHoldsSameUIDTIDLockAgainstNormalWriteAndSecondCleanup() async throws {
    let transport = CleanupRecordTransport(pages: [[456], [], [456], []])
    let client = TiebaAuthenticatedClient(transport: transport)
    let hook = CleanupRecordHook(blocks: true)
    let credential = cleanupCredential()
    let task = Task {
      try await client.cleanupCloudFavoriteRecord(
        credential: credential, expectedUserID: 123, threadID: 456
      ) { try await hook.call() }
    }
    guard await hook.waitUntilCalled() else {
      await hook.release()
      task.cancel()
      return XCTFail("Timed out waiting for hook")
    }
    await assertNormalWriteConflict(client)
    do {
      _ = try await client.cleanupCloudFavoriteRecord(
        credential: credential, expectedUserID: userID, threadID: threadID
      ) { XCTFail("Conflicting cleanup must not enter hook") }
      XCTFail("Expected lock conflict")
    } catch {
      XCTAssertEqual(error as? TiebaCloudFavoriteRecordCleanupError, .writeConflict)
    }
    await hook.release()
    let receipt = try await task.value
    XCTAssertEqual(receipt.outcome, .acceptedAwaitingVerification)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 1)
  }

  func testExistingNormalWritePreflightExcludesRecordCleanup() async throws {
    let transport = CleanupRecordTransport(pages: [], blocksPB: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let credential = cleanupCredential()
    let normal = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential, expectedUserID: 123, forumID: 9,
        threadID: 456, markedPostID: nil
      )
    }
    guard await transport.waitUntilPB() else {
      await transport.releasePB()
      return XCTFail("Timed out waiting for normal preflight")
    }
    do {
      _ = try await client.cleanupCloudFavoriteRecord(
        credential: credential, expectedUserID: 123, threadID: 456
      ) { XCTFail("Conflicting cleanup must not enter hook") }
      XCTFail("Expected lock conflict")
    } catch {
      XCTAssertEqual(error as? TiebaCloudFavoriteRecordCleanupError, .writeConflict)
    }
    await transport.releasePB()
    _ = await normal.result
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 0)
    XCTAssertEqual(snapshot.appProbes, 0)
  }

  private func assertNormalWriteConflict(_ client: TiebaAuthenticatedClient) async {
    for marker: Int64? in [nil, 7] {
      do {
        _ = try await client.setThreadCloudFavoriteState(
          credential: cleanupCredential(), expectedUserID: userID, forumID: 9,
          threadID: threadID, markedPostID: marker
        )
        XCTFail("Expected normal write conflict")
      } catch {
        XCTAssertEqual(error as? TiebaCloudFavoriteRecordCleanupError, .writeConflict)
      }
    }
  }

  private func assertPreflightError(
    _ expected: TiebaCloudFavoriteRecordCleanupError,
    transport: CleanupRecordTransport
  ) async {
    do {
      _ = try await TiebaAuthenticatedClient(transport: transport).cleanupCloudFavoriteRecord(
        credential: cleanupCredential(), expectedUserID: userID, threadID: threadID
      ) { XCTFail("Preflight failure cannot reach dispatch hook") }
      XCTFail("Expected preflight failure")
    } catch {
      XCTAssertEqual(error as? TiebaCloudFavoriteRecordCleanupError, expected)
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writes, 0)
  }
}

private enum CleanupHookFailure: Error, Equatable { case leaseChanged }

private actor CleanupRecordHook {
  var calls = 0
  let blocks: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  init(blocks: Bool = false) { self.blocks = blocks }

  func call() async throws {
    calls += 1
    if blocks, !released {
      await withCheckedContinuation { continuation = $0 }
    }
  }

  func waitUntilCalled() async -> Bool {
    for _ in 0..<1_000 {
      if calls > 0 { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor CleanupRecordTransport: TiebaTransport {
  enum WriteBehavior: Sendable {
    case body(Data)
    case network
    case cancellation
    case httpError
    case oversized
  }

  struct Snapshot: Sendable {
    let paths: [String]
    let offsets: [Int]
    let listTimeouts: [TimeInterval]
    let appProbes: Int
    let webProbes: Int
    let writes: Int
  }

  private var pages: [[Int64]]
  private let listOverride: Data?
  private let listFailureAfterPages: Int?
  private var appIDs: [Int64]
  private var webIDs: [Int64]
  private let tbs: String
  private let writeBehavior: WriteBehavior
  private var paths = [String]()
  private var offsets = [Int]()
  private var listTimeouts = [TimeInterval]()
  private let listGates: [Int: CleanupRecordResponseGate]
  private var appProbes = 0
  private var webProbes = 0
  private var writes = 0
  private let blocksPB: Bool
  private var pbContinuation: CheckedContinuation<Void, Never>?
  private var pbEntered = false
  private var pbReleased = false

  init(
    pages: [[Int64]],
    listOverride: Data? = nil,
    listFailureAfterPages: Int? = nil,
    appIDs: [Int64] = [],
    webIDs: [Int64] = [],
    tbs: String = String(repeating: "a", count: 26),
    writeBehavior: WriteBehavior = .body(Data("{\"error_code\":0}".utf8)),
    blocksPB: Bool = false,
    listGates: [Int: CleanupRecordResponseGate] = [:]
  ) {
    self.pages = pages
    self.listOverride = listOverride
    self.listFailureAfterPages = listFailureAfterPages
    self.appIDs = appIDs
    self.webIDs = webIDs
    self.tbs = tbs
    self.writeBehavior = writeBehavior
    self.blocksPB = blocksPB
    self.listGates = listGates
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(_ request: URLRequest, maximumBodyBytes: Int?) async throws -> TiebaHTTPResponse {
    let path = request.url?.path ?? ""
    paths.append(path)
    let body: Data
    switch path {
    case "/c/s/login":
      appProbes += 1
      let uid = appIDs.isEmpty ? 123 : appIDs.removeFirst()
      body = try JSONSerialization.data(withJSONObject: [
        "error_code": 0, "user": ["id": String(uid), "name": "user", "portrait": "portrait"],
        "anti": ["tbs": tbs],
      ])
    case "/mo/q/newmoindex":
      webProbes += 1
      let uid = webIDs.isEmpty ? 123 : webIDs.removeFirst()
      body = Data("{\"no\":0,\"data\":{\"id\":\"\(uid)\"}}".utf8)
    case "/c/f/post/threadstore":
      let fields = cleanupFields(request)
      offsets.append(Int(fields["offset"] ?? "") ?? -1)
      listTimeouts.append(request.timeoutInterval)
      if let listFailureAfterPages, offsets.count > listFailureAfterPages {
        throw URLError(.timedOut)
      }
      guard fields["rn"] == "20" else { throw TiebaClientError.invalidArgument("Unexpected rn") }
      let ids = pages.isEmpty ? [] : pages.removeFirst()
      if let gate = listGates[offsets.count] { await gate.waitIgnoringCancellation() }
      body =
        try listOverride
        ?? JSONSerialization.data(withJSONObject: [
          "error_code": 0, "store_thread": ids.map { cleanupFavoriteObject(id: $0) },
        ])
    case "/c/c/post/rmstore":
      writes += 1
      let fields = cleanupFields(request)
      guard fields["fid"] == "null", fields["tid"] == "456", fields["user_id"] == "123" else {
        throw TiebaClientError.invalidArgument("Unexpected cleanup target")
      }
      switch writeBehavior {
      case .body(let value): body = value
      case .network: throw URLError(.timedOut)
      case .cancellation: throw CancellationError()
      case .httpError: return TiebaHTTPResponse(body: Data(), statusCode: 503)
      case .oversized:
        body = Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.threadCloudFavoriteWriteResponseMaximumBytes + 1)
      }
    case "/c/f/pb/page":
      pbEntered = true
      if blocksPB, !pbReleased {
        await withCheckedContinuation { pbContinuation = $0 }
      }
      throw TiebaClientError.network(code: URLError.timedOut.rawValue)
    default: throw TiebaClientError.invalidEndpoint
    }
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func snapshot() -> Snapshot {
    .init(
      paths: paths, offsets: offsets, listTimeouts: listTimeouts,
      appProbes: appProbes, webProbes: webProbes, writes: writes)
  }

  func waitUntilPB() async -> Bool {
    for _ in 0..<1_000 {
      if pbEntered { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func releasePB() {
    pbReleased = true
    pbContinuation?.resume()
    pbContinuation = nil
  }
}

/// Models a response body that never finishes even when its task is cancelled.
/// Tests explicitly release it after checking that the client has already returned.
private actor CleanupRecordResponseGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered = false
  private var released = false
  private var cancelled = false
  private var returned = false

  var isSuspended: Bool { entered && !released }

  func waitIgnoringCancellation() async {
    entered = true
    await withTaskCancellationHandler {
      if !released { await withCheckedContinuation { continuation = $0 } }
    } onCancel: {
      Task { await self.recordCancellation() }
    }
    returned = true
  }

  func waitUntilEntered() async -> Bool {
    for _ in 0..<1_000 {
      if entered { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func waitUntilCancelled() async -> Bool {
    for _ in 0..<1_000 {
      if cancelled { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func waitUntilReturned() async -> Bool {
    for _ in 0..<1_000 {
      if returned { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }

  private func recordCancellation() { cancelled = true }
}

private final class CleanupRecordCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  func finish() {
    lock.lock()
    completed = true
    lock.unlock()
  }

  func wait() async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if isCompleted { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return isCompleted
  }

  private var isCompleted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }
}

private func cleanupCredential() -> TiebaSessionCredential {
  .init(
    bduss: String(repeating: "b", count: 192), stoken: String(repeating: "s", count: 64),
    bdussCookieName: .bduss)
}

private func cleanupFields(_ request: URLRequest) -> [String: String] {
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    .replacingOccurrences(of: "+", with: "%20")
  return Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    })
}

private func cleanupFavoriteObject(id: Int64) -> [String: Any] {
  [
    "thread_id": String(id), "title": "Deleted favorite", "forum_name": "", "author": [:],
    "is_deleted": "1", "last_time": "0", "type": "0", "status": "0", "max_pid": "0",
    "min_pid": "0", "mark_pid": "0", "mark_status": "0", "post_no": "0", "post_no_msg": "",
    "count": "0",
  ]
}
