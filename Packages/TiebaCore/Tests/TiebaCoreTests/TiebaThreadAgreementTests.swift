import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaThreadAgreementTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let forumName = "swift"
  private let threadID: Int64 = 900
  private let firstPostID: Int64 = 9_001
  private let tbs = "91be894d01799c4991be894d01"
  private let cuid = "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA"

  func testGalaxy2CUIDMatchesKnownHeliosVectorAndValidatesChecksum() {
    let prefix = "06C7F37D41256F25FABA97B885DB6EFB"

    XCTAssertEqual(TiebaGalaxy2CUID.make(prefix: prefix), cuid)
    XCTAssertTrue(TiebaGalaxy2CUID.isValid(cuid))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(prefix + "|VAPUDW7TB"))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(prefix.lowercased() + "|VAPUDW7TA"))
  }

  func testGeneratedGalaxy2CUIDIsValidAndStableForFactoryLifetime() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let first = try factory.setThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      threadID: threadID,
      firstPostID: firstPostID,
      tbs: tbs,
      isAgreed: true
    )
    let second = try factory.setThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      threadID: threadID,
      firstPostID: firstPostID,
      tbs: tbs,
      isAgreed: false
    )

    let firstCUID = try XCTUnwrap(formFields(first)["cuid"])
    XCTAssertTrue(TiebaGalaxy2CUID.isValid(firstCUID))
    XCTAssertEqual(try formFields(second)["cuid"], firstCUID)
  }

  func testStateProbeUsesCredentialIsolatedHTTPSProtobufRequest() throws {
    let factory = TiebaAuthenticatedRequestFactory(
      configuration: .init(),
      agreementCUID: cuid
    )
    let request = try factory.threadAgreement(
      credential: credential(),
      expectedUserID: userID,
      threadID: threadID,
      firstPostID: firstPostID
    )

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/pb/page?cmd=302001"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertFalse(request.httpShouldHandleCookies)

    let message = try PbPageReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(message.data.kz, threadID)
    XCTAssertEqual(message.data.pid, firstPostID)
    XCTAssertEqual(message.data.pn, 0)
    XCTAssertEqual(message.data.rn, 2)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(message.data.common.bduss, credential().bduss)
    XCTAssertTrue(message.data.common.stoken.isEmpty)
    XCTAssertTrue(message.data.common.tbs.isEmpty)
    XCTAssertTrue(message.data.common.cuid.isEmpty)
  }

  func testWriteUsesExactMinimalSignedFormWithoutSTOKENOrCredentialCookie() throws {
    let factory = TiebaAuthenticatedRequestFactory(
      configuration: .init(),
      agreementCUID: cuid
    )
    let request = try factory.setThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      threadID: threadID,
      firstPostID: firstPostID,
      tbs: tbs,
      isAgreed: true
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/agree/opAgree")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 22.6.5.1")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "agree_type", "cuid", "obj_type", "op_type",
        "post_id", "tbs", "thread_id", "sign",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "22.6.5.1")
    XCTAssertEqual(fields["agree_type"], "2")
    XCTAssertEqual(fields["cuid"], cuid)
    XCTAssertEqual(fields["obj_type"], "3")
    XCTAssertEqual(fields["op_type"], "0")
    XCTAssertEqual(fields["post_id"], String(firstPostID))
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["thread_id"], String(threadID))
    XCTAssertNil(fields["stoken"])
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential().bduss),
          ("_client_version", "22.6.5.1"),
          ("agree_type", "2"),
          ("cuid", cuid),
          ("obj_type", "3"),
          ("op_type", "0"),
          ("post_id", String(firstPostID)),
          ("tbs", tbs),
          ("thread_id", String(threadID)),
        ]
      )
    )

    let undo = try factory.setThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      threadID: threadID,
      firstPostID: firstPostID,
      tbs: tbs,
      isAgreed: false
    )
    XCTAssertEqual(try formFields(undo)["op_type"], "1")
  }

  func testRequestFactoryRejectsInvalidIdentityTBSAndEphemeralCUID() {
    let validFactory = TiebaAuthenticatedRequestFactory(
      configuration: .init(),
      agreementCUID: cuid
    )
    for values in [(Int64(0), threadID, firstPostID), (userID, 0, firstPostID), (userID, threadID, 0)] {
      XCTAssertThrowsError(
        try validFactory.threadAgreement(
          credential: credential(),
          expectedUserID: values.0,
          threadID: values.1,
          firstPostID: values.2
        )
      )
    }
    XCTAssertThrowsError(
      try validFactory.setThreadAgreement(
        credential: credential(),
        expectedUserID: userID,
        threadID: threadID,
        firstPostID: firstPostID,
        tbs: String(repeating: "a", count: 25),
        isAgreed: true
      )
    )
    for invalidCUID in [
      "",
      "06c7f37d41256f25faba97b885db6efb|VAPUDW7TA",
      "06C7F37D41256F25FABA97B885DB6EFB|0",
      "06C7F37D41256F25FABA97B885DB6EFG|VAPUDW7TA",
      "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TB",
      "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7T1",
    ] {
      let factory = TiebaAuthenticatedRequestFactory(
        configuration: .init(),
        agreementCUID: invalidCUID
      )
      XCTAssertThrowsError(
        try factory.setThreadAgreement(
          credential: credential(),
          expectedUserID: userID,
          threadID: threadID,
          firstPostID: firstPostID,
          tbs: tbs,
          isAgreed: true
        )
      )
    }
  }

  func testDecoderMapsBoundAccountStateAndDeclaredNetScore() throws {
    let response = agreementResponse(isAgreed: true, agreeCount: 15, disagreeCount: 4, score: 8)
    let state = try TiebaAuthenticatedDecoder.threadAgreement(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID
    )

    XCTAssertEqual(
      state,
      TiebaThreadAgreement(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: true,
        agreeScore: 8
      )
    )

    let inferred = try TiebaAuthenticatedDecoder.threadAgreement(
      from: agreementResponse(isAgreed: false, agreeCount: 15, disagreeCount: 4),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    XCTAssertEqual(inferred.agreeScore, 11)
  }

  func testDecoderRejectsResourceMismatchInvalidFlagAndMissingAgreement() {
    let mismatches = [
      agreementResponse(isAgreed: false, responseForumID: forumID + 1),
      agreementResponse(isAgreed: false, responseThreadID: threadID + 1),
      agreementResponse(isAgreed: false, responseFirstPostID: firstPostID + 1),
      agreementResponse(isAgreed: false, rawHasAgree: 2),
      agreementResponse(isAgreed: false, includesAgree: false),
    ]
    for response in mismatches {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.threadAgreement(
          from: response,
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID,
          firstPostID: firstPostID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testDecoderRejectsExplicitFirstPostConflictEvenWhenPayloadCarriesExpectedPost() {
    let response = agreementResponse(
      isAgreed: false,
      declaredFirstPostID: firstPostID + 1,
      payloadFirstPostID: firstPostID,
      payloadThreadID: threadID
    )

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.threadAgreement(
        from: response,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        firstPostID: firstPostID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testDecoderRejectsFallbackPostBoundToDifferentThread() {
    for usesPostList in [false, true] {
      let response = agreementResponse(
        isAgreed: false,
        declaredFirstPostID: 0,
        payloadFirstPostID: firstPostID,
        payloadThreadID: threadID + 1,
        usesPostListForFirstPost: usesPostList
      )

      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.threadAgreement(
          from: response,
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID,
          firstPostID: firstPostID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testDecoderAcceptsZeroDeclarationWithBoundPayloadFallback() throws {
    for (payloadThreadID, usesPostList) in [(Int64(0), false), (threadID, true)] {
      let response = agreementResponse(
        isAgreed: true,
        score: 7,
        declaredFirstPostID: 0,
        payloadFirstPostID: firstPostID,
        payloadThreadID: payloadThreadID,
        usesPostListForFirstPost: usesPostList
      )

      let state = try TiebaAuthenticatedDecoder.threadAgreement(
        from: response,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        firstPostID: firstPostID
      )
      XCTAssertTrue(state.isAgreed)
      XCTAssertEqual(state.firstPostID, firstPostID)
      XCTAssertEqual(state.agreeScore, 7)
    }
  }

  func testAuthenticatedReadBindsForumIdentityBeforeReturningAgreement() async throws {
    let transport = ThreadAgreementStubTransport(
      responses: [
        try membershipResponse().serializedData(),
        try agreementResponse(isAgreed: true, score: 7).serializedData(),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.getThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      firstPostID: firstPostID
    )

    XCTAssertTrue(state.isAgreed)
    XCTAssertEqual(state.agreeScore, 7)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), ["/c/f/frs/page", "/c/f/pb/page"])
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.threadAgreementResponseMaximumBytes,
      ]
    )
  }

  func testWriteProbesStateThenBindsFreshTBSAndSendsExactlyOneWrite() async throws {
    let transport = ThreadAgreementStubTransport(
      responses: [
        try agreementResponse(isAgreed: false, score: 10).serializedData(),
        try membershipResponse().serializedData(),
        Data(#"{"error_code":"0","data":{"agree":{"score":"11"}}}"#.utf8),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.setThreadAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: true
    )

    XCTAssertTrue(state.isAgreed)
    XCTAssertEqual(state.agreeScore, 11)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      ["/c/f/pb/page", "/c/f/frs/page", "/c/c/agree/opAgree"]
    )
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.threadAgreementResponseMaximumBytes,
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.threadAgreementWriteResponseMaximumBytes,
      ]
    )
  }

  func testMatchingStateStillVerifiesIdentityAndSkipsWrite() async throws {
    let transport = ThreadAgreementStubTransport(
      responses: [
        try agreementResponse(isAgreed: true, score: 10).serializedData(),
        try membershipResponse().serializedData(),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.setThreadAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: true
    )

    XCTAssertTrue(state.isAgreed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), ["/c/f/pb/page", "/c/f/frs/page"])
  }

  func testWriteFailureIsReturnedWithoutRetry() async throws {
    let transport = ThreadAgreementStubTransport(
      responses: [
        try agreementResponse(isAgreed: false).serializedData(),
        try membershipResponse().serializedData(),
        Data(#"{"error_code":"340006","error_msg":"denied"}"#.utf8),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await client.setThreadAgreementState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: true
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 3)
  }

  func testConcurrentEquivalentWritesShareOneProbeAndOneWrite() async throws {
    let transport = ConcurrentThreadAgreementTransport(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName
    let targetThreadID = threadID
    let targetFirstPostID = firstPostID

    let first = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: "  \(targetForumName)  ",
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: true
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseWrites()
      XCTFail("Timed out waiting for the first agreement write")
      return
    }

    let second = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: true
      )
    }
    guard await waitUntilThreadAgreementWaiterCounts(
      client: client,
      expectedUserID: expectedUserID,
      threadID: targetThreadID,
      firstPostID: targetFirstPostID,
      shared: 1,
      conflict: 0
    ) else {
      second.cancel()
      await transport.releaseWrites()
      _ = await first.result
      _ = await second.result
      XCTFail("Timed out waiting for the equivalent agreement write to join")
      return
    }

    let writeCountBeforeRelease = await transport.writeCount()
    XCTAssertEqual(writeCountBeforeRelease, 1)
    await transport.releaseWrites()
    let firstState = try await first.value
    let secondState = try await second.value

    XCTAssertEqual(firstState, secondState)
    XCTAssertTrue(firstState.isAgreed)
    XCTAssertEqual(firstState.agreeScore, 11)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.pathCounts["/c/f/pb/page"], 1)
    XCTAssertEqual(snapshot.pathCounts["/c/f/frs/page"], 1)
    XCTAssertEqual(snapshot.pathCounts["/c/c/agree/opAgree"], 1)
  }

  func testOppositeTargetWaitsThenThrowsConflictWithoutSecondProbeOrWrite() async throws {
    let transport = ConcurrentThreadAgreementTransport(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName
    let targetThreadID = threadID
    let targetFirstPostID = firstPostID

    let first = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: true
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseWrites()
      XCTFail("Timed out waiting for the first agreement write")
      return
    }
    let conflict = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: false
      )
    }
    guard await waitUntilThreadAgreementWaiterCounts(
      client: client,
      expectedUserID: expectedUserID,
      threadID: targetThreadID,
      firstPostID: targetFirstPostID,
      shared: 0,
      conflict: 1
    ) else {
      conflict.cancel()
      await transport.releaseWrites()
      _ = await first.result
      _ = await conflict.result
      XCTFail("Timed out waiting for the opposite agreement target")
      return
    }

    let writeCountBeforeRelease = await transport.writeCount()
    XCTAssertEqual(writeCountBeforeRelease, 1)
    await transport.releaseWrites()
    _ = try await first.value
    await assertError(.threadAgreementWriteConflict) {
      _ = try await conflict.value
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.pathCounts["/c/f/pb/page"], 1)
    XCTAssertEqual(snapshot.pathCounts["/c/f/frs/page"], 1)
    XCTAssertEqual(snapshot.pathCounts["/c/c/agree/opAgree"], 1)
  }

  func testRotatedCredentialWaitsThenThrowsConflictWithoutSecondWrite() async throws {
    let transport = ConcurrentThreadAgreementTransport(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let oldCredential = credential("b")
    let rotatedCredential = credential("c")
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName
    let targetThreadID = threadID
    let targetFirstPostID = firstPostID

    let first = Task {
      try await client.setThreadAgreementState(
        credential: oldCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: true
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseWrites()
      XCTFail("Timed out waiting for the old-credential agreement write")
      return
    }
    let conflict = Task {
      try await client.setThreadAgreementState(
        credential: rotatedCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: targetThreadID,
        firstPostID: targetFirstPostID,
        isAgreed: true
      )
    }
    guard await waitUntilThreadAgreementWaiterCounts(
      client: client,
      expectedUserID: expectedUserID,
      threadID: targetThreadID,
      firstPostID: targetFirstPostID,
      shared: 0,
      conflict: 1
    ) else {
      conflict.cancel()
      await transport.releaseWrites()
      _ = await first.result
      _ = await conflict.result
      XCTFail("Timed out waiting for the rotated agreement credential")
      return
    }

    await transport.releaseWrites()
    _ = try await first.value
    await assertError(.threadAgreementWriteConflict) {
      _ = try await conflict.value
    }
    let finalWriteCount = await transport.writeCount()
    XCTAssertEqual(finalWriteCount, 1)
  }

  func testWritesForDifferentThreadsProceedInParallel() async throws {
    let transport = ConcurrentThreadAgreementTransport(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName
    let firstThreadID = threadID
    let firstPID = firstPostID
    let secondThreadID = threadID + 1
    let secondPID = firstPostID + 1

    let first = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: firstThreadID,
        firstPostID: firstPID,
        isAgreed: true
      )
    }
    let second = Task {
      try await client.setThreadAgreementState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName,
        threadID: secondThreadID,
        firstPostID: secondPID,
        isAgreed: true
      )
    }
    guard await transport.waitUntilWriteCount(2) else {
      first.cancel()
      second.cancel()
      await transport.releaseWrites()
      _ = await first.result
      _ = await second.result
      XCTFail("Timed out waiting for independent agreement writes")
      return
    }

    let snapshotBeforeRelease = await transport.snapshot()
    XCTAssertEqual(
      Set(snapshotBeforeRelease.writeThreadIDs),
      Set([firstThreadID, secondThreadID])
    )
    await transport.releaseWrites()
    let firstState = try await first.value
    let secondState = try await second.value

    XCTAssertEqual(
      Set([firstState.threadID, secondState.threadID]),
      Set([firstThreadID, secondThreadID])
    )
    let finalWriteCount = await transport.writeCount()
    XCTAssertEqual(finalWriteCount, 2)
  }

  func testWriteDecoderAcceptsMissingScoreButRejectsMalformedScore() throws {
    XCTAssertNil(
      try TiebaAuthenticatedDecoder.threadAgreementWriteScore(
        from: Data(#"{"error_code":"0"}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.threadAgreementWriteScore(
        from: Data(#"{"error_code":"0","data":{"agree":{"score":true}}}"#.utf8)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
  }

  private func credential(_ component: String = "b") -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: component, count: 192))
  }

  private func membershipResponse() -> FrsPageResIdl {
    var user = User()
    user.id = userID
    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID
    forum.name = forumName
    forum.isLike = 1
    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs
    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti
    var response = FrsPageResIdl()
    response.data = data
    return response
  }

  private func agreementResponse(
    isAgreed: Bool,
    agreeCount: Int64 = 10,
    disagreeCount: Int64 = 0,
    score: Int64 = 0,
    responseForumID: Int64? = nil,
    responseThreadID: Int64? = nil,
    responseFirstPostID: Int64? = nil,
    declaredFirstPostID: Int64? = nil,
    payloadFirstPostID: Int64? = nil,
    payloadThreadID: Int64? = nil,
    usesPostListForFirstPost: Bool = false,
    rawHasAgree: Int32? = nil,
    includesAgree: Bool = true
  ) -> PbPageResIdl {
    let resolvedFirstPostID = responseFirstPostID ?? firstPostID
    let resolvedPayloadFirstPostID = payloadFirstPostID ?? resolvedFirstPostID
    var forum = SimpleForum()
    forum.id = responseForumID ?? forumID
    forum.name = forumName

    var thread = ThreadInfo()
    thread.id = responseThreadID ?? threadID
    thread.firstPostID = declaredFirstPostID ?? resolvedFirstPostID
    if includesAgree {
      var agree = Agree()
      agree.agreeNum = agreeCount
      agree.disagreeNum = disagreeCount
      agree.diffAgreeNum = score
      agree.hasAgree = rawHasAgree ?? (isAgreed ? 1 : 0)
      thread.agree = agree
    }

    var firstPost = Post()
    firstPost.id = resolvedPayloadFirstPostID
    firstPost.floor = 1
    firstPost.tid = payloadThreadID ?? responseThreadID ?? threadID

    var data = PbPageResIdl.DataRes()
    data.forum = forum
    data.thread = thread
    if usesPostListForFirstPost {
      data.postList = [firstPost]
    } else {
      data.firstFloorPost = firstPost
    }
    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func protobufPayload(from request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    XCTAssertTrue(body.starts(with: prefix))
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    return body.subdata(in: prefix.count..<(body.count - suffix.count))
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
      XCTFail("Expected TiebaClientError")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}

private func waitUntilThreadAgreementWaiterCounts(
  client: TiebaAuthenticatedClient,
  expectedUserID: Int64,
  threadID: Int64,
  firstPostID: Int64,
  shared: Int,
  conflict: Int,
  timeout: Duration = .seconds(2)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    let counts = await client.threadAgreementWaiterCounts(
      expectedUserID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    if counts.shared == shared, counts.conflict == conflict {
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

private actor ConcurrentThreadAgreementTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let pathCounts: [String: Int]
    let writeThreadIDs: [Int64]
  }

  private let userID: Int64
  private let forumID: Int64
  private let forumName: String
  private let tbs: String
  private var pathCounts = [String: Int]()
  private var writeThreadIDs = [Int64]()
  private var writesReleased = false
  private var writeWaiters = [CheckedContinuation<Void, Never>]()

  init(userID: Int64, forumID: Int64, forumName: String, tbs: String) {
    self.userID = userID
    self.forumID = forumID
    self.forumName = forumName
    self.tbs = tbs
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    guard let path = request.url?.path else { throw TiebaClientError.transportFailure }
    pathCounts[path, default: 0] += 1

    let body: Data
    switch path {
    case "/c/f/pb/page":
      let requestMessage = try PbPageReqIdl(serializedBytes: protobufPayload(from: request))
      body = try agreementResponse(
        threadID: requestMessage.data.kz,
        firstPostID: requestMessage.data.pid
      ).serializedData()
    case "/c/f/frs/page":
      body = try membershipResponse().serializedData()
    case "/c/c/agree/opAgree":
      let fields = try formFields(request)
      guard let threadID = fields["thread_id"].flatMap({ Int64($0) }) else {
        throw TiebaClientError.transportFailure
      }
      writeThreadIDs.append(threadID)
      if !writesReleased {
        await withCheckedContinuation { writeWaiters.append($0) }
      }
      body = Data(#"{"error_code":"0"}"#.utf8)
    default:
      throw TiebaClientError.transportFailure
    }
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func waitUntilWriteCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if writeThreadIDs.count >= expectedCount { return true }
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return false
  }

  func releaseWrites() {
    writesReleased = true
    let waiters = writeWaiters
    writeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func writeCount() -> Int { writeThreadIDs.count }

  func snapshot() -> Snapshot {
    Snapshot(pathCounts: pathCounts, writeThreadIDs: writeThreadIDs)
  }

  private func membershipResponse() -> FrsPageResIdl {
    var user = User()
    user.id = userID
    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID
    forum.name = forumName
    forum.isLike = 1
    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs
    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti
    var response = FrsPageResIdl()
    response.data = data
    return response
  }

  private func agreementResponse(threadID: Int64, firstPostID: Int64) -> PbPageResIdl {
    var forum = SimpleForum()
    forum.id = forumID
    forum.name = forumName
    var agree = Agree()
    agree.agreeNum = 10
    agree.diffAgreeNum = 10
    agree.hasAgree = 0
    var thread = ThreadInfo()
    thread.id = threadID
    thread.firstPostID = firstPostID
    thread.agree = agree
    var firstPost = Post()
    firstPost.id = firstPostID
    firstPost.floor = 1
    firstPost.tid = threadID
    var data = PbPageResIdl.DataRes()
    data.forum = forum
    data.thread = thread
    data.firstFloorPost = firstPost
    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func protobufPayload(from request: URLRequest) throws -> Data {
    guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    guard body.starts(with: prefix), body.count >= prefix.count + suffix.count else {
      throw TiebaClientError.transportFailure
    }
    return body.subdata(in: prefix.count..<(body.count - suffix.count))
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    guard let items = components.queryItems else { throw TiebaClientError.transportFailure }
    return Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )
  }
}

private actor ThreadAgreementStubTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Data]
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(responses: [Data]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let index = requests.count
    guard responses.indices.contains(index) else {
      throw TiebaClientError.transportFailure
    }
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    return TiebaHTTPResponse(body: responses[index], statusCode: 200)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}
