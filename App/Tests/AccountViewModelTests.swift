import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AccountViewModelTests: XCTestCase {
  func testLoadsSwitchesAndRemovesAccounts() async throws {
    let vault = AccountVaultSpy(
      sessions: [
        session(userID: 1, name: "one", updatedAt: 10),
        session(userID: 2, name: "two", updatedAt: 20),
      ],
      activeUserID: 2
    )
    let viewModel = AccountViewModel(vault: vault)

    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.accounts.map(\.id), [2, 1])
    XCTAssertEqual(viewModel.activeAccount?.id, 2)

    await viewModel.switchAccount(to: 1)
    XCTAssertEqual(viewModel.activeAccount?.id, 1)

    await viewModel.removeActiveAccount()
    XCTAssertEqual(viewModel.accounts.map(\.id), [2])
    XCTAssertEqual(viewModel.activeAccount?.id, 2)
  }

  func testSuccessfulLoginValidatesBeforePersistingSession() async throws {
    let vault = AccountVaultSpy()
    let validatedAccount = ValidatedAccount(
      userID: 7,
      username: "validated-user",
      portrait: "portrait-token"
    )
    let service = AccountServiceSpy(
      validation: .success(validatedAccount)
    )
    let viewModel = LoginViewModel(service: service, vault: vault)
    let credentials = AccountCredentials(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bdussBFESS
    )

    let succeeded = await viewModel.complete(credentials: credentials)

    XCTAssertTrue(succeeded)
    XCTAssertFalse(viewModel.isValidating)
    XCTAssertNil(viewModel.errorMessage)
    let validationLengths = await service.validationCredentialLengths()
    XCTAssertEqual(validationLengths?.bduss, 192)
    XCTAssertEqual(validationLengths?.stoken, 64)
    let storedSession = await vault.session(userID: 7)
    let stored = try XCTUnwrap(storedSession)
    XCTAssertEqual(stored.username, "validated-user")
    XCTAssertEqual(stored.bduss.count, 192)
    XCTAssertEqual(stored.stoken?.count, 64)
    XCTAssertEqual(stored.bdussCookieName, .bdussBFESS)
    XCTAssertEqual(Array(validatedAccount.customMirror.children).count, 2)
  }

  func testOlderReloadCannotOverwriteNewerAccountSnapshot() async throws {
    let old = AccountSummary(
      id: 1,
      username: "old",
      displayName: "old",
      portraitURL: nil,
      isActive: true,
      hasFullCredentials: false,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let new = AccountSummary(
      id: 2,
      username: "new",
      displayName: "new",
      portraitURL: nil,
      isActive: true,
      hasFullCredentials: true,
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    let vault = OutOfOrderSummaryVault(first: [old], second: [new])
    let viewModel = AccountViewModel(vault: vault)

    let olderReload = Task { await viewModel.reload() }
    try await waitForAccountState { await vault.requestCount() == 1 }
    await viewModel.reload()
    await olderReload.value

    XCTAssertEqual(viewModel.accounts.map(\.id), [2])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testExplicitResetRecoversAccountViewModelFromUnreadableArchive() async {
    let vault = RecoverableAccountVault()
    let viewModel = AccountViewModel(vault: vault)

    await viewModel.reload()
    XCTAssertEqual(viewModel.state, .failed(AccountVaultError.invalidArchive.localizedDescription))

    await viewModel.resetLocalAccounts()
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(viewModel.accounts.isEmpty)
    let resetCount = await vault.resetCount()
    XCTAssertEqual(resetCount, 1)
  }

  func testFailedLoginDoesNotPersistCredentials() async throws {
    let vault = AccountVaultSpy()
    let service = AccountServiceSpy(
      validation: .failure(AccountTestFailure(message: "credentials rejected"))
    )
    let viewModel = LoginViewModel(service: service, vault: vault)

    let succeeded = await viewModel.complete(
      credentials: AccountCredentials(
        bduss: String(repeating: "b", count: 192),
        stoken: String(repeating: "s", count: 64),
        bdussCookieName: .bduss
      )
    )

    XCTAssertFalse(succeeded)
    XCTAssertEqual(viewModel.errorMessage, "credentials rejected")
    let count = await vault.sessionCount()
    XCTAssertEqual(count, 0)
  }

  func testFollowedForumPaginationReusesSessionAndDeduplicatesForums() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      currentPage: 1,
      hasMore: true
    )
    let secondPage = FollowedForumPageData(
      forums: [forum(id: 2, name: "duplicate"), forum(id: 3, name: "three")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(firstPage), 2: .success(secondPage)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.forums.map(\.id), [1, 2])

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
    try await waitForAccountState { viewModel.forums.map(\.id) == [1, 2, 3] }

    XCTAssertEqual(viewModel.forums.map(\.name), ["one", "two", "three"])
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        FollowedRequest(userID: 7, page: 1, pageSize: 50),
        FollowedRequest(userID: 7, page: 2, pageSize: 50),
      ]
    )
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 1)
  }

  func testFollowedForumsWithoutActiveSessionNeverCallsService() async throws {
    let vault = AccountVaultSpy()
    let service = AccountServiceSpy()
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertEqual(viewModel.state, .failed("请先登录账户。"))
    let requests = await service.followedRequestSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  func testFollowedForumRelationshipChangeRestartsFromFirstPage() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }

    viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 7, forumID: 1, isFollowed: false)
    )
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2 && viewModel.state == .loaded
    }

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.userID), [7, 7])
  }

  func testFollowedForumAccountChangeDropsCachedSession() async throws {
    let vault = AccountVaultSpy(
      sessions: [
        session(userID: 7, name: "first"),
        session(userID: 8, name: "second"),
      ],
      activeUserID: 7
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }

    try await vault.switchActive(to: 8)
    viewModel.accountSessionDidChange()
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2 && viewModel.state == .loaded
    }

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  private func session(
    userID: Int64,
    name: String,
    updatedAt: TimeInterval = 1,
    sessionRevision: UUID = UUID()
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: name,
      displayName: name,
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      sessionRevision: sessionRevision
    )
  }

  private func forum(id: Int64, name: String) -> FollowedForumItem {
    FollowedForumItem(id: id, name: name, level: Int(id), experience: Int(id * 10))
  }
}

private struct FollowedRequest: Equatable, Sendable {
  let userID: Int64
  let page: Int
  let pageSize: Int
}

private struct CredentialLengths: Equatable, Sendable {
  let bduss: Int
  let stoken: Int
}

private struct AccountTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor AccountServiceSpy: AccountService {
  private let validation: Result<ValidatedAccount, AccountTestFailure>
  private let followedPages: [Int: Result<FollowedForumPageData, AccountTestFailure>]
  private var validatedBDUSSLength: Int?
  private var validatedSTOKENLength: Int?
  private var followedRequests: [FollowedRequest] = []

  init(
    validation: Result<ValidatedAccount, AccountTestFailure> = .failure(
      AccountTestFailure(message: "unexpected validation")
    ),
    followedPages: [Int: Result<FollowedForumPageData, AccountTestFailure>] = [:]
  ) {
    self.validation = validation
    self.followedPages = followedPages
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    validatedBDUSSLength = credential.bduss.count
    validatedSTOKENLength = credential.stoken.count
    return try validation.get()
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    followedRequests.append(FollowedRequest(userID: session.id, page: page, pageSize: pageSize))
    guard let result = followedPages[page] else {
      throw AccountTestFailure(message: "unexpected followed-forum page")
    }
    return try result.get()
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw AccountTestFailure(message: "unexpected forum-membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw AccountTestFailure(message: "unexpected forum-account-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw AccountTestFailure(message: "unexpected forum-membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw AccountTestFailure(message: "unexpected forum-check-in mutation")
  }

  func validationCredentialLengths() -> CredentialLengths? {
    guard let validatedBDUSSLength, let validatedSTOKENLength else { return nil }
    return CredentialLengths(bduss: validatedBDUSSLength, stoken: validatedSTOKENLength)
  }

  func followedRequestSnapshot() -> [FollowedRequest] { followedRequests }
}

private actor AccountVaultSpy: AccountVault {
  private var sessions: [Int64: StoredAccountSession]
  private var activeUserID: Int64?
  private var activeReads = 0

  init(sessions: [StoredAccountSession] = [], activeUserID: Int64? = nil) {
    self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    self.activeUserID = activeUserID
  }

  func accountSummaries() async throws -> [AccountSummary] {
    sessions.values
      .sorted { $0.updatedAt > $1.updatedAt }
      .map {
        AccountSummary(
          id: $0.id,
          username: $0.username,
          displayName: $0.displayName,
          portraitURL: nil,
          isActive: $0.id == activeUserID,
          hasFullCredentials: $0.credentials != nil,
          updatedAt: $0.updatedAt
        )
      }
  }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    return activeUserID.flatMap { sessions[$0] }
  }

  func upsert(_ session: StoredAccountSession) async throws {
    sessions[session.id] = session
    activeUserID = session.id
  }

  func switchActive(to userID: Int64) async throws {
    guard sessions[userID] != nil else { throw AccountVaultError.accountNotFound }
    activeUserID = userID
  }

  func remove(userID: Int64) async throws {
    guard sessions.removeValue(forKey: userID) != nil else {
      throw AccountVaultError.accountNotFound
    }
    if activeUserID == userID {
      activeUserID = sessions.values.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }
  }

  func removeAll() async throws {
    sessions.removeAll()
    activeUserID = nil
  }

  func session(userID: Int64) -> StoredAccountSession? { sessions[userID] }
  func sessionCount() -> Int { sessions.count }
  func activeSessionReadCount() -> Int { activeReads }
}

private actor OutOfOrderSummaryVault: AccountVault {
  private let first: [AccountSummary]
  private let second: [AccountSummary]
  private var requests = 0

  init(first: [AccountSummary], second: [AccountSummary]) {
    self.first = first
    self.second = second
  }

  func accountSummaries() async throws -> [AccountSummary] {
    requests += 1
    let request = requests
    if request == 1 {
      try await Task.sleep(nanoseconds: 100_000_000)
      return first
    }
    return second
  }

  func activeSession() async throws -> StoredAccountSession? { nil }
  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}
  func requestCount() -> Int { requests }
}

private actor RecoverableAccountVault: AccountVault {
  private var isUnreadable = true
  private var resets = 0

  func accountSummaries() async throws -> [AccountSummary] {
    if isUnreadable { throw AccountVaultError.invalidArchive }
    return []
  }

  func activeSession() async throws -> StoredAccountSession? { nil }
  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}

  func removeAll() async throws {
    isUnreadable = false
    resets += 1
  }

  func resetCount() -> Int { resets }
}

@MainActor
private func waitForAccountState(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw AccountTestFailure(message: "timed out waiting for account state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
