import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

final class TiebaType35ContentTests: XCTestCase {
  func testTextOnlyType35SurvivesThreadPostAndNestedReplyMappingExactly() throws {
    var content = PbContent()
    content.type = 35
    content.text = "正文第一行\n保留表情 #(笑眼)、空格和末尾文本。 "
    XCTAssertFalse(content.hasTiebaplusInfo)
    for mapped in try mapEveryEntryPoint(content) {
      XCTAssertEqual(mapped.fragments, [.text(content.text)])
      XCTAssertEqual(mapped.plainText, content.text)
    }
  }

  func testExplicitCompleteType35CardKeepsDescriptionAndValidatedURL() throws {
    for rawURL in [
      "https://tieba.baidu.com/p/123?see_lz=0", "http://example.com/card", "//example.com/card",
    ] {
      var content = PbContent()
      content.type = 35
      content.text = "legacy text should not replace a complete card"
      content.tiebaplusInfo.desc = "贴吧组件说明"
      content.tiebaplusInfo.jumpURL = rawURL
      let expectedURL = URL(string: rawURL.hasPrefix("//") ? "https:\(rawURL)" : rawURL)
      XCTAssertTrue(content.hasTiebaplusInfo)
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(mapped.fragments, [.tiebaPlus(description: "贴吧组件说明", url: expectedURL)])
      }
    }
  }

  func testIncompleteCardFallsBackToOriginalTextWithoutUsingDescriptionOrGuessingLinks() throws {
    for (description, jumpURL) in [
      ("", ""), ("", "https://example.com/card"),
      (" \n\t", "https://example.com/card"),
    ] {
      var content = PbContent()
      content.type = 35
      content.text = "https://example.com/plain-text-is-not-a-card"
      content.tiebaplusInfo.desc = description
      content.tiebaplusInfo.jumpURL = jumpURL
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(mapped.fragments, [.text(content.text)])
      }
    }
  }

  func testUnsafeOrMissingCardURLPreservesDescriptionWithoutNavigation() throws {
    let invalid = [
      "", "javascript:alert(1)", "file:///tmp/private", "data:text/html,hello",
      "tieba://thread/123",
      "https:", "/relative", "//", "https://user:password@example.com/card",
      "https://user@example.com/card", "https://example.com/\ncard",
      "https://example.com/" + String(repeating: "x", count: 8_193),
    ]
    for jumpURL in invalid {
      var content = PbContent()
      content.type = 35
      content.text = "原始正文"
      content.tiebaplusInfo.desc = "保留不可点击的卡片说明"
      content.tiebaplusInfo.jumpURL = jumpURL
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(
          mapped.fragments, [.tiebaPlus(description: content.tiebaplusInfo.desc, url: nil)],
          jumpURL)
      }
      content.text = ""
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(mapped.plainText, content.tiebaplusInfo.desc)
      }
      content.tiebaplusInfo.desc = ""
      content.text = "有无效链接但无说明时保留正文"
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(mapped.fragments, [.text(content.text)])
      }
    }
  }

  func testEmptyType35StaysEmptyTextAndAdjacentFragmentsKeepOrder() throws {
    var empty = PbContent()
    empty.type = 35
    empty.tiebaplusInfo.desc = ""
    for mapped in try mapEveryEntryPoint(empty) {
      XCTAssertEqual(mapped.fragments, [.text("")])
      XCTAssertEqual(mapped.plainText, "")
    }

    var fixture = ProtoFixtures.postPage().data
    var first = PbContent()
    first.type = 0
    first.text = "before "
    var middle = PbContent()
    middle.type = 35
    middle.text = "kept body"
    var last = PbContent()
    last.type = 0
    last.text = " after"
    fixture.postList[0].content = [first, middle, last]
    let mapped = try XCTUnwrap(TiebaProtoMapper.postPage(fixture).posts.first?.content)
    XCTAssertEqual(mapped.fragments, [.text(first.text), .text(middle.text), .text(last.text)])
    XCTAssertEqual(mapped.plainText, "before kept body after")
  }

  func testOtherTiebaPlusTypesKeepExistingCardSemantics() throws {
    for type: UInt32 in [36, 37] {
      var content = PbContent()
      content.type = type
      content.text = "unrelated legacy field"
      content.tiebaplusInfo.desc = "existing card"
      content.tiebaplusInfo.jumpURL = "https://example.com/card"
      for mapped in try mapEveryEntryPoint(content) {
        XCTAssertEqual(
          mapped.fragments,
          [.tiebaPlus(description: "existing card", url: URL(string: "https://example.com/card"))])
      }
    }
  }

  private func mapEveryEntryPoint(_ content: PbContent) throws -> [TiebaContent] {
    var thread = ProtoFixtures.threadPage().data
    thread.threadList[0].firstPostContent = [content]
    var post = ProtoFixtures.postPage().data
    post.postList[0].content = [content]
    var comment = ProtoFixtures.commentPage().data
    comment.subpostList[0].content = [content]
    return [
      try XCTUnwrap(TiebaProtoMapper.threadPage(thread).threads.first?.content),
      try XCTUnwrap(TiebaProtoMapper.postPage(post).posts.first?.content),
      try XCTUnwrap(TiebaProtoMapper.commentPage(comment).comments.first?.content),
    ]
  }
}
