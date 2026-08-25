import SwiftUI
import UIKit

enum AppDarkSurfaceStyle: String, CaseIterable, Hashable, Identifiable, Sendable {
  case standard
  case oledBlack

  static let defaultValue = Self.standard

  var id: Self { self }

  var title: String {
    switch self {
    case .standard:
      "系统深色"
    case .oledBlack:
      "纯黑 OLED"
    }
  }

  var systemImage: String {
    switch self {
    case .standard:
      "circle.lefthalf.filled"
    case .oledBlack:
      "circle.fill"
    }
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? defaultValue
  }

  func uiColor(for role: AppSurfaceRole) -> UIColor {
    switch self {
    case .standard:
      role.standardUIColor
    case .oledBlack:
      UIColor { traits in
        let appearance = AppSurfaceAppearance(traits: traits)
        guard
          let components = AppSurfacePalette.oledBlack.components(
            for: role,
            appearance: appearance
          )
        else {
          return role.standardUIColor.resolvedColor(with: traits)
        }
        return components.uiColor
      }
    }
  }

  func color(for role: AppSurfaceRole) -> Color {
    Color(uiColor: uiColor(for: role))
  }
}

enum AppSurfaceRole: CaseIterable, Hashable, Sendable {
  case canvas
  case content
  case card
  case floor
  case control
  case divider
  case bar

  fileprivate var standardUIColor: UIColor {
    switch self {
    case .canvas, .content, .floor, .bar:
      .systemBackground
    case .card:
      .secondarySystemBackground
    case .control:
      .tertiarySystemBackground
    case .divider:
      .separator
    }
  }
}

enum AppSurfaceAppearance: CaseIterable, Hashable, Sendable {
  case light
  case dark
  case highContrastLight
  case highContrastDark

  init(traits: UITraitCollection) {
    switch (
      traits.userInterfaceStyle == .dark,
      traits.accessibilityContrast == .high
    ) {
    case (false, false):
      self = .light
    case (true, false):
      self = .dark
    case (false, true):
      self = .highContrastLight
    case (true, true):
      self = .highContrastDark
    }
  }

  var isDark: Bool {
    switch self {
    case .light, .highContrastLight:
      false
    case .dark, .highContrastDark:
      true
    }
  }

  var isHighContrast: Bool {
    switch self {
    case .light, .dark:
      false
    case .highContrastLight, .highContrastDark:
      true
    }
  }
}

struct AppSurfaceColorComponents: Equatable, Hashable, Sendable {
  let rgb: UInt32

  init(rgb: UInt32) {
    self.rgb = rgb & 0x00FF_FFFF
  }

  var red: CGFloat { CGFloat((rgb >> 16) & 0xFF) / 255 }
  var green: CGFloat { CGFloat((rgb >> 8) & 0xFF) / 255 }
  var blue: CGFloat { CGFloat(rgb & 0xFF) / 255 }

  var uiColor: UIColor {
    UIColor(red: red, green: green, blue: blue, alpha: 1)
  }
}

struct AppSurfaceRoleColors: Equatable, Hashable, Sendable {
  let canvas: UInt32
  let content: UInt32
  let card: UInt32
  let floor: UInt32
  let control: UInt32
  let divider: UInt32
  let bar: UInt32

  func components(for role: AppSurfaceRole) -> AppSurfaceColorComponents {
    let value: UInt32
    switch role {
    case .canvas:
      value = canvas
    case .content:
      value = content
    case .card:
      value = card
    case .floor:
      value = floor
    case .control:
      value = control
    case .divider:
      value = divider
    case .bar:
      value = bar
    }
    return AppSurfaceColorComponents(rgb: value)
  }
}

struct AppSurfacePalette: Equatable, Hashable, Sendable {
  let dark: AppSurfaceRoleColors
  let highContrastDark: AppSurfaceRoleColors

  static let oledBlack = Self(
    dark: AppSurfaceRoleColors(
      canvas: 0x000000,
      content: 0x000000,
      card: 0x101010,
      floor: 0x151515,
      control: 0x1E1E1E,
      divider: 0x101010,
      bar: 0x000000
    ),
    highContrastDark: AppSurfaceRoleColors(
      canvas: 0x000000,
      content: 0x000000,
      card: 0x151515,
      floor: 0x1C1C1E,
      control: 0x2C2C2E,
      divider: 0x48484A,
      bar: 0x000000
    )
  )

  func components(
    for role: AppSurfaceRole,
    appearance: AppSurfaceAppearance
  ) -> AppSurfaceColorComponents? {
    switch appearance {
    case .light, .highContrastLight:
      nil
    case .dark:
      dark.components(for: role)
    case .highContrastDark:
      highContrastDark.components(for: role)
    }
  }
}

enum AppSurfacePolicy {
  static func isOLEDActive(
    style: AppDarkSurfaceStyle,
    colorScheme: ColorScheme
  ) -> Bool {
    style == .oledBlack && colorScheme == .dark
  }

  static func isOLEDActive(
    style: AppDarkSurfaceStyle,
    appearance: AppSurfaceAppearance
  ) -> Bool {
    style == .oledBlack && appearance.isDark
  }
}

private struct AppDarkSurfaceStyleEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppDarkSurfaceStyle.defaultValue
}

extension EnvironmentValues {
  var appDarkSurfaceStyle: AppDarkSurfaceStyle {
    get { self[AppDarkSurfaceStyleEnvironmentKey.self] }
    set { self[AppDarkSurfaceStyleEnvironmentKey.self] = newValue }
  }
}

private struct AppPageSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme
  let role: AppSurfaceRole

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content.background {
        style.color(for: role).ignoresSafeArea()
      }
    } else {
      content
    }
  }
}

private struct AppScrollableSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme
  let role: AppSurfaceRole

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content
        .scrollContentBackground(.hidden)
        .background {
          style.color(for: role).ignoresSafeArea()
        }
    } else {
      content
    }
  }
}

private struct AppListRowSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme
  let role: AppSurfaceRole

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content.listRowBackground(style.color(for: role))
    } else {
      content
    }
  }
}

private struct AppSurfaceBackgroundModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme
  let role: AppSurfaceRole

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content.background(style.color(for: role))
    } else {
      content
    }
  }
}

private struct AppRegularMaterialSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content.background(style.color(for: .bar))
    } else {
      content.background(.regularMaterial)
    }
  }
}

private struct AppBarMaterialSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content.background(style.color(for: .bar))
    } else {
      content.background(.bar)
    }
  }
}

private struct AppNavigationSurfaceModifier: ViewModifier {
  @Environment(\.appDarkSurfaceStyle) private var style
  @Environment(\.colorScheme) private var colorScheme

  @ViewBuilder
  func body(content: Content) -> some View {
    if AppSurfacePolicy.isOLEDActive(style: style, colorScheme: colorScheme) {
      content
        .toolbarBackground(style.color(for: .bar), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    } else {
      content
    }
  }
}

extension View {
  func appPageSurface(_ role: AppSurfaceRole = .canvas) -> some View {
    modifier(AppPageSurfaceModifier(role: role))
  }

  func appScrollableSurface(_ role: AppSurfaceRole = .canvas) -> some View {
    modifier(AppScrollableSurfaceModifier(role: role))
  }

  func appListRowSurface(_ role: AppSurfaceRole = .content) -> some View {
    modifier(AppListRowSurfaceModifier(role: role))
  }

  func appSurfaceBackground(_ role: AppSurfaceRole) -> some View {
    modifier(AppSurfaceBackgroundModifier(role: role))
  }

  func appRegularMaterialSurface() -> some View {
    modifier(AppRegularMaterialSurfaceModifier())
  }

  func appBarMaterialSurface() -> some View {
    modifier(AppBarMaterialSurfaceModifier())
  }

  func appNavigationSurface() -> some View {
    modifier(AppNavigationSurfaceModifier())
  }
}
