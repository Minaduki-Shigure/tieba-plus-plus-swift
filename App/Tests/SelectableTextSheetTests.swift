import XCTest

@testable import TiebaPlusPlus

final class SelectableTextSheetTests: XCTestCase {
  func testPresentationRejectsMissingOrBlankText() {
    XCTAssertNil(SelectableTextPresentation(text: nil))
    XCTAssertNil(SelectableTextPresentation(text: ""))
    XCTAssertNil(SelectableTextPresentation(text: " \n\t "))
  }

  func testPresentationPreservesExactAcceptedSnapshot() throws {
    let text = "  title\nbody \n"

    let presentation = try XCTUnwrap(SelectableTextPresentation(text: text))

    XCTAssertEqual(presentation.text, text)
  }

  func testSameTextCanBePresentedAgainWithIndependentIdentity() throws {
    let first = try XCTUnwrap(SelectableTextPresentation(text: "same"))
    let second = try XCTUnwrap(SelectableTextPresentation(text: "same"))

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotEqual(first, second)
  }

  func testCopyAllWritesExactSnapshotOnceThenDismisses() {
    let presentation = SelectableTextPresentation(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      text: " title\n[图片]\nbody "
    )!
    var pending: SelectableTextPresentation? = presentation

    let copied = SelectableTextSheetCommandPolicy.consume(
      .copyAll,
      expected: presentation,
      pending: &pending
    )

    XCTAssertEqual(copied, presentation.text)
    XCTAssertNil(pending)

    let repeated = SelectableTextSheetCommandPolicy.consume(
      .copyAll,
      expected: presentation,
      pending: &pending
    )
    XCTAssertNil(repeated)
    XCTAssertNil(pending)
  }

  func testCloseDoesNotWriteAndDismissesOnce() {
    let presentation = SelectableTextPresentation(text: "private snapshot")!
    var pending: SelectableTextPresentation? = presentation

    let copied = SelectableTextSheetCommandPolicy.consume(
      .close,
      expected: presentation,
      pending: &pending
    )

    XCTAssertNil(copied)
    XCTAssertNil(pending)
  }

  func testRevokedOrStalePresentationCannotBeConsumed() throws {
    let expected = try XCTUnwrap(
      SelectableTextPresentation(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        text: "snapshot"
      )
    )
    let staleID = try XCTUnwrap(
      SelectableTextPresentation(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        text: "snapshot"
      )
    )
    let staleText = try XCTUnwrap(
      SelectableTextPresentation(id: expected.id, text: "changed")
    )

    var revoked: SelectableTextPresentation?
    XCTAssertNil(
      SelectableTextSheetCommandPolicy.consume(
        .copyAll,
        expected: expected,
        pending: &revoked
      )
    )
    XCTAssertNil(revoked)

    var pending: SelectableTextPresentation? = expected
    XCTAssertNil(
      SelectableTextSheetCommandPolicy.consume(
        .copyAll,
        expected: staleID,
        pending: &pending
      )
    )
    XCTAssertEqual(pending, expected)

    XCTAssertNil(
      SelectableTextSheetCommandPolicy.consume(
        .copyAll,
        expected: staleText,
        pending: &pending
      )
    )
    XCTAssertEqual(pending, expected)
  }
}
