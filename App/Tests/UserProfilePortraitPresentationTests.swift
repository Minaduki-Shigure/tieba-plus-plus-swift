import Foundation
import XCTest

@testable import TiebaPlusPlus

final class UserProfilePortraitPresentationTests: XCTestCase {
  func testPresentationPrefersLargePortraitAndUsesURLAsIdentity() throws {
    let largeURL = try url("https://example.com/large.jpg")
    let fallbackURL = try url("https://example.com/fallback.jpg")
    let presentation = try XCTUnwrap(
      UserProfilePortraitPresentation(
        largePortraitURL: largeURL,
        fallbackPortraitURL: fallbackURL
      )
    )

    XCTAssertEqual(presentation.sourceURL, largeURL)
    XCTAssertEqual(presentation.id, largeURL)
  }

  func testPresentationFallsBackToRegularPortrait() throws {
    let fallbackURL = try url("https://example.com/fallback.jpg")
    let presentation = try XCTUnwrap(
      UserProfilePortraitPresentation(
        largePortraitURL: nil,
        fallbackPortraitURL: fallbackURL
      )
    )

    XCTAssertEqual(presentation.sourceURL, fallbackURL)
  }

  func testPresentationRequiresAtLeastOnePortraitURL() {
    XCTAssertNil(
      UserProfilePortraitPresentation(
        largePortraitURL: nil,
        fallbackPortraitURL: nil
      )
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }
}
