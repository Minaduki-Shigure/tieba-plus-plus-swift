import XCTest

@testable import TiebaPlusPlus

final class ThreadReadingModeTests: XCTestCase {
  func testModeMetadataAndOrderingAreStable() {
    XCTAssertEqual(ThreadReadingMode.allCases, [.standard, .pure, .immersive])
    XCTAssertEqual(ThreadReadingMode.standard.title, "标准阅读")
    XCTAssertEqual(ThreadReadingMode.pure.title, "纯净阅读")
    XCTAssertEqual(ThreadReadingMode.immersive.title, "沉浸阅读（只看楼主）")
    XCTAssertEqual(ThreadReadingMode.standard.systemImage, "book.closed")
    XCTAssertEqual(ThreadReadingMode.pure.systemImage, "book.closed.fill")
    XCTAssertEqual(ThreadReadingMode.immersive.systemImage, "person.fill")
    XCTAssertFalse(ThreadReadingMode.standard.usesPurePresentation)
    XCTAssertTrue(ThreadReadingMode.pure.usesPurePresentation)
    XCTAssertTrue(ThreadReadingMode.immersive.usesPurePresentation)
  }

  func testStandardAndPureSelectionsApplyWithoutConfirmation() {
    let options = ThreadBrowseOptions()

    XCTAssertEqual(
      ThreadReadingModePolicy.selection(
        for: .standard,
        threadID: 101,
        options: options
      ),
      .apply(.standard)
    )
    XCTAssertEqual(
      ThreadReadingModePolicy.selection(
        for: .pure,
        threadID: 101,
        options: options
      ),
      .apply(.pure)
    )
  }

  func testImmersiveSelectionFreezesConfirmationWhenOnlyAuthorIsOff() throws {
    let options = ThreadBrowseOptions(sort: .descending)
    let selection = ThreadReadingModePolicy.selection(
      for: .immersive,
      threadID: 102,
      options: options
    )
    guard case .confirmImmersive(let confirmation) = selection else {
      return XCTFail("Expected an immersive-reading confirmation")
    }

    XCTAssertEqual(confirmation.threadID, 102)
    XCTAssertEqual(confirmation.options, options)
    XCTAssertTrue(confirmation.matches(threadID: 102, options: options))
    XCTAssertFalse(confirmation.matches(threadID: 103, options: options))
    XCTAssertFalse(
      confirmation.matches(
        threadID: 102,
        options: ThreadBrowseOptions(sort: .hot)
      )
    )
  }

  func testImmersiveSelectionAppliesImmediatelyWhenOnlyAuthorIsOn() {
    let options = ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: true)

    XCTAssertEqual(
      ThreadReadingModePolicy.selection(
        for: .immersive,
        threadID: 104,
        options: options
      ),
      .apply(.immersive)
    )
  }

  func testImmersiveSelectionFailsClosedForInvalidThreadIdentity() {
    XCTAssertEqual(
      ThreadReadingModePolicy.selection(
        for: .immersive,
        threadID: 0,
        options: ThreadBrowseOptions()
      ),
      .ignore
    )
  }

  func testImmersiveModeDowngradesIfOnlyAuthorIsDisabled() {
    XCTAssertEqual(
      ThreadReadingModePolicy.normalized(
        .immersive,
        options: ThreadBrowseOptions()
      ),
      .pure
    )
    XCTAssertEqual(
      ThreadReadingModePolicy.normalized(
        .immersive,
        options: ThreadBrowseOptions(onlyThreadAuthor: true)
      ),
      .immersive
    )
    XCTAssertEqual(
      ThreadReadingModePolicy.normalized(
        .standard,
        options: ThreadBrowseOptions()
      ),
      .standard
    )
  }
}
