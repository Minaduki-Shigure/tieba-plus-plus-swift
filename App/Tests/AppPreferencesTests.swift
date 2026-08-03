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

  func testFavoriteThreadOpenOverridesUseStableKeysAndDefaultOff() {
    XCTAssertEqual(
      AppPreferenceKey.favoriteThreadsOpenOnlyAuthor,
      "TiebaPlusPlus.favoriteThreadsOpenOnlyAuthor"
    )
    XCTAssertEqual(
      AppPreferenceKey.favoriteThreadsOpenDescending,
      "TiebaPlusPlus.favoriteThreadsOpenDescending"
    )
    XCTAssertFalse(AppPreferenceDefaults.favoriteThreadsOpenOnlyAuthor)
    XCTAssertFalse(AppPreferenceDefaults.favoriteThreadsOpenDescending)
    XCTAssertEqual(
      FavoriteThreadOpenOverrides(),
      FavoriteThreadOpenOverrides(onlyThreadAuthor: false, descending: false)
    )
  }

  func testFavoriteThreadOpenOverridesApplyAllForceOnCombinations() {
    let original = ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false)
    let combinations: [(Bool, Bool, ThreadPostSort, Bool)] = [
      (false, false, .hot, false),
      (true, false, .hot, true),
      (false, true, .descending, false),
      (true, true, .descending, true),
    ]

    for (onlyThreadAuthor, descending, expectedSort, expectedOnlyThreadAuthor) in combinations {
      let result = FavoriteThreadOpenOverrides(
        onlyThreadAuthor: onlyThreadAuthor,
        descending: descending
      ).applying(to: original)

      XCTAssertEqual(result.sort, expectedSort)
      XCTAssertEqual(result.onlyThreadAuthor, expectedOnlyThreadAuthor)
    }
  }

  func testDisabledFavoriteThreadOverridesPreserveExistingOptions() {
    let original = ThreadBrowseOptions(sort: .ascending, onlyThreadAuthor: true)

    XCTAssertEqual(FavoriteThreadOpenOverrides().applying(to: original), original)
  }

  func testFavoriteThreadOverridesPreserveCompleteHistorySnapshot() throws {
    let snapshot = ThreadHistorySnapshot(
      threadID: 42,
      forumID: 7,
      forumName: "Swift",
      title: "A saved thread",
      excerpt: "Full snapshot excerpt",
      authorName: "Display name",
      authorUsername: "account_name",
      replyCount: 12,
      viewCount: 34,
      createdAt: Date(timeIntervalSince1970: 100),
      lastReplyAt: Date(timeIntervalSince1970: 200),
      authorAvatarURL: try XCTUnwrap(
        URL(string: "https://himg.bdimg.com/sys/portrait/item/test.jpg")
      ),
      browseOptions: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false),
      lastPostID: 99,
      lastFloor: 8
    )

    XCTAssertEqual(FavoriteThreadOpenOverrides().applying(to: snapshot), snapshot)

    let result = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    ).applying(to: snapshot)

    XCTAssertEqual(result.threadID, snapshot.threadID)
    XCTAssertEqual(result.forumID, snapshot.forumID)
    XCTAssertEqual(result.forumName, snapshot.forumName)
    XCTAssertEqual(result.title, snapshot.title)
    XCTAssertEqual(result.excerpt, snapshot.excerpt)
    XCTAssertEqual(result.authorName, snapshot.authorName)
    XCTAssertEqual(result.authorUsername, snapshot.authorUsername)
    XCTAssertEqual(result.replyCount, snapshot.replyCount)
    XCTAssertEqual(result.viewCount, snapshot.viewCount)
    XCTAssertEqual(result.createdAt, snapshot.createdAt)
    XCTAssertEqual(result.lastReplyAt, snapshot.lastReplyAt)
    XCTAssertEqual(result.authorAvatarURL, snapshot.authorAvatarURL)
    XCTAssertEqual(result.lastPostID, snapshot.lastPostID)
    XCTAssertEqual(result.lastFloor, snapshot.lastFloor)
    XCTAssertEqual(
      result.browseOptions,
      ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    )
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
