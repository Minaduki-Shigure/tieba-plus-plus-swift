import UIKit
import XCTest

@testable import ComposerGlyphProbe

final class ComposerGlyphProbeTests: XCTestCase {
  @MainActor
  private func mount(_ source: String, width: CGFloat = 366) -> (UIWindow, SourceGlyphTextView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    window.rootViewController = controller
    let textView = SourceGlyphTextView(
      frame: CGRect(x: 12, y: 100, width: width, height: 500), source: source)
    controller.view.addSubview(textView)
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    textView.layoutIfNeeded()
    textView.layoutManager.ensureLayout(for: textView.textContainer)
    return (window, textView)
  }

  @MainActor
  private func caret(_ view: UITextView, _ offset: Int) throws -> CGRect {
    let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: offset))
    return view.caretRect(for: position)
  }

  @MainActor
  private func assertValidSource(
    _ view: UITextView, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(view.textStorage.string, view.text, file: file, line: line)
    XCTAssertFalse(view.text.contains("\u{fffc}"), file: file, line: line)
    XCTAssertNotEqual(view.selectedRange.location, NSNotFound, file: file, line: line)
    XCTAssertLessThanOrEqual(
      NSMaxRange(view.selectedRange), view.text.utf16.count, file: file, line: line)
  }

  @MainActor
  private func capture(
    _ name: String, view: SourceGlyphTextView, window: UIWindow, values: [String: Any]
  ) throws {
    view.layoutManager.ensureLayout(for: view.textContainer)
    window.layoutIfNeeded()
    let png = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let screenshot = XCTAttachment(image: png)
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    var record = values
    record["source"] = view.textStorage.string
    record["sourceUTF16Count"] = view.textStorage.length
    record["glyphCount"] = view.layoutManager.numberOfGlyphs
    record["selection"] = [view.selectedRange.location, view.selectedRange.length]
    record["generationCalls"] = view.sourceLayout.generationCalls
    record["controlBoxCalls"] = view.sourceLayout.controlBoxCalls
    let json = try JSONSerialization.data(
      withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
    let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
    attachment.name = name + ".json"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("COMPOSER_GLYPH_PROBE \(name) \(String(decoding: json, as: UTF8.self))")
  }

  @MainActor
  func testTokenWidthAndFollowingCaretPreserveSource() throws {
    let source = "甲#(滑稽)乙"
    let (window, view) = mount(source)
    defer { window.isHidden = true }
    let token = (source as NSString).range(of: "#(滑稽)")
    let before = try caret(view, token.location)
    let after = try caret(view, NSMaxRange(token))
    try capture(
      "single-token-metrics", view: view, window: window,
      values: [
        "beforeCaret": NSCoder.string(for: before), "afterCaret": NSCoder.string(for: after),
        "advance": after.minX - before.minX,
      ])
    XCTAssertEqual(view.text, source)
    XCTAssertEqual(before.minY, after.minY, accuracy: 0.5)
    XCTAssertEqual(after.minX - before.minX, view.sourceLayout.tokenWidth, accuracy: 0.5)
    XCTAssertGreaterThan(view.sourceLayout.controlBoxCalls, 0)
    let firstGlyph = view.layoutManager.glyphIndexForCharacter(at: token.location)
    XCTAssertTrue(view.layoutManager.propertyForGlyph(at: firstGlyph).contains(.controlCharacter))
    for offset in (token.location + 1)..<NSMaxRange(token) {
      let glyph = view.layoutManager.glyphIndexForCharacter(at: offset)
      XCTAssertTrue(view.layoutManager.propertyForGlyph(at: glyph).contains(.null))
    }
    assertValidSource(view)
  }

  @MainActor
  func testChineseEmojiAndMultipleTokensWrapWithBoundedGlyphs() throws {
    let source = "中文🙂#(滑稽)后文ABC#(哈哈)最后一段。\n第二行👨‍👩‍👧‍👦#(滑稽)结束。"
    let (window, view) = mount(source, width: 186)
    defer { window.isHidden = true }
    var lines: Set<Int> = []
    var boxes: [String] = []
    view.layoutManager.enumerateLineFragments(
      forGlyphRange: NSRange(
        location: 0, length: view.layoutManager.numberOfGlyphs)
    ) { rect, used, _, _, _ in
      lines.insert(Int(rect.minY.rounded()))
      boxes.append(NSCoder.string(for: used))
      XCTAssertLessThanOrEqual(used.maxX, view.textContainer.size.width + 0.5)
    }
    XCTAssertGreaterThan(lines.count, 2)
    XCTAssertEqual(view.sourceLayout.tokenRanges.count, 3)
    for token in view.sourceLayout.tokenRanges {
      let before = try caret(view, token.location)
      let after = try caret(view, NSMaxRange(token))
      XCTAssertEqual(before.minY, after.minY, accuracy: 0.5, "A token split across lines")
      XCTAssertEqual(after.minX - before.minX, view.sourceLayout.tokenWidth, accuracy: 0.5)
    }
    XCTAssertEqual(view.text, source)
    assertValidSource(view)
    try capture("mixed-script-wrap", view: view, window: window, values: ["lineBoxes": boxes])
  }

  @MainActor
  func testSelectionAndNativeCopyReturnCanonicalToken() throws {
    let source = "前#(滑稽)后🙂"
    let (window, view) = mount(source)
    defer { window.isHidden = true }
    XCTAssertTrue(view.becomeFirstResponder())
    let token = (source as NSString).range(of: "#(滑稽)")
    view.selectedRange = token
    XCTAssertEqual(view.text(in: try XCTUnwrap(view.selectedTextRange)), "#(滑稽)")
    view.copy(nil)
    XCTAssertEqual(UIPasteboard.general.string, "#(滑稽)")
    assertValidSource(view)
    try capture(
      "native-copy-selection", view: view, window: window,
      values: [
        "copiedText": UIPasteboard.general.string ?? ""
      ])
  }

  @MainActor
  func testTokenAtLineBoundaryRetainsItsAdvance() throws {
    for (index, source) in ["甲乙丙丁#(滑稽)后", "甲乙丙#(哈哈)\n后", "#(滑稽)#(哈哈)后"].enumerated() {
      let (window, view) = mount(source, width: 120)
      defer { window.isHidden = true }
      var metrics: [[String: String]] = []
      for token in view.sourceLayout.tokenRanges {
        let before = try caret(view, token.location)
        let after = try caret(view, NSMaxRange(token))
        let glyph = view.layoutManager.glyphIndexForCharacter(at: token.location)
        let rect = view.layoutManager.boundingRect(
          forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer)
        metrics.append([
          "before": NSCoder.string(for: before), "after": NSCoder.string(for: after),
          "glyphBounds": NSCoder.string(for: rect),
        ])
        XCTAssertEqual(rect.width, view.sourceLayout.tokenWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(rect.maxX, view.textContainer.size.width + 0.5)
        if abs(before.minY - after.minY) < 0.5 {
          XCTAssertEqual(after.minX - before.minX, view.sourceLayout.tokenWidth, accuracy: 0.5)
        }
      }
      XCTAssertEqual(view.text, source)
      assertValidSource(view)
      try capture(
        "line-boundary-\(index)", view: view, window: window, values: ["metrics": metrics])
    }
  }

  @MainActor
  func testNativeInsertDeleteUndoRedoRecordActualTokenGranularity() throws {
    let initial = "前后"
    let (window, view) = mount(initial)
    defer { window.isHidden = true }
    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = NSRange(location: 1, length: 0)
    let undo = try XCTUnwrap(view.undoManager)
    undo.removeAllActions()
    undo.beginUndoGrouping()
    view.insertText("#(滑稽)")
    undo.endUndoGrouping()
    XCTAssertEqual(view.text, "前#(滑稽)后")
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertEqual(view.text, initial)
    XCTAssertTrue(undo.canRedo)
    undo.redo()
    XCTAssertEqual(view.text, "前#(滑稽)后")
    view.selectedRange = NSRange(location: 6, length: 0)
    undo.removeAllActions()
    undo.beginUndoGrouping()
    view.deleteBackward()
    undo.endUndoGrouping()
    let afterDelete = view.text ?? ""
    XCTAssertNotEqual(afterDelete, "前#(滑稽)后", "Native deletion must perform a real edit")
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertEqual(view.text, "前#(滑稽)后")
    view.layoutManager.ensureLayout(for: view.textContainer)
    let restoredBefore = try caret(view, 1)
    let restoredAfter = try caret(view, 6)
    XCTAssertEqual(
      restoredAfter.minX - restoredBefore.minX, view.sourceLayout.tokenWidth, accuracy: 0.5)
    undo.redo()
    XCTAssertEqual(view.text, afterDelete)
    assertValidSource(view)
    try capture(
      "native-undo-delete", view: view, window: window,
      values: [
        "sourceAfterNativeDelete": afterDelete,
        "deletedWholeToken": afterDelete == initial,
        "note": "Deletion granularity is measured, not assumed atomic.",
      ])
  }

  @MainActor
  func testMarkedTextCommitPreservesSourceAndValidSelection() throws {
    let (window, view) = mount("前后")
    defer { window.isHidden = true }
    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = NSRange(location: 1, length: 0)
    view.setMarkedText("#(滑稽)", selectedRange: NSRange(location: 5, length: 0))
    XCTAssertNotNil(view.markedTextRange)
    XCTAssertEqual(view.text, "前#(滑稽)后")
    view.layoutManager.ensureLayout(for: view.textContainer)
    let glyph = view.layoutManager.glyphIndexForCharacter(at: 1)
    XCTAssertFalse(view.layoutManager.propertyForGlyph(at: glyph).contains(.controlCharacter))
    assertValidSource(view)
    try capture(
      "marked-source-visible", view: view, window: window, values: ["hasMarkedText": true])
    view.unmarkText()
    XCTAssertNil(view.markedTextRange)
    XCTAssertEqual(view.text, "前#(滑稽)后")
    view.layoutManager.ensureLayout(for: view.textContainer)
    let committedGlyph = view.layoutManager.glyphIndexForCharacter(at: 1)
    XCTAssertTrue(
      view.layoutManager.propertyForGlyph(at: committedGlyph).contains(.controlCharacter))
    assertValidSource(view)
    try capture(
      "marked-source-committed", view: view, window: window, values: ["hasMarkedText": false])
    view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
    XCTAssertEqual(view.text, "前#(滑稽)中文后")
    view.unmarkText()
    XCTAssertEqual(view.text, "前#(滑稽)中文后")
    assertValidSource(view)
  }
}
