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
    let expectedSortOptions = [
      TiebaForumChannelSortOption(id: 37, title: "Custom"),
      TiebaForumChannelSortOption(
        id: 39,
        title: String(repeating: "e\u{301}", count: 40)
      ),
    ] + (40...49).map {
      TiebaForumChannelSortOption(id: Int32($0), title: "Sort \($0)")
    }
    XCTAssertEqual(
      result.channels,
      [
        TiebaForumChannel(
          id: 3_631_832,
          name: "Help",
          isDefault: true,
          sortOptions: expectedSortOptions
        )
      ]
    )
    XCTAssertEqual(result.channels.first?.sortOptions.count, 12)

    let thread = try XCTUnwrap(result.threads.first)
    XCTAssertEqual(thread.id, 100)
    XCTAssertEqual(thread.author?.preferredName, "Swift Author")
    XCTAssertEqual(thread.author?.portrait, "portrait-token")
    XCTAssertEqual(thread.author?.moderatorRole, .moderator)
    XCTAssertEqual(thread.content.plainText, "Hello @reader")
    XCTAssertEqual(thread.content.images.first?.width, 640)
    XCTAssertEqual(
      thread.content.images.first?.thumbnailURL?.absoluteString, "https://img.example/thumb.jpg")
    XCTAssertTrue(thread.isPinned)
  }

  func testHotThreadRankingClientMapsFixtureAndForwardsUnknownCategory() async throws {
    let transport = CapturingTransport(
      body: try ProtoFixtures.hotThreadRanking().serializedData()
    )
    let client = TiebaClient(transport: transport)

    let result = try await client.getHotThreadRanking(categoryCode: " server-37 ")

    XCTAssertEqual(result.topics.map(\.id), [101, 103])
    XCTAssertEqual(result.categories.map(\.code), ["changgeng", "server-37", "youxi"])
    XCTAssertEqual(result.items.map(\.id), [1_001, 1_002, 1_007])
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let decoded = try HotThreadListReqIdl(
      serializedBytes: protobufPayload(from: try XCTUnwrap(request.httpBody))
    )
    XCTAssertEqual(decoded.data.tabID, "1")
    XCTAssertEqual(decoded.data.tabCode, "server-37")
    XCTAssertEqual(decoded.data.common.clientType, 2)
    XCTAssertEqual(decoded.data.common.clientVersion, "12.64.1.1")
  }

  func testHotThreadRankingClientMapsServerError() async {
    var response = HotThreadListResIdl()
    response.error.errorno = 4
    response.error.errmsg = "ranking unavailable"
    let body: Data
    do {
      body = try response.serializedData()
    } catch {
      XCTFail("Failed to serialize fixture: \(error)")
      return
    }
    let client = TiebaClient(transport: StubTransport(body: body))

    await assertClientError(.server(code: 4, message: "ranking unavailable")) {
      _ = try await client.getHotThreadRanking()
    }
  }

  func testPersonalizedClientMapsAndFiltersFeedWithoutEndingRawFullPage() async throws {
    var response = PersonalizedResIdl()
    response.data.threadList = [
      personalizedThread(id: 100, forumID: 10, forumName: "swift"),
      personalizedThread(id: 100, forumID: 10, forumName: "swift"),
      personalizedThread(id: 101, threadID: 102, forumID: 10, forumName: "swift"),
      personalizedThread(id: 103, forumID: 10, forumName: "swift", isAd: true),
      personalizedThread(id: 104, forumID: 10, forumName: "swift", isLive: true),
      personalizedThread(id: 105, forumID: 0, forumName: ""),
      personalizedThread(id: 106, forumID: 10, forumName: "swift"),
      personalizedThread(id: 107, forumID: 11, forumName: "ios"),
      personalizedThread(id: 108, forumID: 12, forumName: "xcode"),
      personalizedThread(id: 109, forumID: 13, forumName: "mac"),
      personalizedThread(id: 110, forumID: 14, forumName: "mobile"),
    ]
    var metadata = PersonalizedResIdl.ThreadPersonalized()
    metadata.tid = 100
    var reason = PersonalizedResIdl.DislikeReason()
    reason.id = 7
    reason.reason = "不感兴趣"
    reason.extra = "opaque"
    metadata.dislikeResource = [reason, reason]
    response.data.threadPersonalized = [metadata]

    let transport = CapturingTransport(body: try response.serializedData())
    let client = TiebaClient(transport: transport)
    let result = try await client.getPersonalizedThreads(page: 2)

    XCTAssertEqual(result.currentPage, 2)
    XCTAssertTrue(result.hasMore)
    XCTAssertEqual(result.items.map(\.id), [100, 106, 107, 108, 109, 110])
    XCTAssertEqual(result.items.first?.thread.forumName, "swift")
    XCTAssertEqual(result.items.first?.thread.author?.preferredName, "Author 100")
    XCTAssertEqual(result.items.first?.reasons, [
      TiebaRecommendationReason(id: 7, title: "不感兴趣", extra: "opaque")
    ])

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let decoded = try PersonalizedReqIdl(
      serializedBytes: protobufPayload(from: try XCTUnwrap(request.httpBody))
    )
    XCTAssertEqual(decoded.data.pn, 2)
    XCTAssertEqual(decoded.data.loadType, 2)
  }

  func testPersonalizedClientContinuesAfterShortNonemptyPageAndMapsServerError() async throws {
    var short = PersonalizedResIdl()
    short.data.threadList = [personalizedThread(id: 1, forumID: 2, forumName: "swift")]
    let page = try await TiebaClient(
      transport: StubTransport(body: try short.serializedData())
    ).getPersonalizedThreads()
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.items.map(\.id), [1])

    let emptyPage = try await TiebaClient(
      transport: StubTransport(body: try PersonalizedResIdl().serializedData())
    ).getPersonalizedThreads(page: 2)
    XCTAssertFalse(emptyPage.hasMore)
    XCTAssertTrue(emptyPage.items.isEmpty)

    var filtered = PersonalizedResIdl()
    filtered.data.threadList = [
      personalizedThread(id: 2, forumID: 2, forumName: "swift", isAd: true)
    ]
    let filteredPage = try await TiebaClient(
      transport: StubTransport(body: try filtered.serializedData())
    ).getPersonalizedThreads(page: 2)
    XCTAssertTrue(filteredPage.hasMore)
    XCTAssertTrue(filteredPage.items.isEmpty)

    var failure = PersonalizedResIdl()
    failure.error.errorno = 4
    failure.error.errmsg = "feed unavailable"
    let failedClient = TiebaClient(
      transport: StubTransport(body: try failure.serializedData())
    )
    await assertClientError(.server(code: 4, message: "feed unavailable")) {
      _ = try await failedClient.getPersonalizedThreads()
    }

    let oversizedClient = TiebaClient(
      transport: StubTransport(body: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1))
    )
    await assertClientError(.responseTooLarge(maximumBytes: 4 * 1_024 * 1_024)) {
      _ = try await oversizedClient.getPersonalizedThreads()
    }
  }

  func testMapsForumChannelPageAndCursor() async throws {
    let transport = CapturingTransport(
      body: try ProtoFixtures.forumChannelPage().serializedData()
    )
    let client = TiebaClient(transport: transport)
    let channel = TiebaForumChannel(
      id: 3_631_832,
      name: "Help",
      sortOptions: [TiebaForumChannelSortOption(id: 37, title: "Custom")]
    )

    let result = try await client.getForumChannelThreads(
      forumID: 42,
      forumName: " swift ",
      channel: channel,
      page: 2,
      pageSize: 30,
      lastThreadID: 950
    )

    XCTAssertEqual(result.channel, channel)
    XCTAssertEqual(result.pagination.currentPage, 2)
    XCTAssertTrue(result.pagination.hasMore)
    XCTAssertTrue(result.pagination.hasPrevious)
    XCTAssertEqual(result.threads.map(\.id), [900, 800])
    XCTAssertEqual(result.threads.first?.forumID, 42)
    XCTAssertEqual(result.threads.first?.forumName, "swift")
    XCTAssertEqual(result.threads.first?.author?.preferredName, "Channel Author")
    XCTAssertEqual(result.threads.first?.content.plainText, "Channel content")
    XCTAssertEqual(result.nextPageCursor, 800)

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let decoded = try GeneralTabListReqIdl(
      serializedBytes: protobufPayload(from: try XCTUnwrap(request.httpBody))
    )
    XCTAssertEqual(decoded.data.pn, 2)
    XCTAssertEqual(decoded.data.lastThreadID, 950)
    XCTAssertEqual(decoded.data.sortType, 37)

    let noMenuChannel = TiebaForumChannel(id: 3_631_833, name: "No menu")
    _ = try await client.getForumChannelThreads(
      forumID: 42,
      forumName: "swift",
      channel: noMenuChannel
    )
    let capturedNoMenuRequest = await transport.lastRequest()
    let noMenuRequest = try XCTUnwrap(capturedNoMenuRequest)
    let noMenuDecoded = try GeneralTabListReqIdl(
      serializedBytes: protobufPayload(from: try XCTUnwrap(noMenuRequest.httpBody))
    )
    XCTAssertEqual(noMenuDecoded.data.sortType, -1)
  }

  func testMapsPostsAndEmbeddedComments() async throws {
    let transport = StubTransport(body: try ProtoFixtures.postPage().serializedData())
    let client = TiebaClient(transport: transport)

    let result = try await client.getPosts(threadID: 100)

    XCTAssertEqual(result.thread.title, "A test thread")
    XCTAssertNil(result.originThread)
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
    let firstPost = try XCTUnwrap(result.firstPost)
    XCTAssertEqual(firstPost.id, result.thread.firstPostID)
    XCTAssertEqual(firstPost.floor, 1)
    XCTAssertEqual(firstPost.threadID, result.thread.id)
    XCTAssertEqual(firstPost.content.plainText, "First floor content")
    XCTAssertFalse(result.posts.contains { $0.floor == 1 || $0.id == firstPost.id })
    let post = try XCTUnwrap(result.posts.first)
    XCTAssertEqual(post.signature, "Sent from fixture")
    XCTAssertEqual(post.content.plainText, "Floor content")
    XCTAssertTrue(post.isThreadAuthor)
    XCTAssertEqual(post.author?.level, 12)
    XCTAssertEqual(post.author?.ipLocation, "Shanghai")
    XCTAssertEqual(post.author?.moderatorRole, .manager)
    XCTAssertEqual(post.author?.isModerator, true)
    XCTAssertEqual(post.agreeCount, 7)
    XCTAssertEqual(post.disagreeCount, 2)
    XCTAssertEqual(post.agreeScore, 5)
    let comment = try XCTUnwrap(post.comments.first)
    XCTAssertEqual(comment.author?.id, 8)
    XCTAssertEqual(comment.author?.level, 9)
    XCTAssertEqual(comment.author?.ipLocation, "Guangdong")
    XCTAssertEqual(comment.author?.moderatorRole, .assistant)
    XCTAssertEqual(comment.author?.isModerator, true)
    XCTAssertEqual(comment.parentPostID, post.id)
    XCTAssertEqual(comment.agreeScore, 3)
    XCTAssertEqual(comment.replyToUserID, 9)
    XCTAssertEqual(comment.replyToUserName, "target-user")
    XCTAssertEqual(comment.content.plainText, "回复 @target-user: Nested reply")
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

  func testLatestReplyLocationIsForwardedToTheAnonymousWireRequest() async throws {
    let transport = CapturingTransport(body: try ProtoFixtures.postPage().serializedData())
    let client = TiebaClient(transport: transport)

    _ = try await client.getPosts(
      threadID: 100,
      page: 7,
      sort: .descending,
      onlyThreadAuthor: true,
      location: .latestReplies(after: 201)
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try protobufPayload(from: body)
    let decoded = try PbPageReqIdl(serializedBytes: payload)
    XCTAssertEqual(decoded.data.pid, 201)
    XCTAssertEqual(decoded.data.pn, 0)
    XCTAssertEqual(decoded.data.lastPid, 201)
    XCTAssertTrue(decoded.data.hasLastPid)
    XCTAssertEqual(decoded.data.r, TiebaPostSort.descending.rawValue)
    XCTAssertEqual(decoded.data.lz, 1)
    XCTAssertEqual(decoded.data.common.bduss, "")
    XCTAssertEqual(decoded.data.common.stoken, "")
    XCTAssertNotNil(payload.range(of: Data([0x88, 0x05])))
  }

  func testEmbeddedCommentOptionsAreForwardedToTheAnonymousPostRequest() async throws {
    let transport = CapturingTransport(body: try ProtoFixtures.postPage().serializedData())
    let client = TiebaClient(transport: transport)

    _ = try await client.getPosts(
      threadID: 100,
      includeComments: true,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let decoded = try PbPageReqIdl(serializedBytes: protobufPayload(from: body))
    XCTAssertEqual(decoded.data.withFloor, 1)
    XCTAssertEqual(decoded.data.floorSortType, 1)
    XCTAssertEqual(decoded.data.floorRn, 4)
    XCTAssertEqual(decoded.data.common.bduss, "")
    XCTAssertEqual(decoded.data.common.stoken, "")
  }

  func testEmbeddedCommentsAreBoundedBeforeMapping() async throws {
    var fixture = ProtoFixtures.postPage()
    var data = fixture.data
    var posts = data.postList
    var post = try XCTUnwrap(posts.first)
    let template = try XCTUnwrap(post.subPostList.subPostList.first)
    post.subPostList.subPostList = (1...60).map { id in
      var comment = template
      comment.id = Int64(id)
      return comment
    }
    posts[0] = post
    data.postList = posts
    fixture.data = data
    let client = TiebaClient(
      transport: StubTransport(body: try fixture.serializedData())
    )

    let result = try await client.getPosts(threadID: 100)

    XCTAssertEqual(result.posts.first?.comments.count, 50)
    XCTAssertEqual(result.posts.first?.comments.first?.id, 1)
    XCTAssertEqual(result.posts.first?.comments.last?.id, 50)
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
    XCTAssertEqual(result.parentPost.author?.moderatorRole, .manager)
    let comment = try XCTUnwrap(result.comments.first)
    XCTAssertEqual(comment.parentPostID, 201)
    XCTAssertEqual(comment.replyToUserID, 7)
    XCTAssertEqual(comment.replyToUserName, "thread-author")
    XCTAssertEqual(comment.content.plainText, "回复 @thread-author :Nested reply")
    XCTAssertEqual(comment.floor, 2)
    XCTAssertEqual(comment.author?.moderatorRole, .assistant)
  }

  func testAnchoredCommentRequestForwardsBothParentAndCommentIDs() async throws {
    let transport = CapturingTransport(body: try ProtoFixtures.commentPage().serializedData())
    let client = TiebaClient(transport: transport)

    _ = try await client.getComments(
      threadID: 100,
      postID: 201,
      aroundCommentID: 301,
      page: 2
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let decoded = try PbFloorReqIdl(serializedBytes: protobufPayload(from: body))
    XCTAssertEqual(decoded.data.kz, 100)
    XCTAssertEqual(decoded.data.pid, 201)
    XCTAssertEqual(decoded.data.spid, 301)
    XCTAssertEqual(decoded.data.pn, 2)
  }

  func testResolvingCommentRequestOmitsParentAndForwardsSubpostID() async throws {
    let transport = CapturingTransport(body: try ProtoFixtures.commentPage().serializedData())
    let client = TiebaClient(transport: transport)

    let result = try await client.getComments(
      threadID: 100,
      resolvingCommentID: 202
    )

    XCTAssertEqual(result.parentPost.id, 201)
    XCTAssertTrue(result.comments.contains(where: { $0.id == 202 }))
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let decoded = try PbFloorReqIdl(serializedBytes: protobufPayload(from: body))
    XCTAssertEqual(decoded.data.kz, 100)
    XCTAssertEqual(decoded.data.pid, 0)
    XCTAssertEqual(decoded.data.spid, 202)
    XCTAssertEqual(decoded.data.pn, 1)
  }

  func testMapsPublicUserProfile() async throws {
    let transport = StubTransport(body: try ProtoFixtures.userProfile().serializedData())
    let client = TiebaClient(transport: transport)

    let profile = try await client.getUserProfile(userID: 957_339_815)

    XCTAssertEqual(profile.user.id, 957_339_815)
    XCTAssertEqual(profile.user.preferredName, "Profile User")
    XCTAssertEqual(profile.user.portrait, "profile-portrait")
    XCTAssertEqual(profile.portraitSource, "profile-portrait?t=1234567890")
    XCTAssertEqual(profile.user.growthLevel, 12)
    XCTAssertEqual(profile.user.gender, .female)
    XCTAssertEqual(profile.tiebaUID, 123_456_789)
    XCTAssertEqual(profile.biography, "Public biography")
    XCTAssertEqual(profile.threadCount, 123)
    XCTAssertEqual(profile.followerCount, 345)
    XCTAssertEqual(
      profile.likedForums,
      [TiebaProfileForum(id: 42, name: "swift"), TiebaProfileForum(id: 77, name: "ios")]
    )
    XCTAssertEqual(profile.totalAgreeCount, 12_345)
    XCTAssertTrue(profile.user.isVIP)
    XCTAssertTrue(profile.user.isVerifiedCreator)
    XCTAssertTrue(profile.isBlocked)
  }

  func testMapsPublicUserThreadsAndUsesEmptyPageAsPaginationTerminator() async throws {
    let transport = StubTransport(body: try ProtoFixtures.userThreadPage().serializedData())
    let client = TiebaClient(transport: transport)

    let page = try await client.getUserThreads(
      userID: 957_339_815,
      page: 2,
      pageSize: 20
    )

    XCTAssertEqual(page.userID, 957_339_815)
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertTrue(page.pagination.hasMore)
    let thread = try XCTUnwrap(page.threads.first)
    XCTAssertEqual(thread.id, 700)
    XCTAssertEqual(thread.firstPostID, 701)
    XCTAssertEqual(thread.forumName, "swift")
    XCTAssertEqual(thread.author?.preferredName, "Profile User")
    XCTAssertEqual(thread.content.plainText, "Public activity")
    XCTAssertEqual(thread.content.images.count, 1)
    XCTAssertEqual(thread.replyCount, 19)
    XCTAssertEqual(thread.viewCount, 456)

    let empty = UserPostResIdl()
    let emptyClient = TiebaClient(transport: StubTransport(body: try empty.serializedData()))
    let lastPage = try await emptyClient.getUserThreads(userID: 957_339_815, page: 3)
    XCTAssertFalse(lastPage.pagination.hasMore)
    XCTAssertTrue(lastPage.threads.isEmpty)
  }

  func testMapsEveryInnerPublicUserReplyUsingItsOwnIdentityTimeAndType() async throws {
    let client = TiebaClient(
      transport: StubTransport(body: try ProtoFixtures.userReplyPage().serializedData())
    )

    let page = try await client.getUserReplies(
      userID: 957_339_815,
      page: 2,
      pageSize: 20
    )

    XCTAssertEqual(page.userID, 957_339_815)
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertEqual(page.pagination.pageSize, 20)
    XCTAssertTrue(page.pagination.hasPrevious)
    XCTAssertTrue(page.pagination.hasMore)
    XCTAssertFalse(page.isHidden)
    XCTAssertEqual(page.replies.map(\.postID), [801, 802, 803])
    XCTAssertEqual(page.replies.map(\.threadID), [700, 700, 700])
    XCTAssertEqual(page.replies.map(\.forumID), [42, 42, 42])
    XCTAssertEqual(
      page.replies.map(\.createdAt),
      [
        Date(timeIntervalSince1970: 1_700_200_001),
        Date(timeIntervalSince1970: 1_700_200_002),
        Date(timeIntervalSince1970: 1_700_200_003),
      ]
    )
    XCTAssertEqual(page.replies.map(\.target), [.post, .comment, .unsupported(rawType: 37)])
    XCTAssertEqual(page.replies[0].content.plainText, "An ordinary floor")
    XCTAssertEqual(page.replies[1].content.plainText, "A nested replyReference")
    let mappedLink = page.replies[1].content.fragments.compactMap { fragment -> TiebaLink? in
      guard case .link(let link) = fragment else { return nil }
      return link
    }.first
    XCTAssertEqual(mappedLink?.url?.absoluteString, "https://tieba.baidu.com/p/700")
    XCTAssertEqual(page.replies[0].author?.id, 957_339_815)
    XCTAssertEqual(page.replies[0].author?.preferredName, "Profile User")
    XCTAssertFalse(page.replies.contains(where: { $0.postID == 999_999 }))
  }

  func testPublicUserRepliesRejectMismatchedUserAndMapHiddenAndEmptyPages() async throws {
    let mismatchedClient = TiebaClient(
      transport: StubTransport(body: try ProtoFixtures.userReplyPage().serializedData())
    )
    let mismatched = try await mismatchedClient.getUserReplies(userID: 999, page: 1)
    XCTAssertTrue(mismatched.replies.isEmpty)
    XCTAssertTrue(mismatched.pagination.hasMore)

    var hiddenFixture = ProtoFixtures.userReplyPage()
    hiddenFixture.data.hidePost = 1
    let hiddenClient = TiebaClient(
      transport: StubTransport(body: try hiddenFixture.serializedData())
    )
    let hidden = try await hiddenClient.getUserReplies(userID: 957_339_815, page: 1)
    XCTAssertTrue(hidden.isHidden)
    XCTAssertFalse(hidden.replies.isEmpty)

    let emptyClient = TiebaClient(
      transport: StubTransport(body: try UserPostResIdl().serializedData())
    )
    let empty = try await emptyClient.getUserReplies(userID: 957_339_815, page: 3)
    XCTAssertTrue(empty.replies.isEmpty)
    XCTAssertFalse(empty.pagination.hasMore)
    XCTAssertTrue(empty.pagination.hasPrevious)
  }

  func testPublicUserRepliesRejectResponseLargerThanFourMiB() async {
    let maximumBytes = 4 * 1_024 * 1_024
    let client = TiebaClient(
      transport: StubTransport(body: Data(count: maximumBytes + 1))
    )

    await assertClientError(.responseTooLarge(maximumBytes: maximumBytes)) {
      _ = try await client.getUserReplies(userID: 957_339_815)
    }
  }

  func testMapsAnonymousForumOverviewModeratorsAndRules() async throws {
    let overviewClient = TiebaClient(
      transport: StubTransport(body: try ProtoFixtures.forumOverview().serializedData())
    )
    let overview = try await overviewClient.getForumOverview(forumID: 42)
    XCTAssertEqual(overview.forum.id, 42)
    XCTAssertEqual(overview.forum.name, "swift")
    XCTAssertEqual(overview.forum.category, "technology")
    XCTAssertEqual(overview.forum.memberCount, 1_000)
    XCTAssertEqual(overview.forum.postCount, 3_000)
    XCTAssertEqual(overview.introduction, "A public forum introduction")
    XCTAssertEqual(overview.originalAvatar, "https://img.example/forum-original.png")
    XCTAssertTrue(overview.forum.hasModerators)

    let moderatorsClient = TiebaClient(
      transport: StubTransport(body: try ProtoFixtures.forumModerators().serializedData())
    )
    let moderatorRoles = try await moderatorsClient.getForumModerators(forumID: 42)
    let ownerRole = try XCTUnwrap(moderatorRoles.first)
    XCTAssertEqual(ownerRole.name, "吧主")
    let owner = try XCTUnwrap(ownerRole.moderators.first)
    XCTAssertEqual(owner.id, 7)
    XCTAssertEqual(owner.preferredName, "Forum Owner")
    XCTAssertEqual(owner.portrait, "moderator-portrait")
    XCTAssertEqual(owner.level, 16)
    XCTAssertEqual(owner.roleName, ownerRole.name)

    let rulesClient = TiebaClient(
      transport: StubTransport(body: try ProtoFixtures.forumRules().serializedData())
    )
    let rules = try await rulesClient.getForumRules(forumID: 42)
    XCTAssertEqual(rules.forum.id, 42)
    XCTAssertEqual(rules.forum.name, "swift")
    XCTAssertEqual(rules.title, "Swift 吧规")
    XCTAssertEqual(rules.preface, "Welcome")
    XCTAssertEqual(rules.publishTime, "2026-08-02")
    XCTAssertEqual(rules.rules.first?.title, "Be constructive")
    XCTAssertEqual(
      rules.rules.first?.content.plainText,
      "Read before posting and respect other members"
    )
    XCTAssertEqual(rules.author?.id, 7)
    XCTAssertEqual(rules.author?.roleName, "吧主")
  }

  func testGlobalThreadSearchClientForwardsEverySortAndDecodesEachPage() async throws {
    let body = Data(
      #"{"no":0,"error":"success","data":{"current_page":3,"has_more":1,"post_list":[{"tid":"42","pid":"201","content":"match","main_post":{"tid":42,"title":"topic"}}]}}"#.utf8
    )
    let transport = CapturingTransport(body: body)
    let client = TiebaClient(transport: transport)

    for sort in TiebaGlobalThreadSearchSort.allCases {
      let page = try await client.searchThreads(
        query: "async",
        page: 3,
        pageSize: 5,
        sort: sort
      )

      XCTAssertEqual(page.pagination.currentPage, 3)
      XCTAssertTrue(page.pagination.hasMore)
      XCTAssertEqual(page.results.first?.threadID, 42)
      XCTAssertEqual(page.results.first?.target, .post(201))

      let capturedRequest = await transport.lastRequest()
      let request = try XCTUnwrap(capturedRequest)
      let query = try XCTUnwrap(
        URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      )
      XCTAssertEqual(
        Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
        [
          "word": "async", "pn": "3", "rn": "5", "st": String(sort.rawValue),
          "tt": "1", "ct": "1", "is_use_zonghe": "1", "cv": "99.9.101",
        ]
      )
    }

    _ = try await client.searchThreads(query: "async")
    let capturedDefaultRequest = await transport.lastRequest()
    let defaultRequest = try XCTUnwrap(capturedDefaultRequest)
    let defaultQuery = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(defaultRequest.url), resolvingAgainstBaseURL: false)
    )
    XCTAssertEqual(defaultQuery.queryItems?.first(where: { $0.name == "st" })?.value, "5")
  }

  func testForumPostSearchClientForwardsOptionsAndDecodesPage() async throws {
    let body = Data(
      #"{"no":0,"error":"success","data":{"current_page":3,"has_more":1,"post_list":[{"tid":"42","pid":"201","content":"match","main_post":{"tid":42,"title":"topic"}}]}}"#.utf8
    )
    let transport = CapturingTransport(body: body)
    let client = TiebaClient(transport: transport)

    let page = try await client.searchForumPosts(
      query: "async",
      forumName: "swift",
      page: 3,
      pageSize: 5,
      sort: .relevance,
      filter: .all
    )

    XCTAssertEqual(page.pagination.currentPage, 3)
    XCTAssertTrue(page.pagination.hasMore)
    XCTAssertEqual(page.results.first?.target, .post(201))
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let query = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
    )
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
      [
        "word": "async", "pn": "3", "rn": "5", "st": "2", "tt": "2",
        "fname": "swift", "ct": "2", "cv": "12.64.1.1",
      ]
    )
  }

  func testMapsModeratorEndpointServerErrorFromItsSecondResponseField() async throws {
    var response = GetBawuInfoResIdl()
    response.error.errorno = 4
    response.error.errmsg = "forum unavailable"
    let client = TiebaClient(transport: StubTransport(body: try response.serializedData()))

    await assertClientError(.server(code: 4, message: "forum unavailable")) {
      _ = try await client.getForumModerators(forumID: 42)
    }
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

  private func personalizedThread(
    id: Int64,
    threadID: Int64? = nil,
    forumID: Int64,
    forumName: String,
    isAd: Bool = false,
    isLive: Bool = false
  ) -> ThreadInfo {
    var thread = ThreadInfo()
    thread.id = id
    thread.threadID = threadID ?? id
    thread.firstPostID = id + 1_000
    thread.fid = forumID
    thread.fname = forumName
    thread.title = "Thread \(id)"
    thread.replyNum = 5
    thread.viewNum = 20
    thread.isAd = isAd ? 1 : 0
    thread.alaInfo = isLive ? Data([0x08, 0x01]) : Data()
    thread.author.id = id + 2_000
    thread.author.nameShow = "Author \(id)"
    return thread
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
