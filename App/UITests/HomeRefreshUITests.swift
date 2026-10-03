import UIKit
import XCTest

/// Exercises the real RootView, native tab bar and account-scoped Home models.
/// The DEBUG fixture replaces storage and services without any live transport.
final class HomeRefreshUITests: XCTestCase {
  private let interfaceTimeout: TimeInterval = 20

  @MainActor
  func testHomeRetapRefreshesCompleteCatalogAndPreservesNavigationOnOtherSelections() throws {
    let app = launchFixture()
    defer { attachFinalState(app) }
    try requireCounts(generation: 1, app: app)
    try requireForums(generation: 1, app: app)

    try tap(app.buttons["root-tab-home"])
    try requireCounts(generation: 2, app: app)
    try requireForums(generation: 2, app: app)

    // An ordinary tab switch retains Home's already loaded complete catalog.
    try tap(app.buttons["root-tab-explore"])
    try waitForHittable(app.buttons["explore-channel-personalized"])
    try tap(app.buttons["root-tab-home"])
    try requireForums(generation: 2, app: app)
    try requireUnchangedCounts(generation: 2, app: app)

    // Re-tapping Home while its stack is pushed must not refresh or pop it.
    try tap(app.buttons["home-settings-entry"])
    let settingsCategory = app.descendants(matching: .any)
      .matching(identifier: "settings-category-appearance-and-layout").firstMatch
    try waitForHittable(settingsCategory)
    try tap(app.buttons["root-tab-home"])
    try waitForHittable(settingsCategory)
    XCTAssertTrue(app.navigationBars["设置"].exists)
    try requireUnchangedCounts(generation: 2, app: app)

    try tap(app.buttons["root-tab-explore"])
    try waitForHittable(app.buttons["explore-channel-personalized"])
    try tap(app.buttons["root-tab-home"])
    try waitForHittable(settingsCategory)
    XCTAssertTrue(app.navigationBars["设置"].exists)
    try requireUnchangedCounts(generation: 2, app: app)

    try tap(app.navigationBars["设置"].buttons.element(boundBy: 0))
    try waitForHittable(app.buttons["home-settings-entry"])
    try requireUnchangedCounts(generation: 2, app: app)
    try tap(app.buttons["root-tab-home"])
    try requireCounts(generation: 3, app: app)
    try requireForums(generation: 3, app: app)
    try requireUnchangedCounts(generation: 3, app: app)
  }

  @MainActor
  func testSignedOutHomeRetapDoesNotReadFollowedForumsOrCheckInCatalog() throws {
    let app = launchFixture(signedOut: true)
    defer { attachFinalState(app) }
    try waitForHittable(app.buttons["home-settings-entry"])
    try requireUnchangedCounts(generation: 0, app: app)
    try tap(app.buttons["root-tab-home"])
    try requireUnchangedCounts(generation: 0, app: app)

    try tap(app.buttons["root-tab-explore"])
    try waitForHittable(app.buttons["explore-channel-personalized"])
    try tap(app.buttons["root-tab-home"])
    try waitForHittable(app.buttons["home-settings-entry"])
    try tap(app.buttons["root-tab-home"])
    try requireUnchangedCounts(generation: 0, app: app)
    XCTAssertFalse(app.buttons["离线首页甲吧"].exists)
    XCTAssertFalse(app.buttons["离线首页乙吧"].exists)
  }

  @MainActor
  private func launchFixture(signedOut: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--home-refresh-ui-testing",
    ]
    if signedOut { app.launchArguments.append("--home-refresh-signed-out") }
    app.launch()
    return app
  }

  @MainActor
  private func requireForums(generation: Int, app: XCUIApplication) throws {
    for (page, name) in [(1, "离线首页甲吧"), (2, "离线首页乙吧")] {
      let card = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
      try wait(NSPredicate(format: "exists == true"), element: card)
      for _ in 0..<4 {
        if card.isHittable { break }
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.tabBars["root-tab-bar"].frame.minY - 8
        let center = (top + bottom) / 2
        let limit = (bottom - top) * 0.4
        let distance = min(limit, max(-limit, center - card.frame.midY))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: center - distance / 2))
        let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: center + distance / 2))
        // Use a bounded drag in either direction. A flick or an unconditional
        // downward swipe can accidentally invoke Home's pull-to-refresh.
        start.press(
          forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
      }
      try waitForHittable(card)
      try wait(
        NSPredicate(format: "value CONTAINS %@", "首页第\(generation)轮·第\(page)页"),
        element: card)
    }
  }

  private func counts(generation: Int) -> String {
    "page1=\(generation) page2=\(generation) catalog=\(generation) unexpected=0"
  }

  @MainActor
  private func requireCounts(generation: Int, app: XCUIApplication) throws {
    try wait(
      NSPredicate(format: "exists == true AND label == %@", counts(generation: generation)),
      element: app.staticTexts["home-refresh-request-counts"])
  }

  @MainActor
  private func requireUnchangedCounts(generation: Int, app: XCUIApplication) throws {
    try requireCounts(generation: generation, app: app)
    let noAdditionalReads = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", counts(generation: generation)),
      object: app.staticTexts["home-refresh-request-counts"])
    noAdditionalReads.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [noAdditionalReads], timeout: 0.75), .completed)
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try waitForHittable(element)
    element.tap()
  }

  @MainActor
  private func waitForHittable(_ element: XCUIElement) throws {
    guard element.waitForExistence(timeout: interfaceTimeout) else {
      throw HomeRefreshUITestError.unavailable("Missing element: \(element.debugDescription)")
    }
    try wait(NSPredicate(format: "hittable == true AND enabled == true"), element: element)
  }

  @MainActor
  private func wait(_ predicate: NSPredicate, element: XCUIElement) throws {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    guard XCTWaiter.wait(for: [expectation], timeout: interfaceTimeout) == .completed else {
      throw HomeRefreshUITestError.unavailable(
        "Timed out: \(predicate), element: \(element.debugDescription)")
    }
  }

  @MainActor
  private func attachFinalState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Home refresh final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Home refresh final state"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum HomeRefreshUITestError: Error {
  case unavailable(String)
}
