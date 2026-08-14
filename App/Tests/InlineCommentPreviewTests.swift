import Foundation
import XCTest

@testable import TiebaPlusPlus

final class InlineCommentPreviewTests: XCTestCase {
  func testPresentationUsesDeclaredTotalAndRemovesOnlyHiddenRows() throws {
    let visible = comment(id: 1, visibility: .visible)
    let hidden = comment(id: 2, visibility: .hidden)
    let placeholder = comment(id: 3, visibility: .placeholder)
    let post = post(totalCount: 8, comments: [visible, hidden, placeholder])

    let presentation = try XCTUnwrap(
      InlineCommentPreviewPresentation(post: post, isPureReadingMode: false)
    )

    XCTAssertEqual(presentation.items.map(\.comment.id), [1, 3])
    XCTAssertEqual(presentation.totalCount, 8)
    XCTAssertTrue(presentation.showsAllCommentsAction)
  }

  func testPresentationKeepsFullCommentsEntryWhenAllPreviewsAreHidden() throws {
    let post = post(
      totalCount: 1,
      comments: [comment(id: 1, visibility: .hidden)]
    )

    let presentation = try XCTUnwrap(
      InlineCommentPreviewPresentation(post: post, isPureReadingMode: false)
    )

    XCTAssertTrue(presentation.items.isEmpty)
    XCTAssertEqual(presentation.totalCount, 1)
    XCTAssertTrue(presentation.showsAllCommentsAction)
  }

  func testPresentationUsesPreviewCountAsSafeDisplayFallbackAndHidesInPureMode() throws {
    let post = post(
      totalCount: -1,
      comments: [comment(id: 1), comment(id: 2)]
    )

    XCTAssertEqual(
      InlineCommentPreviewPresentation(post: post, isPureReadingMode: false)?.totalCount,
      2
    )
    XCTAssertNil(InlineCommentPreviewPresentation(post: post, isPureReadingMode: true))
    XCTAssertNil(
      InlineCommentPreviewPresentation(
        post: self.post(totalCount: 0, comments: []),
        isPureReadingMode: false
      )
    )
  }

  func testPresentationKeepsOnlyFirstThreeNonHiddenRowsInSourceOrder() throws {
    let presentation = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(
          totalCount: 5,
          comments: [
            comment(id: 1, visibility: .hidden),
            comment(id: 2),
            comment(id: 3, visibility: .placeholder),
            comment(id: 4),
            comment(id: 5),
          ]
        ),
        isPureReadingMode: false
      )
    )

    XCTAssertEqual(InlineCommentPreviewPresentation.maximumVisibleItemCount, 3)
    XCTAssertEqual(presentation.items.map(\.comment.id), [2, 3, 4])
    XCTAssertTrue(presentation.showsAllCommentsAction)
  }

  func testFullCommentsActionIsOmittedOnlyWhenAllRepliesFitVisiblePreview() throws {
    let threeComments = (1...3).map { comment(id: Int64($0)) }
    let fourComments = (1...4).map { comment(id: Int64($0)) }
    let complete = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 3, comments: threeComments),
        isPureReadingMode: false
      )
    )
    let mappedOverflow = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 0, comments: fourComments),
        isPureReadingMode: false
      )
    )
    let serverOverflow = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 6, comments: threeComments),
        isPureReadingMode: false
      )
    )
    let mixed = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(
          totalCount: 4,
          comments: [
            comment(id: 1),
            comment(id: 2, visibility: .hidden),
            comment(id: 3, visibility: .placeholder),
            comment(id: 4),
          ]
        ),
        isPureReadingMode: false
      )
    )

    XCTAssertFalse(complete.showsAllCommentsAction)
    XCTAssertTrue(mappedOverflow.showsAllCommentsAction)
    XCTAssertTrue(serverOverflow.showsAllCommentsAction)
    XCTAssertTrue(mixed.showsAllCommentsAction)
  }

  func testPresentationPrecomputesPreviewBodyProjection() throws {
    let linkURL = try XCTUnwrap(URL(string: "https://secret.example/path"))
    let imageURL = try XCTUnwrap(URL(string: "https://secret.example/image.jpg"))
    let target = comment(
      id: 1,
      contents: [
        .text("hello "),
        .mention(name: "reader", userID: 7),
        .link(label: "文档", url: linkURL),
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 1,
          height: 1
        ),
      ]
    )

    let presentation = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 1, comments: [target]),
        isPureReadingMode: false
      )
    )
    let item = try XCTUnwrap(presentation.items.first)

    XCTAssertEqual(item.comment, target)
    XCTAssertEqual(item.bodyText, "hello @reader文档\n[图片]")
  }

  func testReplyPresentationBindsExactVisibleCommentAndStableAccessibilityID() throws {
    let target = comment(id: 31, threadID: 10, parentPostID: 20)
    let parent = post(totalCount: 1, comments: [target])

    let presentation = try XCTUnwrap(
      InlineCommentReplyPresentation(
        thread: thread(),
        parentPost: parent,
        comment: target,
        replyEntriesVisible: true
      )
    )

    XCTAssertEqual(
      presentation.context.target.destination,
      .subpost(parentPostID: 20, subpostID: 31)
    )
    XCTAssertEqual(presentation.context.kind, .subpost)
    XCTAssertEqual(presentation.context.replyingToName, "Commenter 31")
    XCTAssertEqual(presentation.context.replyingToUserID, target.authorID)
    XCTAssertEqual(presentation.accessibilityIdentifier, "inline-comment-reply-31")
  }

  func testReplyPresentationAcceptsCommentUnderExactFirstPost() throws {
    let target = comment(id: 31, threadID: 10, parentPostID: 100)
    let parent = post(
      id: 100,
      floor: 1,
      totalCount: 1,
      comments: [target]
    )

    let presentation = try XCTUnwrap(
      InlineCommentReplyPresentation(
        thread: thread(),
        parentPost: parent,
        comment: target,
        replyEntriesVisible: true
      )
    )

    XCTAssertEqual(
      presentation.context.target.destination,
      .subpost(parentPostID: 100, subpostID: 31)
    )
    XCTAssertEqual(presentation.context.kind, .subpost)
  }

  func testReplyPresentationRejectsDisabledFilteredAndStaleComments() {
    let target = comment(id: 31, threadID: 10, parentPostID: 20)
    let parent = post(totalCount: 1, comments: [target])

    XCTAssertNil(
      InlineCommentReplyPresentation(
        thread: thread(),
        parentPost: parent,
        comment: target,
        replyEntriesVisible: false
      )
    )
    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      let filtered = comment(
        id: 31,
        visibility: visibility,
        threadID: 10,
        parentPostID: 20
      )
      let filteredParent = post(totalCount: 1, comments: [filtered])
      XCTAssertNil(
        InlineCommentReplyPresentation(
          thread: thread(),
          parentPost: filteredParent,
          comment: filtered,
          replyEntriesVisible: true
        )
      )
    }
    XCTAssertNil(
      InlineCommentReplyPresentation(
        thread: thread(),
        parentPost: parent,
        comment: comment(id: 32, threadID: 10, parentPostID: 20),
        replyEntriesVisible: true
      )
    )
    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      XCTAssertNil(
        InlineCommentReplyPresentation(
          thread: thread(),
          parentPost: parent.withLocalVisibility(visibility),
          comment: target,
          replyEntriesVisible: true
        )
      )
    }
  }

  func testReplyPresentationRejectsMismatchedThreadAndParentIdentifiers() {
    for invalid in [
      comment(id: 31, threadID: 11, parentPostID: 20),
      comment(id: 31, threadID: 10, parentPostID: 21),
    ] {
      let parent = post(totalCount: 1, comments: [invalid])
      XCTAssertNil(
        InlineCommentReplyPresentation(
          thread: thread(),
          parentPost: parent,
          comment: invalid,
          replyEntriesVisible: true
        )
      )
    }
  }

  func testReplyPresentationRejectsDuplicateCommentIdentifiers() {
    let target = comment(id: 31, threadID: 10, parentPostID: 20)
    let duplicate = BrowseComment(
      id: target.id,
      authorID: 999,
      authorName: "Different author",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("different content")],
      threadID: 10,
      parentPostID: 20
    )
    let parent = post(totalCount: 2, comments: [target, duplicate])

    XCTAssertNil(
      InlineCommentReplyPresentation(
        thread: thread(),
        parentPost: parent,
        comment: target,
        replyEntriesVisible: true
      )
    )
  }

  func testCopyProjectionUsesLabelsAndFixedMediaMarkersWithoutResourceURLs() throws {
    let linkURL = try XCTUnwrap(URL(string: "https://secret.example/path"))
    let imageURL = try XCTUnwrap(URL(string: "https://secret.example/image.jpg"))
    let voiceURL = try XCTUnwrap(URL(string: "https://secret.example/voice.mp3"))

    XCTAssertEqual(
      BrowseContentCopyText.text([
        .text("hello "),
        .mention(name: "reader", userID: 7),
        .link(label: "文档", url: linkURL),
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 1,
          height: 1
        ),
        .voice(url: voiceURL, duration: 3),
        .video(url: nil, cover: nil, width: 0, height: 0),
      ]),
      "hello @reader文档\n[图片]\n[语音]\n[视频]"
    )
  }

  func testCommentsRouteValidatesEnclosingIdentifiersAndSeparatesAnchors() {
    XCTAssertEqual(
      CommentsRoute(threadID: 10, postID: 20, commentID: nil),
      .post(threadID: 10, postID: 20)
    )
    XCTAssertEqual(
      CommentsRoute(threadID: 10, postID: 20, commentID: 30),
      .comment(threadID: 10, postID: 20, commentID: 30)
    )
    XCTAssertNil(CommentsRoute(threadID: 0, postID: 20, commentID: nil))
    XCTAssertNil(CommentsRoute(threadID: 10, postID: 0, commentID: 30))
    XCTAssertNil(CommentsRoute(threadID: 10, postID: 20, commentID: 0))
  }

  private func thread() -> BrowseThread {
    BrowseThread(
      id: 10,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "",
      authorName: "Author",
      replyCount: 1,
      viewCount: 2,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("first")],
      authorID: 9,
      authorAvatarURL: nil,
      firstPostID: 100
    )
  }

  private func post(
    id: Int64 = 20,
    floor: Int = 2,
    totalCount: Int,
    comments: [BrowseComment]
  ) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: 10,
      floor: floor,
      authorID: 7,
      authorName: "Parent",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: totalCount,
      isThreadAuthor: false,
      contents: [.text("parent")],
      inlineComments: comments
    )
  }

  private func comment(
    id: Int64,
    visibility: LocalContentVisibility = .visible,
    threadID: Int64 = 0,
    parentPostID: Int64 = 0,
    contents: [BrowseContent]? = nil
  ) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: id + 100,
      authorName: "Commenter \(id)",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: contents ?? [.text("comment \(id)")],
      localVisibility: visibility,
      threadID: threadID,
      parentPostID: parentPostID
    )
  }
}
