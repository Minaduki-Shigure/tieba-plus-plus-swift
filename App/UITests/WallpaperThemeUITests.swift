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
      hierarchy.lifetime = .keepAlways
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
    try await waitForRotatedEditor(app, landscape: true)
    try tap(app.buttons["wallpaper-theme-save"], app: app)
    try waitForEditorDismissal(app)
    XCUIDevice.shared.orientation = .portrait
    try openEditorFromAppearance(app)
    try requireStatus("已启用", app: app)
    try await waitForRotatedEditor(app, landscape: false)
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
    let reset = app.buttons["wallpaper-theme-reset"]
    try reveal(reset, app: app)
    let tabBar = app.tabBars["root-tab-bar"]
    XCTAssertTrue(tabBar.exists, "The root tab bar must remain available in the editor.")
    XCTAssertLessThanOrEqual(
      reset.frame.maxY, tabBar.frame.minY + 1,
      "The final editor action must be fully above the tab bar after scrolling to it.")
    try tap(reset, app: app)
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
      let distance = visible.height * (targetFrame.midY > visible.midY ? -0.5 : 0.5)
      try dragScrollableContent(
        app, scroll: scrollView, tracking: element, visible: visible, distance: distance)
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
  private func dragScrollableContent(
    _ app: XCUIApplication, scroll: XCUIElement, tracking target: XCUIElement,
    visible: CGRect, distance: CGFloat
  ) throws {
    // A ScrollView's AX frame includes margins that do not reliably consume
    // scrolling gestures in either orientation. Reveal and rotation both start
    // on actual visible content, outside controls with their own drag gestures.
    let usable = visible.insetBy(dx: 4, dy: 8)
    let downward = distance > 0
    let before = target.frame
    var excludedFrames = scroll.sliders.allElementsBoundByIndex.map(\.frame)
      + scroll.segmentedControls.allElementsBoundByIndex.map(\.frame)
    let crop = scroll.descendants(matching: .any)
      .matching(identifier: "wallpaper-theme-crop").firstMatch
    if crop.exists { excludedFrames.append(crop.frame) }
    let texts = scroll.staticTexts.allElementsBoundByIndex
    let buttons = scroll.buttons.allElementsBoundByIndex
    var candidate: (element: XCUIElement, point: CGPoint, travel: CGFloat)?
    for group in [texts, buttons] {
      for element in group {
        guard element.exists else { continue }
        let frame = element.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let travel = downward ? usable.maxY - point.y : point.y - usable.minY
        guard !frame.isEmpty, !frame.isNull, usable.contains(point),
          !excludedFrames.contains(where: { $0.contains(point) }), travel >= 24,
          travel > (candidate?.travel ?? 0), element.isHittable
        else { continue }
        candidate = (element, point, travel)
      }
      // Prefer text. If a short drag moves every heading offscreen, a vertical
      // drag on an ordinary button can still scroll without tapping it.
      if candidate != nil { break }
    }
    guard let candidate else {
      throw WallpaperUITestError.unavailable(
        "No visible content can begin a scroll: target=\(target.identifier) \(before), "
          + "viewport=\(visible), excluded=\(excludedFrames)")
    }
    let delta = min(abs(distance), candidate.travel) * (downward ? 1.0 : -1.0)
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: candidate.point.x, dy: candidate.point.y))
    let end = origin.withOffset(CGVector(dx: candidate.point.x, dy: candidate.point.y + delta))
    start.press(forDuration: 0.05, thenDragTo: end)
    let after = target.frame
    guard (after.minY - before.minY) * (downward ? 1.0 : -1.0) > 1 else {
      throw WallpaperUITestError.unavailable(
        "Content did not scroll from \(candidate.element.label) at \(candidate.point) "
          + "by \(delta): target=\(target.identifier), before=\(before), after=\(after)")
    }
  }

  /// Save can still be enabled for the previous viewport during rotation. Require
  /// UIKit's window/chrome and the model-driven crop to agree on the new geometry.
  @MainActor
  private func waitForRotatedEditor(_ app: XCUIApplication, landscape: Bool) async throws {
    let deadline = Date().addingTimeInterval(interfaceTimeout)
    var previous: WallpaperEditorGeometry?
    var stableSamples = 0
    var lastGeometry: WallpaperEditorGeometry?
    var succeeded = false
    defer {
      attachRotationEvidence(app, geometry: lastGeometry, landscape: landscape)
    }
    repeat {
      guard app.state == .runningForeground else {
        throw WallpaperUITestError.unavailable("The editor left the foreground during rotation.")
      }
      let crop = app.descendants(matching: .any)
        .matching(identifier: "wallpaper-theme-crop").firstMatch
      let scroll = app.scrollViews["wallpaper-theme-editor-scroll"]
      if crop.exists, scroll.exists, app.windows.firstMatch.exists,
        app.navigationBars.firstMatch.exists, app.tabBars.firstMatch.exists
      {
        let geometry = WallpaperEditorGeometry(
          app: app.frame,
          window: app.windows.firstMatch.frame,
          scroll: scroll.frame,
          navigation: app.navigationBars.firstMatch.frame,
          tab: app.tabBars.firstMatch.frame,
          crop: crop.frame,
          saveEnabled: app.buttons["wallpaper-theme-save"].isEnabled
        )
        lastGeometry = geometry
        if geometry.matchesOrientation(landscape: landscape) {
          let visible = geometry.visibleViewport
          let intersection = geometry.crop.intersection(visible)
          let requiredHeight = min(geometry.crop.height, visible.height) * 0.7
          if intersection.isNull || intersection.height < requiredHeight {
            // A crop may legitimately be taller than the landscape viewport.
            // Bring its center into view without dragging inside the crop gesture.
            let distance = max(-visible.height * 0.6, min(
              visible.height * 0.6, visible.midY - geometry.crop.midY))
            try dragScrollableContent(
              app, scroll: scroll, tracking: crop, visible: visible, distance: distance)
            stableSamples = 0
            previous = nil
          } else if crop.isHittable, geometry.saveEnabled {
            stableSamples = geometry == previous ? stableSamples + 1 : 1
            previous = geometry
            if stableSamples >= 3 {
              succeeded = true
              break
            }
          } else {
            stableSamples = 0
            previous = nil
          }
        } else {
          stableSamples = 0
          previous = nil
        }
      } else {
        stableSamples = 0
        previous = nil
      }
      try await Task.sleep(nanoseconds: 150_000_000)
    } while Date() < deadline
    guard succeeded else {
      throw WallpaperUITestError.unavailable(
        "Editor did not settle into \(landscape ? "landscape" : "portrait"): \(String(describing: lastGeometry))"
      )
    }
  }

  @MainActor
  private func attachRotationEvidence(
    _ app: XCUIApplication, geometry: WallpaperEditorGeometry?, landscape: Bool
  ) {
    let name = "Wallpaper editor \(landscape ? "landscape" : "portrait")"
    let appScreenshot = app.screenshot()
    let screenScreenshot = XCUIScreen.main.screenshot()
    var screenshots = [("app", appScreenshot), ("screen", screenScreenshot)]
    if app.windows.firstMatch.exists {
      screenshots.append(("window", app.windows.firstMatch.screenshot()))
    }
    let details = screenshots.map { source, screenshot in
      let image = screenshot.image
      return "\(source): size=\(image.size), orientation=\(image.imageOrientation.rawValue), "
        + "pixels=\(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0)"
    }.joined(separator: "\n")
    let hierarchy = XCTAttachment(string:
      "state=\(app.state.rawValue)\ndeviceOrientation=\(XCUIDevice.shared.orientation.rawValue)\n"
        + "geometry=\(String(describing: geometry))\n\(details)\n\n\(app.debugDescription)")
    hierarchy.name = "\(name) geometry and hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    for (source, screenshot) in screenshots {
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "\(name) \(source) capture"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    // Screen capture avoids relying on an element's potentially stale rotation
    // crop. Keep the app/window captures above so discrepancies remain visible.
    XCTAssertEqual(app.state, .runningForeground)
    let image = screenScreenshot.image
    let swapped = [UIImage.Orientation.left, .leftMirrored, .right, .rightMirrored]
      .contains(image.imageOrientation)
    let width = swapped ? image.cgImage?.height : image.cgImage?.width
    let height = swapped ? image.cgImage?.width : image.cgImage?.height
    if let width, let height, let geometry, geometry.window.height > 0 {
      XCTAssertEqual(
        Double(width) / Double(height),
        Double(geometry.window.width / geometry.window.height),
        accuracy: 0.02,
        "The screen capture must match the observed app window orientation."
      )
    } else {
      XCTFail("Rotation evidence did not contain a screen image and window geometry.")
    }
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

private struct WallpaperEditorGeometry: Equatable {
  let app: CGRect
  let window: CGRect
  let scroll: CGRect
  let navigation: CGRect
  let tab: CGRect
  let crop: CGRect
  let saveEnabled: Bool

  var visibleViewport: CGRect {
    let bounds = scroll.intersection(window)
    let top = max(bounds.minY, navigation.maxY)
    let bottom = min(bounds.maxY, tab.minY)
    return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
  }

  func matchesOrientation(landscape: Bool) -> Bool {
    guard
      app.width > 0, app.height > 0, window.width > 0, window.height > 0,
      crop.width > 0, crop.height > 0,
      (app.width > app.height) == landscape,
      (window.width > window.height) == landscape,
      abs(app.width - window.width) < 2, abs(app.height - window.height) < 2,
      navigation.width > navigation.height * 3,
      navigation.width >= window.width * 0.7,
      visibleViewport.width > 16, visibleViewport.height > 64,
      crop.minX >= visibleViewport.minX - 1,
      crop.maxX <= visibleViewport.maxX + 1
    else { return false }
    return abs(crop.width / crop.height - window.width / window.height) < 0.02
  }
}

private enum WallpaperUITestError: Error {
  case unavailable(String)
}
