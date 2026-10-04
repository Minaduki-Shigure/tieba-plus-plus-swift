import UIKit
import XCTest

/// Measures the production SearchView while page two is held by the service.
/// No gesture occurs between releasing IO and checking the old visible row.
final class SearchPaginationAnchorUITests: XCTestCase {
  @MainActor
  func testAppendingSecondPageKeepsTheVisibleFirstPageTailInPlace() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--search-scopes-ui-testing",
      "--search-pagination-anchor-ui-testing",
    ]
    app.launch()
    defer { attachState(app, name: "Search append final") }
    try tap(app.buttons["进入离线搜索"], app: app)
    try wait("Initial forum results are visible", app: app) {
      app.staticTexts["测试·贴吧1"].isHittable
    }
    try tap(app.buttons["search-scope-threads"], app: app)
    try wait("First thread page is visible", app: app) {
      app.staticTexts["测试·最新·帖子1"].isHittable
    }
    try requireCounts("forums=1 threads=1 users=0 posts=0 unexpected=0", app: app)

    let tail = app.staticTexts["测试·最新·帖子20"].firstMatch
    try reveal(tail, app: app)
    let release = app.buttons["search-pagination-anchor-release"]
    try wait("Page two is held at the service boundary", app: app) { release.isHittable }
    try requireCounts("forums=1 threads=2 users=0 posts=0 unexpected=0", app: app)
    let before = try stablePosition(tail, app: app)
    XCTAssertFalse(app.staticTexts["测试·最新·帖子21"].exists)
    attachState(app, name: "Search append held before release")

    release.tap()
    try wait("Second page service response was delivered", app: app) {
      app.staticTexts["search-pagination-anchor-state"].label
        == "waiting=0 deliveredRows=20 unexpected=0"
    }
    var stable = 0
    try wait(
      "Appending results keeps thread 20 within three points", app: app,
      diagnostics: { "beforeY=\(before), current=\(tail.frame)" },
      until: {
        let frame = tail.exists ? tail.frame : .null
        if self.fullyVisible(tail, frame: frame, app: app), abs(frame.minY - before) <= 3 {
          stable += 1
        } else {
          stable = 0
        }
        return stable >= 3
      })
    attachState(app, name: "Search append retained without a gesture")

    // Only after the no-gesture assertion may the test move to the new page.
    try reveal(app.staticTexts["测试·最新·帖子21"].firstMatch, app: app)
    try requireCounts("forums=1 threads=2 users=0 posts=0 unexpected=0", app: app)
    XCTAssertEqual(
      app.staticTexts["search-scope-request-log"].label,
      "forums:测试:1:none | threads:测试:1:newest | threads:测试:2:newest")
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "label != %@", "forums=1 threads=2 users=0 posts=0 unexpected=0"),
      object: app.staticTexts["search-scope-request-counts"])
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
  }

  @MainActor
  private func viewport(_ app: XCUIApplication) -> CGRect {
    let list = app.descendants(matching: .any)
      .matching(identifier: "search-threads-list").firstMatch.frame
    let picker = app.segmentedControls["global-thread-search-sort-picker"].frame
    let window = app.windows.firstMatch.frame
    let top = max(list.minY, picker.maxY) + 8
    let bottom = min(list.maxY, window.maxY) - 16
    return CGRect(x: list.minX + 8, y: top, width: list.width - 16, height: max(0, bottom - top))
  }

  @MainActor
  private func fullyVisible(_ target: XCUIElement, frame: CGRect, app: XCUIApplication) -> Bool {
    !frame.isNull && frame.minY.isFinite && frame.minX.isFinite
      && target.isHittable && viewport(app).contains(frame)
  }

  @MainActor
  private func reveal(_ target: XCUIElement, app: XCUIApplication) throws {
    var trace: [String] = []
    for _ in 0..<25 {
      let area = viewport(app)
      let frame = target.exists ? target.frame : .null
      trace.append("target=\(frame), viewport=\(area)")
      if fullyVisible(target, frame: frame, app: app) { return }
      guard area.height > 0 else { break }
      let distance =
        frame.isNull || !frame.midY.isFinite
        ? min(240, area.height * 0.45)
        : min(140, max(-140, frame.midY - area.midY))
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: area.midX, dy: area.midY + distance / 2))
      let end = origin.withOffset(CGVector(dx: area.midX, dy: area.midY - distance / 2))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    try wait(
      "Bounded drags reveal \(target.identifier)", app: app,
      diagnostics: { trace.joined(separator: "\n") },
      until: {
        self.fullyVisible(target, frame: target.exists ? target.frame : .null, app: app)
      })
  }

  @MainActor
  private func stablePosition(_ target: XCUIElement, app: XCUIApplication) throws -> CGFloat {
    var previous: CGFloat?
    var samples = 0
    try wait("Visible first-page tail settles before IO release", app: app) {
      let frame = target.exists ? target.frame : .null
      guard self.fullyVisible(target, frame: frame, app: app) else { return false }
      if let previous, abs(previous - frame.minY) < 1 { samples += 1 } else { samples = 0 }
      previous = frame.minY
      return samples >= 2
    }
    return try XCTUnwrap(previous)
  }

  @MainActor
  private func requireCounts(_ value: String, app: XCUIApplication) throws {
    try wait("Exact search request counts", app: app) {
      app.staticTexts["search-scope-request-counts"].label == value
    }
  }

  @MainActor
  private func tap(_ element: XCUIElement, app: XCUIApplication) throws {
    try wait("Tap \(element.identifier)", app: app) { element.isHittable }
    element.tap()
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
      attachState(app, name: context)
      let message = "\(context). \(diagnostics())"
      XCTFail(message, file: file, line: line)
      throw SearchPaginationAnchorUITestError.timedOut(message)
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

private enum SearchPaginationAnchorUITestError: Error { case timedOut(String) }
