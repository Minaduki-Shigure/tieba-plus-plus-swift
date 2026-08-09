import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class InboxUnreadSummaryViewModelTests: XCTestCase {
  func testLoadPublishesValidatedSummaryForLegacySessionWithoutSTOKEN() async {
    let active = session(userID: 7, revision: uuid(1), stoken: nil)
    let vault = InboxUnreadSummaryVaultSpy(session: active)
    let expected = summary(userID: 7, replies: 3, mentions: 4, fans: 5)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      active.sessionRevision: [.value(expected)]
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.summary, expected)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.summary?.totalCount, 7)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.userID, 7)
    XCTAssertEqual(requests.first?.sessionRevision, active.sessionRevision)
    XCTAssertEqual(requests.first?.bdussByteCount, 192)
    XCTAssertFalse(requests.first?.hasSTOKEN ?? true)
  }

  func testConcurrentRefreshesShareOneInFlightRequest() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let expected = summary(userID: 7, replies: 8, mentions: 2)
    let vault = InboxUnreadSummaryVaultSpy(session: active)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      active.sessionRevision: [.suspended(id: 1, value: expected)]
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)

    let first = Task { await viewModel.refresh() }
    try await waitForInboxUnreadSummaryTest { await service.requestCount() == 1 }
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

  func testSameUserReloginClearsSynchronouslyAndOldResponseCannotOverwrite() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 7, revision: uuid(2))
    let oldSummary = summary(userID: 7, replies: 1, mentions: 1)
    let staleSummary = summary(userID: 7, replies: 99, mentions: 99)
    let newSummary = summary(userID: 7, replies: 4, mentions: 5)
    let vault = InboxUnreadSummaryVaultSpy(session: oldSession)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      oldSession.sessionRevision: [
        .value(oldSummary),
        .suspended(id: 1, value: staleSummary),
      ],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary, oldSummary)

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForInboxUnreadSummaryTest { await service.requestCount() == 2 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForInboxUnreadSummaryTest { viewModel.summary == newSummary }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertEqual(viewModel.summary, newSummary)
    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(
      requests.map(\.sessionRevision),
      [oldSession.sessionRevision, oldSession.sessionRevision, newSession.sessionRevision]
    )
  }

  func testDifferentUserSwitchClearsSynchronouslyAndOldResponseCannotOverwrite() async throws {
    let oldSession = session(userID: 7, revision: uuid(1))
    let newSession = session(userID: 8, revision: uuid(2))
    let staleSummary = summary(userID: 7, replies: 99, mentions: 99)
    let newSummary = summary(userID: 8, replies: 4, mentions: 5)
    let vault = InboxUnreadSummaryVaultSpy(session: oldSession)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      oldSession.sessionRevision: [.suspended(id: 1, value: staleSummary)],
      newSession.sessionRevision: [.value(newSummary)],
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForInboxUnreadSummaryTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForInboxUnreadSummaryTest { viewModel.summary == newSummary }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertEqual(viewModel.summary, newSummary)
    XCTAssertEqual(viewModel.state, .loaded)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
  }

  func testLogoutClearsSynchronouslyAndLateResponseStaysDiscarded() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, replies: 2, mentions: 3)
    let stale = summary(userID: 7, replies: 50, mentions: 50)
    let vault = InboxUnreadSummaryVaultSpy(session: active)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      active.sessionRevision: [.value(initial), .suspended(id: 1, value: stale)]
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)
    await viewModel.refresh()

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForInboxUnreadSummaryTest { await service.requestCount() == 2 }
    await vault.replaceActive(with: nil)
    viewModel.accountSessionDidChange()

    XCTAssertNil(viewModel.summary)
    try await waitForInboxUnreadSummaryTest { viewModel.state == .idle }
    await service.release(id: 1)
    await staleRefresh.value

    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testFailureIsLocalRetryableAndMismatchedResponseIsRejected() async {
    let active = session(userID: 7, revision: uuid(1))
    let vault = InboxUnreadSummaryVaultSpy(session: active)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      active.sessionRevision: [
        .failure("summary unavailable"),
        .value(summary(userID: 8, replies: 1, mentions: 2)),
        .value(summary(userID: 7, replies: 6, mentions: 7)),
      ]
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.state, .failed("summary unavailable"))
    XCTAssertNil(viewModel.summary)

    await viewModel.refresh()
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了不匹配的未读消息摘要，请重新加载后再试。")
    )
    XCTAssertNil(viewModel.summary)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.summary?.replyCount, 6)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testCancelInvalidatesAnUncooperativeLateResponse() async throws {
    let active = session(userID: 7, revision: uuid(1))
    let initial = summary(userID: 7, replies: 2, mentions: 3)
    let stale = summary(userID: 7, replies: 9, mentions: 9)
    let vault = InboxUnreadSummaryVaultSpy(session: active)
    let service = InboxUnreadSummaryServiceSpy(scripts: [
      active.sessionRevision: [
        .value(initial),
        .suspended(id: 1, value: stale),
      ]
    ])
    let viewModel = InboxUnreadSummaryViewModel(service: service, vault: vault)

    await viewModel.refresh()
    let refresh = Task { await viewModel.refresh() }
    try await waitForInboxUnreadSummaryTest { await service.requestCount() == 2 }
    viewModel.cancel()
    XCTAssertEqual(viewModel.summary, initial)
    XCTAssertEqual(viewModel.state, .loaded)

    await service.release(id: 1)
    await refresh.value
    XCTAssertEqual(viewModel.summary, initial)
    XCTAssertEqual(viewModel.state, .loaded)
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
    replies: Int,
    mentions: Int,
    fans: Int = 0
  ) -> InboxUnreadSummary {
    InboxUnreadSummary(
      userID: userID,
      replyCount: replies,
      mentionCount: mentions,
      fanCount: fans
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct InboxUnreadSummaryRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
  let bdussByteCount: Int
  let hasSTOKEN: Bool
}

private enum InboxUnreadSummaryScript: Sendable {
  case value(InboxUnreadSummary)
  case failure(String)
  case suspended(id: Int, value: InboxUnreadSummary)
}

private struct InboxUnreadSummaryTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor InboxUnreadSummaryServiceSpy: AccountService {
  private var scripts: [UUID: [InboxUnreadSummaryScript]]
  private var requests: [InboxUnreadSummaryRequest] = []
  private var suspended:
    [Int: (CheckedContinuation<InboxUnreadSummary, Never>, InboxUnreadSummary)] = [:]

  init(scripts: [UUID: [InboxUnreadSummaryScript]]) {
    self.scripts = scripts
  }

  func inboxUnreadSummary(session: StoredAccountSession) async throws -> InboxUnreadSummary {
    requests.append(
      InboxUnreadSummaryRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        bdussByteCount: session.bduss.utf8.count,
        hasSTOKEN: session.stoken != nil
      )
    )
    guard var pending = scripts[session.sessionRevision], !pending.isEmpty else {
      throw InboxUnreadSummaryTestFailure(message: "Missing unread summary script")
    }
    let script = pending.removeFirst()
    scripts[session.sessionRevision] = pending
    switch script {
    case .value(let value):
      return value
    case .failure(let message):
      throw InboxUnreadSummaryTestFailure(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspended[id] = ($0, value) }
    }
  }

  func release(id: Int) {
    guard let (continuation, value) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [InboxUnreadSummaryRequest] { requests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected check-in request")
  }
}

private actor InboxUnreadSummaryVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? { session }

  func accountSummaries() async throws -> [AccountSummary] {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account summary request")
  }

  func upsert(_ session: StoredAccountSession) async throws {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account mutation")
  }

  func switchActive(to userID: Int64) async throws {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account mutation")
  }

  func remove(userID: Int64) async throws {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account mutation")
  }

  func removeAll() async throws {
    throw InboxUnreadSummaryTestFailure(message: "Unexpected account mutation")
  }
}

private func waitForInboxUnreadSummaryTest(
  timeout: TimeInterval = 2,
  condition: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw InboxUnreadSummaryTestFailure(message: "Timed out waiting for unread summary state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
