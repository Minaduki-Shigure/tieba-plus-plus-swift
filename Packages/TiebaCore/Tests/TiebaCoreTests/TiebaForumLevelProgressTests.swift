import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

final class TiebaForumLevelProgressTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let forumName = "swift"
  private let tbs = "91be894d01799c4991be894d01"

  func testValueNormalizesNameAndPreservesProgressBeyondTarget() throws {
    let progress = try XCTUnwrap(
      TiebaForumLevelProgress(
        level: 12,
        levelName: "  Cafe\u{301}  ",
        currentExperience: 501,
        targetExperience: 500
      )
    )

    XCTAssertEqual(progress.level, 12)
    XCTAssertEqual(progress.levelName, "Caf\u{e9}")
    XCTAssertEqual(progress.currentExperience, 501)
    XCTAssertEqual(progress.targetExperience, 500)
  }

  func testValueAcceptsBothPublishedNameBoundaries() {
    XCTAssertNotNil(
      TiebaForumLevelProgress(
        level: 1,
        levelName: String(repeating: "\u{1f600}", count: 64),
        currentExperience: 0,
        targetExperience: 1
      )
    )
  }

  func testValueEnforcesUTF8ByteBoundaryIndependentlyOfCharacterCount() {
    let multiScalarCharacter = "a\u{301}\u{327}\u{323}"
    let oversizedName = String(repeating: multiScalarCharacter, count: 64)
    XCTAssertEqual(oversizedName.precomposedStringWithCanonicalMapping.count, 64)
    XCTAssertGreaterThan(
      oversizedName.precomposedStringWithCanonicalMapping.utf8.count,
      TiebaForumLevelProgress.levelNameMaximumUTF8Bytes
    )
    XCTAssertNil(levelProgress(levelName: oversizedName))
  }

  func testValueRejectsEveryInvalidInvariant() {
    XCTAssertNil(levelProgress(level: 0))
    XCTAssertNil(levelProgress(level: -1))
    XCTAssertNil(levelProgress(levelName: " \n "))
    XCTAssertNil(levelProgress(levelName: "unsafe\u{0007}name"))
    XCTAssertNil(levelProgress(levelName: String(repeating: "a", count: 65)))
    XCTAssertNil(levelProgress(levelName: String(repeating: "\u{1f600}", count: 64) + "a"))
    XCTAssertNil(levelProgress(currentExperience: -1))
    XCTAssertNil(levelProgress(targetExperience: 0))
    XCTAssertNil(levelProgress(targetExperience: -1))
  }

  func testFollowedForumPublishesCompleteNumericAndStringProgress() throws {
    let numeric = try followedForum(
      level: 12,
      levelName: "  \u{6d77}\u{7eb3}\u{767e}\u{5ddd}  ",
      currentExperience: 501,
      targetExperience: 500
    )
    let strings = try followedForum(
      level: "8",
      levelName: "\u{5c0f}\u{5427}\u{4e3b}",
      currentExperience: "123",
      targetExperience: "456"
    )

    XCTAssertEqual(
      numeric.levelProgress,
      levelProgress(
        level: 12,
        levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
        currentExperience: 501,
        targetExperience: 500
      )
    )
    XCTAssertEqual(
      strings.levelProgress,
      levelProgress(
        level: 8,
        levelName: "\u{5c0f}\u{5427}\u{4e3b}",
        currentExperience: 123,
        targetExperience: 456
      )
    )
  }

  func testFollowedForumDropsIncompleteProgressWithoutDroppingLegacyFields() throws {
    let rows = try [
      followedForum(level: nil),
      followedForum(levelName: nil),
      followedForum(currentExperience: nil),
      followedForum(targetExperience: nil),
    ]

    for forum in rows {
      XCTAssertNil(forum.levelProgress)
      XCTAssertEqual(forum.id, forumID)
      XCTAssertEqual(forum.name, forumName)
    }
  }

  func testFollowedForumDropsInvalidProgressWithoutFailingThePage() throws {
    let rows = try [
      followedForum(level: -1),
      followedForum(levelName: "   "),
      followedForum(levelName: "unsafe\u{0007}name"),
      followedForum(levelName: String(repeating: "a", count: 65)),
      followedForum(currentExperience: -1),
      followedForum(targetExperience: 0),
      followedForum(targetExperience: -1),
    ]

    for forum in rows {
      XCTAssertNil(forum.levelProgress)
      XCTAssertEqual(forum.id, forumID)
      XCTAssertEqual(forum.name, forumName)
    }
  }

  func testForumAccountStatePublishesCompleteFollowedProgress() throws {
    let response = accountStateResponse(
      isFollowed: true,
      level: 12,
      levelName: "  \u{6d77}\u{7eb3}\u{767e}\u{5ddd}  ",
      currentExperience: 501,
      targetExperience: 500
    )
    let context = try TiebaAuthenticatedDecoder.forumAccountState(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertEqual(
      context.state.levelProgress,
      levelProgress(
        level: 12,
        levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
        currentExperience: 501,
        targetExperience: 500
      )
    )
    XCTAssertTrue(context.state.membership.isFollowed)
    XCTAssertEqual(
      context.state.checkIn,
      TiebaForumCheckIn(isCheckedIn: false, consecutiveDays: 6, rank: 43)
    )
  }

  func testForumAccountStateDropsMissingOrInvalidProgressWithoutBreakingOtherState() throws {
    let responses = [
      accountStateResponse(isFollowed: true),
      accountStateResponse(isFollowed: true, level: -1),
      accountStateResponse(isFollowed: true, levelName: "   "),
      accountStateResponse(isFollowed: true, levelName: "unsafe\u{0007}name"),
      accountStateResponse(
        isFollowed: true,
        levelName: String(repeating: "a", count: 65)
      ),
      accountStateResponse(isFollowed: true, currentExperience: -1),
      accountStateResponse(isFollowed: true, targetExperience: 0),
      accountStateResponse(isFollowed: true, targetExperience: -1),
    ]

    for response in responses {
      let context = try TiebaAuthenticatedDecoder.forumAccountState(
        from: response,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
      XCTAssertNil(context.state.levelProgress)
      XCTAssertTrue(context.state.membership.isFollowed)
      XCTAssertEqual(
        context.state.checkIn,
        TiebaForumCheckIn(isCheckedIn: false, consecutiveDays: 6, rank: 43)
      )
    }
  }

  func testForumAccountStateNeverPublishesProgressForUnfollowedForum() throws {
    let response = accountStateResponse(
      isFollowed: false,
      level: 12,
      levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
      currentExperience: 345,
      targetExperience: 500
    )
    let context = try TiebaAuthenticatedDecoder.forumAccountState(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertFalse(context.state.membership.isFollowed)
    XCTAssertNil(context.state.levelProgress)
    XCTAssertNotNil(context.state.checkIn)
  }

  func testLegacyMembershipIgnoresEvenValidLevelProgress() throws {
    let response = accountStateResponse(
      isFollowed: true,
      level: 12,
      levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
      currentExperience: 345,
      targetExperience: 500
    )
    let context = try TiebaAuthenticatedDecoder.forumMembership(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertTrue(context.state.membership.isFollowed)
    XCTAssertNil(context.state.checkIn)
    XCTAssertNil(context.state.levelProgress)
  }

  func testExistingModelInitializersRemainSourceCompatibleAndDefaultToNoProgress() {
    let membership = TiebaForumMembership(
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      isFollowed: true
    )
    let forum = TiebaFollowedForum(
      id: forumID,
      name: forumName,
      level: 12,
      experience: 345
    )
    let state = TiebaForumAccountState(membership: membership, checkIn: nil)

    XCTAssertNil(forum.levelProgress)
    XCTAssertNil(state.levelProgress)
  }

  private func levelProgress(
    level: Int = 12,
    levelName: String = "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
    currentExperience: Int = 345,
    targetExperience: Int = 500
  ) -> TiebaForumLevelProgress? {
    TiebaForumLevelProgress(
      level: level,
      levelName: levelName,
      currentExperience: currentExperience,
      targetExperience: targetExperience
    )
  }

  private func followedForum(
    level: Any? = "12",
    levelName: Any? = "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
    currentExperience: Any? = "345",
    targetExperience: Any? = "500"
  ) throws -> TiebaFollowedForum {
    var forum: [String: Any] = [
      "id": String(forumID),
      "name": forumName,
    ]
    forum["level_id"] = level
    forum["level_name"] = levelName
    forum["cur_score"] = currentExperience
    forum["levelup_score"] = targetExperience
    let body = try JSONSerialization.data(
      withJSONObject: [
        "error_code": 0,
        "has_more": 0,
        "forum_list": ["non-gconforum": [forum]],
      ]
    )
    let page = try TiebaAuthenticatedDecoder.followedForums(
      from: body,
      page: 1,
      pageSize: 50,
      accountUserID: userID,
      targetUserID: userID
    )
    return try XCTUnwrap(page.forums.first)
  }

  private func accountStateResponse(
    isFollowed: Bool,
    level: Int32 = 0,
    levelName: String = "",
    currentExperience: Int32 = 0,
    targetExperience: Int32 = 0
  ) -> FrsPageResIdl {
    var user = User()
    user.id = userID

    var signUser = FrsPageResIdl.DataRes.ForumInfo.SignInfo.SignUser()
    signUser.userID = userID
    signUser.isSignIn = 0
    signUser.contSignNum = 6
    signUser.userSignRank = 43
    var signInfo = FrsPageResIdl.DataRes.ForumInfo.SignInfo()
    signInfo.userInfo = signUser

    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID
    forum.name = forumName
    forum.isLike = isFollowed ? 1 : 0
    forum.userLevel = level
    forum.levelName = levelName
    forum.curScore = currentExperience
    forum.levelupScore = targetExperience
    forum.signInInfo = signInfo

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
}
