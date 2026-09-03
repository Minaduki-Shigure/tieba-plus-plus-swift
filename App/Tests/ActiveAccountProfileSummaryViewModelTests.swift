import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ActiveAccountProfileSummaryViewModelTests: XCTestCase {
  func testLoadPublishesValidatedSummaryUsingFullCredentials() async {
    let active = session(userID: 7, revision: uuid(1))
    let expected = summary(userID: 7, following: 3, followers: 4, posts: 5)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(expected)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.summary, expected)
    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.userID, 7)
    XCTAssertEqual(requests.first?.sessionRevision, active.sessionRevision)
    XCTAssertEqual(requests.first?.bdussByteCount, 192)
    XCTAssertEqual(requests.first?.stokenByteCount, 64)
  }

  func testVerifiedEditorResultPublishesWithoutASecondServerRead() async {
    let active = session(userID: 7, revision: uuid(31))
    let initial = summary(userID: 7, following: 3, followers: 4, posts: 5)
    let edited = summary(userID: 7, following: 6, followers: 7, posts: 8)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    let published = await viewModel.publishVerifiedSummary(edited)

    XCTAssertTrue(published)
    XCTAssertEqual(viewModel.summary, edited)
    XCTAssertEqual(viewModel.state, .loaded)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testSuspendedSummaryRetainsLeaseForVerifiedEditorPublication() async {
    let active = session(userID: 7, revision: uuid(35))
    let initial = summary(userID: 7, following: 3, followers: 4, posts: 5)
    let edited = summary(userID: 7, following: 6, followers: 7, posts: 8)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.suspend()
    let published = await viewModel.publishVerifiedSummary(edited)

    XCTAssertTrue(published)
    XCTAssertEqual(viewModel.summary, edited)
    XCTAssertEqual(viewModel.state, .loaded)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testVerifiedEditorResultCannotCrossRotatedSessionLease() async {
    let original = session(userID: 7, revision: uuid(32))
    let initial = summary(userID: 7, following: 3, followers: 4, posts: 5)
    let edited = summary(userID: 7, following: 6, followers: 7, posts: 8)
    let vault = ActiveProfileVaultSpy(session: original)
    let service = ActiveProfileServiceSpy(scripts: [
      original.sessionRevision: [.value(initial)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()
    await vault.replaceActive(with: session(userID: 7, revision: uuid(33)))

    let published = await viewModel.publishVerifiedSummary(edited)

    XCTAssertFalse(published)
    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testCancelledVerifiedPublicationCannotRestoreClearedSnapshot() async throws {
    let active = session(userID: 7, revision: uuid(34))
    let initial = summary(userID: 7, following: 3, followers: 4, posts: 5)
    let edited = summary(userID: 7, following: 6, followers: 7, posts: 8)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()
    await vault.suspendActiveSessionReads()

    let publication = Task { await viewModel.publishVerifiedSummary(edited) }
    try await waitForActiveProfileTest { await vault.activeSessionWaiterCount() == 1 }
    viewModel.cancel()
    await vault.releaseActiveSessionReads()

    let published = await publication.value
    XCTAssertFalse(published)
    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testMissingFullCredentialsFailsBeforeServiceRequest() async {
    let legacy = session(userID: 7, revision: uuid(1), stoken: nil)
    let vault = ActiveProfileVaultSpy(session: legacy)
    let service = ActiveProfileServiceSpy(scripts: [:])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .failed("此账户需要重新登录，才能安全读取本人资料。"))
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testCredentialLossForSameLeaseClearsPreviouslyLoadedSnapshot() async {
    let revision = uuid(1)
    let active = session(userID: 7, revision: revision)
    let initial = summary(userID: 7, following: 1, followers: 2, posts: 3)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [revision: [.value(initial)]])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    await vault.replaceActive(with: session(userID: 7, revision: revision, stoken: nil))
    await viewModel.refresh()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .failed("此账户需要重新登录，才能安全读取本人资料。"))
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testHiddenAccountChangeClearsSummaryWithoutStartingPrivateRequest() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 8, revision: uuid(2))
    let oldSummary = summary(userID: 7, following: 1, followers: 2, posts: 3)
    let newSummary = summary(userID: 8, following: 4, followers: 5, posts: 6)
    let vault = ActiveProfileVaultSpy(session: oldSession)
    let service = ActiveProfileServiceSpy(scripts: [
      oldSession.sessionRevision: [.value(oldSummary)],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange(loadImmediately: false)

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
    let hiddenRequestCount = await service.requestCount()
    XCTAssertEqual(hiddenRequestCount, 1)

    viewModel.loadIfNeeded()
    try await waitForActiveProfileTest { viewModel.summary == newSummary }
    let visibleRequestCount = await service.requestCount()
    XCTAssertEqual(visibleRequestCount, 2)
  }

  func testConcurrentRefreshesShareOneInFlightRequest() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let expected = summary(userID: 7, following: 8, followers: 2, posts: 9)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.suspended(id: 1, value: expected)]
    ])
    addTeardownBlock { await service.releaseAll() }
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)

    let first = Task { await viewModel.refresh() }
    try await waitForActiveProfileTest { await service.requestCount() == 1 }
    let second = Task { await viewModel.refresh() }
    viewModel.reload()
    viewModel.loadIfNeeded()
    for _ in 0..<20 { await Task.yield() }

    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
    await service.release(id: 1)
    await first.value
    await second.value

    XCTAssertEqual(viewModel.summary, expected)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFailureAndInvalidResponsesPreserveSnapshotForSameLease() async {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, following: 1, followers: 2, posts: 3)
    let replacement = summary(userID: 7, following: 4, followers: 5, posts: 6)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [
        .value(initial),
        .failure("profile unavailable"),
        .value(summary(userID: 8, following: 9, followers: 9, posts: 9)),
        .value(summary(userID: 7, following: -1, followers: 2, posts: 3)),
        .value(summary(userID: 7, following: 1, followers: Int(Int32.max) + 1, posts: 3)),
        .value(replacement),
      ]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary, initial)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary, initial)
    XCTAssertEqual(viewModel.state, .failed("profile unavailable"))

    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary, initial)
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了不匹配的本人资料，请重新加载后再试。")
    )

    for _ in 0..<2 {
      await viewModel.refresh()
      XCTAssertEqual(viewModel.summary, initial)
      XCTAssertEqual(
        viewModel.state,
        .failed("贴吧返回了无效的本人资料计数，请重新加载后再试。")
      )
    }

    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary, replacement)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testSameUserReloginClearsSynchronouslyAndOldResponseCannotOverwrite() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 7, revision: uuid(2))
    let oldSummary = summary(userID: 7, following: 1, followers: 1, posts: 1)
    let staleSummary = summary(userID: 7, following: 99, followers: 99, posts: 99)
    let newSummary = summary(userID: 7, following: 4, followers: 5, posts: 6)
    let vault = ActiveProfileVaultSpy(session: oldSession)
    let service = ActiveProfileServiceSpy(scripts: [
      oldSession.sessionRevision: [
        .value(oldSummary),
        .suspended(id: 1, value: staleSummary),
      ],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    addTeardownBlock { await service.releaseAll() }
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForActiveProfileTest { await service.requestCount() == 2 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForActiveProfileTest { viewModel.summary == newSummary }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertEqual(viewModel.summary, newSummary)
    XCTAssertEqual(viewModel.state, .loaded)
    let revisions = await service.requestsSnapshot().map(\.sessionRevision)
    XCTAssertEqual(
      revisions,
      [oldSession.sessionRevision, oldSession.sessionRevision, newSession.sessionRevision]
    )
  }

  func testDifferentUserSwitchClearsSynchronouslyAndOldResponseCannotOverwrite() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 8, revision: uuid(2))
    let staleSummary = summary(userID: 7, following: 99, followers: 99, posts: 99)
    let newSummary = summary(userID: 8, following: 4, followers: 5, posts: 6)
    let vault = ActiveProfileVaultSpy(session: oldSession)
    let service = ActiveProfileServiceSpy(scripts: [
      oldSession.sessionRevision: [.suspended(id: 1, value: staleSummary)],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    addTeardownBlock { await service.releaseAll() }
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForActiveProfileTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForActiveProfileTest { viewModel.summary == newSummary }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertEqual(viewModel.summary, newSummary)
    XCTAssertEqual(viewModel.state, .loaded)
    let userIDs = await service.requestsSnapshot().map(\.userID)
    XCTAssertEqual(userIDs, [7, 8])
  }

  func testLogoutClearsSynchronouslyAndLateResponseStaysDiscarded() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, following: 2, followers: 3, posts: 4)
    let stale = summary(userID: 7, following: 50, followers: 50, posts: 50)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial), .suspended(id: 1, value: stale)]
    ])
    addTeardownBlock { await service.releaseAll() }
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForActiveProfileTest { await service.requestCount() == 2 }
    await vault.replaceActive(with: nil)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    try await waitForActiveProfileTest { viewModel.state == .idle }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testCancelInvalidatesUncooperativeLateResponseAndClearsSnapshot() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, following: 2, followers: 3, posts: 4)
    let late = summary(userID: 7, following: 9, followers: 9, posts: 9)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial), .suspended(id: 1, value: late)]
    ])
    addTeardownBlock { await service.releaseAll() }
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    let refresh = Task { await viewModel.refresh() }
    try await waitForActiveProfileTest { await service.requestCount() == 2 }
    viewModel.cancel()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
    await service.release(id: 1)
    await refresh.value

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testReloadAfterCancelUsesRotatedSameUserLease() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 7, revision: uuid(2))
    let oldSummary = summary(userID: 7, following: 1, followers: 2, posts: 3)
    let newSummary = summary(userID: 7, following: 4, followers: 5, posts: 6)
    let vault = ActiveProfileVaultSpy(session: oldSession)
    let service = ActiveProfileServiceSpy(scripts: [
      oldSession.sessionRevision: [.value(oldSummary)],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.cancel()
    await vault.replaceActive(with: newSession)
    viewModel.loadIfNeeded()
    try await waitForActiveProfileTest { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.summary, newSummary)
    let revisions = await service.requestsSnapshot().map(\.sessionRevision)
    XCTAssertEqual(revisions, [oldSession.sessionRevision, newSession.sessionRevision])
  }

  func testPostRequestVaultFailureClearsPreviouslyLoadedSnapshot() async {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, following: 2, followers: 3, posts: 4)
    let replacement = summary(userID: 7, following: 5, followers: 6, posts: 7)
    let vault = ActiveProfileVaultSpy(session: active)
    let service = ActiveProfileServiceSpy(scripts: [
      active.sessionRevision: [.value(initial), .value(replacement)]
    ])
    let viewModel = ActiveAccountProfileSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()
    await vault.failActiveRead(number: 4)

    await viewModel.refresh()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .failed("vault unavailable"))
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 4)
  }

  private func session(
    userID: Int64,
    revision: UUID,
    stoken: String? = String(repeating: "s", count: 64)
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      stoken: stoken,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func summary(
    userID: Int64,
    following: Int,
    followers: Int,
    posts: Int
  ) -> AccountProfileSummary {
    AccountProfileSummary(
      userID: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portraitURL: URL(string: "https://himg.bdimg.com/sys/portraitn/item/portrait-\(userID)"),
      biography: "Profile \(userID)",
      followingCount: following,
      followerCount: followers,
      postCount: posts
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct ActiveProfileRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
  let bdussByteCount: Int
  let stokenByteCount: Int
}

private enum ActiveProfileScript: Sendable {
  case value(AccountProfileSummary)
  case failure(String)
  case suspended(id: Int, value: AccountProfileSummary)
}

private struct ActiveProfileTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor ActiveProfileServiceSpy: AccountService {
  private var scripts: [UUID: [ActiveProfileScript]]
  private var requests: [ActiveProfileRequest] = []
  private var suspended:
    [Int: (CheckedContinuation<AccountProfileSummary, Never>, AccountProfileSummary)] = [:]

  init(scripts: [UUID: [ActiveProfileScript]]) {
    self.scripts = scripts
  }

  func selfProfile(session: StoredAccountSession) async throws -> AccountProfileSummary {
    requests.append(
      ActiveProfileRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        bdussByteCount: session.bduss.utf8.count,
        stokenByteCount: session.stoken?.utf8.count ?? 0
      )
    )
    guard var pending = scripts[session.sessionRevision], !pending.isEmpty else {
      throw ActiveProfileTestFailure(message: "Missing profile script")
    }
    let script = pending.removeFirst()
    scripts[session.sessionRevision] = pending
    switch script {
    case .value(let value):
      return value
    case .failure(let message):
      throw ActiveProfileTestFailure(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspended[id] = ($0, value) }
    }
  }

  func release(id: Int) {
    guard let (continuation, value) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func releaseAll() {
    let pending = suspended.values
    suspended.removeAll()
    pending.forEach { continuation, value in
      continuation.resume(returning: value)
    }
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [ActiveProfileRequest] { requests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ActiveProfileTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ActiveProfileTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ActiveProfileTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ActiveProfileTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ActiveProfileTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ActiveProfileTestFailure(message: "Unexpected check-in request")
  }
}

private actor ActiveProfileVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var activeReads = 0
  private var failingRead: Int?
  private var suspendsActiveReads = false
  private var activeReadWaiters: [CheckedContinuation<Void, Never>] = []

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func failActiveRead(number: Int) {
    failingRead = number
  }

  func suspendActiveSessionReads() {
    suspendsActiveReads = true
  }

  func activeSessionWaiterCount() -> Int {
    activeReadWaiters.count
  }

  func releaseActiveSessionReads() {
    suspendsActiveReads = false
    let waiters = activeReadWaiters
    activeReadWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    if suspendsActiveReads {
      await withCheckedContinuation { activeReadWaiters.append($0) }
    }
    if activeReads == failingRead {
      throw ActiveProfileTestFailure(message: "vault unavailable")
    }
    return session
  }

  func activeSessionReadCount() -> Int { activeReads }

  func accountSummaries() async throws -> [AccountSummary] {
    throw ActiveProfileTestFailure(message: "Unexpected account summary request")
  }

  func upsert(_ session: StoredAccountSession) async throws {
    throw ActiveProfileTestFailure(message: "Unexpected account mutation")
  }

  func switchActive(to userID: Int64) async throws {
    throw ActiveProfileTestFailure(message: "Unexpected account mutation")
  }

  func remove(userID: Int64) async throws {
    throw ActiveProfileTestFailure(message: "Unexpected account mutation")
  }

  func removeAll() async throws {
    throw ActiveProfileTestFailure(message: "Unexpected account mutation")
  }
}

@MainActor
private func waitForActiveProfileTest(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    if Date() >= deadline {
      XCTFail("Timed out waiting for active profile state")
      return
    }
    await Task.yield()
  }
}
