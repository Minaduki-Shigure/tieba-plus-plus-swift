import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ThreadSummaryRowTests: XCTestCase {
  func testVideoCoverTakesPriorityOverImages() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let coverURL = try XCTUnwrap(URL(string: "https://example.com/video.jpg"))
    let thread = makeThread(
      contents: [
        .image(thumbnail: imageURL, original: nil, width: 100, height: 100),
        .video(url: nil, cover: coverURL, width: 1280, height: 720),
      ]
    )

    XCTAssertEqual(ThreadSummaryPresentation.media(for: thread), .video(coverURL))
  }

  func testImagePreviewIsBoundedToFirstThreeImages() throws {
    let urls = try (1...4).map { index in
      try XCTUnwrap(URL(string: "https://example.com/\(index).jpg"))
    }
    let thread = makeThread(
      contents: urls.map {
        .image(thumbnail: $0, original: nil, width: 100, height: 100)
      }
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread),
      .images(Array(urls.prefix(3)), totalCount: 4)
    )
  }

  func testPinnedThreadNeverLoadsInlineMedia() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let thread = makeThread(
      contents: [.image(thumbnail: imageURL, original: nil, width: 100, height: 100)],
      isPinned: true
    )

    XCTAssertNil(ThreadSummaryPresentation.media(for: thread))
  }

  private func makeThread(
    contents: [BrowseContent],
    isPinned: Bool = false
  ) -> BrowseThread {
    BrowseThread(
      id: 42,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "Excerpt",
      authorName: "Author",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: contents,
      isPinned: isPinned
    )
  }
}
