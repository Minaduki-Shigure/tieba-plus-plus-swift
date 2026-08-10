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
}

private enum NewThreadSubmissionTestFailure: Error, Sendable {
  case unexpectedCall
  case persistenceFailure
  case timeout
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
  private var requests: [(StoredAccountSession, NewThreadSubmission)] = []
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    behavior: NewThreadSubmissionServiceBehavior,
    suspendsSubmissions: Bool = false
  ) {
    self.behavior = behavior
    self.suspendsSubmissions = suspendsSubmissions
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
  private let failedSaveNumbers: Set<Int>
  private var saves = 0
  private var deletes = 0
  private var failsNextDelete: Bool

  init(
    failedSaveNumbers: Set<Int> = [],
    failsNextDelete: Bool = false
  ) {
    self.failedSaveNumbers = failedSaveNumbers
    self.failsNextDelete = failsNextDelete
  }

  func draft(for key: NewThreadDraftKey) async throws -> NewThreadDraft? {
    values[key]
  }

  func save(_ draft: NewThreadDraft) async throws {
    saves += 1
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
  func saveCount() -> Int { saves }
  func deleteCount() -> Int { deletes }
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
  drafts: NewThreadSubmissionDraftRepository = NewThreadSubmissionDraftRepository()
) -> NewThreadSubmissionStore {
  NewThreadSubmissionStore(
    access: AccountAccess(vault: vault, service: service),
    drafts: drafts,
    observesAccountSessionChanges: false
  )
}

private func newThreadStoreTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func newThreadStoreReceipt() -> NewThreadReceipt {
  NewThreadReceipt(threadID: 70, firstPostID: 700)!
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
