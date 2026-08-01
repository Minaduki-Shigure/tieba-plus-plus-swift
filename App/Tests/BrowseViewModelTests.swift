import Foundation
import XCTest

@testable import TiebaPlusPlus

final class BrowseViewModelTests: XCTestCase {
  @MainActor
  func testForumInitialLoadSucceeds() async throws {
    let service = ScriptedBrowseService()
    let threads = [Fixtures.thread(id: 11), Fixtures.thread(id: 12)]
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: threads,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.threads, threads)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(
      requests,
      [ThreadRequest(forumName: "Swift", page: 1, pageSize: 30)]
    )
  }

  @MainActor
  func testForumInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.failure(StubFailure(message: "forum unavailable")))
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("forum unavailable") }
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  @MainActor
  func testForumPaginationDeduplicatesThreads() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [
      Fixtures.thread(id: 21, title: "first"),
      Fixtures.thread(id: 22, title: "original duplicate"),
    ]
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [
            Fixtures.thread(id: 22, title: "replacement duplicate"),
            Fixtures.thread(id: 23, title: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.threads.map(\.id) == [21, 22, 23] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.threads[1].title, "original duplicate")
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testForumReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.suspended(101))
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 32, title: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.reload()
    try await waitUntil { await service.threadRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.threads.first?.title == "fresh" }

    let resumed = await service.resumeThreads(
      id: 101,
      returning: ThreadPageData(
        forumName: "Swift",
        threads: [Fixtures.thread(id: 31, title: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedThreadRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.threads.map(\.title), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testThreadInitialLoadSucceedsAndRefreshesThreadMetadata() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 41, title: "placeholder")
    let serverThread = Fixtures.thread(id: 41, title: "server title")
    let posts = [Fixtures.post(id: 411, threadID: 41), Fixtures.post(id: 412, threadID: 41)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: serverThread,
          posts: posts,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.thread, serverThread)
    XCTAssertEqual(viewModel.posts, posts)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests, [PostRequest(threadID: 41, page: 1, pageSize: 30)])
  }

  @MainActor
  func testThreadInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueuePosts(.failure(StubFailure(message: "thread unavailable")))
    let viewModel = ThreadViewModel(thread: Fixtures.thread(id: 51), service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("thread unavailable") }
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  @MainActor
  func testThreadPaginationDeduplicatesPosts() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 61)
    let firstPage = [
      Fixtures.post(id: 611, threadID: 61, authorName: "first"),
      Fixtures.post(id: 612, threadID: 61, authorName: "original duplicate"),
    ]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [
            Fixtures.post(id: 612, threadID: 61, authorName: "replacement duplicate"),
            Fixtures.post(id: 613, threadID: 61, authorName: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.posts.map(\.id) == [611, 612, 613] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.posts[1].authorName, "original duplicate")
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testThreadReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 71, title: "initial")
    let staleThread = Fixtures.thread(id: 71, title: "stale")
    let freshThread = Fixtures.thread(id: 71, title: "fresh")
    await service.enqueuePosts(.suspended(201))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: freshThread,
          posts: [Fixtures.post(id: 712, threadID: 71, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)

    viewModel.reload()
    try await waitUntil { await service.postRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.posts.first?.authorName == "fresh" }

    let resumed = await service.resumePosts(
      id: 201,
      returning: PostPageData(
        thread: staleThread,
        posts: [Fixtures.post(id: 711, threadID: 71, authorName: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedPostRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.thread.title, "fresh")
    XCTAssertEqual(viewModel.posts.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testCommentsInitialLoadSucceeds() async throws {
    let service = ScriptedBrowseService()
    let comments = [Fixtures.comment(id: 81), Fixtures.comment(id: 82)]
    await service.enqueueComments(
      .value(CommentPageData(comments: comments, currentPage: 1, hasMore: false))
    )
    let viewModel = CommentsViewModel(threadID: 8, postID: 80, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.comments, comments)
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests, [CommentRequest(threadID: 8, postID: 80, page: 1)])
  }

  @MainActor
  func testCommentsInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.failure(StubFailure(message: "comments unavailable")))
    let viewModel = CommentsViewModel(threadID: 9, postID: 90, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("comments unavailable") }
    XCTAssertTrue(viewModel.comments.isEmpty)
  }

  @MainActor
  func testCommentsPaginationDeduplicatesReplies() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [
      Fixtures.comment(id: 101, authorName: "first"),
      Fixtures.comment(id: 102, authorName: "original duplicate"),
    ]
    await service.enqueueComments(
      .value(CommentPageData(comments: firstPage, currentPage: 1, hasMore: true))
    )
    await service.enqueueComments(
      .value(
        CommentPageData(
          comments: [
            Fixtures.comment(id: 102, authorName: "replacement duplicate"),
            Fixtures.comment(id: 103, authorName: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.comments.map(\.id) == [101, 102, 103] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.comments[1].authorName, "original duplicate")
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testCommentsReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.suspended(301))
    await service.enqueueComments(
      .value(
        CommentPageData(
          comments: [Fixtures.comment(id: 92, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 9, postID: 91, service: service)

    viewModel.reload()
    try await waitUntil { await service.commentRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.comments.first?.authorName == "fresh" }

    let resumed = await service.resumeComments(
      id: 301,
      returning: CommentPageData(
        comments: [Fixtures.comment(id: 91, authorName: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedCommentRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.comments.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }
}

private struct ThreadRequest: Equatable, Sendable {
  let forumName: String
  let page: Int
  let pageSize: Int
}

private struct PostRequest: Equatable, Sendable {
  let threadID: Int64
  let page: Int
  let pageSize: Int
}

private struct CommentRequest: Equatable, Sendable {
  let threadID: Int64
  let postID: Int64
  let page: Int
}

private struct StubFailure: LocalizedError, Equatable, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private enum Stub<Value: Sendable>: Sendable {
  case value(Value)
  case failure(StubFailure)
  case suspended(Int)
}

private actor ScriptedBrowseService: BrowseService {
  private var threadStubs: [Stub<ThreadPageData>] = []
  private var postStubs: [Stub<PostPageData>] = []
  private var commentStubs: [Stub<CommentPageData>] = []

  private var threadRequests: [ThreadRequest] = []
  private var postRequests: [PostRequest] = []
  private var commentRequests: [CommentRequest] = []

  private var completedThreadRequests = 0
  private var completedPostRequests = 0
  private var completedCommentRequests = 0

  private var pendingThreads: [Int: CheckedContinuation<ThreadPageData, any Error>] = [:]
  private var pendingPosts: [Int: CheckedContinuation<PostPageData, any Error>] = [:]
  private var pendingComments: [Int: CheckedContinuation<CommentPageData, any Error>] = [:]

  func enqueueThreads(_ stub: Stub<ThreadPageData>) {
    threadStubs.append(stub)
  }

  func enqueuePosts(_ stub: Stub<PostPageData>) {
    postStubs.append(stub)
  }

  func enqueueComments(_ stub: Stub<CommentPageData>) {
    commentStubs.append(stub)
  }

  func threads(forumName: String, page: Int, pageSize: Int) async throws -> ThreadPageData {
    threadRequests.append(ThreadRequest(forumName: forumName, page: page, pageSize: pageSize))
    defer { completedThreadRequests += 1 }
    guard !threadStubs.isEmpty else {
      throw StubFailure(message: "Unexpected threads request")
    }

    switch threadStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingThreads[identifier] = continuation
      }
    }
  }

  func posts(threadID: Int64, page: Int, pageSize: Int) async throws -> PostPageData {
    postRequests.append(PostRequest(threadID: threadID, page: page, pageSize: pageSize))
    defer { completedPostRequests += 1 }
    guard !postStubs.isEmpty else {
      throw StubFailure(message: "Unexpected posts request")
    }

    switch postStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingPosts[identifier] = continuation
      }
    }
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    commentRequests.append(CommentRequest(threadID: threadID, postID: postID, page: page))
    defer { completedCommentRequests += 1 }
    guard !commentStubs.isEmpty else {
      throw StubFailure(message: "Unexpected comments request")
    }

    switch commentStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingComments[identifier] = continuation
      }
    }
  }

  func resumeThreads(id: Int, returning value: ThreadPageData) -> Bool {
    guard let continuation = pendingThreads.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumePosts(id: Int, returning value: PostPageData) -> Bool {
    guard let continuation = pendingPosts.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumeComments(id: Int, returning value: CommentPageData) -> Bool {
    guard let continuation = pendingComments.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func threadRequestSnapshot() -> [ThreadRequest] { threadRequests }
  func postRequestSnapshot() -> [PostRequest] { postRequests }
  func commentRequestSnapshot() -> [CommentRequest] { commentRequests }

  func threadRequestCount() -> Int { threadRequests.count }
  func postRequestCount() -> Int { postRequests.count }
  func commentRequestCount() -> Int { commentRequests.count }

  func completedThreadRequestCount() -> Int { completedThreadRequests }
  func completedPostRequestCount() -> Int { completedPostRequests }
  func completedCommentRequestCount() -> Int { completedCommentRequests }
}

private enum Fixtures {
  static func thread(
    id: Int64,
    title: String? = nil,
    forumName: String = "Swift"
  ) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 100,
      forumName: forumName,
      title: title ?? "thread-\(id)",
      excerpt: "excerpt-\(id)",
      authorName: "author-\(id)",
      replyCount: 3,
      viewCount: 10,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastReplyAt: Date(timeIntervalSince1970: 1_700_000_100),
      contents: [.text("thread content")]
    )
  }

  static func post(
    id: Int64,
    threadID: Int64,
    authorName: String? = nil
  ) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: Int(id % 100),
      authorID: id + 1_000,
      authorName: authorName ?? "post-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_200),
      nestedReplyCount: 2,
      isThreadAuthor: false,
      contents: [.text("post content")]
    )
  }

  static func comment(id: Int64, authorName: String? = nil) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: id + 2_000,
      authorName: authorName ?? "comment-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_300),
      contents: [.text("comment content")]
    )
  }
}

private struct WaitTimeout: Error {}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw WaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func drainMainActor() async {
  for _ in 0..<20 {
    await Task<Void, Never>.yield()
  }
}
