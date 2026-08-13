import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ComposerTextEditorTests: XCTestCase {
  func testInsertionReplacesExactUTF16SelectionAndPlacesCaretAfterToken() throws {
    let text = "A😀中文Z"
    let selectedText = "中文"
    let selectedRange = try XCTUnwrap(text.range(of: selectedText))
    let nsRange = NSRange(selectedRange, in: text)
    let token = try XCTUnwrap(TiebaClassicEmoticonCatalog.token(for: "滑稽"))

    let result = try XCTUnwrap(
      ComposerTextInsertionPolicy.replacingSelection(
        in: text,
        selection: ComposerTextSelection(nsRange),
        with: token
      )
    )

    XCTAssertEqual(result.text, "A😀#(滑稽)Z")
    XCTAssertEqual(
      result.selection,
      ComposerTextSelection(location: nsRange.location + token.utf16.count, length: 0)
    )
    XCTAssertTrue(TextReplyContentPolicy.isValid(result.text))
  }

  func testInsertionAtCaretPreservesWhitespaceAndExistingContent() throws {
    let token = try XCTUnwrap(TiebaClassicEmoticonCatalog.token(for: "哈哈"))
    let result = try XCTUnwrap(
      ComposerTextInsertionPolicy.replacingSelection(
        in: "前  后",
        selection: ComposerTextSelection(location: 2, length: 0),
        with: token
      )
    )

    XCTAssertEqual(result.text, "前 #(哈哈) 后")
    XCTAssertEqual(result.selection.location, 2 + token.utf16.count)
  }

  func testInsertionRejectsOutOfBoundsAndSplitSurrogateSelections() {
    XCTAssertNil(
      ComposerTextInsertionPolicy.replacingSelection(
        in: "text",
        selection: ComposerTextSelection(location: -1, length: 0),
        with: "#(哈哈)"
      )
    )
    XCTAssertNil(
      ComposerTextInsertionPolicy.replacingSelection(
        in: "text",
        selection: ComposerTextSelection(location: 5, length: 0),
        with: "#(哈哈)"
      )
    )
    XCTAssertNil(
      ComposerTextInsertionPolicy.replacingSelection(
        in: "😀",
        selection: ComposerTextSelection(location: 1, length: 0),
        with: "#(哈哈)"
      )
    )
    XCTAssertNil(
      ComposerTextInsertionPolicy.replacingSelection(
        in: "😀",
        selection: ComposerTextSelection(location: 0, length: 1),
        with: "#(哈哈)"
      )
    )
  }

  func testCatalogRejectsUnknownOrNonCanonicalNamesBeforeInsertion() {
    XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: "reply, portrait, name"))
    XCTAssertNil(TiebaClassicEmoticonCatalog.token(for: "不存在"))
    XCTAssertEqual(
      Set(TiebaClassicEmoticonCatalog.names).count,
      TiebaClassicEmoticonCatalog.names.count
    )
  }
}
