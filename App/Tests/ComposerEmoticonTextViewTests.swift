import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerEmoticonTextViewTests: XCTestCase {
  func testLoadedFaceTakesOneLineHeightOfWidthWithoutChangingSourceOrUndo() throws {
    for size: CGFloat in [17, 40] {
      let fixture = Fixture(source: "甲#(滑稽)乙", size: size)
      defer { fixture.close() }
      let view = fixture.view
      let source = view.textStorage.string
      let undo = try XCTUnwrap(view.undoManager)
      let selected = NSRange(location: 6, length: 0)
      view.selectedRange = selected
      let font = try XCTUnwrap(view.font)
      XCTAssertTrue(view.emoticonLayout.plan.spans.isEmpty, "Missing images stay readable text")
      fixture.loadFaces()
      view.layoutManager.ensureLayout(for: view.textContainer)
      let before = try caret(view, offset: 1)
      let after = try caret(view, offset: 6)
      XCTAssertEqual(after.minX - before.minX, font.lineHeight, accuracy: 0.5)
      XCTAssertEqual(after.minY, before.minY, accuracy: 0.5)
      XCTAssertEqual(view.textStorage.string, source)
      XCTAssertEqual(view.text, source)
      XCTAssertEqual(view.selectedRange, selected)
      XCTAssertFalse(undo.canUndo)
      XCTAssertFalse(source.contains("\u{fffc}"))
    }
  }

  func testNativeCopyCutPasteAndUndoPreserveCanonicalTokens() throws {
    let fixture = Fixture(source: "前😀#(滑稽)后")
    defer { fixture.close() }
    fixture.loadFaces()
    let view = fixture.view
    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = NSRange(location: 3, length: 5)
    view.copy(nil)
    XCTAssertEqual(UIPasteboard.general.string, "#(滑稽)")
    let undo = try XCTUnwrap(view.undoManager)
    undo.removeAllActions()
    undo.beginUndoGrouping()
    view.cut(nil)
    undo.endUndoGrouping()
    XCTAssertEqual(view.text, "前😀后")
    XCTAssertEqual(UIPasteboard.general.string, "#(滑稽)")
    undo.undo()
    XCTAssertEqual(view.text, "前😀#(滑稽)后")
    view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
    view.paste(nil)
    XCTAssertEqual(view.text, "前😀#(滑稽)后#(滑稽)")
    XCTAssertEqual(view.textStorage.string, view.text)
    XCTAssertFalse(view.text.contains("\u{fffc}"))
  }

  func testOneBackspaceDeletesWholeVisibleFaceAndUndoRestoresIt() throws {
    let fixture = Fixture(source: "前#(滑稽)后")
    defer { fixture.close() }
    fixture.loadFaces()
    let view = fixture.view
    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = NSRange(location: 6, length: 0)
    let undo = try XCTUnwrap(view.undoManager)
    undo.removeAllActions()
    undo.beginUndoGrouping()
    view.deleteBackward()
    undo.endUndoGrouping()
    XCTAssertEqual(view.text, "前后")
    undo.undo()
    XCTAssertEqual(view.text, "前#(滑稽)后")
    XCTAssertEqual(view.emoticonLayout.plan.spans.count, 1)
    undo.redo()
    XCTAssertEqual(view.text, "前后")
  }

  func testMarkedTextIsNotFoldedOrNormalizedUntilCompositionCommits() throws {
    let fixture = Fixture(source: "前后")
    defer { fixture.close() }
    fixture.loadFaces()
    let view = fixture.view
    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = NSRange(location: 1, length: 0)
    view.setMarkedText("#(滑稽)", selectedRange: NSRange(location: 2, length: 0))
    // The load callback can complete while the input method still owns a range.
    fixture.loadFaces()
    XCTAssertNotNil(view.markedTextRange)
    XCTAssertTrue(view.emoticonLayout.plan.spans.isEmpty)
    let selection = view.selectedRange
    view.normalizeSelection()
    XCTAssertEqual(view.selectedRange, selection)
    XCTAssertEqual(view.text, "前#(滑稽)后")
    view.unmarkText()
    XCTAssertNil(view.markedTextRange)
    XCTAssertEqual(view.emoticonLayout.plan.spans.count, 1)
    view.normalizeSelection()
    XCTAssertTrue([1, 6].contains(view.selectedRange.location))
    XCTAssertEqual(view.text, "前#(滑稽)后")
  }

  func testUnknownMissingAndGraphemeJoinedTokensStayVisibleAsText() throws {
    let source = "#(未知)#(生气)#(滑稽)\u{301}#(哈哈)"
    let fixture = Fixture(source: source)
    defer { fixture.close() }
    fixture.loadFaces()
    XCTAssertEqual(fixture.view.emoticonLayout.plan.spans.map(\.token), ["#(哈哈)"])
    fixture.view.emoticonLayout.setImages([:])
    XCTAssertTrue(fixture.view.emoticonLayout.plan.spans.isEmpty)
    XCTAssertEqual(fixture.view.textStorage.string, source)
  }

  private func caret(_ view: UITextView, offset: Int) throws -> CGRect {
    view.caretRect(
      for: try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: offset)))
  }

  private final class Fixture {
    let view = ComposerEmoticonTextView()
    let window: UIWindow

    init(source: String, size: CGFloat = 20) {
      if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
      {
        window = UIWindow(windowScene: scene)
      } else {
        window = UIWindow(frame: .zero)
      }
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      let controller = UIViewController()
      window.rootViewController = controller
      view.frame = CGRect(x: 12, y: 100, width: 366, height: 400)
      view.font = .systemFont(ofSize: size)
      view.text = source
      controller.view.addSubview(view)
      window.makeKeyAndVisible()
      controller.view.layoutIfNeeded()
    }

    func loadFaces() {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
        UIColor.systemYellow.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
      }
      let urls = ["滑稽", "哈哈"].compactMap {
        InlineClassicEmoticonPlan.thumbnailURL(exactName: $0)
      }
      view.emoticonLayout.setImages(Dictionary(uniqueKeysWithValues: urls.map { ($0, image) }))
    }

    func close() {
      view.stopLoadingImages()
      view.resignFirstResponder()
      window.isHidden = true
    }
  }
}
