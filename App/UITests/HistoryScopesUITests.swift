import UIKit
import XCTest

final class HistoryScopesUITests: XCTestCase {
  @MainActor
  func testSeparatePositionsSurviveTapsSwipesAndRealDetailReturn() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    scrollUp(app)
    scrollUp(app)
    let thread = try anchor(prefix: "历史帖子·", app: app)
    try select("forum", app: app)
    scrollUp(app)
    scrollUp(app)
    let forum = try anchor(prefix: "历史贴吧·", app: app)
    for _ in 0..<2 {
      try select("thread", app: app)
      try position(thread, app: app)
      try select("forum", app: app)
      try position(forum, app: app)
    }
    try tap(app.staticTexts[forum.title].firstMatch)
    try wait("Real forum opened") {
      app.navigationBars[forum.title].exists && app.staticTexts["暂无帖子"].firstMatch.isHittable
    }
    edgeBack(app)
    try position(forum, app: app)
    try select("thread", app: app)
    try position(thread, app: app)
    try tap(app.staticTexts[thread.title].firstMatch)
    try wait("Real thread opened") { app.staticTexts["离线帖子正文"].firstMatch.isHittable }
    edgeBack(app)
    try position(thread, app: app)
    try store(threads: 30, forums: 30, app: app)

    horizontalSwipe(left: true, app: app)
    try position(forum, app: app)
    horizontalSwipe(left: false, app: app)
    try position(thread, app: app)
    edgeBack(app)
    try wait("Edge gesture leaves history") { app.navigationBars["离线历史入口"].exists }
  }

  @MainActor
  func testSwipeDeletionAndConfirmedClearUpdateBothPersistedCategories() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    try select("forum", app: app)
    scrollUp(app)
    scrollUp(app)
    let forum = try anchor(prefix: "历史贴吧·", app: app)
    try select("thread", app: app)
    let row = app.cells.containing(.staticText, identifier: "历史帖子·1").firstMatch
    try wait("First thread row is visible") { row.isHittable }
    // A short native row drag reveals its action without full-swipe deletion.
    // The count and selected category must stay unchanged until Delete is tapped.
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
    try store(threads: 30, forums: 30, app: app)
    XCTAssertTrue(app.buttons["history-kind-thread"].isSelected)
    try tap(app.buttons["删除"].firstMatch)
    try store(threads: 29, forums: 30, firstThread: "thread:980002", app: app)
    XCTAssertFalse(app.staticTexts["历史帖子·1"].exists)
    XCTAssertTrue(app.buttons["history-kind-thread"].isSelected)
    try select("forum", app: app)
    try position(forum, app: app)

    try tap(app.buttons["清空浏览记录"])
    try tap(app.buttons["取消"].firstMatch)
    try store(threads: 29, forums: 30, firstThread: "thread:980002", app: app)
    try tap(app.buttons["清空浏览记录"])
    try tap(app.buttons["清空全部记录"])
    try store(threads: 0, forums: 0, firstThread: "none", firstForum: "none", app: app)
    try wait("Forum list is empty after clear") { app.staticTexts["暂无贴吧记录"].exists }
    try select("thread", app: app)
    try wait("Thread list is also empty") { app.staticTexts["暂无帖子记录"].exists }
    XCTAssertFalse(app.buttons["清空浏览记录"].isEnabled)
  }

  @MainActor
  func testRecordingPreferenceAndVisitedThreadReorderingUseTheSameArchive() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    try select("forum", app: app)
    scrollUp(app)
    scrollUp(app)
    let forum = try anchor(prefix: "历史贴吧·", app: app)
    try select("thread", app: app)
    try tap(app.buttons["history-recording-menu"])
    try tap(app.buttons["记录浏览历史"].firstMatch)
    try store(threads: 30, forums: 30, recording: true, app: app)
    scrollUp(app)
    scrollUp(app)
    let visited = try anchor(prefix: "历史帖子·", app: app)
    let number = try XCTUnwrap(Int(visited.title.replacingOccurrences(of: "历史帖子·", with: "")))
    XCTAssertGreaterThan(number, 1)
    try tap(app.staticTexts[visited.title].firstMatch)
    try wait("Real thread opened while recording") {
      app.staticTexts["离线帖子正文"].firstMatch.isHittable
    }
    try store(
      threads: 30, forums: 30, recording: true, firstThread: "thread:\(980_000 + number)", app: app)
    edgeBack(app)
    try wait("History returned") { app.navigationBars["浏览记录"].exists }
    try select("forum", app: app)
    try position(forum, app: app)
    try select("thread", app: app)
    // Return to the top through native scrolling and verify the visited row
    // moved there. The fixture never changes selection, offset or model state.
    for _ in 0..<20 {
      let first = historyList("thread", app: app).cells.firstMatch
      if first.staticTexts[visited.title].isHittable { break }
      drag(app, from: CGVector(dx: 0.5, dy: 0.4), to: CGVector(dx: 0.5, dy: 0.8))
    }
    try wait("Visited thread is the first history entry") {
      self.historyList("thread", app: app).cells.firstMatch.staticTexts[visited.title].isHittable
    }
  }

  private struct Anchor {
    let title: String
    let y: CGFloat
  }

  @MainActor
  private func launchFixture() throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--history-scopes-ui-testing",
    ]
    app.launch()
    try tap(app.buttons["进入离线浏览记录"])
    try wait("First history entry visible") { app.staticTexts["历史帖子·1"].firstMatch.isHittable }
    try store(threads: 30, forums: 30, app: app)
    return app
  }

  @MainActor
  private func store(
    threads: Int, forums: Int, recording: Bool = false,
    firstThread: String = "thread:980001", firstForum: String = "forum:历史贴吧·1",
    app: XCUIApplication
  ) throws {
    let expected =
      "threads=\(threads) forums=\(forums) recording=\(recording) "
      + "firstThread=\(firstThread) firstForum=\(firstForum)"
    let summary = app.staticTexts["history-store-summary"]
    try wait(
      "Persisted history", diagnostics: { "expected=\(expected), actual=\(summary.label)" },
      until: { summary.exists && summary.label == expected })
  }

  @MainActor
  private func historyList(_ kind: String, app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "history-\(kind)-list").firstMatch
  }

  @MainActor
  private func select(_ kind: String, app: XCUIApplication) throws {
    try tap(app.buttons["history-kind-\(kind)"])
    try wait("Selected history category") { app.buttons["history-kind-\(kind)"].isSelected }
  }

  @MainActor
  private func fullyVisible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
    element.isHittable && element.frame.minY > app.frame.height * 0.3
      && element.frame.maxY < app.frame.height * 0.9
  }

  @MainActor
  private func anchor(prefix: String, app: XCUIApplication) throws -> Anchor {
    var previous: Anchor?
    var stable = 0
    try wait("Stable history anchor") {
      guard
        let element = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
          .allElementsBoundByIndex.first(where: { self.fullyVisible($0, app: app) })
      else { return false }
      let current = Anchor(title: element.label, y: element.frame.minY)
      if let previous, previous.title == current.title, abs(previous.y - current.y) < 1 {
        stable += 1
      } else {
        stable = 0
      }
      previous = current
      return stable >= 2
    }
    return try XCTUnwrap(previous)
  }

  @MainActor
  private func position(_ saved: Anchor, app: XCUIApplication) throws {
    let element = app.staticTexts[saved.title].firstMatch
    try wait(
      "Retained \(saved.title)", diagnostics: { "expectedY=\(saved.y) frame=\(element.frame)" },
      until: { self.fullyVisible(element, app: app) && abs(element.frame.minY - saved.y) < 3 })
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait(
      "Tap target", diagnostics: { element.debugDescription }, until: { element.isHittable })
    element.tap()
  }

  @MainActor
  private func scrollUp(_ app: XCUIApplication) {
    drag(app, from: CGVector(dx: 0.5, dy: 0.8), to: CGVector(dx: 0.5, dy: 0.4))
  }

  @MainActor
  private func horizontalSwipe(left: Bool, app: XCUIApplication) {
    // Category swipes belong to the category strip. Row swipes must remain
    // available to the native List's destructive action, with no pager theft.
    let strip = app.segmentedControls["history-kind-picker"]
    strip.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.2, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: strip.coordinate(
        withNormalizedOffset: CGVector(dx: left ? 0.2 : 0.8, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
  }

  @MainActor
  private func edgeBack(_ app: XCUIApplication) {
    drag(app, from: CGVector(dx: 0.01, dy: 0.55), to: CGVector(dx: 0.9, dy: 0.55))
  }

  @MainActor
  private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
    app.coordinate(withNormalizedOffset: from).press(
      forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: to),
      withVelocity: .slow, thenHoldForDuration: 0.2)
  }

  @MainActor
  private func wait(
    _ context: String, diagnostics: @escaping () -> String = { "" },
    file: StaticString = #filePath, line: UInt = #line, until condition: @escaping () -> Bool
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      let message = "\(context). \(diagnostics())"
      XCTFail(message, file: file, line: line)
      throw HistoryScopesUITestError.timedOut(message)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "History scope final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "History scope final screen"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum HistoryScopesUITestError: Error { case timedOut(String) }
