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
    XCTAssertEqual(readsWhileSecondSaveIsSuspended, 2)

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
  private let suspendedSaveNumbers: Set<Int>
  private let failedSaveNumbers: Set<Int>
  private var reads = 0
  private var saves = 0
  private var deletes = 0
  private var saveIsReleased = false
  private var saveWaiters: [CheckedContinuation<Void, Never>] = []
  private var failsNextDelete: Bool

  init(
    suspendedSaveNumbers: Set<Int> = [],
    failedSaveNumbers: Set<Int> = [],
    failsNextDelete: Bool = false
  ) {
    self.suspendedSaveNumbers = suspendedSaveNumbers
    self.failedSaveNumbers = failedSaveNumbers
    self.failsNextDelete = failsNextDelete
  }

  func draft(for key: TextReplyDraftKey) async throws -> TextReplyDraft? {
    reads += 1
    values[key]
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

  func releaseNextSave() {
    guard !saveWaiters.isEmpty else { return }
    saveWaiters.removeFirst().resume()
  }
}

@MainActor
private func replySubmissionStore(
  vault: ReplySubmissionVaultSpy,
  service: ReplySubmissionServiceSpy,
  drafts: ReplySubmissionDraftRepository = ReplySubmissionDraftRepository()
) -> TextReplySubmissionStore {
  TextReplySubmissionStore(
    access: AccountAccess(vault: vault, service: service),
    drafts: drafts,
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

@MainActor
private func assertReplySubmissionError<T>(
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

private func waitForReplySubmissionTest(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<1_000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  throw ReplySubmissionTestFailure.timeout
}
