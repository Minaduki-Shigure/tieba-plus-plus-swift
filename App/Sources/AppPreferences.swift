import Foundation
import SwiftUI

enum AppPreferenceKey {
  static let appearance = "TiebaPlusPlus.appearance"
  static let defaultForumSort = "TiebaPlusPlus.defaultForumSort"
  static let homeShowsRecentForums = "TiebaPlusPlus.homeShowsRecentForums"
  static let searchSuggestionsEnabled = "TiebaPlusPlus.searchSuggestionsEnabled"
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
