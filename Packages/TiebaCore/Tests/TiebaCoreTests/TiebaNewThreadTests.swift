import Foundation
import XCTest

@testable import TiebaCore
@testable import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaNewThreadTests: XCTestCase {
  private let userID: Int64 = 1_001
  private let forumID: Int64 = 2_002
  private let forumName = "swift"
  private let threadID: Int64 = 3_003
  private let firstPostID: Int64 = 4_004
  private let tbs = "0123456789abcdef0123456789"

  func testContentPolicyBoundsSwiftCharactersUTF8AndPlainTextBody() {
    XCTAssertTrue(TiebaNewThreadContentPolicy.isValidTitle(""))
    XCTAssertTrue(TiebaNewThreadContentPolicy.isValidTitle(String(repeating: "题", count: 31)))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidTitle(String(repeating: "题", count: 32)))

    let oversizedSingleCharacter = "a" + String(repeating: "\u{301}", count: 600)
    XCTAssertEqual(oversizedSingleCharacter.count, 1)
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidTitle(oversizedSingleCharacter))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidTitle("line\nbreak"))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidTitle("#(pic,1,2,3)"))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidTitle("#(呵呵)"))

    XCTAssertTrue(TiebaNewThreadContentPolicy.isValidContent("正文#(呵呵)#(哈哈)\n第二行\t🙂"))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidContent(""))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidContent("#(pic,1,2,3)"))
    XCTAssertFalse(TiebaNewThreadContentPolicy.isValidContent("unsafe\u{0}"))
    XCTAssertTrue(
      TiebaNewThreadContentPolicy.isValidContent(
        String(repeating: "a", count: TiebaNewThreadContentPolicy.maximumContentCharacterCount)
      )
    )
    XCTAssertFalse(
      TiebaNewThreadContentPolicy.isValidContent(
        String(
          repeating: "a",
          count: TiebaNewThreadContentPolicy.maximumContentCharacterCount + 1
        )
      )
    )
  }

  func testSubmissionDescriptionAndReflectionRedactForumTitleAndContent() {
    let submission = makeSubmission(
      title: "secret-title-4D54F14A",
      content: "secret-content-18D22C95",
      forumName: "secret-forum-A109F1C2"
    )
    XCTAssertEqual(String(describing: submission), "TiebaNewThreadSubmission(redacted)")
    for secret in [submission.title, submission.content, submission.forumName] {
      XCTAssertFalse(String(reflecting: submission).contains(secret))
    }
  }

  func testRequestUsesSignedHTTPSMinimalContractAndPreservesFormText() throws {
    let submission = makeSubmission(
      title: "题目 +%&=🙂",
      content: "第一行e\u{301}#(呵呵)\n第二行 +%&=🙂"
    )
    let request = try makeRequest(submission: submission)
    let parsed = try newThreadForm(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/thread/add")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 7.2.0.0")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )

    XCTAssertEqual(
      Set(parsed.fields.keys),
      [
        "BDUSS", "_client_type", "_client_version", "anonymous", "call_from",
        "can_no_forum", "content", "cuid_gid", "entrance_type", "fid", "from",
        "is_feedback", "is_hide", "is_ntitle", "kw", "name_show", "new_vcode",
        "reply_uid", "sign", "stoken", "subapp_type", "takephoto_num", "tbs", "title",
        "vcode_tag", "z_id",
      ]
    )
    XCTAssertEqual(
      parsed.orderedNames,
      parsed.orderedNames.filter { $0 != "sign" }.sorted() + ["sign"]
    )
    XCTAssertEqual(parsed.fields["content"], submission.content)
    XCTAssertEqual(parsed.fields["title"], submission.title)
    XCTAssertEqual(parsed.fields["fid"], String(forumID))
    XCTAssertEqual(parsed.fields["kw"], forumName)
    XCTAssertEqual(parsed.fields["name_show"], "Current User")
    XCTAssertEqual(parsed.fields["tbs"], tbs)
    XCTAssertEqual(parsed.fields["BDUSS"], credential().bduss)
    XCTAssertEqual(parsed.fields["stoken"], credential().stoken)
    XCTAssertEqual(parsed.fields["_client_type"], "2")
    XCTAssertEqual(parsed.fields["_client_version"], "7.2.0.0")
    XCTAssertEqual(parsed.fields["anonymous"], "1")
    XCTAssertEqual(parsed.fields["call_from"], "2")
    XCTAssertEqual(parsed.fields["can_no_forum"], "0")
    XCTAssertEqual(parsed.fields["cuid_gid"], "")
    XCTAssertEqual(parsed.fields["entrance_type"], "1")
    XCTAssertEqual(parsed.fields["from"], "1021636m")
    XCTAssertEqual(parsed.fields["is_feedback"], "0")
    XCTAssertEqual(parsed.fields["is_hide"], "1")
    XCTAssertEqual(parsed.fields["is_ntitle"], "0")
    XCTAssertEqual(parsed.fields["new_vcode"], "1")
    XCTAssertEqual(parsed.fields["reply_uid"], "null")
    XCTAssertEqual(parsed.fields["subapp_type"], "mini")
    XCTAssertEqual(parsed.fields["takephoto_num"], "0")
    XCTAssertEqual(parsed.fields["vcode_tag"], "12")
    XCTAssertEqual(parsed.fields["z_id"], "")
    XCTAssertEqual(
      parsed.fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: parsed.fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
      )
    )
    for forbidden in [
      "_client_id", "_model", "_net_type", "_os_version", "_phone_imei", "android_id",
      "cuid", "cuid_galaxy2", "device_score", "model", "oaid", "timestamp",
      "stErrorNums", "stMethod", "stMode", "stSize", "stTime", "stTimesNum",
    ] {
      XCTAssertNil(parsed.fields[forbidden])
      XCTAssertNil(request.value(forHTTPHeaderField: forbidden))
    }
  }

  func testUntitledPolarityAndSignedTitleAndContent() throws {
    let untitled = try newThreadForm(makeRequest(submission: makeSubmission(title: "")))
    XCTAssertEqual(untitled.fields["is_ntitle"], "1")
    XCTAssertEqual(untitled.fields["title"], "")

    let titled = try newThreadForm(makeRequest(submission: makeSubmission(title: "title")))
    let changedContent = try newThreadForm(
      makeRequest(submission: makeSubmission(title: "title", content: "different"))
    )
    let changedTitle = try newThreadForm(
      makeRequest(submission: makeSubmission(title: "different", content: "body"))
    )
    XCTAssertEqual(titled.fields["is_ntitle"], "0")
    XCTAssertNotEqual(titled.fields["sign"], changedContent.fields["sign"])
    XCTAssertNotEqual(titled.fields["sign"], changedTitle.fields["sign"])
  }

  func testRequestValidationRejectsInvalidIdentityTitleBodyAndTrustedMetadata() {
    for submission in [
      makeSubmission(forumID: 0),
      makeSubmission(title: String(repeating: "a", count: 32)),
      makeSubmission(content: "#(pic,1,2,3)"),
      makeSubmission(content: ""),
    ] {
      XCTAssertThrowsError(try makeRequest(submission: submission)) {
        guard case .invalidArgument = $0 as? TiebaClientError else {
          return XCTFail("Unexpected error: \($0)")
        }
      }
    }
    XCTAssertThrowsError(
      try makeRequest(submission: makeSubmission(), tbs: "invalid")
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    XCTAssertThrowsError(
      try makeRequest(submission: makeSubmission(), accountDisplayName: "")
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testImageProofRequestUsesCompiledContentAndRejectsCrossSubmissionReplay() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a")
    )
    let submission = makeSubmission(
      submissionID: submissionID,
      content: "正文",
      imageProofs: [proof]
    )
    XCTAssertEqual(
      try newThreadForm(makeRequest(submission: submission)).fields["content"],
      "正文\n#(pic,\(proof.picID),640,480)"
    )
    XCTAssertEqual(
      try newThreadForm(
        makeRequest(
          submission: makeSubmission(
            submissionID: submissionID,
            content: "",
            imageProofs: [proof]
          )
        )
      ).fields["content"],
      "#(pic,\(proof.picID),640,480)"
    )
    XCTAssertThrowsError(
      try makeRequest(submission: makeSubmission(content: "正文", imageProofs: [proof]))
    )
  }

  func testFRSPreflightBindsIdentityTBSAndTrustedDisplayName() throws {
    let response = newThreadForumResponse()
    let context = try TiebaAuthenticatedDecoder.newThreadContext(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )
    XCTAssertEqual(context.userID, userID)
    XCTAssertEqual(context.forumID, forumID)
    XCTAssertEqual(context.forumName, forumName)
    XCTAssertEqual(context.tbs, tbs)
    XCTAssertEqual(context.accountDisplayName, "Current User")
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains("Current User"))

    var fallback = response
    fallback.data.user.nameShow = ""
    fallback.data.user.name = "Fallback User"
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.newThreadContext(
        from: fallback,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      ).accountDisplayName,
      "Fallback User"
    )
  }

  func testFRSPreflightRejectsEveryIdentityAndMetadataMismatch() throws {
    var responses = [FrsPageResIdl]()
    responses.append(newThreadForumResponse(userID: userID + 1))
    responses.append(newThreadForumResponse(forumID: forumID + 1))
    responses.append(newThreadForumResponse(forumName: "other"))
    responses.append(newThreadForumResponse(tbs: "invalid"))
    responses.append(newThreadForumResponse(isLoggedIn: false))
    responses.append(newThreadForumResponse(displayName: ""))
    for response in responses {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadContext(
          from: response,
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testReceiptRequiresExplicitSuccessAndPositiveDecimalIDs() throws {
    let submission = makeSubmission()
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: Data(#"{"error_code":"0","tid":"3003","pid":4004}"#.utf8),
        submission: submission
      ),
      TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    )

    for body in [
      #"{"tid":"3003","pid":"4004"}"#,
      #"{"error_code":"0","tid":"0","pid":"4004"}"#,
      #"{"error_code":"0","tid":"3003","pid":"-1"}"#,
      #"{"error_code":"0","tid":"3.5","pid":"4004"}"#,
    ] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadReceipt(
          from: Data(body.utf8),
          submission: submission
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: Data("not-json".utf8),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
  }

  func testReceiptClassifiesChallengeBeforeServerError() {
    let submission = makeSubmission()
    for signal in [
      #""need_vcode":"1""#,
      #""need_vcode":true"#,
      #""vcode_md5":"token""#,
      #""vcode_pic_url":"https://example.invalid/vcode""#,
      #""pass_token":"token""#,
    ] {
      let body = Data(
        "{\"error_code\":\"340006\",\"msg\":\"需要验证\",\"info\":{\(signal)}}".utf8
      )
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadReceipt(from: body, submission: submission)
      ) {
        XCTAssertEqual(
          $0 as? TiebaClientError,
          .newThreadChallengeRequired(message: "需要验证")
        )
      }
    }

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: Data(#"{"error_code":"340006","errmsg":"denied"}"#.utf8),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: 340_006, message: "denied")) }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: Data(#"{"error_code":"-1","errmsg":"denied"}"#.utf8),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: -1, message: "denied")) }
  }

  func testReceiptDoesNotTreatEmptyFalseZeroOrNullNeedVcodeAsChallenge() throws {
    let submission = makeSubmission()
    let expected = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    for value in ["\"\"", "\"   \"", "false", "\"0\"", "0", "null"] {
      let body = Data(
        ("{\"error_code\":\"0\",\"tid\":\"3003\",\"pid\":\"4004\","
          + "\"info\":{\"need_vcode\":\(value),\"vcode_md5\":\"\","
          + "\"vcode_pic_url\":false,\"pass_token\":0}}").utf8
      )
      XCTAssertEqual(
        try TiebaAuthenticatedDecoder.newThreadReceipt(from: body, submission: submission),
        expected
      )
    }
  }

  func testReadbackConfirmsExactFirstFloorAndAllowsTemporaryAbsence() throws {
    let submission = makeSubmission(title: "A title", content: "body")
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    let context = newThreadContext()
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(title: submission.title, content: submission.content),
        context: context,
        submission: submission,
        receipt: receipt
      ),
      receipt
    )
    XCTAssertNil(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(
          title: submission.title,
          content: submission.content,
          includesFirstPost: false
        ),
        context: context,
        submission: submission,
        receipt: receipt
      )
    )
  }

  func testReadbackConfirmsStructuredType2And11EmoticonsAmongAdjacentText() throws {
    let content = "前#(呵呵)#(哈哈)后"
    let submission = makeSubmission(title: "A title", content: content)
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    let fragments = [
      contentFragment(type: 0, text: "前"),
      contentFragment(type: 2, c: "呵呵"),
      contentFragment(type: 11, c: "哈哈"),
      contentFragment(type: 0, text: "后"),
    ]
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(
          title: submission.title,
          content: "unused",
          contentFragments: fragments
        ),
        context: newThreadContext(),
        submission: submission,
        receipt: receipt
      ),
      receipt
    )
  }

  func testNewThreadImageReadbackSupportsType20AndRejectsWrongDimensions() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a")
    )
    let submission = makeSubmission(
      submissionID: submissionID,
      title: "A title",
      content: "正文",
      imageProofs: [proof]
    )
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    var image = contentFragment(type: 20)
    image.src = "https://tiebapic.baidu.com/forum/pic/item/\(proof.picID).jpg"
    image.width = 640
    image.height = 480
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(
          title: submission.title,
          content: "unused",
          contentFragments: [contentFragment(type: 0, text: "正文"), image]
        ),
        context: newThreadContext(),
        submission: submission,
        receipt: receipt
      ),
      receipt
    )

    image.height = 481
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(
          title: submission.title,
          content: "unused",
          contentFragments: [contentFragment(type: 0, text: "正文"), image]
        ),
        context: newThreadContext(),
        submission: submission,
        receipt: receipt
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testReadbackRejectsUnknownWrongTypeAndType0FakeEmoticons() {
    let content = "前#(呵呵)后"
    let submission = makeSubmission(title: "A title", content: content)
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    for fragment in [
      contentFragment(type: 2, c: "不存在"),
      contentFragment(type: 3, c: "呵呵"),
      contentFragment(type: 0, text: "#(呵呵)"),
    ] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.verifiedNewThread(
          from: newThreadPageResponse(
            title: submission.title,
            content: "unused",
            contentFragments: [
              contentFragment(type: 0, text: "前"), fragment,
              contentFragment(type: 0, text: "后"),
            ]
          ),
          context: newThreadContext(),
          submission: submission,
          receipt: receipt
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testReadbackComparesPlainTextByWireBytesWithoutNFCNormalization() {
    let decomposed = "e\u{301}"
    let precomposed = "\u{E9}"
    XCTAssertEqual(decomposed, precomposed)
    let submission = makeSubmission(title: "A title", content: decomposed)

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(title: submission.title, content: precomposed),
        context: newThreadContext(),
        submission: submission,
        receipt: TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testReadbackPreservesExistingStructuredMentionEquivalence() throws {
    let submission = makeSubmission(
      title: "A title",
      content: "@Target #(哈哈)"
    )
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(
          title: submission.title,
          content: "unused",
          contentFragments: [
            contentFragment(type: 4, text: "@Target"),
            contentFragment(type: 0, text: " "),
            contentFragment(type: 11, c: "哈哈"),
          ]
        ),
        context: newThreadContext(),
        submission: submission,
        receipt: receipt
      ),
      receipt
    )
  }

  func testReadbackRejectsForumAccountThreadTitleBodyAndAuthorMismatch() {
    let submission = makeSubmission(title: "A title", content: "body")
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    let context = newThreadContext()
    let responses = [
      newThreadPageResponse(
        userID: userID + 1, title: submission.title, content: submission.content),
      newThreadPageResponse(
        forumID: forumID + 1, title: submission.title, content: submission.content),
      newThreadPageResponse(
        threadID: threadID + 1, title: submission.title, content: submission.content),
      newThreadPageResponse(
        firstPostID: firstPostID + 1, title: submission.title, content: submission.content),
      newThreadPageResponse(title: "different", content: submission.content),
      newThreadPageResponse(title: submission.title, content: "different"),
      newThreadPageResponse(
        authorID: userID + 1, title: submission.title, content: submission.content),
    ]
    for response in responses {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.verifiedNewThread(
          from: response,
          context: context,
          submission: submission,
          receipt: receipt
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testUntitledReadbackDoesNotTrustServerGeneratedDisplayTitle() throws {
    let submission = makeSubmission(title: "", content: "body")
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.verifiedNewThread(
        from: newThreadPageResponse(title: "server generated title", content: submission.content),
        context: newThreadContext(),
        submission: submission,
        receipt: receipt
      ),
      receipt
    )
  }

  private func credential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func makeSubmission(
    submissionID: UUID? = nil,
    title: String = "title",
    content: String = "body",
    forumID: Int64? = nil,
    forumName: String? = nil,
    imageProofs: [TiebaStaticImageContentProof] = []
  ) -> TiebaNewThreadSubmission {
    TiebaNewThreadSubmission(
      submissionID: submissionID ?? UUID(),
      forumID: forumID ?? self.forumID,
      forumName: forumName ?? self.forumName,
      title: title,
      content: content,
      imageProofs: imageProofs
    )
  }

  private func makeRequest(
    submission: TiebaNewThreadSubmission,
    tbs: String? = nil,
    accountDisplayName: String = "Current User"
  ) throws -> URLRequest {
    try TiebaAuthenticatedRequestFactory(configuration: .init()).newThread(
      credential: credential(),
      expectedUserID: userID,
      submission: submission,
      normalizedForumName: submission.forumName.trimmingCharacters(in: .whitespacesAndNewlines),
      tbs: tbs ?? self.tbs,
      accountDisplayName: accountDisplayName
    )
  }

  private func newThreadForm(_ request: URLRequest) throws -> (
    fields: [String: String], orderedNames: [String]
  ) {
    let body = try XCTUnwrap(request.httpBody)
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    let items = try XCTUnwrap(components.queryItems)
    return (
      Dictionary(
        uniqueKeysWithValues: items.compactMap { item in
          item.value.map { (item.name, $0) }
        }),
      items.map(\.name)
    )
  }

  private func newThreadForumResponse(
    userID: Int64? = nil,
    forumID: Int64? = nil,
    forumName: String? = nil,
    tbs: String? = nil,
    isLoggedIn: Bool = true,
    displayName: String = "Current User"
  ) -> FrsPageResIdl {
    var user = User()
    user.id = userID ?? self.userID
    user.isLogin = isLoggedIn ? 1 : 0
    user.name = displayName.isEmpty ? "" : "current"
    user.nameShow = displayName
    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID ?? self.forumID
    forum.name = forumName ?? self.forumName
    forum.isLike = 0
    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs ?? self.tbs
    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti
    var response = FrsPageResIdl()
    response.data = data
    return response
  }

  private func newThreadContext() -> TiebaNewThreadContext {
    TiebaNewThreadContext(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      tbs: tbs,
      accountDisplayName: "Current User"
    )
  }

  private func newThreadPageResponse(
    userID: Int64? = nil,
    forumID: Int64? = nil,
    threadID: Int64? = nil,
    firstPostID: Int64? = nil,
    authorID: Int64? = nil,
    title: String,
    content: String,
    contentFragments: [PbContent]? = nil,
    includesFirstPost: Bool = true
  ) -> PbPageResIdl {
    let resolvedUserID = userID ?? self.userID
    let resolvedForumID = forumID ?? self.forumID
    let resolvedThreadID = threadID ?? self.threadID
    let resolvedFirstPostID = firstPostID ?? self.firstPostID
    let resolvedAuthorID = authorID ?? self.userID
    var account = User()
    account.isLogin = 1
    account.id = resolvedUserID
    var forum = SimpleForum()
    forum.id = resolvedForumID
    forum.name = self.forumName
    var author = User()
    author.id = resolvedAuthorID
    var thread = ThreadInfo()
    thread.id = resolvedThreadID
    thread.fid = resolvedForumID
    thread.firstPostID = resolvedFirstPostID
    thread.title = title
    thread.authorID = resolvedAuthorID
    thread.author = author
    var fragment = PbContent()
    fragment.type = 0
    fragment.text = content
    var post = Post()
    post.id = self.firstPostID
    post.floor = 1
    post.tid = resolvedThreadID
    post.authorID = resolvedAuthorID
    post.author = author
    post.content = contentFragments ?? [fragment]
    var page = Page()
    page.currentPage = 1
    page.totalPage = 1
    page.pageSize = 2
    var data = PbPageResIdl.DataRes()
    data.user = account
    data.forum = forum
    data.thread = thread
    data.page = page
    if includesFirstPost { data.firstFloorPost = post }
    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func contentFragment(
    type: UInt32,
    text: String = "",
    c: String = ""
  ) -> PbContent {
    var fragment = PbContent()
    fragment.type = type
    fragment.text = text
    fragment.c = c
    return fragment
  }
}
