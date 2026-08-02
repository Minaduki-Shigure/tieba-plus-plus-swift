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
