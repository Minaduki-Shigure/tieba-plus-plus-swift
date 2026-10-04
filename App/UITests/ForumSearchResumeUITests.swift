import UIKit
import XCTest

/// Exercises the production RootView -> ForumView -> ForumPostSearchView route.
/// Only transport and repository boundaries are replaced; native tab selection
/// is responsible for cancellation and reactivation of the real search model.
final class ForumSearchResumeUITests: XCTestCase {
  @MainActor
  func testInterruptedFirstSearchResumesOnTabReturnWithoutDuplicateHistoryOrStaleResults() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--forum-search-resume-ui-testing",
    ]
    app.launch()
    defer { attachState(app, name: "Forum search resume final") }

    let homeField = app.textFields["输入吧名或关键词"]
    try tap(homeField, app: app)
    homeField.typeText("恢复测试")
    try tap(app.buttons["直接打开贴吧"], app: app)
    try tap(app.buttons["吧内搜索"], app: app)
    let search = app.searchFields.firstMatch
    for _ in 0..<4 {
      if search.isHittable { break }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(
        forDuration: 0.05,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    try tap(search, app: app)
    search.typeText("actors\n")
    try requireCounts("requests=1 cancellations=0 late=0 unexpected=0", app: app)
    try requireHistory(app)
    try requireOptions(app)
    try wait("Search keyboard closes after submit", app: app) { app.keyboards.count == 0 }
    XCTAssertFalse(app.staticTexts["恢复后的搜索结果"].exists)

    // The first request is still suspended when the native root tab leaves.
    try tap(app.buttons["root-tab-explore"], app: app)
    let recommendation = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "推荐·第1次")
    ).firstMatch
    try wait("The real Explore tab is visible", app: app) { recommendation.isHittable }
    try requireCounts("requests=1 cancellations=1 late=0 unexpected=0", app: app)
    try requireHistory(app)

    try tap(app.buttons["root-tab-home"], app: app)
    let fresh = app.staticTexts["恢复后的搜索结果"].firstMatch
    try wait("Returning resumes the unfinished first page", app: app) { fresh.isHittable }
    try requireCounts("requests=2 cancellations=1 late=0 unexpected=0", app: app)
    try requireHistory(app)
    try requireOptions(app)
    XCTAssertTrue(app.navigationBars["恢复测试吧内搜索"].exists)
    let request = "actors:恢复测试:1:newest:all"
    XCTAssertEqual(
      app.staticTexts["forum-search-resume-requests"].label, "\(request) | \(request)")
    attachState(app, name: "Forum search restored before old response")

    // Release only the fake network continuation, after the fresh result is
    // visibly installed. A generation mistake would now replace it with old data.
    try tap(app.buttons["forum-search-resume-release-old"], app: app)
    try requireCounts("requests=2 cancellations=1 late=1 unexpected=0", app: app)
    try requireStableFreshResult(app)

    // A subsequent visit keeps the loaded snapshot and must not repeat page 1.
    try tap(app.buttons["root-tab-explore"], app: app)
    try wait("Explore is visible again", app: app) { recommendation.isHittable }
    try tap(app.buttons["root-tab-home"], app: app)
    try wait("Loaded results remain visible", app: app) { fresh.isHittable }
    try requireOptions(app)
    try requireHistory(app)
    try requireCounts("requests=2 cancellations=1 late=1 unexpected=0", app: app)
    try requireStableFreshResult(app)
  }

  @MainActor
  private func requireOptions(_ app: XCUIApplication) throws {
    let sort = app.segmentedControls["forum-post-search-sort-picker"].buttons["最新"]
    let filter = app.segmentedControls["forum-post-search-filter-picker"].buttons["全部"]
    try wait("Original sort and scope stay selected", app: app) {
      sort.isSelected && filter.isSelected
    }
  }

  @MainActor
  private func requireHistory(_ app: XCUIApplication) throws {
    let probe = app.staticTexts["forum-search-resume-history"]
    try wait("Exactly one real history repository record", app: app) {
      probe.label == "writes=1 entries=actors"
    }
  }

  @MainActor
  private func requireCounts(_ expected: String, app: XCUIApplication) throws {
    let probe = app.staticTexts["forum-search-resume-counts"]
    try wait(expected, app: app) { probe.exists && probe.label == expected }
  }

  @MainActor
  private func requireStableFreshResult(_ app: XCUIApplication) throws {
    let old = app.staticTexts["已取消的旧搜索结果"].firstMatch
    let fresh = app.staticTexts["恢复后的搜索结果"].firstMatch
    let counts = app.staticTexts["forum-search-resume-counts"]
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          old.exists || !fresh.isHittable
            || counts.label != "requests=2 cancellations=1 late=1 unexpected=0"
        }
      }, object: nil)
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.2), .completed)
    XCTAssertFalse(old.exists)
    XCTAssertTrue(fresh.isHittable)
    try requireHistory(app)
  }

  @MainActor
  private func tap(_ element: XCUIElement, app: XCUIApplication) throws {
    try wait("Tap \(element.identifier)", app: app) { element.isHittable }
    element.tap()
  }

  @MainActor
  private func wait(
    _ context: String, app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line,
    until condition: @escaping () -> Bool
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      attachState(app, name: "Forum search resume failure: \(context)")
      XCTFail(context, file: file, line: line)
      throw ForumSearchResumeUITestError.timedOut(context)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication, name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "\(name) screen"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum ForumSearchResumeUITestError: Error { case timedOut(String) }
