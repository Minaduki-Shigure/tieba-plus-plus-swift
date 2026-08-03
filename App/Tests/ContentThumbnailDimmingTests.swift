import XCTest

@testable import TiebaPlusPlus

final class ContentThumbnailDimmingTests: XCTestCase {
  func testOnlyEnabledDarkModeUsesUpstreamBrightnessMultiplier() {
    XCTAssertEqual(ContentThumbnailDimmingDecision.darkModeMultiplier, 0.4)
    XCTAssertEqual(
      ContentThumbnailDimmingDecision.multiplier(isDarkMode: true, isEnabled: true),
      0.4
    )
  }

  func testLightModeAndDisabledDarkModeRemainUnmodified() {
    XCTAssertEqual(
      ContentThumbnailDimmingDecision.multiplier(isDarkMode: false, isEnabled: true),
      1
    )
    XCTAssertEqual(
      ContentThumbnailDimmingDecision.multiplier(isDarkMode: true, isEnabled: false),
      1
    )
    XCTAssertEqual(
      ContentThumbnailDimmingDecision.multiplier(isDarkMode: false, isEnabled: false),
      1
    )
  }
}
