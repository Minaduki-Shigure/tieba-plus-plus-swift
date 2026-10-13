import Foundation
import XCTest

@testable import TiebaPlusPlus

final class OfficialTiebaServiceCenterHandoffTests: XCTestCase {
  func testURLIsTheExactCredentialFreeOfficialHTTPSDestination() throws {
    let url = try XCTUnwrap(OfficialTiebaServiceCenterHandoff.validatedURL)
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(url.absoluteString, OfficialTiebaServiceCenterHandoff.absoluteString)
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "tieba.baidu.com")
    XCTAssertNil(components.user)
    XCTAssertNil(components.password)
    XCTAssertNil(components.port)
    XCTAssertEqual(
      components.percentEncodedPath,
      "/mo/q/hybrid-main-service/uegServiceCenter"
    )
    XCTAssertNil(components.query)
    XCTAssertNil(components.fragment)
  }

  func testURLValidationRejectsDestinationAndParameterMutations() {
    let rejectedValues = [
      "http://tieba.baidu.com/mo/q/hybrid-main-service/uegServiceCenter",
      "https://TIEBA.baidu.com/mo/q/hybrid-main-service/uegServiceCenter",
      "https://tieba.baidu.com./mo/q/hybrid-main-service/uegServiceCenter",
      "https://tieba.baidu.com.evil.example/mo/q/hybrid-main-service/uegServiceCenter",
      "https://user:password@tieba.baidu.com/mo/q/hybrid-main-service/uegServiceCenter",
      "https://tieba.baidu.com:443/mo/q/hybrid-main-service/uegServiceCenter",
      "https://tieba.baidu.com/mo/q/hybrid-main-service/uegServiceCenter/",
      "https://tieba.baidu.com/mo/q/hybrid-main-service/other",
      "https://tieba.baidu.com/mo/q/hybrid-main-service/uegServiceCenter?cuid=untrusted",
      "https://tieba.baidu.com/mo/q/hybrid-main-service/uegServiceCenter#fragment",
    ]

    for value in rejectedValues {
      XCTAssertNil(
        OfficialTiebaServiceCenterHandoff.validatedURL(from: value),
        value
      )
    }
  }

  @MainActor
  func testFixedURLRemainsExternalAndCanBePresentedInApp() throws {
    let url = try XCTUnwrap(OfficialTiebaServiceCenterHandoff.validatedURL)

    XCTAssertNil(TiebaLink.target(from: url))
    XCTAssertEqual(
      BrowseContentLinkRouter.disposition(for: url, mode: .systemBrowser),
      .system(url)
    )
    XCTAssertEqual(
      BrowseContentLinkRouter.disposition(for: url, mode: .inAppSafari),
      .inAppSafari(url)
    )

    let presentationModel = ExternalWebPresentationModel()
    XCTAssertTrue(presentationModel.requestPresentation(for: url))
    XCTAssertEqual(presentationModel.page?.url, url)
  }

  @MainActor
  func testOpenHonorsExternalModeAndFallsBackToSystemBrowser() throws {
    let expectedURL = try XCTUnwrap(OfficialTiebaServiceCenterHandoff.validatedURL)
    var inAppURLs: [URL] = []
    var systemURLs: [URL] = []

    XCTAssertTrue(
      OfficialTiebaServiceCenterHandoff.open(
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
      OfficialTiebaServiceCenterHandoff.open(
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
      OfficialTiebaServiceCenterHandoff.open(
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
