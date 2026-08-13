import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaReportPageRequestFactoryTests: XCTestCase {
  func testRequestUsesExactCredentialFreeFieldSet() throws {
    let request = try TiebaRequestFactory(configuration: .init()).reportPage(postID: 123_456)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://c.tieba.baidu.com/c/f/ueg/checkjubao"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
      "category=1&pid=123456"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept"),
      "application/json, application/x-javascript"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

    let fields = try reportFormFields(request)
    XCTAssertEqual(fields, ["category": "1", "pid": "123456"])
    for forbidden in [
      "sign", "BDUSS", "bdusstoken", "stoken", "CUID", "tieba_cuid", "IMEI",
      "phone_imei", "client_id", "client_user_token", "user_id", "model", "net_type",
    ] {
      XCTAssertNil(fields[forbidden], forbidden)
    }
  }

  func testRequestRejectsInvalidIDAndHeaderInjection() throws {
    let factory = TiebaRequestFactory(configuration: .init())
    for postID: Int64 in [Int64.min, -1, 0] {
      XCTAssertThrowsError(try factory.reportPage(postID: postID)) {
        XCTAssertEqual(
          $0 as? TiebaClientError,
          .invalidArgument("Post ID must be positive.")
        )
      }
    }

    let injected = TiebaRequestFactory(
      configuration: .init(userAgent: "client\r\nCookie: secret")
    )
    XCTAssertThrowsError(try injected.reportPage(postID: 1))
  }

  func testEndpointPolicyRequiresExactHTTPSOriginAndPath() throws {
    XCTAssertTrue(
      TiebaReportPagePolicy.allowsEndpoint(
        URL(string: "https://c.tieba.baidu.com/c/f/ueg/checkjubao")
      )
    )
    for rawValue in [
      "http://c.tieba.baidu.com/c/f/ueg/checkjubao",
      "https://c.tieba.baidu.com:443/c/f/ueg/checkjubao",
      "https://user@c.tieba.baidu.com/c/f/ueg/checkjubao",
      "https://c.tieba.baidu.com.evil.example/c/f/ueg/checkjubao",
      "https://c.tieba.baidu.com/c/f/ueg/checkjubao?x=1",
      "https://c.tieba.baidu.com/c/f/ueg/checkjubao#fragment",
      "https://c.tieba.baidu.com/c/f/ueg/%63heckjubao",
    ] {
      XCTAssertFalse(TiebaReportPagePolicy.allowsEndpoint(URL(string: rawValue)), rawValue)
    }
  }
}

final class TiebaReportPageDecoderTests: XCTestCase {
  func testDecoderCanonicalizesVerifiedHTTPReportURLToHTTPS() throws {
    let page = try TiebaReportPageDecoder.page(
      from: successBody(postID: 123, scheme: "http"),
      expectedPostID: 123
    )

    XCTAssertEqual(page.postID, 123)
    XCTAssertEqual(
      page.url.absoluteString,
      "https://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=123&from=threadPost&noshare=1&loadingSignal=1"
    )
  }

  func testDecoderAcceptsStringZeroAndQueryOrderButRebuildsCanonicalOrder() throws {
    let rawURL =
      "https://tieba.baidu.com/tpl/wise-bawu-core/report?loadingSignal=1&noshare=1&from=threadPost&post_id=7&type=2"
    let body = Data("""
      {"errno":"0","errmsg":"","data":{"url":"\(rawURL)"}}
      """.utf8)

    let page = try TiebaReportPageDecoder.page(from: body, expectedPostID: 7)

    XCTAssertEqual(
      page.url.absoluteString,
      "https://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1"
    )
  }

  func testDecoderMapsServerErrorWithoutRequiringData() throws {
    let body = Data(#"{"errno":4,"errmsg":"denied"}"#.utf8)

    XCTAssertThrowsError(try TiebaReportPageDecoder.page(from: body, expectedPostID: 1)) {
      XCTAssertEqual($0 as? TiebaClientError, .server(code: 4, message: "denied"))
    }
  }

  func testDecoderRejectsUntrustedReportURLVariants() throws {
    let validPath = "/tpl/wise-bawu-core/report"
    let invalidURLs = [
      "ftp://tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com.evil.example\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com:443\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://user@tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1#x",
      "https://tieba.baidu.com/tpl/wise-bawu-core/%72eport?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com/tpl/wise-bawu-core%2Freport?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=8&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1&extra=1",
      "https://tieba.baidu.com\(validPath)?type=2&type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=7&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?%74ype=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=%32&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      "https://tieba.baidu.com\(validPath)?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1?",
      "https://tieba.baidu.com\(validPath)?&&&&",
    ]

    for rawURL in invalidURLs {
      assertInvalidJSON(responseBody(rawURL: rawURL), expectedPostID: 7, rawURL)
    }
  }

  func testDecoderRejectsControlsBackslashesAndOversizedRawURL() throws {
    let prefix =
      "https://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1"
    for rawURL in [
      prefix + "\n",
      "https:\\tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1",
      prefix + String(repeating: "a", count: TiebaReportPagePolicy.maximumRawURLBytes),
    ] {
      assertInvalidJSON(responseBody(rawURL: rawURL), expectedPostID: 7, rawURL)
    }
  }

  func testDecoderRejectsDuplicateJSONKeysIncludingEscapedEquivalent() throws {
    let url =
      "https://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=7&from=threadPost&noshare=1&loadingSignal=1"
    let bodies = [
      #"{"errno":0,"errno":4,"errmsg":"","data":{"url":"https://tieba.baidu.com/"}}"#,
      #"{"errno":0,"\u0065rrno":4,"errmsg":"","data":{"url":"https://tieba.baidu.com/"}}"#,
      "{\"errno\":0,\"errmsg\":\"\",\"data\":{\"url\":\"\(url)\",\"url\":\"https://evil.example/\"}}",
    ]
    for body in bodies {
      assertInvalidJSON(Data(body.utf8), expectedPostID: 7, body)
    }
  }

  func testDecoderRejectsMalformedEnvelopeAndInvalidExpectedID() throws {
    let bodies = [
      Data("not-json".utf8),
      Data(#"{"errno":true,"errmsg":"","data":{"url":"x"}}"#.utf8),
      Data(#"{"errno":0,"errmsg":""}"#.utf8),
      Data(#"{"errno":0,"errmsg":1,"data":{"url":"x"}}"#.utf8),
      Data(#"{"errno":0,"errmsg":"","data":{"url":1}}"#.utf8),
    ]
    for body in bodies {
      assertInvalidJSON(body, expectedPostID: 7)
    }
    assertInvalidJSON(successBody(postID: 7), expectedPostID: 0)
  }

  func testDecoderRejectsExcessiveJSONNestingBeforeFoundationDecode() throws {
    let depth = 65
    let body = Data(
      (String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth))
        .utf8
    )
    assertInvalidJSON(body, expectedPostID: 7)
  }

  private func assertInvalidJSON(
    _ body: Data,
    expectedPostID: Int64,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TiebaReportPageDecoder.page(from: body, expectedPostID: expectedPostID),
      message,
      file: file,
      line: line
    ) {
      XCTAssertEqual($0 as? TiebaClientError, .invalidJSON, file: file, line: line)
    }
  }
}

final class TiebaReportPageClientTests: XCTestCase {
  func testClientUsesDedicatedTransportAndDecodesResponse() async throws {
    let ordinary = ReportPageCapturingTransport(body: Data(), error: .transportFailure)
    let report = ReportPageCapturingTransport(body: successBody(postID: 99))
    let client = TiebaClient(transport: ordinary, reportPageTransport: report)

    let page = try await client.getReportPage(postID: 99)

    XCTAssertEqual(page.postID, 99)
    let ordinaryCalls = await ordinary.callCount()
    let reportCalls = await report.callCount()
    XCTAssertEqual(ordinaryCalls, 0)
    XCTAssertEqual(reportCalls, 1)
    let request = await report.lastRequest()
    XCTAssertEqual(request?.url?.absoluteString, "https://c.tieba.baidu.com/c/f/ueg/checkjubao")
    XCTAssertFalse(request?.httpShouldHandleCookies ?? true)
  }

  func testClientDispatches64KiBLimitAndRejectsOversizedResponse() async throws {
    let transport = ReportPageCapturingTransport(body: successBody(postID: 1))
    let client = TiebaClient(transport: transport)

    _ = try await client.getReportPage(postID: 1)

    let limits = await transport.maximumBodyBytes()
    XCTAssertEqual(limits, [TiebaReportPagePolicy.maximumResponseBodyBytes])

    let oversized = TiebaClient(
      transport: ReportPageCapturingTransport(
        body: Data(count: TiebaReportPagePolicy.maximumResponseBodyBytes + 1)
      )
    )
    await assertClientError(
      .responseTooLarge(maximumBytes: TiebaReportPagePolicy.maximumResponseBodyBytes)
    ) {
      _ = try await oversized.getReportPage(postID: 1)
    }
  }

  func testClientMapsHTTPAndMalformedResponseErrors() async throws {
    let badStatus = TiebaClient(
      transport: ReportPageCapturingTransport(body: Data(), statusCode: 503)
    )
    await assertClientError(.httpStatus(503)) {
      _ = try await badStatus.getReportPage(postID: 1)
    }

    let malformed = TiebaClient(
      transport: ReportPageCapturingTransport(body: Data("bad".utf8))
    )
    await assertClientError(.invalidJSON) {
      _ = try await malformed.getReportPage(postID: 1)
    }
  }

  func testRejectAllRedirectPolicyNeverAllowsReportRedirect() throws {
    let source = try XCTUnwrap(URL(string: "https://c.tieba.baidu.com/c/f/ueg/checkjubao"))
    let sameOrigin = try XCTUnwrap(URL(string: "https://c.tieba.baidu.com/other"))
    XCTAssertFalse(TiebaRedirectPolicy.rejectAll.allows(from: source, to: sameOrigin))
    XCTAssertFalse(TiebaRedirectPolicy.rejectAll.allows(from: source, to: source))
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
}

private actor ReportPageCapturingTransport: TiebaTransport {
  private let body: Data
  private let statusCode: Int
  private let error: TiebaClientError?
  private var request: URLRequest?
  private var calls = 0
  private var limits = [Int?]()

  init(body: Data, statusCode: Int = 200, error: TiebaClientError? = nil) {
    self.body = body
    self.statusCode = statusCode
    self.error = error
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    calls += 1
    self.request = request
    if let error { throw error }
    return TiebaHTTPResponse(body: body, statusCode: statusCode)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    calls += 1
    self.request = request
    limits.append(maximumBodyBytes)
    if let error { throw error }
    if let maximumBodyBytes, body.count > maximumBodyBytes {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return TiebaHTTPResponse(body: body, statusCode: statusCode)
  }

  func lastRequest() -> URLRequest? { request }
  func callCount() -> Int { calls }
  func maximumBodyBytes() -> [Int?] { limits }
}

private func successBody(postID: Int64, scheme: String = "https") -> Data {
  responseBody(
    rawURL:
      "\(scheme)://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=\(postID)&from=threadPost&noshare=1&loadingSignal=1"
  )
}

private func responseBody(rawURL: String) -> Data {
  (try? JSONSerialization.data(withJSONObject: [
    "errno": 0,
    "errmsg": "",
    "data": ["url": rawURL],
  ])) ?? Data()
}

private func reportFormFields(_ request: URLRequest) throws -> [String: String] {
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
