import Foundation
import XCTest

@testable import TiebaPlusPlus

final class OfficialBaiduUsernameManagementHandoffTests: XCTestCase {
  func testURLIsTheExactCredentialFreeOfficialHTTPSDestination() throws {
    let url = try XCTUnwrap(OfficialBaiduUsernameManagementHandoff.validatedURL)
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(
      url.absoluteString,
      OfficialBaiduUsernameManagementHandoff.absoluteString
    )
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "wappass.baidu.com")
    XCTAssertNil(components.user)
    XCTAssertNil(components.password)
    XCTAssertNil(components.port)
    XCTAssertEqual(
      components.percentEncodedPath,
      "/static/manage-chunk/change-username.html"
    )
    XCTAssertNil(components.query)
    XCTAssertEqual(components.fragment, "/showUsername")
    XCTAssertEqual(components.percentEncodedFragment, "/showUsername")
  }

  func testURLValidationRejectsEveryDestinationMutation() {
    let rejectedValues = [
      "http://wappass.baidu.com/static/manage-chunk/change-username.html#/showUsername",
      "https://WAPPASS.baidu.com/static/manage-chunk/change-username.html#/showUsername",
      "https://wappass.baidu.com.:443/static/manage-chunk/change-username.html#/showUsername",
      "https://user:password@wappass.baidu.com/static/manage-chunk/change-username.html#/showUsername",
      "https://wappass.baidu.com:443/static/manage-chunk/change-username.html#/showUsername",
      "https://wappass.baidu.com/static/manage-chunk/change-username.htm#/showUsername",
      "https://wappass.baidu.com/static/manage-chunk/change-username.html?credential=secret#/showUsername",
      "https://wappass.baidu.com/static/manage-chunk/change-username.html",
      "https://wappass.baidu.com/static/manage-chunk/change-username.html#/other",
      "https://wappass.baidu.com/static/manage-chunk/change-username.html#%2FshowUsername",
    ]

    for value in rejectedValues {
      XCTAssertNil(
        OfficialBaiduUsernameManagementHandoff.validatedURL(from: value),
        value
      )
    }
  }

  func testDispositionUsesTheSelectedExternalWebMode() throws {
    let url = try XCTUnwrap(OfficialBaiduUsernameManagementHandoff.validatedURL)

    XCTAssertEqual(
      OfficialBaiduUsernameManagementHandoff.disposition(mode: .systemBrowser),
      .system(url)
    )
    XCTAssertEqual(
      OfficialBaiduUsernameManagementHandoff.disposition(mode: .inAppSafari),
      .inAppSafari(url)
    )
  }

  @MainActor
  func testOpenUsesOnlyTheValidatedURLAndFallsBackToSystemBrowser() throws {
    let expectedURL = try XCTUnwrap(OfficialBaiduUsernameManagementHandoff.validatedURL)
    var inAppURLs: [URL] = []
    var systemURLs: [URL] = []

    XCTAssertTrue(
      OfficialBaiduUsernameManagementHandoff.open(
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
      OfficialBaiduUsernameManagementHandoff.open(
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
      OfficialBaiduUsernameManagementHandoff.open(
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
