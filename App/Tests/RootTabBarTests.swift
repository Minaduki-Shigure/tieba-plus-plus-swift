import SwiftUI
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

  func testKeyboardNotificationOwnershipRequiresCurrentScreenAndLocalKeyboard() {
    // A simulator need not have an external display. These identity tokens
    // exercise the same screen-ownership policy used by the native observer.
    let attachedScreen = NSObject()
    let otherScreen = NSObject()
    func accepts(_ source: AnyObject?, attached: AnyObject?, local: Bool? = true) -> Bool {
      RootTabBarKeyboardPolicy.acceptsNotification(
        notificationScreen: source, windowScreen: attached, isLocal: local)
    }
    XCTAssertTrue(accepts(attachedScreen, attached: attachedScreen))
    XCTAssertFalse(accepts(otherScreen, attached: attachedScreen))
    XCTAssertFalse(accepts(attachedScreen, attached: otherScreen))
    XCTAssertTrue(accepts(nil, attached: attachedScreen, local: nil))
    XCTAssertFalse(accepts(attachedScreen, attached: attachedScreen, local: false))
    XCTAssertFalse(accepts(nil, attached: attachedScreen, local: false))
    XCTAssertFalse(accepts(nil, attached: nil))
  }

  func testKeyboardFrameCacheSurvivesSameScreenButCannotReturnAfterMovingToAnotherScreen() {
    let firstScreen = NSObject()
    let secondScreen = NSObject()
    let original = CGRect(x: 0, y: 520, width: 390, height: 324)
    var cachedFrame: CGRect? = original
    for attachedScreen in [firstScreen, nil, firstScreen] {
      cachedFrame = RootTabBarKeyboardPolicy.retainedFrame(
        cachedFrame, frameScreen: firstScreen, attachedScreen: attachedScreen)
      XCTAssertEqual(cachedFrame, original, "Same-screen reattachment must retain keyboard state.")
    }
    cachedFrame = RootTabBarKeyboardPolicy.retainedFrame(
      cachedFrame, frameScreen: firstScreen, attachedScreen: secondScreen)
    XCTAssertNil(cachedFrame)
    // A dismissal on screen A is ignored while the bar is on B. Returning to A
    // must not revive the cached docked frame even without a new notification.
    cachedFrame = RootTabBarKeyboardPolicy.retainedFrame(
      cachedFrame, frameScreen: firstScreen, attachedScreen: firstScreen)
    XCTAssertNil(cachedFrame)
  }

  func testHostedBarKeepsItsNativeInstanceAndKeyboardStateAcrossVisibilityChanges() async throws {
    let visibility = RootTabBarTestVisibility()
    let host = UIHostingController(rootView: RootTabBarTestHost(visibility: visibility))
    let context = try makeWindow(root: host)
    defer { closeWindow(context) }
    func height() -> CGFloat {
      host.sizeThatFits(in: CGSize(width: context.window.bounds.width, height: 200)).height
    }
    try await waitUntil { self.nativeBar(in: host.view) != nil && height() > 1 }
    let bar = try XCTUnwrap(nativeBar(in: host.view))
    // Observe production layout rather than wrapping the representable's
    // callback, which updateUIView is entitled to replace at any time.
    postKeyboard(frame: dockedFrame(in: context.window), screen: context.window.screen)
    try await waitUntil { height() < 1 }
    visibility.isVisible = false
    try await settleLayout(host.view)
    XCTAssertTrue(nativeBar(in: host.view) === bar)
    visibility.isVisible = true
    try await settleLayout(host.view)
    XCTAssertLessThan(height(), 1, "Returning to narrow layout must not reveal the bar over a keyboard.")
    XCTAssertTrue(nativeBar(in: host.view) === bar)

    postKeyboardHide(screen: context.window.screen)
    try await waitUntil { height() > 1 }
    XCTAssertTrue(nativeBar(in: host.view) === bar)
    postKeyboard(frame: dockedFrame(in: context.window), screen: context.window.screen)
    try await waitUntil { height() < 1 }
    visibility.isVisible = false
    try await settleLayout(host.view)
    // The mounted bar must also continue processing a keyboard dismissal while
    // its outer layout is hidden, so the next narrow layout becomes visible.
    postKeyboardHide(screen: context.window.screen)
    try await settleLayout(host.view)
    visibility.isVisible = true
    try await waitUntil { height() > 1 }
    XCTAssertTrue(nativeBar(in: host.view) === bar)
  }

  func testNativeKeyboardObserverHonorsGeometryLocalityAndLegacyNotifications() async throws {
    let controller = UIViewController()
    let context = try makeWindow(root: controller)
    defer { closeWindow(context) }
    let bar = RootNativeTabBar(frame: CGRect(x: 0, y: 0, width: 320, height: 49))
    controller.view.addSubview(bar)
    var changes: [Bool] = []
    bar.onKeyboardCoverageChanged = { changes.append($0) }

    postKeyboard(frame: dockedFrame(in: context.window), screen: context.window.screen)
    try await waitUntil { changes == [true] }
    postKeyboardHide(screen: context.window.screen, isLocal: false)
    // A non-screen object cannot clear the attached screen's keyboard state.
    postKeyboardHide(screen: NSObject())
    try await settleLayout(controller.view)
    XCTAssertEqual(changes, [true])

    let floating = CGRect(x: 20, y: 50, width: 200, height: 100)
    postKeyboard(
      frame: context.window.convert(floating, to: context.window.screen.coordinateSpace),
      screen: context.window.screen)
    try await waitUntil { changes == [true, false] }
    let outsideWindow = CGRect(
      x: context.window.bounds.maxX + 100,
      y: context.window.bounds.maxY - 120, width: 200, height: 120)
    postKeyboard(
      frame: context.window.convert(outsideWindow, to: context.window.screen.coordinateSpace),
      screen: context.window.screen)
    postKeyboard(frame: dockedFrame(in: context.window), screen: context.window.screen, isLocal: false)
    try await settleLayout(controller.view)
    XCTAssertEqual(changes, [true, false])

    postKeyboard(frame: dockedFrame(in: context.window), screen: nil)
    try await waitUntil { changes == [true, false, true] }
    postKeyboardHide(screen: nil)
    try await waitUntil { changes == [true, false, true, false] }
  }

  func testNativeKeyboardObserverDropsSupersededWindowCallbacks() async throws {
    let controller = UIViewController()
    let context = try makeWindow(root: controller)
    defer { closeWindow(context) }
    let bar = RootNativeTabBar(frame: CGRect(x: 0, y: 0, width: 320, height: 49))
    controller.view.addSubview(bar)
    var changes: [Bool] = []
    bar.onKeyboardCoverageChanged = { changes.append($0) }
    postKeyboard(frame: dockedFrame(in: context.window), screen: context.window.screen)
    try await waitUntil { changes == [true] }

    // All three moves occur before deferred SwiftUI callbacks can run. A bool
    // equality check would accept both old and new `false` callbacks here.
    bar.removeFromSuperview()
    controller.view.addSubview(bar)
    bar.removeFromSuperview()
    try await waitUntil { changes.count >= 2 }
    try await settleLayout(controller.view)
    XCTAssertEqual(changes, [true, false])

    var replacementChanges: [Bool] = []
    bar.onKeyboardCoverageChanged = { replacementChanges.append($0) }
    controller.view.addSubview(bar)
    try await waitUntil { replacementChanges == [true] }
    XCTAssertEqual(changes, [true, false])
    postKeyboardHide(screen: context.window.screen)
    try await waitUntil { replacementChanges == [true, false] }
  }

  func testNativeKeyboardForAnotherWindowDoesNotCoverThisWindow() async throws {
    let firstController = UIViewController()
    let context = try makeWindow(root: firstController)
    defer { closeWindow(context) }
    let scene = try XCTUnwrap(context.window.windowScene)
    let bounds = scene.coordinateSpace.bounds
    let halfWidth = bounds.width / 2
    context.window.frame = CGRect(
      x: bounds.minX, y: bounds.minY, width: halfWidth, height: bounds.height)
    firstController.view.frame = context.window.bounds

    let secondController = UIViewController()
    let secondWindow = UIWindow(windowScene: scene)
    secondWindow.frame = CGRect(
      x: bounds.minX + halfWidth, y: bounds.minY, width: halfWidth, height: bounds.height)
    secondWindow.rootViewController = secondController
    secondWindow.isHidden = false
    secondController.view.frame = secondWindow.bounds
    defer {
      secondWindow.isHidden = true
      secondWindow.rootViewController = nil
    }
    let firstBar = RootNativeTabBar(frame: CGRect(x: 0, y: 0, width: halfWidth, height: 49))
    let secondBar = RootNativeTabBar(frame: CGRect(x: 0, y: 0, width: halfWidth, height: 49))
    firstController.view.addSubview(firstBar)
    secondController.view.addSubview(secondBar)
    var firstChanges: [Bool] = []
    var secondChanges: [Bool] = []
    firstBar.onKeyboardCoverageChanged = { firstChanges.append($0) }
    secondBar.onKeyboardCoverageChanged = { secondChanges.append($0) }

    // Both observers receive the same real screen notification. Conversion
    // into each UIWindow must hide only the window intersecting the keyboard.
    postKeyboard(frame: dockedFrame(in: secondWindow), screen: secondWindow.screen)
    try await waitUntil { secondChanges == [true] }
    try await settleLayout(firstController.view)
    XCTAssertTrue(firstChanges.isEmpty)
    postKeyboardHide(screen: secondWindow.screen)
    try await waitUntil { secondChanges == [true, false] }
    XCTAssertTrue(firstChanges.isEmpty)
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

  private func makeWindow(root: UIViewController) throws -> RootTabBarTestWindow {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive },
      "Keyboard integration tests require the native hosted test application.")
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.frame = window.bounds
    root.view.layoutIfNeeded()
    return RootTabBarTestWindow(window: window, previousKeyWindow: previousKeyWindow)
  }

  private func closeWindow(_ context: RootTabBarTestWindow) {
    postKeyboardHide(screen: context.window.screen)
    context.window.isHidden = true
    context.window.rootViewController = nil
    context.previousKeyWindow?.makeKey()
  }

  private func nativeBar(in view: UIView) -> RootNativeTabBar? {
    if let bar = view as? RootNativeTabBar { return bar }
    return view.subviews.lazy.compactMap { self.nativeBar(in: $0) }.first
  }

  private func dockedFrame(in window: UIWindow) -> CGRect {
    window.convert(
      CGRect(x: 0, y: window.bounds.maxY - 160, width: window.bounds.width, height: 160),
      to: window.screen.coordinateSpace)
  }

  private func postKeyboard(frame: CGRect, screen: Any?, isLocal: Bool = true) {
    NotificationCenter.default.post(
      name: UIResponder.keyboardWillChangeFrameNotification, object: screen,
      userInfo: [
        UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
        UIResponder.keyboardIsLocalUserInfoKey: isLocal,
      ])
  }

  private func postKeyboardHide(screen: Any?, isLocal: Bool = true) {
    NotificationCenter.default.post(
      name: UIResponder.keyboardWillHideNotification, object: screen,
      userInfo: [UIResponder.keyboardIsLocalUserInfoKey: isLocal])
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the native tab bar's layout or keyboard callback.")
    throw RootTabBarTestError.timeout
  }

  private func settleLayout(_ view: UIView) async throws {
    try await Task.sleep(for: .milliseconds(100))
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }
}

@MainActor
private final class RootTabBarTestVisibility: ObservableObject {
  @Published var isVisible = true
}

@MainActor
private struct RootTabBarTestHost: View {
  @ObservedObject var visibility: RootTabBarTestVisibility

  var body: some View {
    RootTabBar(
      isVisible: visibility.isVisible,
      selectedTab: .home, showsExploreTab: true, notificationBadge: nil,
      allowsExploreRefresh: false, allowsHomeRefresh: false, onSelect: { _ in })
  }
}

@MainActor
private struct RootTabBarTestWindow {
  let window: UIWindow
  let previousKeyWindow: UIWindow?
}

private enum RootTabBarTestError: Error {
  case timeout
}
