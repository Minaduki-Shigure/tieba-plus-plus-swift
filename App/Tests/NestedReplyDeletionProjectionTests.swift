import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class NestedReplyDeletionProjectionTests: XCTestCase {
  func testCommentsAcceptedDeletionPrunesExactChildAndAgreementIndexIdempotently() async throws {
    let child = projectionComment(201)
    let sibling = projectionComment(202, authorID: 9)
    let service = NestedDeletionProjectionService(commentPages: [projectionPage([child, sibling])])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    let target = try projectionTarget(child)
    let parent = model.parentPost
    let originalCount = model.totalCount
    let rebuilds = model.commentIndexFullRebuildCount

    XCTAssertTrue(model.applyAcceptedContentDeletion(target))
    XCTAssertEqual(model.comments, [sibling])
    XCTAssertEqual(model.displayableComments, [sibling])
    XCTAssertNil(model.comment(withID: child.id))
    XCTAssertNil(model.agreementTarget(forCommentID: child.id))
    XCTAssertEqual(model.comment(withID: sibling.id), sibling)
    XCTAssertEqual(model.parentPost, parent)
    XCTAssertEqual(
      model.totalCount, originalCount,
      "Keep server total; do not guess whether it already decremented")
    XCTAssertEqual(model.commentIndexFullRebuildCount, rebuilds + 1)
    XCTAssertTrue(model.applyAcceptedContentDeletion(target))
    XCTAssertEqual(model.commentIndexFullRebuildCount, rebuilds + 1)
    let retained = Set(model.agreementReadDescriptors.flatMap(\.expectedTargets))
    XCTAssertFalse(retained.contains { $0.objectID == child.id })
    XCTAssertTrue(retained.contains { $0.objectID == sibling.id })
    XCTAssertTrue(retained.contains { $0.objectID == 102 })
  }

  func testCommentsStagedDeletionBindsInitialPageAndSurvivesRefreshAndReload() async throws {
    let child = projectionComment(201)
    let sibling = projectionComment(202)
    let page = projectionPage([child, sibling])
    let service = NestedDeletionProjectionService(commentPages: [page, page, page])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    XCTAssertTrue(model.stageAcceptedContentDeletion(try projectionTarget(child)))
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.comments, [sibling])
    await model.refresh()
    XCTAssertEqual(model.comments, [sibling])
    model.reload()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.comments, [sibling])
    XCTAssertEqual(model.comment(withID: sibling.id), sibling)
    XCTAssertNil(model.comment(withID: child.id))
  }

  func testCommentsAcceptedNotificationDuringInitialLoadIsStagedBeforeResponse() async throws {
    let child = projectionComment(201)
    let service = NestedDeletionProjectionService()
    await service.suspendNextComments()
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    model.loadIfNeeded()
    try await waitForProjection { await service.isCommentSuspended() }
    XCTAssertEqual(model.state, .loading)
    XCTAssertTrue(model.stageAcceptedContentDeletion(try projectionTarget(child)))
    await service.resumeComments(projectionPage([child]))
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.state, .loaded)
    XCTAssertTrue(model.comments.isEmpty)
    XCTAssertFalse(model.hasDisplayableComments)
  }

  func testCommentsAcceptedDeletionFiltersAlreadyInFlightRefresh() async throws {
    let child = projectionComment(201)
    let sibling = projectionComment(202)
    let page = projectionPage([child, sibling])
    let service = NestedDeletionProjectionService(commentPages: [page])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    await service.suspendNextComments()
    let refresh = Task { await model.refresh() }
    try await waitForProjection { await service.isCommentSuspended() }
    XCTAssertTrue(model.applyAcceptedContentDeletion(try projectionTarget(child)))
    await service.resumeComments(page)
    await refresh.value
    XCTAssertEqual(model.comments, [sibling])
    XCTAssertNil(model.agreementTarget(forCommentID: child.id))
    XCTAssertFalse(
      model.agreementReadDescriptors.flatMap(\.expectedTargets).contains {
        $0.objectID == child.id
      })
  }

  func testFilteredEmptyPagesContinueForwardAndDoNotRebuildPerLookup() async throws {
    let first = projectionComment(201)
    let second = projectionComment(202)
    let retained = projectionComment(203)
    let service = NestedDeletionProjectionService(commentPages: [
      projectionPage([first], page: 1, hasMore: true),
      projectionPage([second], page: 2, hasMore: true),
      projectionPage([retained], page: 3),
    ])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    XCTAssertTrue(model.stageAcceptedContentDeletion(try projectionTarget(first)))
    XCTAssertTrue(model.stageAcceptedContentDeletion(try projectionTarget(second)))
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    XCTAssertTrue(model.comments.isEmpty)
    XCTAssertTrue(model.canLoadMore)
    model.loadMore()
    await model.waitForCurrentLoad()
    XCTAssertTrue(model.comments.isEmpty)
    XCTAssertTrue(model.canLoadMore)
    model.loadMore()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.comments, [retained])
    XCTAssertFalse(model.canLoadMore)
    let rebuilds = model.commentIndexFullRebuildCount
    for _ in 0..<1_000 {
      XCTAssertEqual(model.comment(withID: retained.id), retained)
      XCTAssertNotNil(model.agreementTarget(forCommentID: retained.id))
    }
    XCTAssertEqual(model.commentIndexFullRebuildCount, rebuilds)
    let pages = await service.requestedCommentPages()
    XCTAssertEqual(pages, [1, 2, 3])
  }

  func testFilteredEmptyPagesContinueBackwardAndRetainScrollAnchor() async throws {
    let retained = projectionComment(203)
    let deleted = projectionComment(202)
    let earlier = projectionComment(201)
    let service = NestedDeletionProjectionService(commentPages: [
      projectionPage([retained], page: 3, hasPrevious: true),
      projectionPage([deleted], page: 2, hasPrevious: true),
      projectionPage([earlier], page: 1),
    ])
    let model = CommentsViewModel(threadID: 10, postID: 102, aroundCommentID: 203, service: service)
    XCTAssertTrue(model.stageAcceptedContentDeletion(try projectionTarget(deleted)))
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    model.loadPrevious()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.comments, [retained])
    XCTAssertTrue(model.canLoadPrevious)
    model.loadPrevious()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.comments, [earlier, retained])
    XCTAssertFalse(model.canLoadPrevious)
    XCTAssertEqual(model.prependRestoreCommentID, retained.id)
    let pages = await service.requestedCommentPages()
    XCTAssertEqual(pages, [1, 2, 1])
  }

  func testCommentsRejectDeletionIdentityMismatchWithoutMutatingAnySnapshot() async throws {
    let child = projectionComment(201)
    let service = NestedDeletionProjectionService(commentPages: [projectionPage([child])])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    let rebuilds = model.commentIndexFullRebuildCount
    let targets = [
      projectionRawTarget(threadID: 11), projectionRawTarget(forumID: 43),
      projectionRawTarget(forumName: "other"), projectionRawTarget(parentID: 103),
      projectionRawTarget(floor: 3), projectionRawTarget(authorID: 99),
      projectionRawTarget(ownerID: 99),
    ]
    for target in targets {
      XCTAssertFalse(model.applyAcceptedContentDeletion(try XCTUnwrap(target)))
    }
    XCTAssertEqual(model.comments, [child])
    XCTAssertEqual(model.parentPost, projectionParent())
    XCTAssertEqual(model.thread, projectionThread())
    XCTAssertEqual(model.commentIndexFullRebuildCount, rebuilds)
  }

  func testStagedIdentityConflictDoesNotDeleteMatchingNumericChildID() async throws {
    for target in [
      projectionRawTarget(forumID: 43), projectionRawTarget(floor: 3),
      projectionRawTarget(authorID: 99), projectionRawTarget(ownerID: 99),
    ] {
      let child = projectionComment(201)
      let service = NestedDeletionProjectionService(commentPages: [projectionPage([child])])
      let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
      XCTAssertTrue(model.stageAcceptedContentDeletion(try XCTUnwrap(target)))
      model.loadIfNeeded()
      await model.waitForCurrentLoad()
      XCTAssertEqual(model.state, .loaded)
      XCTAssertEqual(model.comments, [child])
      XCTAssertEqual(model.parentPost, projectionParent())
    }
  }

  func testForeignParentResponseCannotReplaceAcceptedSnapshotOrMetadata() async throws {
    let child = projectionComment(201)
    let service = NestedDeletionProjectionService(commentPages: [
      projectionPage([child]), projectionPage([child], parent: projectionParent(id: 103)),
    ])
    let model = CommentsViewModel(threadID: 10, postID: 102, service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    XCTAssertTrue(model.applyAcceptedContentDeletion(try projectionTarget(child)))
    await model.refresh()
    XCTAssertNotNil(model.refreshError)
    XCTAssertEqual(model.parentPost, projectionParent())
    XCTAssertEqual(model.thread, projectionThread())
    XCTAssertTrue(model.comments.isEmpty)
  }

  func testResolvingChildDoesNotRequireUnrelatedParentsLedgerIdentity() async throws {
    let otherParent = projectionParent(id: 103)
    let child = projectionComment(301, parentID: 103)
    let page = CommentPageData(
      parentPost: otherParent, comments: [child], currentPage: 1, hasMore: false,
      totalCount: 1, thread: nil
    )
    let service = NestedDeletionProjectionService(commentPages: [page])
    let model = CommentsViewModel(threadID: 10, resolvingCommentID: child.id, service: service)
    XCTAssertTrue(model.stageAcceptedContentDeletion(try XCTUnwrap(projectionRawTarget())))
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.state, .loaded)
    XCTAssertEqual(model.parentPost, otherParent)
    XCTAssertEqual(model.comments, [child])
  }

  func testThreadProjectionKeepsParentSiblingCountsAndFiltersStalePage() async throws {
    let child = projectionComment(201)
    let sibling = projectionComment(202)
    let parent = projectionPost(comments: [child, sibling])
    let page = projectionPostPage(parent: parent)
    let service = NestedDeletionProjectionService(postPages: [page, page])
    let model = ThreadViewModel(thread: projectionThread(), service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    let target = try projectionTarget(child)
    let rebuilds = model.fullPostIndexRebuildCount
    XCTAssertTrue(model.applyAcceptedContentDeletion(target))
    XCTAssertEqual(model.post(withID: 102)?.inlineComments, [sibling])
    XCTAssertEqual(model.post(withID: 102)?.nestedReplyCount, parent.nestedReplyCount)
    XCTAssertEqual(model.posts.map(\.id), [102, 103])
    XCTAssertEqual(model.firstPost?.id, 101)
    XCTAssertEqual(model.thread.replyCount, projectionThread().replyCount)
    XCTAssertNotNil(model.agreementTarget(forPostID: 102))
    XCTAssertTrue(model.applyAcceptedContentDeletion(target))
    XCTAssertEqual(model.fullPostIndexRebuildCount, rebuilds + 1)
    model.reload()
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.post(withID: 102)?.inlineComments, [sibling])
    XCTAssertEqual(model.posts.map(\.id), [102, 103])
  }

  func testThreadFirstFloorChildIsFilteredWhenStagedDuringLoad() async throws {
    let child = projectionComment(201, parentID: 101)
    let sibling = projectionComment(202, parentID: 101)
    let first = projectionPost(id: 101, floor: 1, comments: [child, sibling])
    let service = NestedDeletionProjectionService()
    await service.suspendNextPosts()
    let model = ThreadViewModel(thread: projectionThread(), service: service)
    model.loadIfNeeded()
    try await waitForProjection { await service.isPostSuspended() }
    let target = try XCTUnwrap(projectionRawTarget(parentID: 101, floor: 1))
    XCTAssertTrue(model.stageAcceptedContentDeletion(target))
    await service.resumePosts(projectionPostPage(first: first))
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.state, .loaded)
    XCTAssertEqual(model.firstPost?.inlineComments, [sibling])
    XCTAssertEqual(model.firstPost?.id, 101)
    XCTAssertEqual(model.posts.map(\.id), [102, 103])
  }

  func testThreadRejectsWrongParentFloorAndChildAuthorThenFiltersInFlightReload() async throws {
    let child = projectionComment(201)
    let sibling = projectionComment(202)
    let page = projectionPostPage(parent: projectionPost(comments: [child, sibling]))
    let service = NestedDeletionProjectionService(postPages: [page])
    let model = ThreadViewModel(thread: projectionThread(), service: service)
    model.loadIfNeeded()
    await model.waitForCurrentLoad()
    XCTAssertFalse(model.applyAcceptedContentDeletion(try XCTUnwrap(projectionRawTarget(floor: 3))))
    XCTAssertFalse(
      model.applyAcceptedContentDeletion(try XCTUnwrap(projectionRawTarget(authorID: 99))))
    XCTAssertEqual(model.post(withID: 102)?.inlineComments, [child, sibling])
    await service.suspendNextPosts()
    model.reload()
    try await waitForProjection { await service.isPostSuspended() }
    XCTAssertTrue(model.applyAcceptedContentDeletion(try projectionTarget(child)))
    await service.resumePosts(page)
    await model.waitForCurrentLoad()
    XCTAssertEqual(model.post(withID: 102)?.inlineComments, [sibling])
  }
}

private func projectionThread() -> BrowseThread {
  BrowseThread(
    id: 10, forumID: 42, forumName: "swift", title: "Nested deletion",
    excerpt: "", authorName: "owner", replyCount: 100, viewCount: 0,
    createdAt: nil, lastReplyAt: nil, contents: [], authorID: 7, firstPostID: 101)
}

private func projectionParent(id: Int64 = 102) -> CommentParentPostContext {
  CommentParentPostContext(
    id: id, threadID: 10, floor: 2, authorID: 8,
    authorName: "parent", authorPortraitURL: nil, createdAt: nil,
    isThreadAuthor: false, contents: [.text("Parent content")])
}

private func projectionPost(
  id: Int64 = 102, floor: Int = 2, comments: [BrowseComment] = []
) -> BrowsePost {
  BrowsePost(
    id: id, threadID: 10, floor: floor, authorID: floor == 1 ? 7 : 8,
    authorName: "parent", authorPortraitURL: nil, createdAt: nil,
    nestedReplyCount: 19, isThreadAuthor: floor == 1,
    contents: [.text("Parent content")], inlineComments: comments)
}

private func projectionComment(
  _ id: Int64, parentID: Int64 = 102, authorID: Int64 = 8
) -> BrowseComment {
  BrowseComment(
    id: id, authorID: authorID, authorName: "child",
    authorPortraitURL: nil, createdAt: nil, contents: [.text("Child \(id)")],
    threadID: 10, parentPostID: parentID)
}

private func projectionTarget(_ comment: BrowseComment) throws -> OwnedContentDeletionTarget {
  try XCTUnwrap(
    OwnedContentDeletionTarget(
      thread: projectionThread(), parentPost: projectionParent(), comment: comment))
}

private func projectionRawTarget(
  threadID: Int64 = 10, forumID: Int64 = 42, forumName: String = "swift",
  parentID: Int64 = 102, floor: Int = 2, authorID: Int64 = 8, ownerID: Int64? = nil
) -> OwnedContentDeletionTarget? {
  OwnedContentDeletionTarget(
    kind: .subpost, forumID: forumID, forumName: forumName,
    threadID: threadID, objectID: 201, authorID: authorID, floor: floor,
    threadOwnerID: ownerID, parentPostID: parentID)
}

private func projectionPage(
  _ comments: [BrowseComment], page: Int = 1, hasMore: Bool = false,
  hasPrevious: Bool = false, parent: CommentParentPostContext = projectionParent()
) -> CommentPageData {
  let thread = projectionThread()
  let targets =
    comments.compactMap {
      ContentAgreementTarget(thread: thread, parentPostID: parent.id, comment: $0)
    } + [ContentAgreementTarget(thread: thread, parentPost: parent)].compactMap { $0 }
  let request = ContentAgreementSubpostPageRequest(
    forumID: 42, forumName: "swift",
    threadID: 10, parentPostID: parent.id, aroundSubpostID: nil, page: page)!
  let descriptor = ContentAgreementReadDescriptor(
    request: .subpostPage(request),
    expectedTargets: Set(targets))
  return CommentPageData(
    parentPost: parent, comments: comments, currentPage: page,
    hasMore: hasMore, hasPrevious: hasPrevious, totalPages: 3, totalCount: 19,
    thread: thread, agreementReadDescriptor: descriptor)
}

private func projectionPostPage(
  parent: BrowsePost = projectionPost(),
  first: BrowsePost = projectionPost(id: 101, floor: 1)
) -> PostPageData {
  PostPageData(
    thread: projectionThread(), posts: [parent, projectionPost(id: 103, floor: 3)],
    currentPage: 1, hasMore: false, firstPost: first)
}

private enum NestedDeletionProjectionError: Error { case unexpectedRequest, timeout }

private actor NestedDeletionProjectionService: BrowseService {
  private var commentPages: [CommentPageData]
  private var postPages: [PostPageData]
  private var suspendComments = false
  private var suspendPosts = false
  private var commentsContinuation: CheckedContinuation<CommentPageData, Error>?
  private var postsContinuation: CheckedContinuation<PostPageData, Error>?
  private var requestedPages: [Int] = []

  init(commentPages: [CommentPageData] = [], postPages: [PostPageData] = []) {
    self.commentPages = commentPages
    self.postPages = postPages
  }

  func suspendNextComments() { suspendComments = true }
  func suspendNextPosts() { suspendPosts = true }
  func isCommentSuspended() -> Bool { commentsContinuation != nil }
  func isPostSuspended() -> Bool { postsContinuation != nil }
  func requestedCommentPages() -> [Int] { requestedPages }
  func resumeComments(_ page: CommentPageData) {
    commentsContinuation?.resume(returning: page)
    commentsContinuation = nil
  }
  func resumePosts(_ page: PostPageData) {
    postsContinuation?.resume(returning: page)
    postsContinuation = nil
  }

  func threads(forumName: String, page: Int, pageSize: Int, options: ForumBrowseOptions)
    async throws -> ThreadPageData
  { throw NestedDeletionProjectionError.unexpectedRequest }

  func posts(
    threadID: Int64, page: Int, pageSize: Int, options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    if suspendPosts {
      suspendPosts = false
      return try await withCheckedThrowingContinuation { postsContinuation = $0 }
    }
    guard !postPages.isEmpty else { throw NestedDeletionProjectionError.unexpectedRequest }
    return postPages.removeFirst()
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    requestedPages.append(page)
    if suspendComments {
      suspendComments = false
      return try await withCheckedThrowingContinuation { commentsContinuation = $0 }
    }
    guard !commentPages.isEmpty else { throw NestedDeletionProjectionError.unexpectedRequest }
    return commentPages.removeFirst()
  }

  func comments(threadID: Int64, postID: Int64, aroundCommentID: Int64, page: Int)
    async throws -> CommentPageData
  { try await comments(threadID: threadID, postID: postID, page: page) }

  func comments(threadID: Int64, resolvingCommentID: Int64) async throws -> CommentPageData {
    try await comments(threadID: threadID, postID: 102, page: 1)
  }
}

@MainActor
private func waitForProjection(_ condition: () async -> Bool) async throws {
  let deadline = Date().addingTimeInterval(3)
  while !(await condition()) {
    guard Date() < deadline else { throw NestedDeletionProjectionError.timeout }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
