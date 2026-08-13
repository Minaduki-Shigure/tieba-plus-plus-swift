import Foundation
import SwiftProtobuf
import XCTest

@testable import TiebaCore
@testable import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaTextReplyClientTests: XCTestCase, @unchecked Sendable {
  private let firstUserID: Int64 = 1_001
  private let secondUserID: Int64 = 1_002
  private let forumID: Int64 = 2_002
  private let threadID: Int64 = 3_003
  private let firstPostID: Int64 = 4_004
  private let parentPostID: Int64 = 5_005
  private let targetSubpostID: Int64 = 6_006

  func testClientConfirmsAllTextReplyTargetShapes() async throws {
    let targets: [TiebaTextReplyTarget] = [
      .thread(firstPostID: firstPostID),
      .post(postID: parentPostID),
      .subpost(parentPostID: parentPostID, subpostID: targetSubpostID),
      .subpost(parentPostID: firstPostID, subpostID: targetSubpostID),
    ]
    for target in targets {
      let transport = TextReplyStateTransport(target: target)
      let client = TiebaAuthenticatedClient(transport: transport)
      let submission = makeSubmission(target: target)
      let result = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )

      XCTAssertEqual(result.submissionID, submission.submissionID)
      XCTAssertEqual(result.userID, firstUserID)
      XCTAssertEqual(result.forumID, forumID)
      XCTAssertEqual(result.threadID, threadID)
      XCTAssertEqual(result.target, target)
      switch (target, result.outcome) {
      case (.thread, .confirmed(.post(let postID, let floor))):
        XCTAssertGreaterThan(postID, 0)
        XCTAssertEqual(floor, 3)
      case (.post(let parent), .confirmed(.subpost(let returnedParent, let subpostID))):
        XCTAssertEqual(returnedParent, parent)
        XCTAssertGreaterThan(subpostID, 0)
      case (
        .subpost(let parent, _),
        .confirmed(.subpost(let returnedParent, let subpostID))
      ):
        XCTAssertEqual(returnedParent, parent)
        XCTAssertGreaterThan(subpostID, 0)
      default:
        XCTFail("Unexpected outcome \(result.outcome) for \(target)")
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writeCount, 1)
      XCTAssertEqual(
        snapshot.maximumBodyBytes.filter { $0 == TiebaAuthenticatedClient.textReplyWriteResponseMaximumBytes }.count,
        1
      )
    }
  }

  func testValidReceiptWithMissingExactIDReturnsAcceptedAwaitingVisibility() async throws {
    for target in [
      TiebaTextReplyTarget.thread(firstPostID: firstPostID),
      .post(postID: parentPostID),
      .subpost(parentPostID: parentPostID, subpostID: targetSubpostID),
    ] {
      let transport = TextReplyStateTransport(target: target, behavior: .missingReadback)
      let client = TiebaAuthenticatedClient(transport: transport)
      let result = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target)
      )
      switch result.outcome {
      case .acceptedAwaitingVisibility(.post(let postID)):
        guard case .thread = target else { return XCTFail("Wrong receipt kind") }
        XCTAssertGreaterThan(postID, 0)
      case .acceptedAwaitingVisibility(.subpost(let parentPostID, let subpostID)):
        XCTAssertEqual(parentPostID, self.parentPostID)
        XCTAssertGreaterThan(subpostID, 0)
      default:
        XCTFail("Expected an accepted receipt")
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writeCount, 1)
    }
  }

  func testExactPIDWithMismatchedContentBecomesRetainedUnknown() async {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let submission = makeSubmission(target: target)
    let transport = TextReplyStateTransport(target: target, behavior: .mismatchedReadback)
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertClientError(.replyOutcomeUnknown) {
      _ = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    await assertClientError(.replyOutcomeUnknown) {
      _ = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testPostDispatchFailuresAreUnknownAndNeverRetried() async {
    for behavior in [
      TextReplyStateTransport.Behavior.networkAfterWrite,
      .timeoutAfterWrite,
      .cancellationAfterWrite,
      .malformedAfterWrite,
      .oversizedAfterWrite,
    ] {
      let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
      let submission = makeSubmission(target: target)
      let transport = TextReplyStateTransport(target: target, behavior: behavior)
      let client = TiebaAuthenticatedClient(transport: transport)

      await assertClientError(.replyOutcomeUnknown) {
        _ = try await client.submitTextReply(
          credential: credential(),
          expectedUserID: firstUserID,
          submission: submission
        )
      }
      await assertClientError(.replyOutcomeUnknown) {
        _ = try await client.submitTextReply(
          credential: credential(),
          expectedUserID: firstUserID,
          submission: submission
        )
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writeCount, 1)
    }
  }

  func testChallengeAndServerRejectionRemainDefinitive() async {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let challengeTransport = TextReplyStateTransport(target: target, behavior: .challenge)
    let challengeClient = TiebaAuthenticatedClient(transport: challengeTransport)
    await assertClientError(.replyChallengeRequired(message: "需要安全验证")) {
      _ = try await challengeClient.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target)
      )
    }
    let challengeSnapshot = await challengeTransport.snapshot()
    XCTAssertEqual(challengeSnapshot.writeCount, 1)

    let serverTransport = TextReplyStateTransport(target: target, behavior: .server)
    let serverClient = TiebaAuthenticatedClient(transport: serverTransport)
    await assertClientError(.server(code: 340006, message: "操作被拒绝")) {
      _ = try await serverClient.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target)
      )
    }
    let serverSnapshot = await serverTransport.snapshot()
    XCTAssertEqual(serverSnapshot.writeCount, 1)
  }

  func testSameSubmissionSharesOneFlightAndConflictingIdentityIsRejected() async throws {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let submission = makeSubmission(target: target, content: "e\u{301}")
    let transport = TextReplyStateTransport(target: target, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for the first write")
    }
    let shared = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: submission
      )
    }
    let conflict = TiebaTextReplySubmission(
      submissionID: submission.submissionID,
      forumID: forumID,
      forumName: "different",
      threadID: threadID,
      target: target,
      content: submission.content
    )
    await assertClientError(.replySubmissionIDConflict) {
      _ = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: conflict
      )
    }
    let canonicallyEquivalentConflict = TiebaTextReplySubmission(
      submissionID: submission.submissionID,
      forumID: submission.forumID,
      forumName: submission.forumName,
      threadID: submission.threadID,
      target: submission.target,
      content: "\u{E9}"
    )
    XCTAssertEqual(submission.content, canonicallyEquivalentConflict.content)
    XCTAssertNotEqual(submission, canonicallyEquivalentConflict)
    await assertClientError(.replySubmissionIDConflict) {
      _ = try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: canonicallyEquivalentConflict
      )
    }
    await transport.releaseWrites()
    let firstResult = try await first.value
    let sharedResult = try await shared.value
    XCTAssertEqual(firstResult, sharedResult)
    let retainedResult = try await client.submitTextReply(
      credential: credential(),
      expectedUserID: firstUserID,
      submission: submission
    )
    XCTAssertEqual(retainedResult, firstResult)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testSameAccountSerializesDifferentSubmissions() async throws {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let transport = TextReplyStateTransport(target: target, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target, content: "first")
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for the first write")
    }
    let second = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target, content: "second")
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
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let transport = TextReplyStateTransport(target: target, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitTextReply(
        credential: credential(marker: "b"),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target, content: "first")
      )
    }
    let second = Task {
      try await client.submitTextReply(
        credential: credential(marker: "c"),
        expectedUserID: secondUserID,
        submission: makeSubmission(target: target, content: "second")
      )
    }
    guard await transport.waitUntilWriteCount(2) else {
      first.cancel()
      second.cancel()
      return XCTFail("Different accounts did not reach the write concurrently")
    }
    await transport.releaseWrites()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult.userID, firstUserID)
    XCTAssertEqual(secondResult.userID, secondUserID)
  }

  func testQueuedCancellationPerformsNoSecondWrite() async throws {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let transport = TextReplyStateTransport(target: target, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target, content: "first")
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      return XCTFail("Timed out waiting for the first write")
    }
    let queued = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target, content: "queued")
      )
    }
    guard await waitUntilTextReplyWaiter(client: client, minimum: 2) else {
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
    XCTAssertEqual(snapshot.writeCount, 1)
  }

  func testPreflightCancellationPerformsNoWrite() async throws {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let transport = TextReplyStateTransport(target: target, blocksPreflight: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let task = Task {
      try await client.submitTextReply(
        credential: credential(),
        expectedUserID: firstUserID,
        submission: makeSubmission(target: target)
      )
    }
    guard await transport.waitUntilPageReadCount(1) else {
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

  func testPostDispatchCallerCancellationDoesNotCancelOwner() async throws {
    let target = TiebaTextReplyTarget.thread(firstPostID: firstPostID)
    let submission = makeSubmission(target: target)
    let transport = TextReplyStateTransport(target: target, blocksWrites: true)
    let client = TiebaAuthenticatedClient(transport: transport)
    let caller = Task {
      try await client.submitTextReply(
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
      // The owner flight continues because the write is already dispatched.
    }
    await transport.releaseWrites()
    let recovered = try await client.submitTextReply(
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

  func testReplyContextRedactsTBSAndCredentials() throws {
    let response = clientPageResponse(
      userID: firstUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      locatedPostID: parentPostID,
      locatedFloor: 2,
      authorID: 8_008,
      content: "parent"
    )
    let context = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: response,
      expectedUserID: firstUserID,
      forumID: forumID,
      forumName: "swift",
      threadID: threadID,
      target: .post(postID: parentPostID)
    )
    XCTAssertEqual(String(describing: context), "TiebaTextReplyContext(redacted)")
    XCTAssertFalse(String(reflecting: context).contains("0123456789abcdef0123456789"))
    XCTAssertFalse(String(reflecting: credential()).contains(credential().bduss))
  }

  private func credential(marker: Character = "b") -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: marker, count: 192),
      stoken: String(repeating: marker == "b" ? "s" : "t", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func makeSubmission(
    target: TiebaTextReplyTarget,
    content: String = "body"
  ) -> TiebaTextReplySubmission {
    TiebaTextReplySubmission(
      submissionID: UUID(),
      forumID: forumID,
      forumName: "swift",
      threadID: threadID,
      target: target,
      content: content
    )
  }

  private func assertClientError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func waitUntilTextReplyWaiter(
    client: TiebaAuthenticatedClient,
    minimum: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      // The queued submission has a distinct UUID, so count all active waiter buckets indirectly.
      let snapshot = await client.textReplyWaiterCountForTests()
      if snapshot >= minimum { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }
}

private actor TextReplyStateTransport: TiebaTransport {
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
    let writeCount: Int
    let pageReadCount: Int
    let floorReadCount: Int
    let maximumBodyBytes: [Int?]
  }

  private struct StoredReply: Sendable {
    let userID: Int64
    let content: String
  }

  private let target: TiebaTextReplyTarget
  private let behavior: Behavior
  private let blocksWrites: Bool
  private let blocksPreflight: Bool
  private let firstPostID: Int64
  private var writeCount = 0
  private var pageReadCount = 0
  private var floorReadCount = 0
  private var nextCreatedID: Int64 = 70_070
  private var storedReplies = [Int64: StoredReply]()
  private var maximumBodyBytes = [Int?]()
  private var writesReleased = false
  private var writeWaiters = [CheckedContinuation<Void, Never>]()

  init(
    target: TiebaTextReplyTarget,
    behavior: Behavior = .success,
    blocksWrites: Bool = false,
    blocksPreflight: Bool = false,
    firstPostID: Int64 = 4_004
  ) {
    self.target = target
    self.behavior = behavior
    self.blocksWrites = blocksWrites
    self.blocksPreflight = blocksPreflight
    self.firstPostID = firstPostID
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
    case "/c/f/pb/page":
      pageReadCount += 1
      if blocksPreflight, pageReadCount == 1 {
        try await Task.sleep(for: .seconds(60))
      }
      let message = try PbPageReqIdl(serializedBytes: clientProtobufPayload(request))
      let accountID = resolvedUserID(message.data.common.bduss)
      let requestedPostID = message.data.pid
      if let stored = storedReplies[requestedPostID] {
        return try protobufResponse(
          clientPageResponse(
            userID: accountID,
            forumID: message.data.forumID,
            threadID: message.data.kz,
            firstPostID: firstPostID,
            locatedPostID: requestedPostID,
            locatedFloor: 3,
            authorID: stored.userID,
            content: behavior == .mismatchedReadback ? "different" : stored.content
          )
        )
      }
      let preflightPostID: Int64
      let floor: UInt32
      switch target {
      case .thread(let postID):
        preflightPostID = postID
        floor = 1
      case .post(let postID):
        preflightPostID = postID
        floor = 2
      case .subpost(let postID, _):
        preflightPostID = postID
        floor = postID == firstPostID ? 1 : 2
      }
      let locatedID = requestedPostID == preflightPostID ? preflightPostID : preflightPostID
      return try protobufResponse(
        clientPageResponse(
          userID: accountID,
          forumID: message.data.forumID,
          threadID: message.data.kz,
          firstPostID: firstPostID,
          locatedPostID: locatedID,
          locatedFloor: floor,
          authorID: 8_008,
          content: floor == 1 ? "topic" : "parent"
        )
      )
    case "/c/f/pb/floor":
      floorReadCount += 1
      let message = try PbFloorReqIdl(serializedBytes: clientProtobufPayload(request))
      if let stored = storedReplies[message.data.spid] {
        return try protobufResponse(
          clientFloorResponse(
            forumID: message.data.forumID,
            threadID: message.data.kz,
            firstPostID: firstPostID,
            parentPostID: message.data.pid,
            subpostID: message.data.spid,
            authorID: stored.userID,
            authorName: "Current User",
            authorPortrait: "current-portrait",
            content: behavior == .mismatchedReadback ? "different" : stored.content,
            replyMentionUserID: targetReplyMentionUserID
          )
        )
      }
      let requestedTargetID: Int64
      if case .subpost(_, let subpostID) = target {
        requestedTargetID = subpostID
      } else {
        requestedTargetID = 6_006
      }
      return try protobufResponse(
        clientFloorResponse(
          forumID: message.data.forumID,
          threadID: message.data.kz,
          firstPostID: firstPostID,
          parentPostID: message.data.pid,
          subpostID: requestedTargetID,
          authorID: 9_009,
          authorName: "Target User",
          authorPortrait: "target-portrait",
          content: "target"
        )
      )
    case "/c/c/post/add":
      writeCount += 1
      let message = try AddPostReqIdl(serializedBytes: clientProtobufPayload(request))
      let createdID = nextCreatedID
      nextCreatedID += 1
      let accountID = resolvedUserID(message.data.common.bduss)
      let userContent = decodedUserContent(message.data.content)
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
      case .success, .mismatchedReadback:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        return try protobufResponse(addPostResponse(threadID: message.data.tid, postID: createdID))
      case .missingReadback:
        return try protobufResponse(addPostResponse(threadID: message.data.tid, postID: createdID))
      case .networkAfterWrite:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        throw TiebaClientError.network(code: -1_005)
      case .timeoutAfterWrite:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        throw URLError(.timedOut)
      case .cancellationAfterWrite:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        throw CancellationError()
      case .malformedAfterWrite:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        return TiebaHTTPResponse(body: Data("not-protobuf".utf8), statusCode: 200)
      case .oversizedAfterWrite:
        storedReplies[createdID] = StoredReply(userID: accountID, content: userContent)
        return TiebaHTTPResponse(
          body: Data(repeating: 0, count: (maximumBodyBytes ?? 131_072) + 1),
          statusCode: 200
        )
      case .challenge:
        return try protobufResponse(
          addPostResponse(
            threadID: message.data.tid,
            postID: createdID,
            challengeMessage: "需要安全验证"
          )
        )
      case .server:
        return try protobufResponse(
          addPostResponse(
            threadID: message.data.tid,
            postID: createdID,
            errorCode: 340_006,
            errorMessage: "操作被拒绝"
          )
        )
      }
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

  func waitUntilPageReadCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if pageReadCount >= expected { return true }
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
      writeCount: writeCount,
      pageReadCount: pageReadCount,
      floorReadCount: floorReadCount,
      maximumBodyBytes: maximumBodyBytes
    )
  }

  private var targetReplyMentionUserID: Int64? {
    if case .subpost = target { 9_009 } else { nil }
  }

  private func resolvedUserID(_ bduss: String) -> Int64 {
    bduss.first == "c" ? 1_002 : 1_001
  }

  private func decodedUserContent(_ wireContent: String) -> String {
    guard case .subpost = target,
      let markerRange = wireContent.range(of: ") :")
    else { return wireContent }
    return String(wireContent[markerRange.upperBound...])
  }
}

private func clientProtobufPayload(_ request: URLRequest) throws -> Data {
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

private func clientPageResponse(
  userID: Int64,
  forumID: Int64,
  threadID: Int64,
  firstPostID: Int64,
  locatedPostID: Int64,
  locatedFloor: UInt32,
  authorID: Int64,
  content: String
) -> PbPageResIdl {
  var account = User()
  account.isLogin = 1
  account.id = userID
  account.name = "current"
  account.nameShow = "Current User"
  account.portrait = "current-portrait"
  var forum = SimpleForum()
  forum.id = forumID
  forum.name = "swift"
  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.firstPostID = firstPostID
  var author = User()
  author.id = authorID
  author.name = authorID == userID ? "current" : "target"
  author.nameShow = authorID == userID ? "Current User" : "Target User"
  author.portrait = authorID == userID ? "current-portrait" : "target-portrait"
  var fragment = PbContent()
  fragment.type = 0
  fragment.text = content
  var post = Post()
  post.id = locatedPostID
  post.floor = locatedFloor
  post.tid = threadID
  post.authorID = authorID
  post.author = author
  post.content = [fragment]
  var anti = Anti()
  anti.tbs = "0123456789abcdef0123456789"
  var page = Page()
  page.currentPage = 1
  page.totalPage = 1
  page.pageSize = 2
  var data = PbPageResIdl.DataRes()
  data.user = account
  data.forum = forum
  data.thread = thread
  data.anti = anti
  data.page = page
  if locatedFloor == 1 {
    data.firstFloorPost = post
  } else {
    data.postList = [post]
  }
  var response = PbPageResIdl()
  response.data = data
  return response
}

private func clientFloorResponse(
  forumID: Int64,
  threadID: Int64,
  firstPostID: Int64,
  parentPostID: Int64,
  subpostID: Int64,
  authorID: Int64,
  authorName: String,
  authorPortrait: String,
  content: String,
  replyMentionUserID: Int64? = nil
) -> PbFloorResIdl {
  var forum = SimpleForum()
  forum.id = forumID
  forum.name = "swift"
  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.firstPostID = firstPostID
  var parent = Post()
  parent.id = parentPostID
  parent.floor = parentPostID == firstPostID ? 1 : 2
  parent.tid = threadID
  var author = User()
  author.id = authorID
  author.name = authorName
  author.nameShow = authorName
  author.portrait = authorPortrait
  var subpost = SubPostList()
  subpost.id = subpostID
  subpost.authorID = authorID
  subpost.author = author
  if let replyMentionUserID {
    var prefix = PbContent()
    prefix.type = 0
    prefix.text = "回复"
    var mention = PbContent()
    mention.type = 4
    mention.uid = replyMentionUserID
    mention.text = "Target User"
    var suffix = PbContent()
    suffix.type = 0
    suffix.text = ":\(content)"
    subpost.content = [prefix, mention, suffix]
  } else {
    var fragment = PbContent()
    fragment.type = 0
    fragment.text = content
    subpost.content = [fragment]
  }
  var anti = Anti()
  anti.tbs = "0123456789abcdef0123456789"
  var page = Page()
  page.currentPage = 1
  page.totalPage = 1
  page.pageSize = 20
  var data = PbFloorResIdl.DataRes()
  data.forum = forum
  data.thread = thread
  data.post = parent
  data.subpostList = [subpost]
  data.anti = anti
  data.page = page
  var response = PbFloorResIdl()
  response.data = data
  return response
}

private func addPostResponse(
  threadID: String,
  postID: Int64,
  errorCode: Int32 = 0,
  errorMessage: String = "",
  challengeMessage: String? = nil
) -> AddPostResIdl {
  var error = TiebaProto.Error()
  error.errorno = errorCode
  error.userMsg = errorMessage
  var data = AddPostResIdl.DataRes()
  data.tid = threadID
  data.pid = String(postID)
  if let challengeMessage {
    var info = PostAntiInfo()
    info.needVcode = "1"
    info.blockContent = challengeMessage
    data.info = info
  }
  var response = AddPostResIdl()
  response.error = error
  response.data = data
  return response
}

private func protobufResponse<Message: SwiftProtobuf.Message>(
  _ message: Message
) throws -> TiebaHTTPResponse {
  TiebaHTTPResponse(body: try message.serializedData(), statusCode: 200)
}
