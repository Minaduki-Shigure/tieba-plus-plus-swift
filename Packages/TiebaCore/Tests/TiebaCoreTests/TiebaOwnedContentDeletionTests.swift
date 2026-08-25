import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaOwnedContentDeletionTests: XCTestCase, @unchecked Sendable {
  private let userID: Int64 = 7_001
  private let forumID: Int64 = 8_001
  private let forumName = "swift"
  private let threadID: Int64 = 9_001
  private let firstPostID: Int64 = 10_001
  private let postID: Int64 = 10_002
  private let tbs = "0123456789abcdef0123456789"

  func testRequestFactoryUsesExactSelfOwnedThreadDeletionContract() throws {
    let request = try factory().deleteOwnedContent(
      credential: credential().bdussCredential,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      tbs: tbs
    )
    let fields = try formFields(request)

    assertCommonWriteRequest(request, path: "/c/c/bawu/delthread")
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "delete_my_thread", "fid", "is_frs_mask",
        "is_vipdel", "sign", "src", "tbs", "word", "z",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["word"], forumName)
    XCTAssertEqual(fields["z"], String(threadID))
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["src"], "1")
    XCTAssertEqual(fields["is_vipdel"], "0")
    XCTAssertEqual(fields["delete_my_thread"], "1")
    XCTAssertEqual(fields["is_frs_mask"], "0")
    XCTAssertEqual(fields["sign"], "c264f7b660f12e6068894b3feeeef47a")
    XCTAssertEqual(fields["sign"], signature(for: fields))
    XCTAssertNil(fields["pid"])
    XCTAssertNil(fields["delete_my_post"])
    XCTAssertNil(fields["stoken"])
  }

  func testRequestFactoryUsesExactSelfOwnedPostDeletionContract() throws {
    let request = try factory().deleteOwnedContent(
      credential: credential().bdussCredential,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID),
      tbs: tbs
    )
    let fields = try formFields(request)

    assertCommonWriteRequest(request, path: "/c/c/bawu/delpost")
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "delete_my_post", "fid", "is_vipdel", "isfloor",
        "pid", "sign", "src", "tbs", "word", "z",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["word"], forumName)
    XCTAssertEqual(fields["z"], String(threadID))
    XCTAssertEqual(fields["pid"], String(postID))
    XCTAssertEqual(fields["isfloor"], "0")
    XCTAssertEqual(fields["src"], "1")
    XCTAssertEqual(fields["is_vipdel"], "0")
    XCTAssertEqual(fields["delete_my_post"], "1")
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["sign"], "e5500175a3fec819b14dfc9daeb8c1e5")
    XCTAssertEqual(fields["sign"], signature(for: fields))
    XCTAssertNil(fields["delete_my_thread"])
    XCTAssertNil(fields["is_frs_mask"])
    XCTAssertNil(fields["stoken"])
  }

  func testRequestFactoryRejectsUnboundIdentifiersAndMalformedTBS() throws {
    let factory = factory()
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: 0,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        tbs: tbs
      )
    )
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: 0),
        tbs: tbs
      )
    )
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .thread(firstPostID: 0),
        tbs: tbs
      )
    )
    for malformedTBS in ["", "short", String(repeating: "A", count: 26)] {
      XCTAssertThrowsError(
        try factory.deleteOwnedContent(
          credential: credential().bdussCredential,
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName,
          threadID: threadID,
          target: .post(postID: postID),
          tbs: malformedTBS
        )
      )
    }
  }

  func testPreflightAcceptsOnlyTheSignedInAuthorsOwnTarget() throws {
    let response = pageResponse()
    let thread = try deletionContext(response, target: .thread(firstPostID: firstPostID))
    XCTAssertEqual(thread.userID, userID)
    XCTAssertEqual(thread.forumID, forumID)
    XCTAssertEqual(thread.threadID, threadID)
    XCTAssertEqual(thread.target, .thread(firstPostID: firstPostID))
    XCTAssertEqual(thread.tbs, tbs)

    let post = try deletionContext(response, target: .post(postID: postID))
    XCTAssertEqual(post.target, .post(postID: postID))

    var wrongThreadAuthor = response
    wrongThreadAuthor.data.thread.authorID = userID + 1
    assertInvalidPreflight(
      wrongThreadAuthor,
      target: .thread(firstPostID: firstPostID)
    )

    var wrongFirstPostAuthor = response
    wrongFirstPostAuthor.data.firstFloorPost.authorID = userID + 1
    assertInvalidPreflight(
      wrongFirstPostAuthor,
      target: .thread(firstPostID: firstPostID)
    )

    var wrongPostAuthor = response
    wrongPostAuthor.data.postList[0].authorID = userID + 1
    assertInvalidPreflight(wrongPostAuthor, target: .post(postID: postID))

    var mismatchedDeclaredAndEmbeddedAuthor = response
    mismatchedDeclaredAndEmbeddedAuthor.data.postList[0].author.id = userID + 1
    assertInvalidPreflight(
      mismatchedDeclaredAndEmbeddedAuthor,
      target: .post(postID: postID)
    )
  }

  func testClientStopsBeforeWriteWhenPreflightAuthorDoesNotMatch() async throws {
    var response = pageResponse()
    response.data.postList[0].authorID = userID + 1
    response.data.postList[0].author.id = userID + 1
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try response.serializedData()),
    ])

    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(transport: transport).deleteOwnedContent(
        credential: self.credential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        forumName: self.forumName,
        threadID: self.threadID,
        target: .post(postID: self.postID)
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.agreementPageResponseMaximumBytes
    ])
  }

  func testDeletionAcknowledgementClassifiesSuccessRejectionAndMalformedBodies() throws {
    for body in [
      #"{"error_code":0}"#,
      #"{"errno":"0"}"#,
      #"{"error":{"errno":0}}"#,
    ] {
      XCTAssertNoThrow(
        try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
          from: Data(body.utf8)
        )
      )
    }

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
        from: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 340_006, message: "denied"))
    }

    for body in [#"{}"#, #"[]"#, #"{"error_code":false}"#, #"{"error_code":0.5}"#] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
          from: Data(body.utf8)
        )
      ) { error in
        XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
      }
    }
  }

  func testClientPreservesExplicitRejectionAndMapsUnverifiableACKToUnknown() async throws {
    let preflight = try pageResponse().serializedData()
    let rejectionTransport = OwnedContentDeletionTransport(steps: [
      .response(preflight),
      .response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
    ])
    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await self.deletePost(using: rejectionTransport)
    }
    let rejectionSnapshot = await rejectionTransport.snapshot()
    XCTAssertEqual(
      rejectionSnapshot.paths,
      ["/c/f/pb/page", "/c/c/bawu/delpost"]
    )

    for step in [
      OwnedContentDeletionStep.response(Data(#"{}"#.utf8)),
      .failure(.transportFailure),
    ] {
      let transport = OwnedContentDeletionTransport(steps: [.response(preflight), step])
      await assertError(.ownedContentDeletionOutcomeUnknown) {
        _ = try await self.deletePost(using: transport)
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
      XCTAssertEqual(snapshot.paths.filter { $0 == "/c/c/bawu/delpost" }.count, 1)
    }
  }

  func testClientReturnsBoundReceiptAfterOneVerifiedWrite() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try pageResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let receipt = try await deletePost(using: transport)

    XCTAssertEqual(receipt.userID, userID)
    XCTAssertEqual(receipt.forumID, forumID)
    XCTAssertEqual(receipt.threadID, threadID)
    XCTAssertEqual(receipt.target, .post(postID: postID))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
      TiebaAuthenticatedClient.ownedContentDeletionWriteResponseMaximumBytes,
    ])
  }

  func testEquivalentConcurrentCallsShareOnePreflightAndWrite() async throws {
    let transport = OwnedContentDeletionTransport(
      steps: [
        .response(try pageResponse().serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task { try await self.deletePost(using: client) }
    let second = Task { try await self.deletePost(using: client) }

    guard await transport.waitUntilRequestCount(2) else {
      await transport.releaseBlockedRequest()
      first.cancel()
      second.cancel()
      _ = await first.result
      _ = await second.result
      return XCTFail("Deletion write did not dispatch")
    }
    await transport.releaseBlockedRequest()

    let firstReceipt = try await first.value
    let secondReceipt = try await second.value
    XCTAssertEqual(firstReceipt, secondReceipt)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
  }

  func testUnknownTerminalPreventsAnyLaterRequestForTheSameTarget() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try pageResponse().serializedData()),
      .response(Data(#"{}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.ownedContentDeletionOutcomeUnknown) {
      _ = try await self.deletePost(using: client)
    }
    let firstSnapshot = await transport.snapshot()
    XCTAssertEqual(firstSnapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])

    await assertError(.ownedContentDeletionOutcomeUnknown) {
      _ = try await client.deleteOwnedContent(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "c", count: 192),
          stoken: String(repeating: "t", count: 64),
          bdussCookieName: .bdussBFESS
        ),
        expectedUserID: self.userID,
        forumID: self.forumID,
        forumName: self.forumName,
        threadID: self.threadID,
        target: .post(postID: self.postID)
      )
    }
    let secondSnapshot = await transport.snapshot()
    XCTAssertEqual(secondSnapshot.paths, firstSnapshot.paths)
    XCTAssertEqual(secondSnapshot.maximumBodyBytes, firstSnapshot.maximumBodyBytes)
  }

  func testExplicitServerRejectionDoesNotCreateTerminalAndCanPreflightAgain() async throws {
    let preflight = try pageResponse().serializedData()
    let transport = OwnedContentDeletionTransport(steps: [
      .response(preflight),
      .response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
      .response(preflight),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await self.deletePost(using: client)
    }
    let receipt = try await deletePost(using: client)

    XCTAssertEqual(receipt.target, .post(postID: postID))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, [
      "/c/f/pb/page", "/c/c/bawu/delpost",
      "/c/f/pb/page", "/c/c/bawu/delpost",
    ])
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func credential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func pageResponse() -> PbPageResIdl {
    var signedInUser = User()
    signedInUser.isLogin = 1
    signedInUser.id = userID

    var author = User()
    author.id = userID

    var forum = SimpleForum()
    forum.id = forumID
    forum.name = forumName

    var thread = ThreadInfo()
    thread.id = threadID
    thread.fid = forumID
    thread.firstPostID = firstPostID
    thread.authorID = userID
    thread.author = author

    var firstPost = Post()
    firstPost.id = firstPostID
    firstPost.tid = threadID
    firstPost.floor = 1
    firstPost.authorID = userID
    firstPost.author = author

    var post = Post()
    post.id = postID
    post.tid = threadID
    post.floor = 2
    post.authorID = userID
    post.author = author

    var page = Page()
    page.pageSize = 2
    page.currentPage = 1
    page.totalPage = 1
    page.totalCount = 2

    var anti = Anti()
    anti.tbs = tbs

    var data = PbPageResIdl.DataRes()
    data.user = signedInUser
    data.forum = forum
    data.thread = thread
    data.firstFloorPost = firstPost
    data.postList = [post]
    data.page = page
    data.anti = anti

    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func deletionContext(
    _ response: PbPageResIdl,
    target: TiebaOwnedContentDeletionTarget
  ) throws -> TiebaOwnedContentDeletionContext {
    try TiebaAuthenticatedDecoder.ownedContentDeletionContext(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target
    )
  }

  private func assertInvalidPreflight(
    _ response: PbPageResIdl,
    target: TiebaOwnedContentDeletionTarget,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try deletionContext(response, target: target),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .invalidAuthenticatedResponse,
        file: file,
        line: line
      )
    }
  }

  private func assertCommonWriteRequest(
    _ request: URLRequest,
    path: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com", file: file, line: line)
    XCTAssertEqual(request.url?.path, path, file: file, line: line)
    XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1",
      file: file,
      line: line
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open", file: file, line: line)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded",
      file: file,
      line: line
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept"),
      "application/json",
      file: file,
      line: line
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept-Encoding"),
      "gzip",
      file: file,
      line: line
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"), file: file, line: line)
  }

  private func signature(for fields: [String: String]) -> String {
    TiebaFormSigner.signature(
      for: fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    )
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    let items = try XCTUnwrap(components.queryItems)
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  private func deletePost(
    using transport: OwnedContentDeletionTransport
  ) async throws -> TiebaOwnedContentDeletionReceipt {
    try await deletePost(using: TiebaAuthenticatedClient(transport: transport))
  }

  private func deletePost(
    using client: TiebaAuthenticatedClient
  ) async throws -> TiebaOwnedContentDeletionReceipt {
    try await client.deleteOwnedContent(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID)
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
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private enum OwnedContentDeletionStep: Sendable {
  case response(Data)
  case failure(TiebaClientError)
}

private struct OwnedContentDeletionTransportSnapshot: Sendable {
  let paths: [String]
  let maximumBodyBytes: [Int?]
}

private actor OwnedContentDeletionTransport: TiebaTransport {
  private var steps: [OwnedContentDeletionStep]
  private var paths = [String]()
  private var maximumBodyBytes = [Int?]()
  private let blockedRequestIndex: Int?
  private var blockedRequestContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

  init(
    steps: [OwnedContentDeletionStep],
    blockedRequestIndex: Int? = nil
  ) {
    self.steps = steps
    self.blockedRequestIndex = blockedRequestIndex
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let requestIndex = paths.count
    paths.append(request.url?.path ?? "")
    self.maximumBodyBytes.append(maximumBodyBytes)
    if let blockedRequestIndex,
      requestIndex == blockedRequestIndex,
      !isBlockedRequestReleased
    {
      await withCheckedContinuation { continuation in
        blockedRequestContinuation = continuation
      }
    }
    guard !steps.isEmpty else { throw TiebaClientError.transportFailure }
    switch steps.removeFirst() {
    case .response(let body):
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .failure(let error):
      throw error
    }
  }

  func waitUntilRequestCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if paths.count >= expected { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    blockedRequestContinuation?.resume()
    blockedRequestContinuation = nil
  }

  func snapshot() -> OwnedContentDeletionTransportSnapshot {
    OwnedContentDeletionTransportSnapshot(
      paths: paths,
      maximumBodyBytes: maximumBodyBytes
    )
  }
}
