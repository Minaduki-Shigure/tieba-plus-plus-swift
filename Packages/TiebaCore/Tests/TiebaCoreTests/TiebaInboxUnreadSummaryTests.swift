import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaInboxUnreadSummaryTests: XCTestCase {
  private let userID: Int64 = 957_339_815

  func testRequestUsesOnlyMinimalSignedHTTPSForm() throws {
    let request = try factory().inboxUnreadSummary(
      credential: credential(),
      expectedUserID: userID
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/s/msg")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 8.2.2")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertEqual(Set(fields.keys), ["BDUSS", "_client_version", "bookmark", "sign"])
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "8.2.2")
    XCTAssertEqual(fields["bookmark"], "1")
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential().bduss),
          ("_client_version", "8.2.2"),
          ("bookmark", "1"),
        ]
      )
    )

    for forbidden in [
      "STOKEN", "stoken", "tbs", "Cookie", "cookie", "CUID", "cuid", "IMEI", "imei",
      "_phone_imei", "android_id", "idfv", "model", "scr_w", "scr_h", "timestamp",
      "_client_id", "_client_type", "net_type", "from", "stErrorNums", "stMethod",
      "stMode", "stTimesNum", "stTime", "stSize",
    ] {
      XCTAssertNil(fields[forbidden], "Unexpected field \(forbidden)")
    }
  }

  func testRequestRejectsInvalidCredentialAndExpectedUserID() {
    XCTAssertThrowsError(
      try factory().inboxUnreadSummary(
        credential: TiebaBDUSSCredential(bduss: "short"),
        expectedUserID: userID
      )
    )
    XCTAssertThrowsError(
      try factory().inboxUnreadSummary(
        credential: credential(),
        expectedUserID: 0
      )
    )
  }

  func testDecoderAcceptsIntegerAndDecimalStringCounts() throws {
    let summary = try decode(
      #"{"error_code":"0","message":{"replyme":"12","atme":3,"fans":"4"}}"#
    )

    XCTAssertEqual(summary.userID, userID)
    XCTAssertEqual(summary.replyCount, 12)
    XCTAssertEqual(summary.mentionCount, 3)
    XCTAssertEqual(summary.fanCount, 4)
    XCTAssertEqual(summary.totalCount, 15)
  }

  func testDecoderPreservesMissingOrNullFansAsUnavailable() throws {
    for raw in [
      #"{"error_code":0,"message":{"replyme":0,"atme":"0"}}"#,
      #"{"error_code":0,"message":{"replyme":0,"atme":"0","fans":null}}"#,
    ] {
      let summary = try decode(raw)
      XCTAssertEqual(summary.replyCount, 0)
      XCTAssertEqual(summary.mentionCount, 0)
      XCTAssertNil(summary.fanCount)
      XCTAssertEqual(summary.totalCount, 0)
    }
  }

  func testDecoderPreservesExplicitZeroFansAsAvailable() throws {
    let summary = try decode(
      #"{"error_code":0,"message":{"replyme":0,"atme":0,"fans":0}}"#
    )

    XCTAssertEqual(summary.fanCount, 0)
  }

  func testDecoderAcceptsMaximumBoundedCount() throws {
    let maximum = Int32.max
    let body =
      "{\"error_code\":0,\"message\":{\"replyme\":\(maximum),"
      + "\"atme\":\"\(maximum)\",\"fans\":\(maximum)}}"
    let summary = try decode(
      body
    )

    XCTAssertEqual(summary.replyCount, Int(maximum))
    XCTAssertEqual(summary.mentionCount, Int(maximum))
    XCTAssertEqual(summary.fanCount, Int(maximum))
    XCTAssertEqual(summary.totalCount, Int(maximum) * 2)
  }

  func testDecoderRejectsMissingRequiredCountsAndMalformedEnvelope() {
    let bodies = [
      #"{}"#,
      #"[]"#,
      #"{"error_code":0}"#,
      #"{"error_code":0,"message":null}"#,
      #"{"error_code":0,"message":[]}"#,
      #"{"error_code":0,"message":{"atme":0}}"#,
      #"{"error_code":0,"message":{"replyme":0}}"#,
      #"{"error_code":0,"message":{"replyme":null,"atme":0}}"#,
      #"{"error_code":0,"message":{"replyme":0,"atme":null}}"#,
      #"not-json"#,
    ]

    for body in bodies {
      XCTAssertThrowsError(try decode(body), "Expected rejection for \(body)")
    }
  }

  func testDecoderRejectsBooleansFloatsNegativeOverflowAndNonDecimalStrings() {
    let invalidValues = [
      "true", "false", "1.0", "1e0", "-1", "2147483648", "\"-1\"", "\"+1\"",
      "\" 1\"", "\"1 \"", "\"1.0\"", "\"1e0\"", "\"\"",
      "\"9223372036854775808\"", "[]", "{}",
    ]

    for value in invalidValues {
      for key in ["replyme", "atme", "fans"] {
        let fanSuffix = key == "fans" ? ",\"fans\":\(value)" : ""
        let reply = key == "replyme" ? value : "0"
        let mention = key == "atme" ? value : "0"
        let raw =
          "{\"error_code\":0,\"message\":{\"replyme\":\(reply),\"atme\":\(mention)\(fanSuffix)}}"
        XCTAssertThrowsError(try decode(raw), "Expected rejection for \(key)=\(value)")
      }
    }
  }

  func testDecoderMapsServerErrorAndRejectsMalformedErrorCode() {
    XCTAssertThrowsError(
      try decode(#"{"error_code":"7","error_msg":"denied"}"#)
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 7, message: "denied"))
    }

    for raw in [
      #"{"error_code":true,"message":{"replyme":0,"atme":0}}"#,
      #"{"error_code":0.0,"message":{"replyme":0,"atme":0}}"#,
      #"{"error_code":"zero","message":{"replyme":0,"atme":0}}"#,
    ] {
      XCTAssertThrowsError(try decode(raw))
    }
  }

  func testDecoderRejectsInvalidExpectedUserID() {
    XCTAssertThrowsError(
      try TiebaInboxUnreadSummaryDecoder.summary(
        from: Data(#"{"error_code":0,"message":{"replyme":0,"atme":0}}"#.utf8),
        expectedUserID: 0
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidAuthenticatedResponse)
    }
  }

  func testClientBindsExpectedUserIDAndUsesEndpointLimit() async throws {
    let transport = InboxUnreadSummaryStubTransport(
      body: Data(#"{"error_code":0,"message":{"replyme":"2","atme":"3"}}"#.utf8)
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let summary = try await client.getInboxUnreadSummary(
      credential: credential(),
      expectedUserID: userID
    )

    XCTAssertEqual(summary.userID, userID)
    XCTAssertEqual(summary.replyCount, 2)
    XCTAssertEqual(summary.mentionCount, 3)
    XCTAssertNil(summary.fanCount)
    XCTAssertEqual(summary.totalCount, 5)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [TiebaAuthenticatedClient.inboxUnreadSummaryResponseMaximumBytes]
    )
  }

  func testClientRejectsOversizedBody() async {
    let transport = InboxUnreadSummaryStubTransport(
      body: Data(
        repeating: 0,
        count: TiebaAuthenticatedClient.inboxUnreadSummaryResponseMaximumBytes + 1
      )
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.inboxUnreadSummaryResponseMaximumBytes
      )
    ) {
      _ = try await client.getInboxUnreadSummary(
        credential: credential(),
        expectedUserID: userID
      )
    }
  }

  private func decode(_ body: String) throws -> TiebaInboxUnreadSummary {
    try TiebaInboxUnreadSummaryDecoder.summary(
      from: Data(body.utf8),
      expectedUserID: userID
    )
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
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

private actor InboxUnreadSummaryStubTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let body: Data
  private let statusCode: Int
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(body: Data, statusCode: Int = 200) {
    self.body = body
    self.statusCode = statusCode
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
    return TiebaHTTPResponse(body: body, statusCode: statusCode)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}
