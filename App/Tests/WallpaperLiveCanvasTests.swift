import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperLiveCanvasTests: XCTestCase {
  func testOffsetNestedCanvasMatchesFullWindowPixelsBeforeAndAfterRotation() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let full = WallpaperLiveCanvasView(frame: window.bounds)
    let container = UIView(frame: CGRect(x: 32, y: 80, width: 300, height: 600))
    let nested = WallpaperLiveCanvasView(frame: CGRect(x: 15, y: 20, width: 200, height: 450))
    window.addSubview(full)
    window.addSubview(container)
    container.addSubview(nested)
    defer {
      full.removeFromSuperview()
      container.removeFromSuperview()
      window.isHidden = true
    }
    let image = try gradientImage()
    for view in [full, nested] {
      view.configure(
        image: image, settings: .defaultValue, highContrast: false, reducesTransparency: false)
    }
    try assertMatchingPixels(full: full, nested: nested, window: window)

    // A physically shorter content area and a shifted nested page must retain
    // the same full-window crop, including after an actual window bounds change.
    window.bounds.size = CGSize(width: 800, height: 400)
    full.frame = window.bounds
    container.frame = CGRect(x: 70, y: 35, width: 650, height: 300)
    nested.frame = CGRect(x: 10, y: 15, width: 450, height: 240)
    for view in [full, nested] {
      view.setNeedsLayout()
      view.layoutIfNeeded()
    }
    try assertMatchingPixels(full: full, nested: nested, window: window)
  }

  func testLiveCanvasUpdatesOpacityAppearanceImageAndAccessibilityWithoutAnimations() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    let view = WallpaperLiveCanvasView(frame: CGRect(x: 30, y: 40, width: 100, height: 200))
    window.addSubview(view)
    defer {
      view.removeFromSuperview()
      window.isHidden = true
    }
    let red = try solidImage(.red)
    for appearance in WallpaperThemeAppearance.allCases {
      for opacity in [0.0, 0.5, 1.0] {
        let settings = WallpaperThemeSettings(
          appearance: appearance, imageOpacity: opacity, blurRadius: 0, accentRGB: nil)
        view.configure(image: red, settings: settings, highContrast: false, reducesTransparency: false)
        let base = appearance == .dark ? 0.0 : 255.0
        try assertPixel(
          render(view), at: CGPoint(x: 50, y: 100),
          equals: [base * (1 - opacity) + 255 * opacity, base * (1 - opacity), base * (1 - opacity)])
      }
      for (highContrast, reducesTransparency) in [(true, false), (false, true)] {
        var settings = WallpaperThemeSettings.defaultValue
        settings.appearance = appearance
        view.configure(
          image: red, settings: settings,
          highContrast: highContrast, reducesTransparency: reducesTransparency)
        let base = appearance == .dark ? 0.0 : 255.0
        try assertPixel(render(view), at: CGPoint(x: 50, y: 100), equals: [base, base, base])
      }
    }
    view.configure(
      image: try solidImage(.blue), settings: .defaultValue,
      highContrast: false, reducesTransparency: false)
    try assertPixel(render(view), at: CGPoint(x: 50, y: 100), equals: [0, 0, 255])
    XCTAssertTrue((view.layer.animationKeys() ?? []).isEmpty)
    XCTAssertTrue(view.layer.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } ?? false)

    view.removeFromSuperview()
    try assertPixel(render(view), at: CGPoint(x: 50, y: 100), equals: [255, 255, 255])
  }

  private func assertMatchingPixels(
    full: WallpaperLiveCanvasView, nested: WallpaperLiveCanvasView, window: UIWindow
  ) throws {
    let complete = render(full)
    let partial = render(nested)
    for fractionY in [0.1, 0.5, 0.9] {
      for fractionX in [0.1, 0.5, 0.9] {
        let point = CGPoint(
          x: floor(nested.bounds.width * fractionX), y: floor(nested.bounds.height * fractionY))
        let windowPoint = nested.convert(point, to: window)
        let expected = try pixel(complete, at: windowPoint)
        try assertPixel(partial, at: point, equals: expected.map(Double.init))
      }
    }
  }

  private func gradientImage() throws -> CGImage {
    let colors = [UIColor.red.cgColor, UIColor.green.cgColor, UIColor.blue.cgColor] as CFArray
    let gradient = try XCTUnwrap(CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil))
    let image = renderer(size: CGSize(width: 160, height: 240)).image { context in
      context.cgContext.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: 160, y: 240), options: [])
    }
    return try XCTUnwrap(image.cgImage)
  }

  private func solidImage(_ color: UIColor) throws -> CGImage {
    let image = renderer(size: CGSize(width: 10, height: 10)).image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    return try XCTUnwrap(image.cgImage)
  }

  private func render(_ view: UIView) -> UIImage {
    renderer(size: view.bounds.size).image { view.layer.render(in: $0.cgContext) }
  }

  private func renderer(size: CGSize) -> UIGraphicsImageRenderer {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: size, format: format)
  }

  private func assertPixel(
    _ image: UIImage, at point: CGPoint, equals expected: [Double],
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let actual = try pixel(image, at: point)
    for index in 0..<3 {
      XCTAssertEqual(Double(actual[index]), expected[index], accuracy: 4, file: file, line: line)
    }
  }

  private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
    let cgImage = try XCTUnwrap(image.cgImage)
    let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return Array(bytes.prefix(3))
  }
}
