import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeSurfaceTests: XCTestCase {
  func testStandardAccentContrastOnKnownOpaqueCanvasAndEveryPreset() throws {
    let selections =
      AppAccentColor.allCases.map(AppAccentColorSelection.preset)
      + [0x000000, 0xFFFFFF, 0xFFFF00, 0xFF00FF, 0x00FFFF].map {
        .custom(AppAccentColorSeed(rgb: UInt32($0))!)
      }
    for selection in selections {
      let style = AppAccentColorStyle(selection: selection)
      for appearance in AppAccentColorAppearance.allCases {
        // These are the opaque appearance bases, not arbitrary wallpaper colors.
        let background: UInt32 = appearance.isDark ? 0x000000 : 0xFFFFFF
        let required = appearance.isHighContrast ? 7.0 : 4.5
        XCTAssertGreaterThanOrEqual(
          AppAccentColorContrast.contrastRatio(
            style.components(for: appearance), AppAccentColorComponents(rgb: background)),
          required, "\(selection) \(appearance)")
      }
    }
  }

  func testAccessibilityMakesEverySemanticSurfaceOpaque() {
    for appearance in WallpaperThemeAppearance.allCases {
      for role in AppSurfaceRole.allCases {
        XCTAssertEqual(
          WallpaperThemeSurfacePolicy.surfaceOpacity(
            for: role, appearance: appearance, highContrast: true, reducesTransparency: false), 1)
        XCTAssertEqual(
          WallpaperThemeSurfacePolicy.surfaceOpacity(
            for: role, appearance: appearance, highContrast: false, reducesTransparency: true), 1)
      }
    }
    XCTAssertEqual(
      WallpaperThemeSurfacePolicy.canvasOpacity(
        highContrast: false, reducesTransparency: false), 0)
    XCTAssertEqual(
      WallpaperThemeSurfacePolicy.canvasOpacity(
        highContrast: true, reducesTransparency: false), 1)
    XCTAssertEqual(
      WallpaperThemeSurfacePolicy.canvasOpacity(
        highContrast: false, reducesTransparency: true), 1)
  }

  func testWallpaperOpacityActuallyRendersItsEndpointsAndHalfBlend() async throws {
    for appearance in WallpaperThemeAppearance.allCases {
      for opacity in [0.0, 0.5, 1.0] {
        let rendered = try await captureCanvas(appearance: appearance, imageOpacity: opacity)
        attach(rendered, name: "\(appearance)-wallpaper-opacity-\(opacity)")
        let actual = try pixel(
          rendered, point: CGPoint(x: rendered.size.width / 2, y: rendered.size.height / 2))
        let base = appearance == .dark ? 0.0 : 255.0
        // A solid red image blends directly with the appearance's white or black base.
        // The middle value detects an extra tint layer as well as incorrect endpoints.
        let expectedRed = base * (1 - opacity) + 255 * opacity
        let expectedGreenAndBlue = base * (1 - opacity)
        let context = "\(appearance) opacity \(opacity)"
        XCTAssertEqual(Double(actual.0), expectedRed, accuracy: 4, context)
        XCTAssertEqual(Double(actual.1), expectedGreenAndBlue, accuracy: 4, context)
        XCTAssertEqual(Double(actual.2), expectedGreenAndBlue, accuracy: 4, context)
      }
    }
  }

  func testAccessibilityActuallyRendersAnOpaqueCanvas() async throws {
    let modes: [(String, Bool, Bool)] = [
      ("increased-contrast", true, false),
      ("reduced-transparency", false, true),
    ]
    for appearance in WallpaperThemeAppearance.allCases {
      for (name, highContrast, reducesTransparency) in modes {
        let rendered = try await captureCanvas(
          appearance: appearance, imageOpacity: 1, highContrast: highContrast,
          reducesTransparency: reducesTransparency)
        attach(rendered, name: "\(appearance)-\(name)-opaque-canvas")
        let actual = try pixel(
          rendered, point: CGPoint(x: rendered.size.width / 2, y: rendered.size.height / 2))
        let expected = appearance == .dark ? 0.0 : 255.0
        let context = "\(appearance) \(name)"
        XCTAssertEqual(Double(actual.0), expected, accuracy: 4, context)
        XCTAssertEqual(Double(actual.1), expected, accuracy: 4, context)
        XCTAssertEqual(Double(actual.2), expected, accuracy: 4, context)
      }
    }
  }

  /// UIKit hosting is intentional: ImageRenderer alone does not render native List,
  /// NavigationStack and TabView surfaces and would miss an opaque container regression.
  /// This integration check uses the simulator's standard accessibility settings.
  func testNativeListNavigationAndTabSurfacesActuallyRevealTheWallpaper() async throws {
    for appearance in WallpaperThemeAppearance.allCases {
      let red = try await capture(color: .red, appearance: appearance)
      let blue = try await capture(color: .blue, appearance: appearance)
      attach(red, name: "\(appearance)-red-wallpaper")
      attach(blue, name: "\(appearance)-blue-wallpaper")
      for (name, point) in [
        ("navigation", CGPoint(x: 15, y: 75)),
        ("list canvas", CGPoint(x: 15, y: red.size.height * 0.5)),
        ("tab", CGPoint(x: 15, y: red.size.height - 45)),
      ] {
        let first = try pixel(red, point: point)
        let second = try pixel(blue, point: point)
        XCTAssertGreaterThan(
          abs(first.0 - second.0) + abs(first.2 - second.2), 12,
          "\(name) must reveal the shared wallpaper instead of a native opaque background")
      }
    }
  }

  private func capture(color: UIColor, appearance: WallpaperThemeAppearance) async throws -> UIImage
  {
    var settings = WallpaperThemeSettings.defaultValue
    settings.appearance = appearance
    let snapshot = WallpaperThemeSnapshot(
      id: UUID(), settings: settings, image: try XCTUnwrap(wallpaperImage(color: color).cgImage))
    let root = TabView {
      NavigationStack {
        List {
          Text("阅读内容").appListRowSurface(.content)
        }
        .listStyle(.plain)
        .appScrollableSurface()
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
      }
      .appNavigationSurface()
      .tabItem { Label("首页", systemImage: "house") }
    }
    .appNavigationSurface()
    .environment(\.wallpaperTheme, snapshot)
    return try await capture(root, appearance: appearance)
  }

  private func captureCanvas(
    appearance: WallpaperThemeAppearance,
    imageOpacity: Double,
    highContrast: Bool = false,
    reducesTransparency: Bool = false
  ) async throws -> UIImage {
    var settings = WallpaperThemeSettings.defaultValue
    settings.appearance = appearance
    settings.imageOpacity = imageOpacity
    // Render the same canvas used by WallpaperThemePreview, with explicit inputs
    // because the system accessibility environment values are read-only.
    let root = WallpaperThemeCanvas(
      image: try XCTUnwrap(wallpaperImage(color: .red).cgImage), settings: settings,
      highContrast: highContrast, reducesTransparency: reducesTransparency)
      .ignoresSafeArea()
    return try await capture(root, appearance: appearance)
  }

  private func wallpaperImage(color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image {
      color.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
  }

  private func capture<Content: View>(
    _ root: Content, appearance: WallpaperThemeAppearance
  ) async throws -> UIImage {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive },
      "Native wallpaper rendering must run in the hosted iOS test application")
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let size = scene.coordinateSpace.bounds.size
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.preferredRange = .standard
    let host = UIHostingController(rootView: root.preferredColorScheme(appearance.colorScheme))
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    try await Task.sleep(nanoseconds: 200_000_000)
    var didRender = false
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      didRender = host.view.drawHierarchy(
        in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
    }
    XCTAssertTrue(didRender, "UIKit must actually render the native container hierarchy")
    return rendered
  }

  private func pixel(_ image: UIImage, point: CGPoint) throws -> (Int, Int, Int) {
    let cgImage = try XCTUnwrap(image.cgImage)
    let sample = try XCTUnwrap(
      cgImage.cropping(to: CGRect(
        x: (point.x * image.scale).rounded(.down),
        y: (point.y * image.scale).rounded(.down),
        width: 1, height: 1)))
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
  }

  private func attach(_ image: UIImage, name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
