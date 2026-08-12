import Foundation
import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class AppPreferencesTests: XCTestCase {
  func testForumPrimaryActionUsesStableTiebaLiteValuesAndFallback() {
    XCTAssertEqual(
      AppPreferenceKey.forumPrimaryAction,
      "TiebaPlusPlus.forumPrimaryAction"
    )
    XCTAssertEqual(ForumPrimaryAction.defaultValue, .newThread)
    XCTAssertEqual(
      ForumPrimaryAction.allCases,
      [.newThread, .refresh, .scrollToTop, .hidden]
    )
    XCTAssertEqual(
      ForumPrimaryAction.allCases.map(\.rawValue),
      ["post", "refresh", "back_to_top", "hide"]
    )
    XCTAssertEqual(
      ForumPrimaryAction.allCases.map(\.title),
      ["发布主题", "刷新", "回到顶部", "隐藏"]
    )
    XCTAssertEqual(
      ForumPrimaryAction.allCases.map(\.systemImage),
      ["square.and.pencil", "arrow.clockwise", "arrow.up.to.line", "eye.slash"]
    )
    XCTAssertEqual(ForumPrimaryAction.resolved("refresh"), .refresh)
    XCTAssertEqual(ForumPrimaryAction.resolved("back_to_top"), .scrollToTop)
    XCTAssertEqual(ForumPrimaryAction.resolved("future-value"), .newThread)
    XCTAssertEqual(ForumPrimaryAction.resolved(""), .newThread)
  }

  func testForumPrimaryActionPersistsInUserDefaults() throws {
    let suiteName = "AppPreferencesTests.forum-primary-action.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(defaults.object(forKey: AppPreferenceKey.forumPrimaryAction))
    defaults.set(
      ForumPrimaryAction.scrollToTop.rawValue,
      forKey: AppPreferenceKey.forumPrimaryAction
    )

    let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertEqual(
      ForumPrimaryAction.resolved(
        reloadedDefaults.string(forKey: AppPreferenceKey.forumPrimaryAction) ?? ""
      ),
      .scrollToTop
    )
  }

  func testForumPrimaryActionPolicyKeepsOnlySelectedToolbarAction() {
    let readySelections: [(ForumPrimaryAction, ForumPrimaryAction?)] = [
      (.newThread, .newThread),
      (.refresh, .refresh),
      (.scrollToTop, .scrollToTop),
      (.hidden, nil),
    ]

    for (selected, expectedToolbarAction) in readySelections {
      let policy = ForumPrimaryActionPolicy(
        selected: selected,
        hasNewThreadTarget: true,
        isLoading: false,
        hasThreads: true
      )

      XCTAssertEqual(policy.toolbarAction, expectedToolbarAction)
      for action in ForumPrimaryAction.allCases {
        XCTAssertEqual(
          policy.canPerform(action),
          action == expectedToolbarAction
        )
      }
    }
  }

  func testForumPrimaryActionPolicyRechecksPageCapabilities() {
    let missingTarget = ForumPrimaryActionPolicy(
      selected: .newThread,
      hasNewThreadTarget: false,
      isLoading: false,
      hasThreads: true
    )
    XCTAssertEqual(missingTarget.toolbarAction, .newThread)
    XCTAssertFalse(missingTarget.canPerform(.newThread))

    let loading = ForumPrimaryActionPolicy(
      selected: .refresh,
      hasNewThreadTarget: true,
      isLoading: true,
      hasThreads: true
    )
    XCTAssertEqual(loading.toolbarAction, .refresh)
    XCTAssertFalse(loading.canPerform(.refresh))

    let empty = ForumPrimaryActionPolicy(
      selected: .scrollToTop,
      hasNewThreadTarget: true,
      isLoading: false,
      hasThreads: false
    )
    XCTAssertEqual(empty.toolbarAction, .scrollToTop)
    XCTAssertFalse(empty.canPerform(.scrollToTop))

    let hidden = ForumPrimaryActionPolicy(
      selected: .hidden,
      hasNewThreadTarget: true,
      isLoading: false,
      hasThreads: true
    )
    XCTAssertNil(hidden.toolbarAction)
    XCTAssertFalse(hidden.canPerform(.hidden))
  }

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

  func testFollowedForumsLayoutUsesStableValuesAndDefaultsToAdaptive() {
    XCTAssertEqual(
      AppPreferenceKey.followedForumsLayout,
      "TiebaPlusPlus.followedForumsLayout"
    )
    XCTAssertEqual(FollowedForumsLayoutMode.defaultValue, .adaptive)
    XCTAssertEqual(FollowedForumsLayoutMode.allCases, [.adaptive, .singleColumn])
    XCTAssertEqual(
      FollowedForumsLayoutMode.allCases.map(\.rawValue),
      ["adaptive", "singleColumn"]
    )
    XCTAssertEqual(
      FollowedForumsLayoutMode.allCases.map(\.title),
      ["自适应", "单列"]
    )
    XCTAssertEqual(FollowedForumsLayoutMode.resolved("adaptive"), .adaptive)
    XCTAssertEqual(FollowedForumsLayoutMode.resolved("singleColumn"), .singleColumn)
    XCTAssertEqual(FollowedForumsLayoutMode.resolved("future-value"), .adaptive)
    XCTAssertEqual(FollowedForumsLayoutMode.adaptive.toggled, .singleColumn)
    XCTAssertEqual(FollowedForumsLayoutMode.singleColumn.toggled, .adaptive)
  }

  func testFollowedForumsLayoutPersistsInUserDefaults() throws {
    let suiteName = "AppPreferencesTests.followed-forums-layout.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(defaults.object(forKey: AppPreferenceKey.followedForumsLayout))
    defaults.set(
      FollowedForumsLayoutMode.singleColumn.rawValue,
      forKey: AppPreferenceKey.followedForumsLayout
    )

    let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertEqual(
      FollowedForumsLayoutMode.resolved(
        reloadedDefaults.string(forKey: AppPreferenceKey.followedForumsLayout) ?? ""
      ),
      .singleColumn
    )
  }

  func testFollowedForumsLayoutForcesSingleColumnAtAccessibilitySizes() {
    XCTAssertEqual(
      FollowedForumsLayoutPolicy.effectiveMode(
        preferred: .adaptive,
        dynamicTypeSize: .xxxLarge
      ),
      .adaptive
    )
    XCTAssertEqual(
      FollowedForumsLayoutPolicy.effectiveMode(
        preferred: .singleColumn,
        dynamicTypeSize: .large
      ),
      .singleColumn
    )

    let accessibilitySizes: [DynamicTypeSize] = [
      .accessibility1,
      .accessibility2,
      .accessibility3,
      .accessibility4,
      .accessibility5,
    ]
    for size in accessibilitySizes {
      XCTAssertEqual(
        FollowedForumsLayoutPolicy.effectiveMode(
          preferred: .adaptive,
          dynamicTypeSize: size
        ),
        .singleColumn
      )
    }
  }

  func testPersonalizedRecommendationIdentityIsStableAndRepairsInvalidStorage() throws {
    let suiteName = "AppPreferencesTests.personalized.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = PersonalizedRecommendationIdentity.current(defaults: defaults)
    let second = PersonalizedRecommendationIdentity.current(defaults: defaults)
    XCTAssertEqual(first, second)
    XCTAssertEqual(UUID(uuidString: first)?.uuidString.lowercased(), first)
    XCTAssertEqual(
      defaults.string(forKey: AppPreferenceKey.personalizedRecommendationCUID),
      first
    )

    defaults.set("not-a-uuid", forKey: AppPreferenceKey.personalizedRecommendationCUID)
    let repaired = PersonalizedRecommendationIdentity.current(defaults: defaults)
    XCTAssertNotEqual(repaired, "not-a-uuid")
    XCTAssertEqual(UUID(uuidString: repaired)?.uuidString.lowercased(), repaired)
  }

  func testPersonalizedFollowedForumsOnlyUsesStableKeyAndDefaultsOff() {
    XCTAssertEqual(
      AppPreferenceKey.personalizedFollowedForumsOnly,
      "TiebaPlusPlus.personalizedFollowedForumsOnly"
    )
    XCTAssertFalse(AppPreferenceDefaults.personalizedFollowedForumsOnly)
  }

  @MainActor
  func testReplyEntryPreferenceUsesStableKeyAndDefaultsToVisible() {
    XCTAssertEqual(
      AppPreferenceKey.hidesReplyEntryPoints,
      "TiebaPlusPlus.hidesReplyEntryPoints"
    )
    XCTAssertFalse(AppPreferenceDefaults.hidesReplyEntryPoints)
    XCTAssertFalse(EnvironmentValues().hidesReplyEntryPoints)

    var environment = EnvironmentValues()
    environment.hidesReplyEntryPoints = true
    XCTAssertTrue(environment.hidesReplyEntryPoints)
  }

  func testReplyEntryPreferencePersistsInUserDefaults() throws {
    let suiteName = "AppPreferencesTests.reply-entry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(defaults.object(forKey: AppPreferenceKey.hidesReplyEntryPoints))
    XCTAssertFalse(defaults.bool(forKey: AppPreferenceKey.hidesReplyEntryPoints))

    defaults.set(true, forKey: AppPreferenceKey.hidesReplyEntryPoints)

    let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertTrue(reloadedDefaults.bool(forKey: AppPreferenceKey.hidesReplyEntryPoints))
  }

  func testPostAndReplyRiskNoticeUsesStableKeyAndDefaultsOn() throws {
    XCTAssertEqual(
      AppPreferenceKey.showsPostAndReplyRiskNotice,
      "TiebaPlusPlus.showsPostAndReplyRiskNotice"
    )
    XCTAssertTrue(AppPreferenceDefaults.showsPostAndReplyRiskNotice)

    let suiteName = "AppPreferencesTests.post-reply-risk-notice.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(defaults.object(forKey: AppPreferenceKey.showsPostAndReplyRiskNotice))
    defaults.set(false, forKey: AppPreferenceKey.showsPostAndReplyRiskNotice)

    let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertFalse(
      reloadedDefaults.bool(forKey: AppPreferenceKey.showsPostAndReplyRiskNotice)
    )
  }

  func testReplyEntryVisibilityPolicyMatrix() {
    for preferenceHidden in [false, true] {
      for pureReading in [false, true] {
        for contextAvailable in [false, true] {
          let policy = ReplyEntryVisibilityPolicy(
            preferenceHidden: preferenceHidden,
            pureReading: pureReading,
            contextAvailable: contextAvailable
          )
          XCTAssertEqual(
            policy.showsReplyEntry,
            contextAvailable && !preferenceHidden && !pureReading,
            "Unexpected reply entry visibility for hidden=\(preferenceHidden), "
              + "pureReading=\(pureReading), contextAvailable=\(contextAvailable)"
          )
        }
      }
    }
  }

  func testHomeStartDestinationUsesStableValuesTitlesAndOrdering() {
    XCTAssertEqual(
      AppStartDestination.allCases,
      [.home, .hotThreads, .hotTopics, .notifications, .favorites, .history]
    )
    XCTAssertEqual(
      AppStartDestination.allCases.map(\.rawValue),
      ["home", "hotThreads", "hotTopics", "notifications", "favorites", "history"]
    )
    XCTAssertEqual(
      AppStartDestination.allCases.map(\.title),
      ["首页", "帖子热榜", "热门话题", "消息", "本地收藏", "浏览记录"]
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

  @MainActor
  func testAccentColorUsesStableValuesTitlesAndDefault() {
    XCTAssertEqual(AppPreferenceKey.accentColor, "TiebaPlusPlus.accentColor")
    XCTAssertEqual(AppAccentColor.allCases, [.blue, .indigo, .teal, .green, .rose])
    XCTAssertEqual(
      AppAccentColor.allCases.map(\.rawValue),
      ["blue", "indigo", "teal", "green", "rose"]
    )
    XCTAssertEqual(
      AppAccentColor.allCases.map(\.title),
      ["贴吧蓝", "靛蓝", "青绿", "叶绿", "玫红"]
    )
    XCTAssertEqual(AppAccentColor.defaultValue, .blue)
    XCTAssertEqual(AppAccentColor.resolved("blue"), .blue)
    XCTAssertEqual(AppAccentColor.resolved("rose"), .rose)
    XCTAssertEqual(AppAccentColor.resolved(""), .blue)
    XCTAssertEqual(AppAccentColor.resolved("future-value"), .blue)
    XCTAssertEqual(EnvironmentValues().appAccentColor, .blue)

    var environment = EnvironmentValues()
    environment.appAccentColor = .teal
    XCTAssertEqual(environment.appAccentColor, .teal)
  }

  @MainActor
  func testContentImagePreviewQualityUsesStableValuesAndDefaultsToStandard() {
    XCTAssertEqual(
      AppPreferenceKey.contentImagePreviewQuality,
      "TiebaPlusPlus.contentImagePreviewQuality"
    )
    XCTAssertEqual(ContentImagePreviewQuality.allCases, [.standard, .highDefinition])
    XCTAssertEqual(
      ContentImagePreviewQuality.allCases.map(\.rawValue),
      ["standard", "highDefinition"]
    )
    XCTAssertEqual(
      ContentImagePreviewQuality.allCases.map(\.title),
      ["标准（推荐）", "高清"]
    )
    XCTAssertEqual(ContentImagePreviewQuality.defaultValue, .standard)
    XCTAssertEqual(ContentImagePreviewQuality.resolved("standard"), .standard)
    XCTAssertEqual(ContentImagePreviewQuality.resolved("highDefinition"), .highDefinition)
    XCTAssertEqual(ContentImagePreviewQuality.resolved(""), .standard)
    XCTAssertEqual(ContentImagePreviewQuality.resolved("future-value"), .standard)
    XCTAssertEqual(EnvironmentValues().contentImagePreviewQuality, .standard)

    var environment = EnvironmentValues()
    environment.contentImagePreviewQuality = .highDefinition
    XCTAssertEqual(environment.contentImagePreviewQuality, .highDefinition)
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
