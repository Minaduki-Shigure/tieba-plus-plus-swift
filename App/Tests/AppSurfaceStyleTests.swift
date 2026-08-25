import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class AppSurfaceStyleTests: XCTestCase {
  private let expectedDarkValues: [AppSurfaceRole: UInt32] = [
    .canvas: 0x000000,
    .content: 0x000000,
    .card: 0x101010,
    .floor: 0x151515,
    .control: 0x1E1E1E,
    .divider: 0x101010,
    .bar: 0x000000,
  ]

  private let expectedHighContrastDarkValues: [AppSurfaceRole: UInt32] = [
    .canvas: 0x000000,
    .content: 0x000000,
    .card: 0x151515,
    .floor: 0x1C1C1E,
    .control: 0x2C2C2E,
    .divider: 0x48484A,
    .bar: 0x000000,
  ]

  func testOLEDPaletteHasExactOpaqueComponentsForDarkAppearances() throws {
    for role in AppSurfaceRole.allCases {
      XCTAssertEqual(
        try XCTUnwrap(
          AppSurfacePalette.oledBlack.components(for: role, appearance: .dark)
        ).rgb,
        try XCTUnwrap(expectedDarkValues[role])
      )
      XCTAssertEqual(
        try XCTUnwrap(
          AppSurfacePalette.oledBlack.components(
            for: role,
            appearance: .highContrastDark
          )
        ).rgb,
        try XCTUnwrap(expectedHighContrastDarkValues[role])
      )
    }
  }

  func testOLEDPaletteDoesNotReplaceLightSurfaces() {
    for role in AppSurfaceRole.allCases {
      XCTAssertNil(
        AppSurfacePalette.oledBlack.components(for: role, appearance: .light)
      )
      XCTAssertNil(
        AppSurfacePalette.oledBlack.components(
          for: role,
          appearance: .highContrastLight
        )
      )
    }
  }

  @MainActor
  func testDynamicColorsUseOLEDOnlyForDarkTraits() throws {
    for role in AppSurfaceRole.allCases {
      for appearance in AppSurfaceAppearance.allCases {
        let traits = traits(for: appearance)
        let resolvedOLED = AppDarkSurfaceStyle.oledBlack
          .uiColor(for: role)
          .resolvedColor(with: traits)

        if appearance.isDark {
          XCTAssertEqual(
            try rgbValue(resolvedOLED),
            try XCTUnwrap(
              AppSurfacePalette.oledBlack.components(
                for: role,
                appearance: appearance
              )
            ).rgb
          )
          XCTAssertEqual(try alphaValue(resolvedOLED), 1, accuracy: 0.000_001)
        } else {
          let resolvedStandard = AppDarkSurfaceStyle.standard
            .uiColor(for: role)
            .resolvedColor(with: traits)
          assertEqualColor(resolvedOLED, resolvedStandard)
        }
      }
    }
  }

  func testOLEDActivationPolicyRequiresBothSelectionAndDarkAppearance() {
    XCTAssertFalse(
      AppSurfacePolicy.isOLEDActive(style: .standard, colorScheme: .light)
    )
    XCTAssertFalse(
      AppSurfacePolicy.isOLEDActive(style: .standard, colorScheme: .dark)
    )
    XCTAssertFalse(
      AppSurfacePolicy.isOLEDActive(style: .oledBlack, colorScheme: .light)
    )
    XCTAssertTrue(
      AppSurfacePolicy.isOLEDActive(style: .oledBlack, colorScheme: .dark)
    )

    for appearance in AppSurfaceAppearance.allCases {
      XCTAssertEqual(
        AppSurfacePolicy.isOLEDActive(style: .oledBlack, appearance: appearance),
        appearance.isDark
      )
      XCTAssertFalse(
        AppSurfacePolicy.isOLEDActive(style: .standard, appearance: appearance)
      )
    }
  }

  func testUnspecifiedInterfaceStyleDoesNotActivateOLED() {
    let appearance = AppSurfaceAppearance(traits: UITraitCollection())
    XCTAssertFalse(appearance.isDark)
    XCTAssertFalse(
      AppSurfacePolicy.isOLEDActive(style: .oledBlack, appearance: appearance)
    )
  }

  @MainActor
  func testEnvironmentDefaultsToStandardAndAcceptsOLEDSelection() {
    XCTAssertEqual(EnvironmentValues().appDarkSurfaceStyle, .standard)

    var environment = EnvironmentValues()
    environment.appDarkSurfaceStyle = .oledBlack
    XCTAssertEqual(environment.appDarkSurfaceStyle, .oledBlack)
  }

  func testHighContrastPalettePreservesBlackCanvasAndStrengthensLayerSeparation() throws {
    for role in [AppSurfaceRole.canvas, .content, .bar] {
      XCTAssertEqual(expectedDarkValues[role], 0x000000)
      XCTAssertEqual(expectedHighContrastDarkValues[role], 0x000000)
    }

    for role in [AppSurfaceRole.card, .floor, .control, .divider] {
      XCTAssertGreaterThan(
        try XCTUnwrap(expectedHighContrastDarkValues[role]),
        try XCTUnwrap(expectedDarkValues[role])
      )
    }
  }

  @MainActor
  func testSystemLabelsRemainReadableAcrossOLEDSurfaces() throws {
    for appearance in [AppSurfaceAppearance.dark, .highContrastDark] {
      let traits = traits(for: appearance)
      let label = UIColor.label.resolvedColor(with: traits)
      let secondaryLabel = UIColor.secondaryLabel.resolvedColor(with: traits)

      for role in AppSurfaceRole.allCases {
        let background = try XCTUnwrap(
          AppSurfacePalette.oledBlack.components(for: role, appearance: appearance)
        )
        XCTAssertGreaterThanOrEqual(
          contrastRatio(foreground: label, background: background),
          7.0,
          "Primary label contrast failed for \(role) in \(appearance)"
        )
        XCTAssertGreaterThanOrEqual(
          contrastRatio(foreground: secondaryLabel, background: background),
          4.5,
          "Secondary label contrast failed for \(role) in \(appearance)"
        )
      }
    }
  }

  private func traits(for appearance: AppSurfaceAppearance) -> UITraitCollection {
    UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceStyle: appearance.isDark ? .dark : .light),
      UITraitCollection(accessibilityContrast: appearance.isHighContrast ? .high : .normal),
    ])
  }

  private func rgbValue(_ color: UIColor) throws -> UInt32 {
    let components = try rgbaComponents(color)
    return UInt32((components.red * 255).rounded()) << 16
      | UInt32((components.green * 255).rounded()) << 8
      | UInt32((components.blue * 255).rounded())
  }

  private func alphaValue(_ color: UIColor) throws -> CGFloat {
    try rgbaComponents(color).alpha
  }

  private func assertEqualColor(
    _ first: UIColor,
    _ second: UIColor,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let lhs = try rgbaComponents(first)
      let rhs = try rgbaComponents(second)
      XCTAssertEqual(lhs.red, rhs.red, accuracy: 0.000_001, file: file, line: line)
      XCTAssertEqual(lhs.green, rhs.green, accuracy: 0.000_001, file: file, line: line)
      XCTAssertEqual(lhs.blue, rhs.blue, accuracy: 0.000_001, file: file, line: line)
      XCTAssertEqual(lhs.alpha, rhs.alpha, accuracy: 0.000_001, file: file, line: line)
    } catch {
      XCTFail("Could not compare colors: \(error)", file: file, line: line)
    }
  }

  private func rgbaComponents(
    _ color: UIColor
  ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      throw ColorTestError.unavailableComponents
    }
    return (red, green, blue, alpha)
  }

  private func contrastRatio(
    foreground: UIColor,
    background: AppSurfaceColorComponents
  ) -> Double {
    guard let foreground = try? rgbaComponents(foreground) else { return 0 }
    let alpha = Double(foreground.alpha)
    let composite = (
      red: Double(foreground.red) * alpha + Double(background.red) * (1 - alpha),
      green: Double(foreground.green) * alpha + Double(background.green) * (1 - alpha),
      blue: Double(foreground.blue) * alpha + Double(background.blue) * (1 - alpha)
    )
    let foregroundLuminance = relativeLuminance(composite)
    let backgroundLuminance = relativeLuminance((
      red: Double(background.red),
      green: Double(background.green),
      blue: Double(background.blue)
    ))
    return (max(foregroundLuminance, backgroundLuminance) + 0.05)
      / (min(foregroundLuminance, backgroundLuminance) + 0.05)
  }

  private func relativeLuminance(
    _ components: (red: Double, green: Double, blue: Double)
  ) -> Double {
    func linearized(_ component: Double) -> Double {
      component <= 0.04045
        ? component / 12.92
        : Foundation.pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(components.red)
      + 0.7152 * linearized(components.green)
      + 0.0722 * linearized(components.blue)
  }
}

private enum ColorTestError: Error {
  case unavailableComponents
}
