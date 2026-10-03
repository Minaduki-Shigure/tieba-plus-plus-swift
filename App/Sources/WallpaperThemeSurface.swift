import CoreGraphics
import SwiftUI

private struct WallpaperThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue: WallpaperThemeSnapshot? = nil
}

private struct WallpaperCanvasEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var wallpaperTheme: WallpaperThemeSnapshot? {
    get { self[WallpaperThemeEnvironmentKey.self] }
    set { self[WallpaperThemeEnvironmentKey.self] = newValue }
  }

  /// A page installs one canvas. Rows and nested scrolling containers only tint surfaces.
  var wallpaperCanvasInstalled: Bool {
    get { self[WallpaperCanvasEnvironmentKey.self] }
    set { self[WallpaperCanvasEnvironmentKey.self] = newValue }
  }
}

extension WallpaperThemeAppearance {
  var colorScheme: ColorScheme { self == .dark ? .dark : .light }
  var surfaceColor: Color { self == .dark ? .black : .white }
}

enum WallpaperThemeSurfacePolicy {
  // The worst-case canvas is #D6D6D6 in light and #292929 in dark. Wallpaper
  // accents use the existing high-contrast palette, retaining >= 4.5 contrast
  // even over a solid black/white image. No image analysis is needed while scrolling.
  static let normalCanvasOpacity = 0.84

  static func canvasOpacity(highContrast: Bool, reducesTransparency: Bool) -> Double {
    highContrast || reducesTransparency ? 1 : normalCanvasOpacity
  }

  static func surfaceOpacity(
    for role: AppSurfaceRole,
    highContrast: Bool,
    reducesTransparency: Bool
  ) -> Double {
    if highContrast || reducesTransparency { return 1 }
    switch role {
    case .canvas, .content, .floor: return 0
    case .card: return 0.20
    case .control: return 0.35
    case .divider: return 0.40
    case .bar: return 0.25
    }
  }
}

/// Shared by editor and live pages, so opacity and readability match after Save.
/// The CGImage is already oriented, cropped and blurred off the main actor.
struct WallpaperThemePreview: View {
  let image: CGImage
  let settings: WallpaperThemeSettings
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        settings.appearance.surfaceColor
        if contrast != .increased && !reducesTransparency {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .opacity(settings.imageOpacity)
        }
        settings.appearance.surfaceColor
          .opacity(
            WallpaperThemeSurfacePolicy.canvasOpacity(
              highContrast: contrast == .increased,
              reducesTransparency: reducesTransparency
            ))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct WallpaperPageCanvas: ViewModifier {
  @Environment(\.wallpaperTheme) private var wallpaper
  @Environment(\.wallpaperCanvasInstalled) private var installed

  func body(content: Content) -> some View {
    content
      .environment(\.wallpaperCanvasInstalled, installed || wallpaper != nil)
      .background {
        if let wallpaper, !installed {
          WallpaperThemePreview(image: wallpaper.image, settings: wallpaper.settings)
            .ignoresSafeArea()
        }
      }
  }
}

struct WallpaperSemanticSurface: View {
  let settings: WallpaperThemeSettings
  let role: AppSurfaceRole
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

  var body: some View {
    settings.appearance.surfaceColor.opacity(
      WallpaperThemeSurfacePolicy.surfaceOpacity(
        for: role,
        highContrast: contrast == .increased,
        reducesTransparency: reducesTransparency
      )
    )
  }
}
