import TiebaProto
import XCTest

@testable import TiebaCore

final class TiebaProtoMapperTests: XCTestCase {
  func testUserReplyMappingBoundsOuterAndInnerCollectionsAndRejectsOverflowingTime() {
    var data = UserPostResIdl.DataRes()
    for groupIndex in 0...100 {
      var group = PostInfoList()
      group.forumID = 42
      group.threadID = UInt64(1_000 + groupIndex)
      group.userID = 957_339_815

      if groupIndex == 0 {
        group.content = (1...101).map { replyIndex in
          var reply = PostInfoList.PostInfoContent()
          reply.postID = UInt64(replyIndex)
          reply.createTime =
            replyIndex == 1 ? UInt64.max : UInt64(1_700_000_000 + replyIndex)
          return reply
        }
      } else {
        var reply = PostInfoList.PostInfoContent()
        reply.postID = UInt64(10_000 + groupIndex)
        reply.createTime = 1_700_000_000
        group.content = [reply]
      }
      data.postList.append(group)
    }

    let page = TiebaProtoMapper.userReplyPage(
      data,
      userID: 957_339_815,
      requestedPage: 1,
      pageSize: 20
    )

    XCTAssertEqual(page.replies.count, 199)
    XCTAssertEqual(page.replies.prefix(100).map(\.postID), (1...100).map { Int64($0) })
    XCTAssertNil(page.replies.first?.createdAt)
    XCTAssertNotNil(page.replies[1].createdAt)
    XCTAssertFalse(page.replies.contains(where: { $0.postID == 101 }))
    XCTAssertEqual(page.replies.last?.threadID, 1_099)
    XCTAssertFalse(page.replies.contains(where: { $0.threadID == 1_100 }))
  }

  func testHotThreadRankingMapsServerCategoriesAndRejectsMalformedDuplicates() throws {
    let ranking = TiebaProtoMapper.hotThreadRanking(ProtoFixtures.hotThreadRanking().data)

    XCTAssertEqual(ranking.topics.map(\.id), [101, 103])
    XCTAssertEqual(ranking.topics.map(\.rank), [1, 2])
    XCTAssertEqual(ranking.topics.first?.name, "First topic")
    XCTAssertEqual(ranking.topics.first?.description, "Topic description")
    XCTAssertEqual(ranking.topics.first?.discussionCount, Int64.max)
    XCTAssertEqual(ranking.topics.first?.tag, 2)
    XCTAssertEqual(ranking.topics.first?.imageURL?.absoluteString, "https://img.example/topic.png")

    XCTAssertEqual(
      ranking.categories,
      [
        TiebaHotThreadCategory(serverID: 0, code: "changgeng", title: "视频"),
        TiebaHotThreadCategory(serverID: 37, code: "server-37", title: "未知分类"),
        TiebaHotThreadCategory(
          serverID: 8,
          code: "youxi",
          title: String(repeating: "e\u{301}", count: 40)
        ),
      ]
    )
    XCTAssertEqual(ranking.categories.map(\.id), ["changgeng", "server-37", "youxi"])

    XCTAssertEqual(ranking.items.map(\.id), [1_001, 1_002, 1_007])
    XCTAssertEqual(ranking.items.map(\.rank), [1, 2, 3])
    XCTAssertEqual(ranking.items.map(\.hotScore), [900, 0, 700])
    XCTAssertEqual(ranking.items.map(\.thread.forumID), [10, 20, 70])
    XCTAssertEqual(ranking.items.map(\.thread.forumName), ["Forum A", "Forum B", "Forum D"])
    XCTAssertEqual(ranking.items[1].thread.content.plainText, "Fallback content")
    XCTAssertEqual(ranking.items[1].thread.firstPostID, 11_002)
  }

  func testHotThreadRankingBoundsEachServerCollectionAfterFiltering() {
    var data = HotThreadListResIdl.DataRes()
    for index in 1...25 {
      var topic = RecommendTopicList()
      topic.topicID = UInt64(index)
      topic.topicName = "Topic \(index)"
      data.topicList.append(topic)

      var category = FrsTabInfo()
      category.tabID = Int32(index)
      category.tabName = "Category \(index)"
      category.tabCode = "category-\(index)"
      data.hotThreadTabInfo.append(category)
    }
    for index in 1...105 {
      var thread = ThreadInfo()
      thread.id = Int64(index)
      thread.threadID = Int64(index)
      thread.fid = Int64(index + 1_000)
      thread.fname = "Forum \(index)"
      data.threadInfo.append(thread)
    }

    let ranking = TiebaProtoMapper.hotThreadRanking(data)

    XCTAssertEqual(ranking.topics.count, 20)
    XCTAssertEqual(ranking.categories.count, 20)
    XCTAssertEqual(ranking.items.count, 100)
    XCTAssertEqual(ranking.topics.map(\.rank), Array(1...20))
    XCTAssertEqual(ranking.items.map(\.rank), Array(1...100))
    XCTAssertEqual(ranking.items.last?.id, 100)
  }

  func testModeratorRoleNormalizationIsBoundedAndRequiresModeratorFlag() {
    XCTAssertNil(TiebaProtoMapper.moderatorRole(isModerator: false, rawValue: "manager"))
    XCTAssertEqual(
      TiebaProtoMapper.moderatorRole(isModerator: true, rawValue: " Manager\n"),
      .manager
    )
    XCTAssertEqual(
      TiebaProtoMapper.moderatorRole(isModerator: true, rawValue: "assist"),
      .assistant
    )
    XCTAssertEqual(
      TiebaProtoMapper.moderatorRole(isModerator: true, rawValue: "ASSISTANT"),
      .assistant
    )
    XCTAssertEqual(
      TiebaProtoMapper.moderatorRole(isModerator: true, rawValue: ""),
      .moderator
    )
    XCTAssertEqual(
      TiebaProtoMapper.moderatorRole(
        isModerator: true,
        rawValue: String(repeating: "untrusted", count: 100)
      ),
      .moderator
    )
  }

  func testLegacyModeratorInitializerMaintainsRoleInvariant() {
    let legacyModerator = TiebaUser(
      id: 1,
      username: "moderator",
      displayName: "Moderator",
      portrait: "",
      level: 0,
      growthLevel: 0,
      gender: .unknown,
      ipLocation: "",
      badges: [],
      isModerator: true,
      isVIP: false,
      isVerifiedCreator: false
    )
    let ordinaryUser = TiebaUser(
      id: 2,
      username: "ordinary",
      displayName: "Ordinary",
      portrait: "",
      level: 0,
      growthLevel: 0,
      gender: .unknown,
      ipLocation: "",
      badges: [],
      isModerator: false,
      isVIP: false,
      isVerifiedCreator: false,
      moderatorRole: .manager
    )

    XCTAssertEqual(legacyModerator.moderatorRole, .moderator)
    XCTAssertTrue(legacyModerator.isModerator)
    XCTAssertNil(ordinaryUser.moderatorRole)
    XCTAssertFalse(ordinaryUser.isModerator)
  }

  func testUserProfileKeepsOnlyValidUniqueLikedForumPreviews() throws {
    var fixture = ProtoFixtures.userProfile().data
    fixture.user.myLikeNum = 1
    fixture.user.likeForum.append(
      User.LikeForumInfo.with {
        $0.forumID = 42
        $0.forumName = "duplicate"
      }
    )
    fixture.user.likeForum.append(
      User.LikeForumInfo.with {
        $0.forumID = 0
        $0.forumName = "invalid-id"
      }
    )
    fixture.user.likeForum.append(
      User.LikeForumInfo.with {
        $0.forumID = UInt64(Int64.max) + 1
        $0.forumName = "overflow"
      }
    )
    fixture.user.likeForum.append(
      User.LikeForumInfo.with {
        $0.forumID = 88
        $0.forumName = "   "
      }
    )

    let profile = try XCTUnwrap(TiebaProtoMapper.userProfile(fixture))

    XCTAssertEqual(profile.user.portrait, "profile-portrait")
    XCTAssertEqual(profile.portraitSource, "profile-portrait?t=1234567890")
    XCTAssertEqual(profile.followedForumCount, 1)
    XCTAssertEqual(
      profile.likedForums,
      [TiebaProfileForum(id: 42, name: "swift"), TiebaProfileForum(id: 77, name: "ios")]
    )
  }

  func testPostPagePrefersNewTotalPageAndMapsCursorPostIDs() {
    let fixture = ProtoFixtures.postPage().data

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(fixture.page.lzTotalFloor, 33)
    XCTAssertEqual(result.pagination.totalPages, 6)
    XCTAssertEqual(result.thread.pagePostIDs, [301, 302])
  }

  func testPostPageMapsIndependentFirstFloorSeparatelyFromReplies() throws {
    let result = TiebaProtoMapper.postPage(ProtoFixtures.postPage().data)

    let firstPost = try XCTUnwrap(result.firstPost)
    XCTAssertEqual(firstPost.id, 101)
    XCTAssertEqual(firstPost.threadID, result.thread.id)
    XCTAssertEqual(firstPost.floor, 1)
    XCTAssertEqual(firstPost.content.plainText, "First floor content")
    XCTAssertEqual(firstPost.author?.id, 7)
    XCTAssertTrue(firstPost.isThreadAuthor)
    XCTAssertEqual(result.posts.map(\.id), [201])
    XCTAssertFalse(result.posts.contains { $0.floor == 1 || $0.id == firstPost.id })
  }

  func testPostPagePrefersValidFirstFloorFromPostList() throws {
    var fixture = ProtoFixtures.postPage().data
    var listedFirstPost = fixture.firstFloorPost
    listedFirstPost.content = [PbContent.with {
      $0.type = 0
      $0.text = "Listed first floor"
    }]
    fixture.postList.insert(listedFirstPost, at: 0)

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(try XCTUnwrap(result.firstPost).content.plainText, "Listed first floor")
    XCTAssertEqual(result.posts.map(\.id), [201])
  }

  func testPostPageFallsBackFromInvalidListedFirstFloor() throws {
    var fixture = ProtoFixtures.postPage().data
    var wrongThreadFirstPost = fixture.firstFloorPost
    wrongThreadFirstPost.tid = fixture.thread.id + 1
    fixture.postList.insert(wrongThreadFirstPost, at: 0)

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(try XCTUnwrap(result.firstPost).content.plainText, "First floor content")
    XCTAssertEqual(result.posts.map(\.id), [201])
  }

  func testPostPageRejectsInvalidIndependentFirstFloor() {
    let base = ProtoFixtures.postPage().data
    var invalidID = base.firstFloorPost
    invalidID.id = 0
    var invalidFloor = base.firstFloorPost
    invalidFloor.floor = 2
    var invalidThread = base.firstFloorPost
    invalidThread.tid = base.thread.id + 1
    var mismatchedFirstPostID = base.firstFloorPost
    mismatchedFirstPostID.id = base.thread.firstPostID + 1
    var botPost = base.firstFloorPost
    botPost.chatContent.botUk = "bot-user"

    for (label, candidate) in [
      ("invalid ID", invalidID),
      ("invalid floor", invalidFloor),
      ("invalid thread", invalidThread),
      ("mismatched first-post ID", mismatchedFirstPostID),
      ("bot post", botPost),
    ] {
      var fixture = base
      fixture.firstFloorPost = candidate
      XCTAssertNil(TiebaProtoMapper.postPage(fixture).firstPost, label)
    }
  }

  func testPostPageAllowsMissingFirstFloorWireThreadID() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.firstFloorPost.tid = 0

    let firstPost = try XCTUnwrap(TiebaProtoMapper.postPage(fixture).firstPost)

    XCTAssertEqual(firstPost.id, fixture.thread.firstPostID)
    XCTAssertEqual(firstPost.threadID, fixture.thread.id)
  }

  func testPostPageDerivesFirstPostIDWithoutTreatingAnchorAsFirstPost() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.firstPostID = 0
    fixture.thread.postID = fixture.postList[0].id

    let result = TiebaProtoMapper.postPage(fixture)
    let firstPost = try XCTUnwrap(result.firstPost)

    XCTAssertNotEqual(fixture.thread.postID, firstPost.id)
    XCTAssertEqual(firstPost.id, fixture.firstFloorPost.id)
    XCTAssertEqual(result.thread.firstPostID, firstPost.id)
    XCTAssertEqual(result.posts.map(\.id), [fixture.thread.postID])
  }

  func testPostPageDoesNotPromoteAnchorWhenFirstFloorIsMissing() {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.firstPostID = 0
    fixture.thread.postID = fixture.postList[0].id
    fixture.firstFloorPost = Post()

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertNil(result.firstPost)
    XCTAssertEqual(result.thread.firstPostID, 0)
    XCTAssertEqual(result.posts.map(\.id), [fixture.thread.postID])
  }

  func testPostPagePeelsFirstFloorWithoutDeduplicatingOrdinaryReplies() throws {
    var fixture = ProtoFixtures.postPage().data
    let reply = try XCTUnwrap(fixture.postList.first)
    let listedFirstPost = fixture.firstFloorPost
    var selectedIDWithWrongFloor = listedFirstPost
    selectedIDWithWrongFloor.floor = 2
    var unrelatedFirstFloor = listedFirstPost
    unrelatedFirstFloor.id += 1
    fixture.postList = [
      listedFirstPost,
      reply,
      selectedIDWithWrongFloor,
      unrelatedFirstFloor,
      reply,
    ]

    let result = TiebaProtoMapper.postPage(fixture)
    let firstPost = try XCTUnwrap(result.firstPost)

    XCTAssertEqual(firstPost.id, listedFirstPost.id)
    XCTAssertEqual(result.posts.map(\.id), [reply.id, reply.id])
  }

  func testPostPageFallsBackToLegacyTotalPage() {
    var fixture = ProtoFixtures.postPage().data
    fixture.page.newTotalPage = 0

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(result.pagination.totalPages, 4)
  }

  func testPostAgreementScorePrefersDeclaredValueAndFallsBackToDifference() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.postList[0].agree.agreeNum = 5
    fixture.postList[0].agree.disagreeNum = 2
    fixture.postList[0].agree.diffAgreeNum = 9

    XCTAssertEqual(try XCTUnwrap(TiebaProtoMapper.postPage(fixture).posts.first).agreeScore, 9)

    fixture.postList[0].agree.diffAgreeNum = 0
    XCTAssertEqual(try XCTUnwrap(TiebaProtoMapper.postPage(fixture).posts.first).agreeScore, 3)
  }

  func testDirectLeadingReplyMentionKeepsContentAndMapsTarget() throws {
    var fixture = ProtoFixtures.postPage().data
    var mention = PbContent()
    mention.type = 4
    mention.text = "@direct-target"
    mention.uid = 77
    var body = PbContent()
    body.type = 0
    body.text = " hello"
    fixture.postList[0].subPostList.subPostList[0].content = [mention, body]

    let post = try XCTUnwrap(TiebaProtoMapper.postPage(fixture).posts.first)
    let comment = try XCTUnwrap(post.comments.first)

    XCTAssertEqual(comment.replyToUserID, 77)
    XCTAssertEqual(comment.replyToUserName, "direct-target")
    XCTAssertEqual(comment.content.plainText, "@direct-target hello")
    XCTAssertEqual(comment.content.fragments.count, 2)
  }

  func testPostPageMapsDistinctValidOriginOnlyForSharedThread() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.isShareThread = 1
    fixture.thread.originThreadInfo.tid = " 900 "
    fixture.thread.originThreadInfo.pid = 901
    fixture.thread.originThreadInfo.fid = 77
    fixture.thread.originThreadInfo.fname = " Original Forum "
    fixture.thread.originThreadInfo.title = " Original title "

    let result = TiebaProtoMapper.postPage(fixture)
    let origin = try XCTUnwrap(result.originThread)

    XCTAssertEqual(origin.id, 900)
    XCTAssertEqual(origin.firstPostID, 901)
    XCTAssertEqual(origin.forumID, 77)
    XCTAssertEqual(origin.forumName, "Original Forum")
    XCTAssertEqual(origin.title, "Original title")
    XCTAssertEqual(origin.content.plainText, "Opening post")
    XCTAssertEqual(origin.content.images.count, 1)
    XCTAssertEqual(
      origin.content.fragments.filter { fragment in
        if case .video = fragment { return true }
        return false
      }.count,
      1
    )
    XCTAssertEqual(
      origin.content.fragments.filter { fragment in
        if case .voice = fragment { return true }
        return false
      }.count,
      1
    )
  }

  func testPostPageRejectsInvalidOrSelfReferentialSharedOrigin() {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.isShareThread = 1
    fixture.thread.originThreadInfo.tid = "not-a-thread"
    XCTAssertNil(TiebaProtoMapper.postPage(fixture).originThread)

    fixture.thread.originThreadInfo.tid = String(fixture.thread.id)
    XCTAssertNil(TiebaProtoMapper.postPage(fixture).originThread)
  }

  func testPostPageMapsReadOnlyPollAndSanitizesCounts() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.originThreadInfo.pollInfo.title = " Favorite language? "
    fixture.thread.originThreadInfo.pollInfo.isMulti = 1
    fixture.thread.originThreadInfo.pollInfo.totalNum = -4
    fixture.thread.originThreadInfo.pollInfo.totalPoll = -8

    var firstOption = PollInfo.PollOption()
    firstOption.text = " Swift "
    firstOption.num = 12
    var secondOption = PollInfo.PollOption()
    secondOption.text = " Objective-C "
    secondOption.num = -3
    fixture.thread.originThreadInfo.pollInfo.options = [firstOption, secondOption]

    let poll = try XCTUnwrap(TiebaProtoMapper.postPage(fixture).poll)

    XCTAssertEqual(poll.title, "Favorite language?")
    XCTAssertTrue(poll.isMultipleChoice)
    XCTAssertEqual(poll.participantCount, 0)
    XCTAssertEqual(poll.totalVoteCount, 0)
    XCTAssertEqual(poll.options.map(\.text), ["Swift", "Objective-C"])
    XCTAssertEqual(poll.options.map(\.voteCount), [12, 0])
  }

  func testPostPageIgnoresPollMetadataWithoutOptions() {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.originThreadInfo.pollInfo.title = "Empty poll"
    fixture.thread.originThreadInfo.pollInfo.totalNum = 10

    XCTAssertNil(TiebaProtoMapper.postPage(fixture).poll)
  }

  func testPostPagePrefersDirectPollWhenBothCarriersArePopulated() throws {
    var fixture = ProtoFixtures.postPage().data
    var directOption = PollInfo.PollOption()
    directOption.text = "Direct option"
    directOption.num = 2
    fixture.thread.pollInfo.options = [directOption]
    fixture.thread.pollInfo.totalPoll = 2
    var mirroredOption = PollInfo.PollOption()
    mirroredOption.text = "Mirrored option"
    mirroredOption.num = 3
    fixture.thread.originThreadInfo.pollInfo.options = [mirroredOption]
    fixture.thread.originThreadInfo.pollInfo.totalPoll = 3

    let poll = try XCTUnwrap(TiebaProtoMapper.postPage(fixture).poll)

    XCTAssertEqual(poll.options.map(\.text), ["Direct option"])
  }

  func testPostPageKeepsSharedOriginPollOffOuterThread() throws {
    var fixture = ProtoFixtures.postPage().data
    fixture.thread.isShareThread = 1
    fixture.thread.originThreadInfo.tid = "900"
    var option = PollInfo.PollOption()
    option.text = "Origin option"
    option.num = 5
    fixture.thread.originThreadInfo.pollInfo.options = [option]
    fixture.thread.originThreadInfo.pollInfo.totalPoll = 5

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertNil(result.poll)
    let origin = try XCTUnwrap(result.originThread)
    let originPoll = try XCTUnwrap(origin.poll)
    XCTAssertEqual(originPoll.options.map(\.text), ["Origin option"])

    fixture.thread.isShareThread = 2
    let unknownFlagResult = TiebaProtoMapper.postPage(fixture)
    XCTAssertNil(unknownFlagResult.poll)
    XCTAssertNil(unknownFlagResult.originThread)
  }

  func testForumOverviewRequiresARepresentablePositiveForumID() {
    let mapped = TiebaProtoMapper.forumOverview(ProtoFixtures.forumOverview().data)
    XCTAssertEqual(mapped?.forum.id, 42)
    XCTAssertEqual(mapped?.forum.postCount, 3_000)
    XCTAssertEqual(mapped?.introduction, "A public forum introduction")

    var noRichIntroduction = ProtoFixtures.forumOverview().data
    noRichIntroduction.forumInfo.content = []
    XCTAssertEqual(TiebaProtoMapper.forumOverview(noRichIntroduction)?.introduction, "")

    var missingID = ProtoFixtures.forumOverview().data
    missingID.forumInfo.forumID = 0
    XCTAssertNil(TiebaProtoMapper.forumOverview(missingID))
  }

  func testForumModeratorMapperPreservesRoleGroupingAndDropsEmptyEntries() {
    var fixture = ProtoFixtures.forumModerators().data
    var emptyModerator =
      GetBawuInfoResIdl.DataRes.BawuTeam.BawuRoleDes.BawuRoleInfoPub()
    emptyModerator.userLevel = 99
    var role = fixture.bawuTeamInfo.bawuTeamList[0]
    role.roleInfo.append(emptyModerator)
    fixture.bawuTeamInfo.bawuTeamList = [role]

    let roles = TiebaProtoMapper.forumModeratorRoles(fixture)

    XCTAssertEqual(roles.count, 1)
    XCTAssertEqual(roles[0].name, "吧主")
    XCTAssertEqual(roles[0].moderators.map(\.id), [7])
  }

  func testForumRuleMapperUsesRequestedIDAsFallbackAndMapsRichContent() {
    var fixture = ProtoFixtures.forumRules().data
    fixture.forum.forumID = 0

    let rules = TiebaProtoMapper.forumRules(fixture, requestedForumID: 99)

    XCTAssertEqual(rules.forum.id, 99)
    XCTAssertEqual(rules.forum.memberCount, 1_000)
    XCTAssertEqual(rules.forum.postCount, 3_000)
    XCTAssertTrue(rules.forum.hasRules)
    XCTAssertEqual(rules.rules.map(\.status), [1])
    XCTAssertEqual(rules.rules[0].content.fragments.count, 2)
    XCTAssertEqual(rules.author?.portrait, "moderator-portrait")
  }
}
