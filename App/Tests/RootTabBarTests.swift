import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class RootTabBarTests: XCTestCase {
  func testProgrammaticSelectionUpdatesDoNotEmitUserSelection() throws {
    let coordinator = RootTabBarControl.Coordinator()
    let bar = UITabBar()
    bar.delegate = coordinator
    var selections: [RootMainTab] = []
    for tab in RootMainTab.allCases {
      coordinator.update(
        bar: bar, selectedTab: tab, showsExploreTab: true,
        notificationBadge: nil, allowsExploreRefresh: tab == .explore,
        onSelect: { selections.append($0) })
      XCTAssertEqual(bar.selectedItem?.accessibilityIdentifier, "root-tab-\(tab.rawValue)")
    }
    XCTAssertTrue(selections.isEmpty)
  }

  func testNativeDelegateForwardsEqualSelectionsAndUsesCurrentCallback() throws {
    let coordinator = RootTabBarControl.Coordinator()
    let bar = UITabBar()
    var firstSelections: [RootMainTab] = []
    coordinator.update(
      bar: bar, selectedTab: .explore, showsExploreTab: true,
      notificationBadge: nil, allowsExploreRefresh: true,
      onSelect: { firstSelections.append($0) })
    let explore = try XCTUnwrap(bar.selectedItem)
    coordinator.tabBar(bar, didSelect: explore)
    coordinator.tabBar(bar, didSelect: explore)
    XCTAssertEqual(firstSelections, [.explore, .explore])

    var currentSelections: [RootMainTab] = []
    coordinator.update(
      bar: bar, selectedTab: .explore, showsExploreTab: true,
      notificationBadge: nil, allowsExploreRefresh: true,
      onSelect: { currentSelections.append($0) })
    coordinator.tabBar(bar, didSelect: explore)
    XCTAssertEqual(firstSelections, [.explore, .explore])
    XCTAssertEqual(currentSelections, [.explore])
    // Actual UITabBar reselection dispatch is covered by the UI test. Calling
    // the delegate here only proves we do not discard/duplicate that event.
  }

  func testHiddenExploreCannotSelectAnotherTabByFormerIndex() throws {
    let coordinator = RootTabBarControl.Coordinator()
    let bar = UITabBar()
    var selections: [RootMainTab] = []
    coordinator.update(
      bar: bar, selectedTab: .explore, showsExploreTab: true,
      notificationBadge: "7", allowsExploreRefresh: true,
      onSelect: { selections.append($0) })
    let oldExplore = try XCTUnwrap(bar.selectedItem)
    let notifications = try XCTUnwrap(bar.items?[2])
    coordinator.update(
      bar: bar, selectedTab: .explore, showsExploreTab: false,
      notificationBadge: nil, allowsExploreRefresh: false,
      onSelect: { selections.append($0) })
    XCTAssertEqual(bar.items?.map(\.accessibilityIdentifier), [
      "root-tab-home", "root-tab-notifications", "root-tab-account",
    ])
    XCTAssertEqual(bar.selectedItem?.accessibilityIdentifier, "root-tab-home")
    XCTAssertTrue(bar.items?[1] === notifications)
    XCTAssertNil(notifications.badgeValue)
    coordinator.tabBar(bar, didSelect: oldExplore)
    coordinator.tabBar(bar, didSelect: notifications)
    coordinator.tabBar(bar, didSelect: UITabBarItem(title: "发现", image: nil, tag: 1))
    XCTAssertEqual(selections, [.notifications])

    coordinator.update(
      bar: bar, selectedTab: .home, showsExploreTab: true,
      notificationBadge: "99+", allowsExploreRefresh: false,
      onSelect: { selections.append($0) })
    XCTAssertTrue(bar.items?[1] === oldExplore)
    XCTAssertEqual(notifications.badgeValue, "99+")
    XCTAssertNil(oldExplore.accessibilityHint)
  }

  func testTabReselectionRefreshesOnlyVisibleActiveExploreRoot() {
    let root = RootMainNavigationState(selectedTab: .explore, exploreSection: .hot)
    XCTAssertEqual(action(.explore, navigation: root), .refreshExplore)
    XCTAssertEqual(action(.home, navigation: root), .select(.home))
    XCTAssertEqual(action(.notifications, navigation: root), .select(.notifications))

    var pushed = root
    pushed.append(.forum("Swift"), to: .explore)
    let original = pushed
    XCTAssertEqual(action(.explore, navigation: pushed), .none)
    XCTAssertEqual(pushed, original, "Reselecting must not pop or rebuild a navigation stack.")
    XCTAssertEqual(action(.explore, navigation: root, active: false), .none)
    XCTAssertEqual(action(.explore, navigation: root, showsExplore: false), .none)
    XCTAssertEqual(
      action(.explore, navigation: RootMainNavigationState(selectedTab: .home)),
      .select(.explore))
    for tab in [RootMainTab.home, .notifications, .account] {
      XCTAssertEqual(action(tab, navigation: RootMainNavigationState(selectedTab: tab)), .none)
    }
  }

  func testKeyboardCoverageDistinguishesDockedFloatingAndOtherWindowFrames() {
    let window = CGRect(x: 0, y: 0, width: 390, height: 844)
    func covers(_ frame: CGRect) -> Bool {
      RootTabBarKeyboardPolicy.coversBottom(
        keyboardFrame: frame, windowBounds: window, bottomSafeArea: 34)
    }
    XCTAssertTrue(covers(CGRect(x: 0, y: 520, width: 390, height: 324)))
    XCTAssertTrue(covers(CGRect(x: 0, y: 760, width: 390, height: 84)))
    XCTAssertFalse(covers(CGRect(x: 0, y: 844, width: 390, height: 324)))
    XCTAssertFalse(covers(CGRect(x: 50, y: 400, width: 290, height: 220)))
    XCTAssertFalse(covers(CGRect(x: 500, y: 520, width: 390, height: 324)))
    XCTAssertFalse(covers(CGRect(x: 0, y: 820, width: 390, height: 24)))
    XCTAssertFalse(covers(.null))
    XCTAssertFalse(covers(.infinite))
  }

  func testHomeReselectionRequiresAnActiveAccountAndVisibleForegroundRoot() {
    let root = RootMainNavigationState(selectedTab: .home)
    func homeAction(
      _ navigation: RootMainNavigationState? = nil,
      signedIn: Bool = true, active: Bool = true
    ) -> RootTabSelectionAction {
      RootTabSelectionPolicy.action(
        selecting: .home, navigation: navigation ?? root, showsExploreTab: true,
        sceneIsActive: active, hasActiveAccount: signedIn)
    }
    XCTAssertEqual(homeAction(), .refreshHome)
    XCTAssertEqual(homeAction(signedIn: false), .none)
    XCTAssertEqual(homeAction(active: false), .none)
    var pushed = root
    pushed.append(.forum("Swift"), to: .home)
    let original = pushed
    XCTAssertEqual(homeAction(pushed), .none)
    XCTAssertEqual(pushed, original)
    XCTAssertEqual(
      homeAction(RootMainNavigationState(selectedTab: .explore)), .select(.home))
    XCTAssertEqual(
      RootTabSelectionPolicy.action(
        selecting: .home, navigation: root, showsExploreTab: false,
        sceneIsActive: true, hasActiveAccount: true), .refreshHome)
  }

  func testHomeRefreshHintTracksEligibilityWithoutChangingNativeItemIdentity() throws {
    let coordinator = RootTabBarControl.Coordinator()
    let bar = UITabBar()
    coordinator.update(
      bar: bar, selectedTab: .home, showsExploreTab: true,
      notificationBadge: nil, allowsExploreRefresh: false, allowsHomeRefresh: true,
      onSelect: { _ in })
    let home = try XCTUnwrap(bar.selectedItem)
    XCTAssertEqual(home.accessibilityHint, "再次选择以刷新首页")
    coordinator.update(
      bar: bar, selectedTab: .home, showsExploreTab: true,
      notificationBadge: nil, allowsExploreRefresh: false, allowsHomeRefresh: false,
      onSelect: { _ in })
    XCTAssertTrue(home === bar.selectedItem)
    XCTAssertNil(home.accessibilityHint)
  }

  private func action(
    _ tab: RootMainTab,
    navigation: RootMainNavigationState,
    active: Bool = true,
    showsExplore: Bool = true
  ) -> RootTabSelectionAction {
    RootTabSelectionPolicy.action(
      selecting: tab, navigation: navigation, showsExploreTab: showsExplore,
      sceneIsActive: active)
  }
}
