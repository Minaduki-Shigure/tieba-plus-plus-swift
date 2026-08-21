import Foundation
import SwiftProtobuf
import XCTest

@testable import TiebaCore
@testable import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaNewThreadClientTests: XCTestCase, @unchecked Sendable {
  private let firstUserID: Int64 = 1_001
  private let secondUserID: Int64 = 1_002
  private let forumID: Int64 = 2_002

  func testClientConfirmsNewThreadUsingBoundedPreflightWriteAndReadback() async throws {
    let transport = NewThreadStateTransport(forumID: forumID)
    let client = TiebaAuthenticatedClient(transport: transport)
    let submission = makeSubmission()
    let result = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission
    )

    XCTAssertEqual(result.submissionID, submission.submissionID)
    XCTAssertEqual(result.userID, firstUserID)
    XCTAssertEqual(result.forumID, forumID)
    XCTAssertEqual(result.forumName, "swift")
    guard case .confirmed(let receipt) = result.outcome else {
      return XCTFail("Expected confirmed thread")
    }
    XCTAssertGreaterThan(receipt.threadID, 0)
    XCTAssertGreaterThan(receipt.firstPostID, 0)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 1)
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.readbackCount, 1)
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.newThreadWriteResponseMaximumBytes,
        TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
      ]
    )
  }

  func testValidReceiptWithMissingFirstFloorIsAcceptedAwaitingVisibility() async throws {
    let transport = NewThreadStateTransport(forumID: forumID, behavior: .missingReadback)
    let client = TiebaAuthenticatedClient(transport: transport)
    let result = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: makeSubmission()
    )
    guard case .acceptedAwaitingVisibility(let receipt) = result.outcome else {
      return XCTFail("Expected accepted receipt")
    }
    XCTAssertGreaterThan(receipt.threadID, 0)
    XCTAssertGreaterThan(receipt.firstPostID, 0)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.readbackCount, 1)
  }

  func testVisibilityVerificationUsesFreshContextAndNeverWrites() async throws {
    let submission = makeSubmission()
    let receipt = TiebaNewThreadReceipt(threadID: 30_030, firstPostID: 40_040)
    let transport = NewThreadStateTransport(forumID: forumID)
    await transport.seedThread(
      userID: firstUserID,
      receipt: receipt,
      title: submission.title,
      content: submission.content
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let verified = try await client.verifyNewThreadVisibility(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission,
      receipt: receipt
    )

    XCTAssertEqual(verified, receipt)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 1)
    XCTAssertEqual(snapshot.readbackCount, 1)
    XCTAssertEqual(snapshot.writeCount, 0)
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
      ]
    )
  }

  func testVisibilityVerificationReturnsNilWhileFirstFloorIsUnavailable() async throws {
    let submission = makeSubmission()
    let receipt = TiebaNewThreadReceipt(threadID: 30_030, firstPostID: 40_040)
    let transport = NewThreadStateTransport(
      forumID: forumID,
      behavior: .missingReadback
    )
    await transport.seedThread(
      userID: firstUserID,
      receipt: receipt,
      title: submission.title,
      content: submission.content
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let verified = try await client.verifyNewThreadVisibility(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission,
      receipt: receipt
    )

    XCTAssertNil(verified)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 1)
    XCTAssertEqual(snapshot.readbackCount, 1)
    XCTAssertEqual(snapshot.writeCount, 0)
  }

  func testVisibilityVerificationRejectsMismatchedReadback() async {
    let submission = makeSubmission()
    let receipt = TiebaNewThreadReceipt(threadID: 30_030, firstPostID: 40_040)
    let transport = NewThreadStateTransport(
      forumID: forumID,
      behavior: .mismatchedReadback
    )
    await transport.seedThread(
      userID: firstUserID,
      receipt: receipt,
      title: submission.title,
      content: submission.content
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertClientError(.invalidAuthenticatedResponse) {
      _ = try await client.verifyNewThreadVisibility(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission,
        receipt: receipt
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 1)
    XCTAssertEqual(snapshot.readbackCount, 1)
    XCTAssertEqual(snapshot.writeCount, 0)
  }

  func testVisibilityVerificationRejectsInvalidReceiptBeforeNetwork() async {
    let transport = NewThreadStateTransport(forumID: forumID)
    let client = TiebaAuthenticatedClient(transport: transport)

    for receipt in [
      TiebaNewThreadReceipt(threadID: 0, firstPostID: 1),
      TiebaNewThreadReceipt(threadID: 1, firstPostID: 0),
      TiebaNewThreadReceipt(threadID: -1, firstPostID: -1),
    ] {
      await assertClientError(
        .invalidArgument("New-thread receipt identifiers must be positive.")
      ) {
        _ = try await client.verifyNewThreadVisibility(
          credential: credential(),
          expectedUserID: firstUserID,
          submission: makeSubmission(),
          receipt: receipt
        )
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 0)
    XCTAssertEqual(snapshot.readbackCount, 0)
    XCTAssertEqual(snapshot.writeCount, 0)
    XCTAssertTrue(snapshot.maximumBodyBytes.isEmpty)
  }

  func testVisibilityVerificationRejectsInvalidSubmissionBeforeNetwork() async {
    let transport = NewThreadStateTransport(forumID: forumID)
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertClientError(
      .invalidArgument(
        "Submission text is empty, too large, contains unsupported control characters, or contains an unsupported Tieba rich-content marker."
      )
    ) {
      _ = try await client.verifyNewThreadVisibility(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: ""),
        receipt: TiebaNewThreadReceipt(threadID: 30_030, firstPostID: 40_040)
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 0)
    XCTAssertEqual(snapshot.readbackCount, 0)
    XCTAssertEqual(snapshot.writeCount, 0)
    XCTAssertTrue(snapshot.maximumBodyBytes.isEmpty)
  }

  func testMismatchedReadbackBecomesRetainedUnknown() async {
    let submission = makeSubmission()
    let transport = NewThreadStateTransport(forumID: forumID, behavior: .mismatchedReadback)
    let client = TiebaAuthenticatedClient(transport: transport)
    for _ in 0..<2 {
      await assertClientError(.newThreadOutcomeUnknown) {
        _ = try await client.submitNewThread(
          credential: credential(),
          expectedUserID: firstUserID,
          submission: submission
        )
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testPostDispatchFailuresAreUnknownBoundedAndNeverRetried() async {
    for behavior in [
      NewThreadStateTransport.Behavior.networkAfterWrite,
      .timeoutAfterWrite,
      .cancellationAfterWrite,
      .malformedAfterWrite,
      .oversizedAfterWrite,
    ] {
      let submission = makeSubmission()
      let transport = NewThreadStateTransport(forumID: forumID, behavior: behavior)
      let client = TiebaAuthenticatedClient(transport: transport)
      for _ in 0..<2 {
        await assertClientError(.newThreadOutcomeUnknown) {
          _ = try await client.submitNewThread(
            credential: credential(),
            expectedUserID: firstUserID,
            submission: submission
          )
        }
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writeCount, 1)
      XCTAssertEqual(
        snapshot.maximumBodyBytes.filter {
          $0 == TiebaAuthenticatedClient.newThreadWriteResponseMaximumBytes
        }.count,
        1
      )
    }
  }

  func testChallengeAndServerRejectionRemainDefinitive() async {
    let challengeTransport = NewThreadStateTransport(forumID: forumID, behavior: .challenge)
    let challengeClient = TiebaAuthenticatedClient(transport: challengeTransport)
    await assertClientError(.newThreadChallengeRequired(message: "需要安全验证")) {
      _ = try await challengeClient.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission()
      )
    }
    let challengeSnapshot = await challengeTransport.snapshot()
    XCTAssertEqual(challengeSnapshot.writeCount, 1)

    let serverTransport = NewThreadStateTransport(forumID: forumID, behavior: .server)
    let serverClient = TiebaAuthenticatedClient(transport: serverTransport)
    await assertClientError(.server(code: 340_006, message: "操作被拒绝")) {
      _ = try await serverClient.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission()
      )
    }
    let serverSnapshot = await serverTransport.snapshot()
    XCTAssertEqual(serverSnapshot.writeCount, 1)
  }

  func testSameSubmissionSharesOneFlightAndConflictingIdentityIsRejected() async throws {
    let submission = makeSubmission(content: "e\u{301}")
    let transport = NewThreadStateTransport(forumID: forumID, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for first write")
    }
    let shared = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    let conflict = TiebaNewThreadSubmission(
      submissionID: submission.submissionID,
      forumID: forumID,
      forumName: "different",
      title: submission.title,
      content: submission.content
    )
    await assertClientError(.newThreadSubmissionIDConflict) {
      _ = try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: conflict
      )
    }
    let canonicallyEquivalentConflict = TiebaNewThreadSubmission(
      submissionID: submission.submissionID,
      forumID: submission.forumID,
      forumName: submission.forumName,
      title: submission.title,
      content: "\u{E9}"
    )
    XCTAssertEqual(submission.content, canonicallyEquivalentConflict.content)
    XCTAssertNotEqual(submission, canonicallyEquivalentConflict)
    await assertClientError(.newThreadSubmissionIDConflict) {
      _ = try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: canonicallyEquivalentConflict
      )
    }
    await assertClientError(.newThreadSubmissionIDConflict) {
      _ = try await client.submitNewThread(
        credential: credential(marker: "c"),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    await transport.releaseWrites()
    let firstResult = try await first.value
    let sharedResult = try await shared.value
    XCTAssertEqual(firstResult, sharedResult)
    let retained = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission
    )
    XCTAssertEqual(retained, firstResult)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testCredentialFingerprintUsesEveryCredentialFieldAndRedactsReflection() {
    let base = credential()
    let fingerprint = TiebaNewThreadCredentialFingerprint(credential: base)
    XCTAssertEqual(
      fingerprint,
      TiebaNewThreadCredentialFingerprint(credential: base)
    )
    XCTAssertNotEqual(
      fingerprint,
      TiebaNewThreadCredentialFingerprint(
        credential: TiebaSessionCredential(
          bduss: "changed-\(base.bduss)",
          stoken: base.stoken,
          bdussCookieName: base.bdussCookieName
        )
      )
    )
    XCTAssertNotEqual(
      fingerprint,
      TiebaNewThreadCredentialFingerprint(
        credential: TiebaSessionCredential(
          bduss: base.bduss,
          stoken: "changed-\(base.stoken)",
          bdussCookieName: base.bdussCookieName
        )
      )
    )
    XCTAssertNotEqual(
      fingerprint,
      TiebaNewThreadCredentialFingerprint(
        credential: TiebaSessionCredential(
          bduss: base.bduss,
          stoken: base.stoken,
          bdussCookieName: .bdussBFESS
        )
      )
    )
    XCTAssertEqual(String(describing: fingerprint), "TiebaNewThreadCredentialFingerprint(redacted)")
    XCTAssertEqual(String(reflecting: fingerprint), "TiebaNewThreadCredentialFingerprint(redacted)")
    XCTAssertTrue(Array(fingerprint.customMirror.children).isEmpty)
    XCTAssertFalse(String(reflecting: fingerprint).contains(base.bduss))
    XCTAssertFalse(String(reflecting: fingerprint).contains(base.stoken))
  }

  func testSameAccountSerializesDifferentSubmissions() async throws {
    let transport = NewThreadStateTransport(forumID: forumID, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: "first")
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for first write")
    }
    let second = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: "second")
      )
    }
    try await Task.sleep(for: .milliseconds(40))
    let blockedSnapshot = await transport.snapshot()
    XCTAssertEqual(blockedSnapshot.writeCount, 1)
    await transport.releaseWrites()
    _ = try await first.value
    _ = try await second.value
    let completedSnapshot = await transport.snapshot()
    XCTAssertEqual(completedSnapshot.writeCount, 2)
  }

  func testDifferentAccountsCanWriteInParallel() async throws {
    let transport = NewThreadStateTransport(forumID: forumID, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitNewThread(
        credential: credential(marker: "b"),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: "first")
      )
    }
    let second = Task {
      try await client.submitNewThread(
        credential: credential(marker: "c"),
        expectedUserID: secondUserID,
        submission: makeSubmission(content: "second")
      )
    }
    guard await transport.waitUntilWriteCount(2) else {
      first.cancel()
      second.cancel()
      return XCTFail("Different accounts did not reach writes in parallel")
    }
    await transport.releaseWrites()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult.userID, firstUserID)
    XCTAssertEqual(secondResult.userID, secondUserID)
  }

  func testQueuedCancellationPerformsNoSecondPreflightOrWrite() async throws {
    let transport = NewThreadStateTransport(forumID: forumID, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: "first")
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for first write")
    }
    let queued = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(content: "queued")
      )
    }
    guard await waitUntilNewThreadWaiter(client: client, minimum: 2) else {
      queued.cancel()
      first.cancel()
      return XCTFail("Timed out waiting for queued caller")
    }
    queued.cancel()
    do {
      _ = try await queued.value
      XCTFail("Expected queued cancellation")
    } catch is CancellationError {
      // Expected.
    }
    await transport.releaseWrites()
    _ = try await first.value
    try await Task.sleep(for: .milliseconds(20))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.preflightCount, 1)
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testPreflightCancellationPerformsNoWrite() async throws {
    let transport = NewThreadStateTransport(
      forumID: forumID,
      blocksPreflight: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let task = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission()
      )
    }
    guard await transport.waitUntilPreflightCount(1) else {
      task.cancel()
      return XCTFail("Timed out waiting for preflight")
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected preflight cancellation")
    } catch is CancellationError {
      // Expected.
    }
    try await Task.sleep(for: .milliseconds(20))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 0)
  }

  func testPostDispatchCallerCancellationDoesNotCancelOwnerOrDuplicateWrite() async throws {
    let submission = makeSubmission()
    let transport = NewThreadStateTransport(forumID: forumID, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let caller = Task {
      try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      caller.cancel()
      return XCTFail("Timed out waiting for dispatched write")
    }
    caller.cancel()
    do {
      _ = try await caller.value
      XCTFail("Expected caller cancellation")
    } catch is CancellationError {
      // The owner flight continues after dispatch.
    }
    await transport.releaseWrites()
    let recovered = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission
    )
    guard case .confirmed = recovered.outcome else {
      return XCTFail("Expected retained owner result")
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testCompletedSuccessRetentionIsBounded() async throws {
    let transport = NewThreadStateTransport(forumID: forumID)
    let client = TiebaAuthenticatedClient(transport: transport)
    let submissions = (0...TiebaAuthenticatedClient.retainedNewThreadSubmissionLimit).map {
      makeSubmission(content: "body-\($0)")
    }
    for submission in submissions {
      _ = try await client.submitNewThread(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    let retainedCount = await client.newThreadRetainedFlightCountForTests()
    XCTAssertEqual(retainedCount, TiebaAuthenticatedClient.retainedNewThreadSubmissionLimit)
    let initialWrites = await transport.snapshot().writeCount
    _ = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submissions.last!
    )
    let afterRetained = await transport.snapshot()
    XCTAssertEqual(afterRetained.writeCount, initialWrites)
    _ = try await client.submitNewThread(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submissions.first!
    )
    let afterEvicted = await transport.snapshot()
    XCTAssertEqual(afterEvicted.writeCount, initialWrites + 1)
  }

  private func credential(marker: Character = "b") -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: marker, count: 192),
      stoken: String(repeating: marker == "b" ? "s" : "t", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func makeSubmission(
    title: String = "title",
    content: String = "body"
  ) -> TiebaNewThreadSubmission {
    TiebaNewThreadSubmission(
      submissionID: UUID(),
      forumID: forumID,
      forumName: "swift",
      title: title,
      content: content
    )
  }

  private func assertClientError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected TiebaClientError")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor NewThreadStateTransport: TiebaTransport {
  enum Behavior: Sendable {
    case success
    case missingReadback
    case mismatchedReadback
    case networkAfterWrite
    case timeoutAfterWrite
    case cancellationAfterWrite
    case malformedAfterWrite
    case oversizedAfterWrite
    case challenge
    case server
  }

  struct Snapshot: Sendable {
    let preflightCount: Int
    let writeCount: Int
    let readbackCount: Int
    let maximumBodyBytes: [Int?]
  }

  fileprivate struct StoredThread: Sendable {
    let userID: Int64
    let forumID: Int64
    let threadID: Int64
    let firstPostID: Int64
    let title: String
    let content: String
  }

  private let forumID: Int64
  private let behavior: Behavior
  private let blocksWrites: Bool
  private let blocksPreflight: Bool
  private var preflightCount = 0
  private var writeCount = 0
  private var readbackCount = 0
  private var nextThreadID: Int64 = 30_030
  private var nextPostID: Int64 = 40_040
  private var storedThreads = [Int64: StoredThread]()
  private var maximumBodyBytes = [Int?]()
  private var writesReleased = false
  private var writeWaiters = [CheckedContinuation<Void, Never>]()

  init(
    forumID: Int64,
    behavior: Behavior = .success,
    blocksWrites: Bool = false,
    blocksPreflight: Bool = false
  ) {
    self.forumID = forumID
    self.behavior = behavior
    self.blocksWrites = blocksWrites
    self.blocksPreflight = blocksPreflight
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    self.maximumBodyBytes.append(maximumBodyBytes)
    guard let path = request.url?.path else { throw TiebaClientError.transportFailure }
    switch path {
    case "/c/f/frs/page":
      preflightCount += 1
      if blocksPreflight {
        try await Task.sleep(for: .seconds(60))
      }
      let message = try FrsPageReqIdl(serializedBytes: newThreadProtobufPayload(request))
      return try newThreadProtobufResponse(
        newThreadFRSResponse(
          userID: resolvedUserID(message.data.common.bduss),
          forumID: forumID,
          forumName: message.data.kw
        )
      )
    case "/c/c/thread/add":
      writeCount += 1
      let fields = try newThreadFormFields(request)
      guard
        let rawForumID = fields["fid"],
        let requestedForumID = Int64(rawForumID),
        let title = fields["title"],
        let content = fields["content"],
        let bduss = fields["BDUSS"]
      else { throw TiebaClientError.transportFailure }
      let created = StoredThread(
        userID: resolvedUserID(bduss),
        forumID: requestedForumID,
        threadID: nextThreadID,
        firstPostID: nextPostID,
        title: title,
        content: content
      )
      nextThreadID += 1
      nextPostID += 1
      if blocksWrites, !writesReleased {
        await withCheckedContinuation { continuation in
          if writesReleased {
            continuation.resume()
          } else {
            writeWaiters.append(continuation)
          }
        }
      }
      switch behavior {
      case .success, .missingReadback, .mismatchedReadback:
        storedThreads[created.threadID] = created
        return try newThreadJSONResponse(
          errorCode: 0,
          threadID: created.threadID,
          firstPostID: created.firstPostID
        )
      case .networkAfterWrite:
        storedThreads[created.threadID] = created
        throw TiebaClientError.network(code: -1_005)
      case .timeoutAfterWrite:
        storedThreads[created.threadID] = created
        throw URLError(.timedOut)
      case .cancellationAfterWrite:
        storedThreads[created.threadID] = created
        throw CancellationError()
      case .malformedAfterWrite:
        storedThreads[created.threadID] = created
        return TiebaHTTPResponse(body: Data("not-json".utf8), statusCode: 200)
      case .oversizedAfterWrite:
        storedThreads[created.threadID] = created
        return TiebaHTTPResponse(
          body: Data(repeating: 0, count: (maximumBodyBytes ?? 131_072) + 1),
          statusCode: 200
        )
      case .challenge:
        return try newThreadJSONResponse(
          errorCode: 340_006,
          threadID: created.threadID,
          firstPostID: created.firstPostID,
          message: "需要安全验证",
          challenge: true
        )
      case .server:
        return try newThreadJSONResponse(
          errorCode: 340_006,
          threadID: created.threadID,
          firstPostID: created.firstPostID,
          message: "操作被拒绝"
        )
      }
    case "/c/f/pb/page":
      readbackCount += 1
      let message = try PbPageReqIdl(serializedBytes: newThreadProtobufPayload(request))
      guard let stored = storedThreads[message.data.kz] else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return try newThreadProtobufResponse(
        newThreadPageResponse(
          stored: stored,
          includesFirstPost: behavior != .missingReadback,
          content: behavior == .mismatchedReadback ? "different" : stored.content
        )
      )
    default:
      throw TiebaClientError.invalidEndpoint
    }
  }

  func waitUntilWriteCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if writeCount >= expected { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func waitUntilPreflightCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if preflightCount >= expected { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func releaseWrites() {
    writesReleased = true
    let waiters = writeWaiters
    writeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      preflightCount: preflightCount,
      writeCount: writeCount,
      readbackCount: readbackCount,
      maximumBodyBytes: maximumBodyBytes
    )
  }

  func seedThread(
    userID: Int64,
    receipt: TiebaNewThreadReceipt,
    title: String,
    content: String
  ) {
    storedThreads[receipt.threadID] = StoredThread(
      userID: userID,
      forumID: forumID,
      threadID: receipt.threadID,
      firstPostID: receipt.firstPostID,
      title: title,
      content: content
    )
  }

  private func resolvedUserID(_ bduss: String) -> Int64 {
    bduss.first == "c" ? 1_002 : 1_001
  }
}

private func waitUntilNewThreadWaiter(
  client: TiebaAuthenticatedClient,
  minimum: Int,
  timeout: Duration = .seconds(2)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await client.newThreadWaiterCountForTests() >= minimum { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

private func newThreadProtobufPayload(_ request: URLRequest) throws -> Data {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  let boundary = TiebaRequestFactory.multipartBoundary
  let marker = Data(
    ("--\(boundary)\r\n"
      + "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n").utf8
  )
  guard let range = body.range(of: marker) else { throw TiebaClientError.transportFailure }
  let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
  guard body.suffix(suffix.count) == suffix else { throw TiebaClientError.transportFailure }
  return body.subdata(in: range.upperBound..<(body.count - suffix.count))
}

private func newThreadFormFields(_ request: URLRequest) throws -> [String: String] {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    .replacingOccurrences(of: "+", with: "%20")
  guard let items = components.queryItems else { throw TiebaClientError.transportFailure }
  return Dictionary(
    uniqueKeysWithValues: items.compactMap { item in
      item.value.map { (item.name, $0) }
    })
}

private func newThreadFRSResponse(
  userID: Int64,
  forumID: Int64,
  forumName: String
) -> FrsPageResIdl {
  var user = User()
  user.isLogin = 1
  user.id = userID
  user.name = "current"
  user.nameShow = "Current User"
  var forum = FrsPageResIdl.DataRes.ForumInfo()
  forum.id = forumID
  forum.name = forumName
  forum.isLike = 0
  var anti = FrsPageResIdl.DataRes.Anti()
  anti.tbs = "0123456789abcdef0123456789"
  var data = FrsPageResIdl.DataRes()
  data.user = user
  data.forum = forum
  data.anti = anti
  var response = FrsPageResIdl()
  response.data = data
  return response
}

private func newThreadPageResponse(
  stored: NewThreadStateTransport.StoredThread,
  includesFirstPost: Bool,
  content: String
) -> PbPageResIdl {
  var account = User()
  account.isLogin = 1
  account.id = stored.userID
  var forum = SimpleForum()
  forum.id = stored.forumID
  forum.name = "swift"
  var author = User()
  author.id = stored.userID
  var thread = ThreadInfo()
  thread.id = stored.threadID
  thread.fid = stored.forumID
  thread.firstPostID = stored.firstPostID
  thread.title = stored.title
  thread.authorID = stored.userID
  thread.author = author
  var fragment = PbContent()
  fragment.type = 0
  fragment.text = content
  var post = Post()
  post.id = stored.firstPostID
  post.floor = 1
  post.tid = stored.threadID
  post.authorID = stored.userID
  post.author = author
  post.content = [fragment]
  var page = Page()
  page.currentPage = 1
  page.totalPage = 1
  page.pageSize = 2
  var data = PbPageResIdl.DataRes()
  data.user = account
  data.forum = forum
  data.thread = thread
  data.page = page
  if includesFirstPost { data.firstFloorPost = post }
  var response = PbPageResIdl()
  response.data = data
  return response
}

private func newThreadJSONResponse(
  errorCode: Int,
  threadID: Int64,
  firstPostID: Int64,
  message: String = "",
  challenge: Bool = false
) throws -> TiebaHTTPResponse {
  var object: [String: Any] = [
    "error_code": String(errorCode),
    "tid": String(threadID),
    "pid": String(firstPostID),
  ]
  if !message.isEmpty { object["msg"] = message }
  if challenge { object["info"] = ["need_vcode": "1"] }
  return TiebaHTTPResponse(
    body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
    statusCode: 200
  )
}

private func newThreadProtobufResponse<Message: SwiftProtobuf.Message>(
  _ message: Message
) throws -> TiebaHTTPResponse {
  TiebaHTTPResponse(body: try message.serializedData(), statusCode: 200)
}
