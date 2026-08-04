import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaNotificationTests: XCTestCase {
  private let userID: Int64 = 957_339_815

  func testReplyRequestUsesMinimalHTTPSProtobufContract() throws {
    let request = try factory().notifications(
      credential: credential(),
      expectedUserID: userID,
      kind: .replies,
      page: 2
    )

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/u/feed/replyme?cmd=303007"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")

    let message = try ReplyMeReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(message.data.pn, "2")
    XCTAssertEqual(message.data.common.bduss, credential().bduss)
    XCTAssertEqual(message.data.common.clientVersion, "22.6.5.1")
    XCTAssertEqual(message.data.common.clientType, 0)
    XCTAssertTrue(message.data.common.stoken.isEmpty)
    XCTAssertTrue(message.data.common.cuid.isEmpty)
    XCTAssertTrue(message.data.common.cuidGalaxy2.isEmpty)
    XCTAssertTrue(message.data.common.phoneImei.isEmpty)
    XCTAssertTrue(message.data.common.model.isEmpty)
    XCTAssertEqual(message.data.common.timestamp, 0)
    XCTAssertEqual(message.data.common.scrW, 0)
    XCTAssertEqual(message.data.common.scrH, 0)
    XCTAssertTrue(message.data.common.androidID.isEmpty)
  }

  func testMentionRequestUsesOnlyMinimalSignedHTTPSForm() throws {
    let request = try factory().notifications(
      credential: credential(),
      expectedUserID: userID,
      kind: .mentions,
      page: 3
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/u/feed/atme")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "pn", "sign"]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "22.6.5.1")
    XCTAssertEqual(fields["pn"], "3")
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential().bduss),
          ("_client_version", "22.6.5.1"),
          ("pn", "3"),
        ]
      )
    )
    for forbidden in [
      "STOKEN", "stoken", "CUID", "cuid", "IMEI", "imei", "model",
      "_timestamp", "timestamp", "scr_w", "scr_h", "android_id", "from",
      "_client_type",
    ] {
      XCTAssertNil(fields[forbidden])
    }
  }

  func testDecodesReplyPageAndBindsAccountKindAndNavigationIDs() throws {
    let response = replyResponse(page: 2, hasMore: true, hasPrevious: true)
    let page = try TiebaNotificationDecoder.replyPage(
      from: response,
      expectedUserID: userID,
      requestedPage: 2
    )

    XCTAssertEqual(page.userID, userID)
    XCTAssertEqual(page.kind, .replies)
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertEqual(page.pagination.pageSize, page.items.count)
    XCTAssertEqual(page.pagination.totalPages, 4)
    XCTAssertEqual(page.pagination.totalCount, 61)
    XCTAssertEqual(page.pagination.nextPage, 3)
    XCTAssertEqual(page.pagination.previousPage, 1)

    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, 99)
    XCTAssertEqual(item.threadID, 42)
    XCTAssertEqual(item.postID, 99)
    XCTAssertEqual(item.quotedPostID, 77)
    XCTAssertEqual(item.content, "reply text")
    XCTAssertEqual(item.quotedContent, "quoted text")
    XCTAssertEqual(item.forumName, "swift")
    XCTAssertEqual(item.timestamp, 1_700_000_000)
    XCTAssertTrue(item.isFloorReply)
    XCTAssertFalse(item.isFirstPost)
    XCTAssertFalse(item.isUnread)
    XCTAssertEqual(item.sender.id, 123)
    XCTAssertEqual(item.sender.preferredName, "Reply Sender")
    XCTAssertTrue(item.sender.isFriend)
    XCTAssertFalse(item.sender.isFan)
    XCTAssertEqual(item.quotedUser?.id, 456)
  }

  func testDecodesMentionPageIncludingFirstPostFlag() throws {
    let page = try TiebaNotificationDecoder.mentionPage(
      from: mentionBody(),
      expectedUserID: userID,
      requestedPage: 1
    )

    XCTAssertEqual(page.userID, userID)
    XCTAssertEqual(page.kind, .mentions)
    XCTAssertEqual(page.pagination.currentPage, 1)
    XCTAssertEqual(page.pagination.nextPage, 2)
    XCTAssertNil(page.pagination.previousPage)
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.threadID, 43)
    XCTAssertEqual(item.postID, 100)
    XCTAssertEqual(item.sender.id, 124)
    XCTAssertEqual(item.sender.username, "mention-user")
    XCTAssertEqual(item.content, "@account hello")
    XCTAssertEqual(item.title, "mentioned topic")
    XCTAssertEqual(item.quotedContent, "quoted mention")
    XCTAssertEqual(item.quotedPostID, 88)
    XCTAssertEqual(item.quotedUser?.id, 457)
    XCTAssertEqual(item.threadType, 3)
    XCTAssertTrue(item.isFirstPost)
    XCTAssertFalse(item.isFloorReply)
    XCTAssertTrue(item.isUnread)
  }

  func testDecodesMinimalValidItemsForBothKinds() throws {
    var reply = replyResponse()
    var replyItem = ReplyMeResIdl.DataRes.ReplyList()
    replyItem.threadID = 1
    replyItem.postID = 2
    var replySender = User()
    replySender.id = 3
    replyItem.replyer = replySender
    reply.data.replyList = [replyItem]

    let replyPage = try TiebaNotificationDecoder.replyPage(
      from: reply,
      expectedUserID: userID,
      requestedPage: 1
    )
    XCTAssertEqual(replyPage.items.first?.sender.id, 3)
    XCTAssertEqual(replyPage.items.first?.content, "")
    XCTAssertNil(replyPage.items.first?.quotedPostID)

    let mention = Data(
      #"{"error_code":0,"at_list":[{"thread_id":1,"post_id":2,"time":0,"fname":"","content":"","is_floor":0,"is_first_post":0,"replyer":{"id":3}}],"page":{"current_page":1,"has_more":0,"has_prev":0}}"#.utf8
    )
    let mentionPage = try TiebaNotificationDecoder.mentionPage(
      from: mention,
      expectedUserID: userID,
      requestedPage: 1
    )
    XCTAssertEqual(mentionPage.items.first?.sender.id, 3)
    XCTAssertEqual(mentionPage.items.first?.sender.preferredName, "")
    XCTAssertFalse(mentionPage.items.first?.isFirstPost ?? true)
  }

  func testAcceptsOnlyDocumentedPrimitiveEmptyMentionSentinels() throws {
    for sentinel in ["[]", "null", "\"\"", "0", "\"0\""] {
      let body = Data(
        """
        {"error_code":"0","at_list":\(sentinel),
         "page":{"current_page":"1","has_more":"0","has_prev":"0"}}
        """.utf8
      )
      let page = try TiebaNotificationDecoder.mentionPage(
        from: body,
        expectedUserID: userID,
        requestedPage: 1
      )
      XCTAssertTrue(page.items.isEmpty)
    }

    for sentinel in ["\"nonempty\"", "1", "true", "{}"] {
      let body = Data(
        """
        {"error_code":"0","at_list":\(sentinel),
         "page":{"current_page":"1","has_more":"0","has_prev":"0"}}
        """.utf8
      )
      XCTAssertThrowsError(
        try TiebaNotificationDecoder.mentionPage(
          from: body,
          expectedUserID: userID,
          requestedPage: 1
        )
      )
    }
  }

  func testRejectsMissingCrossKindAndMalformedMentionResponses() {
    let bodies = [
      #"{"error_code":"0","page":{"current_page":"1","has_more":"0","has_prev":"0"}}"#,
      #"{"error_code":"0","reply_list":[{}],"page":{"current_page":"1","has_more":"0","has_prev":"0"}}"#,
      #"{"error_code":"0","at_list":[],"reply_list":[{}],"page":{"current_page":"1","has_more":"0","has_prev":"0"}}"#,
      #"{"error_code":"0","at_list":[{"thread_id":"1","post_id":"2"}],"page":{"current_page":"1","has_more":"0","has_prev":"0"}}"#,
      #"{"error_code":"0","at_list":[],"page":{"current_page":"2","has_more":"0","has_prev":"0"}}"#,
      #"{"error_code":"0","at_list":[],"page":{"current_page":"1","has_more":"2","has_prev":"0"}}"#,
    ]
    for raw in bodies {
      XCTAssertThrowsError(
        try TiebaNotificationDecoder.mentionPage(
          from: Data(raw.utf8),
          expectedUserID: userID,
          requestedPage: 1
        )
      )
    }
  }

  func testRejectsInvalidReplyIdentityFlagsDuplicatesAndPagination() throws {
    var missingSender = replyResponse()
    missingSender.data.replyList[0].clearReplyer()

    var invalidID = replyResponse()
    invalidID.data.replyList[0].postID = 0

    var invalidFlag = replyResponse()
    invalidFlag.data.replyList[0].isFloor = 2

    var duplicate = replyResponse()
    duplicate.data.replyList.append(duplicate.data.replyList[0])

    var wrongPage = replyResponse()
    wrongPage.data.page.currentPage = 2

    var impossibleForward = replyResponse()
    impossibleForward.data.replyList.removeAll()
    impossibleForward.data.page.hasMore_p = 1

    var missingError = replyResponse()
    missingError.clearError()

    for response in [
      missingSender, invalidID, invalidFlag, duplicate, wrongPage, impossibleForward,
      missingError,
    ] {
      XCTAssertThrowsError(
        try TiebaNotificationDecoder.replyPage(
          from: response,
          expectedUserID: userID,
          requestedPage: 1
        )
      )
    }
  }

  func testMapsReplyAndMentionServerErrors() throws {
    var reply = replyResponse()
    reply.error.errorno = 7
    reply.error.errmsg = "reply denied"
    XCTAssertThrowsError(
      try TiebaNotificationDecoder.replyPage(
        from: reply,
        expectedUserID: userID,
        requestedPage: 1
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 7, message: "reply denied"))
    }

    XCTAssertThrowsError(
      try TiebaNotificationDecoder.mentionPage(
        from: Data(#"{"error_code":"8","error_msg":"mention denied"}"#.utf8),
        expectedUserID: userID,
        requestedPage: 1
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 8, message: "mention denied"))
    }
  }

  func testClientUsesTwoMiBLimitForBothKindsAndRejectsOversizedBodies() async throws {
    let replyBody = try replyResponse().serializedData()
    let transport = NotificationStubTransport(
      responses: [
        .init(body: replyBody),
        .init(body: mentionBody()),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    _ = try await client.getNotifications(
      credential: credential(), expectedUserID: userID, kind: .replies
    )
    _ = try await client.getNotifications(
      credential: credential(), expectedUserID: userID, kind: .mentions
    )
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.notificationResponseMaximumBytes,
        TiebaAuthenticatedClient.notificationResponseMaximumBytes,
      ]
    )

    let oversized = NotificationStubTransport(
      responses: [
        .init(
          body: Data(
            repeating: 0,
            count: TiebaAuthenticatedClient.notificationResponseMaximumBytes + 1
          )
        )
      ]
    )
    let oversizedClient = TiebaAuthenticatedClient(transport: oversized)
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.notificationResponseMaximumBytes)
    ) {
      _ = try await oversizedClient.getNotifications(
        credential: credential(), expectedUserID: userID, kind: .mentions
      )
    }
  }

  func testClientRejectsMalformedProtobufAndInvalidArguments() async {
    let client = TiebaAuthenticatedClient(
      transport: NotificationStubTransport(responses: [.init(body: Data("not-protobuf".utf8))])
    )
    await assertError(.invalidProtobuf) {
      _ = try await client.getNotifications(
        credential: credential(), expectedUserID: userID, kind: .replies
      )
    }

    for page in [0, Int(Int32.max) + 1] {
      await assertAnyClientError {
        _ = try await client.getNotifications(
          credential: credential(), expectedUserID: userID, kind: .mentions, page: page
        )
      }
    }
    await assertAnyClientError {
      _ = try await client.getNotifications(
        credential: credential(), expectedUserID: 0, kind: .mentions
      )
    }
  }

  func testAuthenticatedNotificationTransportPolicyRejectsEveryRedirect() {
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tiebac.baidu.com/c/u/feed/atme"),
        to: URL(string: "https://tiebac.baidu.com/c/u/feed/atme?redirected=1")
      )
    )
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tiebac.baidu.com/c/u/feed/replyme?cmd=303007"),
        to: URL(string: "https://example.com/")
      )
    )
  }

  private func replyResponse(
    page pageNumber: Int32 = 1,
    hasMore: Bool = false,
    hasPrevious: Bool = false
  ) -> ReplyMeResIdl {
    var sender = User()
    sender.id = 123
    sender.name = "reply-user"
    sender.nameShow = "Reply Sender"
    sender.portrait = "portrait-token"
    sender.isFriend = 1

    var quotedUser = User()
    quotedUser.id = 456
    quotedUser.name = "quoted-user"
    quotedUser.nameShow = "Quoted User"

    var item = ReplyMeResIdl.DataRes.ReplyList()
    item.threadID = 42
    item.postID = 99
    item.time = 1_700_000_000
    item.fname = "swift"
    item.content = "reply text"
    item.isFloor = 1
    item.quoteContent = "quoted text"
    item.replyer = sender
    item.quotePid = 77
    item.quoteUser = quotedUser

    var page = Page()
    page.pageSize = 20
    page.currentPage = pageNumber
    page.totalCount = 61
    page.totalPage = hasMore ? max(pageNumber + 1, 4) : pageNumber
    page.hasMore_p = hasMore ? 1 : 0
    page.hasPrev_p = hasPrevious ? 1 : 0

    var data = ReplyMeResIdl.DataRes()
    data.page = page
    data.replyList = [item]

    var error = TiebaProto.Error()
    error.errorno = 0

    var response = ReplyMeResIdl()
    response.error = error
    response.data = data
    return response
  }

  private func mentionBody() -> Data {
    Data(
      #"{"error_code":"0","at_list":[{"thread_id":"43","post_id":"100","time":"1700000001","fname":"ios","title":"mentioned topic","content":"@account hello","quote_content":"quoted mention","quote_pid":"88","quote_user":{"id":"457","name":"quoted-mention","name_show":"Quoted Mention","portrait":"portrait-3"},"thread_type":"3","is_floor":"0","is_first_post":"1","unread":"1","replyer":{"id":"124","name":"mention-user","name_show":"Mention Sender","portrait":"portrait-2","is_friend":"0","is_fans":"1"}}],"page":{"current_page":"1","has_more":"1","has_prev":"0"}}"#.utf8
    )
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
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

  private func assertAnyClientError(operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Expected TiebaClientError")
    } catch is TiebaClientError {
      return
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}

private actor NotificationStubTransport: TiebaTransport {
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
