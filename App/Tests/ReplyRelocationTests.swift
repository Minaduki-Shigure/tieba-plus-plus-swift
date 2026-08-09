import XCTest

@testable import TiebaPlusPlus

final class ReplyRelocationTests: XCTestCase {
  @MainActor
  func testConfirmedThreadReplyReloadsAroundExactPostAndPublishesScrollTarget() async {
    let service = ReplyRelocationBrowseService()
    let thread = Self.thread(id: 90, firstPostID: 901)
    let reply = Self.post(id: 902, threadID: thread.id, floor: 2)
    await service.enqueuePostPage(
      PostPageData(
        thread: thread,
        posts: [reply],
        currentPage: 1,
        hasMore: false,
        totalPages: 1
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    let verified = await viewModel.verifyAndRelocateAcceptedReply(postID: reply.id)

    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.threadID, thread.id)
    XCTAssertEqual(requests.first?.page, 1)
    XCTAssertEqual(requests.first?.location, .postID(reply.id))
    XCTAssertEqual(verified?.id, reply.id)
    XCTAssertEqual(viewModel.scrollTargetPostID, reply.id)
    XCTAssertEqual(viewModel.posts.map(\.id), [reply.id])
  }

  @MainActor
  func testInvalidConfirmedThreadReplyIDDoesNotReload() async {
    let service = ReplyRelocationBrowseService()
    let viewModel = ThreadViewModel(thread: Self.thread(id: 91), service: service)

    viewModel.relocateAfterConfirmedReply(postID: 0)
    await Task.yield()

    let requests = await service.postRequestSnapshot()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  @MainActor
  func testThreadReplyRelocationLeavesHotSortBeforeExactRequest() async {
    let service = ReplyRelocationBrowseService()
    let thread = Self.thread(id: 94, firstPostID: 941)
    let reply = Self.post(id: 942, threadID: thread.id, floor: 2)
    await service.enqueuePostPage(
      PostPageData(
        thread: thread,
        posts: [reply],
        currentPage: 1,
        hasMore: false
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      options: ThreadBrowseOptions(sort: .hot)
    )

    viewModel.relocateAfterConfirmedReply(postID: reply.id)
    await viewModel.waitForCurrentLoad()

    let requests = await service.postRequestSnapshot()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.options.sort, .ascending)
    XCTAssertEqual(request.location, .postID(reply.id))
    XCTAssertEqual(viewModel.options.sort, .ascending)
  }

  @MainActor
  func testThreadReplyRelocationDisablesOnlyThreadAuthorBeforeExactRequest() async {
    let service = ReplyRelocationBrowseService()
    let thread = Self.thread(id: 95, firstPostID: 951)
    let reply = Self.post(id: 952, threadID: thread.id, floor: 2)
    await service.enqueuePostPage(
      PostPageData(
        thread: thread,
        posts: [reply],
        currentPage: 1,
        hasMore: false
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      options: ThreadBrowseOptions(sort: .ascending, onlyThreadAuthor: true)
    )

    viewModel.relocateAfterConfirmedReply(postID: reply.id)
    await viewModel.waitForCurrentLoad()

    let requests = await service.postRequestSnapshot()
    let request = try XCTUnwrap(requests.first)
    XCTAssertFalse(request.options.onlyThreadAuthor)
    XCTAssertEqual(request.location, .postID(reply.id))
    XCTAssertFalse(viewModel.options.onlyThreadAuthor)
  }

  @MainActor
  func testConfirmedNestedReplyReloadsAroundExactCommentAndPublishesScrollTarget() async {
    let service = ReplyRelocationBrowseService()
    let thread = Self.thread(id: 92, firstPostID: 921)
    let parent = Self.parentPost(id: 922, threadID: thread.id)
    let reply = Self.comment(id: 923, threadID: thread.id, parentPostID: parent.id)
    await service.enqueueCommentPage(
      CommentPageData(
        parentPost: parent,
        comments: [reply],
        currentPage: 3,
        hasMore: true,
        hasPrevious: true,
        totalPages: 5,
        totalCount: 41,
        thread: thread
      )
    )
    let viewModel = CommentsViewModel(
      threadID: thread.id,
      postID: parent.id,
      service: service
    )

    let verified = await viewModel.verifyAndRelocateAcceptedReply(commentID: reply.id)

    let requests = await service.aroundCommentRequestSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.threadID, thread.id)
    XCTAssertEqual(requests.first?.postID, parent.id)
    XCTAssertEqual(requests.first?.commentID, reply.id)
    XCTAssertEqual(requests.first?.page, 1)
    XCTAssertEqual(verified?.id, reply.id)
    XCTAssertEqual(viewModel.scrollTargetCommentID, reply.id)
    XCTAssertEqual(viewModel.comments.map(\.id), [reply.id])

    let next = Self.comment(id: 924, threadID: thread.id, parentPostID: parent.id)
    await service.enqueueCommentPage(
      CommentPageData(
        parentPost: parent,
        comments: [next],
        currentPage: 4,
        hasMore: false,
        hasPrevious: true,
        totalPages: 5,
        totalCount: 42,
        thread: thread
      )
    )
    viewModel.loadMoreIfNeeded(current: reply)
    await viewModel.waitForCurrentLoad()

    let pageRequests = await service.commentRequestSnapshot()
    XCTAssertEqual(pageRequests.count, 1)
    XCTAssertEqual(pageRequests.first?.threadID, thread.id)
    XCTAssertEqual(pageRequests.first?.postID, parent.id)
    XCTAssertEqual(pageRequests.first?.page, 4)
    XCTAssertEqual(viewModel.comments.map(\.id), [reply.id, next.id])
  }

  @MainActor
  func testMissingConfirmedNestedReplyDoesNotPublishFalseScrollTarget() async {
    let service = ReplyRelocationBrowseService()
    let thread = Self.thread(id: 93, firstPostID: 931)
    let parent = Self.parentPost(id: 932, threadID: thread.id)
    let requestedCommentID: Int64 = 933
    await service.enqueueCommentPage(
      CommentPageData(
        parentPost: parent,
        comments: [],
        currentPage: 1,
        hasMore: false,
        thread: thread
      )
    )
    let viewModel = CommentsViewModel(
      threadID: thread.id,
      postID: parent.id,
      service: service
    )

    let verified = await viewModel.verifyAndRelocateAcceptedReply(
      commentID: requestedCommentID
    )

    XCTAssertNil(verified)
    XCTAssertNil(viewModel.scrollTargetCommentID)
    XCTAssertEqual(viewModel.positionNotice, "未能在返回页面中定位目标回复。")
  }

  private static func thread(id: Int64, firstPostID: Int64 = 0) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 100,
      forumName: "Swift",
      title: "thread-\(id)",
      excerpt: "excerpt",
      authorName: "author",
      replyCount: 1,
      viewCount: 2,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("thread")],
      firstPostID: firstPostID
    )
  }

  private static func post(id: Int64, threadID: Int64, floor: Int) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: 7,
      authorName: "reply-author",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: false,
      contents: [.text("reply")]
    )
  }

  private static func parentPost(id: Int64, threadID: Int64) -> CommentParentPostContext {
    CommentParentPostContext(
      id: id,
      threadID: threadID,
      floor: 2,
      authorID: 8,
      authorName: "parent-author",
      authorPortraitURL: nil,
      createdAt: nil,
      isThreadAuthor: false,
      contents: [.text("parent")]
    )
  }

  private static func comment(
    id: Int64,
    threadID: Int64,
    parentPostID: Int64
  ) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: 9,
      authorName: "comment-author",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("nested reply")],
      threadID: threadID,
      parentPostID: parentPostID
    )
  }
}

private struct ReplyRelocationPostRequest: Sendable {
  let threadID: Int64
  let page: Int
  let options: ThreadBrowseOptions
  let location: ThreadPostLocation?
}

private struct ReplyRelocationPageRequest: Sendable {
  let threadID: Int64
  let postID: Int64
  let page: Int
}

private struct ReplyRelocationCommentRequest: Sendable {
  let threadID: Int64
  let postID: Int64
  let commentID: Int64
  let page: Int
}

private enum ReplyRelocationStubError: Error {
  case unexpectedRequest
}

private actor ReplyRelocationBrowseService: BrowseService {
  private var postPages: [PostPageData] = []
  private var commentPages: [CommentPageData] = []
  private var postRequests: [ReplyRelocationPostRequest] = []
  private var commentRequests: [ReplyRelocationPageRequest] = []
  private var aroundCommentRequests: [ReplyRelocationCommentRequest] = []

  func enqueuePostPage(_ page: PostPageData) {
    postPages.append(page)
  }

  func enqueueCommentPage(_ page: CommentPageData) {
    commentPages.append(page)
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    throw ReplyRelocationStubError.unexpectedRequest
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    postRequests.append(
      ReplyRelocationPostRequest(
        threadID: threadID,
        page: page,
        options: options,
        location: location
      )
    )
    guard !postPages.isEmpty else { throw ReplyRelocationStubError.unexpectedRequest }
    return postPages.removeFirst()
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    commentRequests.append(
      ReplyRelocationPageRequest(threadID: threadID, postID: postID, page: page)
    )
    guard !commentPages.isEmpty else { throw ReplyRelocationStubError.unexpectedRequest }
    return commentPages.removeFirst()
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    aroundCommentRequests.append(
      ReplyRelocationCommentRequest(
        threadID: threadID,
        postID: postID,
        commentID: commentID,
        page: page
      )
    )
    guard !commentPages.isEmpty else { throw ReplyRelocationStubError.unexpectedRequest }
    return commentPages.removeFirst()
  }

  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData {
    throw ReplyRelocationStubError.unexpectedRequest
  }

  func postRequestSnapshot() -> [ReplyRelocationPostRequest] { postRequests }

  func commentRequestSnapshot() -> [ReplyRelocationPageRequest] { commentRequests }

  func aroundCommentRequestSnapshot() -> [ReplyRelocationCommentRequest] {
    aroundCommentRequests
  }
}
