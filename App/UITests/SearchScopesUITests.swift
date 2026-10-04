import UIKit
import XCTest

/// Exercises the production SearchView, its native Lists and navigation through
/// an offline service. The fixture does not initialize live transport or Keychain.
final class SearchScopesUITests: XCTestCase {
  @MainActor
  func testThreeScopesRetainPositionsAcrossTapsSwipesAndDetailReturn() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    var positions: [Scope: (String, CGFloat)] = [:]
    for scope in Scope.allCases {
      try select(scope, app: app)
      try requireTitle(scope.firstTitle, app: app)
      scrollUp(app)
      scrollUp(app)
      let anchor = try visibleTitle(prefix: scope.titlePrefix, app: app)
      positions[scope] = (anchor.label, anchor.frame.minY)
    }
    try counts("forums=1 threads=1 users=1 posts=0 unexpected=0", app: app)

    for scope in [Scope.forums, .users, .threads, .forums, .threads] {
      try select(scope, app: app)
      let saved = try XCTUnwrap(positions[scope])
      try position(title: saved.0, y: saved.1, context: "Retained \(scope.rawValue)", app: app)
    }
    let thread = try XCTUnwrap(positions[.threads])
    try tap(app.staticTexts[thread.0].firstMatch)
    try requireTitle("离线帖子正文", app: app)
    edgeBack(app)
    try position(title: thread.0, y: thread.1, context: "Search detail return", app: app)
    try counts("forums=1 threads=1 users=1 posts=1 unexpected=0", app: app)

    swipeLeft(app)
    let user = try XCTUnwrap(positions[.users])
    try position(title: user.0, y: user.1, context: "Swipe from threads to users", app: app)
    try counts("forums=1 threads=1 users=1 posts=1 unexpected=0", app: app)
    edgeBack(app)
    try wait("System edge gesture pops the search page") {
      app.navigationBars["离线搜索入口"].exists
    }
  }

  @MainActor
  func testThreadPaginationAndSortLeaveOtherScopesAtTheirPositions() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    scrollUp(app)
    scrollUp(app)
    let forum = try visibleTitle(prefix: Scope.forums.titlePrefix, app: app)
    let forumPosition = (forum.label, forum.frame.minY)
    try select(.users, app: app)
    try requireTitle(Scope.users.firstTitle, app: app)
    scrollUp(app)
    scrollUp(app)
    let user = try visibleTitle(prefix: Scope.users.titlePrefix, app: app)
    let userPosition = (user.label, user.frame.minY)
    try select(.threads, app: app)
    try requireTitle(Scope.threads.firstTitle, app: app)

    let secondPage = app.staticTexts["测试·最新·帖子21"].firstMatch
    for _ in 0..<25 {
      if fullyVisible(secondPage, app: app) { break }
      scrollUp(app)
    }
    try wait("Second thread page becomes visible") { self.fullyVisible(secondPage, app: app) }
    let anchor = try visibleTitle(prefix: Scope.threads.titlePrefix, app: app)
    let threadPosition = (anchor.label, anchor.frame.minY)
    try counts("forums=1 threads=2 users=1 posts=0 unexpected=0", app: app)
    try select(.forums, app: app)
    try position(
      title: forumPosition.0, y: forumPosition.1, context: "Forums after thread pagination",
      app: app)
    try select(.threads, app: app)
    try position(
      title: threadPosition.0, y: threadPosition.1, context: "Retained second page", app: app)

    try tap(app.segmentedControls["global-thread-search-sort-picker"].buttons["相关"])
    try requireTitle("测试·相关·帖子1", app: app)
    try counts("forums=1 threads=3 users=1 posts=0 unexpected=0", app: app)
    try requests(
      [
        "forums:测试:1:none", "users:测试:1:none", "threads:测试:1:newest",
        "threads:测试:2:newest", "threads:测试:1:relevance",
      ], app: app)
    try select(.forums, app: app)
    try position(
      title: forumPosition.0, y: forumPosition.1, context: "Forums after thread sort", app: app)
    try select(.users, app: app)
    try position(
      title: userPosition.0, y: userPosition.1, context: "Users after thread sort", app: app)
    try counts("forums=1 threads=3 users=1 posts=0 unexpected=0", app: app)
  }

  @MainActor
  func testNewQueryResetsEveryScopeAndLoadsOnlyTheSelectedScope() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    for scope in Scope.allCases {
      try select(scope, app: app)
      try requireTitle(scope.firstTitle, app: app)
      scrollUp(app)
      scrollUp(app)
    }
    try counts("forums=1 threads=1 users=1 posts=0 unexpected=0", app: app)

    // Reveal and edit the real searchable field. No fixture control changes the
    // query, selected scope or List offset on behalf of the app under test.
    let search = app.searchFields.firstMatch
    for _ in 0..<8 {
      if search.isHittable { break }
      scrollDown(app)
    }
    try tap(search)
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
    search.typeText("next\n")
    try wait("Search submission dismisses the keyboard") { app.keyboards.count == 0 }
    try requireTitle("next·用户1", app: app)
    try counts("forums=1 threads=1 users=2 posts=0 unexpected=0", app: app)
    XCTAssertFalse(app.staticTexts["测试·用户1"].exists)

    try select(.forums, app: app)
    try requireTitle("next·贴吧1", app: app)
    try counts("forums=2 threads=1 users=2 posts=0 unexpected=0", app: app)
    try select(.threads, app: app)
    try requireTitle("next·最新·帖子1", app: app)
    try counts("forums=2 threads=2 users=2 posts=0 unexpected=0", app: app)
    try requests(
      [
        "forums:测试:1:none", "threads:测试:1:newest", "users:测试:1:none",
        "users:next:1:none", "forums:next:1:none", "threads:next:1:newest",
      ], app: app)
    try select(.users, app: app)
    try requireTitle("next·用户1", app: app)
    try counts("forums=2 threads=2 users=2 posts=0 unexpected=0", app: app)
  }

  private enum Scope: String, CaseIterable {
    case forums, threads, users

    var titlePrefix: String {
      switch self {
      case .forums: "测试·贴吧"
      case .threads: "测试·最新·帖子"
      case .users: "测试·用户"
      }
    }

    var firstTitle: String { "\(titlePrefix)1" }
  }

  @MainActor
  private func launchFixture() throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--search-scopes-ui-testing",
    ]
    app.launch()
    try tap(app.buttons["进入离线搜索"])
    try requireTitle(Scope.forums.firstTitle, app: app)
    try counts("forums=1 threads=0 users=0 posts=0 unexpected=0", app: app)
    return app
  }

  @MainActor
  private func select(_ scope: Scope, app: XCUIApplication) throws {
    try tap(app.buttons["search-scope-\(scope.rawValue)"])
  }

  @MainActor
  private func requireTitle(_ title: String, app: XCUIApplication) throws {
    let element = app.staticTexts[title].firstMatch
    try wait(
      "Visible title: \(title)", diagnostics: { element.debugDescription },
      until: { element.isHittable })
  }

  @MainActor
  private func fullyVisible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
    element.isHittable && element.frame.minY > app.frame.height * 0.35
      && element.frame.maxY < app.frame.height * 0.85
  }

  @MainActor
  private func visibleTitle(prefix: String, app: XCUIApplication) throws -> XCUIElement {
    let titles = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    var result: XCUIElement?
    try wait("Find a unique, fully visible \(prefix) anchor") {
      result = titles.allElementsBoundByIndex.first { self.fullyVisible($0, app: app) }
      return result != nil
    }
    return try XCTUnwrap(result)
  }

  @MainActor
  private func position(title: String, y: CGFloat, context: String, app: XCUIApplication) throws {
    let element = app.staticTexts[title].firstMatch
    try wait(
      context, diagnostics: { "expectedY=\(y), frame=\(element.frame)" },
      until: { element.isHittable && abs(element.frame.minY - y) < 3 })
  }

  @MainActor
  private func counts(_ expected: String, app: XCUIApplication) throws {
    let counter = app.staticTexts["search-scope-request-counts"]
    try wait(
      "Request counts", diagnostics: { "expected=\(expected), actual=\(counter.label)" },
      until: { counter.exists && counter.label == expected })
    let unchanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected), object: counter)
    unchanged.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 0.75), .completed)
  }

  @MainActor
  private func requests(_ expected: [String], app: XCUIApplication) throws {
    let log = app.staticTexts["search-scope-request-log"]
    XCTAssertEqual(log.label, expected.joined(separator: " | "))
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait(
      "Tap target", diagnostics: { element.debugDescription }, until: { element.isHittable })
    element.tap()
  }

  @MainActor
  private func scrollUp(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
  }

  @MainActor
  private func scrollDown(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
  }

  @MainActor
  private func swipeLeft(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65)))
  }

  @MainActor
  private func edgeBack(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55)))
  }

  @MainActor
  private func wait(
    _ context: String, diagnostics: @escaping () -> String = { "" },
    file: StaticString = #filePath, line: UInt = #line,
    until condition: @escaping () -> Bool
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      let message = "\(context). \(diagnostics())"
      XCTFail(message, file: file, line: line)
      throw SearchScopesUITestError.timedOut(message)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum SearchScopesUITestError: Error { case timedOut(String) }
