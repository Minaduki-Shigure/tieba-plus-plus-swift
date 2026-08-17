import XCTest

@MainActor
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
    let (app, scrollView, _, _) = try launch(scenario: "long-plain-text")
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
    let (app, scrollView, ready, initialMarkerFrame) = try launch(scenario: scenario)

    scrollView.swipeUp(velocity: .fast)
    resetToStart(
      scrollView: scrollView,
      ready: ready,
      initialMarkerFrame: initialMarkerFrame
    )

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
      resetToStart(
        scrollView: scrollView,
        ready: ready,
        initialMarkerFrame: initialMarkerFrame
      )
    }

    app.terminate()
  }

  private func launch(scenario: String) throws
    -> (XCUIApplication, XCUIElement, XCUIElement, CGRect)
  {
    let app = XCUIApplication()
    app.launchEnvironment["TIEBA_PERFORMANCE_SCENARIO"] = scenario
    app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
    app.launch()

    let ready = app.staticTexts["PERF-READY-\(scenario)"]
    XCTAssertTrue(ready.waitForExistence(timeout: 20), "Performance fixture did not load")
    let scrollView = app.scrollViews["thread-post-list"]
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5), "Thread scroll view is unavailable")
    XCTAssertTrue(
      isVisible(ready, in: scrollView),
      "First-floor marker is outside the thread viewport at launch: "
        + "marker=\(ready.frame), viewport=\(scrollView.frame)"
    )
    return (app, scrollView, ready, ready.frame)
  }

  private func resetToStart(
    scrollView: XCUIElement,
    ready: XCUIElement,
    initialMarkerFrame: CGRect
  ) {
    for _ in 0..<8 {
      if isVisible(ready, in: scrollView) {
        let currentFrame = ready.frame
        if abs(currentFrame.minY - initialMarkerFrame.minY) <= 1,
           abs(currentFrame.height - initialMarkerFrame.height) <= 1
        {
          return
        }
      }
      scrollView.swipeDown(velocity: .fast)
    }
    XCTFail(
      "Scroll measurement did not reset to the first floor: "
        + "marker=\(ready.frame), viewport=\(scrollView.frame)"
    )
  }

  private func isVisible(_ element: XCUIElement, in viewport: XCUIElement) -> Bool {
    guard element.exists, viewport.exists else { return false }
    let elementFrame = element.frame
    let intersection = elementFrame.intersection(viewport.frame)
    return !intersection.isNull
      && !intersection.isInfinite
      && intersection.width >= max(elementFrame.width - 1, 1)
      && intersection.height >= max(elementFrame.height - 1, 1)
  }
}
