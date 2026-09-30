import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaOwnActivityTests: XCTestCase {
  private let userID: Int64 = 42

  func testOwnActivityUsesExactV12CredentialAndOptionalZeroContract() throws {
    for isThread in [true, false] {
      let credential = credential()
      let request = try factory().ownActivity(
        credential: credential, expectedUserID: userID, isThread: isThread,
        page: 3, pageSize: 20
      )
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://tiebac.baidu.com/c/u/feed/userpost?cmd=303002&format=protobuf"
      )
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
      XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), "42")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.52.1.0")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "CUID"))
      let (scalars, payload) = try multipart(request)
      XCTAssertEqual(scalars, ["stoken": credential.stoken])
      let data = try UserPostReqIdl(serializedBytes: payload).data
      XCTAssertEqual(data.uid, userID)
      XCTAssertEqual(data.rn, 20)
      XCTAssertEqual(data.pn, 3)
      XCTAssertEqual(data.needContent, 1)
      XCTAssertEqual(data.qType, 1)
      XCTAssertTrue(data.hasIsThread)
      XCTAssertTrue(data.hasIsViewCard)
      XCTAssertEqual(data.isThread, isThread ? 1 : 0)
      XCTAssertEqual(data.isViewCard, isThread ? 1 : 0)
      XCTAssertEqual(data.hasSubtype, !isThread)
      XCTAssertEqual(data.subtype, 0)
      var common = CommonReq()
      common.clientType = 2
      common.clientVersion = "12.52.1.0"
      common.bduss = credential.bduss
      common.stoken = credential.stoken
      XCTAssertEqual(data.common, common)
    }
  }

  func testPublicActivityKeepsGuestFieldsAndDoesNotAdoptV12ReplyContract() throws {
    let guest = TiebaRequestFactory(configuration: .init())
    for isThread in [true, false] {
      let request =
        try isThread
        ? guest.userThreads(userID: userID, page: 2, pageSize: 20)
        : guest.userReplies(userID: userID, page: 2, pageSize: 20)
      let (_, payload) = try multipart(request)
      let data = try UserPostReqIdl(serializedBytes: payload).data
      XCTAssertEqual(data.common.bduss, "")
      XCTAssertEqual(data.common.stoken, "")
      XCTAssertEqual(data.common.clientVersion, isThread ? "12.64.1.1" : "8")
      XCTAssertEqual(data.hasIsThread, isThread)
      XCTAssertEqual(data.hasIsViewCard, isThread)
      XCTAssertFalse(data.hasSubtype)
      XCTAssertEqual(data.qType, 0)
    }
  }

  func testInvalidArgumentsNeverDispatchEvenIdentityProbes() async {
    let invalidCases: [(Int64, Int, Int)] = [
      (0, 1, 20), (-1, 1, 20), (42, 0, 20), (42, Int(Int32.max) + 1, 20),
      (42, 1, 0), (42, 1, 101),
    ]
    let transport = OwnActivityTransport(bodies: [])
    let client = TiebaAuthenticatedClient(transport: transport)
    for (uid, page, size) in invalidCases {
      do {
        _ = try await client.getOwnReplies(
          credential: credential(), expectedUserID: uid, page: page, pageSize: size
        )
        XCTFail("Invalid arguments must fail")
      } catch let error as TiebaClientError {
        guard case .invalidArgument = error else { return XCTFail("Unexpected \(error)") }
      } catch { XCTFail("Unexpected \(error)") }
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testInvalidCredentialAndConfigurationNeverDispatch() async {
    let transport = OwnActivityTransport(bodies: [])
    let badCredential = TiebaSessionCredential(
      bduss: "invalid", stoken: "invalid", bdussCookieName: .bduss
    )
    for configuration in [TiebaClientConfiguration(), .init(requestTimeout: .infinity)] {
      let client = TiebaAuthenticatedClient(configuration: configuration, transport: transport)
      do {
        _ = try await client.getOwnThreads(
          credential: configuration.requestTimeout.isFinite ? badCredential : credential(),
          expectedUserID: userID
        )
        XCTFail("Invalid inputs must fail")
      } catch let error as TiebaClientError {
        guard case .invalidArgument = error else { return XCTFail("Unexpected \(error)") }
      } catch { XCTFail("Unexpected \(error)") }
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testOwnThreadsBindBothSessionIdentitiesBeforeBoundedPrivateRead() async throws {
    var response = response()
    response.data.postList = [group()]
    let transport = OwnActivityTransport(bodies: sessionBodies() + [try response.serializedData()])
    let result = try await TiebaAuthenticatedClient(transport: transport).getOwnThreads(
      credential: credential(), expectedUserID: userID, page: 2
    )
    XCTAssertEqual(result.userID, userID)
    XCTAssertEqual(result.threads.map(\.id), [100])
    XCTAssertEqual(result.threads.first?.author?.id, userID)
    XCTAssertEqual(result.threads.first?.title, "Thread context")
    XCTAssertEqual(result.pagination.currentPage, 2)
    XCTAssertTrue(result.pagination.hasMore)
    XCTAssertTrue(result.pagination.hasPrevious)
    let requests = await transport.requests
    let limits = await transport.limits
    XCTAssertEqual(
      requests.map { $0.url?.path }, ["/c/s/login", "/mo/q/newmoindex", "/c/u/feed/userpost"])
    XCTAssertEqual(limits, [512 * 1_024, 256 * 1_024, 4 * 1_024 * 1_024])
  }

  func testOwnRepliesUseEveryInnerIdentityAndNeverAttributeThreadAuthorToReply() async throws {
    var response = response()
    var group = group()
    group.userID = 99
    group.userName = "other thread author"
    group.postID = 999
    group.content = [
      reply(postID: 101, type: 0), reply(postID: 102, type: 1), reply(postID: 103, type: 7),
    ]
    response.data.postList = [group]
    let transport = OwnActivityTransport(bodies: sessionBodies() + [try response.serializedData()])
    let result = try await TiebaAuthenticatedClient(transport: transport).getOwnReplies(
      credential: credential(), expectedUserID: userID
    )
    XCTAssertEqual(result.replies.map(\.postID), [101, 102, 103])
    XCTAssertEqual(result.replies.map(\.threadID), [100, 100, 100])
    XCTAssertEqual(result.replies.map(\.target), [.post, .comment, .unsupported(rawType: 7)])
    XCTAssertTrue(result.replies.allSatisfy { $0.author == nil })
    XCTAssertEqual(result.replies.map { $0.createdAt?.timeIntervalSince1970 }, [101, 102, 103])
    XCTAssertEqual(
      result.replies.map { $0.content.plainText }, ["Reply 101", "Reply 102", "Reply 103"])
    XCTAssertTrue(
      TiebaProtoMapper.userReplyPage(response.data, userID: userID, requestedPage: 1, pageSize: 20)
        .replies.isEmpty,
      "Public V8 author validation must remain unchanged"
    )
  }

  func testReplyPageCanContainMoreInnerRepliesThanRequestedOuterPageSize() throws {
    var response = response()
    var group = group()
    group.content = (1...80).map { reply(postID: UInt64($0), type: 0) }
    response.data.postList = [group]
    let page = try TiebaOwnActivityDecoder.replies(
      from: response, expectedUserID: userID, page: 1, pageSize: 20
    )
    XCTAssertEqual(page.replies.count, 80)
    XCTAssertEqual(page.pagination.pageSize, 20)
  }

  func testWrongExpectedOrMismatchedSessionIdentityNeverDispatchesActivity() async {
    for (appID, webID) in [(99, 99), (42, 99)] {
      let transport = OwnActivityTransport(bodies: sessionBodies(appID: appID, webID: webID))
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await TiebaAuthenticatedClient(transport: transport).getOwnReplies(
          credential: self.credential(), expectedUserID: self.userID
        )
      }
      let requests = await transport.requests
      XCTAssertFalse(requests.contains { $0.url?.path == "/c/u/feed/userpost" })
    }
  }

  func testSessionFailureDoesNotFallBackToGuestActivity() async {
    let transport = OwnActivityTransport(bodies: [
      Data("{\"error_code\":4,\"error_msg\":\"login required\"}".utf8)
    ])
    await assertError(.server(code: 4, message: "login required")) {
      _ = try await TiebaAuthenticatedClient(transport: transport).getOwnThreads(
        credential: self.credential(), expectedUserID: self.userID
      )
    }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testCancelledTaskNeverDispatches() async {
    let transport = OwnActivityTransport(bodies: sessionBodies())
    let client = TiebaAuthenticatedClient(transport: transport)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.getOwnReplies(
        credential: self.credential(), expectedUserID: self.userID)
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testEmptyAndHiddenPagesRetainDistinctVisibilityState() throws {
    for hidden: UInt32 in [0, 1] {
      var response = response()
      response.data.hidePost = hidden
      let threads = try TiebaOwnActivityDecoder.threads(
        from: response, expectedUserID: userID, page: 2, pageSize: 20
      )
      let replies = try TiebaOwnActivityDecoder.replies(
        from: response, expectedUserID: userID, page: 2, pageSize: 20
      )
      XCTAssertTrue(threads.threads.isEmpty)
      XCTAssertTrue(replies.replies.isEmpty)
      XCTAssertFalse(threads.pagination.hasMore)
      XCTAssertFalse(replies.pagination.hasMore)
      XCTAssertEqual(threads.isHidden, hidden != 0)
      XCTAssertEqual(replies.isHidden, hidden != 0)
    }
  }

  func testMissingDataForeignThreadAuthorAndInvalidIdentifiersFailClosed() throws {
    var badResponses = [UserPostResIdl()]
    for invalidValue: UInt64 in [0, UInt64.max] {
      var response = response()
      var group = group()
      group.threadID = invalidValue
      response.data.postList = [group]
      badResponses.append(response)
    }
    var foreign = response()
    var foreignGroup = group()
    foreignGroup.userID = 99
    foreign.data.postList = [foreignGroup]
    badResponses.append(foreign)
    for response in badResponses {
      XCTAssertThrowsError(
        try TiebaOwnActivityDecoder.threads(
          from: response, expectedUserID: userID, page: 1, pageSize: 20
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testMalformedReplyIdentityAndTimestampAreNotSilentlyDropped() throws {
    var values = [reply(postID: 0, type: 0), reply(postID: UInt64.max, type: 1)]
    var badTime = reply(postID: 1, type: 0)
    badTime.createTime = UInt64.max
    values.append(badTime)
    for value in values {
      var response = response()
      var group = group()
      group.content = [value]
      response.data.postList = [group]
      XCTAssertThrowsError(
        try TiebaOwnActivityDecoder.replies(
          from: response, expectedUserID: userID, page: 1, pageSize: 20
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testOversizedNestedCollectionsAreRejectedRatherThanTruncated() throws {
    var response = response()
    response.data.postList = Array(repeating: group(), count: 101)
    XCTAssertThrowsError(
      try TiebaOwnActivityDecoder.threads(
        from: response, expectedUserID: userID, page: 1, pageSize: 100
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    var group = group()
    group.content = Array(repeating: reply(postID: 1, type: 0), count: 101)
    response.data.postList = [group]
    XCTAssertThrowsError(
      try TiebaOwnActivityDecoder.replies(
        from: response, expectedUserID: userID, page: 1, pageSize: 100
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testServerMalformedAndOversizedActivityErrorsArePreserved() async throws {
    var serverError = response()
    serverError.error.errorno = 4
    serverError.error.errmsg = "login required"
    let cases: [(Data, TiebaClientError)] = [
      (try serverError.serializedData(), .server(code: 4, message: "login required")),
      (Data([0xFF]), .invalidProtobuf),
      (Data(), .invalidAuthenticatedResponse),
      (
        Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1),
        .responseTooLarge(maximumBytes: 4 * 1_024 * 1_024)
      ),
    ]
    for (body, error) in cases {
      let transport = OwnActivityTransport(bodies: sessionBodies() + [body])
      await assertError(error) {
        _ = try await TiebaAuthenticatedClient(transport: transport).getOwnReplies(
          credential: self.credential(), expectedUserID: self.userID
        )
      }
    }
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func credential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192), stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func sessionBodies(appID: Int = 42, webID: Int = 42) -> [Data] {
    [
      Data(
        "{\"error_code\":0,\"user\":{\"id\":\"\(appID)\",\"name\":\"self\",\"portrait\":\"self-avatar\"}}"
          .utf8),
      Data("{\"no\":0,\"data\":{\"id\":\"\(webID)\"}}".utf8),
    ]
  }

  private func response() -> UserPostResIdl {
    var response = UserPostResIdl()
    response.data = UserPostResIdl.DataRes()
    return response
  }

  private func group() -> PostInfoList {
    var group = PostInfoList()
    group.threadID = 100
    group.postID = 1
    group.forumID = 7
    group.forumName = "Swift"
    group.title = "Thread context"
    group.userID = userID
    group.userName = "self"
    return group
  }

  private func reply(postID: UInt64, type: UInt64) -> PostInfoList.PostInfoContent {
    var reply = PostInfoList.PostInfoContent()
    reply.postID = postID
    reply.postType = type
    reply.createTime = postID
    var text = PostInfoList.PostInfoContent.Abstract()
    text.text = "Reply \(postID)"
    reply.postContent = [text]
    return reply
  }

  private func multipart(_ request: URLRequest) throws -> ([String: String], Data) {
    let body = try XCTUnwrap(request.httpBody)
    let boundary = "--\(TiebaRequestFactory.multipartBoundary)\r\n"
    let marker = Data(
      (boundary + "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n").utf8)
    let range = try XCTUnwrap(body.range(of: marker))
    let suffix = Data("\r\n--\(TiebaRequestFactory.multipartBoundary)--\r\n".utf8)
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    let text = try XCTUnwrap(String(data: body[..<range.lowerBound], encoding: .utf8))
    var fields = [String: String]()
    let prefix = "Content-Disposition: form-data; name=\""
    for part in text.components(separatedBy: boundary) {
      guard part.hasPrefix(prefix), let end = part.range(of: "\"\r\n\r\n") else { continue }
      let name = String(part.dropFirst(prefix.count).prefix(upTo: end.lowerBound))
      XCTAssertNil(fields[name])
      fields[name] = String(part[end.upperBound...]).trimmingCharacters(in: .newlines)
    }
    return (fields, body.subdata(in: range.upperBound..<(body.count - suffix.count)))
  }

  private func assertError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch { XCTAssertEqual(error as? TiebaClientError, expected) }
  }
}

private actor OwnActivityTransport: TiebaTransport {
  private let bodies: [Data]
  private(set) var requests = [URLRequest]()
  private(set) var limits = [Int?]()

  init(bodies: [Data]) { self.bodies = bodies }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(_ request: URLRequest, maximumBodyBytes: Int?) async throws -> TiebaHTTPResponse {
    requests.append(request)
    limits.append(maximumBodyBytes)
    guard bodies.indices.contains(requests.count - 1) else {
      throw TiebaClientError.transportFailure
    }
    // Deliberately ignore the transport's limit: the client must also guard size.
    return TiebaHTTPResponse(body: bodies[requests.count - 1], statusCode: 200)
  }
}
