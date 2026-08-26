import XCTest

@testable import TiebaPlusPlus

final class AccountHubItemTests: XCTestCase {
  func testItemsKeepStableTiebaLiteAlignedOrderAndPresentation() {
    XCTAssertEqual(
      AccountHubItem.allCases,
      [.localFavorites, .history, .appearance, .settings, .about]
    )
    XCTAssertEqual(
      AccountHubItem.allCases.map(\.title),
      ["本机收藏", "浏览记录", "外观", "设置", "关于贴吧++"]
    )
    XCTAssertEqual(
      AccountHubItem.allCases.map(\.systemImage),
      [
        "bookmark",
        "clock.arrow.circlepath",
        "circle.lefthalf.filled",
        "gearshape",
        "info.circle",
      ]
    )
  }

  func testNavigationItemsUseTypedRootDestinationsAndAppearanceStaysInline() {
    let expectedDestinations: [RootDestination?] = [
      .favorites,
      .history,
      nil,
      .settings,
      .about,
    ]

    XCTAssertEqual(
      AccountHubItem.allCases.map(\.destination),
      expectedDestinations
    )
  }

  func testNavigationItemsAppendInsideMyTabWithoutChangingOtherStacks() {
    var navigation = RootMainNavigationState(
      selectedTab: .account,
      homePath: [.hotTopics],
      notificationsPath: [.user(42)]
    )

    for destination in AccountHubItem.allCases.compactMap(\.destination) {
      navigation.append(destination, to: .account)
    }

    XCTAssertEqual(navigation.selectedTab, .account)
    XCTAssertEqual(
      navigation.path(for: .account),
      [.favorites, .history, .settings, .about]
    )
    XCTAssertEqual(navigation.path(for: .home), [.hotTopics])
    XCTAssertEqual(navigation.path(for: .notifications), [.user(42)])
  }

  func testMessagesSearchAppendsInsideMessagesTabWithoutChangingOtherStacks() {
    var navigation = RootMainNavigationState(
      selectedTab: .notifications,
      homePath: [.history],
      accountPath: [.settings]
    )

    navigation.append(NotificationsToolbarRoute.searchDestination, to: .notifications)

    XCTAssertEqual(NotificationsToolbarRoute.searchDestination, .search(""))
    XCTAssertEqual(navigation.selectedTab, .notifications)
    XCTAssertEqual(navigation.path(for: .notifications), [.search("")])
    XCTAssertEqual(navigation.path(for: .home), [.history])
    XCTAssertEqual(navigation.path(for: .account), [.settings])
  }

  func testItemsExposeUniqueStableAccessibilityIdentifiers() {
    let identifiers = AccountHubItem.allCases.map(\.accessibilityIdentifier)

    XCTAssertEqual(
      identifiers,
      [
        "account-hub-local-favorites",
        "account-hub-history",
        "account-hub-appearance",
        "account-hub-settings",
        "account-hub-about",
      ]
    )
    XCTAssertEqual(Set(identifiers).count, identifiers.count)
  }
}
