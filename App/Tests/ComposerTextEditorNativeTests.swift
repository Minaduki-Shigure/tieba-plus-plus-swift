import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerTextEditorNativeTests: XCTestCase {
  func testPickerInsertionWhileAnotherFieldIsFocusedReplacesEmojiAndSupportsUndoRedo() throws {
    let fixture = Fixture(text: "前👍🏽后e\u{301}")
    defer { fixture.close() }
    fixture.state.selection = ComposerTextSelection(location: 1, length: 4)
    fixture.apply()
    let pickerSearch = UITextField(frame: CGRect(x: 12, y: 20, width: 280, height: 44))
    fixture.window.rootViewController?.view.addSubview(pickerSearch)
    XCTAssertTrue(pickerSearch.becomeFirstResponder())
    XCTAssertFalse(fixture.view.isFirstResponder)
    let original = fixture.state.text
    let undo = try XCTUnwrap(fixture.view.undoManager)

    XCTAssertTrue(fixture.insert("#(滑稽)"))
    XCTAssertTrue(fixture.state.text.utf8.elementsEqual("前#(滑稽)后e\u{301}".utf8))
    XCTAssertEqual(fixture.state.selection, ComposerTextSelection(location: 6, length: 0))
    XCTAssertTrue(pickerSearch.isFirstResponder, "Insertion must not steal focus from the picker")
    XCTAssertTrue(undo.canUndo)

    // The SwiftUI binding echo must not be mistaken for an external draft load.
    fixture.apply()
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertTrue(fixture.view.text.utf8.elementsEqual(original.utf8))
    XCTAssertTrue(fixture.state.text.utf8.elementsEqual(original.utf8))
    XCTAssertTrue(undo.canRedo)
    undo.redo()
    XCTAssertTrue(fixture.view.text.utf8.elementsEqual("前#(滑稽)后e\u{301}".utf8))
    XCTAssertTrue(fixture.state.text.utf8.elementsEqual(fixture.view.text.utf8))
  }

  func testNewDocumentClearsNativeUndoEvenWhenAccountDraftHasIdenticalText() throws {
    let fixture = Fixture(text: "账户甲的草稿")
    defer { fixture.close() }
    let oldID = fixture.state.documentID
    XCTAssertTrue(fixture.insert("#(哈哈)"))
    let undo = try XCTUnwrap(fixture.view.undoManager)
    XCTAssertTrue(undo.canUndo)
    let identicalDraft = fixture.state.text

    // Account/target changes invalidate synchronously before a SwiftUI render.
    fixture.controller.invalidateDocument()
    XCTAssertFalse(undo.canUndo)
    XCTAssertFalse(undo.canRedo)
    XCTAssertFalse(
      fixture.controller.insert(
        "#(滑稽)", expectedText: identicalDraft, selection: fixture.state.selection,
        documentID: oldID))

    fixture.state.documentID = UUID()
    fixture.apply()
    XCTAssertEqual(fixture.view.text, identicalDraft)
    XCTAssertFalse(undo.canUndo)
    XCTAssertFalse(undo.canRedo)
    XCTAssertTrue(fixture.insert("#(滑稽)"))
    undo.undo()
    XCTAssertEqual(fixture.view.text, identicalDraft)
    XCTAssertFalse(undo.canUndo, "Undo cannot continue into the previous account's document")
  }

  func testExternalDraftAndClearDoNotRegisterUserEditsOrRestorePreviousContents() throws {
    let fixture = Fixture(text: "旧草稿")
    defer { fixture.close() }
    XCTAssertTrue(fixture.insert("#(哈哈)"))
    let undo = try XCTUnwrap(fixture.view.undoManager)
    for replacement in ["恢复的草稿#(滑稽)", ""] {
      fixture.controller.invalidateDocument()
      fixture.state.documentID = UUID()
      fixture.state.text = replacement
      fixture.state.selection = ComposerTextSelection(
        location: replacement.utf16.count, length: 0)
      fixture.apply()
      XCTAssertEqual(fixture.view.text, replacement)
      XCTAssertEqual(fixture.state.text, replacement)
      XCTAssertFalse(undo.canUndo)
      XCTAssertFalse(undo.canRedo)
      XCTAssertTrue(fixture.insert("#(哈哈)"))
      undo.undo()
      XCTAssertEqual(fixture.view.text, replacement)
      XCTAssertFalse(undo.canUndo)
    }
  }

  func testPickerRejectsStaleSourceSelectionDocumentAndLockedEditorWithoutEditing() throws {
    let fixture = Fixture(text: "A😀Z")
    defer { fixture.close() }
    let source = fixture.state.text
    XCTAssertFalse(
      fixture.controller.insert(
        "#(哈哈)", expectedText: "过期内容", selection: fixture.state.selection,
        documentID: fixture.state.documentID))
    XCTAssertFalse(
      fixture.controller.insert(
        "#(哈哈)", expectedText: source, selection: .start,
        documentID: fixture.state.documentID))
    XCTAssertFalse(
      fixture.controller.insert(
        "#(哈哈)", expectedText: source, selection: fixture.state.selection,
        documentID: UUID()))
    fixture.view.isEditable = false
    XCTAssertFalse(fixture.insert("#(哈哈)"))
    fixture.view.isEditable = true
    fixture.view.selectedRange = NSRange(location: 2, length: 0)
    XCTAssertFalse(
      fixture.controller.insert(
        "#(哈哈)", expectedText: source,
        selection: ComposerTextSelection(location: 2, length: 0),
        documentID: fixture.state.documentID))
    XCTAssertEqual(fixture.view.text, source)
    XCTAssertEqual(fixture.state.text, source)
    XCTAssertFalse(try XCTUnwrap(fixture.view.undoManager).canUndo)
  }

  func testMarkedTextRejectsPickerUntilCompositionEndsAndDetachedEditorCannotEdit() throws {
    let fixture = Fixture(text: "前后")
    defer { fixture.close() }
    XCTAssertTrue(fixture.view.becomeFirstResponder())
    fixture.view.selectedRange = NSRange(location: 1, length: 0)
    fixture.view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
    XCTAssertNotNil(fixture.view.markedTextRange)
    let composing = try XCTUnwrap(fixture.view.text)
    XCTAssertFalse(
      fixture.controller.insert(
        "#(哈哈)", expectedText: composing,
        selection: ComposerTextSelection(fixture.view.selectedRange),
        documentID: fixture.state.documentID))
    XCTAssertEqual(fixture.view.text, composing)
    XCTAssertNotNil(fixture.view.markedTextRange)

    fixture.view.unmarkText()
    fixture.coordinator.textViewDidChange(fixture.view)
    XCTAssertTrue(fixture.insert("#(哈哈)"))
    let committed = fixture.state.text
    ComposerTextEditor.dismantleUIView(fixture.view, coordinator: fixture.coordinator)
    XCTAssertFalse(fixture.insert("#(滑稽)"))
    XCTAssertEqual(fixture.view.text, committed)
    XCTAssertNil(fixture.view.delegate)
  }

  func testParentFocusRemovalWaitsUntilAfterApplyWithoutWritingBindings() async {
    let fixture = Fixture(text: "正在编辑的回复")
    defer { fixture.close() }
    XCTAssertTrue(fixture.view.becomeFirstResponder())
    XCTAssertTrue(fixture.state.isFocused)
    let editingEnded = XCTNSNotificationExpectation(
      name: UITextView.textDidEndEditingNotification, object: fixture.view)

    fixture.state.isFocused = false
    fixture.state.bindingWriteCount = 0
    fixture.apply()

    XCTAssertTrue(
      fixture.view.isFirstResponder,
      "Representable updates must not synchronously resign the keyboard while SwiftUI is rendering")
    XCTAssertEqual(fixture.state.bindingWriteCount, 0)
    await fulfillment(of: [editingEnded], timeout: 3)
    XCTAssertFalse(fixture.view.isFirstResponder)
    XCTAssertFalse(fixture.state.isFocused)
    XCTAssertEqual(fixture.state.bindingWriteCount, 0)
    XCTAssertEqual(fixture.state.text, "正在编辑的回复")
  }

  func testLatestFocusRequestCancelsPendingResignationWithoutLosingKeyboard() async {
    let fixture = Fixture(text: "保留当前输入焦点")
    defer { fixture.close() }
    XCTAssertTrue(fixture.view.becomeFirstResponder())
    let editingEnded = XCTNSNotificationExpectation(
      name: UITextView.textDidEndEditingNotification, object: fixture.view)
    editingEnded.isInverted = true
    fixture.state.bindingWriteCount = 0

    // Both requests occur in one main-actor turn, before either queued focus
    // update can run. The stale resignation must not briefly hide the keyboard.
    fixture.state.isFocused = false
    fixture.apply()
    fixture.state.isFocused = true
    fixture.apply()
    XCTAssertTrue(fixture.view.isFirstResponder)
    XCTAssertEqual(fixture.state.bindingWriteCount, 0)
    await finishQueuedMainActorWork()
    await fulfillment(of: [editingEnded], timeout: 0.2)
    XCTAssertTrue(fixture.view.isFirstResponder)
    XCTAssertTrue(fixture.state.isFocused)
    XCTAssertEqual(fixture.state.bindingWriteCount, 0)
  }

  func testDismantlingCancelsPendingFocusEvenWhileViewRemainsInWindow() async {
    let fixture = Fixture(text: "离开编辑器")
    defer { fixture.close() }
    XCTAssertFalse(fixture.view.isFirstResponder)
    let editingBegan = XCTNSNotificationExpectation(
      name: UITextView.textDidBeginEditingNotification, object: fixture.view)
    editingBegan.isInverted = true
    fixture.state.bindingWriteCount = 0
    fixture.state.isFocused = true
    fixture.apply()
    XCTAssertFalse(fixture.view.isFirstResponder)

    ComposerTextEditor.dismantleUIView(fixture.view, coordinator: fixture.coordinator)
    // Keep the view mounted and strongly retained: a window/weak-view guard
    // alone cannot prevent a stale task from taking focus after dismantling.
    XCTAssertNotNil(fixture.view.window)
    await finishQueuedMainActorWork()
    await fulfillment(of: [editingBegan], timeout: 0.2)
    XCTAssertFalse(fixture.view.isFirstResponder)
    XCTAssertNil(fixture.view.delegate)
    XCTAssertEqual(fixture.state.bindingWriteCount, 0)
    XCTAssertFalse(fixture.insert("#(滑稽)"))
  }

  private func finishQueuedMainActorWork() async {
    let sentinel = expectation(description: "Main actor runs after the queued focus requests")
    Task { @MainActor in sentinel.fulfill() }
    await fulfillment(of: [sentinel], timeout: 3)
  }

  @MainActor
  private final class State {
    var text: String
    var selection: ComposerTextSelection
    var isFocused = false
    var documentID = UUID()
    var bindingWriteCount = 0

    init(text: String) {
      self.text = text
      selection = ComposerTextSelection(location: text.utf16.count, length: 0)
    }
  }

  @MainActor
  private final class Fixture {
    let state: State
    let controller = ComposerTextEditorController()
    let view = ComposerEmoticonTextView()
    let window: UIWindow
    let coordinator: ComposerTextEditor.Coordinator

    init(text: String) {
      let state = State(text: text)
      self.state = state
      let parent = Self.editor(state: state, controller: controller)
      coordinator = parent.makeCoordinator()
      let host = UIViewController()
      if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
      {
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      } else {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      }
      window.rootViewController = host
      view.frame = CGRect(x: 12, y: 100, width: 366, height: 300)
      host.view.addSubview(view)
      view.delegate = coordinator
      view.font = .preferredFont(forTextStyle: .body)
      window.makeKeyAndVisible()
      host.view.layoutIfNeeded()
      coordinator.apply(parent: parent, to: view)
    }

    func apply() {
      let parent = Self.editor(state: state, controller: controller)
      coordinator.parent = parent
      coordinator.apply(parent: parent, to: view)
    }

    func insert(_ token: String) -> Bool {
      controller.insert(
        token, expectedText: state.text, selection: state.selection, documentID: state.documentID)
    }

    func close() {
      ComposerTextEditor.dismantleUIView(view, coordinator: coordinator)
      window.isHidden = true
    }

    private static func editor(
      state: State, controller: ComposerTextEditorController
    ) -> ComposerTextEditor {
      ComposerTextEditor(
        text: Binding(
          get: { state.text },
          set: {
            state.bindingWriteCount += 1
            state.text = $0
          }),
        selection: Binding(
          get: { state.selection },
          set: {
            state.bindingWriteCount += 1
            state.selection = $0
          }),
        isFocused: Binding(
          get: { state.isFocused },
          set: {
            state.bindingWriteCount += 1
            state.isFocused = $0
          }),
        controller: controller, documentID: state.documentID, isEditable: true,
        accessibilityLabel: "测试正文", accessibilityIdentifier: "composer-native-test")
    }
  }
}
