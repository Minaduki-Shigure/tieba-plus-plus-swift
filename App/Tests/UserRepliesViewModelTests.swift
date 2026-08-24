import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserRepliesViewModelTests: XCTestCase {
  func testLoadIsExplicitAndUsesRawHiddenTailForPagination() async throws {
    let visible = BrowseUserReply.fixture(threadID: 10, postID: 100)
    let hiddenTail = BrowseUserReply.fixture(
      threadID: 10,
      postID: 101,
      localVisibility: .hidden
    )
    let next = BrowseUserReply.fixture(threadID: 11, postID: 102)
    let service = UserReplyServiceStub(
      stubs: [
        .value(
          UserReplyPageData(
            replies: [visible, hiddenTail],
            currentPage: 1,
            hasMore: true,
            isHidden: false
          )
        ),
        .value(
          UserReplyPageData(
            replies: [next],
            currentPage: 2,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserRepliesViewModel(userID: 7, service: service)

    await Task.yield()
    let requestsBeforeLoad = await service.requestSnapshot()
    XCTAssertEqual(requestsBeforeLoad, [])

    viewModel.loadIfNeeded()
    try await waitForReplies { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.replies, [visible, hiddenTail])
    XCTAssertEqual(viewModel.displayableReplies, [visible])

    viewModel.loadMoreIfNeeded(current: hiddenTail)
    try await waitForReplies { viewModel.replies == [visible, hiddenTail, next] }

    XCTAssertEqual(viewModel.displayableReplies, [visible, next])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testDuplicateOnlyPageStopsPagination() async throws {
    let reply = BrowseUserReply.fixture(threadID: 20, postID: 200)
    let service = UserReplyServiceStub(
      stubs: [
        .value(
          UserReplyPageData(
            replies: [reply],
            currentPage: 1,
            hasMore: true,
            isHidden: false
          )
        ),
        .value(
          UserReplyPageData(
            replies: [reply],
            currentPage: 2,
            hasMore: true,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserRepliesViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForReplies { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: reply)
    try await waitForReplies { !viewModel.isLoadingMore }
    viewModel.loadMoreIfNeeded(current: reply)
    await Task.yield()

    XCTAssertEqual(viewModel.replies, [reply])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testServerHiddenPageDoesNotContinuePagination() async throws {
    let reply = BrowseUserReply.fixture(threadID: 30, postID: 300)
    let service = UserReplyServiceStub(
      stubs: [
        .value(
          UserReplyPageData(
            replies: [reply],
            currentPage: 1,
            hasMore: true,
            isHidden: true
          )
        )
      ]
    )
    let viewModel = UserRepliesViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForReplies { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: reply)
    viewModel.retryLoadMore()
    await Task.yield()

    XCTAssertTrue(viewModel.isActivityHidden)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1])
  }

  func testFailedInitialLoadCanRetryIndependently() async throws {
    let reply = BrowseUserReply.fixture(threadID: 40, postID: 400)
    let service = UserReplyServiceStub(
      stubs: [
        .failure,
        .value(
          UserReplyPageData(
            replies: [reply],
            currentPage: 1,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserRepliesViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForReplies {
      if case .failed = viewModel.state { return true }
      return false
    }
    viewModel.reload()
    try await waitForReplies { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.replies, [reply])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
  }

  func testCancelingPaginationRearmsTheRawTailSentinel() async throws {
    let first = BrowseUserReply.fixture(threadID: 50, postID: 500)
    let second = BrowseUserReply.fixture(threadID: 50, postID: 501)
    let service = UserReplyServiceStub(
      stubs: [
        .value(
          UserReplyPageData(
            replies: [first],
            currentPage: 1,
            hasMore: true,
            isHidden: false
          )
        ),
        .suspended(1),
        .value(
          UserReplyPageData(
            replies: [second],
            currentPage: 2,
            hasMore: false,
            isHidden: false
          )
        ),
      ]
    )
    let viewModel = UserRepliesViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForReplies { viewModel.state == .loaded }
    let epoch = viewModel.paginationEpoch
    viewModel.loadMoreIfNeeded(current: first)
    try await service.waitUntilSuspendedRequestStarted(id: 1)
    viewModel.cancel()
    await service.failSuspendedRequest(id: 1)

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertEqual(viewModel.paginationEpoch, epoch + 1)
    viewModel.loadMoreIfNeeded(current: first)
    try await waitForReplies { viewModel.replies == [first, second] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  func testNavigationSeparatesExactReplyAndOriginThreadAndUnknownTypeFailsClosed() {
    let post = BrowseUserReply.fixture(threadID: 60, postID: 600, target: .post)
    let comment = BrowseUserReply.fixture(threadID: 61, postID: 601, target: .comment)
    let unknown = BrowseUserReply.fixture(
      threadID: 62,
      postID: 602,
      target: .unsupported(rawType: 9)
    )

    XCTAssertEqual(
      post.navigationTarget,
      .thread(TiebaThreadRoute(threadID: 60, postID: 600))
    )
    XCTAssertEqual(comment.navigationTarget, .comment(threadID: 61, commentID: 601))
    XCTAssertNil(unknown.navigationTarget)

    XCTAssertEqual(
      post.originThreadNavigationTarget,
      .thread(TiebaThreadRoute(threadID: 60))
    )
    XCTAssertEqual(
      comment.originThreadNavigationTarget,
      .thread(TiebaThreadRoute(threadID: 61))
    )
    XCTAssertEqual(
      unknown.originThreadNavigationTarget,
      .thread(TiebaThreadRoute(threadID: 62))
    )
  }

  func testNavigationRejectsNonpositiveReplyIdentities() {
    let zeroThread = BrowseUserReply.fixture(threadID: 0, postID: 600)
    let negativeThread = BrowseUserReply.fixture(threadID: -1, postID: 600)
    let zeroPost = BrowseUserReply.fixture(threadID: 60, postID: 0)
    let negativePost = BrowseUserReply.fixture(threadID: 60, postID: -1)

    for reply in [zeroThread, negativeThread] {
      XCTAssertNil(reply.navigationTarget)
      XCTAssertNil(reply.originThreadNavigationTarget)
    }
    for reply in [zeroPost, negativePost] {
      XCTAssertNil(reply.navigationTarget)
      XCTAssertEqual(
        reply.originThreadNavigationTarget,
        .thread(TiebaThreadRoute(threadID: 60))
      )
    }
  }

  func testReplyRowPresentationKeepsActionsIndependentAndFiltersFailClosed() {
    let reply = BrowseUserReply.fixture(
      threadID: 60,
      postID: 600,
      threadTitle: " 原主题 "
    )
    let presentation = UserActivityReplyRowPresentation(reply: reply)

    XCTAssertEqual(
      presentation.replyTarget,
      .thread(TiebaThreadRoute(threadID: 60, postID: 600))
    )
    XCTAssertEqual(
      presentation.originThreadTarget,
      .thread(TiebaThreadRoute(threadID: 60))
    )
    XCTAssertEqual(presentation.originThreadTitle, "原主题")
    XCTAssertEqual(presentation.originThreadAccessibilityLabel, "打开原主题：原主题")

    let placeholder = UserActivityReplyRowPresentation(
      reply: reply.withLocalVisibility(.placeholder)
    )
    let hidden = UserActivityReplyRowPresentation(
      reply: reply.withLocalVisibility(.hidden)
    )
    XCTAssertNil(placeholder.replyTarget)
    XCTAssertNil(placeholder.originThreadTarget)
    XCTAssertNil(placeholder.originThreadTitle)
    XCTAssertNil(placeholder.originThreadAccessibilityLabel)
    XCTAssertNil(hidden.replyTarget)
    XCTAssertNil(hidden.originThreadTarget)
    XCTAssertNil(hidden.originThreadTitle)
    XCTAssertNil(hidden.originThreadAccessibilityLabel)
  }

  func testReplyRowPresentationUsesStableFallbackForUntitledOrigin() {
    let reply = BrowseUserReply.fixture(
      threadID: 60,
      postID: 600,
      threadTitle: " \n "
    )
    let presentation = UserActivityReplyRowPresentation(reply: reply)

    XCTAssertEqual(presentation.originThreadTitle, "查看原主题")
    XCTAssertEqual(presentation.originThreadAccessibilityLabel, "查看原主题")

    let literalTitle = UserActivityReplyRowPresentation(
      reply: BrowseUserReply.fixture(
        threadID: 61,
        postID: 601,
        threadTitle: "查看原主题"
      )
    )
    XCTAssertEqual(literalTitle.originThreadTitle, "查看原主题")
    XCTAssertEqual(literalTitle.originThreadAccessibilityLabel, "打开原主题：查看原主题")
  }

  func testCoreMappingAppliesReplyFiltersWithoutDroppingRawItems() {
    let page = TiebaUserReplyPage(
      userID: 7,
      replies: [
        TiebaUserReply(
          threadID: 70,
          forumID: 42,
          forumName: "swift",
          threadTitle: "blocked topic",
          postID: 700,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000),
          content: TiebaContent(fragments: [.text("reply body")]),
          author: nil,
          target: .comment
        )
      ],
      pagination: TiebaPagination(
        pageSize: 20,
        currentPage: 2,
        totalPages: 0,
        totalCount: 0,
        hasMore: true,
        hasPrevious: true
      ),
      isHidden: false
    )
    let filter = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked", list: .block)]
    )

    let mapped = TiebaCoreBrowseService.mapUserReplyPage(page, applying: filter)

    XCTAssertEqual(mapped.currentPage, 2)
    XCTAssertTrue(mapped.hasMore)
    XCTAssertEqual(mapped.replies.count, 1)
    XCTAssertEqual(mapped.replies.first?.excerpt, "reply body")
    XCTAssertEqual(mapped.replies.first?.localVisibility, .placeholder)
    XCTAssertEqual(mapped.replies.first?.target, .comment)
  }
}

private struct UserReplyRequest: Equatable, Sendable {
  let userID: Int64
  let page: Int
  let pageSize: Int
}

private enum UserReplyStubError: Error {
  case failure
  case unexpectedRequest
}

private enum UserReplyStub: Sendable {
  case value(UserReplyPageData)
  case failure
  case suspended(Int)
}

private actor UserReplyServiceStub: UserProfileService {
  private var stubs: [UserReplyStub]
  private var requests: [UserReplyRequest] = []
  private var suspended: [Int: CheckedContinuation<UserReplyPageData, any Error>] = [:]
  private var startedSuspensions: Set<Int> = []
  private var suspensionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  init(stubs: [UserReplyStub]) {
    self.stubs = stubs
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    throw UserReplyStubError.unexpectedRequest
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  {
    throw UserReplyStubError.unexpectedRequest
  }

  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserReplyPageData
  {
    requests.append(UserReplyRequest(userID: userID, page: page, pageSize: pageSize))
    guard !stubs.isEmpty else { throw UserReplyStubError.unexpectedRequest }
    switch stubs.removeFirst() {
    case .value(let value):
      return value
    case .failure:
      throw UserReplyStubError.failure
    case .suspended(let id):
      startedSuspensions.insert(id)
      let waiters = suspensionWaiters.removeValue(forKey: id) ?? []
      waiters.forEach { $0.resume() }
      return try await withCheckedThrowingContinuation { suspended[id] = $0 }
    }
  }

  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
  {
    throw UserReplyStubError.unexpectedRequest
  }

  func requestSnapshot() -> [UserReplyRequest] { requests }

  func failSuspendedRequest(id: Int) {
    suspended.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  func waitUntilSuspendedRequestStarted(id: Int) async {
    guard !startedSuspensions.contains(id) else { return }
    await withCheckedContinuation { continuation in
      suspensionWaiters[id, default: []].append(continuation)
    }
  }
}

extension BrowseUserReply {
  fileprivate static func fixture(
    threadID: Int64,
    postID: Int64,
    threadTitle: String? = nil,
    target: BrowseUserReplyTarget = .post,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseUserReply {
    BrowseUserReply(
      threadID: threadID,
      postID: postID,
      forumID: 42,
      forumName: "swift",
      threadTitle: threadTitle ?? "thread-\(threadID)",
      excerpt: "reply-\(postID)",
      createdAt: nil,
      authorID: 7,
      authorName: "测试用户",
      authorUsername: "fixture-user",
      target: target,
      localVisibility: localVisibility
    )
  }
}

@MainActor
private func waitForReplies(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw UserReplyStubError.failure }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
