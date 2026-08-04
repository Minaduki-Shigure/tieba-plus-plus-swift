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
}
