import Foundation
import SwiftProtobuf
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

  func testRequestUsesSignedHTTPSMultipartContractAndPreservesContentBytes() throws {
    let submission = makeSubmission(
      title: "题目 +%&=🙂",
      content: "第一行e\u{301}#(呵呵)\n第二行 +%&=🙂"
    )
    let request = try makeRequest(submission: submission)
    let parsed = try newThreadMultipart(request)
    let message = try AddThreadReqIdl(serializedBytes: parsed.protobuf)

    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
    XCTAssertEqual(request.url?.path, "/c/c/thread/add")
    let queryItems = try XCTUnwrap(
      URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
    )
    XCTAssertEqual(queryItems, [
      URLQueryItem(name: "cmd", value: "309730"),
      URLQueryItem(name: "format", value: "protobuf"),
    ])
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.52.1.0")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)"
    )

    XCTAssertEqual(
      Set(parsed.fields.keys),
      ["BDUSS", "_client_type", "_client_version", "stoken", "sign"]
    )
    XCTAssertEqual(
      parsed.orderedNames,
      ["BDUSS", "_client_type", "_client_version", "stoken", "sign"]
    )
    XCTAssertEqual(parsed.fields["BDUSS"], credential().bduss)
    XCTAssertEqual(parsed.fields["stoken"], credential().stoken)
    XCTAssertEqual(parsed.fields["_client_type"], "2")
    XCTAssertEqual(parsed.fields["_client_version"], "12.52.1.0")

    XCTAssertTrue(message.hasData)
    XCTAssertTrue(message.data.hasCommon)
    // The entire CommonReq must equal this minimal allowlist: adding a device
    // identifier, timestamp, location or other telemetry would fail equality.
    var expectedCommon = CommonReq()
    expectedCommon.clientType = 2
    expectedCommon.clientVersion = "12.52.1.0"
    expectedCommon.bduss = credential().bduss
    expectedCommon.stoken = credential().stoken
    expectedCommon.tbs = tbs
    XCTAssertEqual(message.data.common, expectedCommon)
    XCTAssertEqual(Array(message.data.content.utf8), Array(submission.content.utf8))
    XCTAssertEqual(message.data.title, submission.title)
    XCTAssertEqual(message.data.fid, String(forumID))
    XCTAssertEqual(message.data.kw, forumName)
    XCTAssertEqual(message.data.nameShow, "Current User")
    XCTAssertEqual(message.data.anonymous, "1")
    XCTAssertEqual(message.data.canNoForum, "0")
    XCTAssertEqual(message.data.entranceType, "0")
    XCTAssertEqual(message.data.isHide, "1")
    XCTAssertEqual(message.data.isNtitle, "0")
    XCTAssertEqual(message.data.newVcode, "1")
    XCTAssertEqual(message.data.takephotoNum, "0")
    XCTAssertEqual(message.data.vcodeTag, "12")
    XCTAssertEqual(message.data.isPictxt, "0")
    XCTAssertTrue(message.data.hasShowCustomFigure)
    XCTAssertEqual(message.data.showCustomFigure, 0)
    XCTAssertTrue(message.data.hasIsShowBless)
    XCTAssertEqual(message.data.isShowBless, 0)
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

  func testUntitledPolarityAndPayloadChangesPreserveCredentialOnlySignature() throws {
    let untitled = try AddThreadReqIdl(
      serializedBytes: newThreadMultipart(makeRequest(submission: makeSubmission(title: ""))).protobuf
    )
    XCTAssertEqual(untitled.data.isNtitle, "1")
    XCTAssertEqual(untitled.data.title, "")

    let titled = try newThreadMultipart(makeRequest(submission: makeSubmission(title: "title")))
    let changedContent = try newThreadMultipart(
      makeRequest(submission: makeSubmission(title: "title", content: "different"))
    )
    let changedTitle = try newThreadMultipart(
      makeRequest(submission: makeSubmission(title: "different", content: "body"))
    )
    XCTAssertEqual(try AddThreadReqIdl(serializedBytes: titled.protobuf).data.isNtitle, "0")
    XCTAssertEqual(
      try AddThreadReqIdl(serializedBytes: changedContent.protobuf).data.content,
      "different"
    )
    XCTAssertEqual(
      try AddThreadReqIdl(serializedBytes: changedTitle.protobuf).data.title,
      "different"
    )
    XCTAssertNotEqual(titled.protobuf, changedContent.protobuf)
    XCTAssertNotEqual(titled.protobuf, changedTitle.protobuf)
    XCTAssertEqual(titled.fields["sign"], changedContent.fields["sign"])
    XCTAssertEqual(titled.fields["sign"], changedTitle.fields["sign"])
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
      try AddThreadReqIdl(
        serializedBytes: newThreadMultipart(makeRequest(submission: submission)).protobuf
      ).data.content,
      "正文\n#(pic,\(proof.picID),640,480)"
    )
    XCTAssertEqual(
      try AddThreadReqIdl(
        serializedBytes: newThreadMultipart(
          makeRequest(
            submission: makeSubmission(
              submissionID: submissionID,
              content: "",
              imageProofs: [proof]
            )
          )
        ).protobuf
      ).data.content,
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
        from: try newThreadResponse().serializedData(),
        submission: submission
      ),
      TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    )

    var missingError = newThreadResponse()
    missingError.clearError()
    var missingData = newThreadResponse()
    missingData.clearData()
    var invalidResponses = [missingError, missingData]
    for invalidID in ["", "0", "-1", "3.5", "+3", " 3", "3 ", "9223372036854775808"] {
      var invalidThread = newThreadResponse()
      invalidThread.data.tid = invalidID
      invalidResponses.append(invalidThread)
      var invalidPost = newThreadResponse()
      invalidPost.data.pid = invalidID
      invalidResponses.append(invalidPost)
    }
    for response in invalidResponses {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadReceipt(
          from: try response.serializedData(),
          submission: submission
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: Data("not-protobuf".utf8),
        submission: submission
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidProtobuf) }
  }

  func testReceiptClassifiesEveryPostAntiInfoSignalBeforeServerError() throws {
    let signals: [(inout PostAntiInfo) -> Void] = [
      { $0.needVcode = "1" },
      { $0.vcodeMd5 = "token" },
      { $0.vcodePrevType = "slide" },
      { $0.vcodeType = "slide" },
      { $0.vcodePicURL = "https://example.invalid/vcode" },
      { $0.passToken = "token" },
      { $0.blockCancel = "cancel" },
      { $0.blockConfirm = "confirm" },
      { $0.blockContent = "需要验证" },
      { $0.confilterHitwords = ["word"] },
      { $0.accessState = AccessState() },
      { $0.vcodeExtra.slideendpoint = "https://example.invalid/challenge" },
    ]
    for signal in signals {
      var response = newThreadResponse(errorCode: 340_006, message: "需要验证")
      var info = PostAntiInfo()
      signal(&info)
      response.data.info = info
      try assertChallenge(response, message: "需要验证")
    }
  }

  func testReceiptClassifiesEveryAntiStatSignalBeforeApparentSuccess() throws {
    let signals: [(inout PostAntiStat) -> Void] = [
      { $0.forbidFlag = 1 },
      { $0.forbidInfo = "需要验证" },
      { $0.blockStat = 1 },
      { $0.hideStat = 1 },
      { $0.vcodeStat = 1 },
    ]
    for signal in signals {
      var response = newThreadResponse(message: "需要验证")
      var antiStat = PostAntiStat()
      signal(&antiStat)
      response.data.antiStat = antiStat
      try assertChallenge(response, message: "需要验证")
    }
  }

  func testReceiptClassifiesEveryVcodeInfoSignalBeforeServerError() throws {
    let signals: [(inout VcodeInfo) -> Void] = [
      { $0.vcodeMd5 = "token" },
      { $0.vcodePicURL = "https://example.invalid/vcode" },
      { $0.vcodeType = "slide" },
      { $0.vcodeExtra.textimg = "challenge" },
      { $0.vcodeExtra.slideimg = "challenge" },
      { $0.vcodeExtra.endpoint = "https://example.invalid/challenge" },
      { $0.vcodeExtra.successimg = "challenge" },
      { $0.vcodeExtra.slideendpoint = "https://example.invalid/challenge" },
    ]
    for signal in signals {
      var response = newThreadResponse(errorCode: 340_006, message: "需要验证")
      var anti = VcodeInfo()
      signal(&anti)
      response.data.anti = anti
      try assertChallenge(response, message: "需要验证")
    }
  }

  func testReceiptChallengeRemainsDefinitiveWhenSuccessEnvelopeIsIncomplete() throws {
    var response = newThreadResponse()
    response.clearError()
    response.data.tid = ""
    response.data.pid = ""
    response.data.info.needVcode = "1"
    try assertChallenge(
      response,
      message: "Tieba requires additional verification before this topic can be submitted."
    )
  }

  func testReceiptServerErrorUsesUserMessageThenErrorMessage() throws {
    for code: Int32 in [340_006, -1] {
      var response = newThreadResponse(errorCode: code, message: "denied")
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadReceipt(
          from: try response.serializedData(),
          submission: makeSubmission()
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: code, message: "denied")) }

      response.error.userMsg = "请稍后重试"
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.newThreadReceipt(
          from: try response.serializedData(),
          submission: makeSubmission()
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: code, message: "请稍后重试")) }
    }
  }

  func testReceiptDoesNotTreatEmptyOrZeroChallengeMessagesAsChallenge() throws {
    let submission = makeSubmission()
    let expected = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    for value in ["", "   ", "0", " 0 "] {
      var response = newThreadResponse()
      var info = PostAntiInfo()
      info.needVcode = value
      info.vcodeExtra = VcodeExtra()
      response.data.info = info
      response.data.antiStat = PostAntiStat()
      var anti = VcodeInfo()
      anti.vcodeExtra = VcodeExtra()
      response.data.anti = anti
      XCTAssertEqual(
        try TiebaAuthenticatedDecoder.newThreadReceipt(
          from: try response.serializedData(),
          submission: submission
        ),
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

  func testExpandedEmoticonsSurviveNewThreadWireEncodingAndSignature() throws {
    let content = "前e\u{301}#(吃瓜)#(捂嘴笑)#(菜狗)#(小姐姐来啦)#(哼)后 +%&=🙂"
    let submission = makeSubmission(content: content)
    let parsed = try newThreadMultipart(makeRequest(submission: submission))
    let message = try AddThreadReqIdl(serializedBytes: parsed.protobuf)

    XCTAssertEqual(Array(message.data.content.utf8), Array(content.utf8))
    XCTAssertEqual(
      parsed.fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: parsed.fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
      )
    )
    let legacy = try newThreadMultipart(makeRequest(submission: makeSubmission(content: "#(生气)")))
    XCTAssertEqual(parsed.fields["sign"], legacy.fields["sign"])
    XCTAssertNotEqual(parsed.protobuf, legacy.protobuf)
  }

  func testExpandedEmoticonsRequireStructuredExactNewThreadReadback() throws {
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    for name in ["吃瓜", "捂嘴笑", "菜狗", "小姐姐来啦", "哼", "生气"] {
      let submission = makeSubmission(content: "前#(\(name))后")
      for type: UInt32 in [2, 11] {
        let fragments = [
          contentFragment(type: 0, text: "前"),
          contentFragment(type: type, c: name),
          contentFragment(type: 0, text: "后"),
        ]
        XCTAssertEqual(
          try TiebaAuthenticatedDecoder.verifiedNewThread(
            from: newThreadPageResponse(
              title: submission.title, content: "unused", contentFragments: fragments
            ),
            context: newThreadContext(),
            submission: submission,
            receipt: receipt
          ),
          receipt,
          "\(name), type \(type)"
        )
      }
      let wrongName = name == "生气" ? "哼" : "生气"
      for fragment in [
        contentFragment(type: 0, text: "#(\(name))"),
        contentFragment(type: 2, c: wrongName),
        contentFragment(type: 11, c: "小姐姐来拉"),
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
  }

  func testExpandedNewThreadCatalogDoesNotPermitUnknownOrInjectedMarkers() {
    for content in [
      "#(小姐姐来拉)", "#(吃瓜,extra)", "#(吃瓜)#(未知表情)",
      "#(吃瓜)#(pic,1,2,3)", "#(吃瓜)#(reply, portrait, name)",
    ] {
      XCTAssertThrowsError(try makeRequest(submission: makeSubmission(content: content))) {
        guard case .invalidArgument = $0 as? TiebaClientError else {
          return XCTFail("Unexpected error for \(content): \($0)")
        }
      }
    }
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

  private func newThreadMultipart(_ request: URLRequest) throws -> (
    fields: [String: String], orderedNames: [String], protobuf: Data
  ) {
    let body = try XCTUnwrap(request.httpBody)
    let boundary = TiebaRequestFactory.multipartBoundary
    let dataHeader = Data(
      ("--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n").utf8
    )
    let dataHeaderRange = try XCTUnwrap(body.range(of: dataHeader))
    let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
    guard body.suffix(suffix.count) == suffix else {
      throw TiebaClientError.transportFailure
    }
    let protobuf = body.subdata(in: dataHeaderRange.upperBound..<(body.count - suffix.count))
    let prefix = String(decoding: body[..<dataHeaderRange.lowerBound], as: UTF8.self)
    let parts = prefix.components(separatedBy: "--\(boundary)\r\n")
    var fields = [String: String]()
    var orderedNames = [String]()
    for part in parts where !part.isEmpty {
      let separator = try XCTUnwrap(part.range(of: "\r\n\r\n"))
      let header = String(part[..<separator.lowerBound])
      var value = String(part[separator.upperBound...])
      let fieldHeader = "Content-Disposition: form-data; name=\""
      guard
        header.hasPrefix(fieldHeader), header.hasSuffix("\""),
        let terminator = value.range(of: "\r\n", options: .backwards),
        terminator.upperBound == value.endIndex
      else {
        throw TiebaClientError.transportFailure
      }
      value.removeSubrange(terminator)
      let name = String(header.dropFirst(fieldHeader.count).dropLast())
      guard fields.updateValue(value, forKey: name) == nil else {
        throw TiebaClientError.transportFailure
      }
      orderedNames.append(name)
    }
    return (fields, orderedNames, protobuf)
  }

  private func newThreadResponse(
    errorCode: Int32 = 0,
    message: String = ""
  ) -> AddThreadResIdl {
    var error = TiebaProto.Error()
    error.errorno = errorCode
    error.errmsg = message
    var data = AddThreadResIdl.DataRes()
    data.tid = String(threadID)
    data.pid = String(firstPostID)
    var response = AddThreadResIdl()
    response.error = error
    response.data = data
    return response
  }

  private func assertChallenge(
    _ response: AddThreadResIdl,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let body = try response.serializedData()
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.newThreadReceipt(from: body, submission: makeSubmission()),
      file: file,
      line: line
    ) {
      XCTAssertEqual(
        $0 as? TiebaClientError,
        .newThreadChallengeRequired(message: message),
        file: file,
        line: line
      )
    }
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
