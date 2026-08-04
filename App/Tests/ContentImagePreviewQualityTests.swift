import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ContentImagePreviewQualityTests: XCTestCase {
  func testStandardAndHighDefinitionSelectOnlyTheirPreviewSources() throws {
    let thumbnail = try url("https://img.example/standard.jpg")
    let fullSize = try url("https://img.example/high-definition.jpg")

    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail,
        fullSize: fullSize,
        quality: .standard
      ),
      thumbnail
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail,
        fullSize: fullSize,
        quality: .highDefinition
      ),
      fullSize
    )
  }

  func testHighDefinitionFallsBackToStandardWithoutChangingIdentity() throws {
    let thumbnail = try url("https://img.example/only-preview.jpg")

    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail,
        fullSize: nil,
        quality: .highDefinition
      ),
      thumbnail
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail,
        fullSize: thumbnail,
        quality: .highDefinition
      ),
      thumbnail
    )
  }

  func testGalleryAlwaysPrefersOriginalThenFullSizeThenThumbnail() throws {
    let thumbnail = try url("https://img.example/standard.jpg")
    let fullSize = try url("https://img.example/high-definition.jpg")
    let original = try url("https://img.example/original.jpg")

    XCTAssertEqual(
      BrowseContentImageSourceResolver.galleryURL(
        thumbnail: thumbnail,
        fullSize: fullSize,
        original: original
      ),
      original
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.galleryURL(
        thumbnail: thumbnail,
        fullSize: fullSize,
        original: nil
      ),
      fullSize
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.galleryURL(
        thumbnail: thumbnail,
        fullSize: nil,
        original: nil
      ),
      thumbnail
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }
}
