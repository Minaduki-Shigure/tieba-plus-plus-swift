import Foundation
import SwiftProtobuf
import XCTest

@testable import TiebaCore
@testable import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaTextReplyTests: XCTestCase, @unchecked Sendable {
  private let userID: Int64 = 1_001
  private let forumID: Int64 = 2_002
  private let threadID: Int64 = 3_003
  private let firstPostID: Int64 = 4_004
  private let parentPostID: Int64 = 5_005
  private let targetSubpostID: Int64 = 6_006
  private let createdPostID: Int64 = 7_007
  private let forumName = "swift"
  private let tbs = "0123456789abcdef0123456789"

  func testContentPolicyPreservesUsefulWhitespaceAndRejectsUnsafeInput() {
    XCTAssertTrue(TiebaTextReplyContentPolicy.isValid("  hello\nworld  "))
    XCTAssertTrue(
      TiebaTextReplyContentPolicy.isValid(
        String(repeating: "a", count: TiebaTextReplyContentPolicy.maximumCharacterCount)
      )
    )
    XCTAssertFalse(TiebaTextReplyContentPolicy.isValid(" \n\t "))
    XCTAssertFalse(TiebaTextReplyContentPolicy.isValid("text\u{0000}"))
    XCTAssertFalse(TiebaTextReplyContentPolicy.isValid("#(pic,1,2,3)"))
    XCTAssertFalse(
      TiebaTextReplyContentPolicy.isValid(
        String(repeating: "a", count: TiebaTextReplyContentPolicy.maximumCharacterCount + 1)
      )
    )
    XCTAssertFalse(
      TiebaTextReplyContentPolicy.isValid(
        String(
          repeating: "😀",
          count: TiebaTextReplyContentPolicy.maximumUTF8ByteCount / 4 + 1
        )
      )
    )
  }

  func testSubmissionDescriptionAndReflectionRedactContentAndForumName() {
    let secretContent = "private draft body"
    let secretForumName = "private-forum"
    let submission = TiebaTextReplySubmission(
      submissionID: UUID(),
      forumID: forumID,
      forumName: secretForumName,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      content: secretContent
    )
    XCTAssertEqual(String(describing: submission), "TiebaTextReplySubmission(redacted)")
    XCTAssertFalse(String(reflecting: submission).contains(secretContent))
    XCTAssertFalse(String(reflecting: submission).contains(secretForumName))
    XCTAssertEqual(
      Mirror(reflecting: submission).children.count,
      5
    )
  }

  func testThreadReplyRequestUsesSignedMinimalContract() throws {
    let submission = makeSubmission(target: .thread(firstPostID: firstPostID))
    let request = try makeRequest(submission: submission)
    let parsed = try parseMultipart(request)
    let message = try AddPostReqIdl(serializedBytes: parsed.protobuf)

    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
    XCTAssertEqual(request.url?.path, "/c/c/post/add")
    XCTAssertEqual(queryItems(request.url)["cmd"], "309731")
    XCTAssertEqual(queryItems(request.url)["format"], "protobuf")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(
      Set(parsed.fields.keys),
      Set(["BDUSS", "_client_type", "_client_version", "stoken", "sign"])
    )
    XCTAssertEqual(
      parsed.orderedFieldNames,
      ["BDUSS", "_client_type", "_client_version", "stoken", "sign"]
    )
    XCTAssertEqual(parsed.fields["BDUSS"], credential().bduss)
    XCTAssertEqual(parsed.fields["stoken"], credential().stoken)
    XCTAssertEqual(parsed.fields["_client_type"], "2")
    XCTAssertEqual(parsed.fields["_client_version"], "12.35.1.0")
    assertSignature(parsed.fields)
    let differentPayload = try parseMultipart(
      makeRequest(
        submission: makeSubmission(
          target: .thread(firstPostID: firstPostID),
          content: "different body"
        )
      )
    )
    XCTAssertEqual(differentPayload.fields["sign"], parsed.fields["sign"])
    XCTAssertNotEqual(differentPayload.protobuf, parsed.protobuf)

    XCTAssertEqual(message.data.common.bduss, credential().bduss)
    XCTAssertEqual(message.data.common.stoken, credential().stoken)
    XCTAssertEqual(message.data.common.tbs, tbs)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(message.data.common.clientVersion, "12.35.1.0")
    XCTAssertEqual(message.data.content, submission.content)
    XCTAssertEqual(message.data.fid, String(forumID))
    XCTAssertEqual(message.data.kw, forumName)
    XCTAssertEqual(message.data.tid, String(threadID))
    XCTAssertEqual(message.data.nameShow, "Current User")
    XCTAssertEqual(message.data.postFrom, "13")
    XCTAssertEqual(message.data.barrageTime, "0")
    XCTAssertTrue(message.data.hasVFid)
    XCTAssertTrue(message.data.hasVFname)
    XCTAssertFalse(message.data.hasReplyUid)
    XCTAssertFalse(message.data.hasQuoteID)
    XCTAssertFalse(message.data.hasRepostid)
    XCTAssertFalse(message.data.hasSubPostID)
    assertCommonReplyFlags(message.data)
    assertNoDeviceMetadata(in: parsed.fields)
  }

  func testPostReplyRequestBindsParentAndServerDerivedAuthor() throws {
    let submission = makeSubmission(target: .post(postID: parentPostID))
    let message = try AddPostReqIdl(
      serializedBytes: parseMultipart(
        makeRequest(submission: submission, replyUserID: 8_008)
      ).protobuf
    )

    XCTAssertEqual(message.data.content, submission.content)
    XCTAssertEqual(message.data.replyUid, "8008")
    XCTAssertEqual(message.data.quoteID, String(parentPostID))
    XCTAssertEqual(message.data.repostid, String(parentPostID))
    XCTAssertEqual(message.data.postFrom, "0")
    XCTAssertFalse(message.data.hasSubPostID)
    XCTAssertFalse(message.data.hasBarrageTime)
    XCTAssertFalse(message.data.hasVFid)
    XCTAssertFalse(message.data.hasVFname)
  }

  func testSubpostReplyRequestBuildsOnlyTheProtocolOwnedReplyMarker() throws {
    let submission = makeSubmission(
      target: .subpost(parentPostID: parentPostID, subpostID: targetSubpostID),
      content: "plain body"
    )
    let message = try AddPostReqIdl(
      serializedBytes: parseMultipart(
        makeRequest(
          submission: submission,
          replyUserID: 9_009,
          replyUserDisplayName: "Target User",
          replyUserPortrait: "portrait-token"
        )
      ).protobuf
    )

    XCTAssertEqual(
      message.data.content,
      "回复 #(reply, portrait-token, Target User) :plain body"
    )
    XCTAssertEqual(message.data.replyUid, "9009")
    XCTAssertEqual(message.data.quoteID, String(parentPostID))
    XCTAssertEqual(message.data.repostid, String(parentPostID))
    XCTAssertEqual(message.data.subPostID, String(targetSubpostID))
    XCTAssertFalse(message.data.hasPostFrom)
  }

  func testRequestValidationRejectsRichMarkerAndIncompleteNestedIdentity() {
    let unsafe = makeSubmission(
      target: .thread(firstPostID: firstPostID),
      content: "#(pic,1,2,3)"
    )
    XCTAssertThrowsError(try makeRequest(submission: unsafe)) {
      guard let error = $0 as? TiebaClientError, case .invalidArgument = error else {
        return XCTFail("Unexpected error: \($0)")
      }
    }

    let nested = makeSubmission(
      target: .subpost(parentPostID: parentPostID, subpostID: targetSubpostID)
    )
    XCTAssertThrowsError(
      try makeRequest(
        submission: nested,
        replyUserID: 9_009,
        replyUserDisplayName: "Target User",
        replyUserPortrait: ""
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

  }

  func testReceiptDecoderReturnsTypedIdentifiersAndPrefersUserMessage() throws {
    let submission = makeSubmission(target: .thread(firstPostID: firstPostID))
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: try addPostResponse().serializedData(),
        submission: submission
      ),
      .post(postID: createdPostID)
    )

    var rejection = addPostResponse(errorCode: 123, errorMessage: "internal")
    rejection.error.userMsg = "请稍后再试"
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: try rejection.serializedData(),
        submission: submission
      )
    ) {
      XCTAssertEqual(
        $0 as? TiebaClientError,
        .server(code: 123, message: "请稍后再试")
      )
    }
  }

  func testReceiptDecoderFailsClosedForEveryChallengeEnvelope() throws {
    let submission = makeSubmission(target: .thread(firstPostID: firstPostID))

    var vcode = addPostResponse()
    var info = PostAntiInfo()
    info.needVcode = "1"
    info.blockContent = "需要验证"
    vcode.data.info = info
    assertChallenge(vcode, submission: submission, message: "需要验证")

    var hidden = addPostResponse()
    var antiStat = PostAntiStat()
    antiStat.hideStat = 1
    antiStat.forbidInfo = "内容受限"
    hidden.data.antiStat = antiStat
    assertChallenge(hidden, submission: submission, message: "内容受限")

    var access = addPostResponse()
    var accessState = AccessState()
    accessState.type = "verify"
    var accessInfo = PostAntiInfo()
    accessInfo.accessState = accessState
    access.data.info = accessInfo
    assertChallenge(
      access,
      submission: submission,
      message: "Tieba requires additional verification before this reply can be submitted."
    )

    var anti = addPostResponse()
    var vcodeInfo = VcodeInfo()
    vcodeInfo.vcodeMd5 = "token"
    anti.data.anti = vcodeInfo
    assertChallenge(
      anti,
      submission: submission,
      message: "Tieba requires additional verification before this reply can be submitted."
    )

    var extraOnly = addPostResponse()
    var extra = VcodeExtra()
    extra.slideendpoint = "https://example.invalid/challenge"
    var extraInfo = VcodeInfo()
    extraInfo.vcodeExtra = extra
    extraOnly.data.anti = extraInfo
    assertChallenge(
      extraOnly,
      submission: submission,
      message: "Tieba requires additional verification before this reply can be submitted."
    )
  }

  func testReceiptDecoderRequiresExplicitErrorEnvelopeAndMatchingThread() throws {
    let submission = makeSubmission(target: .thread(firstPostID: firstPostID))
    var missingError = addPostResponse()
    missingError.clearError()
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: try missingError.serializedData(),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var wrongThread = addPostResponse()
    wrongThread.data.tid = "999"
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: try wrongThread.serializedData(),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testPageContextBindsAccountForumThreadFreshTBSAndOrdinaryPost() throws {
    let targetAuthorID: Int64 = 8_008
    let response = pageResponse(
      locatedPostID: parentPostID,
      locatedFloor: 2,
      locatedAuthorID: targetAuthorID,
      locatedContent: "parent"
    )
    let context = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: parentPostID)
    )
    XCTAssertEqual(context.userID, userID)
    XCTAssertEqual(context.replyUserID, targetAuthorID)
    XCTAssertEqual(context.tbs, tbs)
    XCTAssertEqual(context.accountDisplayName, "Current User")

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplyPageContext(
        from: pageResponse(
          locatedPostID: firstPostID,
          locatedFloor: 1,
          locatedAuthorID: targetAuthorID,
          locatedContent: "topic"
        ),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: firstPostID)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testNestedContextRequiresExactTargetAndNonemptyPresentationIdentity() throws {
    let parent = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: pageResponse(
        locatedPostID: parentPostID,
        locatedFloor: 2,
        locatedAuthorID: 8_008,
        locatedContent: "parent"
      ),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .subpost(parentPostID: parentPostID, subpostID: targetSubpostID)
    )
    let context = try TiebaAuthenticatedDecoder.textReplySubpostContext(
      from: floorResponse(
        subpostID: targetSubpostID,
        subpostAuthorID: 9_009,
        subpostAuthorName: "Target User",
        subpostAuthorPortrait: "portrait-token",
        subpostContent: "target"
      ),
      parentContext: parent,
      subpostID: targetSubpostID
    )
    XCTAssertEqual(context.replyUserID, 9_009)
    XCTAssertEqual(context.replyUserDisplayName, "Target User")
    XCTAssertEqual(context.replyUserPortrait, "portrait-token")

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplySubpostContext(
        from: floorResponse(
          subpostID: targetSubpostID,
          subpostAuthorID: 9_009,
          subpostAuthorName: "Target User",
          subpostAuthorPortrait: "",
          subpostContent: "target"
        ),
        parentContext: parent,
        subpostID: targetSubpostID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testFirstPostNestedReplyContextAndReadbackRemainSubposts() throws {
    let parent = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: pageResponse(
        locatedPostID: firstPostID,
        locatedFloor: 1,
        locatedAuthorID: 8_008,
        locatedContent: "topic"
      ),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .subpost(parentPostID: firstPostID, subpostID: targetSubpostID)
    )
    let context = try TiebaAuthenticatedDecoder.textReplySubpostContext(
      from: floorResponse(
        parentPostID: firstPostID,
        parentFloor: 1,
        subpostID: targetSubpostID,
        subpostAuthorID: 9_009,
        subpostAuthorName: "Target User",
        subpostAuthorPortrait: "portrait-token",
        subpostContent: "target"
      ),
      parentContext: parent,
      subpostID: targetSubpostID
    )

    let created = try XCTUnwrap(
      TiebaAuthenticatedDecoder.verifiedTextReplySubpost(
        from: floorResponse(
          parentPostID: firstPostID,
          parentFloor: 1,
          subpostID: createdPostID,
          subpostAuthorID: userID,
          subpostAuthorName: "Current User",
          subpostAuthorPortrait: "current-portrait",
          subpostContent: "body",
          replyMentionUserID: 9_009
        ),
        context: context,
        newSubpostID: createdPostID,
        content: "body"
      )
    )
    XCTAssertEqual(created, .subpost(parentPostID: firstPostID, subpostID: createdPostID))
  }

  func testReadbackOnlyTreatsMissingExactIDAsAwaitingVisibility() throws {
    XCTAssertNil(
      try TiebaAuthenticatedDecoder.verifiedTextReplyPost(
        from: pageResponse(
          locatedPostID: parentPostID,
          locatedFloor: 2,
          locatedAuthorID: userID,
          locatedContent: "body"
        ),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        postID: createdPostID,
        content: "body"
      )
    )

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.verifiedTextReplyPost(
        from: pageResponse(
          locatedPostID: createdPostID,
          locatedFloor: 3,
          locatedAuthorID: userID,
          locatedContent: "different"
        ),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        postID: createdPostID,
        content: "body"
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testSubpostReadbackRejectsExactIDWithWrongMention() throws {
    let parent = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: pageResponse(
        locatedPostID: parentPostID,
        locatedFloor: 2,
        locatedAuthorID: 8_008,
        locatedContent: "parent"
      ),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .subpost(parentPostID: parentPostID, subpostID: targetSubpostID)
    )
    let context = try TiebaAuthenticatedDecoder.textReplySubpostContext(
      from: floorResponse(
        subpostID: targetSubpostID,
        subpostAuthorID: 9_009,
        subpostAuthorName: "Target User",
        subpostAuthorPortrait: "portrait-token",
        subpostContent: "target"
      ),
      parentContext: parent,
      subpostID: targetSubpostID
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.verifiedTextReplySubpost(
        from: floorResponse(
          subpostID: createdPostID,
          subpostAuthorID: userID,
          subpostAuthorName: "Current User",
          subpostAuthorPortrait: "current-portrait",
          subpostContent: "body",
          replyMentionUserID: 99_999
        ),
        context: context,
        newSubpostID: createdPostID,
        content: "body"
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var malformedOrder = floorResponse(
      subpostID: createdPostID,
      subpostAuthorID: userID,
      subpostAuthorName: "Current User",
      subpostAuthorPortrait: "current-portrait",
      subpostContent: "body",
      replyMentionUserID: 9_009
    )
    var unexpected = PbContent()
    unexpected.type = 0
    unexpected.text = "unexpected"
    var malformedSubpost = malformedOrder.data.subpostList[0]
    malformedSubpost.content.insert(unexpected, at: 0)
    malformedOrder.data.subpostList[0] = malformedSubpost
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.verifiedTextReplySubpost(
        from: malformedOrder,
        context: context,
        newSubpostID: createdPostID,
        content: "body"
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  private func credential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func makeSubmission(
    target: TiebaTextReplyTarget,
    content: String = "body"
  ) -> TiebaTextReplySubmission {
    TiebaTextReplySubmission(
      submissionID: UUID(),
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target,
      content: content
    )
  }

  private func makeRequest(
    submission: TiebaTextReplySubmission,
    replyUserID: Int64? = nil,
    replyUserDisplayName: String? = nil,
    replyUserPortrait: String? = nil
  ) throws -> URLRequest {
    try TiebaAuthenticatedRequestFactory(configuration: .init()).textReply(
      credential: credential(),
      expectedUserID: userID,
      submission: submission,
      normalizedForumName: forumName,
      tbs: tbs,
      accountDisplayName: "Current User",
      replyUserID: replyUserID,
      replyUserDisplayName: replyUserDisplayName,
      replyUserPortrait: replyUserPortrait
    )
  }

  private func assertCommonReplyFlags(
    _ data: AddPostReqIdl.DataReq,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(data.anonymous, "1", file: file, line: line)
    XCTAssertEqual(data.canNoForum, "0", file: file, line: line)
    XCTAssertEqual(data.isFeedback, "0", file: file, line: line)
    XCTAssertEqual(data.takephotoNum, "0", file: file, line: line)
    XCTAssertEqual(data.entranceType, "0", file: file, line: line)
    XCTAssertEqual(data.vcodeTag, "12", file: file, line: line)
    XCTAssertEqual(data.newVcode, "1", file: file, line: line)
    XCTAssertEqual(data.isBarrage, "0", file: file, line: line)
    XCTAssertTrue(data.hasIsBarrage, file: file, line: line)
    XCTAssertEqual(data.isTwzhiboThread, "0", file: file, line: line)
    XCTAssertTrue(data.hasIsTwzhiboThread, file: file, line: line)
    XCTAssertEqual(data.floorNum, "0", file: file, line: line)
    XCTAssertTrue(data.hasFloorNum, file: file, line: line)
    XCTAssertEqual(data.isAd, "0", file: file, line: line)
    XCTAssertEqual(data.isAddition, "0", file: file, line: line)
    XCTAssertTrue(data.hasIsAddition, file: file, line: line)
    XCTAssertEqual(data.isGiftpost, "0", file: file, line: line)
    XCTAssertTrue(data.hasIsGiftpost, file: file, line: line)
    XCTAssertEqual(data.isPictxt, "0", file: file, line: line)
    XCTAssertEqual(data.showCustomFigure, 0, file: file, line: line)
    XCTAssertTrue(data.hasShowCustomFigure, file: file, line: line)
    XCTAssertEqual(data.isShowBless, 0, file: file, line: line)
    XCTAssertTrue(data.hasIsShowBless, file: file, line: line)
  }

  private func assertNoDeviceMetadata(
    in fields: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for forbidden in [
      "_phone_imei", "android_id", "brand", "cuid", "cuid_galaxy2", "device_score",
      "first_install_time", "last_update_time", "model", "oaid", "z_id", "lat", "lng",
    ] {
      XCTAssertNil(fields[forbidden], file: file, line: line)
    }
  }

  private func assertSignature(
    _ fields: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let unsigned = fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(for: unsigned),
      file: file,
      line: line
    )
  }

  private func addPostResponse(
    errorCode: Int32 = 0,
    errorMessage: String = ""
  ) -> AddPostResIdl {
    var error = TiebaProto.Error()
    error.errorno = errorCode
    error.errmsg = errorMessage
    var data = AddPostResIdl.DataRes()
    data.tid = String(threadID)
    data.pid = String(createdPostID)
    var response = AddPostResIdl()
    response.error = error
    response.data = data
    return response
  }

  private func assertChallenge(
    _ response: AddPostResIdl,
    submission: TiebaTextReplySubmission,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: response.serializedData(),
        submission: submission
      ),
      file: file,
      line: line
    ) {
      XCTAssertEqual(
        $0 as? TiebaClientError,
        .replyChallengeRequired(message: message),
        file: file,
        line: line
      )
    }
  }

  private func pageResponse(
    locatedPostID: Int64,
    locatedFloor: UInt32,
    locatedAuthorID: Int64,
    locatedContent: String
  ) -> PbPageResIdl {
    var account = User()
    account.isLogin = 1
    account.id = userID
    account.name = "current"
    account.nameShow = "Current User"
    account.portrait = "current-portrait"

    var forum = SimpleForum()
    forum.id = forumID
    forum.name = forumName

    var thread = ThreadInfo()
    thread.id = threadID
    thread.fid = forumID
    thread.firstPostID = firstPostID

    var author = User()
    author.id = locatedAuthorID
    author.name = "author"
    author.nameShow = locatedAuthorID == userID ? "Current User" : "Target User"
    author.portrait = locatedAuthorID == userID ? "current-portrait" : "target-portrait"
    var text = PbContent()
    text.type = 0
    text.text = locatedContent
    var post = Post()
    post.id = locatedPostID
    post.floor = locatedFloor
    post.tid = threadID
    post.authorID = locatedAuthorID
    post.author = author
    post.content = [text]

    var anti = Anti()
    anti.tbs = tbs
    var page = Page()
    page.currentPage = 1
    page.totalPage = 1
    page.pageSize = 2
    var data = PbPageResIdl.DataRes()
    data.user = account
    data.forum = forum
    data.thread = thread
    data.anti = anti
    data.page = page
    data.postList = [post]
    if locatedPostID == firstPostID {
      data.firstFloorPost = post
      data.postList = []
    }
    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func floorResponse(
    parentPostID: Int64? = nil,
    parentFloor: UInt32 = 2,
    subpostID: Int64,
    subpostAuthorID: Int64,
    subpostAuthorName: String,
    subpostAuthorPortrait: String,
    subpostContent: String,
    replyMentionUserID: Int64? = nil
  ) -> PbFloorResIdl {
    var forum = SimpleForum()
    forum.id = forumID
    forum.name = forumName
    var thread = ThreadInfo()
    thread.id = threadID
    thread.fid = forumID
    thread.firstPostID = firstPostID
    let resolvedParentPostID = parentPostID ?? self.parentPostID
    var parent = Post()
    parent.id = resolvedParentPostID
    parent.floor = parentFloor
    parent.tid = threadID

    var author = User()
    author.id = subpostAuthorID
    author.name = subpostAuthorName
    author.nameShow = subpostAuthorName
    author.portrait = subpostAuthorPortrait
    var subpost = SubPostList()
    subpost.id = subpostID
    subpost.authorID = subpostAuthorID
    subpost.author = author
    if let replyMentionUserID {
      var prefix = PbContent()
      prefix.type = 0
      prefix.text = "回复"
      var mention = PbContent()
      mention.type = 4
      mention.uid = replyMentionUserID
      mention.text = "Target User"
      var suffix = PbContent()
      suffix.type = 0
      suffix.text = ":\(subpostContent)"
      subpost.content = [prefix, mention, suffix]
    } else {
      var text = PbContent()
      text.type = 0
      text.text = subpostContent
      subpost.content = [text]
    }

    var anti = Anti()
    anti.tbs = tbs
    var page = Page()
    page.currentPage = 1
    page.totalPage = 1
    page.pageSize = 20
    var data = PbFloorResIdl.DataRes()
    data.forum = forum
    data.thread = thread
    data.post = parent
    data.subpostList = [subpost]
    data.anti = anti
    data.page = page
    var response = PbFloorResIdl()
    response.data = data
    return response
  }
}

private struct ParsedReplyMultipart {
  let fields: [String: String]
  let orderedFieldNames: [String]
  let protobuf: Data
}

private func parseMultipart(_ request: URLRequest) throws -> ParsedReplyMultipart {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  let boundary = TiebaRequestFactory.multipartBoundary
  let dataHeader = Data(
    ("--\(boundary)\r\n"
      + "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n").utf8
  )
  guard let dataHeaderRange = body.range(of: dataHeader) else {
    throw TiebaClientError.transportFailure
  }
  let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
  guard body.suffix(suffix.count) == suffix else {
    throw TiebaClientError.transportFailure
  }
  let protobufStart = dataHeaderRange.upperBound
  let protobufEnd = body.count - suffix.count
  let protobuf = body.subdata(in: protobufStart..<protobufEnd)
  let fieldPrefix = body.subdata(in: 0..<dataHeaderRange.lowerBound)
  let fieldText = String(decoding: fieldPrefix, as: UTF8.self)
  let parts = fieldText.components(separatedBy: "--\(boundary)\r\n")
  var fields = [String: String]()
  var orderedFieldNames = [String]()
  for part in parts where !part.isEmpty {
    let separator = "\r\n\r\n"
    guard let separatorRange = part.range(of: separator) else {
      throw TiebaClientError.transportFailure
    }
    let header = String(part[..<separatorRange.lowerBound])
    var value = String(part[separatorRange.upperBound...])
    if value.hasSuffix("\r\n") { value.removeLast(2) }
    let prefix = "Content-Disposition: form-data; name=\""
    guard header.hasPrefix(prefix), header.hasSuffix("\"") else {
      throw TiebaClientError.transportFailure
    }
    let name = String(header.dropFirst(prefix.count).dropLast())
    guard fields.updateValue(value, forKey: name) == nil else {
      throw TiebaClientError.transportFailure
    }
    orderedFieldNames.append(name)
  }
  return ParsedReplyMultipart(
    fields: fields,
    orderedFieldNames: orderedFieldNames,
    protobuf: protobuf
  )
}

private func queryItems(_ url: URL?) -> [String: String] {
  guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
  else { return [:] }
  return Dictionary(uniqueKeysWithValues: items.compactMap { item in
    item.value.map { (item.name, $0) }
  })
}
