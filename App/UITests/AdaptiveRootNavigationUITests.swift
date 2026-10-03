import UIKit
import XCTest

/// The same production RootView is resized inside an actual iPad window. Only
/// the DEBUG service/storage boundaries and surrounding size controls are fake.
final class AdaptiveRootNavigationUITests: XCTestCase {
  private let interfaceTimeout: TimeInterval = 20

  @MainActor
  func testContainerThresholdsAndRotationKeepPushedExploreAndRefreshSemantics() throws {
    let app = try launchFixture()
    defer { finish(app) }
    try requireTitle("推荐·第1次", app: app)
    try requireMode("bottom", app: app)
    try tap(app.buttons["打开主题 推荐·第1次"].firstMatch)
    try requireThread(app)
    try requireCounts(personalized: 1, posts: 1, app: app)

    for (width, mode) in [
      (599, "bottom"), (600, "rail"), (839, "rail"),
      (840, "sidebar"), (1024, "sidebar"), (390, "bottom"),
    ] {
      try setWidth(width, mode: mode, app: app)
      try requireThread(app)
      try requireUnchangedCounts(personalized: 1, posts: 1, app: app)
      try tap(tab("explore", mode: mode, app: app))
      try requireThread(app)
      try requireUnchangedCounts(personalized: 1, posts: 1, app: app)
    }

    try setWidth(0, mode: "sidebar", app: app)
    attach("iPad landscape sidebar and retained thread", app: app)
    XCUIDevice.shared.orientation = .portrait
    try wait(NSPredicate { _, _ in app.frame.height > app.frame.width }, element: app)
    try requireMode("rail", app: app)
    try requireThread(app)
    attach("iPad portrait rail and retained thread", app: app)
    XCUIDevice.shared.orientation = .landscapeLeft
    try wait(NSPredicate { _, _ in app.frame.width > app.frame.height }, element: app)
    try requireMode("sidebar", app: app)
    try requireUnchangedCounts(personalized: 1, posts: 1, app: app)

    try tap(app.navigationBars.buttons.element(boundBy: 0))
    try requireTitle("推荐·第1次", app: app)
    try tap(tab("explore", mode: "sidebar", app: app))
    try requireTitle("推荐·第2次", app: app)
    try requireCounts(personalized: 2, posts: 1, app: app)
    try setWidth(390, mode: "bottom", app: app)
    try tap(tab("explore", mode: "bottom", app: app))
    try requireTitle("推荐·第3次", app: app)
    try requireUnchangedCounts(personalized: 3, posts: 1, app: app)
  }

  @MainActor
  func testAllTabPathsBadgeHiddenExploreAndLargeTextSurviveLayoutChanges() throws {
    let app = try launchFixture()
    defer { finish(app) }
    try requireTitle("推荐·第1次", app: app)
    try setWidth(840, mode: "sidebar", app: app)
    try tap(tab("home", mode: "sidebar", app: app))
    // Home owns the initial unread read. Wait for it before pushing Settings,
    // which deliberately suspends Home's root-only automatic reads.
    try wait(
      NSPredicate(format: "value == %@", "7"),
      element: tab("notifications", mode: "sidebar", app: app))
    try tap(app.buttons["home-settings-entry"])
    try requireNavigationTitle("设置", app: app)
    try wait(
      NSPredicate(format: "value == %@", "7"),
      element: tab("notifications", mode: "sidebar", app: app))

    try tap(tab("explore", mode: "sidebar", app: app))
    try tap(app.buttons["打开主题 推荐·第1次"].firstMatch)
    try requireThread(app)
    try tap(tab("notifications", mode: "sidebar", app: app))
    try requireNavigationTitle("消息", app: app)
    try tap(app.navigationBars.buttons["搜索"])
    try requireNavigationTitle("搜索", app: app)
    // Empty Search intentionally focuses on each appearance. Submit a local
    // query and leave search focus so subsequent narrow-tab switches can use
    // the visible bottom bar; keyboard persistence has its own test below.
    let inboxSearch = app.searchFields.firstMatch
    try tap(inboxSearch)
    inboxSearch.typeText("navigation\n")
    try tap(app.buttons["取消"].firstMatch)
    try wait(NSPredicate(format: "exists == false"), element: app.keyboards.firstMatch)
    try requireNavigationTitle("navigation", app: app)
    try tap(tab("account", mode: "sidebar", app: app))
    try requireNavigationTitle("我的", app: app)
    let history = app.buttons["account-hub-history"]
    for _ in 0..<5 {
      if history.isHittable { break }
      app.collectionViews.firstMatch.swipeUp()
    }
    try tap(history)
    try requireNavigationTitle("浏览记录", app: app)

    for (width, mode) in [(600, "rail"), (390, "bottom"), (840, "sidebar")] {
      try setWidth(width, mode: mode, app: app)
      try requireNavigationTitle("浏览记录", app: app)
      try tap(tab("notifications", mode: mode, app: app))
      try requireNavigationTitle("navigation", app: app)
      try tap(tab("home", mode: mode, app: app))
      try requireNavigationTitle("设置", app: app)
      try tap(tab("explore", mode: mode, app: app))
      try requireThread(app)
      try tap(tab("account", mode: mode, app: app))
      try requireNavigationTitle("浏览记录", app: app)
      try requireUnchangedCounts(personalized: 1, posts: 1, app: app)
    }

    try tap(app.buttons["adaptive-toggle-text"])
    try requireMode("sidebar", app: app)
    for name in ["home", "explore", "notifications", "account"] {
      try requireHittable(tab(name, mode: "sidebar", app: app))
    }
    attach("iPad sidebar accessibility text and unread badge", app: app)
    try tap(app.buttons["adaptive-toggle-text"])

    // Visibility follows the existing product rule. Do not require Explore's
    // removed navigation stack to survive hiding and recreating that tab.
    try tap(tab("home", mode: "sidebar", app: app))
    try tap(app.buttons["adaptive-toggle-explore"])
    try wait(
      NSPredicate { _, _ in
        !app.buttons["root-side-tab-explore"].exists
      }, element: app)
    try requireNavigationTitle("设置", app: app)
    try setWidth(390, mode: "bottom", app: app)
    XCTAssertFalse(app.buttons["root-tab-explore"].exists)
    for name in ["home", "notifications", "account"] {
      try requireHittable(tab(name, mode: "bottom", app: app))
    }
    try tap(app.buttons["adaptive-toggle-explore"])
    try requireHittable(tab("explore", mode: "bottom", app: app))
    try setWidth(840, mode: "sidebar", app: app)
    try requireHittable(tab("explore", mode: "sidebar", app: app))
    try requireNavigationTitle("设置", app: app)
    try wait(
      NSPredicate(format: "value == %@", "7"),
      element: tab("notifications", mode: "sidebar", app: app))
  }

  @MainActor
  func testKeyboardStaysAttachedAcrossWideAndNarrowLayouts() throws {
    let app = try launchFixture()
    defer { finish(app) }
    try requireTitle("推荐·第1次", app: app)
    try setWidth(840, mode: "sidebar", app: app)
    try tap(tab("home", mode: "sidebar", app: app))
    let search = app.textFields["输入吧名或关键词"]
    try tap(search)
    try wait(NSPredicate(format: "exists == true"), element: app.keyboards.firstMatch)
    search.typeText("fixture")

    for (width, mode) in [(390, "bottom"), (600, "rail"), (840, "sidebar"), (390, "bottom")] {
      try tap(app.buttons["adaptive-width-\(width)"])
      try requireModeValue(mode, app: app)
      try wait(NSPredicate(format: "exists == true"), element: app.keyboards.firstMatch)
      XCTAssertEqual(search.value as? String, "fixture")
      if mode == "bottom" {
        try wait(
          NSPredicate { _, _ in
            !app.buttons["root-tab-home"].isHittable
          }, element: app)
        XCTAssertFalse(app.buttons["root-tab-explore"].isHittable)
      } else {
        try requireHittable(tab("home", mode: mode, app: app))
      }
    }
    attach("Narrow root keeps keyboard and hides bottom bar", app: app)
    search.typeText("\n")
    try wait(NSPredicate(format: "exists == false"), element: app.keyboards.firstMatch)
    try requireMode("bottom", app: app)
    try requireNavigationTitle("fixture", app: app)
    try requireUnchangedCounts(personalized: 1, posts: 0, app: app)
  }

  @MainActor
  private func launchFixture() throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--adaptive-root-ui-testing",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    try wait(NSPredicate { _, _ in app.frame.width > app.frame.height }, element: app)
    return app
  }

  @MainActor
  private func tab(_ name: String, mode: String, app: XCUIApplication) -> XCUIElement {
    app.buttons[mode == "bottom" ? "root-tab-\(name)" : "root-side-tab-\(name)"]
  }

  @MainActor
  private func setWidth(_ width: Int, mode: String, app: XCUIApplication) throws {
    try tap(app.buttons["adaptive-width-\(width)"])
    try requireMode(mode, app: app)
  }

  @MainActor
  private func requireModeValue(_ mode: String, app: XCUIApplication) throws {
    let marker = app.descendants(matching: .any)
      .matching(identifier: "root-navigation-layout").firstMatch
    try wait(NSPredicate(format: "exists == true AND value == %@", mode), element: marker)
  }

  @MainActor
  private func requireMode(_ mode: String, app: XCUIApplication) throws {
    try requireModeValue(mode, app: app)
    if mode == "bottom" {
      try requireHittable(app.buttons["root-tab-home"])
      XCTAssertFalse(app.buttons["root-side-tab-home"].isHittable)
      let bars = app.tabBars.allElementsBoundByIndex.filter { $0.isHittable }
      XCTAssertEqual(bars.count, 1)
    } else {
      try requireHittable(app.buttons["root-side-tab-home"])
      XCTAssertFalse(app.buttons["root-tab-home"].isHittable)
      let side = app.descendants(matching: .any)
        .matching(identifier: "root-side-navigation").firstMatch
      try wait(NSPredicate(format: "exists == true"), element: side)
      XCTAssertEqual(side.frame.width, mode == "rail" ? 80 : 240, accuracy: 1)
      let navigation = app.navigationBars.firstMatch
      try wait(
        NSPredicate { _, _ in
          navigation.exists && navigation.frame.minX >= side.frame.maxX - 1
            && navigation.frame.maxX <= app.frame.maxX + 1
        }, element: navigation)
    }
  }

  @MainActor
  private func requireTitle(_ title: String, app: XCUIApplication) throws {
    try requireHittable(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch)
  }

  @MainActor
  private func requireThread(_ app: XCUIApplication) throws {
    try requireHittable(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "离线帖子正文")).firstMatch)
  }

  @MainActor
  private func requireNavigationTitle(_ title: String, app: XCUIApplication) throws {
    try wait(NSPredicate(format: "exists == true"), element: app.navigationBars[title])
  }

  private func counts(personalized: Int, posts: Int) -> String {
    "concern=0 personalized=\(personalized) hot=0 posts=\(posts)"
  }

  @MainActor
  private func requireCounts(personalized: Int, posts: Int, app: XCUIApplication) throws {
    try wait(
      NSPredicate(format: "label == %@", counts(personalized: personalized, posts: posts)),
      element: app.staticTexts["explore-refresh-request-counts"])
  }

  @MainActor
  private func requireUnchangedCounts(personalized: Int, posts: Int, app: XCUIApplication) throws {
    try requireCounts(personalized: personalized, posts: posts, app: app)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "label != %@", counts(personalized: personalized, posts: posts)),
      object: app.staticTexts["explore-refresh-request-counts"])
    expectation.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 0.5), .completed)
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try requireHittable(element)
    element.tap()
  }

  @MainActor
  private func requireHittable(_ element: XCUIElement) throws {
    try wait(
      NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
      element: element)
  }

  @MainActor
  private func wait(_ predicate: NSPredicate, element: XCUIElement) throws {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    guard XCTWaiter.wait(for: [expectation], timeout: interfaceTimeout) == .completed else {
      throw AdaptiveRootUITestError.unavailable(
        "Timed out: \(predicate), \(element.debugDescription)")
    }
  }

  @MainActor
  private func finish(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Adaptive root final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    attach("Adaptive root final screen", app: app)
    XCUIDevice.shared.orientation = .portrait
  }

  @MainActor
  private func attach(_ name: String, app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum AdaptiveRootUITestError: Error {
  case unavailable(String)
}
