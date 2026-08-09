import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ConcernFeedViewModelTests: XCTestCase {
  func testInactiveViewNeverRequestsUntilExplicitlySelected() async throws {
    let session = concernSession(userID: 7)
    let vault = ConcernVaultSpy(session: session)
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(concernPage(userID: 7, ids: [1], nextPageTag: nil, hasMore: false, requestUnix: 10))
      ]
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)

    viewModel.setActive(false)
    for _ in 0..<20 { await Task<Never, Never>.yield() }
    let inactiveRequestCount = await service.requestCount()
    XCTAssertEqual(inactiveRequestCount, 0)

    viewModel.setActive(true)
    try await waitForConcernTest { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.threads.map(\.id), [1])
    let activeRequestCount = await service.requestCount()
    XCTAssertEqual(activeRequestCount, 1)

    viewModel.setActive(false)
    viewModel.accountSessionDidChange()
    for _ in 0..<20 { await Task<Never, Never>.yield() }
    let changedWhileInactiveRequestCount = await service.requestCount()
    XCTAssertEqual(changedWhileInactiveRequestCount, 1)
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  func testPaginationKeepsRefreshFrontierAndRefreshReplacesSnapshot() async throws {
    let vault = ConcernVaultSpy(session: concernSession(userID: 7))
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(
          concernPage(
            userID: 7, ids: [1], nextPageTag: "page-a", hasMore: true,
            requestUnix: 100
          )
        )
      ],
      .init(userID: 7, pageTag: "page-a", requestUnix: 100): [
        .page(
          concernPage(
            userID: 7, ids: [2], nextPageTag: "page-b", hasMore: true,
            requestUnix: 999
          )
        )
      ],
      .init(userID: 7, pageTag: nil, requestUnix: 100): [
        .page(
          concernPage(
            userID: 7, ids: [3], nextPageTag: "page-c", hasMore: true,
            requestUnix: 200
          )
        )
      ],
      .init(userID: 7, pageTag: "page-c", requestUnix: 200): [
        .page(
          concernPage(
            userID: 7, ids: [4], nextPageTag: nil, hasMore: false,
            requestUnix: 777
          )
        )
      ],
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)

    viewModel.setActive(true)
    try await waitForConcernTest { viewModel.threads.map(\.id) == [1] }
    viewModel.loadMore()
    try await waitForConcernTest { viewModel.threads.map(\.id) == [1, 2] }
    await viewModel.refresh()
    XCTAssertEqual(viewModel.threads.map(\.id), [3])
    viewModel.loadMore()
    try await waitForConcernTest { viewModel.threads.map(\.id) == [3, 4] }

    let requests = await service.requestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        .init(userID: 7, pageTag: nil, requestUnix: 0),
        .init(userID: 7, pageTag: "page-a", requestUnix: 100),
        .init(userID: 7, pageTag: nil, requestUnix: 100),
        .init(userID: 7, pageTag: "page-c", requestUnix: 200),
      ]
    )
    XCTAssertFalse(viewModel.hasMore)
  }

  func testDuplicateOnlyPageRequiresExplicitContinuationWithAdvancedCursor() async throws {
    let vault = ConcernVaultSpy(session: concernSession(userID: 7))
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(
          concernPage(
            userID: 7, ids: [1], nextPageTag: "page-a", hasMore: true,
            requestUnix: 100
          )
        )
      ],
      .init(userID: 7, pageTag: "page-a", requestUnix: 100): [
        .page(
          concernPage(
            userID: 7,
            threads: [concernThread(id: 1, title: "Updated")],
            nextPageTag: "page-b",
            hasMore: true,
            requestUnix: 101
          )
        )
      ],
      .init(userID: 7, pageTag: "page-b", requestUnix: 100): [
        .page(
          concernPage(
            userID: 7, ids: [2], nextPageTag: nil, hasMore: false,
            requestUnix: 102
          )
        )
      ],
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)

    viewModel.setActive(true)
    try await waitForConcernTest { viewModel.state == .loaded }
    viewModel.loadMore()
    try await waitForConcernTest { viewModel.loadMoreError != nil }
    XCTAssertEqual(viewModel.threads.map(\.id), [1])
    XCTAssertEqual(viewModel.threads.first?.title, "Updated")

    viewModel.retryLoadMore()
    try await waitForConcernTest { viewModel.threads.map(\.id) == [1, 2] }
    let duplicateRequests = await service.requestsSnapshot()
    let requestedPageTags = duplicateRequests.map(\.pageTag)
    XCTAssertEqual(requestedPageTags, [nil, "page-a", "page-b"])
  }

  func testRefreshFailurePreservesExistingSnapshot() async throws {
    let vault = ConcernVaultSpy(session: concernSession(userID: 7))
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(concernPage(userID: 7, ids: [1], nextPageTag: nil, hasMore: false, requestUnix: 10))
      ],
      .init(userID: 7, pageTag: nil, requestUnix: 10): [.failure("刷新失败")],
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)
    viewModel.setActive(true)
    try await waitForConcernTest { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threads.map(\.id), [1])
    XCTAssertEqual(viewModel.refreshError, "刷新失败")
  }

  func testAccountSwitchClearsImmediatelyAndLateResponseCannotOverwrite() async throws {
    let oldSession = concernSession(userID: 7, revision: concernUUID(7))
    let newSession = concernSession(userID: 8, revision: concernUUID(8))
    let vault = ConcernVaultSpy(session: oldSession)
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(
          concernPage(userID: 7, ids: [71], nextPageTag: nil, hasMore: false, requestUnix: 10),
          delayNanoseconds: 120_000_000
        )
      ],
      .init(userID: 8, pageTag: nil, requestUnix: 0): [
        .page(concernPage(userID: 8, ids: [81], nextPageTag: nil, hasMore: false, requestUnix: 20))
      ],
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)
    viewModel.setActive(true)
    try await waitForConcernTest { await service.requestCount() == 1 }

    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertTrue(viewModel.threads.isEmpty)
    try await waitForConcernTest { viewModel.threads.map(\.id) == [81] }
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(viewModel.threads.map(\.id), [81])
    let switchRequests = await service.requestsSnapshot()
    let requestedUserIDs = switchRequests.map(\.userID)
    XCTAssertEqual(requestedUserIDs, [7, 8])
  }

  func testSameUserCredentialRotationAndLogoutDiscardInFlightResult() async throws {
    let original = concernSession(userID: 7, revision: concernUUID(7))
    let rotated = concernSession(userID: 7, revision: concernUUID(8))
    let vault = ConcernVaultSpy(session: original)
    let service = ConcernServiceSpy(scripts: [
      .init(userID: 7, pageTag: nil, requestUnix: 0): [
        .page(
          concernPage(userID: 7, ids: [1], nextPageTag: nil, hasMore: false, requestUnix: 10),
          delayNanoseconds: 80_000_000
        ),
        .page(
          concernPage(userID: 7, ids: [2], nextPageTag: nil, hasMore: false, requestUnix: 20),
          delayNanoseconds: 80_000_000
        ),
      ]
    ])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)
    viewModel.setActive(true)
    try await waitForConcernTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: rotated)
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)

    viewModel.accountSessionDidChange()
    try await waitForConcernTest { await service.requestCount() == 2 }
    await vault.replaceActive(with: nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testSignedOutAndLegacySessionsNeverReachAccountService() async throws {
    let vault = ConcernVaultSpy(session: nil)
    let service = ConcernServiceSpy(scripts: [:])
    let viewModel = ConcernFeedViewModel(service: service, vault: vault)

    viewModel.setActive(true)
    try await waitForConcernTest { viewModel.state == .signedOut }
    let signedOutRequestCount = await service.requestCount()
    XCTAssertEqual(signedOutRequestCount, 0)

    await vault.replaceActive(with: concernSession(userID: 7, stoken: nil))
    viewModel.accountSessionDidChange()
    try await waitForConcernTest { viewModel.state == .needsRelogin }
    let legacyRequestCount = await service.requestCount()
    XCTAssertEqual(legacyRequestCount, 0)
  }

  func testExploreChannelsMirrorAccountAvailabilityWithoutChangingOrder() async throws {
    let vault = ConcernVaultSpy(session: nil)
    let viewModel = ExploreChannelsViewModel(vault: vault)

    viewModel.reload()
    try await waitForConcernTest {
      viewModel.visibleSections == [.personalized, .hot]
    }

    await vault.replaceActive(with: concernSession(userID: 7, stoken: nil))
    viewModel.reload()
    try await waitForConcernTest {
      viewModel.visibleSections == [.concern, .personalized, .hot]
    }

    await vault.replaceActive(with: nil)
    viewModel.reload()
    try await waitForConcernTest {
      viewModel.visibleSections == [.personalized, .hot]
    }
  }
}

private struct ConcernRequest: Hashable, Sendable {
  let userID: Int64
  let pageTag: String?
  let requestUnix: UInt64
}

private enum ConcernScript: Sendable {
  case page(ConcernFeedPageData, delayNanoseconds: UInt64 = 0)
  case failure(String)
}

private struct ConcernTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor ConcernServiceSpy: AccountService {
  private var scripts: [ConcernRequest: [ConcernScript]]
  private var requests = [ConcernRequest]()

  init(scripts: [ConcernRequest: [ConcernScript]]) {
    self.scripts = scripts
  }

  func concernFeed(
    session: StoredAccountSession,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> ConcernFeedPageData {
    let request = ConcernRequest(
      userID: session.id,
      pageTag: pageTag,
      requestUnix: lastRequestUnix
    )
    requests.append(request)
    guard var pending = scripts[request], !pending.isEmpty else {
      throw ConcernTestFailure(message: "Missing concern script")
    }
    let script = pending.removeFirst()
    scripts[request] = pending
    switch script {
    case .page(let page, let delayNanoseconds):
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      return page
    case .failure(let message):
      throw ConcernTestFailure(message: message)
    }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ConcernTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ConcernTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ConcernTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ConcernTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ConcernTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ConcernTestFailure(message: "Unexpected check-in")
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [ConcernRequest] { requests }
}

private actor ConcernVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? { session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

private func concernSession(
  userID: Int64,
  revision: UUID = UUID(),
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

private func concernPage(
  userID: Int64,
  ids: [Int64],
  nextPageTag: String?,
  hasMore: Bool,
  requestUnix: UInt64
) -> ConcernFeedPageData {
  concernPage(
    userID: userID,
    threads: ids.map { concernThread(id: $0) },
    nextPageTag: nextPageTag,
    hasMore: hasMore,
    requestUnix: requestUnix
  )
}

private func concernPage(
  userID: Int64,
  threads: [BrowseThread],
  nextPageTag: String?,
  hasMore: Bool,
  requestUnix: UInt64
) -> ConcernFeedPageData {
  ConcernFeedPageData(
    userID: userID,
    threads: threads,
    nextPageTag: nextPageTag,
    hasMore: hasMore,
    requestUnix: requestUnix
  )
}

private func concernThread(id: Int64, title: String? = nil) -> BrowseThread {
  BrowseThread(
    id: id,
    forumID: 42,
    forumName: "swift",
    title: title ?? "Thread \(id)",
    excerpt: "Excerpt \(id)",
    authorName: "Author \(id)",
    replyCount: 3,
    viewCount: 10,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [.text("Content \(id)")]
  )
}

private func concernUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private struct ConcernWaitTimeout: Error {}

@MainActor
private func waitForConcernTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw ConcernWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
