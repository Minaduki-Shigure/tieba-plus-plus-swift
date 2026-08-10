import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserLikedForumsViewModelTests: XCTestCase {
  func testPageBindingIncludesAccountRevisionTargetAndPage() {
    let revision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let session = makeSession(userID: 7, revision: revision)
    let binding = UserLikedForumsPageBinding(
      session: session,
      targetUserID: 42,
      page: 3
    )

    XCTAssertEqual(binding.accountUserID, 7)
    XCTAssertEqual(binding.sessionRevision, revision)
    XCTAssertEqual(binding.targetUserID, 42)
    XCTAssertEqual(binding.page, 3)
    XCTAssertTrue(binding.matches(session: session, targetUserID: 42, page: 3))
    XCTAssertFalse(binding.matches(session: session, targetUserID: 43, page: 3))
    XCTAssertFalse(binding.matches(session: session, targetUserID: 42, page: 4))
    XCTAssertFalse(
      binding.matches(
        session: makeSession(userID: 7, revision: UUID()),
        targetUserID: 42,
        page: 3
      )
    )
  }

  func testInitialLoadUsesActiveSessionTargetAndFiftyItemRequestPage() async throws {
    let session = makeSession(userID: 7)
    let page = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 1, name: "Swift")],
      hasMore: false
    )
    let service = UserLikedForumsServiceSpy(scripts: [1: [.page(page)]])
    let vault = UserLikedForumsVaultSpy(session: session)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: vault
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.forums.map(\.name), ["Swift"])
    XCTAssertFalse(viewModel.isSignedOut)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        UserLikedForumsRequest(
          accountUserID: 7,
          sessionRevision: session.sessionRevision,
          targetUserID: 42,
          page: 1,
          pageSize: 50
        )
      ]
    )
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 2)
  }

  func testSignedOutStateNeverCallsAccountService() async throws {
    let service = UserLikedForumsServiceSpy()
    let vault = UserLikedForumsVaultSpy(session: nil)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: vault
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { viewModel.isSignedOut }

    XCTAssertEqual(viewModel.state, .failed("请先登录账户。"))
    XCTAssertTrue(viewModel.forums.isEmpty)
    let requests = await service.requestsSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  func testPaginationPreservesOrderAndDeduplicatesByStableForumID() async throws {
    let session = makeSession(userID: 7)
    let firstPage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      hasMore: true
    )
    let secondPage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 2,
      forums: [forum(id: 2, name: "duplicate"), forum(id: 3, name: "three")],
      hasMore: false
    )
    let service = UserLikedForumsServiceSpy(
      scripts: [1: [.page(firstPage)], 2: [.page(secondPage)]]
    )
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: UserLikedForumsVaultSpy(session: session)
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
    try await waitForUserLikedForums {
      await service.requestCount() == 2 && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.forums.map(\.id), [1, 2, 3])
    XCTAssertEqual(viewModel.forums.map(\.name), ["one", "two", "three"])
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testDuplicateOnlyContinuationFailsClosedWithoutLooping() async throws {
    let session = makeSession(userID: 7)
    let firstPage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 1, name: "one")],
      hasMore: true
    )
    let duplicatePage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 2,
      forums: [forum(id: 1, name: "duplicate")],
      hasMore: true
    )
    let service = UserLikedForumsServiceSpy(
      scripts: [1: [.page(firstPage)], 2: [.page(duplicatePage)]]
    )
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: UserLikedForumsVaultSpy(session: session)
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
    try await waitForUserLikedForums { viewModel.loadMoreError != nil }

    XCTAssertEqual(viewModel.forums.map(\.name), ["one"])
    XCTAssertEqual(
      viewModel.loadMoreError,
      "喜欢贴吧分页未取得进展，请重新加载后再试。"
    )
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testRejectsResponseBoundToAnotherAccountTargetOrPage() async throws {
    let session = makeSession(userID: 7)
    let cases: [UserLikedForumPageData] = [
      likedPage(
        accountUserID: 8,
        targetUserID: 42,
        page: 1,
        forums: [forum(id: 1, name: "wrong-account")],
        hasMore: false
      ),
      likedPage(
        accountUserID: 7,
        targetUserID: 43,
        page: 1,
        forums: [forum(id: 1, name: "wrong-target")],
        hasMore: false
      ),
      likedPage(
        accountUserID: 7,
        targetUserID: 42,
        page: 2,
        forums: [forum(id: 1, name: "wrong-page")],
        hasMore: false
      ),
    ]

    for page in cases {
      let service = UserLikedForumsServiceSpy(scripts: [1: [.page(page)]])
      let viewModel = UserLikedForumsViewModel(
        targetUserID: 42,
        service: service,
        vault: UserLikedForumsVaultSpy(session: session)
      )
      viewModel.loadIfNeeded()
      try await waitForUserLikedForums {
        if case .failed = viewModel.state { return true }
        return false
      }
      XCTAssertTrue(viewModel.forums.isEmpty)
    }
  }

  func testLateResultIsDiscardedWhenSameAccountSessionRevisionRotates() async throws {
    let oldSession = makeSession(
      userID: 7,
      revision: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    )
    let rotatedSession = makeSession(
      userID: 7,
      revision: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    )
    let stalePage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 1, name: "stale")],
      hasMore: false
    )
    let service = UserLikedForumsServiceSpy(
      scripts: [1: [.suspended(id: 1, page: stalePage)]]
    )
    let vault = UserLikedForumsVaultSpy(session: oldSession)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: vault
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { await service.requestCount() == 1 }
    await vault.replaceActive(with: rotatedSession)
    let released = await service.release(id: 1)
    XCTAssertTrue(released)
    try await waitForUserLikedForums {
      await vault.activeSessionReadCount() == 2 && viewModel.state == .idle
    }

    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertFalse(viewModel.isSignedOut)
  }

  func testExplicitAccountChangeClearsAndReloadsForNewAccount() async throws {
    let firstSession = makeSession(userID: 7)
    let secondSession = makeSession(userID: 8)
    let firstPage = likedPage(
      accountUserID: 7,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 1, name: "first")],
      hasMore: false
    )
    let secondPage = likedPage(
      accountUserID: 8,
      targetUserID: 42,
      page: 1,
      forums: [forum(id: 2, name: "second")],
      hasMore: false
    )
    let service = UserLikedForumsServiceSpy(
      scripts: [1: [.page(firstPage), .page(secondPage)]]
    )
    let vault = UserLikedForumsVaultSpy(session: firstSession)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: vault
    )

    viewModel.loadIfNeeded()
    try await waitForUserLikedForums { viewModel.forums.map(\.name) == ["first"] }
    await vault.replaceActive(with: secondSession)
    viewModel.accountSessionDidChange()
    XCTAssertTrue(viewModel.forums.isEmpty)
    try await waitForUserLikedForums { viewModel.forums.map(\.name) == ["second"] }

    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.accountUserID), [7, 8])
    XCTAssertEqual(requests.map(\.targetUserID), [42, 42])
  }

  func testStopsAtOneHundredPagesWhenServerClaimsMore() async throws {
    let session = makeSession(userID: 7)
    let scripts = Dictionary(
      uniqueKeysWithValues: (1...UserLikedForumsViewModel.maximumCatalogPageCount).map { page in
        (
          page,
          [
            UserLikedForumsScript.page(
              likedPage(
                accountUserID: 7,
                targetUserID: 42,
                page: page,
                forums: [forum(id: Int64(page), name: "forum-\(page)")],
                hasMore: true
              )
            )
          ]
        )
      }
    )
    let service = UserLikedForumsServiceSpy(scripts: scripts)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: UserLikedForumsVaultSpy(session: session)
    )

    viewModel.loadIfNeeded()
    for expectedPage in 1...UserLikedForumsViewModel.maximumCatalogPageCount {
      try await waitForUserLikedForums {
        await service.requestCount() == expectedPage
          && viewModel.forums.count == expectedPage
          && !viewModel.isLoadingMore
      }
      if expectedPage < UserLikedForumsViewModel.maximumCatalogPageCount {
        viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
      }
    }

    XCTAssertEqual(
      viewModel.forums.count,
      UserLikedForumsViewModel.maximumCatalogPageCount
    )
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, UserLikedForumsViewModel.maximumCatalogPageCount)
    XCTAssertEqual(
      viewModel.loadMoreError,
      "喜欢贴吧数量超过当前安全读取上限，请稍后重新加载。"
    )
  }

  func testStopsAtFiveThousandRetainedForums() async throws {
    let session = makeSession(userID: 7)
    let forumsPerPage = 100
    let pageCount = UserLikedForumsViewModel.maximumRetainedForums / forumsPerPage
    let scripts = Dictionary(
      uniqueKeysWithValues: (1...pageCount).map { page in
        let firstID = (page - 1) * forumsPerPage + 1
        let forums = (firstID..<(firstID + forumsPerPage)).map {
          forum(id: Int64($0), name: "forum-\($0)")
        }
        return (
          page,
          [
            UserLikedForumsScript.page(
              likedPage(
                accountUserID: 7,
                targetUserID: 42,
                page: page,
                forums: forums,
                hasMore: true
              )
            )
          ]
        )
      }
    )
    let service = UserLikedForumsServiceSpy(scripts: scripts)
    let viewModel = UserLikedForumsViewModel(
      targetUserID: 42,
      service: service,
      vault: UserLikedForumsVaultSpy(session: session)
    )

    viewModel.loadIfNeeded()
    for expectedPage in 1...pageCount {
      try await waitForUserLikedForums {
        await service.requestCount() == expectedPage
          && viewModel.forums.count == expectedPage * forumsPerPage
          && !viewModel.isLoadingMore
      }
      if expectedPage < pageCount {
        viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.forums.last))
      }
    }

    XCTAssertEqual(viewModel.forums.count, UserLikedForumsViewModel.maximumRetainedForums)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, pageCount)
    XCTAssertEqual(
      viewModel.loadMoreError,
      "喜欢贴吧数量超过当前安全读取上限，请稍后重新加载。"
    )
  }

  private func forum(id: Int64, name: String) -> FollowedForumItem {
    FollowedForumItem(id: id, name: name, level: 0, experience: 0)
  }

  private func likedPage(
    accountUserID: Int64,
    targetUserID: Int64,
    page: Int,
    forums: [FollowedForumItem],
    hasMore: Bool
  ) -> UserLikedForumPageData {
    UserLikedForumPageData(
      accountUserID: accountUserID,
      targetUserID: targetUserID,
      forums: forums,
      currentPage: page,
      hasMore: hasMore
    )
  }

  private func makeSession(
    userID: Int64,
    revision: UUID = UUID()
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "",
      bduss: "test",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      sessionRevision: revision
    )
  }
}

private struct UserLikedForumsRequest: Equatable, Sendable {
  let accountUserID: Int64
  let sessionRevision: UUID
  let targetUserID: Int64
  let page: Int
  let pageSize: Int
}

private enum UserLikedForumsScript: Sendable {
  case page(UserLikedForumPageData)
  case failure(String)
  case suspended(id: Int, page: UserLikedForumPageData)
}

private struct UserLikedForumsTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor UserLikedForumsServiceSpy: AccountService {
  private var scripts: [Int: [UserLikedForumsScript]]
  private var requests: [UserLikedForumsRequest] = []
  private var suspended:
    [Int: (CheckedContinuation<UserLikedForumPageData, Never>, UserLikedForumPageData)] = [:]

  init(scripts: [Int: [UserLikedForumsScript]] = [:]) {
    self.scripts = scripts
  }

  func likedForums(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> UserLikedForumPageData {
    requests.append(
      UserLikedForumsRequest(
        accountUserID: session.id,
        sessionRevision: session.sessionRevision,
        targetUserID: targetUserID,
        page: page,
        pageSize: pageSize
      )
    )
    guard var pending = scripts[page], !pending.isEmpty else {
      throw UserLikedForumsTestFailure(message: "Missing liked-forum script for page \(page)")
    }
    let script = pending.removeFirst()
    scripts[page] = pending
    switch script {
    case .page(let value):
      return value
    case .failure(let message):
      throw UserLikedForumsTestFailure(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { continuation in
        suspended[id] = (continuation, value)
      }
    }
  }

  func release(id: Int) -> Bool {
    guard let (continuation, value) = suspended.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [UserLikedForumsRequest] { requests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw UserLikedForumsTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw UserLikedForumsTestFailure(message: "Unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw UserLikedForumsTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw UserLikedForumsTestFailure(message: "Unexpected account-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw UserLikedForumsTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw UserLikedForumsTestFailure(message: "Unexpected check-in request")
  }
}

private actor UserLikedForumsVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var activeSessionReads = 0

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? {
    activeSessionReads += 1
    return session
  }

  func activeSessionReadCount() -> Int { activeSessionReads }

  func accountSummaries() async throws -> [AccountSummary] {
    throw UserLikedForumsTestFailure(message: "Unexpected account-summary request")
  }

  func upsert(_ session: StoredAccountSession) async throws {
    throw UserLikedForumsTestFailure(message: "Unexpected account mutation")
  }

  func switchActive(to userID: Int64) async throws {
    throw UserLikedForumsTestFailure(message: "Unexpected account mutation")
  }

  func remove(userID: Int64) async throws {
    throw UserLikedForumsTestFailure(message: "Unexpected account mutation")
  }

  func removeAll() async throws {
    throw UserLikedForumsTestFailure(message: "Unexpected account mutation")
  }
}

@MainActor
private func waitForUserLikedForums(
  timeout: TimeInterval = 5,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw UserLikedForumsTestFailure(message: "Timed out waiting for liked-forum state")
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
}
