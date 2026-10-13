import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ComposerEmoticonSpansTests: XCTestCase {
  func testEveryCatalogImageKeepsItsExactSourceRangeAndToken() throws {
    let entries = TiebaClassicEmoticonCatalog.entries
    let source = "前😀" + entries.map { "#(\($0.name))" }.joined(separator: "\r\n") + "e\u{301} 后"
    let plan = ComposerEmoticonSpans(source: source)
    XCTAssertTrue(plan.source.utf8.elementsEqual(source.utf8))
    XCTAssertEqual(plan.spans.count, entries.filter { $0.thumbnailURL != nil }.count)
    for span in plan.spans {
      let range = try XCTUnwrap(Range(span.range, in: source))
      XCTAssertEqual(String(source[range]), span.token)
      XCTAssertEqual(span.token, TiebaClassicEmoticonCatalog.token(for: span.name))
      XCTAssertTrue(TiebaClassicEmoticonCatalog.allowsThumbnailURL(span.thumbnailURL))
      XCTAssertEqual(plan.span(containingUTF16Offset: span.range.location), span)
      XCTAssertEqual(plan.span(containingUTF16Offset: NSMaxRange(span.range) - 1), span)
      XCTAssertNil(plan.span(containingUTF16Offset: NSMaxRange(span.range)))
    }
  }

  func testIncompleteAndUnknownMarkersDoNotSwallowValidInnerOrFollowingTokens() {
    let source = "#(未知 #(滑稽)) #(生气) #(哈哈) #(haHa) #(\n哈哈) #("
    let plan = ComposerEmoticonSpans(source: source)
    XCTAssertEqual(plan.spans.map(\.token), ["#(滑稽)", "#(哈哈)"])
    XCTAssertTrue(plan.source.utf8.elementsEqual(source.utf8))
    XCTAssertNil(plan.span(containingUTF16Offset: -1))
    XCTAssertNil(plan.span(containingUTF16Offset: source.utf16.count))
  }

  func testMarkedTextStaysLiteralWithoutHidingOtherFaces() throws {
    let source = "#(滑稽)中文#(哈哈)#(吃瓜)"
    let middle = try XCTUnwrap(source.range(of: "#(哈哈)"))
    let marked = NSRange(middle, in: source)
    XCTAssertEqual(
      ComposerEmoticonSpans(source: source, excluding: marked).spans.map(\.token),
      ["#(滑稽)", "#(吃瓜)"])
    XCTAssertEqual(ComposerEmoticonSpans(source: source).spans.count, 3)
    XCTAssertEqual(
      ComposerEmoticonSpans(
        source: source, excluding: NSRange(location: marked.location + 2, length: 1)
      ).spans.count, 2)
  }

  func testSelectionAndSingleBackspaceExpandWholeTokensInOriginalUTF16Space() throws {
    let source = "A😀#(滑稽)中#(哈哈)Z"
    let plan = ComposerEmoticonSpans(source: source)
    XCTAssertEqual(
      plan.spans.map(\.range), [NSRange(location: 3, length: 5), NSRange(location: 9, length: 5)])
    XCTAssertEqual(plan.selection(NSRange(location: 7, length: 1)), NSRange(location: 3, length: 5))
    XCTAssertEqual(
      plan.selection(NSRange(location: 5, length: 6)), NSRange(location: 3, length: 11))
    XCTAssertEqual(plan.selection(NSRange(location: 8, length: 1)), NSRange(location: 8, length: 1))
    XCTAssertEqual(plan.selection(NSRange(location: 3, length: 0)), NSRange(location: 3, length: 0))
    XCTAssertEqual(plan.selection(NSRange(location: 8, length: 0)), NSRange(location: 8, length: 0))
    XCTAssertEqual(
      plan.selection(NSRange(location: 7, length: 0), movingFrom: NSRange(location: 8, length: 0)),
      NSRange(location: 3, length: 0))
    XCTAssertEqual(
      plan.selection(NSRange(location: 4, length: 0), movingFrom: NSRange(location: 3, length: 0)),
      NSRange(location: 8, length: 0))
    let deleting = try XCTUnwrap(plan.selection(NSRange(location: 7, length: 1)))
    let result = source.replacingCharacters(
      in: try XCTUnwrap(Range(deleting, in: source)), with: "")
    XCTAssertEqual(result, "A😀中#(哈哈)Z")
  }

  func testInvalidAndSplitComposedCharacterSelectionsAreRejected() {
    let plan = ComposerEmoticonSpans(source: "😀e\u{301}#(滑稽)")
    for range in [
      NSRange(location: -1, length: 0), NSRange(location: 1, length: 0),
      NSRange(location: 2, length: 1), NSRange(location: 0, length: Int.max),
      NSRange(location: Int.max, length: 1),
    ] {
      XCTAssertNil(plan.selection(range))
    }
  }

  func testLongUnfinishedDraftKeepsContentAndRecognizesTheFinalToken() {
    let source = String(repeating: "#(未完成", count: 4_000) + "#(滑稽)"
    let plan = ComposerEmoticonSpans(source: source)
    XCTAssertEqual(plan.spans.map(\.token), ["#(滑稽)"])
    XCTAssertTrue(plan.source.utf8.elementsEqual(source.utf8))
  }

  func testCombiningSuffixKeepsTokenLiteralAndNeverCreatesInvalidSelection() {
    for suffix in ["\u{301}", "\u{fe0f}", "\u{20e3}"] {
      let source = "#(滑稽)" + suffix + "后#(哈哈)"
      let plan = ComposerEmoticonSpans(source: source)
      XCTAssertEqual(plan.spans.map(\.token), ["#(哈哈)"])
      XCTAssertEqual(
        plan.selection(NSRange(location: 2, length: 1)), NSRange(location: 2, length: 1))
      XCTAssertEqual(
        plan.selection(NSRange(location: 3, length: 0)), NSRange(location: 3, length: 0))
      for span in plan.spans {
        XCTAssertTrue(ComposerTextSelection(span.range).isValid(for: source))
      }
    }
  }

  func testEmptyInteriorMarkExcludesTokenAndMalformedMarksKeepSourceLiteral() {
    let source = "#(滑稽)#(哈哈)"
    XCTAssertEqual(
      ComposerEmoticonSpans(source: source, excluding: NSRange(location: 3, length: 0))
        .spans.map(\.token), ["#(哈哈)"])
    for range in [
      NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
      NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max),
    ] {
      let plan = ComposerEmoticonSpans(source: source, excluding: range)
      XCTAssertTrue(plan.spans.isEmpty)
      XCTAssertEqual(plan.source, source)
    }
  }
}
