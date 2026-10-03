import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeSurfaceTests: XCTestCase {
  func testWallpaperAccentContrastCoversWorstCaseCanvasAndEveryPreset() throws {
    let selections =
      AppAccentColor.allCases.map(AppAccentColorSelection.preset)
      + [0x000000, 0xFFFFFF, 0xFFFF00, 0xFF00FF, 0x00FFFF].map {
        .custom(AppAccentColorSeed(rgb: UInt32($0))!)
      }
    for selection in selections {
      let style = AppAccentColorStyle(selection: selection, usesWallpaperContrast: true)
      for appearance in AppAccentColorAppearance.allCases {
        let background: UInt32 =
          appearance.isHighContrast
          ? (appearance.isDark ? 0x000000 : 0xFFFFFF)
          : (appearance.isDark ? 0x292929 : 0xD6D6D6)
        let required = appearance.isHighContrast ? 7.0 : 4.5
        XCTAssertGreaterThanOrEqual(
          AppAccentColorContrast.contrastRatio(
            style.components(for: appearance), AppAccentColorComponents(rgb: background)),
          required, "\(selection) \(appearance)")
      }
      // Default users retain the exact existing accent, independent of wallpaper support.
      XCTAssertEqual(AppAccentColorStyle(selection: selection).palette, selection.style.palette)
    }
  }

  func testAccessibilityMakesEverySemanticSurfaceOpaque() {
    for role in AppSurfaceRole.allCases {
      XCTAssertEqual(
        WallpaperThemeSurfacePolicy.surfaceOpacity(
          for: role, highContrast: true, reducesTransparency: false), 1)
      XCTAssertEqual(
        WallpaperThemeSurfacePolicy.surfaceOpacity(
          for: role, highContrast: false, reducesTransparency: true), 1)
    }
    XCTAssertEqual(
      WallpaperThemeSurfacePolicy.canvasOpacity(
        highContrast: false, reducesTransparency: false), 0.84)
    XCTAssertEqual(
      WallpaperThemeSurfacePolicy.canvasOpacity(
        highContrast: true, reducesTransparency: false), 1)
  }

  /// UIKit hosting is intentional: ImageRenderer alone does not render native List,
  /// NavigationStack and TabView surfaces and would miss an opaque container regression.
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
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive },
      "Native wallpaper rendering must run in the hosted iOS test application")
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let size = scene.coordinateSpace.bounds.size
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image {
      color.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    var settings = WallpaperThemeSettings.defaultValue
    settings.appearance = appearance
    let snapshot = WallpaperThemeSnapshot(
      id: UUID(), settings: settings, image: try XCTUnwrap(source.cgImage))
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
    .preferredColorScheme(appearance.colorScheme)
    let host = UIHostingController(rootView: root)
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
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.translateBy(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1)
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
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
