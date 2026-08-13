import Foundation
import XCTest

@testable import TiebaPlusPlus

final class FollowedForumCardPresentationTests: XCTestCase {
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
}
