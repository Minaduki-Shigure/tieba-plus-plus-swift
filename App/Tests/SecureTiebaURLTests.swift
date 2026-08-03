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

  func testWebPreservesUnmodifiedHTTPAndHTTPSURLsVerbatim() throws {
    for rawValue in [
      "https://example.com/a%2Fb?next=%2F%2f&empty=#part%2F",
      "http://example.com/a%2Fb?next=%2F%2f&empty=#part%2F",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))

      XCTAssertEqual(SecureTiebaURL.web(url)?.absoluteString, rawValue)
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
