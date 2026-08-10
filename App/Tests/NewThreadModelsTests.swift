import XCTest

@testable import TiebaPlusPlus

final class NewThreadModelsTests: XCTestCase {
  func testComposerPresentationKeepsWriteTerminalStatesLocked() throws {
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let lockedStates: [NewThreadSubmissionState] = [
      .submitting(UUID()),
      .challengeRequired,
      .outcomeUnknown,
      .acceptedAwaitingVisibility(receipt),
      .confirmed(receipt),
      .accountChanged,
    ]

    for state in lockedStates {
      let presentation = NewThreadComposerPresentation(state: state)
      XCTAssertFalse(presentation.allowsEditing)
      XCTAssertFalse(presentation.allowsSubmission)
      XCTAssertEqual(
        presentation.allowsStartingNewThread,
        state == .confirmed(receipt)
      )
    }

    XCTAssertTrue(
      NewThreadComposerPresentation(
        state: .acceptedAwaitingVisibility(receipt)
      ).allowsVisibilityCheck
    )
  }

  func testComposerPresentationAllowsCredentialRepairWithoutUnsafeSubmission() {
    let presentation = NewThreadComposerPresentation(
      state: .failed(.fullCredentialsRequired)
    )

    XCTAssertTrue(presentation.allowsEditing)
    XCTAssertFalse(presentation.allowsSubmission)
    XCTAssertFalse(presentation.allowsVisibilityCheck)
  }

  func testTargetNormalizesForumNameAndUsesExactNormalizedIdentity() throws {
    let composed = try XCTUnwrap(
      NewThreadTarget(forumID: 7, forumName: "  Cafe\u{301}  ")
    )
    let precomposed = try XCTUnwrap(
      NewThreadTarget(forumID: 7, forumName: "Caf\u{E9}")
    )

    XCTAssertEqual(composed.forumName, "Caf\u{E9}")
    XCTAssertEqual(composed, precomposed)
    XCTAssertEqual(composed.id, "forum:7:Caf\u{E9}")
    XCTAssertNotEqual(
      composed,
      NewThreadTarget(forumID: 8, forumName: "Caf\u{E9}")
    )
    XCTAssertNotEqual(
      composed,
      NewThreadTarget(forumID: 7, forumName: "another")
    )
  }

  func testTargetRejectsInvalidIdentity() {
    XCTAssertNil(NewThreadTarget(forumID: 0, forumName: "swift"))
    XCTAssertNil(NewThreadTarget(forumID: 7, forumName: " \n "))
    XCTAssertNil(NewThreadTarget(forumID: 7, forumName: "bad\u{0}name"))
    XCTAssertNil(
      NewThreadTarget(forumID: 7, forumName: String(repeating: "a", count: 101))
    )
  }

  func testSubmissionNormalizesOptionalTitleAndPreservesExactContent() throws {
    let target = newThreadModelTarget()
    let content = "  第一行\nCafe\u{301}\t末尾  "
    let titled = try XCTUnwrap(
      NewThreadSubmission(
        id: newThreadModelUUID(1),
        target: target,
        title: "  标题  ",
        content: content
      )
    )
    let untitled = try XCTUnwrap(
      NewThreadSubmission(target: target, title: " \n ", content: content)
    )

    XCTAssertEqual(titled.title, "标题")
    XCTAssertEqual(titled.content, content)
    XCTAssertNil(untitled.title)
  }

  func testSubmissionPoliciesRejectOversizedOrNonPlainText() {
    let target = newThreadModelTarget()
    XCTAssertNotNil(
      NewThreadSubmission(
        target: target,
        title: String(repeating: "a", count: NewThreadTitlePolicy.maximumCharacterCount),
        content: "正文"
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: String(repeating: "a", count: NewThreadTitlePolicy.maximumCharacterCount + 1),
        content: "正文"
      )
    )
    XCTAssertNil(NewThreadSubmission(target: target, title: "#(title)", content: "正文"))
    XCTAssertNil(NewThreadSubmission(target: target, title: nil, content: " \n\t "))
    XCTAssertNil(NewThreadSubmission(target: target, title: nil, content: "#(pic,1,2,3)"))
    XCTAssertNil(NewThreadSubmission(target: target, title: nil, content: "bad\u{0}text"))
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: String(repeating: "a", count: NewThreadContentPolicy.maximumCharacterCount + 1)
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: String(
          repeating: "你",
          count: NewThreadContentPolicy.maximumUTF8ByteCount / 3 + 1
        )
      )
    )
  }

  func testReceiptResultAndVisibilityConfirmationValidateIdentity() throws {
    let target = newThreadModelTarget()
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let result = try XCTUnwrap(
      NewThreadResult(
        submissionID: newThreadModelUUID(2),
        userID: 9,
        target: target,
        outcome: .acceptedAwaitingVisibility(receipt)
      )
    )
    let confirmation = try XCTUnwrap(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: 9,
        title: "  标题  ",
        content: "正文"
      )
    )

    XCTAssertEqual(result.outcome, .acceptedAwaitingVisibility(receipt))
    XCTAssertEqual(confirmation.title, "标题")
    XCTAssertNotNil(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: 9,
        title: String(repeating: "自动标题", count: 20),
        content: "正文"
      )
    )
    XCTAssertNil(NewThreadReceipt(threadID: 0, firstPostID: 700))
    XCTAssertNil(NewThreadReceipt(threadID: 70, firstPostID: 0))
    XCTAssertNil(
      NewThreadResult(
        submissionID: UUID(),
        userID: 0,
        target: target,
        outcome: .confirmed(receipt)
      )
    )
    XCTAssertNil(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: 0,
        title: nil,
        content: "正文"
      )
    )
  }

  func testDraftKeysSeparateAccountsAndExactTargets() throws {
    let target = newThreadModelTarget()
    let same = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: " swift "))
    let otherName = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift-alt"))
    let first = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: target))

    XCTAssertEqual(first, NewThreadDraftKey(userID: 9, target: same))
    XCTAssertNotEqual(first, NewThreadDraftKey(userID: 10, target: target))
    XCTAssertNotEqual(first, NewThreadDraftKey(userID: 9, target: otherName))
    XCTAssertNil(NewThreadDraftKey(userID: 0, target: target))
  }

  func testDraftAllowsIncompleteEditingButLocksValidTerminalProofs() throws {
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadModelTarget()))
    let submissionID = newThreadModelUUID(3)
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))

    XCTAssertNotNil(NewThreadDraft(key: key, title: "标题", content: ""))
    XCTAssertNotNil(NewThreadDraft(key: key, title: nil, content: "尚未完成"))
    XCTAssertNil(NewThreadDraft(key: key, title: nil, content: ""))
    XCTAssertNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        disposition: .submissionPending(submissionID: submissionID)
      )
    )
    XCTAssertNotNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        disposition: .challengeRequired(
          submissionID: submissionID,
          sessionRevision: UUID()
        )
      )
    )
    XCTAssertNotNil(
      NewThreadDraft(
        key: key,
        title: "标题",
        content: "正文",
        disposition: .confirmed(submissionID: submissionID, receipt: receipt)
      )
    )
    XCTAssertNotNil(
      NewThreadDraft(
        key: key,
        title: "标题",
        content: "正文",
        disposition: .acceptedAwaitingVisibility(
          submissionID: submissionID,
          receipt: receipt
        )
      )
    )
  }

  func testSensitiveModelsUseRedactedDescriptions() throws {
    let target = newThreadModelTarget()
    let submission = try XCTUnwrap(
      NewThreadSubmission(target: target, title: "secret title", content: "secret content")
    )
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: target))
    let draft = try XCTUnwrap(
      NewThreadDraft(key: key, title: "secret title", content: "secret content")
    )

    for value in [String(describing: submission), String(reflecting: submission)] {
      XCTAssertFalse(value.contains("secret title"))
      XCTAssertFalse(value.contains("secret content"))
    }
    for value in [String(describing: draft), String(reflecting: draft)] {
      XCTAssertFalse(value.contains("secret title"))
      XCTAssertFalse(value.contains("secret content"))
    }
  }
}

private func newThreadModelTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func newThreadModelUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}
