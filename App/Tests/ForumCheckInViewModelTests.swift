import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ForumCheckInViewModelTests: XCTestCase {
  func testInvalidForumNeverReadsAccountOrCallsService() async {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy()
    let viewModel = makeViewModel(forumID: 0, vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .idle)
    let vaultReadCount = await vault.activeSessionReadCount()
    let accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(vaultReadCount, 0)
    XCTAssertEqual(accountStateRequestCount, 0)
  }

  func testSignedOutDoesNotCallAccountStateService() async {
    let vault = ForumCheckInVaultSpy()
    let service = ForumCheckInServiceSpy()
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .signedOut)
    let accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(accountStateRequestCount, 0)
  }

  func testLoadsRequiresFollowUnavailableReadyAndSignedStates() async {
    let cases: [(ForumAccountStateData, ForumCheckInState)] = [
      (accountState(isFollowed: false, checkIn: nil), .requiresFollow),
      (accountState(isFollowed: true, checkIn: nil), .unavailable),
      (
        accountState(
          isFollowed: true,
          checkIn: ForumCheckInData(isCheckedIn: false, consecutiveDays: 0, rank: 0)
        ),
        .ready
      ),
      (
        accountState(
          isFollowed: true,
          checkIn: ForumCheckInData(isCheckedIn: true, consecutiveDays: 12, rank: 34)
        ),
        .signedToday(consecutiveDays: 12, rank: 34)
      ),
    ]

    for (accountState, expectedState) in cases {
      let vault = ForumCheckInVaultSpy(session: session(userID: 1))
      let service = ForumCheckInServiceSpy(
        accountStates: [1: [.success(accountState)]]
      )
      let viewModel = makeViewModel(vault: vault, service: service)

      await viewModel.loadIfNeeded()

      XCTAssertEqual(viewModel.state, expectedState)
      XCTAssertNil(viewModel.errorMessage)
    }
  }

  func testDuplicateCheckInTapProducesOneWrite() async throws {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy(
      accountStates: [1: [.success(readyState())]],
      checkIns: [1: .success(signedState(days: 3, rank: 20))],
      checkInDelays: [1: 120_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let first = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 1 }
    await viewModel.checkIn()
    await first.value

    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 3, rank: 20))
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testWriteFailureReconcilesSignedStateWithoutRetryingWrite() async {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .success(signedState(days: 8, rank: 16)),
        ]
      ],
      checkIns: [1: .failure(.init(message: "response lost"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.checkIn()

    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 8, rank: 16))
    XCTAssertNil(viewModel.errorMessage)
    let accountStateRequestCount = await service.accountStateRequestCount()
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testWriteFailureReconcilesUnsignedStateWithoutRetryingWrite() async {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .success(readyState()),
        ]
      ],
      checkIns: [1: .failure(.init(message: "write failed"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.checkIn()

    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.errorMessage, "write failed")
    let accountStateRequestCount = await service.accountStateRequestCount()
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testWriteAndReconciliationFailureExposeRetryWithoutRetryingWrite() async {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .failure(.init(message: "readback failed")),
        ]
      ],
      checkIns: [1: .failure(.init(message: "write failed"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.checkIn()

    XCTAssertEqual(viewModel.state, .failed)
    XCTAssertEqual(viewModel.errorMessage, "write failed")
    let accountStateRequestCount = await service.accountStateRequestCount()
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testCancellationPerformsOneIndependentReadbackAndNeverRetriesWrite() async throws {
    let vault = ForumCheckInVaultSpy(session: session(userID: 1))
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .success(signedState(days: 2, rank: 9)),
        ]
      ],
      checkIns: [1: .success(signedState(days: 2, rank: 9))],
      checkInDelays: [1: 5_000_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let write = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 1 }
    write.cancel()
    await write.value

    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 2, rank: 9))
    XCTAssertNil(viewModel.errorMessage)
    let accountStateRequestCount = await service.accountStateRequestCount()
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testAccountSwitchDuringFailedWriteNeverReadsBackWithOldSession() async throws {
    let firstSession = session(userID: 1, updatedAt: 1)
    let secondSession = session(userID: 2, updatedAt: 2)
    let vault = ForumCheckInVaultSpy(session: firstSession)
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [.success(readyState(userID: 1))],
        2: [.success(signedState(userID: 2, days: 4, rank: 5))],
      ],
      checkIns: [1: .failure(.init(message: "write failed"))],
      checkInDelays: [1: 120_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldWrite = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 1 }
    await vault.replaceActive(with: secondSession)
    await oldWrite.value

    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 4, rank: 5))
    let requests = await service.accountStateRequestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        ForumCheckInRequest(userID: 1, sessionRevision: firstSession.sessionRevision),
        ForumCheckInRequest(userID: 2, sessionRevision: secondSession.sessionRevision),
      ]
    )
    let checkInRequestCount = await service.checkInRequestCount()
    XCTAssertEqual(checkInRequestCount, 1)
  }

  func testSuspendedOldWriteDoesNotBlockImmediateCheckInForDifferentUser() async throws {
    let oldSession = session(userID: 1)
    let newSession = session(userID: 2)
    let vault = ForumCheckInVaultSpy(session: oldSession)
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [.success(readyState(userID: 1))],
        2: [.success(readyState(userID: 2))],
      ],
      checkInsByRevision: [
        oldSession.sessionRevision: .success(signedState(userID: 1, days: 9, rank: 99)),
        newSession.sessionRevision: .success(signedState(userID: 2, days: 4, rank: 5)),
      ],
      checkInDelaysByRevision: [oldSession.sessionRevision: 180_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldWrite = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()

    let newWrite = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 2 }
    await newWrite.value
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 4, rank: 5))

    await oldWrite.value
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 4, rank: 5))
    let requests = await service.checkInRequestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        ForumCheckInRequest(userID: 1, sessionRevision: oldSession.sessionRevision),
        ForumCheckInRequest(userID: 2, sessionRevision: newSession.sessionRevision),
      ]
    )
  }

  func testSuspendedOldWriteCannotBlockOrPolluteSameUserNewRevision() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let oldSession = session(
      userID: 1,
      sessionRevision: oldRevision,
      credentialComponent: "a"
    )
    let newSession = session(
      userID: 1,
      sessionRevision: newRevision,
      credentialComponent: "c"
    )
    let vault = ForumCheckInVaultSpy(session: oldSession)
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .success(readyState()),
        ]
      ],
      checkInsByRevision: [
        oldRevision: .success(signedState(days: 9, rank: 99)),
        newRevision: .success(signedState(days: 3, rank: 4)),
      ],
      checkInDelaysByRevision: [oldRevision: 180_000_000]
    )
    let notificationRecorder = ForumCheckInNotificationRecorder()
    let notificationToken = NotificationCenter.default.addObserver(
      forName: .forumCheckInDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ForumCheckInChange(notification),
        change.accountID == 1,
        change.forumID == 100,
        change.sessionRevision == oldRevision || change.sessionRevision == newRevision
      else { return }
      notificationRecorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(notificationToken) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldWrite = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()

    let newWrite = Task { await viewModel.checkIn() }
    try await waitForForumCheckInTest { await service.checkInRequestCount() == 2 }
    await newWrite.value
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 3, rank: 4))

    await oldWrite.value
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 3, rank: 4))
    await viewModel.forumCheckInDidChange(
      ForumCheckInChange(
        accountID: 1,
        sessionRevision: oldRevision,
        forumID: 100,
        consecutiveDays: 9,
        rank: 99
      )
    )
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 3, rank: 4))
    let requests = await service.checkInRequestsSnapshot()
    XCTAssertEqual(requests.map(\.sessionRevision), [oldRevision, newRevision])
    let notifiedRevisions = notificationRecorder.snapshot().map(\.sessionRevision)
    XCTAssertFalse(notifiedRevisions.contains(oldRevision))
    XCTAssertTrue(notifiedRevisions.contains(newRevision))
  }

  func testRealServiceDefersNewRevisionReadbackUntilOldWriteSettles() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000011")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000012")
    )
    let oldSession = session(
      userID: 1,
      sessionRevision: oldRevision,
      credentialComponent: "a"
    )
    let newSession = session(
      userID: 1,
      sessionRevision: newRevision,
      credentialComponent: "c"
    )
    let vault = ForumCheckInVaultSpy(session: oldSession)
    let client = ForumCheckInIntegrationClientSpy(
      oldBDUSS: oldSession.bduss,
      newBDUSS: newSession.bduss
    )
    let service = TiebaCoreAccountService(client: client)
    let viewModel = ForumCheckInViewModel(
      forumID: 100,
      forumName: "Swift",
      access: AccountAccess(vault: vault, service: service)
    )
    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.state, .ready)

    let oldCompletion = ForumCheckInOperationCompletion()
    let oldWrite = Task {
      await viewModel.checkIn()
      await oldCompletion.markCompleted()
    }
    try await waitForForumCheckInTest { await client.checkInRequestCount() == 1 }

    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    XCTAssertEqual(viewModel.state, .ready)

    let newCompletion = ForumCheckInOperationCompletion()
    let newWrite = Task {
      await viewModel.checkIn()
      await newCompletion.markCompleted()
    }
    try await waitForForumCheckInTest {
      await service.forumWriteConflictWaiterCount() == 1
    }

    XCTAssertEqual(viewModel.state, .checking)
    let accountStateReadsBeforeRelease = await client.accountStateRequestCount()
    let checkInWritesBeforeRelease = await client.checkInRequestCount()
    let newCompletedBeforeRelease = await newCompletion.isCompleted()
    XCTAssertEqual(accountStateReadsBeforeRelease, 2)
    XCTAssertEqual(checkInWritesBeforeRelease, 1)
    XCTAssertFalse(newCompletedBeforeRelease)

    await client.releaseOldCheckIn()
    try await waitForForumCheckInTest {
      let oldCompleted = await oldCompletion.isCompleted()
      let newCompleted = await newCompletion.isCompleted()
      return oldCompleted && newCompleted
    }
    await oldWrite.value
    await newWrite.value

    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 3, rank: 4))
    XCTAssertNil(viewModel.errorMessage)
    let finalAccountStateReads = await client.accountStateRequestCount()
    let finalCheckInWrites = await client.checkInRequestCount()
    XCTAssertEqual(finalAccountStateReads, 3)
    XCTAssertEqual(finalCheckInWrites, 1)
  }

  func testUnreadableVaultAfterLoadStopsWithoutRecursiveRequests() async {
    let vault = ForumCheckInVaultSpy(
      session: session(userID: 1),
      failingReadNumbers: [2]
    )
    let service = ForumCheckInServiceSpy(
      accountStates: [1: [.success(readyState())]]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .failed)
    XCTAssertEqual(viewModel.errorMessage, "无法读取当前账户，请稍后重试。")
    let vaultReadCount = await vault.activeSessionReadCount()
    let accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(vaultReadCount, 2)
    XCTAssertEqual(accountStateRequestCount, 1)
  }

  func testMembershipAndCheckInNotificationsAreScopedToCurrentAccountAndForum() async {
    let activeSession = session(userID: 1)
    let vault = ForumCheckInVaultSpy(session: activeSession)
    let service = ForumCheckInServiceSpy(
      accountStates: [
        1: [
          .success(readyState()),
          .success(accountState(isFollowed: false, checkIn: nil)),
        ]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 2, forumID: 100, isFollowed: false)
    )
    await viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 1, forumID: 999, isFollowed: false)
    )
    var accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(accountStateRequestCount, 1)
    XCTAssertEqual(viewModel.state, .ready)

    await viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 1, forumID: 100, isFollowed: false)
    )
    accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
    XCTAssertEqual(viewModel.state, .requiresFollow)

    await viewModel.forumCheckInDidChange(
      ForumCheckInChange(
        accountID: 2,
        sessionRevision: activeSession.sessionRevision,
        forumID: 100,
        consecutiveDays: 7,
        rank: 8
      )
    )
    XCTAssertEqual(viewModel.state, .requiresFollow)
    await viewModel.forumCheckInDidChange(
      ForumCheckInChange(
        accountID: 1,
        sessionRevision: UUID(),
        forumID: 100,
        consecutiveDays: 9,
        rank: 99
      )
    )
    XCTAssertEqual(viewModel.state, .requiresFollow)
    await viewModel.forumCheckInDidChange(
      ForumCheckInChange(
        accountID: 1,
        sessionRevision: activeSession.sessionRevision,
        forumID: 100,
        consecutiveDays: 7,
        rank: 8
      )
    )
    XCTAssertEqual(viewModel.state, .signedToday(consecutiveDays: 7, rank: 8))
    accountStateRequestCount = await service.accountStateRequestCount()
    XCTAssertEqual(accountStateRequestCount, 2)
  }

  func testCheckInNotificationContainsOnlyCredentialFreeState() throws {
    let revision = try XCTUnwrap(
      UUID(uuidString: "11111111-2222-3333-4444-555555555555")
    )
    let notification = Notification(
      name: .forumCheckInDidChange,
      userInfo: [
        "accountID": NSNumber(value: 1),
        "sessionRevision": revision.uuidString,
        "forumID": NSNumber(value: 100),
        "consecutiveDays": NSNumber(value: 6),
        "rank": NSNumber(value: 12),
      ]
    )

    XCTAssertEqual(
      ForumCheckInChange(notification),
      ForumCheckInChange(
        accountID: 1,
        sessionRevision: revision,
        forumID: 100,
        consecutiveDays: 6,
        rank: 12
      )
    )
    XCTAssertEqual(
      Set(notification.userInfo?.keys.compactMap { $0 as? String } ?? []),
      ["accountID", "sessionRevision", "forumID", "consecutiveDays", "rank"]
    )
    XCTAssertNil(
      ForumCheckInChange(
        Notification(
          name: .forumCheckInDidChange,
          userInfo: [
            "accountID": NSNumber(value: 1),
            "forumID": NSNumber(value: 100),
            "consecutiveDays": NSNumber(value: 6),
            "rank": NSNumber(value: 12),
          ]
        )
      )
    )
  }

  func testCheckInRowVisibilityHidesOnlyIdleAndSignedOutStates() {
    XCTAssertFalse(ForumCheckInRowVisibility.isVisible(for: .idle))
    XCTAssertFalse(ForumCheckInRowVisibility.isVisible(for: .signedOut))
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .loading))
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .requiresFollow))
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .unavailable))
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .ready))
    XCTAssertTrue(
      ForumCheckInRowVisibility.isVisible(
        for: .signedToday(consecutiveDays: 1, rank: 2)
      )
    )
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .checking))
    XCTAssertTrue(ForumCheckInRowVisibility.isVisible(for: .failed))
    XCTAssertEqual(
      ForumCheckInRowVisibility.signedStatus(consecutiveDays: 2, rank: 0),
      "今日已签到 · 连续 2 天"
    )
  }

  private func makeViewModel(
    forumID: Int64 = 100,
    vault: ForumCheckInVaultSpy,
    service: ForumCheckInServiceSpy
  ) -> ForumCheckInViewModel {
    ForumCheckInViewModel(
      forumID: forumID,
      forumName: "Swift",
      access: AccountAccess(vault: vault, service: service)
    )
  }

  private func session(
    userID: Int64,
    updatedAt: TimeInterval = 1,
    sessionRevision: UUID = UUID(),
    credentialComponent: String? = nil
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(
        repeating: credentialComponent ?? (userID == 1 ? "a" : "b"),
        count: 192
      ),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      sessionRevision: sessionRevision
    )
  }

  private func accountState(
    userID: Int64 = 1,
    isFollowed: Bool,
    checkIn: ForumCheckInData?
  ) -> ForumAccountStateData {
    ForumAccountStateData(
      membership: ForumMembershipData(
        userID: userID,
        forumID: 100,
        forumName: "Swift",
        isFollowed: isFollowed
      ),
      checkIn: checkIn
    )
  }

  private func readyState(userID: Int64 = 1) -> ForumAccountStateData {
    accountState(
      userID: userID,
      isFollowed: true,
      checkIn: ForumCheckInData(isCheckedIn: false, consecutiveDays: 0, rank: 0)
    )
  }

  private func signedState(
    userID: Int64 = 1,
    days: Int,
    rank: Int
  ) -> ForumAccountStateData {
    accountState(
      userID: userID,
      isFollowed: true,
      checkIn: ForumCheckInData(isCheckedIn: true, consecutiveDays: days, rank: rank)
    )
  }
}

private struct ForumCheckInTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private struct ForumCheckInRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
}

private final class ForumCheckInNotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = [ForumCheckInChange]()

  func record(_ change: ForumCheckInChange) {
    lock.withLock { changes.append(change) }
  }

  func snapshot() -> [ForumCheckInChange] {
    lock.withLock { changes }
  }
}

private actor ForumCheckInOperationCompletion {
  private var completed = false

  func markCompleted() { completed = true }
  func isCompleted() -> Bool { completed }
}

private actor ForumCheckInIntegrationClientSpy: TiebaAuthenticatedAccountClient {
  private let oldBDUSS: String
  private let newBDUSS: String
  private var newSessionAccountStateReads = 0
  private var accountStateRequests = 0
  private var checkInRequests = 0
  private var oldCheckInIsReleased = false
  private var oldCheckInWaiters: [CheckedContinuation<Void, Never>] = []

  init(oldBDUSS: String, newBDUSS: String) {
    self.oldBDUSS = oldBDUSS
    self.newBDUSS = newBDUSS
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw ForumCheckInTestFailure(message: "unexpected validation")
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw ForumCheckInTestFailure(message: "unexpected followed-forum request")
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw ForumCheckInTestFailure(message: "unexpected membership request")
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    accountStateRequests += 1
    guard expectedUserID == 1, forumID == 100 else {
      throw ForumCheckInTestFailure(message: "unexpected account-state identity")
    }
    if credential.bduss == oldBDUSS {
      return coreState(isCheckedIn: false, days: 0, rank: 0)
    }
    guard credential.bduss == newBDUSS else {
      throw ForumCheckInTestFailure(message: "unexpected account-state credential")
    }
    newSessionAccountStateReads += 1
    return newSessionAccountStateReads == 1
      ? coreState(isCheckedIn: false, days: 0, rank: 0)
      : coreState(isCheckedIn: true, days: 3, rank: 4)
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw ForumCheckInTestFailure(message: "unexpected membership mutation")
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    checkInRequests += 1
    guard
      credential.bduss == oldBDUSS,
      expectedUserID == 1,
      forumID == 100
    else {
      throw ForumCheckInTestFailure(message: "unexpected second check-in write")
    }
    if !oldCheckInIsReleased {
      await withCheckedContinuation { oldCheckInWaiters.append($0) }
    }
    return coreState(isCheckedIn: true, days: 9, rank: 99)
  }

  func releaseOldCheckIn() {
    oldCheckInIsReleased = true
    let waiters = oldCheckInWaiters
    oldCheckInWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func accountStateRequestCount() -> Int { accountStateRequests }
  func checkInRequestCount() -> Int { checkInRequests }

  private func coreState(
    isCheckedIn: Bool,
    days: Int,
    rank: Int
  ) -> TiebaForumAccountState {
    TiebaForumAccountState(
      membership: TiebaForumMembership(
        userID: 1,
        forumID: 100,
        forumName: "Swift",
        isFollowed: true
      ),
      checkIn: TiebaForumCheckIn(
        isCheckedIn: isCheckedIn,
        consecutiveDays: days,
        rank: rank
      )
    )
  }
}

private actor ForumCheckInServiceSpy: AccountService {
  private var accountStates: [
    Int64: [Result<ForumAccountStateData, ForumCheckInTestFailure>]
  ]
  private let checkIns: [Int64: Result<ForumAccountStateData, ForumCheckInTestFailure>]
  private let checkInsByRevision: [
    UUID: Result<ForumAccountStateData, ForumCheckInTestFailure>
  ]
  private let accountStateDelays: [Int64: UInt64]
  private let checkInDelays: [Int64: UInt64]
  private let checkInDelaysByRevision: [UUID: UInt64]
  private var accountStateRequests: [ForumCheckInRequest] = []
  private var checkInRequests: [ForumCheckInRequest] = []

  init(
    accountStates: [
      Int64: [Result<ForumAccountStateData, ForumCheckInTestFailure>]
    ] = [:],
    checkIns: [Int64: Result<ForumAccountStateData, ForumCheckInTestFailure>] = [:],
    checkInsByRevision: [
      UUID: Result<ForumAccountStateData, ForumCheckInTestFailure>
    ] = [:],
    accountStateDelays: [Int64: UInt64] = [:],
    checkInDelays: [Int64: UInt64] = [:],
    checkInDelaysByRevision: [UUID: UInt64] = [:]
  ) {
    self.accountStates = accountStates
    self.checkIns = checkIns
    self.checkInsByRevision = checkInsByRevision
    self.accountStateDelays = accountStateDelays
    self.checkInDelays = checkInDelays
    self.checkInDelaysByRevision = checkInDelaysByRevision
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ForumCheckInTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ForumCheckInTestFailure(message: "unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ForumCheckInTestFailure(message: "unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    accountStateRequests.append(
      ForumCheckInRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision
      )
    )
    if let delay = accountStateDelays[session.id] {
      try await Task.sleep(nanoseconds: delay)
    }
    guard var results = accountStates[session.id], let result = results.first else {
      throw ForumCheckInTestFailure(message: "unexpected account-state request")
    }
    if results.count > 1 {
      results.removeFirst()
      accountStates[session.id] = results
    }
    return try result.get()
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ForumCheckInTestFailure(message: "unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    checkInRequests.append(
      ForumCheckInRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision
      )
    )
    if let delay = checkInDelaysByRevision[session.sessionRevision] ?? checkInDelays[session.id] {
      try await Task.sleep(nanoseconds: delay)
    }
    guard let result = checkInsByRevision[session.sessionRevision] ?? checkIns[session.id] else {
      throw ForumCheckInTestFailure(message: "unexpected check-in mutation")
    }
    return try result.get()
  }

  func accountStateRequestCount() -> Int { accountStateRequests.count }
  func checkInRequestCount() -> Int { checkInRequests.count }
  func accountStateRequestsSnapshot() -> [ForumCheckInRequest] { accountStateRequests }
  func checkInRequestsSnapshot() -> [ForumCheckInRequest] { checkInRequests }
}

private actor ForumCheckInVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private let failingReadNumbers: Set<Int>
  private var activeReads = 0

  init(
    session: StoredAccountSession? = nil,
    failingReadNumbers: Set<Int> = []
  ) {
    self.session = session
    self.failingReadNumbers = failingReadNumbers
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    if failingReadNumbers.contains(activeReads) {
      throw ForumCheckInTestFailure(message: "vault unavailable")
    }
    return session
  }

  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSessionReadCount() -> Int { activeReads }
}

@MainActor
private func waitForForumCheckInTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw ForumCheckInTestFailure(message: "timed out waiting for check-in state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
