import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaUserInteractionPermissionsTests: XCTestCase, @unchecked Sendable {
  private let accountID: Int64 = 957_339_815
  private let targetID: Int64 = 123_456_789
  private let initialTBS = "91be894d01799c4991be894d01"
  private let freshTBS = String(repeating: "a", count: 26)

  func testReadAndWriteRequestsUseExactMinimalSignedTiebaLiteContract() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let credential = sessionCredential()
    let read = try factory.userInteractionPermissions(
      credential: credential,
      expectedUserID: accountID,
      targetUserID: targetID
    )
    let readFields = try formFields(read)
    let readUnsigned = [
      ("BDUSS", credential.bduss),
      ("_client_type", "2"),
      ("_client_version", "12.41.7.1"),
      ("black_uid", String(targetID)),
      ("stoken", credential.stoken),
    ]

    XCTAssertEqual(read.url?.absoluteString, "https://tiebac.baidu.com/c/u/user/getUserBlackInfo")
    XCTAssertEqual(read.httpMethod, "POST")
    XCTAssertFalse(read.httpShouldHandleCookies)
    XCTAssertEqual(read.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertEqual(read.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(Set(readFields.keys), Set(readUnsigned.map(\.0)).union(["sign"]))
    XCTAssertEqual(readFields["sign"], TiebaFormSigner.signature(for: readUnsigned))
    XCTAssertNil(read.value(forHTTPHeaderField: "Authorization"))

    let desired = permissions(follow: true, interaction: false, chat: true)
    let write = try factory.setUserInteractionPermissions(
      credential: credential,
      expectedUserID: accountID,
      targetUserID: targetID,
      tbs: freshTBS,
      permissions: desired
    )
    let writeFields = try formFields(write)
    let expectedJSON = #"{"chat":1,"follow":1,"interact":0}"#
    let writeUnsigned = readUnsigned + [("perm_list", expectedJSON), ("tbs", freshTBS)]

    XCTAssertEqual(write.url?.absoluteString, "https://tiebac.baidu.com/c/c/user/setUserBlack")
    XCTAssertEqual(write.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertEqual(write.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(writeFields["perm_list"], expectedJSON)
    XCTAssertEqual(Set(writeFields.keys), Set(writeUnsigned.map(\.0)).union(["sign"]))
    XCTAssertEqual(writeFields["sign"], TiebaFormSigner.signature(for: writeUnsigned))
    XCTAssertNil(writeFields["cuid"])
    XCTAssertNil(writeFields["_phone_imei"])
  }

  func testRequestFactoryRejectsUnboundIdentityAndMalformedTBS() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    for (account, target) in [(Int64(0), targetID), (accountID, Int64(0)), (accountID, accountID)] {
      XCTAssertThrowsError(
        try factory.userInteractionPermissions(
          credential: sessionCredential(),
          expectedUserID: account,
          targetUserID: target
        )
      )
    }
    for tbs in ["", "short", String(repeating: "A", count: 26)] {
      XCTAssertThrowsError(
        try factory.setUserInteractionPermissions(
          credential: sessionCredential(),
          expectedUserID: accountID,
          targetUserID: targetID,
          tbs: tbs,
          permissions: permissions()
        )
      )
    }
  }

  func testStrictDecoderAcceptsEveryBitCombinationAndIgnoresBlackWhiteMetadata() throws {
    for follow in [0, 1] {
      for interaction in [0, 1] {
        for chat in [0, 1] {
          let body = permissionBody(
            follow: follow,
            interaction: interaction,
            chat: chat,
            suffix: #", "is_black_white":{"untrusted":"ignored"}"#
          )
          XCTAssertEqual(
            try TiebaAuthenticatedDecoder.userInteractionPermissions(
              from: body,
              expectedUserID: accountID,
              targetUserID: targetID
            ),
            TiebaUserInteractionPermissionState(
              userID: accountID,
              targetUserID: targetID,
              permissions: permissions(
                follow: follow == 1,
                interaction: interaction == 1,
                chat: chat == 1
              )
            )
          )
        }
      }
    }
  }

  func testStrictDecoderRequiresExactIntegerErrorCodeAndAllThreeExactIntegerBits() throws {
    for rawCode in [nil, #""0""#, "false", "0.0"] as [String?] {
      let code = rawCode.map { "\"error_code\":\($0)," } ?? ""
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.userInteractionPermissions(
          from: Data("{\(code)\"perm_list\":{\"follow\":0,\"interact\":0,\"chat\":0}}".utf8),
          expectedUserID: accountID,
          targetUserID: targetID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    }

    for key in ["follow", "interact", "chat"] {
      for invalid in [#""1""#, "true", "1.0", "2", "-1", "null"] {
        var values = ["follow": "0", "interact": "0", "chat": "0"]
        values[key] = invalid
        let followValue = values["follow"]!
        let interactionValue = values["interact"]!
        let chatValue = values["chat"]!
        let body = Data(
          "{\"error_code\":0,\"perm_list\":{\"follow\":\(followValue),\"interact\":\(interactionValue),\"chat\":\(chatValue)}}".utf8
        )
        XCTAssertThrowsError(
          try TiebaAuthenticatedDecoder.userInteractionPermissions(
            from: body,
            expectedUserID: accountID,
            targetUserID: targetID
          )
        ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
      }
    }
    for missing in ["follow", "interact", "chat"] {
      let fields = ["follow", "interact", "chat"].filter { $0 != missing }
        .map { "\"\($0)\":0" }.joined(separator: ",")
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.userInteractionPermissions(
          from: Data("{\"error_code\":0,\"perm_list\":{\(fields)}}".utf8),
          expectedUserID: accountID,
          targetUserID: targetID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    }
  }

  func testStrictDecoderSurfacesServerErrorAndWriteACKRequiresExactErrorCode() throws {
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.userInteractionPermissions(
        from: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8),
        expectedUserID: accountID,
        targetUserID: targetID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: 340_006, message: "denied")) }
    XCTAssertNoThrow(
      try TiebaAuthenticatedDecoder.checkUserInteractionPermissionsWriteResponse(
        Data(#"{"error_code":0}"#.utf8)
      )
    )
    for body in [#"{}"#, #"{"error_code":"0"}"#, #"{"error_code":false}"#] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.checkUserInteractionPermissionsWriteResponse(Data(body.utf8))
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    }
  }

  func testPublicReadBindsTargetWithProfileBeforeRawPermissionRead() async throws {
    let transport = PermissionStubTransport(responses: [
      .init(body: try profileData()),
      .init(body: permissionBody(follow: 1, interaction: 0, chat: 1)),
    ])
    let result = try await TiebaAuthenticatedClient(transport: transport)
      .getUserInteractionPermissionState(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID
      )

    XCTAssertEqual(result.permissions, permissions(follow: true, interaction: false, chat: true))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/u/user/profile", "/c/u/user/getUserBlackInfo",
    ])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.userRelationshipResponseMaximumBytes,
      TiebaAuthenticatedClient.userInteractionPermissionsResponseMaximumBytes,
    ])
  }

  func testPublicReadRejectsMismatchedProfileWithoutReadingPermissions() async throws {
    let transport = PermissionStubTransport(responses: [
      .init(body: try profileData(targetUserID: targetID + 1)),
    ])
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(transport: transport)
        .getUserInteractionPermissionState(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          targetUserID: self.targetID
        )
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testWriteSkipsMutationWhenBoundStateAlreadyMatches() async throws {
    let desired = permissions(follow: true, interaction: false, chat: true)
    let transport = PermissionStubTransport(responses: [
      .init(body: try profileData()),
      .init(body: permissionBody(desired)),
    ])
    let result = try await TiebaAuthenticatedClient(transport: transport)
      .setUserInteractionPermissions(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID,
        permissions: desired
      )

    XCTAssertEqual(result.permissions, desired)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/u/user/profile", "/c/u/user/getUserBlackInfo",
    ])
  }

  func testWriteUsesFreshProfileTBSAndExactlyOneRawReadback() async throws {
    let desired = permissions(follow: true, interaction: true, chat: false)
    let transport = PermissionStubTransport(responses: successfulWriteResponses(desired: desired))
    let result = try await TiebaAuthenticatedClient(transport: transport)
      .setUserInteractionPermissions(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID,
        permissions: desired
      )

    XCTAssertEqual(result.permissions, desired)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path), [
      "/c/u/user/profile", "/c/u/user/getUserBlackInfo", "/c/u/user/profile",
      "/c/c/user/setUserBlack", "/c/u/user/getUserBlackInfo",
    ])
    XCTAssertEqual(try formFields(snapshot.requests[3])["tbs"], freshTBS)
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/setUserBlack" }.count, 1)
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.userRelationshipResponseMaximumBytes,
      TiebaAuthenticatedClient.userInteractionPermissionsResponseMaximumBytes,
      TiebaAuthenticatedClient.userRelationshipResponseMaximumBytes,
      TiebaAuthenticatedClient.userInteractionPermissionsWriteResponseMaximumBytes,
      TiebaAuthenticatedClient.userInteractionPermissionsResponseMaximumBytes,
    ])
  }

  func testACKTransportFailureStillUsesOneReadbackAndNeverRetries() async throws {
    let desired = permissions(follow: true, interaction: false, chat: true)
    var responses = successfulWriteResponses(desired: desired)
    responses[3] = .init(error: .transportFailure)
    let transport = PermissionStubTransport(responses: responses)
    let result = try await TiebaAuthenticatedClient(transport: transport)
      .setUserInteractionPermissions(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID,
        permissions: desired
      )

    XCTAssertEqual(result.permissions, desired)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 5)
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/setUserBlack" }.count, 1)
  }

  func testMismatchedOrFailedReadbackReturnsTypedUnknownWithoutRetry() async throws {
    let desired = permissions(follow: true, interaction: true, chat: true)
    var mismatched = successfulWriteResponses(desired: desired)
    mismatched[4] = .init(body: permissionBody(follow: 0, interaction: 0, chat: 0))
    var failed = successfulWriteResponses(desired: desired)
    failed[4] = .init(error: .transportFailure)

    for responses in [mismatched, failed] {
      let transport = PermissionStubTransport(responses: responses)
      await assertError(.userInteractionPermissionsOutcomeUnknown) {
        _ = try await TiebaAuthenticatedClient(transport: transport)
          .setUserInteractionPermissions(
            credential: self.sessionCredential(),
            expectedUserID: self.accountID,
            targetUserID: self.targetID,
            permissions: desired
          )
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.requests.count, 5)
      XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/setUserBlack" }.count, 1)
    }
  }

  func testEquivalentConcurrentWritesShareOneFlightAndOneCallerMayCancel() async throws {
    let desired = permissions(follow: true, interaction: true, chat: false)
    let transport = PermissionStubTransport(
      responses: successfulWriteResponses(desired: desired),
      blockedRequestIndex: 3
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = permissionWriteTask(client: client, desired: desired)
    guard await transport.waitUntilRequestCount(4) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for permission write")
    }
    let joined = permissionWriteTask(client: client, desired: desired)
    guard await waitUntilPermissionWaiterCount(client, count: 2) else {
      joined.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      return XCTFail("Equivalent caller did not join permission flight")
    }

    joined.cancel()
    await assertCancellation(joined)
    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    XCTAssertEqual(firstResult.permissions, desired)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 5)
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/setUserBlack" }.count, 1)
  }

  func testConflictingAndRotatedCallersWaitThenOnlyReadCurrentState() async throws {
    let written = permissions(follow: true, interaction: false, chat: true)
    for (secondCredential, secondDesired) in [
      (sessionCredential(), permissions(follow: false, interaction: true, chat: false)),
      (sessionCredential(stokenCharacter: "t"), written),
    ] {
      let responses = successfulWriteResponses(desired: written) + [
        .init(body: try profileData()),
        .init(body: permissionBody(written)),
      ]
      let transport = PermissionStubTransport(responses: responses, blockedRequestIndex: 3)
      let client = TiebaAuthenticatedClient(transport: transport)
      let first = permissionWriteTask(client: client, desired: written)
      guard await transport.waitUntilRequestCount(4) else {
        first.cancel()
        await transport.releaseBlockedRequest()
        return XCTFail("Timed out waiting for first permission write")
      }
      let second = Task {
        try await client.setUserInteractionPermissions(
          credential: secondCredential,
          expectedUserID: accountID,
          targetUserID: targetID,
          permissions: secondDesired
        )
      }
      guard await waitUntilPermissionWaiterCount(client, count: 2) else {
        second.cancel()
        await transport.releaseBlockedRequest()
        _ = await first.result
        return XCTFail("Conflicting caller did not wait")
      }
      let blockedRequestCount = await transport.requestCount()
      XCTAssertEqual(blockedRequestCount, 4)
      await transport.releaseBlockedRequest()
      let firstResult = try await first.value
      let secondResult = try await second.value
      XCTAssertEqual(firstResult.permissions, written)
      XCTAssertEqual(secondResult.permissions, written)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.requests.count, 7)
      XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/setUserBlack" }.count, 1)
    }
  }

  func testDifferentTargetsCanProgressInParallel() async throws {
    let secondTargetID: Int64 = 987_654_321
    let desired = permissions(follow: true, interaction: true, chat: false)
    let responses = successfulWriteResponses(desired: desired, omittingReadback: true) + [
      .init(body: try profileData(targetUserID: secondTargetID)),
      .init(body: permissionBody()),
      .init(body: try profileData(targetUserID: secondTargetID, tbs: freshTBS)),
      .init(body: Data(#"{"error_code":0}"#.utf8)),
      .init(body: permissionBody(desired)),
      .init(body: permissionBody(desired)),
    ]
    let transport = PermissionStubTransport(responses: responses, blockedRequestIndex: 3)
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = permissionWriteTask(client: client, desired: desired)
    guard await transport.waitUntilRequestCount(4) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for first target")
    }
    let second = Task {
      try await client.setUserInteractionPermissions(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: secondTargetID,
        permissions: desired
      )
    }
    guard await transport.waitUntilRequestCount(9) else {
      second.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      return XCTFail("Second target did not finish while first target was blocked")
    }
    let secondResult = try await second.value
    XCTAssertEqual(secondResult.permissions, desired)
    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    let snapshot = await transport.snapshot()
    XCTAssertEqual(firstResult.permissions, desired)
    XCTAssertEqual(snapshot.requests.count, 10)
  }

  func testLastOwnerCancellationBeforeDispatchCancelsFlightWithoutWriting() async throws {
    let transport = CancellablePermissionTransport()
    let client = TiebaAuthenticatedClient(transport: transport)
    let task = permissionWriteTask(client: client, desired: permissions(follow: true))
    guard await transport.waitUntilStarted() else {
      task.cancel()
      return XCTFail("Preflight did not start")
    }
    task.cancel()
    await assertCancellation(task)
    guard await waitUntilPermissionFlightGone(client) else {
      return XCTFail("Cancelled preflight flight was retained")
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.map(\.url?.path), ["/c/u/user/profile"])
  }

  func testCancellationAfterDispatchDoesNotAbortRequiredReadback() async throws {
    let desired = permissions(follow: true, chat: true)
    let transport = PermissionStubTransport(
      responses: successfulWriteResponses(desired: desired),
      blockedRequestIndex: 3
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let task = permissionWriteTask(client: client, desired: desired)
    guard await transport.waitUntilRequestCount(4) else {
      task.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Write did not dispatch")
    }
    task.cancel()
    await assertCancellation(task)
    await transport.releaseBlockedRequest()
    guard await transport.waitUntilRequestCount(5), await waitUntilPermissionFlightGone(client) else {
      return XCTFail("Post-dispatch flight did not complete its readback")
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map(\.url?.path).suffix(2), [
      "/c/c/user/setUserBlack", "/c/u/user/getUserBlackInfo",
    ])
  }

  func testPermissionWriteWaitsForFollowAndThenOnlyReadsPermissions() async throws {
    let desired = permissions(follow: true)
    let transport = PermissionStubTransport(
      responses: [
        .init(body: try profileData(isFollowed: 0)),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try profileData(isFollowed: 1)),
        .init(body: try profileData()),
        .init(body: permissionBody()),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let follow = Task {
      try await client.setUserFollowState(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      follow.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Follow write did not dispatch")
    }
    let permission = permissionWriteTask(client: client, desired: desired)
    guard await waitUntilFollowWaiterCount(client, count: 2) else {
      permission.cancel()
      await transport.releaseBlockedRequest()
      _ = await follow.result
      return XCTFail("Permission operation did not wait for follow")
    }
    let blockedRequestCount = await transport.requestCount()
    XCTAssertEqual(blockedRequestCount, 2)
    await transport.releaseBlockedRequest()
    let followResult = try await follow.value
    let permissionResult = try await permission.value
    XCTAssertTrue(followResult.isFollowed)
    XCTAssertEqual(permissionResult.permissions, permissions())
    let snapshot = await transport.snapshot()
    XCTAssertFalse(snapshot.requests.contains { $0.url?.path == "/c/c/user/setUserBlack" })
  }

  func testFollowWriteWaitsForPermissionsAndThenOnlyReadsRelationship() async throws {
    let desired = permissions(follow: true, interaction: true)
    let responses = successfulWriteResponses(desired: desired) + [
      .init(body: try profileData(isFollowed: 0)),
    ]
    let transport = PermissionStubTransport(responses: responses, blockedRequestIndex: 3)
    let client = TiebaAuthenticatedClient(transport: transport)
    let permission = permissionWriteTask(client: client, desired: desired)
    guard await transport.waitUntilRequestCount(4) else {
      permission.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Permission write did not dispatch")
    }
    let follow = Task {
      try await client.setUserFollowState(
        credential: sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await waitUntilPermissionWaiterCount(client, count: 2) else {
      follow.cancel()
      await transport.releaseBlockedRequest()
      _ = await permission.result
      return XCTFail("Follow operation did not wait for permissions")
    }
    let blockedRequestCount = await transport.requestCount()
    XCTAssertEqual(blockedRequestCount, 4)
    await transport.releaseBlockedRequest()
    let permissionResult = try await permission.value
    let followResult = try await follow.value
    XCTAssertEqual(permissionResult.permissions, desired)
    XCTAssertFalse(followResult.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertFalse(snapshot.requests.contains {
      $0.url?.path == "/c/c/user/follow" || $0.url?.path == "/c/c/user/unfollow"
    })
  }

  private func successfulWriteResponses(
    desired: TiebaUserInteractionPermissions,
    omittingReadback: Bool = false
  ) -> [PermissionStubTransport.Response] {
    var responses: [PermissionStubTransport.Response] = [
      .init(body: try! profileData()),
      .init(body: permissionBody()),
      .init(body: try! profileData(tbs: freshTBS)),
      .init(body: Data(#"{"error_code":0}"#.utf8)),
    ]
    if !omittingReadback { responses.append(.init(body: permissionBody(desired))) }
    return responses
  }

  private func permissionWriteTask(
    client: TiebaAuthenticatedClient,
    credential: TiebaSessionCredential? = nil,
    targetUserID: Int64? = nil,
    desired: TiebaUserInteractionPermissions
  ) -> Task<TiebaUserInteractionPermissionState, Swift.Error> {
    Task {
      try await client.setUserInteractionPermissions(
        credential: credential ?? sessionCredential(),
        expectedUserID: accountID,
        targetUserID: targetUserID ?? targetID,
        permissions: desired
      )
    }
  }

  private func profileData(
    targetUserID: Int64? = nil,
    isFollowed: Int32 = 0,
    tbs: String? = nil
  ) throws -> Data {
    try ProtoFixtures.userRelationship(
      targetUserID: targetUserID ?? self.targetID,
      isFollowed: isFollowed,
      tbs: tbs ?? initialTBS
    ).serializedData()
  }

  private func permissions(
    follow: Bool = false,
    interaction: Bool = false,
    chat: Bool = false
  ) -> TiebaUserInteractionPermissions {
    TiebaUserInteractionPermissions(
      blocksFollow: follow,
      blocksInteraction: interaction,
      blocksChat: chat
    )
  }

  private func permissionBody(
    _ value: TiebaUserInteractionPermissions,
    suffix: String = ""
  ) -> Data {
    permissionBody(
      follow: value.blocksFollow ? 1 : 0,
      interaction: value.blocksInteraction ? 1 : 0,
      chat: value.blocksChat ? 1 : 0,
      suffix: suffix
    )
  }

  private func permissionBody(
    follow: Int = 0,
    interaction: Int = 0,
    chat: Int = 0,
    suffix: String = ""
  ) -> Data {
    Data(
      "{\"error_code\":0,\"perm_list\":{\"follow\":\(follow),\"interact\":\(interaction),\"chat\":\(chat)}\(suffix)}".utf8
    )
  }

  private func sessionCredential(
    bdussCharacter: String = "b",
    stokenCharacter: String = "s"
  ) -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: bdussCharacter, count: 192),
      stoken: String(repeating: stokenCharacter, count: 64),
      bdussCookieName: .bduss
    )
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    let text = try XCTUnwrap(String(data: body, encoding: .utf8))
    var components = URLComponents()
    components.scheme = "https"
    components.host = "example.invalid"
    components.percentEncodedQuery = text
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }

  private func waitUntilPermissionWaiterCount(
    _ client: TiebaAuthenticatedClient,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    await waitUntil(timeout: timeout) {
      await client.userInteractionPermissionsWaiterCount(
        expectedUserID: self.accountID,
        targetUserID: self.targetID
      ) == count
    }
  }

  private func waitUntilFollowWaiterCount(
    _ client: TiebaAuthenticatedClient,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    await waitUntil(timeout: timeout) {
      await client.userFollowWaiterCount(
        expectedUserID: self.accountID,
        targetUserID: self.targetID
      ) == count
    }
  }

  private func waitUntilPermissionFlightGone(
    _ client: TiebaAuthenticatedClient,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    await waitUntil(timeout: timeout) {
      !(await client.userInteractionPermissionsFlightExists(
        expectedUserID: self.accountID,
        targetUserID: self.targetID
      ))
    }
  }

  private func waitUntil(
    timeout: Duration,
    condition: () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return true }
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return false
  }

  private func assertCancellation<T>(_ task: Task<T, Swift.Error>) async {
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
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
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor PermissionStubTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int
    let error: TiebaClientError?

    init(body: Data = Data(), statusCode: Int = 200, error: TiebaClientError? = nil) {
      self.body = body
      self.statusCode = statusCode
      self.error = error
    }
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Response]
  private let blockedRequestIndex: Int?
  private var capturedRequests = [URLRequest]()
  private var capturedMaximumBodyBytes = [Int?]()
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

  init(responses: [Response], blockedRequestIndex: Int? = nil) {
    self.responses = responses
    self.blockedRequestIndex = blockedRequestIndex
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(_ request: URLRequest, maximumBodyBytes: Int?) async throws -> TiebaHTTPResponse {
    let index = capturedRequests.count
    guard responses.indices.contains(index) else { throw TiebaClientError.transportFailure }
    capturedRequests.append(request)
    capturedMaximumBodyBytes.append(maximumBodyBytes)
    let response = responses[index]
    if index == blockedRequestIndex, !isBlockedRequestReleased {
      await withCheckedContinuation { continuation in
        if isBlockedRequestReleased {
          continuation.resume()
        } else {
          blockedContinuation = continuation
        }
      }
    }
    if let error = response.error { throw error }
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
  }

  func waitUntilRequestCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while capturedRequests.count < count, clock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return capturedRequests.count >= count
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }

  func requestCount() -> Int { capturedRequests.count }

  func snapshot() -> Snapshot {
    Snapshot(requests: capturedRequests, maximumBodyBytes: capturedMaximumBodyBytes)
  }
}

private actor CancellablePermissionTransport: TiebaTransport {
  private var capturedRequests = [URLRequest]()

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    capturedRequests.append(request)
    try await Task.sleep(for: .seconds(30))
    throw TiebaClientError.transportFailure
  }

  func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while capturedRequests.isEmpty, clock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return !capturedRequests.isEmpty
  }

  func requests() -> [URLRequest] { capturedRequests }
}
