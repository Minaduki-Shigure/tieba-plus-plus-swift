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

  func testTextSizeAdjustmentUsesStableValuesTitlesAndDefault() {
    XCTAssertEqual(
      AppPreferenceKey.textSizeAdjustment,
      "TiebaPlusPlus.textSizeAdjustment"
    )
    XCTAssertEqual(
      AppTextSizeAdjustment.allCases,
      [
        .twoStepsSmaller,
        .oneStepSmaller,
        .standard,
        .oneStepLarger,
        .twoStepsLarger,
        .threeStepsLarger,
      ]
    )
    XCTAssertEqual(AppTextSizeAdjustment.allCases.map(\.rawValue), [-2, -1, 0, 1, 2, 3])
    XCTAssertEqual(
      AppTextSizeAdjustment.allCases.map(\.title),
      [
        "比系统小两级",
        "比系统小一级",
        "跟随系统",
        "比系统大一级",
        "比系统大两级",
        "比系统大三级",
      ]
    )
    XCTAssertEqual(AppTextSizeAdjustment.defaultValue, .standard)
    XCTAssertEqual(AppTextSizeAdjustment.resolved(-2), .twoStepsSmaller)
    XCTAssertEqual(AppTextSizeAdjustment.resolved(3), .threeStepsLarger)
    XCTAssertEqual(AppTextSizeAdjustment.resolved(Int.min), .standard)
    XCTAssertEqual(AppTextSizeAdjustment.resolved(Int.max), .standard)
  }

  func testTextSizeAdjustmentOffsetsAndClampsEveryDynamicTypeSize() {
    let sizes: [DynamicTypeSize] = [
      .xSmall,
      .small,
      .medium,
      .large,
      .xLarge,
      .xxLarge,
      .xxxLarge,
      .accessibility1,
      .accessibility2,
      .accessibility3,
      .accessibility4,
      .accessibility5,
    ]

    for (systemIndex, systemSize) in sizes.enumerated() {
      for adjustment in AppTextSizeAdjustment.allCases {
        let expectedIndex = min(
          max(systemIndex + adjustment.rawValue, sizes.startIndex),
          sizes.index(before: sizes.endIndex)
        )
        XCTAssertEqual(
          AppDynamicTypeSizeResolver.resolvedSize(
            systemSize: systemSize,
            adjustment: adjustment
          ),
          sizes[expectedIndex],
          "Unexpected result for system index \(systemIndex), adjustment \(adjustment.rawValue)"
        )
      }
    }
  }

  func testExpandedControlsStartAtExtraExtraLargeDynamicTypeSize() {
    XCTAssertFalse(AppDynamicTypeLayout.prefersExpandedControls(for: .xSmall))
    XCTAssertFalse(AppDynamicTypeLayout.prefersExpandedControls(for: .xLarge))
    XCTAssertTrue(AppDynamicTypeLayout.prefersExpandedControls(for: .xxLarge))
    XCTAssertTrue(AppDynamicTypeLayout.prefersExpandedControls(for: .accessibility5))
  }

  func testSettingsUseMenuPickersFromExtraExtraExtraLargeDynamicTypeSize() {
    XCTAssertFalse(AppDynamicTypeLayout.prefersMenuPickers(for: .xSmall))
    XCTAssertFalse(AppDynamicTypeLayout.prefersMenuPickers(for: .xxLarge))
    XCTAssertTrue(AppDynamicTypeLayout.prefersMenuPickers(for: .xxxLarge))
    XCTAssertTrue(AppDynamicTypeLayout.prefersMenuPickers(for: .accessibility1))
    XCTAssertTrue(AppDynamicTypeLayout.prefersMenuPickers(for: .accessibility5))
  }

  func testContentMediaLoadPolicyUsesStableValuesAndFallsBackToAutomatic() {
    XCTAssertEqual(
      AppPreferenceKey.contentMediaLoadPolicy,
      "TiebaPlusPlus.contentMediaLoadPolicy"
    )
    XCTAssertEqual(
      ContentMediaLoadPolicy.allCases,
      [.automatic, .networkAware, .tapToLoad]
    )
    XCTAssertEqual(
      ContentMediaLoadPolicy.allCases.map(\.rawValue),
      ["automatic", "networkAware", "tapToLoad"]
    )
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("automatic"), .automatic)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("networkAware"), .networkAware)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("tapToLoad"), .tapToLoad)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved("future-value"), .automatic)
    XCTAssertEqual(ContentMediaLoadPolicy.resolved(""), .automatic)
    XCTAssertEqual(
      ContentMediaLoadPolicy.allCases.map(\.title),
      ["自动加载", "节省流量", "点按加载"]
    )
  }

  @MainActor
  func testExternalWebOpenModeUsesStableValuesAndDefaultsToSystemBrowser() {
    XCTAssertEqual(
      AppPreferenceKey.externalWebOpenMode,
      "TiebaPlusPlus.externalWebOpenMode"
    )
    XCTAssertEqual(ExternalWebOpenMode.allCases, [.systemBrowser, .inAppSafari])
    XCTAssertEqual(
      ExternalWebOpenMode.allCases.map(\.rawValue),
      ["systemBrowser", "inAppSafari"]
    )
    XCTAssertEqual(
      ExternalWebOpenMode.allCases.map(\.title),
      ["系统默认浏览器", "应用内 Safari"]
    )
    XCTAssertEqual(ExternalWebOpenMode.defaultValue, .systemBrowser)
    XCTAssertEqual(ExternalWebOpenMode.resolved("systemBrowser"), .systemBrowser)
    XCTAssertEqual(ExternalWebOpenMode.resolved("inAppSafari"), .inAppSafari)
    XCTAssertEqual(ExternalWebOpenMode.resolved(""), .systemBrowser)
    XCTAssertEqual(ExternalWebOpenMode.resolved("future-value"), .systemBrowser)
    XCTAssertEqual(EnvironmentValues().externalWebOpenMode, .systemBrowser)

    var environment = EnvironmentValues()
    environment.externalWebOpenMode = .inAppSafari
    XCTAssertEqual(environment.externalWebOpenMode, .inAppSafari)
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
