import Foundation
import TiebaCore

struct ComposerImageSubmissionIntent:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  enum Kind: Hashable, Sendable {
    case newThread
    case directTopicReply
  }

  fileprivate enum Payload: Hashable, Sendable {
    case newThread(NewThreadSubmission)
    case directTopicReply(TextReplySubmission)
  }

  fileprivate let payload: Payload

  init?(newThread submission: NewThreadSubmission) {
    guard
      !submission.attachments.isEmpty,
      ComposerImageUploadContext(newThread: submission.target) != nil,
      let validated = NewThreadSubmission(
        id: submission.id,
        target: submission.target,
        title: submission.title,
        content: submission.content,
        attachments: submission.attachments,
        imageWatermark: submission.imageWatermark
      ),
      validated == submission,
      Self.snapshots(
        attachments: submission.attachments,
        watermark: submission.imageWatermark
      ) != nil
    else { return nil }
    payload = .newThread(submission)
  }

  init?(directTopicReply submission: TextReplySubmission) {
    guard
      !submission.attachments.isEmpty,
      ComposerImageUploadContext(directTopicReply: submission.target) != nil,
      let validated = TextReplySubmission(
        id: submission.id,
        target: submission.target,
        content: submission.content,
        attachments: submission.attachments,
        imageWatermark: submission.imageWatermark
      ),
      validated == submission,
      Self.snapshots(
        attachments: submission.attachments,
        watermark: submission.imageWatermark
      ) != nil
    else { return nil }
    payload = .directTopicReply(submission)
  }

  var kind: Kind {
    switch payload {
    case .newThread:
      .newThread
    case .directTopicReply:
      .directTopicReply
    }
  }

  var submissionID: UUID {
    switch payload {
    case .newThread(let submission):
      submission.id
    case .directTopicReply(let submission):
      submission.id
    }
  }

  var context: ComposerImageUploadContext {
    switch payload {
    case .newThread(let submission):
      ComposerImageUploadContext(newThread: submission.target)!
    case .directTopicReply(let submission):
      ComposerImageUploadContext(directTopicReply: submission.target)!
    }
  }

  var attachments: [ComposerImageAttachment] {
    switch payload {
    case .newThread(let submission):
      submission.attachments
    case .directTopicReply(let submission):
      submission.attachments
    }
  }

  var imageWatermark: TiebaStaticImageWatermark {
    switch payload {
    case .newThread(let submission):
      submission.imageWatermark
    case .directTopicReply(let submission):
      submission.imageWatermark
    }
  }

  var description: String { "ComposerImageSubmissionIntent.\(kind)(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: ["kind": kind], displayStyle: .struct) }

  fileprivate var attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot] {
    Self.snapshots(attachments: attachments, watermark: imageWatermark)!
  }

  fileprivate func matches(_ record: ComposerImageUploadLedgerRecord) -> Bool {
    let snapshots = attachmentSnapshots
    switch payload {
    case .newThread(let submission):
      return record.matchesIntent(
        newThreadSubmission: submission,
        key: record.key,
        attachmentSnapshots: snapshots
      )
    case .directTopicReply(let submission):
      return record.matchesIntent(
        directTopicReplySubmission: submission,
        key: record.key,
        attachmentSnapshots: snapshots
      )
    }
  }

  private static func snapshots(
    attachments: [ComposerImageAttachment],
    watermark: TiebaStaticImageWatermark
  ) -> [ComposerImageUploadAttachmentSnapshot]? {
    let snapshots = attachments.compactMap {
      ComposerImageUploadAttachmentSnapshot(attachment: $0, watermark: watermark)
    }
    guard snapshots.count == attachments.count else { return nil }
    return snapshots
  }
}

enum ComposerImageSubmissionRecoveryState: Hashable, Sendable {
  case uploadResumeRequired(
    reference: ComposerImageSubmissionReference,
    successfulUploadCount: Int,
    totalAttachmentCount: Int
  )
  case finalSubmissionResumeRequired(reference: ComposerImageSubmissionReference)
  case locked(
    reference: ComposerImageSubmissionReference,
    operation: ComposerImageUploadOutcomeUnknownOperation
  )
  case completed(reference: ComposerImageSubmissionReference)

  var reference: ComposerImageSubmissionReference {
    switch self {
    case .uploadResumeRequired(let reference, _, _),
      .finalSubmissionResumeRequired(let reference),
      .locked(let reference, _),
      .completed(let reference):
      reference
    }
  }
}

enum ComposerImageSubmissionPipelineError:
  LocalizedError, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case invalidIntent
  case referenceMismatch
  case signedOut
  case fullCredentialsRequired
  case accountChanged
  case recordNotFound
  case intentMismatch
  case activeRecordExists
  case uploadResumeRequired
  case finalSubmissionResumeRequired
  case locked(ComposerImageUploadOutcomeUnknownOperation)
  case completed
  case attachmentUnavailable
  case preparationFailed
  case ledgerUnavailable
  case invalidState
  case outcomeUnknown(ComposerImageUploadOutcomeUnknownOperation)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidIntent:
      "图片发布内容或目标无效，未开始发送。"
    case .referenceMismatch:
      "图片发布引用与当前提交不匹配，未开始发送。"
    case .signedOut:
      "请先登录贴吧账户后再发布图片。"
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全发布图片。"
    case .accountChanged:
      "图片发布期间账户已改变，未继续发送。"
    case .recordNotFound:
      "没有找到这次图片发布的安全恢复记录。"
    case .intentMismatch:
      "安全恢复记录与当前图片、正文或发布位置不匹配。"
    case .activeRecordExists:
      "此账户和发布位置已有一条尚未清理的图片发布记录。"
    case .uploadResumeRequired:
      "图片上传需要由您明确继续，应用不会自动发送。"
    case .finalSubmissionResumeRequired:
      "最终发布需要由您明确继续，应用不会自动发送。"
    case .locked:
      "上一次网络操作的结果尚未确认，当前图片发布已锁定。"
    case .completed:
      "这次图片发布已经完成。"
    case .attachmentUnavailable:
      "无法读取并验证本地图片附件，未继续发送。"
    case .preparationFailed:
      "无法安全准备图片上传，未开始发送。"
    case .ledgerUnavailable:
      "无法安全读取或保存图片发布恢复记录。"
    case .invalidState:
      "图片发布恢复状态无效，未继续操作。"
    case .outcomeUnknown:
      "网络请求已经开始，但结果无法确认；应用不会自动重试。"
    case .unavailable:
      "当前无法安全继续图片发布。"
    }
  }

  var description: String {
    switch self {
    case .invalidIntent:
      "ComposerImageSubmissionPipelineError.invalidIntent(redacted)"
    case .referenceMismatch:
      "ComposerImageSubmissionPipelineError.referenceMismatch(redacted)"
    case .signedOut:
      "ComposerImageSubmissionPipelineError.signedOut"
    case .fullCredentialsRequired:
      "ComposerImageSubmissionPipelineError.fullCredentialsRequired"
    case .accountChanged:
      "ComposerImageSubmissionPipelineError.accountChanged"
    case .recordNotFound:
      "ComposerImageSubmissionPipelineError.recordNotFound(redacted)"
    case .intentMismatch:
      "ComposerImageSubmissionPipelineError.intentMismatch(redacted)"
    case .activeRecordExists:
      "ComposerImageSubmissionPipelineError.activeRecordExists(redacted)"
    case .uploadResumeRequired:
      "ComposerImageSubmissionPipelineError.uploadResumeRequired"
    case .finalSubmissionResumeRequired:
      "ComposerImageSubmissionPipelineError.finalSubmissionResumeRequired"
    case .locked:
      "ComposerImageSubmissionPipelineError.locked(redacted)"
    case .completed:
      "ComposerImageSubmissionPipelineError.completed"
    case .attachmentUnavailable:
      "ComposerImageSubmissionPipelineError.attachmentUnavailable(redacted)"
    case .preparationFailed:
      "ComposerImageSubmissionPipelineError.preparationFailed(redacted)"
    case .ledgerUnavailable:
      "ComposerImageSubmissionPipelineError.ledgerUnavailable(redacted)"
    case .invalidState:
      "ComposerImageSubmissionPipelineError.invalidState(redacted)"
    case .outcomeUnknown:
      "ComposerImageSubmissionPipelineError.outcomeUnknown(redacted)"
    case .unavailable:
      "ComposerImageSubmissionPipelineError.unavailable(redacted)"
    }
  }

  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

protocol ComposerImageSubmissionPipelining: Sendable {
  func prepareNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState
  func prepareDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState
  func prepare(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState
  func blockingRecoveryState(
    for context: ComposerImageUploadContext,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState?
  func blockingRecoveryState(
    for intent: ComposerImageSubmissionIntent,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState?
  func recoveryState(
    for intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState?
  func executeNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> NewThreadResult
  func executeDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> TextReplyResult
  func recoverNewThreadUploadsForVisibility(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult]
  func recoverDirectTopicReplyUploadsForVisibility(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult]
  func recoverUploadsForVisibility(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult]
  func markCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState
  func removeAttachments(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws
  func deleteCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws
}

actor ComposerImageSubmissionPipeline: ComposerImageSubmissionPipelining {
  private enum FinalResult: Sendable {
    case newThread(NewThreadResult)
    case directTopicReply(TextReplyResult)
  }

  private let access: AccountAccess
  private let attachmentStore: ComposerImageAttachmentStore
  private let ledger: ComposerImageUploadLedger
  private let attachmentDeletionScheduler: (any ComposerImageAttachmentDeletionScheduling)?

  init(
    access: AccountAccess,
    attachmentStore: ComposerImageAttachmentStore,
    ledger: ComposerImageUploadLedger,
    attachmentDeletionScheduler: (any ComposerImageAttachmentDeletionScheduling)? = nil
  ) {
    self.access = access
    self.attachmentStore = attachmentStore
    self.ledger = ledger
    self.attachmentDeletionScheduler = attachmentDeletionScheduler
  }

  @discardableResult
  func prepareNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard let intent = ComposerImageSubmissionIntent(newThread: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    return try await prepare(intent: intent, reference: reference)
  }

  @discardableResult
  func prepareDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard let intent = ComposerImageSubmissionIntent(directTopicReply: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    return try await prepare(intent: intent, reference: reference)
  }

  @discardableResult
  func prepare(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard intent.submissionID == reference.submissionID else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    try Task.checkCancellation()
    let session = try await activeSessionForPreparation(reference: reference)
    guard
      let key = ComposerImageUploadLedgerKey(
        context: intent.context,
        userID: session.id,
        sessionRevision: reference.sessionRevision,
        submissionID: reference.submissionID
      )
    else { throw ComposerImageSubmissionPipelineError.invalidIntent }

    let record: ComposerImageUploadLedgerRecord
    do {
      switch intent.payload {
      case .newThread(let submission):
        record = try await ledger.prepare(
          newThreadSubmission: submission,
          key: key,
          attachmentSnapshots: intent.attachmentSnapshots
        )
      case .directTopicReply(let submission):
        record = try await ledger.prepare(
          directTopicReplySubmission: submission,
          key: key,
          attachmentSnapshots: intent.attachmentSnapshots
        )
      }
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }
    return try Self.recoveryState(for: record)
  }

  /// Finds an orphaned context owner without needing a draft. This never authorizes execution;
  /// callers with a reconstructable draft must use the intent overload for digest verification.
  func blockingRecoveryState(
    for context: ComposerImageUploadContext,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard userID > 0 else { throw ComposerImageSubmissionPipelineError.invalidIntent }
    let record: ComposerImageUploadLedgerRecord?
    do {
      record = try await ledger.record(for: context, userID: userID)
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }
    guard let record else { return nil }
    return try Self.recoveryState(for: record)
  }

  /// Verifies the complete immutable submission intent before exposing its recovery state.
  func blockingRecoveryState(
    for intent: ComposerImageSubmissionIntent,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    let state = try await blockingRecoveryState(for: intent.context, userID: userID)
    guard let state else { return nil }
    let record = try await resolvedRecord(
      for: intent,
      reference: state.reference,
      expectedUserID: userID
    )
    return try Self.recoveryState(for: record)
  }

  func recoveryState(
    for intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard
      userID > 0,
      intent.submissionID == reference.submissionID
    else { throw ComposerImageSubmissionPipelineError.referenceMismatch }
    let state = try await blockingRecoveryState(for: intent, userID: userID)
    guard let state else { return nil }
    guard state.reference == reference else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    return state
  }

  func executeNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> NewThreadResult {
    guard let intent = ComposerImageSubmissionIntent(newThread: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    let result = try await execute(intent: intent, reference: reference)
    guard case .newThread(let newThreadResult) = result else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    return newThreadResult
  }

  func executeDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> TextReplyResult {
    guard let intent = ComposerImageSubmissionIntent(directTopicReply: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    let result = try await execute(intent: intent, reference: reference)
    guard case .directTopicReply(let replyResult) = result else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    return replyResult
  }

  func recoverNewThreadUploadsForVisibility(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    guard let intent = ComposerImageSubmissionIntent(newThread: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    return try await recoverUploadsForVisibility(intent: intent, reference: reference)
  }

  func recoverDirectTopicReplyUploadsForVisibility(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    guard let intent = ComposerImageSubmissionIntent(directTopicReply: submission) else {
      throw ComposerImageSubmissionPipelineError.invalidIntent
    }
    return try await recoverUploadsForVisibility(intent: intent, reference: reference)
  }

  func recoverUploadsForVisibility(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    let record = try await resolvedRecord(for: intent, reference: reference)
    switch record.stage {
    case .finalSubmissionPending, .completed:
      break
    case .prepared, .attachmentDispatchPending, .uploadsComplete, .outcomeUnknown:
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    let uploads = try await recoverSuccessfulUploads(record: record)
    guard uploads.count == record.attachments.count else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    _ = try await exactActiveSession(for: record.key)
    return uploads
  }

  @discardableResult
  /// Records that the Store has durably persisted a terminal draft. This deliberately keeps
  /// both the authenticated ledger and image files for later visibility verification.
  func markCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    let record = try await resolvedRecord(for: intent, reference: reference)
    switch record.stage {
    case .finalSubmissionPending:
      do {
        let completed = try await ledger.markCompleted(for: record.key)
        return try Self.recoveryState(for: completed)
      } catch {
        throw Self.pipelineError(forLedgerError: error)
      }
    case .completed:
      return try Self.recoveryState(for: record)
    case .prepared, .attachmentDispatchPending, .uploadsComplete, .outcomeUnknown:
      throw ComposerImageSubmissionPipelineError.invalidState
    }
  }

  func removeAttachments(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws {
    let record = try await resolvedRecord(for: intent, reference: reference)
    guard record.stage == .completed else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    guard let attachmentDeletionScheduler else { return }
    // Cleanup bookkeeping must not retain a completed ledger record forever.
    // A failed enqueue leaks only an already-terminal local file; it never
    // authorizes deletion or makes the confirmed submission resendable.
    _ = try? await attachmentDeletionScheduler.scheduleDeletion(
      of: record.attachments.map(\.attachment)
    )
  }

  func deleteCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws {
    guard
      userID > 0,
      intent.submissionID == reference.submissionID
    else { throw ComposerImageSubmissionPipelineError.referenceMismatch }
    let record: ComposerImageUploadLedgerRecord?
    do {
      record = try await ledger.record(for: intent.context, userID: userID)
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }
    guard let record else { return }
    guard
      record.key.submissionID == reference.submissionID,
      record.key.sessionRevision == reference.sessionRevision
    else { throw ComposerImageSubmissionPipelineError.referenceMismatch }
    guard intent.matches(record) else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    guard record.stage == .completed else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    do {
      try await ledger.delete(for: record.key)
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }
  }

  private func execute(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> FinalResult {
    var record = try await resolvedRecord(for: intent, reference: reference)
    switch record.stage {
    case .prepared, .uploadsComplete:
      break
    case .attachmentDispatchPending(let attachmentID):
      throw ComposerImageSubmissionPipelineError.locked(.attachment(attachmentID: attachmentID))
    case .finalSubmissionPending:
      throw ComposerImageSubmissionPipelineError.locked(.finalSubmission)
    case .outcomeUnknown:
      throw ComposerImageSubmissionPipelineError.locked(
        record.outcomeUnknownOperation ?? .finalSubmission
      )
    case .completed:
      throw ComposerImageSubmissionPipelineError.completed
    }

    var uploads = try await recoverSuccessfulUploads(record: record)
    while let nextSnapshot = record.nextAttachment {
      let session = try await exactActiveSession(for: record.key)
      let prepared = try await prepareUpload(
        snapshot: nextSnapshot,
        record: record,
        session: session
      )
      _ = try await exactActiveSession(for: record.key)

      do {
        record = try await ledger.markAttachmentDispatchPending(
          for: record.key,
          nextAttachmentID: nextSnapshot.id
        )
      } catch {
        throw Self.pipelineError(forLedgerError: error)
      }

      let operation = ComposerImageUploadOutcomeUnknownOperation.attachment(
        attachmentID: nextSnapshot.id
      )
      do {
        let result = try await access.service.dispatchStaticImageUpload(prepared)
        guard Self.isValid(result, prepared: prepared, receipt: result.receipt) else {
          throw ComposerImageSubmissionPipelineError.invalidState
        }
        record = try await ledger.recordBoundReceipt(
          result.receipt,
          verifiedAgainst: prepared.coreUpload,
          for: record.key
        )
        uploads.append(result)
      } catch {
        await markOutcomeUnknownAfterPending(for: record.key)
        throw ComposerImageSubmissionPipelineError.outcomeUnknown(operation)
      }
    }

    guard
      record.stage == .uploadsComplete,
      uploads.count == record.attachments.count
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    let session = try await exactActiveSession(for: record.key)
    do {
      record = try await ledger.markFinalSubmissionPending(for: record.key)
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }

    do {
      let result: FinalResult
      switch intent.payload {
      case .newThread(let submission):
        let newThreadResult = try await access.service.submitNewThread(
          session: session,
          submission: submission,
          imageUploads: uploads
        )
        guard
          newThreadResult.submissionID == submission.id,
          newThreadResult.userID == session.id,
          newThreadResult.target == submission.target
        else { throw ComposerImageSubmissionPipelineError.invalidState }
        result = .newThread(newThreadResult)
      case .directTopicReply(let submission):
        let replyResult = try await access.service.submitTextReply(
          session: session,
          submission: submission,
          imageUploads: uploads
        )
        guard
          replyResult.submissionID == submission.id,
          replyResult.userID == session.id,
          replyResult.target == submission.target
        else { throw ComposerImageSubmissionPipelineError.invalidState }
        result = .directTopicReply(replyResult)
      }
      return result
    } catch {
      await markOutcomeUnknownAfterPending(for: record.key)
      throw ComposerImageSubmissionPipelineError.outcomeUnknown(.finalSubmission)
    }
  }

  private func recoverSuccessfulUploads(
    record: ComposerImageUploadLedgerRecord
  ) async throws -> [ComposerImageUploadResult] {
    var uploads = [ComposerImageUploadResult]()
    uploads.reserveCapacity(record.successfulReceiptPrefix.count)
    for (snapshot, receipt) in zip(
      record.attachments,
      record.successfulReceiptPrefix
    ) {
      let session = try await exactActiveSession(for: record.key)
      let prepared = try await prepareUpload(
        snapshot: snapshot,
        record: record,
        session: session
      )
      let recovered: ComposerImageUploadResult
      do {
        recovered = try await access.service.recoverStaticImageUpload(
          prepared,
          authenticatedReceipt: receipt
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ComposerImageSubmissionPipelineError.preparationFailed
      }
      guard Self.isValid(recovered, prepared: prepared, receipt: receipt) else {
        throw ComposerImageSubmissionPipelineError.intentMismatch
      }
      uploads.append(recovered)
    }
    return uploads
  }

  private func prepareUpload(
    snapshot: ComposerImageUploadAttachmentSnapshot,
    record: ComposerImageUploadLedgerRecord,
    session: StoredAccountSession
  ) async throws -> ComposerPreparedImageUpload {
    let bytes: Data
    do {
      bytes = try await attachmentStore.validatedData(for: snapshot.attachment)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageSubmissionPipelineError.attachmentUnavailable
    }

    let prepared: ComposerPreparedImageUpload
    do {
      prepared = try await access.service.prepareStaticImageUpload(
        session: session,
        submissionID: record.key.submissionID,
        forumID: record.key.context.forumID,
        forumName: record.key.context.forumName,
        attachment: snapshot.attachment,
        validatedBytes: bytes,
        watermark: snapshot.watermark
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ComposerImageUploadPreparationError {
      switch error {
      case .fullCredentialsRequired:
        throw ComposerImageSubmissionPipelineError.fullCredentialsRequired
      case .invalidUpload, .unavailable:
        throw ComposerImageSubmissionPipelineError.preparationFailed
      }
    } catch {
      throw ComposerImageSubmissionPipelineError.preparationFailed
    }

    guard
      prepared.sessionUserID == record.key.userID,
      prepared.sessionRevision == record.key.sessionRevision,
      prepared.submissionID == record.key.submissionID,
      prepared.forumID == record.key.context.forumID,
      prepared.forumName.utf8.elementsEqual(record.key.context.forumName.utf8),
      prepared.attachment == snapshot.attachment,
      prepared.validatedBytes == bytes,
      prepared.watermark == snapshot.watermark,
      prepared.coreUpload.uploadID == snapshot.id,
      prepared.coreUpload.forumName.utf8.elementsEqual(record.key.context.forumName.utf8),
      prepared.coreUpload.encodedBytes == bytes,
      prepared.coreUpload.pixelWidth == snapshot.attachment.pixelWidth,
      prepared.coreUpload.pixelHeight == snapshot.attachment.pixelHeight,
      prepared.coreUpload.preservesOriginal == snapshot.preservesOriginal,
      prepared.coreUpload.watermark == snapshot.watermark
    else { throw ComposerImageSubmissionPipelineError.preparationFailed }
    return prepared
  }

  private func activeSessionForPreparation(
    reference: ComposerImageSubmissionReference
  ) async throws -> StoredAccountSession {
    let session: StoredAccountSession?
    do {
      session = try await access.vault.activeSession()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageSubmissionPipelineError.unavailable
    }
    guard let session else { throw ComposerImageSubmissionPipelineError.signedOut }
    guard session.sessionRevision == reference.sessionRevision else {
      throw ComposerImageSubmissionPipelineError.accountChanged
    }
    guard session.id > 0 else { throw ComposerImageSubmissionPipelineError.invalidIntent }
    guard session.credentials != nil else {
      throw ComposerImageSubmissionPipelineError.fullCredentialsRequired
    }
    return session
  }

  private func exactActiveSession(
    for key: ComposerImageUploadLedgerKey
  ) async throws -> StoredAccountSession {
    let session: StoredAccountSession?
    do {
      session = try await access.vault.activeSession()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageSubmissionPipelineError.unavailable
    }
    guard
      let session,
      session.id == key.userID,
      session.sessionRevision == key.sessionRevision
    else { throw ComposerImageSubmissionPipelineError.accountChanged }
    guard session.credentials != nil else {
      throw ComposerImageSubmissionPipelineError.fullCredentialsRequired
    }
    return session
  }

  private func resolvedRecord(
    for intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    expectedUserID: Int64? = nil
  ) async throws -> ComposerImageUploadLedgerRecord {
    guard intent.submissionID == reference.submissionID else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    let records: [ComposerImageUploadLedgerRecord]
    do {
      records = try await ledger.load()
    } catch {
      throw Self.pipelineError(forLedgerError: error)
    }
    guard
      let record = records.first(where: { $0.key.submissionID == reference.submissionID })
    else { throw ComposerImageSubmissionPipelineError.recordNotFound }
    guard
      record.key.sessionRevision == reference.sessionRevision,
      record.key.context == intent.context,
      expectedUserID.map({ $0 == record.key.userID }) ?? true
    else { throw ComposerImageSubmissionPipelineError.referenceMismatch }
    guard intent.matches(record) else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    return record
  }

  private func markOutcomeUnknownAfterPending(
    for key: ComposerImageUploadLedgerKey
  ) async {
    _ = try? await ledger.markOutcomeUnknown(for: key)
  }

  private static func recoveryState(
    for record: ComposerImageUploadLedgerRecord
  ) throws -> ComposerImageSubmissionRecoveryState {
    guard
      let reference = ComposerImageSubmissionReference(
        submissionID: record.key.submissionID,
        sessionRevision: record.key.sessionRevision
      )
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    switch record.stage {
    case .prepared:
      return .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: record.successfulReceiptPrefix.count,
        totalAttachmentCount: record.attachments.count
      )
    case .uploadsComplete:
      return .finalSubmissionResumeRequired(reference: reference)
    case .attachmentDispatchPending(let attachmentID):
      return .locked(
        reference: reference,
        operation: .attachment(attachmentID: attachmentID)
      )
    case .finalSubmissionPending:
      return .locked(reference: reference, operation: .finalSubmission)
    case .outcomeUnknown:
      return .locked(
        reference: reference,
        operation: record.outcomeUnknownOperation ?? .finalSubmission
      )
    case .completed:
      return .completed(reference: reference)
    }
  }

  private static func isValid(
    _ result: ComposerImageUploadResult,
    prepared: ComposerPreparedImageUpload,
    receipt: TiebaStaticImageUploadReceipt
  ) -> Bool {
    result.sessionRevision == prepared.sessionRevision
      && result.attachment == prepared.attachment
      && result.watermark == prepared.watermark
      && result.receipt == receipt
      && result.proof.submissionID == prepared.submissionID
      && result.proof.userID == prepared.sessionUserID
      && result.proof.forumID == prepared.forumID
      && result.proof.forumName.utf8.elementsEqual(prepared.forumName.utf8)
      && result.proof.uploadID == prepared.attachment.id
      && result.proof.picID == receipt.picID
      && result.proof.width == receipt.width
      && result.proof.height == receipt.height
  }

  private static func pipelineError(forLedgerError error: any Error)
    -> ComposerImageSubmissionPipelineError
  {
    guard let error = error as? ComposerImageUploadLedgerError else { return .ledgerUnavailable }
    switch error {
    case .recordAlreadyExists, .activeContextConflict:
      return .activeRecordExists
    case .recordNotFound:
      return .recordNotFound
    case .identityMismatch:
      return .referenceMismatch
    case .intentMismatch:
      return .intentMismatch
    case .invalidIdentity, .invalidAttachments, .unexpectedAttachment, .invalidReceipt:
      return .invalidIntent
    case .invalidTransition:
      return .invalidState
    case .corruptedArchive, .authenticationFailed, .authenticationUnavailable,
      .unsupportedSchemaVersion, .archiveTooLarge, .tooManyRecords, .unsafeStorage, .readFailed,
      .writeFailed:
      return .ledgerUnavailable
    }
  }
}
