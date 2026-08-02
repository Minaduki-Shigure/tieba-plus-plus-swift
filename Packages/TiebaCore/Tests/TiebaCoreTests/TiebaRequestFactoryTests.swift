import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaRequestFactoryTests: XCTestCase {
  private let factory = TiebaRequestFactory(configuration: .init())

  func testThreadRequestMatchesAiotiebaWireFixture() throws {
    let request = try factory.threads(
      forumName: "starry",
      page: 1,
      pageSize: 10,
      sort: .replyTime,
      featuredOnly: false
    )
    let payload = try protobufPayload(from: request)

    let aiotiebaFixture = try XCTUnwrap(
      Data(hexString: "0a1fba020d0802120931322e36342e312e310a06737461727279100a180ff80206")
    )
    let decoded = try FrsPageReqIdl(serializedBytes: payload)
    XCTAssertEqual(decoded, try FrsPageReqIdl(serializedBytes: aiotiebaFixture))
    XCTAssertEqual(decoded.data.common.clientType, 2)
    XCTAssertEqual(decoded.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(decoded.data.common.bduss, "")
    XCTAssertEqual(decoded.data.common.stoken, "")
    XCTAssertEqual(decoded.data.common.zID, "")
    XCTAssertEqual(decoded.data.kw, "starry")
    XCTAssertEqual(decoded.data.pn, 0)
    XCTAssertEqual(decoded.data.rnNeed, 15)
  }

  func testPostAndCommentRequestWireFixtures() throws {
    let postRequest = try factory.posts(
      threadID: 123_456,
      page: 1,
      pageSize: 10,
      sort: .ascending,
      onlyThreadAuthor: false,
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let postFixture = try XCTUnwrap(
      Data(hexString: "0a19ca010d0802120931322e36342e312e3120c0c407680a900101")
    )
    XCTAssertEqual(
      try PbPageReqIdl(serializedBytes: protobufPayload(from: postRequest)),
      try PbPageReqIdl(serializedBytes: postFixture)
    )

    let commentRequest = try factory.comments(
      threadID: 123_456,
      anchorID: 654_321,
      page: 1,
      anchorIsComment: false
    )
    let commentFixture = try XCTUnwrap(
      Data(hexString: "0a194a0d0802120931322e36342e312e3108c0c40710f1f7272001")
    )
    XCTAssertEqual(
      try PbFloorReqIdl(serializedBytes: protobufPayload(from: commentRequest)),
      try PbFloorReqIdl(serializedBytes: commentFixture)
    )

    let aroundRequest = try factory.comments(
      threadID: 123_456,
      anchorID: 654_321,
      page: 2,
      anchorIsComment: true
    )
    let aroundFixture = try XCTUnwrap(
      Data(hexString: "0a194a0d0802120931322e36342e312e3108c0c40718f1f7272002")
    )
    XCTAssertEqual(
      try PbFloorReqIdl(serializedBytes: protobufPayload(from: aroundRequest)),
      try PbFloorReqIdl(serializedBytes: aroundFixture)
    )
  }

  func testBrowseSortAndFilterOptionsAreEncoded() throws {
    let featuredCreationRequest = try factory.threads(
      forumName: "swift",
      page: 2,
      pageSize: 30,
      sort: .creationTime,
      featuredOnly: true,
      featuredClassificationID: 9
    )
    let featuredCreation = try FrsPageReqIdl(
      serializedBytes: protobufPayload(from: featuredCreationRequest)
    )
    XCTAssertEqual(featuredCreation.data.sortType, TiebaThreadSort.creationTime.rawValue)
    XCTAssertEqual(featuredCreation.data.isGood, 1)
    XCTAssertEqual(featuredCreation.data.classID, 9)

    let descendingAuthorRequest = try factory.posts(
      threadID: 123_456,
      page: 2,
      pageSize: 30,
      sort: .descending,
      onlyThreadAuthor: true,
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let descendingAuthor = try PbPageReqIdl(
      serializedBytes: protobufPayload(from: descendingAuthorRequest)
    )
    XCTAssertEqual(descendingAuthor.data.r, TiebaPostSort.descending.rawValue)
    XCTAssertEqual(descendingAuthor.data.lz, 1)

    let hotRequest = try factory.posts(
      threadID: 123_456,
      page: 1,
      pageSize: 30,
      sort: .hot,
      onlyThreadAuthor: false,
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let hot = try PbPageReqIdl(serializedBytes: protobufPayload(from: hotRequest))
    XCTAssertEqual(hot.data.r, TiebaPostSort.hot.rawValue)
    XCTAssertEqual(hot.data.lz, 0)
  }

  func testForumChannelRequestUsesIndependentSortAndMinimalAnonymousFields() throws {
    let channel = TiebaForumChannel(id: 3_631_832, name: " Help ", isDefault: true)
    let request = try factory.forumChannelThreads(
      forumID: 2_432_903,
      channel: channel,
      page: 2,
      pageSize: 30,
      sort: .creationTime,
      lastThreadID: 10_911_529_130
    )
    let decoded = try GeneralTabListReqIdl(
      serializedBytes: protobufPayload(from: request)
    )

    XCTAssertEqual(TiebaForumChannelSort.replyTime.rawValue, 0)
    XCTAssertEqual(TiebaForumChannelSort.creationTime.rawValue, 1)
    XCTAssertEqual(request.url?.path, "/c/f/frs/generalTabList")
    XCTAssertEqual(request.url?.query, "cmd=309622")
    XCTAssertEqual(decoded.data.common.clientType, 2)
    XCTAssertEqual(decoded.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(decoded.data.common.bduss, "")
    XCTAssertEqual(decoded.data.common.stoken, "")
    XCTAssertEqual(decoded.data.common.clientID, "")
    XCTAssertEqual(decoded.data.common.phoneImei, "")
    XCTAssertEqual(decoded.data.tabID, 3_631_832)
    XCTAssertEqual(decoded.data.forumID, 2_432_903)
    XCTAssertEqual(decoded.data.pn, 2)
    XCTAssertEqual(decoded.data.rn, 30)
    XCTAssertEqual(decoded.data.lastThreadID, 10_911_529_130)
    XCTAssertEqual(decoded.data.isDefaultNavtab, 1)
    XCTAssertEqual(decoded.data.tabName, "Help")
    XCTAssertEqual(decoded.data.isGeneralTab, 1)
    XCTAssertEqual(decoded.data.sortType, 1)
    XCTAssertEqual(decoded.data.tabType, 15)
    XCTAssertEqual(decoded.data.isNewfrs, 1)
  }

  func testPostLocationWireSemantics() throws {
    let descendingInitialRequest = try factory.posts(
      threadID: 123_456,
      page: 1,
      pageSize: 30,
      sort: .descending,
      onlyThreadAuthor: false,
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let descendingInitial = try PbPageReqIdl(
      serializedBytes: protobufPayload(from: descendingInitialRequest)
    )
    XCTAssertEqual(descendingInitial.data.pid, 0)
    XCTAssertEqual(descendingInitial.data.pn, 0)
    XCTAssertEqual(descendingInitial.data.r, TiebaPostSort.descending.rawValue)

    let explicitPageRequest = try factory.posts(
      threadID: 123_456,
      page: 1,
      pageSize: 30,
      sort: .descending,
      onlyThreadAuthor: false,
      location: .pageNumber,
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let explicitPage = try PbPageReqIdl(
      serializedBytes: protobufPayload(from: explicitPageRequest)
    )
    XCTAssertEqual(explicitPage.data.pid, 0)
    XCTAssertEqual(explicitPage.data.pn, 1)

    let locatedRequest = try factory.posts(
      threadID: 123_456,
      page: 5,
      pageSize: 30,
      sort: .ascending,
      onlyThreadAuthor: false,
      location: .postID(654_321),
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let located = try PbPageReqIdl(serializedBytes: protobufPayload(from: locatedRequest))
    XCTAssertEqual(located.data.pid, 654_321)
    XCTAssertEqual(located.data.pn, 0)

    let cursorRequest = try factory.posts(
      threadID: 123_456,
      page: 4,
      pageSize: 30,
      sort: .descending,
      onlyThreadAuthor: false,
      location: .pageCursor(654_321),
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let cursor = try PbPageReqIdl(serializedBytes: protobufPayload(from: cursorRequest))
    XCTAssertEqual(cursor.data.pid, 654_321)
    XCTAssertEqual(cursor.data.pn, 4)
    XCTAssertEqual(cursor.data.r, TiebaPostSort.descending.rawValue)

    let zeroHintRequest = try factory.posts(
      threadID: 123_456,
      page: 0,
      pageSize: 30,
      sort: .descending,
      onlyThreadAuthor: false,
      location: .pageCursor(654_321),
      includeComments: false,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let zeroHint = try PbPageReqIdl(serializedBytes: protobufPayload(from: zeroHintRequest))
    XCTAssertEqual(zeroHint.data.pid, 654_321)
    XCTAssertEqual(zeroHint.data.pn, 0)
  }

  func testEveryEndpointIsHTTPSAndCredentialFree() throws {
    let requests = [
      try factory.threads(
        forumName: "swift",
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        featuredOnly: false
      ),
      try factory.forumChannelThreads(
        forumID: 42,
        channel: TiebaForumChannel(id: 9, name: "Help"),
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        lastThreadID: nil
      ),
      try factory.posts(
        threadID: 1,
        page: 1,
        pageSize: 30,
        sort: .ascending,
        onlyThreadAuthor: false,
        includeComments: true,
        commentsSortedByAgree: true,
        commentPageSize: 4
      ),
      try factory.comments(threadID: 1, anchorID: 2, page: 1, anchorIsComment: false),
      try factory.userProfile(userID: 957_339_815),
      try factory.userThreads(userID: 957_339_815, page: 1, pageSize: 20),
      try factory.forumOverview(forumID: 42),
      try factory.forumModerators(forumID: 42),
      try factory.forumRules(forumID: 42),
    ]

    XCTAssertEqual(
      requests.map(\.url?.path),
      [
        "/c/f/frs/page", "/c/f/frs/generalTabList", "/c/f/pb/page", "/c/f/pb/floor",
        "/c/u/user/profile", "/c/u/feed/userpost", "/c/f/forum/getforumdetail",
        "/c/f/forum/getBawuInfo", "/c/f/forum/forumRuleDetail",
      ]
    )
    XCTAssertEqual(
      requests.map(\.url?.query),
      [
        "cmd=301001", "cmd=309622", "cmd=302001", "cmd=302002", "cmd=303012",
        "cmd=303002", "cmd=303021", "cmd=301007", "cmd=309690",
      ]
    )
    for request in requests {
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

      let body = try XCTUnwrap(request.httpBody)
      let printableBody = String(decoding: body, as: UTF8.self).lowercased()
      XCTAssertFalse(printableBody.contains("bduss"))
      XCTAssertFalse(printableBody.contains("stoken"))
    }
  }

  func testPublicUserRequestsEncodeTiebaLiteCompatibleFields() throws {
    let profileRequest = try factory.userProfile(userID: 957_339_815)
    let profile = try ProfileReqIdl(
      serializedBytes: protobufPayload(from: profileRequest)
    )
    XCTAssertEqual(profile.data.uid, 0)
    XCTAssertEqual(profile.data.needPostCount, 1)
    XCTAssertEqual(profile.data.friendUid, 957_339_815)
    XCTAssertEqual(profile.data.isGuest, 1)
    XCTAssertEqual(profile.data.pn, 1)
    XCTAssertEqual(profile.data.rn, 20)
    XCTAssertEqual(profile.data.hasPlist_p, 1)
    XCTAssertEqual(profile.data.isFromUsercenter, 1)
    XCTAssertEqual(profile.data.page, 1)
    XCTAssertEqual(profile.data.common.clientType, 2)
    XCTAssertEqual(profile.data.common.bduss, "")
    XCTAssertEqual(profile.data.common.stoken, "")

    let threadsRequest = try factory.userThreads(
      userID: 957_339_815,
      page: 2,
      pageSize: 20
    )
    let threads = try UserPostReqIdl(
      serializedBytes: protobufPayload(from: threadsRequest)
    )
    XCTAssertEqual(threads.data.uid, 957_339_815)
    XCTAssertEqual(threads.data.rn, 20)
    XCTAssertEqual(threads.data.isThread, 1)
    XCTAssertEqual(threads.data.needContent, 1)
    XCTAssertEqual(threads.data.pn, 2)
    XCTAssertEqual(threads.data.isViewCard, 1)
    XCTAssertEqual(threads.data.common.bduss, "")
    XCTAssertEqual(threads.data.common.stoken, "")
  }

  func testPublicForumMetadataRequestsMatchWireFixtures() throws {
    let overviewRequest = try factory.forumOverview(forumID: 42)
    let overviewPayload = try protobufPayload(from: overviewRequest)
    let overviewFixture = try XCTUnwrap(
      Data(hexString: "0a11082a120d0802120931322e36342e312e31")
    )
    let overview = try GetForumDetailReqIdl(serializedBytes: overviewPayload)
    XCTAssertEqual(overview, try GetForumDetailReqIdl(serializedBytes: overviewFixture))
    XCTAssertEqual(overview.data.forumID, 42)
    XCTAssertEqual(overview.data.common.clientType, 2)
    XCTAssertEqual(overview.data.common.clientVersion, "12.64.1.1")
    XCTAssertEqual(overview.data.common.bduss, "")
    XCTAssertEqual(overview.data.common.stoken, "")

    let moderatorsRequest = try factory.forumModerators(forumID: 42)
    let moderatorsPayload = try protobufPayload(from: moderatorsRequest)
    let moderatorsFixture = try XCTUnwrap(
      Data(hexString: "0a110a0d0802120931322e36342e312e31102a")
    )
    let moderators = try GetBawuInfoReqIdl(serializedBytes: moderatorsPayload)
    XCTAssertEqual(moderators, try GetBawuInfoReqIdl(serializedBytes: moderatorsFixture))
    XCTAssertEqual(moderators.data.fid, 42)
    XCTAssertEqual(moderators.data.common.clientType, 2)
    XCTAssertEqual(moderators.data.common.bduss, "")
    XCTAssertEqual(moderators.data.common.stoken, "")

    let rulesRequest = try factory.forumRules(forumID: 42)
    let rulesPayload = try protobufPayload(from: rulesRequest)
    let rulesFixture = try XCTUnwrap(
      Data(hexString: "0a11082a120d0802120931322e36342e312e31")
    )
    let rules = try ForumRuleDetailReqIdl(serializedBytes: rulesPayload)
    XCTAssertEqual(rules, try ForumRuleDetailReqIdl(serializedBytes: rulesFixture))
    XCTAssertEqual(rules.data.forumID, 42)
    XCTAssertEqual(rules.data.common.clientType, 2)
    XCTAssertEqual(rules.data.common.bduss, "")
    XCTAssertEqual(rules.data.common.stoken, "")
  }

  func testRejectsInvalidArgumentsAndHeaderInjection() throws {
    XCTAssertThrowsError(
      try factory.threads(
        forumName: "  ",
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        featuredOnly: false
      )
    )
    XCTAssertThrowsError(
      try factory.comments(threadID: 0, anchorID: 1, page: 1, anchorIsComment: false)
    )
    XCTAssertThrowsError(
      try factory.posts(
        threadID: 1,
        page: 1,
        pageSize: 30,
        sort: .descending,
        onlyThreadAuthor: false,
        location: .pageCursor(0),
        includeComments: false,
        commentsSortedByAgree: true,
        commentPageSize: 4
      )
    )
    XCTAssertThrowsError(
      try factory.posts(
        threadID: 1,
        page: 0,
        pageSize: 30,
        sort: .descending,
        onlyThreadAuthor: false,
        location: .pageNumber,
        includeComments: false,
        commentsSortedByAgree: true,
        commentPageSize: 4
      )
    )

    let injected = TiebaRequestFactory(
      configuration: .init(userAgent: "client\r\nAuthorization: secret")
    )
    XCTAssertThrowsError(
      try injected.threads(
        forumName: "swift",
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        featuredOnly: false
      )
    )
    XCTAssertThrowsError(try factory.searchForums(query: "  "))
    XCTAssertThrowsError(try factory.searchForums(query: String(repeating: "a", count: 101)))
    XCTAssertThrowsError(try factory.searchUsers(query: "  "))
    XCTAssertThrowsError(try factory.searchUsers(query: String(repeating: "a", count: 101)))
    XCTAssertThrowsError(try factory.searchThreads(query: "swift", page: 0, pageSize: 20))
    XCTAssertThrowsError(try factory.searchThreads(query: "swift", page: 1, pageSize: 51))
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "  ", forumName: "swift", page: 1, pageSize: 20, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "async", forumName: "  ", page: 1, pageSize: 20, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: String(repeating: "a", count: 101), forumName: "swift", page: 1,
        pageSize: 20, sort: .newest, filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "async", forumName: String(repeating: "a", count: 101), page: 1,
        pageSize: 20, sort: .newest, filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "async", forumName: "swift", page: 0, pageSize: 20, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "async", forumName: "swift", page: 1, pageSize: 0, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(
      try factory.searchForumPosts(
        query: "async", forumName: "swift", page: 1, pageSize: 51, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 0, topicName: "topic", page: 1, pageSize: 10, lastID: nil)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 1, topicName: "  ", page: 1, pageSize: 10, lastID: nil)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(
        topicID: 1,
        topicName: String(repeating: "a", count: 201),
        page: 1,
        pageSize: 10,
        lastID: nil
      )
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 1, topicName: "topic", page: 0, pageSize: 10, lastID: nil)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 1, topicName: "topic", page: 1, pageSize: 31, lastID: nil)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 1, topicName: "topic", page: 2, pageSize: 10, lastID: nil)
    )
    XCTAssertThrowsError(
      try factory.hotTopic(topicID: 1, topicName: "topic", page: 2, pageSize: 10, lastID: 0)
    )
    XCTAssertThrowsError(try factory.userProfile(userID: 0))
    XCTAssertThrowsError(
      try factory.forumChannelThreads(
        forumID: 0,
        channel: TiebaForumChannel(id: 1, name: "Help"),
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        lastThreadID: nil
      )
    )
    XCTAssertThrowsError(
      try factory.forumChannelThreads(
        forumID: 1,
        channel: TiebaForumChannel(id: 0, name: "Help"),
        page: 1,
        pageSize: 30,
        sort: .replyTime,
        lastThreadID: nil
      )
    )
    XCTAssertThrowsError(
      try factory.forumChannelThreads(
        forumID: 1,
        channel: TiebaForumChannel(id: 1, name: "   "),
        page: 0,
        pageSize: 101,
        sort: .replyTime,
        lastThreadID: 0
      )
    )
    XCTAssertThrowsError(try factory.userThreads(userID: 1, page: 0, pageSize: 20))
    XCTAssertThrowsError(try factory.userThreads(userID: 1, page: 1, pageSize: 101))
    XCTAssertThrowsError(try factory.forumOverview(forumID: 0))
    XCTAssertThrowsError(try factory.forumModerators(forumID: -1))
    XCTAssertThrowsError(try factory.forumRules(forumID: 0))
    XCTAssertThrowsError(try injected.searchForums(query: "swift"))
    XCTAssertThrowsError(try injected.searchUsers(query: "swift"))
    XCTAssertThrowsError(
      try injected.searchForumPosts(
        query: "async", forumName: "swift", page: 1, pageSize: 20, sort: .newest,
        filter: .all)
    )
    XCTAssertThrowsError(try injected.hotTopics())
    XCTAssertThrowsError(
      try injected.hotTopic(
        topicID: 1,
        topicName: "topic",
        page: 1,
        pageSize: 10,
        lastID: nil
      )
    )
  }

  func testHotTopicRequestsUseCredentialFreeHTTPSWebEndpoints() throws {
    let listRequest = try factory.hotTopics()
    let detailRequest = try factory.hotTopic(
      topicID: 28_356_723,
      topicName: " \u{4e3b}\u{6301}\u{4eba}\u{8bdd}\u{9898} & iOS ",
      page: 2,
      pageSize: 10,
      lastID: 10_913_428_976
    )

    XCTAssertEqual(listRequest.url?.scheme, "https")
    XCTAssertEqual(listRequest.url?.host, "tieba.baidu.com")
    XCTAssertEqual(listRequest.url?.path, "/mo/q/hotMessage/list")
    XCTAssertEqual(queryItems(listRequest), ["fr": "newwise"])

    XCTAssertEqual(detailRequest.url?.scheme, "https")
    XCTAssertEqual(detailRequest.url?.host, "tieba.baidu.com")
    XCTAssertEqual(detailRequest.url?.path, "/mo/q/newtopic/topicDetail")
    XCTAssertEqual(
      queryItems(detailRequest),
      [
        "topic_id": "28356723",
        "topic_name": "\u{4e3b}\u{6301}\u{4eba}\u{8bdd}\u{9898} & iOS",
        "is_new": "1",
        "is_share": "1",
        "pn": "2",
        "rn": "10",
        "offset": "10",
        "last_id": "10913428976",
        "derivative_to_pic_id": "",
      ]
    )

    for request in [listRequest, detailRequest] {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.httpBody)
    }
  }

  func testSearchRequestsUseEncodedCredentialFreeHTTPSWebEndpoint() throws {
    let forumRequest = try factory.searchForums(query: " Swift & iOS ")
    let userRequest = try factory.searchUsers(query: "Swift 用户")
    let threadRequest = try factory.searchThreads(query: "Swift 中文", page: 2, pageSize: 15)

    XCTAssertEqual(forumRequest.url?.scheme, "https")
    XCTAssertEqual(forumRequest.url?.host, "tieba.baidu.com")
    XCTAssertEqual(forumRequest.url?.path, "/mo/q/search/forum")
    XCTAssertEqual(queryItems(forumRequest)["word"], "Swift & iOS")

    XCTAssertEqual(userRequest.url?.scheme, "https")
    XCTAssertEqual(userRequest.url?.host, "tieba.baidu.com")
    XCTAssertEqual(userRequest.url?.path, "/mo/q/search/user")
    XCTAssertEqual(queryItems(userRequest), ["word": "Swift 用户"])

    XCTAssertEqual(threadRequest.url?.scheme, "https")
    XCTAssertEqual(threadRequest.url?.host, "tieba.baidu.com")
    XCTAssertEqual(threadRequest.url?.path, "/mo/q/search/thread")
    XCTAssertEqual(
      queryItems(threadRequest),
      [
        "word": "Swift 中文",
        "pn": "2",
        "rn": "15",
        "st": "5",
        "tt": "1",
        "ct": "1",
        "is_use_zonghe": "1",
        "cv": "99.9.101",
      ]
    )

    for request in [forumRequest, userRequest, threadRequest] {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.httpBody)
    }
  }

  func testGlobalThreadSearchUsesDistinctSortContractAndExactCredentialFreeQueryItems() throws {
    XCTAssertEqual(TiebaGlobalThreadSearchSort.newest.rawValue, 5)
    XCTAssertEqual(TiebaGlobalThreadSearchSort.oldest.rawValue, 0)
    XCTAssertEqual(TiebaGlobalThreadSearchSort.relevance.rawValue, 2)
    XCTAssertEqual(TiebaThreadSearchSort.newest.rawValue, 1)

    let sorts: [(TiebaGlobalThreadSearchSort, String)] = [
      (.newest, "5"),
      (.oldest, "0"),
      (.relevance, "2"),
    ]

    for (sort, expectedValue) in sorts {
      let request = try factory.searchThreads(
        query: " Swift 中文 ",
        page: 2,
        pageSize: 15,
        sort: sort
      )
      let components = try XCTUnwrap(
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      )

      XCTAssertEqual(components.scheme, "https")
      XCTAssertEqual(components.host, "tieba.baidu.com")
      XCTAssertNil(components.port)
      XCTAssertNil(components.user)
      XCTAssertNil(components.password)
      XCTAssertEqual(components.path, "/mo/q/search/thread")
      XCTAssertEqual(
        components.queryItems,
        [
          URLQueryItem(name: "word", value: "Swift 中文"),
          URLQueryItem(name: "pn", value: "2"),
          URLQueryItem(name: "rn", value: "15"),
          URLQueryItem(name: "st", value: expectedValue),
          URLQueryItem(name: "tt", value: "1"),
          URLQueryItem(name: "ct", value: "1"),
          URLQueryItem(name: "is_use_zonghe", value: "1"),
          URLQueryItem(name: "cv", value: "99.9.101"),
        ]
      )
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertNil(request.httpBody)
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
      XCTAssertEqual(
        Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
        Set(["accept", "accept-encoding", "user-agent"])
      )
    }

    let defaultRequest = try factory.searchThreads(query: "swift", page: 1, pageSize: 20)
    XCTAssertEqual(queryItems(defaultRequest)["st"], "5")
  }

  func testForumPostSearchUsesTiebaLiteCompatibleCredentialFreeRequest() throws {
    let request = try factory.searchForumPosts(
      query: " async await ",
      forumName: " swift ",
      page: 2,
      pageSize: 15,
      sort: .relevance,
      filter: .threadsOnly
    )

    XCTAssertEqual(TiebaThreadSearchSort.newest.rawValue, 1)
    XCTAssertEqual(TiebaThreadSearchSort.relevance.rawValue, 2)
    XCTAssertEqual(TiebaThreadSearchFilter.threadsOnly.rawValue, 1)
    XCTAssertEqual(TiebaThreadSearchFilter.all.rawValue, 2)
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tieba.baidu.com")
    XCTAssertEqual(request.url?.path, "/mo/q/search/thread")
    XCTAssertEqual(
      queryItems(request),
      [
        "word": "async await",
        "pn": "2",
        "rn": "15",
        "st": "2",
        "tt": "1",
        "fname": "swift",
        "ct": "2",
        "cv": "12.64.1.1",
      ]
    )
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    XCTAssertEqual(
      Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
      Set(["accept", "accept-encoding", "user-agent"])
    )
  }

  func testEndpointPolicyRejectsDowngradeAndCrossHostRedirects() {
    XCTAssertTrue(TiebaEndpointPolicy.allows(URL(string: "https://tiebac.baidu.com/c/f/pb/page")))
    XCTAssertTrue(
      TiebaEndpointPolicy.allows(URL(string: "https://tieba.baidu.com/mo/q/search/forum")))
    XCTAssertFalse(TiebaEndpointPolicy.allows(URL(string: "http://tiebac.baidu.com/c/f/pb/page")))
    XCTAssertFalse(
      TiebaEndpointPolicy.allows(URL(string: "https://tiebac.baidu.com.example/c/f/pb/page")))
    XCTAssertFalse(
      TiebaEndpointPolicy.allows(URL(string: "https://tiebac.baidu.com:8443/c/f/pb/page")))
    XCTAssertFalse(
      TiebaEndpointPolicy.allows(URL(string: "https://user@tiebac.baidu.com/c/f/pb/page")))
    XCTAssertTrue(
      TiebaEndpointPolicy.allowsRedirect(
        from: URL(string: "https://tieba.baidu.com/mo/q/search/forum"),
        to: URL(string: "https://tieba.baidu.com/mo/q/search/forum?word=swift")
      )
    )
    XCTAssertFalse(
      TiebaEndpointPolicy.allowsRedirect(
        from: URL(string: "https://tiebac.baidu.com/c/f/pb/page"),
        to: URL(string: "https://tieba.baidu.com/mo/q/search/thread")
      )
    )
    XCTAssertFalse(
      TiebaEndpointPolicy.allowsRedirect(
        from: URL(string: "https://tiebac.baidu.com/c/s/login"),
        to: URL(string: "https://tiebac.baidu.com:8443/c/s/login")
      )
    )
    XCTAssertTrue(
      TiebaRedirectPolicy.sameOrigin.allows(
        from: URL(string: "https://tieba.baidu.com/mo/q/search/forum"),
        to: URL(string: "https://tieba.baidu.com/mo/q/search/forum?word=swift")
      )
    )
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tiebac.baidu.com/c/s/login"),
        to: URL(string: "https://tiebac.baidu.com/c/s/login-v2")
      )
    )
  }

  private func queryItems(_ request: URLRequest) -> [String: String] {
    guard
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: components.queryItems?.compactMap { item in
        item.value.map { (item.name, $0) }
      } ?? [])
  }

  private func protobufPayload(from request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8)
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    XCTAssertTrue(body.starts(with: prefix))
    XCTAssertTrue(body.count >= prefix.count + suffix.count)
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    return body.subdata(in: prefix.count..<body.count - suffix.count)
  }
}

extension Data {
  fileprivate init?(hexString: String) {
    let characters = Array(hexString.utf8)
    guard characters.count.isMultiple(of: 2) else { return nil }
    self.init()
    reserveCapacity(characters.count / 2)
    for index in stride(from: 0, to: characters.count, by: 2) {
      guard
        let byte = UInt8(
          String(bytes: characters[index...index + 1], encoding: .utf8) ?? "", radix: 16)
      else { return nil }
      append(byte)
    }
  }
}
