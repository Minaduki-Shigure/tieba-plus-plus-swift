import Foundation
import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class AppPreferencesTests: XCTestCase {
  func testHomeCustomizationUsesStableKeysAndDefaults() {
    XCTAssertEqual(
      AppPreferenceKey.homeStartDestination,
      "TiebaPlusPlus.homeStartDestination"
    )
    XCTAssertEqual(
      AppPreferenceKey.homeShowsDiscovery,
      "TiebaPlusPlus.homeShowsDiscovery"
    )
    XCTAssertEqual(AppStartDestination.defaultValue, .home)
    XCTAssertTrue(AppPreferenceDefaults.homeShowsDiscovery)
    XCTAssertEqual(AppStartDestination.resolved(""), .home)
    XCTAssertEqual(AppStartDestination.resolved("future-value"), .home)
  }

  func testHomeStartDestinationUsesStableValuesTitlesAndOrdering() {
    XCTAssertEqual(
      AppStartDestination.allCases,
      [.home, .hotThreads, .hotTopics, .favorites, .history]
    )
    XCTAssertEqual(
      AppStartDestination.allCases.map(\.rawValue),
      ["home", "hotThreads", "hotTopics", "favorites", "history"]
    )
    XCTAssertEqual(
      AppStartDestination.allCases.map(\.title),
      ["首页", "帖子热榜", "热门话题", "本地收藏", "浏览记录"]
    )

    for destination in AppStartDestination.allCases {
      XCTAssertEqual(AppStartDestination.resolved(destination.rawValue), destination)
    }
  }

  func testAppearanceFallsBackToSystemForUnknownStoredValue() {
    XCTAssertEqual(AppAppearance.resolved("system"), .system)
    XCTAssertEqual(AppAppearance.resolved("light"), .light)
    XCTAssertEqual(AppAppearance.resolved("dark"), .dark)
    XCTAssertEqual(AppAppearance.resolved("future-value"), .system)
    XCTAssertNil(AppAppearance.system.colorScheme)
    XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
  }

  func testContentMediaLoadPolicyUsesStableValuesAndFallsBackToAutomatic() {
    XCTAssertEqual(
      AppPreferenceKey.contentMediaLoadPolicy,
      "TiebaPlusPlus.contentMediaLoadPolicy"
    )
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("automatic"), .automatic)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("tapToLoad"), .tapToLoad)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("future-value"), .automatic)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved(""), .automatic)
    XCTAssertEqual(ContentMediaLoadPolicy.automatic.title, "自动加载")
    XCTAssertEqual(ContentMediaLoadPolicy.tapToLoad.title, "点按加载")
  }

  @MainActor
  func testThreadListMediaCollapseUsesStableKeyAndDefaultsToExpanded() {
    XCTAssertEqual(
      AppPreferenceKey.hidesThreadListMedia,
      "TiebaPlusPlus.hidesThreadListMedia"
    )
    XCTAssertFalse(EnvironmentValues().hidesThreadListMedia)
  }

  @MainActor
  func testContentThumbnailDimmingUsesStableKeyAndDefaultsToEnabled() {
    XCTAssertEqual(
      AppPreferenceKey.darkensContentThumbnailsInDarkMode,
      "TiebaPlusPlus.darkensContentThumbnailsInDarkMode"
    )
    XCTAssertTrue(EnvironmentValues().darkensContentThumbnailsInDarkMode)
  }

  @MainActor
  func testUsernameAndNicknamePresentationUsesStableKeyAndDefaultsToSingleName() {
    XCTAssertEqual(
      AppPreferenceKey.showsBothUsernameAndNickname,
      "TiebaPlusPlus.showsBothUsernameAndNickname"
    )
    XCTAssertFalse(EnvironmentValues().showsBothUsernameAndNickname)
  }

  func testForumSortUsesPerForumOverrideBeforeGlobalDefault() throws {
    let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      ForumThreadSort.creationTime.rawValue,
      forKey: AppPreferenceKey.defaultForumSort
    )

    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: "Other", defaults: defaults),
      .creationTime
    )

    ForumSortPreferences.save(.replyTime, for: " Cafe\u{301} ", defaults: defaults)

    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: "Café", defaults: defaults),
      .replyTime
    )
    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: "CAFÉ", defaults: defaults),
      .replyTime
    )
    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: "Other", defaults: defaults),
      .creationTime
    )
  }

  func testForumSortRejectsUnboundedNamesAndInvalidDefaults() throws {
    let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("future-value", forKey: AppPreferenceKey.defaultForumSort)
    let oversizedName = String(repeating: "a", count: 1_025)

    ForumSortPreferences.save(.creationTime, for: oversizedName, defaults: defaults)

    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: oversizedName, defaults: defaults),
      .replyTime
    )
    XCTAssertEqual(
      ForumSortPreferences.resolvedSort(for: "", defaults: defaults),
      .replyTime
    )
  }
}
