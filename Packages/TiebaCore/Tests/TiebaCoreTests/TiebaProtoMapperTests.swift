import TiebaProto
import XCTest

@testable import TiebaCore

final class TiebaProtoMapperTests: XCTestCase {
  func testPostPagePrefersNewTotalPageAndMapsCursorPostIDs() {
    let fixture = ProtoFixtures.postPage().data

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(fixture.page.lzTotalFloor, 33)
    XCTAssertEqual(result.pagination.totalPages, 6)
    XCTAssertEqual(result.thread.pagePostIDs, [301, 302])
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
