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

  func testFollowedForumIndexRemainsPartialUntilCompleteSurfaceReachesServerEnd() async throws {
    let revision = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let activeSession = session(
      userID: 7,
      name: "active",
      sessionRevision: revision
    )
    let vault = AccountVaultSpy(
      sessions: [activeSession],
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
    let service = AccountServiceSpy(
      followedPages: [1: .success(firstPage), 2: .success(secondPage)]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.indexState == .partial }
    XCTAssertEqual(viewModel.forums.map(\.id), [1, 2])
    XCTAssertEqual(viewModel.indexState, .partial)
    let initialRequests = await service.followedRequestSnapshot()
    XCTAssertEqual(initialRequests.map(\.page), [1])

    let surfaceID = UUID()
    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState {
      if case .ready = viewModel.indexState { return true }
      return false
    }

    XCTAssertEqual(viewModel.forums.map(\.name), ["one", "two", "three"])
    XCTAssertEqual(
      viewModel.indexState,
      .ready(
        FollowedForumIndexSnapshot(
          lease: FollowedForumsSessionLease(activeSession),
          forumIDs: [1, 2, 3]
        )
      )
    )
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        FollowedRequest(userID: 7, page: 1, pageSize: 50),
        FollowedRequest(userID: 7, page: 2, pageSize: 50),
      ]
    )
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 4)
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
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
    XCTAssertEqual(viewModel.indexState, .signedOut)
    XCTAssertTrue(viewModel.isSignedOut)
    let requests = await service.followedRequestSnapshot()
    XCTAssertTrue(requests.isEmpty)

    viewModel.accountSessionDidChange(loadImmediately: false)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.indexState, .idle)
    XCTAssertFalse(viewModel.isSignedOut)
  }

  func testFollowedForumsServiceFailureDoesNotMarkSignedOut() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let service = AccountServiceSpy(
      followedPages: [
        1: .failure(AccountTestFailure(message: "network unavailable"))
      ]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertEqual(viewModel.state, .failed("network unavailable"))
    XCTAssertEqual(viewModel.indexState, .failed("network unavailable"))
    XCTAssertFalse(viewModel.isSignedOut)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests, [FollowedRequest(userID: 7, page: 1, pageSize: 50)])
  }

  func testCompleteIndexFailureDoesNotPublishPartialIDsAndRetriesSamePage() async throws {
    let revision = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let activeSession = session(
      userID: 7,
      name: "active",
      sessionRevision: revision
    )
    let vault = AccountVaultSpy(sessions: [activeSession], activeUserID: 7)
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let secondPage = FollowedForumPageData(
      forums: [forum(id: 2, name: "two")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(
      followedPages: [
        1: .success(firstPage),
        2: .failure(AccountTestFailure(message: "page two unavailable")),
      ]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState {
      viewModel.indexState == .failed("page two unavailable")
    }

    XCTAssertEqual(viewModel.forums.map(\.id), [1])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.loadMoreError, "page two unavailable")
    if case .ready = viewModel.indexState {
      XCTFail("A failed catalog must not publish a partial followed-forum index")
    }
    let failedRequests = await service.followedRequestSnapshot()
    XCTAssertEqual(failedRequests.map(\.page), [1, 2])

    await service.setFollowedPageResult(.success(secondPage), for: 2)
    viewModel.retryCompleteIndex()
    try await waitForAccountState {
      if case .ready = viewModel.indexState { return true }
      return false
    }

    let retriedRequests = await service.followedRequestSnapshot()
    XCTAssertEqual(retriedRequests.map(\.page), [1, 2, 2])
    XCTAssertEqual(
      viewModel.indexState,
      .ready(
        FollowedForumIndexSnapshot(
          lease: FollowedForumsSessionLease(activeSession),
          forumIDs: [1, 2]
        )
      )
    )
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
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

  func testUnfollowRemovesOnlyTheMatchingAccountPinBeforeReload() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let pins = TransientFollowedForumPinsStore()
    try await pins.setPin(accountID: 7, forumID: 1, forumName: "one")
    try await pins.setPin(accountID: 7, forumID: 2, forumName: "two")
    try await pins.setPin(accountID: 8, forumID: 1, forumName: "one")
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.forumProjection.pinned.count == 2 }

    viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 7, forumID: 1, isFollowed: false)
    )
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2
        && viewModel.state == .loaded
        && viewModel.forumProjection.pinned.map(\.id) == [2]
    }

    let firstAccountPins = try await pins.pins(accountID: 7)
    let secondAccountPins = try await pins.pins(accountID: 8)
    XCTAssertEqual(firstAccountPins.map(\.forumID), [2])
    XCTAssertEqual(secondAccountPins.map(\.forumID), [1])
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

  func testFollowedForumPinsSwitchAccountsWithoutAddingNetworkRequests() async throws {
    let vault = AccountVaultSpy(
      sessions: [
        session(userID: 7, name: "first"),
        session(userID: 8, name: "second"),
      ],
      activeUserID: 7
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      currentPage: 1,
      hasMore: true
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let pins = TransientFollowedForumPinsStore()
    try await pins.setPin(
      accountID: 7,
      forumID: 2,
      forumName: "two",
      pinnedAt: Date(timeIntervalSince1970: 20)
    )
    try await pins.setPin(
      accountID: 8,
      forumID: 1,
      forumName: "one",
      pinnedAt: Date(timeIntervalSince1970: 30)
    )
    try await pins.setPin(
      accountID: 7,
      forumID: 99,
      forumName: "not-loaded",
      pinnedAt: Date(timeIntervalSince1970: 40)
    )
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState {
      viewModel.state == .loaded && viewModel.homeForums.map(\.id) == [2, 1]
    }
    let firstAccountRequests = await service.followedRequestSnapshot()
    XCTAssertEqual(firstAccountRequests.map(\.page), [1])

    try await vault.switchActive(to: 8)
    viewModel.accountSessionDidChange()
    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertTrue(viewModel.followedForumPins.isEmpty)
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2
        && viewModel.state == .loaded
        && viewModel.homeForums.map(\.id) == [1, 2]
    }

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertTrue(viewModel.canLoadNextPage)
  }

  func testDelayedUnfollowForInactiveAccountOnlyCleansThatAccountsPin() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 8, name: "active")],
      activeUserID: 8
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let pins = TransientFollowedForumPinsStore()
    try await pins.setPin(accountID: 7, forumID: 1, forumName: "one")
    try await pins.setPin(accountID: 8, forumID: 1, forumName: "one")
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.forumProjection.pinned.map(\.id) == [1] }

    viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 7, forumID: 1, isFollowed: false)
    )
    try await waitForAccountState {
      guard let oldAccountPins = try? await pins.pins(accountID: 7) else { return false }
      return oldAccountPins.isEmpty
    }

    let currentPins = try await pins.pins(accountID: 8)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(currentPins.map(\.forumID), [1])
    XCTAssertEqual(viewModel.forumProjection.pinned.map(\.id), [1])
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testPinningLoadedForumChangesProjectionWithoutNetworkRequest() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      currentPage: 1,
      hasMore: true
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let pins = TransientFollowedForumPinsStore()
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }

    viewModel.setPinned(forum(id: 2, name: "two"), isPinned: true)
    try await waitForAccountState { viewModel.homeForums.map(\.id) == [2, 1] }

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
    XCTAssertTrue(viewModel.canLoadNextPage)
  }

  func testQueuedPinThenUnpinPersistsInCallOrder() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let target = forum(id: 1, name: "one")
    let page = FollowedForumPageData(
      forums: [target],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let pins = SuspendedFollowedForumPinsRepository(suspendsFirstSet: true)
    addTeardownBlock { _ = await pins.releaseFirstSet() }
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }

    viewModel.setPinned(target, isPinned: true)
    await pins.waitUntilFirstSetStarts()
    viewModel.setPinned(target, isPinned: false)
    let released = await pins.releaseFirstSet()
    XCTAssertTrue(released)
    try await waitForAccountState {
      await pins.mutationSnapshot().count == 2 && !viewModel.isPinned(target)
    }

    let mutations = await pins.mutationSnapshot()
    let finalPins = try await pins.pins(accountID: 7)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(mutations, [
      .pin(accountID: 7, forumID: 1),
      .unpin(accountID: 7, forumID: 1),
    ])
    XCTAssertTrue(finalPins.isEmpty)
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testPinCompletingAfterAccountSwitchCannotPublishIntoNewAccount() async throws {
    let vault = AccountVaultSpy(
      sessions: [
        session(userID: 7, name: "first"),
        session(userID: 8, name: "second"),
      ],
      activeUserID: 7
    )
    let first = forum(id: 1, name: "one")
    let second = forum(id: 2, name: "two")
    let page = FollowedForumPageData(
      forums: [first, second],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let secondAccountPin = try XCTUnwrap(
      FollowedForumPin(
        accountID: 8,
        forumID: 2,
        forumName: "two",
        pinnedAt: Date(timeIntervalSince1970: 20)
      )
    )
    let pins = SuspendedFollowedForumPinsRepository(
      initialPins: [secondAccountPin],
      suspendsFirstSet: true
    )
    addTeardownBlock { _ = await pins.releaseFirstSet() }
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }

    viewModel.setPinned(first, isPinned: true)
    await pins.waitUntilFirstSetStarts()
    try await vault.switchActive(to: 8)
    viewModel.accountSessionDidChange()
    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertTrue(viewModel.followedForumPins.isEmpty)
    let released = await pins.releaseFirstSet()
    XCTAssertTrue(released)
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2
        && viewModel.state == .loaded
        && viewModel.homeForums.map(\.id) == [2, 1]
    }

    let oldAccountPins = try await pins.pins(accountID: 7)
    let currentAccountPins = try await pins.pins(accountID: 8)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(oldAccountPins.map(\.forumID), [1])
    XCTAssertEqual(currentAccountPins.map(\.forumID), [2])
    XCTAssertEqual(viewModel.forumProjection.pinned.map(\.id), [2])
    XCTAssertNil(viewModel.pinOperationError)
    XCTAssertEqual(requests.map(\.userID), [7, 8])
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testUnfollowCleanupCompletingAfterSwitchCannotReloadOrPublishOldAccount() async throws {
    let vault = AccountVaultSpy(
      sessions: [
        session(userID: 7, name: "first"),
        session(userID: 8, name: "second"),
      ],
      activeUserID: 7
    )
    let first = forum(id: 1, name: "one")
    let second = forum(id: 2, name: "two")
    let page = FollowedForumPageData(
      forums: [first, second],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let firstAccountPin = try XCTUnwrap(
      FollowedForumPin(
        accountID: 7,
        forumID: 1,
        forumName: "one",
        pinnedAt: Date(timeIntervalSince1970: 10)
      )
    )
    let secondAccountPin = try XCTUnwrap(
      FollowedForumPin(
        accountID: 8,
        forumID: 2,
        forumName: "two",
        pinnedAt: Date(timeIntervalSince1970: 20)
      )
    )
    let pins = SuspendedFollowedForumPinsRepository(
      initialPins: [firstAccountPin, secondAccountPin],
      suspendsFirstRemove: true
    )
    addTeardownBlock { _ = await pins.releaseFirstRemove() }
    let viewModel = FollowedForumsViewModel(
      service: service,
      vault: vault,
      pinRepository: pins
    )
    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.forumProjection.pinned.map(\.id) == [1] }

    viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 7, forumID: 1, isFollowed: false)
    )
    await pins.waitUntilFirstRemoveStarts()
    try await vault.switchActive(to: 8)
    viewModel.accountSessionDidChange()
    let released = await pins.releaseFirstRemove()
    XCTAssertTrue(released)
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 2
        && viewModel.state == .loaded
        && viewModel.homeForums.map(\.id) == [2, 1]
    }
    await Task.yield()

    let oldAccountPins = try await pins.pins(accountID: 7)
    let currentAccountPins = try await pins.pins(accountID: 8)
    let requests = await service.followedRequestSnapshot()
    XCTAssertTrue(oldAccountPins.isEmpty)
    XCTAssertEqual(currentAccountPins.map(\.forumID), [2])
    XCTAssertEqual(viewModel.forumProjection.pinned.map(\.id), [2])
    XCTAssertNil(viewModel.pinOperationError)
    XCTAssertEqual(requests.map(\.userID), [7, 8])
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testFollowedForumsDiscardFirstPageWhenSessionRevisionChangesDuringRequest() async throws {
    let firstRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let sessionBeforeRequest = session(
      userID: 7,
      name: "before",
      sessionRevision: firstRevision
    )
    let sessionAfterRequest = session(
      userID: 7,
      name: "after",
      sessionRevision: secondRevision
    )
    let vault = AccountVaultSpy(
      sessions: [sessionAfterRequest],
      activeUserID: 7,
      activeSessionScript: [sessionBeforeRequest, sessionAfterRequest]
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "stale")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState {
      await service.followedRequestSnapshot().count == 1 && viewModel.state == .idle
    }

    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.indexState, .idle)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests, [FollowedRequest(userID: 7, page: 1, pageSize: 50)])
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 2)
  }

  func testCompleteIndexDiscardsAutomaticPaginationWhenSameUserRevisionRotates() async throws {
    let firstRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    let secondRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    let firstSession = session(
      userID: 7,
      name: "first",
      sessionRevision: firstRevision
    )
    let rotatedSession = session(
      userID: 7,
      name: "rotated",
      sessionRevision: secondRevision
    )
    let vault = AccountVaultSpy(
      sessions: [rotatedSession],
      activeUserID: 7,
      activeSessionScript: [firstSession, firstSession, firstSession, rotatedSession]
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let secondPage = FollowedForumPageData(
      forums: [forum(id: 2, name: "stale")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(
      followedPages: [1: .success(firstPage), 2: .success(secondPage)]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState {
      let requestCount = await service.followedRequestSnapshot().count
      let activeSessionReads = await vault.activeSessionReadCount()
      return requestCount == 2
        && activeSessionReads == 4
        && viewModel.state == .idle
    }

    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertEqual(viewModel.indexState, .idle)
    XCTAssertFalse(viewModel.isLoadingMore)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
    XCTAssertEqual(requests.map(\.userID), [7, 7])
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
  }

  func testReplacingSuspendedInitialLoadPreventsCancelledTaskFromCallingService() async {
    let vault = SuspendedActiveSessionVault(
      session: session(userID: 7, name: "active")
    )
    let page = FollowedForumPageData(
      forums: [forum(id: 1, name: "stale")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(page)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    let initialRefresh = Task { await viewModel.refresh() }
    await vault.waitUntilActiveSessionRequested()

    viewModel.accountSessionDidChange(loadImmediately: false)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.indexState, .idle)
    let released = await vault.releaseActiveSession()
    XCTAssertTrue(released)
    await initialRefresh.value

    let requests = await service.followedRequestSnapshot()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testMembershipChangeBeforeInitialLeaseInvalidatesSuspendedRequest() async throws {
    let activeSession = session(userID: 7, name: "active")
    let vault = SuspendedActiveSessionReadVault(
      session: activeSession,
      suspendedReadNumber: 1
    )
    addTeardownBlock { _ = await vault.releaseSuspendedRead() }
    let replacement = FollowedForumPageData(
      forums: [forum(id: 2, name: "replacement")],
      currentPage: 1,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(replacement)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    await vault.waitUntilReadIsSuspended()
    viewModel.forumMembershipDidChange(
      ForumMembershipChange(accountID: 7, forumID: 1, isFollowed: true)
    )
    try await waitForAccountState {
      viewModel.state == .loaded && viewModel.forums.map(\.id) == [2]
    }

    let released = await vault.releaseSuspendedRead()
    XCTAssertTrue(released)
    await Task.yield()

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests, [FollowedRequest(userID: 7, page: 1, pageSize: 50)])
    XCTAssertEqual(viewModel.forums.map(\.id), [2])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testFollowedForumsDoNotRequestNextPageWhenLeaseChangedBeforeRequest() async throws {
    let firstRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let secondRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let firstSession = session(
      userID: 7,
      name: "first",
      sessionRevision: firstRevision
    )
    let rotatedSession = session(
      userID: 7,
      name: "rotated",
      sessionRevision: secondRevision
    )
    let vault = AccountVaultSpy(
      sessions: [rotatedSession],
      activeUserID: 7,
      activeSessionScript: [firstSession, firstSession, rotatedSession]
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let service = AccountServiceSpy(followedPages: [1: .success(firstPage)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }
    let surfaceID = UUID()
    viewModel.fullListSurfaceDidAppear(id: surfaceID)
    XCTAssertTrue(viewModel.canLoadNextPage)
    viewModel.loadNextPage()
    try await waitForAccountState {
      await vault.activeSessionReadCount() == 3 && viewModel.state == .idle
    }

    XCTAssertTrue(viewModel.forums.isEmpty)
    XCTAssertEqual(viewModel.indexState, .idle)
    XCTAssertFalse(viewModel.isLoadingMore)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests, [FollowedRequest(userID: 7, page: 1, pageSize: 50)])
    viewModel.fullListSurfaceDidDisappear(id: surfaceID)
  }

  func testFollowedForumsRejectUnexpectedReturnedPageNumber() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let unexpectedPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(followedPages: [1: .success(unexpectedPage)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState {
      if case .failed = viewModel.state { return true }
      return false
    }

    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了异常的关注贴吧页码，请重新加载后再试。")
    )
    XCTAssertEqual(
      viewModel.indexState,
      .failed("贴吧返回了异常的关注贴吧页码，请重新加载后再试。")
    )
    XCTAssertTrue(viewModel.forums.isEmpty)
    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeSessionReads, 2)
  }

  func testCompleteIndexFailsClosedWhenFirstPageIsEmptyButClaimsMore() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let emptyPage = FollowedForumPageData(
      forums: [],
      currentPage: 1,
      hasMore: true
    )
    let service = AccountServiceSpy(followedPages: [1: .success(emptyPage)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState {
      if case .failed = viewModel.indexState { return true }
      return false
    }

    let expectedMessage = "关注贴吧分页未取得进展，请重新加载后再试。"
    XCTAssertEqual(viewModel.indexState, .failed(expectedMessage))
    XCTAssertEqual(viewModel.state, .failed(expectedMessage))
    XCTAssertTrue(viewModel.forums.isEmpty)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
  }

  func testCompleteIndexFailsClosedWhenNextPageOnlyContainsDuplicates() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one"), forum(id: 2, name: "two")],
      currentPage: 1,
      hasMore: true
    )
    let duplicatePage = FollowedForumPageData(
      forums: [forum(id: 2, name: "duplicate")],
      currentPage: 2,
      hasMore: true
    )
    let service = AccountServiceSpy(
      followedPages: [1: .success(firstPage), 2: .success(duplicatePage)]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState {
      if case .failed = viewModel.indexState { return true }
      return false
    }

    let expectedMessage = "关注贴吧分页未取得进展，请重新加载后再试。"
    XCTAssertEqual(viewModel.forums.map(\.name), ["one", "two"])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.indexState, .failed(expectedMessage))
    XCTAssertEqual(viewModel.loadMoreError, expectedMessage)
    XCTAssertFalse(viewModel.canLoadNextPage)
    viewModel.loadNextPage()
    XCTAssertFalse(viewModel.isLoadingMore)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
  }

  func testCompleteIndexFailsClosedAtPageLimitWhenServerClaimsMore() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let pages: [Int: Result<FollowedForumPageData, AccountTestFailure>] = Dictionary(
      uniqueKeysWithValues: (1...FollowedForumsViewModel.maximumCatalogPageCount).map { page in
        (
          page,
          .success(
            FollowedForumPageData(
              forums: [forum(id: Int64(page), name: "forum-\(page)")],
              currentPage: page,
              hasMore: true
            )
          )
        )
      }
    )
    let service = AccountServiceSpy(followedPages: pages)
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState(timeout: 5) {
      if case .failed = viewModel.indexState { return true }
      return false
    }

    let expectedMessage = "关注贴吧数量超过当前安全读取上限，请稍后重新加载。"
    XCTAssertEqual(viewModel.indexState, .failed(expectedMessage))
    XCTAssertEqual(
      viewModel.forums.count,
      FollowedForumsViewModel.maximumCatalogPageCount
    )
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.page),
      Array(1...FollowedForumsViewModel.maximumCatalogPageCount)
    )
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
  }

  func testCompleteIndexFailsClosedAtRetainedForumLimitWhenServerClaimsMore() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let forumsPerPage = 100
    let pageCount = FollowedForumsViewModel.maximumRetainedForums / forumsPerPage
    let pages: [Int: Result<FollowedForumPageData, AccountTestFailure>] = Dictionary(
      uniqueKeysWithValues: (1...pageCount).map { page in
        let firstID = (page - 1) * forumsPerPage + 1
        let forums = (firstID..<(firstID + forumsPerPage)).map { identifier in
          forum(id: Int64(identifier), name: "forum-\(identifier)")
        }
        return (
          page,
          .success(
            FollowedForumPageData(
              forums: forums,
              currentPage: page,
              hasMore: true
            )
          )
        )
      }
    )
    let service = AccountServiceSpy(followedPages: pages)
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.completeIndexSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState(timeout: 5) {
      if case .failed = viewModel.indexState { return true }
      return false
    }

    let expectedMessage = "关注贴吧数量超过当前安全读取上限，请稍后重新加载。"
    XCTAssertEqual(viewModel.indexState, .failed(expectedMessage))
    XCTAssertEqual(viewModel.forums.count, FollowedForumsViewModel.maximumRetainedForums)
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), Array(1...pageCount))
    viewModel.completeIndexSurfaceDidDisappear(id: surfaceID)
  }

  func testFollowedForumsHomeProjectionKeepsFirstSixForumsInOrder() {
    let forums = (1...8).map { forum(id: Int64($0), name: "forum-\($0)") }

    let visibleForums = FollowedForumsHomeProjection.visibleForums(from: forums)

    XCTAssertEqual(FollowedForumsHomeProjection.maximumForumCount, 6)
    XCTAssertEqual(visibleForums, Array(forums.prefix(6)))
  }

  func testFullListRequiresExplicitCommandBeforeLoadingNextPage() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let secondPage = FollowedForumPageData(
      forums: [forum(id: 2, name: "two")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(
      followedPages: [1: .success(firstPage), 2: .success(secondPage)]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let surfaceID = UUID()

    viewModel.fullListSurfaceDidAppear(id: surfaceID)
    try await waitForAccountState { viewModel.state == .loaded }

    XCTAssertTrue(viewModel.canLoadNextPage)
    await Task.yield()
    let requestsBeforeCommand = await service.followedRequestSnapshot()
    XCTAssertTrue(viewModel.canLoadNextPage)
    XCTAssertEqual(requestsBeforeCommand.map(\.page), [1])

    viewModel.loadNextPage()
    try await waitForAccountState { !viewModel.isLoadingMore && viewModel.forums.count == 2 }

    XCTAssertFalse(viewModel.canLoadNextPage)
    let requestsAfterCommand = await service.followedRequestSnapshot()
    XCTAssertEqual(requestsAfterCommand.map(\.page), [1, 2])
    viewModel.fullListSurfaceDidDisappear(id: surfaceID)
  }

  func testExplicitNextPageCommandRequiresAnActiveFullListSurface() async throws {
    let vault = AccountVaultSpy(
      sessions: [session(userID: 7, name: "active")],
      activeUserID: 7
    )
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let service = AccountServiceSpy(followedPages: [1: .success(firstPage)])
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)

    viewModel.loadIfNeeded()
    try await waitForAccountState { viewModel.state == .loaded }
    XCTAssertTrue(viewModel.canLoadNextPage)

    viewModel.loadNextPage()
    await Task.yield()

    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
    XCTAssertFalse(viewModel.isLoadingMore)
  }

  func testFullListSurfaceRegistrationIsIdempotentAndSupportsMultipleSurfaces() {
    let viewModel = FollowedForumsViewModel(
      service: AccountServiceSpy(),
      vault: AccountVaultSpy()
    )
    let firstSurfaceID = UUID()
    let secondSurfaceID = UUID()

    XCTAssertFalse(viewModel.hasActiveFullListSurface)
    viewModel.fullListSurfaceDidAppear(id: firstSurfaceID)
    viewModel.fullListSurfaceDidAppear(id: firstSurfaceID)
    XCTAssertTrue(viewModel.hasActiveFullListSurface)
    viewModel.fullListSurfaceDidDisappear(id: firstSurfaceID)
    XCTAssertFalse(viewModel.hasActiveFullListSurface)
    viewModel.fullListSurfaceDidDisappear(id: firstSurfaceID)
    XCTAssertFalse(viewModel.hasActiveFullListSurface)

    viewModel.fullListSurfaceDidAppear(id: firstSurfaceID)
    viewModel.fullListSurfaceDidAppear(id: secondSurfaceID)
    viewModel.fullListSurfaceDidDisappear(id: firstSurfaceID)
    XCTAssertTrue(viewModel.hasActiveFullListSurface)

    viewModel.fullListSurfaceDidDisappear(id: secondSurfaceID)
    XCTAssertFalse(viewModel.hasActiveFullListSurface)
    viewModel.cancel()
  }

  func testCompleteIndexSurfaceRegistrationIsIdempotentAndStopsAfterLastConsumerLeaves()
    async throws
  {
    let activeSession = session(userID: 7, name: "active")
    let vault = SuspendedActiveSessionReadVault(
      session: activeSession,
      suspendedReadNumber: 3
    )
    addTeardownBlock { _ = await vault.releaseSuspendedRead() }
    let firstPage = FollowedForumPageData(
      forums: [forum(id: 1, name: "one")],
      currentPage: 1,
      hasMore: true
    )
    let secondPage = FollowedForumPageData(
      forums: [forum(id: 2, name: "must-not-load")],
      currentPage: 2,
      hasMore: false
    )
    let service = AccountServiceSpy(
      followedPages: [1: .success(firstPage), 2: .success(secondPage)]
    )
    let viewModel = FollowedForumsViewModel(service: service, vault: vault)
    let firstSurfaceID = UUID()
    let secondSurfaceID = UUID()

    XCTAssertFalse(viewModel.hasActiveCompleteIndexSurface)
    viewModel.completeIndexSurfaceDidAppear(id: firstSurfaceID)
    viewModel.completeIndexSurfaceDidAppear(id: firstSurfaceID)
    viewModel.completeIndexSurfaceDidAppear(id: secondSurfaceID)
    await vault.waitUntilReadIsSuspended()
    XCTAssertEqual(viewModel.forums.map(\.id), [1])
    XCTAssertEqual(viewModel.indexState, .loading)
    XCTAssertTrue(viewModel.hasActiveCompleteIndexSurface)

    viewModel.completeIndexSurfaceDidDisappear(id: firstSurfaceID)
    XCTAssertTrue(viewModel.hasActiveCompleteIndexSurface)
    viewModel.completeIndexSurfaceDidDisappear(id: firstSurfaceID)
    XCTAssertTrue(viewModel.hasActiveCompleteIndexSurface)
    viewModel.completeIndexSurfaceDidDisappear(id: secondSurfaceID)
    XCTAssertFalse(viewModel.hasActiveCompleteIndexSurface)

    let resumed = await vault.releaseSuspendedRead()
    XCTAssertTrue(resumed)
    try await waitForAccountState {
      viewModel.state == .loaded && viewModel.indexState == .partial
    }

    XCTAssertEqual(viewModel.forums.map(\.id), [1])
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testPersonalizedFollowedIndexUsesSelectedInactiveAccountWithoutSwitchingActiveAccount()
    async throws
  {
    let selected = session(userID: 7, name: "selected")
    let active = session(userID: 8, name: "active")
    let vault = AccountVaultSpy(sessions: [selected, active], activeUserID: 8)
    let service = AccountServiceSpy(
      followedPages: [
        1: .success(
          FollowedForumPageData(
            forums: [forum(id: 70, name: "selected-forum")],
            currentPage: 1,
            hasMore: false
          )
        )
      ]
    )
    let viewModel = PersonalizedFollowedForumIndexViewModel(
      service: service,
      vault: vault,
      lookup: vault
    )

    viewModel.setPersona(.account(userID: 7), loadIfNeeded: true)
    try await waitForAccountState {
      if case .ready = viewModel.state { return true }
      return false
    }

    guard case .ready(let snapshot) = viewModel.state else {
      return XCTFail("Expected a complete selected-account index")
    }
    XCTAssertEqual(snapshot.lease, FollowedForumsSessionLease(selected))
    XCTAssertEqual(snapshot.forumIDs, Set<Int64>([70]))
    let requests = await service.followedRequestSnapshot()
    XCTAssertEqual(requests, [FollowedRequest(userID: 7, page: 1, pageSize: 50)])
    let activeAfterLoad = try await vault.activeSession()
    XCTAssertEqual(activeAfterLoad?.id, 8)
  }

  func testPersonalizedFollowedIndexCancelsBeforeTransportWhenPersonaChangesDuringLookup()
    async throws
  {
    let first = session(userID: 7, name: "first")
    let second = session(userID: 8, name: "second")
    let vault = AccountVaultSpy(sessions: [first, second], activeUserID: 8)
    let lookup = SuspendedAccountSessionLookup(session: first)
    let service = AccountServiceSpy()
    let viewModel = PersonalizedFollowedForumIndexViewModel(
      service: service,
      vault: vault,
      lookup: lookup
    )

    viewModel.setPersona(.account(userID: 7), loadIfNeeded: true)
    await lookup.waitUntilRequested()
    viewModel.setPersona(.account(userID: 8), loadIfNeeded: false)
    let resumed = await lookup.resume()
    XCTAssertTrue(resumed)
    try await Task.sleep(nanoseconds: 20_000_000)

    let requests = await service.followedRequestSnapshot()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testPersonalizedPersonaKeepsInactiveSelectionAndFallsBackOnlyAfterConfirmedRemoval()
    async throws
  {
    let suiteName = "AccountViewModelTests.personalized-persona.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    PersonalizedRecommendationPersona.account(userID: 7).persist(defaults: defaults)
    let selected = session(userID: 7, name: "selected")
    let active = session(userID: 8, name: "active")
    let vault = AccountVaultSpy(sessions: [selected, active], activeUserID: 8)
    let viewModel = PersonalizedRecommendationPersonaViewModel(
      vault: vault,
      defaults: defaults
    )

    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.selection, .account(userID: 7))
    XCTAssertEqual(viewModel.selectedAccount?.id, 7)

    try await vault.remove(userID: 7)
    await viewModel.reload()

    XCTAssertEqual(viewModel.selection, .anonymous)
    XCTAssertEqual(
      defaults.string(forKey: AppPreferenceKey.personalizedRecommendationPersona),
      "anonymous"
    )
    let activeAfterReload = try await vault.activeSession()
    XCTAssertEqual(activeAfterReload?.id, 8)
  }

  func testPersonalizedPersonaKeepsPreferenceWhenAccountSummaryReadFails() async throws {
    let suiteName = "AccountViewModelTests.personalized-persona-failure.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let selected = PersonalizedRecommendationPersona.account(userID: 7)
    selected.persist(defaults: defaults)
    let viewModel = PersonalizedRecommendationPersonaViewModel(
      vault: FailingSummaryAccountVault(),
      defaults: defaults
    )

    await viewModel.reload()

    XCTAssertEqual(viewModel.selection, selected)
    XCTAssertEqual(
      defaults.string(forKey: AppPreferenceKey.personalizedRecommendationPersona),
      "account:7"
    )
    guard case .failed = viewModel.state else {
      return XCTFail("Expected the transient vault error to remain visible")
    }
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

private enum FollowedForumPinsMutation: Equatable, Sendable {
  case pin(accountID: Int64, forumID: Int64)
  case unpin(accountID: Int64, forumID: Int64)
}

private actor SuspendedFollowedForumPinsRepository: FollowedForumPinsRepository {
  private var storedPins: [FollowedForumPin]
  private var suspendsFirstSet: Bool
  private var suspendsFirstRemove: Bool
  private var mutations: [FollowedForumPinsMutation] = []
  private var firstSetContinuation: CheckedContinuation<Void, Never>?
  private var firstRemoveContinuation: CheckedContinuation<Void, Never>?
  private var firstSetStarted = false
  private var firstRemoveStarted = false
  private var firstSetWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRemoveWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    initialPins: [FollowedForumPin] = [],
    suspendsFirstSet: Bool = false,
    suspendsFirstRemove: Bool = false
  ) {
    storedPins = initialPins
    self.suspendsFirstSet = suspendsFirstSet
    self.suspendsFirstRemove = suspendsFirstRemove
  }

  func pins(accountID: Int64) async throws -> [FollowedForumPin] {
    storedPins
      .filter { $0.accountID == accountID }
      .sorted {
        if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
        return $0.forumID < $1.forumID
      }
  }

  func setPin(
    accountID: Int64,
    forumID: Int64,
    forumName: String,
    pinnedAt: Date
  ) async throws {
    if suspendsFirstSet {
      suspendsFirstSet = false
      firstSetStarted = true
      let waiters = firstSetWaiters
      firstSetWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { firstSetContinuation = $0 }
    }
    guard
      let pin = FollowedForumPin(
        accountID: accountID,
        forumID: forumID,
        forumName: forumName,
        pinnedAt: pinnedAt
      )
    else { throw FollowedForumPinsStoreError.invalidForum }
    storedPins.removeAll { $0.key == pin.key }
    storedPins.append(pin)
    mutations.append(.pin(accountID: accountID, forumID: forumID))
  }

  func removePin(accountID: Int64, forumID: Int64) async throws {
    if suspendsFirstRemove {
      suspendsFirstRemove = false
      firstRemoveStarted = true
      let waiters = firstRemoveWaiters
      firstRemoveWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { firstRemoveContinuation = $0 }
    }
    storedPins.removeAll { $0.accountID == accountID && $0.forumID == forumID }
    mutations.append(.unpin(accountID: accountID, forumID: forumID))
  }

  func waitUntilFirstSetStarts() async {
    if firstSetStarted { return }
    await withCheckedContinuation { firstSetWaiters.append($0) }
  }

  func waitUntilFirstRemoveStarts() async {
    if firstRemoveStarted { return }
    await withCheckedContinuation { firstRemoveWaiters.append($0) }
  }

  func releaseFirstSet() -> Bool {
    guard let continuation = firstSetContinuation else { return false }
    firstSetContinuation = nil
    continuation.resume()
    return true
  }

  func releaseFirstRemove() -> Bool {
    guard let continuation = firstRemoveContinuation else { return false }
    firstRemoveContinuation = nil
    continuation.resume()
    return true
  }

  func mutationSnapshot() -> [FollowedForumPinsMutation] { mutations }
}

private actor AccountServiceSpy: AccountService {
  private let validation: Result<ValidatedAccount, AccountTestFailure>
  private var followedPages: [Int: Result<FollowedForumPageData, AccountTestFailure>]
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

  func setFollowedPageResult(
    _ result: Result<FollowedForumPageData, AccountTestFailure>,
    for page: Int
  ) {
    followedPages[page] = result
  }

  func followedRequestSnapshot() -> [FollowedRequest] { followedRequests }
}

private actor AccountVaultSpy: AccountVault, AccountSessionLookup {
  private var sessions: [Int64: StoredAccountSession]
  private var activeUserID: Int64?
  private var activeSessionScript: [StoredAccountSession?]
  private var activeReads = 0

  init(
    sessions: [StoredAccountSession] = [],
    activeUserID: Int64? = nil,
    activeSessionScript: [StoredAccountSession?] = []
  ) {
    self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    self.activeUserID = activeUserID
    self.activeSessionScript = activeSessionScript
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
    if !activeSessionScript.isEmpty {
      return activeSessionScript.removeFirst()
    }
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

private actor SuspendedActiveSessionReadVault: AccountVault {
  private let storedSession: StoredAccountSession
  private let suspendedReadNumber: Int
  private var activeReads = 0
  private var suspendedReadContinuation: CheckedContinuation<StoredAccountSession?, Never>?
  private var suspendedReadWasRequested = false
  private var suspendedReadWaiters: [CheckedContinuation<Void, Never>] = []

  init(session: StoredAccountSession, suspendedReadNumber: Int) {
    storedSession = session
    self.suspendedReadNumber = suspendedReadNumber
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    guard activeReads == suspendedReadNumber else { return storedSession }
    return await withCheckedContinuation { continuation in
      suspendedReadContinuation = continuation
      suspendedReadWasRequested = true
      let waiters = suspendedReadWaiters
      suspendedReadWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}

  func waitUntilReadIsSuspended() async {
    if suspendedReadWasRequested { return }
    await withCheckedContinuation { continuation in
      suspendedReadWaiters.append(continuation)
    }
  }

  func releaseSuspendedRead() -> Bool {
    guard let continuation = suspendedReadContinuation else { return false }
    suspendedReadContinuation = nil
    continuation.resume(returning: storedSession)
    return true
  }
}

private actor SuspendedActiveSessionVault: AccountVault {
  private let storedSession: StoredAccountSession
  private var activeSessionContinuation: CheckedContinuation<StoredAccountSession?, Never>?
  private var activeSessionWasRequested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []

  init(session: StoredAccountSession) {
    storedSession = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    return await withCheckedContinuation { continuation in
      activeSessionContinuation = continuation
      activeSessionWasRequested = true
      let waiters = requestWaiters
      requestWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}

  func waitUntilActiveSessionRequested() async {
    if activeSessionWasRequested { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func releaseActiveSession() -> Bool {
    guard let continuation = activeSessionContinuation else { return false }
    activeSessionContinuation = nil
    continuation.resume(returning: storedSession)
    return true
  }
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

private actor FailingSummaryAccountVault: AccountVault {
  func accountSummaries() async throws -> [AccountSummary] {
    throw AccountTestFailure(message: "vault unavailable")
  }

  func activeSession() async throws -> StoredAccountSession? { nil }
  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}
}

private actor SuspendedAccountSessionLookup: AccountSessionLookup {
  private let storedSession: StoredAccountSession
  private var continuation: CheckedContinuation<StoredAccountSession?, Never>?
  private var requested = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(session: StoredAccountSession) {
    storedSession = session
  }

  func session(userID: Int64) async throws -> StoredAccountSession? {
    requested = true
    let pendingWaiters = waiters
    waiters.removeAll()
    pendingWaiters.forEach { $0.resume() }
    return await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilRequested() async {
    if requested { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func resume() -> Bool {
    guard let continuation else { return false }
    self.continuation = nil
    continuation.resume(returning: storedSession)
    return true
  }
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
