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

  func testCompletionURLAcceptsOnlyTiebaAccountPathFamily() throws {
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine"))
      )
    )
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tiebac.baidu.com/index/tbwise"))
      )
    )
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(
          URL(string: "https://tieba.baidu.com/index/tbwise/home?source=login#account")
        )
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
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwiseevil/mine"))
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.isCompletionURL(
        try XCTUnwrap(URL(string: "https://tieba.baidu.com/INDEX/tbwise/mine"))
      )
    )
  }

  func testCredentialCaptureContextRequiresEphemeralStoreAndCompletionURL() throws {
    let completionURL = try XCTUnwrap(
      URL(string: "https://tieba.baidu.com/index/tbwise/mine")
    )
    XCTAssertTrue(
      TiebaLoginNavigationPolicy.allowsCredentialCapture(
        at: completionURL,
        dataStoreIsPersistent: false
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsCredentialCapture(
        at: completionURL,
        dataStoreIsPersistent: true
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsCredentialCapture(
        at: try XCTUnwrap(URL(string: "https://tieba.baidu.com/p/123")),
        dataStoreIsPersistent: false
      )
    )
    XCTAssertFalse(
      TiebaLoginNavigationPolicy.allowsCredentialCapture(
        at: nil,
        dataStoreIsPersistent: false
      )
    )
  }

  func testCredentialCaptureRequiresACompletePairFromOneSnapshot() throws {
    let bduss = try cookie(name: "BDUSS", value: validBDUSS, domain: ".baidu.com")
    let stoken = try cookie(
      name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com"
    )

    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: [bduss]))
    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: [stoken]))

    let credentials = try XCTUnwrap(
      TiebaLoginNavigationPolicy.credentials(from: [bduss, stoken])
    )
    XCTAssertEqual(credentials.bduss, validBDUSS)
    XCTAssertEqual(credentials.stoken, validSTOKEN)
    XCTAssertEqual(credentials.bdussCookieName, .bduss)
  }

  func testCredentialCapturePreservesActualBFESSCookieName() throws {
    let credentials = try XCTUnwrap(
      TiebaLoginNavigationPolicy.credentials(from: [
        try cookie(
          name: "bduss",
          value: String(repeating: "b", count: 192),
          domain: ".baidu.com",
          expires: Date(timeIntervalSinceNow: 7_200)
        ),
        try cookie(
          name: "bduss_bfess",
          value: String(repeating: "f", count: 192),
          domain: "baidu.com",
          expires: Date(timeIntervalSinceNow: 3_600)
        ),
        try cookie(name: "stoken", value: validSTOKEN, domain: "tieba.baidu.com"),
      ])
    )

    XCTAssertEqual(credentials.bduss.first, "f")
    XCTAssertEqual(credentials.bdussCookieName, .bdussBFESS)
  }

  func testSecureCookiesPrecedeNewerNonSecureCandidates() throws {
    let cookies = [
      try cookie(
        name: "BDUSS",
        value: String(repeating: "b", count: 192),
        domain: ".baidu.com",
        expires: Date(timeIntervalSinceNow: 3_600)
      ),
      try cookie(
        name: "BDUSS_BFESS",
        value: String(repeating: "f", count: 192),
        domain: ".baidu.com",
        secure: false,
        expires: Date(timeIntervalSinceNow: 7_200)
      ),
      try cookie(
        name: "STOKEN",
        value: String(repeating: "s", count: 64),
        domain: ".tieba.baidu.com",
        expires: Date(timeIntervalSinceNow: 3_600)
      ),
      try cookie(
        name: "STOKEN",
        value: String(repeating: "n", count: 64),
        domain: ".tieba.baidu.com",
        secure: false,
        expires: Date(timeIntervalSinceNow: 7_200)
      ),
    ]

    for orderedCookies in [cookies, Array(cookies.reversed())] {
      let credentials = try XCTUnwrap(
        TiebaLoginNavigationPolicy.credentials(
          from: orderedCookies,
          cookiePolicy: .isolatedHTTPSLoginCompletion
        )
      )
      XCTAssertEqual(credentials.bduss.first, "b")
      XCTAssertEqual(credentials.stoken.first, "s")
      XCTAssertEqual(credentials.bdussCookieName, .bduss)
    }
  }

  func testNonSecurePairRequiresExplicitIsolatedHTTPSPolicy() throws {
    let cookies = try credentialCookies(secure: false)
    XCTAssertNil(TiebaLoginNavigationPolicy.credentials(from: cookies))

    let credentials = try XCTUnwrap(
      TiebaLoginNavigationPolicy.credentials(
        from: cookies,
        cookiePolicy: .isolatedHTTPSLoginCompletion
      )
    )
    XCTAssertEqual(credentials.bduss, validBDUSS)
    XCTAssertEqual(credentials.stoken, validSTOKEN)
  }

  func testCredentialCaptureEnforcesExactDomainsPathsExpiryAndLengths() throws {
    let validBDUSSCookie = try cookie(
      name: "BDUSS", value: validBDUSS, domain: ".baidu.com"
    )
    let validSTOKENCookie = try cookie(
      name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com"
    )
    let invalidBDUSSCookies = [
      try cookie(name: "BDUSS", value: validBDUSS, domain: ".tieba.baidu.com"),
      try cookie(name: "BDUSS", value: validBDUSS, domain: ".sub.baidu.com"),
      try cookie(name: "BDUSS", value: validBDUSS, domain: ".baidu.com", path: "/login"),
      try cookie(
        name: "BDUSS", value: validBDUSS, domain: ".baidu.com",
        expires: Date(timeIntervalSinceNow: -60)
      ),
      try cookie(name: "BDUSS", value: String(repeating: "b", count: 191), domain: ".baidu.com"),
    ]
    let invalidSTOKENCookies = [
      try cookie(name: "STOKEN", value: validSTOKEN, domain: ".baidu.com"),
      try cookie(name: "STOKEN", value: validSTOKEN, domain: ".sub.tieba.baidu.com"),
      try cookie(
        name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com", path: "/login"
      ),
      try cookie(
        name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com",
        expires: Date(timeIntervalSinceNow: -60)
      ),
      try cookie(
        name: "STOKEN", value: String(repeating: "s", count: 63),
        domain: ".tieba.baidu.com"
      ),
    ]

    for cookie in invalidBDUSSCookies {
      XCTAssertNil(
        TiebaLoginNavigationPolicy.credentials(from: [cookie, validSTOKENCookie])
      )
    }
    for cookie in invalidSTOKENCookies {
      XCTAssertNil(
        TiebaLoginNavigationPolicy.credentials(from: [validBDUSSCookie, cookie])
      )
    }
  }

  func testCredentialCaptureRejectsRFC6265UnsafeOctetsInEitherSecret() throws {
    let forbiddenSuffixes = [" ", "\t", "\"", ",", ";", "\\"]

    for suffix in forbiddenSuffixes {
      let invalidBDUSS = String(repeating: "b", count: 191) + suffix
      let invalidSTOKEN = String(repeating: "s", count: 63) + suffix
      XCTAssertFalse(AccountCredentialFormat.isValidBDUSS(invalidBDUSS))
      XCTAssertFalse(AccountCredentialFormat.isValidSTOKEN(invalidSTOKEN))
      if let bdussCookie = HTTPCookie(
        properties: cookieProperties(
          name: "BDUSS", value: invalidBDUSS, domain: ".baidu.com"
        )
      ) {
        XCTAssertNil(
          TiebaLoginNavigationPolicy.credentials(
            from: [
              bdussCookie,
              try cookie(name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com"),
            ]
          )
        )
      }
      if let stokenCookie = HTTPCookie(
        properties: cookieProperties(
          name: "STOKEN", value: invalidSTOKEN, domain: ".tieba.baidu.com"
        )
      ) {
        XCTAssertNil(
          TiebaLoginNavigationPolicy.credentials(
            from: [
              try cookie(name: "BDUSS", value: validBDUSS, domain: ".baidu.com"),
              stokenCookie,
            ]
          )
        )
      }
    }
  }

  func testCredentialRetryPolicyStopsAtItsBound() {
    var policy = TiebaLoginCredentialRetryPolicy()
    var delays: [UInt64] = []

    for _ in 0..<5 {
      guard case .retry(let delay) = policy.evaluate(nil) else {
        return XCTFail("Expected a bounded retry before exhaustion")
      }
      delays.append(delay)
    }
    guard case .failed = policy.evaluate(nil) else {
      return XCTFail("Expected the sixth missing-cookie attempt to fail")
    }

    XCTAssertEqual(
      delays,
      [100_000_000, 200_000_000, 400_000_000, 800_000_000, 1_000_000_000]
    )
    XCTAssertEqual(policy.completedAttempts, 6)
    XCTAssertTrue(policy.isTerminal)
    guard case .ignored = policy.evaluate(nil) else {
      return XCTFail("Expected results after exhaustion to be ignored")
    }
    XCTAssertEqual(policy.completedAttempts, 6)
  }

  func testCredentialRetryPolicyStopsImmediatelyAfterCredentialsArrive() {
    var policy = TiebaLoginCredentialRetryPolicy()
    guard case .retry = policy.evaluate(nil) else {
      return XCTFail("Expected the first missing-cookie attempt to retry")
    }

    let expected = AccountCredentials(
      bduss: validBDUSS,
      stoken: validSTOKEN,
      bdussCookieName: .bduss
    )
    guard case .captured(let credentials) = policy.evaluate(expected)
    else {
      return XCTFail("Expected credentials to finish the capture")
    }

    XCTAssertEqual(credentials.bduss, expected.bduss)
    XCTAssertEqual(credentials.stoken, expected.stoken)
    XCTAssertEqual(policy.completedAttempts, 2)
    XCTAssertTrue(policy.isTerminal)
    guard case .ignored = policy.evaluate(expected) else {
      return XCTFail("Expected late credentials to be ignored")
    }
  }

  func testCredentialRetryDoesNotCombineSecretsAcrossSnapshots() throws {
    var policy = TiebaLoginCredentialRetryPolicy()
    let bdussOnly = [
      try cookie(name: "BDUSS", value: validBDUSS, domain: ".baidu.com")
    ]
    guard
      case .retry = policy.evaluate(
        TiebaLoginNavigationPolicy.credentials(from: bdussOnly)
      )
    else { return XCTFail("Expected an incomplete first snapshot to retry") }

    let stokenOnly = [
      try cookie(name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com")
    ]
    guard
      case .retry = policy.evaluate(
        TiebaLoginNavigationPolicy.credentials(from: stokenOnly)
      )
    else { return XCTFail("Expected an unrelated half snapshot to retry") }

    guard
      case .captured(let credentials) = policy.evaluate(
        TiebaLoginNavigationPolicy.credentials(from: try credentialCookies())
      )
    else { return XCTFail("Expected the later complete snapshot to finish") }
    XCTAssertEqual(credentials.bduss, validBDUSS)
    XCTAssertEqual(credentials.stoken, validSTOKEN)
    XCTAssertEqual(policy.completedAttempts, 3)
  }

  private var validBDUSS: String { String(repeating: "b", count: 192) }
  private var validSTOKEN: String { String(repeating: "s", count: 64) }

  private func credentialCookies(secure: Bool = true) throws -> [HTTPCookie] {
    [
      try cookie(
        name: "BDUSS", value: validBDUSS, domain: ".baidu.com", secure: secure
      ),
      try cookie(
        name: "STOKEN", value: validSTOKEN, domain: ".tieba.baidu.com", secure: secure
      ),
    ]
  }

  private func cookie(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    secure: Bool = true,
    expires: Date? = Date(timeIntervalSinceNow: 3_600)
  ) throws -> HTTPCookie {
    let properties = cookieProperties(
      name: name,
      value: value,
      domain: domain,
      path: path,
      secure: secure,
      expires: expires
    )
    return try XCTUnwrap(
      HTTPCookie(properties: properties)
    )
  }

  private func cookieProperties(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    secure: Bool = true,
    expires: Date? = Date(timeIntervalSinceNow: 3_600)
  ) -> [HTTPCookiePropertyKey: Any] {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
    ]
    if let expires {
      properties[.expires] = expires
    }
    if secure {
      properties[.secure] = "TRUE"
    }
    return properties
  }
}
