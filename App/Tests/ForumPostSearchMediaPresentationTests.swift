import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumPostSearchMediaPresentationTests: XCTestCase {
  func testExpandedPresentationKeepsFirstThreeURLsAndFullCount() throws {
    let urls = try (1...4).map { index in
      try XCTUnwrap(URL(string: "https://img.example/\(index).jpg"))
    }
    let contents = urls.map {
      BrowseContent.image(
        thumbnail: $0,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      )
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
        fullSize: nil,
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

  func testExpandedPresentationUsesSelectedPreviewQuality() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://img.example/standard.jpg"))
    let fullSize = try XCTUnwrap(URL(string: "https://img.example/high-definition.jpg"))
    let contents: [BrowseContent] = [
      .image(
        thumbnail: thumbnail,
        fullSize: fullSize,
        original: try XCTUnwrap(URL(string: "https://img.example/original.jpg")),
        width: 100,
        height: 100
      )
    ]

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(
        contents: contents,
        hidesMedia: false,
        quality: .standard
      ),
      .expanded(imageURLs: [thumbnail], totalCount: 1)
    )
    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(
        contents: contents,
        hidesMedia: false,
        quality: .highDefinition
      ),
      .expanded(imageURLs: [fullSize], totalCount: 1)
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
      .image(
        thumbnail: imageURL,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      ),
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
