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
  static func canvasOpacity(highContrast: Bool, reducesTransparency: Bool) -> Double {
    highContrast || reducesTransparency ? 1 : 0
  }

  static func surfaceOpacity(
    for role: AppSurfaceRole,
    appearance: WallpaperThemeAppearance,
    highContrast: Bool,
    reducesTransparency: Bool
  ) -> Double {
    if highContrast || reducesTransparency { return 1 }
    // TiebaLite applies small, local foreground tints to cards/floors. Its
    // translucent_light name denotes light text, equivalent to our dark reading.
    switch role {
    case .canvas, .content: return 0
    case .card, .control: return appearance == .dark ? 16.0 / 255 : 32.0 / 255
    case .floor: return appearance == .dark ? 21.0 / 255 : 42.0 / 255
    case .divider: return appearance == .dark ? 16.0 / 255 : 21.0 / 255
    // Reply/action panes retain a readable window surface. Native navigation
    // and tab bars are independently transparent in AppNavigationSurfaceModifier.
    case .bar: return 1
    }
  }

  static func surfaceColor(
    for role: AppSurfaceRole,
    appearance: WallpaperThemeAppearance,
    highContrast: Bool,
    reducesTransparency: Bool
  ) -> Color {
    if highContrast || reducesTransparency { return appearance.surfaceColor }
    if role == .bar {
      let component = appearance == .dark ? 32.0 / 255 : 248.0 / 255
      return Color(red: component, green: component, blue: component)
    }
    return appearance == .dark ? .white : .black
  }
}

/// Shared by editor and live pages, so image opacity matches after Save.
/// The CGImage is already oriented, cropped and blurred off the main actor.
struct WallpaperThemePreview: View {
  let image: CGImage
  let settings: WallpaperThemeSettings
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

  var body: some View {
    WallpaperThemeCanvas(
      image: image, settings: settings,
      highContrast: contrast == .increased, reducesTransparency: reducesTransparency)
  }
}

/// The actual canvas renderer receives accessibility values from the live wrapper.
struct WallpaperThemeCanvas: View {
  let image: CGImage
  let settings: WallpaperThemeSettings
  let highContrast: Bool
  let reducesTransparency: Bool

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        settings.appearance.surfaceColor
        if !highContrast && !reducesTransparency {
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
              highContrast: highContrast,
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
    WallpaperThemeSurfacePolicy.surfaceColor(
      for: role,
      appearance: settings.appearance,
      highContrast: contrast == .increased,
      reducesTransparency: reducesTransparency
    ).opacity(
      WallpaperThemeSurfacePolicy.surfaceOpacity(
        for: role,
        appearance: settings.appearance,
        highContrast: contrast == .increased,
        reducesTransparency: reducesTransparency
      )
    )
  }
}
