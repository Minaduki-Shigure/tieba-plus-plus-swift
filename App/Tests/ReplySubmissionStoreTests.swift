import CryptoKit
import Foundation
@_spi(TiebaPlusPlusApp) import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ReplySubmissionStoreTests: XCTestCase {
  func testActivationAndPreflightUseExactSessionRevision() async throws {
    let target = storeReplyTarget()
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2)))
    let vault = ReplySubmissionVaultSpy()
    let store = replySubmissionStore(vault: vault, service: service)
    let signedOutEntry = store.entry(for: target)

    await store.activate(target, for: UUID())
    XCTAssertEqual(signedOutEntry.state, .signedOut)

    let legacy = storeReplySession(userID: 9, revision: replyUUID(1), hasSTOKEN: false)
    await vault.replaceActive(with: legacy)
    await store.activate(target, for: UUID())
    XCTAssertEqual(signedOutEntry.state, .failed(.fullCredentialsRequired))

    let first = storeReplySession(userID: 9, revision: replyUUID(2))
    await vault.replaceActive(with: first)
    await store.activate(target, for: UUID())
    XCTAssertEqual(signedOutEntry.state, .ready)

    let renewed = storeReplySession(userID: 9, revision: replyUUID(3))
    await vault.replaceActive(with: renewed)
    await assertReplySubmissionError(.accountChanged) {
      try await store.submit("正文", for: target, submissionID: replyUUID(4))
    }
    let preflightRequestCount = await service.requestCount()
    XCTAssertEqual(preflightRequestCount, 0)
    XCTAssertEqual(signedOutEntry.state, .accountChanged)
  }

  func testAutosaveThenClearIsOrderedEvenWhenFirstWriteIsSuspended() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let vault = ReplySubmissionVaultSpy(session: session)
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2)))
    let drafts = ReplySubmissionDraftRepository(suspendedSaveNumbers: [1])
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    let scope = UUID()
    await store.activate(target, for: scope)
    let entry = store.entry(for: target)

    let save = Task { try await store.saveDraft("旧草稿", for: target) }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 1 }
    let clear = Task { try await store.saveDraft("", for: target) }
    for _ in 0..<20 { await Task.yield() }
    let deleteCountBeforeRelease = await drafts.deleteCount()
    XCTAssertEqual(deleteCountBeforeRelease, 0)

    await drafts.releaseSaves()
    _ = try await save.value
    _ = try await clear.value
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedAfterClear = try await drafts.draft(for: key)
    XCTAssertNil(storedAfterClear)
    XCTAssertNil(entry.draft)
    XCTAssertEqual(entry.state, .ready)
  }

  func testSuspendedImageSaveThenDiscardLeavesNoDraftOrReferencedAttachment() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-save-discard-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let oldAttachment = replyStoreImageAttachment(id: replyUUID(5))
    let newAttachment = replyStoreImageAttachment(id: replyUUID(6))
    try await attachmentStore.remove(oldAttachment)
    let oldURL = directoryURL.appendingPathComponent(oldAttachment.relativePrivateFilename)
    let newURL = directoryURL.appendingPathComponent(newAttachment.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: oldURL)
    try Data([0x31, 0x32, 0x33]).write(to: newURL)

    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      "旧图片",
      attachments: [oldAttachment],
      imageWatermark: .forumName,
      for: target
    )
    let save = Task { @MainActor in
      try await store.saveDraft(
        "新图片",
        attachments: [newAttachment],
        imageWatermark: .username,
        for: target
      )
    }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 2 }
    let discard = Task { @MainActor in try await store.discardDraft(for: target) }
    await Task.yield()
    await assertReplySubmissionError(.submissionInProgress) {
      try await store.saveDraft("不得复活", for: target)
    }

    await drafts.releaseSaves()
    _ = try await save.value
    try await discard.value
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let persisted = try await drafts.draft(for: key)
    XCTAssertNil(persisted)
    XCTAssertNil(store.entry(for: target).draft)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
  }

  func testConcurrentImageSavesKeepLatestAndRecycleEveryReplacedAttachment() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-concurrent-saves-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let firstAttachment = replyStoreImageAttachment(id: replyUUID(7))
    let secondAttachment = replyStoreImageAttachment(id: replyUUID(8))
    let latestAttachment = replyStoreImageAttachment(id: replyUUID(9))
    try await attachmentStore.remove(firstAttachment)
    let firstURL = directoryURL.appendingPathComponent(firstAttachment.relativePrivateFilename)
    let secondURL = directoryURL.appendingPathComponent(secondAttachment.relativePrivateFilename)
    let latestURL = directoryURL.appendingPathComponent(latestAttachment.relativePrivateFilename)
    for url in [firstURL, secondURL, latestURL] {
      try Data([0x31, 0x32, 0x33]).write(to: url)
    }

    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      "第一版",
      attachments: [firstAttachment],
      imageWatermark: .forumName,
      for: target
    )
    let second = Task { @MainActor in
      try await store.saveDraft(
        "第二版",
        attachments: [secondAttachment],
        imageWatermark: .forumName,
        for: target
      )
    }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 2 }
    let latest = Task { @MainActor in
      try await store.saveDraft(
        "最终版",
        attachments: [latestAttachment],
        imageWatermark: .none,
        for: target
      )
    }
    await drafts.releaseSaves()
    _ = try await second.value
    _ = try await latest.value

    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    XCTAssertEqual(persisted.content, "最终版")
    XCTAssertEqual(persisted.attachments, [latestAttachment])
    XCTAssertEqual(store.entry(for: target).draft, persisted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: latestURL.path))
  }

  func testCancelledAutosaveWaitingForPermitNeitherPersistsNorCleansAttachments() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-cancelled-autosave-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let firstAttachment = replyStoreImageAttachment(id: replyUUID(13))
    let retainedAttachment = replyStoreImageAttachment(id: replyUUID(14))
    let cancelledAttachment = replyStoreImageAttachment(id: replyUUID(15))
    try await attachmentStore.remove(firstAttachment)
    let firstURL = directoryURL.appendingPathComponent(firstAttachment.relativePrivateFilename)
    let retainedURL = directoryURL.appendingPathComponent(
      retainedAttachment.relativePrivateFilename
    )
    let cancelledURL = directoryURL.appendingPathComponent(
      cancelledAttachment.relativePrivateFilename
    )
    for url in [firstURL, retainedURL, cancelledURL] {
      try Data([0x31, 0x32, 0x33]).write(to: url)
    }

    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      "第一版",
      attachments: [firstAttachment],
      imageWatermark: .forumName,
      for: target
    )
    let retained = Task { @MainActor in
      try await store.saveDraft(
        "应保留",
        attachments: [retainedAttachment],
        imageWatermark: .forumName,
        for: target
      )
    }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 2 }
    let cancelled = Task { @MainActor in
      try await store.saveDraft(
        "已取消",
        attachments: [cancelledAttachment],
        imageWatermark: .none,
        for: target
      )
    }
    await Task.yield()
    cancelled.cancel()
    await drafts.releaseSaves()
    _ = try await retained.value
    do {
      _ = try await cancelled.value
      XCTFail("Expected queued autosave cancellation")
    } catch is CancellationError {
      // Expected after the permit advances to this waiter.
    }

    let saveCount = await drafts.saveCount()
    XCTAssertEqual(saveCount, 2)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    XCTAssertEqual(storedDraft?.content, "应保留")
    XCTAssertEqual(storedDraft?.attachments, [retainedAttachment])
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cancelledURL.path))
  }

  func testAccountChangeCleanupDeletesOnlyAttachmentsWithoutAnyDurableReference() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-account-change-cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let referencedAttachment = replyStoreImageAttachment(id: replyUUID(16))
    let orphanAttachment = replyStoreImageAttachment(id: replyUUID(17))
    try await attachmentStore.remove(referencedAttachment)
    let referencedURL = directoryURL.appendingPathComponent(
      referencedAttachment.relativePrivateFilename
    )
    let orphanURL = directoryURL.appendingPathComponent(orphanAttachment.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: referencedURL)
    try Data([0x31, 0x32, 0x33]).write(to: orphanURL)

    let target = storeReplyTarget()
    let session = storeReplySession()
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(
      vault: vault,
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      "持久引用",
      attachments: [referencedAttachment],
      imageWatermark: .forumName,
      for: target
    )
    XCTAssertEqual(store.draftOwnerUserID(for: target), session.id)

    await vault.replaceActive(with: storeReplySession(userID: 10, revision: replyUUID(18)))
    store.accountSessionDidChange()
    await store.removeUnreferencedAttachments(
      [referencedAttachment, orphanAttachment],
      userID: session.id,
      for: target
    )

    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let persisted = try await drafts.draft(for: key)
    XCTAssertEqual(persisted?.attachments, [referencedAttachment])
    XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
  }

  func testCleanupSealRejectsLateSaveAndFailsClosedDuringSubmissionFlight() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-cleanup-seal-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let cleanupCandidate = replyStoreImageAttachment(id: replyUUID(19))
    let flightCandidate = replyStoreImageAttachment(id: replyUUID(20))
    try await attachmentStore.remove(cleanupCandidate)
    let cleanupURL = directoryURL.appendingPathComponent(
      cleanupCandidate.relativePrivateFilename
    )
    let flightURL = directoryURL.appendingPathComponent(flightCandidate.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: cleanupURL)

    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(suspendedReadNumbers: [2])
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: service,
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())

    let cleanup = Task { @MainActor in
      await store.removeUnreferencedAttachments(
        [cleanupCandidate],
        userID: session.id,
        for: target
      )
    }
    try await waitForReplySubmissionTest { await drafts.draftReadCount() == 2 }
    XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupURL.path))
    await assertReplySubmissionError(.submissionInProgress) {
      try await store.saveDraft("不得排到清理之后", for: target)
    }
    await drafts.releaseReads()
    await cleanup.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupURL.path))

    try Data([0x31, 0x32, 0x33]).write(to: flightURL)
    let submission = Task { @MainActor in
      try await store.submit(
        "持有同 key seal",
        for: target,
        submissionID: replyUUID(21)
      )
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    await store.removeUnreferencedAttachments(
      [flightCandidate],
      userID: session.id,
      for: target
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: flightURL.path))
    await service.releaseSubmissions()
    _ = try await submission.value
  }

  func testSuspendedSaveThenSubmitDispatchesExplicitSnapshotWithoutLateOverwrite() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let created = CreatedTextReply.post(postID: 701, floor: 2)
    let drafts = ReplySubmissionDraftRepository(suspendedSaveNumbers: [1])
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(created),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: service,
      drafts: drafts
    )
    await store.activate(target, for: UUID())

    let oldSave = Task { @MainActor in try await store.saveDraft("旧自动保存", for: target) }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 1 }
    let submissionID = replyUUID(12)
    let submit = Task { @MainActor in
      try await store.submit(
        "明确提交快照",
        attachments: [],
        imageWatermark: .forumName,
        for: target,
        submissionID: submissionID
      )
    }
    await Task.yield()
    await assertReplySubmissionError(.submissionInProgress) {
      try await store.saveDraft("迟到自动保存", for: target)
    }

    await drafts.releaseSaves()
    _ = try await oldSave.value
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    let lastSubmission = await service.lastSubmission()
    let submitted = try XCTUnwrap(lastSubmission)
    XCTAssertEqual(submitted.id, submissionID)
    XCTAssertEqual(submitted.content, "明确提交快照")
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let pending = try XCTUnwrap(storedDraft)
    XCTAssertEqual(pending.content, "明确提交快照")
    XCTAssertEqual(pending.disposition, .submissionPending(submissionID: submissionID))

    await service.releaseSubmissions()
    _ = try await submit.value
    XCTAssertNotEqual(store.entry(for: target).draft?.content, "旧自动保存")
  }

  func testSameSubmissionSharesOwnerFlightAndViewReactivationDoesNotCancelIt() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let vault = ReplySubmissionVaultSpy(session: session)
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(vault: vault, service: service)
    let firstScope = UUID()
    await store.activate(target, for: firstScope)
    let entry = store.entry(for: target)
    let submissionID = replyUUID(10)

    let first = Task {
      try await store.submit("同一正文", for: target, submissionID: submissionID)
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    store.deactivate(firstScope)
    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .submitting(submissionID))

    let shared = Task {
      try await store.submit("同一正文", for: target, submissionID: submissionID)
    }
    await assertReplySubmissionError(.submissionInProgress) {
      try await store.submit("另一正文", for: target, submissionID: replyUUID(11))
    }
    let requestCountBeforeRelease = await service.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)

    await service.releaseSubmissions()
    let firstResult = try await first.value
    let sharedResult = try await shared.value
    XCTAssertEqual(firstResult, sharedResult)
    let finalRequestCount = await service.requestCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(entry.state, .confirmed(.post(postID: 701, floor: 2)))
  }

  func testConfirmedFlightSynchronizesSiblingDraftKeyAndPreventsDuplicateReply() async throws {
    let target = storeReplyTarget()
    let siblingTarget = try XCTUnwrap(
      TextReplyTarget(
        forumID: target.forumID,
        forumName: "swift-alt",
        threadID: target.threadID,
        firstPostID: target.firstPostID,
        destination: target.destination
      )
    )
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: storeReplySession()),
      service: service
    )
    await store.activate(target, for: UUID())
    await store.activate(siblingTarget, for: UUID())

    let submission = Task { @MainActor in
      try await store.submit("同键回复", for: target, submissionID: replyUUID(90))
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    await store.activate(siblingTarget, for: UUID())
    XCTAssertEqual(store.entry(for: siblingTarget).state, .submitting(replyUUID(90)))

    await service.releaseSubmissions()
    _ = try await submission.value

    XCTAssertEqual(
      store.entry(for: siblingTarget).state,
      .confirmed(.post(postID: 701, floor: 2))
    )
    await assertReplySubmissionError(.outcomeUnknown) {
      try await store.submit("同键回复", for: siblingTarget, submissionID: replyUUID(91))
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testSubmitRevalidatesPersistedTerminalBeforeOverwritingStaleAlias() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository()
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2))
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: service,
      drafts: drafts
    )
    await store.activate(target, for: UUID())
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let terminalDraft = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "结果未知",
        disposition: .outcomeUnknown(submissionID: replyUUID(92))
      )
    )
    try await drafts.save(terminalDraft)

    await assertReplySubmissionError(.outcomeUnknown) {
      try await store.submit("过期内存正文", for: target, submissionID: replyUUID(93))
    }

    XCTAssertEqual(store.entry(for: target).state, .outcomeUnknown)
    let retainedDraft = try await drafts.draft(for: key)
    XCTAssertEqual(retainedDraft, terminalDraft)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testOldAccountFlightDoesNotOverwriteLoadingSiblingAfterAccountSwitch() async throws {
    let target = storeReplyTarget()
    let siblingTarget = try XCTUnwrap(
      TextReplyTarget(
        forumID: target.forumID,
        forumName: "swift-alt",
        threadID: target.threadID,
        firstPostID: target.firstPostID,
        destination: target.destination
      )
    )
    let original = storeReplySession(userID: 9, revision: replyUUID(94))
    let replacement = storeReplySession(userID: 10, revision: replyUUID(95))
    let vault = ReplySubmissionVaultSpy(session: original)
    let drafts = ReplySubmissionDraftRepository(suspendedReadNumbers: [3])
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())

    let submission = Task { @MainActor in
      try await store.submit("旧账户正文", for: target, submissionID: replyUUID(96))
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: replacement)
    store.accountSessionDidChange()

    let siblingActivation = Task { @MainActor in
      await store.activate(siblingTarget, for: UUID())
    }
    try await waitForReplySubmissionTest { await drafts.draftReadCount() == 3 }
    XCTAssertEqual(store.entry(for: siblingTarget).state, .loading)

    await service.releaseSubmissions()
    await assertReplySubmissionError(.accountChanged) { try await submission.value }
    XCTAssertEqual(store.entry(for: siblingTarget).state, .loading)
    XCTAssertNil(store.entry(for: siblingTarget).draft)

    await drafts.releaseReads()
    await siblingActivation.value
    XCTAssertEqual(store.entry(for: siblingTarget).state, .ready)
    XCTAssertNil(store.entry(for: siblingTarget).draft)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testFailedFlightReleasesExactLeaseSiblingFromSubmittingState() async throws {
    let target = storeReplyTarget()
    let siblingTarget = try XCTUnwrap(
      TextReplyTarget(
        forumID: target.forumID,
        forumName: "swift-alt",
        threadID: target.threadID,
        firstPostID: target.firstPostID,
        destination: target.destination
      )
    )
    let service = ReplySubmissionServiceSpy(
      behavior: .failure(.server(code: 500)),
      suspendsSubmissions: true
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: storeReplySession()),
      service: service
    )
    await store.activate(target, for: UUID())
    await store.activate(siblingTarget, for: UUID())

    let submissionID = replyUUID(97)
    let submission = Task { @MainActor in
      try await store.submit("失败正文", for: target, submissionID: submissionID)
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    await store.activate(siblingTarget, for: UUID())
    XCTAssertEqual(store.entry(for: siblingTarget).state, .submitting(submissionID))

    await service.releaseSubmissions()
    await assertReplySubmissionError(.server(code: 500)) { try await submission.value }
    XCTAssertEqual(store.entry(for: target).state, .failed(.server(code: 500)))
    XCTAssertEqual(store.entry(for: siblingTarget).state, .failed(.server(code: 500)))

    let saved = try await store.saveDraft("可继续编辑", for: siblingTarget)
    XCTAssertEqual(saved?.content, "可继续编辑")
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testChallengeCannotBeTurnedIntoRetryByEditingOrDiscardingDraft() async throws {
    let target = storeReplyTarget()
    let service = ReplySubmissionServiceSpy(behavior: .failure(.challengeRequired))
    let vault = ReplySubmissionVaultSpy(session: storeReplySession())
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    let entry = store.entry(for: target)

    await assertReplySubmissionError(.challengeRequired) {
      try await store.submit("原正文", for: target, submissionID: replyUUID(20))
    }
    _ = try await store.saveDraft("修改后正文", for: target)
    XCTAssertEqual(entry.state, .challengeRequired)
    try await store.discardDraft(for: target)
    XCTAssertEqual(entry.state, .challengeRequired)
    XCTAssertEqual(entry.draft?.content, "")
    _ = try await store.saveDraft("再次编辑", for: target)
    XCTAssertEqual(entry.state, .challengeRequired)

    await assertReplySubmissionError(.challengeRequired) {
      try await store.submit("再次编辑", for: target, submissionID: replyUUID(21))
    }
    let challengeRequestCount = await service.requestCount()
    XCTAssertEqual(challengeRequestCount, 1)

    let rebuilt = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .challengeRequired)
    await assertReplySubmissionError(.challengeRequired) {
      try await rebuilt.submit("再次编辑", for: target, submissionID: replyUUID(22))
    }
    let rebuiltRequestCount = await service.requestCount()
    XCTAssertEqual(rebuiltRequestCount, 1)

    await vault.replaceActive(
      with: storeReplySession(userID: 9, revision: replyUUID(23))
    )
    let renewed = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await renewed.activate(target, for: UUID())
    XCTAssertEqual(renewed.entry(for: target).state, .ready)
    XCTAssertEqual(renewed.entry(for: target).draft?.content, "再次编辑")
  }

  func testUnknownOutcomePersistsAcrossStoreRebuildAndNeverResends() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let service = ReplySubmissionServiceSpy(behavior: .failure(.outcomeUnknown))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository()
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.outcomeUnknown) {
      try await store!.submit("结果未知", for: target, submissionID: replyUUID(30))
    }
    XCTAssertEqual(store?.entry(for: target).state, .outcomeUnknown)
    store = nil

    let rebuilt = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .outcomeUnknown)
    await assertReplySubmissionError(.outcomeUnknown) {
      try await rebuilt.submit("结果未知", for: target, submissionID: replyUUID(31))
    }
    let unknownRequestCount = await service.requestCount()
    XCTAssertEqual(unknownRequestCount, 1)
  }

  func testDispatchPendingDraftIsDurableBeforeServiceReceivesWrite() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let submissionID = replyUUID(35)
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())

    let submission = Task {
      try await store.submit("发送边界正文", for: target, submissionID: submissionID)
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    guard case .submissionPending(let persistedID) = persisted.disposition else {
      XCTFail("Expected a durable submission-pending tombstone before dispatch")
      return
    }
    XCTAssertEqual(persistedID, submissionID)

    await service.releaseSubmissions()
    _ = try await submission.value
  }

  func testDispatchPendingSaveFailureDoesNotDispatchAndRestoresEditing() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2)))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository(failedSaveNumbers: [2])
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.unavailable) {
      try await store!.submit("未派发正文", for: target, submissionID: replyUUID(36))
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    XCTAssertEqual(persisted.disposition, .editing)
    store = nil

    let rebuilt = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .ready)
    XCTAssertEqual(rebuilt.entry(for: target).draft?.content, "未派发正文")
  }

  func testTerminalPendingSaveFailureRebuildsFailClosedAndNeverResends() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let receipt = TextReplyReceipt.post(postID: 701)
    let service = ReplySubmissionServiceSpy(behavior: .accepted(receipt))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository(failedSaveNumbers: [3])
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.unavailable) {
      try await store!.submit("终态失败正文", for: target, submissionID: replyUUID(37))
    }
    XCTAssertEqual(store?.entry(for: target).state, .acceptedAwaitingVisibility(receipt))
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    guard case .submissionPending = persisted.disposition else {
      XCTFail("Expected the pre-dispatch tombstone to survive terminal persistence failure")
      return
    }
    store = nil

    let rebuilt = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .outcomeUnknown)
    await assertReplySubmissionError(.outcomeUnknown) {
      try await rebuilt.submit("终态失败正文", for: target, submissionID: replyUUID(38))
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testRetryableFailureRestoreSaveFailureRemainsFailClosed() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let service = ReplySubmissionServiceSpy(behavior: .failure(.server(code: 500)))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository(failedSaveNumbers: [3])
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())

    await assertReplySubmissionError(.outcomeUnknown) {
      try await store.submit("恢复失败正文", for: target, submissionID: replyUUID(39))
    }
    XCTAssertEqual(store.entry(for: target).state, .outcomeUnknown)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    guard case .submissionPending = persisted.disposition else {
      XCTFail("Expected retry restoration failure to preserve the submission tombstone")
      return
    }
  }

  func testIndeterminateServiceFailuresRemainFailClosed() async throws {
    let behaviors: [ReplySubmissionServiceBehavior] = [
      .failure(.unavailable),
      .untypedFailure,
      .cancellation,
    ]
    for (index, behavior) in behaviors.enumerated() {
      let target = storeReplyTarget()
      let session = storeReplySession()
      let service = ReplySubmissionServiceSpy(behavior: behavior)
      let vault = ReplySubmissionVaultSpy(session: session)
      let drafts = ReplySubmissionDraftRepository()
      let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
      await store.activate(target, for: UUID())

      await assertReplySubmissionError(.outcomeUnknown) {
        try await store.submit(
          "不确定结果正文 \(index)",
          for: target,
          submissionID: replyUUID(UInt8(40 + index))
        )
      }
      XCTAssertEqual(store.entry(for: target).state, .outcomeUnknown)
      let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
      let storedDraft = try await drafts.draft(for: key)
      let persisted = try XCTUnwrap(storedDraft)
      switch persisted.disposition {
      case .submissionPending, .outcomeUnknown:
        break
      default:
        XCTFail("Expected indeterminate service failure to remain non-resendable")
      }
    }
  }

  func testConfirmedReplyBecomesPendingBeforeDeleteAndRebuildBlocksResend() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2)))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository(failsNextDelete: true)
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.unavailable) {
      try await store!.submit("已成功正文", for: target, submissionID: replyUUID(40))
    }
    XCTAssertEqual(
      store?.entry(for: target).state,
      .acceptedAwaitingVisibility(.post(postID: 701))
    )
    store = nil

    let rebuilt = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(
      rebuilt.entry(for: target).state,
      .acceptedAwaitingVisibility(.post(postID: 701))
    )
    await assertReplySubmissionError(.outcomeUnknown) {
      try await rebuilt.submit("已成功正文", for: target, submissionID: replyUUID(41))
    }
    let confirmedRequestCount = await service.requestCount()
    XCTAssertEqual(confirmedRequestCount, 1)
  }

  func testVisibilityProofRequiresExactUserContentAndReceipt() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let receipt = TextReplyReceipt.post(postID: 701)
    let service = ReplySubmissionServiceSpy(behavior: .accepted(receipt))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    _ = try await store.submit("待确认正文", for: target, submissionID: replyUUID(50))

    let wrongUser = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: 10,
        content: "待确认正文"
      )
    )
    await assertReplySubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongUser, matching: receipt, for: target)
    }
    let wrongContent = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: 9,
        content: "别的正文"
      )
    )
    await assertReplySubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongContent, matching: receipt, for: target)
    }
    let wrongReceipt = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 702, floor: 3),
        authorUserID: 9,
        content: "待确认正文"
      )
    )
    await assertReplySubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongReceipt, matching: receipt, for: target)
    }

    let proof = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: 9,
        content: "待确认正文"
      )
    )
    let result = try await store.confirmVisibility(proof, matching: receipt, for: target)
    XCTAssertEqual(result.outcome, .confirmed(.post(postID: 701, floor: 2)))
    XCTAssertEqual(store.entry(for: target).state, .confirmed(.post(postID: 701, floor: 2)))
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let storedAfterConfirmation = try await drafts.draft(for: key)
    XCTAssertNil(storedAfterConfirmation)
  }

  func testVisibilityProofRejectsSubpostParentMismatch() async throws {
    let target = storeReplyTarget(destination: .post(postID: 701))
    let receipt = TextReplyReceipt.subpost(parentPostID: 701, subpostID: 703)
    let service = ReplySubmissionServiceSpy(behavior: .accepted(receipt))
    let vault = ReplySubmissionVaultSpy(session: storeReplySession())
    let store = replySubmissionStore(vault: vault, service: service)
    await store.activate(target, for: UUID())
    _ = try await store.submit("楼中楼正文", for: target, submissionID: replyUUID(60))

    let wrongParent = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .subpost(parentPostID: 702, subpostID: 703),
        authorUserID: 9,
        content: "楼中楼正文"
      )
    )
    await assertReplySubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongParent, matching: receipt, for: target)
    }
    XCTAssertEqual(store.entry(for: target).state, .acceptedAwaitingVisibility(receipt))
    let parentMismatchRequestCount = await service.requestCount()
    XCTAssertEqual(parentMismatchRequestCount, 1)
  }

  func testActivationDrainsMutationAppendedWhileWaitingForPreviousTail() async throws {
    let target = storeReplyTarget()
    let siblingTarget = try XCTUnwrap(
      TextReplyTarget(
        forumID: target.forumID,
        forumName: "swift-alt",
        threadID: target.threadID,
        firstPostID: target.firstPostID,
        destination: target.destination
      )
    )
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(
      suspendedSaveNumbers: [1, 2]
    )
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2))
    )
    let vault = ReplySubmissionVaultSpy(session: session)
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    await store.activate(siblingTarget, for: UUID())

    let firstSave = Task { try await store.saveDraft("旧草稿", for: target) }
    try await waitForReplySubmissionTest { await drafts.saveCount() == 1 }
    let activation = Task { await store.activate(target, for: UUID()) }
    for _ in 0..<20 { await Task.yield() }
    let secondSave = Task { try await store.saveDraft("新草稿", for: siblingTarget) }
    for _ in 0..<20 { await Task.yield() }
    await drafts.releaseNextSave()
    try await waitForReplySubmissionTest { await drafts.saveCount() == 2 }
    let readsWhileSecondSaveIsSuspended = await drafts.draftReadCount()
    XCTAssertEqual(readsWhileSecondSaveIsSuspended, 4)

    await drafts.releaseSaves()
    await assertReplySubmissionError(.accountChanged) { try await firstSave.value }
    _ = try await secondSave.value
    await activation.value
    XCTAssertEqual(store.entry(for: target).state, .ready)
    XCTAssertEqual(store.entry(for: target).draft?.content, "新草稿")
  }

  func testSameUserReloginDuringFlightRejectsLateResultAndPersistsPendingProof() async throws {
    try await assertAccountChangeDuringFlight(
      replacement: storeReplySession(userID: 9, revision: replyUUID(71)),
      postsNotification: false
    )
  }

  func testLogoutDuringFlightRejectsLateResultAndPersistsPendingProof() async throws {
    try await assertAccountChangeDuringFlight(replacement: nil, postsNotification: true)
  }

  func testSwitchDuringFlightRejectsLateResultAndPersistsPendingProof() async throws {
    try await assertAccountChangeDuringFlight(
      replacement: storeReplySession(userID: 10, revision: replyUUID(72)),
      postsNotification: true
    )
  }

  func testImageRepliesAreLimitedToDirectTopicDestination() async throws {
    let target = storeReplyTarget(destination: .post(postID: 701))
    let session = storeReplySession()
    let pipeline = ReplyImagePipelineSpy(
      behavior: .confirmed(.subpost(parentPostID: 701, subpostID: 702)),
      userID: session.id
    )
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.subpost(parentPostID: 701, subpostID: 702))
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: service,
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())

    await assertReplySubmissionError(.invalidSubmission) {
      try await store.submit(
        "楼层图片回复",
        attachments: [replyStoreImageAttachment(id: replyUUID(80))],
        imageWatermark: .forumName,
        for: target,
        submissionID: replyUUID(81)
      )
    }
    let rejectedPrepareCount = await pipeline.prepareCount()
    let rejectedExecuteCount = await pipeline.executeCount()
    let rejectedServiceCount = await service.requestCount()
    XCTAssertEqual(rejectedPrepareCount, 0)
    XCTAssertEqual(rejectedExecuteCount, 0)
    XCTAssertEqual(rejectedServiceCount, 0)
  }

  func testEditingAttachmentReplacementWaitsForSuccessfulDraftMetadataWrite() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reply-attachment-replacement-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let oldAttachment = replyStoreImageAttachment(id: replyUUID(91))
    let newAttachment = replyStoreImageAttachment(id: replyUUID(92))
    try await attachmentStore.remove(oldAttachment)
    let oldFileURL = directoryURL.appendingPathComponent(oldAttachment.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: oldFileURL)

    let target = storeReplyTarget()
    let session = storeReplySession()
    let drafts = ReplySubmissionDraftRepository(failedSaveNumbers: [2])
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      "旧图片",
      attachments: [oldAttachment],
      imageWatermark: .forumName,
      for: target
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldFileURL.path))

    await assertReplySubmissionError(.unavailable) {
      try await store.saveDraft(
        "新图片",
        attachments: [newAttachment],
        imageWatermark: .forumName,
        for: target
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldFileURL.path))

    _ = try await store.saveDraft(
      "新图片",
      attachments: [newAttachment],
      imageWatermark: .forumName,
      for: target
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldFileURL.path))
  }

  func testImagePreparationDraftRecoversWithoutNetworkUntilExplicitResume() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let submissionID = replyUUID(82)
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID,
        sessionRevision: session.sessionRevision
      )
    )
    let attachment = replyStoreImageAttachment(id: replyUUID(83))
    let created = CreatedTextReply.post(postID: 701, floor: 2)
    let pipeline = ReplyImagePipelineSpy(behavior: .confirmed(created), userID: session.id)
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(created))
    let vault = ReplySubmissionVaultSpy(session: session)
    let drafts = ReplySubmissionDraftRepository(failedSaveNumbers: [3])
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.unavailable) {
      try await store!.submit(
        "图片回复",
        attachments: [attachment],
        imageWatermark: .forumName,
        for: target,
        submissionID: submissionID
      )
    }
    let prepareCountAfterFailure = await pipeline.prepareCount()
    let executeCountAfterFailure = await pipeline.executeCount()
    XCTAssertEqual(prepareCountAfterFailure, 1)
    XCTAssertEqual(executeCountAfterFailure, 0)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let preparationDraft = try await drafts.draft(for: key)
    XCTAssertEqual(
      preparationDraft?.disposition,
      .imagePreparationPending(reference: reference)
    )
    store = nil

    let rebuilt = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(
      rebuilt.entry(for: target).state,
      .imageRecovery(
        .uploadResumeRequired(
          reference: reference,
          successfulUploadCount: 0,
          totalAttachmentCount: 1
        )
      )
    )
    XCTAssertEqual(
      rebuilt.entry(for: target).draft?.disposition,
      .imagePipeline(reference: reference)
    )
    let executeCountBeforeResume = await pipeline.executeCount()
    XCTAssertEqual(executeCountBeforeResume, 0)

    let result = try await rebuilt.resumeImageSubmission(for: target)
    XCTAssertEqual(result.outcome, .confirmed(created))
    let executeCountAfterResume = await pipeline.executeCount()
    let markCountAfterResume = await pipeline.markCompletedCount()
    let removeCountAfterResume = await pipeline.removeAttachmentsCount()
    let deleteCountAfterResume = await pipeline.deleteCompletedCount()
    let draftAfterResume = try await drafts.draft(for: key)
    XCTAssertEqual(executeCountAfterResume, 1)
    XCTAssertEqual(markCountAfterResume, 1)
    XCTAssertEqual(removeCountAfterResume, 1)
    XCTAssertEqual(deleteCountAfterResume, 1)
    XCTAssertNil(draftAfterResume)
  }

  func testMissingDraftWithBlockingImageLedgerNeverStartsNetwork() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: replyUUID(84),
        sessionRevision: session.sessionRevision
      )
    )
    let pipeline = ReplyImagePipelineSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      userID: session.id
    )
    await pipeline.seed(
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      )
    )
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2))),
      pipeline: pipeline
    )

    await store.activate(target, for: UUID())
    XCTAssertEqual(store.entry(for: target).state, .imageRecoveryUnavailable)
    await assertReplySubmissionError(.unavailable) {
      try await store.submit("不得重复发送", for: target)
    }
    let blockedExecuteCount = await pipeline.executeCount()
    XCTAssertEqual(blockedExecuteCount, 0)
  }

  func testAcceptedImageReplyRetainsProofUntilExactVisibilityConfirmation() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let submissionID = replyUUID(85)
    let attachment = replyStoreImageAttachment(id: replyUUID(86))
    let receipt = TextReplyReceipt.post(postID: 701)
    let upload = try replyStoreImageUploadResult(
      attachment: attachment,
      submissionID: submissionID,
      session: session,
      target: target,
      watermark: .username
    )
    let pipeline = ReplyImagePipelineSpy(
      behavior: .accepted(receipt),
      userID: session.id,
      visibilityUploads: [upload]
    )
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(
      vault: ReplySubmissionVaultSpy(session: session),
      service: ReplySubmissionServiceSpy(behavior: .accepted(receipt)),
      drafts: drafts,
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())

    _ = try await store.submit(
      "带图正文",
      attachments: [attachment],
      imageWatermark: .username,
      for: target,
      submissionID: submissionID
    )
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID,
        sessionRevision: session.sessionRevision
      )
    )
    XCTAssertEqual(
      store.entry(for: target).draft?.disposition,
      .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt)
    )
    let acceptedMarkCount = await pipeline.markCompletedCount()
    let acceptedRemoveCount = await pipeline.removeAttachmentsCount()
    let acceptedDeleteCount = await pipeline.deleteCompletedCount()
    let recoveredUploads = try await store.visibilityImageUploads(for: target)
    XCTAssertEqual(acceptedMarkCount, 1)
    XCTAssertEqual(acceptedRemoveCount, 0)
    XCTAssertEqual(acceptedDeleteCount, 0)
    XCTAssertEqual(recoveredUploads, [upload])

    let wrongWatermark = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: session.id,
        content: "带图正文",
        attachments: [attachment],
        imageWatermark: .none
      )
    )
    await assertReplySubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongWatermark, matching: receipt, for: target)
    }
    let exact = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: session.id,
        content: "带图正文",
        attachments: [attachment],
        imageWatermark: .username
      )
    )
    let result = try await store.confirmVisibility(exact, matching: receipt, for: target)
    XCTAssertEqual(result.outcome, .confirmed(.post(postID: 701, floor: 2)))
    let recoverVisibilityCount = await pipeline.recoverVisibilityCount()
    let confirmedRemoveCount = await pipeline.removeAttachmentsCount()
    let confirmedDeleteCount = await pipeline.deleteCompletedCount()
    let key = try XCTUnwrap(TextReplyDraftKey(userID: session.id, target: target))
    let draftAfterConfirmation = try await drafts.draft(for: key)
    XCTAssertEqual(recoverVisibilityCount, 2)
    XCTAssertEqual(confirmedRemoveCount, 1)
    XCTAssertEqual(confirmedDeleteCount, 1)
    XCTAssertNil(draftAfterConfirmation)
  }

  func testConfirmedImageCleanupFailureIsReentrantAcrossActivation() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let submissionID = replyUUID(87)
    let created = CreatedTextReply.post(postID: 701, floor: 2)
    let pipeline = ReplyImagePipelineSpy(
      behavior: .confirmed(created),
      userID: session.id,
      failsNextRemove: true
    )
    let drafts = ReplySubmissionDraftRepository()
    let vault = ReplySubmissionVaultSpy(session: session)
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(created))
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store?.activate(target, for: UUID())

    _ = try await store!.submit(
      "清理恢复",
      attachments: [replyStoreImageAttachment(id: replyUUID(88))],
      imageWatermark: .forumName,
      for: target,
      submissionID: submissionID
    )
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID,
        sessionRevision: session.sessionRevision
      )
    )
    XCTAssertEqual(
      store?.entry(for: target).draft?.disposition,
      .imageConfirmed(reference: reference, created: created)
    )
    let failedRemoveCount = await pipeline.removeAttachmentsCount()
    let deleteCountBeforeRebuild = await pipeline.deleteCompletedCount()
    XCTAssertEqual(failedRemoveCount, 1)
    XCTAssertEqual(deleteCountBeforeRebuild, 0)
    store = nil

    let rebuilt = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .confirmed(created))
    XCTAssertNil(rebuilt.entry(for: target).draft)
    let cleanupExecuteCount = await pipeline.executeCount()
    let cleanupRemoveCount = await pipeline.removeAttachmentsCount()
    let cleanupDeleteCount = await pipeline.deleteCompletedCount()
    XCTAssertEqual(cleanupExecuteCount, 1)
    XCTAssertEqual(cleanupRemoveCount, 2)
    XCTAssertEqual(cleanupDeleteCount, 1)
  }

  func testLockedImageReplyCannotBeAutomaticallyOrExplicitlyResent() async throws {
    let target = storeReplyTarget()
    let session = storeReplySession()
    let submissionID = replyUUID(89)
    let attachment = replyStoreImageAttachment(id: replyUUID(90))
    let operation = ComposerImageUploadOutcomeUnknownOperation.attachment(
      attachmentID: attachment.id
    )
    let pipeline = ReplyImagePipelineSpy(
      behavior: .failure(.outcomeUnknown(operation)),
      userID: session.id
    )
    let drafts = ReplySubmissionDraftRepository()
    let vault = ReplySubmissionVaultSpy(session: session)
    let service = ReplySubmissionServiceSpy(behavior: .confirmed(.post(postID: 701, floor: 2)))
    var store: TextReplySubmissionStore? = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store?.activate(target, for: UUID())

    await assertReplySubmissionError(.outcomeUnknown) {
      try await store!.submit(
        "结果未知",
        attachments: [attachment],
        imageWatermark: .none,
        for: target,
        submissionID: submissionID
      )
    }
    let executeCountAfterUnknown = await pipeline.executeCount()
    XCTAssertEqual(executeCountAfterUnknown, 1)
    store = nil

    let rebuilt = replySubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await rebuilt.activate(target, for: UUID())
    guard
      case .imageRecovery(.locked(_, let recoveredOperation)) =
        rebuilt.entry(for: target).state
    else { return XCTFail("Expected locked image recovery") }
    XCTAssertEqual(recoveredOperation, operation)
    await assertReplySubmissionError(.outcomeUnknown) {
      try await rebuilt.resumeImageSubmission(for: target)
    }
    await assertReplySubmissionError(.outcomeUnknown) {
      try await rebuilt.submit("不得重发", for: target)
    }
    let executeCountAfterBlockedRetries = await pipeline.executeCount()
    XCTAssertEqual(executeCountAfterBlockedRetries, 1)
  }

  private func assertAccountChangeDuringFlight(
    replacement: StoredAccountSession?,
    postsNotification: Bool
  ) async throws {
    let original = storeReplySession(userID: 9, revision: replyUUID(70))
    let target = storeReplyTarget()
    let service = ReplySubmissionServiceSpy(
      behavior: .confirmed(.post(postID: 701, floor: 2)),
      suspendsSubmissions: true
    )
    let vault = ReplySubmissionVaultSpy(session: original)
    let drafts = ReplySubmissionDraftRepository()
    let store = replySubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    let entry = store.entry(for: target)
    let task = Task {
      try await store.submit("切换期间正文", for: target, submissionID: replyUUID(73))
    }
    try await waitForReplySubmissionTest { await service.requestCount() == 1 }

    await vault.replaceActive(with: replacement)
    if postsNotification { store.accountSessionDidChange() }
    await service.releaseSubmissions()
    await assertReplySubmissionError(.accountChanged) { try await task.value }
    XCTAssertEqual(entry.state, .accountChanged)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: original.id, target: target))
    let persisted = try await drafts.draft(for: key)
    guard let persisted else {
      XCTFail("Expected a pending draft for the original account")
      return
    }
    guard case .acceptedAwaitingVisibility(_, .post(postID: 701)) = persisted.disposition else {
      XCTFail("Expected a non-resendable pending draft for the original account")
      return
    }
    let accountChangeRequestCount = await service.requestCount()
    XCTAssertEqual(accountChangeRequestCount, 1)
  }
}

private enum ReplySubmissionTestFailure: Error, Sendable {
  case unexpectedCall
  case persistenceFailure
  case timeout
}

private enum ReplyImagePipelineBehavior: Sendable {
  case confirmed(CreatedTextReply)
  case accepted(TextReplyReceipt)
  case failure(ComposerImageSubmissionPipelineError)
}

private actor ReplyImagePipelineSpy: ComposerImageSubmissionPipelining {
  private let behavior: ReplyImagePipelineBehavior
  private let userID: Int64
  private let visibilityUploads: [ComposerImageUploadResult]
  private var state: ComposerImageSubmissionRecoveryState?
  private var prepareCalls = 0
  private var executeCalls = 0
  private var recoverVisibilityCalls = 0
  private var markCompletedCalls = 0
  private var removeAttachmentsCalls = 0
  private var deleteCompletedCalls = 0
  private var failsNextRemove: Bool

  init(
    behavior: ReplyImagePipelineBehavior,
    userID: Int64,
    visibilityUploads: [ComposerImageUploadResult] = [],
    failsNextRemove: Bool = false
  ) {
    self.behavior = behavior
    self.userID = userID
    self.visibilityUploads = visibilityUploads
    self.failsNextRemove = failsNextRemove
  }

  func seed(_ state: ComposerImageSubmissionRecoveryState?) {
    self.state = state
  }

  func prepareNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func prepareDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard submission.id == reference.submissionID else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    prepareCalls += 1
    let prepared = ComposerImageSubmissionRecoveryState.uploadResumeRequired(
      reference: reference,
      successfulUploadCount: 0,
      totalAttachmentCount: submission.attachments.count
    )
    state = prepared
    return prepared
  }

  func prepare(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func blockingRecoveryState(
    for context: ComposerImageUploadContext,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard userID == self.userID else { return nil }
    return state
  }

  func blockingRecoveryState(
    for intent: ComposerImageSubmissionIntent,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    try await blockingRecoveryState(for: intent.context, userID: userID)
  }

  func recoveryState(
    for intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard userID == self.userID else { return nil }
    guard state?.reference == reference else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    guard intent.submissionID == reference.submissionID else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    return state
  }

  func executeNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> NewThreadResult {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func executeDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> TextReplyResult {
    guard submission.id == reference.submissionID, state?.reference == reference else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    executeCalls += 1
    switch behavior {
    case .confirmed(let created):
      state = .locked(reference: reference, operation: .finalSubmission)
      return TextReplyResult(
        submissionID: submission.id,
        userID: userID,
        target: submission.target,
        outcome: .confirmed(created)
      )!
    case .accepted(let receipt):
      state = .locked(reference: reference, operation: .finalSubmission)
      return TextReplyResult(
        submissionID: submission.id,
        userID: userID,
        target: submission.target,
        outcome: .acceptedAwaitingVisibility(receipt)
      )!
    case .failure(let error):
      switch error {
      case .outcomeUnknown(let operation), .locked(let operation):
        state = .locked(reference: reference, operation: operation)
      default:
        break
      }
      throw error
    }
  }

  func recoverNewThreadUploadsForVisibility(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func recoverDirectTopicReplyUploadsForVisibility(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    guard submission.id == reference.submissionID, state?.reference == reference else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    guard state == .completed(reference: reference) else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    recoverVisibilityCalls += 1
    return visibilityUploads
  }

  func recoverUploadsForVisibility(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func markCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard intent.submissionID == reference.submissionID, state?.reference == reference else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    guard let state else { throw ComposerImageSubmissionPipelineError.invalidState }
    switch state {
    case .locked(_, .finalSubmission), .completed:
      break
    default:
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    markCompletedCalls += 1
    let completed = ComposerImageSubmissionRecoveryState.completed(reference: reference)
    self.state = completed
    return completed
  }

  func removeAttachments(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws {
    guard intent.submissionID == reference.submissionID, state == .completed(reference: reference)
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    removeAttachmentsCalls += 1
    if failsNextRemove {
      failsNextRemove = false
      throw ComposerImageSubmissionPipelineError.unavailable
    }
  }

  func deleteCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws {
    guard
      userID == self.userID,
      intent.submissionID == reference.submissionID,
      state == .completed(reference: reference)
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    deleteCompletedCalls += 1
    state = nil
  }

  func prepareCount() -> Int { prepareCalls }
  func executeCount() -> Int { executeCalls }
  func recoverVisibilityCount() -> Int { recoverVisibilityCalls }
  func markCompletedCount() -> Int { markCompletedCalls }
  func removeAttachmentsCount() -> Int { removeAttachmentsCalls }
  func deleteCompletedCount() -> Int { deleteCompletedCalls }
}

private actor ReplySubmissionVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession? = nil) {
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

private enum ReplySubmissionServiceBehavior: Sendable {
  case confirmed(CreatedTextReply)
  case accepted(TextReplyReceipt)
  case failure(TextReplySubmissionError)
  case untypedFailure
  case cancellation
}

private actor ReplySubmissionServiceSpy: AccountService {
  private let behavior: ReplySubmissionServiceBehavior
  private let suspendsSubmissions: Bool
  private var requests: [(StoredAccountSession, TextReplySubmission)] = []
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    behavior: ReplySubmissionServiceBehavior,
    suspendsSubmissions: Bool = false
  ) {
    self.behavior = behavior
    self.suspendsSubmissions = suspendsSubmissions
  }

  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission
  ) async throws -> TextReplyResult {
    requests.append((session, submission))
    if suspendsSubmissions, !isReleased {
      await withCheckedContinuation { waiters.append($0) }
    }
    switch behavior {
    case .confirmed(let created):
      return TextReplyResult(
        submissionID: submission.id,
        userID: session.id,
        target: submission.target,
        outcome: .confirmed(created)
      )!
    case .accepted(let receipt):
      return TextReplyResult(
        submissionID: submission.id,
        userID: session.id,
        target: submission.target,
        outcome: .acceptedAwaitingVisibility(receipt)
      )!
    case .failure(let error):
      throw error
    case .untypedFailure:
      throw ReplySubmissionTestFailure.persistenceFailure
    case .cancellation:
      throw CancellationError()
    }
  }

  func requestCount() -> Int { requests.count }
  func lastSubmission() -> TextReplySubmission? { requests.last?.1 }

  func releaseSubmissions() {
    isReleased = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ReplySubmissionTestFailure.unexpectedCall
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ReplySubmissionTestFailure.unexpectedCall
  }
}

private actor ReplySubmissionDraftRepository: TextReplyDraftRepository {
  private var values: [TextReplyDraftKey: TextReplyDraft] = [:]
  private let suspendedReadNumbers: Set<Int>
  private let suspendedSaveNumbers: Set<Int>
  private let failedSaveNumbers: Set<Int>
  private var reads = 0
  private var saves = 0
  private var deletes = 0
  private var readIsReleased = false
  private var readWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveIsReleased = false
  private var saveWaiters: [CheckedContinuation<Void, Never>] = []
  private var failsNextDelete: Bool

  init(
    suspendedReadNumbers: Set<Int> = [],
    suspendedSaveNumbers: Set<Int> = [],
    failedSaveNumbers: Set<Int> = [],
    failsNextDelete: Bool = false
  ) {
    self.suspendedReadNumbers = suspendedReadNumbers
    self.suspendedSaveNumbers = suspendedSaveNumbers
    self.failedSaveNumbers = failedSaveNumbers
    self.failsNextDelete = failsNextDelete
  }

  func draft(for key: TextReplyDraftKey) async throws -> TextReplyDraft? {
    reads += 1
    if suspendedReadNumbers.contains(reads), !readIsReleased {
      await withCheckedContinuation { readWaiters.append($0) }
    }
    return values[key]
  }

  func save(_ draft: TextReplyDraft) async throws {
    saves += 1
    if suspendedSaveNumbers.contains(saves), !saveIsReleased {
      await withCheckedContinuation { saveWaiters.append($0) }
    }
    if failedSaveNumbers.contains(saves) {
      throw ReplySubmissionTestFailure.persistenceFailure
    }
    values[draft.key] = draft
  }

  func delete(for key: TextReplyDraftKey) async throws {
    deletes += 1
    if failsNextDelete {
      failsNextDelete = false
      throw ReplySubmissionTestFailure.persistenceFailure
    }
    values.removeValue(forKey: key)
  }

  func deleteAll() async throws { values.removeAll() }
  func draftReadCount() -> Int { reads }
  func saveCount() -> Int { saves }
  func deleteCount() -> Int { deletes }

  func releaseSaves() {
    saveIsReleased = true
    let continuations = saveWaiters
    saveWaiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseReads() {
    readIsReleased = true
    let continuations = readWaiters
    readWaiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseNextSave() {
    guard !saveWaiters.isEmpty else { return }
    saveWaiters.removeFirst().resume()
  }
}

@MainActor
private func replySubmissionStore(
  vault: ReplySubmissionVaultSpy,
  service: ReplySubmissionServiceSpy,
  drafts: ReplySubmissionDraftRepository = ReplySubmissionDraftRepository(),
  pipeline: ReplyImagePipelineSpy? = nil,
  attachmentStore: ComposerImageAttachmentStore? = nil
) -> TextReplySubmissionStore {
  TextReplySubmissionStore(
    access: AccountAccess(vault: vault, service: service),
    drafts: drafts,
    imagePipeline: pipeline,
    attachmentStore: attachmentStore,
    attachmentDeletionScheduler: attachmentStore.map {
      ImmediateComposerImageAttachmentDeletionScheduler(store: $0)
    },
    observesAccountSessionChanges: false
  )
}

private func storeReplyTarget(
  destination: TextReplyTarget.Destination = .thread(firstPostID: 700)
) -> TextReplyTarget {
  TextReplyTarget(
    forumID: 7,
    forumName: "swift",
    threadID: 70,
    firstPostID: 700,
    destination: destination
  )!
}

private func storeReplySession(
  userID: Int64 = 9,
  revision: UUID = replyUUID(1),
  hasSTOKEN: Bool = true
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: hasSTOKEN
      ? String(repeating: "s", count: AccountCredentialFormat.stokenLength)
      : nil,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func replyUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func replyStoreImageAttachment(id: UUID) -> ComposerImageAttachment {
  let bytes = Data([0x31, 0x32, 0x33])
  return ComposerImageAttachment(
    id: id,
    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    byteCount: Int64(bytes.count),
    pixelWidth: 16,
    pixelHeight: 16,
    quality: .standard
  )!
}

private func replyStoreImageUploadResult(
  attachment: ComposerImageAttachment,
  submissionID: UUID,
  session: StoredAccountSession,
  target: TextReplyTarget,
  watermark: TiebaStaticImageWatermark
) throws -> ComposerImageUploadResult {
  let bytes = Data([0x31, 0x32, 0x33])
  let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let receiptData = try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": TiebaStaticImageUploadReceipt.currentSchemaVersion,
      "uploadID": attachment.id.uuidString.lowercased(),
      "contentSHA256": sha256,
      "userID": session.id,
      "forumName": target.forumName,
      "preservesOriginal": false,
      "watermark": watermark.rawValue,
      "uploadedPixelWidth": attachment.pixelWidth,
      "uploadedPixelHeight": attachment.pixelHeight,
      "resourceID": md5 + String(TiebaStaticImageUploadPolicy.chunkSize),
      "picID": String(repeating: "a", count: 40),
      "width": attachment.pixelWidth,
      "height": attachment.pixelHeight,
      "byteCount": bytes.count,
      "chunkCount": 1,
    ],
    options: [.sortedKeys]
  )
  let receipt = try JSONDecoder().decode(TiebaStaticImageUploadReceipt.self, from: receiptData)
  let upload = TiebaStaticImageUpload(
    uploadID: attachment.id,
    forumName: target.forumName,
    encodedBytes: bytes,
    pixelWidth: attachment.pixelWidth,
    pixelHeight: attachment.pixelHeight,
    watermark: watermark
  )
  let proof = try TiebaStaticImageContentProof.bind(
    upload: upload,
    receipt: receipt,
    expectedUserID: session.id,
    submissionID: submissionID,
    forumID: target.forumID
  )
  return ComposerImageUploadResult(
    sessionRevision: session.sessionRevision,
    attachment: attachment,
    watermark: watermark,
    receipt: receipt,
    proof: proof
  )
}

@MainActor
private func assertReplySubmissionError<T: Sendable>(
  _ expected: TextReplySubmissionError,
  operation: @MainActor () async throws -> T,
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

private func waitForReplySubmissionTest(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<1_000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw ReplySubmissionTestFailure.timeout
}
