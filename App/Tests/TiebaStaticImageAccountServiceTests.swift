import CryptoKit
import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaStaticImageAccountServiceTests: XCTestCase {
  func testPreparationRequiresExactFullSessionBeforeCallingCore() async throws {
    let bytes = Data([0x01, 0x02, 0x03])
    let attachment = try staticImageAttachment(id: staticImageUUID(1), bytes: bytes)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift"
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
    let service = TiebaCoreAccountService(client: spy)

    for session in [
      staticImageSession(stoken: nil),
      staticImageSession(stoken: "short"),
      staticImageSession(bduss: "short"),
      staticImageSession(userID: 0),
    ] {
      await assertStaticImagePreparationError(.fullCredentialsRequired) {
        try await service.prepareStaticImageUpload(
          session: session,
          submissionID: staticImageUUID(20),
          forumID: 7,
          forumName: "swift",
          attachment: attachment,
          validatedBytes: bytes,
          watermark: .forumName
        )
      }
    }
    let uploadRequestCount = await spy.uploadRequestCount()
    XCTAssertEqual(uploadRequestCount, 0)
  }

  func testPreparedUploadCanBeRecordedPendingBeforeExactDispatchAndBinding() async throws {
    let bytes = Data(repeating: 0x4A, count: 512_001)
    let attachment = try staticImageAttachment(
      id: staticImageUUID(2),
      bytes: bytes,
      width: 2_048,
      height: 1_536,
      quality: .highQuality
    )
    let submissionID = staticImageUUID(21)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift",
      preservesOriginal: true,
      watermark: .username
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
    let service = TiebaCoreAccountService(client: spy)

    let prepared = try await service.prepareStaticImageUpload(
      session: staticImageSession(cookieName: .bdussBFESS),
      submissionID: submissionID,
      forumID: 7,
      forumName: "swift",
      attachment: attachment,
      validatedBytes: bytes,
      watermark: .username
    )
    let requestCountAfterPreparation = await spy.uploadRequestCount()
    XCTAssertEqual(requestCountAfterPreparation, 0)
    XCTAssertEqual(prepared.sessionUserID, 9)
    XCTAssertEqual(prepared.sessionRevision, staticImageUUID(200))
    XCTAssertEqual(prepared.submissionID, submissionID)
    XCTAssertEqual(prepared.forumID, 7)
    XCTAssertEqual(prepared.forumName, "swift")
    XCTAssertEqual(prepared.attachment, attachment)
    XCTAssertEqual(prepared.validatedBytes, bytes)
    XCTAssertEqual(prepared.watermark, .username)
    XCTAssertEqual(prepared.coreUpload.uploadID, attachment.id)
    XCTAssertEqual(prepared.coreUpload.encodedBytes, bytes)
    XCTAssertTrue(prepared.coreUpload.preservesOriginal)
    XCTAssertEqual(prepared.expectedChunkCount, 2)
    XCTAssertEqual(prepared.credential.bduss.utf8.count, AccountCredentialFormat.bdussLength)
    XCTAssertEqual(prepared.credential.stoken.utf8.count, AccountCredentialFormat.stokenLength)
    let diagnostics = [String(describing: prepared), String(reflecting: prepared)].joined()
    XCTAssertFalse(diagnostics.contains(prepared.credential.bduss))
    XCTAssertFalse(diagnostics.contains(prepared.credential.stoken))

    let ledger = StaticImageLedgerPendingSpy()
    await ledger.persistPending(prepared)
    let isPending = await ledger.contains(prepared)
    let requestCountAfterPendingRecord = await spy.uploadRequestCount()
    XCTAssertTrue(isPending)
    XCTAssertEqual(requestCountAfterPendingRecord, 0)

    let result = try await service.dispatchStaticImageUpload(prepared)

    XCTAssertEqual(result.receipt, receipt)
    XCTAssertEqual(result.sessionRevision, staticImageUUID(200))
    XCTAssertEqual(result.attachment, attachment)
    XCTAssertEqual(result.watermark, .username)
    XCTAssertEqual(result.proof.submissionID, submissionID)
    XCTAssertEqual(result.proof.userID, 9)
    XCTAssertEqual(result.proof.forumID, 7)
    XCTAssertEqual(result.proof.forumName, "swift")
    XCTAssertEqual(result.proof.uploadID, attachment.id)
    let requests = await spy.uploadRequests()
    let request = try XCTUnwrap(requests.count == 1 ? requests[0] : nil)
    XCTAssertEqual(request.expectedUserID, 9)
    XCTAssertEqual(request.upload.uploadID, attachment.id)
    XCTAssertEqual(request.upload.forumName, "swift")
    XCTAssertEqual(request.upload.encodedBytes, bytes)
    XCTAssertEqual(request.upload.pixelWidth, attachment.pixelWidth)
    XCTAssertEqual(request.upload.pixelHeight, attachment.pixelHeight)
    XCTAssertTrue(request.upload.preservesOriginal)
    XCTAssertEqual(request.upload.watermark, .username)
    XCTAssertEqual(request.bdussByteCount, AccountCredentialFormat.bdussLength)
    XCTAssertEqual(request.stokenByteCount, AccountCredentialFormat.stokenLength)
    XCTAssertEqual(request.cookieName, .bdussBFESS)
  }

  func testKnownReceiptIsReturnedWhenCancellationArrivesWithResponse() async throws {
    let bytes = Data([0x0A, 0x0B, 0x0C])
    let attachment = try staticImageAttachment(id: staticImageUUID(9), bytes: bytes)
    let submissionID = staticImageUUID(29)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift"
    )
    let service = TiebaCoreAccountService(
      client: StaticImageAccountClientSpy(uploadBehavior: .receiptAndCancel(receipt))
    )

    let prepared = try await service.prepareStaticImageUpload(
      session: staticImageSession(),
      submissionID: submissionID,
      forumID: 7,
      forumName: "swift",
      attachment: attachment,
      validatedBytes: bytes,
      watermark: .forumName
    )
    let result = try await service.dispatchStaticImageUpload(prepared)

    XCTAssertTrue(Task.isCancelled)
    XCTAssertEqual(result.receipt, receipt)
    XCTAssertEqual(result.sessionRevision, staticImageUUID(200))
    XCTAssertEqual(result.attachment, attachment)
    XCTAssertEqual(result.watermark, .forumName)
    XCTAssertEqual(result.proof.submissionID, submissionID)
    XCTAssertEqual(result.proof.uploadID, attachment.id)
  }

  func testAuthenticatedReceiptRecoveryUsesFreshPreparationWithoutNetwork() async throws {
    let bytes = Data([0x0D, 0x0E, 0x0F])
    let attachment = try staticImageAttachment(id: staticImageUUID(11), bytes: bytes)
    let submissionID = staticImageUUID(32)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift"
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
    let service = TiebaCoreAccountService(client: spy)
    let prepared = try await service.prepareStaticImageUpload(
      session: staticImageSession(),
      submissionID: submissionID,
      forumID: 7,
      forumName: "swift",
      attachment: attachment,
      validatedBytes: bytes,
      watermark: .forumName
    )

    let recovered = try await service.recoverStaticImageUpload(
      prepared,
      authenticatedReceipt: receipt
    )

    XCTAssertEqual(recovered.receipt, receipt)
    XCTAssertEqual(recovered.attachment, attachment)
    XCTAssertEqual(recovered.sessionRevision, staticImageUUID(200))
    XCTAssertEqual(recovered.proof.submissionID, submissionID)
    XCTAssertEqual(recovered.proof.uploadID, attachment.id)
    let uploadRequestCount = await spy.uploadRequestCount()
    XCTAssertEqual(uploadRequestCount, 0)
  }

  func testPreparationRejectsForgedBytesAndNonExactForumBeforeNetwork() async throws {
    let bytes = Data([0x10, 0x20, 0x30])
    let attachment = try staticImageAttachment(id: staticImageUUID(3), bytes: bytes)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift"
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
    let service = TiebaCoreAccountService(client: spy)

    for input in [
      (bytes: Data([0x10, 0x20, 0x31]), forumID: Int64(7), forumName: "swift"),
      (bytes: bytes, forumID: Int64(0), forumName: "swift"),
      (bytes: bytes, forumID: Int64(7), forumName: " swift "),
    ] {
      await assertStaticImagePreparationError(.invalidUpload) {
        try await service.prepareStaticImageUpload(
          session: staticImageSession(),
          submissionID: staticImageUUID(22),
          forumID: input.forumID,
          forumName: input.forumName,
          attachment: attachment,
          validatedBytes: input.bytes,
          watermark: .forumName
        )
      }
    }
    let uploadRequestCount = await spy.uploadRequestCount()
    XCTAssertEqual(uploadRequestCount, 0)
  }

  func testDispatchRejectsForgedReceiptIdentity() async throws {
    let bytes = Data([0x21, 0x22, 0x23])
    let attachment = try staticImageAttachment(id: staticImageUUID(4), bytes: bytes)
    let submissionID = staticImageUUID(23)
    let forgedReceipts = try [
      staticImageReceipt(
        attachment: attachment,
        bytes: bytes,
        userID: 10,
        forumName: "swift"
      ),
      staticImageReceipt(
        attachment: attachment,
        bytes: bytes,
        userID: 9,
        forumName: "other"
      ),
      staticImageReceipt(
        attachment: attachment,
        bytes: bytes,
        userID: 9,
        forumName: "swift",
        uploadID: staticImageUUID(99)
      ),
      staticImageReceipt(
        attachment: attachment,
        bytes: Data([0x21, 0x22, 0x24]),
        userID: 9,
        forumName: "swift"
      ),
    ]
    for receipt in forgedReceipts {
      let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
      let service = TiebaCoreAccountService(client: spy)
      let prepared = try await service.prepareStaticImageUpload(
        session: staticImageSession(),
        submissionID: submissionID,
        forumID: 7,
        forumName: "swift",
        attachment: attachment,
        validatedBytes: bytes,
        watermark: .forumName
      )
      await assertStaticImageError(.invalidReceipt) {
        try await service.dispatchStaticImageUpload(prepared)
      }
      let uploadRequestCount = await spy.uploadRequestCount()
      XCTAssertEqual(uploadRequestCount, 1)
    }
  }

  func testDispatchErrorsAreTypedRedactedAndCancellationStaysCancellation() async throws {
    let bytes = Data([0x31, 0x32, 0x33])
    let attachment = try staticImageAttachment(id: staticImageUUID(5), bytes: bytes)
    let cases: [(StaticImageUploadBehavior, ComposerImageUploadError)] = [
      (.failure(.invalidArgument("private argument")), .preparedUploadRejected),
      (.failure(.staticImageUploadIDConflict), .uploadConflict),
      (
        .failure(
          .staticImageUploadOutcomeUnknown(
            uploadID: attachment.id,
            dispatchedChunk: 1
          )
        ),
        .outcomeUnknown(attachment: attachment, dispatchedChunk: 1)
      ),
      (.failure(.server(code: 123, message: "private server message")), .server(code: 123)),
      (.failure(.network(code: -1_009)), .unavailable),
      (
        .failure(
          .staticImageUploadOutcomeUnknown(
            uploadID: staticImageUUID(98),
            dispatchedChunk: 1
          )
        ),
        .unavailable
      ),
    ]

    for (behavior, expected) in cases {
      let service = TiebaCoreAccountService(
        client: StaticImageAccountClientSpy(uploadBehavior: behavior)
      )
      let prepared = try await service.prepareStaticImageUpload(
        session: staticImageSession(),
        submissionID: staticImageUUID(24),
        forumID: 7,
        forumName: "swift",
        attachment: attachment,
        validatedBytes: bytes,
        watermark: .forumName
      )
      do {
        _ = try await service.dispatchStaticImageUpload(prepared)
        XCTFail("Expected mapped image upload error")
      } catch let error as ComposerImageUploadError {
        XCTAssertEqual(error, expected)
        let diagnostics = [
          error.localizedDescription,
          String(describing: error),
          String(reflecting: error),
        ].joined(separator: "|")
        for secret in [attachment.sha256, attachment.relativePrivateFilename, "private"] {
          XCTAssertFalse(diagnostics.contains(secret))
        }
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    let cancellationService = TiebaCoreAccountService(
      client: StaticImageAccountClientSpy(uploadBehavior: .cancellation)
    )
    let cancellationPrepared = try await cancellationService.prepareStaticImageUpload(
      session: staticImageSession(),
      submissionID: staticImageUUID(24),
      forumID: 7,
      forumName: "swift",
      attachment: attachment,
      validatedBytes: bytes,
      watermark: .forumName
    )
    do {
      _ = try await cancellationService.dispatchStaticImageUpload(cancellationPrepared)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testProofOverloadsRequireExactAttachmentOrderAndMapToCore() async throws {
    let firstBytes = Data([0x41, 0x42, 0x43])
    let secondBytes = Data([0x51, 0x52, 0x53])
    let first = try staticImageAttachment(id: staticImageUUID(6), bytes: firstBytes)
    let second = try staticImageAttachment(id: staticImageUUID(7), bytes: secondBytes)
    let firstReceipt = try staticImageReceipt(
      attachment: first,
      bytes: firstBytes,
      userID: 9,
      forumName: "swift",
      picIDCharacter: "a"
    )
    let secondReceipt = try staticImageReceipt(
      attachment: second,
      bytes: secondBytes,
      userID: 9,
      forumName: "swift",
      picIDCharacter: "b"
    )
    let spy = StaticImageAccountClientSpy(
      uploadBehavior: .receipts([
        first.id: firstReceipt,
        second.id: secondReceipt,
      ])
    )
    let service = TiebaCoreAccountService(client: spy)
    let replyID = staticImageUUID(30)
    let replySubmission = try directImageReplySubmission(
      id: replyID,
      attachments: [first, second]
    )
    let replyUploads = try await [
      staticImageUploadResult(
        service: service,
        submissionID: replyID,
        attachment: first,
        bytes: firstBytes
      ),
      staticImageUploadResult(
        service: service,
        submissionID: replyID,
        attachment: second,
        bytes: secondBytes
      ),
    ]

    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: staticImageSession(),
        submission: replySubmission,
        imageUploads: Array(replyUploads.reversed())
      )
    }
    let wrongSubmissionUpload = try await staticImageUploadResult(
      service: service,
      submissionID: staticImageUUID(31),
      attachment: first,
      bytes: firstBytes
    )
    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: staticImageSession(),
        submission: replySubmission,
        imageUploads: [wrongSubmissionUpload, replyUploads[1]]
      )
    }
    let duplicatePicReceipt = try staticImageReceipt(
      attachment: second,
      bytes: secondBytes,
      userID: 9,
      forumName: "swift",
      picIDCharacter: "a"
    )
    let duplicatePicService = TiebaCoreAccountService(
      client: StaticImageAccountClientSpy(uploadBehavior: .receipt(duplicatePicReceipt))
    )
    let duplicatePicUpload = try await staticImageUploadResult(
      service: duplicatePicService,
      submissionID: replyID,
      attachment: second,
      bytes: secondBytes
    )
    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: staticImageSession(),
        submission: replySubmission,
        imageUploads: [replyUploads[0], duplicatePicUpload]
      )
    }
    let mismatchedWatermarkUpload = ComposerImageUploadResult(
      sessionRevision: replyUploads[0].sessionRevision,
      attachment: replyUploads[0].attachment,
      watermark: .none,
      receipt: replyUploads[0].receipt,
      proof: replyUploads[0].proof
    )
    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: staticImageSession(),
        submission: replySubmission,
        imageUploads: [mismatchedWatermarkUpload, replyUploads[1]]
      )
    }
    let rejectedReplySubmissionCount = await spy.replySubmissionCount()
    XCTAssertEqual(rejectedReplySubmissionCount, 0)

    _ = try await service.submitTextReply(
      session: staticImageSession(),
      submission: replySubmission,
      imageUploads: replyUploads
    )
    let recordedReplies = await spy.replySubmissions()
    let recordedReply = try XCTUnwrap(recordedReplies.first)
    XCTAssertEqual(recordedReply.imageProofs.map(\.uploadID), [first.id, second.id])

    let threadID = staticImageUUID(40)
    let threadSubmission = try imageNewThreadSubmission(
      id: threadID,
      attachments: [first, second]
    )
    let threadUploads = try await [
      staticImageUploadResult(
        service: service,
        submissionID: threadID,
        attachment: first,
        bytes: firstBytes
      ),
      staticImageUploadResult(
        service: service,
        submissionID: threadID,
        attachment: second,
        bytes: secondBytes
      ),
    ]
    _ = try await service.submitNewThread(
      session: staticImageSession(),
      submission: threadSubmission,
      imageUploads: threadUploads
    )
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    _ = try await service.verifyNewThreadVisibility(
      session: staticImageSession(),
      submission: threadSubmission,
      receipt: receipt,
      imageUploads: threadUploads
    )

    let recordedThreads = await spy.newThreadSubmissions()
    let recordedVerifications = await spy.visibilitySubmissions()
    let recordedThread = try XCTUnwrap(recordedThreads.first)
    let recordedVerification = try XCTUnwrap(recordedVerifications.first)
    XCTAssertEqual(recordedThread.imageProofs.map(\.uploadID), [first.id, second.id])
    XCTAssertEqual(recordedVerification.imageProofs.map(\.uploadID), [first.id, second.id])
  }

  func testProofForumMismatchIsRejectedAndLegacyTextAPIsDelegateEmptyProofs() async throws {
    let bytes = Data([0x61, 0x62, 0x63])
    let attachment = try staticImageAttachment(id: staticImageUUID(8), bytes: bytes)
    let otherReceipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "other"
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(otherReceipt))
    let service = TiebaCoreAccountService(client: spy)
    let submission = try directImageReplySubmission(
      id: staticImageUUID(50),
      attachments: [attachment]
    )
    let wrongForumUpload = try await staticImageUploadResult(
      service: service,
      submissionID: submission.id,
      forumID: 8,
      forumName: "other",
      attachment: attachment,
      bytes: bytes
    )

    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: staticImageSession(),
        submission: submission,
        imageUploads: [wrongForumUpload]
      )
    }

    let textReply = try directImageReplySubmission(
      id: staticImageUUID(51),
      attachments: []
    )
    let textThread = try imageNewThreadSubmission(
      id: staticImageUUID(52),
      attachments: []
    )
    _ = try await service.submitTextReply(
      session: staticImageSession(),
      submission: textReply
    )
    _ = try await service.submitNewThread(
      session: staticImageSession(),
      submission: textThread
    )
    _ = try await service.verifyNewThreadVisibility(
      session: staticImageSession(),
      submission: textThread,
      receipt: try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    )

    let replies = await spy.replySubmissions()
    let threads = await spy.newThreadSubmissions()
    let verifications = await spy.visibilitySubmissions()
    XCTAssertEqual(replies.last?.imageProofs, [])
    XCTAssertEqual(threads.last?.imageProofs, [])
    XCTAssertEqual(verifications.last?.imageProofs, [])
  }

  func testImageUploadsCannotCrossSessionRevisionForSameUser() async throws {
    let bytes = Data([0x71, 0x72, 0x73])
    let attachment = try staticImageAttachment(id: staticImageUUID(10), bytes: bytes)
    let receipt = try staticImageReceipt(
      attachment: attachment,
      bytes: bytes,
      userID: 9,
      forumName: "swift"
    )
    let spy = StaticImageAccountClientSpy(uploadBehavior: .receipt(receipt))
    let service = TiebaCoreAccountService(client: spy)
    let reply = try directImageReplySubmission(
      id: staticImageUUID(60),
      attachments: [attachment]
    )
    let thread = try imageNewThreadSubmission(
      id: staticImageUUID(61),
      attachments: [attachment]
    )
    let replyUpload = try await staticImageUploadResult(
      service: service,
      submissionID: reply.id,
      attachment: attachment,
      bytes: bytes
    )
    let threadUpload = try await staticImageUploadResult(
      service: service,
      submissionID: thread.id,
      attachment: attachment,
      bytes: bytes
    )
    let replacementSession = staticImageSession(revision: staticImageUUID(201))

    await assertTextReplyImageError(.invalidSubmission) {
      try await service.submitTextReply(
        session: replacementSession,
        submission: reply,
        imageUploads: [replyUpload]
      )
    }
    await assertNewThreadImageError(.invalidSubmission) {
      try await service.submitNewThread(
        session: replacementSession,
        submission: thread,
        imageUploads: [threadUpload]
      )
    }
    await assertNewThreadImageError(.invalidSubmission) {
      try await service.verifyNewThreadVisibility(
        session: replacementSession,
        submission: thread,
        receipt: try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700)),
        imageUploads: [threadUpload]
      )
    }

    let replyCount = await spy.replySubmissionCount()
    let threadCount = await spy.newThreadSubmissionCount()
    let visibilityCount = await spy.visibilitySubmissionCount()
    XCTAssertEqual(replyCount, 0)
    XCTAssertEqual(threadCount, 0)
    XCTAssertEqual(visibilityCount, 0)
  }
}

private struct StaticImageUploadRequest: Sendable {
  let expectedUserID: Int64
  let upload: TiebaStaticImageUpload
  let bdussByteCount: Int
  let stokenByteCount: Int
  let cookieName: TiebaBDUSSCookieName
}

private enum StaticImageUploadBehavior: Sendable {
  case receipt(TiebaStaticImageUploadReceipt)
  case receiptAndCancel(TiebaStaticImageUploadReceipt)
  case receipts([UUID: TiebaStaticImageUploadReceipt])
  case failure(TiebaClientError)
  case cancellation
}

private enum StaticImageAccountSpyError: Error, Sendable {
  case unexpectedCall
}

private actor StaticImageAccountClientSpy: TiebaAuthenticatedAccountClient {
  private let uploadBehavior: StaticImageUploadBehavior
  private var recordedUploadRequests: [StaticImageUploadRequest] = []
  private var recordedReplySubmissions: [TiebaTextReplySubmission] = []
  private var recordedNewThreadSubmissions: [TiebaNewThreadSubmission] = []
  private var recordedVisibilitySubmissions: [TiebaNewThreadSubmission] = []

  init(uploadBehavior: StaticImageUploadBehavior) {
    self.uploadBehavior = uploadBehavior
  }

  func uploadStaticImage(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    upload: TiebaStaticImageUpload
  ) async throws -> TiebaStaticImageUploadReceipt {
    recordedUploadRequests.append(
      StaticImageUploadRequest(
        expectedUserID: expectedUserID,
        upload: upload,
        bdussByteCount: credential.bduss.utf8.count,
        stokenByteCount: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName
      )
    )
    switch uploadBehavior {
    case .receipt(let receipt):
      return receipt
    case .receiptAndCancel(let receipt):
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return receipt
    case .receipts(let receipts):
      guard let receipt = receipts[upload.uploadID] else {
        throw StaticImageAccountSpyError.unexpectedCall
      }
      return receipt
    case .failure(let error):
      throw error
    case .cancellation:
      throw CancellationError()
    }
  }

  func submitTextReply(
    credential _: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    recordedReplySubmissions.append(submission)
    return TiebaTextReplyResult(
      submissionID: submission.submissionID,
      userID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      target: submission.target,
      outcome: .confirmed(.post(postID: 701, floor: 2))
    )
  }

  func submitNewThread(
    credential _: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission
  ) async throws -> TiebaNewThreadResult {
    recordedNewThreadSubmissions.append(submission)
    return TiebaNewThreadResult(
      submissionID: submission.submissionID,
      userID: expectedUserID,
      forumID: submission.forumID,
      forumName: submission.forumName,
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700))
    )
  }

  func verifyNewThreadVisibility(
    credential _: TiebaSessionCredential,
    expectedUserID _: Int64,
    submission: TiebaNewThreadSubmission,
    receipt: TiebaNewThreadReceipt
  ) async throws -> TiebaNewThreadReceipt? {
    recordedVisibilitySubmissions.append(submission)
    return receipt
  }

  func uploadRequests() -> [StaticImageUploadRequest] { recordedUploadRequests }
  func uploadRequestCount() -> Int { recordedUploadRequests.count }
  func replySubmissions() -> [TiebaTextReplySubmission] { recordedReplySubmissions }
  func replySubmissionCount() -> Int { recordedReplySubmissions.count }
  func newThreadSubmissions() -> [TiebaNewThreadSubmission] { recordedNewThreadSubmissions }
  func visibilitySubmissions() -> [TiebaNewThreadSubmission] { recordedVisibilitySubmissions }
  func newThreadSubmissionCount() -> Int { recordedNewThreadSubmissions.count }
  func visibilitySubmissionCount() -> Int { recordedVisibilitySubmissions.count }

  func validateAccount(
    credential _: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw StaticImageAccountSpyError.unexpectedCall
  }

  func getFollowedForums(
    credential _: TiebaBDUSSCredential,
    userID _: Int64,
    page _: Int,
    pageSize _: Int
  ) async throws -> TiebaFollowedForumPage {
    throw StaticImageAccountSpyError.unexpectedCall
  }

  func getForumMembership(
    credential _: TiebaBDUSSCredential,
    expectedUserID _: Int64,
    forumID _: Int64,
    forumName _: String
  ) async throws -> TiebaForumMembership {
    throw StaticImageAccountSpyError.unexpectedCall
  }

  func getForumAccountState(
    credential _: TiebaBDUSSCredential,
    expectedUserID _: Int64,
    forumID _: Int64,
    forumName _: String
  ) async throws -> TiebaForumAccountState {
    throw StaticImageAccountSpyError.unexpectedCall
  }

  func setForumFollowState(
    credential _: TiebaBDUSSCredential,
    expectedUserID _: Int64,
    forumID _: Int64,
    forumName _: String,
    isFollowed _: Bool
  ) async throws -> TiebaForumMembership {
    throw StaticImageAccountSpyError.unexpectedCall
  }

  func checkInToForum(
    credential _: TiebaBDUSSCredential,
    expectedUserID _: Int64,
    forumID _: Int64,
    forumName _: String
  ) async throws -> TiebaForumAccountState {
    throw StaticImageAccountSpyError.unexpectedCall
  }
}

private actor StaticImageLedgerPendingSpy {
  private struct Identity: Sendable, Equatable {
    let sessionUserID: Int64
    let sessionRevision: UUID
    let submissionID: UUID
    let forumID: Int64
    let attachmentID: UUID
  }

  private var pendingIdentity: Identity?

  func persistPending(_ prepared: ComposerPreparedImageUpload) {
    pendingIdentity = Self.identity(prepared)
  }

  func contains(_ prepared: ComposerPreparedImageUpload) -> Bool {
    pendingIdentity == Self.identity(prepared)
  }

  private static func identity(_ prepared: ComposerPreparedImageUpload) -> Identity {
    Identity(
      sessionUserID: prepared.sessionUserID,
      sessionRevision: prepared.sessionRevision,
      submissionID: prepared.submissionID,
      forumID: prepared.forumID,
      attachmentID: prepared.attachment.id
    )
  }
}

private func staticImageAttachment(
  id: UUID,
  bytes: Data,
  width: Int = 640,
  height: Int = 480,
  quality: ComposerImageAttachmentQuality = .standard
) throws -> ComposerImageAttachment {
  try XCTUnwrap(
    ComposerImageAttachment(
      id: id,
      sha256: staticImageSHA256(bytes),
      byteCount: Int64(bytes.count),
      pixelWidth: width,
      pixelHeight: height,
      quality: quality
    )
  )
}

private func staticImageReceipt(
  attachment: ComposerImageAttachment,
  bytes: Data,
  userID: Int64,
  forumName: String,
  uploadID: UUID? = nil,
  preservesOriginal: Bool = false,
  watermark: TiebaStaticImageWatermark = .forumName,
  picIDCharacter: Character = "a"
) throws -> TiebaStaticImageUploadReceipt {
  let object: [String: Any] = [
    "schemaVersion": TiebaStaticImageUploadReceipt.currentSchemaVersion,
    "uploadID": (uploadID ?? attachment.id).uuidString.lowercased(),
    "contentSHA256": staticImageSHA256(bytes),
    "userID": userID,
    "forumName": forumName,
    "preservesOriginal": preservesOriginal,
    "watermark": watermark.rawValue,
    "uploadedPixelWidth": attachment.pixelWidth,
    "uploadedPixelHeight": attachment.pixelHeight,
    "resourceID": staticImageMD5(bytes) + String(TiebaStaticImageUploadPolicy.chunkSize),
    "picID": String(repeating: String(picIDCharacter), count: 40),
    "width": attachment.pixelWidth,
    "height": attachment.pixelHeight,
    "byteCount": bytes.count,
    "chunkCount": (bytes.count - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1,
  ]
  return try JSONDecoder().decode(
    TiebaStaticImageUploadReceipt.self,
    from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  )
}

private func directImageReplySubmission(
  id: UUID,
  attachments: [ComposerImageAttachment]
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
      content: "正文",
      attachments: attachments
    )
  )
}

private func imageNewThreadSubmission(
  id: UUID,
  attachments: [ComposerImageAttachment]
) throws -> NewThreadSubmission {
  try XCTUnwrap(
    NewThreadSubmission(
      id: id,
      target: try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift")),
      title: "标题",
      content: "正文",
      attachments: attachments
    )
  )
}

private func staticImageUploadResult(
  service: TiebaCoreAccountService,
  submissionID: UUID,
  forumID: Int64 = 7,
  forumName: String = "swift",
  attachment: ComposerImageAttachment,
  bytes: Data
) async throws -> ComposerImageUploadResult {
  let prepared = try await service.prepareStaticImageUpload(
    session: staticImageSession(),
    submissionID: submissionID,
    forumID: forumID,
    forumName: forumName,
    attachment: attachment,
    validatedBytes: bytes,
    watermark: .forumName
  )
  return try await service.dispatchStaticImageUpload(prepared)
}

private func staticImageSession(
  userID: Int64 = 9,
  bduss: String = String(repeating: "b", count: AccountCredentialFormat.bdussLength),
  stoken: String? = String(repeating: "s", count: AccountCredentialFormat.stokenLength),
  cookieName: AccountBDUSSCookieName = .bduss,
  revision: UUID = staticImageUUID(200)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: bduss,
    stoken: stoken,
    bdussCookieName: cookieName,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func staticImageSHA256(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func staticImageMD5(_ bytes: Data) -> String {
  Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func staticImageUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func assertStaticImagePreparationError<T: Sendable>(
  _ expected: ComposerImageUploadPreparationError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as ComposerImageUploadPreparationError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}

private func assertStaticImageError<T: Sendable>(
  _ expected: ComposerImageUploadError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as ComposerImageUploadError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}

private func assertTextReplyImageError<T: Sendable>(
  _ expected: TextReplySubmissionError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as TextReplySubmissionError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}

private func assertNewThreadImageError<T: Sendable>(
  _ expected: NewThreadSubmissionError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as NewThreadSubmissionError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
