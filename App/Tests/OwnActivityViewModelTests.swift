import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class OwnActivityViewModelTests: XCTestCase {
  func testSignedOutAndIncompleteSessionsNeverCallActivityService() async throws {
    for session in [nil, ownActivitySession(stoken: nil)] {
      let service = OwnActivityServiceSpy([])
      let model = OwnActivityViewModel(
        kind: .threads, service: service, vault: OwnActivityVault(session))
      await model.refresh()
      let requests = await service.requests
      XCTAssertTrue(requests.isEmpty)
      XCTAssertEqual(model.isSignedOut, session == nil)
      XCTAssertNil(model.accountUserID)
      XCTAssertTrue(model.threads.isEmpty)
    }
  }

  func testThreadsPaginationDeduplicatesAndStopsOnRepeatedOrEmptyPage() async throws {
    let service = OwnActivityServiceSpy([
      .value(activityPage(ids: [1, 1, 2], page: 1, more: true)),
      .value(activityPage(ids: [2, 3], page: 2, more: true)),
      .value(activityPage(ids: [2, 3], page: 3, more: true)),
    ])
    let model = OwnActivityViewModel(
      kind: .threads, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    XCTAssertEqual(model.threads.map(\.id), [1, 2])
    XCTAssertTrue(model.hasMore)
    model.loadMore()
    model.loadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertEqual(model.threads.map(\.id), [1, 2, 3])
    model.loadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertFalse(model.hasMore)
    model.loadMore()
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.page), [1, 2, 3])
    XCTAssertEqual(model.accountUserID, 7)
  }

  func testRepliesPreservePostAndCommentNavigationAndDeduplicateCompositeIdentity() async throws {
    let replies = [
      activityReply(thread: 1, post: 2), activityReply(thread: 2, post: 2, target: .comment),
    ]
    let page = OwnActivityPageData(
      accountUserID: 7, threads: [], replies: replies + [replies[0]], currentPage: 1,
      hasMore: false, isHidden: false)
    let service = OwnActivityServiceSpy([.value(page)])
    let model = OwnActivityViewModel(
      kind: .replies, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    XCTAssertEqual(model.replies, replies)
    XCTAssertEqual(model.replies.map(\.target), [.post, .comment])
    XCTAssertTrue(model.threads.isEmpty)
    let requests = await service.requests
    XCTAssertEqual(requests.map(\.kind), [.replies])
  }

  func testExpandedReplyPageCanExceedRequestSizeAndStopsAtRetentionLimit() async throws {
    let expanded = (1...2_005).map { activityReply(thread: 1, post: Int64($0)) }
    let page = OwnActivityPageData(
      accountUserID: 7, threads: [], replies: expanded, currentPage: 1, hasMore: true,
      isHidden: false)
    let service = OwnActivityServiceSpy([.value(page)])
    let model = OwnActivityViewModel(
      kind: .replies, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    XCTAssertEqual(model.state, .loaded)
    XCTAssertEqual(model.replies.count, OwnActivityViewModel.maximumRetainedItems)
    XCTAssertEqual(model.replies.first?.postID, 1)
    XCTAssertEqual(model.replies.last?.postID, 2_000)
    XCTAssertFalse(model.hasMore)
    model.loadMore()
    let requests = await service.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testReloadsCoalesceAndAccountChangeClearsImmediatelyAndIgnoresLateSuccess() async throws {
    let initial = ownActivitySession()
    let replacement = ownActivitySession(userID: 8)
    let service = OwnActivityServiceSpy([
      .suspended(1, .success(activityPage(ids: [1]))),
      .value(activityPage(ids: [8], userID: 8)),
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = OwnActivityVault(initial)
    let model = OwnActivityViewModel(kind: .threads, service: service, vault: vault)
    model.loadIfNeeded()
    model.reload()
    model.loadIfNeeded()
    try await wait { await service.waiting(1) }
    var requests = await service.requests
    XCTAssertEqual(requests.count, 1)
    await vault.replace(replacement)
    model.accountSessionDidChange()
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertNil(model.accountUserID)
    try await wait { model.accountUserID == 8 }
    await service.release(1)
    await drain()
    XCTAssertEqual(model.threads.map(\.id), [8])
    requests = await service.requests
    XCTAssertEqual(requests.map(\.userID), [7, 8])
  }

  func testSameUIDLoginRotationRejectsLateFailureWithoutNotification() async throws {
    let service = OwnActivityServiceSpy([
      .suspended(1, .failure(OwnActivityTestFailure(message: "old private error")))
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = OwnActivityVault(ownActivitySession())
    let model = OwnActivityViewModel(kind: .threads, service: service, vault: vault)
    model.loadIfNeeded()
    try await wait { await service.waiting(1) }
    await vault.replace(ownActivitySession())
    await service.release(1)
    try await wait { model.state != .loading }
    XCTAssertEqual(model.state, .failed("登录账户已变化，请重新加载本人动态。"))
    XCTAssertNil(model.accountUserID)
    XCTAssertNil(model.loadMoreError)
    XCTAssertTrue(model.threads.isEmpty)
  }

  func testAccountChangeBeforeNextPageRejectsRequestAndClearsPriorPrivateRows() async throws {
    let service = OwnActivityServiceSpy([.value(activityPage(ids: [1], more: true))])
    let vault = OwnActivityVault(ownActivitySession())
    let model = OwnActivityViewModel(kind: .threads, service: service, vault: vault)
    await model.refresh()
    await vault.replace(ownActivitySession())
    model.loadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertNil(model.accountUserID)
    XCTAssertEqual(model.state, .failed("登录账户已变化，请重新加载本人动态。"))
    let requests = await service.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testPaginationFailureKeepsBoundRowsAndExplicitRetryUsesSamePage() async throws {
    let service = OwnActivityServiceSpy([
      .value(activityPage(ids: [1], more: true)), .failure("try again"),
      .value(activityPage(ids: [2], page: 2)),
    ])
    let model = OwnActivityViewModel(
      kind: .threads, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    model.loadMore()
    try await wait { model.loadMoreError != nil }
    XCTAssertEqual(model.threads.map(\.id), [1])
    XCTAssertEqual(model.state, .loaded)
    model.loadMore()
    var requests = await service.requests
    XCTAssertEqual(requests.count, 2)
    model.retryLoadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertEqual(model.threads.map(\.id), [1, 2])
    XCTAssertNil(model.loadMoreError)
    requests = await service.requests
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  func testPostRequestVaultFailureClearsExistingSnapshotEvenOnServiceError() async throws {
    let service = OwnActivityServiceSpy([
      .value(activityPage(ids: [1], more: true)), .failure("private error"),
    ])
    let vault = OwnActivityVault(ownActivitySession())
    let model = OwnActivityViewModel(kind: .threads, service: service, vault: vault)
    await model.refresh()
    await vault.failRead(4)
    model.loadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertNil(model.accountUserID)
    XCTAssertEqual(model.state, .failed("vault unavailable"))
  }

  func testHiddenReplyResponseClearsPreviousRowsAndStopsPagination() async throws {
    let initial = OwnActivityPageData(
      accountUserID: 7, threads: [], replies: [activityReply(thread: 1, post: 2)], currentPage: 1,
      hasMore: true, isHidden: false)
    let hidden = OwnActivityPageData(
      accountUserID: 7, threads: [], replies: [], currentPage: 2, hasMore: true, isHidden: true)
    let service = OwnActivityServiceSpy([.value(initial), .value(hidden)])
    let model = OwnActivityViewModel(
      kind: .replies, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    model.loadMore()
    try await wait { !model.isLoadingMore }
    XCTAssertTrue(model.isHidden)
    XCTAssertFalse(model.hasMore)
    XCTAssertTrue(model.replies.isEmpty)
    XCTAssertEqual(model.state, .loaded)
  }

  func testMalformedIdentityPageAndWrongKindCannotPublishResults() async throws {
    let wrongKind = OwnActivityPageData(
      accountUserID: 7, threads: [], replies: [activityReply(thread: 1, post: 1)], currentPage: 1,
      hasMore: false, isHidden: false)
    for response in [
      activityPage(ids: [1], userID: 8), activityPage(ids: [1], page: 2), activityPage(ids: [0]),
      wrongKind,
    ] {
      let service = OwnActivityServiceSpy([.value(response)])
      let model = OwnActivityViewModel(
        kind: .threads, service: service, vault: OwnActivityVault(ownActivitySession()))
      await model.refresh()
      guard case .failed = model.state else { return XCTFail("Expected response rejection") }
      XCTAssertTrue(model.threads.isEmpty)
      XCTAssertTrue(model.replies.isEmpty)
      XCTAssertNil(model.accountUserID)
    }
  }

  func testSuspendClearsRowsAndLateUncooperativeResponseCannotRestoreThem() async throws {
    let service = OwnActivityServiceSpy([
      .value(activityPage(ids: [1], more: true)),
      .suspended(1, .success(activityPage(ids: [2], page: 2))),
    ])
    addTeardownBlock { await service.releaseAll() }
    let model = OwnActivityViewModel(
      kind: .threads, service: service, vault: OwnActivityVault(ownActivitySession()))
    await model.refresh()
    model.loadMore()
    try await wait { await service.waiting(1) }
    model.suspend()
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertNil(model.accountUserID)
    await service.release(1)
    await drain()
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertEqual(model.state, .idle)
  }

  private func wait(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await condition()) {
      guard Date() < deadline else { throw OwnActivityTestFailure(message: "timed out") }
      await Task.yield()
    }
  }

  private func drain() async { for _ in 0..<50 { await Task.yield() } }
}

private struct OwnActivityTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private struct OwnActivityRequest: Equatable, Sendable {
  let userID: Int64
  let revision: UUID
  let kind: OwnActivityKind
  let page: Int
  let pageSize: Int
}

private enum OwnActivityScript: Sendable {
  case value(OwnActivityPageData)
  case failure(String)
  case suspended(Int, Result<OwnActivityPageData, OwnActivityTestFailure>)
}

private actor OwnActivityServiceSpy: AccountService {
  var scripts: [OwnActivityScript]
  private(set) var requests: [OwnActivityRequest] = []
  private var suspended:
    [Int: (
      CheckedContinuation<OwnActivityPageData, Error>,
      Result<OwnActivityPageData, OwnActivityTestFailure>
    )] = [:]
  init(_ scripts: [OwnActivityScript]) { self.scripts = scripts }
  func ownActivity(session: StoredAccountSession, kind: OwnActivityKind, page: Int, pageSize: Int)
    async throws -> OwnActivityPageData
  {
    requests.append(
      .init(
        userID: session.id, revision: session.sessionRevision, kind: kind, page: page,
        pageSize: pageSize))
    guard !scripts.isEmpty else { throw OwnActivityTestFailure(message: "unexpected request") }
    switch scripts.removeFirst() {
    case .value(let page): return page
    case .failure(let message): throw OwnActivityTestFailure(message: message)
    case .suspended(let id, let result):
      return try await withCheckedThrowingContinuation { suspended[id] = ($0, result) }
    }
  }
  func waiting(_ id: Int) -> Bool { suspended[id] != nil }
  func release(_ id: Int) {
    guard let (continuation, result) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(with: result.mapError { $0 as Error })
  }
  func releaseAll() { for id in Array(suspended.keys) { release(id) } }
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw OwnActivityTestFailure(message: "unexpected")
  }
  func followedForums(session: StoredAccountSession, page: Int, pageSize: Int) async throws
    -> FollowedForumPageData
  { throw OwnActivityTestFailure(message: "unexpected") }
  func forumMembership(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws -> ForumMembershipData
  { throw OwnActivityTestFailure(message: "unexpected") }
  func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws -> ForumAccountStateData
  { throw OwnActivityTestFailure(message: "unexpected") }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData { throw OwnActivityTestFailure(message: "unexpected") }
  func checkInToForum(session: StoredAccountSession, forumID: Int64, forumName: String) async throws
    -> ForumAccountStateData
  { throw OwnActivityTestFailure(message: "unexpected") }
}

private actor OwnActivityVault: AccountVault {
  var session: StoredAccountSession?
  var readCount = 0
  var failingRead: Int?
  init(_ session: StoredAccountSession?) { self.session = session }
  func replace(_ session: StoredAccountSession?) { self.session = session }
  func failRead(_ count: Int) { failingRead = count }
  func activeSession() async throws -> StoredAccountSession? {
    readCount += 1
    if readCount == failingRead { throw OwnActivityTestFailure(message: "vault unavailable") }
    return session
  }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws {
    throw OwnActivityTestFailure(message: "unexpected")
  }
  func switchActive(to userID: Int64) async throws {
    throw OwnActivityTestFailure(message: "unexpected")
  }
  func remove(userID: Int64) async throws { throw OwnActivityTestFailure(message: "unexpected") }
  func removeAll() async throws { throw OwnActivityTestFailure(message: "unexpected") }
}

private func ownActivitySession(
  userID: Int64 = 7, stoken: String? = String(repeating: "s", count: 64)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID, username: "user", displayName: "User", portrait: "portrait",
    bduss: String(repeating: "b", count: 192), stoken: stoken,
    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID())
}

private func activityPage(ids: [Int64], userID: Int64 = 7, page: Int = 1, more: Bool = false)
  -> OwnActivityPageData
{
  OwnActivityPageData(
    accountUserID: userID,
    threads: ids.map {
      BrowseThread(
        id: $0, forumID: 8, forumName: "forum", title: "thread \($0)", excerpt: "",
        authorName: "User", replyCount: 0, viewCount: 0, createdAt: nil, lastReplyAt: nil,
        contents: [], authorID: userID)
    }, replies: [], currentPage: page, hasMore: more, isHidden: false)
}

private func activityReply(thread: Int64, post: Int64, target: BrowseUserReplyTarget = .post)
  -> BrowseUserReply
{
  BrowseUserReply(
    threadID: thread, postID: post, forumID: 8, forumName: "forum", threadTitle: "thread",
    excerpt: "reply", createdAt: nil, authorID: 7, authorName: "User", authorUsername: "user",
    target: target)
}
