import Foundation
import XCTest

@testable import TiebaPlusPlus

final class PostCopyTextTests: XCTestCase {
  func testFirstFloorCopyIncludesTitleAndPublicTextFragments() throws {
    let post = makePost(
      floor: 1,
      contents: [
        .text(" hello "),
        .mention(name: "reader", userID: 7),
        .text("\n"),
        .link(label: "文档", url: try XCTUnwrap(URL(string: "https://example.com"))),
        .emoticon(name: "[笑]", url: nil),
        .unsupported(label: "未知内容"),
        .image(
          thumbnail: try XCTUnwrap(URL(string: "https://example.com/thumb.jpg")),
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
        .video(url: nil, cover: nil, width: 0, height: 0),
      ]
    )

    XCTAssertEqual(
      PostCopyText.text(threadTitle: " A thread ", post: post),
      "A thread\nhello @reader\n文档[笑][未知内容]\n[图片]\n[视频]"
    )
  }

  func testReplyCopyOmitsThreadTitleAndUsesURLForUnlabelledLink() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/path"))
    let post = makePost(
      floor: 2,
      contents: [.text("reply "), .link(label: "", url: url)]
    )

    XCTAssertEqual(
      PostCopyText.text(threadTitle: "A thread", post: post),
      "reply example.com"
    )
  }

  func testMediaOnlyReplyPreservesPublicContentBoundariesWithoutURLs() throws {
    let post = makePost(
      floor: 2,
      contents: [
        .image(
          thumbnail: try XCTUnwrap(URL(string: "https://example.com/thumb.jpg")),
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
        .voice(url: try XCTUnwrap(URL(string: "https://example.com/voice.mp3")), duration: 3),
      ]
    )

    XCTAssertEqual(
      PostCopyText.text(threadTitle: "A thread", post: post),
      "[图片]\n[语音]"
    )
  }

  func testProjectionExcludesEveryResourceURLAndMentionIdentifier() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://secret.invalid/thumb?token=thumb"))
    let fullSize = try XCTUnwrap(URL(string: "https://secret.invalid/full?token=full"))
    let original = try XCTUnwrap(URL(string: "https://secret.invalid/original?token=original"))
    let dynamic = try XCTUnwrap(URL(string: "https://secret.invalid/dynamic?token=dynamic"))
    let video = try XCTUnwrap(URL(string: "https://secret.invalid/video?token=video"))
    let cover = try XCTUnwrap(URL(string: "https://secret.invalid/cover?token=cover"))
    let page = try XCTUnwrap(URL(string: "https://secret.invalid/page?token=page"))
    let voice = try XCTUnwrap(URL(string: "https://secret.invalid/voice?token=voice"))
    let emoticon = try XCTUnwrap(URL(string: "https://secret.invalid/emote?token=emote"))
    let post = makePost(
      floor: 2,
      contents: [
        .mention(name: "reader", userID: 8_675_309),
        .image(
          thumbnail: thumbnail,
          fullSize: fullSize,
          original: original,
          dynamic: dynamic,
          width: 1,
          height: 1
        ),
        .video(url: video, cover: cover, width: 1, height: 1, pageURL: page),
        .voice(url: voice, duration: 3),
        .emoticon(name: "[笑]", url: emoticon),
      ]
    )

    let projection = try XCTUnwrap(PostCopyText.text(threadTitle: nil, post: post))

    XCTAssertEqual(projection, "@reader\n[图片]\n[视频]\n[语音]\n[笑]")
    for sentinel in [
      "thumb", "full", "original", "dynamic", "video", "cover", "page", "voice",
      "emote", "token=", "8675309",
    ] {
      XCTAssertFalse(projection.contains(sentinel), "Projection leaked \(sentinel)")
    }
  }

  func testFirstFloorOmitsTitleWhenCallingSurfaceDoesNotAuthorizeIt() {
    let post = makePost(floor: 1, contents: [.text("body")])

    XCTAssertEqual(PostCopyText.text(threadTitle: nil, post: post), "body")
  }

  func testFilteredPostAndParentProduceNoSelectableProjection() {
    let post = makePost(floor: 2, contents: [.text("hidden")])
      .withLocalPresentation(visibility: .placeholder, inlineComments: [])
    let parent = makeParentPost(floor: 2, id: 10, contents: [.text("hidden")])
      .withLocalVisibility(.hidden)

    XCTAssertNil(PostCopyText.text(threadTitle: nil, post: post))
    XCTAssertNil(PostCopyText.text(thread: nil, parentPost: parent))
  }

  func testHostlessUnlabelledLinkUsesFixedMarkerInsteadOfAbsoluteURL() throws {
    let url = try XCTUnwrap(URL(string: "mailto:secret@example.com?token=private"))
    let post = makePost(floor: 2, contents: [.link(label: "", url: url)])

    XCTAssertEqual(PostCopyText.text(threadTitle: nil, post: post), "[链接]")
  }

  func testFilteredCommentProducesNoSelectableProjection() {
    let visible = makeComment(visibility: .visible)
    let placeholder = makeComment(visibility: .placeholder)
    let hidden = makeComment(visibility: .hidden)

    XCTAssertEqual(PostCopyText.text(comment: visible), "child")
    XCTAssertNil(PostCopyText.text(comment: placeholder))
    XCTAssertNil(PostCopyText.text(comment: hidden))
  }

  func testCommentParentFirstFloorIncludesOnlyVisibleMatchingThreadTitle() {
    let parent = makeParentPost(floor: 1, id: 9, contents: [.text("body")])
    let visibleThread = makeThread(firstPostID: 9, localVisibility: .visible)
    let filteredThread = makeThread(firstPostID: 9, localVisibility: .placeholder)
    let mismatchedThread = makeThread(firstPostID: 10, localVisibility: .visible)

    XCTAssertEqual(
      PostCopyText.text(thread: visibleThread, parentPost: parent),
      "A thread\nbody"
    )
    XCTAssertEqual(PostCopyText.text(thread: filteredThread, parentPost: parent), "body")
    XCTAssertEqual(PostCopyText.text(thread: mismatchedThread, parentPost: parent), "body")
    XCTAssertEqual(PostCopyText.text(thread: nil, parentPost: parent), "body")
  }

  func testCommentParentOrdinaryFloorNeverIncludesThreadTitle() {
    let parent = makeParentPost(floor: 2, id: 10, contents: [.text("body")])

    XCTAssertEqual(
      PostCopyText.text(
        thread: makeThread(firstPostID: 9, localVisibility: .visible),
        parentPost: parent
      ),
      "body"
    )
  }

  private func makePost(floor: Int, contents: [BrowseContent]) -> BrowsePost {
    BrowsePost(
      id: Int64(floor),
      threadID: 42,
      floor: floor,
      authorID: 7,
      authorName: "reader",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: floor == 1,
      contents: contents
    )
  }

  private func makeParentPost(
    floor: Int,
    id: Int64,
    contents: [BrowseContent]
  ) -> CommentParentPostContext {
    CommentParentPostContext(
      id: id,
      threadID: 42,
      floor: floor,
      authorID: 7,
      authorName: "reader",
      authorPortraitURL: nil,
      createdAt: nil,
      isThreadAuthor: floor == 1,
      contents: contents
    )
  }

  private func makeThread(
    firstPostID: Int64,
    localVisibility: LocalContentVisibility
  ) -> BrowseThread {
    BrowseThread(
      id: 42,
      forumID: 2,
      forumName: "swift",
      title: " A thread ",
      excerpt: "",
      authorName: "reader",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      firstPostID: firstPostID,
      localVisibility: localVisibility
    )
  }

  private func makeComment(visibility: LocalContentVisibility) -> BrowseComment {
    BrowseComment(
      id: 20,
      authorID: 7,
      authorName: "reader",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("child")],
      localVisibility: visibility,
      threadID: 42,
      parentPostID: 9
    )
  }
}
