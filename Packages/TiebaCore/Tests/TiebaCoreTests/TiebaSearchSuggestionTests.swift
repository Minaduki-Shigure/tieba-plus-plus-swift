import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaSearchSuggestionTests: XCTestCase {
  private let factory = TiebaRequestFactory(configuration: .init())

  func testRequestUsesExactMinimalAnonymousWireContract() throws {
    let request = try factory.searchSuggestions(query: " swift ")
    let payload = try protobufPayload(from: request)
    let expectedWire = Data([
      0x0A, 0x0A, 0x12, 0x05, 0x73, 0x77, 0x69, 0x66, 0x74, 0x1A, 0x01, 0x30,
    ])
    let decoded = try SearchSugReqIdl(serializedBytes: payload)

    XCTAssertEqual(payload, expectedWire)
    XCTAssertEqual(decoded.data.word, "swift")
    XCTAssertEqual(decoded.data.isforum, "0")
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
    XCTAssertEqual(request.url?.path, "/c/s/searchSug")
    XCTAssertEqual(request.url?.query, "cmd=309438")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=-*_r1999"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    XCTAssertEqual(
      Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
      Set(["accept-encoding", "content-type", "user-agent", "x_bd_data_type"])
    )
  }

  func testRequestAcceptsCharacterAndUTF8Boundaries() throws {
    let twoCharacters = try decodedRequest(query: " áb ")
    XCTAssertEqual(twoCharacters.data.word, "áb")

    let hundredASCIICharacters = String(repeating: "x", count: 100)
    XCTAssertEqual(
      try decodedRequest(query: hundredASCIICharacters).data.word,
      hundredASCIICharacters
    )

    let fourHundredUTF8Bytes = String(repeating: "🇨🇳", count: 50)
    XCTAssertEqual(fourHundredUTF8Bytes.count, 50)
    XCTAssertEqual(fourHundredUTF8Bytes.utf8.count, 400)
    XCTAssertEqual(
      try decodedRequest(query: fourHundredUTF8Bytes).data.word,
      fourHundredUTF8Bytes
    )
  }

  func testRequestRejectsInvalidQueries() {
    let invalidQueries = [
      "",
      " x ",
      String(repeating: "x", count: 101),
      String(repeating: "🇨🇳", count: 51),
      "bad\u{0000}query",
      "bad\nquery",
    ]

    for query in invalidQueries {
      XCTAssertThrowsError(try factory.searchSuggestions(query: query), "Accepted: \(query)") {
        XCTAssertEqual(
          $0 as? TiebaClientError,
          .invalidArgument(
            "Search suggestion query must contain between 2 and 100 non-control characters and no more than 400 UTF-8 bytes."
          )
        )
      }
    }
  }

  func testRequestRejectsInvalidConfiguration() {
    let invalidFactories = [
      TiebaRequestFactory(configuration: .init(userAgent: "")),
      TiebaRequestFactory(configuration: .init(clientVersion: "")),
      TiebaRequestFactory(configuration: .init(requestTimeout: 0)),
    ]

    for invalidFactory in invalidFactories {
      XCTAssertThrowsError(try invalidFactory.searchSuggestions(query: "swift"))
    }
  }

  func testMapperFiltersBoundsAndExactlyDeduplicatesInStableOrder() {
    let fourHundredUTF8Bytes = String(repeating: "🇨🇳", count: 50)
    var data = SearchSugResIdl.DataRes()
    data.list = [
      " swift ",
      "swift",
      "Swift",
      " x ",
      "bad\u{0000}value",
      String(repeating: "x", count: 101),
      String(repeating: "🇨🇳", count: 51),
      fourHundredUTF8Bytes,
      "result-1",
      "result-2",
      "result-3",
      "result-4",
      "result-5",
      "result-6",
      "result-7",
      "result-8",
      "result-9",
    ]

    let result = TiebaProtoMapper.searchSuggestions(data)

    XCTAssertEqual(
      result,
      [
        "swift", "Swift", "x", fourHundredUTF8Bytes, "result-1", "result-2",
        "result-3", "result-4", "result-5", "result-6",
      ]
    )
    XCTAssertTrue(result.contains("x"), "A valid one-character server suggestion must be retained.")
  }

  func testClientMapsSuccessfulResponseAndForwardsMinimalRequest() async throws {
    let transport = SearchSuggestionCapturingTransport(
      body: try response(list: [" swift ", "swift", "Swift", " S ", "iOS"]).serializedData()
    )
    let client = TiebaClient(transport: transport)

    let suggestions = try await client.searchSuggestions(query: " swift ")

    XCTAssertEqual(suggestions, ["swift", "Swift", "S", "iOS"])
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/s/searchSug?cmd=309438")
    let decoded = try SearchSugReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(decoded.data.word, "swift")
    XCTAssertEqual(decoded.data.isforum, "0")
  }

  func testClientIgnoresUnknownResponseFields() async throws {
    var body = try response(list: ["swift language"]).serializedData()
    body.append(contentsOf: [0x9A, 0x06, 0x03, 0x66, 0x75, 0x74])
    let client = TiebaClient(transport: SearchSuggestionStubTransport(body: body))

    let result = try await client.searchSuggestions(query: "swift")

    XCTAssertEqual(result, ["swift language"])
  }

  func testClientMapsMalformedAndServerErrorResponses() async throws {
    let malformedClient = TiebaClient(
      transport: SearchSuggestionStubTransport(body: Data([0x0A]))
    )
    await assertClientError(.invalidProtobuf) {
      _ = try await malformedClient.searchSuggestions(query: "swift")
    }

    let serverErrorClient = TiebaClient(
      transport: SearchSuggestionStubTransport(
        body: try response(errorCode: 4, errorMessage: "suggestions unavailable")
          .serializedData()
      )
    )
    await assertClientError(.server(code: 4, message: "suggestions unavailable")) {
      _ = try await serverErrorClient.searchSuggestions(query: "swift")
    }
  }

  func testClientRejectsOversizedResponseBeforeProtobufDecode() async {
    let client = TiebaClient(
      transport: SearchSuggestionStubTransport(
        body: Data(repeating: 0, count: 64 * 1_024 + 1)
      )
    )

    await assertClientError(.responseTooLarge(maximumBytes: 64 * 1_024)) {
      _ = try await client.searchSuggestions(query: "swift")
    }
  }

  private func decodedRequest(query: String) throws -> SearchSugReqIdl {
    try SearchSugReqIdl(
      serializedBytes: protobufPayload(from: factory.searchSuggestions(query: query))
    )
  }

  private func response(
    list: [String] = [],
    errorCode: Int32 = 0,
    errorMessage: String = ""
  ) -> SearchSugResIdl {
    var response = SearchSugResIdl()
    response.error.errorno = errorCode
    response.error.errmsg = errorMessage
    response.data.list = list
    return response
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

  private func protobufPayload(from request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    XCTAssertTrue(body.starts(with: prefix))
    XCTAssertTrue(body.count >= prefix.count + suffix.count)
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    return body.subdata(in: prefix.count..<body.count - suffix.count)
  }
}

final class TiebaLiveTestsSearchSuggestions: XCTestCase {
  func testAnonymousSearchSuggestions() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.34 integration-test")
    )
    let suggestions = try await client.searchSuggestions(query: "原神")

    XCTAssertFalse(suggestions.isEmpty)
    XCTAssertLessThanOrEqual(suggestions.count, 10)
    XCTAssertEqual(Set(suggestions).count, suggestions.count)
    XCTAssertTrue(
      suggestions.allSatisfy {
        (1...100).contains($0.count) && $0.utf8.count <= 400
          && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      }
    )
  }
}

private actor SearchSuggestionCapturingTransport: TiebaTransport {
  let body: Data
  private var request: URLRequest?

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    self.request = request
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func lastRequest() -> URLRequest? { request }
}

private struct SearchSuggestionStubTransport: TiebaTransport, Sendable {
  let body: Data

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    TiebaHTTPResponse(body: body, statusCode: 200)
  }
}
