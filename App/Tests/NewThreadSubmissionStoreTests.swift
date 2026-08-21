import CryptoKit
import Foundation
@_spi(TiebaPlusPlusApp) import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class NewThreadSubmissionStoreTests: XCTestCase {
  func testActivationAndPreflightBindExactSessionRevision() async throws {
    let target = newThreadStoreTarget()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt()))
    let vault = NewThreadSubmissionVaultSpy()
    let store = newThreadSubmissionStore(vault: vault, service: service)
    let entry = store.entry(for: target)

    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .signedOut)

    let legacy = newThreadStoreSession(revision: newThreadStoreUUID(1), hasSTOKEN: false)
    await vault.replaceActive(with: legacy)
    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .failed(.fullCredentialsRequired))
    _ = try await store.saveDraft(
      title: "凭据不足草稿",
      content: "仍然允许保存",
      for: target
    )
    await assertNewThreadSubmissionError(.fullCredentialsRequired) {
      try await store.submit(
        title: "凭据不足草稿",
        content: "仍然允许保存",
        for: target
      )
    }
    let legacyRequestCount = await service.requestCount()
    XCTAssertEqual(legacyRequestCount, 0)

    let active = newThreadStoreSession(revision: newThreadStoreUUID(2))
    await vault.replaceActive(with: active)
    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .ready)

    await vault.replaceActive(
      with: newThreadStoreSession(revision: newThreadStoreUUID(3))
    )
    await assertNewThreadSubmissionError(.accountChanged) {
      try await store.submit(
        title: "标题",
        content: "正文",
        for: target,
        submissionID: newThreadStoreUUID(4)
      )
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(entry.state, .accountChanged)
  }

  func testCancelledCallerBeforeSubmitPerformsNoPersistenceOrWrite() async throws {
    let target = newThreadStoreTarget()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt()))
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    let gate = NewThreadSubmissionGate()

    let caller = Task { @MainActor in
      await gate.wait()
      return try await store.submit(
        title: nil,
        content: "不会发送",
        for: target,
        submissionID: newThreadStoreUUID(5)
      )
    }
    caller.cancel()
    await gate.open()

    do {
      _ = try await caller.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected before the app-owned flight is created.
    }
    let requestCount = await service.requestCount()
    let saveCount = await drafts.saveCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(saveCount, 0)
    XCTAssertEqual(store.entry(for: target).state, .ready)
  }

  func testSuspendedImageSaveThenDiscardLeavesNoDraftOrReferencedAttachment() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "new-thread-save-discard-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let oldAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(6))
    let newAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(7))
    try await attachmentStore.remove(oldAttachment)
    let oldURL = directoryURL.appendingPathComponent(oldAttachment.relativePrivateFilename)
    let newURL = directoryURL.appendingPathComponent(newAttachment.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: oldURL)
    try Data([0x31, 0x32, 0x33]).write(to: newURL)

    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let drafts = NewThreadSubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = newThreadSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      title: nil,
      content: "旧图片",
      attachments: [oldAttachment],
      imageWatermark: .forumName,
      for: target
    )

    let save = Task { @MainActor in
      try await store.saveDraft(
        title: nil,
        content: "新图片",
        attachments: [newAttachment],
        imageWatermark: .username,
        for: target
      )
    }
    try await waitForNewThreadSubmissionTest { await drafts.saveCount() == 2 }
    let discard = Task { @MainActor in try await store.discardDraft(for: target) }
    await Task.yield()
    await assertNewThreadSubmissionError(.submissionInProgress) {
      try await store.saveDraft(title: nil, content: "不得复活", for: target)
    }

    await drafts.releaseSaves()
    _ = try await save.value
    try await discard.value
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let persisted = try await drafts.draft(for: key)
    XCTAssertNil(persisted)
    XCTAssertNil(store.entry(for: target).draft)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
  }

  func testConcurrentImageSavesKeepLatestAndRecycleEveryReplacedAttachment() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "new-thread-concurrent-saves-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let firstAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(8))
    let secondAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(9))
    let latestAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(12))
    try await attachmentStore.remove(firstAttachment)
    let firstURL = directoryURL.appendingPathComponent(firstAttachment.relativePrivateFilename)
    let secondURL = directoryURL.appendingPathComponent(secondAttachment.relativePrivateFilename)
    let latestURL = directoryURL.appendingPathComponent(latestAttachment.relativePrivateFilename)
    for url in [firstURL, secondURL, latestURL] {
      try Data([0x31, 0x32, 0x33]).write(to: url)
    }

    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let drafts = NewThreadSubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = newThreadSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      title: nil,
      content: "第一版",
      attachments: [firstAttachment],
      imageWatermark: .forumName,
      for: target
    )
    let second = Task { @MainActor in
      try await store.saveDraft(
        title: nil,
        content: "第二版",
        attachments: [secondAttachment],
        imageWatermark: .forumName,
        for: target
      )
    }
    try await waitForNewThreadSubmissionTest { await drafts.saveCount() == 2 }
    let latest = Task { @MainActor in
      try await store.saveDraft(
        title: nil,
        content: "最终版",
        attachments: [latestAttachment],
        imageWatermark: .none,
        for: target
      )
    }
    await drafts.releaseSaves()
    _ = try await second.value
    _ = try await latest.value

    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
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
      "new-thread-cancelled-autosave-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let firstAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(14))
    let retainedAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(15))
    let cancelledAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(16))
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

    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let drafts = NewThreadSubmissionDraftRepository(suspendedSaveNumbers: [2])
    let store = newThreadSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      title: nil,
      content: "第一版",
      attachments: [firstAttachment],
      imageWatermark: .forumName,
      for: target
    )
    let retained = Task { @MainActor in
      try await store.saveDraft(
        title: nil,
        content: "应保留",
        attachments: [retainedAttachment],
        imageWatermark: .forumName,
        for: target
      )
    }
    try await waitForNewThreadSubmissionTest { await drafts.saveCount() == 2 }
    let cancelled = Task { @MainActor in
      try await store.saveDraft(
        title: nil,
        content: "已取消",
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
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    XCTAssertEqual(storedDraft?.content, "应保留")
    XCTAssertEqual(storedDraft?.attachments, [retainedAttachment])
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cancelledURL.path))
  }

  func testAccountChangeCleanupDeletesOnlyAttachmentsWithoutAnyDurableReference() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "new-thread-account-change-cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let referencedAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(17))
    let orphanAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(18))
    try await attachmentStore.remove(referencedAttachment)
    let referencedURL = directoryURL.appendingPathComponent(
      referencedAttachment.relativePrivateFilename
    )
    let orphanURL = directoryURL.appendingPathComponent(orphanAttachment.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: referencedURL)
    try Data([0x31, 0x32, 0x33]).write(to: orphanURL)

    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadSubmissionStore(
      vault: vault,
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: drafts,
      attachmentStore: attachmentStore
    )
    await store.activate(target, for: UUID())
    _ = try await store.saveDraft(
      title: nil,
      content: "持久引用",
      attachments: [referencedAttachment],
      imageWatermark: .forumName,
      for: target
    )
    XCTAssertEqual(store.draftOwnerUserID(for: target), session.id)

    await vault.replaceActive(
      with: newThreadStoreSession(userID: 10, revision: newThreadStoreUUID(19))
    )
    store.accountSessionDidChange()
    await store.removeUnreferencedAttachments(
      [referencedAttachment, orphanAttachment],
      userID: session.id,
      for: target
    )

    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let persisted = try await drafts.draft(for: key)
    XCTAssertEqual(persisted?.attachments, [referencedAttachment])
    XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
  }

  func testCleanupSealRejectsLateSaveAndFailsClosedDuringSubmissionFlight() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "new-thread-cleanup-seal-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    let attachmentStore = ComposerImageAttachmentStore(
      directoryURL: directoryURL,
      trustedRootURL: rootURL
    )
    let cleanupCandidate = newThreadStoreImageAttachment(id: newThreadStoreUUID(20))
    let flightCandidate = newThreadStoreImageAttachment(id: newThreadStoreUUID(21))
    try await attachmentStore.remove(cleanupCandidate)
    let cleanupURL = directoryURL.appendingPathComponent(
      cleanupCandidate.relativePrivateFilename
    )
    let flightURL = directoryURL.appendingPathComponent(flightCandidate.relativePrivateFilename)
    try Data([0x31, 0x32, 0x33]).write(to: cleanupURL)

    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let drafts = NewThreadSubmissionDraftRepository(suspendedReadNumbers: [2])
    let service = NewThreadSubmissionServiceSpy(
      behavior: .confirmed(newThreadStoreReceipt()),
      suspendsSubmissions: true
    )
    let store = newThreadSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
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
    try await waitForNewThreadSubmissionTest { await drafts.draftReadCount() == 2 }
    XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupURL.path))
    await assertNewThreadSubmissionError(.submissionInProgress) {
      try await store.saveDraft(title: nil, content: "不得排到清理之后", for: target)
    }
    await drafts.releaseReads()
    await cleanup.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupURL.path))

    try Data([0x31, 0x32, 0x33]).write(to: flightURL)
    let submission = Task { @MainActor in
      try await store.submit(
        title: nil,
        content: "持有同 key seal",
        for: target,
        submissionID: newThreadStoreUUID(22)
      )
    }
    try await waitForNewThreadSubmissionTest { await service.requestCount() == 1 }
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
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let receipt = newThreadStoreReceipt()
    let drafts = NewThreadSubmissionDraftRepository(suspendedSaveNumbers: [1])
    let service = NewThreadSubmissionServiceSpy(
      behavior: .confirmed(receipt),
      suspendsSubmissions: true
    )
    let store = newThreadSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: service,
      drafts: drafts
    )
    await store.activate(target, for: UUID())

    let oldSave = Task { @MainActor in
      try await store.saveDraft(title: "旧标题", content: "旧自动保存", for: target)
    }
    try await waitForNewThreadSubmissionTest { await drafts.saveCount() == 1 }
    let submissionID = newThreadStoreUUID(13)
    let submit = Task { @MainActor in
      try await store.submit(
        title: "提交标题",
        content: "明确提交快照",
        attachments: [],
        imageWatermark: .forumName,
        for: target,
        submissionID: submissionID
      )
    }
    await Task.yield()
    await assertNewThreadSubmissionError(.submissionInProgress) {
      try await store.saveDraft(title: "迟到标题", content: "迟到自动保存", for: target)
    }

    await drafts.releaseSaves()
    _ = try await oldSave.value
    try await waitForNewThreadSubmissionTest { await service.requestCount() == 1 }
    let lastSubmission = await service.lastSubmission()
    let submitted = try XCTUnwrap(lastSubmission)
    XCTAssertEqual(submitted.id, submissionID)
    XCTAssertEqual(submitted.title, "提交标题")
    XCTAssertEqual(submitted.content, "明确提交快照")
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let pending = try XCTUnwrap(storedDraft)
    XCTAssertEqual(pending.title, "提交标题")
    XCTAssertEqual(pending.content, "明确提交快照")
    XCTAssertEqual(pending.disposition, .submissionPending(submissionID: submissionID))

    await service.releaseSubmissions()
    _ = try await submit.value
    XCTAssertEqual(store.entry(for: target).draft?.content, "明确提交快照")
  }

  func testSameSubmissionSharesAppOwnedFlightAndNeverWritesTwice() async throws {
    let target = newThreadStoreTarget()
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(
      behavior: .confirmed(receipt),
      suspendsSubmissions: true
    )
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let store = newThreadSubmissionStore(vault: vault, service: service)
    let scope = UUID()
    await store.activate(target, for: scope)
    let entry = store.entry(for: target)
    let submissionID = newThreadStoreUUID(10)

    let first = Task { @MainActor in
      try await store.submit(
        title: "标题",
        content: "同一正文",
        for: target,
        submissionID: submissionID
      )
    }
    try await waitForNewThreadSubmissionTest { await service.requestCount() == 1 }
    first.cancel()
    store.deactivate(scope)
    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .submitting(submissionID))

    let shared = Task { @MainActor in
      try await store.submit(
        title: "标题",
        content: "同一正文",
        for: target,
        submissionID: submissionID
      )
    }
    await assertNewThreadSubmissionError(.submissionInProgress) {
      try await store.submit(
        title: "另一个标题",
        content: "另一正文",
        for: target,
        submissionID: newThreadStoreUUID(11)
      )
    }
    let requestCountBeforeRelease = await service.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)

    await service.releaseSubmissions()
    let firstResult = try await first.value
    let sharedResult = try await shared.value
    XCTAssertEqual(firstResult, sharedResult)
    XCTAssertEqual(firstResult.outcome, .confirmed(receipt))
    let finalRequestCount = await service.requestCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(entry.state, .confirmed(receipt))
  }

  func testSubmissionPendingProofIsDurableBeforeServiceCompletes() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let service = NewThreadSubmissionServiceSpy(
      behavior: .confirmed(newThreadStoreReceipt()),
      suspendsSubmissions: true
    )
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    let submissionID = newThreadStoreUUID(20)

    let submission = Task { @MainActor in
      try await store.submit(
        title: "标题",
        content: "发送边界正文",
        for: target,
        submissionID: submissionID
      )
    }
    try await waitForNewThreadSubmissionTest { await service.requestCount() == 1 }
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    XCTAssertEqual(persisted.title, "标题")
    XCTAssertEqual(persisted.content, "发送边界正文")
    XCTAssertEqual(
      persisted.disposition,
      .submissionPending(submissionID: submissionID)
    )

    await service.releaseSubmissions()
    _ = try await submission.value
  }

  func testPendingSaveFailureDoesNotDispatchAndRebuildRestoresEditing() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt()))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository(failedSaveNumbers: [2])
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.unavailable) {
      try await store!.submit(
        title: "标题",
        content: "未派发正文",
        for: target,
        submissionID: newThreadStoreUUID(21)
      )
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let storedEditingDraft = try await drafts.draft(for: key)
    XCTAssertEqual(storedEditingDraft?.disposition, .editing)
    store = nil

    let rebuilt = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .ready)
    XCTAssertEqual(rebuilt.entry(for: target).draft?.title, "标题")
    XCTAssertEqual(rebuilt.entry(for: target).draft?.content, "未派发正文")
  }

  func testChallengeLocksDraftUntilSessionRevisionChanges() async throws {
    let target = newThreadStoreTarget()
    let original = newThreadStoreSession(revision: newThreadStoreUUID(30))
    let service = NewThreadSubmissionServiceSpy(behavior: .failure(.challengeRequired))
    let vault = NewThreadSubmissionVaultSpy(session: original)
    let drafts = NewThreadSubmissionDraftRepository()
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.challengeRequired) {
      try await store!.submit(
        title: "标题",
        content: "挑战正文",
        for: target,
        submissionID: newThreadStoreUUID(31)
      )
    }
    XCTAssertEqual(store?.entry(for: target).state, .challengeRequired)
    await assertNewThreadSubmissionError(.challengeRequired) {
      try await store!.saveDraft(title: "修改", content: "修改", for: target)
    }
    await assertNewThreadSubmissionError(.challengeRequired) {
      try await store!.discardDraft(for: target)
    }
    await assertNewThreadSubmissionError(.challengeRequired) {
      try await store!.submit(title: nil, content: "重发", for: target)
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
    store = nil

    let blocked = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await blocked.activate(target, for: UUID())
    XCTAssertEqual(blocked.entry(for: target).state, .challengeRequired)

    await vault.replaceActive(
      with: newThreadStoreSession(revision: newThreadStoreUUID(32))
    )
    let renewed = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await renewed.activate(target, for: UUID())
    XCTAssertEqual(renewed.entry(for: target).state, .ready)
    XCTAssertEqual(renewed.entry(for: target).draft?.content, "挑战正文")
  }

  func testUnknownOutcomeSurvivesRebuildAndCannotBeEditedOrResent() async throws {
    let target = newThreadStoreTarget()
    let service = NewThreadSubmissionServiceSpy(behavior: .untypedFailure)
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let drafts = NewThreadSubmissionDraftRepository()
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await store!.submit(
        title: nil,
        content: "结果未知",
        for: target,
        submissionID: newThreadStoreUUID(40)
      )
    }
    XCTAssertEqual(store?.entry(for: target).state, .outcomeUnknown)
    store = nil

    let rebuilt = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .outcomeUnknown)
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.saveDraft(title: nil, content: "修改", for: target)
    }
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.discardDraft(for: target)
    }
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.submit(title: nil, content: "重发", for: target)
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testVisibilityConfirmationRequiresExactReceiptTargetUserTitleAndContent() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(behavior: .accepted(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    _ = try await store.submit(
      title: "标题",
      content: "待确认正文",
      for: target,
      submissionID: newThreadStoreUUID(50)
    )
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await store.discardDraft(for: target)
    }
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await store.saveDraft(title: "修改", content: "修改", for: target)
    }

    let wrongUser = newThreadConfirmation(
      receipt: receipt,
      target: target,
      userID: 10,
      title: "标题",
      content: "待确认正文"
    )
    await assertNewThreadSubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongUser, matching: receipt, for: target)
    }
    let wrongTitle = newThreadConfirmation(
      receipt: receipt,
      target: target,
      userID: session.id,
      title: "别的标题",
      content: "待确认正文"
    )
    await assertNewThreadSubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongTitle, matching: receipt, for: target)
    }
    let wrongContent = newThreadConfirmation(
      receipt: receipt,
      target: target,
      userID: session.id,
      title: "标题",
      content: "别的正文"
    )
    await assertNewThreadSubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongContent, matching: receipt, for: target)
    }
    let otherTarget = NewThreadTarget(forumID: 8, forumName: "other")!
    let wrongTarget = newThreadConfirmation(
      receipt: receipt,
      target: otherTarget,
      userID: session.id,
      title: "标题",
      content: "待确认正文"
    )
    await assertNewThreadSubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongTarget, matching: receipt, for: target)
    }

    let proof = newThreadConfirmation(
      receipt: receipt,
      target: target,
      userID: session.id,
      title: "标题",
      content: "待确认正文"
    )
    let confirmed = try await store.confirmVisibility(proof, matching: receipt, for: target)
    XCTAssertEqual(confirmed.outcome, .confirmed(receipt))
    XCTAssertEqual(store.entry(for: target).state, .confirmed(receipt))
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let storedAfterConfirmation = try await drafts.draft(for: key)
    XCTAssertEqual(
      storedAfterConfirmation?.disposition,
      .confirmed(submissionID: newThreadStoreUUID(50), receipt: receipt)
    )
    try await store.discardDraft(for: target)
    let storedAfterExplicitDiscard = try await drafts.draft(for: key)
    XCTAssertNil(storedAfterExplicitDiscard)
    XCTAssertEqual(store.entry(for: target).state, .ready)
  }

  func testUntitledSubmissionAcceptsServerGeneratedTitleDuringVisibilityConfirmation()
    async throws
  {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(behavior: .accepted(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let store = newThreadSubmissionStore(vault: vault, service: service)
    await store.activate(target, for: UUID())
    _ = try await store.submit(
      title: nil,
      content: "无标题正文",
      for: target,
      submissionID: newThreadStoreUUID(51)
    )

    let generatedTitleProof = newThreadConfirmation(
      receipt: receipt,
      target: target,
      userID: session.id,
      title: String(repeating: "贴吧生成标题", count: 8),
      content: "无标题正文"
    )
    let confirmed = try await store.confirmVisibility(
      generatedTitleProof,
      matching: receipt,
      for: target
    )

    XCTAssertEqual(confirmed.outcome, .confirmed(receipt))
    XCTAssertEqual(store.entry(for: target).state, .confirmed(receipt))
  }

  func testSameUserReloginDuringFlightDiscardsLatePresentationButPersistsProof() async throws {
    let target = newThreadStoreTarget()
    let original = newThreadStoreSession(revision: newThreadStoreUUID(60))
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(
      behavior: .confirmed(receipt),
      suspendsSubmissions: true
    )
    let vault = NewThreadSubmissionVaultSpy(session: original)
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await store.activate(target, for: UUID())
    let entry = store.entry(for: target)

    let submission = Task { @MainActor in
      try await store.submit(
        title: "标题",
        content: "切换期间正文",
        for: target,
        submissionID: newThreadStoreUUID(61)
      )
    }
    try await waitForNewThreadSubmissionTest { await service.requestCount() == 1 }
    await vault.replaceActive(
      with: newThreadStoreSession(revision: newThreadStoreUUID(62))
    )
    await service.releaseSubmissions()
    await assertNewThreadSubmissionError(.accountChanged) { try await submission.value }
    XCTAssertEqual(entry.state, .accountChanged)
    let key = try XCTUnwrap(NewThreadDraftKey(userID: original.id, target: target))
    let storedDraft = try await drafts.draft(for: key)
    let persisted = try XCTUnwrap(storedDraft)
    XCTAssertEqual(
      persisted.disposition,
      .confirmed(
        submissionID: newThreadStoreUUID(61),
        receipt: receipt
      )
    )
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testConfirmedResultSurvivesImmediateStoreRebuildUntilExplicitDiscard() async throws {
    let target = newThreadStoreTarget()
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let drafts = NewThreadSubmissionDraftRepository()
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    _ = try await store!.submit(
      title: "已确认标题",
      content: "已确认正文",
      for: target,
      submissionID: newThreadStoreUUID(69)
    )
    XCTAssertEqual(store?.entry(for: target).state, .confirmed(receipt))
    store = nil

    let rebuilt = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .confirmed(receipt))
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.submit(title: "已确认标题", content: "已确认正文", for: target)
    }
    let requestCountBeforeDiscard = await service.requestCount()
    XCTAssertEqual(requestCountBeforeDiscard, 1)

    try await rebuilt.discardDraft(for: target)
    XCTAssertEqual(rebuilt.entry(for: target).state, .ready)
    _ = try await rebuilt.submit(
      title: "下一主题",
      content: "下一正文",
      for: target,
      submissionID: newThreadStoreUUID(71)
    )
    let requestCountAfterNewSubmission = await service.requestCount()
    XCTAssertEqual(requestCountAfterNewSubmission, 2)
  }

  func testConfirmedTombstoneSaveFailureRebuildsUnknownAndNeverResends() async throws {
    let target = newThreadStoreTarget()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt()))
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let drafts = NewThreadSubmissionDraftRepository(failedSaveNumbers: [3])
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await store!.submit(
        title: nil,
        content: "确认标记写入失败",
        for: target,
        submissionID: newThreadStoreUUID(72)
      )
    }
    XCTAssertEqual(store?.entry(for: target).state, .outcomeUnknown)
    store = nil

    let rebuilt = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .outcomeUnknown)
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.submit(title: nil, content: "确认标记写入失败", for: target)
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testConfirmedTombstoneSurvivesDiscardFailureAndNeverResends() async throws {
    let target = newThreadStoreTarget()
    let receipt = newThreadStoreReceipt()
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: newThreadStoreSession())
    let drafts = NewThreadSubmissionDraftRepository(failsNextDelete: true)
    var store: NewThreadSubmissionStore? = newThreadSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts
    )
    await store?.activate(target, for: UUID())

    _ = try await store!.submit(
      title: nil,
      content: "已经成功",
      for: target,
      submissionID: newThreadStoreUUID(70)
    )
    XCTAssertEqual(store?.entry(for: target).state, .confirmed(receipt))
    await assertNewThreadSubmissionError(.unavailable) {
      try await store!.discardDraft(for: target)
    }
    XCTAssertEqual(store?.entry(for: target).state, .confirmed(receipt))
    store = nil

    let rebuilt = newThreadSubmissionStore(vault: vault, service: service, drafts: drafts)
    await rebuilt.activate(target, for: UUID())
    XCTAssertEqual(rebuilt.entry(for: target).state, .confirmed(receipt))
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.submit(title: nil, content: "已经成功", for: target)
    }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testImagePreparationSaveFailureRestartsWithoutNetworkUntilExplicitResume()
    async throws
  {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(80)
    let reference = ComposerImageSubmissionReference(
      submissionID: submissionID,
      sessionRevision: session.sessionRevision
    )!
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(81))
    let receipt = newThreadStoreReceipt()
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .confirmed(receipt),
      userID: session.id
    )
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository(failedSaveNumbers: [3])
    var store: NewThreadSubmissionStore? = newThreadImageSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.unavailable) {
      try await store!.submit(
        title: "图片主题",
        content: "正文",
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
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let preparationDraft = try await drafts.draft(for: key)
    XCTAssertEqual(
      preparationDraft?.disposition,
      .imagePreparationPending(reference: reference)
    )
    store = nil

    let rebuilt = newThreadImageSubmissionStore(
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
    XCTAssertEqual(result.outcome, .confirmed(receipt))
    let executeCountAfterResume = await pipeline.executeCount()
    let markCountAfterResume = await pipeline.markCompletedCount()
    let removeCountAfterResume = await pipeline.removeAttachmentsCount()
    let deleteCountAfterResume = await pipeline.deleteCompletedCount()
    XCTAssertEqual(executeCountAfterResume, 1)
    XCTAssertEqual(markCountAfterResume, 1)
    XCTAssertEqual(removeCountAfterResume, 1)
    XCTAssertEqual(deleteCountAfterResume, 1)
    let terminalDraft = try await drafts.draft(for: key)
    XCTAssertEqual(
      terminalDraft?.disposition,
      .imageConfirmed(reference: reference, receipt: receipt)
    )
  }

  func testImagePipelineAccountChangeCannotRemainResumable() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(180))
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .failure(.accountChanged),
      userID: session.id
    )
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: NewThreadSubmissionDraftRepository(),
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.accountChanged) {
      try await store.submit(
        title: nil,
        content: "账户已切换",
        attachments: [attachment],
        imageWatermark: .forumName,
        for: target,
        submissionID: newThreadStoreUUID(181)
      )
    }

    XCTAssertEqual(store.entry(for: target).state, .accountChanged)
    await assertNewThreadSubmissionError(.accountChanged) {
      try await store.resumeImageSubmission(for: target)
    }
    let executeCount = await pipeline.executeCount()
    XCTAssertEqual(executeCount, 1)
  }

  func testImageOutcomeUnknownLocksAcrossRestartAndNeverDispatchesTwice() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(82)
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(83))
    let operation = ComposerImageUploadOutcomeUnknownOperation.attachment(
      attachmentID: attachment.id
    )
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .failure(.outcomeUnknown(operation)),
      userID: session.id
    )
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt()))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository()
    var store: NewThreadSubmissionStore? = newThreadImageSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store?.activate(target, for: UUID())

    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await store!.submit(
        title: nil,
        content: "未知结果",
        attachments: [attachment],
        imageWatermark: .none,
        for: target,
        submissionID: submissionID
      )
    }
    let executeCountAfterUnknown = await pipeline.executeCount()
    XCTAssertEqual(executeCountAfterUnknown, 1)
    store = nil

    let rebuilt = newThreadImageSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await rebuilt.activate(target, for: UUID())
    guard case .imageRecovery(.locked(_, let recoveredOperation)) =
      rebuilt.entry(for: target).state
    else {
      return XCTFail("Expected locked image recovery")
    }
    XCTAssertEqual(recoveredOperation, operation)
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.resumeImageSubmission(for: target)
    }
    await assertNewThreadSubmissionError(.outcomeUnknown) {
      try await rebuilt.submit(title: nil, content: "重复发送", for: target)
    }
    let executeCountAfterBlockedRetries = await pipeline.executeCount()
    XCTAssertEqual(executeCountAfterBlockedRetries, 1)
  }

  func testEditingDraftRollbackPromotesExactImageLedgerWithoutAutomaticNetwork()
    async throws
  {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(84)
    let reference = ComposerImageSubmissionReference(
      submissionID: submissionID,
      sessionRevision: session.sessionRevision
    )!
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(85))
    let receipt = newThreadStoreReceipt()
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .accepted(receipt),
      userID: session.id
    )
    let seededIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(
        newThread: XCTUnwrap(
          NewThreadSubmission(
            id: submissionID,
            target: target,
            title: "回滚标题",
            content: "回滚正文",
            attachments: [attachment],
            imageWatermark: .username
          )
        )
      )
    )
    await pipeline.seed(
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      ),
      intent: seededIntent
    )
    let service = NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt))
    let vault = NewThreadSubmissionVaultSpy(session: session)
    let drafts = NewThreadSubmissionDraftRepository()
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    let editing = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "回滚标题",
        content: "回滚正文",
        attachments: [attachment],
        imageWatermark: .username
      )
    )
    try await drafts.save(editing)

    let store = newThreadImageSubmissionStore(
      vault: vault,
      service: service,
      drafts: drafts,
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())
    XCTAssertEqual(
      store.entry(for: target).state,
      .imageRecovery(
        .uploadResumeRequired(
          reference: reference,
          successfulUploadCount: 0,
          totalAttachmentCount: 1
        )
      )
    )
    XCTAssertEqual(store.entry(for: target).draft?.disposition, .imagePipeline(reference: reference))
    let executeCountBeforeExplicitResume = await pipeline.executeCount()
    XCTAssertEqual(executeCountBeforeExplicitResume, 0)

    _ = try await store.resumeImageSubmission(for: target)
    let executeCountAfterExplicitResume = await pipeline.executeCount()
    let acceptedMarkCount = await pipeline.markCompletedCount()
    let acceptedRemoveCount = await pipeline.removeAttachmentsCount()
    let acceptedDeleteCount = await pipeline.deleteCompletedCount()
    XCTAssertEqual(executeCountAfterExplicitResume, 1)
    XCTAssertEqual(acceptedMarkCount, 1)
    XCTAssertEqual(acceptedRemoveCount, 0)
    XCTAssertEqual(acceptedDeleteCount, 0)
    XCTAssertEqual(
      store.entry(for: target).draft?.disposition,
      .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt)
    )
  }

  func testImageLedgerFromPreviousSessionRevisionLocksWithoutNetwork() async throws {
    let target = newThreadStoreTarget()
    let oldSession = newThreadStoreSession(revision: newThreadStoreUUID(86))
    let renewedSession = newThreadStoreSession(revision: newThreadStoreUUID(87))
    let submissionID = newThreadStoreUUID(88)
    let reference = ComposerImageSubmissionReference(
      submissionID: submissionID,
      sessionRevision: oldSession.sessionRevision
    )!
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(89))
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .confirmed(newThreadStoreReceipt()),
      userID: renewedSession.id
    )
    let seededIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(
        newThread: XCTUnwrap(
          NewThreadSubmission(
            id: submissionID,
            target: target,
            title: nil,
            content: "旧会话草稿",
            attachments: [attachment],
            imageWatermark: .forumName
          )
        )
      )
    )
    await pipeline.seed(
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      ),
      intent: seededIntent
    )
    let drafts = NewThreadSubmissionDraftRepository()
    let key = try XCTUnwrap(NewThreadDraftKey(userID: renewedSession.id, target: target))
    try await drafts.save(
      XCTUnwrap(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "旧会话草稿",
          attachments: [attachment]
        )
      )
    )
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: renewedSession),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      drafts: drafts,
      pipeline: pipeline
    )

    await store.activate(target, for: UUID())
    XCTAssertEqual(store.entry(for: target).state, .accountChanged)
    let previousSessionExecuteCount = await pipeline.executeCount()
    XCTAssertEqual(previousSessionExecuteCount, 0)
    await assertNewThreadSubmissionError(.accountChanged) {
      try await store.resumeImageSubmission(for: target)
    }
  }

  func testImageVisibilityRequiresExactAttachmentWatermarkAndAuthenticatedUploads()
    async throws
  {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(90)
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(91))
    let receipt = newThreadStoreReceipt()
    let upload = try newThreadStoreImageUploadResult(
      attachment: attachment,
      submissionID: submissionID,
      session: session,
      target: target,
      watermark: .username
    )
    let exact = try XCTUnwrap(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: session.id,
        title: "图片标题",
        content: "图片正文",
        attachments: [attachment],
        imageWatermark: .username
      )
    )
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .accepted(receipt),
      userID: session.id,
      visibilityUploads: [upload]
    )
    let drafts = NewThreadSubmissionDraftRepository()
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(
        behavior: .confirmed(receipt),
        visibilityConfirmation: exact
      ),
      drafts: drafts,
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())
    _ = try await store.submit(
      title: "图片标题",
      content: "图片正文",
      attachments: [attachment],
      imageWatermark: .username,
      for: target,
      submissionID: submissionID
    )
    let acceptedMarkCount = await pipeline.markCompletedCount()
    let acceptedRemoveCount = await pipeline.removeAttachmentsCount()
    let acceptedDeleteCount = await pipeline.deleteCompletedCount()
    XCTAssertEqual(acceptedMarkCount, 1)
    XCTAssertEqual(acceptedRemoveCount, 0)
    XCTAssertEqual(acceptedDeleteCount, 0)

    let wrongWatermark = try XCTUnwrap(
      NewThreadVisibilityConfirmation(
        receipt: receipt,
        target: target,
        authorUserID: session.id,
        title: "图片标题",
        content: "图片正文",
        attachments: [attachment],
        imageWatermark: .none
      )
    )
    await assertNewThreadSubmissionError(.invalidSubmission) {
      try await store.confirmVisibility(wrongWatermark, matching: receipt, for: target)
    }
    let verifiedResult = try await store.verifyVisibility(for: target)
    let result = try XCTUnwrap(verifiedResult)
    XCTAssertEqual(result.outcome, .confirmed(receipt))
    let recoverCount = await pipeline.recoverVisibilityCount()
    let confirmedRemoveCount = await pipeline.removeAttachmentsCount()
    let confirmedDeleteCount = await pipeline.deleteCompletedCount()
    XCTAssertEqual(recoverCount, 2)
    XCTAssertEqual(confirmedRemoveCount, 1)
    XCTAssertEqual(confirmedDeleteCount, 1)
    XCTAssertEqual(
      store.entry(for: target).draft?.disposition,
      .imageConfirmed(
        reference: ComposerImageSubmissionReference(
          submissionID: submissionID,
          sessionRevision: session.sessionRevision
        )!,
        receipt: receipt
      )
    )
  }

  func testMissingDraftWithBlockingImageLedgerNeverStartsAnotherSubmission() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let reference = ComposerImageSubmissionReference(
      submissionID: newThreadStoreUUID(94),
      sessionRevision: session.sessionRevision
    )!
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .confirmed(newThreadStoreReceipt()),
      userID: session.id
    )
    let orphanAttachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(97))
    let seededIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(
        newThread: XCTUnwrap(
          NewThreadSubmission(
            id: reference.submissionID,
            target: target,
            title: nil,
            content: "孤儿账本",
            attachments: [orphanAttachment],
            imageWatermark: .forumName
          )
        )
      )
    )
    await pipeline.seed(
      .uploadResumeRequired(
        reference: reference,
        successfulUploadCount: 0,
        totalAttachmentCount: 1
      ),
      intent: seededIntent
    )
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(newThreadStoreReceipt())),
      pipeline: pipeline
    )

    await store.activate(target, for: UUID())
    XCTAssertEqual(store.entry(for: target).state, .imageRecoveryUnavailable)
    await assertNewThreadSubmissionError(.unavailable) {
      try await store.submit(title: nil, content: "不得重复", for: target)
    }
    let executeCount = await pipeline.executeCount()
    XCTAssertEqual(executeCount, 0)
  }

  func testFinalImageSubmissionResumeAlsoRequiresExplicitAction() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(95)
    let reference = ComposerImageSubmissionReference(
      submissionID: submissionID,
      sessionRevision: session.sessionRevision
    )!
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(96))
    let receipt = newThreadStoreReceipt()
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .confirmed(receipt),
      userID: session.id
    )
    let seededIntent = try XCTUnwrap(
      ComposerImageSubmissionIntent(
        newThread: XCTUnwrap(
          NewThreadSubmission(
            id: submissionID,
            target: target,
            title: nil,
            content: "上传已完成",
            attachments: [attachment],
            imageWatermark: .forumName
          )
        )
      )
    )
    await pipeline.seed(
      .finalSubmissionResumeRequired(reference: reference),
      intent: seededIntent
    )
    let drafts = NewThreadSubmissionDraftRepository()
    let key = try XCTUnwrap(NewThreadDraftKey(userID: session.id, target: target))
    try await drafts.save(
      XCTUnwrap(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "上传已完成",
          attachments: [attachment],
          disposition: .imagePipeline(reference: reference)
        )
      )
    )
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt)),
      drafts: drafts,
      pipeline: pipeline
    )

    await store.activate(target, for: UUID())
    XCTAssertEqual(
      store.entry(for: target).state,
      .imageRecovery(.finalSubmissionResumeRequired(reference: reference))
    )
    let executeCountBeforeResume = await pipeline.executeCount()
    XCTAssertEqual(executeCountBeforeResume, 0)
    let result = try await store.resumeImageSubmission(for: target)
    XCTAssertEqual(result.outcome, .confirmed(receipt))
    let executeCountAfterResume = await pipeline.executeCount()
    XCTAssertEqual(executeCountAfterResume, 1)
  }

  func testCancellingImageSubmitCallerDoesNotCancelAppOwnedFlight() async throws {
    let target = newThreadStoreTarget()
    let session = newThreadStoreSession()
    let submissionID = newThreadStoreUUID(92)
    let attachment = newThreadStoreImageAttachment(id: newThreadStoreUUID(93))
    let receipt = newThreadStoreReceipt()
    let pipeline = NewThreadImagePipelineSpy(
      behavior: .confirmed(receipt),
      userID: session.id,
      suspendsExecution: true
    )
    let store = newThreadImageSubmissionStore(
      vault: NewThreadSubmissionVaultSpy(session: session),
      service: NewThreadSubmissionServiceSpy(behavior: .confirmed(receipt)),
      pipeline: pipeline
    )
    await store.activate(target, for: UUID())

    let first = Task { @MainActor in
      try await store.submit(
        title: nil,
        content: "取消等待",
        attachments: [attachment],
        imageWatermark: .forumName,
        for: target,
        submissionID: submissionID
      )
    }
    try await waitForNewThreadSubmissionTest { await pipeline.executeCount() == 1 }
    first.cancel()
    let shared = Task { @MainActor in
      try await store.submit(
        title: nil,
        content: "取消等待",
        attachments: [attachment],
        imageWatermark: .forumName,
        for: target,
        submissionID: submissionID
      )
    }
    await pipeline.releaseExecutions()
    let result = try await shared.value
    XCTAssertEqual(result.outcome, .confirmed(receipt))
    let executeCount = await pipeline.executeCount()
    XCTAssertEqual(executeCount, 1)
    _ = try? await first.value
  }
}

private enum NewThreadSubmissionTestFailure: Error, Sendable {
  case unexpectedCall
  case persistenceFailure
  case timeout
}

private enum NewThreadImagePipelineBehavior: Sendable {
  case confirmed(NewThreadReceipt)
  case accepted(NewThreadReceipt)
  case failure(ComposerImageSubmissionPipelineError)
}

private actor NewThreadImagePipelineSpy: ComposerImageSubmissionPipelining {
  private let behavior: NewThreadImagePipelineBehavior
  private let userID: Int64
  private let suspendsExecution: Bool
  private let executionGate = NewThreadSubmissionGate()
  private let visibilityUploads: [ComposerImageUploadResult]
  private var state: ComposerImageSubmissionRecoveryState?
  private var recordedIntent: ComposerImageSubmissionIntent?
  private var prepareCalls = 0
  private var executeCalls = 0
  private var recoverVisibilityCalls = 0
  private var markCompletedCalls = 0
  private var removeAttachmentsCalls = 0
  private var deleteCompletedCalls = 0

  init(
    behavior: NewThreadImagePipelineBehavior,
    userID: Int64,
    visibilityUploads: [ComposerImageUploadResult] = [],
    suspendsExecution: Bool = false
  ) {
    self.behavior = behavior
    self.userID = userID
    self.visibilityUploads = visibilityUploads
    self.suspendsExecution = suspendsExecution
  }

  func seed(
    _ state: ComposerImageSubmissionRecoveryState?,
    intent: ComposerImageSubmissionIntent? = nil
  ) {
    self.state = state
    recordedIntent = intent
  }

  func prepareNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard
      submission.id == reference.submissionID,
      let intent = ComposerImageSubmissionIntent(newThread: submission)
    else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    recordedIntent = intent
    prepareCalls += 1
    let prepared = ComposerImageSubmissionRecoveryState.uploadResumeRequired(
      reference: reference,
      successfulUploadCount: 0,
      totalAttachmentCount: submission.attachments.count
    )
    state = prepared
    return prepared
  }

  func prepareDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func prepare(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func blockingRecoveryState(
    for context: ComposerImageUploadContext,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard userID == self.userID else { return nil }
    guard let state else { return nil }
    guard recordedIntent?.context == context else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    return state
  }

  func blockingRecoveryState(
    for intent: ComposerImageSubmissionIntent,
    userID: Int64
  ) async throws -> ComposerImageSubmissionRecoveryState? {
    guard userID == self.userID else { return nil }
    guard let state else { return nil }
    guard recordedIntent == intent else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    return state
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
    guard recordedIntent == intent, intent.submissionID == reference.submissionID else {
      throw ComposerImageSubmissionPipelineError.intentMismatch
    }
    return state
  }

  func executeNewThread(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> NewThreadResult {
    guard
      submission.id == reference.submissionID,
      state?.reference == reference,
      ComposerImageSubmissionIntent(newThread: submission) == recordedIntent
    else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    executeCalls += 1
    if suspendsExecution {
      await executionGate.wait()
    }
    switch behavior {
    case .confirmed(let receipt):
      state = .locked(reference: reference, operation: .finalSubmission)
      return NewThreadResult(
        submissionID: submission.id,
        userID: userID,
        target: submission.target,
        outcome: .confirmed(receipt)
      )!
    case .accepted(let receipt):
      state = .locked(reference: reference, operation: .finalSubmission)
      return NewThreadResult(
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

  func executeDirectTopicReply(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> TextReplyResult {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func recoverNewThreadUploadsForVisibility(
    submission: NewThreadSubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    guard
      submission.id == reference.submissionID,
      state?.reference == reference,
      ComposerImageSubmissionIntent(newThread: submission) == recordedIntent
    else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    guard state == .completed(reference: reference) else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    recoverVisibilityCalls += 1
    return visibilityUploads
  }

  func recoverDirectTopicReplyUploadsForVisibility(
    submission: TextReplySubmission,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func recoverUploadsForVisibility(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> [ComposerImageUploadResult] {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func markCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws -> ComposerImageSubmissionRecoveryState {
    guard
      recordedIntent == intent,
      intent.submissionID == reference.submissionID,
      state?.reference == reference
    else {
      throw ComposerImageSubmissionPipelineError.referenceMismatch
    }
    guard let currentState = state else {
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    switch currentState {
    case .locked(_, .finalSubmission), .completed:
      break
    default:
      throw ComposerImageSubmissionPipelineError.invalidState
    }
    markCompletedCalls += 1
    let completed = ComposerImageSubmissionRecoveryState.completed(reference: reference)
    state = completed
    return completed
  }

  func removeAttachments(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference
  ) async throws {
    guard
      recordedIntent == intent,
      intent.submissionID == reference.submissionID,
      state == .completed(reference: reference)
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    removeAttachmentsCalls += 1
  }

  func deleteCompleted(
    intent: ComposerImageSubmissionIntent,
    reference: ComposerImageSubmissionReference,
    userID: Int64
  ) async throws {
    guard
      userID == self.userID,
      recordedIntent == intent,
      intent.submissionID == reference.submissionID,
      state == .completed(reference: reference)
    else { throw ComposerImageSubmissionPipelineError.invalidState }
    deleteCompletedCalls += 1
    state = nil
  }

  func releaseExecutions() async {
    await executionGate.open()
  }

  func prepareCount() -> Int { prepareCalls }
  func executeCount() -> Int { executeCalls }
  func recoverVisibilityCount() -> Int { recoverVisibilityCalls }
  func markCompletedCount() -> Int { markCompletedCalls }
  func removeAttachmentsCount() -> Int { removeAttachmentsCalls }
  func deleteCompletedCount() -> Int { deleteCompletedCalls }
}

private actor NewThreadSubmissionVaultSpy: AccountVault {
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

private enum NewThreadSubmissionServiceBehavior: Sendable {
  case confirmed(NewThreadReceipt)
  case accepted(NewThreadReceipt)
  case failure(NewThreadSubmissionError)
  case untypedFailure
  case cancellation
}

private actor NewThreadSubmissionServiceSpy: AccountService {
  private let behavior: NewThreadSubmissionServiceBehavior
  private let suspendsSubmissions: Bool
  private let visibilityConfirmation: NewThreadVisibilityConfirmation?
  private var requests: [(StoredAccountSession, NewThreadSubmission)] = []
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    behavior: NewThreadSubmissionServiceBehavior,
    suspendsSubmissions: Bool = false,
    visibilityConfirmation: NewThreadVisibilityConfirmation? = nil
  ) {
    self.behavior = behavior
    self.suspendsSubmissions = suspendsSubmissions
    self.visibilityConfirmation = visibilityConfirmation
  }

  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission
  ) async throws -> NewThreadResult {
    requests.append((session, submission))
    if suspendsSubmissions, !isReleased {
      await withCheckedContinuation { waiters.append($0) }
    }
    switch behavior {
    case .confirmed(let receipt):
      return NewThreadResult(
        submissionID: submission.id,
        userID: session.id,
        target: submission.target,
        outcome: .confirmed(receipt)
      )!
    case .accepted(let receipt):
      return NewThreadResult(
        submissionID: submission.id,
        userID: session.id,
        target: submission.target,
        outcome: .acceptedAwaitingVisibility(receipt)
      )!
    case .failure(let error):
      throw error
    case .untypedFailure:
      throw NewThreadSubmissionTestFailure.unexpectedCall
    case .cancellation:
      throw CancellationError()
    }
  }

  func requestCount() -> Int { requests.count }
  func lastSubmission() -> NewThreadSubmission? { requests.last?.1 }

  func verifyNewThreadVisibility(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    receipt: NewThreadReceipt,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadVisibilityConfirmation? {
    guard
      let visibilityConfirmation,
      visibilityConfirmation.receipt == receipt,
      visibilityConfirmation.authorUserID == session.id,
      visibilityConfirmation.target == submission.target,
      visibilityConfirmation.attachments == submission.attachments,
      visibilityConfirmation.imageWatermark == submission.imageWatermark,
      imageUploads.map(\.attachment) == submission.attachments
    else { throw NewThreadSubmissionError.invalidSubmission }
    return visibilityConfirmation
  }

  func releaseSubmissions() {
    isReleased = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw NewThreadSubmissionTestFailure.unexpectedCall
  }
}

private actor NewThreadSubmissionDraftRepository: NewThreadDraftRepository {
  private var values: [NewThreadDraftKey: NewThreadDraft] = [:]
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

  func draft(for key: NewThreadDraftKey) async throws -> NewThreadDraft? {
    reads += 1
    if suspendedReadNumbers.contains(reads), !readIsReleased {
      await withCheckedContinuation { readWaiters.append($0) }
    }
    return values[key]
  }

  func save(_ draft: NewThreadDraft) async throws {
    saves += 1
    if suspendedSaveNumbers.contains(saves), !saveIsReleased {
      await withCheckedContinuation { saveWaiters.append($0) }
    }
    if failedSaveNumbers.contains(saves) {
      throw NewThreadSubmissionTestFailure.persistenceFailure
    }
    values[draft.key] = draft
  }

  func delete(for key: NewThreadDraftKey) async throws {
    deletes += 1
    if failsNextDelete {
      failsNextDelete = false
      throw NewThreadSubmissionTestFailure.persistenceFailure
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
}

private actor NewThreadSubmissionGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }
}

@MainActor
private func newThreadSubmissionStore(
  vault: NewThreadSubmissionVaultSpy,
  service: NewThreadSubmissionServiceSpy,
  drafts: NewThreadSubmissionDraftRepository = NewThreadSubmissionDraftRepository(),
  attachmentStore: ComposerImageAttachmentStore? = nil
) -> NewThreadSubmissionStore {
  NewThreadSubmissionStore(
    access: AccountAccess(vault: vault, service: service),
    drafts: drafts,
    attachmentStore: attachmentStore,
    attachmentDeletionScheduler: attachmentStore.map {
      ImmediateComposerImageAttachmentDeletionScheduler(store: $0)
    },
    observesAccountSessionChanges: false
  )
}

@MainActor
private func newThreadImageSubmissionStore(
  vault: NewThreadSubmissionVaultSpy,
  service: NewThreadSubmissionServiceSpy,
  drafts: NewThreadSubmissionDraftRepository = NewThreadSubmissionDraftRepository(),
  pipeline: NewThreadImagePipelineSpy,
  attachmentStore: ComposerImageAttachmentStore? = nil
) -> NewThreadSubmissionStore {
  NewThreadSubmissionStore(
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

private func newThreadStoreTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func newThreadStoreReceipt() -> NewThreadReceipt {
  NewThreadReceipt(threadID: 70, firstPostID: 700)!
}

private func newThreadStoreImageAttachment(id: UUID) -> ComposerImageAttachment {
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

private func newThreadStoreImageUploadResult(
  attachment: ComposerImageAttachment,
  submissionID: UUID,
  session: StoredAccountSession,
  target: NewThreadTarget,
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

private func newThreadConfirmation(
  receipt: NewThreadReceipt,
  target: NewThreadTarget,
  userID: Int64,
  title: String?,
  content: String
) -> NewThreadVisibilityConfirmation {
  NewThreadVisibilityConfirmation(
    receipt: receipt,
    target: target,
    authorUserID: userID,
    title: title,
    content: content
  )!
}

private func newThreadStoreSession(
  userID: Int64 = 9,
  revision: UUID = newThreadStoreUUID(1),
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

private func newThreadStoreUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

@MainActor
private func assertNewThreadSubmissionError<T: Sendable>(
  _ expected: NewThreadSubmissionError,
  operation: @MainActor () async throws -> T,
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

private func waitForNewThreadSubmissionTest(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<1_000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw NewThreadSubmissionTestFailure.timeout
}
