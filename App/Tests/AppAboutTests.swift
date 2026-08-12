import Foundation
import XCTest

@testable import TiebaPlusPlus

final class AppAboutTests: XCTestCase {
  func testMetadataNormalizesBundleValuesAndFormatsVersion() {
    let metadata = AppAboutMetadata(
      infoDictionary: [
        "CFBundleDisplayName": "  贴吧++  ",
        "CFBundleName": "Ignored",
        "CFBundleShortVersionString": " 0.59.0 ",
        "CFBundleVersion": " 62 ",
      ]
    )

    XCTAssertEqual(metadata.displayName, "贴吧++")
    XCTAssertEqual(metadata.versionName, "0.59.0")
    XCTAssertEqual(metadata.buildNumber, "62")
    XCTAssertEqual(metadata.versionDescription, "版本 0.59.0（62）")
  }

  func testMetadataFallsBackForMissingInvalidAndOversizedValues() {
    let metadata = AppAboutMetadata(
      infoDictionary: [
        "CFBundleDisplayName": " \n ",
        "CFBundleName": String(repeating: "a", count: 101),
        "CFBundleShortVersionString": 59,
        "CFBundleVersion": "bad\u{0}build",
      ]
    )

    XCTAssertEqual(metadata.displayName, AppAboutMetadata.fallbackDisplayName)
    XCTAssertNil(metadata.versionName)
    XCTAssertNil(metadata.buildNumber)
    XCTAssertEqual(metadata.versionDescription, "版本未知")
  }

  func testMetadataUsesBundleNameFallbackAndOmitsMissingBuild() {
    let metadata = AppAboutMetadata(
      infoDictionary: [
        "CFBundleDisplayName": " \n ",
        "CFBundleName": "TiebaPlusPlus",
        "CFBundleShortVersionString": "0.60.0",
        "CFBundleVersion": NSNull(),
      ]
    )

    XCTAssertEqual(metadata.displayName, "TiebaPlusPlus")
    XCTAssertEqual(metadata.versionDescription, "版本 0.60.0")
  }

  func testMetadataShowsBuildWhenOnlyBuildIsAvailable() {
    let metadata = AppAboutMetadata(
      infoDictionary: ["CFBundleVersion": "62"]
    )

    XCTAssertNil(metadata.versionName)
    XCTAssertEqual(metadata.buildNumber, "62")
    XCTAssertEqual(metadata.versionDescription, "构建 62")
  }

  func testSourceURLIsAnExactCredentialFreeHTTPSRepositoryTarget() throws {
    let url = try XCTUnwrap(AppAboutSourceLink.validatedURL)
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(url.absoluteString, AppAboutSourceLink.absoluteString)
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "github.com")
    XCTAssertNil(components.user)
    XCTAssertNil(components.password)
    XCTAssertNil(components.port)
    XCTAssertEqual(
      components.percentEncodedPath,
      "/Minaduki-Shigure/tieba-plus-plus-swift"
    )
    XCTAssertNil(components.query)
    XCTAssertNil(components.fragment)
  }

  func testSourceURLUsesSelectedExternalWebMode() throws {
    let url = try XCTUnwrap(AppAboutSourceLink.validatedURL)

    XCTAssertEqual(
      AppAboutSourceLink.disposition(mode: .systemBrowser),
      .system(url)
    )
    XCTAssertEqual(
      AppAboutSourceLink.disposition(mode: .inAppSafari),
      .inAppSafari(url)
    )
  }

  @MainActor
  func testSourceOpenUsesOnlyTheValidatedURLAndFallsBackToSystem() throws {
    let expectedURL = try XCTUnwrap(AppAboutSourceLink.validatedURL)
    var inAppURLs: [URL] = []
    var systemURLs: [URL] = []

    XCTAssertTrue(
      AppAboutSourceLink.open(
        mode: .inAppSafari,
        inAppSafari: { url in
          inAppURLs.append(url)
          return false
        },
        systemBrowser: { systemURLs.append($0) }
      )
    )
    XCTAssertEqual(inAppURLs, [expectedURL])
    XCTAssertEqual(systemURLs, [expectedURL])

    inAppURLs.removeAll()
    systemURLs.removeAll()
    XCTAssertTrue(
      AppAboutSourceLink.open(
        mode: .inAppSafari,
        inAppSafari: { url in
          inAppURLs.append(url)
          return true
        },
        systemBrowser: { systemURLs.append($0) }
      )
    )
    XCTAssertEqual(inAppURLs, [expectedURL])
    XCTAssertTrue(systemURLs.isEmpty)

    inAppURLs.removeAll()
    systemURLs.removeAll()
    XCTAssertTrue(
      AppAboutSourceLink.open(
        mode: .systemBrowser,
        inAppSafari: { url in
          inAppURLs.append(url)
          return true
        },
        systemBrowser: { systemURLs.append($0) }
      )
    )
    XCTAssertTrue(inAppURLs.isEmpty)
    XCTAssertEqual(systemURLs, [expectedURL])
  }
}
