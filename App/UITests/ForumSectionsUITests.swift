import UIKit
import XCTest

/// Real ForumView/List/pager/navigation with offline read boundaries. No live
/// account or transport is initialized by this DEBUG-only launch route.
final class ForumSectionsUITests: XCTestCase {
  @MainActor
  func testFourSectionsRetainReadingPositionsAndDetailNavigation() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    let sections = [
      ("latest", "最新"), ("featured", "精华"),
      ("channel-71", "讨论"), ("channel-72", "图集"),
    ]
    var positions: [String: (String, CGFloat)] = [:]
    for (id, title) in sections {
      try tap(app.buttons["forum-section-\(id)"])
      try requireRow("\(title)·帖子1", app: app)
      scrollUp(app)
      scrollUp(app)
      let row = try visibleRow(prefix: title, app: app)
      positions[id] = (row.label, row.frame.minY)
    }
    try requireUnchangedCounts(
      "latest=1 featured=1 channel71=1 channel72=1 account=1 unexpected=0", app: app)

    for id in ["latest", "channel-72", "featured", "channel-71", "latest"] {
      try tap(app.buttons["forum-section-\(id)"])
      let saved = try XCTUnwrap(positions[id])
      let row = app.buttons.matching(NSPredicate(format: "label == %@", saved.0)).firstMatch
      try wait { row.isHittable && abs(row.frame.minY - saved.1) < 3 }
    }

    let saved = try XCTUnwrap(positions["latest"])
    let row = app.buttons.matching(NSPredicate(format: "label == %@", saved.0)).firstMatch
    try tap(row)
    let body = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "离线帖子正文")).firstMatch
    try wait { body.isHittable }
    // The system interactive pop must remain available alongside the horizontal
    // pager. A completed edge gesture returns to the same retained row.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
      .press(
        forDuration: 0.1,
        thenDragTo:
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55)))
    try wait { row.isHittable && abs(row.frame.minY - saved.1) < 3 }
    try requireUnchangedCounts(
      "latest=1 featured=1 channel71=1 channel72=1 account=1 unexpected=0", app: app)

    // Swiping in list content changes the selected section, while vertical
    // scrolling above and system edge-back below keep their native behaviors.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65))
      .press(
        forDuration: 0.1,
        thenDragTo:
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65)))
    let featured = try XCTUnwrap(positions["featured"])
    let featuredRow = app.buttons.matching(NSPredicate(format: "label == %@", featured.0))
      .firstMatch
    try wait { featuredRow.isHittable && abs(featuredRow.frame.minY - featured.1) < 3 }
    try requireUnchangedCounts(
      "latest=1 featured=1 channel71=1 channel72=1 account=1 unexpected=0", app: app)

    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
      .press(
        forDuration: 0.1,
        thenDragTo:
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55)))
    try wait { app.navigationBars["离线测试入口"].exists }
  }

  @MainActor
  func testChannelPaginationAndToolbarScrollToTopStaySectionLocal() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    try tap(app.buttons["forum-section-channel-71"])
    try requireRow("讨论·帖子1", app: app)
    let counts = app.staticTexts["forum-section-request-counts"]
    for _ in 0..<25 {
      if counts.label.contains("channel71=2") { break }
      scrollUp(app)
    }
    try requireCounts(
      "latest=1 featured=0 channel71=2 channel72=0 account=1 unexpected=0", app: app)
    // Request counters advance at dispatch. Wait for actual second-page rows
    // before measuring the retained position, rather than observing old rows
    // while the response is still being applied.
    let secondPageRow = app.buttons["打开主题 讨论·帖子31"].firstMatch
    for _ in 0..<6 {
      if secondPageRow.isHittable { break }
      scrollUp(app)
    }
    try wait { secondPageRow.isHittable }
    let row = try visibleRow(prefix: "讨论", app: app)
    let title = row.label
    let y = row.frame.minY
    try tap(app.buttons["forum-section-latest"])
    try requireRow("最新·帖子1", app: app)
    try tap(app.buttons["forum-section-channel-71"])
    let retained = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    try wait { retained.isHittable && abs(retained.frame.minY - y) < 3 }
    try tap(app.buttons["forum-primary-action-back_to_top"])
    try requireRow("讨论·帖子1", app: app)
    try requireUnchangedCounts(
      "latest=1 featured=0 channel71=2 channel72=0 account=1 unexpected=0", app: app)
  }

  @MainActor
  private func launchFixture() throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--forum-sections-ui-testing",
    ]
    app.launch()
    try tap(app.buttons["进入离线贴吧"])
    try requireRow("最新·帖子1", app: app)
    let checkInStatus = app.descendants(matching: .any)
      .matching(identifier: "forum-check-in-status").firstMatch
    try wait { checkInStatus.exists }
    try requireCounts(
      "latest=1 featured=0 channel71=0 channel72=0 account=1 unexpected=0", app: app)
    return app
  }

  @MainActor
  private func requireRow(_ title: String, app: XCUIApplication) throws {
    let row = app.buttons.matching(NSPredicate(format: "label == %@", "打开主题 \(title)")).firstMatch
    try wait { row.isHittable }
  }

  @MainActor
  private func visibleRow(prefix: String, app: XCUIApplication) throws -> XCUIElement {
    let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "打开主题 \(prefix)·"))
    var result: XCUIElement?
    try wait {
      result = rows.allElementsBoundByIndex.first {
        $0.isHittable && $0.frame.minY > app.frame.height * 0.35
          && $0.frame.maxY < app.frame.height * 0.85
      }
      return result != nil
    }
    return try XCTUnwrap(result)
  }

  @MainActor
  private func scrollUp(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      .press(
        forDuration: 0.1,
        thenDragTo:
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
  }

  @MainActor
  private func requireCounts(_ expected: String, app: XCUIApplication) throws {
    let counts = app.staticTexts["forum-section-request-counts"]
    try wait { counts.exists && counts.label == expected }
  }

  @MainActor
  private func requireUnchangedCounts(_ expected: String, app: XCUIApplication) throws {
    try requireCounts(expected, app: app)
    let noAdditionalRequest = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected),
      object: app.staticTexts["forum-section-request-counts"])
    noAdditionalRequest.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [noAdditionalRequest], timeout: 0.75), .completed)
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait { element.isHittable }
    element.tap()
  }

  @MainActor
  private func wait(_ condition: @escaping () -> Bool) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      throw ForumSectionsUITestError.timedOut
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

private enum ForumSectionsUITestError: Error { case timedOut }
