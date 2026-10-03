import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import TiebaCore
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

final class ComposerWebPPersistenceTests: XCTestCase {
  func testMixedOriginalDraftsRestoreOrderAndUploadExactProcessedBytes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(root)
    let sources: [Data] = [
      try encodedImage(.jpeg), try encodedImage(.png), try encodedImage(.gif),
      ComposerWebPTestFixture.withMetadata(ComposerWebPTestFixture.lossless, orientation: 1),
      ComposerWebPTestFixture.animated(),
    ]
    let expectedEncodings: [ComposerImageAttachmentEncoding] = [.jpeg, .png, .gif, .webp, .webp]
    var attachments = [ComposerImageAttachment]()
    var expectedBytes = [UUID: Data]()
    for (index, source) in sources.enumerated() {
      let processed = try ComposerImageAttachmentProcessor().process(
        data: source, quality: .original)
      let attachment = try await store.importImage(data: source, quality: .original)
      XCTAssertEqual(attachment.encoding, expectedEncodings[index])
      XCTAssertTrue(
        ComposerImageAttachment.isValidRelativePrivateFilename(attachment.relativePrivateFilename))
      XCTAssertEqual(attachment.byteCount, Int64(processed.data.count))
      XCTAssertEqual(attachment.sha256, hexadecimal(SHA256.hash(data: processed.data)))
      if index == 3 {
        XCTAssertNotEqual(
          processed.data, source, "Persist the sanitized WebP, not its private metadata.")
      }
      attachments.append(attachment)
      expectedBytes[attachment.id] = processed.data
    }
    // Exercise the same ordering operation used by the composer, including a
    // WebP animation between older supported formats rather than a WebP-only draft.
    let ordered = ComposerImagePickerPolicy.moving(attachments, from: 4, by: -3)
    XCTAssertEqual(ordered.map(\.encoding), [.jpeg, .webp, .png, .gif, .webp])
    let threadTarget = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
    let threadKey = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: threadTarget))
    let threadDraft = try XCTUnwrap(
      NewThreadDraft(
        key: threadKey, title: "WebP 混合草稿", content: "离线图片测试",
        attachments: ordered, imageWatermark: .none))
    let threadFile = root.appendingPathComponent("thread-drafts.json")
    try await FileNewThreadDraftStore(fileURL: threadFile).save(threadDraft)
    let loadedThread = try await FileNewThreadDraftStore(fileURL: threadFile).draft(for: threadKey)
    let restoredThread = try XCTUnwrap(loadedThread)
    XCTAssertEqual(restoredThread, threadDraft)

    let replyTarget = try makeReplyTarget()
    let replyKey = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget))
    let replyDraft = try XCTUnwrap(
      TextReplyDraft(
        key: replyKey, content: "混合图片回复", attachments: ordered, imageWatermark: .none))
    let replyFile = root.appendingPathComponent("reply-drafts.json")
    try await FileTextReplyDraftStore(fileURL: replyFile).save(replyDraft)
    let loadedReply = try await FileTextReplyDraftStore(fileURL: replyFile).draft(for: replyKey)
    XCTAssertEqual(loadedReply, replyDraft)

    // A newly-created store has no in-memory imported image or format cache.
    let restoredStore = makeStore(root)
    for attachment in restoredThread.attachments {
      let bytes = try await restoredStore.validatedData(for: attachment)
      XCTAssertEqual(bytes, expectedBytes[attachment.id])
    }
    try await verifyPipeline(
      root: root, attachments: restoredThread.attachments,
      expectedBytes: expectedBytes, isReply: false)
  }

  func testAnimatedWebPReplyRestoresReceiptWithoutUploadingAgain() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = ComposerWebPTestFixture.animated()
    let attachment = try await makeStore(root).importImage(data: source, quality: .original)
    XCTAssertEqual(attachment.encoding, .webp)
    XCTAssertEqual(ComposerImagePickerPolicy.formatBadge(for: attachment.encoding), "WebP")
    XCTAssertTrue(attachment.relativePrivateFilename.hasSuffix(".webp"))
    let bytes = try await makeStore(root).validatedData(for: attachment)
    XCTAssertEqual(bytes, source, "The clean animation must remain encoded, not flattened.")
    try await verifyPipeline(
      root: root, attachments: [attachment], expectedBytes: [attachment.id: source], isReply: true)
  }

  func testWrongFilenameAndEncodingRelabellingCannotBypassStoreValidation() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(root)
    let webp = try await store.importImage(
      data: ComposerWebPTestFixture.lossless, quality: .original)
    let bytes = try await store.validatedData(for: webp)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(webp)) as? [String: Any])
    for suffix in ["png", "jpg", "gif", "WEBP", "webp.jpg"] {
      var forged = json
      forged["relativePrivateFilename"] = "\(webp.id.uuidString.lowercased()).\(suffix)"
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          ComposerImageAttachment.self, from: JSONSerialization.data(withJSONObject: forged)))
    }
    for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
      XCTAssertNil(
        ComposerImageAttachment(
          id: UUID(), sha256: webp.sha256, byteCount: webp.byteCount,
          pixelWidth: webp.pixelWidth, pixelHeight: webp.pixelHeight, encoding: .webp,
          quality: quality))
    }
    for encoding in [ComposerImageAttachmentEncoding.jpeg, .png, .gif] {
      try await assertRelabelRejected(bytes: bytes, encoding: encoding, root: root, store: store)
    }
    let jpeg = try await store.importImage(data: encodedImage(.jpeg), quality: .original)
    let jpegBytes = try await store.validatedData(for: jpeg)
    try await assertRelabelRejected(bytes: jpegBytes, encoding: .webp, root: root, store: store)
    let unchanged = try await store.validatedData(for: webp)
    XCTAssertEqual(unchanged, bytes)
  }

  func testUnknownWebPUploadOutcomeStaysLockedAfterReopeningLedger() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(root)
    let source = ComposerWebPTestFixture.animated()
    let attachment = try await store.importImage(data: source, quality: .original)
    let session = makeSession()
    let client = WebPPersistenceClient(failsUpload: true)
    let access = AccountAccess(
      vault: WebPPersistenceVault(session: session),
      service: TiebaCoreAccountService(client: client))
    let ledgerFile = root.appendingPathComponent("unknown-upload-ledger.json")
    let pipeline = ComposerImageSubmissionPipeline(
      access: access, attachmentStore: store, ledger: makeLedger(ledgerFile))
    let submission = try XCTUnwrap(
      TextReplySubmission(
        target: makeReplyTarget(), content: "离线上传结果未知", attachments: [attachment]))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submission.id, sessionRevision: session.sessionRevision))
    let operation = ComposerImageUploadOutcomeUnknownOperation.attachment(
      attachmentID: attachment.id)
    try await pipeline.prepareDirectTopicReply(submission: submission, reference: reference)
    do {
      _ = try await pipeline.executeDirectTopicReply(submission: submission, reference: reference)
      XCTFail("The interrupted upload must report an unknown outcome.")
    } catch {
      XCTAssertEqual(error as? ComposerImageSubmissionPipelineError, .outcomeUnknown(operation))
    }

    let restarted = ComposerImageSubmissionPipeline(
      access: access, attachmentStore: makeStore(root), ledger: makeLedger(ledgerFile))
    let state = try await restarted.recoveryState(
      for: XCTUnwrap(ComposerImageSubmissionIntent(directTopicReply: submission)),
      reference: reference, userID: session.id)
    XCTAssertEqual(state, .locked(reference: reference, operation: operation))
    do {
      _ = try await restarted.executeDirectTopicReply(submission: submission, reference: reference)
      XCTFail("Reopening must not authorize a duplicate upload.")
    } catch {
      XCTAssertEqual(error as? ComposerImageSubmissionPipelineError, .locked(operation))
    }
    let uploads = await client.uploads
    let finalCalls = await client.finalCalls
    let retainedBytes = try await makeStore(root).validatedData(for: attachment)
    XCTAssertEqual(uploads.count, 1)
    XCTAssertEqual(uploads.first?.encodedBytes, source)
    XCTAssertEqual(finalCalls, 0)
    XCTAssertEqual(retainedBytes, source)
  }

  private func verifyPipeline(
    root: URL, attachments: [ComposerImageAttachment], expectedBytes: [UUID: Data], isReply: Bool
  ) async throws {
    let session = makeSession()
    let client = WebPPersistenceClient()
    let service = TiebaCoreAccountService(client: client)
    let access = AccountAccess(vault: WebPPersistenceVault(session: session), service: service)
    let ledgerFile = root.appendingPathComponent("upload-ledger.json")
    let ledger = makeLedger(ledgerFile)
    let pipeline = ComposerImageSubmissionPipeline(
      access: access, attachmentStore: makeStore(root), ledger: ledger)
    let submissionID = UUID()
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID, sessionRevision: session.sessionRevision))
    let intent: ComposerImageSubmissionIntent
    if isReply {
      let submission = try XCTUnwrap(
        TextReplySubmission(
          id: submissionID, target: makeReplyTarget(), content: "离线 WebP 回复",
          attachments: attachments, imageWatermark: .none))
      intent = try XCTUnwrap(ComposerImageSubmissionIntent(directTopicReply: submission))
      try await pipeline.prepareDirectTopicReply(submission: submission, reference: reference)
      _ = try await pipeline.executeDirectTopicReply(submission: submission, reference: reference)
    } else {
      let submission = try XCTUnwrap(
        NewThreadSubmission(
          id: submissionID, target: XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift")),
          title: "离线 WebP 主题", content: "混合格式附件",
          attachments: attachments, imageWatermark: .none))
      intent = try XCTUnwrap(ComposerImageSubmissionIntent(newThread: submission))
      try await pipeline.prepareNewThread(submission: submission, reference: reference)
      _ = try await pipeline.executeNewThread(submission: submission, reference: reference)
    }
    let observedUploads = await client.uploads
    XCTAssertEqual(observedUploads.map(\.uploadID), attachments.map(\.id))
    for (upload, attachment) in zip(observedUploads, attachments) {
      XCTAssertEqual(upload.encodedBytes, expectedBytes[attachment.id])
      XCTAssertEqual(upload.pixelWidth, attachment.pixelWidth)
      XCTAssertEqual(upload.pixelHeight, attachment.pixelHeight)
      XCTAssertTrue(upload.preservesOriginal)
      XCTAssertEqual(upload.watermark, .none)
    }
    let finalProofs = await client.finalProofs
    XCTAssertEqual(finalProofs.map(\.uploadID), attachments.map(\.id))
    XCTAssertTrue(
      finalProofs.allSatisfy {
        $0.submissionID == submissionID && $0.userID == 9 && $0.forumID == 7
      })

    // Reopen both disk stores, then bind the authenticated receipts against the
    // freshly-read bytes through the real account service and pipeline.
    let restarted = ComposerImageSubmissionPipeline(
      access: access, attachmentStore: makeStore(root), ledger: makeLedger(ledgerFile))
    let recovered = try await restarted.recoverUploadsForVisibility(
      intent: intent, reference: reference)
    XCTAssertEqual(recovered.map(\.attachment), attachments)
    XCTAssertEqual(recovered.map(\.proof), finalProofs)
    for (result, attachment) in zip(recovered, attachments) {
      XCTAssertEqual(result.receipt.uploadID, attachment.id)
      XCTAssertEqual(result.receipt.contentSHA256, attachment.sha256)
      XCTAssertEqual(result.receipt.byteCount, Int(attachment.byteCount))
      XCTAssertEqual(result.sessionRevision, session.sessionRevision)
      XCTAssertTrue(result.receipt.preservesOriginal)
    }
    let afterRecoveryUploads = await client.uploads
    XCTAssertEqual(afterRecoveryUploads.count, attachments.count)
    let finalCalls = await client.finalCalls
    XCTAssertEqual(finalCalls, 1)

    // A receipt for this byte stream still cannot be relabelled as another
    // attachment, even if encoding, dimensions and all bytes are identical.
    let first = try XCTUnwrap(attachments.first)
    let duplicate = try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(), sha256: first.sha256, byteCount: first.byteCount,
        pixelWidth: first.pixelWidth, pixelHeight: first.pixelHeight,
        encoding: first.encoding, quality: first.quality))
    let prepared = try await service.prepareStaticImageUpload(
      session: session, submissionID: submissionID, forumID: 7, forumName: "swift",
      attachment: duplicate, validatedBytes: XCTUnwrap(expectedBytes[first.id]), watermark: .none)
    do {
      _ = try await service.recoverStaticImageUpload(
        prepared, authenticatedReceipt: recovered[0].receipt)
      XCTFail("A receipt for a different attachment identity must not bind.")
    } catch {
      XCTAssertEqual(error as? ComposerImageUploadError, .invalidReceipt)
    }
  }

  private func assertRelabelRejected(
    bytes: Data, encoding: ComposerImageAttachmentEncoding, root: URL,
    store: ComposerImageAttachmentStore
  ) async throws {
    let forged = try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(), sha256: hexadecimal(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count),
        pixelWidth: 8, pixelHeight: 6, encoding: encoding, quality: .original))
    try bytes.write(
      to: root.appendingPathComponent("attachments").appendingPathComponent(
        forged.relativePrivateFilename))
    do {
      _ = try await store.validatedData(for: forged)
      XCTFail("Matching hash and filename must not override the encoded image format.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .storedFileTampered)
    }
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerWebP-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeStore(_ root: URL) -> ComposerImageAttachmentStore {
    ComposerImageAttachmentStore(
      directoryURL: root.appendingPathComponent("attachments"), trustedRootURL: root)
  }

  private func makeLedger(_ file: URL) -> ComposerImageUploadLedger {
    ComposerImageUploadLedger(
      fileURL: file,
      authenticator: ComposerImageUploadLedgerHMACAuthenticator(
        testingKey: Data(repeating: 0x57, count: 32)))
  }

  private func makeReplyTarget() throws -> TextReplyTarget {
    try XCTUnwrap(
      TextReplyTarget(
        forumID: 7, forumName: "swift", threadID: 70, firstPostID: 700,
        destination: .thread(firstPostID: 700)))
  }

  private func makeSession() -> StoredAccountSession {
    StoredAccountSession(
      id: 9, username: "offline-webp", displayName: "Offline", portrait: "",
      bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
      stoken: String(repeating: "s", count: AccountCredentialFormat.stokenLength),
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
  }

  private func encodedImage(_ type: UTType) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
  digest.map { String(format: "%02x", $0) }.joined()
}

private enum WebPPersistenceFailure: Error { case unexpectedCall }

private struct WebPPersistenceVault: AccountVault {
  let session: StoredAccountSession
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? { session }
  func upsert(_ session: StoredAccountSession) async throws {
    throw WebPPersistenceFailure.unexpectedCall
  }
  func switchActive(to userID: Int64) async throws { throw WebPPersistenceFailure.unexpectedCall }
  func remove(userID: Int64) async throws { throw WebPPersistenceFailure.unexpectedCall }
  func removeAll() async throws { throw WebPPersistenceFailure.unexpectedCall }
}

/// The real account service builds and validates upload/proof objects; only the
/// final network boundary is replaced, so no live account or transport exists.
private actor WebPPersistenceClient: TiebaAuthenticatedAccountClient {
  private let failsUpload: Bool
  private(set) var uploads: [TiebaStaticImageUpload] = []
  private(set) var finalProofs: [TiebaStaticImageContentProof] = []
  private(set) var finalCalls = 0

  init(failsUpload: Bool = false) { self.failsUpload = failsUpload }

  func uploadStaticImage(
    credential: TiebaSessionCredential, expectedUserID: Int64, upload: TiebaStaticImageUpload
  ) async throws -> TiebaStaticImageUploadReceipt {
    uploads.append(upload)
    if failsUpload {
      throw TiebaClientError.staticImageUploadOutcomeUnknown(
        uploadID: upload.uploadID, dispatchedChunk: 1)
    }
    let object: [String: Any] = [
      "schemaVersion": TiebaStaticImageUploadReceipt.currentSchemaVersion,
      "uploadID": upload.uploadID.uuidString,
      "contentSHA256": hexadecimal(SHA256.hash(data: upload.encodedBytes)),
      "userID": expectedUserID, "forumName": upload.forumName,
      "preservesOriginal": upload.preservesOriginal, "watermark": upload.watermark.rawValue,
      "uploadedPixelWidth": upload.pixelWidth, "uploadedPixelHeight": upload.pixelHeight,
      "resourceID": hexadecimal(Insecure.MD5.hash(data: upload.encodedBytes))
        + String(TiebaStaticImageUploadPolicy.chunkSize),
      "picID": String(hexadecimal(SHA256.hash(data: upload.encodedBytes)).prefix(40)),
      "width": upload.pixelWidth, "height": upload.pixelHeight,
      "byteCount": upload.encodedBytes.count,
      "chunkCount": (upload.encodedBytes.count - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1,
    ]
    return try JSONDecoder().decode(
      TiebaStaticImageUploadReceipt.self, from: JSONSerialization.data(withJSONObject: object))
  }

  func submitNewThread(
    credential: TiebaSessionCredential, expectedUserID: Int64, submission: TiebaNewThreadSubmission
  ) async throws -> TiebaNewThreadResult {
    finalCalls += 1
    finalProofs = submission.imageProofs
    return TiebaNewThreadResult(
      submissionID: submission.submissionID, userID: expectedUserID, forumID: submission.forumID,
      forumName: submission.forumName,
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)))
  }

  func submitTextReply(
    credential: TiebaSessionCredential, expectedUserID: Int64, submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    finalCalls += 1
    finalProofs = submission.imageProofs
    return TiebaTextReplyResult(
      submissionID: submission.submissionID, userID: expectedUserID, forumID: submission.forumID,
      threadID: submission.threadID, target: submission.target,
      outcome: .confirmed(.post(postID: 701, floor: 2)))
  }

  func validateAccount(credential: TiebaBDUSSCredential) async throws -> TiebaAuthenticatedAccount {
    throw WebPPersistenceFailure.unexpectedCall
  }
  func getFollowedForums(
    credential: TiebaBDUSSCredential, userID: Int64, page: Int, pageSize: Int
  ) async throws -> TiebaFollowedForumPage { throw WebPPersistenceFailure.unexpectedCall }
  func getForumMembership(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumMembership { throw WebPPersistenceFailure.unexpectedCall }
  func getForumAccountState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw WebPPersistenceFailure.unexpectedCall }
  func setForumFollowState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership { throw WebPPersistenceFailure.unexpectedCall }
  func checkInToForum(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw WebPPersistenceFailure.unexpectedCall }
}
