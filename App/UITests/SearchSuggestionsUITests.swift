import UIKit
import XCTest

/// Edits the actual searchable field and chooses its native suggestion. The
/// fixture only supplies offline responses and observes requests/repository writes.
final class SearchSuggestionsUITests: XCTestCase {
  @MainActor
  func testChoosingSuggestionSubmitsOnceInTheSelectedScopeAndDoesNotRestartOnReturn() throws {
    let app = try launchFixture(enabled: true)
    defer { attachState(app) }
    try tap(app.buttons["search-scope-threads"])
    try visible("测试·最新·帖子1", app: app)
    try counts("forums=1 threads=1 users=0 posts=0 unexpected=0", app: app)
    try history(writes: 0, entries: "", app: app)
    try unchangedSuggestions("queries=", app: app)

    let search = try openSearch(app)
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
    search.typeText("nex")
    let suggestion = app.buttons["搜索建议：next"].firstMatch
    try wait("Native suggestion appears") { suggestion.isHittable }
    let requested = app.staticTexts["search-suggestion-request-log"].label
    XCTAssertTrue(requested.hasSuffix("nex"), requested)
    XCTAssertEqual(app.buttons.matching(identifier: "搜索建议：next").count, 1)
    try tap(suggestion)
    try wait("Choosing a suggestion dismisses search") { app.keyboards.count == 0 }
    try visible("next·最新·帖子1", app: app)
    XCTAssertTrue(app.buttons["search-scope-threads"].isSelected)
    try counts("forums=1 threads=2 users=0 posts=0 unexpected=0", app: app)
    try history(writes: 1, entries: "next", app: app)
    try unchangedSuggestions(requested, app: app)

    try tap(app.staticTexts["next·最新·帖子1"].firstMatch)
    try visible("离线帖子正文", app: app)
    edgeBack(app)
    try visible("next·最新·帖子1", app: app)
    try counts("forums=1 threads=2 users=0 posts=1 unexpected=0", app: app)
    try unchangedSuggestions(requested, app: app)
    try history(writes: 1, entries: "next", app: app)

    // Cancelling a later edit must not submit it or destroy the retained results.
    let reopenedSearch = try openSearch(app)
    reopenedSearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
    reopenedSearch.typeText("ne")
    try wait("Suggestions appear during a new edit") { suggestion.isHittable }
    let afterEdit = app.staticTexts["search-suggestion-request-log"].label
    XCTAssertTrue(afterEdit.hasSuffix("ne"), afterEdit)
    try tap(app.buttons["取消"].firstMatch)
    try wait("Cancel dismisses search") { app.keyboards.count == 0 }
    try visible("next·最新·帖子1", app: app)
    try history(writes: 1, entries: "next", app: app)
    try counts("forums=1 threads=2 users=0 posts=1 unexpected=0", app: app)
    _ = try openSearch(app)
    try unchangedSuggestions(afterEdit, app: app)
    try tap(app.buttons["取消"].firstMatch)
  }

  @MainActor
  func testDisabledPreferenceMakesNoSuggestionRequestsButKeyboardSubmissionStillWorks() throws {
    let app = try launchFixture(enabled: false)
    defer { attachState(app) }
    let search = try openSearch(app)
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
    search.typeText("next")
    try unchangedSuggestions("queries=", app: app)
    XCTAssertFalse(app.buttons["搜索建议：next"].exists)
    search.typeText("\n")
    try wait("Keyboard submit closes search") { app.keyboards.count == 0 }
    try visible("next·贴吧1", app: app)
    try history(writes: 1, entries: "next", app: app)
    try counts("forums=2 threads=0 users=0 posts=0 unexpected=0", app: app)
    try unchangedSuggestions("queries=", app: app)
  }

  @MainActor
  private func launchFixture(enabled: Bool) throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--explore-refresh-ui-testing", "--search-scopes-ui-testing",
    ]
    if enabled { app.launchArguments.append("--search-suggestions-enabled") }
    app.launch()
    try tap(app.buttons["进入离线搜索"])
    try visible("测试·贴吧1", app: app)
    return app
  }

  @MainActor
  private func openSearch(_ app: XCUIApplication) throws -> XCUIElement {
    let search = app.searchFields.firstMatch
    for _ in 0..<8 {
      if search.isHittable { break }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(
        forDuration: 0.05,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    try tap(search)
    try wait("Search keyboard is visible") { app.keyboards.count > 0 }
    return search
  }

  @MainActor
  private func unchangedSuggestions(_ expected: String, app: XCUIApplication) throws {
    let probe = app.staticTexts["search-suggestion-request-log"]
    XCTAssertEqual(probe.label, expected)
    let change = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { probe.label != expected }
      }, object: nil)
    change.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [change], timeout: 1.2), .completed)
    XCTAssertEqual(probe.label, expected)
  }

  @MainActor
  private func history(writes: Int, entries: String, app: XCUIApplication) throws {
    let probe = app.staticTexts["search-history-write-summary"]
    let expected = "writes=\(writes) entries=\(entries)"
    try wait(
      "Exactly one repository write per submission", diagnostics: { probe.label },
      until: { probe.exists && probe.label == expected })
  }

  @MainActor
  private func counts(_ expected: String, app: XCUIApplication) throws {
    let probe = app.staticTexts["search-scope-request-counts"]
    try wait(
      "Only the selected scope requests results", diagnostics: { probe.label },
      until: { probe.exists && probe.label == expected })
  }

  @MainActor
  private func visible(_ title: String, app: XCUIApplication) throws {
    try wait("Visible result: \(title)") { app.staticTexts[title].firstMatch.isHittable }
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait(
      "Tap target", diagnostics: { element.debugDescription }, until: { element.isHittable })
    element.tap()
  }

  @MainActor
  private func edgeBack(_ app: XCUIApplication) {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55)).press(
      forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55)),
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
      throw SuggestionUITestError.timedOut(message)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Search suggestions final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Search suggestions final screen"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum SuggestionUITestError: Error { case timedOut(String) }
