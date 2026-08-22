import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaAuthenticatedPersonalizedTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let cuid = "00000000-0000-4000-8000-000000000222"

  func testRequestUsesBoundV12WireContractWithoutCredentialCookieOrURLLeakage() throws {
    let credential = sessionCredential()
    let request = try factory().personalizedThreads(
      credential: credential,
      expectedUserID: userID,
      page: 2
    )
    let fields = try multipartScalarFields(request)
    let message = try PersonalizedReqIdl(serializedBytes: protobufPayload(request))

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/excellent/personalized?cmd=309264"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_type"), "2")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      TiebaAuthenticatedRequestFactory.selfProfileUserAgent
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=-*_r1999"
    )
    XCTAssertEqual(
      Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
      Set([
        "accept-encoding", "client_type", "client_user_token", "content-type", "cookie",
        "user-agent", "x_bd_data_type",
      ])
    )
    XCTAssertEqual(fields, ["stoken": credential.stoken])
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

    let url = try XCTUnwrap(request.url?.absoluteString)
    let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
    for exposedSurface in [url, cookie] {
      XCTAssertFalse(exposedSurface.contains(credential.bduss))
      XCTAssertFalse(exposedSurface.contains(credential.stoken))
    }

    XCTAssertEqual(message.data.pn, 2)
    XCTAssertEqual(message.data.loadType, 2)
    XCTAssertEqual(message.data.pageThreadCount, 11)
    XCTAssertEqual(message.data.qType, 1)
    XCTAssertEqual(message.data.newNetType, 1)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "12.52.1.0")
    XCTAssertEqual(message.data.common.bduss, credential.bduss)
    XCTAssertEqual(message.data.common.stoken, credential.stoken)
    XCTAssertEqual(message.data.common.cuid, cuid)
    XCTAssertEqual(message.data.common.netType, 1)
    XCTAssertEqual(message.data.common.personalizedRecSwitch, 1)
    XCTAssertEqual(message.data.common.clientID, "")
    XCTAssertEqual(message.data.common.phoneImei, "")
    XCTAssertEqual(message.data.common.androidID, "")
    XCTAssertEqual(message.data.common.zID, "")
  }

  func testRequestEncodesRefreshPaginationAndRejectsUnboundInputs() throws {
    let first = try PersonalizedReqIdl(
      serializedBytes: protobufPayload(
        factory().personalizedThreads(
          credential: sessionCredential(),
          expectedUserID: userID,
          page: 1
        )
      )
    )
    XCTAssertEqual(first.data.pn, 1)
    XCTAssertEqual(first.data.loadType, 1)

    for invalidPage in [0, -1, Int(Int32.max) + 1] {
      XCTAssertThrowsError(
        try factory().personalizedThreads(
          credential: sessionCredential(),
          expectedUserID: userID,
          page: invalidPage
        )
      )
    }
    XCTAssertThrowsError(
      try factory().personalizedThreads(
        credential: sessionCredential(),
        expectedUserID: 0,
        page: 1
      )
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedRequestFactory(
        configuration: .init(personalizedCUID: "not-a-uuid")
      ).personalizedThreads(
        credential: sessionCredential(),
        expectedUserID: userID,
        page: 1
      )
    )
    XCTAssertThrowsError(
      try factory().personalizedThreads(
        credential: TiebaSessionCredential(
          bduss: "short",
          stoken: String(repeating: "s", count: 64),
          bdussCookieName: .bduss
        ),
        expectedUserID: userID,
        page: 1
      )
    )
  }

  func testClientAppliesLimitDecodesAndMapsAuthenticatedPage() async throws {
    var response = PersonalizedResIdl()
    response.data.threadList = [personalizedThread(id: 100)]
    let transport = AuthenticatedPersonalizedTransport(
      response: .init(body: try response.serializedData())
    )
    let client = TiebaAuthenticatedClient(
      configuration: .init(personalizedCUID: cuid),
      transport: transport
    )

    let page = try await client.getPersonalizedThreads(
      credential: sessionCredential(),
      expectedUserID: userID,
      page: 2
    )

    XCTAssertEqual(page.currentPage, 2)
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.items.map(\.id), [100])
    XCTAssertEqual(page.items.first?.thread.forumName, "swift")
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      TiebaAuthenticatedClient.personalizedResponseMaximumBytes
    )
    let request = try XCTUnwrap(snapshot.request)
    let message = try PersonalizedReqIdl(serializedBytes: protobufPayload(request))
    XCTAssertEqual(message.data.pn, 2)
    XCTAssertEqual(message.data.common.bduss, sessionCredential().bduss)
  }

  func testClientPreservesServerDecodeHTTPAndResponseLimitFailures() async throws {
    var rejected = PersonalizedResIdl()
    rejected.error.errorno = 4
    rejected.error.errmsg = "feed unavailable"
    await assertError(.server(code: 4, message: "feed unavailable")) {
      _ = try await self.client(body: try rejected.serializedData()).getPersonalizedThreads(
        credential: self.sessionCredential(),
        expectedUserID: self.userID
      )
    }
    await assertError(.invalidProtobuf) {
      _ = try await self.client(body: Data([0x0A])).getPersonalizedThreads(
        credential: self.sessionCredential(),
        expectedUserID: self.userID
      )
    }
    await assertError(.httpStatus(503)) {
      _ = try await self.client(body: Data(), statusCode: 503).getPersonalizedThreads(
        credential: self.sessionCredential(),
        expectedUserID: self.userID
      )
    }
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.personalizedResponseMaximumBytes)
    ) {
      _ = try await self.client(
        body: Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.personalizedResponseMaximumBytes + 1
        )
      ).getPersonalizedThreads(
        credential: self.sessionCredential(),
        expectedUserID: self.userID
      )
    }
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init(personalizedCUID: cuid))
  }

  private func client(body: Data, statusCode: Int = 200) -> TiebaAuthenticatedClient {
    TiebaAuthenticatedClient(
      configuration: .init(personalizedCUID: cuid),
      transport: AuthenticatedPersonalizedTransport(
        response: .init(body: body, statusCode: statusCode)
      )
    )
  }

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func personalizedThread(id: Int64) -> ThreadInfo {
    var thread = ThreadInfo()
    thread.id = id
    thread.threadID = id
    thread.firstPostID = id + 1_000
    thread.fid = 10
    thread.fname = "swift"
    thread.title = "Thread \(id)"
    thread.replyNum = 5
    thread.viewNum = 20
    return thread
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
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func multipartScalarFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    let dataPartMarker = Data(
      "--\(TiebaRequestFactory.multipartBoundary)\r\n"
        .appending("Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n")
        .utf8
    )
    let dataPartRange = try XCTUnwrap(body.range(of: dataPartMarker))
    let scalarBytes = body[..<dataPartRange.lowerBound]
    let fieldNamePrefix = "Content-Disposition: form-data; name=\""
    let fieldNameSuffix = "\"\r\n\r\n"
    let text = try XCTUnwrap(String(data: scalarBytes, encoding: .utf8))
    var fields = [String: String]()
    for part in text.components(separatedBy: "--\(TiebaRequestFactory.multipartBoundary)\r\n") {
      guard
        part.hasPrefix(fieldNamePrefix),
        let nameEnd = part.range(of: fieldNameSuffix)
      else { continue }
      let nameStart = part.index(part.startIndex, offsetBy: fieldNamePrefix.count)
      let name = String(part[nameStart..<nameEnd.lowerBound])
      let value = String(part[nameEnd.upperBound...]).trimmingCharacters(in: .newlines)
      XCTAssertNil(fields[name])
      fields[name] = value
    }
    return fields
  }

  private func protobufPayload(_ request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let marker = Data(
      "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    let range = try XCTUnwrap(body.range(of: marker))
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    return body.subdata(in: range.upperBound..<(body.count - suffix.count))
  }
}

private actor AuthenticatedPersonalizedTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int

    init(body: Data, statusCode: Int = 200) {
      self.body = body
      self.statusCode = statusCode
    }
  }

  struct Snapshot: Sendable {
    let request: URLRequest?
    let maximumBodyBytes: Int?
  }

  private let response: Response
  private var request: URLRequest?
  private var maximumBodyBytes: Int?

  init(response: Response) {
    self.response = response
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    self.request = request
    self.maximumBodyBytes = maximumBodyBytes
    if let maximumBodyBytes, response.body.count > maximumBodyBytes {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
  }

  func snapshot() -> Snapshot {
    Snapshot(request: request, maximumBodyBytes: maximumBodyBytes)
  }
}
