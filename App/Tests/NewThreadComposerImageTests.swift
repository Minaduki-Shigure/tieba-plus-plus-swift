import Foundation
import XCTest

@testable import TiebaPlusPlus

final class NewThreadComposerImageTests: XCTestCase {
  func testComposerUsesCurrentDefaultWhenThereIsNoImageDraft() {
    XCTAssertEqual(
      ComposerImageWatermarkPolicy.initialValue(
        preference: .none,
        hasImageDraft: false,
        draftWatermark: .username
      ),
      .none
    )
    XCTAssertEqual(
      ComposerImageWatermarkPolicy.initialValue(
        preference: .forumName,
        hasImageDraft: false,
        draftWatermark: nil
      ),
      .forumName
    )
  }

  func testAutosaveIdentityIncludesAttachmentOrderAndWatermark() {
    let first = composerImageAttachment(1)
    let second = composerImageAttachment(2)
    let baseline = NewThreadComposerAutosaveTaskID(
      title: "标题",
      content: "正文",
      attachments: [first, second],
      imageWatermark: .forumName,
      shouldSave: true
    )

    XCTAssertEqual(
      baseline,
      NewThreadComposerAutosaveTaskID(
        title: "标题",
        content: "正文",
        attachments: [first, second],
        imageWatermark: .forumName,
        shouldSave: true
      )
    )
    XCTAssertNotEqual(
      baseline,
      NewThreadComposerAutosaveTaskID(
        title: "标题",
        content: "正文",
        attachments: [second, first],
        imageWatermark: .forumName,
        shouldSave: true
      )
    )
    XCTAssertNotEqual(
      baseline,
      NewThreadComposerAutosaveTaskID(
        title: "标题",
        content: "正文",
        attachments: [first, second],
        imageWatermark: .username,
        shouldSave: true
      )
    )
  }

  func testRecoverableImageStatesExposeOnlyTheirExplicitAction() throws {
    let reference = try imageSubmissionReference()
    let upload = NewThreadComposerPresentation(
      state: .imageRecovery(
        .uploadResumeRequired(
          reference: reference,
          successfulUploadCount: 1,
          totalAttachmentCount: 3
        )
      )
    )
    let publication = NewThreadComposerPresentation(
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
  }

  func testLockedAndUnavailableImageRecoveryNeverOfferNetworkAction() throws {
    let reference = try imageSubmissionReference()
    let states: [NewThreadSubmissionState] = [
      .imageRecovery(
        .locked(
          reference: reference,
          operation: .attachment(attachmentID: composerImageUUID(3))
        )
      ),
      .imageRecovery(
        .locked(reference: reference, operation: .finalSubmission)
      ),
      .imageRecovery(.completed(reference: reference)),
      .imageRecoveryUnavailable,
    ]

    for state in states {
      let presentation = NewThreadComposerPresentation(state: state)
      XCTAssertNil(presentation.imageRecoveryAction)
      XCTAssertFalse(presentation.allowsEditing)
      XCTAssertFalse(presentation.allowsSubmission)
      XCTAssertFalse(presentation.allowsVisibilityCheck)
      XCTAssertNotNil(presentation.status)
    }
  }

  func testContentAdmissionAllowsImageOnlyAndReservesMarkerBudget() {
    XCTAssertTrue(
      NewThreadComposerContentAdmissionPolicy.accepts(content: "", attachmentCount: 1)
    )
    XCTAssertFalse(
      NewThreadComposerContentAdmissionPolicy.accepts(content: "", attachmentCount: 0)
    )
    XCTAssertFalse(
      NewThreadComposerContentAdmissionPolicy.accepts(content: " \n\t ", attachmentCount: 1)
    )
    XCTAssertFalse(
      NewThreadComposerContentAdmissionPolicy.accepts(
        content: String(repeating: "a", count: NewThreadContentPolicy.maximumCharacterCount),
        attachmentCount: 1
      )
    )
    XCTAssertFalse(
      NewThreadComposerContentAdmissionPolicy.accepts(content: "正文", attachmentCount: 10)
    )
  }

  func testConfirmationSnapshotInvalidatesOnAttachmentOrWatermarkChange() throws {
    let target = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    let first = composerImageAttachment(4)
    let second = composerImageAttachment(5)
    let snapshot = try XCTUnwrap(
      SubmissionConfirmationPolicy.newThreadSnapshot(
        id: composerImageUUID(6),
        target: target,
        title: "图片主题",
        content: "正文",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )

    XCTAssertTrue(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: "图片主题",
        content: "正文",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: "图片主题",
        content: "正文",
        attachments: [second, first],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: "图片主题",
        content: "正文",
        attachments: [first, second],
        imageWatermark: .none,
        submissionAllowed: true
      )
    )
  }
}

private func imageSubmissionReference() throws -> ComposerImageSubmissionReference {
  try XCTUnwrap(
    ComposerImageSubmissionReference(
      submissionID: composerImageUUID(20),
      sessionRevision: composerImageUUID(21)
    )
  )
}

private func composerImageUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func composerImageAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: composerImageUUID(value),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(1_000 + Int(value)),
    pixelWidth: 100,
    pixelHeight: 80,
    quality: .standard
  )!
}
