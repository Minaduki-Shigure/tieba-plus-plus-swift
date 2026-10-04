import UIKit
import XCTest

/// Uses the actual account-bound inbox and ContentFilterRepository. Fixture
/// controls finish held service responses; they cannot initiate pagination.
final class InboxFilteredPaginationUITests: XCTestCase {
  @MainActor
  func testHiddenMiddlePageContinuesWithoutMovingTheVisibleTail() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--inbox-scopes-ui-testing", "--inbox-scopes-filtered-middle-page",
    ]
    app.launch()
    defer { attachState(app, name: "Filtered inbox final state") }
    try wait("Home inbox tab is ready", app: app) {
      app.buttons["root-tab-notifications"].isHittable
    }
    app.buttons["root-tab-notifications"].tap()
    let first = app.staticTexts["回复消息·第1条"].firstMatch
    try wait("First page is visible", app: app) { self.fullyVisible(first, app: app) }
    try counts("replies=1 mentions=0 page2=0 page3=0 posts=0 unexpected=0", app: app)

    let tail = app.staticTexts["回复消息·第20条"].firstMatch
    try reveal(tail, app: app)
    let secondResponse = app.buttons["inbox-filtered-pagination-release-2"]
    try wait("Page two is requested and held at the service boundary", app: app) {
      secondResponse.isHittable
    }
    try counts("replies=2 mentions=0 page2=1 page3=0 posts=0 unexpected=0", app: app)
    let before = try stablePosition(tail, app: app)
    assertNoHiddenMessages(app)

    secondResponse.tap()
    // No scrolling, channel switches or reactivation may prompt the next read.
    // Page three must start solely because the hidden page finished loading.
    let thirdResponse = app.buttons["inbox-filtered-pagination-release-3"]
    try wait("The hidden second page automatically requests page three", app: app) {
      thirdResponse.isHittable
    }
    try counts("replies=3 mentions=0 page2=1 page3=1 posts=0 unexpected=0", app: app)
    try position(tail, y: before, context: "Tail stays put while page three is pending", app: app)
    assertNoHiddenMessages(app)

    thirdResponse.tap()
    let filterState = app.staticTexts["inbox-filtered-pagination-state"]
    try wait("Both complete server pages were returned through the real filter", app: app) {
      let value = filterState.label
      return value.contains("waiting=0 hiddenRows=20 finalRows=20")
        && !value.contains("filterReads=0") && value.hasSuffix("unexpected=0")
    }
    try position(tail, y: before, context: "Appending page three preserves the tail", app: app)
    assertNoHiddenMessages(app)
    try counts("replies=3 mentions=0 page2=1 page3=1 posts=0 unexpected=0", app: app)

    // Only now move the viewport to read the newly appended visible page.
    try reveal(app.staticTexts["回复消息·第41条"].firstMatch, app: app)
    assertNoHiddenMessages(app)
    XCTAssertFalse(app.buttons["继续加载"].exists)
    XCTAssertEqual(
      app.staticTexts["inbox-scope-request-log"].label, "replies:1 | replies:2 | replies:3")
    try counts("replies=3 mentions=0 page2=1 page3=1 posts=0 unexpected=0", app: app)
  }

  @MainActor
  private func viewport(_ app: XCUIApplication) -> CGRect {
    let top = app.buttons["inbox-kind-replies"].frame.maxY + 6
    let bottom = app.tabBars["root-tab-bar"].frame.minY - 12
    return CGRect(x: 8, y: top, width: app.frame.width - 16, height: max(0, bottom - top))
  }

  @MainActor
  private func fullyVisible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
    element.exists && element.isHittable && viewport(app).contains(element.frame)
  }

  @MainActor
  private func reveal(_ target: XCUIElement, app: XCUIApplication) throws {
    for _ in 0..<32 {
      if fullyVisible(target, app: app) { return }
      let area = viewport(app)
      guard area.height > 0 else { break }
      let distance =
        target.exists
        ? min(120, max(-120, target.frame.midY - area.midY))
        : min(180, area.height * 0.35)
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: area.midX, dy: area.midY + distance / 2))
      let end = origin.withOffset(CGVector(dx: area.midX, dy: area.midY - distance / 2))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    try wait("Bounded drags reveal \(target.identifier)", app: app) {
      self.fullyVisible(target, app: app)
    }
  }

  @MainActor
  private func stablePosition(_ target: XCUIElement, app: XCUIApplication) throws -> CGFloat {
    var previous: CGFloat?
    var stable = 0
    try wait("Visible first-page tail settles before releasing IO", app: app) {
      guard self.fullyVisible(target, app: app) else { return false }
      let y = target.frame.minY
      if let previous, abs(previous - y) < 1 { stable += 1 } else { stable = 0 }
      previous = y
      return stable >= 2
    }
    return try XCTUnwrap(previous)
  }

  @MainActor
  private func position(_ target: XCUIElement, y: CGFloat, context: String, app: XCUIApplication)
    throws
  {
    var stable = 0
    try wait(context, app: app, diagnostics: { "expectedY=\(y), frame=\(target.frame)" }) {
      if self.fullyVisible(target, app: app), abs(target.frame.minY - y) <= 3 {
        stable += 1
      } else {
        stable = 0
      }
      return stable >= 3
    }
  }

  @MainActor
  private func assertNoHiddenMessages(_ app: XCUIApplication) {
    let hidden = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "应被隐藏的中间页"))
    if hidden.firstMatch.exists { attachState(app, name: "Unexpected hidden content") }
    XCTAssertFalse(hidden.firstMatch.exists)
    XCTAssertFalse(app.staticTexts["已屏蔽此消息"].exists)
  }

  @MainActor
  private func counts(_ expected: String, app: XCUIApplication) throws {
    let counter = app.staticTexts["inbox-scope-request-counts"]
    try wait("Exact inbox requests: \(expected)", app: app) { counter.label == expected }
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected), object: counter)
    changed.isInverted = true
    let result = XCTWaiter.wait(for: [changed], timeout: 0.75)
    if result != .completed { attachState(app, name: "Unexpected additional inbox request") }
    XCTAssertEqual(result, .completed)
  }

  @MainActor
  private func wait(
    _ context: String, app: XCUIApplication, diagnostics: () -> String = { "" },
    file: StaticString = #filePath, line: UInt = #line,
    until condition: @escaping () -> Bool
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      let message = "\(context). \(diagnostics())"
      attachState(app, name: context)
      XCTFail(message, file: file, line: line)
      throw FilteredInboxUITestError.timedOut(message)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication, name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum FilteredInboxUITestError: Error { case timedOut(String) }
