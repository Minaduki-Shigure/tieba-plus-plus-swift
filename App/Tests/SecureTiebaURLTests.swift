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

  func testLegacyPortraitHostIsRewrittenForHTTPAndHTTPS() throws {
    for scheme in ["http", "https"] {
      let legacy = try XCTUnwrap(
        URL(string: "\(scheme)://tb.himg.baidu.com/sys/portrait/item/token"))
      let normalized = try XCTUnwrap(SecureTiebaURL.media(legacy))

      XCTAssertEqual(normalized.scheme, "https")
      XCTAssertEqual(normalized.host, "himg.bdimg.com")
    }
  }

  func testMediaOnlyUpgradesKnownBaiduHosts() throws {
    let baidu = try XCTUnwrap(URL(string: "http://imgsrc.baidu.com/forum/pic.jpg"))
    XCTAssertEqual(SecureTiebaURL.media(baidu)?.scheme, "https")

    let unrelated = try XCTUnwrap(URL(string: "http://example.com/pic.jpg"))
    XCTAssertNil(SecureTiebaURL.media(unrelated))
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
