import XCTest

@testable import TiebaPlusPlus

final class CompactListMediaViewTests: XCTestCase {
  func testVideoSummaryUsesCompactNonActionWording() {
    let summary = ThreadListMediaSummary.video

    XCTAssertEqual(summary.title, "视频")
    XCTAssertEqual(summary.accessibilityLabel, "包含视频，预览已收起")
  }

  func testImageSummaryReportsTheFullNonnegativeCount() {
    XCTAssertEqual(ThreadListMediaSummary.images(count: 4).title, "4 张图片")
    XCTAssertEqual(
      ThreadListMediaSummary.images(count: 4).accessibilityLabel,
      "包含 4 张图片，预览已收起"
    )
    XCTAssertEqual(ThreadListMediaSummary.images(count: -1).title, "0 张图片")
  }
}
