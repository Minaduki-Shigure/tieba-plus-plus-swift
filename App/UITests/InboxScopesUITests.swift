import UIKit
import XCTest

/// Real RootView, account-bound inbox models, native Lists and detail routes.
/// The DEBUG fixture supplies only offline data and observes actual requests.
final class InboxScopesUITests: XCTestCase {
  @MainActor
  func testBothPositionsSurviveNativeSwipesDetailReturnAndMainTabChanges() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    scrollUp(app)
    scrollUp(app)
    let reply = try anchor(.replies, app: app)
    try select(.mentions, app: app)
    try requireMessage(.mentions, number: 1, app: app)
    scrollUp(app)
    scrollUp(app)
    let mention = try anchor(.mentions, app: app)
    try counts(replies: 1, mentions: 1, app: app)

    for _ in 0..<2 {
      try select(.replies, app: app)
      try position(reply, context: "Retained reply position", app: app)
      try select(.mentions, app: app)
      try position(mention, context: "Retained mention position", app: app)
    }
    try select(.replies, app: app)
    try position(reply, context: "Reply before opening detail", app: app)
    try tap(app.staticTexts[reply.title].firstMatch)
    try wait("Real thread detail is visible") {
      app.staticTexts["离线帖子正文"].firstMatch.isHittable
    }
    edgeBack(app)
    try position(reply, context: "Reply position after detail return", app: app)
    try counts(replies: 1, mentions: 1, posts: 1, app: app)

    horizontalSwipe(left: true, app: app)
    try position(mention, context: "Native swipe to retained mentions", app: app)
    horizontalSwipe(left: false, app: app)
    try position(reply, context: "Native swipe back to retained replies", app: app)
    try tap(app.buttons["root-tab-home"])
    try wait("Home is selected") { app.buttons["root-tab-home"].isSelected }
    try tap(app.buttons["root-tab-notifications"])
    try position(reply, context: "Reply position after switching main tabs", app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Mention position after switching main tabs", app: app)
    try counts(replies: 1, mentions: 1, posts: 1, app: app)
    try requestLog(["replies:1", "mentions:1"], app: app)
  }

  @MainActor
  func testSecondPageAndEachPullRefreshPreserveTheOtherChannelPosition() throws {
    let app = try launchFixture()
    defer { attachState(app) }
    try reveal(.replies, number: 21, app: app)
    let secondPageReply = try anchor(.replies, app: app)
    try counts(replies: 2, mentions: 0, page2: 1, app: app)
    try select(.mentions, app: app)
    try requireMessage(.mentions, number: 1, app: app)

    pullToRefresh(app)
    try counts(replies: 2, mentions: 2, page2: 1, app: app)
    try requireMessage(.mentions, number: 1, app: app)
    scrollUp(app)
    scrollUp(app)
    let mention = try anchor(.mentions, app: app)
    try select(.replies, app: app)
    try position(
      secondPageReply, context: "Retained reply page two after mention refresh", app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Retained mentions after returning to page two", app: app)
    try select(.replies, app: app)
    try returnToFirstMessage(.replies, app: app)
    pullToRefresh(app)
    try counts(replies: 3, mentions: 2, page2: 1, app: app)
    try requireMessage(.replies, number: 1, app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Mention position after reply refresh", app: app)
    try counts(replies: 3, mentions: 2, page2: 1, app: app)
    try requestLog(
      ["replies:1", "replies:2", "mentions:1", "mentions:1", "replies:1"], app: app)
  }

  @MainActor
  func testFailedRefreshRetainsMessagesAndCursorWhileOtherChannelStaysUntouched() throws {
    let app = try launchFixture(failsFirstRefresh: true)
    defer { attachState(app) }
    try select(.mentions, app: app)
    try requireMessage(.mentions, number: 1, app: app)
    scrollUp(app)
    scrollUp(app)
    let mention = try anchor(.mentions, app: app)
    try select(.replies, app: app)
    try requireMessage(.replies, number: 1, app: app)

    pullToRefresh(app)
    let alert = app.alerts["刷新失败"]
    try wait("A real refresh error is presented") {
      alert.exists && alert.staticTexts["离线回复刷新失败"].exists
    }
    try tap(alert.buttons["好"])
    try requireMessage(.replies, number: 1, app: app)
    try counts(replies: 2, mentions: 1, app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Mention position after failed reply refresh", app: app)
    try select(.replies, app: app)
    try requireMessage(.replies, number: 1, app: app)

    // Continue the retained first-page cursor before retrying the refresh.
    // A cleared snapshot or a skipped page cannot satisfy this request log.
    try reveal(.replies, number: 21, app: app)
    try counts(replies: 3, mentions: 1, page2: 1, app: app)
    try requestLog(["replies:1", "mentions:1", "replies:1", "replies:2"], app: app)
    let paginated = try anchor(.replies, app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Other channel after retained-cursor pagination", app: app)
    try select(.replies, app: app)
    try position(
      paginated, context: "Page two survived failed refresh and channel switches", app: app)
    try returnToFirstMessage(.replies, app: app)
    pullToRefresh(app)
    try counts(replies: 4, mentions: 1, page2: 1, app: app)
    XCTAssertFalse(app.alerts["刷新失败"].exists)
    try requireMessage(.replies, number: 1, app: app)
    try select(.mentions, app: app)
    try position(mention, context: "Other channel after successful refresh retry", app: app)
    try counts(replies: 4, mentions: 1, page2: 1, app: app)
    try requestLog(
      ["replies:1", "mentions:1", "replies:1", "replies:2", "replies:1"], app: app)
  }

  private enum Channel: String {
    case replies, mentions
    var prefix: String { self == .replies ? "回复消息·第" : "提及消息·第" }
    func title(_ number: Int) -> String { "\(prefix)\(number)条" }
  }

  private struct Anchor {
    let title: String
    let y: CGFloat
  }

  @MainActor
  private func launchFixture(failsFirstRefresh: Bool = false) throws -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--inbox-scopes-ui-testing",
    ]
    if failsFirstRefresh { app.launchArguments.append("--inbox-scopes-refresh-failure") }
    app.launch()
    try counts(replies: 0, mentions: 0, app: app)
    try tap(app.buttons["root-tab-notifications"])
    try requireMessage(.replies, number: 1, app: app)
    try counts(replies: 1, mentions: 0, app: app)
    return app
  }

  @MainActor
  private func select(_ channel: Channel, app: XCUIApplication) throws {
    try tap(app.buttons["inbox-kind-\(channel.rawValue)"])
  }

  @MainActor
  private func requireMessage(_ channel: Channel, number: Int, app: XCUIApplication) throws {
    let element = app.staticTexts[channel.title(number)].firstMatch
    try wait(
      "Visible \(channel.rawValue) message \(number)", diagnostics: { element.debugDescription },
      until: { self.fullyVisible(element, app: app) })
  }

  @MainActor
  private func fullyVisible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
    let bottom = app.tabBars["root-tab-bar"].frame.minY
    let top = app.buttons["inbox-kind-replies"].frame.maxY
    return element.isHittable && element.frame.minY > top + 6
      && element.frame.maxY < bottom - 12
  }

  @MainActor
  private func anchor(_ channel: Channel, app: XCUIApplication) throws -> Anchor {
    let messages = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", channel.prefix))
    var previous: Anchor?
    var stable = 0
    try wait("Find a stable visible \(channel.rawValue) anchor") {
      guard
        let element = messages.allElementsBoundByIndex.first(where: {
          self.fullyVisible($0, app: app) && $0.frame.minY > app.frame.height * 0.4
        })
      else { return false }
      let candidate = Anchor(title: element.label, y: element.frame.minY)
      if let previous, previous.title == candidate.title, abs(previous.y - candidate.y) < 1 {
        stable += 1
      } else {
        stable = 0
      }
      previous = candidate
      return stable >= 2
    }
    return try XCTUnwrap(previous)
  }

  @MainActor
  private func position(_ saved: Anchor, context: String, app: XCUIApplication) throws {
    let element = app.staticTexts[saved.title].firstMatch
    try wait(
      context, diagnostics: { "expectedY=\(saved.y), frame=\(element.frame)" },
      until: { self.fullyVisible(element, app: app) && abs(element.frame.minY - saved.y) < 3 })
  }

  @MainActor
  private func reveal(_ channel: Channel, number: Int, app: XCUIApplication) throws {
    let target = app.staticTexts[channel.title(number)].firstMatch
    for _ in 0..<24 {
      if fullyVisible(target, app: app) { break }
      scrollUp(app)
    }
    try requireMessage(channel, number: number, app: app)
  }

  @MainActor
  private func returnToFirstMessage(_ channel: Channel, app: XCUIApplication) throws {
    let first = app.staticTexts[channel.title(1)].firstMatch
    // Short, slow drags near the top avoid flinging past it and accidentally
    // triggering an extra refresh before the deliberate pull below.
    for _ in 0..<55 {
      if fullyVisible(first, app: app) { return }
      let distance: CGFloat
      if first.exists {
        let missingDistance = app.buttons["inbox-kind-replies"].frame.maxY + 10 - first.frame.minY
        distance = min(100, max(12, missingDistance))
      } else {
        distance = 100
      }
      drag(
        app, from: CGVector(dx: 0.5, dy: 0.42),
        to: CGVector(dx: 0.5, dy: 0.42 + distance / app.frame.height))
    }
    try requireMessage(channel, number: 1, app: app)
  }

  @MainActor
  private func counts(
    replies: Int, mentions: Int, page2: Int = 0, page3: Int = 0, posts: Int = 0,
    app: XCUIApplication
  ) throws {
    let expected =
      "replies=\(replies) mentions=\(mentions) page2=\(page2) page3=\(page3) posts=\(posts) unexpected=0"
    let counter = app.staticTexts["inbox-scope-request-counts"]
    try wait(
      "Inbox request counts", diagnostics: { "expected=\(expected), actual=\(counter.label)" },
      until: { counter.exists && counter.label == expected })
    let unchanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected), object: counter)
    unchanged.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 0.75), .completed)
  }

  @MainActor
  private func requestLog(_ expected: [String], app: XCUIApplication) throws {
    XCTAssertEqual(
      app.staticTexts["inbox-scope-request-log"].label, expected.joined(separator: " | "))
  }

  @MainActor
  private func tap(_ element: XCUIElement) throws {
    try wait("Tap target", diagnostics: { element.debugDescription }, until: { element.isHittable })
    element.tap()
  }

  @MainActor
  private func scrollUp(_ app: XCUIApplication) {
    drag(app, from: CGVector(dx: 0.5, dy: 0.8), to: CGVector(dx: 0.5, dy: 0.4))
  }

  @MainActor
  private func pullToRefresh(_ app: XCUIApplication) {
    drag(app, from: CGVector(dx: 0.5, dy: 0.32), to: CGVector(dx: 0.5, dy: 0.85))
  }

  @MainActor
  private func horizontalSwipe(left: Bool, app: XCUIApplication) {
    drag(
      app, from: CGVector(dx: left ? 0.85 : 0.15, dy: 0.6),
      to: CGVector(dx: left ? 0.15 : 0.85, dy: 0.6))
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
      throw InboxScopesUITestError.timedOut(message)
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Inbox scope final hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Inbox scope final screen"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}

private enum InboxScopesUITestError: Error { case timedOut(String) }
