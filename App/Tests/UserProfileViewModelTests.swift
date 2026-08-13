import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserProfileViewModelTests: XCTestCase {
  func testLoadsAnonymousProfileAndPublicThreads() async throws {
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [.fixture(id: 10)],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }

    XCTAssertEqual(viewModel.profile?.id, 7)
    XCTAssertEqual(viewModel.profile?.preferredName, "测试用户")
    XCTAssertEqual(viewModel.profile?.followedForumCount, 5)
    XCTAssertEqual(
      viewModel.profile?.likedForums,
      [BrowseProfileForum(id: 42, name: "swift"), BrowseProfileForum(id: 77, name: "ios")]
    )
    XCTAssertEqual(viewModel.threads.map(\.id), [10])
    XCTAssertFalse(viewModel.isActivityHidden)
    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    XCTAssertEqual(threadRequests, [UserThreadRequest(userID: 7, page: 1)])
  }

  func testThreadFailureLeavesLoadedProfileAvailable() async throws {
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [.failure]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      guard case .failed = viewModel.threadState else { return false }
      return viewModel.state == .loaded
    }

    XCTAssertEqual(viewModel.profile, .fixture)
    XCTAssertEqual(viewModel.state, .loaded)
    guard case .failed = viewModel.threadState else {
      return XCTFail("The public-thread section should expose its own failure")
    }
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  func testRetryingInitialThreadsDoesNotReloadProfile() async throws {
    let replacement = BrowseThread.fixture(id: 11)
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [
        .failure,
        .value(
          UserThreadPageData(
            threads: [replacement],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      guard case .failed = viewModel.threadState else { return false }
      return viewModel.state == .loaded
    }

    viewModel.retryInitialThreads()
    try await waitForProfile {
      viewModel.threadState == .loaded && viewModel.threads == [replacement]
    }

    XCTAssertEqual(viewModel.profile, .fixture)
    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    XCTAssertEqual(
      threadRequests,
      [
        UserThreadRequest(userID: 7, page: 1),
        UserThreadRequest(userID: 7, page: 1),
      ]
    )
  }

  func testProfileFailureRemainsFullPageFailureWhenThreadsLoad() async throws {
    let thread = BrowseThread.fixture(id: 12)
    let service = UserProfileServiceStub(
      profileStubs: [.failure],
      threadStubs: [
        .value(
          UserThreadPageData(
            threads: [thread],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      guard case .failed = viewModel.state else { return false }
      return viewModel.threadState == .loaded
    }

    XCTAssertNil(viewModel.profile)
    guard case .failed = viewModel.state else {
      return XCTFail("Profile failure should remain the full-page state")
    }
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertEqual(viewModel.threads, [thread])
  }

  func testRefreshWaitsForProfileAndThreads() async throws {
    let thread = BrowseThread.fixture(id: 13)
    let service = UserProfileServiceStub(
      profileStubs: [.suspended(1301)],
      threadStubs: [.suspended(1302)]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)
    let completion = UserProfileRefreshCompletionProbe()

    let refreshTask = Task { @MainActor in
      await viewModel.refresh()
      await completion.markCompleted()
    }
    try await waitForProfile {
      let profileRequestCount = await service.profileRequestCount()
      let threadRequestCount = await service.threadRequestCount()
      return profileRequestCount == 1 && threadRequestCount == 1
    }

    let resumedProfile = await service.resumeProfile(id: 1301, returning: .fixture)
    XCTAssertTrue(resumedProfile)
    await service.waitUntilSuspendedRequestReturned(id: 1301)
    try await waitForProfile { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.threadState, .loading)
    let completedBeforeThreads = await completion.isCompleted()
    XCTAssertFalse(completedBeforeThreads)

    let resumedThreads = await service.resumeThreads(
      id: 1302,
      returning: UserThreadPageData(
        threads: [thread],
        currentPage: 1,
        hasMore: false,
        isHidden: false
      )
    )
    XCTAssertTrue(resumedThreads)
    await refreshTask.value

    let completedAfterThreads = await completion.isCompleted()
    XCTAssertTrue(completedAfterThreads)
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertEqual(viewModel.threads, [thread])
  }

  func testCancelAndReentryAfterLoadedPageDoNotReloadEitherResource() async throws {
    let thread = BrowseThread.fixture(id: 14)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [thread],
          currentPage: 1,
          hasMore: false,
          isHidden: false
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }

    viewModel.cancel()
    viewModel.loadIfNeeded()
    await Task.yield()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertEqual(viewModel.profile, .fixture)
    XCTAssertEqual(viewModel.threads, [thread])
    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    XCTAssertEqual(threadRequests, [UserThreadRequest(userID: 7, page: 1)])
  }

  func testCancelAfterProfileLoadsReentersByReloadingOnlyThreads() async throws {
    let oldThread = BrowseThread.fixture(id: 15)
    let replacementThread = BrowseThread.fixture(id: 16)
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [
        .suspended(1501),
        .value(
          UserThreadPageData(
            threads: [replacementThread],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      guard viewModel.state == .loaded else { return false }
      return await service.threadRequestCount() == 1
    }

    viewModel.cancel()
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .idle)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.threadState == .loaded && viewModel.threads == [replacementThread]
    }

    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    XCTAssertEqual(threadRequests.map(\.page), [1, 1])

    let resumed = await service.resumeThreads(
      id: 1501,
      returning: UserThreadPageData(
        threads: [oldThread],
        currentPage: 1,
        hasMore: true,
        isHidden: false
      )
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 1501)
    await Task.yield()

    XCTAssertEqual(viewModel.profile, .fixture)
    XCTAssertEqual(viewModel.threads, [replacementThread])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .loaded)
  }

  func testDisplayableThreadsKeepVisibleAndPlaceholderWithoutRemovingRawThreads() async throws {
    let visible = BrowseThread.fixture(id: 20)
    let placeholder = BrowseThread.fixture(id: 21, localVisibility: .placeholder)
    let hidden = BrowseThread.fixture(id: 22, localVisibility: .hidden)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [visible, placeholder, hidden],
          currentPage: 1,
          hasMore: false,
          isHidden: false
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }

    XCTAssertEqual(viewModel.threads, [visible, placeholder, hidden])
    XCTAssertEqual(viewModel.displayableThreads, [visible, placeholder])
    XCTAssertTrue(viewModel.hasDisplayableThreads)
  }

  func testHiddenRawTailCanTriggerNextPage() async throws {
    let visible = BrowseThread.fixture(id: 30)
    let hiddenTail = BrowseThread.fixture(id: 31, localVisibility: .hidden)
    let next = BrowseThread.fixture(id: 32)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [visible, hiddenTail],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        ),
        2: UserThreadPageData(
          threads: [next],
          currentPage: 2,
          hasMore: false,
          isHidden: false
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    viewModel.loadMoreIfNeeded(current: hiddenTail)

    try await waitForProfile { viewModel.threads.map(\.id) == [30, 31, 32] }
    XCTAssertEqual(viewModel.displayableThreads.map(\.id), [30, 32])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testServerHiddenActivityDoesNotRequestAnotherPageWhenRawThreadsExist() async throws {
    let rawTail = BrowseThread.fixture(id: 35)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [rawTail],
          currentPage: 1,
          hasMore: true,
          isHidden: true
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    viewModel.loadMoreIfNeeded(current: rawTail)

    XCTAssertTrue(viewModel.isActivityHidden)
    XCTAssertEqual(viewModel.threads, [rawTail])
    XCTAssertFalse(viewModel.isLoadingMore)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testLaterServerHiddenPageStopsFurtherPaginationAndRetry() async throws {
    let first = BrowseThread.fixture(id: 36)
    let hiddenPageTail = BrowseThread.fixture(id: 37)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [first],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        ),
        2: UserThreadPageData(
          threads: [hiddenPageTail],
          currentPage: 2,
          hasMore: true,
          isHidden: true
        ),
        3: UserThreadPageData(
          threads: [.fixture(id: 38)],
          currentPage: 3,
          hasMore: false,
          isHidden: false
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForProfile {
      viewModel.threads == [first, hiddenPageTail]
        && viewModel.isActivityHidden
        && !viewModel.isLoadingMore
    }

    XCTAssertTrue(viewModel.hasDisplayableThreads)
    viewModel.loadMoreIfNeeded(current: hiddenPageTail)
    viewModel.retryLoadMore()
    XCTAssertFalse(viewModel.isLoadingMore)
    await Task.yield()

    XCTAssertEqual(viewModel.threads, [first, hiddenPageTail])
    XCTAssertTrue(viewModel.isActivityHidden)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testAllHiddenPagesCanAdvanceUntilVisibleThread() async throws {
    let first = BrowseThread.fixture(id: 40, localVisibility: .hidden)
    let second = BrowseThread.fixture(id: 41, localVisibility: .hidden)
    let visible = BrowseThread.fixture(id: 42)
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [first],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        ),
        2: UserThreadPageData(
          threads: [second],
          currentPage: 2,
          hasMore: true,
          isHidden: false
        ),
        3: UserThreadPageData(
          threads: [visible],
          currentPage: 3,
          hasMore: false,
          isHidden: false
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    XCTAssertFalse(viewModel.hasDisplayableThreads)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { viewModel.threads.map(\.id) == [40, 41] }
    XCTAssertFalse(viewModel.hasDisplayableThreads)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { viewModel.threads.map(\.id) == [40, 41, 42] }
    XCTAssertEqual(viewModel.displayableThreads, [visible])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3])
  }

  func testInitialLoadAndRefreshAdvanceThreadPaginationEpoch() async throws {
    let page = UserThreadPageData(
      threads: [.fixture(id: 50, localVisibility: .hidden)],
      currentPage: 1,
      hasMore: true,
      isHidden: false
    )
    let service = UserProfileServiceStub(profile: .fixture, pages: [1: page])
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    let initialEpoch = viewModel.threadPaginationEpoch
    XCTAssertGreaterThan(initialEpoch, 0)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.threads.map(\.id), [50])
    XCTAssertGreaterThan(viewModel.threadPaginationEpoch, initialEpoch)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testPaginationMergesUniqueThreadsAndStopsOnRepeatedPage() async throws {
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [.fixture(id: 10)],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        ),
        2: UserThreadPageData(
          threads: [.fixture(id: 10), .fixture(id: 11)],
          currentPage: 2,
          hasMore: true,
          isHidden: false
        ),
        3: UserThreadPageData(
          threads: [.fixture(id: 11)],
          currentPage: 3,
          hasMore: true,
          isHidden: false
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded && viewModel.threadState == .loaded
    }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { viewModel.threads.map(\.id) == [10, 11] }

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { await service.threadRequestCount() == 3 && !viewModel.isLoadingMore }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    await Task.yield()

    XCTAssertEqual(viewModel.threads.map(\.id), [10, 11])
    let requestCount = await service.threadRequestCount()
    XCTAssertEqual(requestCount, 3)
  }

  func testContentFilterReloadSupersedesSuspendedInitialResponse() async throws {
    let replacement = BrowseThread.fixture(id: 61, localVisibility: .placeholder)
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [
        .suspended(601),
        .value(
          UserThreadPageData(
            threads: [replacement],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile { await service.threadRequestCount() == 1 }

    viewModel.reloadThreadsAfterContentFilterChange()
    try await waitForProfile { viewModel.threads == [replacement] }

    let resumed = await service.resumeThreads(
      id: 601,
      returning: UserThreadPageData(
        threads: [.fixture(id: 60)],
        currentPage: 1,
        hasMore: true,
        isHidden: false
      )
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 601)
    // The cancelled load checks cancellation immediately after the service call returns.
    await Task.yield()

    XCTAssertEqual(viewModel.threads, [replacement])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertEqual(viewModel.profile, .fixture)
    let profileRequests = await service.profileRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testContentFilterReloadSupersedesSuspendedPaginationResponse() async throws {
    let initialTail = BrowseThread.fixture(id: 70, localVisibility: .hidden)
    let replacement = BrowseThread.fixture(id: 72)
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [
        .value(
          UserThreadPageData(
            threads: [initialTail],
            currentPage: 1,
            hasMore: true,
            isHidden: false
          )
        ),
        .suspended(701),
        .value(
          UserThreadPageData(
            threads: [replacement],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile { viewModel.threads == [initialTail] }
    viewModel.loadMoreIfNeeded(current: initialTail)
    try await waitForProfile {
      await service.threadRequestCount() == 2 && viewModel.isLoadingMore
    }

    viewModel.reloadThreadsAfterContentFilterChange()
    try await waitForProfile { viewModel.threads == [replacement] }

    let resumed = await service.resumeThreads(
      id: 701,
      returning: UserThreadPageData(
        threads: [.fixture(id: 71)],
        currentPage: 2,
        hasMore: false,
        isHidden: false
      )
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 701)
    // The cancelled load checks cancellation immediately after the service call returns.
    await Task.yield()

    XCTAssertEqual(viewModel.threads, [replacement])
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 1])
  }

  func testCancellingPaginationRearmsRawTailAndRetriesSamePage() async throws {
    let first = BrowseThread.fixture(id: 80)
    let second = BrowseThread.fixture(id: 81)
    let service = UserProfileServiceStub(
      profile: .fixture,
      threadStubs: [
        .value(
          UserThreadPageData(
            threads: [first],
            currentPage: 1,
            hasMore: true,
            isHidden: false
          )
        ),
        .suspended(801),
        .value(
          UserThreadPageData(
            threads: [second],
            currentPage: 2,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile { viewModel.threads == [first] }
    let epochBeforeLoadMore = viewModel.threadPaginationEpoch
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForProfile {
      await service.threadRequestCount() == 2 && viewModel.isLoadingMore
    }

    viewModel.cancel()

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertEqual(viewModel.threadState, .loaded)
    XCTAssertGreaterThan(viewModel.threadPaginationEpoch, epochBeforeLoadMore)
    viewModel.loadIfNeeded()
    await Task.yield()
    let requestsAfterReentry = await service.threadRequestSnapshot()
    XCTAssertEqual(requestsAfterReentry.map(\.page), [1, 2])

    viewModel.loadMoreIfNeeded(current: first)
    try await waitForProfile { viewModel.threads == [first, second] }

    let resumed = await service.resumeThreads(
      id: 801,
      returning: UserThreadPageData(
        threads: [second],
        currentPage: 2,
        hasMore: false,
        isHidden: false
      )
    )
    XCTAssertTrue(resumed)
    await service.waitUntilSuspendedRequestReturned(id: 801)
    await Task.yield()

    XCTAssertEqual(viewModel.threads, [first, second])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  func testCancelThenReentryRejectsLateProfileAndThreadResults() async throws {
    let oldThread = BrowseThread.fixture(id: 90)
    let replacementThread = BrowseThread.fixture(id: 91)
    let service = UserProfileServiceStub(
      profileStubs: [
        .suspended(901),
        .value(.replacementFixture),
      ],
      threadStubs: [
        .suspended(902),
        .value(
          UserThreadPageData(
            threads: [replacementThread],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      let profileRequestCount = await service.profileRequestCount()
      let threadRequestCount = await service.threadRequestCount()
      return profileRequestCount == 1 && threadRequestCount == 1
    }

    viewModel.cancel()
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.threadState, .idle)

    viewModel.loadIfNeeded()
    try await waitForProfile {
      viewModel.state == .loaded
        && viewModel.threadState == .loaded
        && viewModel.profile == .replacementFixture
        && viewModel.threads == [replacementThread]
    }

    let resumedProfile = await service.resumeProfile(id: 901, returning: .fixture)
    let resumedThreads = await service.resumeThreads(
      id: 902,
      returning: UserThreadPageData(
        threads: [oldThread],
        currentPage: 1,
        hasMore: true,
        isHidden: false
      )
    )
    XCTAssertTrue(resumedProfile)
    XCTAssertTrue(resumedThreads)
    await service.waitUntilSuspendedRequestReturned(id: 901)
    await service.waitUntilSuspendedRequestReturned(id: 902)
    await Task.yield()

    XCTAssertEqual(viewModel.profile, .replacementFixture)
    XCTAssertEqual(viewModel.threads, [replacementThread])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.threadState, .loaded)
    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7, 7])
    XCTAssertEqual(threadRequests.map(\.page), [1, 1])
  }
}

private struct UserThreadRequest: Equatable, Sendable {
  let userID: Int64
  let page: Int
}

private enum UserProfileStubError: Error {
  case failure
  case missingPage
}

private enum UserProfileStub: Sendable {
  case value(BrowseUserProfile)
  case failure
  case suspended(Int)
}

private enum UserThreadStub: Sendable {
  case value(UserThreadPageData)
  case failure
  case suspended(Int)
}

private actor UserProfileServiceStub: UserProfileService {
  let profile: BrowseUserProfile
  let pages: [Int: UserThreadPageData]
  private var profileStubs: [UserProfileStub]
  private var threadStubs: [UserThreadStub]
  private var profileRequests: [Int64] = []
  private var threadRequests: [UserThreadRequest] = []
  private var pendingProfiles: [Int: CheckedContinuation<BrowseUserProfile, any Error>] = [:]
  private var pendingThreads: [Int: CheckedContinuation<UserThreadPageData, any Error>] = [:]
  private var returnedSuspendedRequests: Set<Int> = []
  private var suspendedReturnWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  init(profile: BrowseUserProfile, pages: [Int: UserThreadPageData]) {
    self.profile = profile
    self.pages = pages
    profileStubs = []
    threadStubs = []
  }

  init(profile: BrowseUserProfile, threadStubs: [UserThreadStub]) {
    self.profile = profile
    pages = [:]
    profileStubs = []
    self.threadStubs = threadStubs
  }

  init(profileStubs: [UserProfileStub], threadStubs: [UserThreadStub]) {
    profile = .fixture
    pages = [:]
    self.profileStubs = profileStubs
    self.threadStubs = threadStubs
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    profileRequests.append(userID)
    if !profileStubs.isEmpty {
      switch profileStubs.removeFirst() {
      case .value(let response):
        return response
      case .failure:
        throw UserProfileStubError.failure
      case .suspended(let identifier):
        let response: BrowseUserProfile = try await withCheckedThrowingContinuation {
          pendingProfiles[identifier] = $0
        }
        markSuspendedRequestReturned(identifier)
        return response
      }
    }
    return profile
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  {
    threadRequests.append(UserThreadRequest(userID: userID, page: page))
    if !threadStubs.isEmpty {
      switch threadStubs.removeFirst() {
      case .value(let response):
        return response
      case .failure:
        throw UserProfileStubError.failure
      case .suspended(let identifier):
        let response: UserThreadPageData = try await withCheckedThrowingContinuation {
          pendingThreads[identifier] = $0
        }
        markSuspendedRequestReturned(identifier)
        return response
      }
    }
    guard let response = pages[page] else { throw UserProfileStubError.missingPage }
    return response
  }

  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserReplyPageData
  {
    UserReplyPageData(
      replies: [],
      currentPage: page,
      hasMore: false,
      isHidden: false
    )
  }

  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
  {
    UserRelationPageData(
      users: [],
      currentPage: page,
      totalCount: 0,
      hasMore: false,
      notice: "",
      visibilitySwitch: nil
    )
  }

  func resumeThreads(id: Int, returning value: UserThreadPageData) -> Bool {
    guard let continuation = pendingThreads.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumeProfile(id: Int, returning value: BrowseUserProfile) -> Bool {
    guard let continuation = pendingProfiles.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func waitUntilSuspendedRequestReturned(id: Int) async {
    guard !returnedSuspendedRequests.contains(id) else { return }
    await withCheckedContinuation { continuation in
      suspendedReturnWaiters[id, default: []].append(continuation)
    }
  }

  func profileRequestSnapshot() -> [Int64] { profileRequests }
  func profileRequestCount() -> Int { profileRequests.count }
  func threadRequestSnapshot() -> [UserThreadRequest] { threadRequests }
  func threadRequestCount() -> Int { threadRequests.count }

  private func markSuspendedRequestReturned(_ id: Int) {
    returnedSuspendedRequests.insert(id)
    let waiters = suspendedReturnWaiters.removeValue(forKey: id) ?? []
    waiters.forEach { $0.resume() }
  }
}

private actor UserProfileRefreshCompletionProbe {
  private var completed = false

  func markCompleted() { completed = true }
  func isCompleted() -> Bool { completed }
}

extension BrowseUserProfile {
  fileprivate static let fixture = makeFixture(displayName: "测试用户")
  fileprivate static let replacementFixture = makeFixture(displayName: "新资料")

  private static func makeFixture(displayName: String) -> BrowseUserProfile {
    BrowseUserProfile(
      id: 7,
      tiebaUID: 70,
      username: "fixture-user",
      displayName: displayName,
      portraitURL: nil,
      largePortraitURL: nil,
      growthLevel: 8,
      gender: .female,
      ipLocation: "上海",
      badges: ["测试印记"],
      biography: "公开简介",
      tiebaAge: "10.0",
      threadCount: 3,
      postCount: 20,
      followerCount: 100,
      followingCount: 10,
      followedForumCount: 5,
      likedForums: [
        BrowseProfileForum(id: 42, name: "swift"),
        BrowseProfileForum(id: 77, name: "ios"),
      ],
      totalAgreeCount: 500,
      isModerator: false,
      isVIP: true,
      isVerifiedCreator: false,
      isBlocked: false
    )
  }
}

extension BrowseThread {
  fileprivate static func fixture(
    id: Int64,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 42,
      forumName: "swift",
      title: "thread-\(id)",
      excerpt: "excerpt-\(id)",
      authorName: "测试用户",
      replyCount: 2,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("content")],
      localVisibility: localVisibility
    )
  }
}

@MainActor
private func waitForProfile(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw UserProfileStubError.missingPage }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
