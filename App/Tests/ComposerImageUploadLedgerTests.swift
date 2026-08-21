import CryptoKit
import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ComposerImageUploadLedgerTests: XCTestCase {
  private let authenticator = ComposerImageUploadLedgerHMACAuthenticator(
    testingKey: Data(repeating: 0x5A, count: 32)
  )

  func testContextFactoriesAcceptOnlyNewThreadAndDirectTopicReplyTargets() throws {
    let newThreadTarget = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    XCTAssertEqual(
      ComposerImageUploadContext(newThread: newThreadTarget),
      .newThread(forumID: 7, forumName: "swift")
    )
    let direct = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 700,
        firstPostID: 701,
        destination: .thread(firstPostID: 701)
      )
    )
    XCTAssertEqual(
      ComposerImageUploadContext(directTopicReply: direct),
      .directTopicReply(
        forumID: 7,
        forumName: "swift",
        threadID: 700,
        firstPostID: 701
      )
    )
    let floorReply = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 700,
        firstPostID: 701,
        destination: .post(postID: 702)
      )
    )
    XCTAssertNil(ComposerImageUploadContext(directTopicReply: floorReply))
    XCTAssertNil(
      ComposerImageUploadLedgerKey(
        context: .newThread(forumID: 7, forumName: " swift "),
        userID: 1001,
        sessionRevision: fixedUUID(100),
        submissionID: fixedUUID(101)
      )
    )
    XCTAssertNil(
      ComposerImageUploadLedgerKey(
        context: .directTopicReply(
          forumID: 7,
          forumName: "swift",
          threadID: 0,
          firstPostID: 701
        ),
        userID: 1001,
        sessionRevision: fixedUUID(100),
        submissionID: fixedUUID(101)
      )
    )
  }

  func testNewThreadIntentFreezesEverySubmissionAndAttachmentFieldAcrossRestart() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2, preservesOriginal: true, watermark: .username)
    let snapshots = [first.snapshot, second.snapshot]
    let submission = try makeNewThreadSubmission(
      key: key,
      title: "Exact title",
      content: "Exact body",
      attachments: snapshots
    )
    let ledger = makeLedger(fileURL: location.file)
    let record = try await ledger.prepare(
      newThreadSubmission: submission,
      key: key,
      attachmentSnapshots: snapshots
    )
    XCTAssertTrue(
      record.matchesIntent(
        newThreadSubmission: submission,
        key: key,
        attachmentSnapshots: snapshots
      )
    )

    let changedBody = try makeNewThreadSubmission(
      key: key,
      title: submission.title,
      content: "Changed body",
      attachments: snapshots
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: changedBody,
        key: key,
        attachmentSnapshots: snapshots
      )
    )
    let changedTitle = try makeNewThreadSubmission(
      key: key,
      title: "Changed title",
      content: submission.content,
      attachments: snapshots
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: changedTitle,
        key: key,
        attachmentSnapshots: snapshots
      )
    )
    let reordered = [second.snapshot, first.snapshot]
    let reorderedSubmission = try makeNewThreadSubmission(
      key: key,
      title: submission.title,
      content: submission.content,
      attachments: reordered
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: reorderedSubmission,
        key: key,
        attachmentSnapshots: reordered
      )
    )
    let changedWatermark = [
      try XCTUnwrap(
        ComposerImageUploadAttachmentSnapshot(
          attachment: first.attachment,
          watermark: .none
        )
      ),
      second.snapshot,
    ]
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: submission,
        key: key,
        attachmentSnapshots: changedWatermark
      )
    )
    let qualityChangedAttachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: first.attachment.id,
        relativePrivateFilename: first.attachment.relativePrivateFilename,
        sha256: first.attachment.sha256,
        byteCount: first.attachment.byteCount,
        pixelWidth: first.attachment.pixelWidth,
        pixelHeight: first.attachment.pixelHeight,
        encoding: first.attachment.encoding,
        quality: .highQuality
      )
    )
    let qualityChangedSnapshot = try XCTUnwrap(
      ComposerImageUploadAttachmentSnapshot(
        attachment: qualityChangedAttachment,
        watermark: first.snapshot.watermark
      )
    )
    let qualityChangedSnapshots = [qualityChangedSnapshot, second.snapshot]
    let qualityChangedSubmission = try makeNewThreadSubmission(
      key: key,
      title: submission.title,
      content: submission.content,
      attachments: qualityChangedSnapshots
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: qualityChangedSubmission,
        key: key,
        attachmentSnapshots: qualityChangedSnapshots
      )
    )
    let changedSessionKey = try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: key.context,
        userID: key.userID,
        sessionRevision: fixedUUID(999),
        submissionID: key.submissionID
      )
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: submission,
        key: changedSessionKey,
        attachmentSnapshots: snapshots
      )
    )
    let changedTargetKey = try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: .newThread(forumID: 8, forumName: "other"),
        userID: key.userID,
        sessionRevision: key.sessionRevision,
        submissionID: key.submissionID
      )
    )
    let changedTargetSubmission = try makeNewThreadSubmission(
      key: changedTargetKey,
      title: submission.title,
      content: submission.content,
      attachments: snapshots
    )
    XCTAssertFalse(
      record.matchesIntent(
        newThreadSubmission: changedTargetSubmission,
        key: changedTargetKey,
        attachmentSnapshots: snapshots
      )
    )

    let loadedAfterRestart = try await makeLedger(fileURL: location.file).record(for: key)
    let restartedRecord = try XCTUnwrap(loadedAfterRestart)
    XCTAssertTrue(
      restartedRecord.matchesIntent(
        newThreadSubmission: submission,
        key: key,
        attachmentSnapshots: snapshots
      )
    )
    XCTAssertEqual(record.intentDigest.description, "ComposerImageUploadIntentDigest(redacted)")
    XCTAssertFalse(record.description.contains(submission.content))
    XCTAssertFalse(record.intentDigest.description.contains(submission.content))
    let encodedArchiveText = String(
      decoding: try Data(contentsOf: location.file),
      as: UTF8.self
    )
    XCTAssertFalse(encodedArchiveText.contains("Exact title"))
    XCTAssertFalse(encodedArchiveText.contains("Exact body"))
  }

  func testTitlePresenceIsUnambiguousAndDirectReplyIntentFreezesBody() async throws {
    let key = makeKey()
    let image = try fixture(index: 1)
    let withoutTitle = try XCTUnwrap(
      ComposerImageUploadIntentDigest.newThread(
        key: key,
        title: nil,
        content: "body",
        attachmentSnapshots: [image.snapshot]
      )
    )
    let emptyTitle = try XCTUnwrap(
      ComposerImageUploadIntentDigest.newThread(
        key: key,
        title: "",
        content: "body",
        attachmentSnapshots: [image.snapshot]
      )
    )
    XCTAssertNotEqual(withoutTitle, emptyTitle)
    XCTAssertNotEqual(
      try XCTUnwrap(
        ComposerImageUploadIntentDigest.newThread(
          key: key,
          title: "a",
          content: "bc",
          attachmentSnapshots: [image.snapshot]
        )
      ),
      try XCTUnwrap(
        ComposerImageUploadIntentDigest.newThread(
          key: key,
          title: "ab",
          content: "c",
          attachmentSnapshots: [image.snapshot]
        )
      )
    )

    let replyKey = makeDirectTopicReplyKey()
    let reply = try makeDirectTopicReplySubmission(
      key: replyKey,
      content: "reply body",
      attachments: [image.snapshot]
    )
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = makeLedger(fileURL: location.file)
    let record = try await ledger.prepare(
      directTopicReplySubmission: reply,
      key: replyKey,
      attachmentSnapshots: [image.snapshot]
    )
    let changed = try makeDirectTopicReplySubmission(
      key: replyKey,
      content: "changed reply body",
      attachments: [image.snapshot]
    )
    XCTAssertFalse(
      record.matchesIntent(
        directTopicReplySubmission: changed,
        key: replyKey,
        attachmentSnapshots: [image.snapshot]
      )
    )
    let loadedAfterRestart = try await makeLedger(fileURL: location.file).record(for: replyKey)
    let restarted = try XCTUnwrap(loadedAfterRestart)
    XCTAssertTrue(
      restarted.matchesIntent(
        directTopicReplySubmission: reply,
        key: replyKey,
        attachmentSnapshots: [image.snapshot]
      )
    )
  }

  func testIntentDigestChangesForEveryRepresentableAttachmentMetadataField() throws {
    let key = makeKey()
    let image = try fixture(index: 1)
    let baseline = try XCTUnwrap(
      ComposerImageUploadIntentDigest.newThread(
        key: key,
        title: "title",
        content: "body",
        attachmentSnapshots: [image.snapshot]
      )
    )

    let variants: [ComposerImageUploadAttachmentSnapshot] = try [
      snapshotReplacing(image.attachment, id: fixedUUID(501)),
      snapshotReplacing(image.attachment, sha256: String(repeating: "a", count: 64)),
      snapshotReplacing(image.attachment, byteCount: image.attachment.byteCount + 1),
      snapshotReplacing(image.attachment, pixelWidth: image.attachment.pixelWidth + 1),
      snapshotReplacing(image.attachment, pixelHeight: image.attachment.pixelHeight + 1),
      snapshotReplacing(image.attachment, quality: .highQuality),
      try XCTUnwrap(
        ComposerImageUploadAttachmentSnapshot(
          attachment: image.attachment,
          watermark: .none
        )
      ),
    ]
    for variant in variants {
      XCTAssertNotEqual(
        baseline,
        try XCTUnwrap(
          ComposerImageUploadIntentDigest.newThread(
            key: key,
            title: "title",
            content: "body",
            attachmentSnapshots: [variant]
          )
        )
      )
    }

    let keyVariants = try [
      ledgerKey(
        context: key.context,
        userID: key.userID + 1,
        sessionRevision: key.sessionRevision,
        submissionID: key.submissionID
      ),
      ledgerKey(
        context: key.context,
        userID: key.userID,
        sessionRevision: fixedUUID(502),
        submissionID: key.submissionID
      ),
      ledgerKey(
        context: key.context,
        userID: key.userID,
        sessionRevision: key.sessionRevision,
        submissionID: fixedUUID(503)
      ),
      ledgerKey(
        context: .newThread(forumID: 8, forumName: "swift"),
        userID: key.userID,
        sessionRevision: key.sessionRevision,
        submissionID: key.submissionID
      ),
      ledgerKey(
        context: .newThread(forumID: 7, forumName: "swiftlang"),
        userID: key.userID,
        sessionRevision: key.sessionRevision,
        submissionID: key.submissionID
      ),
    ]
    for variant in keyVariants {
      XCTAssertNotEqual(
        baseline,
        try XCTUnwrap(
          ComposerImageUploadIntentDigest.newThread(
            key: variant,
            title: "title",
            content: "body",
            attachmentSnapshots: [image.snapshot]
          )
        )
      )
    }
  }

  func testSameSubmissionIDCannotPrepareChangedIntentAndDoesNotOverwrite() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      content: "original",
      attachments: [image.snapshot]
    )
    let originalArchive = try Data(contentsOf: location.file)
    let changed = try makeNewThreadSubmission(
      key: key,
      content: "changed",
      attachments: [image.snapshot]
    )
    await assertLedgerError(.intentMismatch) {
      try await ledger.prepare(
        newThreadSubmission: changed,
        key: key,
        attachmentSnapshots: [image.snapshot]
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), originalArchive)
  }

  func testPreservesOriginalIsDerivedOnlyFromQuality() throws {
    let standard = try fixture(index: 1, preservesOriginal: false)
    let highQuality = try fixture(index: 2, preservesOriginal: true)
    XCTAssertFalse(standard.snapshot.preservesOriginal)
    XCTAssertTrue(highQuality.snapshot.preservesOriginal)

    var encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(standard.snapshot)
      ) as? [String: Any]
    )
    encoded["preservesOriginal"] = true
    let injected = try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        ComposerImageUploadAttachmentSnapshot.self,
        from: injected
      )
    )
  }

  func testNewThreadAndDirectTopicReplyContextsRoundTripWithoutLosingOrder() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = makeLedger(fileURL: location.file)
    let first = try fixture(index: 1)
    let second = try fixture(index: 2, preservesOriginal: true, watermark: .username)
    let newThreadKey = try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: .newThread(forumID: 7, forumName: "swift"),
        userID: 1001,
        sessionRevision: fixedUUID(100),
        submissionID: fixedUUID(101)
      )
    )
    let replyContext = ComposerImageUploadContext.directTopicReply(
      forumID: 7,
      forumName: "swift",
      threadID: 700,
      firstPostID: 701
    )
    let replyKey = try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: replyContext,
        userID: 1001,
        sessionRevision: fixedUUID(100),
        submissionID: fixedUUID(102)
      )
    )

    let newThreadSubmission = try makeNewThreadSubmission(
      key: newThreadKey,
      attachments: [first.snapshot, second.snapshot]
    )
    let prepared = try await ledger.prepare(
      newThreadSubmission: newThreadSubmission,
      key: newThreadKey,
      attachmentSnapshots: [first.snapshot, second.snapshot]
    )
    XCTAssertEqual(prepared.attachments.map(\.id), [first.attachment.id, second.attachment.id])
    XCTAssertEqual(prepared.nextAttachment?.id, first.attachment.id)
    XCTAssertEqual(prepared.stage, .prepared)
    XCTAssertFalse(prepared.blocksAutomaticResend)
    let replySubmission = try makeDirectTopicReplySubmission(
      key: replyKey,
      attachments: [second.snapshot]
    )
    _ = try await ledger.prepare(
      directTopicReplySubmission: replySubmission,
      key: replyKey,
      attachmentSnapshots: [second.snapshot]
    )

    let reopened = makeLedger(fileURL: location.file)
    let loaded = try await reopened.load()
    XCTAssertEqual(Set(loaded.map(\.key)), Set([newThreadKey, replyKey]))
    let loadedReply = try await reopened.record(
      for: replyContext,
      userID: replyKey.userID,
      sessionRevision: replyKey.sessionRevision,
      submissionID: replyKey.submissionID
    )
    XCTAssertEqual(loadedReply?.key, replyKey)
    XCTAssertTrue(
      try XCTUnwrap(loadedReply).matchesIntent(
        directTopicReplySubmission: replySubmission,
        key: replyKey,
        attachmentSnapshots: [second.snapshot]
      )
    )
  }

  func testDispatchAndFinalPendingStagesSurviveRestartAndBlockAutomaticResend() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2, preservesOriginal: true)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [first.snapshot, second.snapshot]
    )

    let dispatchPending = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: first.attachment.id
    )
    XCTAssertEqual(
      dispatchPending.stage,
      .attachmentDispatchPending(nextAttachmentID: first.attachment.id)
    )
    XCTAssertTrue(dispatchPending.blocksAutomaticResend)
    let firstRestart = makeLedger(fileURL: location.file)
    let firstRecoveredStage = try await firstRestart.record(for: key)?.stage
    XCTAssertEqual(
      firstRecoveredStage,
      .attachmentDispatchPending(nextAttachmentID: first.attachment.id)
    )

    let firstRecorded = try await firstRestart.recordBoundReceipt(
      first.receipt,
      verifiedAgainst: first.upload,
      for: key
    )
    XCTAssertEqual(firstRecorded.successfulReceiptPrefix, [first.receipt])
    XCTAssertEqual(firstRecorded.nextAttachment?.id, second.attachment.id)
    XCTAssertEqual(firstRecorded.stage, .prepared)
    _ = try await firstRestart.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: second.attachment.id
    )
    let completed = try await firstRestart.recordBoundReceipt(
      second.receipt,
      verifiedAgainst: second.upload,
      for: key
    )
    XCTAssertEqual(completed.successfulReceiptPrefix, [first.receipt, second.receipt])
    XCTAssertNil(completed.nextAttachment)
    XCTAssertEqual(completed.stage, .uploadsComplete)

    let finalPending = try await firstRestart.markFinalSubmissionPending(for: key)
    XCTAssertEqual(finalPending.stage, .finalSubmissionPending)
    XCTAssertTrue(finalPending.blocksAutomaticResend)
    let secondRestart = makeLedger(fileURL: location.file)
    let recoveredRecord = try await secondRestart.record(for: key)
    let recovered = try XCTUnwrap(recoveredRecord)
    XCTAssertEqual(recovered.stage, .finalSubmissionPending)
    XCTAssertEqual(recovered.successfulReceiptPrefix, [first.receipt, second.receipt])
    XCTAssertTrue(recovered.blocksAutomaticResend)

    let unknown = try await secondRestart.markOutcomeUnknown(for: key)
    XCTAssertEqual(unknown.stage, .outcomeUnknown)
    XCTAssertEqual(unknown.outcomeUnknownOperation, .finalSubmission)
    XCTAssertTrue(unknown.blocksAutomaticResend)
    await assertLedgerError(.invalidTransition) {
      try await secondRestart.delete(for: key)
    }
    let retainedUnknown = try await secondRestart.load(for: key)
    XCTAssertEqual(retainedUnknown, unknown)
  }

  func testOnlyCompletedTerminalRecordCanBeDeleted() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: ledger, key: key, attachments: [image.snapshot])

    await assertLedgerError(.invalidTransition) {
      try await ledger.delete(for: key)
    }
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: image.attachment.id
    )
    _ = try await ledger.recordBoundReceipt(
      image.receipt,
      verifiedAgainst: image.upload,
      for: key
    )
    _ = try await ledger.markFinalSubmissionPending(for: key)
    let completed = try await ledger.markCompleted(for: key)

    XCTAssertEqual(completed.stage, .completed)
    XCTAssertTrue(completed.blocksAutomaticResend)
    XCTAssertNil(completed.outcomeUnknownOperation)
    let restartedCompleted = try await makeLedger(fileURL: location.file).record(for: key)
    XCTAssertEqual(restartedCompleted, completed)
    await assertLedgerError(.invalidTransition) {
      try await ledger.markCompleted(for: key)
    }
    await assertLedgerError(.invalidTransition) {
      try await ledger.markOutcomeUnknown(for: key)
    }

    try await ledger.delete(for: key)
    let deleted = try await ledger.load(for: key)
    XCTAssertNil(deleted)
  }

  func testAttachmentOutcomeUnknownRetainsExactUnsentPrefixAndNextAttachment() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: ledger, key: key, attachments: [image.snapshot])
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: image.attachment.id
    )

    let unknown = try await ledger.markOutcomeUnknown(for: key)
    XCTAssertEqual(unknown.stage, .outcomeUnknown)
    XCTAssertEqual(unknown.nextAttachment?.id, image.attachment.id)
    XCTAssertTrue(unknown.successfulReceiptPrefix.isEmpty)
    XCTAssertEqual(
      unknown.outcomeUnknownOperation,
      .attachment(attachmentID: image.attachment.id)
    )
    XCTAssertTrue(unknown.blocksAutomaticResend)
    let reopened = makeLedger(fileURL: location.file)
    let recovered = try await reopened.record(for: key)
    XCTAssertEqual(recovered, unknown)
  }

  func testPrepareRejectsEmptyTooManyAndDuplicateAttachmentsWithoutCreatingArchive() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = makeLedger(fileURL: location.file)
    let key = makeKey()
    let one = try fixture(index: 1)

    await assertLedgerError(.invalidAttachments) {
      let submission = try self.makeNewThreadSubmission(key: key, attachments: [])
      return try await ledger.prepare(
        newThreadSubmission: submission,
        key: key,
        attachmentSnapshots: []
      )
    }
    await assertLedgerError(.invalidAttachments) {
      let snapshots = try (1...10).map { try self.fixture(index: $0).snapshot }
      let submission = try self.makeNewThreadSubmission(
        key: key,
        attachments: [snapshots[0]]
      )
      return try await ledger.prepare(
        newThreadSubmission: submission,
        key: key,
        attachmentSnapshots: snapshots
      )
    }
    await assertLedgerError(.invalidAttachments) {
      try await ledger.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [one.snapshot]
        ),
        key: key,
        attachmentSnapshots: [one.snapshot, one.snapshot]
      )
    }
    let duplicateDigestAttachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: fixedUUID(999),
        sha256: one.attachment.sha256,
        byteCount: one.attachment.byteCount,
        pixelWidth: one.attachment.pixelWidth,
        pixelHeight: one.attachment.pixelHeight,
        quality: one.attachment.quality
      )
    )
    let duplicateDigestSnapshot = try XCTUnwrap(
      ComposerImageUploadAttachmentSnapshot(attachment: duplicateDigestAttachment)
    )
    await assertLedgerError(.invalidAttachments) {
      try await ledger.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [one.snapshot]
        ),
        key: key,
        attachmentSnapshots: [one.snapshot, duplicateDigestSnapshot]
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
  }

  func testExactlyNineOrderedAttachmentsAreAccepted() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let attachments = try (1...9).map { try fixture(index: $0).snapshot }
    let ledger = makeLedger(fileURL: location.file)

    let key = makeKey()
    let record = try await prepareNewThread(in: ledger, key: key, attachments: attachments)
    XCTAssertEqual(record.attachments.map(\.id), attachments.map(\.id))
    XCTAssertEqual(record.nextAttachment?.id, attachments[0].id)
  }

  func testIdentityAndNextAttachmentMismatchesFailClosedWithoutChangingArchive() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [first.snapshot, second.snapshot]
    )
    let original = try Data(contentsOf: location.file)

    let wrongIdentity = try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: key.context,
        userID: key.userID + 1,
        sessionRevision: key.sessionRevision,
        submissionID: key.submissionID
      )
    )
    await assertLedgerError(.identityMismatch) {
      try await ledger.markAttachmentDispatchPending(
        for: wrongIdentity,
        nextAttachmentID: first.attachment.id
      )
    }
    await assertLedgerError(.unexpectedAttachment) {
      try await ledger.markAttachmentDispatchPending(
        for: key,
        nextAttachmentID: second.attachment.id
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
    let retainedStage = try await ledger.record(for: key)?.stage
    XCTAssertEqual(retainedStage, .prepared)
  }

  func testReceiptMustBeTheExactBoundPrefixMemberAndFailureDoesNotOverwrite() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [first.snapshot, second.snapshot]
    )
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: first.attachment.id
    )
    let original = try Data(contentsOf: location.file)

    await assertLedgerError(.invalidReceipt) {
      try await ledger.recordBoundReceipt(
        second.receipt,
        verifiedAgainst: second.upload,
        for: key
      )
    }
    let wrongBytesUpload = TiebaStaticImageUpload(
      uploadID: first.upload.uploadID,
      forumName: first.upload.forumName,
      encodedBytes: Data(repeating: 0xFF, count: first.upload.encodedBytes.count),
      pixelWidth: first.upload.pixelWidth,
      pixelHeight: first.upload.pixelHeight,
      preservesOriginal: first.upload.preservesOriginal,
      watermark: first.upload.watermark
    )
    await assertLedgerError(.invalidReceipt) {
      try await ledger.recordBoundReceipt(
        first.receipt,
        verifiedAgainst: wrongBytesUpload,
        for: key
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
    let retainedRecord = try await ledger.record(for: key)
    XCTAssertTrue(try XCTUnwrap(retainedRecord).successfulReceiptPrefix.isEmpty)
  }

  func testDuplicateReceiptPictureIDIsRejectedBeforeCompletionWithoutOverwrite() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2, pictureID: first.receipt.picID)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [first.snapshot, second.snapshot]
    )
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: first.attachment.id
    )
    _ = try await ledger.recordBoundReceipt(
      first.receipt,
      verifiedAgainst: first.upload,
      for: key
    )
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: second.attachment.id
    )
    let beforeRejectedReceipt = try Data(contentsOf: location.file)

    await assertLedgerError(.invalidReceipt) {
      try await ledger.recordBoundReceipt(
        second.receipt,
        verifiedAgainst: second.upload,
        for: key
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), beforeRejectedReceipt)
    let retainedRecord = try await ledger.record(for: key)
    let retained = try XCTUnwrap(retainedRecord)
    XCTAssertEqual(retained.successfulReceiptPrefix, [first.receipt])
    XCTAssertEqual(
      retained.stage,
      .attachmentDispatchPending(nextAttachmentID: second.attachment.id)
    )
  }

  func testInvalidStateTransitionsFailClosed() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: ledger, key: key, attachments: [image.snapshot])

    await assertLedgerError(.invalidTransition) {
      try await ledger.markFinalSubmissionPending(for: key)
    }
    await assertLedgerError(.invalidTransition) {
      try await ledger.markOutcomeUnknown(for: key)
    }
    await assertLedgerError(.invalidTransition) {
      try await ledger.recordBoundReceipt(
        image.receipt,
        verifiedAgainst: image.upload,
        for: key
      )
    }
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: image.attachment.id
    )
    await assertLedgerError(.invalidTransition) {
      try await ledger.markAttachmentDispatchPending(
        for: key,
        nextAttachmentID: image.attachment.id
      )
    }
  }

  func testConcurrentPreparePublishesExactlyOneRecord() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    let submission = try makeNewThreadSubmission(key: key, attachments: [image.snapshot])

    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for _ in 0..<24 {
        group.addTask {
          do {
            _ = try await ledger.prepare(
              newThreadSubmission: submission,
              key: key,
              attachmentSnapshots: [image.snapshot]
            )
            return true
          } catch {
            return false
          }
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }
    XCTAssertEqual(successes, 1)
    let records = try await ledger.load()
    let record = try await ledger.record(for: key)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(record?.key, key)
  }

  func testConcurrentIndependentPrepareRespectsRecordLimitWithoutCorruption() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file, maximumRecords: 8)
    let attempts = try (1...16).map { index in
      let key = makeKey(submissionIndex: 1_000 + index)
      return (
        key,
        try makeNewThreadSubmission(key: key, attachments: [image.snapshot])
      )
    }

    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for (key, submission) in attempts {
        group.addTask {
          do {
            _ = try await ledger.prepare(
              newThreadSubmission: submission,
              key: key,
              attachmentSnapshots: [image.snapshot]
            )
            return true
          } catch {
            return false
          }
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }
    XCTAssertEqual(successes, 8)
    let reopened = makeLedger(fileURL: location.file, maximumRecords: 8)
    let records = try await reopened.load()
    XCTAssertEqual(records.count, 8)
  }

  func testFailedStagedWritePreservesPreviouslyCommittedStage() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let initial = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: initial, key: key, attachments: [image.snapshot])
    let original = try Data(contentsOf: location.file)
    let failing = makeLedger(
      fileURL: location.file,
      prepareStagedFile: { _ in throw TestFailure.expected }
    )

    await assertLedgerError(.writeFailed) {
      try await failing.markAttachmentDispatchPending(
        for: key,
        nextAttachmentID: image.attachment.id
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
    let retainedStage = try await initial.record(for: key)?.stage
    XCTAssertEqual(retainedStage, .prepared)
  }

  func testStagedFileSyncFailureRejectsTransitionAndPreservesOldArchive() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let initial = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: initial, key: key, attachments: [image.snapshot])
    let original = try Data(contentsOf: location.file)
    let failing = makeLedger(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .stagedFile { throw TestFailure.expected }
      }
    )

    await assertLedgerError(.writeFailed) {
      try await failing.markAttachmentDispatchPending(
        for: key,
        nextAttachmentID: image.attachment.id
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
    let recovered = try await initial.record(for: key)
    XCTAssertEqual(recovered?.stage, .prepared)
  }

  func testDirectorySyncFailureReportsFailureEvenWhenNewArchiveWasPublished() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let initial = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: initial, key: key, attachments: [image.snapshot])
    let original = try Data(contentsOf: location.file)
    let failing = makeLedger(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .parentDirectory { throw TestFailure.expected }
      }
    )

    await assertLedgerError(.writeFailed) {
      try await failing.markAttachmentDispatchPending(
        for: key,
        nextAttachmentID: image.attachment.id
      )
    }
    XCTAssertNotEqual(try Data(contentsOf: location.file), original)
    let recovered = try await initial.record(for: key)
    XCTAssertEqual(
      recovered?.stage,
      .attachmentDispatchPending(nextAttachmentID: image.attachment.id)
    )
    XCTAssertTrue(try XCTUnwrap(recovered).blocksAutomaticResend)
  }

  func testTamperedMACFailsClosedAndMutationDoesNotOverwrite() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(in: ledger, key: key, attachments: [image.snapshot])

    var envelope = try readEnvelope(at: location.file)
    envelope.canonicalPayload[envelope.canonicalPayload.startIndex] ^= 0x01
    try writeEnvelope(envelope, to: location.file)
    let tampered = try Data(contentsOf: location.file)
    let reopened = makeLedger(fileURL: location.file)
    await assertLedgerError(.authenticationFailed) {
      try await reopened.load()
    }
    await assertLedgerError(.authenticationFailed) {
      let key = self.makeKey(submissionIndex: 2)
      try await reopened.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [image.snapshot]
        ),
        key: key,
        attachmentSnapshots: [image.snapshot]
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), tampered)
  }

  func testDifferentDeviceKeyCannotAuthenticateArchive() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let image = try fixture(index: 1)
    _ = try await prepareNewThread(
      in: makeLedger(fileURL: location.file),
      key: key,
      attachments: [image.snapshot]
    )
    let wrongKeyLedger = ComposerImageUploadLedger(
      fileURL: location.file,
      authenticator: ComposerImageUploadLedgerHMACAuthenticator(
        testingKey: Data(repeating: 0xA5, count: 32)
      )
    )

    await assertLedgerError(.authenticationFailed) {
      try await wrongKeyLedger.load()
    }
  }

  func testFutureEnvelopeAndSignedPayloadSchemasAreRejectedWithoutMigration() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let futureEnvelope = TestSignedEnvelope(
      schemaVersion: 2,
      canonicalPayload: Data("{\"records\":[],\"schemaVersion\":1}".utf8),
      authenticationCode: Data(repeating: 0, count: 32)
    )
    try writeEnvelope(futureEnvelope, to: location.file)
    let futureEnvelopeBytes = try Data(contentsOf: location.file)
    let ledger = makeLedger(fileURL: location.file)
    await assertLedgerError(.unsupportedSchemaVersion) {
      try await ledger.load()
    }
    XCTAssertEqual(try Data(contentsOf: location.file), futureEnvelopeBytes)

    let futurePayload = Data("{\"records\":[],\"schemaVersion\":2}".utf8)
    try writeSignedPayload(futurePayload, to: location.file)
    let futurePayloadBytes = try Data(contentsOf: location.file)
    await assertLedgerError(.unsupportedSchemaVersion) {
      try await ledger.load()
    }
    XCTAssertEqual(try Data(contentsOf: location.file), futurePayloadBytes)
  }

  func testUnsignedLegacyAndNoncanonicalSignedArchivesFailClosed() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let unsigned = Data("{\"records\":[],\"schemaVersion\":1}".utf8)
    try unsigned.write(to: location.file)
    let ledger = makeLedger(fileURL: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }
    XCTAssertEqual(try Data(contentsOf: location.file), unsigned)

    let noncanonical = Data("{ \"schemaVersion\" : 1, \"records\" : [] }".utf8)
    try writeSignedPayload(noncanonical, to: location.file)
    let signedNoncanonical = try Data(contentsOf: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }
    XCTAssertEqual(try Data(contentsOf: location.file), signedNoncanonical)
  }

  func testSignedDuplicateRecordReceiptReorderingAndMetadataMismatchFailClosed() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = makeKey()
    let first = try fixture(index: 1)
    let second = try fixture(index: 2)
    let ledger = makeLedger(fileURL: location.file)
    _ = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [first.snapshot, second.snapshot]
    )
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: first.attachment.id
    )
    _ = try await ledger.recordBoundReceipt(
      first.receipt,
      verifiedAgainst: first.upload,
      for: key
    )
    _ = try await ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: second.attachment.id
    )
    _ = try await ledger.recordBoundReceipt(
      second.receipt,
      verifiedAgainst: second.upload,
      for: key
    )
    let validPayload = try readEnvelope(at: location.file).canonicalPayload

    var duplicateRoot = try jsonObject(from: validPayload)
    var duplicateRecords = try XCTUnwrap(duplicateRoot["records"] as? [[String: Any]])
    duplicateRecords.append(duplicateRecords[0])
    duplicateRoot["records"] = duplicateRecords
    try writeSignedJSONObject(duplicateRoot, to: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }

    var reorderedRoot = try jsonObject(from: validPayload)
    var reorderedRecords = try XCTUnwrap(reorderedRoot["records"] as? [[String: Any]])
    var receipts = try XCTUnwrap(
      reorderedRecords[0]["successfulReceiptPrefix"] as? [[String: Any]]
    )
    receipts.swapAt(0, 1)
    reorderedRecords[0]["successfulReceiptPrefix"] = receipts
    reorderedRoot["records"] = reorderedRecords
    try writeSignedJSONObject(reorderedRoot, to: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }

    var duplicateDigestRoot = try jsonObject(from: validPayload)
    var duplicateDigestRecords = try XCTUnwrap(
      duplicateDigestRoot["records"] as? [[String: Any]]
    )
    var duplicateDigestAttachments = try XCTUnwrap(
      duplicateDigestRecords[0]["attachments"] as? [[String: Any]]
    )
    let firstAttachment = try XCTUnwrap(
      duplicateDigestAttachments[0]["attachment"] as? [String: Any]
    )
    var secondAttachment = try XCTUnwrap(
      duplicateDigestAttachments[1]["attachment"] as? [String: Any]
    )
    let duplicatedDigest = firstAttachment["sha256"]
    secondAttachment["sha256"] = duplicatedDigest
    duplicateDigestAttachments[1]["attachment"] = secondAttachment
    duplicateDigestRecords[0]["attachments"] = duplicateDigestAttachments
    var duplicateDigestReceipts = try XCTUnwrap(
      duplicateDigestRecords[0]["successfulReceiptPrefix"] as? [[String: Any]]
    )
    duplicateDigestReceipts[1]["contentSHA256"] = duplicatedDigest
    duplicateDigestRecords[0]["successfulReceiptPrefix"] = duplicateDigestReceipts
    duplicateDigestRoot["records"] = duplicateDigestRecords
    try writeSignedJSONObject(duplicateDigestRoot, to: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }

    var duplicatePictureRoot = try jsonObject(from: validPayload)
    var duplicatePictureRecords = try XCTUnwrap(
      duplicatePictureRoot["records"] as? [[String: Any]]
    )
    var duplicatePictureReceipts = try XCTUnwrap(
      duplicatePictureRecords[0]["successfulReceiptPrefix"] as? [[String: Any]]
    )
    duplicatePictureReceipts[1]["picID"] = duplicatePictureReceipts[0]["picID"]
    duplicatePictureRecords[0]["successfulReceiptPrefix"] = duplicatePictureReceipts
    duplicatePictureRoot["records"] = duplicatePictureRecords
    try writeSignedJSONObject(duplicatePictureRoot, to: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }

    var mismatchRoot = try jsonObject(from: validPayload)
    var mismatchRecords = try XCTUnwrap(mismatchRoot["records"] as? [[String: Any]])
    var attachments = try XCTUnwrap(
      mismatchRecords[0]["attachments"] as? [[String: Any]]
    )
    var attachment = try XCTUnwrap(attachments[0]["attachment"] as? [String: Any])
    attachment["byteCount"] = (attachment["byteCount"] as? Int ?? 1) + 1
    attachments[0]["attachment"] = attachment
    mismatchRecords[0]["attachments"] = attachments
    mismatchRoot["records"] = mismatchRecords
    try writeSignedJSONObject(mismatchRoot, to: location.file)
    await assertLedgerError(.corruptedArchive) {
      try await ledger.load()
    }
  }

  func testArchiveAndRecordLimitsFailClosedWithoutEviction() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let image = try fixture(index: 1)
    let oneRecordLedger = makeLedger(fileURL: location.file, maximumRecords: 1)
    _ = try await prepareNewThread(
      in: oneRecordLedger,
      key: makeKey(submissionIndex: 1),
      attachments: [image.snapshot]
    )
    let original = try Data(contentsOf: location.file)
    await assertLedgerError(.tooManyRecords) {
      let key = self.makeKey(submissionIndex: 2)
      try await oneRecordLedger.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [image.snapshot]
        ),
        key: key,
        attachmentSnapshots: [image.snapshot]
      )
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)

    try Data(repeating: 0, count: 2_048).write(to: location.file)
    let bounded = makeLedger(fileURL: location.file, maximumArchiveBytes: 1_024)
    let oversized = try Data(contentsOf: location.file)
    await assertLedgerError(.archiveTooLarge) {
      try await bounded.load()
    }
    XCTAssertEqual(try Data(contentsOf: location.file), oversized)
  }

  func testArchiveUsesBackupExclusionProtectionAndRedactedDescriptions() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let image = try fixture(index: 1)
    let key = makeKey()
    let ledger = makeLedger(fileURL: location.file)
    let record = try await prepareNewThread(
      in: ledger,
      key: key,
      attachments: [image.snapshot]
    )

    let values = try location.file.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
    let directoryValues = try location.directory.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
    #if os(iOS)
      let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
      XCTAssertEqual(
        attributes[.protectionKey] as? FileProtectionType,
        .complete
      )
    #endif
    XCTAssertEqual(record.description, "ComposerImageUploadLedgerRecord(redacted)")
    XCTAssertFalse(record.description.contains(image.attachment.sha256))
    XCTAssertFalse(record.description.contains(image.attachment.relativePrivateFilename))
    for error in [
      ComposerImageUploadLedgerError.invalidReceipt,
      .authenticationFailed,
      .identityMismatch,
    ] {
      let message = try XCTUnwrap(error.errorDescription)
      XCTAssertFalse(message.contains(image.attachment.sha256))
      XCTAssertFalse(message.contains(image.attachment.relativePrivateFilename))
    }
  }

  func testTargetSymlinkAndNonRegularArchiveAreRejectedWithoutTouchingTargets() async throws {
    let location = makeLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let outside = location.directory.appendingPathComponent("outside", isDirectory: false)
    let sentinel = Data("sentinel".utf8)
    try sentinel.write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: location.file,
      withDestinationURL: outside
    )
    let ledger = makeLedger(fileURL: location.file)

    await assertLedgerError(.unsafeStorage) {
      try await ledger.load()
    }
    await assertLedgerError(.unsafeStorage) {
      let key = self.makeKey()
      let snapshot = try self.fixture(index: 1).snapshot
      try await ledger.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [snapshot]
        ),
        key: key,
        attachmentSnapshots: [snapshot]
      )
    }
    XCTAssertEqual(try Data(contentsOf: outside), sentinel)

    try FileManager.default.removeItem(at: location.file)
    try FileManager.default.createDirectory(at: location.file, withIntermediateDirectories: false)
    await assertLedgerError(.unsafeStorage) {
      try await ledger.load()
    }
  }

  func testSymlinkedArchiveParentIsRejectedWithoutPublishingIntoDestination() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerImageUploadLedgerAncestorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let realDirectory = root.appendingPathComponent("real", isDirectory: true)
    let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(
      at: realDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: aliasDirectory,
      withDestinationURL: realDirectory
    )
    let aliasedFile = aliasDirectory.appendingPathComponent("ledger.json", isDirectory: false)
    let ledger = makeLedger(fileURL: aliasedFile)

    await assertLedgerError(.unsafeStorage) {
      let key = self.makeKey()
      let snapshot = try self.fixture(index: 1).snapshot
      try await ledger.prepare(
        newThreadSubmission: try self.makeNewThreadSubmission(
          key: key,
          attachments: [snapshot]
        ),
        key: key,
        attachmentSnapshots: [snapshot]
      )
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: realDirectory.appendingPathComponent("ledger.json").path
      )
    )
  }

  func testFixedAuthenticatorIsDeterministicAndRejectsWrongOrMalformedCodes() throws {
    let payload = Data("canonical".utf8)
    let code = try authenticator.authenticationCode(for: payload)
    XCTAssertEqual(code.count, 32)
    XCTAssertEqual(code, try authenticator.authenticationCode(for: payload))
    XCTAssertTrue(try authenticator.isValidAuthenticationCode(code, for: payload))
    XCTAssertFalse(
      try authenticator.isValidAuthenticationCode(code, for: Data("different".utf8))
    )
    XCTAssertFalse(
      try authenticator.isValidAuthenticationCode(Data(repeating: 0, count: 31), for: payload)
    )
    let invalidKey = ComposerImageUploadLedgerHMACAuthenticator(testingKey: Data([0]))
    XCTAssertThrowsError(try invalidKey.authenticationCode(for: payload)) { error in
      XCTAssertEqual(
        error as? ComposerImageUploadLedgerAuthenticationError,
        .invalidKey
      )
    }
  }

  private func makeLedger(
    fileURL: URL,
    maximumRecords: Int = ComposerImageUploadLedger.defaultMaximumRecords,
    maximumArchiveBytes: Int = ComposerImageUploadLedger.defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (
      @Sendable (ComposerImageUploadLedgerDurabilityCheckpoint) throws
        -> Void
    )? = nil
  ) -> ComposerImageUploadLedger {
    ComposerImageUploadLedger(
      fileURL: fileURL,
      authenticator: authenticator,
      maximumRecords: maximumRecords,
      maximumArchiveBytes: maximumArchiveBytes,
      prepareStagedFile: prepareStagedFile,
      beforeDurabilitySync: beforeDurabilitySync
    )
  }

  private func makeKey(submissionIndex: Int = 101) -> ComposerImageUploadLedgerKey {
    ComposerImageUploadLedgerKey(
      context: .newThread(forumID: 7, forumName: "swift"),
      userID: 1001,
      sessionRevision: fixedUUID(100),
      submissionID: fixedUUID(submissionIndex)
    )!
  }

  private func makeDirectTopicReplyKey(
    submissionIndex: Int = 201
  ) -> ComposerImageUploadLedgerKey {
    ComposerImageUploadLedgerKey(
      context: .directTopicReply(
        forumID: 7,
        forumName: "swift",
        threadID: 700,
        firstPostID: 701
      ),
      userID: 1001,
      sessionRevision: fixedUUID(100),
      submissionID: fixedUUID(submissionIndex)
    )!
  }

  private func ledgerKey(
    context: ComposerImageUploadContext,
    userID: Int64,
    sessionRevision: UUID,
    submissionID: UUID
  ) throws -> ComposerImageUploadLedgerKey {
    try XCTUnwrap(
      ComposerImageUploadLedgerKey(
        context: context,
        userID: userID,
        sessionRevision: sessionRevision,
        submissionID: submissionID
      )
    )
  }

  private func snapshotReplacing(
    _ attachment: ComposerImageAttachment,
    id: UUID? = nil,
    sha256: String? = nil,
    byteCount: Int64? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    quality: ComposerImageAttachmentQuality? = nil
  ) throws -> ComposerImageUploadAttachmentSnapshot {
    let replacementID = id ?? attachment.id
    let replacement = try XCTUnwrap(
      ComposerImageAttachment(
        id: replacementID,
        sha256: sha256 ?? attachment.sha256,
        byteCount: byteCount ?? attachment.byteCount,
        pixelWidth: pixelWidth ?? attachment.pixelWidth,
        pixelHeight: pixelHeight ?? attachment.pixelHeight,
        encoding: attachment.encoding,
        quality: quality ?? attachment.quality
      )
    )
    return try XCTUnwrap(
      ComposerImageUploadAttachmentSnapshot(attachment: replacement)
    )
  }

  private func makeNewThreadSubmission(
    key: ComposerImageUploadLedgerKey,
    title: String? = "title",
    content: String = "body",
    attachments: [ComposerImageUploadAttachmentSnapshot]
  ) throws -> NewThreadSubmission {
    guard case .newThread(let forumID, let forumName) = key.context else {
      throw TestFailure.expected
    }
    return try XCTUnwrap(
      NewThreadSubmission(
        id: key.submissionID,
        target: try XCTUnwrap(NewThreadTarget(forumID: forumID, forumName: forumName)),
        title: title,
        content: content,
        attachments: attachments.map(\.attachment)
      )
    )
  }

  private func makeDirectTopicReplySubmission(
    key: ComposerImageUploadLedgerKey,
    content: String = "reply",
    attachments: [ComposerImageUploadAttachmentSnapshot]
  ) throws -> TextReplySubmission {
    guard
      case .directTopicReply(
        let forumID,
        let forumName,
        let threadID,
        let firstPostID
      ) = key.context
    else { throw TestFailure.expected }
    let target = try XCTUnwrap(
      TextReplyTarget(
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        destination: .thread(firstPostID: firstPostID)
      )
    )
    return try XCTUnwrap(
      TextReplySubmission(
        id: key.submissionID,
        target: target,
        content: content,
        attachments: attachments.map(\.attachment)
      )
    )
  }

  @discardableResult
  private func prepareNewThread(
    in ledger: ComposerImageUploadLedger,
    key: ComposerImageUploadLedgerKey,
    title: String? = "title",
    content: String = "body",
    attachments: [ComposerImageUploadAttachmentSnapshot]
  ) async throws -> ComposerImageUploadLedgerRecord {
    try await ledger.prepare(
      newThreadSubmission: makeNewThreadSubmission(
        key: key,
        title: title,
        content: content,
        attachments: attachments
      ),
      key: key,
      attachmentSnapshots: attachments
    )
  }

  private func fixture(
    index: Int,
    preservesOriginal: Bool = false,
    watermark: TiebaStaticImageWatermark = .forumName,
    userID: Int64 = 1001,
    forumName: String = "swift",
    pictureID: String? = nil
  ) throws -> ImageFixture {
    let bytes = Data([0x10, UInt8(index & 0xFF), 0x20, 0x30, 0x40])
    let id = fixedUUID(index)
    let sha256 = hexadecimal(SHA256.hash(data: bytes))
    let quality: ComposerImageAttachmentQuality = preservesOriginal ? .highQuality : .standard
    let attachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: id,
        sha256: sha256,
        byteCount: Int64(bytes.count),
        pixelWidth: 2,
        pixelHeight: 2,
        quality: quality
      )
    )
    let snapshot = try XCTUnwrap(
      ComposerImageUploadAttachmentSnapshot(
        attachment: attachment,
        watermark: watermark
      )
    )
    let upload = TiebaStaticImageUpload(
      uploadID: id,
      forumName: forumName,
      encodedBytes: bytes,
      pixelWidth: 2,
      pixelHeight: 2,
      preservesOriginal: preservesOriginal,
      watermark: watermark
    )
    let receiptFixture = ReceiptFixture(
      schemaVersion: TiebaStaticImageUploadReceipt.currentSchemaVersion,
      uploadID: id,
      contentSHA256: sha256,
      userID: userID,
      forumName: forumName,
      preservesOriginal: preservesOriginal,
      watermark: watermark,
      uploadedPixelWidth: 2,
      uploadedPixelHeight: 2,
      resourceID: hexadecimal(Insecure.MD5.hash(data: bytes))
        + String(TiebaStaticImageUploadPolicy.chunkSize),
      picID: pictureID
        ?? String(repeating: String(format: "%x", index & 0xF), count: 40),
      width: 2,
      height: 2,
      byteCount: bytes.count,
      chunkCount: 1
    )
    let receipt = try JSONDecoder().decode(
      TiebaStaticImageUploadReceipt.self,
      from: JSONEncoder().encode(receiptFixture)
    )
    XCTAssertTrue(receipt.isBound(to: upload, expectedUserID: userID))
    return ImageFixture(
      attachment: attachment,
      snapshot: snapshot,
      upload: upload,
      receipt: receipt
    )
  }

  private func makeLocation() -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ComposerImageUploadLedgerTests-\(UUID().uuidString)", isDirectory: true)
    return (
      directory,
      directory.appendingPathComponent("ledger.json", isDirectory: false)
    )
  }

  private func fixedUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
  }

  private func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private func readEnvelope(at fileURL: URL) throws -> TestSignedEnvelope {
    try JSONDecoder().decode(TestSignedEnvelope.self, from: Data(contentsOf: fileURL))
  }

  private func writeEnvelope(_ envelope: TestSignedEnvelope, to fileURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(envelope).write(to: fileURL, options: .atomic)
  }

  private func writeSignedPayload(_ payload: Data, to fileURL: URL) throws {
    try writeEnvelope(
      TestSignedEnvelope(
        schemaVersion: ComposerImageUploadLedger.schemaVersion,
        canonicalPayload: payload,
        authenticationCode: try authenticator.authenticationCode(for: payload)
      ),
      to: fileURL
    )
  }

  private func jsonObject(from payload: Data) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any]
    )
  }

  private func writeSignedJSONObject(_ object: [String: Any], to fileURL: URL) throws {
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try writeSignedPayload(payload, to: fileURL)
  }

  private func assertLedgerError<T>(
    _ expected: ComposerImageUploadLedgerError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected ledger error", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ComposerImageUploadLedgerError, expected, file: file, line: line)
    }
  }
}

private struct ImageFixture: Sendable {
  let attachment: ComposerImageAttachment
  let snapshot: ComposerImageUploadAttachmentSnapshot
  let upload: TiebaStaticImageUpload
  let receipt: TiebaStaticImageUploadReceipt
}

private struct ReceiptFixture: Encodable {
  let schemaVersion: Int
  let uploadID: UUID
  let contentSHA256: String
  let userID: Int64
  let forumName: String
  let preservesOriginal: Bool
  let watermark: TiebaStaticImageWatermark
  let uploadedPixelWidth: Int
  let uploadedPixelHeight: Int
  let resourceID: String
  let picID: String
  let width: Int
  let height: Int
  let byteCount: Int
  let chunkCount: Int
}

private struct TestSignedEnvelope: Codable {
  let schemaVersion: Int
  var canonicalPayload: Data
  let authenticationCode: Data
}

private enum TestFailure: Error {
  case expected
}
