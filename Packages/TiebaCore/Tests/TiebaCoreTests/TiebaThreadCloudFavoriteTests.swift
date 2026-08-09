import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaThreadCloudFavoriteTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let threadID: Int64 = 8_675_309
  private let markedPostID: Int64 = 9_001
  private let tbs = "91be894d01799c4991be894d01"

  func testPublicStateReportsWhetherACloudFavoriteExists() {
    let favorite = TiebaThreadCloudFavoriteState(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID
    )
    let absent = TiebaThreadCloudFavoriteState(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: nil
    )

    XCTAssertTrue(favorite.isFavorited)
    XCTAssertFalse(absent.isFavorited)
    XCTAssertEqual(favorite.markedPostID, markedPostID)
  }

  func testStateProbeUsesMinimalAuthenticatedHTTPSProtobufRequest() throws {
    let credential = sessionCredential()
    let request = try factory().threadCloudFavoriteState(
      credential: credential,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/pb/page?cmd=302001"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertFalse(request.url?.absoluteString.contains(credential.bduss) ?? true)
    XCTAssertFalse(request.url?.absoluteString.contains(credential.stoken) ?? true)

    let message = try PbPageReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(message.data.kz, threadID)
    XCTAssertEqual(message.data.forumID, forumID)
    XCTAssertEqual(message.data.pn, 1)
    XCTAssertEqual(message.data.rn, 2)
    XCTAssertEqual(message.data.lz, 0)
    XCTAssertEqual(message.data.withFloor, 0)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(message.data.common.bduss, credential.bduss)
    XCTAssertTrue(message.data.common.stoken.isEmpty)
    XCTAssertTrue(message.data.common.tbs.isEmpty)
    XCTAssertTrue(message.data.common.cuid.isEmpty)
    XCTAssertTrue(message.data.common.phoneImei.isEmpty)
  }

  func testAddRequestUsesExactMinimalSignedContract() throws {
    let credential = sessionCredential()
    let request = try factory().setThreadCloudFavoriteState(
      credential: credential,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      markedPostID: markedPostID
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/post/addstore")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "data", "stoken", "sign"]
    )
    XCTAssertEqual(fields["BDUSS"], credential.bduss)
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["stoken"], credential.stoken)

    let data = try XCTUnwrap(fields["data"]?.data(using: .utf8))
    let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(Set(row.keys), ["pid", "status", "tid"])
    XCTAssertEqual(row["tid"] as? String, String(threadID))
    XCTAssertEqual(row["pid"] as? String, String(markedPostID))
    XCTAssertEqual((row["status"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential.bduss),
          ("_client_version", "12.41.7.1"),
          ("data", try XCTUnwrap(fields["data"])),
          ("stoken", credential.stoken),
        ]
      )
    )
    for forbidden in [
      "fid", "tbs", "tid", "user_id", "cuid", "CUID", "imei", "IMEI", "oaid",
      "android_id", "model", "timestamp", "_timestamp", "client_id", "client_type",
      "_client_type",
    ] {
      XCTAssertNil(fields[forbidden])
    }
  }

  func testRemoveRequestUsesExactMinimalSignedContractAndFreshTBS() throws {
    let credential = sessionCredential()
    let request = try factory().setThreadCloudFavoriteState(
      credential: credential,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      markedPostID: nil
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/post/rmstore")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "fid", "stoken", "tbs", "tid", "user_id", "sign"]
    )
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["tid"], String(threadID))
    XCTAssertEqual(fields["user_id"], String(userID))
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential.bduss),
          ("_client_version", "12.41.7.1"),
          ("fid", String(forumID)),
          ("stoken", credential.stoken),
          ("tbs", tbs),
          ("tid", String(threadID)),
          ("user_id", String(userID)),
        ]
      )
    )
    for forbidden in [
      "data", "cuid", "CUID", "imei", "IMEI", "oaid", "android_id", "model",
      "timestamp", "_timestamp", "client_id", "client_type", "_client_type",
    ] {
      XCTAssertNil(fields[forbidden])
    }
  }

  func testRequestFactoryRejectsInvalidCredentialsIdentityTBSAndMarker() throws {
    let invalidCredential = TiebaSessionCredential(
      bduss: String(repeating: "b", count: 191),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
    XCTAssertThrowsError(
      try factory().threadCloudFavoriteState(
        credential: invalidCredential,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    )

    let invalidIdentities = [
      (Int64(0), forumID, threadID),
      (userID, Int64(0), threadID),
      (userID, forumID, Int64(0)),
    ]
    for identity in invalidIdentities {
      XCTAssertThrowsError(
        try factory().threadCloudFavoriteState(
          credential: sessionCredential(),
          expectedUserID: identity.0,
          forumID: identity.1,
          threadID: identity.2
        )
      )
    }
    for invalidTBS in ["", String(repeating: "a", count: 25), String(repeating: "A", count: 26)] {
      XCTAssertThrowsError(
        try factory().setThreadCloudFavoriteState(
          credential: sessionCredential(),
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID,
          tbs: invalidTBS,
          markedPostID: markedPostID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
    XCTAssertThrowsError(
      try factory().setThreadCloudFavoriteState(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        tbs: tbs,
        markedPostID: 0
      )
    )
  }

  func testDecoderMapsAuthoritativeStateAndKeepsTBSPrivate() throws {
    let context = try TiebaAuthenticatedDecoder.threadCloudFavoriteContext(
      from: cloudFavoriteResponse(markedPostID: markedPostID),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )

    XCTAssertEqual(
      context.state,
      TiebaThreadCloudFavoriteState(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      )
    )
    XCTAssertFalse(String(describing: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(
      Array(context.customMirror.children).contains { String(describing: $0.value).contains(tbs) }
    )

    let absent = try TiebaAuthenticatedDecoder.threadCloudFavoriteContext(
      from: cloudFavoriteResponse(markedPostID: nil, rawMarkedPostID: "0"),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )
    XCTAssertNil(absent.state.markedPostID)
    XCTAssertFalse(absent.state.isFavorited)
  }

  func testDecoderRejectsUnauthenticatedMismatchedIncompleteAndInvalidStates() throws {
    var missingData = PbPageResIdl()
    assertDecodeError(.invalidAuthenticatedResponse, response: missingData)

    missingData = cloudFavoriteResponse(markedPostID: nil, includeAnti: false)
    assertDecodeError(.invalidAuthenticatedResponse, response: missingData)
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, userID: userID + 1)
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, isLogin: 0)
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, forumID: forumID + 1)
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, threadID: threadID + 1)
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, threadFID: forumID + 1)
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, tbs: String(repeating: "A", count: 26))
    )
    assertDecodeError(
      .invalidAuthenticatedResponse,
      response: cloudFavoriteResponse(markedPostID: nil, collectStatus: 2)
    )
    for rawMarker in ["", "0", "-1", "+1", " 1", "1 ", "abc", "9223372036854775808"] {
      assertDecodeError(
        .invalidAuthenticatedResponse,
        response: cloudFavoriteResponse(
          markedPostID: nil,
          collectStatus: 1,
          rawMarkedPostID: rawMarker
        )
      )
    }
    for rawMarker in ["1", "-1", "abc", "9223372036854775808"] {
      assertDecodeError(
        .invalidAuthenticatedResponse,
        response: cloudFavoriteResponse(
          markedPostID: nil,
          collectStatus: 0,
          rawMarkedPostID: rawMarker
        )
      )
    }
  }

  func testDecoderSurfacesProtobufAndWriteServerErrors() throws {
    let protobuf = cloudFavoriteResponse(
      markedPostID: nil,
      errorCode: 123,
      errorMessage: "denied"
    )
    assertDecodeError(.server(code: 123, message: "denied"), response: protobuf)

    XCTAssertNoThrow(
      try TiebaAuthenticatedDecoder.checkThreadCloudFavoriteWriteResponse(
        Data(#"{"error_code":"0"}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkThreadCloudFavoriteWriteResponse(
        Data(#"{"error_code":"123","error_msg":"denied"}"#.utf8)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: 123, message: "denied")) }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkThreadCloudFavoriteWriteResponse(Data(#"{}"#.utf8))
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
  }

  func testAuthenticatedClientReadsStrictStateWithBoundedResponse() async throws {
    let body = try cloudFavoriteResponse(markedPostID: markedPostID).serializedData()
    let transport = CloudFavoriteStaticTransport(body: body)
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.getThreadCloudFavoriteState(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )

    XCTAssertEqual(state.markedPostID, markedPostID)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), ["/c/f/pb/page"])
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [TiebaAuthenticatedClient.threadCloudFavoriteStateResponseMaximumBytes]
    )
  }

  func testStateResponseLimitIsEnforcedBeforeProtobufDecode() async throws {
    let oversized = Data(
      repeating: 0,
      count: TiebaAuthenticatedClient.threadCloudFavoriteStateResponseMaximumBytes + 1
    )
    let transport = CloudFavoriteStaticTransport(body: oversized)
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.threadCloudFavoriteStateResponseMaximumBytes
      )
    ) {
      _ = try await client.getThreadCloudFavoriteState(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        threadID: self.threadID
      )
    }
  }

  func testPreReadMakesEquivalentAddAndRemoveIdempotent() async throws {
    for initialMarker in [Int64?.some(markedPostID), nil] {
      let transport = CloudFavoriteMutationTransport(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        tbs: tbs,
        initialMarkedPostID: initialMarker
      )
      let client = TiebaAuthenticatedClient(transport: transport)

      let state = try await client.setThreadCloudFavoriteState(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: initialMarker
      )

      XCTAssertEqual(state.markedPostID, initialMarker)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.requests.map(\.url?.path), ["/c/f/pb/page"])
      XCTAssertEqual(snapshot.writeCount, 0)
    }
  }

  func testAddUpdateAndRemoveEachPerformAtMostOneWriteAndReconcile() async throws {
    let cases: [(initial: Int64?, target: Int64?, path: String)] = [
      (nil, markedPostID, "/c/c/post/addstore"),
      (markedPostID, markedPostID + 1, "/c/c/post/addstore"),
      (markedPostID, nil, "/c/c/post/rmstore"),
    ]

    for item in cases {
      let transport = CloudFavoriteMutationTransport(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        tbs: tbs,
        initialMarkedPostID: item.initial
      )
      let client = TiebaAuthenticatedClient(transport: transport)

      let state = try await client.setThreadCloudFavoriteState(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: item.target
      )

      XCTAssertEqual(state.markedPostID, item.target)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(
        snapshot.requests.map(\.url?.path),
        ["/c/f/pb/page", item.path, "/c/f/pb/page"]
      )
      XCTAssertEqual(snapshot.writeCount, 1)
      XCTAssertEqual(
        snapshot.maximumBodyBytes,
        [
          TiebaAuthenticatedClient.threadCloudFavoriteStateResponseMaximumBytes,
          TiebaAuthenticatedClient.threadCloudFavoriteWriteResponseMaximumBytes,
          TiebaAuthenticatedClient.threadCloudFavoriteStateResponseMaximumBytes,
        ]
      )
      if item.path.hasSuffix("rmstore") {
        XCTAssertEqual(try formFields(snapshot.requests[1])["tbs"], tbs)
      }
    }
  }

  func testSuccessfulWriteRequiresMatchingReadBackState() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      behavior: .successWithoutCommit
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.invalidAuthenticatedResponse) {
      _ = try await client.setThreadCloudFavoriteState(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        threadID: self.threadID,
        markedPostID: self.markedPostID
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page",
    ])
  }

  func testUncertainFailureReturnsCommittedStateWithoutRetryingWrite() async throws {
    for behavior in [
      CloudFavoriteMutationTransport.WriteBehavior.networkAfterCommit,
      .malformedAfterCommit,
      .oversizedAfterCommit,
    ] {
      let transport = CloudFavoriteMutationTransport(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        tbs: tbs,
        initialMarkedPostID: nil,
        behavior: behavior
      )
      let client = TiebaAuthenticatedClient(transport: transport)

      let state = try await client.setThreadCloudFavoriteState(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      )

      XCTAssertEqual(state.markedPostID, markedPostID)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.writeCount, 1)
      XCTAssertEqual(snapshot.requests.map(\.url?.path), [
        "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page",
      ])
    }
  }

  func testUncertainFailurePreservesOriginalErrorWhenReadBackDoesNotMatch() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      behavior: .networkWithoutCommit
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.network(code: -1_005)) {
      _ = try await client.setThreadCloudFavoriteState(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        threadID: self.threadID,
        markedPostID: self.markedPostID
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.count, 3)
  }

  func testCancellationErrorAfterCommittedWriteOnlyReconcilesWithoutRetrying() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      behavior: .cancellationAfterCommit
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.setThreadCloudFavoriteState(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID
    )

    XCTAssertEqual(state.markedPostID, markedPostID)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page",
    ])
  }

  func testDefiniteServerFailureDoesNotReconcileOrRetry() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      behavior: .server
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.server(code: 123, message: "denied")) {
      _ = try await client.setThreadCloudFavoriteState(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        threadID: self.threadID,
        markedPostID: self.markedPostID
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore",
    ])
  }

  func testConcurrentEquivalentWriteCoalescesAndConflictOnlyReadsAfterIt() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      blocksFirstWrite: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let credential = sessionCredential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetThreadID = threadID
    let targetMarker = markedPostID

    let first = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseFirstWrite()
      XCTFail("Timed out waiting for the first cloud-favorite write")
      return
    }

    let equivalent = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    let conflict = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: nil
      )
    }
    guard await waitUntilWaiterCounts(client: client, shared: 1, conflict: 1) else {
      equivalent.cancel()
      conflict.cancel()
      await transport.releaseFirstWrite()
      _ = await first.result
      _ = await equivalent.result
      _ = await conflict.result
      XCTFail("Timed out waiting for coalesced and conflicting callers")
      return
    }

    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 2)
    await transport.releaseFirstWrite()
    let firstState = try await first.value
    let equivalentState = try await equivalent.value
    let conflictState = try await conflict.value

    XCTAssertEqual(firstState.markedPostID, targetMarker)
    XCTAssertEqual(equivalentState, firstState)
    XCTAssertEqual(conflictState.markedPostID, targetMarker)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page", "/c/f/pb/page",
    ])
    let finalCounts = await client.threadCloudFavoriteWaiterCounts(
      expectedUserID: userID,
      threadID: threadID
    )
    XCTAssertEqual(finalCounts.shared, 0)
    XCTAssertEqual(finalCounts.conflict, 0)
  }

  func testCancellingSharedWaiterReturnsBeforeWriteCompletesAndKeepsFlightAlive() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      blocksFirstWrite: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let credential = sessionCredential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetThreadID = threadID
    let targetMarker = markedPostID

    let first = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseFirstWrite()
      XCTFail("Timed out waiting for the first cloud-favorite write")
      return
    }
    let shared = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await waitUntilWaiterCounts(client: client, shared: 1, conflict: 0) else {
      shared.cancel()
      await transport.releaseFirstWrite()
      _ = await first.result
      _ = await shared.result
      XCTFail("Timed out waiting for the shared cloud-favorite caller")
      return
    }

    shared.cancel()
    do {
      _ = try await shared.value
      XCTFail("Expected shared waiter cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
    let countsAfterCancellation = await client.threadCloudFavoriteWaiterCounts(
      expectedUserID: userID,
      threadID: threadID
    )
    XCTAssertEqual(countsAfterCancellation.shared, 0)
    XCTAssertEqual(countsAfterCancellation.conflict, 0)
    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 2)

    await transport.releaseFirstWrite()
    let firstState = try await first.value
    XCTAssertEqual(firstState.markedPostID, targetMarker)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page",
    ])
  }

  func testCancellingConflictWaiterReturnsBeforeWriteCompletesAndDoesNotRead() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      blocksFirstWrite: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let credential = sessionCredential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetThreadID = threadID
    let targetMarker = markedPostID

    let first = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseFirstWrite()
      XCTFail("Timed out waiting for the first cloud-favorite write")
      return
    }
    let conflict = Task {
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: nil
      )
    }
    guard await waitUntilWaiterCounts(client: client, shared: 0, conflict: 1) else {
      conflict.cancel()
      await transport.releaseFirstWrite()
      _ = await first.result
      _ = await conflict.result
      XCTFail("Timed out waiting for the conflicting cloud-favorite caller")
      return
    }

    conflict.cancel()
    do {
      _ = try await conflict.value
      XCTFail("Expected conflict waiter cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
    let countsAfterCancellation = await client.threadCloudFavoriteWaiterCounts(
      expectedUserID: userID,
      threadID: threadID
    )
    XCTAssertEqual(countsAfterCancellation.shared, 0)
    XCTAssertEqual(countsAfterCancellation.conflict, 0)
    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 2)

    await transport.releaseFirstWrite()
    let firstState = try await first.value
    XCTAssertEqual(firstState.markedPostID, targetMarker)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page",
    ])
  }

  func testRotatedCredentialWaitsThenOnlyReadsCurrentState() async throws {
    let transport = CloudFavoriteMutationTransport(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      tbs: tbs,
      initialMarkedPostID: nil,
      blocksFirstWrite: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let oldCredential = sessionCredential(stokenCharacter: "s")
    let rotatedCredential = sessionCredential(stokenCharacter: "t")
    let expectedUserID = userID
    let targetForumID = forumID
    let targetThreadID = threadID
    let targetMarker = markedPostID

    let first = Task {
      try await client.setThreadCloudFavoriteState(
        credential: oldCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      first.cancel()
      await transport.releaseFirstWrite()
      XCTFail("Timed out waiting for the old-credential write")
      return
    }
    let rotated = Task {
      try await client.setThreadCloudFavoriteState(
        credential: rotatedCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        threadID: targetThreadID,
        markedPostID: targetMarker
      )
    }
    guard await waitUntilWaiterCounts(client: client, shared: 0, conflict: 1) else {
      rotated.cancel()
      await transport.releaseFirstWrite()
      _ = await first.result
      _ = await rotated.result
      XCTFail("Timed out waiting for the rotated credential")
      return
    }

    await transport.releaseFirstWrite()
    let firstState = try await first.value
    let rotatedState = try await rotated.value
    XCTAssertEqual(firstState.markedPostID, targetMarker)
    XCTAssertEqual(rotatedState.markedPostID, targetMarker)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/f/pb/page", "/c/c/post/addstore", "/c/f/pb/page", "/c/f/pb/page",
    ])
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func sessionCredential(
    bdussCharacter: Character = "b",
    stokenCharacter: Character = "s"
  ) -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: bdussCharacter, count: 192),
      stoken: String(repeating: stokenCharacter, count: 64),
      bdussCookieName: .bduss
    )
  }

  private func cloudFavoriteResponse(
    markedPostID: Int64?,
    userID: Int64? = nil,
    isLogin: Int32 = 1,
    forumID: Int64? = nil,
    threadID: Int64? = nil,
    threadFID: Int64? = nil,
    tbs: String? = nil,
    collectStatus: Int32? = nil,
    rawMarkedPostID: String? = nil,
    includeAnti: Bool = true,
    errorCode: Int32 = 0,
    errorMessage: String = ""
  ) -> PbPageResIdl {
    var user = User()
    user.isLogin = isLogin
    user.id = userID ?? self.userID

    var forum = SimpleForum()
    forum.id = forumID ?? self.forumID
    forum.name = "swift"

    var thread = ThreadInfo()
    thread.id = threadID ?? self.threadID
    thread.fid = threadFID ?? self.forumID
    thread.collectStatus = collectStatus ?? (markedPostID == nil ? 0 : 1)
    thread.collectMarkPid = rawMarkedPostID ?? markedPostID.map(String.init) ?? ""

    var data = PbPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.thread = thread
    if includeAnti {
      var anti = Anti()
      anti.tbs = tbs ?? self.tbs
      data.anti = anti
    }

    var error = TiebaProto.Error()
    error.errorno = errorCode
    error.errmsg = errorMessage

    var response = PbPageResIdl()
    response.error = error
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
    try cloudFavoriteFormFields(request)
  }

  private func assertDecodeError(
    _ expected: TiebaClientError,
    response: PbPageResIdl,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.threadCloudFavoriteContext(
        from: response,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      ),
      file: file,
      line: line
    ) { XCTAssertEqual($0 as? TiebaClientError, expected, file: file, line: line) }
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

  private func waitUntilWaiterCounts(
    client: TiebaAuthenticatedClient,
    shared: Int,
    conflict: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let counts = await client.threadCloudFavoriteWaiterCounts(
        expectedUserID: userID,
        threadID: threadID
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
}

private actor CloudFavoriteStaticTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let body: Data
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}

private actor CloudFavoriteMutationTransport: TiebaTransport {
  enum WriteBehavior: Sendable {
    case success
    case successWithoutCommit
    case networkAfterCommit
    case networkWithoutCommit
    case cancellationAfterCommit
    case malformedAfterCommit
    case oversizedAfterCommit
    case server
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
    let writeCount: Int
  }

  private let userID: Int64
  private let forumID: Int64
  private let threadID: Int64
  private let tbs: String
  private let behavior: WriteBehavior
  private let blocksFirstWrite: Bool
  private var markedPostID: Int64?
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()
  private var writeCount = 0
  private var firstWriteContinuation: CheckedContinuation<Void, Never>?
  private var isFirstWriteReleased = false

  init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    tbs: String,
    initialMarkedPostID: Int64?,
    behavior: WriteBehavior = .success,
    blocksFirstWrite: Bool = false
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.tbs = tbs
    self.markedPostID = initialMarkedPostID
    self.behavior = behavior
    self.blocksFirstWrite = blocksFirstWrite
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    switch request.url?.path {
    case "/c/f/pb/page":
      return TiebaHTTPResponse(
        body: try cloudFavoriteResponseBody(
          userID: userID,
          forumID: forumID,
          threadID: threadID,
          markedPostID: markedPostID,
          tbs: tbs
        ),
        statusCode: 200
      )
    case "/c/c/post/addstore", "/c/c/post/rmstore":
      writeCount += 1
      let target = try cloudFavoriteWriteTarget(request)
      if blocksFirstWrite, writeCount == 1, !isFirstWriteReleased {
        await withCheckedContinuation { continuation in
          if isFirstWriteReleased {
            continuation.resume()
          } else {
            firstWriteContinuation = continuation
          }
        }
      }
      switch behavior {
      case .success:
        markedPostID = target
        return successResponse()
      case .successWithoutCommit:
        return successResponse()
      case .networkAfterCommit:
        markedPostID = target
        throw TiebaClientError.network(code: -1_005)
      case .networkWithoutCommit:
        throw TiebaClientError.network(code: -1_005)
      case .cancellationAfterCommit:
        markedPostID = target
        throw CancellationError()
      case .malformedAfterCommit:
        markedPostID = target
        return TiebaHTTPResponse(body: Data("not-json".utf8), statusCode: 200)
      case .oversizedAfterCommit:
        markedPostID = target
        return TiebaHTTPResponse(
          body: Data(repeating: 0, count: (maximumBodyBytes ?? 65_536) + 1),
          statusCode: 200
        )
      case .server:
        return TiebaHTTPResponse(
          body: Data(#"{"error_code":"123","error_msg":"denied"}"#.utf8),
          statusCode: 200
        )
      }
    default:
      throw TiebaClientError.invalidEndpoint
    }
  }

  func waitUntilWriteCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while writeCount < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return writeCount >= expectedCount
  }

  func releaseFirstWrite() {
    isFirstWriteReleased = true
    let continuation = firstWriteContinuation
    firstWriteContinuation = nil
    continuation?.resume()
  }

  func requestCount() -> Int { requests.count }

  func snapshot() -> Snapshot {
    Snapshot(
      requests: requests,
      maximumBodyBytes: maximumBodyBytes,
      writeCount: writeCount
    )
  }

  private func successResponse() -> TiebaHTTPResponse {
    TiebaHTTPResponse(body: Data(#"{"error_code":"0"}"#.utf8), statusCode: 200)
  }
}

private func cloudFavoriteResponseBody(
  userID: Int64,
  forumID: Int64,
  threadID: Int64,
  markedPostID: Int64?,
  tbs: String
) throws -> Data {
  var user = User()
  user.isLogin = 1
  user.id = userID

  var forum = SimpleForum()
  forum.id = forumID
  forum.name = "swift"

  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.collectStatus = markedPostID == nil ? 0 : 1
  thread.collectMarkPid = markedPostID.map(String.init) ?? ""

  var anti = Anti()
  anti.tbs = tbs

  var data = PbPageResIdl.DataRes()
  data.user = user
  data.forum = forum
  data.thread = thread
  data.anti = anti

  var response = PbPageResIdl()
  response.data = data
  return try response.serializedData()
}

private func cloudFavoriteWriteTarget(_ request: URLRequest) throws -> Int64? {
  switch request.url?.path {
  case "/c/c/post/addstore":
    let fields = try cloudFavoriteFormFields(request)
    guard
      let value = fields["data"],
      let data = value.data(using: .utf8),
      let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      rows.count == 1,
      let pid = rows[0]["pid"] as? String,
      let markedPostID = Int64(pid),
      markedPostID > 0
    else {
      throw TiebaClientError.invalidArgument("Malformed test addstore request.")
    }
    return markedPostID
  case "/c/c/post/rmstore":
    return nil
  default:
    throw TiebaClientError.invalidEndpoint
  }
}

private func cloudFavoriteFormFields(_ request: URLRequest) throws -> [String: String] {
  guard let body = request.httpBody else {
    throw TiebaClientError.invalidArgument("Missing test request body.")
  }
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    .replacingOccurrences(of: "+", with: "%20")
  guard let items = components.queryItems else {
    throw TiebaClientError.invalidArgument("Malformed test form body.")
  }
  return Dictionary(
    uniqueKeysWithValues: items.compactMap { item in
      item.value.map { (item.name, $0) }
    }
  )
}
