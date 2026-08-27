import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class ThreadToolbarLayoutPolicyTests: XCTestCase {
  func testCompactWidthAlwaysUsesCompactToolbar() {
    for size: DynamicTypeSize in [.xSmall, .large, .accessibility5] {
      XCTAssertEqual(
        ThreadToolbarLayoutPolicy.mode(
          horizontalSizeClass: .compact,
          dynamicTypeSize: size
        ),
        .compact
      )
    }
  }

  func testUnspecifiedWidthFailsClosedToCompactToolbar() {
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.mode(
        horizontalSizeClass: nil,
        dynamicTypeSize: .large
      ),
      .compact
    )
  }

  func testRegularWidthExpandsOnlyAtStandardTextSizes() {
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.mode(
        horizontalSizeClass: .regular,
        dynamicTypeSize: .large
      ),
      .expanded
    )
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.mode(
        horizontalSizeClass: .regular,
        dynamicTypeSize: .xLarge
      ),
      .expanded
    )
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.mode(
        horizontalSizeClass: .regular,
        dynamicTypeSize: .xxLarge
      ),
      .compact
    )
  }

  func testPrimaryActionsKeepCompactToolbarToShareAndMore() {
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.primaryActions(for: .compact),
      [.share, .more]
    )
    XCTAssertEqual(
      ThreadToolbarLayoutPolicy.primaryActions(for: .expanded),
      [.readingMode, .share, .localFavorite, .cloudFavorite, .more]
    )
  }
}
