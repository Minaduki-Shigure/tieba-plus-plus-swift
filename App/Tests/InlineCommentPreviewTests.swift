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

    XCTAssertEqual(presentation.comments.map(\.id), [1, 3])
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

    XCTAssertTrue(presentation.comments.isEmpty)
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

  func testFullCommentsActionIsOmittedOnlyWhenEveryReplyHasAVisiblePreview() throws {
    let fourComments = (1...4).map { comment(id: Int64($0)) }
    let complete = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 4, comments: fourComments),
        isPureReadingMode: false
      )
    )
    let partial = try XCTUnwrap(
      InlineCommentPreviewPresentation(
        post: post(totalCount: 6, comments: fourComments),
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
    XCTAssertTrue(partial.showsAllCommentsAction)
    XCTAssertTrue(mixed.showsAllCommentsAction)
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
        .image(thumbnail: imageURL, original: nil, width: 1, height: 1),
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
      .comment(threadID: 10, commentID: 30)
    )
    XCTAssertNil(CommentsRoute(threadID: 0, postID: 20, commentID: nil))
    XCTAssertNil(CommentsRoute(threadID: 10, postID: 0, commentID: 30))
    XCTAssertNil(CommentsRoute(threadID: 10, postID: 20, commentID: 0))
  }

  private func post(totalCount: Int, comments: [BrowseComment]) -> BrowsePost {
    BrowsePost(
      id: 20,
      threadID: 10,
      floor: 2,
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
    visibility: LocalContentVisibility = .visible
  ) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: id + 100,
      authorName: "Commenter \(id)",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("comment \(id)")],
      localVisibility: visibility
    )
  }
}
