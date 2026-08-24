import Foundation
import XCTest

@testable import TiebaPlusPlus

final class TiebaAppLinkTests: XCTestCase {
  func testCanonicalRoutesRoundTripExactly() throws {
    let cases: [(route: TiebaAppRoute, value: String)] = [
      (.search, "tieba-plus-plus://search"),
      (.history, "tieba-plus-plus://history"),
      (.cloudFavorites, "tieba-plus-plus://favorite"),
      (.notifications(.replies), "tieba-plus-plus://notifications/0"),
      (.notifications(.mentions), "tieba-plus-plus://notifications/1"),
    ]

    for testCase in cases {
      let url = try XCTUnwrap(TiebaAppLink.appURL(for: testCase.route))
      XCTAssertEqual(url.absoluteString, testCase.value)
      XCTAssertEqual(TiebaAppLink.route(from: url), testCase.route)
    }
  }

  func testOnlyCanonicalAppRoutesAreAccepted() {
    let rejectedValues = [
      "https://search",
      "TIEBA-PLUS-PLUS://search",
      "tieba-plus-plus:search",
      "tieba-plus-plus:///search",
      "tieba-plus-plus://SEARCH",
      "tieba-plus-plus://%73earch",
      "tieba-plus-plus://search/",
      "tieba-plus-plus://search//",
      "tieba-plus-plus://search/extra",
      "tieba-plus-plus://search?",
      "tieba-plus-plus://search?query=swift",
      "tieba-plus-plus://search#",
      "tieba-plus-plus://search#section",
      "tieba-plus-plus://@search",
      "tieba-plus-plus://user@search",
      "tieba-plus-plus://user:password@search",
      "tieba-plus-plus://search:",
      "tieba-plus-plus://search:443",
      "tieba-plus-plus://search/%2E",
      "tieba-plus-plus://search/%2F",
      "tieba-plus-plus://favorite/",
      "tieba-plus-plus://favorites",
      "tieba-plus-plus://notifications",
      "tieba-plus-plus://notifications/",
      "tieba-plus-plus://notifications/00",
      "tieba-plus-plus://notifications/01",
      "tieba-plus-plus://notifications/2",
      "tieba-plus-plus://notifications/-1",
      "tieba-plus-plus://notifications/replies",
      "tieba-plus-plus://notifications/mentions",
      "tieba-plus-plus://notifications/%30",
      "tieba-plus-plus://notifications/%2E",
      "tieba-plus-plus://notifications/0/",
      "tieba-plus-plus://notifications//0",
      "tieba-plus-plus://notifications/0/extra",
      "tieba-plus-plus://notifications/0?source=shortcut",
      "tieba-plus-plus://notifications/0#inbox",
      "tieba-plus-plus://forum/swift",
      "tieba-plus-plus://thread/42",
      "tieba-plus-plus://user/7",
    ]

    for value in rejectedValues {
      XCTAssertNil(
        URL(string: value).flatMap(TiebaAppLink.route(from:)),
        value
      )
    }
  }

  func testAppOnlyRoutesNeverBecomeContentOrClipboardTargets() throws {
    let routes: [TiebaAppRoute] = [
      .search,
      .history,
      .cloudFavorites,
      .notifications(.replies),
      .notifications(.mentions),
    ]

    for route in routes {
      let url = try XCTUnwrap(TiebaAppLink.appURL(for: route))
      XCTAssertNil(TiebaLink.target(from: url))
      XCTAssertNil(TiebaLink.target(fromPastedText: url.absoluteString))
    }
  }
}
