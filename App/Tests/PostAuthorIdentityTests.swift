import XCTest

@testable import TiebaPlusPlus

final class PostAuthorIdentityTests: XCTestCase {
  @MainActor
  func testBadgesUseStableLevelRoleAndThreadAuthorOrder() {
    XCTAssertEqual(
      PostAuthorNameLine.badges(
        level: 18,
        moderatorRole: .assistant,
        isThreadAuthor: true
      ),
      [.level(18), .moderator(.assistant), .threadAuthor]
    )
  }

  @MainActor
  func testBadgeTitlesUseOnlyBoundedRoleLabels() {
    XCTAssertEqual(PostAuthorBadge.moderator(.manager).title, "吧主")
    XCTAssertEqual(PostAuthorBadge.moderator(.assistant).title, "小吧主")
    XCTAssertEqual(PostAuthorBadge.moderator(.moderator).title, "吧务")
    XCTAssertEqual(
      PostAuthorBadge.moderator(.manager).accessibilityLabel,
      "本吧身份：吧主"
    )
    XCTAssertEqual(PostAuthorBadge.threadAuthor.accessibilityLabel, "本帖楼主")
  }

  @MainActor
  func testMissingMetadataDoesNotCreateBadges() {
    XCTAssertTrue(
      PostAuthorNameLine.badges(
        level: 0,
        moderatorRole: nil,
        isThreadAuthor: false
      ).isEmpty
    )
    XCTAssertEqual(
      PostAuthorNameLine.badges(
        level: -1,
        moderatorRole: .moderator,
        isThreadAuthor: false
      ),
      [.moderator(.moderator)]
    )
  }
}
