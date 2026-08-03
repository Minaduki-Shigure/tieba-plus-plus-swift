import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumPostSearchMediaPresentationTests: XCTestCase {
  func testExpandedPresentationKeepsFirstThreeURLsAndFullCount() throws {
    let urls = try (1...4).map { index in
      try XCTUnwrap(URL(string: "https://img.example/\(index).jpg"))
    }
    let contents = urls.map {
      BrowseContent.image(thumbnail: $0, original: nil, width: 100, height: 100)
    }

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: false),
      .expanded(imageURLs: Array(urls.prefix(3)), totalCount: 4)
    )
  }

  func testCollapsedPresentationKeepsOnlyFullImageCount() throws {
    let repeatedURL = try XCTUnwrap(URL(string: "https://img.example/repeated.jpg"))
    let contents = (0..<4).map { _ in
      BrowseContent.image(
        thumbnail: repeatedURL,
        original: nil,
        width: 100,
        height: 100
      )
    }

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: true),
      .collapsed(.images(count: 4))
    )
  }

  func testVideoOnlyContentRemainsWithoutMediaPresentation() throws {
    let videoURL = try XCTUnwrap(URL(string: "https://video.example/video.mp4"))
    let coverURL = try XCTUnwrap(URL(string: "https://img.example/cover.jpg"))
    let contents: [BrowseContent] = [
      .video(url: videoURL, cover: coverURL, width: 1_280, height: 720)
    ]

    for hidesMedia in [false, true] {
      XCTAssertEqual(
        ForumPostSearchMediaPresentation.resolve(
          contents: contents,
          hidesMedia: hidesMedia
        ),
        .none
      )
    }
  }

  func testImagePresentationIgnoresOtherContentKinds() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://img.example/image.jpg"))
    let videoURL = try XCTUnwrap(URL(string: "https://video.example/video.mp4"))
    let contents: [BrowseContent] = [
      .text("matched text"),
      .video(url: videoURL, cover: nil, width: 1_280, height: 720),
      .image(thumbnail: imageURL, original: nil, width: 100, height: 100),
    ]

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: false),
      .expanded(imageURLs: [imageURL], totalCount: 1)
    )
    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: true),
      .collapsed(.images(count: 1))
    )
  }

  func testContentWithoutImagesHasNoPresentation() {
    let contents: [BrowseContent] = [.text("matched text")]

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: false),
      .none
    )
    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(contents: contents, hidesMedia: true),
      .none
    )
  }
}
