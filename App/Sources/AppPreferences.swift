import Foundation
import SwiftUI

enum AppPreferenceKey {
  static let appearance = "TiebaPlusPlus.appearance"
  static let defaultForumSort = "TiebaPlusPlus.defaultForumSort"
  static let homeStartDestination = "TiebaPlusPlus.homeStartDestination"
  static let homeShowsDiscovery = "TiebaPlusPlus.homeShowsDiscovery"
  static let homeShowsRecentForums = "TiebaPlusPlus.homeShowsRecentForums"
  static let searchSuggestionsEnabled = "TiebaPlusPlus.searchSuggestionsEnabled"
  static let externalWebOpenMode = "TiebaPlusPlus.externalWebOpenMode"
  static let contentMediaLoadPolicy = "TiebaPlusPlus.contentMediaLoadPolicy"
  static let hidesThreadListMedia = "TiebaPlusPlus.hidesThreadListMedia"
  static let darkensContentThumbnailsInDarkMode =
    "TiebaPlusPlus.darkensContentThumbnailsInDarkMode"
  static let showsBothUsernameAndNickname =
    "TiebaPlusPlus.showsBothUsernameAndNickname"
  static let favoriteThreadsOpenOnlyAuthor =
    "TiebaPlusPlus.favoriteThreadsOpenOnlyAuthor"
  static let favoriteThreadsOpenDescending =
    "TiebaPlusPlus.favoriteThreadsOpenDescending"
}

enum AppPreferenceDefaults {
  static let homeShowsDiscovery = true
  static let favoriteThreadsOpenOnlyAuthor = false
  static let favoriteThreadsOpenDescending = false
}

struct FavoriteThreadOpenOverrides: Equatable, Sendable {
  let onlyThreadAuthor: Bool
  let descending: Bool

  init(
    onlyThreadAuthor: Bool = AppPreferenceDefaults.favoriteThreadsOpenOnlyAuthor,
    descending: Bool = AppPreferenceDefaults.favoriteThreadsOpenDescending
  ) {
    self.onlyThreadAuthor = onlyThreadAuthor
    self.descending = descending
  }

  func applying(to options: ThreadBrowseOptions) -> ThreadBrowseOptions {
    var result = options
    if onlyThreadAuthor {
      result.onlyThreadAuthor = true
    }
    if descending {
      result.sort = .descending
    }
    return result
  }

  func applying(to snapshot: ThreadHistorySnapshot) -> ThreadHistorySnapshot {
    ThreadHistorySnapshot(
      threadID: snapshot.threadID,
      forumID: snapshot.forumID,
      forumName: snapshot.forumName,
      title: snapshot.title,
      excerpt: snapshot.excerpt,
      authorName: snapshot.authorName,
      authorUsername: snapshot.authorUsername,
      replyCount: snapshot.replyCount,
      viewCount: snapshot.viewCount,
      createdAt: snapshot.createdAt,
      lastReplyAt: snapshot.lastReplyAt,
      authorAvatarURL: snapshot.authorAvatarURL,
      browseOptions: applying(to: snapshot.browseOptions),
      lastPostID: snapshot.lastPostID,
      lastFloor: snapshot.lastFloor
    )
  }
}

enum AppStartDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case home
  case hotThreads
  case hotTopics
  case favorites
  case history

  static let defaultValue: Self = .home

  var id: Self { self }

  var title: String {
    switch self {
    case .home:
      "首页"
    case .hotThreads:
      "帖子热榜"
    case .hotTopics:
      "热门话题"
    case .favorites:
      "本地收藏"
    case .history:
      "浏览记录"
    }
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? defaultValue
  }
}

enum ExternalWebOpenMode: String, CaseIterable, Hashable, Identifiable, Sendable {
  case systemBrowser
  case inAppSafari

  static let defaultValue: Self = .systemBrowser

  var id: Self { self }

  var title: String {
    switch self {
    case .systemBrowser:
      "系统默认浏览器"
    case .inAppSafari:
      "应用内 Safari"
    }
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? defaultValue
  }
}

private struct HidesThreadListMediaEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

private struct DarkensContentThumbnailsInDarkModeEnvironmentKey: EnvironmentKey {
  static let defaultValue = true
}

private struct ShowsBothUsernameAndNicknameEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

private struct ExternalWebOpenModeEnvironmentKey: EnvironmentKey {
  static let defaultValue = ExternalWebOpenMode.defaultValue
}

extension EnvironmentValues {
  var hidesThreadListMedia: Bool {
    get { self[HidesThreadListMediaEnvironmentKey.self] }
    set { self[HidesThreadListMediaEnvironmentKey.self] = newValue }
  }

  var darkensContentThumbnailsInDarkMode: Bool {
    get { self[DarkensContentThumbnailsInDarkModeEnvironmentKey.self] }
    set { self[DarkensContentThumbnailsInDarkModeEnvironmentKey.self] = newValue }
  }

  var showsBothUsernameAndNickname: Bool {
    get { self[ShowsBothUsernameAndNicknameEnvironmentKey.self] }
    set { self[ShowsBothUsernameAndNicknameEnvironmentKey.self] = newValue }
  }

  var externalWebOpenMode: ExternalWebOpenMode {
    get { self[ExternalWebOpenModeEnvironmentKey.self] }
    set { self[ExternalWebOpenModeEnvironmentKey.self] = newValue }
  }
}

enum AppAppearance: String, CaseIterable, Hashable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: Self { self }

  var title: String {
    switch self {
    case .system:
      "跟随系统"
    case .light:
      "浅色"
    case .dark:
      "深色"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? .system
  }
}

enum ContentMediaLoadPolicy: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case networkAware
  case tapToLoad

  var id: Self { self }

  var title: String {
    switch self {
    case .automatic:
      "自动加载"
    case .networkAware:
      "节省流量"
    case .tapToLoad:
      "点按加载"
    }
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? .automatic
  }
}

enum ForumSortPreferences {
  private static let perForumPrefix = "TiebaPlusPlus.forumSort."
  private static let maximumForumNameBytes = 1_024

  static func resolvedSort(
    for forumName: String,
    defaults: UserDefaults = .standard
  ) -> ForumThreadSort {
    if
      let key = perForumKey(for: forumName),
      let rawValue = defaults.string(forKey: key),
      let sort = ForumThreadSort(rawValue: rawValue)
    {
      return sort
    }
    return ForumThreadSort(
      rawValue: defaults.string(forKey: AppPreferenceKey.defaultForumSort) ?? ""
    ) ?? .replyTime
  }

  static func save(
    _ sort: ForumThreadSort,
    for forumName: String,
    defaults: UserDefaults = .standard
  ) {
    guard let key = perForumKey(for: forumName) else { return }
    defaults.set(sort.rawValue, forKey: key)
  }

  private static func perForumKey(for rawName: String) -> String? {
    let name = rawName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
    guard
      !name.isEmpty,
      name.utf8.count <= maximumForumNameBytes
    else { return nil }
    return perForumPrefix + Data(name.utf8).base64EncodedString()
  }
}
