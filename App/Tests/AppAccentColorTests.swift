import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class AppAccentColorTests: XCTestCase {
  private let expectedValues: [AppAccentColor: [UInt32]] = [
    .blue: [0x125DBE, 0x74A9FF, 0x004E9A, 0x9BC2FF],
    .indigo: [0x4F46A5, 0xA7A0FF, 0x353080, 0xC2BDFF],
    .teal: [0x00675B, 0x54D3BD, 0x004C43, 0x80E6D4],
    .green: [0x28643A, 0x72D68C, 0x154A26, 0x9AE7AC],
    .rose: [0x8E3B66, 0xF18CB8, 0x6F234C, 0xFFB0D0],
  ]

  func testEveryPaletteHasExactOpaqueComponentsForAllAppearances() throws {
    for accentColor in AppAccentColor.allCases {
      let expected = try XCTUnwrap(expectedValues[accentColor])
      XCTAssertEqual(expected.count, AppAccentColorAppearance.allCases.count)

      for (appearance, value) in zip(AppAccentColorAppearance.allCases, expected) {
        XCTAssertEqual(accentColor.components(for: appearance).rgb, value)
      }
    }
  }

  @MainActor
  func testDynamicUIColorsResolveFromExplicitTraitsWithoutGlobalState() throws {
    for accentColor in AppAccentColor.allCases {
      for appearance in AppAccentColorAppearance.allCases {
        let traits = traits(for: appearance)
        let resolvedAccent = accentColor.uiColor.resolvedColor(with: traits)
        let resolvedOnAccent = accentColor.onAccentUIColor.resolvedColor(with: traits)

        XCTAssertEqual(
          try rgbValue(resolvedAccent),
          accentColor.components(for: appearance).rgb
        )
        XCTAssertEqual(
          try rgbValue(resolvedOnAccent),
          AppAccentColor.onAccentComponents(for: appearance).rgb
        )
      }
    }
  }

  func testPaletteMeetsNormalAndHighContrastThresholds() {
    let lightBackgrounds = [0xFFFFFF, 0xF2F2F7].map(AppAccentColorComponents.init(rgb:))
    let darkBackgrounds = [0x000000, 0x1C1C1E, 0x2C2C2E].map(
      AppAccentColorComponents.init(rgb:)
    )

    for accentColor in AppAccentColor.allCases {
      for appearance in AppAccentColorAppearance.allCases {
        let accent = accentColor.components(for: appearance)
        let backgrounds = appearance.isDark ? darkBackgrounds : lightBackgrounds
        let minimumContrast = appearance.isHighContrast ? 7.0 : 4.5

        for background in backgrounds {
          XCTAssertGreaterThanOrEqual(
            contrastRatio(accent, background),
            minimumContrast,
            "Insufficient contrast for \(accentColor.rawValue) in \(appearance)"
          )
        }

        XCTAssertGreaterThanOrEqual(
          contrastRatio(AppAccentColor.onAccentComponents(for: appearance), accent),
          4.5,
          "Insufficient on-accent contrast for \(accentColor.rawValue) in \(appearance)"
        )
      }
    }
  }

  private func traits(for appearance: AppAccentColorAppearance) -> UITraitCollection {
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: appearance.isDark ? .dark : .light),
      UITraitCollection(accessibilityContrast: appearance.isHighContrast ? .high : .normal),
    ])
  }

  private func rgbValue(_ color: UIColor) throws -> UInt32 {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertEqual(alpha, 1, accuracy: 0.000_001)
    return UInt32((red * 255).rounded()) << 16
      | UInt32((green * 255).rounded()) << 8
      | UInt32((blue * 255).rounded())
  }

  private func contrastRatio(
    _ first: AppAccentColorComponents,
    _ second: AppAccentColorComponents
  ) -> Double {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    return (max(firstLuminance, secondLuminance) + 0.05)
      / (min(firstLuminance, secondLuminance) + 0.05)
  }

  private func relativeLuminance(_ color: AppAccentColorComponents) -> Double {
    func linearized(_ value: UInt32) -> Double {
      let component = Double(value) / 255
      return component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linearized((color.rgb >> 16) & 0xFF)
      + 0.7152 * linearized((color.rgb >> 8) & 0xFF)
      + 0.0722 * linearized(color.rgb & 0xFF)
  }
}
