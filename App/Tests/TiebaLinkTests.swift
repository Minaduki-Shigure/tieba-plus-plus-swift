import Foundation
import XCTest

@testable import TiebaPlusPlus

final class TiebaLinkTests: XCTestCase {
  func testCanonicalForumURLUsesStructuredEncodingAndRoundTrips() throws {
    let target = TiebaLinkTarget.forum(" C++ & C# 100% ")
    let url = try XCTUnwrap(TiebaLink.canonicalURL(for: target))
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "tieba.baidu.com")
    XCTAssertEqual(components.path, "/f")
    XCTAssertEqual(components.queryItems, [URLQueryItem(name: "kw", value: "C++ & C# 100%")])
    XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
    XCTAssertFalse(url.absoluteString.contains("C++"))
    XCTAssertEqual(TiebaLink.target(from: url), .forum("C++ & C# 100%"))
  }

  func testThreadShareAndCopyURLsKeepOnlySupportedState() throws {
    let shareURL = try XCTUnwrap(
      TiebaLink.canonicalURL(
        for: .thread(
          TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 99)
        )
      )
    )
    let copyURL = try XCTUnwrap(
      TiebaLink.threadCopyURL(threadID: 42, onlyThreadAuthor: true)
    )

    XCTAssertEqual(shareURL.absoluteString, "https://tieba.baidu.com/p/42")
    XCTAssertEqual(copyURL.absoluteString, "https://tieba.baidu.com/p/42?see_lz=1")
    let shareText = TiebaLink.shareText(url: shareURL, title: "A thread")
    XCTAssertEqual(
      shareText,
      "「A thread」\nhttps://tieba.baidu.com/p/42\n（分享自贴吧++）"
    )
    XCTAssertEqual(
      TiebaLink.target(fromPastedText: shareText),
      .thread(TiebaThreadRoute(threadID: 42))
    )
    XCTAssertEqual(
      TiebaLink.target(from: copyURL),
      .thread(TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true))
    )
    XCTAssertNil(
      TiebaLink.canonicalURL(for: .thread(TiebaThreadRoute(threadID: 0)))
    )
    XCTAssertNil(TiebaThreadRoute(threadID: 42).placeholderThread.authorAvatarURL)
    XCTAssertNil(TiebaLink.canonicalURL(for: .user(7)))
  }

  func testOfficialHTTPSParserPreservesThreadAuthorAndPostAnchor() throws {
    let threadURL = try XCTUnwrap(
      URL(string: "https://tieba.baidu.com/p/42?see_lz=1&pid=99&from=share")
    )
    let forumURL = try XCTUnwrap(
      URL(string: "https://tieba.baidu.com/f?kw=Swift%20%E8%AF%AD%E8%A8%80&fr=share")
    )

    XCTAssertEqual(
      TiebaLink.target(from: threadURL),
      .thread(
        TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 99)
      )
    )
    XCTAssertEqual(TiebaLink.target(from: forumURL), .forum("Swift 语言"))
    XCTAssertEqual(
      TiebaLink.target(from: "  http://tieba.baidu.com:80/p/7?post_id=8  "),
      .thread(TiebaThreadRoute(threadID: 7, postID: 8))
    )
  }

  func testOfficialThreadURLAcceptsInertHashSlashFragment() throws {
    let rawURL = "https://tieba.baidu.com/p/10957526376?see_lz=0#/"
    let expected = TiebaLinkTarget.thread(
      TiebaThreadRoute(threadID: 10_957_526_376, onlyThreadAuthor: false)
    )

    XCTAssertEqual(TiebaLink.target(from: rawURL), expected)
    XCTAssertEqual(TiebaLink.target(fromPastedText: rawURL), expected)
  }

  func testOfficialClientSchemeCanBePastedButUsesTheSameStrictTargets() throws {
    let forumURL = try XCTUnwrap(
      URL(string: "com.baidu.tieba://unidispatch/frs?kw=swift&source=official")
    )
    let threadURL = try XCTUnwrap(
      URL(
        string: "com.baidu.tieba://unidispatch/pb?tid=42&see_lz=1&hightlight_anchor_pid=99"
      )
    )

    XCTAssertEqual(TiebaLink.target(from: forumURL), .forum("swift"))
    XCTAssertEqual(
      TiebaLink.target(from: threadURL),
      .thread(
        TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 99)
      )
    )
  }

  func testAppSchemeRoundTripsForumThreadAndUserRoutes() throws {
    let targets: [TiebaLinkTarget] = [
      .forum("Swift #1"),
      .thread(TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 99)),
      .user(7),
    ]

    for target in targets {
      let url = try XCTUnwrap(TiebaLink.appURL(for: target))
      XCTAssertEqual(TiebaLink.target(from: url), target)
    }
  }

  func testForumNamesAreBoundedAndCannotBecomePathComponents() throws {
    XCTAssertNotNil(TiebaLink.canonicalURL(for: .forum(String(repeating: "a", count: 100))))
    XCTAssertNil(TiebaLink.canonicalURL(for: .forum(String(repeating: "a", count: 101))))
    XCTAssertNil(TiebaLink.canonicalURL(for: .forum("one/two")))
    XCTAssertNil(TiebaLink.canonicalURL(for: .forum("one\\two")))
    XCTAssertNil(TiebaLink.canonicalURL(for: .forum("one\u{0000}two")))
    XCTAssertNil(
      TiebaLink.target(
        from: try XCTUnwrap(URL(string: "https://tieba.baidu.com/f?kw=one%2Ftwo"))
      )
    )
  }

  func testParserRejectsAmbiguousAndHostileURLs() throws {
    let invalidURLs = [
      "https://tieba.baidu.com.evil.example/f?kw=swift",
      "https://reader@tieba.baidu.com/f?kw=swift",
      "https://tieba.baidu.com:444/f?kw=swift",
      "ftp://tieba.baidu.com/f?kw=swift",
      "https://tieba.baidu.com/f",
      "https://tieba.baidu.com/f?kw=",
      "https://tieba.baidu.com/f?kw",
      "https://tieba.baidu.com/f?kw=one&kw=two",
      "https://tieba.baidu.com/f?kw=swift&kw",
      "https://tieba.baidu.com/f/?kw=swift",
      "https://tieba.baidu.com/f?kw=swift#/",
      "https://tieba.baidu.com/p/0",
      "https://tieba.baidu.com/p/-1",
      "https://tieba.baidu.com/p/9223372036854775808",
      "https://tieba.baidu.com/p//42",
      "https://tieba.baidu.com/p/42/",
      "https://tieba.baidu.com/p/42/extra",
      "https://tieba.baidu.com/p/42#99",
      "https://tieba.baidu.com/p/42#/thread",
      "https://tieba.baidu.com/p/42#//evil",
      "https://tieba.baidu.com/p/42?see_lz=2",
      "https://tieba.baidu.com/p/42?see_lz",
      "https://tieba.baidu.com/p/42?see_lz=0&see_lz=1",
      "https://tieba.baidu.com/p/42?pid=0",
      "https://tieba.baidu.com/p/42?pid",
      "https://tieba.baidu.com/p/42?pid=7&post_id=8",
      "tieba-plus-plus://thread/42?unknown=1",
      "tieba-plus-plus://thread/42?",
      "tieba-plus-plus://thread/42?see_lz",
      "tieba-plus-plus://thread/42?pid",
      "tieba-plus-plus://thread:8080/42",
      "tieba-plus-plus://reader@thread/42",
      "tieba-plus-plus://thread//42",
      "tieba-plus-plus://thread/42/",
      "tieba-plus-plus://thread/42/extra",
      "tieba-plus-plus://thread/42#/",
      "tieba-plus-plus://forum/",
      "tieba-plus-plus://user/-1",
      "tieba-plus-plus://user/7/",
      "com.baidu.tieba://unidispatch/unknown?tid=42",
      "com.baidu.tieba://unidispatch/frs?kw",
      "com.baidu.tieba://unidispatch/frs?kw=swift&kw",
      "com.baidu.tieba://unidispatch/pb?tid=0",
      "com.baidu.tieba://unidispatch/pb?tid",
      "com.baidu.tieba://unidispatch/pb?tid=42&tid",
      "com.baidu.tieba://unidispatch/pb?tid=42#/",
    ]

    for rawURL in invalidURLs {
      XCTAssertNil(
        TiebaLink.target(from: try XCTUnwrap(URL(string: rawURL))),
        rawURL
      )
    }

    XCTAssertNil(
      TiebaLink.target(
        fromPastedText: "https://tieba.baidu.com/p/1\nhttps://tieba.baidu.com/p/2"
      )
    )
  }
}
