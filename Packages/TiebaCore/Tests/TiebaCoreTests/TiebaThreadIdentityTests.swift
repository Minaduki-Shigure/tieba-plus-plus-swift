import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaThreadIdentityTests: XCTestCase {
  func testClientUsesAnonymousPbPageAndReturnsStrictWireIdentity() async throws {
    let response = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    let transport = ThreadIdentityTransport(body: try response.serializedData())
    let client = TiebaClient(transport: transport)

    let identity = try await client.resolveThreadIdentity(
      threadID: 41,
      expectedForumName: "  swift  "
    )

    XCTAssertEqual(identity, TiebaThreadIdentity(threadID: 41, forumID: 9, forumName: "swift"))
    let requests = await transport.requestSnapshot()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/c/f/pb/page")
    XCTAssertEqual(request.url?.query, "cmd=302001")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    let message = try PbPageReqIdl(serializedBytes: threadIdentityPayload(from: request))
    XCTAssertEqual(message.data.kz, 41)
    XCTAssertEqual(message.data.pn, 1)
    XCTAssertEqual(message.data.rn, 2)
    XCTAssertTrue(message.data.common.bduss.isEmpty)
  }

  func testDecoderRejectsContradictoryThreadAndForumBindings() throws {
    var wrongThread = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    wrongThread.data.thread.id = 42
    assertInvalid(wrongThread, threadID: 41, forumName: "swift")

    var wrongFID = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    wrongFID.data.thread.fid = 10
    assertInvalid(wrongFID, threadID: 41, forumName: "swift")

    var wrongThreadName = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    wrongThreadName.data.thread.fname = "ios"
    assertInvalid(wrongThreadName, threadID: 41, forumName: "swift")

    let expectedNameMismatch = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    assertInvalid(expectedNameMismatch, threadID: 41, forumName: "ios")
  }

  func testDecoderRejectsMissingOrInvalidForumAndThreadData() throws {
    var missingForum = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    missingForum.data.clearForum()
    assertInvalid(missingForum, threadID: 41, forumName: "swift")

    var missingThread = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    missingThread.data.clearThread()
    assertInvalid(missingThread, threadID: 41, forumName: "swift")

    var zeroForum = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    zeroForum.data.forum.id = 0
    assertInvalid(zeroForum, threadID: 41, forumName: "swift")

    var emptyName = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    emptyName.data.forum.name = "  "
    assertInvalid(emptyName, threadID: 41, forumName: "")

    var controlName = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    controlName.data.forum.name = "swift\n"
    controlName.data.thread.fname = "swift\n"
    assertInvalid(controlName, threadID: 41, forumName: "")
  }

  func testDecoderPreservesServerErrors() {
    var response = identityResponse(threadID: 41, forumID: 9, forumName: "swift")
    response.error.errorno = 4
    response.error.errmsg = "not found"

    XCTAssertThrowsError(
      try TiebaThreadIdentityDecoder.identity(
        from: response,
        expectedThreadID: 41,
        expectedForumName: "swift"
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 4, message: "not found"))
    }
  }

  private func assertInvalid(
    _ response: PbPageResIdl,
    threadID: Int64,
    forumName: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TiebaThreadIdentityDecoder.identity(
        from: response,
        expectedThreadID: threadID,
        expectedForumName: forumName
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidProtobuf, file: file, line: line)
    }
  }
}

private func identityResponse(
  threadID: Int64,
  forumID: Int64,
  forumName: String
) -> PbPageResIdl {
  var forum = SimpleForum()
  forum.id = forumID
  forum.name = forumName

  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.fname = forumName

  var data = PbPageResIdl.DataRes()
  data.forum = forum
  data.thread = thread

  var response = PbPageResIdl()
  response.data = data
  return response
}

private actor ThreadIdentityTransport: TiebaTransport {
  private let body: Data
  private var requests: [URLRequest] = []

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    requests.append(request)
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func requestSnapshot() -> [URLRequest] { requests }
}

private func threadIdentityPayload(from request: URLRequest) throws -> Data {
  let body = try XCTUnwrap(request.httpBody)
  let prefix = Data(
    "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
  )
  let suffix = Data("\r\n---*_r1999--\r\n".utf8)
  guard
    body.starts(with: prefix),
    body.count >= prefix.count + suffix.count,
    body.suffix(suffix.count) == suffix
  else { throw TiebaClientError.invalidProtobuf }
  return body.subdata(in: prefix.count..<(body.count - suffix.count))
}
