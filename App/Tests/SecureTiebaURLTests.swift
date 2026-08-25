import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SecureTiebaURLTests: XCTestCase {
  func testPortraitTokenUsesCertificateValidHTTPSHost() throws {
    let url = try XCTUnwrap(SecureTiebaURL.portrait("portrait token"))

    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "himg.bdimg.com")
    XCTAssertEqual(url.path, "/sys/portraitn/item/portrait token")
  }

  func testPortraitAcceptsHTTPSURLAndRejectsUnsafeAbsoluteURL() throws {
    let remote = try XCTUnwrap(
      SecureTiebaURL.portrait("https://gss0.bdstatic.com/sys/portrait/item/token.jpg")
    )

    XCTAssertEqual(remote.scheme, "https")
    XCTAssertEqual(remote.host, "gss0.bdstatic.com")
    XCTAssertNil(SecureTiebaURL.portrait("file:///private/avatar.png"))
    XCTAssertNil(SecureTiebaURL.portrait("javascript://alert"))
  }

  func testStrictPortraitAcceptsOnlyCanonicalTokenAndCacheBuster() {
    XCTAssertEqual(
      SecureTiebaURL.strictPortrait("portrait-token?t=123")?.absoluteString,
      "https://himg.bdimg.com/sys/portraitn/item/portrait-token"
    )
    XCTAssertEqual(
      SecureTiebaURL.strictPortrait(
        "https://tb.himg.baidu.com/sys/portrait/item/portrait-token?t=12345678901234567890"
      )?.absoluteString,
      "https://himg.bdimg.com/sys/portraitn/item/portrait-token"
    )
    XCTAssertNil(
      SecureTiebaURL.strictPortrait(
        "portrait-token?t=123456789012345678901"
      )
    )
    XCTAssertNil(SecureTiebaURL.strictPortrait("portrait-token?evil=123"))
    XCTAssertNil(SecureTiebaURL.strictPortrait("file:///private/avatar.png"))
  }

  func testLargePortraitAcceptsStrictBareTokenAndLengthBoundary() throws {
    let token = "AbC012._~-"
    let url = try XCTUnwrap(SecureTiebaURL.largePortrait(token))

    XCTAssertEqual(
      url.absoluteString,
      "https://himg.bdimg.com/sys/portraith/item/AbC012._~-"
    )
    XCTAssertNotNil(SecureTiebaURL.largePortrait(String(repeating: "a", count: 512)))
    XCTAssertNil(SecureTiebaURL.largePortrait(String(repeating: "a", count: 513)))
    XCTAssertEqual(
      SecureTiebaURL.largePortrait(" \n\tAbC012._~- \r")?.absoluteString,
      url.absoluteString
    )
    XCTAssertEqual(
      SecureTiebaURL.largePortrait("AbC012._~-?t=12345678901234567890")?.absoluteString,
      url.absoluteString
    )
    XCTAssertEqual(
      SecureTiebaURL.largePortrait("AbC012._~-?t=1")?.absoluteString,
      url.absoluteString
    )
  }

  func testLargePortraitCanonicalizesAllowedHostsSchemesAndPaths() throws {
    for rawValue in [
      "http://tb.himg.baidu.com/sys/portrait/item/token-1",
      "https://tb.himg.baidu.com/sys/portrait/item/token-1",
      "http://himg.bdimg.com/sys/portraitn/item/token-1",
      "https://himg.bdimg.com/sys/portraitn/item/token-1",
      "HTTPS://HIMG.BDIMG.COM/sys/portraith/item/token-1",
      "//tb.himg.baidu.com/sys/portraith/item/token-1",
      "https://himg.bdimg.com/sys/portrait/item/token-1?t=1234567890",
    ] {
      XCTAssertEqual(
        SecureTiebaURL.largePortrait(rawValue)?.absoluteString,
        "https://himg.bdimg.com/sys/portraith/item/token-1"
      )
    }
  }

  func testLargePortraitDecodesURLTokenExactlyOnce() {
    XCTAssertEqual(
      SecureTiebaURL.largePortrait(
        "https://himg.bdimg.com/sys/portrait/item/a%2Eb%7Ec"
      )?.absoluteString,
      "https://himg.bdimg.com/sys/portraith/item/a.b~c"
    )

    for encodedToken in [
      "a%2Fb",
      "a%2fb",
      "a%5Cb",
      "a%5cb",
      "a%252Fb",
      "a%255Cb",
      "%2E%2E",
      "%2e%2e",
      "%252E",
      "%252E%252E",
      "a%00b",
      "%ZZ",
    ] {
      XCTAssertNil(
        SecureTiebaURL.largePortrait(
          "https://himg.bdimg.com/sys/portrait/item/\(encodedToken)"
        )
      )
    }
  }

  func testLargePortraitRejectsInvalidBareTokens() {
    let invalidTokens: [String?] = [
      nil,
      "",
      " ",
      ".",
      "..",
      "a/b",
      "a\\b",
      "a%b",
      "a?b",
      "a?t=",
      "a?t=123456789012345678901",
      "a?t=1&t=2",
      "a?t=1?t=2",
      "a?t=%31",
      "a?t=+1",
      "a?t=-1",
      "a?t=1.0",
      "a?t=１２３",
      "a?t=1#fragment",
      "头像",
    ]

    for token in invalidTokens {
      XCTAssertNil(SecureTiebaURL.largePortrait(token))
    }
  }

  func testLargePortraitRejectsUntrustedURLStructure() {
    let invalidURLs = [
      "https://gss0.bdstatic.com/sys/portrait/item/token",
      "https://example.com/sys/portrait/item/token",
      "https://himg.bdimg.com.example.com/sys/portrait/item/token",
      "https://himg.bdimg.com./sys/portrait/item/token",
      "https://%68img.bdimg.com/sys/portrait/item/token",
      "https://himg.bdimg.com@evil.example/sys/portrait/item/token",
      "https://evil@himg.bdimg.com/sys/portrait/item/token",
      "https://himg.bdimg.com%40evil.example/sys/portrait/item/token",
      "https://himg.bdimg.com%3A443/sys/portrait/item/token",
      "https://himg.bdimg.com\\@evil.example/sys/portrait/item/token",
      "https://user@himg.bdimg.com/sys/portrait/item/token",
      "https://user:password@himg.bdimg.com/sys/portrait/item/token",
      "https://himg.bdimg.com:443/sys/portrait/item/token",
      "https://himg.bdimg.com:0/sys/portrait/item/token",
      "https://himg.bdimg.com:65535/sys/portrait/item/token",
      "https://himg.bdimg.com:+443/sys/portrait/item/token",
      "https://himg.bdimg.com:0443/sys/portrait/item/token",
      "https://himg.bdimg.com:/sys/portrait/item/token",
      "https://himg.bdimg.com/sys/portrait/item/token?size=large",
      "https://himg.bdimg.com/sys/portrait/item/token?",
      "https://himg.bdimg.com/sys/portrait/item/token?t=",
      "https://himg.bdimg.com/sys/portrait/item/token?t=123456789012345678901",
      "https://himg.bdimg.com/sys/portrait/item/token?t=1&t=2",
      "https://himg.bdimg.com/sys/portrait/item/token?t=%31",
      "https://himg.bdimg.com/sys/portrait/item/token?t=+1",
      "https://himg.bdimg.com/sys/portrait/item/token?t=-1",
      "https://himg.bdimg.com/sys/portrait/item/token?t=1.0",
      "https://himg.bdimg.com/sys/portrait/item/token#fragment",
      "https://himg.bdimg.com/sys/portrait/item/token#",
      "ftp://himg.bdimg.com/sys/portrait/item/token",
      "https://himg.bdimg.com/sys/avatar/item/token",
      "https://himg.bdimg.com/sys/Portrait/item/token",
      "https://himg.bdimg.com/sys/portrait/itemevil/token",
      "https://himg.bdimg.com/sys/portrait/item/",
      "https://himg.bdimg.com/sys/portrait/item//token",
      "https://himg.bdimg.com/sys/portrait/item/./token",
      "https://himg.bdimg.com/sys/portrait/item/%2E/token",
      "https://himg.bdimg.com/sys/portrait/item/token/../x",
      "https://himg.bdimg.com/sys/portrait/item/token/extra",
      "https://himg.bdimg.com/sys%2Fportrait/item/token",
      "https://himg.bdimg.com/sys/portrait/item/a\\b",
      "https://himg.bdimg.com/sys/portrait/item/%C0%AF",
      "https://himg.bdimg.com/sys/portrait/item/a∕b",
      "https://himg.bdimg.com\r\n/sys/portrait/item/token",
      "//himg.bdimg.com:443/sys/portrait/item/token",
    ]

    for rawValue in invalidURLs {
      XCTAssertNil(SecureTiebaURL.largePortrait(rawValue), rawValue)
    }
  }

  func testLargePortraitRejectsRawSourceOver4096BytesBeforeTrimming() {
    let url = "https://himg.bdimg.com/sys/portrait/item/token"
    let boundedSource = String(repeating: " ", count: 4_096 - url.utf8.count) + url
    let oversizedSource = " " + boundedSource

    XCTAssertNotNil(SecureTiebaURL.largePortrait(boundedSource))
    XCTAssertNil(SecureTiebaURL.largePortrait(oversizedSource))
  }

  func testLegacyPortraitHostIsRewrittenForHTTPAndHTTPS() throws {
    for scheme in ["http", "https"] {
      let rawValue =
        "\(scheme)://tb.himg.baidu.com/sys/portrait/item/a%2Fb?next=%2F%2f&empty=#part%2F"
      let legacy = try XCTUnwrap(URL(string: rawValue))
      let normalized = try XCTUnwrap(SecureTiebaURL.media(legacy))

      XCTAssertEqual(
        normalized.absoluteString,
        "https://himg.bdimg.com/sys/portrait/item/a%2Fb?next=%2F%2f&empty=#part%2F"
      )
    }
  }

  func testMediaOnlyUpgradesKnownBaiduHosts() throws {
    let baidu = try XCTUnwrap(
      URL(string: "http://imgsrc.baidu.com/forum/a%2Fb.jpg?next=%2F%2f&empty=#part%2F")
    )
    XCTAssertEqual(
      SecureTiebaURL.media(baidu)?.absoluteString,
      "https://imgsrc.baidu.com/forum/a%2Fb.jpg?next=%2F%2f&empty=#part%2F"
    )

    let unrelated = try XCTUnwrap(URL(string: "http://example.com/pic.jpg"))
    XCTAssertNil(SecureTiebaURL.media(unrelated))
  }

  func testBaiduHTTPUpgradeMovesExplicitDefaultPortToHTTPSDefault() throws {
    let defaultPort = try XCTUnwrap(
      URL(string: "http://imgsrc.baidu.com:80/forum/a.jpg")
    )
    XCTAssertEqual(
      SecureTiebaURL.media(defaultPort)?.absoluteString,
      "https://imgsrc.baidu.com/forum/a.jpg"
    )

    let nonstandardPort = try XCTUnwrap(
      URL(string: "http://imgsrc.baidu.com:8080/forum/a.jpg")
    )
    XCTAssertEqual(
      SecureTiebaURL.media(nonstandardPort)?.absoluteString,
      "https://imgsrc.baidu.com:8080/forum/a.jpg"
    )
  }

  func testWebPreservesUnmodifiedHTTPAndHTTPSURLsVerbatim() throws {
    for rawValue in [
      "https://example.com/a%2Fb?next=%2F%2f&empty=#part%2F",
      "http://example.com/a%2Fb?next=%2F%2f&empty=#part%2F",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))

      XCTAssertEqual(SecureTiebaURL.web(url)?.absoluteString, rawValue)
    }
  }

  func testVideoPageAcceptsBoundedCredentialFreeWebURL() throws {
    let prefix = "https://example.com/watch/"
    let boundedValue = prefix + String(
      repeating: "a",
      count: SecureTiebaURL.maximumVideoPageURLBytes - prefix.utf8.count
    )
    let boundedURL = try XCTUnwrap(URL(string: boundedValue))

    XCTAssertEqual(SecureTiebaURL.videoPage(boundedURL), boundedURL)
    XCTAssertEqual(
      SecureTiebaURL.videoPage(URL(string: "http://example.com/watch/42"))?.absoluteString,
      "http://example.com/watch/42"
    )
  }

  func testVideoPageRejectsCredentialsNonWebOversizedAndControlCharacters() throws {
    let prefix = "https://example.com/watch/"
    let oversizedValue = prefix + String(
      repeating: "a",
      count: SecureTiebaURL.maximumVideoPageURLBytes - prefix.utf8.count + 1
    )
    let rejectedValues = [
      "https://user@example.com/watch/42",
      "https://user:password@example.com/watch/42",
      "javascript:alert(1)",
      "data:text/plain,secret",
      "file:///private/data",
      "https://example.com/watch/%0A",
      "https://example.com/watch/%00",
      oversizedValue,
    ]

    for rawValue in rejectedValues {
      let url = try XCTUnwrap(URL(string: rawValue), "Could not construct test URL: \(rawValue)")
      XCTAssertNil(SecureTiebaURL.videoPage(url), "Unexpectedly accepted: \(rawValue)")
    }
  }

  func testRejectsURLsContainingCredentials() throws {
    for rawValue in [
      "https://user@example.com/path",
      "https://user:password@example.com/path",
      "http://user@example.com/path",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))

      XCTAssertNil(SecureTiebaURL.media(url))
      XCTAssertNil(SecureTiebaURL.web(url))
    }
  }

  func testRejectsNonWebSchemes() throws {
    XCTAssertNil(SecureTiebaURL.media(URL(string: "file:///private/data")))
    XCTAssertNil(SecureTiebaURL.web(URL(string: "javascript:alert(1)")))
    XCTAssertNil(SecureTiebaURL.web(URL(string: "data:text/plain,secret")))
  }

  func testVoiceURLUsesStructuredQueryEncoding() throws {
    let url = try XCTUnwrap(SecureTiebaURL.voice(md5: "abc&play_from=other"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "tiebac.baidu.com")
    XCTAssertEqual(
      components.queryItems,
      [
        URLQueryItem(name: "voice_md5", value: "abc&play_from=other"),
        URLQueryItem(name: "play_from", value: "pb_voice_play"),
      ]
    )
  }
}
