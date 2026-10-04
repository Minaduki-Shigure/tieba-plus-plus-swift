import UIKit
import XCTest

final class UserProfileActivityUITests: XCTestCase {
  @MainActor
  func testIndependentPositionsSurviveSwipesAndThreadNavigation() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    scrollUp(app)
    scrollUp(app)
    let thread = try visibleAnchor(app.staticTexts, prefix: "公开主题·帖子", app: app)
    let threadTitle = thread.label
    let threadY = thread.frame.minY

    try select(.replies, app: app)
    scrollUp(app)
    scrollUp(app)
    let reply = try visibleAnchor(app.buttons, prefix: "打开原主题：回复原主题", app: app)
    let replyTitle = reply.label
    let replyY = reply.frame.minY
    try counts(
      "profile=1 threads=1 replies=1 relationship=1 posts=0 comments=0 unexpected=0", app: app)

    for _ in 0..<2 {
      try select(.threads, app: app)
      try position(app.staticTexts[threadTitle].firstMatch, y: threadY, context: "Retained topics")
      try select(.replies, app: app)
      try position(app.buttons[replyTitle].firstMatch, y: replyY, context: "Retained replies")
    }
    try select(.threads, app: app)
    try tap(app.staticTexts[threadTitle].firstMatch)
    try wait("Thread body visible") { app.staticTexts["离线帖子正文"].firstMatch.isHittable }
    edgeBack(app)
    try position(app.staticTexts[threadTitle].firstMatch, y: threadY, context: "Detail return")
    // Relationship reads retain the existing account-bound revalidation on
    // detail return; ordinary activity switches must not add more reads.
    try counts(
      "profile=1 threads=1 replies=1 relationship=2 posts=1 comments=0 unexpected=0", app: app)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65)))
    try position(app.buttons[replyTitle].firstMatch, y: replyY, context: "Native swipe to replies")
    try counts(
      "profile=1 threads=1 replies=1 relationship=2 posts=1 comments=0 unexpected=0", app: app)
    edgeBack(app)
    try wait("Profile edge pop") { app.navigationBars["离线资料入口"].exists }
  }

  @MainActor
  func testReplyDestinationsAndPaginationRetainTheirPage() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    try select(.replies, app: app)
    let ordinary = replyButton(1, app: app)
    try reveal(ordinary, app: app)
    try tap(ordinary)
    try wait("Ordinary reply destination") { app.staticTexts["离线普通回复正文"].firstMatch.isHittable }
    edgeBack(app)
    try wait("Ordinary reply return") { ordinary.isHittable }

    let nested = replyButton(2, app: app)
    try reveal(nested, app: app)
    try tap(nested)
    let comment = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "离线楼中楼正文")).firstMatch
    try wait("Nested reply destination") { comment.isHittable }
    edgeBack(app)
    try wait("Nested reply return") { nested.isHittable }
    try tap(app.buttons["打开原主题：回复原主题2"].firstMatch)
    try wait("Original topic destination") { app.staticTexts["离线帖子正文"].firstMatch.isHittable }
    edgeBack(app)
    try wait("Original topic return") { nested.isHittable }
    try counts(
      "profile=1 threads=1 replies=1 relationship=4 posts=2 comments=1 unexpected=0", app: app)

    let secondPage = app.buttons["打开原主题：回复原主题21"].firstMatch
    for _ in 0..<25 {
      if secondPage.isHittable { break }
      scrollUp(app)
    }
    try wait("Second reply page visible") { secondPage.isHittable }
    let anchor = try visibleAnchor(app.buttons, prefix: "打开原主题：回复原主题", app: app)
    let title = anchor.label
    let y = anchor.frame.minY
    try select(.threads, app: app)
    try select(.replies, app: app)
    try position(app.buttons[title].firstMatch, y: y, context: "Return to paginated replies")
    try counts(
      "profile=1 threads=1 replies=2 relationship=4 posts=2 comments=1 unexpected=0", app: app)
  }

  private enum Activity: String { case threads, replies }

  @MainActor
  private func launchFixture() throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--profile-activity-ui-testing",
    ]
    app.launch()
    try tap(app.buttons["进入离线用户主页"])
    try counts(
      "profile=1 threads=1 replies=0 relationship=1 posts=0 comments=0 unexpected=0", app: app)
    return app
  }

  @MainActor
  private func select(_ section: Activity, app: XCUIApplication) throws {
    try tap(app.buttons["user-profile-section-\(section.rawValue)"])
  }

  @MainActor
  private func replyButton(_ number: Int, app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "公开回复·第\(number)条")).firstMatch
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) throws {
    for _ in 0..<5 {
      if element.isHittable { return }
      scrollUp(app)
    }
    try wait("Reveal reply", diagnostics: { element.debugDescription }) { element.isHittable }
  }

  @MainActor
  private func visibleAnchor(_ query: XCUIElementQuery, prefix: String, app: XCUIApplication) throws
    -> XCUIElement
  {
    let candidates = query.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    var result: XCUIElement?
    try wait("Find unique visible position anchor: \(prefix)") {
      result = candidates.allElementsBoundByIndex.first {
        $0.isHittable && $0.frame.minY > app.frame.height * 0.35
          && $0.frame.maxY < app.frame.height * 0.85
      }
      return result != nil
    }
    return try XCTUnwrap(result)
  }

  @MainActor
  private func position(_ element: XCUIElement, y: CGFloat, context: String) throws {
    try wait(context, diagnostics: { "expectedY=\(y), frame=\(element.frame)" }) {
      element.isHittable && abs(element.frame.minY - y) < 3
    }
  }

  @MainActor
  private func counts(_ expected: String, app: XCUIApplication) throws {
    let counter = app.staticTexts["profile-activity-request-counts"]
    try wait("Request counts", diagnostics: { "expected=\(expected), actual=\(counter.label)" }) {
      counter.exists && counter.label == expected
    }
    let unchanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected), object: counter)
    unchanged.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 0.75), .completed)
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait("Tap target", diagnostics: { element.debugDescription }) { element.isHittable }
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
      throw ProfileActivityUITestError.timedOut(message)
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

private enum ProfileActivityUITestError: Error { case timedOut(String) }
