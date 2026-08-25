import XCTest

@testable import TiebaPlusPlus

final class AppSettingsHierarchyTests: XCTestCase {
  func testRootCategoriesKeepStableOrderAndTitles() {
    XCTAssertEqual(
      AppSettingsCategory.allCases,
      [
        .appearanceAndLayout,
        .readingAndContent,
        .homeAndRecommendations,
        .favoritesAndHistory,
        .checkInAndPosting,
        .storageAndPrivacy,
      ]
    )
    XCTAssertEqual(
      AppSettingsCategory.allCases.map(\.title),
      [
        "外观与布局",
        "阅读与内容",
        "首页与推荐",
        "收藏与历史",
        "签到与发布",
        "存储与隐私",
      ]
    )
  }

  func testRootCategoriesExposeUniqueStableAccessibilityIdentifiers() {
    let identifiers = AppSettingsCategory.allCases.map(\.accessibilityIdentifier)

    XCTAssertEqual(
      identifiers,
      [
        "settings-category-appearance-and-layout",
        "settings-category-reading-and-content",
        "settings-category-home-and-recommendations",
        "settings-category-favorites-and-history",
        "settings-category-check-in-and-posting",
        "settings-category-storage-and-privacy",
      ]
    )
    XCTAssertEqual(Set(identifiers).count, identifiers.count)
  }
}
