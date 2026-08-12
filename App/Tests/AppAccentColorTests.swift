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
    for accentColor in AppAccentColor.allCases {
      for appearance in AppAccentColorAppearance.allCases {
        let accent = accentColor.components(for: appearance)
        let backgrounds = AppAccentColorContrast.backgrounds(for: appearance)
        let minimumContrast = appearance.isHighContrast
          ? AppAccentColorContrast.highContrastMinimum
          : AppAccentColorContrast.normalMinimum

        for background in backgrounds {
          XCTAssertGreaterThanOrEqual(
            AppAccentColorContrast.contrastRatio(accent, background),
            minimumContrast,
            "Insufficient contrast for \(accentColor.rawValue) in \(appearance)"
          )
        }

        XCTAssertGreaterThanOrEqual(
          AppAccentColorContrast.contrastRatio(
            AppAccentColor.onAccentComponents(for: appearance),
            accent
          ),
          AppAccentColorContrast.onAccentMinimum,
          "Insufficient on-accent contrast for \(accentColor.rawValue) in \(appearance)"
        )
      }
    }
  }

  func testCustomStorageGrammarIsStrictAndCanonical() throws {
    let seed = try XCTUnwrap(AppAccentColorSeed(hexString: "12aBeF"))
    XCTAssertEqual(seed.rgb, 0x12ABEF)
    XCTAssertEqual(seed.hexString, "12ABEF")
    XCTAssertEqual(seed.storageValue, "custom:12ABEF")
    XCTAssertEqual(AppAccentColorSelection.resolved(seed.storageValue), .custom(seed))
    XCTAssertEqual(AppAccentColorSelection.custom(seed).storageValue, "custom:12ABEF")
    XCTAssertEqual(AppAccentColorSelection.custom(seed).title, "自定义")
    XCTAssertEqual(AppAccentColorSelection.custom(seed).editingSeed, seed)
    XCTAssertEqual(AppAccentColorSelection.custom(seed).customSeed, seed)

    let invalidValues = [
      "", "custom:", "custom:12345", "custom:1234567", "custom:#123456",
      "custom:12aBeF",
      "custom:0x123456", "custom:12345678", "custom:12 456", "custom:12/456",
      "Custom:123456", " custom:123456", "custom:123456\n", "custom:１２３４５６",
      "custom:12345é", String(repeating: "A", count: 8_192),
    ]
    for value in invalidValues {
      XCTAssertNil(AppAccentColorSeed(storageValue: value), "Accepted \(value.debugDescription)")
      XCTAssertEqual(
        AppAccentColorSelection.resolved(value),
        .preset(.blue),
        "Did not safely fall back for \(value.debugDescription)"
      )
    }
    XCTAssertNil(AppAccentColorSeed(rgb: 0x01_000000))
  }

  func testAllPresetSelectionsRetainExactExistingPalettes() {
    for preset in AppAccentColor.allCases {
      let selection = AppAccentColorSelection.resolved(preset.rawValue)
      let style = selection.style
      XCTAssertEqual(selection, .preset(preset))
      XCTAssertEqual(selection.storageValue, preset.rawValue)
      XCTAssertEqual(selection.title, preset.title)
      XCTAssertNil(selection.customSeed)
      XCTAssertEqual(style.selection, selection)
      XCTAssertFalse(style.didFallback)

      for appearance in AppAccentColorAppearance.allCases {
        XCTAssertEqual(
          style.components(for: appearance),
          preset.components(for: appearance)
        )
      }
    }
  }

  func testCustomPaletteIsDeterministicAndAccessibleAcrossSeedGrid() throws {
    let channelValues = stride(from: UInt32(0), through: 255, by: 17)
    for red in channelValues {
      for green in channelValues {
        for blue in channelValues {
          let seed = try XCTUnwrap(
            AppAccentColorSeed(rgb: (red << 16) | (green << 8) | blue)
          )
          let first = try XCTUnwrap(AppAccentPalette.custom(seed: seed))
          let second = try XCTUnwrap(AppAccentPalette.custom(seed: seed))
          XCTAssertEqual(first, second)
          assertCustomPaletteContract(first)
        }
      }
    }
  }

  func testCustomPaletteRetainsFirstGuardedCandidateOnGrayPath() throws {
    for rawValue in UInt32(0)...255 {
      let seed = try XCTUnwrap(
        AppAccentColorSeed(rgb: (rawValue << 16) | (rawValue << 8) | rawValue)
      )
      let palette = try XCTUnwrap(AppAccentPalette.custom(seed: seed))

      for appearance in AppAccentColorAppearance.allCases {
        let chosen = palette.components(for: appearance)
        let seedChannel = Int((seed.rgb >> 16) & 0xFF)
        let chosenChannel = Int((chosen.rgb >> 16) & 0xFF)
        let chosenDistance = appearance.isDark
          ? chosenChannel - seedChannel
          : seedChannel - chosenChannel
        guard chosenDistance > 0 else { continue }

        let priorChannel = appearance.isDark
          ? UInt32(seedChannel + chosenDistance - 1)
          : UInt32(seedChannel - chosenDistance + 1)
        let prior = AppAccentColorComponents(
          rgb: (priorChannel << 16) | (priorChannel << 8) | priorChannel
        )
        XCTAssertFalse(
          customCandidateMeetsGuardedContract(prior, appearance: appearance),
          "Gray seed \(rawValue) did not retain the first valid candidate in \(appearance)"
        )
      }
    }
  }

  func testCustomPaletteHandlesExtremeAndPresetSeeds() throws {
    let seeds: [UInt32] = [
      0x000000, 0xFFFFFF, 0x808080,
      0xFF0000, 0x00FF00, 0x0000FF,
      0x00FFFF, 0xFF00FF, 0xFFFF00,
    ] + AppAccentColor.allCases.map(\.editingSeed.rgb)

    for value in seeds {
      let seed = try XCTUnwrap(AppAccentColorSeed(rgb: value))
      let palette = try XCTUnwrap(AppAccentPalette.custom(seed: seed))
      assertCustomPaletteContract(palette)
    }
  }

  func testCustomPaletteFallbackReplacesTheWholeInvalidGroup() throws {
    let seed = try XCTUnwrap(AppAccentColorSeed(rgb: 0x123456))
    let invalid = AppAccentPalette(
      light: 0xFFFFFF,
      dark: 0x000000,
      highContrastLight: 0xFFFFFF,
      highContrastDark: 0x000000
    )

    let result = AppAccentPalette.validatedCustomOrDefault(seed: seed) { _ in invalid }

    XCTAssertTrue(result.didFallback)
    XCTAssertEqual(result.palette, AppAccentColor.defaultValue.palette)
  }

  func testEditorSeedPolicyPreservesCustomSeedAcrossPresetSwitches() throws {
    let active = try XCTUnwrap(AppAccentColorSeed(rgb: 0x123456))
    let saved = try XCTUnwrap(AppAccentColorSeed(rgb: 0xABCDEF))

    XCTAssertEqual(
      AppAccentColorEditorPolicy.initialSeed(
        selection: .custom(active),
        savedCustomSeed: saved
      ),
      active
    )
    XCTAssertEqual(
      AppAccentColorEditorPolicy.initialSeed(
        selection: .preset(.rose),
        savedCustomSeed: saved
      ),
      saved
    )
    XCTAssertEqual(
      AppAccentColorEditorPolicy.initialSeed(
        selection: .preset(.teal),
        savedCustomSeed: nil
      ),
      AppAccentColor.teal.editingSeed
    )
  }

  func testApplyingCustomSeedWritesSelfContainedSelectionFirst() throws {
    enum Event: Equatable {
      case selection(AppAccentColorSelection)
      case savedSeed(AppAccentColorSeed)
    }

    let seed = try XCTUnwrap(AppAccentColorSeed(rgb: 0x123456))
    var events: [Event] = []

    AppAccentColorEditorPolicy.apply(
      seed,
      setSelection: { events.append(.selection($0)) },
      setSavedCustomSeed: { events.append(.savedSeed($0)) }
    )

    XCTAssertEqual(events, [.selection(.custom(seed)), .savedSeed(seed)])
  }

  @MainActor
  func testCustomDynamicColorsResolveForEveryAppearance() throws {
    let seed = try XCTUnwrap(AppAccentColorSeed(rgb: 0xE7C400))
    let style = AppAccentColorSelection.custom(seed).style

    for appearance in AppAccentColorAppearance.allCases {
      let resolvedAccent = style.uiColor.resolvedColor(with: traits(for: appearance))
      let resolvedOnAccent = style.onAccentUIColor.resolvedColor(
        with: traits(for: appearance)
      )
      XCTAssertEqual(try rgbValue(resolvedAccent), style.components(for: appearance).rgb)
      XCTAssertEqual(
        try rgbValue(resolvedOnAccent),
        AppAccentColor.onAccentComponents(for: appearance).rgb
      )
    }
  }

  func testCGColorSeedConversionIsOpaqueBoundedAndStable() throws {
    let exact = try XCTUnwrap(AppAccentColorSeed(rgb: 0x12ABEF))
    XCTAssertEqual(AppAccentColorSeed(cgColor: exact.cgColor), exact)

    let gray = try XCTUnwrap(AppAccentColorSeed(cgColor: CGColor(gray: 0.5, alpha: 1)))
    XCTAssertEqual((gray.rgb >> 16) & 0xFF, (gray.rgb >> 8) & 0xFF)
    XCTAssertEqual((gray.rgb >> 8) & 0xFF, gray.rgb & 0xFF)

    let extendedSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
    let extended = try XCTUnwrap(
      CGColor(
        colorSpace: extendedSpace,
        components: [-0.25, 1.25, 0.5, 1]
      )
    )
    XCTAssertEqual(AppAccentColorSeed(cgColor: extended)?.rgb, 0x00FF80)

    XCTAssertNil(
      AppAccentColorSeed(
        cgColor: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
      )
    )
    XCTAssertNil(
      AppAccentColorSeed(
        cgColor: CGColor(
          srgbRed: 0.2,
          green: 0.4,
          blue: 0.6,
          alpha: 1 - (CGFloat(1) / CGFloat(255))
        )
      )
    )
    XCTAssertNil(
      AppAccentColorSeed.quantizedRGB(red: .nan, green: 0, blue: 0)
    )
    XCTAssertNil(
      AppAccentColorSeed.quantizedRGB(red: 0, green: .infinity, blue: 0)
    )
    XCTAssertEqual(
      AppAccentColorSeed.quantizedRGB(red: -1, green: 2, blue: 0.5),
      0x00FF80
    )
  }

  func testDisplayP3SeedConversionIsDeterministic() throws {
    let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    let color = try XCTUnwrap(
      CGColor(colorSpace: displayP3, components: [1, 0.25, 0, 1])
    )
    let first = try XCTUnwrap(AppAccentColorSeed(cgColor: color))
    let second = try XCTUnwrap(AppAccentColorSeed(cgColor: color))
    XCTAssertEqual(first, second)
    XCTAssertLessThanOrEqual(first.rgb, 0xFFFFFF)
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

  private func assertCustomPaletteContract(
    _ palette: AppAccentPalette,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for appearance in AppAccentColorAppearance.allCases {
      let accent = palette.components(for: appearance)
      let minimum = appearance.isHighContrast
        ? AppAccentColorContrast.highContrastMinimum
        : AppAccentColorContrast.normalMinimum
      for background in AppAccentColorContrast.backgrounds(for: appearance) {
        XCTAssertGreaterThanOrEqual(
          AppAccentColorContrast.contrastRatio(accent, background),
          minimum,
          file: file,
          line: line
        )
      }
      XCTAssertGreaterThanOrEqual(
        AppAccentColorContrast.contrastRatio(
          AppAccentColor.onAccentComponents(for: appearance),
          accent
        ),
        AppAccentColorContrast.onAccentMinimum,
        file: file,
        line: line
      )
    }

    XCTAssertLessThanOrEqual(
      AppAccentColorContrast.relativeLuminance(palette.components(for: .highContrastLight)),
      AppAccentColorContrast.relativeLuminance(palette.components(for: .light)),
      file: file,
      line: line
    )
    XCTAssertGreaterThanOrEqual(
      AppAccentColorContrast.relativeLuminance(palette.components(for: .highContrastDark)),
      AppAccentColorContrast.relativeLuminance(palette.components(for: .dark)),
      file: file,
      line: line
    )
  }

  private func customCandidateMeetsGuardedContract(
    _ accent: AppAccentColorComponents,
    appearance: AppAccentColorAppearance
  ) -> Bool {
    let minimum = appearance.isHighContrast
      ? AppAccentColorContrast.generatedHighContrastMinimum
      : AppAccentColorContrast.generatedNormalMinimum
    return AppAccentColorContrast.backgrounds(for: appearance).allSatisfy {
      AppAccentColorContrast.hasContrast(accent, $0, required: minimum)
    } && AppAccentColorContrast.hasContrast(
      AppAccentColor.onAccentComponents(for: appearance),
      accent,
      required: AppAccentColorContrast.generatedOnAccentMinimum
    )
  }
}
