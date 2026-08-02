import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SecureTiebaLoginWebViewTests: XCTestCase {
  func testNavigationPolicyRequiresHTTPSAndAnExactHostAllowlist() throws {
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport?login"))
      )
    )
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://passport.baidu.com/v2/"))
      )
    )
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://passport.baidu.com:443/v2/"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "http://wappass.baidu.com/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://news.baidu.com/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://wappass.baidu.com.example/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://evilbaidu.com/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://wappass.baidu.com:444/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "https://user@wappass.baidu.com/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsMainFrame(
        try XCTUnwrap(URL(string: "file:///private/account-data"))
      )
    )

    XCTAssertTrue(
      TiebaLoginNavigationPolicy.allowsSubframe(
        try XCTUnwrap(URL(string: "https://dlswbr.baidu.com/challenge"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsSubframe(
        try XCTUnwrap(URL(string: "https://example.com/challenge"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsSubframe(
        try XCTUnwrap(URL(string: "javascript:alert(1)"))
      )
    )
  }

  func testCompletionURLIsRestrictedToTiebaMinePath() throws {
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/p/123"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine-redirect"))
      )
    )
  }

  func testCredentialCaptureAcceptsOnlyParentDomainBDUSS() throws {
    let unrelated = [
      try cookie(name: "BDUSS", value: String(repeating: "x", count: 192), domain: ".example.com")
    ]
    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: unrelated))

    let cookies = unrelated + [
      try cookie(name: "BDUSS", value: String(repeating: "b", count: 192), domain: ".baidu.com"),
      try cookie(name: "STOKEN", value: String(repeating: "s", count: 64), domain: ".tieba.baidu.com"),
      try cookie(
        name: "BDUSS",
        value: String(repeating: "m", count: 192),
        domain: ".baidu.com",
        path: "/passport",
        expires: Date(timeIntervalSinceNow: 7_200)
      ),
    ]
    let credentials = try XCTUnwrap(TiebaLoginNavigationPolicy.credentials(from: cookies))
    XCTAssertEqual(credentials.bduss.count, 192)
    XCTAssertEqual(credentials.bduss.first, "b")
  }

  func testCredentialCaptureRejectsWrongDomainOrMalformedValues() throws {
    let wrongDomain = [
      try cookie(
        name: "BDUSS",
        value: String(repeating: "b", count: 192),
        domain: ".tieba.baidu.com"
      )
    ]
    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: wrongDomain))

    let malformed = [
      try cookie(name: "BDUSS", value: "short", domain: ".baidu.com")
    ]
    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: malformed))
  }

  func testCredentialCaptureRejectsInsecureExpiredAndWhitespaceValues() throws {
    let validBDUSS = String(repeating: "b", count: 192)

    XCTAssertNil(
      TiebaLoginNavigationPolicy.credentials(from: [
        try cookie(name: "BDUSS", value: validBDUSS, domain: ".baidu.com", secure: false)
      ])
    )
    XCTAssertNil(
      TiebaLoginNavigationPolicy.credentials(from: [
        try cookie(
          name: "BDUSS",
          value: validBDUSS,
          domain: ".baidu.com",
          expires: Date(timeIntervalSinceNow: -60)
        )
      ])
    )
    XCTAssertNil(
      TiebaLoginNavigationPolicy.credentials(from: [
        try cookie(
          name: "BDUSS",
          value: String(repeating: "b", count: 191) + " ",
          domain: ".baidu.com"
        )
      ])
    )
  }

  private func cookie(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    secure: Bool = true,
    expires: Date = Date(timeIntervalSinceNow: 3_600)
  ) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
      .expires: expires,
    ]
    if secure {
      properties[.secure] = "TRUE"
    }
    return try XCTUnwrap(
      HTTPCookie(properties: properties)
    )
  }
}
