import UIKit
import XCTest

/// These tests launch the production RootView/ExploreView and feed view models.
/// Only account, storage and network boundaries are replaced by DEBUG fixtures.
final class ExploreRefreshUITests: XCTestCase {
  private let interfaceTimeout: TimeInterval = 20

  @MainActor
  func testReselectingEachChannelAndNativeExploreTabRefreshesOnlyCurrentFeed() throws {
    let app = launchFixture()
    defer { attachFinalState(app) }
    try requireTitle("推荐·第1次", app: app)
    try requireCounts(concern: 0, personalized: 1, hot: 0, app: app)

    try tap(app.buttons["explore-channel-personalized"], app: app)
    try requireTitle("推荐·第2次", app: app)
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("推荐·第3次", app: app)
    try requireCounts(concern: 0, personalized: 3, hot: 0, app: app)

    try tap(app.buttons["explore-channel-concern"], app: app)
    try requireTitle("关注·第1次", app: app)
    try tap(app.buttons["explore-channel-concern"], app: app)
    try requireTitle("关注·第2次", app: app)
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("关注·第3次", app: app)
    try requireCounts(concern: 3, personalized: 3, hot: 0, app: app)

    try tap(app.buttons["explore-channel-hot"], app: app)
    try requireTitle("热门·第1次", app: app)
    try tap(app.buttons["explore-channel-hot"], app: app)
    try requireTitle("热门·第2次", app: app)
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("热门·第3次", app: app)
    try requireCounts(concern: 3, personalized: 3, hot: 3, app: app)

    // Changing to an already loaded channel is not another refresh request.
    try tap(app.buttons["explore-channel-personalized"], app: app)
    try requireTitle("推荐·第3次", app: app)
    try requireUnchangedCounts(concern: 3, personalized: 3, hot: 3, app: app)

    try tap(app.buttons["root-tab-home"], app: app)
    try waitForHittable(app.buttons["home-explore-entry"])
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("推荐·第3次", app: app)
    try requireUnchangedCounts(concern: 3, personalized: 3, hot: 3, app: app)

    // Home's shortcut explicitly creates a new Explore activation. That existing
    // behavior loads once; programmatic tab selection must not add a re-tap load.
    try tap(app.buttons["root-tab-home"], app: app)
    try tap(app.buttons["home-explore-entry"], app: app)
    try requireTitle("推荐·第4次", app: app)
    try requireUnchangedCounts(concern: 3, personalized: 4, hot: 3, app: app)
  }

  @MainActor
  func testExploreRetapAndTabSwitchPreservePushedThreadUntilBack() throws {
    let app = launchFixture()
    defer { attachFinalState(app) }
    try requireTitle("推荐·第1次", app: app)
    try tap(app.buttons["打开主题 推荐·第1次"].firstMatch, app: app)
    try requireThreadBody(app)
    try requireCounts(concern: 0, personalized: 1, hot: 0, posts: 1, app: app)

    try tap(app.buttons["root-tab-explore"], app: app)
    try requireThreadBody(app)
    try requireUnchangedCounts(concern: 0, personalized: 1, hot: 0, posts: 1, app: app)

    try tap(app.buttons["root-tab-home"], app: app)
    try waitForHittable(app.buttons["home-explore-entry"])
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireThreadBody(app)
    try requireUnchangedCounts(concern: 0, personalized: 1, hot: 0, posts: 1, app: app)

    try tap(app.navigationBars.buttons.element(boundBy: 0), app: app)
    try waitForHittable(app.buttons["explore-channel-personalized"])
    try requireTitle("推荐·第1次", app: app)
    try requireUnchangedCounts(concern: 0, personalized: 1, hot: 0, posts: 1, app: app)
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("推荐·第2次", app: app)
    try requireCounts(concern: 0, personalized: 2, hot: 0, posts: 1, app: app)
  }

  @MainActor
  func testSingleNativeBarRotatesAndHidesWhileHomeKeyboardIsVisible() throws {
    let app = launchFixture()
    defer {
      attachFinalState(app)
      XCUIDevice.shared.orientation = .portrait
    }
    try requireTitle("推荐·第1次", app: app)
    try requireSingleBarInsideWindow(app)
    attachScreenshot("Explore portrait native bar", app: app)

    XCUIDevice.shared.orientation = .landscapeLeft
    try wait(NSPredicate { _, _ in app.frame.width > app.frame.height }, element: app)
    try requireSingleBarInsideWindow(app)
    attachScreenshot("Explore landscape native bar", app: app)
    try tap(app.buttons["root-tab-explore"], app: app)
    try requireTitle("推荐·第2次", app: app)

    XCUIDevice.shared.orientation = .portrait
    try wait(NSPredicate { _, _ in app.frame.height > app.frame.width }, element: app)
    try tap(app.buttons["root-tab-home"], app: app)
    let search = app.textFields["输入吧名或关键词"]
    try tap(search, app: app)
    try wait(NSPredicate(format: "exists == true"), element: app.keyboards.firstMatch)
    try wait(
      NSPredicate { _, _ in !app.buttons["root-tab-home"].isHittable }, element: app)
    XCTAssertFalse(app.buttons["root-tab-explore"].isHittable)
    attachScreenshot("Home keyboard hides native bar", app: app)

    search.typeText("fixture\n")
    try wait(NSPredicate(format: "exists == false"), element: app.keyboards.firstMatch)
    try requireSingleBarInsideWindow(app)
    attachScreenshot("Native bar restored after search submission", app: app)
    try requireUnchangedCounts(concern: 0, personalized: 2, hot: 0, app: app)
  }

  @MainActor
  private func launchFixture() -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing",
    ]
    app.launch()
    return app
  }

  @MainActor
  private func requireTitle(_ title: String, app: XCUIApplication) throws {
    // The actual ThreadSummaryRow is a button; its accessibility label can
    // combine title/excerpt or explicitly say "打开主题 <title>".
    let element = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    try waitForHittable(element)
  }

  @MainActor
  private func requireThreadBody(_ app: XCUIApplication) throws {
    let body = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "离线帖子正文")).firstMatch
    try waitForHittable(body)
    XCTAssertFalse(app.buttons["explore-channel-personalized"].isHittable)
  }

  @MainActor
  private func requireCounts(
    concern: Int, personalized: Int, hot: Int, posts: Int = 0, app: XCUIApplication
  ) throws {
    try wait(
      NSPredicate(
        format: "exists == true AND label == %@",
        counts(concern: concern, personalized: personalized, hot: hot, posts: posts)),
      element: app.staticTexts["explore-refresh-request-counts"])
  }

  @MainActor
  private func requireUnchangedCounts(
    concern: Int, personalized: Int, hot: Int, posts: Int = 0, app: XCUIApplication
  ) throws {
    try requireCounts(
      concern: concern, personalized: personalized, hot: hot, posts: posts, app: app)
    let noExtraRequest = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "label != %@",
        counts(concern: concern, personalized: personalized, hot: hot, posts: posts)),
      object: app.staticTexts["explore-refresh-request-counts"])
    noExtraRequest.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [noExtraRequest], timeout: 0.75), .completed)
  }

  private func counts(concern: Int, personalized: Int, hot: Int, posts: Int) -> String {
    "concern=\(concern) personalized=\(personalized) hot=\(hot) posts=\(posts)"
  }

  @MainActor
  private func requireSingleBarInsideWindow(_ app: XCUIApplication) throws {
    try waitForHittable(app.buttons["root-tab-explore"])
    let bar = app.tabBars["root-tab-bar"]
    try wait(
      NSPredicate { _, _ in
        guard bar.exists else { return false }
        let frame = bar.frame
        let window = app.frame
        return frame.width > 200 && frame.height >= 24 && frame.height <= 65
          && frame.minX >= window.minX - 1 && frame.maxX <= window.maxX + 1
          && frame.maxY <= window.maxY + 1 && window.maxY - frame.maxY <= 50
      }, element: bar)
    let visibleBars = app.tabBars.allElementsBoundByIndex.filter { $0.isHittable }
    XCTAssertEqual(visibleBars.count, 1, "Only one native tab bar should be visible")
    XCTAssertEqual(visibleBars.first?.identifier, "root-tab-bar")
  }

  @MainActor
  private func tap(_ element: XCUIElement, app: XCUIApplication) throws {
    try waitForHittable(element)
    element.tap()
  }

  @MainActor
  private func waitForHittable(_ element: XCUIElement) throws {
    try wait(NSPredicate(format: "exists == true AND hittable == true"), element: element)
  }

  @MainActor
  private func wait(_ predicate: NSPredicate, element: XCUIElement) throws {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    guard XCTWaiter.wait(for: [expectation], timeout: interfaceTimeout) == .completed else {
      throw ExploreRefreshUITestError.unavailable(
        "Timed out: \(predicate), element: \(element.debugDescription)")
    }
  }

  @MainActor
  private func attachFinalState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Explore refresh final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    attachScreenshot("Explore refresh final state", app: app)
  }

  @MainActor
  private func attachScreenshot(_ name: String, app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum ExploreRefreshUITestError: Error {
  case unavailable(String)
}
