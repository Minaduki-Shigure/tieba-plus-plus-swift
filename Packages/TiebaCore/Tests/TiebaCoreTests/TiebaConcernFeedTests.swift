import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaConcernFeedTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let cuid = "00000000-0000-0000-0000-000000000123"

  func testRequestUsesSignedCredentialIsolatedContract() throws {
    let factory = TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(personalizedCUID: cuid)
    )
    let credential = sessionCredential()
    let request = try factory.concernFeed(
      credential: credential,
      expectedUserID: userID,
      pageTag: nil,
      lastRequestUnix: 0
    )
    let body = try XCTUnwrap(request.httpBody)
    let message = try UserLikeReqIdl(serializedBytes: protobufPayload(from: body))

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/concern/userlike?cmd=309474"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 11.10.8.6")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

    let fields = try scalarFields(from: body)
    XCTAssertEqual(Set(fields.keys), ["BDUSS", "_client_version", "stoken", "sign"])
    XCTAssertEqual(fields["BDUSS"], credential.bduss)
    XCTAssertEqual(fields["_client_version"], "11.10.8.6")
    XCTAssertEqual(fields["stoken"], credential.stoken)
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential.bduss),
          ("_client_version", "11.10.8.6"),
          ("stoken", credential.stoken),
        ]
      )
    )

    XCTAssertEqual(message.data.pageTag, "")
    XCTAssertEqual(message.data.lastReqUnix, 0)
    XCTAssertEqual(message.data.followType, 1)
    XCTAssertEqual(message.data.loadType, 1)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "11.10.8.6")
    XCTAssertEqual(message.data.common.cuid, cuid)
    XCTAssertEqual(message.data.common.netType, 1)
    XCTAssertEqual(message.data.common.bduss, credential.bduss)
    XCTAssertEqual(message.data.common.stoken, credential.stoken)
    for forbidden in [
      "_client_id", "_phone_imei", "model", "brand", "oaid", "android_id", "idfv",
      "cuid_galaxy2", "cuid_gid", "c3_aid", "device_score",
    ] {
      XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("name=\"\(forbidden)\""))
    }
    XCTAssertFalse(request.url?.absoluteString.contains(credential.bduss) ?? true)
    XCTAssertFalse(request.url?.absoluteString.contains(credential.stoken) ?? true)
  }

  func testLoadMorePreservesOpaqueCursorAndSnapshotTimestamp() throws {
    let request = try factory().concernFeed(
      credential: sessionCredential(),
      expectedUserID: userID,
      pageTag: "thread_opaque-42",
      lastRequestUnix: 1_786_269_913
    )
    let message = try UserLikeReqIdl(
      serializedBytes: protobufPayload(from: try XCTUnwrap(request.httpBody))
    )

    XCTAssertEqual(message.data.pageTag, "thread_opaque-42")
    XCTAssertEqual(message.data.lastReqUnix, 1_786_269_913)
    XCTAssertEqual(message.data.followType, 1)
    XCTAssertEqual(message.data.loadType, 2)
  }

  func testRequestRejectsInvalidIdentityCursorTimestampAndCUID() throws {
    XCTAssertThrowsError(
      try factory().concernFeed(
        credential: sessionCredential(), expectedUserID: 0, pageTag: nil, lastRequestUnix: 0
      )
    )
    for pageTag in ["", "thread\n2", String(repeating: "a", count: 4_097)] {
      XCTAssertThrowsError(
        try factory().concernFeed(
          credential: sessionCredential(),
          expectedUserID: userID,
          pageTag: pageTag,
          lastRequestUnix: 1
        )
      )
    }
    XCTAssertThrowsError(
      try factory().concernFeed(
        credential: sessionCredential(),
        expectedUserID: userID,
        pageTag: "thread_2",
        lastRequestUnix: 0
      )
    )
    XCTAssertThrowsError(
      try factory().concernFeed(
        credential: sessionCredential(),
        expectedUserID: userID,
        pageTag: nil,
        lastRequestUnix: UInt64(Int64.max) + 1
      )
    )
    let invalidCUIDFactory = TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(personalizedCUID: "not-a-uuid")
    )
    XCTAssertThrowsError(
      try invalidCUIDFactory.concernFeed(
        credential: sessionCredential(),
        expectedUserID: userID,
        pageTag: nil,
        lastRequestUnix: 0
      )
    )
  }

  func testClientMapsSupportedThreadsAndFiltersUnsafeCards() async throws {
    var response = UserLikeResIdl()
    response.data.threadInfo = [
      item(id: 1),
      item(id: 1),
      item(id: 2, recomType: 2),
      item(id: 3, threadID: 4),
      item(id: 5, forumID: 0),
      item(id: 6, isAd: true),
      item(id: 7, isLive: true),
      item(id: 8),
    ]
    response.data.pageTag = "thread_next"
    response.data.hasMore = 1
    response.data.reqUnix = 1_786_269_913
    let transport = ConcernQueueTransport(responses: [
      .init(body: try response.serializedData())
    ])
    let client = TiebaAuthenticatedClient(
      configuration: TiebaClientConfiguration(personalizedCUID: cuid),
      transport: transport
    )

    let page = try await client.getConcernFeed(
      credential: sessionCredential(),
      expectedUserID: userID
    )

    XCTAssertEqual(page.requestedUserID, userID)
    XCTAssertEqual(page.threads.map(\.id), [1, 8])
    XCTAssertEqual(page.threads.first?.forumName, "swift")
    XCTAssertEqual(page.threads.first?.author?.preferredName, "Author 1")
    XCTAssertEqual(page.nextPageTag, "thread_next")
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.requestUnix, 1_786_269_913)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, ["/c/f/concern/userlike"])
    XCTAssertEqual(snapshot.maximumBodyBytes, [TiebaAuthenticatedClient.concernResponseMaximumBytes])
  }

  func testClientRejectsInvalidEnvelopePaginationAndOversizedBody() async throws {
    var serverError = validResponse()
    serverError.error.errorno = 7
    serverError.error.errmsg = "denied"
    await assertError(.server(code: 7, message: "denied"), response: serverError)

    var invalidFlag = validResponse()
    invalidFlag.data.hasMore = 2
    await assertError(.invalidAuthenticatedResponse, response: invalidFlag)

    var missingCursor = validResponse()
    missingCursor.data.pageTag = ""
    await assertError(.invalidAuthenticatedResponse, response: missingCursor)

    var stalledCursor = validResponse()
    stalledCursor.data.pageTag = "same"
    await assertError(
      .invalidAuthenticatedResponse,
      response: stalledCursor,
      requestedPageTag: "same"
    )

    var invalidTimestamp = validResponse()
    invalidTimestamp.data.reqUnix = 0
    await assertError(.invalidAuthenticatedResponse, response: invalidTimestamp)

    var excessiveItems = validResponse()
    excessiveItems.data.threadInfo = (1...101).map { item(id: Int64($0)) }
    await assertError(.invalidAuthenticatedResponse, response: excessiveItems)

    let oversized = Data(
      repeating: 0,
      count: TiebaAuthenticatedClient.concernResponseMaximumBytes + 1
    )
    let oversizedClient = TiebaAuthenticatedClient(
      transport: ConcernQueueTransport(responses: [.init(body: oversized)])
    )
    await assertClientError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.concernResponseMaximumBytes)
    ) {
      _ = try await oversizedClient.getConcernFeed(
        credential: self.sessionCredential(), expectedUserID: self.userID
      )
    }
  }

  func testLoginTipUsesSessionProbeBeforeClassifyingEmptyPage() async throws {
    let envelope = loginTipResponse()
    let validTransport = ConcernQueueTransport(responses: [
      .init(body: try envelope.serializedData()),
      .init(body: appAccountBody()),
      .init(body: webAccountBody(userID: userID)),
    ])
    let validClient = TiebaAuthenticatedClient(transport: validTransport)

    let page = try await validClient.getConcernFeed(
      credential: sessionCredential(), expectedUserID: userID
    )

    XCTAssertTrue(page.threads.isEmpty)
    XCTAssertFalse(page.hasMore)
    let validSnapshot = await validTransport.snapshot()
    XCTAssertEqual(
      validSnapshot.requests.map { $0.url?.path },
      ["/c/f/concern/userlike", "/c/s/login", "/mo/q/newmoindex"]
    )

    let expiredTransport = ConcernQueueTransport(responses: [
      .init(body: try envelope.serializedData()),
      .init(body: Data("{\"error_code\":1,\"error_msg\":\"expired\"}".utf8)),
    ])
    let expiredClient = TiebaAuthenticatedClient(transport: expiredTransport)
    await assertClientError(.invalidAuthenticatedResponse) {
      _ = try await expiredClient.getConcernFeed(
        credential: self.sessionCredential(), expectedUserID: self.userID
      )
    }

    var ordinaryEmpty = envelope
    ordinaryEmpty.data.userTips = "暂时没有动态"
    let ordinaryTransport = ConcernQueueTransport(responses: [
      .init(body: try ordinaryEmpty.serializedData())
    ])
    _ = try await TiebaAuthenticatedClient(transport: ordinaryTransport).getConcernFeed(
      credential: sessionCredential(), expectedUserID: userID
    )
    let ordinarySnapshot = await ordinaryTransport.snapshot()
    let ordinaryRequestCount = ordinarySnapshot.requests.count
    XCTAssertEqual(ordinaryRequestCount, 1)
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(
      configuration: TiebaClientConfiguration(personalizedCUID: cuid)
    )
  }

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func item(
    id: Int64,
    threadID: Int64? = nil,
    forumID: Int64 = 42,
    recomType: Int32 = 1,
    isAd: Bool = false,
    isLive: Bool = false
  ) -> UserLikeResIdl.ConcernData {
    var thread = ThreadInfo()
    thread.id = id
    thread.threadID = threadID ?? id
    thread.firstPostID = id + 1_000
    thread.fid = forumID
    thread.fname = forumID > 0 ? "swift" : ""
    thread.title = "Thread \(id)"
    thread.isAd = isAd ? 1 : 0
    thread.alaInfo = isLive ? Data([0x08, 0x01]) : Data()
    thread.author.id = id + 2_000
    thread.author.nameShow = "Author \(id)"
    var result = UserLikeResIdl.ConcernData()
    result.threadList = thread
    result.recomType = recomType
    return result
  }

  private func validResponse() -> UserLikeResIdl {
    var response = UserLikeResIdl()
    response.data.threadInfo = [item(id: 1)]
    response.data.pageTag = "next"
    response.data.hasMore = 1
    response.data.reqUnix = 1_786_269_913
    return response
  }

  private func loginTipResponse() -> UserLikeResIdl {
    var response = UserLikeResIdl()
    response.data.pageTag = "thread_0"
    response.data.hasMore = 0
    response.data.userTips = "登录查看吧友最新贴子~"
    response.data.reqUnix = 1_786_269_913
    response.data.userTipsType = 1
    return response
  }

  private func appAccountBody() -> Data {
    Data(
      """
      {"error_code":0,"user":{"id":"\(userID)","name":"account","portrait":"portrait"}}
      """.utf8
    )
  }

  private func webAccountBody(userID: Int64) -> Data {
    Data("{\"no\":0,\"data\":{\"id\":\"\(userID)\"}}".utf8)
  }

  private func assertError(
    _ expected: TiebaClientError,
    response: UserLikeResIdl,
    requestedPageTag: String? = nil
  ) async {
    let body: Data
    do {
      body = try response.serializedData()
    } catch {
      XCTFail("Unable to encode response: \(error)")
      return
    }
    let client = TiebaAuthenticatedClient(
      transport: ConcernQueueTransport(responses: [.init(body: body)])
    )
    await assertClientError(expected) {
      _ = try await client.getConcernFeed(
        credential: self.sessionCredential(),
        expectedUserID: self.userID,
        pageTag: requestedPageTag,
        lastRequestUnix: requestedPageTag == nil ? 0 : 1_786_269_913
      )
    }
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

  private func scalarFields(from body: Data) throws -> [String: String] {
    let names = ["BDUSS", "_client_version", "stoken", "sign"]
    return try Dictionary(uniqueKeysWithValues: names.map { name in
      (name, try multipartValue(named: name, from: body))
    })
  }

  private func multipartValue(named name: String, from body: Data) throws -> String {
    let marker = Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
    guard let markerRange = body.range(of: marker) else {
      throw TiebaClientError.invalidProtobuf
    }
    let boundary = Data("\r\n---*_r1999".utf8)
    let tail = body[markerRange.upperBound...]
    guard let end = tail.range(of: boundary)?.lowerBound else {
      throw TiebaClientError.invalidProtobuf
    }
    return String(decoding: body[markerRange.upperBound..<end], as: UTF8.self)
  }

  private func protobufPayload(from body: Data) throws -> Data {
    let marker = Data(
      "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    guard
      let markerRange = body.range(of: marker),
      body.count >= markerRange.upperBound + suffix.count,
      body.suffix(suffix.count) == suffix
    else {
      throw TiebaClientError.invalidProtobuf
    }
    return body.subdata(in: markerRange.upperBound..<(body.count - suffix.count))
  }
}

private actor ConcernQueueTransport: TiebaTransport {
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
