import UIKit
import XCTest

/// Both cases present the production composer and its actual picker sheet.
/// The DEBUG host only supplies an offline account, real temporary file stores
/// and buttons invoking the mounted UITextView's native UndoManager.
final class ComposerEmoticonUITests: XCTestCase {
  @MainActor
  func testNewThreadPickerUndoRedoAndReopenedFileDraftKeepSourceTokens() throws {
    try exerciseComposer(
      route: "composer-fixture-new-thread", editorID: "new-thread-content",
      draftID: "composer-fixture-thread-disk")
  }

  @MainActor
  func testReplyPickerUndoRedoAndReopenedFileDraftKeepSourceTokens() throws {
    try exerciseComposer(
      route: "composer-fixture-reply", editorID: "reply-composer-editor",
      draftID: "composer-fixture-reply-disk")
  }

  @MainActor
  private func exerciseComposer(route: String, editorID: String, draftID: String) throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      "--composer-emoticon-ui-testing",
    ]
    app.launch()
    defer { attachState(app, name: "\(editorID) final") }

    let original = "中文👍🏽 "
    let edited = original + "#(滑稽)"
    let editor = app.textViews[editorID]
    try tap(app.buttons[route], app: app)
    try requireSource(original, editor: editor, app: app)
    try tap(app.buttons["composer-fixture-inspect"], app: app)
    try requireUndoState("undo=0 redo=0", app: app)
    try finishKeyboardIntroductionIfPresented(app)

    // Restored selection is at the end. Opening the real picker resigns the
    // editor; searching makes the picker's field the actual first responder.
    try tap(app.buttons["插入经典表情"], app: app)
    let search = app.searchFields.firstMatch
    try tap(search, app: app)
    try finishKeyboardIntroductionIfPresented(app)
    search.typeText("滑稽")
    try tap(app.buttons["表情 滑稽"], app: app)
    try wait("Picker closes", app: app) { !app.navigationBars["经典表情"].exists }
    try requireSource(edited, editor: editor, app: app)
    attachState(app, name: "\(editorID) picker source token")

    try tap(app.buttons["composer-fixture-undo"], app: app)
    try requireSource(original, editor: editor, app: app)
    try tap(app.buttons["composer-fixture-inspect"], app: app)
    try requireUndoState("undo=0 redo=1", app: app)
    try tap(app.buttons["composer-fixture-redo"], app: app)
    try requireSource(edited, editor: editor, app: app)
    try tap(app.buttons["composer-fixture-inspect"], app: app)
    try requireUndoState("undo=1 redo=0", app: app)

    // The production onDisappear path persists and deactivates the composer.
    // This probe is populated from a file-store read after the durable write,
    // not from the editor binding or an in-memory draft copy.
    try tap(app.navigationBars.buttons.firstMatch, app: app)
    let disk = app.staticTexts[draftID]
    try wait("File draft contains the original token syntax", app: app) {
      disk.exists && disk.label == edited
    }
    XCTAssertEqual(app.staticTexts["composer-fixture-service-counts"].label, "unexpected=0")
    try tap(app.buttons[route], app: app)
    try requireSource(edited, editor: editor, app: app)
    try tap(app.buttons["composer-fixture-inspect"], app: app)
    try requireUndoState("undo=0 redo=0", app: app)
    try tap(app.buttons["composer-fixture-undo"], app: app)
    try requireSource(edited, editor: editor, app: app)
    attachState(app, name: "\(editorID) restored document has no stale undo")
    try tap(app.navigationBars.buttons.firstMatch, app: app)
    try wait("Return to fixture", app: app) { app.buttons[route].isHittable }
    XCTAssertEqual(app.staticTexts[draftID].label, edited)
    XCTAssertEqual(app.staticTexts["composer-fixture-service-counts"].label, "unexpected=0")
  }

  @MainActor
  private func requireSource(_ source: String, editor: XCUIElement, app: XCUIApplication) throws {
    try wait("Native editor source equals \(source)", app: app) {
      editor.exists && (editor.value as? String)?.utf8.elementsEqual(source.utf8) == true
    }
    XCTAssertFalse((editor.value as? String ?? "").contains("\u{fffc}"))
  }

  @MainActor
  private func requireUndoState(_ expected: String, app: XCUIApplication) throws {
    let state = app.staticTexts["composer-fixture-undo-state"]
    try wait("Native undo state \(expected)", app: app) { state.label == expected }
  }

  @MainActor
  private func finishKeyboardIntroductionIfPresented(_ app: XCUIApplication) throws {
    // A fresh simulator can present QuickPath's first-keyboard introduction.
    // Finish that real system UI before requesting another presentation; its
    // pending keyboard transition otherwise blocks the reply's picker sheet.
    let introduction = app.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS %@",
        "Speed up your typing by sliding your finger across the letters to compose a word.")
    ).firstMatch
    guard introduction.waitForExistence(timeout: 2) else { return }
    attachState(app, name: "System QuickPath introduction before composer interaction")
    try tap(app.buttons["Continue"], app: app)
    try wait("QuickPath introduction dismisses", app: app) { !introduction.exists }
  }

  @MainActor
  private func tap(_ element: XCUIElement, app: XCUIApplication) throws {
    guard element.waitForExistence(timeout: 20) else {
      attachState(app, name: "Missing \(element.identifier)")
      XCTFail("Missing element \(element.identifier)")
      throw ComposerEmoticonUITestError.timedOut
    }
    try wait("Tap \(element.identifier)", app: app) { element.isHittable && element.isEnabled }
    element.tap()
  }

  @MainActor
  private func wait(
    _ context: String, app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line,
    until condition: @escaping () -> Bool
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
      attachState(app, name: "Composer failure: \(context)")
      XCTFail(context, file: file, line: line)
      throw ComposerEmoticonUITestError.timedOut
    }
  }

  @MainActor
  private func attachState(_ app: XCUIApplication, name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screen.name = "\(name) screen"
    screen.lifetime = .keepAlways
    add(screen)
  }
}

private enum ComposerEmoticonUITestError: Error { case timedOut }
