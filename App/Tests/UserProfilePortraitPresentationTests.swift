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

final class UserLikedForumsPreviewPresentationTests: XCTestCase {
  func testFullListEntryDoesNotDependOnPublicCountOrPreview() {
    let presentation = UserLikedForumsPreviewPresentation(
      reportedCount: 0,
      previewCount: 0,
      offersFullList: true
    )

    XCTAssertTrue(presentation.showsSection)
    XCTAssertEqual(presentation.title, "喜欢的吧")
    XCTAssertFalse(presentation.footer.contains("共喜欢 0"))
    XCTAssertTrue(presentation.footer.contains("公开资料未提供"))
  }

  func testEmptyPublicDataWithoutFullListCapabilityKeepsSectionHidden() {
    let presentation = UserLikedForumsPreviewPresentation(
      reportedCount: 0,
      previewCount: 0,
      offersFullList: false
    )

    XCTAssertFalse(presentation.showsSection)
  }

  func testPublicCountAndPreviewRemainClearlyDescribedAsPreview() {
    let presentation = UserLikedForumsPreviewPresentation(
      reportedCount: 12,
      previewCount: 3,
      offersFullList: true
    )

    XCTAssertTrue(presentation.showsSection)
    XCTAssertEqual(presentation.totalCount, 12)
    XCTAssertEqual(presentation.title, "喜欢的吧 12")
    XCTAssertEqual(
      presentation.footer,
      "公开资料提供了 3 个预览；资料计数为 12 个吧。"
    )
  }

  func testPreviewCountRaisesStaleReportedCountWithoutClaimingCompleteness() {
    let presentation = UserLikedForumsPreviewPresentation(
      reportedCount: 1,
      previewCount: 2,
      offersFullList: false
    )

    XCTAssertEqual(presentation.totalCount, 2)
    XCTAssertEqual(presentation.title, "喜欢的吧")
    XCTAssertEqual(
      presentation.footer,
      "公开资料提供了 2 个预览，但未提供可靠的完整数量。"
    )
  }
}
