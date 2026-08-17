import XCTest

final class ThreadScrollPerformanceTests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testBaselineScrolling() throws {
    try measureScrolling(scenario: "baseline")
  }

  func testLongPlainTextScrolling() throws {
    try measureScrolling(scenario: "long-plain-text")
  }

  func testInlineRepliesScrolling() throws {
    try measureScrolling(scenario: "inline-replies")
  }

  func testManyFloorsScrolling() throws {
    try measureScrolling(scenario: "many-floors")
  }

  func testLongPlainTextTraceDriver() throws {
    let (app, scrollView, _) = try launch(scenario: "long-plain-text")
    let delay = ProcessInfo.processInfo.environment["TIEBA_PROFILE_ATTACH_DELAY"]
      .flatMap(TimeInterval.init) ?? 5
    Thread.sleep(forTimeInterval: delay)
    for _ in 0..<20 {
      scrollView.swipeUp(velocity: .fast)
    }
    Thread.sleep(forTimeInterval: 2)
    app.terminate()
  }

  private func measureScrolling(scenario: String) throws {
    let (app, scrollView, ready) = try launch(scenario: scenario)

    scrollView.swipeUp(velocity: .fast)
    resetToStart(scrollView: scrollView, ready: ready)

    let options = XCTMeasureOptions()
    options.iterationCount = 5
    options.invocationOptions = [.manuallyStop]
    measure(
      metrics: [
        XCTClockMetric(),
        XCTCPUMetric(application: app),
        XCTMemoryMetric(application: app),
        XCTOSSignpostMetric.scrollDecelerationMetric,
      ],
      options: options
    ) {
      scrollView.swipeUp(velocity: .fast)
      stopMeasuring()
      resetToStart(scrollView: scrollView, ready: ready)
    }

    app.terminate()
  }

  private func launch(scenario: String) throws
    -> (XCUIApplication, XCUIElement, XCUIElement)
  {
    let app = XCUIApplication()
    app.launchEnvironment["TIEBA_PERFORMANCE_SCENARIO"] = scenario
    app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
    app.launch()

    let ready = app.staticTexts["PERF-READY-\(scenario)"]
    XCTAssertTrue(ready.waitForExistence(timeout: 20), "Performance fixture did not load")
    let scrollView = app.scrollViews.firstMatch
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5), "Thread scroll view is unavailable")
    return (app, scrollView, ready)
  }

  private func resetToStart(scrollView: XCUIElement, ready: XCUIElement) {
    for _ in 0..<4 where !ready.isHittable {
      scrollView.swipeDown(velocity: .fast)
    }
    XCTAssertTrue(ready.isHittable, "Scroll measurement did not reset to the first floor")
  }
}
