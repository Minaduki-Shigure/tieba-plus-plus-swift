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
  func testBuiltBundleDeclaresPrimaryAndAlternateIconsForPhoneAndPad() throws {
    // Inspect actool's compiled declarations. Modern alternates may name only
    // an asset in Assets.car; CI inspects those compiled icon renditions with
    // assetutil, and the UI suite actually switches them through UIKit.
    let bundle = Bundle.main
    XCTAssertEqual(bundle.bundleIdentifier, "io.github.minaduki.tieba-plus-plus")
    for (manifestKey, idiom) in [
      ("CFBundleIcons", UIUserInterfaceIdiom.phone),
      ("CFBundleIcons~ipad", UIUserInterfaceIdiom.pad),
    ] {
      let manifest = try XCTUnwrap(
        bundle.object(forInfoDictionaryKey: manifestKey) as? [String: Any], manifestKey
      )
      let primary = try XCTUnwrap(manifest["CFBundlePrimaryIcon"] as? [String: Any])
      try assertIconDeclaration(primary, assetName: "AppIcon", idiom: idiom, bundle: bundle)

      let alternates = try XCTUnwrap(manifest["CFBundleAlternateIcons"] as? [String: Any])
      XCTAssertEqual(Set(alternates.keys), ["AppIconLight", "AppIconDark"], manifestKey)
      for choice in [AppIconChoice.light, .dark] {
        let name = try XCTUnwrap(choice.alternateIconName)
        let icon = try XCTUnwrap(alternates[name] as? [String: Any], "\(manifestKey).\(name)")
        try assertIconDeclaration(icon, assetName: name, idiom: idiom, bundle: bundle)
      }
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

  @MainActor
  private func assertIconDeclaration(
    _ declaration: [String: Any],
    assetName: String,
    idiom: UIUserInterfaceIdiom,
    bundle: Bundle,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertEqual(declaration["CFBundleIconName"] as? String, assetName, file: file, line: line)
    guard declaration["CFBundleIconFiles"] != nil else { return }
    let files = try XCTUnwrap(
      declaration["CFBundleIconFiles"] as? [String], assetName, file: file, line: line
    )
    XCTAssertFalse(files.isEmpty, assetName, file: file, line: line)
    XCTAssertEqual(Set(files).count, files.count, assetName, file: file, line: line)
    let traits = UITraitCollection(traitsFrom: [
      UITraitCollection(userInterfaceIdiom: idiom), UITraitCollection(displayScale: 2),
    ])
    for iconFile in files {
      let image = try XCTUnwrap(
        UIImage(named: iconFile, in: bundle, compatibleWith: traits),
        "Missing bundled icon \(assetName): \(iconFile) (\(idiom.rawValue))",
        file: file, line: line
      )
      let cgImage = try XCTUnwrap(image.cgImage, iconFile, file: file, line: line)
      XCTAssertEqual(cgImage.width, cgImage.height, iconFile, file: file, line: line)
      XCTAssertGreaterThan(cgImage.width, 0, iconFile, file: file, line: line)
    }
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
