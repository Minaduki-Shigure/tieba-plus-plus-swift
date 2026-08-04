import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ImageGalleryTests: XCTestCase {
  func testPresentationFiltersImagesAndPreservesOriginalContentOffsets() throws {
    let firstThumbnail = try url("https://example.com/first-thumb.jpg")
    let firstOriginal = try url("https://example.com/first-original.jpg")
    let secondThumbnail = try url("https://example.com/second-thumb.jpg")
    let contents: [BrowseContent] = [
      .text("before"),
      .image(thumbnail: firstThumbnail, original: firstOriginal, width: 100, height: 80),
      .video(url: nil, cover: nil, width: 0, height: 0),
      .image(thumbnail: secondThumbnail, original: nil, width: 80, height: 100),
      .voice(url: try url("https://example.com/voice.mp3"), duration: 3),
    ]

    let presentation = try XCTUnwrap(
      ImageGalleryPresentation(contents: contents, selectedContentOffset: 3)
    )

    XCTAssertEqual(
      presentation.items,
      [
        ImageGalleryItem(contentOffset: 1, url: firstOriginal, width: 100, height: 80),
        ImageGalleryItem(contentOffset: 3, url: secondThumbnail, width: 80, height: 100),
      ]
    )
    XCTAssertEqual(
      presentation.items.map(\.id),
      [
        .local(postID: nil, contentOffset: 1),
        .local(postID: nil, contentOffset: 3),
      ]
    )
    XCTAssertEqual(presentation.initialIndex, 1)
  }

  func testPresentationDoesNotMergeDuplicateURLsAndSelectsByContentOffset() throws {
    let duplicateURL = try url("https://example.com/duplicate.jpg")
    let contents: [BrowseContent] = [
      .image(thumbnail: duplicateURL, original: nil, width: 100, height: 100),
      .text("between"),
      .image(thumbnail: duplicateURL, original: duplicateURL, width: 200, height: 200),
    ]

    let presentation = try XCTUnwrap(
      ImageGalleryPresentation(contents: contents, selectedContentOffset: 2)
    )

    XCTAssertEqual(presentation.items.count, 2)
    XCTAssertEqual(presentation.items.map(\.url), [duplicateURL, duplicateURL])
    XCTAssertEqual(presentation.items.map(\.contentOffset), [0, 2])
    XCTAssertEqual(presentation.initialIndex, 1)
    XCTAssertEqual(presentation.id, .local(postID: nil, contentOffset: 2))
  }

  func testPresentationRejectsSelectionThatIsNotAnImageInTheSameContents() throws {
    let imageURL = try url("https://example.com/image.jpg")
    let contents: [BrowseContent] = [
      .text("not an image"),
      .image(thumbnail: imageURL, original: nil, width: 100, height: 100),
    ]

    XCTAssertNil(ImageGalleryPresentation(contents: contents, selectedContentOffset: 0))
    XCTAssertNil(ImageGalleryPresentation(contents: contents, selectedContentOffset: 2))
    XCTAssertNil(ImageGalleryPresentation(contents: [], selectedContentOffset: 0))
  }

  func testZoomGeometryClampsScaleToSupportedRange() {
    XCTAssertEqual(ImageZoomGeometry.clampedScale(0.5), 1)
    XCTAssertEqual(ImageZoomGeometry.clampedScale(3), 3)
    XCTAssertEqual(ImageZoomGeometry.clampedScale(8), 5)
    XCTAssertEqual(ImageZoomGeometry.clampedScale(.nan), 1)
    XCTAssertFalse(ImageZoomGeometry.allowsPanning(at: 1))
    XCTAssertTrue(ImageZoomGeometry.allowsPanning(at: 1.01))
  }

  func testLoadingPresentationUsesExactDeterminateProgressWhenLengthIsReliable() {
    let progress = RemoteImageDownloadProgress(
      receivedByteCount: 49,
      expectedByteCount: 100
    )

    XCTAssertEqual(
      ImageViewerLoadingPresentation.make(from: .downloading(progress)),
      .determinate(fraction: 0.49, percentage: 49)
    )
  }

  func testLoadingPresentationDoesNotInventPercentageForUnknownOrInvalidLength() {
    XCTAssertEqual(ImageViewerLoadingPresentation.make(from: nil), .indeterminate)
    XCTAssertEqual(
      ImageViewerLoadingPresentation.make(
        from: .downloading(
          RemoteImageDownloadProgress(receivedByteCount: 10, expectedByteCount: nil)
        )
      ),
      .indeterminate
    )
    XCTAssertEqual(
      ImageViewerLoadingPresentation.make(
        from: .downloading(
          RemoteImageDownloadProgress(receivedByteCount: 101, expectedByteCount: 100)
        )
      ),
      .indeterminate
    )
  }

  func testLoadingPresentationSeparatesDecodingFromTransfer() {
    XCTAssertEqual(ImageViewerLoadingPresentation.make(from: .decoding), .decoding)
  }

  func testZoomGeometryClampsPanAndResetsItAtOneTimesZoom() {
    let viewport = CGSize(width: 200, height: 100)

    XCTAssertEqual(
      ImageZoomGeometry.clampedOffset(
        CGSize(width: 500, height: -500),
        scale: 2,
        viewportSize: viewport
      ),
      CGSize(width: 100, height: -50)
    )
    XCTAssertEqual(
      ImageZoomGeometry.clampedOffset(
        CGSize(width: 40, height: 20),
        scale: 1,
        viewportSize: viewport
      ),
      .zero
    )
  }

  func testZoomGeometryUsesFittedImageSizeForDirectionalPanLimits() {
    let viewport = CGSize(width: 200, height: 200)
    let fittedImageSize = ImageZoomGeometry.fittedImageSize(
      width: 400,
      height: 200,
      viewportSize: viewport
    )

    XCTAssertEqual(fittedImageSize, CGSize(width: 200, height: 100))
    XCTAssertEqual(
      ImageZoomGeometry.clampedOffset(
        CGSize(width: 500, height: 500),
        scale: 2,
        viewportSize: viewport,
        fittedImageSize: fittedImageSize
      ),
      CGSize(width: 100, height: 0)
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }
}
