import XCTest

@testable import TiebaPlusPlus

final class InboxUnreadBadgePresentationTests: XCTestCase {
  func testZeroUnreadCountHidesBadgeAndDescribesEmptyState() {
    let presentation = InboxUnreadBadgePresentation(replyCount: 0, mentionCount: 0)

    XCTAssertEqual(presentation.count, 0)
    XCTAssertNil(presentation.badgeText)
    XCTAssertEqual(presentation.accessibilityValue, "没有未读回复或提及")
  }

  func testBadgeCombinesOnlyReplyAndMentionCounts() {
    let presentation = InboxUnreadBadgePresentation(
      summary: InboxUnreadSummary(
        userID: 42,
        replyCount: 12,
        mentionCount: 7,
        fanCount: 9_999
      )
    )

    XCTAssertEqual(presentation.count, 19)
    XCTAssertEqual(presentation.badgeText, "19")
    XCTAssertEqual(presentation.accessibilityValue, "19 条未读回复或提及")
  }

  func testBadgeRejectsSummaryFromAUserOtherThanTheDisplayedAccount() {
    let summary = InboxUnreadSummary(
      userID: 42,
      replyCount: 12,
      mentionCount: 7,
      fanCount: 0
    )

    XCTAssertNotNil(InboxUnreadBadgePresentation(summary: summary, activeUserID: 42))
    XCTAssertNil(InboxUnreadBadgePresentation(summary: summary, activeUserID: 43))
  }

  func testBadgeUsesNinetyNinePlusWithoutLosingAccessibleExactCount() {
    let presentation = InboxUnreadBadgePresentation(replyCount: 80, mentionCount: 45)

    XCTAssertEqual(presentation.count, 125)
    XCTAssertEqual(presentation.badgeText, "99+")
    XCTAssertEqual(presentation.accessibilityValue, "125 条未读回复或提及")
  }

  func testBadgeClampsInvalidNegativeCountsAndSaturatesOverflow() {
    XCTAssertEqual(
      InboxUnreadBadgePresentation(replyCount: -4, mentionCount: 3),
      InboxUnreadBadgePresentation(replyCount: 0, mentionCount: 3)
    )

    let overflow = InboxUnreadBadgePresentation(replyCount: Int.max, mentionCount: 1)
    XCTAssertEqual(overflow.count, Int.max)
    XCTAssertEqual(overflow.badgeText, "99+")
  }

  func testAccessibleValueReportsARefreshFailureAlongsideTheLastKnownCount() {
    let empty = InboxUnreadBadgePresentation(replyCount: 0, mentionCount: 0)
    let nonempty = InboxUnreadBadgePresentation(replyCount: 2, mentionCount: 3)

    XCTAssertEqual(
      empty.accessibilityValue(refreshFailed: true),
      "没有未读回复或提及，当前更新失败"
    )
    XCTAssertEqual(
      nonempty.accessibilityValue(refreshFailed: true),
      "5 条未读回复或提及，当前更新失败"
    )
  }
}
