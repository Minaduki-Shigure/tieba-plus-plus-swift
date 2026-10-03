import UIKit
import XCTest

final class WallpaperThemeUITests: XCTestCase {
  private let interfaceTimeout: TimeInterval = 30

  /// The DEBUG fixture exercises the real editor, processor, repository and theme
  /// application. System Photos authorization/import remains a separate device check.
  @MainActor
  func testDraftCancelSaveRelaunchAndRestoreDefault() async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--wallpaper-theme-ui-testing",
    ]
    defer {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Wallpaper theme final hierarchy"
      hierarchy.lifetime = .deleteOnSuccess
      add(hierarchy)
      attachScreenshot("Wallpaper theme final state", app: app)
      XCUIDevice.shared.orientation = .portrait
    }
    app.launch()
    try openEditor(app)
    if app.staticTexts["wallpaper-theme-status"].label == "已启用"
      || app.buttons["wallpaper-theme-reset"].isEnabled
    {
      try waitUntilEnabled(app.buttons["wallpaper-theme-reset"])
      try restoreDefault(app)
      try openEditorFromAppearance(app)
    }
    try requireStatus("尚未启用", app: app)
    try tap(app.buttons["wallpaper-theme-test-image"], app: app)
    try waitUntilEnabled(app.buttons["wallpaper-theme-save"])
    try tap(app.buttons["wallpaper-theme-cancel"], app: app)
    try openEditorFromAppearance(app)
    try requireStatus("尚未启用", app: app)
    XCTAssertFalse(app.buttons["wallpaper-theme-save"].isEnabled)

    try tap(app.buttons["wallpaper-theme-test-image"], app: app)
    try waitUntilEnabled(app.buttons["wallpaper-theme-save"])
    let opacity = app.sliders["wallpaper-theme-opacity"]
    try reveal(opacity, app: app)
    opacity.adjust(toNormalizedSliderPosition: 1)
    let appearance = app.segmentedControls["wallpaper-theme-appearance"]
    try tap(appearance.buttons["深色"], app: app)
    let blur = app.sliders["wallpaper-theme-blur"]
    try reveal(blur, app: app)
    blur.adjust(toNormalizedSliderPosition: 0.3)
    try waitUntilEnabled(app.buttons["wallpaper-theme-save"])
    attachScreenshot("Unsaved wallpaper preview", app: app)
    try tap(app.buttons["wallpaper-theme-save"], app: app)
    try waitForEditorDismissal(app)

    app.terminate()
    app.launch()
    let themedHome = try await captureColoredHome(app)
    attachImage("Saved wallpaper visible on cold-launch Home", image: themedHome.image)
    try openEditor(app)
    try requireStatus("已启用", app: app)
    try waitUntilEnabled(app.buttons["wallpaper-theme-save"])
    let restoredAppearance = app.segmentedControls["wallpaper-theme-appearance"]
    try reveal(restoredAppearance, app: app)
    XCTAssertTrue(restoredAppearance.buttons["深色"].isSelected)
    attachScreenshot("Wallpaper restored after relaunch", app: app)

    XCUIDevice.shared.orientation = .landscapeLeft
    try waitUntilEnabled(app.buttons["wallpaper-theme-save"])
    attachScreenshot("Wallpaper editor landscape crop", app: app)
    XCUIDevice.shared.orientation = .portrait
    try restoreDefault(app)

    app.terminate()
    app.launch()
    try waitForHome(app)
    let defaultHome = try captureHome(app)
    attachImage("Default Home after wallpaper removal", image: defaultHome.image)
    try requireWallpaperDifference(themed: themedHome, restored: defaultHome)
    try openEditor(app)
    try requireStatus("尚未启用", app: app)
    XCTAssertFalse(app.buttons["wallpaper-theme-save"].isEnabled)
  }

  @MainActor
  private func openEditor(_ app: XCUIApplication) throws {
    try tap(app.buttons["home-settings-entry"].firstMatch, app: app)
    try tap(
      app.descendants(matching: .any)
        .matching(identifier: "settings-category-appearance-and-layout").firstMatch,
      app: app
    )
    try openEditorFromAppearance(app)
  }

  @MainActor
  private func openEditorFromAppearance(_ app: XCUIApplication) throws {
    try tap(
      app.descendants(matching: .any).matching(identifier: "settings-wallpaper-theme").firstMatch,
      app: app
    )
    try waitUntilEnabled(app.buttons["wallpaper-theme-test-image"])
  }

  @MainActor
  private func restoreDefault(_ app: XCUIApplication) throws {
    try tap(app.buttons["wallpaper-theme-reset"], app: app)
    try tap(app.buttons["wallpaper-theme-confirm-reset"], app: app)
    try waitForEditorDismissal(app)
  }

  @MainActor
  private func waitForEditorDismissal(_ app: XCUIApplication) throws {
    try wait(
      NSPredicate(format: "exists == false"),
      element: app.buttons["wallpaper-theme-save"]
    )
  }

  @MainActor
  private func requireStatus(_ status: String, app: XCUIApplication) throws {
    try wait(
      NSPredicate(format: "exists == true AND label == %@", status),
      element: app.staticTexts["wallpaper-theme-status"]
    )
  }

  @MainActor
  private func tap(_ element: XCUIElement, app: XCUIApplication) throws {
    try reveal(element, app: app)
    try wait(NSPredicate(format: "hittable == true AND enabled == true"), element: element)
    element.tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) throws {
    guard element.waitForExistence(timeout: interfaceTimeout) else {
      throw WallpaperUITestError.unavailable("Missing element: \(element.identifier)")
    }
    if element.isHittable { return }
    let editorScrollView = app.scrollViews["wallpaper-theme-editor-scroll"]
    let scrollView = editorScrollView.exists
      ? editorScrollView
      : app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
    guard scrollView.exists else {
      throw WallpaperUITestError.unavailable(
        "No scroll container for element: \(element.identifier)")
    }
    for _ in 0..<12 {
      let scrollFrame = scrollView.frame
      var visible = scrollFrame.intersection(app.frame)
      let navigationBar = app.navigationBars.firstMatch
      if navigationBar.exists, navigationBar.frame.intersects(visible) {
        let top = max(visible.minY, navigationBar.frame.maxY)
        visible = CGRect(x: visible.minX, y: top, width: visible.width,
          height: max(0, visible.maxY - top))
      }
      let tabBar = app.tabBars.firstMatch
      if tabBar.exists, tabBar.frame.intersects(visible) {
        visible.size.height = max(0, min(visible.maxY, tabBar.frame.minY) - visible.minY)
      }
      guard visible.width > 16, visible.height > 64 else {
        throw WallpaperUITestError.unavailable(
          "Scroll container has no usable viewport: \(scrollFrame)")
      }
      let targetFrame = element.frame
      guard !targetFrame.isEmpty, !targetFrame.isNull else {
        throw WallpaperUITestError.unavailable(
          "Element has no layout frame: \(element.identifier)")
      }
      let movesUp = targetFrame.midY > visible.midY
      let upperY = visible.minY + visible.height * 0.25
      let lowerY = visible.minY + visible.height * 0.75
      // The editor has 16pt content padding. Its center contains the crop's
      // drag gesture and sliders, so scroll through the empty leading margin.
      let origin = scrollView.coordinate(withNormalizedOffset: .zero)
      let marginX = visible.minX + 8 - scrollFrame.minX
      let start = origin.withOffset(CGVector(
        dx: marginX, dy: (movesUp ? lowerY : upperY) - scrollFrame.minY))
      let end = origin.withOffset(CGVector(
        dx: marginX, dy: (movesUp ? upperY : lowerY) - scrollFrame.minY))
      start.press(forDuration: 0.05, thenDragTo: end)
      if element.isHittable { return }
    }
    throw WallpaperUITestError.unavailable(
      "Element is not visible: \(element.identifier), target: \(element.frame), container: \(scrollView.frame)")
  }

  @MainActor
  private func waitUntilEnabled(_ element: XCUIElement) throws {
    try wait(NSPredicate(format: "exists == true AND enabled == true"), element: element)
  }

  @MainActor
  private func wait(_ predicate: NSPredicate, element: XCUIElement) throws {
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: interfaceTimeout
    )
    guard result == .completed else {
      throw WallpaperUITestError.unavailable(
        "Timed out waiting for \(element.identifier): \(predicate.predicateFormat)"
      )
    }
  }

  @MainActor
  private func attachScreenshot(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func waitForHome(_ app: XCUIApplication) throws {
    try wait(
      NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
      element: app.buttons["home-settings-entry"].firstMatch
    )
    try wait(NSPredicate(format: "exists == true"), element: app.tabBars.firstMatch)
    try wait(NSPredicate(format: "exists == true"), element: app.navigationBars.firstMatch)
  }

  /// Wait for the actual saved image to reach Home. Launch-time chrome can become
  /// accessible before the asynchronous repository load has installed the wallpaper.
  @MainActor
  private func captureColoredHome(_ app: XCUIApplication) async throws -> WallpaperHomeCapture {
    try waitForHome(app)
    let deadline = Date().addingTimeInterval(interfaceTimeout)
    var lastFailure = "No Home screenshot was captured."
    repeat {
      let capture = try captureHome(app)
      var missingRegions: [String] = []
      for region in capture.regions {
        let colored = try region.points.filter {
          try colorSpread(capture.image, point: $0, frame: capture.frame) > 5
        }.count
        if colored < region.requiredColoredPoints {
          missingRegions.append("\(region.name): \(colored)/\(region.points.count) colored samples")
        }
      }
      if missingRegions.isEmpty { return capture }
      lastFailure = missingRegions.joined(separator: "; ")
      try await Task.sleep(nanoseconds: 150_000_000)
    } while Date() < deadline
    throw WallpaperUITestError.unavailable(
      "Saved wallpaper did not become visible through real Home surfaces: \(lastFailure)"
    )
  }

  @MainActor
  private func captureHome(_ app: XCUIApplication) throws -> WallpaperHomeCapture {
    let frame = app.frame
    let navigation = app.navigationBars.firstMatch.frame
    let tab = app.tabBars.firstMatch.frame
    guard frame.width > 0, frame.height > 0, navigation.height > 0, tab.height > 0 else {
      throw WallpaperUITestError.unavailable(
        "Home does not expose its native navigation and tab bars.")
    }
    // Six points from the leading edge stays outside Home's inset list cards,
    // title glyphs and toolbar/tab icons. Use three points per native bar so a
    // separator or a single antialiased pixel cannot decide the result.
    let x = frame.minX + 6
    let listTop = navigation.maxY + 8
    let listBottom = tab.minY - 8
    guard listBottom > listTop else {
      throw WallpaperUITestError.unavailable(
        "Home list has no visible canvas between its native bars.")
    }
    let regions = [
      WallpaperHomeRegion(
        name: "navigation bar",
        points: [-4.0, 0, 4].map { CGPoint(x: x, y: navigation.midY + $0) },
        requiredColoredPoints: 2
      ),
      WallpaperHomeRegion(
        name: "list canvas",
        points: [0.12, 0.28, 0.44, 0.60, 0.76, 0.92].map {
          CGPoint(x: x, y: listTop + (listBottom - listTop) * $0)
        },
        requiredColoredPoints: 4
      ),
      WallpaperHomeRegion(
        name: "tab bar",
        points: [-4.0, 0, 4].map { CGPoint(x: x, y: tab.midY + $0) },
        requiredColoredPoints: 2
      ),
    ]
    return WallpaperHomeCapture(image: app.screenshot().image, frame: frame, regions: regions)
  }

  @MainActor
  private func requireWallpaperDifference(
    themed: WallpaperHomeCapture, restored: WallpaperHomeCapture
  ) throws {
    for region in themed.regions {
      let changed = try region.points.filter { point in
        let relativeX = (point.x - themed.frame.minX) / themed.frame.width
        let relativeY = (point.y - themed.frame.minY) / themed.frame.height
        let restoredPoint = CGPoint(
          x: restored.frame.minX + relativeX * restored.frame.width,
          y: restored.frame.minY + relativeY * restored.frame.height
        )
        let withWallpaper = try colorSpread(themed.image, point: point, frame: themed.frame)
        let withoutWallpaper = try colorSpread(
          restored.image, point: restoredPoint, frame: restored.frame
        )
        return withWallpaper - withoutWallpaper > 5
      }.count
      XCTAssertGreaterThanOrEqual(
        changed, region.requiredColoredPoints,
        "The saved image must add visible color to Home's \(region.name), compared with restored defaults."
      )
    }
  }

  /// Crop a single source pixel before drawing to avoid orientation assumptions
  /// or accidental full-size decoding for each sample. RGBA byte order is explicit.
  @MainActor
  private func colorSpread(_ image: UIImage, point: CGPoint, frame: CGRect) throws -> Int {
    let source = try XCTUnwrap(image.cgImage)
    let x = Int(((point.x - frame.minX) * CGFloat(source.width) / frame.width).rounded(.down))
    let y = Int(((point.y - frame.minY) * CGFloat(source.height) / frame.height).rounded(.down))
    guard x >= 0, y >= 0, x < source.width, y < source.height else {
      throw WallpaperUITestError.unavailable(
        "Home screenshot sample lies outside the captured image.")
    }
    let pixel = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let channels = bytes.prefix(3).map(Int.init)
    return (channels.max() ?? 0) - (channels.min() ?? 0)
  }

  @MainActor
  private func attachImage(_ name: String, image: UIImage) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private struct WallpaperHomeCapture {
  let image: UIImage
  let frame: CGRect
  let regions: [WallpaperHomeRegion]
}

private struct WallpaperHomeRegion {
  let name: String
  let points: [CGPoint]
  let requiredColoredPoints: Int
}

private enum WallpaperUITestError: Error {
  case unavailable(String)
}
