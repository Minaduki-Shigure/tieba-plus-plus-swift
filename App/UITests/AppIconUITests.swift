import XCTest

final class AppIconUITests: XCTestCase {
  // A cold CI simulator can spend several seconds on a single AX snapshot.
  // Leave time for all readiness properties to resolve without skipping them.
  private let interfaceTimeout: TimeInterval = 30

  @MainActor
  func testAlternateIconsRoundTripAndPersistAcrossLaunches() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    defer {
      attachHierarchy(name: "Final app accessibility hierarchy", from: app)
      attachHierarchy(name: "Final SpringBoard accessibility hierarchy", from: springboard)
      attachScreenshot(name: "Final app icon state", from: app)
      let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      screen.name = "Final simulator screen"
      screen.lifetime = .deleteOnSuccess
      add(screen)
    }

    app.launch()
    try openIconSettings(in: app)
    try requireSelected("classic", in: app)
    try require(
      option("light", in: app).isEnabled && option("dark", in: app).isEnabled,
      "The fresh simulator installation must support both alternate app icons."
    )

    try select("light", in: app, springboard: springboard)
    attachScreenshot(name: "Light icon selected", from: app)

    app.terminate()
    app.launch()
    try openIconSettings(in: app)
    try requireSelected("light", in: app)
    attachScreenshot(name: "Light icon retained after relaunch", from: app)

    try select("dark", in: app, springboard: springboard)
    attachScreenshot(name: "Dark icon selected", from: app)
    try select("classic", in: app, springboard: springboard)

    app.terminate()
    app.launch()
    try openIconSettings(in: app)
    try requireSelected("classic", in: app)
    attachScreenshot(name: "Primary icon restored after relaunch", from: app)
  }

  @MainActor
  private func openIconSettings(in app: XCUIApplication) throws {
    let settings = app.buttons["home-settings-entry"].firstMatch
    try tap(settings, description: "Home settings button")
    let appearance = app.descendants(matching: .any)
      .matching(identifier: "settings-category-appearance-and-layout").firstMatch
    try tap(appearance, description: "Appearance and layout settings")
    let icons = app.descendants(matching: .any)
      .matching(identifier: "settings-app-icon").firstMatch
    try tap(icons, description: "App icon settings")
    try require(
      option("classic", in: app).waitForExistence(timeout: interfaceTimeout),
      "The app icon settings page did not appear."
    )
  }

  @MainActor
  private func select(
    _ name: String,
    in app: XCUIApplication,
    springboard: XCUIApplication
  ) throws {
    let selectedOption = option(name, in: app)
    try tap(selectedOption, description: "App icon option \(name)")

    // This is an expected part of the workflow, not an unrelated interruption.
    // Some OS versions expose the notification through the app, others through
    // SpringBoard. A system that omits it must still pass the actual readback.
    let appAlert = app.alerts.firstMatch
    if appAlert.waitForExistence(timeout: 5) {
      try dismissIconNotification(appAlert)
    } else {
      let systemAlert = springboard.alerts.firstMatch
      if systemAlert.waitForExistence(timeout: 5) {
        try dismissIconNotification(systemAlert)
      }
    }

    try requireSelected(name, in: app)
    try require(
      !app.alerts.staticTexts["未能更换图标"].exists,
      "The app reported that the requested icon was not applied."
    )
  }

  @MainActor
  private func dismissIconNotification(_ alert: XCUIElement) throws {
    try require(
      !alert.staticTexts["未能更换图标"].exists,
      "The app reported an icon change failure instead of a system confirmation."
    )
    let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
      .joined(separator: " ")
    try require(
      text.contains("图标") || text.localizedCaseInsensitiveContains("icon"),
      "An unrelated alert interrupted the icon workflow: \(text)"
    )
    try require(
      alert.buttons.count == 1,
      "The expected icon-change notification should only have its acknowledgement button."
    )
    try tap(alert.buttons.firstMatch, description: "System icon-change acknowledgement")
    try wait(
      for: NSPredicate(format: "exists == false"),
      on: alert,
      description: "System icon-change notification dismissal"
    )
  }

  @MainActor
  private func requireSelected(_ name: String, in app: XCUIApplication) throws {
    try wait(
      for: NSPredicate(format: "exists == true AND value == %@", "当前使用"),
      on: option(name, in: app),
      description: "System readback for app icon \(name)"
    )
    for other in ["classic", "light", "dark"] where other != name {
      try require(
        option(other, in: app).value as? String != "当前使用",
        "More than one app icon is marked as currently selected."
      )
    }
  }

  @MainActor
  private func option(_ name: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons["app-icon-option-\(name)"].firstMatch
  }

  @MainActor
  private func tap(_ element: XCUIElement, description: String) throws {
    try wait(
      for: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
      on: element,
      description: description
    )
    element.tap()
  }

  @MainActor
  private func wait(
    for predicate: NSPredicate,
    on element: XCUIElement,
    description: String
  ) throws {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: interfaceTimeout)
    if result != .completed {
      let exists = element.exists
      throw IconUITestFailure(
        message: "Timed out waiting for \(description): exists=\(exists), "
          + "hittable=\(exists && element.isHittable), enabled=\(exists && element.isEnabled)."
      )
    }
  }

  @MainActor
  private func attachHierarchy(name: String, from app: XCUIApplication) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .deleteOnSuccess
    add(attachment)
  }

  @MainActor
  private func attachScreenshot(name: String, from app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .deleteOnSuccess
    add(attachment)
  }

  private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw IconUITestFailure(message: message) }
  }
}

private struct IconUITestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}
