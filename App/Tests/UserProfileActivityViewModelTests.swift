import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserProfileActivityViewModelTests: XCTestCase {
  func testLoadsOnlySelectedActivityAndRetainsBothCompletedPages() async throws {
    let service = ActivityProfileServiceStub()
    let model = UserProfileActivityViewModel(userID: 7, service: service)

    let initialRequests = await service.snapshot()
    XCTAssertEqual(initialRequests, .empty)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }
    let threads = model.profileModel.threads
    var requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1], replies: []))

    model.select(.replies)
    try await waitForActivity { model.repliesModel.state == .loaded }
    let replies = model.repliesModel.replies
    model.select(.threads)
    model.select(.threads)
    model.deactivate()
    model.activate()
    model.select(.replies)

    requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1], replies: [1]))
    XCTAssertEqual(model.profileModel.threads, threads)
    XCTAssertEqual(model.repliesModel.replies, replies)
    XCTAssertEqual(model.selectedSection, .replies)
    XCTAssertTrue(model.isActive)
  }

  func testChangingActivityCancelsOnlyThreadsWhileSharedProfileFinishes() async throws {
    let service = ActivityProfileServiceStub(
      profiles: [.suspended(10)], threads: [.suspended(11), .value(activityThreads(102))])
    addTeardownBlock { await service.finishPending() }
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity { await service.pendingIDs() == [10, 11] }

    model.select(.replies)
    try await waitForActivity { model.repliesModel.state == .loaded }
    XCTAssertEqual(model.profileModel.state, .loading)
    XCTAssertEqual(model.profileModel.threadState, .idle)
    let profileResumed = await service.resumeProfile(10, value: activityProfile("loaded"))
    XCTAssertTrue(profileResumed)
    try await waitForActivity { model.profileModel.profile?.displayName == "loaded" }
    XCTAssertEqual(model.profileModel.state, .loaded)

    model.select(.threads)
    try await waitForActivity { model.profileModel.threads.map(\.id) == [102] }
    let threadsResumed = await service.resumeThreads(11, value: activityThreads(999))
    XCTAssertTrue(threadsResumed)
    try await waitForActivity { await service.returnedIDs().contains(11) }
    await drainActivityTasks()
    let canceledReads = await service.canceledIDs()
    XCTAssertEqual(canceledReads, [11])
    XCTAssertEqual(model.profileModel.threads.map(\.id), [102])
    let requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1, 1], replies: [1]))
  }

  func testDetailReturnRestartsOnlyCanceledSelectedReplyAndRejectsItsLateResult() async throws {
    let service = ActivityProfileServiceStub(
      replies: [.suspended(20), .value(activityReplies(202))])
    addTeardownBlock { await service.finishPending() }
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }
    let profile = model.profileModel.profile
    let threads = model.profileModel.threads
    model.select(.replies)
    try await waitForActivity { await service.pendingIDs().contains(20) }
    model.deactivate()
    XCTAssertEqual(model.repliesModel.state, .idle)
    XCTAssertEqual(model.selectedSection, .replies)
    model.activate()
    try await waitForActivity { model.repliesModel.replies.map(\.postID) == [202] }

    let resumed = await service.resumeReplies(20, value: activityReplies(999))
    XCTAssertTrue(resumed)
    try await waitForActivity { await service.returnedIDs().contains(20) }
    await drainActivityTasks()
    XCTAssertEqual(model.repliesModel.replies.map(\.postID), [202])
    XCTAssertEqual(model.profileModel.profile, profile)
    XCTAssertEqual(model.profileModel.threads, threads)
    let requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1], replies: [1, 1]))
  }

  func testReplyRefreshRetainsProfileAndDoesNotStartHiddenReadsAfterSelectionChanges() async throws
  {
    let service = ActivityProfileServiceStub(
      profiles: [.value(activityProfile("original")), .suspended(30)],
      replies: [.value(activityReplies(201)), .suspended(31)])
    addTeardownBlock { await service.finishPending() }
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }
    let cachedThreads = model.profileModel.threads
    model.select(.replies)
    try await waitForActivity { model.repliesModel.state == .loaded }
    var refreshFinished = false
    let refresh = Task { @MainActor in
      await model.refresh()
      refreshFinished = true
    }
    try await waitForActivity { await service.pendingIDs() == [30, 31] }
    XCTAssertEqual(model.profileModel.profile?.displayName, "original")
    XCTAssertEqual(model.profileModel.state, .loaded)
    XCTAssertTrue(model.profileModel.isRefreshingProfile)
    XCTAssertFalse(refreshFinished)

    model.select(.threads)
    XCTAssertEqual(model.profileModel.threads, cachedThreads)
    let profileResumed = await service.resumeProfile(30, value: activityProfile("updated"))
    XCTAssertTrue(profileResumed)
    try await waitForActivity { model.profileModel.profile?.displayName == "updated" }
    XCTAssertFalse(model.profileModel.isRefreshingProfile)
    XCTAssertFalse(refreshFinished)
    let repliesResumed = await service.resumeReplies(31, value: activityReplies(999))
    XCTAssertTrue(repliesResumed)
    try await waitForActivity { refreshFinished }
    await refresh.value
    XCTAssertTrue(model.repliesModel.replies.isEmpty)
    XCTAssertEqual(model.repliesModel.state, .idle)
    XCTAssertEqual(model.profileModel.threads, cachedThreads)
    let requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 2, threads: [1], replies: [1, 1]))
  }

  func testProfileRefreshFailurePreservesSnapshotAndContentRefreshSucceeds() async throws {
    let service = ActivityProfileServiceStub(
      profiles: [
        .value(activityProfile("cached")), .failure, .value(activityProfile("recovered")),
      ],
      threads: [.value(activityThreads(101)), .value(activityThreads(102))])
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }

    await model.refresh()
    XCTAssertEqual(model.profileModel.state, .loaded)
    XCTAssertEqual(model.profileModel.profile?.displayName, "cached")
    XCTAssertNotNil(model.profileModel.profileRefreshError)
    XCTAssertFalse(model.profileModel.isRefreshingProfile)
    XCTAssertEqual(model.profileModel.threads.map(\.id), [102])

    model.retryProfile()
    try await waitForActivity { model.profileModel.profile?.displayName == "recovered" }
    XCTAssertNil(model.profileModel.profileRefreshError)
    let requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 3, threads: [1, 1], replies: []))
  }

  func testInitialProfileRetryDoesNotRefetchCompletedActivity() async throws {
    let service = ActivityProfileServiceStub(profiles: [.failure, .value(activityProfile("retry"))])
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity {
      guard case .failed = model.profileModel.state else { return false }
      return model.profileModel.threadState == .loaded
    }
    model.retryProfile()
    try await waitForActivity { model.profileModel.state == .loaded }
    let requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 2, threads: [1], replies: []))
    XCTAssertEqual(model.profileModel.threads.map(\.id), [101])
  }

  func testFilterInvalidationReloadsOnlyVisiblePageAndDefersOtherPageUntilSelection() async throws {
    let service = ActivityProfileServiceStub(
      threads: [.value(activityThreads(101)), .value(activityThreads(102))],
      replies: [
        .value(activityReplies(201)), .value(activityReplies(202)), .value(activityReplies(203)),
      ])
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }
    model.select(.replies)
    try await waitForActivity { model.repliesModel.state == .loaded }
    let cachedProfile = model.profileModel.profile

    model.invalidateContentFilters()
    try await waitForActivity { model.repliesModel.replies.map(\.postID) == [202] }
    XCTAssertTrue(model.profileModel.threads.isEmpty)
    XCTAssertEqual(model.profileModel.threadState, .idle)
    XCTAssertEqual(model.profileModel.profile, cachedProfile)
    var requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1], replies: [1, 1]))

    model.select(.threads)
    try await waitForActivity { model.profileModel.threads.map(\.id) == [102] }
    model.deactivate()
    model.invalidateContentFilters()
    model.select(.replies)
    await drainActivityTasks()
    requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1, 1], replies: [1, 1]))
    XCTAssertEqual(model.repliesModel.state, .idle)
    model.activate()
    try await waitForActivity { model.repliesModel.replies.map(\.postID) == [203] }
    XCTAssertTrue(model.profileModel.threads.isEmpty)
    requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1, 1], replies: [1, 1, 1]))
  }

  func testFilterChangeRejectsLateReplyAndDoesNotLetOldTaskClearReplacement() async throws {
    let service = ActivityProfileServiceStub(replies: [.suspended(40), .suspended(41)])
    addTeardownBlock { await service.finishPending() }
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    model.select(.replies)
    model.activate()
    try await waitForActivity {
      let pending = await service.pendingIDs()
      return model.profileModel.state == .loaded && pending.contains(40)
    }
    model.invalidateContentFilters()
    try await waitForActivity { await service.pendingIDs() == [40, 41] }
    let oldResumed = await service.resumeReplies(40, value: activityReplies(999))
    XCTAssertTrue(oldResumed)
    try await waitForActivity { await service.returnedIDs().contains(40) }
    await drainActivityTasks()
    XCTAssertEqual(model.repliesModel.state, .loading)
    XCTAssertTrue(model.repliesModel.replies.isEmpty)

    // If the old task's defer erased the replacement task handle, leaving the
    // page here would fail to cancel request 41 and could publish hidden rows.
    model.select(.threads)
    let replacementResumed = await service.resumeReplies(41, value: activityReplies(998))
    XCTAssertTrue(replacementResumed)
    try await waitForActivity { await service.returnedIDs().contains(41) }
    await drainActivityTasks()
    let canceledReads = await service.canceledIDs()
    XCTAssertEqual(canceledReads, [40, 41])
    XCTAssertTrue(model.repliesModel.replies.isEmpty)
    XCTAssertEqual(model.repliesModel.state, .idle)
  }

  func testInactiveAndAlreadyCanceledRefreshDoNotRead() async throws {
    let service = ActivityProfileServiceStub()
    let model = UserProfileActivityViewModel(userID: 7, service: service)
    await model.refresh()
    model.retryProfile()
    var requests = await service.snapshot()
    XCTAssertEqual(requests, .empty)
    model.activate()
    try await waitForActivity {
      model.profileModel.state == .loaded && model.profileModel.threadState == .loaded
    }
    let task = Task { @MainActor in await model.refresh() }
    task.cancel()
    await task.value
    requests = await service.snapshot()
    XCTAssertEqual(requests, ActivityRequests(profiles: 1, threads: [1], replies: []))
  }
}

private struct ActivityRequests: Equatable, Sendable {
  var profiles = 0
  var threads: [Int] = []
  var replies: [Int] = []
  static let empty = Self()
}

private enum ActivityProfileError: Error {
  case expectedFailure
  case unexpectedRequest
  case timedOut
}

private enum ActivityStub<Value: Sendable>: Sendable {
  case value(Value)
  case failure
  case suspended(Int)
}

private actor ActivityProfileServiceStub: UserProfileService {
  private var profiles: [ActivityStub<BrowseUserProfile>]
  private var threads: [ActivityStub<UserThreadPageData>]
  private var replies: [ActivityStub<UserReplyPageData>]
  private var requests = ActivityRequests()
  private var pendingProfiles: [Int: CheckedContinuation<BrowseUserProfile, any Error>] = [:]
  private var pendingThreads: [Int: CheckedContinuation<UserThreadPageData, any Error>] = [:]
  private var pendingReplies: [Int: CheckedContinuation<UserReplyPageData, any Error>] = [:]
  private var returned: Set<Int> = []
  private var canceled: Set<Int> = []

  init(
    profiles: [ActivityStub<BrowseUserProfile>] = [.value(activityProfile("profile"))],
    threads: [ActivityStub<UserThreadPageData>] = [.value(activityThreads(101))],
    replies: [ActivityStub<UserReplyPageData>] = [.value(activityReplies(201))]
  ) {
    self.profiles = profiles
    self.threads = threads
    self.replies = replies
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    requests.profiles += 1
    guard userID == 7, !profiles.isEmpty else { throw ActivityProfileError.unexpectedRequest }
    switch profiles.removeFirst() {
    case .value(let value): return value
    case .failure: throw ActivityProfileError.expectedFailure
    case .suspended(let id):
      defer { markReturned(id) }
      return try await withCheckedThrowingContinuation { pendingProfiles[id] = $0 }
    }
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws -> UserThreadPageData {
    requests.threads.append(page)
    guard userID == 7, pageSize == 20, !threads.isEmpty else {
      throw ActivityProfileError.unexpectedRequest
    }
    switch threads.removeFirst() {
    case .value(let value): return value
    case .failure: throw ActivityProfileError.expectedFailure
    case .suspended(let id):
      defer { markReturned(id) }
      return try await withCheckedThrowingContinuation { pendingThreads[id] = $0 }
    }
  }

  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws -> UserReplyPageData {
    requests.replies.append(page)
    guard userID == 7, pageSize == 20, !replies.isEmpty else {
      throw ActivityProfileError.unexpectedRequest
    }
    switch replies.removeFirst() {
    case .value(let value): return value
    case .failure: throw ActivityProfileError.expectedFailure
    case .suspended(let id):
      defer { markReturned(id) }
      return try await withCheckedThrowingContinuation { pendingReplies[id] = $0 }
    }
  }

  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
  {
    throw ActivityProfileError.unexpectedRequest
  }

  func snapshot() -> ActivityRequests { requests }
  func pendingIDs() -> Set<Int> {
    Set(pendingProfiles.keys).union(pendingThreads.keys).union(pendingReplies.keys)
  }
  func returnedIDs() -> Set<Int> { returned }
  func canceledIDs() -> Set<Int> { canceled }

  func resumeProfile(_ id: Int, value: BrowseUserProfile) -> Bool {
    guard let pending = pendingProfiles.removeValue(forKey: id) else { return false }
    pending.resume(returning: value)
    return true
  }

  func resumeThreads(_ id: Int, value: UserThreadPageData) -> Bool {
    guard let pending = pendingThreads.removeValue(forKey: id) else { return false }
    pending.resume(returning: value)
    return true
  }

  func resumeReplies(_ id: Int, value: UserReplyPageData) -> Bool {
    guard let pending = pendingReplies.removeValue(forKey: id) else { return false }
    pending.resume(returning: value)
    return true
  }

  func finishPending() {
    for continuation in pendingProfiles.values {
      continuation.resume(throwing: CancellationError())
    }
    for continuation in pendingThreads.values { continuation.resume(throwing: CancellationError()) }
    for continuation in pendingReplies.values { continuation.resume(throwing: CancellationError()) }
    pendingProfiles.removeAll()
    pendingThreads.removeAll()
    pendingReplies.removeAll()
  }

  private func markReturned(_ id: Int) {
    returned.insert(id)
    if Task.isCancelled { canceled.insert(id) }
  }
}

private func activityProfile(_ name: String) -> BrowseUserProfile {
  BrowseUserProfile(
    id: 7, tiebaUID: 70, username: "profile-user", displayName: name,
    portraitURL: nil, largePortraitURL: nil, growthLevel: 8, gender: .female,
    ipLocation: "上海", badges: [], biography: "公开资料", tiebaAge: "10.0",
    threadCount: 3, postCount: 20, followerCount: 100, followingCount: 10,
    followedForumCount: 1, likedForums: [BrowseProfileForum(id: 42, name: "swift")],
    totalAgreeCount: 500, isModerator: false, isVIP: false,
    isVerifiedCreator: false, isBlocked: false)
}

private func activityThreads(_ id: Int64) -> UserThreadPageData {
  UserThreadPageData(
    threads: [
      BrowseThread(
        id: id, forumID: 42, forumName: "swift", title: "thread-\(id)",
        excerpt: "excerpt", authorName: "用户", replyCount: 2, viewCount: 10,
        createdAt: nil, lastReplyAt: nil, contents: [.text("content")])
    ], currentPage: 1, hasMore: false, isHidden: false)
}

private func activityReplies(_ id: Int64) -> UserReplyPageData {
  UserReplyPageData(
    replies: [
      BrowseUserReply(
        threadID: 100, postID: id, forumID: 42, forumName: "swift", threadTitle: "主题",
        excerpt: "reply-\(id)", createdAt: nil, authorID: 7, authorName: "用户",
        authorUsername: "profile-user", target: .post, localVisibility: .visible)
    ], currentPage: 1, hasMore: false, isHidden: false)
}

@MainActor
private func waitForActivity(
  timeout: TimeInterval = 2,
  file: StaticString = #filePath,
  line: UInt = #line,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      XCTFail("Profile activity condition timed out", file: file, line: line)
      throw ActivityProfileError.timedOut
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
}

@MainActor
private func drainActivityTasks() async {
  for _ in 0..<10 { await Task.yield() }
}
