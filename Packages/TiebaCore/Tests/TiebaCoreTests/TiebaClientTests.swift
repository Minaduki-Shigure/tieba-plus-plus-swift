import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaClientTests: XCTestCase {
  func testMapsThreadPageFixtureForSwiftUI() async throws {
    let transport = StubTransport(body: try ProtoFixtures.threadPage().serializedData())
    let client = TiebaClient(transport: transport)

    let result = try await client.getThreads(forumName: "swift")

    XCTAssertEqual(result.forum.id, 42)
    XCTAssertTrue(result.forum.hasModerators)
    XCTAssertTrue(result.forum.hasRules)
    XCTAssertEqual(result.forum.avatar, "https://img.example/forum.png")
    XCTAssertEqual(result.forum.slogan, "A forum for Swift")
    XCTAssertEqual(
      result.forum.featuredClassifications,
      [TiebaForumClassification(id: 9, name: "Tutorials")]
    )
    XCTAssertEqual(result.pagination.nextPage, 2)
    XCTAssertEqual(result.tabs["Latest"], 3)

    let thread = try XCTUnwrap(result.threads.first)
    XCTAssertEqual(thread.id, 100)
    XCTAssertEqual(thread.author?.preferredName, "Swift Author")
    XCTAssertEqual(thread.author?.portrait, "portrait-token")
    XCTAssertEqual(thread.content.plainText, "Hello @reader")
    XCTAssertEqual(thread.content.images.first?.width, 640)
    XCTAssertEqual(
      thread.content.images.first?.thumbnailURL?.absoluteString, "https://img.example/thumb.jpg")
    XCTAssertTrue(thread.isPinned)
  }

  func testMapsPostsAndEmbeddedComments() async throws {
    let transport = StubTransport(body: try ProtoFixtures.postPage().serializedData())
    let client = TiebaClient(transport: transport)

    let result = try await client.getPosts(threadID: 100)

    XCTAssertEqual(result.thread.title, "A test thread")
    XCTAssertEqual(result.thread.viewCount, 500)
    XCTAssertEqual(result.thread.content.plainText, "Opening post")
    XCTAssertEqual(result.thread.content.images.count, 1)
    XCTAssertEqual(
      result.thread.content.images.first?.thumbnailURL?.absoluteString,
      "https://img.example/thread-thumb.jpg"
    )
    XCTAssertEqual(
      result.thread.content.fragments.filter { fragment in
        if case .video = fragment { return true }
        return false
      }.count, 1)
    XCTAssertEqual(
      result.thread.content.fragments.filter { fragment in
        if case .voice = fragment { return true }
        return false
      }.count, 1)
    XCTAssertEqual(result.pagination.currentPage, 2)
    XCTAssertEqual(result.pagination.totalPages, 6)
    XCTAssertEqual(result.thread.pagePostIDs, [301, 302])
    let post = try XCTUnwrap(result.posts.first)
    XCTAssertEqual(post.signature, "Sent from fixture")
    XCTAssertEqual(post.content.plainText, "Floor content")
    XCTAssertTrue(post.isThreadAuthor)
    XCTAssertEqual(post.comments.first?.author?.id, 8)
    XCTAssertEqual(post.comments.first?.parentPostID, post.id)
  }

  func testPostCursorIsForwardedToTheWireRequest() async throws {
    let transport = CapturingTransport(body: try ProtoFixtures.postPage().serializedData())
    let client = TiebaClient(transport: transport)

    _ = try await client.getPosts(
      threadID: 100,
      page: 4,
      sort: .descending,
      location: .pageCursor(201)
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try protobufPayload(from: body)
    let decoded = try PbPageReqIdl(serializedBytes: payload)
    XCTAssertEqual(decoded.data.pid, 201)
    XCTAssertEqual(decoded.data.pn, 4)
    XCTAssertEqual(decoded.data.r, TiebaPostSort.descending.rawValue)
  }

  func testAuthorIDsPreserveThreadAuthorFlagsWithoutExpandedUsers() async throws {
    let transport = StubTransport(
      body: try ProtoFixtures.postPageWithoutExpandedUsers().serializedData()
    )
    let client = TiebaClient(transport: transport)

    let result = try await client.getPosts(threadID: 100)

    let post = try XCTUnwrap(result.posts.first)
    XCTAssertNil(post.author)
    XCTAssertTrue(post.isThreadAuthor)
    let comment = try XCTUnwrap(post.comments.first)
    XCTAssertNil(comment.author)
    XCTAssertTrue(comment.isThreadAuthor)
  }

  func testDropsNonHTTPContentURLs() async throws {
    let transport = StubTransport(
      body: try ProtoFixtures.threadPageWithUnsafeLink().serializedData()
    )
    let client = TiebaClient(transport: transport)

    let result = try await client.getThreads(forumName: "swift")
    let thread = try XCTUnwrap(result.threads.first)
    let unsafeLink = try XCTUnwrap(thread.content.fragments.last)
    guard case .link(let link) = unsafeLink else {
      return XCTFail("Expected the fixture's final fragment to be a link")
    }
    XCTAssertNil(link.url)
  }

  func testMapsCommentReplyContext() async throws {
    let transport = StubTransport(body: try ProtoFixtures.commentPage().serializedData())
    let client = TiebaClient(transport: transport)

    let result = try await client.getComments(threadID: 100, postID: 201)

    XCTAssertEqual(result.parentPost.id, 201)
    let comment = try XCTUnwrap(result.comments.first)
    XCTAssertEqual(comment.parentPostID, 201)
    XCTAssertEqual(comment.replyToUserID, 7)
    XCTAssertEqual(comment.content.plainText, "Nested reply")
    XCTAssertEqual(comment.floor, 2)
  }

  func testMapsServerHTTPDecodeAndNetworkErrors() async throws {
    let serverTransport = StubTransport(
      body: try ProtoFixtures.serverError(code: 4, message: "not found").serializedData()
    )
    let serverClient = TiebaClient(transport: serverTransport)
    await assertClientError(.server(code: 4, message: "not found")) {
      _ = try await serverClient.getThreads(forumName: "swift")
    }

    let httpClient = TiebaClient(transport: StubTransport(body: Data(), statusCode: 503))
    await assertClientError(.httpStatus(503)) {
      _ = try await httpClient.getThreads(forumName: "swift")
    }

    let decodeClient = TiebaClient(transport: StubTransport(body: Data([0x0A])))
    await assertClientError(.invalidProtobuf) {
      _ = try await decodeClient.getThreads(forumName: "swift")
    }

    let networkClient = TiebaClient(
      transport: StubTransport(error: URLError(.notConnectedToInternet)))
    await assertClientError(.network(code: URLError.notConnectedToInternet.rawValue)) {
      _ = try await networkClient.getThreads(forumName: "swift")
    }
  }

  func testPreservesCancelledURLErrorAsCancellationError() async {
    let client = TiebaClient(transport: StubTransport(error: URLError(.cancelled)))

    do {
      _ = try await client.getThreads(forumName: "swift")
      XCTFail("Expected CancellationError")
    } catch is CancellationError {
      // Expected: callers use cancellation to suppress stale UI updates.
    } catch {
      XCTFail("Unexpected error: \(error)")
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
}

private actor CapturingTransport: TiebaTransport {
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

private func protobufPayload(from body: Data) throws -> Data {
  let prefix = Data(
    "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
  )
  let suffix = Data("\r\n---*_r1999--\r\n".utf8)
  guard body.starts(with: prefix), body.count >= prefix.count + suffix.count else {
    throw TiebaClientError.invalidProtobuf
  }
  return body.subdata(in: prefix.count..<body.count - suffix.count)
}

private struct StubTransport: TiebaTransport, Sendable {
  let body: Data
  let statusCode: Int
  let errorCode: URLError.Code?

  init(body: Data, statusCode: Int = 200) {
    self.body = body
    self.statusCode = statusCode
    self.errorCode = nil
  }

  init(error: URLError) {
    self.body = Data()
    self.statusCode = 0
    self.errorCode = error.code
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    if let errorCode {
      throw URLError(errorCode)
    }
    return TiebaHTTPResponse(body: body, statusCode: statusCode)
  }
}
