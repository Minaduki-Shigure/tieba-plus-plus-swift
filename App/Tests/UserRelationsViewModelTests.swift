import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserRelationsViewModelTests: XCTestCase {
  func testLoadIsExplicitAndUsesRawHiddenTailForPagination() async throws {
    let visible = BrowseRelatedUser.fixture(id: 10)
    let hiddenTail = BrowseRelatedUser.fixture(id: 11, localVisibility: .hidden)
    let next = BrowseRelatedUser.fixture(id: 12)
    let service = UserRelationServiceStub(
      stubs: [
        .value(
          .fixture(
            users: [visible, hiddenTail],
            currentPage: 1,
            totalCount: 3,
            hasMore: true,
            notice: "仅展示正常账号",
            visibilitySwitch: 1
          )
        ),
        .value(
          .fixture(
            users: [next],
            currentPage: 2,
            totalCount: 3,
            hasMore: false,
            notice: "",
            visibilitySwitch: nil
          )
        ),
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .following, service: service)

    await Task.yield()
    let requestsBeforeLoad = await service.requestSnapshot()
    XCTAssertTrue(requestsBeforeLoad.isEmpty)

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.users, [visible, hiddenTail])
    XCTAssertEqual(viewModel.displayableUsers, [visible])
    XCTAssertEqual(viewModel.totalCount, 3)
    XCTAssertEqual(viewModel.notice, "仅展示正常账号")
    XCTAssertEqual(viewModel.visibilitySwitch, 1)

    viewModel.loadMoreIfNeeded(current: hiddenTail)
    try await waitForRelations { viewModel.users == [visible, hiddenTail, next] }

    XCTAssertEqual(viewModel.displayableUsers, [visible, next])
    XCTAssertEqual(viewModel.notice, "仅展示正常账号")
    XCTAssertEqual(viewModel.visibilitySwitch, 1)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(
      requests,
      [
        UserRelationRequest(userID: 7, kind: .following, page: 1),
        UserRelationRequest(userID: 7, kind: .following, page: 2),
      ]
    )
  }

  func testKindsUseIndependentLazyViewModels() async throws {
    let followingService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [.fixture(id: 20)], totalCount: 1))]
    )
    let followerService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [.fixture(id: 21)], totalCount: 1))]
    )
    let following = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: followingService
    )
    let followers = UserRelationsViewModel(
      userID: 7,
      kind: .followers,
      service: followerService
    )

    following.loadIfNeeded()
    try await waitForRelations { following.state == .loaded }

    XCTAssertEqual(following.users.map(\.id), [20])
    XCTAssertEqual(followers.state, .idle)
    let followerRequestsBeforeLoad = await followerService.requestSnapshot()
    XCTAssertTrue(followerRequestsBeforeLoad.isEmpty)

    followers.loadIfNeeded()
    try await waitForRelations { followers.state == .loaded }
    XCTAssertEqual(followers.users.map(\.id), [21])
    let followingRequests = await followingService.requestSnapshot()
    let followerRequests = await followerService.requestSnapshot()
    XCTAssertEqual(followingRequests.map(\.kind), [.following])
    XCTAssertEqual(followerRequests.map(\.kind), [.followers])
  }

  func testEmptyPageStopsEvenWhenServerClaimsMoreWithoutInferringPrivacy() async throws {
    let service = UserRelationServiceStub(
      stubs: [
        .value(
          .fixture(
            users: [],
            totalCount: 40,
            hasMore: true,
            notice: "仅展示正常账号",
            visibilitySwitch: 0
          )
        )
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .following, service: service)

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.retryLoadMore()
    await Task.yield()

    XCTAssertTrue(viewModel.users.isEmpty)
    XCTAssertFalse(viewModel.hasDisplayableUsers)
    XCTAssertEqual(viewModel.totalCount, 40)
    XCTAssertEqual(viewModel.notice, "仅展示正常账号")
    XCTAssertEqual(viewModel.visibilitySwitch, 0)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testDuplicateOnlyPageStopsPagination() async throws {
    let user = BrowseRelatedUser.fixture(id: 30)
    let service = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [user], hasMore: true)),
        .value(.fixture(users: [user], currentPage: 2, hasMore: true)),
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .followers, service: service)

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: user)
    try await waitForRelations { !viewModel.isLoadingMore }
    viewModel.loadMoreIfNeeded(current: user)
    await Task.yield()

    XCTAssertEqual(viewModel.users, [user])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testInitialFailureAndPaginationFailureCanRetry() async throws {
    let first = BrowseRelatedUser.fixture(id: 40)
    let second = BrowseRelatedUser.fixture(id: 41)
    let service = UserRelationServiceStub(
      stubs: [
        .failure,
        .value(.fixture(users: [first], hasMore: true)),
        .failure,
        .value(.fixture(users: [second], currentPage: 2)),
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .followers, service: service)

    viewModel.loadIfNeeded()
    try await waitForRelations {
      if case .failed = viewModel.state { return true }
      return false
    }
    viewModel.reload()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForRelations { viewModel.loadMoreError != nil }
    viewModel.retryLoadMore()
    try await waitForRelations { viewModel.users == [first, second] }

    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2, 2])
  }

  func testCancelingPaginationRearmsTailAndLateResultCannotApply() async throws {
    let first = BrowseRelatedUser.fixture(id: 50)
    let stale = BrowseRelatedUser.fixture(id: 51)
    let replacement = BrowseRelatedUser.fixture(id: 52)
    let service = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [first], hasMore: true)),
        .suspended(501),
        .value(.fixture(users: [replacement], currentPage: 2)),
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .following, service: service)

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    let epoch = viewModel.paginationEpoch
    viewModel.loadMoreIfNeeded(current: first)
    await service.waitUntilSuspendedRequestStarted(id: 501)
    viewModel.cancel()

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertEqual(viewModel.paginationEpoch, epoch + 1)
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForRelations { viewModel.users == [first, replacement] }

    let resumed = await service.resumeSuspended(
      id: 501,
      returning: .fixture(users: [stale], currentPage: 2)
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 501)
    await Task.yield()

    XCTAssertEqual(viewModel.users, [first, replacement])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  func testReloadSupersedesSuspendedInitialResponse() async throws {
    let stale = BrowseRelatedUser.fixture(id: 60)
    let replacement = BrowseRelatedUser.fixture(id: 61, localVisibility: .placeholder)
    let service = UserRelationServiceStub(
      stubs: [
        .suspended(601),
        .value(.fixture(users: [replacement], notice: "new")),
      ]
    )
    let viewModel = UserRelationsViewModel(userID: 7, kind: .followers, service: service)

    viewModel.loadIfNeeded()
    await service.waitUntilSuspendedRequestStarted(id: 601)
    viewModel.reloadAfterContentFilterChange()
    try await waitForRelations { viewModel.users == [replacement] }

    let resumed = await service.resumeSuspended(
      id: 601,
      returning: .fixture(users: [stale], notice: "stale")
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 601)
    await Task.yield()

    XCTAssertEqual(viewModel.users, [replacement])
    XCTAssertEqual(viewModel.notice, "new")
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testRelatedUserFilteringCoversIdentityNamesAndIntroductionWithoutDroppingRows() {
    let cases: [(ContentFilterRule, BrowseRelatedUser)] = [
      (.user(id: 70, name: "", list: .block), .fixture(id: 70)),
      (.user(id: nil, name: "显示昵称", list: .block), .fixture(id: 71)),
      (.user(id: nil, name: "account-72", list: .block), .fixture(id: 72)),
      (.keyword("个人简介", list: .block), .fixture(id: 73)),
    ]

    for (rule, user) in cases {
      let snapshot = ContentFilterSnapshot(
        displayMode: .hidden,
        blockVideos: false,
        rules: [rule]
      )
      let filtered = snapshot.applying(to: user)

      XCTAssertEqual(filtered.id, user.id)
      XCTAssertEqual(filtered.localVisibility, .hidden)
      XCTAssertEqual(filtered.withLocalVisibility(.visible), user)
    }
  }

  func testCoreMappingValidatesContextAndPreservesPublicIdentityMetadata() throws {
    let response = TiebaUserRelationPage(
      requestedUserID: 7,
      kind: .following,
      users: [
        TiebaRelatedUser(
          id: 80,
          username: "account-80",
          displayName: "被过滤昵称",
          portrait: "portrait-token",
          introduction: "公开简介"
        ),
        TiebaRelatedUser(
          id: 81,
          username: "account-81",
          displayName: "普通昵称",
          portrait: "file:///private/avatar.png",
          introduction: "普通简介"
        )
      ],
      pagination: TiebaPagination(
        pageSize: 20,
        currentPage: 2,
        totalPages: 3,
        totalCount: 41,
        hasMore: true,
        hasPrevious: true
      ),
      notice: "仅展示正常账号",
      visibilitySwitch: 1
    )
    let filter = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("被过滤", list: .block)]
    )

    let mapped = try TiebaCoreBrowseService.mapUserRelationPage(
      response,
      expectedUserID: 7,
      expectedKind: .following,
      applying: filter
    )

    XCTAssertEqual(mapped.currentPage, 2)
    XCTAssertEqual(mapped.totalCount, 41)
    XCTAssertTrue(mapped.hasMore)
    XCTAssertEqual(mapped.notice, "仅展示正常账号")
    XCTAssertEqual(mapped.visibilitySwitch, 1)
    XCTAssertEqual(mapped.users.count, 2)
    XCTAssertEqual(mapped.users.first?.id, 80)
    XCTAssertEqual(mapped.users.first?.username, "account-80")
    XCTAssertEqual(mapped.users.first?.displayName, "被过滤昵称")
    XCTAssertEqual(mapped.users.first?.introduction, "公开简介")
    XCTAssertEqual(mapped.users.first?.localVisibility, .placeholder)
    XCTAssertEqual(mapped.users.first?.portraitURL?.scheme, "https")
    XCTAssertEqual(mapped.users.first?.portraitURL?.host, "himg.bdimg.com")
    XCTAssertEqual(mapped.users.first?.portraitURL?.path, "/sys/portraitn/item/portrait-token")
    XCTAssertNil(mapped.users.first?.portraitURL?.query)
    XCTAssertEqual(mapped.users.last?.localVisibility, .visible)
    XCTAssertNil(mapped.users.last?.portraitURL)
  }

  func testCoreMappingRejectsMismatchedUserAndKindContext() {
    let response = TiebaUserRelationPage(
      requestedUserID: 7,
      kind: .following,
      users: [],
      pagination: TiebaPagination(
        pageSize: 20,
        currentPage: 1,
        totalPages: 0,
        totalCount: 0,
        hasMore: false,
        hasPrevious: false
      ),
      notice: "",
      visibilitySwitch: nil
    )

    XCTAssertThrowsError(
      try TiebaCoreBrowseService.mapUserRelationPage(
        response,
        expectedUserID: 8,
        expectedKind: .following
      )
    )
    XCTAssertThrowsError(
      try TiebaCoreBrowseService.mapUserRelationPage(
        response,
        expectedUserID: 7,
        expectedKind: .followers
      )
    )
  }

  func testInvalidJSONUsesAFeatureNeutralMessage() {
    guard case .unavailable(let message) = TiebaCoreBrowseService.browseError(
      TiebaClientError.invalidJSON
    ) else {
      return XCTFail("Expected a user-facing unavailable error.")
    }

    XCTAssertEqual(message, "贴吧返回了无法识别的数据，接口可能已经更新。")
  }
}

private struct UserRelationRequest: Equatable, Sendable {
  let userID: Int64
  let kind: UserRelationKind
  let page: Int
}

private enum UserRelationStubError: Error {
  case failure
  case unexpectedRequest
  case timeout
}

private enum UserRelationStub: Sendable {
  case value(UserRelationPageData)
  case failure
  case suspended(Int)
}

private actor UserRelationServiceStub: UserProfileService {
  private var stubs: [UserRelationStub]
  private var requests: [UserRelationRequest] = []
  private var suspended: [Int: CheckedContinuation<UserRelationPageData, any Error>] = [:]
  private var startedSuspensions: Set<Int> = []
  private var returnedSuspensions: Set<Int> = []
  private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var returnWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  init(stubs: [UserRelationStub]) {
    self.stubs = stubs
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    throw UserRelationStubError.unexpectedRequest
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  {
    throw UserRelationStubError.unexpectedRequest
  }

  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserReplyPageData
  {
    throw UserRelationStubError.unexpectedRequest
  }

  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
  {
    requests.append(UserRelationRequest(userID: userID, kind: kind, page: page))
    guard !stubs.isEmpty else { throw UserRelationStubError.unexpectedRequest }
    switch stubs.removeFirst() {
    case .value(let response):
      return response
    case .failure:
      throw UserRelationStubError.failure
    case .suspended(let id):
      startedSuspensions.insert(id)
      let startedWaiters = startWaiters.removeValue(forKey: id) ?? []
      startedWaiters.forEach { $0.resume() }
      let response: UserRelationPageData = try await withCheckedThrowingContinuation {
        suspended[id] = $0
      }
      returnedSuspensions.insert(id)
      let returnedWaiters = returnWaiters.removeValue(forKey: id) ?? []
      returnedWaiters.forEach { $0.resume() }
      return response
    }
  }

  func requestSnapshot() -> [UserRelationRequest] { requests }

  func resumeSuspended(id: Int, returning response: UserRelationPageData) -> Bool {
    guard let continuation = suspended.removeValue(forKey: id) else { return false }
    continuation.resume(returning: response)
    return true
  }

  func waitUntilSuspendedRequestStarted(id: Int) async {
    guard !startedSuspensions.contains(id) else { return }
    await withCheckedContinuation { continuation in
      startWaiters[id, default: []].append(continuation)
    }
  }

  func waitUntilSuspendedRequestReturned(id: Int) async {
    guard !returnedSuspensions.contains(id) else { return }
    await withCheckedContinuation { continuation in
      returnWaiters[id, default: []].append(continuation)
    }
  }
}

extension BrowseRelatedUser {
  fileprivate static func fixture(
    id: Int64,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseRelatedUser {
    BrowseRelatedUser(
      id: id,
      username: "account-\(id)",
      displayName: "显示昵称",
      portraitURL: nil,
      introduction: "个人简介",
      localVisibility: localVisibility
    )
  }
}

extension UserRelationPageData {
  fileprivate static func fixture(
    users: [BrowseRelatedUser],
    currentPage: Int = 1,
    totalCount: Int = 0,
    hasMore: Bool = false,
    notice: String = "",
    visibilitySwitch: Int? = nil
  ) -> UserRelationPageData {
    UserRelationPageData(
      users: users,
      currentPage: currentPage,
      totalCount: totalCount,
      hasMore: hasMore,
      notice: notice,
      visibilitySwitch: visibilitySwitch
    )
  }
}

@MainActor
private func waitForRelations(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw UserRelationStubError.timeout }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
