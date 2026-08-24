import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ReplyComposerImageTests: XCTestCase {
  func testComposerKeepsImageDraftWatermarkInsteadOfCurrentDefault() {
    XCTAssertEqual(
      ComposerImageWatermarkPolicy.initialValue(
        preference: .none,
        hasImageDraft: true,
        draftWatermark: .username
      ),
      .username
    )
    XCTAssertEqual(
      ComposerImageWatermarkPolicy.initialValue(
        preference: .username,
        hasImageDraft: true,
        draftWatermark: .forumName
      ),
      .forumName
    )
  }

  func testOnlyDirectTopicReplyAllowsAttachments() throws {
    let direct = try replyImageTarget(.thread(firstPostID: 100))
    let floor = try replyImageTarget(.post(postID: 101))
    let nested = try replyImageTarget(.subpost(parentPostID: 101, subpostID: 102))

    XCTAssertTrue(ReplyComposerImagePolicy.allowsAttachments(for: direct))
    XCTAssertFalse(ReplyComposerImagePolicy.allowsAttachments(for: floor))
    XCTAssertFalse(ReplyComposerImagePolicy.allowsAttachments(for: nested))
    XCTAssertTrue(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: "",
        attachmentCount: 1,
        target: direct
      )
    )
    XCTAssertFalse(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: "正文",
        attachmentCount: 1,
        target: floor
      )
    )
    XCTAssertFalse(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: "正文",
        attachmentCount: 1,
        target: nested
      )
    )
  }

  func testAutosaveIdentityIncludesAttachmentOrderAndWatermark() {
    let first = replyComposerAttachment(1)
    let second = replyComposerAttachment(2)
    let baseline = ReplyComposerAutosaveTaskID(
      text: "正文",
      attachments: [first, second],
      imageWatermark: .forumName,
      shouldSave: true
    )

    XCTAssertEqual(
      baseline,
      ReplyComposerAutosaveTaskID(
        text: "正文",
        attachments: [first, second],
        imageWatermark: .forumName,
        shouldSave: true
      )
    )
    XCTAssertNotEqual(
      baseline,
      ReplyComposerAutosaveTaskID(
        text: "正文",
        attachments: [second, first],
        imageWatermark: .forumName,
        shouldSave: true
      )
    )
    XCTAssertNotEqual(
      baseline,
      ReplyComposerAutosaveTaskID(
        text: "正文",
        attachments: [first, second],
        imageWatermark: .none,
        shouldSave: true
      )
    )
  }

  func testContentAdmissionAllowsImageOnlyAndReservesMarkerBudget() throws {
    let direct = try replyImageTarget(.thread(firstPostID: 100))

    XCTAssertTrue(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: "",
        attachmentCount: 1,
        target: direct
      )
    )
    XCTAssertFalse(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: "",
        attachmentCount: 0,
        target: direct
      )
    )
    XCTAssertFalse(
      ReplyComposerContentAdmissionPolicy.accepts(
        content: String(repeating: "a", count: TextReplyContentPolicy.maximumCharacterCount),
        attachmentCount: 1,
        target: direct
      )
    )
  }

  func testRecoveryPresentationExposesOnlySafeExplicitActions() throws {
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: replyComposerUUID(10),
        sessionRevision: replyComposerUUID(11)
      )
    )
    let upload = TextReplyComposerPresentation(
      state: .imageRecovery(
        .uploadResumeRequired(
          reference: reference,
          successfulUploadCount: 0,
          totalAttachmentCount: 2
        )
      )
    )
    let publication = TextReplyComposerPresentation(
      state: .imageRecovery(.finalSubmissionResumeRequired(reference: reference))
    )

    XCTAssertEqual(upload.imageRecoveryAction, .continueUpload)
    XCTAssertEqual(upload.imageRecoveryAction?.title, "继续上传")
    XCTAssertEqual(publication.imageRecoveryAction, .continuePublication)
    XCTAssertEqual(publication.imageRecoveryAction?.title, "继续发布")
    for presentation in [upload, publication] {
      XCTAssertFalse(presentation.allowsEditing)
      XCTAssertFalse(presentation.allowsSubmission)
      XCTAssertFalse(presentation.allowsVisibilityCheck)
    }

    let blockedStates: [TextReplySubmissionState] = [
      .imageRecovery(
        .locked(
          reference: reference,
          operation: .attachment(attachmentID: replyComposerUUID(13))
        )
      ),
      .imageRecovery(
        .locked(reference: reference, operation: .finalSubmission)
      ),
      .imageRecovery(.completed(reference: reference)),
      .imageRecoveryUnavailable,
    ]
    for state in blockedStates {
      let presentation = TextReplyComposerPresentation(state: state)
      XCTAssertNil(presentation.imageRecoveryAction)
      XCTAssertFalse(presentation.allowsEditing)
      XCTAssertFalse(presentation.allowsSubmission)
      XCTAssertFalse(presentation.allowsVisibilityCheck)
      XCTAssertNotNil(presentation.status)
    }
  }

  func testConfirmationInvalidatesOnAttachmentOrWatermarkChange() throws {
    let target = try replyImageTarget(.thread(firstPostID: 100))
    let first = replyComposerAttachment(3)
    let second = replyComposerAttachment(4)
    let snapshot = try XCTUnwrap(
      SubmissionConfirmationPolicy.textReplySnapshot(
        id: replyComposerUUID(12),
        target: target,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )

    XCTAssertTrue(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "图片回复",
        attachments: [second, first],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .forumName,
        submissionAllowed: true
      )
    )
  }
}

private func replyImageTarget(
  _ destination: TextReplyTarget.Destination
) throws -> TextReplyTarget {
  try XCTUnwrap(
    TextReplyTarget(
      forumID: 7,
      forumName: "swift",
      threadID: 70,
      firstPostID: 100,
      destination: destination
    )
  )
}

private func replyComposerUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func replyComposerAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: replyComposerUUID(value),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(1_000 + Int(value)),
    pixelWidth: 100,
    pixelHeight: 80,
    quality: .standard
  )!
}
