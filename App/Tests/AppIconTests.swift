import Foundation
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class AppIconTests: XCTestCase {
  func testCatalogMapsOnlyTheThreeDeclaredSystemIconNames() {
    XCTAssertEqual(AppIconChoice.allCases, [.classic, .light, .dark])
    XCTAssertEqual(Set(AppIconChoice.allCases.map(\.id)).count, 3)
    XCTAssertEqual(Set(AppIconChoice.allCases.map(\.title)).count, 3)
    XCTAssertTrue(
      AppIconChoice.allCases.allSatisfy {
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })

    XCTAssertNil(AppIconChoice.classic.alternateIconName)
    XCTAssertEqual(AppIconChoice.light.alternateIconName, "AppIconLight")
    XCTAssertEqual(AppIconChoice.dark.alternateIconName, "AppIconDark")
    XCTAssertEqual(AppIconChoice.classic.previewAssetName, "AppIconPreviewClassic")
    XCTAssertEqual(AppIconChoice.light.previewAssetName, "AppIconPreviewLight")
    XCTAssertEqual(AppIconChoice.dark.previewAssetName, "AppIconPreviewDark")

    for choice in AppIconChoice.allCases {
      XCTAssertEqual(AppIconChoice.from(alternateIconName: choice.alternateIconName), choice)
    }
    for unknown in ["", "AppIcon", "appiconlight", "AppIconLight ", "OtherAppIcon"] {
      XCTAssertNil(AppIconChoice.from(alternateIconName: unknown), unknown)
    }
  }

  @MainActor
  func testBuiltBundleDeclaresPrimaryAndAlternateIconsWithValidDeviceOverrides() throws {
    // Inspect actool's compiled declarations. Modern alternates may name only
    // an asset in Assets.car; CI inspects those compiled icon renditions with
    // assetutil, and the UI suite actually switches them through UIKit.
    let bundle = Bundle.main
    XCTAssertEqual(bundle.bundleIdentifier, "io.github.minaduki.tieba-plus-plus")
    // Bundle resolves device-qualified keys for this runtime and removes the
    // suffixes from its in-memory dictionary. Inspect the file to validate
    // any iPad override even when these tests are running on an iPhone.
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: bundle.bundleURL.appendingPathComponent("Info.plist")),
        options: [], format: nil
      ) as? [String: Any]
    )
    for manifestKey in ["CFBundleIcons", "CFBundleIcons~ipad"] {
      // iPad uses the generic dictionary when there is no device-specific
      // override. If an override exists it must be complete: UIKit does not
      // merge missing alternate entries from the generic dictionary.
      if manifestKey == "CFBundleIcons~ipad", info[manifestKey] == nil { continue }
      let manifest = try XCTUnwrap(
        info[manifestKey] as? [String: Any], manifestKey
      )
      _ = try assertIconManifest(manifest, label: manifestKey)
    }
  }

  @MainActor
  func testRuntimeBundleResolvesLoadableIconsForCurrentDevice() throws {
    let bundle = Bundle.main
    let manifest = try XCTUnwrap(
      bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
    )
    let files = try assertIconManifest(manifest, label: "Resolved CFBundleIcons")
    let idiom = UIDevice.current.userInterfaceIdiom
    let traits = UITraitCollection(userInterfaceIdiom: idiom)
    // Only load legacy PNGs selected for this device. An iPhone process does
    // not need to resolve standalone iPad resources from the raw override.
    for iconFile in files {
      let image = try XCTUnwrap(
        UIImage(named: iconFile, in: bundle, compatibleWith: traits),
        "Missing bundled icon: \(iconFile) (\(idiom.rawValue))"
      )
      let cgImage = try XCTUnwrap(image.cgImage, iconFile)
      XCTAssertEqual(cgImage.width, cgImage.height, iconFile)
      XCTAssertGreaterThan(cgImage.width, 0, iconFile)
    }
  }

  @MainActor
  func testBundledPreviewsAreDistinctOpaqueSquareImagesAtUsefulResolution() throws {
    var previewPixels: [Data] = []
    for choice in AppIconChoice.allCases {
      let image = try XCTUnwrap(
        UIImage(named: choice.previewAssetName, in: .main, compatibleWith: nil),
        choice.previewAssetName
      )
      let cgImage = try XCTUnwrap(image.cgImage, choice.previewAssetName)
      XCTAssertEqual(cgImage.width, cgImage.height, choice.previewAssetName)
      XCTAssertGreaterThanOrEqual(cgImage.width, 128, choice.previewAssetName)

      let pixels = try rgbaPixels(cgImage)
      XCTAssertTrue(
        stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 },
        "\(choice.previewAssetName) must not contain transparent pixels"
      )
      previewPixels.append(pixels)
    }
    XCTAssertEqual(Set(previewPixels).count, 3, "Each picker option must show its own artwork")
  }

  private func assertIconManifest(
    _ manifest: [String: Any],
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String] {
    let primary = try XCTUnwrap(
      manifest["CFBundlePrimaryIcon"] as? [String: Any], label, file: file, line: line
    )
    var files = try assertIconDeclaration(primary, assetName: "AppIcon", file: file, line: line)
    let alternates = try XCTUnwrap(
      manifest["CFBundleAlternateIcons"] as? [String: Any], label, file: file, line: line
    )
    XCTAssertEqual(
      Set(alternates.keys), ["AppIconLight", "AppIconDark"], label, file: file, line: line)
    for choice in [AppIconChoice.light, .dark] {
      let name = try XCTUnwrap(choice.alternateIconName, file: file, line: line)
      let icon = try XCTUnwrap(
        alternates[name] as? [String: Any], "\(label).\(name)", file: file, line: line
      )
      files.append(
        contentsOf: try assertIconDeclaration(icon, assetName: name, file: file, line: line))
    }
    return files
  }

  private func assertIconDeclaration(
    _ declaration: [String: Any],
    assetName: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> [String] {
    XCTAssertEqual(declaration["CFBundleIconName"] as? String, assetName, file: file, line: line)
    guard declaration["CFBundleIconFiles"] != nil else { return [] }
    let files = try XCTUnwrap(
      declaration["CFBundleIconFiles"] as? [String], assetName, file: file, line: line
    )
    XCTAssertFalse(files.isEmpty, assetName, file: file, line: line)
    XCTAssertEqual(Set(files).count, files.count, assetName, file: file, line: line)
    XCTAssertTrue(files.allSatisfy { !$0.isEmpty }, assetName, file: file, line: line)
    return files
  }

  private func rgbaPixels(_ image: CGImage) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Data(pixels)
  }
}
