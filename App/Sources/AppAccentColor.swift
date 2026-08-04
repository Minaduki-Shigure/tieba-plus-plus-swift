import SwiftUI
import UIKit

enum AppAccentColorAppearance: CaseIterable, Hashable, Sendable {
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

struct AppAccentColorComponents: Equatable, Hashable, Sendable {
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

private struct AppAccentPalette: Sendable {
  let light: UInt32
  let dark: UInt32
  let highContrastLight: UInt32
  let highContrastDark: UInt32

  func components(for appearance: AppAccentColorAppearance) -> AppAccentColorComponents {
    let value: UInt32
    switch appearance {
    case .light:
      value = light
    case .dark:
      value = dark
    case .highContrastLight:
      value = highContrastLight
    case .highContrastDark:
      value = highContrastDark
    }
    return AppAccentColorComponents(rgb: value)
  }
}

enum AppAccentColor: String, CaseIterable, Hashable, Identifiable, Sendable {
  case blue
  case indigo
  case teal
  case green
  case rose

  static let defaultValue = Self.blue

  var id: Self { self }

  var title: String {
    switch self {
    case .blue:
      "贴吧蓝"
    case .indigo:
      "靛蓝"
    case .teal:
      "青绿"
    case .green:
      "叶绿"
    case .rose:
      "玫红"
    }
  }

  var color: Color {
    Color(uiColor: uiColor)
  }

  var onAccentColor: Color {
    Color(uiColor: onAccentUIColor)
  }

  var uiColor: UIColor {
    let palette = palette
    return UIColor { traits in
      palette.components(for: AppAccentColorAppearance(traits: traits)).uiColor
    }
  }

  var onAccentUIColor: UIColor {
    UIColor { traits in
      Self.onAccentComponents(
        for: AppAccentColorAppearance(traits: traits)
      ).uiColor
    }
  }

  func components(for appearance: AppAccentColorAppearance) -> AppAccentColorComponents {
    palette.components(for: appearance)
  }

  static func onAccentComponents(
    for appearance: AppAccentColorAppearance
  ) -> AppAccentColorComponents {
    AppAccentColorComponents(rgb: appearance.isDark ? 0x000000 : 0xFFFFFF)
  }

  static func resolved(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? defaultValue
  }

  private var palette: AppAccentPalette {
    switch self {
    case .blue:
      AppAccentPalette(
        light: 0x125DBE,
        dark: 0x74A9FF,
        highContrastLight: 0x004E9A,
        highContrastDark: 0x9BC2FF
      )
    case .indigo:
      AppAccentPalette(
        light: 0x4F46A5,
        dark: 0xA7A0FF,
        highContrastLight: 0x353080,
        highContrastDark: 0xC2BDFF
      )
    case .teal:
      AppAccentPalette(
        light: 0x00675B,
        dark: 0x54D3BD,
        highContrastLight: 0x004C43,
        highContrastDark: 0x80E6D4
      )
    case .green:
      AppAccentPalette(
        light: 0x28643A,
        dark: 0x72D68C,
        highContrastLight: 0x154A26,
        highContrastDark: 0x9AE7AC
      )
    case .rose:
      AppAccentPalette(
        light: 0x8E3B66,
        dark: 0xF18CB8,
        highContrastLight: 0x6F234C,
        highContrastDark: 0xFFB0D0
      )
    }
  }
}

private struct AppAccentColorEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppAccentColor.defaultValue
}

extension EnvironmentValues {
  var appAccentColor: AppAccentColor {
    get { self[AppAccentColorEnvironmentKey.self] }
    set { self[AppAccentColorEnvironmentKey.self] = newValue }
  }
}
