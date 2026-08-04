import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaAgreementTests: XCTestCase, @unchecked Sendable {
  private let userID: Int64 = 7_001
  private let secondUserID: Int64 = 7_002
  private let forumID: Int64 = 8_001
  private let forumName = "swift"
  private let threadID: Int64 = 9_001
  private let firstPostID: Int64 = 10_001
  private let postID: Int64 = 10_002
  private let secondPostID: Int64 = 10_003
  private let subpostID: Int64 = 11_001
  private let tbs = "0123456789abcdef0123456789"

  func testAgreementPageRequestMirrorsPostDescriptorAndBindsCredential() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.agreementPage(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      page: 0,
      pageSize: 20,
      sort: .descending,
      onlyThreadAuthor: true,
      location: .pageCursor(postID),
      includeSubposts: true,
      subpostsSortedByAgree: false,
      subpostPageSize: 7
    )

    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
    XCTAssertEqual(request.url?.path, "/c/f/pb/page")
    XCTAssertEqual(request.url?.query, "cmd=302001")
    let proto = try PbPageReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(proto.data.common.clientType, 2)
    XCTAssertEqual(proto.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(proto.data.common.bduss, credential().bduss)
    XCTAssertEqual(proto.data.forumID, forumID)
    XCTAssertEqual(proto.data.kz, threadID)
    XCTAssertEqual(proto.data.pid, postID)
    XCTAssertEqual(proto.data.pn, 0)
    XCTAssertEqual(proto.data.rn, 20)
    XCTAssertEqual(proto.data.r, TiebaPostSort.descending.rawValue)
    XCTAssertEqual(proto.data.lz, 1)
    XCTAssertEqual(proto.data.withFloor, 1)
    XCTAssertEqual(proto.data.floorSortType, 0)
    XCTAssertEqual(proto.data.floorRn, 7)
  }

  func testAgreementPageRejectsZeroExceptForCursorLocation() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    XCTAssertNoThrow(
      try factory.agreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        page: 0,
        pageSize: 20,
        sort: .ascending,
        onlyThreadAuthor: false,
        location: .pageCursor(postID),
        includeSubposts: false,
        subpostsSortedByAgree: true,
        subpostPageSize: 4
      )
    )
    XCTAssertThrowsError(
      try factory.agreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        page: 0,
        pageSize: 20,
        sort: .ascending,
        onlyThreadAuthor: false,
        location: .pageNumber,
        includeSubposts: false,
        subpostsSortedByAgree: true,
        subpostPageSize: 4
      )
    )
  }

  func testSubpostPageRequestCarriesFullParentContext() throws {
    let request = try TiebaAuthenticatedRequestFactory(configuration: .init())
      .subpostAgreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID,
        aroundSubpostID: subpostID,
        page: 3
      )
    let proto = try PbFloorReqIdl(serializedBytes: protobufPayload(from: request))
    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/f/pb/floor?cmd=302002")
    XCTAssertEqual(proto.data.common.bduss, credential().bduss)
    XCTAssertEqual(proto.data.forumID, forumID)
    XCTAssertEqual(proto.data.kz, threadID)
    XCTAssertEqual(proto.data.pid, postID)
    XCTAssertEqual(proto.data.spid, subpostID)
    XCTAssertEqual(proto.data.pn, 3)
  }

  func testWriteMapsAllTargetsAndReusesOneGalaxy2CUID() throws {
    let cuid = try XCTUnwrap(TiebaGalaxy2CUID.make(prefix: String(repeating: "A", count: 32)))
    let factory = TiebaAuthenticatedRequestFactory(
      configuration: .init(),
      agreementCUID: cuid
    )
    let targets: [(TiebaAgreementTarget, String, Int64)] = [
      (.thread(firstPostID: firstPostID), "3", firstPostID),
      (.post(postID: postID), "1", postID),
      (.subpost(parentPostID: postID, subpostID: subpostID), "2", subpostID),
    ]

    for (target, objectType, targetID) in targets {
      let request = try factory.setAgreement(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        target: target,
        tbs: tbs,
        isAgreed: true
      )
      var fields = try formFields(request)
      let sign = try XCTUnwrap(fields.removeValue(forKey: "sign"))
      XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/agree/opAgree")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 22.6.5.1")
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertEqual(
        Set(fields.keys),
        [
          "BDUSS", "_client_version", "agree_type", "cuid", "obj_type", "op_type",
          "post_id", "tbs", "thread_id",
        ]
      )
      XCTAssertEqual(fields["BDUSS"], credential().bduss)
      XCTAssertEqual(fields["_client_version"], "22.6.5.1")
      XCTAssertEqual(fields["agree_type"], "2")
      XCTAssertEqual(fields["cuid"], cuid)
      XCTAssertEqual(fields["obj_type"], objectType)
      XCTAssertEqual(fields["op_type"], "0")
      XCTAssertEqual(fields["post_id"], String(targetID))
      XCTAssertEqual(fields["thread_id"], String(threadID))
      XCTAssertEqual(fields["tbs"], tbs)
      XCTAssertNil(fields["stoken"])
      XCTAssertNil(fields["forum_id"])
      XCTAssertEqual(
        sign,
        TiebaAuthenticatedRequestFactory.signature(for: fields.map { ($0.key, $0.value) })
      )
    }
  }

  func testGalaxy2CUIDGenerationIsValidAndRejectsTampering() throws {
    let knownPrefix = "06C7F37D41256F25FABA97B885DB6EFB"
    let knownCUID = "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA"
    XCTAssertEqual(TiebaGalaxy2CUID.make(prefix: knownPrefix), knownCUID)
    XCTAssertTrue(TiebaGalaxy2CUID.isValid(knownCUID))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(knownPrefix + "|VAPUDW7TB"))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(knownPrefix.lowercased() + "|VAPUDW7TA"))

    let value = TiebaGalaxy2CUID.generate()
    XCTAssertTrue(TiebaGalaxy2CUID.isValid(value))
    XCTAssertEqual(value.utf8.count, 42)
    XCTAssertTrue(value.dropFirst(32).hasPrefix("|V"))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(value + "A"))
    XCTAssertFalse(TiebaGalaxy2CUID.isValid(String(repeating: "A", count: 32) + "|0"))

    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let first = try factory.setAgreement(
      credential: credential(), expectedUserID: userID, forumID: forumID,
      threadID: threadID, target: .post(postID: postID), tbs: tbs, isAgreed: true
    )
    let second = try factory.setAgreement(
      credential: credential(), expectedUserID: userID, forumID: forumID,
      threadID: threadID, target: .subpost(parentPostID: postID, subpostID: subpostID),
      tbs: tbs, isAgreed: false
    )
    let generatedCUID = try XCTUnwrap(formFields(first)["cuid"])
    XCTAssertTrue(TiebaGalaxy2CUID.isValid(generatedCUID))
    XCTAssertEqual(try formFields(second)["cuid"], generatedCUID)
  }

  func testRequestFactoryRejectsInvalidIdentityTBSAndCUID() throws {
    let validCUID = "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TA"
    let factory = TiebaAuthenticatedRequestFactory(
      configuration: .init(),
      agreementCUID: validCUID
    )
    for (invalidUserID, invalidForumID, invalidThreadID) in [
      (Int64(0), forumID, threadID),
      (userID, Int64(0), threadID),
      (userID, forumID, Int64(0)),
    ] {
      XCTAssertThrowsError(
        try factory.agreementPage(
          credential: credential(),
          expectedUserID: invalidUserID,
          forumID: invalidForumID,
          threadID: invalidThreadID,
          page: 1,
          pageSize: 20,
          sort: .ascending,
          onlyThreadAuthor: false,
          location: nil,
          includeSubposts: false,
          subpostsSortedByAgree: true,
          subpostPageSize: 4
        )
      )
    }
    XCTAssertThrowsError(
      try factory.setAgreement(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        target: .subpost(parentPostID: 0, subpostID: subpostID),
        tbs: tbs,
        isAgreed: true
      )
    )
    XCTAssertThrowsError(
      try factory.setAgreement(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        target: .post(postID: postID),
        tbs: String(repeating: "a", count: 25),
        isAgreed: true
      )
    )
    for invalidCUID in [
      "",
      "06c7f37d41256f25faba97b885db6efb|VAPUDW7TA",
      "06C7F37D41256F25FABA97B885DB6EFB|0",
      "06C7F37D41256F25FABA97B885DB6EFG|VAPUDW7TA",
      "06C7F37D41256F25FABA97B885DB6EFB|VAPUDW7TB",
    ] {
      let invalidFactory = TiebaAuthenticatedRequestFactory(
        configuration: .init(),
        agreementCUID: invalidCUID
      )
      XCTAssertThrowsError(
        try invalidFactory.setAgreement(
          credential: credential(),
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID,
          target: .post(postID: postID),
          tbs: tbs,
          isAgreed: true
        )
      )
    }
  }

  func testPageDecoderMapsTopicPostAndInlineSubpostInOneBatch() throws {
    let response = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      topicAgreement: true,
      postID: postID,
      postAgreement: nil,
      inlineSubpostID: subpostID,
      subpostAgreement: true
    )
    let page = try TiebaAuthenticatedDecoder.agreementPage(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )

    XCTAssertEqual(page.userID, userID)
    XCTAssertEqual(page.pagination.currentPage, 1)
    XCTAssertEqual(page.pagination.pageSize, 15)
    XCTAssertEqual(page.agreements.count, 3)
    XCTAssertEqual(
      page.agreements.first(where: { $0.target == .thread(firstPostID: firstPostID) })?.isAgreed,
      true
    )
    let post = try XCTUnwrap(
      page.agreements.first(where: { $0.target == .post(postID: postID) })
    )
    XCTAssertFalse(post.isAgreed)
    XCTAssertEqual(post.agreeScore, 0)
    XCTAssertEqual(
      page.agreements.first(where: {
        $0.target == .subpost(parentPostID: postID, subpostID: subpostID)
      })?.isAgreed,
      true
    )
  }

  func testPageDecoderMapsCanonicalFirstFloorInlineSubpostsOnce() throws {
    let firstFloorSubpostID = subpostID + 1
    var firstFloorOnly = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    firstFloorOnly.data.firstFloorPost.subPostList = inlineSubpostContainer(
      parentPostID: firstPostID,
      subpostID: firstFloorSubpostID,
      isAgreed: true
    )

    var page = try decodePage(firstFloorOnly)
    XCTAssertEqual(
      page.agreements.first(where: {
        $0.target == .subpost(
          parentPostID: firstPostID,
          subpostID: firstFloorSubpostID
        )
      })?.isAgreed,
      true
    )

    let preferredSubpostID = subpostID + 2
    let fallbackSubpostID = subpostID + 3
    var duplicatedFirstFloor = firstFloorOnly
    duplicatedFirstFloor.data.firstFloorPost.subPostList = inlineSubpostContainer(
      parentPostID: firstPostID,
      subpostID: fallbackSubpostID,
      isAgreed: false
    )
    var postListFirstFloor = duplicatedFirstFloor.data.firstFloorPost
    postListFirstFloor.subPostList = inlineSubpostContainer(
      parentPostID: firstPostID,
      subpostID: preferredSubpostID,
      isAgreed: true
    )
    duplicatedFirstFloor.data.postList.insert(postListFirstFloor, at: 0)

    page = try decodePage(duplicatedFirstFloor)
    XCTAssertEqual(
      page.agreements.filter { $0.target == .thread(firstPostID: firstPostID) }.count,
      1
    )
    XCTAssertEqual(
      page.agreements.first(where: {
        $0.target == .subpost(parentPostID: firstPostID, subpostID: preferredSubpostID)
      })?.isAgreed,
      true
    )
    XCTAssertFalse(
      page.agreements.contains(where: {
        $0.target == .subpost(parentPostID: firstPostID, subpostID: fallbackSubpostID)
      })
    )
  }

  func testPageDecoderRejectsUnboundAccountMalformedFloorsAndPagination() throws {
    var wrongUser = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    wrongUser.data.user.id = userID + 1
    XCTAssertThrowsError(
      try decodePage(wrongUser)
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var signedOut = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    signedOut.data.user.isLogin = 0
    XCTAssertThrowsError(try decodePage(signedOut))

    var wrongForum = signedOut
    wrongForum.data.user.isLogin = 1
    wrongForum.data.forum.id = forumID + 1
    XCTAssertThrowsError(try decodePage(wrongForum))

    var wrongThread = signedOut
    wrongThread.data.user.isLogin = 1
    wrongThread.data.thread.id = threadID + 1
    XCTAssertThrowsError(try decodePage(wrongThread))

    var floorZero = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    floorZero.data.postList[0].floor = 0
    XCTAssertThrowsError(try decodePage(floorZero))

    var malformedFirst = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    malformedFirst.data.firstFloorPost.tid = threadID + 1
    XCTAssertThrowsError(try decodePage(malformedFirst))

    var badPagination = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    badPagination.data.page.hasMore_p = 2
    XCTAssertThrowsError(try decodePage(badPagination))

    badPagination = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    badPagination.data.page.totalCount = -1
    XCTAssertThrowsError(try decodePage(badPagination))

    badPagination = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    badPagination.data.page.currentPage = -1
    XCTAssertThrowsError(try decodePage(badPagination))
  }

  func testPageDecoderRejectsInvalidAgreementAndDuplicateIDs() throws {
    var invalid = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    invalid.data.postList[0].agree.hasAgree_p = 7
    XCTAssertThrowsError(try decodePage(invalid))

    var duplicate = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    duplicate.data.postList.append(duplicate.data.postList[0])
    XCTAssertThrowsError(try decodePage(duplicate))

    var omittedParentID = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID,
      inlineSubpostID: subpostID
    )
    omittedParentID.data.postList[0].subPostList.pid = 0
    XCTAssertNoThrow(try decodePage(omittedParentID))

    var wrongParentBinding = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID,
      inlineSubpostID: subpostID
    )
    wrongParentBinding.data.postList[0].subPostList.pid = UInt64(postID + 1)
    XCTAssertThrowsError(try decodePage(wrongParentBinding))
  }

  func testFloorDecoderMapsOrdinaryParentAndSubposts() throws {
    let response = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: postID,
      parentFloor: 2,
      parentAgreement: true,
      subpostID: subpostID,
      subpostAgreement: false
    )
    let page = try TiebaAuthenticatedDecoder.subpostAgreementPage(
      from: response,
      validatedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: postID,
      requiredSubpostID: subpostID
    )
    XCTAssertEqual(page.agreements.count, 2)
    XCTAssertEqual(
      page.agreements.first(where: { $0.target == .post(postID: postID) })?.isAgreed,
      true
    )
    XCTAssertEqual(
      page.agreements.first(where: {
        $0.target == .subpost(parentPostID: postID, subpostID: subpostID)
      })?.isAgreed,
      false
    )
  }

  func testFloorDecoderMapsCanonicalFirstParentToThreadAgreement() throws {
    var response = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: firstPostID,
      parentFloor: 1,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: false
    )
    response.data.thread.agree = agree(true, score: 12)
    let page = try TiebaAuthenticatedDecoder.subpostAgreementPage(
      from: response,
      validatedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: firstPostID
    )
    XCTAssertEqual(
      page.agreements.first(where: { $0.target == .thread(firstPostID: firstPostID) })?.isAgreed,
      true
    )
    XCTAssertFalse(page.agreements.contains(where: { $0.target == .post(postID: firstPostID) }))

    response.data.thread.firstPostID = firstPostID + 1
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.subpostAgreementPage(
        from: response,
        validatedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: firstPostID
      )
    )
  }

  func testFloorDecoderRejectsWrongForumParentAndMissingRequiredSubpost() throws {
    var response = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: postID,
      parentFloor: 2,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: false
    )
    response.data.forum.id = forumID + 1
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.subpostAgreementPage(
        from: response,
        validatedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID
      )
    )

    response = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: postID,
      parentFloor: 0,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: false
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.subpostAgreementPage(
        from: response,
        validatedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID
      )
    )

    response = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: postID,
      parentFloor: 2,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: false
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.subpostAgreementPage(
        from: response,
        validatedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID,
        requiredSubpostID: subpostID + 1
      )
    )
  }

  func testAuthenticatedClientReadsPageAndFloorBatches() async throws {
    let probe = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    let floor = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      parentPostID: postID,
      parentFloor: 2,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: true
    )
    let transport = AgreementQueueTransport(steps: [
      .response(try probe.serializedData()),
      .response(try floor.serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let page = try await client.getSubpostAgreementPage(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: postID,
      aroundSubpostID: subpostID
    )
    XCTAssertEqual(page.agreements.last?.target, .subpost(parentPostID: postID, subpostID: subpostID))
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/c/f/pb/page", "/c/f/pb/floor"])
    let bodyLimits = await transport.bodyLimits()
    XCTAssertEqual(
      bodyLimits,
      [
        TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
        TiebaAuthenticatedClient.subpostAgreementPageResponseMaximumBytes,
      ]
    )
  }

  func testAgreementPageAndFloorRejectResponsesAboveTheirDistinctLimits() async throws {
    let oversizedPage = Data(
      count: TiebaAuthenticatedClient.agreementPageResponseMaximumBytes + 1
    )
    let pageTransport = AgreementQueueTransport(steps: [.response(oversizedPage)])
    let pageClient = TiebaAuthenticatedClient(transport: pageTransport)
    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.agreementPageResponseMaximumBytes
      )
    ) {
      _ = try await pageClient.getAgreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    }

    let probe = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    let oversizedFloor = Data(
      count: TiebaAuthenticatedClient.subpostAgreementPageResponseMaximumBytes + 1
    )
    let floorTransport = AgreementQueueTransport(steps: [
      .response(try probe.serializedData()),
      .response(oversizedFloor),
    ])
    let floorClient = TiebaAuthenticatedClient(transport: floorTransport)
    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.subpostAgreementPageResponseMaximumBytes
      )
    ) {
      _ = try await floorClient.getSubpostAgreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID
      )
    }
  }

  func testSubpostPageRejectsParentKindDriftBetweenProbeAndFloor() async throws {
    let ordinaryParentProbe = pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID
    )
    let sameIDAsFirstFloor = floorResponse(
      forumID: forumID,
      threadID: threadID,
      firstPostID: postID,
      parentPostID: postID,
      parentFloor: 1,
      parentAgreement: false,
      subpostID: subpostID,
      subpostAgreement: false
    )
    let transport = AgreementQueueTransport(steps: [
      .response(try ordinaryParentProbe.serializedData()),
      .response(try sameIDAsFirstFloor.serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.invalidAuthenticatedResponse) {
      _ = try await client.getSubpostAgreementPage(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: postID
      )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/c/f/pb/page", "/c/f/pb/floor"])
  }

  func testLegacyTopicAgreementWrappersRemainCompatible() async throws {
    let readTransport = AgreementQueueTransport(steps: [
      .response(try pageResponse(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        firstPostID: firstPostID,
        topicAgreement: true,
        postID: postID
      ).serializedData())
    ])
    let readClient = TiebaAuthenticatedClient(transport: readTransport)
    let read = try await readClient.getThreadAgreement(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      firstPostID: firstPostID
    )
    XCTAssertTrue(read.isAgreed)
    XCTAssertEqual(read.firstPostID, firstPostID)

    let writeTransport = AgreementQueueTransport(steps: [
      .response(try pageResponse(
        userID: userID,
        forumID: forumID,
        threadID: threadID,
        firstPostID: firstPostID,
        topicAgreement: false,
        postID: postID
      ).serializedData()),
      .response(try membershipResponse(
        userID: userID, forumID: forumID, forumName: forumName, tbs: tbs
      ).serializedData()),
      .response(Data(#"{"error_code":"0","data":{"agree":{"score":"10"}}}"#.utf8)),
    ])
    let writeClient = TiebaAuthenticatedClient(transport: writeTransport)
    let written = try await writeClient.setThreadAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: true
    )
    XCTAssertTrue(written.isAgreed)
    XCTAssertEqual(written.agreeScore, 10)
    let paths = await writeTransport.paths()
    XCTAssertEqual(paths, ["/c/f/pb/page", "/c/f/frs/page", "/c/c/agree/opAgree"])
  }

  func testUncertainWriteReadsBackExactlyOnceWithoutRetryingWrite() async throws {
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: false).serializedData()),
      .response(try membershipResponse(userID: userID, forumID: forumID, forumName: forumName, tbs: tbs).serializedData()),
      .failure(.network(code: -1_001)),
      .response(try targetPage(isAgreed: true).serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let state = try await client.setAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID),
      isAgreed: true
    )
    XCTAssertTrue(state.isAgreed)
    let paths = await transport.paths()
    XCTAssertEqual(paths.filter { $0 == "/c/f/pb/page" }.count, 2)
    XCTAssertEqual(paths.filter { $0 == "/c/c/agree/opAgree" }.count, 1)
    XCTAssertEqual(paths.count, 4)
  }

  func testUncertainWriteWithOldReadbackThrowsOriginalError() async throws {
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: false).serializedData()),
      .response(try membershipResponse(userID: userID, forumID: forumID, forumName: forumName, tbs: tbs).serializedData()),
      .failure(.network(code: -1_001)),
      .response(try targetPage(isAgreed: false).serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(.network(code: -1_001)) {
      _ = try await client.setAgreementState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        isAgreed: true
      )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths.filter { $0 == "/c/f/pb/page" }.count, 2)
    XCTAssertEqual(paths.filter { $0 == "/c/c/agree/opAgree" }.count, 1)
  }

  func testCancellationAfterPossibleWriteUsesOneReadback() async throws {
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: false).serializedData()),
      .response(try membershipResponse(userID: userID, forumID: forumID, forumName: forumName, tbs: tbs).serializedData()),
      .cancelled,
      .response(try targetPage(isAgreed: true).serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let state = try await client.setAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID),
      isAgreed: true
    )
    XCTAssertTrue(state.isAgreed)
    let paths = await transport.paths()
    XCTAssertEqual(paths.filter { $0 == "/c/f/pb/page" }.count, 2)
    XCTAssertEqual(paths.filter { $0 == "/c/c/agree/opAgree" }.count, 1)
  }

  func testOversizedWriteResponseIsUncertainAndNeverRetried() async throws {
    let oversized = Data(repeating: 0x41, count: 64 * 1_024 + 1)
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: false).serializedData()),
      .response(try membershipResponse(userID: userID, forumID: forumID, forumName: forumName, tbs: tbs).serializedData()),
      .response(oversized),
      .response(try targetPage(isAgreed: false).serializedData()),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(.responseTooLarge(maximumBytes: 64 * 1_024)) {
      _ = try await client.setAgreementState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        isAgreed: true
      )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths.filter { $0 == "/c/c/agree/opAgree" }.count, 1)
    XCTAssertEqual(paths.filter { $0 == "/c/f/pb/page" }.count, 2)
  }

  func testDefinitiveServerWriteErrorDoesNotReadBack() async throws {
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: false).serializedData()),
      .response(try membershipResponse(userID: userID, forumID: forumID, forumName: forumName, tbs: tbs).serializedData()),
      .response(Data(#"{"error_code":"123","error_msg":"denied"}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(.server(code: 123, message: "denied")) {
      _ = try await client.setAgreementState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        isAgreed: true
      )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths.count, 3)
  }

  func testMatchingStateSkipsIdentityProbeAndWrite() async throws {
    let transport = AgreementQueueTransport(steps: [
      .response(try targetPage(isAgreed: true).serializedData())
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let state = try await client.setAgreementState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID),
      isAgreed: true
    )
    XCTAssertTrue(state.isAgreed)
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/c/f/pb/page"])
  }

  func testWriteScoreDecoderAcceptsMissingButRejectsMalformedScore() throws {
    XCTAssertNil(
      try TiebaAuthenticatedDecoder.threadAgreementWriteScore(
        from: Data(#"{"error_code":"0"}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.threadAgreementWriteScore(
        from: Data(#"{"error_code":"0","data":{"agree":{"score":true}}}"#.utf8)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
  }

  func testSameTargetSharesOneWriteAndOppositeTargetOnlyReadsBack() async throws {
    let transport = BlockingAgreementTransport(
      firstUserID: userID,
      secondUserID: secondUserID,
      forumID: forumID,
      forumName: forumName,
      firstPostID: firstPostID,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.setAgreementState(
        credential: credential(), expectedUserID: userID, forumID: forumID,
        forumName: forumName, threadID: threadID, target: .post(postID: postID),
        isAgreed: true
      )
    }
    guard await transport.waitUntilWriteCount(1) else {
      XCTFail("first write did not start")
      return
    }
    let shared = Task {
      try await client.setAgreementState(
        credential: credential(), expectedUserID: userID, forumID: forumID,
        forumName: forumName, threadID: threadID, target: .post(postID: postID),
        isAgreed: true
      )
    }
    guard await waitForAgreementWaiters(
      client,
      target: .post(postID: postID),
      shared: 1,
      conflict: 0
    ) else {
      XCTFail("shared waiter did not attach")
      return
    }
    let opposite = Task {
      try await client.setAgreementState(
        credential: credential(), expectedUserID: userID, forumID: forumID,
        forumName: forumName, threadID: threadID, target: .post(postID: postID),
        isAgreed: false
      )
    }
    guard await waitForAgreementWaiters(
      client,
      target: .post(postID: postID),
      shared: 1,
      conflict: 1
    ) else {
      XCTFail("conflict waiter did not attach")
      return
    }
    await transport.releaseWrites()
    let firstState = try await first.value
    let sharedState = try await shared.value
    let oppositeState = try await opposite.value
    XCTAssertTrue(firstState.isAgreed)
    XCTAssertTrue(sharedState.isAgreed)
    XCTAssertTrue(oppositeState.isAgreed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.pageReadCount, 2)
  }

  func testRotatedCredentialWaitsThenReadsBackWithoutSecondWrite() async throws {
    let transport = BlockingAgreementTransport(
      firstUserID: userID,
      secondUserID: secondUserID,
      forumID: forumID,
      forumName: forumName,
      firstPostID: firstPostID,
      tbs: tbs
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = writeTask(
      client: client,
      credential: credential("b"),
      userID: userID,
      postID: postID
    )
    guard await transport.waitUntilWriteCount(1) else {
      XCTFail("first credential write did not start")
      return
    }
    let rotated = writeTask(
      client: client,
      credential: credential("d"),
      userID: userID,
      postID: postID
    )
    guard await waitForAgreementWaiters(
      client,
      target: .post(postID: postID),
      shared: 0,
      conflict: 1
    ) else {
      XCTFail("rotated credential did not enter read-only conflict path")
      return
    }
    await transport.releaseWrites()
    let firstState = try await first.value
    XCTAssertTrue(firstState.isAgreed)
    let rotatedState = try await rotated.value
    XCTAssertTrue(rotatedState.isAgreed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.writeCount, 1)
    XCTAssertEqual(snapshot.pageReadCount, 2)
  }

  func testSameAccountSerializesDifferentTargetsButDifferentAccountsRunInParallel() async throws {
    let sameAccountTransport = BlockingAgreementTransport(
      firstUserID: userID,
      secondUserID: secondUserID,
      forumID: forumID,
      forumName: forumName,
      firstPostID: firstPostID,
      tbs: tbs
    )
    let sameAccountClient = TiebaAuthenticatedClient(transport: sameAccountTransport)
    let first = writeTask(
      client: sameAccountClient,
      credential: credential(),
      userID: userID,
      postID: postID
    )
    guard await sameAccountTransport.waitUntilWriteCount(1) else {
      XCTFail("first same-account write did not start")
      return
    }
    let second = writeTask(
      client: sameAccountClient,
      credential: credential(),
      userID: userID,
      postID: secondPostID
    )
    try await Task.sleep(for: .milliseconds(30))
    let blockedSnapshot = await sameAccountTransport.snapshot()
    XCTAssertEqual(blockedSnapshot.writeCount, 1)
    await sameAccountTransport.releaseWrites()
    _ = try await first.value
    _ = try await second.value
    let completedSnapshot = await sameAccountTransport.snapshot()
    XCTAssertEqual(completedSnapshot.writeCount, 2)

    let twoAccountTransport = BlockingAgreementTransport(
      firstUserID: userID,
      secondUserID: secondUserID,
      forumID: forumID,
      forumName: forumName,
      firstPostID: firstPostID,
      tbs: tbs
    )
    let twoAccountClient = TiebaAuthenticatedClient(transport: twoAccountTransport)
    let accountOne = writeTask(
      client: twoAccountClient,
      credential: credential("b"),
      userID: userID,
      postID: postID
    )
    let accountTwo = writeTask(
      client: twoAccountClient,
      credential: credential("c"),
      userID: secondUserID,
      postID: secondPostID
    )
    guard await twoAccountTransport.waitUntilWriteCount(2) else {
      XCTFail("different-account writes did not run in parallel")
      return
    }
    await twoAccountTransport.releaseWrites()
    _ = try await accountOne.value
    _ = try await accountTwo.value
  }

  private func decodePage(_ response: PbPageResIdl) throws -> TiebaAgreementPage {
    try TiebaAuthenticatedDecoder.agreementPage(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )
  }

  private func targetPage(isAgreed: Bool) -> PbPageResIdl {
    pageResponse(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      postID: postID,
      postAgreement: isAgreed
    )
  }

  private func credential(_ character: Character = "b") -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: character, count: 192))
  }

  private func writeTask(
    client: TiebaAuthenticatedClient,
    credential: TiebaBDUSSCredential,
    userID: Int64,
    postID: Int64
  ) -> Task<TiebaAgreementState, Swift.Error> {
    Task {
      try await client.setAgreementState(
        credential: credential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        isAgreed: true
      )
    }
  }

  private func waitForAgreementWaiters(
    _ client: TiebaAuthenticatedClient,
    target: TiebaAgreementTarget,
    shared: Int,
    conflict: Int
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      let counts = await client.agreementWaiterCounts(
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        target: target
      )
      if counts.shared == shared, counts.conflict == conflict { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
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

private enum AgreementStep: Sendable {
  case response(Data)
  case httpResponse(Data, status: Int)
  case failure(TiebaClientError)
  case cancelled
}

private actor AgreementQueueTransport: TiebaTransport {
  private var steps: [AgreementStep]
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(steps: [AgreementStep]) {
    self.steps = steps
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    guard !steps.isEmpty else { throw TiebaClientError.transportFailure }
    switch steps.removeFirst() {
    case .response(let body):
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .httpResponse(let body, let status):
      return TiebaHTTPResponse(body: body, statusCode: status)
    case .failure(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    }
  }

  func paths() -> [String] { requests.compactMap(\.url?.path) }
  func bodyLimits() -> [Int?] { maximumBodyBytes }
}

private struct BlockingAgreementSnapshot: Sendable {
  let writeCount: Int
  let pageReadCount: Int
}

private struct BlockingAgreementStateKey: Hashable, Sendable {
  let userID: Int64
  let postID: Int64
}

private actor BlockingAgreementTransport: TiebaTransport {
  private let firstUserID: Int64
  private let secondUserID: Int64
  private let forumID: Int64
  private let forumName: String
  private let firstPostID: Int64
  private let tbs: String
  private var states = [BlockingAgreementStateKey: Bool]()
  private var writes = 0
  private var pageReads = 0
  private var writesReleased = false
  private var writeWaiters = [CheckedContinuation<Void, Never>]()

  init(
    firstUserID: Int64,
    secondUserID: Int64,
    forumID: Int64,
    forumName: String,
    firstPostID: Int64,
    tbs: String
  ) {
    self.firstUserID = firstUserID
    self.secondUserID = secondUserID
    self.forumID = forumID
    self.forumName = forumName
    self.firstPostID = firstPostID
    self.tbs = tbs
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    guard let path = request.url?.path else { throw TiebaClientError.transportFailure }
    switch path {
    case "/c/f/pb/page":
      let proto = try PbPageReqIdl(serializedBytes: protobufPayload(from: request))
      let userID = resolvedUserID(proto.data.common.bduss)
      let targetPostID = proto.data.pid > 0 ? proto.data.pid : firstPostID + 1
      pageReads += 1
      let response = pageResponse(
        userID: userID,
        forumID: proto.data.forumID > 0 ? proto.data.forumID : forumID,
        threadID: proto.data.kz,
        firstPostID: firstPostID,
        postID: targetPostID,
        postAgreement: states[BlockingAgreementStateKey(userID: userID, postID: targetPostID)]
          ?? false
      )
      return TiebaHTTPResponse(body: try response.serializedData(), statusCode: 200)
    case "/c/f/frs/page":
      let proto = try FrsPageReqIdl(serializedBytes: protobufPayload(from: request))
      let userID = resolvedUserID(proto.data.common.bduss)
      let response = membershipResponse(
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        tbs: tbs
      )
      return TiebaHTTPResponse(body: try response.serializedData(), statusCode: 200)
    case "/c/c/agree/opAgree":
      let fields = try formFields(request)
      guard
        let postID = fields["post_id"].flatMap({ Int64($0) }),
        let opType = fields["op_type"],
        let bduss = fields["BDUSS"]
      else {
        throw TiebaClientError.transportFailure
      }
      let userID = resolvedUserID(bduss)
      writes += 1
      if !writesReleased {
        await withCheckedContinuation { writeWaiters.append($0) }
      }
      states[BlockingAgreementStateKey(userID: userID, postID: postID)] = opType == "0"
      return TiebaHTTPResponse(body: Data(#"{"error_code":"0"}"#.utf8), statusCode: 200)
    default:
      throw TiebaClientError.transportFailure
    }
  }

  func waitUntilWriteCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if writes >= expected { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func releaseWrites() {
    writesReleased = true
    let waiters = writeWaiters
    writeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func snapshot() -> BlockingAgreementSnapshot {
    BlockingAgreementSnapshot(writeCount: writes, pageReadCount: pageReads)
  }

  private func resolvedUserID(_ bduss: String) -> Int64 {
    bduss.first == "c" ? secondUserID : firstUserID
  }
}

private func pageResponse(
  userID: Int64,
  forumID: Int64,
  threadID: Int64,
  firstPostID: Int64,
  topicAgreement: Bool = false,
  postID: Int64,
  postAgreement: Bool? = false,
  inlineSubpostID: Int64? = nil,
  subpostAgreement: Bool? = false
) -> PbPageResIdl {
  var user = User()
  user.isLogin = 1
  user.id = userID

  var forum = SimpleForum()
  forum.id = forumID
  forum.name = "swift"

  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.firstPostID = firstPostID
  thread.agree = agree(topicAgreement, score: topicAgreement ? 10 : 9)

  var firstPost = Post()
  firstPost.id = firstPostID
  firstPost.floor = 1
  firstPost.tid = threadID

  var post = Post()
  post.id = postID
  post.floor = 2
  post.tid = threadID
  if let postAgreement {
    post.agree = agree(postAgreement, score: postAgreement ? 4 : 3)
  }
  if let inlineSubpostID {
    var subpost = SubPostList()
    subpost.id = inlineSubpostID
    subpost.floor = 1
    if let subpostAgreement {
      subpost.agree = agree(subpostAgreement, score: subpostAgreement ? 2 : 1)
    }
    var container = Post.SubPost()
    container.pid = UInt64(postID)
    container.subPostList = [subpost]
    post.subPostList = container
  }

  var page = Page()
  page.pageSize = 15
  page.currentPage = 1
  page.totalPage = 2
  page.totalCount = 20
  page.hasMore_p = 1
  page.hasPrev_p = 0

  var anti = Anti()
  anti.tbs = "0123456789abcdef0123456789"
  var data = PbPageResIdl.DataRes()
  data.user = user
  data.forum = forum
  data.page = page
  data.anti = anti
  data.postList = [post]
  data.thread = thread
  data.firstFloorPost = firstPost
  var response = PbPageResIdl()
  response.data = data
  return response
}

private func inlineSubpostContainer(
  parentPostID: Int64,
  subpostID: Int64,
  isAgreed: Bool
) -> Post.SubPost {
  var subpost = SubPostList()
  subpost.id = subpostID
  subpost.floor = 1
  subpost.agree = agree(isAgreed, score: isAgreed ? 2 : 1)
  var container = Post.SubPost()
  container.pid = UInt64(parentPostID)
  container.subPostList = [subpost]
  return container
}

private func floorResponse(
  forumID: Int64,
  threadID: Int64,
  firstPostID: Int64,
  parentPostID: Int64,
  parentFloor: UInt32,
  parentAgreement: Bool?,
  subpostID: Int64,
  subpostAgreement: Bool?
) -> PbFloorResIdl {
  var forum = SimpleForum()
  forum.id = forumID
  forum.name = "swift"
  var thread = ThreadInfo()
  thread.id = threadID
  thread.fid = forumID
  thread.firstPostID = firstPostID
  thread.agree = agree(false, score: 5)
  var parent = Post()
  parent.id = parentPostID
  parent.floor = parentFloor
  parent.tid = threadID
  if let parentAgreement {
    parent.agree = agree(parentAgreement, score: parentAgreement ? 4 : 3)
  }
  var subpost = SubPostList()
  subpost.id = subpostID
  subpost.floor = 1
  if let subpostAgreement {
    subpost.agree = agree(subpostAgreement, score: subpostAgreement ? 2 : 1)
  }
  var page = Page()
  page.pageSize = 20
  page.currentPage = 1
  page.totalPage = 1
  page.totalCount = 1
  var anti = Anti()
  anti.tbs = "0123456789abcdef0123456789"
  var data = PbFloorResIdl.DataRes()
  data.page = page
  data.anti = anti
  data.post = parent
  data.subpostList = [subpost]
  data.thread = thread
  data.forum = forum
  var response = PbFloorResIdl()
  response.data = data
  return response
}

private func agree(_ isAgreed: Bool, score: Int64) -> Agree {
  var agreement = Agree()
  agreement.agreeNum = score
  agreement.diffAgreeNum = score
  agreement.hasAgree_p = isAgreed ? 1 : 0
  return agreement
}

private func membershipResponse(
  userID: Int64,
  forumID: Int64,
  forumName: String,
  tbs: String
) -> FrsPageResIdl {
  var user = User()
  user.id = userID
  var forum = FrsPageResIdl.DataRes.ForumInfo()
  forum.id = forumID
  forum.name = forumName
  forum.isLike = 1
  var anti = FrsPageResIdl.DataRes.Anti()
  anti.tbs = tbs
  var data = FrsPageResIdl.DataRes()
  data.user = user
  data.forum = forum
  data.anti = anti
  var response = FrsPageResIdl()
  response.data = data
  return response
}

private func protobufPayload(from request: URLRequest) throws -> Data {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  let prefix = Data(
    "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
  )
  let suffix = Data("\r\n---*_r1999--\r\n".utf8)
  guard body.starts(with: prefix), body.count >= prefix.count + suffix.count else {
    throw TiebaClientError.transportFailure
  }
  return body.subdata(in: prefix.count..<(body.count - suffix.count))
}

private func formFields(_ request: URLRequest) throws -> [String: String] {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    .replacingOccurrences(of: "+", with: "%20")
  guard let items = components.queryItems else { throw TiebaClientError.transportFailure }
  return Dictionary(
    uniqueKeysWithValues: items.compactMap { item in
      item.value.map { (item.name, $0) }
    }
  )
}
