import CoreGraphics
import XCTest

@testable import TiebaPlusPlus

final class ThreadScrollPositionTests: XCTestCase {
  func testVisibilityRequiresPositiveIntersectionWithViewport() {
    XCTAssertEqual(
      position(frame: CGRect(x: 0, y: -20, width: 100, height: 40)),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: 41)
    )
    XCTAssertEqual(
      position(frame: CGRect(x: 0, y: 599, width: 100, height: 40)),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: 41)
    )

    let excludedFrames = [
      CGRect(x: 0, y: -40, width: 100, height: 40),
      CGRect(x: 0, y: 600, width: 100, height: 40),
      CGRect(x: 0, y: 100, width: 100, height: 0),
    ]
    for frame in excludedFrames {
      XCTAssertEqual(position(frame: frame), .empty)
    }
  }

  func testVisibilityKeepsProgressAndPrependEligibilityIndependent() {
    XCTAssertEqual(
      position(tracksReadingProgress: true, tracksPrependAnchor: false),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: nil)
    )
    XCTAssertEqual(
      position(tracksReadingProgress: false, tracksPrependAnchor: true),
      ThreadScrollPosition(readingProgressPostID: nil, prependAnchorPostID: 41)
    )
    XCTAssertEqual(
      position(tracksReadingProgress: false, tracksPrependAnchor: false),
      .empty
    )
  }

  func testPixelMovementWithinViewportKeepsStablePreferenceValue() {
    let initial = position(frame: CGRect(x: 0, y: 100, width: 100, height: 40))

    for y in stride(from: CGFloat(-39), through: 599, by: 17) {
      XCTAssertEqual(
        position(frame: CGRect(x: 0, y: y, width: 100, height: 40)),
        initial
      )
    }
  }

  func testPreferenceReductionUsesLastVisibleProgressPostAndFirstReplyAnchor() {
    var reduced = ThreadScrollPositionPreferenceKey.defaultValue
    let values = [
      ThreadScrollPosition(readingProgressPostID: 1, prependAnchorPostID: nil),
      ThreadScrollPosition(readingProgressPostID: 2, prependAnchorPostID: 2),
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 3),
    ]

    for value in values {
      ThreadScrollPositionPreferenceKey.reduce(value: &reduced) { value }
    }

    XCTAssertEqual(
      reduced,
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 2)
    )
  }

  func testVisibilityRejectsInvalidIdentityAndViewport() {
    XCTAssertEqual(position(postID: 0), .empty)
    XCTAssertEqual(position(viewportHeight: 0), .empty)
    XCTAssertEqual(position(viewportHeight: .infinity), .empty)
  }

  private func position(
    postID: Int64 = 41,
    frame: CGRect = CGRect(x: 0, y: 100, width: 100, height: 40),
    viewportHeight: CGFloat = 600,
    tracksReadingProgress: Bool = true,
    tracksPrependAnchor: Bool = true
  ) -> ThreadScrollPosition {
    ThreadPostVisibilityPolicy.position(
      postID: postID,
      frame: frame,
      viewportHeight: viewportHeight,
      tracksReadingProgress: tracksReadingProgress,
      tracksPrependAnchor: tracksPrependAnchor
    )
  }
}
