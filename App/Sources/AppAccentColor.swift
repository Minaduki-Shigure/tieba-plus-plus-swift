import CoreGraphics
import Foundation
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

struct AppAccentColorSeed: Equatable, Hashable, Sendable {
  static let storagePrefix = "custom:"

  let rgb: UInt32

  init?(rgb: UInt32) {
    guard rgb <= 0x00FF_FFFF else { return nil }
    self.rgb = rgb
  }

  init?(hexString: String) {
    let bytes = Array(hexString.utf8)
    guard bytes.count == 6 else { return nil }

    var value: UInt32 = 0
    for byte in bytes {
      let nibble: UInt32
      switch byte {
      case 0x30...0x39:
        nibble = UInt32(byte - 0x30)
      case 0x41...0x46:
        nibble = UInt32(byte - 0x41 + 10)
      case 0x61...0x66:
        nibble = UInt32(byte - 0x61 + 10)
      default:
        return nil
      }
      value = (value << 4) | nibble
    }
    self.rgb = value
  }

  init?(storageValue: String) {
    let bytes = storageValue.utf8
    guard
      bytes.count == Self.storagePrefix.utf8.count + 6,
      storageValue.hasPrefix(Self.storagePrefix)
    else { return nil }
    guard
      let seed = Self(
        hexString: String(storageValue.dropFirst(Self.storagePrefix.count))
      ),
      seed.storageValue == storageValue
    else { return nil }
    self = seed
  }

  init?(cgColor source: CGColor) {
    guard
      let sourceSpace = source.colorSpace,
      sourceSpace.model == .rgb || sourceSpace.model == .monochrome,
      let sourceComponents = source.components,
      sourceComponents.count == sourceSpace.numberOfComponents + 1,
      sourceComponents.allSatisfy({ $0.isFinite }),
      sourceComponents.dropLast().allSatisfy({ abs($0) <= 16 }),
      source.alpha == 1,
      let target = CGColorSpace(name: CGColorSpace.extendedSRGB),
      let converted = source.converted(
        to: target,
        intent: .relativeColorimetric,
        options: nil
      ),
      converted.colorSpace?.model == .rgb,
      let components = converted.components,
      components.count == 4,
      components.allSatisfy({ $0.isFinite }),
      components.dropLast().allSatisfy({ abs($0) <= 16 }),
      components[3] == 1,
      let value = Self.quantizedRGB(
        red: components[0],
        green: components[1],
        blue: components[2]
      )
    else { return nil }
    rgb = value
  }

  var hexString: String {
    String(format: "%06X", rgb)
  }

  var storageValue: String {
    Self.storagePrefix + hexString
  }

  var components: AppAccentColorComponents {
    AppAccentColorComponents(rgb: rgb)
  }

  var cgColor: CGColor {
    CGColor(
      srgbRed: components.red,
      green: components.green,
      blue: components.blue,
      alpha: 1
    )
  }

  static func quantizedRGB(
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat
  ) -> UInt32? {
    let values = [red, green, blue]
    guard values.allSatisfy({ $0.isFinite }) else { return nil }

    func byte(_ value: CGFloat) -> UInt32 {
      UInt32((min(max(value, 0), 1) * 255).rounded())
    }

    return (byte(red) << 16) | (byte(green) << 8) | byte(blue)
  }
}

enum AppAccentColorContrast {
  static let normalMinimum = 4.5
  static let highContrastMinimum = 7.0
  static let onAccentMinimum = 4.5
  static let generatedNormalMinimum = 4.51
  static let generatedHighContrastMinimum = 7.01
  static let generatedOnAccentMinimum = 4.51

  static let lightBackgrounds = [0xFFFFFF, 0xF2F2F7].map(
    AppAccentColorComponents.init(rgb:)
  )
  static let darkBackgrounds = [0x000000, 0x1C1C1E, 0x2C2C2E].map(
    AppAccentColorComponents.init(rgb:)
  )

  private static let linearSRGB: [Double] = (0...255).map { rawValue in
    let component = Double(rawValue) / 255
    return component <= 0.04045
      ? component / 12.92
      : Foundation.pow((component + 0.055) / 1.055, 2.4)
  }

  static func backgrounds(
    for appearance: AppAccentColorAppearance
  ) -> [AppAccentColorComponents] {
    appearance.isDark ? darkBackgrounds : lightBackgrounds
  }

  static func relativeLuminance(_ color: AppAccentColorComponents) -> Double {
    0.2126 * linearSRGB[Int((color.rgb >> 16) & 0xFF)]
      + 0.7152 * linearSRGB[Int((color.rgb >> 8) & 0xFF)]
      + 0.0722 * linearSRGB[Int(color.rgb & 0xFF)]
  }

  static func contrastRatio(
    _ first: AppAccentColorComponents,
    _ second: AppAccentColorComponents
  ) -> Double {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    return (max(firstLuminance, secondLuminance) + 0.05)
      / (min(firstLuminance, secondLuminance) + 0.05)
  }

  static func hasContrast(
    _ first: AppAccentColorComponents,
    _ second: AppAccentColorComponents,
    required: Double
  ) -> Bool {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    let lighter = max(firstLuminance, secondLuminance)
    let darker = min(firstLuminance, secondLuminance)
    return lighter + 0.05 >= required * (darker + 0.05)
  }
}

struct AppAccentPalette: Equatable, Hashable, Sendable {
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

  static func custom(seed: AppAccentColorSeed) -> Self? {
    guard
      let light = derived(from: seed.components, for: .light),
      let dark = derived(from: seed.components, for: .dark),
      let highContrastLight = derived(from: seed.components, for: .highContrastLight),
      let highContrastDark = derived(from: seed.components, for: .highContrastDark)
    else { return nil }

    let palette = Self(
      light: light.rgb,
      dark: dark.rgb,
      highContrastLight: highContrastLight.rgb,
      highContrastDark: highContrastDark.rgb
    )
    return palette.isValidCustomPalette ? palette : nil
  }

  private static func derived(
    from seed: AppAccentColorComponents,
    for appearance: AppAccentColorAppearance
  ) -> AppAccentColorComponents? {
    let target: UInt32 = appearance.isDark ? 0xFFFFFF : 0x000000
    let backgrounds = AppAccentColorContrast.backgrounds(for: appearance)
    let accentMinimum = appearance.isHighContrast
      ? AppAccentColorContrast.generatedHighContrastMinimum
      : AppAccentColorContrast.generatedNormalMinimum
    let foreground = AppAccentColor.onAccentComponents(for: appearance)

    for step in 0...255 {
      let candidate = mixed(seed, toward: target, step: step)
      guard backgrounds.allSatisfy({
        AppAccentColorContrast.hasContrast(candidate, $0, required: accentMinimum)
      }) else { continue }
      guard AppAccentColorContrast.hasContrast(
        foreground,
        candidate,
        required: AppAccentColorContrast.generatedOnAccentMinimum
      ) else { continue }
      return candidate
    }
    return nil
  }

  private static func mixed(
    _ source: AppAccentColorComponents,
    toward target: UInt32,
    step: Int
  ) -> AppAccentColorComponents {
    let stepCount = 255

    func mixedChannel(_ source: UInt32, _ target: UInt32) -> UInt32 {
      let numerator = Int(source) * (stepCount - step) + Int(target) * step
      return UInt32((numerator + stepCount / 2) / stepCount)
    }

    let red = mixedChannel((source.rgb >> 16) & 0xFF, (target >> 16) & 0xFF)
    let green = mixedChannel((source.rgb >> 8) & 0xFF, (target >> 8) & 0xFF)
    let blue = mixedChannel(source.rgb & 0xFF, target & 0xFF)
    return AppAccentColorComponents(rgb: (red << 16) | (green << 8) | blue)
  }

  private var isValidCustomPalette: Bool {
    for appearance in AppAccentColorAppearance.allCases {
      let accent = components(for: appearance)
      let minimum = appearance.isHighContrast
        ? AppAccentColorContrast.generatedHighContrastMinimum
        : AppAccentColorContrast.generatedNormalMinimum
      guard AppAccentColorContrast.backgrounds(for: appearance).allSatisfy({
        AppAccentColorContrast.hasContrast(accent, $0, required: minimum)
      }) else { return false }
      guard AppAccentColorContrast.hasContrast(
        AppAccentColor.onAccentComponents(for: appearance),
        accent,
        required: AppAccentColorContrast.generatedOnAccentMinimum
      ) else { return false }
    }

    return AppAccentColorContrast.relativeLuminance(
      components(for: .highContrastLight)
    ) <= AppAccentColorContrast.relativeLuminance(components(for: .light))
      && AppAccentColorContrast.relativeLuminance(
        components(for: .highContrastDark)
      ) >= AppAccentColorContrast.relativeLuminance(components(for: .dark))
  }

  static func validatedCustomOrDefault(
    seed: AppAccentColorSeed
  ) -> (palette: AppAccentPalette, didFallback: Bool) {
    validatedCustomOrDefault(seed: seed) { custom(seed: $0) }
  }

  static func validatedCustomOrDefault(
    seed: AppAccentColorSeed,
    derive: (AppAccentColorSeed) -> AppAccentPalette?
  ) -> (palette: AppAccentPalette, didFallback: Bool) {
    guard let palette = derive(seed), palette.isValidCustomPalette else {
      return (AppAccentColor.defaultValue.palette, true)
    }
    return (palette, false)
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

  var editingSeed: AppAccentColorSeed {
    AppAccentColorSeed(rgb: palette.light)!
  }

  var palette: AppAccentPalette {
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

enum AppAccentColorSelection: Equatable, Hashable, Sendable {
  case preset(AppAccentColor)
  case custom(AppAccentColorSeed)

  static let defaultValue = Self.preset(AppAccentColor.defaultValue)

  static func resolved(_ rawValue: String) -> Self {
    if let preset = AppAccentColor(rawValue: rawValue) {
      return .preset(preset)
    }
    if let seed = AppAccentColorSeed(storageValue: rawValue) {
      return .custom(seed)
    }
    return defaultValue
  }

  var storageValue: String {
    switch self {
    case .preset(let preset):
      preset.rawValue
    case .custom(let seed):
      seed.storageValue
    }
  }

  var title: String {
    switch self {
    case .preset(let preset):
      preset.title
    case .custom:
      "自定义"
    }
  }

  var customSeed: AppAccentColorSeed? {
    guard case .custom(let seed) = self else { return nil }
    return seed
  }

  var editingSeed: AppAccentColorSeed {
    switch self {
    case .preset(let preset):
      preset.editingSeed
    case .custom(let seed):
      seed
    }
  }

  var style: AppAccentColorStyle {
    AppAccentColorStyle(selection: self)
  }
}

struct AppAccentColorStyle: Equatable, Hashable, Sendable {
  let selection: AppAccentColorSelection
  let palette: AppAccentPalette
  let didFallback: Bool

  init(selection: AppAccentColorSelection) {
    self.selection = selection
    switch selection {
    case .preset(let preset):
      palette = preset.palette
      didFallback = false
    case .custom(let seed):
      let result = AppAccentPalette.validatedCustomOrDefault(seed: seed)
      palette = result.palette
      didFallback = result.didFallback
    }
  }

  var title: String { selection.title }

  var color: Color { Color(uiColor: uiColor) }

  var onAccentColor: Color { Color(uiColor: onAccentUIColor) }

  var uiColor: UIColor {
    let palette = palette
    return UIColor { traits in
      palette.components(for: AppAccentColorAppearance(traits: traits)).uiColor
    }
  }

  var onAccentUIColor: UIColor {
    UIColor { traits in
      AppAccentColor.onAccentComponents(
        for: AppAccentColorAppearance(traits: traits)
      ).uiColor
    }
  }

  func components(for appearance: AppAccentColorAppearance) -> AppAccentColorComponents {
    palette.components(for: appearance)
  }
}

enum AppAccentColorEditorPolicy {
  static func initialSeed(
    selection: AppAccentColorSelection,
    savedCustomSeed: AppAccentColorSeed?
  ) -> AppAccentColorSeed {
    selection.customSeed ?? savedCustomSeed ?? selection.editingSeed
  }

  static func apply(
    _ seed: AppAccentColorSeed,
    setSelection: (AppAccentColorSelection) -> Void,
    setSavedCustomSeed: (AppAccentColorSeed) -> Void
  ) {
    setSelection(.custom(seed))
    setSavedCustomSeed(seed)
  }
}

private struct AppAccentColorEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppAccentColorSelection.defaultValue.style
}

extension EnvironmentValues {
  var appAccentColor: AppAccentColorStyle {
    get { self[AppAccentColorEnvironmentKey.self] }
    set { self[AppAccentColorEnvironmentKey.self] = newValue }
  }
}
