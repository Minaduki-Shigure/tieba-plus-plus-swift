import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaPersonalizedFeedbackTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let threadID: Int64 = 8_675_309
  private let cuid = "00000000-0000-0000-0000-000000000111"

  func testRequestUsesExactBoundHTTPSContractAndRecommendationIdentity() throws {
    let credential = sessionCredential()
    let submission = feedbackSubmission()
    let request = try factory().personalizedFeedback(
      credential: credential,
      expectedUserID: userID,
      submission: submission
    )
    let fields = try formFields(request)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/c/excellent/submitDislike"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_type", "_client_version", "cuid", "dislike",
        "dislike_from", "sign", "stoken",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential.bduss)
    XCTAssertEqual(fields["stoken"], credential.stoken)
    XCTAssertEqual(fields["_client_type"], "2")
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["cuid"], cuid)
    XCTAssertEqual(fields["dislike_from"], "homepage")

    let dislikeData = try XCTUnwrap(fields["dislike"]?.data(using: .utf8))
    let rows = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: dislikeData) as? [[String: Any]]
    )
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(Set(row.keys), ["click_time", "dislike_ids", "extra", "fid", "tid"])
    XCTAssertEqual(row["tid"] as? String, String(threadID))
    XCTAssertEqual(row["fid"] as? String, String(forumID))
    XCTAssertEqual(row["dislike_ids"] as? String, "2,7")
    XCTAssertEqual(row["extra"] as? String, "opaque-a,opaque-b")
    XCTAssertEqual((row["click_time"] as? NSNumber)?.int64Value, 1_723_456_789_012)
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential.bduss),
          ("_client_type", "2"),
          ("_client_version", "12.41.7.1"),
          ("cuid", cuid),
          ("dislike", try XCTUnwrap(fields["dislike"])),
          ("dislike_from", "homepage"),
          ("stoken", credential.stoken),
        ]
      )
    )
    for forbidden in [
      "user_id", "imei", "_phone_imei", "oaid", "android_id", "model", "brand",
      "latitude", "longitude", "timestamp", "client_id",
    ] {
      XCTAssertNil(fields[forbidden])
    }
  }

  func testRequestCanonicalizesPersonalizedIdentityAndRejectsInvalidIdentity() throws {
    let canonicalCUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let canonicalFactory = TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(
        personalizedCUID: "  AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\n"
      )
    )
    let request = try canonicalFactory.personalizedFeedback(
      credential: sessionCredential(),
      expectedUserID: userID,
      submission: feedbackSubmission()
    )
    XCTAssertEqual(try formFields(request)["cuid"], canonicalCUID)

    let invalidFactory = TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(personalizedCUID: "not-a-uuid")
    )
    XCTAssertThrowsError(
      try invalidFactory.personalizedFeedback(
        credential: sessionCredential(),
        expectedUserID: userID,
        submission: feedbackSubmission()
      )
    )
  }

  func testRequestRejectsUnboundOrOversizedFeedbackBeforeTransport() throws {
    let invalidSubmissions = [
      TiebaPersonalizedFeedbackSubmission(
        threadID: 0,
        forumID: forumID,
        reasonIDs: [2],
        reasonExtras: ["opaque"],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: 0,
        reasonIDs: [2],
        reasonExtras: ["opaque"],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: forumID,
        reasonIDs: [],
        reasonExtras: [],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: forumID,
        reasonIDs: [2, 2],
        reasonExtras: ["a", "b"],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: forumID,
        reasonIDs: [2],
        reasonExtras: [],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: forumID,
        reasonIDs: [2],
        reasonExtras: [String(repeating: "x", count: 4_097)],
        clickTimeMilliseconds: 1
      ),
      TiebaPersonalizedFeedbackSubmission(
        threadID: threadID,
        forumID: forumID,
        reasonIDs: [2],
        reasonExtras: ["opaque"],
        clickTimeMilliseconds: 0
      ),
    ]

    for submission in invalidSubmissions {
      XCTAssertThrowsError(
        try factory().personalizedFeedback(
          credential: sessionCredential(),
          expectedUserID: userID,
          submission: submission
        )
      )
    }
    XCTAssertThrowsError(
      try factory().personalizedFeedback(
        credential: sessionCredential(),
        expectedUserID: 0,
        submission: feedbackSubmission()
      )
    )
  }

  func testDecoderAcceptsOnlyExplicitSuccessAndPreservesServerRejection() throws {
    XCTAssertNoThrow(
      try TiebaAuthenticatedDecoder.checkPersonalizedFeedbackResponse(
        Data(#"{"error_code":0}"#.utf8)
      )
    )
    XCTAssertNoThrow(
      try TiebaAuthenticatedDecoder.checkPersonalizedFeedbackResponse(
        Data(#"{"errno":"0"}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkPersonalizedFeedbackResponse(Data(#"{}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkPersonalizedFeedbackResponse(
        Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 340_006, message: "denied"))
    }
  }

  func testClientSendsOnceAndDistinguishesSuccessRejectionAndUnknownOutcome() async throws {
    let successTransport = PersonalizedFeedbackTransport(
      outcomes: [.response(Data(#"{"error_code":0}"#.utf8))]
    )
    try await client(transport: successTransport).submitPersonalizedFeedback(
      credential: sessionCredential(),
      expectedUserID: userID,
      submission: feedbackSubmission()
    )
    var snapshot = await successTransport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/c/excellent/submitDislike"])
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [TiebaAuthenticatedClient.personalizedFeedbackResponseMaximumBytes]
    )

    let rejectionTransport = PersonalizedFeedbackTransport(
      outcomes: [.response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8))]
    )
    await assertError(.server(code: 340_006, message: "denied")) {
      try await self.client(transport: rejectionTransport).submitPersonalizedFeedback(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        submission: self.feedbackSubmission()
      )
    }
    snapshot = await rejectionTransport.snapshot()
    XCTAssertEqual(snapshot.paths.count, 1)

    for outcome in [
      PersonalizedFeedbackTransport.Outcome.response(Data(#"{}"#.utf8)),
      .failure(.transportFailure),
    ] {
      let transport = PersonalizedFeedbackTransport(outcomes: [outcome])
      await assertError(.personalizedFeedbackOutcomeUnknown) {
        try await self.client(transport: transport).submitPersonalizedFeedback(
          credential: self.sessionCredential(),
          expectedUserID: self.userID,
          submission: self.feedbackSubmission()
        )
      }
      snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths.count, 1)
    }
  }

  func testEquivalentConcurrentFeedbackSharesOneFlightAndConflictDoesNotQueue() async throws {
    let transport = PersonalizedFeedbackTransport(
      outcomes: [.response(Data(#"{"error_code":0}"#.utf8))],
      blocksFirstRequest: true
    )
    let client = client(transport: transport)
    let credential = sessionCredential()
    let submission = feedbackSubmission()
    let expectedUserID = userID
    let first = Task {
      try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    XCTAssertTrue(firstRequestStarted)

    let equivalent = Task {
      try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }
    guard await waitUntilFeedbackWaiterCount(client: client, count: 2) else {
      equivalent.cancel()
      await transport.releaseFirstRequest()
      _ = try? await first.value
      XCTFail("Equivalent feedback did not join the active flight")
      return
    }
    let conflicting = TiebaPersonalizedFeedbackSubmission(
      threadID: threadID,
      forumID: forumID,
      reasonIDs: [9],
      reasonExtras: ["other"],
      clickTimeMilliseconds: submission.clickTimeMilliseconds
    )
    let conflictProbe = PersonalizedFeedbackOutcomeProbe()
    let conflictTask = Task {
      do {
        try await client.submitPersonalizedFeedback(
          credential: credential,
          expectedUserID: expectedUserID,
          submission: conflicting
        )
        await conflictProbe.record(.success)
      } catch let error as TiebaClientError {
        await conflictProbe.record(.tiebaFailure(error))
      } catch {
        await conflictProbe.record(.unexpectedFailure)
      }
    }
    let conflictFinishedBeforeRelease = await waitUntilFeedbackOutcome(conflictProbe)
    guard conflictFinishedBeforeRelease else {
      conflictTask.cancel()
      equivalent.cancel()
      await transport.releaseFirstRequest()
      _ = await conflictTask.result
      _ = try? await first.value
      _ = try? await equivalent.value
      XCTFail("Conflicting feedback queued behind the active write")
      return
    }
    let conflictOutcome = await conflictProbe.snapshot()
    XCTAssertEqual(
      conflictOutcome,
      .tiebaFailure(.personalizedFeedbackWriteConflict)
    )

    await transport.releaseFirstRequest()
    await conflictTask.value
    try await first.value
    try await equivalent.value
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths.count, 1)
  }

  func testCancelledJoinedWaiterReturnsWhileDispatchedWriteRemainsSingleFlight() async throws {
    let transport = PersonalizedFeedbackTransport(
      outcomes: [.response(Data(#"{"error_code":0}"#.utf8))],
      blocksFirstRequest: true
    )
    let client = client(transport: transport)
    let credential = sessionCredential()
    let submission = feedbackSubmission()
    let expectedUserID = userID
    let first = Task {
      try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    XCTAssertTrue(firstRequestStarted)

    let cancelledWaiter = Task {
      try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }
    guard await waitUntilFeedbackWaiterCount(client: client, count: 2) else {
      cancelledWaiter.cancel()
      await transport.releaseFirstRequest()
      _ = try? await first.value
      XCTFail("Equivalent feedback did not join the active flight")
      return
    }
    cancelledWaiter.cancel()
    await assertCancellation(cancelledWaiter)
    let cancelledWaiterWasRemoved = await waitUntilFeedbackWaiterCount(
      client: client,
      count: 1
    )
    XCTAssertTrue(cancelledWaiterWasRemoved)

    let replacementWaiter = Task {
      try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }
    guard await waitUntilFeedbackWaiterCount(client: client, count: 2) else {
      replacementWaiter.cancel()
      await transport.releaseFirstRequest()
      _ = try? await first.value
      XCTFail("Replacement feedback did not join the active flight")
      return
    }
    var snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths.count, 1)

    await transport.releaseFirstRequest()
    try await first.value
    try await replacementWaiter.value
    snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths.count, 1)
  }

  func testPreCancelledCallerPerformsNoWrite() async {
    let transport = PersonalizedFeedbackTransport(
      outcomes: [.response(Data(#"{"error_code":0}"#.utf8))]
    )
    let client = client(transport: transport)
    let credential = sessionCredential()
    let expectedUserID = userID
    let submission = feedbackSubmission()
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.submitPersonalizedFeedback(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission
      )
    }.result

    switch result {
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    case .success:
      XCTFail("Expected pre-cancelled feedback to stop before transport")
    }
    let snapshot = await transport.snapshot()
    XCTAssertTrue(snapshot.paths.isEmpty)
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(personalizedCUID: cuid)
    )
  }

  private func client(
    transport: PersonalizedFeedbackTransport
  ) -> TiebaAuthenticatedClient {
    TiebaAuthenticatedClient(
      configuration: TiebaClientConfiguration(personalizedCUID: cuid),
      transport: transport
    )
  }

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func feedbackSubmission() -> TiebaPersonalizedFeedbackSubmission {
    TiebaPersonalizedFeedbackSubmission(
      threadID: threadID,
      forumID: forumID,
      reasonIDs: [2, 7],
      reasonExtras: ["opaque-a", "opaque-b"],
      clickTimeMilliseconds: 1_723_456_789_012
    )
  }

  private func waitUntilFeedbackWaiterCount(
    client: TiebaAuthenticatedClient,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await client.personalizedFeedbackWaiterCount(
        expectedUserID: userID,
        threadID: threadID
      ) == count {
        return true
      }
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return false
  }

  private func waitUntilFeedbackOutcome(
    _ probe: PersonalizedFeedbackOutcomeProbe,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await probe.snapshot() != nil { return true }
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return false
  }

  private func assertCancellation(_ task: Task<Void, Swift.Error>) async {
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    return Dictionary(
      uniqueKeysWithValues: components.queryItems?.compactMap { item in
        item.value.map { (item.name, $0) }
      } ?? []
    )
  }

  private func assertError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(type(of: error))")
    }
  }
}

private enum PersonalizedFeedbackTestOutcome: Equatable, Sendable {
  case success
  case tiebaFailure(TiebaClientError)
  case unexpectedFailure
}

private actor PersonalizedFeedbackOutcomeProbe {
  private var outcome: PersonalizedFeedbackTestOutcome?

  func record(_ outcome: PersonalizedFeedbackTestOutcome) {
    self.outcome = outcome
  }

  func snapshot() -> PersonalizedFeedbackTestOutcome? { outcome }
}

private actor PersonalizedFeedbackTransport: TiebaTransport {
  enum Outcome: Sendable {
    case response(Data)
    case failure(TiebaClientError)
  }

  struct Snapshot: Sendable {
    let paths: [String]
    let maximumBodyBytes: [Int]
  }

  private var outcomes: [Outcome]
  private let blocksFirstRequest: Bool
  private var requests: [URLRequest] = []
  private var limits: [Int] = []
  private var firstRequestReleased = false
  private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

  init(outcomes: [Outcome], blocksFirstRequest: Bool = false) {
    self.outcomes = outcomes
    self.blocksFirstRequest = blocksFirstRequest
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    requests.append(request)
    if let maximumBodyBytes { limits.append(maximumBodyBytes) }
    if blocksFirstRequest, requests.count == 1, !firstRequestReleased {
      await withCheckedContinuation { firstRequestWaiters.append($0) }
    }
    guard !outcomes.isEmpty else { throw TiebaClientError.transportFailure }
    switch outcomes.removeFirst() {
    case .response(let body):
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .failure(let error):
      throw error
    }
  }

  func waitUntilRequestCount(
    _ count: Int,
    timeoutNanoseconds: UInt64 = 2_000_000_000
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while requests.count < count, clock.now < deadline {
      await Task.yield()
    }
    return requests.count >= count
  }

  func releaseFirstRequest() {
    firstRequestReleased = true
    let waiters = firstRequestWaiters
    firstRequestWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      paths: requests.map { $0.url?.path ?? "" },
      maximumBodyBytes: limits
    )
  }
}
