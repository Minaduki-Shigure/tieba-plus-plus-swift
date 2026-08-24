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

  func testOwnFollowingManagementRequiresFullCredentialsWithoutPerRowRelationshipReads()
    async throws
  {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let first = BrowseRelatedUser.fixture(id: 80)
    let second = BrowseRelatedUser.fixture(id: 81)
    let browseService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [first, second], totalCount: 2))]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [first, second], totalCount: 2))]
    )
    let vault = UserRelationVaultSpy(session: active)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.followControlState(for: first), .followed(isEnabled: true))
    XCTAssertEqual(viewModel.followControlState(for: second), .followed(isEnabled: true))
    let publicRequests = await browseService.requestSnapshot()
    let authenticatedRequests = await accountService.followingRequestsSnapshot()
    XCTAssertTrue(publicRequests.isEmpty)
    XCTAssertEqual(authenticatedRequests.map(\.page), [1])
    let relationshipReads = await accountService.readRequestCount()
    XCTAssertEqual(relationshipReads, 0)
  }

  func testManagementControlsStayHiddenOutsideExactFullCredentialOwnerFollowingList()
    async throws
  {
    let target = BrowseRelatedUser.fixture(id: 90)
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let incomplete = relationSession(
      userID: 7,
      revision: relationUUID(2),
      hasFullCredentials: false
    )
    let accountService = UserRelationAccountServiceSpy()
    let otherUser = UserRelationsViewModel(
      userID: 8,
      kind: .following,
      service: UserRelationServiceStub(stubs: [.value(.fixture(users: [target]))]),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )
    let followers = UserRelationsViewModel(
      userID: 7,
      kind: .followers,
      service: UserRelationServiceStub(stubs: [.value(.fixture(users: [target]))]),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )
    let incompleteOwner = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: [.value(.fixture(users: [target]))]),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: incomplete),
        service: accountService
      )
    )
    let viewModels = [otherUser, followers, incompleteOwner]

    for viewModel in viewModels {
      viewModel.loadIfNeeded()
      await viewModel.resolveManagementAccessIfNeeded()
    }
    try await waitForRelations { viewModels.allSatisfy { $0.state == .loaded } }

    for viewModel in viewModels {
      XCTAssertEqual(viewModel.followControlState(for: target), .hidden)
      XCTAssertNil(viewModel.followPrompt(for: target))
      XCTAssertFalse(viewModel.canSelectFollowingFilter)
    }
    let relationshipReads = await accountService.readRequestCount()
    let relationshipWrites = await accountService.writeRequestCount()
    XCTAssertEqual(relationshipReads, 0)
    XCTAssertEqual(relationshipWrites, 0)
  }

  func testUnfollowKeepsLoadedRowAndAllowsOneWriteRefollowInPlace() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let target = BrowseRelatedUser.fixture(id: 91, concernState: .mutual)
    let browseService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [target], totalCount: 1))]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [target], totalCount: 1))],
      writes: [
        .value(relationData(userID: 7, targetUserID: 91, isFollowed: false)),
        .value(relationData(userID: 7, targetUserID: 91, isFollowed: true)),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    XCTAssertTrue(viewModel.canSelectFollowingFilter)
    viewModel.selectFollowingFilter(.mutual)
    XCTAssertEqual(viewModel.followingFilter, .mutual)
    XCTAssertEqual(viewModel.displayableUsers, [target])
    let unfollowPrompt = try XCTUnwrap(viewModel.followPrompt(for: target))

    viewModel.setFollowed(unfollowPrompt)
    try await waitForRelations {
      viewModel.mutatingUserID == nil && viewModel.followedState(for: target) == false
    }

    XCTAssertEqual(viewModel.users, [target])
    XCTAssertEqual(viewModel.displayableUsers, [target])
    XCTAssertEqual(viewModel.followingFilter, .mutual)
    XCTAssertEqual(viewModel.totalCount, 1)
    XCTAssertEqual(viewModel.followControlState(for: target), .notFollowed(isEnabled: true))
    var writes = await accountService.writeRequestsSnapshot()
    XCTAssertEqual(
      writes,
      [
        UserRelationWriteRequest(
          userID: 7,
          sessionRevision: active.sessionRevision,
          targetUserID: 91,
          isFollowed: false
        )
      ]
    )

    let refollowPrompt = try XCTUnwrap(viewModel.followPrompt(for: target))
    XCTAssertTrue(refollowPrompt.targetFollowed)
    viewModel.setFollowed(refollowPrompt)
    try await waitForRelations {
      viewModel.mutatingUserID == nil && viewModel.followedState(for: target) == true
    }

    XCTAssertEqual(viewModel.users, [target])
    XCTAssertEqual(viewModel.totalCount, 1)
    writes = await accountService.writeRequestsSnapshot()
    XCTAssertEqual(writes.map(\.isFollowed), [false, true])
    let relationshipReads = await accountService.readRequestCount()
    XCTAssertEqual(relationshipReads, 0)
  }

  func testSameUserRevisionChangeRejectsOldPromptWithoutWriting() async throws {
    let oldSession = relationSession(userID: 7, revision: relationUUID(1), credential: "a")
    let newSession = relationSession(userID: 7, revision: relationUUID(2), credential: "b")
    let target = BrowseRelatedUser.fixture(id: 92)
    let browseService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [target], totalCount: 1))]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [target], totalCount: 1)),
        .value(.fixture(users: [target], totalCount: 1)),
      ]
    )
    let vault = UserRelationVaultSpy(session: oldSession)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    let stalePrompt = try XCTUnwrap(viewModel.followPrompt(for: target))

    await vault.replaceActive(with: newSession)
    let token = viewModel.invalidateForAccountSessionChange()
    await viewModel.resolveManagementAccessAfterSessionChange(ifCurrent: token)
    viewModel.setFollowed(stalePrompt)
    await Task.yield()

    XCTAssertEqual(viewModel.managementLease, AccountSessionLease(newSession))
    XCTAssertEqual(viewModel.followControlState(for: target), .followed(isEnabled: true))
    let writes = await accountService.writeRequestCount()
    XCTAssertEqual(writes, 0)
  }

  func testHiddenAndPlaceholderForgedPromptsNeverWrite() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let lease = AccountSessionLease(active)
    let hidden = BrowseRelatedUser.fixture(id: 97, localVisibility: .hidden)
    let placeholder = BrowseRelatedUser.fixture(id: 98, localVisibility: .placeholder)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [hidden])),
        .value(.fixture(users: [placeholder])),
      ]
    )
    let hiddenViewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: [.value(.fixture(users: [hidden]))]),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )
    let placeholderViewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: [.value(.fixture(users: [placeholder]))]),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    for viewModel in [hiddenViewModel, placeholderViewModel] {
      viewModel.loadIfNeeded()
      await viewModel.resolveManagementAccessIfNeeded()
    }
    try await waitForRelations {
      hiddenViewModel.state == .loaded && placeholderViewModel.state == .loaded
    }

    hiddenViewModel.setFollowed(
      UserRelationFollowPrompt(
        user: hidden,
        lease: lease,
        previouslyFollowed: true,
        targetFollowed: false
      )
    )
    placeholderViewModel.setFollowed(
      UserRelationFollowPrompt(
        user: placeholder,
        lease: lease,
        previouslyFollowed: true,
        targetFollowed: false
      )
    )
    await Task.yield()

    XCTAssertEqual(hiddenViewModel.followControlState(for: hidden), .hidden)
    XCTAssertEqual(placeholderViewModel.followControlState(for: placeholder), .hidden)
    let writes = await accountService.writeRequestCount()
    XCTAssertEqual(writes, 0)
  }

  func testManagementResolverRetriesCancellationAndTransientVaultFailureOnRefresh()
    async throws
  {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let target = BrowseRelatedUser.fixture(id: 99)
    let browseService = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [target], totalCount: 1)),
        .value(.fixture(users: [target], totalCount: 1)),
      ]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [target], totalCount: 1))]
    )
    let vault = UserRelationVaultSpy(
      session: active,
      activeSessionScripts: [
        .cancelled,
        .failure("vault temporarily unavailable"),
        .value(active),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    await viewModel.resolveManagementAccessIfNeeded()
    XCTAssertNil(viewModel.managementLease)

    await viewModel.refresh()
    XCTAssertNil(viewModel.managementLease)
    XCTAssertEqual(viewModel.followControlState(for: target), .hidden)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.managementLease, AccountSessionLease(active))
    XCTAssertEqual(viewModel.followControlState(for: target), .followed(isEnabled: true))
    let activeReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeReads, 4)
    let relationshipReads = await accountService.readRequestCount()
    XCTAssertEqual(relationshipReads, 0)
  }

  func testLateMutationAfterAccountSwitchCannotPublishStateOrNotification() async throws {
    let oldSession = relationSession(userID: 7, revision: relationUUID(1))
    let newSession = relationSession(userID: 8, revision: relationUUID(2))
    let target = BrowseRelatedUser.fixture(id: 93)
    let browseService = UserRelationServiceStub(
      stubs: [.value(.fixture(users: [target], totalCount: 1))]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [target], totalCount: 1))],
      writes: [
        .suspended(
          id: 701,
          value: relationData(userID: 7, targetUserID: 93, isFollowed: false)
        )
      ]
    )
    addTeardownBlock { await accountService.releaseAll() }
    let vault = UserRelationVaultSpy(session: oldSession)
    let recorder = UserRelationNotificationRecorder()
    let notificationToken = NotificationCenter.default.addObserver(
      forName: .userRelationshipDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = UserRelationshipChange(notification),
        change.sessionRevision == oldSession.sessionRevision,
        change.targetUserID == target.id
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(notificationToken) }
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.setFollowed(try XCTUnwrap(viewModel.followPrompt(for: target)))
    try await waitForRelations { await accountService.hasSuspendedWrite(id: 701) }

    await vault.replaceActive(with: newSession)
    let resumed = await accountService.resumeSuspendedWrite(id: 701)
    XCTAssertTrue(resumed)
    try await waitForRelations {
      viewModel.mutatingUserID == nil && viewModel.state == .loaded
    }

    XCTAssertEqual(viewModel.users, [target])
    XCTAssertEqual(viewModel.followControlState(for: target), .hidden)
    XCTAssertNil(viewModel.relationshipMutationError)
    XCTAssertTrue(recorder.snapshot().isEmpty)
    let writes = await accountService.writeRequestCount()
    XCTAssertEqual(writes, 1)
  }

  func testLateSecondPageCannotOverwriteConfirmedRelationshipOverride() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let target = BrowseRelatedUser.fixture(id: 94)
    let next = BrowseRelatedUser.fixture(id: 95)
    let browseService = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [target], totalCount: 2, hasMore: true)),
        .suspended(702),
      ]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [target], totalCount: 2, hasMore: true)),
        .suspended(702),
      ],
      writes: [.value(relationData(userID: 7, targetUserID: 94, isFollowed: false))]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: target)
    try await waitForRelations { await accountService.hasSuspendedFollowing(id: 702) }

    viewModel.setFollowed(try XCTUnwrap(viewModel.followPrompt(for: target)))
    try await waitForRelations {
      viewModel.mutatingUserID == nil && viewModel.followedState(for: target) == false
    }
    let resumed = await accountService.resumeSuspendedFollowing(
      id: 702,
      returning: .fixture(
        users: [target, next],
        currentPage: 2,
        totalCount: 2,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitForRelations { !viewModel.isLoadingMore }

    XCTAssertEqual(viewModel.users, [target, next])
    XCTAssertEqual(viewModel.followControlState(for: target), .notFollowed(isEnabled: true))
    let writes = await accountService.writeRequestCount()
    XCTAssertEqual(writes, 1)
  }

  func testFailedMutationLocksOnlyRowUntilSuccessfulRefresh() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let target = BrowseRelatedUser.fixture(id: 96)
    let browseService = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [target], totalCount: 1)),
        .value(.fixture(users: [target], totalCount: 1)),
      ]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [target], totalCount: 1)),
        .value(.fixture(users: [target], totalCount: 1)),
      ],
      writes: [.failure("write failed")]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.setFollowed(try XCTUnwrap(viewModel.followPrompt(for: target)))
    try await waitForRelations { viewModel.mutatingUserID == nil }

    XCTAssertTrue(viewModel.lockedRelationshipUserIDs.contains(target.id))
    XCTAssertEqual(viewModel.followControlState(for: target), .followed(isEnabled: false))
    XCTAssertNil(viewModel.followPrompt(for: target))
    XCTAssertNotNil(viewModel.relationshipMutationError)

    await viewModel.refresh()

    XCTAssertFalse(viewModel.lockedRelationshipUserIDs.contains(target.id))
    XCTAssertEqual(viewModel.followControlState(for: target), .followed(isEnabled: true))
    XCTAssertNotNil(viewModel.followPrompt(for: target))
    let writes = await accountService.writeRequestCount()
    XCTAssertEqual(writes, 1)
  }

  func testRefreshDuringMutationWaitsForWriteAndQueuedFirstPage() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let target = BrowseRelatedUser.fixture(id: 100)
    let browseService = UserRelationServiceStub(
      stubs: [
        .value(.fixture(users: [target], totalCount: 1)),
        .suspended(703),
      ]
    )
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [target], totalCount: 1)),
        .suspended(703),
      ],
      writes: [
        .suspended(
          id: 704,
          value: relationData(userID: 7, targetUserID: 100, isFollowed: false)
        )
      ]
    )
    addTeardownBlock { await accountService.releaseAll() }
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: browseService,
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    await viewModel.resolveManagementAccessIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.setFollowed(try XCTUnwrap(viewModel.followPrompt(for: target)))
    try await waitForRelations { await accountService.hasSuspendedWrite(id: 704) }

    let refreshProbe = UserRelationAsyncCompletionProbe()
    let refreshTask = Task { @MainActor in
      await refreshProbe.markStarted()
      await viewModel.refresh()
      await refreshProbe.markCompleted()
    }
    try await waitForRelations { await refreshProbe.hasStarted() }
    await Task.yield()

    var refreshCompleted = await refreshProbe.hasCompleted()
    XCTAssertFalse(refreshCompleted, "Refresh returned while the relationship write was suspended")
    var requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
    let publicRequests = await browseService.requestSnapshot()
    XCTAssertTrue(publicRequests.isEmpty)

    let writeResumed = await accountService.resumeSuspendedWrite(id: 704)
    XCTAssertTrue(writeResumed)
    try await waitForRelations { await accountService.hasSuspendedFollowing(id: 703) }

    refreshCompleted = await refreshProbe.hasCompleted()
    XCTAssertFalse(refreshCompleted, "Refresh returned before its queued first page completed")
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])

    let pageResumed = await accountService.resumeSuspendedFollowing(
      id: 703,
      returning: .fixture(users: [target], totalCount: 1)
    )
    XCTAssertTrue(pageResumed)
    await refreshTask.value

    refreshCompleted = await refreshProbe.hasCompleted()
    XCTAssertTrue(refreshCompleted)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.users, [target])
    XCTAssertNil(viewModel.mutatingUserID)
  }

  func testMutualFilterRequiresCompleteAuthenticatedMetadataButKeepsManagementAvailable()
    async throws
  {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let known = BrowseRelatedUser.fixture(id: 110, concernState: .mutual)
    let incompleteUsers = [
      BrowseRelatedUser.fixture(id: 111),
      BrowseRelatedUser.fixture(id: 112, concernState: .unknown(9)),
    ]

    for incomplete in incompleteUsers {
      let accountService = UserRelationAccountServiceSpy(
        followingPages: [.value(.fixture(users: [known, incomplete], totalCount: 2))]
      )
      let viewModel = UserRelationsViewModel(
        userID: 7,
        kind: .following,
        service: UserRelationServiceStub(stubs: []),
        accountAccess: AccountAccess(
          vault: UserRelationVaultSpy(session: active),
          service: accountService
        )
      )

      viewModel.loadIfNeeded()
      try await waitForRelations { viewModel.state == .loaded }

      XCTAssertFalse(viewModel.concernMetadataIsComplete)
      XCTAssertFalse(viewModel.canSelectFollowingFilter)
      XCTAssertEqual(viewModel.followControlState(for: known), .followed(isEnabled: true))
      XCTAssertEqual(viewModel.displayableUsers, [known, incomplete])
      viewModel.selectFollowingFilter(.mutual)
      XCTAssertEqual(viewModel.followingFilter, .all)
    }
  }

  func testEmptyAuthenticatedPageHasCompleteMetadataAndNoRelationsPresentation() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [], totalCount: 0))]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }

    XCTAssertTrue(viewModel.concernMetadataIsComplete)
    XCTAssertTrue(viewModel.canSelectFollowingFilter)
    XCTAssertEqual(viewModel.emptyPresentation, .noRelations)
  }

  func testCompleteRefreshRestoresFilterAvailabilityAfterIncompleteSnapshot() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let mutual = BrowseRelatedUser.fixture(id: 113, concernState: .mutual)
    let missing = BrowseRelatedUser.fixture(id: 114)
    let complete = BrowseRelatedUser.fixture(id: 114, concernState: .following)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [mutual, missing], totalCount: 2)),
        .value(.fixture(users: [mutual, complete], totalCount: 2)),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    XCTAssertFalse(viewModel.canSelectFollowingFilter)

    await viewModel.refresh()

    XCTAssertTrue(viewModel.concernMetadataIsComplete)
    XCTAssertTrue(viewModel.canSelectFollowingFilter)
    XCTAssertEqual(viewModel.followingFilter, .all)
  }

  func testCompletePageWithoutMutualShowsAuthoritativeNoMutualState() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let oneWay = BrowseRelatedUser.fixture(id: 115, concernState: .following)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [.value(.fixture(users: [oneWay], totalCount: 1))]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)

    XCTAssertEqual(viewModel.followingFilter, .mutual)
    XCTAssertEqual(viewModel.emptyPresentation, .noMutual)
    XCTAssertTrue(viewModel.displayableUsers.isEmpty)
  }

  func testMutualFilterScansFiveRawPagesThenRequiresExplicitContinuation() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let initial = BrowseRelatedUser.fixture(id: 120, concernState: .following)
    let skipped = (121...125).map {
      BrowseRelatedUser.fixture(id: Int64($0), concernState: .notFollowing)
    }
    let mutual = BrowseRelatedUser.fixture(id: 126, concernState: .mutual)
    var pages = [
      UserRelationStub.value(
        .fixture(users: [initial], currentPage: 1, totalCount: 99, hasMore: true)
      )
    ]
    pages += skipped.enumerated().map { offset, user in
      .value(
        .fixture(
          users: [user],
          currentPage: offset + 2,
          totalCount: 99,
          hasMore: true
        )
      )
    }
    pages.append(
      .value(.fixture(users: [mutual], currentPage: 7, totalCount: 99, hasMore: false))
    )
    let accountService = UserRelationAccountServiceSpy(followingPages: pages)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    try await waitForRelations { viewModel.mutualScanIsPaused && !viewModel.isLoadingMore }

    XCTAssertEqual(viewModel.followingFilter, .mutual)
    XCTAssertTrue(viewModel.displayableUsers.isEmpty)
    XCTAssertEqual(viewModel.emptyPresentation, .mutualScanPaused)
    XCTAssertEqual(viewModel.totalCount, 99)
    var requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6])

    let pausedRawTail = try XCTUnwrap(viewModel.users.last)
    viewModel.loadMoreIfNeeded(current: pausedRawTail)
    await Task.yield()
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6])

    viewModel.continueMutualScan()
    try await waitForRelations { viewModel.displayableUsers == [mutual] }

    XCTAssertFalse(viewModel.mutualScanIsPaused)
    XCTAssertEqual(viewModel.users, [initial] + skipped + [mutual])
    XCTAssertEqual(viewModel.emptyPresentation, .none)
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6, 7])
  }

  func testExistingMutualStillPausesAfterFiveRawPagesWithoutNewVisibleMutual() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let initialMutual = BrowseRelatedUser.fixture(id: 170, concernState: .mutual)
    let skipped = (171...175).map {
      BrowseRelatedUser.fixture(id: Int64($0), concernState: .following)
    }
    let nextMutual = BrowseRelatedUser.fixture(id: 176, concernState: .mutual)
    var pages = [
      UserRelationStub.value(
        .fixture(users: [initialMutual], currentPage: 1, totalCount: 99, hasMore: true)
      )
    ]
    pages += skipped.enumerated().map { offset, user in
      .value(
        .fixture(
          users: [user],
          currentPage: offset + 2,
          totalCount: 99,
          hasMore: true
        )
      )
    }
    pages.append(
      .value(.fixture(users: [nextMutual], currentPage: 7, totalCount: 99, hasMore: false))
    )
    let accountService = UserRelationAccountServiceSpy(followingPages: pages)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    viewModel.loadMoreIfNeeded(current: initialMutual)
    try await waitForRelations { viewModel.mutualScanIsPaused && !viewModel.isLoadingMore }

    XCTAssertEqual(viewModel.displayableUsers, [initialMutual])
    XCTAssertEqual(viewModel.emptyPresentation, .none)
    var requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6])

    let pausedRawTail = try XCTUnwrap(viewModel.users.last)
    viewModel.loadMoreIfNeeded(current: pausedRawTail)
    await Task.yield()
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6])

    viewModel.continueMutualScan()
    try await waitForRelations { viewModel.displayableUsers == [initialMutual, nextMutual] }
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3, 4, 5, 6, 7])
    XCTAssertFalse(viewModel.mutualScanIsPaused)
  }

  func testMutualScanFailureDoesNotPresentAFalseSearchingState() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let oneWay = BrowseRelatedUser.fixture(id: 180, concernState: .following)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [oneWay], totalCount: 2, hasMore: true)),
        .failure,
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    try await waitForRelations { viewModel.loadMoreError != nil && !viewModel.isLoadingMore }

    XCTAssertTrue(viewModel.displayableUsers.isEmpty)
    XCTAssertEqual(viewModel.emptyPresentation, .none)
    let requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testFollowingFilterCannotChangeDuringAnInFlightContinuation() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let first = BrowseRelatedUser.fixture(id: 185, concernState: .following)
    let second = BrowseRelatedUser.fixture(id: 186, concernState: .following)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [first], totalCount: 2, hasMore: true)),
        .suspended(803),
      ]
    )
    addTeardownBlock { await accountService.releaseAll() }
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForRelations { await accountService.hasSuspendedFollowing(id: 803) }

    viewModel.selectFollowingFilter(.mutual)
    XCTAssertEqual(viewModel.followingFilter, .all)

    let resumed = await accountService.resumeSuspendedFollowing(
      id: 803,
      returning: .fixture(users: [second], currentPage: 2, totalCount: 2, hasMore: false)
    )
    XCTAssertTrue(resumed)
    try await waitForRelations { viewModel.users == [first, second] }

    viewModel.selectFollowingFilter(.mutual)
    XCTAssertEqual(viewModel.followingFilter, .mutual)
  }

  func testIncompleteMetadataOnLaterPageStopsScanAndFallsBackToAll() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let initial = BrowseRelatedUser.fixture(id: 130, concernState: .following)
    let unknown = BrowseRelatedUser.fixture(id: 131, concernState: .unknown(3))
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [initial], totalCount: 20, hasMore: true)),
        .value(.fixture(users: [unknown], currentPage: 2, totalCount: 20, hasMore: true)),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    XCTAssertTrue(viewModel.canSelectFollowingFilter)
    viewModel.selectFollowingFilter(.mutual)
    try await waitForRelations { !viewModel.isLoadingMore }

    XCTAssertFalse(viewModel.concernMetadataIsComplete)
    XCTAssertFalse(viewModel.canSelectFollowingFilter)
    XCTAssertEqual(viewModel.followingFilter, .all)
    XCTAssertFalse(viewModel.mutualScanIsPaused)
    XCTAssertEqual(viewModel.displayableUsers, [initial, unknown])
    XCTAssertEqual(viewModel.followControlState(for: initial), .followed(isEnabled: true))
    let requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testHiddenLoadedMutualUsesLocalFilterEmptyStateWithoutAutomaticScan() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let hiddenMutual = BrowseRelatedUser.fixture(
      id: 135,
      concernState: .mutual,
      localVisibility: .hidden
    )
    let rawTail = BrowseRelatedUser.fixture(id: 136, concernState: .following)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [hiddenMutual, rawTail], totalCount: 3, hasMore: true)),
        .value(
          .fixture(
            users: [.fixture(id: 137, concernState: .mutual)],
            currentPage: 2,
            totalCount: 3,
            hasMore: false
          )
        ),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)

    XCTAssertTrue(viewModel.hasLoadedMutual)
    XCTAssertTrue(viewModel.displayableUsers.isEmpty)
    XCTAssertEqual(viewModel.emptyPresentation, .locallyFiltered)
    XCTAssertFalse(viewModel.mutualScanIsPaused)
    viewModel.loadMoreIfNeeded(current: rawTail)
    await Task.yield()
    let requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testMutualScanStopsWhenItFirstFindsOnlyALocallyHiddenMutual() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let oneWay = BrowseRelatedUser.fixture(id: 138, concernState: .following)
    let hiddenMutual = BrowseRelatedUser.fixture(
      id: 139,
      concernState: .mutual,
      localVisibility: .hidden
    )
    let laterVisibleMutual = BrowseRelatedUser.fixture(id: 140, concernState: .mutual)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [oneWay], totalCount: 3, hasMore: true)),
        .value(
          .fixture(
            users: [hiddenMutual],
            currentPage: 2,
            totalCount: 3,
            hasMore: true
          )
        ),
        .value(
          .fixture(
            users: [laterVisibleMutual],
            currentPage: 3,
            totalCount: 3,
            hasMore: false
          )
        ),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    try await waitForRelations { !viewModel.isLoadingMore && viewModel.hasLoadedMutual }

    XCTAssertTrue(viewModel.displayableUsers.isEmpty)
    XCTAssertEqual(viewModel.emptyPresentation, .locallyFiltered)
    XCTAssertFalse(viewModel.mutualScanIsPaused)
    var requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])

    let hiddenRawTail = try XCTUnwrap(viewModel.users.last)
    viewModel.loadMoreIfNeeded(current: hiddenRawTail)
    await Task.yield()
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testMutualFilterUsesRawTailForPagination() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let mutual = BrowseRelatedUser.fixture(id: 140, concernState: .mutual)
    let rawTail = BrowseRelatedUser.fixture(id: 141, concernState: .following)
    let next = BrowseRelatedUser.fixture(id: 142, concernState: .mutual)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [mutual, rawTail], totalCount: 3, hasMore: true)),
        .value(.fixture(users: [next], currentPage: 2, totalCount: 3, hasMore: false)),
      ]
    )
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: UserRelationVaultSpy(session: active),
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    XCTAssertEqual(viewModel.displayableUsers, [mutual])

    viewModel.loadMoreIfNeeded(current: mutual)
    await Task.yield()
    var requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])

    viewModel.loadMoreIfNeeded(current: rawTail)
    try await waitForRelations { viewModel.displayableUsers == [mutual, next] }
    requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testLateAuthenticatedFirstPageCannotCrossSessionRevision() async throws {
    let oldSession = relationSession(userID: 7, revision: relationUUID(1), credential: "a")
    let newSession = relationSession(userID: 7, revision: relationUUID(2), credential: "b")
    let stale = BrowseRelatedUser.fixture(id: 150, concernState: .mutual)
    let replacement = BrowseRelatedUser.fixture(id: 151, concernState: .mutual)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .suspended(801),
        .value(.fixture(users: [replacement], totalCount: 1)),
      ]
    )
    addTeardownBlock { await accountService.releaseAll() }
    let vault = UserRelationVaultSpy(session: oldSession)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { await accountService.hasSuspendedFollowing(id: 801) }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange(reloadIfActive: true)
    try await waitForRelations { viewModel.users == [replacement] }

    let resumed = await accountService.resumeSuspendedFollowing(
      id: 801,
      returning: .fixture(users: [stale], totalCount: 1)
    )
    XCTAssertTrue(resumed)
    await Task.yield()

    XCTAssertEqual(viewModel.users, [replacement])
    XCTAssertEqual(viewModel.managementLease, AccountSessionLease(newSession))
    XCTAssertEqual(viewModel.followingFilter, .all)
    let requests = await accountService.followingRequestsSnapshot()
    XCTAssertEqual(requests.map(\.sessionRevision), [oldSession.sessionRevision, newSession.sessionRevision])
  }

  func testPostRequestLeaseValidationRejectsRevisionChangeWithoutNotification() async throws {
    let oldSession = relationSession(userID: 7, revision: relationUUID(1), credential: "a")
    let newSession = relationSession(userID: 7, revision: relationUUID(2), credential: "b")
    let stale = BrowseRelatedUser.fixture(id: 155, concernState: .mutual)
    let accountService = UserRelationAccountServiceSpy(followingPages: [.suspended(802)])
    addTeardownBlock { await accountService.releaseAll() }
    let vault = UserRelationVaultSpy(session: oldSession)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(vault: vault, service: accountService)
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { await accountService.hasSuspendedFollowing(id: 802) }
    await vault.replaceActive(with: newSession)
    let resumed = await accountService.resumeSuspendedFollowing(
      id: 802,
      returning: .fixture(users: [stale], totalCount: 1)
    )
    XCTAssertTrue(resumed)
    try await waitForRelations {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertTrue(viewModel.users.isEmpty)
    XCTAssertNil(viewModel.managementLease)
    XCTAssertEqual(viewModel.followingFilter, .all)
    XCTAssertFalse(viewModel.canSelectFollowingFilter)
  }

  func testSuccessfulRefreshPreservesMutualFilterForSameLease() async throws {
    let active = relationSession(userID: 7, revision: relationUUID(1))
    let revised = relationSession(userID: 7, revision: relationUUID(2), credential: "r")
    let first = BrowseRelatedUser.fixture(id: 160, concernState: .mutual)
    let refreshed = BrowseRelatedUser.fixture(id: 161, concernState: .mutual)
    let accountService = UserRelationAccountServiceSpy(
      followingPages: [
        .value(.fixture(users: [first], totalCount: 2)),
        .value(.fixture(users: [refreshed], totalCount: 2)),
      ]
    )
    let vault = UserRelationVaultSpy(session: active)
    let viewModel = UserRelationsViewModel(
      userID: 7,
      kind: .following,
      service: UserRelationServiceStub(stubs: []),
      accountAccess: AccountAccess(
        vault: vault,
        service: accountService
      )
    )

    viewModel.loadIfNeeded()
    try await waitForRelations { viewModel.state == .loaded }
    viewModel.selectFollowingFilter(.mutual)
    await viewModel.refresh()

    XCTAssertEqual(viewModel.followingFilter, .mutual)
    XCTAssertEqual(viewModel.displayableUsers, [refreshed])
    XCTAssertEqual(viewModel.totalCount, 2)

    await vault.replaceActive(with: revised)
    viewModel.accountSessionDidChange(reloadIfActive: false)
    XCTAssertEqual(viewModel.followingFilter, .all)
    XCTAssertTrue(viewModel.users.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.managementLease)
  }

  func testRelatedUserFilteringCoversIdentityNamesAndIntroductionWithoutDroppingRows() {
    let cases: [(ContentFilterRule, BrowseRelatedUser)] = [
      (
        .user(id: 70, name: "", list: .block),
        .fixture(id: 70, concernState: .mutual)
      ),
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
          introduction: "公开简介",
          concernState: .mutual
        ),
        TiebaRelatedUser(
          id: 81,
          username: "account-81",
          displayName: "普通昵称",
          portrait: "file:///private/avatar.png",
          introduction: "普通简介",
          concernState: .unknown(Int64.max)
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
    XCTAssertEqual(mapped.users.first?.concernState, .mutual)
    XCTAssertEqual(mapped.users.first?.localVisibility, .placeholder)
    XCTAssertEqual(mapped.users.first?.portraitURL?.scheme, "https")
    XCTAssertEqual(mapped.users.first?.portraitURL?.host, "himg.bdimg.com")
    XCTAssertEqual(mapped.users.first?.portraitURL?.path, "/sys/portraitn/item/portrait-token")
    XCTAssertNil(mapped.users.first?.portraitURL?.query)
    XCTAssertEqual(mapped.users.last?.localVisibility, .visible)
    XCTAssertEqual(mapped.users.last?.concernState, .unknown(Int64.max))
    XCTAssertNil(mapped.users.last?.portraitURL)

    for rawValue in [Int64.min, -1, 3, Int64.max] {
      let state = BrowseRelatedUserConcernState(rawValue: rawValue)
      XCTAssertEqual(state, .unknown(rawValue))
      XCTAssertEqual(state.rawValue, rawValue)
    }
    XCTAssertEqual(BrowseRelatedUserConcernState(rawValue: 2), .mutual)
    XCTAssertNotEqual(BrowseRelatedUserConcernState(rawValue: 1), .mutual)
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

  private func relationSession(
    userID: Int64,
    revision: UUID,
    credential: Character = "s",
    hasFullCredentials: Bool = true
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: credential, count: 192),
      stoken: hasFullCredentials ? String(repeating: credential, count: 64) : nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func relationData(
    userID: Int64,
    targetUserID: Int64,
    isFollowed: Bool
  ) -> UserRelationshipData {
    UserRelationshipData(
      userID: userID,
      targetUserID: targetUserID,
      isFollowed: isFollowed
    )
  }

  private func relationUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct UserRelationRequest: Equatable, Sendable {
  let userID: Int64
  let kind: UserRelationKind
  let page: Int
}

private struct AuthenticatedUserRelationRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
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

private struct UserRelationWriteRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
  let targetUserID: Int64
  let isFollowed: Bool
}

private enum UserRelationWriteScript: Sendable {
  case value(UserRelationshipData)
  case failure(String)
  case suspended(id: Int, value: UserRelationshipData)
}

private enum UserRelationVaultReadScript: Sendable {
  case value(StoredAccountSession?)
  case failure(String)
  case cancelled
}

private struct UserRelationAccountFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private final class UserRelationNotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = [UserRelationshipChange]()

  func record(_ change: UserRelationshipChange) {
    lock.withLock { changes.append(change) }
  }

  func snapshot() -> [UserRelationshipChange] {
    lock.withLock { changes }
  }
}

private actor UserRelationAsyncCompletionProbe {
  private var started = false
  private var completed = false

  func markStarted() { started = true }
  func markCompleted() { completed = true }
  func hasStarted() -> Bool { started }
  func hasCompleted() -> Bool { completed }
}

private actor UserRelationAccountServiceSpy: AccountService {
  private var followingPages: [UserRelationStub]
  private var writes: [UserRelationWriteScript]
  private var followingRequests: [AuthenticatedUserRelationRequest] = []
  private var readRequests: [UserRelationWriteRequest] = []
  private var writeRequests: [UserRelationWriteRequest] = []
  private var suspendedFollowing:
    [Int: CheckedContinuation<UserRelationPageData, any Error>] = [:]
  private var suspendedWrites:
    [Int: (CheckedContinuation<UserRelationshipData, Never>, UserRelationshipData)] = [:]

  init(
    followingPages: [UserRelationStub] = [],
    writes: [UserRelationWriteScript] = []
  ) {
    self.followingPages = followingPages
    self.writes = writes
  }

  func ownFollowing(
    session: StoredAccountSession,
    page: Int
  ) async throws -> UserRelationPageData {
    followingRequests.append(
      AuthenticatedUserRelationRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        page: page
      )
    )
    guard !followingPages.isEmpty else {
      throw UserRelationAccountFailure(message: "Unexpected own-following request")
    }
    switch followingPages.removeFirst() {
    case .value(let page):
      return page
    case .failure:
      throw UserRelationAccountFailure(message: "Own-following request failed")
    case .suspended(let id):
      return try await withCheckedThrowingContinuation { suspendedFollowing[id] = $0 }
    }
  }

  func userRelationship(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserRelationshipData {
    readRequests.append(
      UserRelationWriteRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        targetUserID: targetUserID,
        isFollowed: false
      )
    )
    throw UserRelationAccountFailure(message: "Unexpected relationship read")
  }

  func setUserFollowed(
    session: StoredAccountSession,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> UserRelationshipData {
    writeRequests.append(
      UserRelationWriteRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        targetUserID: targetUserID,
        isFollowed: isFollowed
      )
    )
    guard !writes.isEmpty else {
      throw UserRelationAccountFailure(message: "Unexpected relationship write")
    }
    switch writes.removeFirst() {
    case .value(let relationship):
      return relationship
    case .failure(let message):
      throw UserRelationAccountFailure(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedWrites[id] = ($0, value) }
    }
  }

  func readRequestCount() -> Int { readRequests.count }
  func followingRequestsSnapshot() -> [AuthenticatedUserRelationRequest] { followingRequests }
  func writeRequestCount() -> Int { writeRequests.count }
  func writeRequestsSnapshot() -> [UserRelationWriteRequest] { writeRequests }
  func hasSuspendedWrite(id: Int) -> Bool { suspendedWrites[id] != nil }
  func hasSuspendedFollowing(id: Int) -> Bool { suspendedFollowing[id] != nil }

  func resumeSuspendedFollowing(id: Int, returning page: UserRelationPageData) -> Bool {
    guard let continuation = suspendedFollowing.removeValue(forKey: id) else { return false }
    continuation.resume(returning: page)
    return true
  }

  func resumeSuspendedWrite(id: Int) -> Bool {
    guard let (continuation, value) = suspendedWrites.removeValue(forKey: id) else {
      return false
    }
    continuation.resume(returning: value)
    return true
  }

  func releaseAll() {
    let pendingFollowing = Array(suspendedFollowing.values)
    suspendedFollowing.removeAll()
    pendingFollowing.forEach {
      $0.resume(throwing: UserRelationAccountFailure(message: "Released suspended following"))
    }
    let pending = Array(suspendedWrites.values)
    suspendedWrites.removeAll()
    pending.forEach { continuation, value in continuation.resume(returning: value) }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw UserRelationAccountFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw UserRelationAccountFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw UserRelationAccountFailure(message: "Unexpected forum membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw UserRelationAccountFailure(message: "Unexpected forum account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw UserRelationAccountFailure(message: "Unexpected forum mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw UserRelationAccountFailure(message: "Unexpected check-in request")
  }
}

private actor UserRelationVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var activeSessionScripts: [UserRelationVaultReadScript]
  private var activeSessionReads = 0

  init(
    session: StoredAccountSession?,
    activeSessionScripts: [UserRelationVaultReadScript] = []
  ) {
    self.session = session
    self.activeSessionScripts = activeSessionScripts
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeSessionReads += 1
    guard !activeSessionScripts.isEmpty else { return session }
    switch activeSessionScripts.removeFirst() {
    case .value(let session):
      return session
    case .failure(let message):
      throw UserRelationAccountFailure(message: message)
    case .cancelled:
      throw CancellationError()
    }
  }

  func activeSessionReadCount() -> Int { activeSessionReads }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
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
    concernState: BrowseRelatedUserConcernState? = nil,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseRelatedUser {
    BrowseRelatedUser(
      id: id,
      username: "account-\(id)",
      displayName: "显示昵称",
      portraitURL: nil,
      introduction: "个人简介",
      concernState: concernState,
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
