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

  func testSubmissionSupportsOrderedImageOnlyAndTextWithUpToNineAttachments() throws {
    let target = newThreadModelTarget()
    let attachments = (1...ComposerImageDraftPolicy.maximumAttachmentCount).map {
      newThreadModelAttachment(UInt8($0))
    }

    let imageOnly = try XCTUnwrap(
      NewThreadSubmission(
        id: newThreadModelUUID(20),
        target: target,
        title: nil,
        content: "",
        attachments: attachments
      )
    )
    let textAndImages = try XCTUnwrap(
      NewThreadSubmission(
        id: newThreadModelUUID(21),
        target: target,
        title: "标题",
        content: "正文 #(滑稽)",
        attachments: Array(attachments.reversed())
      )
    )
    let reorderedIdentity = try XCTUnwrap(
      NewThreadSubmission(
        id: imageOnly.id,
        target: target,
        title: nil,
        content: "",
        attachments: Array(attachments.reversed())
      )
    )

    XCTAssertEqual(imageOnly.attachments, attachments)
    XCTAssertEqual(textAndImages.attachments, Array(attachments.reversed()))
    XCTAssertNotEqual(imageOnly, reorderedIdentity)
    XCTAssertEqual(Set([imageOnly, reorderedIdentity]).count, 2)
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: "",
        attachments: attachments + [newThreadModelAttachment(10)]
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: "",
        attachments: [attachments[0], attachments[0]]
      )
    )
    let duplicateContent = try XCTUnwrap(
      ComposerImageAttachment(
        id: newThreadModelUUID(11),
        sha256: attachments[0].sha256,
        byteCount: attachments[0].byteCount,
        pixelWidth: attachments[0].pixelWidth,
        pixelHeight: attachments[0].pixelHeight,
        quality: attachments[0].quality
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: "",
        attachments: [attachments[0], duplicateContent]
      )
    )
  }

  func testAttachmentDoesNotBypassSubmissionPolicyButEditingDraftRemainsLossless() {
    let attachment = newThreadModelAttachment(1)
    let target = newThreadModelTarget()

    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: " \n\t ",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      NewThreadSubmission(
        target: target,
        title: nil,
        content: String(
          repeating: "a",
          count: NewThreadContentPolicy.maximumCharacterCount - 1
        ),
        attachments: [attachment]
      )
    )
    let key = NewThreadDraftKey(userID: 9, target: target)!
    XCTAssertNotNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment]
      )
    )
    XCTAssertNotNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: String(
          repeating: "a",
          count: NewThreadContentPolicy.maximumCharacterCount + 1
        ),
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment],
        disposition: .submissionPending(submissionID: UUID())
      )
    )
  }

  func testReceiptResultAndVisibilityConfirmationValidateIdentity() throws {
    let target = newThreadModelTarget()
    let attachment = newThreadModelAttachment(20)
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
    let imageOnlyConfirmation = try XCTUnwrap(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: 9,
        title: nil,
        content: "",
        attachments: [attachment]
      )
    )
    XCTAssertEqual(imageOnlyConfirmation.attachments, [attachment])
    XCTAssertNil(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: 9,
        title: nil,
        content: " \n\t ",
        attachments: [attachment]
      )
    )
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

  func testDraftSupportsImageOnlyAndIncludesOrderedAttachmentsInIdentity() throws {
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadModelTarget()))
    let first = newThreadModelAttachment(1)
    let second = newThreadModelAttachment(2)
    let date = Date(timeIntervalSince1970: 100)
    let imageOnly = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        attachments: [first, second],
        updatedAt: date
      )
    )
    let reordered = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        attachments: [second, first],
        updatedAt: date
      )
    )

    XCTAssertEqual(imageOnly.attachments, [first, second])
    XCTAssertNotEqual(imageOnly, reordered)
    XCTAssertEqual(Set([imageOnly, reordered]).count, 2)
    XCTAssertNil(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        attachments: [first, first]
      )
    )
  }

  func testPureTextDraftDispositionsRejectImageAttachments() throws {
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadModelTarget()))
    let attachment = newThreadModelAttachment(1)
    let submissionID = newThreadModelUUID(20)
    let sessionRevision = newThreadModelUUID(21)
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let dispositions: [NewThreadDraftDisposition] = [
      .submissionPending(submissionID: submissionID),
      .challengeRequired(submissionID: submissionID, sessionRevision: sessionRevision),
      .acceptedAwaitingVisibility(submissionID: submissionID, receipt: receipt),
      .confirmed(submissionID: submissionID, receipt: receipt),
      .outcomeUnknown(submissionID: submissionID),
    ]

    for disposition in dispositions {
      XCTAssertNil(
        NewThreadDraft(
          key: key,
          title: "标题",
          content: "正文",
          attachments: [attachment],
          disposition: disposition
        )
      )
    }
  }

  func testImageDraftStatesRequireNonemptyValidAttachments() throws {
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadModelTarget()))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: newThreadModelUUID(20),
        sessionRevision: newThreadModelUUID(21)
      )
    )
    let attachment = newThreadModelAttachment(1)
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let dispositions: [NewThreadDraftDisposition] = [
      .imagePreparationPending(reference: reference),
      .imagePipeline(reference: reference),
      .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt),
      .imageConfirmed(reference: reference, receipt: receipt),
    ]

    for disposition in dispositions {
      XCTAssertNil(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "正文",
          disposition: disposition
        )
      )
      XCTAssertNil(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "正文",
          attachments: [attachment, attachment],
          disposition: disposition
        )
      )
      let draft = try XCTUnwrap(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "正文",
          attachments: [attachment],
          disposition: disposition
        )
      )
      XCTAssertEqual(draft.disposition.imageSubmissionReference, reference)
    }
  }

  func testImageAcceptedAndConfirmedDraftsRejectInvalidReceipts() throws {
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadModelTarget()))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: newThreadModelUUID(20),
        sessionRevision: newThreadModelUUID(21)
      )
    )
    let invalidReceipt = try JSONDecoder().decode(
      NewThreadReceipt.self,
      from: Data(#"{"threadID":0,"firstPostID":700}"#.utf8)
    )
    XCTAssertFalse(invalidReceipt.isValid)

    for disposition in [
      NewThreadDraftDisposition.imageAcceptedAwaitingVisibility(
        reference: reference,
        receipt: invalidReceipt
      ),
      .imageConfirmed(reference: reference, receipt: invalidReceipt),
    ] {
      XCTAssertNil(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "正文",
          attachments: [newThreadModelAttachment(1)],
          disposition: disposition
        )
      )
    }
  }

  func testSensitiveModelsUseRedactedDescriptions() throws {
    let target = newThreadModelTarget()
    let attachment = newThreadModelAttachment(30)
    let submission = try XCTUnwrap(
      NewThreadSubmission(
        target: target,
        title: "secret title",
        content: "secret content",
        attachments: [attachment]
      )
    )
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: target))
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "secret title",
        content: "secret content",
        attachments: [attachment]
      )
    )

    for value in [String(describing: submission), String(reflecting: submission)] {
      XCTAssertFalse(value.contains("secret title"))
      XCTAssertFalse(value.contains("secret content"))
      XCTAssertFalse(value.contains(attachment.sha256))
      XCTAssertFalse(value.contains(attachment.relativePrivateFilename))
    }
    for value in [String(describing: draft), String(reflecting: draft)] {
      XCTAssertFalse(value.contains("secret title"))
      XCTAssertFalse(value.contains("secret content"))
      XCTAssertFalse(value.contains(attachment.sha256))
      XCTAssertFalse(value.contains(attachment.relativePrivateFilename))
    }
    XCTAssertFalse(
      Mirror(reflecting: submission).children.contains { child in
        String(reflecting: child.value).contains(attachment.sha256)
          || String(reflecting: child.value).contains(attachment.relativePrivateFilename)
      }
    )
    XCTAssertFalse(
      Mirror(reflecting: draft).children.contains { child in
        String(reflecting: child.value).contains(attachment.sha256)
          || String(reflecting: child.value).contains(attachment.relativePrivateFilename)
      }
    )
  }
}

private func newThreadModelTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func newThreadModelUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func newThreadModelAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: newThreadModelUUID(value),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(100 + Int(value)),
    pixelWidth: 20,
    pixelHeight: 10,
    quality: .standard
  )!
}
