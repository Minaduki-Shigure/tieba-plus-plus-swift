import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaForumMembershipTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let forumName = "swift"
  private let tbs = "91be894d01799c4991be894d01"

  func testMembershipProbeUsesAuthenticatedHTTPSProtobufFRSRequest() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.forumMembership(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: "  \(forumName)  "
    )

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/frs/page?cmd=301001"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertFalse(request.httpShouldHandleCookies)

    let message = try FrsPageReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(message.data.kw, forumName)
    XCTAssertEqual(message.data.rn, 1)
    XCTAssertEqual(message.data.rnNeed, 1)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(message.data.common.bduss, credential().bduss)
    XCTAssertTrue(message.data.common.stoken.isEmpty)
    XCTAssertTrue(message.data.common.tbs.isEmpty)
  }

  func testMembershipProbeRejectsMalformedProtobufClientVersion() {
    for clientVersion in ["", "12.64.1.1\r\nInjected: true"] {
      let factory = TiebaAuthenticatedRequestFactory(
        configuration: .init(clientVersion: clientVersion)
      )
      XCTAssertThrowsError(
        try factory.forumMembership(
          credential: credential(),
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName
        )
      )
    }
  }

  func testFollowRequestUsesExactVersionFieldsSignatureAndStaticCookie() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.setForumFollowState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs,
      isFollowed: true
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/forum/like")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 7.2.0.0")
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "fid", "kw", "tbs", "sign"]
    )
    XCTAssertEqual(fields["_client_version"], "7.2.0.0")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["kw"], forumName)
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertNil(fields["stoken"])
    XCTAssertEqual(fields["sign"], "78a77e5e664bec270acbb9d34e4a47ca")
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential().bduss),
          ("_client_version", "7.2.0.0"),
          ("fid", String(forumID)),
          ("kw", forumName),
          ("tbs", tbs),
        ]
      )
    )
  }

  func testUnfollowRequestUsesCurrentUIEndpointVersionAndUIDHeader() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.setForumFollowState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs,
      isFollowed: false
    )
    let fields = try formFields(request)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/c/forum/unfavolike"
    )
    XCTAssertEqual(fields["_client_version"], "11.10.8.6")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertNil(fields["stoken"])
    XCTAssertEqual(fields["sign"], "d4b44e7b2b55ba55c74dc5c3f56c49d2")
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "fid", "kw", "tbs", "sign"]
    )
  }

  func testMapsAuthoritativeMembershipAndKeepsTBSOutOfPublicModelAndReflection() throws {
    let response = membershipResponse(isFollowed: true)
    let context = try TiebaAuthenticatedDecoder.forumMembership(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertEqual(
      context.membership,
      TiebaForumMembership(
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        isFollowed: true
      )
    )
    XCTAssertFalse(String(describing: context.membership).contains(tbs))
    XCTAssertFalse(String(describing: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(
      Array(context.customMirror.children).contains { String(describing: $0.value).contains(tbs) }
    )
  }

  func testRejectsUIDForumAndTBSMismatches() throws {
    let uidMismatch = membershipResponse(isFollowed: false, userID: userID + 1)
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumMembership(
        from: uidMismatch,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    let forumMismatch = membershipResponse(isFollowed: false, forumID: forumID + 1)
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumMembership(
        from: forumMismatch,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    let nameMismatch = membershipResponse(isFollowed: false, forumName: "other")
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumMembership(
        from: nameMismatch,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    for invalidTBS in [String(repeating: "a", count: 25), String(repeating: "A", count: 26)] {
      let response = membershipResponse(isFollowed: false, tbs: invalidTBS)
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.forumMembership(
          from: response,
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testSetSkipsWriteWhenProbeAlreadyMatchesTargetState() async throws {
    let probe = try membershipResponse(isFollowed: true).serializedData()
    let transport = ForumMembershipStubTransport(responses: [.init(body: probe)])
    let client = TiebaAuthenticatedClient(transport: transport)

    let membership = try await client.setForumFollowState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      isFollowed: true
    )

    XCTAssertTrue(membership.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(snapshot.maximumBodyBytes, [TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes])
  }

  func testSetProbesThenSendsOneBoundedWriteWithoutRetry() async throws {
    let probe = try membershipResponse(isFollowed: false).serializedData()
    let success = Data(#"{"error_code":"0","error":{"errno":"0"}}"#.utf8)
    let transport = ForumMembershipStubTransport(
      responses: [.init(body: probe), .init(body: success)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let membership = try await client.setForumFollowState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      isFollowed: true
    )

    XCTAssertTrue(membership.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.forumFollowWriteResponseMaximumBytes,
      ]
    )
    XCTAssertEqual(snapshot.requests.last?.url?.path, "/c/c/forum/like")
  }

  func testNestedWriteErrorIsRejectedWithoutRetry() async throws {
    let probe = try membershipResponse(isFollowed: false).serializedData()
    let failure = Data(
      #"{"error_code":0,"error":{"errno":"340006","errmsg":"denied"}}"#.utf8
    )
    let transport = ForumMembershipStubTransport(
      responses: [.init(body: probe), .init(body: failure)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await client.setForumFollowState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        isFollowed: true
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
  }

  func testWriteDecoderChecksEverySupportedTopLevelErrorCodeAlias() throws {
    for key in ["error_code", "errno", "no"] {
      try TiebaAuthenticatedDecoder.checkForumFollowWriteResponse(
        Data("{\"\(key)\":\"0\"}".utf8)
      )

      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.checkForumFollowWriteResponse(
          Data("{\"\(key)\":\"123\",\"errmsg\":\"rejected\"}".utf8)
        )
      ) {
        XCTAssertEqual($0 as? TiebaClientError, .server(code: 123, message: "rejected"))
      }
    }

    for malformedCode in ["true", "1.5"] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.checkForumFollowWriteResponse(
          Data("{\"error_code\":\(malformedCode)}".utf8)
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    }
  }

  func testWriteResponseIsBoundedAt64KiB() async throws {
    let probe = try membershipResponse(isFollowed: false).serializedData()
    let oversized = Data(
      repeating: 0,
      count: TiebaAuthenticatedClient.forumFollowWriteResponseMaximumBytes + 1
    )
    let transport = ForumMembershipStubTransport(
      responses: [.init(body: probe), .init(body: oversized)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.forumFollowWriteResponseMaximumBytes
      )
    ) {
      _ = try await client.setForumFollowState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        isFollowed: true
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
  }

  func testAuthenticatedClientRejectsEveryRedirect() {
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tiebac.baidu.com/c/c/forum/like"),
        to: URL(string: "https://tiebac.baidu.com/c/c/forum/like?redirected=1")
      )
    )
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
  }

  private func membershipResponse(
    isFollowed: Bool,
    userID: Int64? = nil,
    forumID: Int64? = nil,
    forumName: String? = nil,
    tbs: String? = nil
  ) -> FrsPageResIdl {
    var user = User()
    user.id = userID ?? self.userID

    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID ?? self.forumID
    forum.name = forumName ?? self.forumName
    forum.isLike = isFollowed ? 1 : 0

    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs ?? self.tbs

    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti

    var response = FrsPageResIdl()
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

private actor ForumMembershipStubTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int

    init(body: Data, statusCode: Int = 200) {
      self.body = body
      self.statusCode = statusCode
    }
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Response]
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(responses: [Response]) {
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
    let response = responses[index]
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}
