import Foundation
import XCTest

@testable import TiebaPlusPlus

final class FollowedForumCardPresentationTests: XCTestCase {
  func testLevelProgressNormalizesNameAndClampsOverTargetExperience() throws {
    let progress = try XCTUnwrap(
      ForumLevelProgressData(
        level: 12,
        levelName: " Cafe\u{301} ",
        currentExperience: 650,
        targetExperience: 500
      )
    )

    XCTAssertEqual(progress.levelName, "Caf\u{00E9}")
    XCTAssertEqual(progress.fractionCompleted, 1)

    let presentation = ForumLevelProgressPresentation(progress: progress)
    XCTAssertEqual(presentation.levelTitle, "LV12 · Caf\u{00E9}")
    XCTAssertEqual(presentation.experienceText, "经验 650 / 500")
    XCTAssertEqual(presentation.fractionCompleted, 1)
    XCTAssertEqual(
      presentation.accessibilityValue,
      "等级 12，Caf\u{00E9}，当前经验 650，升级经验 500，完成 100%"
    )
  }

  func testLevelProgressRejectsInvalidValues() {
    XCTAssertNotNil(
      ForumLevelProgressData(
        level: 1,
        levelName: "Member",
        currentExperience: 0,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 0,
        levelName: "Member",
        currentExperience: 1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: " \n ",
        currentExperience: 1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: "Member\u{0000}",
        currentExperience: 1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: String(repeating: "a", count: 65),
        currentExperience: 1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: String(
          repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
          count: 12
        ),
        currentExperience: 1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: "Member",
        currentExperience: -1,
        targetExperience: 2
      )
    )
    XCTAssertNil(
      ForumLevelProgressData(
        level: 1,
        levelName: "Member",
        currentExperience: 1,
        targetExperience: 0
      )
    )
  }

  func testUsesAuthoritativeLevelProgressInsteadOfLegacyFallback() throws {
    let progress = try XCTUnwrap(
      ForumLevelProgressData(
        level: 12,
        levelName: "Member",
        currentExperience: 345,
        targetExperience: 500
      )
    )
    let presentation = FollowedForumCardPresentation(
      forum: FollowedForumItem(
        id: 42,
        name: "swift",
        level: 11,
        experience: 999,
        slogan: "Swift community",
        levelProgress: progress
      )
    )

    XCTAssertTrue(presentation.progressText.isEmpty)
    let levelProgress = try XCTUnwrap(presentation.levelProgress)
    XCTAssertEqual(levelProgress.levelTitle, "LV12 · Member")
    XCTAssertEqual(levelProgress.experienceText, "经验 345 / 500")
    XCTAssertEqual(levelProgress.fractionCompleted, 0.69, accuracy: 0.001)
    XCTAssertEqual(
      presentation.accessibilityValue,
      "Swift community，等级 12，Member，当前经验 345，升级经验 500，完成 69%"
    )
  }

  func testUsesAllowedAvatarAndCombinesSloganWithProgress() throws {
    let avatarURL = try XCTUnwrap(
      URL(string: "https://imgsrc.baidu.com/forum/swift.png")
    )
    let presentation = FollowedForumCardPresentation(
      forum: FollowedForumItem(
        id: 42,
        name: "swift",
        level: 12,
        experience: 345,
        avatarURL: avatarURL,
        slogan: " Swift community "
      )
    )

    XCTAssertEqual(presentation.avatarURL, avatarURL)
    XCTAssertEqual(presentation.slogan, "Swift community")
    XCTAssertEqual(presentation.progressText, "等级 12，经验 345")
    XCTAssertEqual(presentation.accessibilityValue, "Swift community，等级 12，经验 345")
  }

  func testFallsBackToProgressWhenSloganIsEmpty() {
    let presentation = FollowedForumCardPresentation(
      forum: FollowedForumItem(
        id: 43,
        name: "ios",
        level: 8,
        experience: 123,
        slogan: "  \n "
      )
    )

    XCTAssertNil(presentation.avatarURL)
    XCTAssertTrue(presentation.slogan.isEmpty)
    XCTAssertEqual(presentation.progressText, "等级 8，经验 123")
    XCTAssertEqual(presentation.accessibilityValue, "等级 8，经验 123")
  }

  func testRejectsUnrelatedAvatarWithoutDroppingSlogan() throws {
    let presentation = FollowedForumCardPresentation(
      forum: FollowedForumItem(
        id: 44,
        name: "security",
        level: 0,
        experience: 0,
        avatarURL: try XCTUnwrap(URL(string: "https://example.com/avatar.png")),
        slogan: "Safe fallback"
      )
    )

    XCTAssertNil(presentation.avatarURL)
    XCTAssertEqual(presentation.slogan, "Safe fallback")
    XCTAssertTrue(presentation.progressText.isEmpty)
    XCTAssertEqual(presentation.accessibilityValue, "Safe fallback")
  }

  func testCheckedInMarkIsAnIndependentAccountScopedPresentationValue() {
    let forum = FollowedForumItem(
      id: 45,
      name: "swift",
      level: 8,
      experience: 123,
      slogan: "Swift community"
    )

    let ordinary = FollowedForumCardPresentation(forum: forum)
    let checkedIn = FollowedForumCardPresentation(
      forum: forum,
      isCheckedInToday: true
    )

    XCTAssertFalse(ordinary.isCheckedInToday)
    XCTAssertEqual(ordinary.accessibilityValue, "Swift community，等级 8，经验 123")
    XCTAssertTrue(checkedIn.isCheckedInToday)
    XCTAssertEqual(
      checkedIn.accessibilityValue,
      "Swift community，等级 8，经验 123，今日已签到"
    )
  }

  func testCheckedInMarkRemainsAvailableWithoutLevelMetadata() {
    let presentation = FollowedForumCardPresentation(
      forum: FollowedForumItem(
        id: 46,
        name: "empty",
        level: 0,
        experience: 0
      ),
      isCheckedInToday: true
    )

    XCTAssertTrue(presentation.progressText.isEmpty)
    XCTAssertEqual(presentation.accessibilityValue, "今日已签到")
  }
}
