import Foundation
import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class AppPreferencesTests: XCTestCase {
  func testAppearanceFallsBackToSystemForUnknownStoredValue() {
    XCTAssertEqual(AppAppearance.resolved("system"), .system)
    XCTAssertEqual(AppAppearance.resolved("light"), .light)
    XCTAssertEqual(AppAppearance.resolved("dark"), .dark)
    XCTAssertEqual(AppAppearance.resolved("future-value"), .system)
    XCTAssertNil(AppAppearance.system.colorScheme)
    XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
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
