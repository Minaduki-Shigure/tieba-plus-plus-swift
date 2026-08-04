import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class CloudFavoritesViewModelTests: XCTestCase {
  func testPaginationReplacesDuplicateWithNewServerDataAndStopsAfterEmptyPage() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "旧标题"), cloudItem(id: 12)],
              nextOffset: 2,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 2, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "新标题", latestFloor: 9), cloudItem(id: 13)],
              nextOffset: 4,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 4, pageSize: 2): [
          .page(cloudPage(userID: 7, items: [], nextOffset: 6, hasMore: true))
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault, pageSize: 2)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.threads.map(\.id), [11, 12])

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12, 13] }
    XCTAssertEqual(viewModel.threads.first?.title, "新标题")
    XCTAssertEqual(viewModel.threads.first?.latestFloor, 9)
    XCTAssertEqual(viewModel.threads.first?.hasUpdates, true)

    let last = try XCTUnwrap(viewModel.threads.last)
    viewModel.loadMoreIfNeeded(current: last)
    try await waitForCloudFavoritesTest {
      await service.requestCount() == 3 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: last)
    for _ in 0..<20 { await Task.yield() }

    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 2, 4])
    XCTAssertEqual(requests.map(\.pageSize), [2, 2, 2])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testLoadMoreFailureCanRetryWithoutDroppingExistingItems() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11)],
              nextOffset: 30,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 30): [
          .failure("网络暂时不可用"),
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 12)],
              nextOffset: nil,
              hasMore: false
            )
          ),
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForCloudFavoritesTest { viewModel.loadMoreError == "网络暂时不可用" }
    XCTAssertEqual(viewModel.threads.map(\.id), [11])

    viewModel.retryLoadMore()
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 30, 30])
  }

  func testDuplicateOnlyPageUpdatesItemAndRequiresExplicitContinuation() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "旧标题"), cloudItem(id: 12)],
              nextOffset: 2,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 2, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "新标题")],
              nextOffset: 4,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 4, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 13)],
              nextOffset: 6,
              hasMore: true
            )
          )
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault, pageSize: 2)

    await viewModel.refresh()
    let last = try XCTUnwrap(viewModel.threads.last)
    viewModel.loadMoreIfNeeded(current: last)
    try await waitForCloudFavoritesTest {
      await service.requestCount() == 2 && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.threads.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.threads.first?.title, "新标题")
    XCTAssertEqual(viewModel.loadMoreError, "云端收藏列表已发生变化，请继续加载。")

    viewModel.retryLoadMore()
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12, 13] }
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 2, 4])
  }

  func testAccountChangeClearsImmediatelyAndOldResponseCannotOverwriteNewAccount() async throws {
    let oldSession = cloudSession(userID: 7, revision: cloudUUID(7))
    let newSession = cloudSession(userID: 8, revision: cloudUUID(8))
    let vault = CloudFavoritesVaultSpy(session: oldSession)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 71)], nextOffset: nil, hasMore: false),
            delayNanoseconds: 120_000_000
          )
        ],
        .init(userID: 8, offset: 0): [
          .page(
            cloudPage(userID: 8, items: [cloudItem(id: 81)], nextOffset: nil, hasMore: false)
          )
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    let oldRefresh = Task { await viewModel.refresh() }
    try await waitForCloudFavoritesTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [81] }
    await oldRefresh.value

    XCTAssertEqual(viewModel.threads.map(\.id), [81])
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
  }

  func testSessionRevisionChangingDuringRequestDiscardsResponse() async throws {
    let oldSession = cloudSession(userID: 7, revision: cloudUUID(7))
    let rotatedSession = cloudSession(userID: 7, revision: cloudUUID(8))
    let vault = CloudFavoritesVaultSpy(session: oldSession)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 71)], nextOffset: nil, hasMore: false),
            delayNanoseconds: 80_000_000
          )
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    let refresh = Task { await viewModel.refresh() }
    try await waitForCloudFavoritesTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: rotatedSession)
    await refresh.value

    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testLegacySessionServiceErrorAsksUserToLogInAgain() async {
    let legacy = cloudSession(userID: 7, stoken: nil)
    let vault = CloudFavoritesVaultSpy(session: legacy)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [.requiresRelogin]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.state, .failed("此账户需要重新登录，才能安全读取贴吧收藏。"))
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  func testMismatchedUserAndNonAdvancingOffsetAreRejected() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 8, items: [cloudItem(id: 11)], nextOffset: nil, hasMore: false)
          ),
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 11)], nextOffset: 0, hasMore: true)
          ),
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    await viewModel.refresh()
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了不匹配的账户收藏，请重新加载后再试。")
    )

    await viewModel.refresh()
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了异常的收藏分页位置，请重新加载后再试。")
    )
  }
}

private struct CloudFavoritesRequest: Hashable, Sendable {
  let userID: Int64
  let offset: Int
  let pageSize: Int

  init(userID: Int64, offset: Int, pageSize: Int = 30) {
    self.userID = userID
    self.offset = offset
    self.pageSize = pageSize
  }
}

private enum CloudFavoritesScript: Sendable {
  case page(CloudFavoritePage, delayNanoseconds: UInt64 = 0)
  case failure(String)
  case requiresRelogin
}

private struct CloudFavoritesTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor CloudFavoritesServiceSpy: AccountService {
  private var scripts: [CloudFavoritesRequest: [CloudFavoritesScript]]
  private var requests: [CloudFavoritesRequest] = []

  init(scripts: [CloudFavoritesRequest: [CloudFavoritesScript]]) {
    self.scripts = scripts
  }

  func cloudFavorites(
    session: StoredAccountSession,
    offset: Int,
    pageSize: Int
  ) async throws -> CloudFavoritePage {
    let request = CloudFavoritesRequest(userID: session.id, offset: offset, pageSize: pageSize)
    requests.append(request)
    guard var pending = scripts[request], !pending.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Missing cloud favorites script")
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
      throw CloudFavoritesTestFailure(message: message)
    case .requiresRelogin:
      guard session.stoken == nil else {
        throw CloudFavoritesTestFailure(message: "Expected a legacy session")
      }
      throw CloudFavoritesTestFailure(
        message: "此账户需要重新登录，才能安全读取贴吧收藏。"
      )
    }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw CloudFavoritesTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw CloudFavoritesTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw CloudFavoritesTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw CloudFavoritesTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw CloudFavoritesTestFailure(message: "Unexpected check-in")
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [CloudFavoritesRequest] { requests }
}

private actor CloudFavoritesVaultSpy: AccountVault {
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

private func cloudSession(
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

private func cloudPage(
  userID: Int64,
  items: [CloudFavoriteThread],
  nextOffset: Int?,
  hasMore: Bool
) -> CloudFavoritePage {
  CloudFavoritePage(
    userID: userID,
    items: items,
    nextOffset: nextOffset,
    hasMore: hasMore
  )
}

private func cloudItem(
  id: Int64,
  title: String? = nil,
  latestFloor: Int? = 3,
  isDeleted: Bool = false
) -> CloudFavoriteThread {
  CloudFavoriteThread(
    id: id,
    title: title ?? "Thread \(id)",
    forumName: "swift",
    authorName: "author-\(id)",
    markPostID: 1_000 + id,
    latestPostID: 2_000 + id,
    latestFloor: latestFloor,
    hasUpdates: latestFloor != nil,
    isDeleted: isDeleted,
    updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
  )
}

private func cloudUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

@MainActor
private func waitForCloudFavoritesTest(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
  while !(await condition()) {
    if ContinuousClock.now >= deadline {
      XCTFail("Timed out waiting for cloud favorites test condition")
      return
    }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
