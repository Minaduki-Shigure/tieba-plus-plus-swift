import CryptoKit
import Foundation
@_spi(TiebaPlusPlusApp) import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerImageSubmissionPipelineTests: XCTestCase {
  func testTypedIntentAcceptsOnlyImageNewThreadAndDirectTopicReply() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let attachment = try XCTUnwrap(environment.attachments.first)
    let newThread = try makeNewThread(attachments: [attachment])
    let directReply = try makeDirectReply(attachments: [attachment])
    let textOnlyNewThread = try makeNewThread(
      id: pipelineUUID(31),
      attachments: []
    )
    let floorTarget = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 70,
        firstPostID: 700,
        destination: .post(postID: 701)
      )
    )
    let textOnlyFloorReply = try XCTUnwrap(
      TextReplySubmission(
        id: pipelineUUID(32),
        target: floorTarget,
        content: "reply"
      )
    )

    XCTAssertEqual(ComposerImageSubmissionIntent(newThread: newThread)?.kind, .newThread)
    XCTAssertEqual(
      ComposerImageSubmissionIntent(directTopicReply: directReply)?.kind,
      .directTopicReply
    )
    XCTAssertNil(ComposerImageSubmissionIntent(newThread: textOnlyNewThread))
    XCTAssertNil(ComposerImageSubmissionIntent(directTopicReply: textOnlyFloorReply))
  }

  func testActivationQueryMapsPreparedWithoutAnyNetworkCall() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    let prepared = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )
    let intent = try XCTUnwrap(ComposerImageSubmissionIntent(newThread: submission))

    let activation = try await environment.pipeline.recoveryState(
      for: intent,
      reference: reference,
      userID: pipelineUserID
    )

    XCTAssertEqual(
      prepared,
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      )
    )
    XCTAssertEqual(activation, prepared)
    let observations = await environment.service.observations()
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [])
    XCTAssertEqual(observations.finalSubmissionCount, 0)
    XCTAssertEqual(observations.recoveredAttachmentIDs, [])
  }

  func testContextOwnerScanFindsOrphanedBlockingRecordWithoutDraftOrNetwork() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )

    let state = try await environment.pipeline.blockingRecoveryState(
      for: .newThread(forumID: 7, forumName: "swift"),
      userID: pipelineUserID
    )

    XCTAssertEqual(
      state,
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      )
    )
    let observations = await environment.service.observations()
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [])
    XCTAssertEqual(observations.finalSubmissionCount, 0)
    XCTAssertEqual(observations.recoveredAttachmentIDs, [])

    let changedSubmission = try makeNewThread(
      id: submission.id,
      attachments: environment.attachments,
      content: "changed body"
    )
    let changedIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(newThread: changedSubmission)
    )
    await assertPipelineError(.intentMismatch) {
      try await environment.pipeline.blockingRecoveryState(
        for: changedIntent,
        userID: pipelineUserID
      )
    }
  }

  func testPrepareRequiresExactReferenceAndFreezesDefaultForumWatermark() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try XCTUnwrap(
      NewThreadSubmission(
        id: pipelineUUID(30),
        target: try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift")),
        title: "title",
        content: "body",
        attachments: environment.attachments
      )
    )
    let wrongReference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submission.id,
        sessionRevision: pipelineUUID(201)
      )
    )

    await assertPipelineError(.accountChanged) {
      try await environment.pipeline.prepareNewThread(
        submission: submission,
        reference: wrongReference
      )
    }
    let emptyRecords = try await environment.ledger.load()
    XCTAssertEqual(emptyRecords.count, 0)

    let reference = try makeReference(submissionID: submission.id)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )
    let records = try await environment.ledger.load()
    XCTAssertEqual(records.first?.attachments.map(\.watermark), [.forumName])
  }

  func testRecoveryStateMapsEveryDurableNetworkBoundaryAndTerminalStage() async throws {
    let pendingEnvironment = try await makeEnvironment(imageCount: 1)
    defer { pendingEnvironment.remove() }
    let pendingSubmission = try makeNewThread(attachments: pendingEnvironment.attachments)
    let pendingReference = try makeReference(submissionID: pendingSubmission.id)
    let pendingIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(newThread: pendingSubmission)
    )
    _ = try await pendingEnvironment.pipeline.prepareNewThread(
      submission: pendingSubmission,
      reference: pendingReference
    )
    let pendingKey = try await ledgerKey(
      in: pendingEnvironment.ledger,
      submissionID: pendingSubmission.id
    )
    _ = try await pendingEnvironment.ledger.markAttachmentDispatchPending(
      for: pendingKey,
      nextAttachmentID: pendingEnvironment.attachments[0].id
    )
    var pendingState = try await pendingEnvironment.pipeline.blockingRecoveryState(
      for: pendingIntent,
      userID: pipelineUserID
    )
    XCTAssertEqual(
      pendingState,
      .locked(
        reference: pendingReference,
        operation: .attachment(attachmentID: pendingEnvironment.attachments[0].id)
      )
    )
    _ = try await pendingEnvironment.ledger.markOutcomeUnknown(for: pendingKey)
    pendingState = try await pendingEnvironment.pipeline.blockingRecoveryState(
      for: pendingIntent,
      userID: pipelineUserID
    )
    XCTAssertEqual(
      pendingState,
      .locked(
        reference: pendingReference,
        operation: .attachment(attachmentID: pendingEnvironment.attachments[0].id)
      )
    )

    let finalEnvironment = try await makeEnvironment(imageCount: 1)
    defer { finalEnvironment.remove() }
    let finalSubmission = try makeNewThread(
      id: pipelineUUID(41),
      attachments: finalEnvironment.attachments
    )
    let finalReference = try makeReference(submissionID: finalSubmission.id)
    let finalIntent = try XCTUnwrap(ComposerImageSubmissionIntent(newThread: finalSubmission))
    _ = try await finalEnvironment.pipeline.prepareNewThread(
      submission: finalSubmission,
      reference: finalReference
    )
    _ = try await seedNextReceipt(
      environment: finalEnvironment,
      submissionID: finalSubmission.id
    )
    var finalState = try await finalEnvironment.pipeline.blockingRecoveryState(
      for: finalIntent,
      userID: pipelineUserID
    )
    XCTAssertEqual(
      finalState,
      .finalSubmissionResumeRequired(reference: finalReference)
    )
    let finalKey = try await ledgerKey(
      in: finalEnvironment.ledger,
      submissionID: finalSubmission.id
    )
    _ = try await finalEnvironment.ledger.markFinalSubmissionPending(for: finalKey)
    finalState = try await finalEnvironment.pipeline.blockingRecoveryState(
      for: finalIntent,
      userID: pipelineUserID
    )
    XCTAssertEqual(
      finalState,
      .locked(reference: finalReference, operation: .finalSubmission)
    )
    _ = try await finalEnvironment.ledger.markCompleted(for: finalKey)
    finalState = try await finalEnvironment.pipeline.blockingRecoveryState(
      for: finalIntent,
      userID: pipelineUserID
    )
    XCTAssertEqual(finalState, .completed(reference: finalReference))
    let finalObservations = await finalEnvironment.service.observations()
    XCTAssertEqual(finalObservations.dispatchedAttachmentIDs, [])
    XCTAssertEqual(finalObservations.finalSubmissionCount, 0)
  }

  func testTwoImagesDispatchSequentiallyAfterPendingAndFinalRunsAfterPending() async throws {
    let environment = try await makeEnvironment(imageCount: 2)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )

    let result = try await environment.pipeline.executeNewThread(
      submission: submission,
      reference: reference
    )

    XCTAssertEqual(result.submissionID, submission.id)
    let observations = await environment.service.observations()
    XCTAssertEqual(
      observations.dispatchedAttachmentIDs,
      environment.attachments.map(\.id)
    )
    XCTAssertEqual(observations.uploadPendingWasVisible, [true, true])
    XCTAssertEqual(observations.finalSubmissionCount, 1)
    XCTAssertEqual(observations.finalPendingWasVisible, [true])
    let records = try await environment.ledger.load()
    let record = records.first
    XCTAssertEqual(record?.stage, .finalSubmissionPending)
  }

  func testRestartRecoversSuccessfulPrefixFromFreshBytesAndDispatchesOnlyRemainingImage()
    async throws
  {
    let environment = try await makeEnvironment(imageCount: 2)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )
    _ = try await seedNextReceipt(
      environment: environment,
      submissionID: submission.id
    )

    _ = try await environment.pipeline.executeNewThread(
      submission: submission,
      reference: reference
    )

    let observations = await environment.service.observations()
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [environment.attachments[1].id])
    XCTAssertEqual(observations.recoveredAttachmentIDs, [environment.attachments[0].id])
    XCTAssertEqual(observations.uploadPendingWasVisible, [true])
    XCTAssertEqual(observations.finalPendingWasVisible, [true])
  }

  func testAccountChangeAfterFirstReceiptStopsBeforeNextDispatch() async throws {
    let environment = try await makeEnvironment(imageCount: 2)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    await environment.service.changeAccount(
      afterDispatchNumber: 1,
      to: pipelineSession(revision: pipelineUUID(201))
    )
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )

    await assertPipelineError(.accountChanged) {
      try await environment.pipeline.executeNewThread(
        submission: submission,
        reference: reference
      )
    }

    let observations = await environment.service.observations()
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [environment.attachments[0].id])
    let loaded = try await environment.ledger.load()
    let record = try XCTUnwrap(loaded.first)
    XCTAssertEqual(record.stage, .prepared)
    XCTAssertEqual(record.successfulReceiptPrefix.count, 1)
  }

  func testDispatchFailureAfterPendingLocksRecordAndRedactsUnderlyingError() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    await environment.service.failDispatch(number: 1)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )

    let expected = ComposerImageSubmissionPipelineError.outcomeUnknown(
      .attachment(attachmentID: environment.attachments[0].id)
    )
    let captured = await capturePipelineError {
      try await environment.pipeline.executeNewThread(
        submission: submission,
        reference: reference
      )
    }

    XCTAssertEqual(captured, expected)
    let loaded = try await environment.ledger.load()
    let record = try XCTUnwrap(loaded.first)
    XCTAssertEqual(record.stage, .outcomeUnknown)
    let unwrappedError = try XCTUnwrap(captured)
    let diagnostics = [
      unwrappedError.localizedDescription,
      String(describing: unwrappedError),
      String(reflecting: unwrappedError),
    ].joined(separator: "|")
    for secret in [
      PipelineServiceSpy.secretFailureMessage,
      environment.attachments[0].sha256,
      environment.attachments[0].relativePrivateFilename,
      submission.content,
    ] {
      XCTAssertFalse(diagnostics.contains(secret))
    }
  }

  func testFinalFailureAfterPendingLocksAsFinalOutcomeUnknown() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    await environment.service.failFinalSubmission()
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )

    await assertPipelineError(.outcomeUnknown(.finalSubmission)) {
      try await environment.pipeline.executeNewThread(
        submission: submission,
        reference: reference
      )
    }

    let observations = await environment.service.observations()
    XCTAssertEqual(observations.finalPendingWasVisible, [true])
    let loaded = try await environment.ledger.load()
    let record = try XCTUnwrap(loaded.first)
    XCTAssertEqual(record.stage, .outcomeUnknown)
    XCTAssertEqual(record.outcomeUnknownOperation, .finalSubmission)
  }

  func testKnownUploadReceiptIsRecordedWithoutPostPendingCancellationCheck() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    await environment.service.cancelTask(afterDispatchNumber: 1)
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )
    let pipeline = environment.pipeline
    let task = Task {
      try await pipeline.executeNewThread(
        submission: submission,
        reference: reference
      )
    }

    let result = try await task.value

    XCTAssertEqual(result.submissionID, submission.id)
    let records = try await environment.ledger.load()
    XCTAssertEqual(records.first?.successfulReceiptPrefix.count, 1)
    XCTAssertEqual(records.first?.stage, .finalSubmissionPending)
  }

  func testVisibilityRecoveryUsesFreshBytesWithoutNetworkAndRejectsRemovedFile() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeNewThread(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    let intent = try XCTUnwrap(ComposerImageSubmissionIntent(newThread: submission))
    await environment.service.acceptNewThreadAwaitingVisibility()
    _ = try await environment.pipeline.prepareNewThread(
      submission: submission,
      reference: reference
    )
    let result = try await environment.pipeline.executeNewThread(
      submission: submission,
      reference: reference
    )
    guard case .acceptedAwaitingVisibility = result.outcome else {
      return XCTFail("Expected accepted-awaiting-visibility outcome.")
    }
    _ = try await environment.pipeline.markCompleted(intent: intent, reference: reference)
    let retainedBytes = try await environment.attachmentStore.validatedData(
      for: environment.attachments[0]
    )
    XCTAssertFalse(retainedBytes.isEmpty)
    await environment.service.resetObservations()

    let recovered = try await environment.pipeline.recoverNewThreadUploadsForVisibility(
      submission: submission,
      reference: reference
    )

    XCTAssertEqual(recovered.map(\.attachment), environment.attachments)
    var observations = await environment.service.observations()
    XCTAssertEqual(observations.recoveredAttachmentIDs, environment.attachments.map(\.id))
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [])
    XCTAssertEqual(observations.finalSubmissionCount, 0)

    try await environment.attachmentStore.remove(environment.attachments[0])
    await assertPipelineError(.attachmentUnavailable) {
      try await environment.pipeline.recoverNewThreadUploadsForVisibility(
        submission: submission,
        reference: reference
      )
    }
    observations = await environment.service.observations()
    XCTAssertEqual(observations.dispatchedAttachmentIDs, [])
    XCTAssertEqual(observations.finalSubmissionCount, 0)
  }

  func testDirectTopicReplyAndCompletedCleanupAreTypedAndIdempotent() async throws {
    let environment = try await makeEnvironment(imageCount: 1)
    defer { environment.remove() }
    let submission = try makeDirectReply(attachments: environment.attachments)
    let reference = try makeReference(submissionID: submission.id)
    let intent = try XCTUnwrap(
      ComposerImageSubmissionIntent(directTopicReply: submission)
    )
    _ = try await environment.pipeline.prepareDirectTopicReply(
      submission: submission,
      reference: reference
    )

    let result = try await environment.pipeline.executeDirectTopicReply(
      submission: submission,
      reference: reference
    )
    guard case .confirmed(.post(let postID, _)) = result.outcome else {
      return XCTFail("Expected a confirmed direct topic reply.")
    }
    XCTAssertEqual(postID, 701)
    var completedState = try await environment.pipeline.markCompleted(
      intent: intent,
      reference: reference
    )
    XCTAssertEqual(completedState, .completed(reference: reference))
    completedState = try await environment.pipeline.markCompleted(
      intent: intent,
      reference: reference
    )
    XCTAssertEqual(completedState, .completed(reference: reference))
    try await environment.pipeline.removeAttachments(
      intent: intent,
      reference: reference
    )
    try await environment.pipeline.removeAttachments(
      intent: intent,
      reference: reference
    )
    try await environment.pipeline.deleteCompleted(
      intent: intent,
      reference: reference,
      userID: pipelineUserID
    )
    try await environment.pipeline.deleteCompleted(
      intent: intent,
      reference: reference,
      userID: pipelineUserID
    )
    let deletedState = try await environment.pipeline.blockingRecoveryState(
      for: intent,
      userID: pipelineUserID
    )
    XCTAssertNil(deletedState)
  }

  private func makeEnvironment(imageCount: Int) async throws -> PipelineEnvironment {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ComposerImageSubmissionPipelineTests-\(UUID().uuidString)",
        isDirectory: true
      )
    let attachmentDirectory = rootURL.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: attachmentDirectory,
      withIntermediateDirectories: true
    )
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: attachmentDirectory,
      trustedRootURL: rootURL
    )
    var attachments = [ComposerImageAttachment]()
    for index in 0..<imageCount {
      let input = try pipelineImageData(index: index)
      attachments.append(
        try await attachmentStore.importImage(
          data: input,
          quality: index.isMultiple(of: 2) ? .standard : .highQuality,
          id: pipelineUUID(index + 1)
        )
      )
    }
    let ledger = ComposerImageUploadLedger(
      fileURL: rootURL.appendingPathComponent("ledger.json"),
      authenticator: ComposerImageUploadLedgerHMACAuthenticator(
        testingKey: Data(repeating: 0x6A, count: 32)
      )
    )
    let vault = PipelineVaultSpy(session: pipelineSession())
    let pictureCharacters = Dictionary(
      uniqueKeysWithValues: attachments.enumerated().map { index, attachment in
        (attachment.id, String(format: "%x", index + 1))
      }
    )
    let service = PipelineServiceSpy(
      ledger: ledger,
      vault: vault,
      pictureCharacters: pictureCharacters
    )
    let pipeline = ComposerImageSubmissionPipeline(
      access: AccountAccess(vault: vault, service: service),
      attachmentStore: attachmentStore,
      ledger: ledger
    )
    return PipelineEnvironment(
      rootURL: rootURL,
      attachmentStore: attachmentStore,
      ledger: ledger,
      vault: vault,
      service: service,
      pipeline: pipeline,
      attachments: attachments
    )
  }

  private func seedNextReceipt(
    environment: PipelineEnvironment,
    submissionID: UUID
  ) async throws -> ComposerImageUploadLedgerRecord {
    let key = try await ledgerKey(in: environment.ledger, submissionID: submissionID)
    let loadedRecord = try await environment.ledger.record(for: key)
    let record = try XCTUnwrap(loadedRecord)
    let snapshot = try XCTUnwrap(record.nextAttachment)
    let bytes = try await environment.attachmentStore.validatedData(for: snapshot.attachment)
    let prepared = try await environment.service.prepareStaticImageUpload(
      session: pipelineSession(),
      submissionID: submissionID,
      forumID: key.context.forumID,
      forumName: key.context.forumName,
      attachment: snapshot.attachment,
      validatedBytes: bytes,
      watermark: snapshot.watermark
    )
    let receipt = try pipelineReceipt(
      prepared: prepared,
      pictureCharacter: environment.pictureCharacter(for: snapshot.id)
    )
    _ = try await environment.ledger.markAttachmentDispatchPending(
      for: key,
      nextAttachmentID: snapshot.id
    )
    return try await environment.ledger.recordBoundReceipt(
      receipt,
      verifiedAgainst: prepared.coreUpload,
      for: key
    )
  }

  private func ledgerKey(
    in ledger: ComposerImageUploadLedger,
    submissionID: UUID
  ) async throws -> ComposerImageUploadLedgerKey {
    let loaded = try await ledger.load()
    let records = loaded.filter { $0.key.submissionID == submissionID }
    return try XCTUnwrap(records.count == 1 ? records[0].key : nil)
  }

  private func makeNewThread(
    id: UUID = pipelineUUID(30),
    attachments: [ComposerImageAttachment],
    watermark: TiebaStaticImageWatermark = .username,
    content: String = "private body"
  ) throws -> NewThreadSubmission {
    try XCTUnwrap(
      NewThreadSubmission(
        id: id,
        target: try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift")),
        title: "title",
        content: content,
        attachments: attachments,
        imageWatermark: watermark
      )
    )
  }

  private func makeDirectReply(
    id: UUID = pipelineUUID(30),
    attachments: [ComposerImageAttachment],
    watermark: TiebaStaticImageWatermark = .none
  ) throws -> TextReplySubmission {
    let target = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 70,
        firstPostID: 700,
        destination: .thread(firstPostID: 700)
      )
    )
    return try XCTUnwrap(
      TextReplySubmission(
        id: id,
        target: target,
        content: "private reply",
        attachments: attachments,
        imageWatermark: watermark
      )
    )
  }

  private func makeReference(submissionID: UUID) throws -> ComposerImageSubmissionReference {
    try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID,
        sessionRevision: pipelineUUID(200)
      )
    )
  }

  private func pipelineImageData(index: Int) throws -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(24 + index), height: CGFloat(16 + index)),
      format: format
    ).image { context in
      UIColor(
        red: CGFloat(index + 1) / 10,
        green: 0.3,
        blue: 0.7,
        alpha: 1
      ).setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(24 + index), height: CGFloat(16 + index))
      )
    }
    return try XCTUnwrap(image.pngData())
  }
}

private struct PipelineEnvironment {
  let rootURL: URL
  let attachmentStore: ComposerImageAttachmentStore
  let ledger: ComposerImageUploadLedger
  let vault: PipelineVaultSpy
  let service: PipelineServiceSpy
  let pipeline: ComposerImageSubmissionPipeline
  let attachments: [ComposerImageAttachment]

  func pictureCharacter(for attachmentID: UUID) -> String {
    let index = attachments.firstIndex(where: { $0.id == attachmentID }) ?? 0
    return String(format: "%x", index + 1)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private struct PipelineServiceObservations: Sendable {
  let dispatchedAttachmentIDs: [UUID]
  let uploadPendingWasVisible: [Bool]
  let finalSubmissionCount: Int
  let finalPendingWasVisible: [Bool]
  let recoveredAttachmentIDs: [UUID]
}

private enum PipelineTestFailure: Error, Sendable {
  case secret(String)
  case unexpectedCall
}

private actor PipelineServiceProbe {
  private var recoveredAttachmentIDs = [UUID]()

  func recordRecovery(_ attachmentID: UUID) {
    recoveredAttachmentIDs.append(attachmentID)
  }

  func recoveries() -> [UUID] { recoveredAttachmentIDs }
  func reset() { recoveredAttachmentIDs.removeAll() }
}

private actor PipelineServiceSpy: AccountService {
  static let secretFailureMessage = "private-service-error-detail"

  nonisolated let ledger: ComposerImageUploadLedger
  nonisolated let vault: PipelineVaultSpy
  nonisolated let probe = PipelineServiceProbe()
  nonisolated let pictureCharacters: [UUID: String]
  private var dispatchedAttachmentIDs = [UUID]()
  private var uploadPendingWasVisible = [Bool]()
  private var finalSubmissionCount = 0
  private var finalPendingWasVisible = [Bool]()
  private var failedDispatchNumber: Int?
  private var accountChange: (number: Int, session: StoredAccountSession)?
  private var finalSubmissionFails = false
  private var newThreadIsAcceptedAwaitingVisibility = false
  private var cancellationDispatchNumber: Int?

  init(
    ledger: ComposerImageUploadLedger,
    vault: PipelineVaultSpy,
    pictureCharacters: [UUID: String]
  ) {
    self.ledger = ledger
    self.vault = vault
    self.pictureCharacters = pictureCharacters
  }

  nonisolated func prepareStaticImageUpload(
    session: StoredAccountSession,
    submissionID: UUID,
    forumID: Int64,
    forumName: String,
    attachment: ComposerImageAttachment,
    validatedBytes: Data,
    watermark: TiebaStaticImageWatermark
  ) async throws -> ComposerPreparedImageUpload {
    guard let credential = session.credentials else {
      throw ComposerImageUploadPreparationError.fullCredentialsRequired
    }
    let digest = pipelineHexadecimal(SHA256.hash(data: validatedBytes))
    guard
      session.id > 0,
      forumID > 0,
      !forumName.isEmpty,
      !validatedBytes.isEmpty,
      attachment.sha256 == digest,
      attachment.byteCount == Int64(validatedBytes.count)
    else { throw ComposerImageUploadPreparationError.invalidUpload }
    let upload = TiebaStaticImageUpload(
      uploadID: attachment.id,
      forumName: forumName,
      encodedBytes: validatedBytes,
      pixelWidth: attachment.pixelWidth,
      pixelHeight: attachment.pixelHeight,
      preservesOriginal: attachment.quality == .highQuality,
      watermark: watermark
    )
    return ComposerPreparedImageUpload(
      sessionUserID: session.id,
      sessionRevision: session.sessionRevision,
      credential: credential,
      submissionID: submissionID,
      forumID: forumID,
      forumName: forumName,
      attachment: attachment,
      validatedBytes: validatedBytes,
      watermark: watermark,
      coreUpload: upload,
      expectedChunkCount: (validatedBytes.count - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1
    )
  }

  func dispatchStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload
  ) async throws -> ComposerImageUploadResult {
    dispatchedAttachmentIDs.append(prepared.attachment.id)
    let dispatchNumber = dispatchedAttachmentIDs.count
    let records = try await ledger.load()
    let record = records.first {
      $0.key.submissionID == prepared.submissionID
    }
    uploadPendingWasVisible.append(
      record?.stage
        == .attachmentDispatchPending(nextAttachmentID: prepared.attachment.id)
    )
    if failedDispatchNumber == dispatchNumber {
      throw PipelineTestFailure.secret(Self.secretFailureMessage)
    }
    let receipt = try pipelineReceipt(
      prepared: prepared,
      pictureCharacter: pictureCharacters[prepared.attachment.id] ?? "f"
    )
    let result = try Self.boundResult(prepared: prepared, receipt: receipt)
    if let accountChange, accountChange.number == dispatchNumber {
      await vault.replaceActive(with: accountChange.session)
    }
    if cancellationDispatchNumber == dispatchNumber {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    return result
  }

  nonisolated func recoverStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload,
    authenticatedReceipt: TiebaStaticImageUploadReceipt
  ) async throws -> ComposerImageUploadResult {
    await probe.recordRecovery(prepared.attachment.id)
    return try Self.boundResult(prepared: prepared, receipt: authenticatedReceipt)
  }

  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadResult {
    try await recordFinalSubmission(
      session: session,
      submissionID: submission.id,
      attachments: submission.attachments,
      expectedWatermark: submission.imageWatermark,
      uploads: imageUploads
    )
    let receipt = NewThreadReceipt(threadID: 70, firstPostID: 700)!
    let outcome: NewThreadOutcome =
      newThreadIsAcceptedAwaitingVisibility
      ? .acceptedAwaitingVisibility(receipt)
      : .confirmed(receipt)
    return NewThreadResult(
      submissionID: submission.id,
      userID: session.id,
      target: submission.target,
      outcome: outcome
    )!
  }

  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> TextReplyResult {
    try await recordFinalSubmission(
      session: session,
      submissionID: submission.id,
      attachments: submission.attachments,
      expectedWatermark: submission.imageWatermark,
      uploads: imageUploads
    )
    return TextReplyResult(
      submissionID: submission.id,
      userID: session.id,
      target: submission.target,
      outcome: .confirmed(.post(postID: 701, floor: 2))
    )!
  }

  func failDispatch(number: Int) {
    failedDispatchNumber = number
  }

  func changeAccount(afterDispatchNumber number: Int, to session: StoredAccountSession) {
    accountChange = (number, session)
  }

  func failFinalSubmission() {
    finalSubmissionFails = true
  }

  func acceptNewThreadAwaitingVisibility() {
    newThreadIsAcceptedAwaitingVisibility = true
  }

  func cancelTask(afterDispatchNumber number: Int) {
    cancellationDispatchNumber = number
  }

  func observations() async -> PipelineServiceObservations {
    PipelineServiceObservations(
      dispatchedAttachmentIDs: dispatchedAttachmentIDs,
      uploadPendingWasVisible: uploadPendingWasVisible,
      finalSubmissionCount: finalSubmissionCount,
      finalPendingWasVisible: finalPendingWasVisible,
      recoveredAttachmentIDs: await probe.recoveries()
    )
  }

  func resetObservations() async {
    dispatchedAttachmentIDs.removeAll()
    uploadPendingWasVisible.removeAll()
    finalSubmissionCount = 0
    finalPendingWasVisible.removeAll()
    await probe.reset()
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw PipelineTestFailure.unexpectedCall
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw PipelineTestFailure.unexpectedCall
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw PipelineTestFailure.unexpectedCall
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw PipelineTestFailure.unexpectedCall
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw PipelineTestFailure.unexpectedCall
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw PipelineTestFailure.unexpectedCall
  }

  private func recordFinalSubmission(
    session: StoredAccountSession,
    submissionID: UUID,
    attachments: [ComposerImageAttachment],
    expectedWatermark: TiebaStaticImageWatermark,
    uploads: [ComposerImageUploadResult]
  ) async throws {
    finalSubmissionCount += 1
    let records = try await ledger.load()
    let record = records.first { $0.key.submissionID == submissionID }
    finalPendingWasVisible.append(record?.stage == .finalSubmissionPending)
    guard
      session.id == pipelineUserID,
      uploads.map(\.attachment) == attachments,
      uploads.allSatisfy({ $0.watermark == expectedWatermark })
    else { throw PipelineTestFailure.secret(Self.secretFailureMessage) }
    if finalSubmissionFails {
      throw PipelineTestFailure.secret(Self.secretFailureMessage)
    }
  }

  nonisolated private static func boundResult(
    prepared: ComposerPreparedImageUpload,
    receipt: TiebaStaticImageUploadReceipt
  ) throws -> ComposerImageUploadResult {
    let proof = try TiebaStaticImageContentProof.bind(
      upload: prepared.coreUpload,
      receipt: receipt,
      expectedUserID: prepared.sessionUserID,
      submissionID: prepared.submissionID,
      forumID: prepared.forumID
    )
    return ComposerImageUploadResult(
      sessionRevision: prepared.sessionRevision,
      attachment: prepared.attachment,
      watermark: prepared.watermark,
      receipt: receipt,
      proof: proof
    )
  }
}

private actor PipelineVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? { session }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }
}

private struct PipelineReceiptFixture: Encodable {
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

private func pipelineReceipt(
  prepared: ComposerPreparedImageUpload,
  pictureCharacter: String
) throws -> TiebaStaticImageUploadReceipt {
  let bytes = prepared.validatedBytes
  return try JSONDecoder().decode(
    TiebaStaticImageUploadReceipt.self,
    from: JSONEncoder().encode(
      PipelineReceiptFixture(
        schemaVersion: TiebaStaticImageUploadReceipt.currentSchemaVersion,
        uploadID: prepared.attachment.id,
        contentSHA256: pipelineHexadecimal(SHA256.hash(data: bytes)),
        userID: prepared.sessionUserID,
        forumName: prepared.forumName,
        preservesOriginal: prepared.attachment.quality == .highQuality,
        watermark: prepared.watermark,
        uploadedPixelWidth: prepared.attachment.pixelWidth,
        uploadedPixelHeight: prepared.attachment.pixelHeight,
        resourceID: pipelineHexadecimal(Insecure.MD5.hash(data: bytes))
          + String(TiebaStaticImageUploadPolicy.chunkSize),
        picID: String(repeating: pictureCharacter, count: 40),
        width: prepared.attachment.pixelWidth,
        height: prepared.attachment.pixelHeight,
        byteCount: bytes.count,
        chunkCount: (bytes.count - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1
      )
    )
  )
}

private let pipelineUserID: Int64 = 9

private func pipelineSession(
  revision: UUID = pipelineUUID(200)
) -> StoredAccountSession {
  StoredAccountSession(
    id: pipelineUserID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: String(repeating: "s", count: AccountCredentialFormat.stokenLength),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func pipelineUUID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

private func pipelineHexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
  digest.map { String(format: "%02x", $0) }.joined()
}

@MainActor
private func assertPipelineError<T: Sendable>(
  _ expected: ComposerImageSubmissionPipelineError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let captured = await capturePipelineError(
    operation: operation,
    file: file,
    line: line
  )
  XCTAssertEqual(captured, expected, file: file, line: line)
}

@MainActor
private func capturePipelineError<T: Sendable>(
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async -> ComposerImageSubmissionPipelineError? {
  do {
    _ = try await operation()
    XCTFail("Expected a pipeline error.", file: file, line: line)
    return nil
  } catch let error as ComposerImageSubmissionPipelineError {
    return error
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
    return nil
  }
}
