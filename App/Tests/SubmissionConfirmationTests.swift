import XCTest

@testable import TiebaPlusPlus

final class SubmissionConfirmationTests: XCTestCase {
  func testEntryRiskNoticePresentsOnceWhenEnabled() {
    var gate = ComposerEntryRiskNoticeGate()

    XCTAssertFalse(gate.isPresented)
    XCTAssertFalse(gate.isResolved)
    XCTAssertTrue(gate.composerBecameReady(showsNotice: true))
    XCTAssertTrue(gate.isPresented)
    XCTAssertFalse(gate.composerBecameReady(showsNotice: true))

    gate.resolve()
    XCTAssertFalse(gate.isPresented)
    XCTAssertTrue(gate.isResolved)
    XCTAssertFalse(gate.composerBecameReady(showsNotice: true))
  }

  func testDisabledEntryRiskNoticeResolvesWithoutPresenting() {
    var gate = ComposerEntryRiskNoticeGate()

    XCTAssertFalse(gate.composerBecameReady(showsNotice: false))
    XCTAssertFalse(gate.isPresented)
    XCTAssertTrue(gate.isResolved)
  }

  func testImplicitEntryRiskNoticeDismissalWaitsForButtonActionResolution() {
    var gate = ComposerEntryRiskNoticeGate()
    gate.composerBecameReady(showsNotice: true)

    gate.beginImplicitDismissal()
    XCTAssertFalse(gate.isPresented)
    XCTAssertTrue(gate.implicitDismissalIsPending)
    XCTAssertFalse(gate.isResolved)

    gate.resolve()
    XCTAssertFalse(gate.implicitDismissalIsPending)
    XCTAssertTrue(gate.isResolved)
  }

  func testExternalHandoffResolvesOnlyAPresentedEntryNotice() {
    var gate = ComposerEntryRiskNoticeGate()

    XCTAssertFalse(gate.resolveForExternalHandoff())
    XCTAssertTrue(gate.composerBecameReady(showsNotice: true))
    XCTAssertTrue(gate.resolveForExternalHandoff())
    XCTAssertTrue(gate.isResolved)
    XCTAssertFalse(gate.resolveForExternalHandoff())
    gate.beginImplicitDismissal()
    XCTAssertFalse(gate.implicitDismissalIsPending)
    XCTAssertTrue(gate.isResolved)
  }

  func testExternalHandoffClaimsSetterFirstImplicitDismissal() {
    var gate = ComposerEntryRiskNoticeGate()
    XCTAssertTrue(gate.composerBecameReady(showsNotice: true))

    gate.beginImplicitDismissal()

    XCTAssertTrue(gate.implicitDismissalIsPending)
    XCTAssertTrue(gate.resolveForExternalHandoff())
    XCTAssertTrue(gate.isResolved)
    XCTAssertFalse(gate.implicitDismissalIsPending)
  }

  func testEntryNoticeCopyDoesNotReplaceFinalConfirmationCopy() {
    XCTAssertEqual(ComposerEntryRiskNoticeCopy.standard.continueTitle, "继续编辑")
    XCTAssertEqual(ComposerEntryRiskNoticeCopy.standard.leaveTitle, "返回")
    XCTAssertEqual(
      OfficialTiebaReplyHandoffCopy.actionTitle,
      "尝试使用官方客户端回帖"
    )
    XCTAssertFalse(OfficialTiebaReplyHandoffCopy.unavailableMessage.isEmpty)
    XCTAssertEqual(SubmissionConfirmationCopy.reply.actionTitle, "发送")
    XCTAssertEqual(SubmissionConfirmationCopy.newThread.actionTitle, "发布")
    XCTAssertNotEqual(
      ComposerEntryRiskNoticeCopy.standard.title,
      SubmissionConfirmationCopy.reply.title
    )
  }

  func testConfirmationPreparationCannotOverlapOrBeFinishedByAStaleTask() {
    let first = confirmationUUID(11)
    let second = confirmationUUID(12)
    let lifecycle = confirmationUUID(13)
    var gate = SubmissionConfirmationPreparationGate()

    XCTAssertEqual(gate.begin(lifecycleID: lifecycle, id: first), first)
    XCTAssertTrue(gate.isPreparing)
    XCTAssertNil(gate.begin(lifecycleID: lifecycle, id: second))
    XCTAssertFalse(gate.finish(second))
    XCTAssertTrue(gate.isCurrent(first, lifecycleID: lifecycle))
    XCTAssertTrue(gate.finish(first))
    XCTAssertFalse(gate.isPreparing)

    XCTAssertEqual(gate.begin(lifecycleID: lifecycle, id: second), second)
    XCTAssertFalse(gate.finish(first))
    XCTAssertTrue(gate.isCurrent(second, lifecycleID: lifecycle))
    gate.cancel()
    XCTAssertFalse(gate.isPreparing)
  }

  func testConfirmationPreparationCannotCrossAComposerLifecycle() throws {
    let preparationID = confirmationUUID(21)
    var lifecycleGate = ReplyComposerLifecycleGate()
    let originalLifecycle = lifecycleGate.beginAppearance()
    var preparationGate = SubmissionConfirmationPreparationGate()
    XCTAssertEqual(
      preparationGate.begin(
        lifecycleID: originalLifecycle,
        id: preparationID
      ),
      preparationID
    )

    XCTAssertNotNil(lifecycleGate.scheduleDeactivation())
    let replacementLifecycle = lifecycleGate.beginAppearance()

    XCTAssertNotEqual(replacementLifecycle, originalLifecycle)
    XCTAssertFalse(lifecycleGate.isCurrent(originalLifecycle))
    XCTAssertFalse(
      preparationGate.isCurrent(
        preparationID,
        lifecycleID: replacementLifecycle
      )
    )
    XCTAssertTrue(preparationGate.finish(preparationID))
  }

  func testReplySnapshotFreezesTargetContentAndIdentifier() throws {
    let target = try replyConfirmationTarget()
    let id = confirmationUUID(1)
    let snapshot = try XCTUnwrap(
      SubmissionConfirmationPolicy.textReplySnapshot(
        id: id,
        target: target,
        content: "原始回复",
        submissionAllowed: true
      )
    )

    XCTAssertEqual(snapshot.id, id)
    XCTAssertEqual(snapshot.target, target)
    XCTAssertEqual(snapshot.content, "原始回复")
    XCTAssertTrue(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "原始回复",
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "已编辑回复",
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        snapshot,
        target: target,
        content: "原始回复",
        submissionAllowed: false
      )
    )
    XCTAssertNil(
      SubmissionConfirmationPolicy.textReplySnapshot(
        target: target,
        content: "原始回复",
        submissionAllowed: false
      )
    )
  }

  func testReplyAndNewThreadSnapshotsTreatCanonicalUnicodeByteChangesAsEdits() throws {
    let decomposed = "e\u{301}"
    let precomposed = "\u{E9}"
    XCTAssertEqual(decomposed, precomposed)

    let replyTarget = try replyConfirmationTarget()
    let reply = try XCTUnwrap(
      SubmissionConfirmationPolicy.textReplySnapshot(
        target: replyTarget,
        content: decomposed,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        reply,
        target: replyTarget,
        content: precomposed,
        submissionAllowed: true
      )
    )

    let threadTarget = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    let thread = try XCTUnwrap(
      SubmissionConfirmationPolicy.newThreadSnapshot(
        target: threadTarget,
        title: nil,
        content: decomposed,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        thread,
        target: threadTarget,
        title: nil,
        content: precomposed,
        submissionAllowed: true
      )
    )
  }

  func testNewThreadSnapshotNormalizesTitleAndRejectsChanges() throws {
    let target = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    let snapshot = try XCTUnwrap(
      SubmissionConfirmationPolicy.newThreadSnapshot(
        id: confirmationUUID(2),
        target: target,
        title: "  原始标题  ",
        content: "原始正文",
        submissionAllowed: true
      )
    )

    XCTAssertEqual(snapshot.title, "原始标题")
    XCTAssertTrue(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: " 原始标题 ",
        content: "原始正文",
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: "其他标题",
        content: "原始正文",
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        snapshot,
        target: target,
        title: "原始标题",
        content: "其他正文",
        submissionAllowed: true
      )
    )
  }

  func testImageSnapshotsFreezeAttachmentOrderAndWatermark() throws {
    let first = confirmationAttachment(31)
    let second = confirmationAttachment(32)
    let replyTarget = try replyConfirmationTarget()
    let reply = try XCTUnwrap(
      SubmissionConfirmationPolicy.textReplySnapshot(
        target: replyTarget,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertTrue(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        reply,
        target: replyTarget,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        reply,
        target: replyTarget,
        content: "图片回复",
        attachments: [second, first],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        reply,
        target: replyTarget,
        content: "图片回复",
        attachments: [first, second],
        imageWatermark: .none,
        submissionAllowed: true
      )
    )

    let threadTarget = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    let thread = try XCTUnwrap(
      SubmissionConfirmationPolicy.newThreadSnapshot(
        target: threadTarget,
        title: "标题",
        content: "图片主题",
        attachments: [first, second],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        thread,
        target: threadTarget,
        title: "标题",
        content: "图片主题",
        attachments: [first],
        imageWatermark: .username,
        submissionAllowed: true
      )
    )
    XCTAssertFalse(
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        thread,
        target: threadTarget,
        title: "标题",
        content: "图片主题",
        attachments: [first, second],
        imageWatermark: .forumName,
        submissionAllowed: true
      )
    )
  }

  func testPendingSnapshotCannotBeReplacedAndIsConsumedOnceByExactIdentifier() throws {
    let target = try replyConfirmationTarget()
    let current = try XCTUnwrap(
      TextReplySubmission(
        id: confirmationUUID(3),
        target: target,
        content: "相同内容"
      )
    )
    let stale = try XCTUnwrap(
      TextReplySubmission(
        id: confirmationUUID(4),
        target: target,
        content: "相同内容"
      )
    )
    var pending: TextReplySubmission?

    XCTAssertTrue(SubmissionConfirmationPolicy.present(current, pending: &pending))
    XCTAssertFalse(SubmissionConfirmationPolicy.present(stale, pending: &pending))
    XCTAssertEqual(pending, current)
    XCTAssertNil(SubmissionConfirmationPolicy.consume(stale, pending: &pending))
    XCTAssertEqual(pending, current)
    XCTAssertEqual(
      SubmissionConfirmationPolicy.consume(current, pending: &pending),
      current
    )
    XCTAssertNil(pending)
    XCTAssertNil(SubmissionConfirmationPolicy.consume(current, pending: &pending))
  }
}

private func replyConfirmationTarget() throws -> TextReplyTarget {
  try XCTUnwrap(
    TextReplyTarget(
      forumID: 7,
      forumName: "swift",
      threadID: 70,
      firstPostID: 700,
      destination: .thread(firstPostID: 700)
    )
  )
}

private func confirmationUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func confirmationAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: confirmationUUID(value),
    sha256: String(repeating: String(value % 10), count: 64),
    byteCount: 1,
    pixelWidth: 1,
    pixelHeight: 1,
    quality: .standard
  )!
}
