import XCTest

@testable import TiebaPlusPlus

final class FanReminderPresentationTests: XCTestCase {
  func testZeroReminderHidesBadgeAndDescribesEmptyState() {
    let presentation = FanReminderPresentation(count: 0)

    XCTAssertEqual(presentation.count, 0)
    XCTAssertFalse(presentation.isUnavailable)
    XCTAssertNil(presentation.badgeText)
    XCTAssertEqual(presentation.accessibilityValue, "没有粉丝提醒")
  }

  func testReminderUsesVisualCapWithoutLosingAccessibleExactCount() {
    let presentation = FanReminderPresentation(count: 125)

    XCTAssertEqual(presentation.count, 125)
    XCTAssertEqual(presentation.badgeText, "99+")
    XCTAssertEqual(presentation.accessibilityValue, "125 条粉丝提醒")
  }

  func testReminderCapsOnlyAboveNinetyNine() {
    XCTAssertEqual(FanReminderPresentation(count: 99).badgeText, "99")
    XCTAssertEqual(FanReminderPresentation(count: 100).badgeText, "99+")
  }

  func testReminderAcceptsOnlyTheDisplayedAccountSummary() {
    let summary = InboxUnreadSummary(
      userID: 42,
      replyCount: 3,
      mentionCount: 4,
      fanCount: 12
    )

    let presentation = FanReminderPresentation(summary: summary, activeUserID: 42)
    XCTAssertEqual(presentation?.badgeText, "12")
    XCTAssertEqual(presentation?.accessibilityValue, "12 条粉丝提醒")
    XCTAssertNil(FanReminderPresentation(summary: summary, activeUserID: 43))
  }

  func testMissingReminderCountStaysUnavailable() {
    let summary = InboxUnreadSummary(
      userID: 42,
      replyCount: 3,
      mentionCount: 4,
      fanCount: nil
    )

    let presentation = FanReminderPresentation(summary: summary)
    let boundPresentation = FanReminderPresentation(summary: summary, activeUserID: 42)

    XCTAssertTrue(presentation.isUnavailable)
    XCTAssertNil(presentation.badgeText)
    XCTAssertEqual(presentation.accessibilityValue, "服务端未提供粉丝提醒计数")
    XCTAssertEqual(boundPresentation, presentation)
  }

  func testReminderClampsInvalidNegativeCount() {
    XCTAssertEqual(
      FanReminderPresentation(count: -1),
      FanReminderPresentation(count: 0)
    )
  }

  func testAccessibleValueReportsRefreshFailureAlongsideLastKnownCount() {
    let presentation = FanReminderPresentation(count: 5)

    XCTAssertEqual(
      presentation.accessibilityValue(refreshFailed: true),
      "5 条粉丝提醒，当前更新失败"
    )
  }
}
