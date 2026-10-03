import Foundation
import XCTest

@testable import TiebaCore

final class TiebaClassicEmoticonCatalogTests: XCTestCase {
  func testEveryCompiledEntryHasUniqueIdentityAndExactAcceptedWireToken() {
    let entries = TiebaClassicEmoticonCatalog.entries
    XCTAssertEqual(entries.count, 126)
    XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    XCTAssertEqual(entries.map(\.name), TiebaClassicEmoticonCatalog.names)
    for entry in entries {
      XCTAssertEqual(entry.id, entry.name)
      let token = "#(\(entry.name))"
      XCTAssertEqual(TiebaClassicEmoticonCatalog.token(for: entry.name), token)
      XCTAssertTrue(TiebaTextReplyContentPolicy.isValid("前\(token)后"), entry.name)
      XCTAssertTrue(TiebaNewThreadContentPolicy.isValidContent(token), entry.name)
      if let url = entry.thumbnailURL {
        XCTAssertTrue(TiebaClassicEmoticonCatalog.allowsThumbnailURL(url), entry.name)
      }
    }
  }

  func testNewNamesCoverLegacyExtrasAndCurrentOfficialClientExamples() {
    for name in ["沙发", "手纸", "三道杠", "吃瓜", "捂嘴笑", "干饭", "奥特曼", "鼠2"] {
      XCTAssertNotNil(TiebaClassicEmoticonCatalog.token(for: name), name)
      XCTAssertNotNil(TiebaClassicEmoticonCatalog.entries.first { $0.name == name }?.thumbnailURL)
    }
  }

  func testConflictingHistoricalNamesDoNotRewriteSavedDraftMeaning() throws {
    let angry = try XCTUnwrap(TiebaClassicEmoticonCatalog.entries.first { $0.name == "生气" })
    let humph = try XCTUnwrap(TiebaClassicEmoticonCatalog.entries.first { $0.name == "哼" })
    XCTAssertNil(angry.thumbnailURL)
    XCTAssertEqual(humph.thumbnailURL?.lastPathComponent, "image_emoticon31@2x.png")
    XCTAssertEqual(TiebaClassicEmoticonCatalog.token(for: angry.name), "#(生气)")
    XCTAssertEqual(TiebaClassicEmoticonCatalog.token(for: humph.name), "#(哼)")
    XCTAssertNotEqual(
      TiebaClassicEmoticonTokenizer.submissionProofTokens(in: "#(生气)"),
      TiebaClassicEmoticonTokenizer.submissionProofTokens(in: "#(哼)")
    )
    XCTAssertEqual(TiebaClassicEmoticonCatalog.token(for: "小姐姐来啦"), "#(小姐姐来啦)")
    XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: "小姐姐来拉"))
    XCTAssertFalse(TiebaTextReplyContentPolicy.isValid("#(小姐姐来拉)"))
  }

  func testDuplicateOfficialNameUsesOneEntryAndKnownAssetSpelling() throws {
    let melon = TiebaClassicEmoticonCatalog.entries.filter { $0.name == "吃瓜" }
    XCTAssertEqual(melon.count, 1)
    XCTAssertEqual(melon.first?.thumbnailURL?.lastPathComponent, "image_emoticon86@2x.png")
    XCTAssertEqual(
      TiebaClassicEmoticonCatalog.entries.first?.thumbnailURL?.absoluteString,
      "https://tb3.bdstatic.com/emoji/image_emoticon@2x.png"
    )
    XCTAssertFalse(
      TiebaClassicEmoticonCatalog.allowsThumbnailURL(
        try XCTUnwrap(URL(string: "https://tb3.bdstatic.com/emoji/image_emoticon1@2x.png"))
      )
    )
  }

  func testSearchTrimsWhitespaceMatchesNamesAndTokensWithoutChangingCatalog() {
    XCTAssertEqual(
      TiebaClassicEmoticonCatalog.entries(matching: " \n\t"), TiebaClassicEmoticonCatalog.entries)
    XCTAssertEqual(TiebaClassicEmoticonCatalog.entries(matching: " #（吃瓜） "), [])
    XCTAssertEqual(TiebaClassicEmoticonCatalog.entries(matching: " #(吃瓜) \n").map(\.name), ["吃瓜"])
    XCTAssertEqual(TiebaClassicEmoticonCatalog.entries(matching: "wHaT").map(\.name), ["what"])
    XCTAssertEqual(TiebaClassicEmoticonCatalog.entries(matching: "oK").map(\.name), ["OK"])
    XCTAssertEqual(
      TiebaClassicEmoticonCatalog.entries(matching: "小姐姐").map(\.name),
      ["小姐姐别走", "小姐姐在吗", "小姐姐来啦", "小姐姐来玩呀"]
    )
    XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: "oK"))
    XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: " 吃瓜 "))
    XCTAssertEqual(TiebaClassicEmoticonCatalog.entries(matching: "不存在的表情"), [])
  }

  func testUntrustedNamesAndURLVariantsCannotCreateCatalogArtworkRequests() throws {
    let invalidNames = [
      "不存在", "image_emoticon25", "../image_emoticon25", "#(滑稽)",
      "滑稽/../../secret", "https://example.com/emoji", "滑稽\u{0000}",
    ]
    for name in invalidNames {
      XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: name), name)
      XCTAssertFalse(TiebaClassicEmoticonCatalog.entries.contains { $0.name == name }, name)
    }
    let path = "/emoji/image_emoticon25@2x.png"
    for candidate in [
      "http://tb3.bdstatic.com\(path)",
      "https://example.com\(path)",
      "https://tb3.bdstatic.com.evil.invalid\(path)",
      "https://tb3.bdstatic.com@evil.invalid\(path)",
      "https://user@tb3.bdstatic.com\(path)",
      "https://user:password@tb3.bdstatic.com\(path)",
      "https://tb3.bdstatic.com:443\(path)",
      "https://tb3.bdstatic.com\(path)?token=private",
      "https://tb3.bdstatic.com\(path)#fragment",
      "https://tb3.bdstatic.com/emoji/../private.png",
      "https://tb3.bdstatic.com/emoji/image_emoticon999999@2x.png",
      "https://tb3.bdstatic.com/emoji/image_emoticon61@2x.png",
      "https://tb3.bdstatic.com/emoji/image_editoricon115@2x.png",
    ] {
      XCTAssertFalse(
        TiebaClassicEmoticonCatalog.allowsThumbnailURL(try XCTUnwrap(URL(string: candidate))),
        candidate
      )
    }
  }
}
