import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ImageGalleryTests: XCTestCase {
  func testPresentationFiltersImagesAndPreservesOriginalContentOffsets() throws {
    let firstThumbnail = try url("https://example.com/first-thumb.jpg")
    let firstOriginal = try url("https://example.com/first-original.jpg")
    let secondThumbnail = try url("https://example.com/second-thumb.jpg")
    let secondFullSize = try url("https://example.com/second-full.jpg")
    let contents: [BrowseContent] = [
      .text("before"),
      .image(
        thumbnail: firstThumbnail,
        fullSize: nil,
        original: firstOriginal,
        width: 100,
        height: 80
      ),
      .video(url: nil, cover: nil, width: 0, height: 0),
      .image(
        thumbnail: secondThumbnail,
        fullSize: secondFullSize,
        original: nil,
        width: 80,
        height: 100
      ),
      .voice(url: try url("https://example.com/voice.mp3"), duration: 3),
    ]

    let presentation = try XCTUnwrap(
      ImageGalleryPresentation(contents: contents, selectedContentOffset: 3)
    )

    XCTAssertEqual(
      presentation.items,
      [
        ImageGalleryItem(contentOffset: 1, url: firstOriginal, width: 100, height: 80),
        ImageGalleryItem(contentOffset: 3, url: secondFullSize, width: 80, height: 100),
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
      .image(
        thumbnail: duplicateURL,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      ),
      .text("between"),
      .image(
        thumbnail: duplicateURL,
        fullSize: nil,
        original: duplicateURL,
        width: 200,
        height: 200
      ),
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
      .image(
        thumbnail: imageURL,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      ),
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

  @MainActor
  func testPagingAxisUsesStableModeLabelsIconsAndOrientations() {
    XCTAssertEqual(ImageGalleryPagingAxis.allCases, [.horizontal, .vertical])
    XCTAssertEqual(ImageGalleryPagingAxis.horizontal.toggled, .vertical)
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.toggled, .horizontal)
    XCTAssertEqual(ImageGalleryPagingAxis.horizontal.title, "横向翻页")
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.title, "纵向翻页")
    XCTAssertEqual(ImageGalleryPagingAxis.horizontal.systemImage, "arrow.left.and.right")
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.systemImage, "arrow.up.and.down")
    XCTAssertEqual(ImageGalleryPagingAxis.horizontal.pageViewControllerOrientation, .horizontal)
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.pageViewControllerOrientation, .vertical)
    XCTAssertEqual(
      ImageGalleryPagingAxis.horizontal.transitionDirection(for: .left),
      .forward
    )
    XCTAssertEqual(
      ImageGalleryPagingAxis.horizontal.transitionDirection(for: .right),
      .reverse
    )
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.transitionDirection(for: .up), .forward)
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.transitionDirection(for: .down), .reverse)
    XCTAssertEqual(ImageGalleryPagingAxis.horizontal.transitionDirection(for: .next), .forward)
    XCTAssertEqual(ImageGalleryPagingAxis.vertical.transitionDirection(for: .previous), .reverse)
    XCTAssertNil(ImageGalleryPagingAxis.horizontal.transitionDirection(for: .up))
    XCTAssertNil(ImageGalleryPagingAxis.vertical.transitionDirection(for: .left))
  }

  func testPagerSnapshotPreservesStableSelectionAcrossPrependAndAppend() throws {
    let first = try item(1)
    let second = try item(2)
    let third = try item(3)
    let fourth = try item(4)
    let initial = ImageGalleryPagerSnapshot(
      items: [second, third],
      requestedSelection: third.id
    )
    let expanded = ImageGalleryPagerSnapshot(
      items: [first, second, third, fourth],
      requestedSelection: third.id
    )

    XCTAssertEqual(initial.resolvedSelection(currentID: nil), third.id)
    XCTAssertEqual(expanded.resolvedSelection(currentID: third.id), third.id)
    XCTAssertEqual(
      expanded.resolvedSelection(currentID: third.id, prefersCurrent: true),
      third.id
    )
    XCTAssertEqual(expanded.adjacentID(to: third.id, direction: .reverse), second.id)
    XCTAssertEqual(expanded.adjacentID(to: third.id, direction: .forward), fourth.id)
    XCTAssertEqual(expanded.transitionDirection(from: third.id, to: first.id), .reverse)
    XCTAssertEqual(expanded.transitionDirection(from: second.id, to: fourth.id), .forward)
  }

  func testPagerSnapshotFiltersDuplicateIDsAndUsesDeterministicFallback() throws {
    let first = try item(1)
    let duplicate = ImageGalleryItem(
      id: first.id,
      contentOffset: 99,
      url: try url("https://example.com/duplicate.jpg")
    )
    let second = try item(2)
    let missingID = ImageGalleryItem.ID.local(postID: nil, contentOffset: 999)
    let snapshot = ImageGalleryPagerSnapshot(
      items: [first, duplicate, second],
      requestedSelection: missingID
    )

    XCTAssertEqual(snapshot.items, [first, second])
    XCTAssertEqual(snapshot.resolvedSelection(currentID: nil), first.id)
    XCTAssertEqual(
      snapshot.resolvedSelection(currentID: second.id, prefersCurrent: true),
      second.id
    )
    XCTAssertNil(snapshot.adjacentID(to: first.id, direction: .reverse))
    XCTAssertNil(snapshot.adjacentID(to: second.id, direction: .forward))
  }

  func testPagerSnapshotRetainsAtMostCurrentPlusTwoNeighborsPerSide() throws {
    let items = try (1...9).map(item)
    let snapshot = ImageGalleryPagerSnapshot(items: items, requestedSelection: items[4].id)

    XCTAssertEqual(
      snapshot.retainingIDs(around: items[4].id),
      Set(items[2...6].map(\.id))
    )
    XCTAssertEqual(snapshot.retainingIDs(around: items[0].id).count, 3)
    XCTAssertEqual(snapshot.retainingIDs(around: items[4].id, radius: 1).count, 3)
    XCTAssertTrue(snapshot.retainingIDs(around: nil).isEmpty)
  }

  func testInteractiveTransitionKeepsNewerSelectionRequestAuthoritative() throws {
    let first = try item(1)
    let second = try item(2)
    let third = try item(3)

    XCTAssertFalse(
      ImageGalleryInteractiveTransitionPolicy.shouldPublishVisibleSelection(
        pendingRequestedSelection: third.id,
        hasPendingSnapshot: true,
        startingSelection: first.id,
        pendingContainsVisibleSelection: true
      )
    )
    XCTAssertNil(
      ImageGalleryInteractiveTransitionPolicy.preferredVisibleSelection(
        pendingRequestedSelection: third.id,
        startingSelection: first.id,
        visibleSelection: second.id,
        pendingContainsVisibleSelection: true
      )
    )
    XCTAssertTrue(
      ImageGalleryInteractiveTransitionPolicy.shouldPublishVisibleSelection(
        pendingRequestedSelection: first.id,
        hasPendingSnapshot: true,
        startingSelection: first.id,
        pendingContainsVisibleSelection: true
      )
    )
    XCTAssertEqual(
      ImageGalleryInteractiveTransitionPolicy.preferredVisibleSelection(
        pendingRequestedSelection: first.id,
        startingSelection: first.id,
        visibleSelection: second.id,
        pendingContainsVisibleSelection: true
      ),
      second.id
    )
    XCTAssertFalse(
      ImageGalleryInteractiveTransitionPolicy.shouldPublishVisibleSelection(
        pendingRequestedSelection: first.id,
        hasPendingSnapshot: true,
        startingSelection: first.id,
        pendingContainsVisibleSelection: false
      )
    )
    XCTAssertNil(
      ImageGalleryInteractiveTransitionPolicy.preferredVisibleSelection(
        pendingRequestedSelection: first.id,
        startingSelection: first.id,
        visibleSelection: second.id,
        pendingContainsVisibleSelection: false
      )
    )
  }

  func testAccessibilityDescriptionsUseRemoteAndSelectedGlobalPositions() throws {
    let local = try item(1)
    let remote = ImageGalleryItem(
      id: .remote(overallIndex: 8, pictureID: "picture", postID: 2),
      contentOffset: 2,
      url: try url("https://example.com/remote.jpg")
    )
    let descriptions = ImageGalleryAccessibilityPolicy.pageDescriptions(
      items: [local, remote],
      selectedID: local.id,
      selectedDisplayIndex: 7,
      totalCount: 20
    )

    XCTAssertEqual(descriptions[local.id], "第 7 张，共 20 张")
    XCTAssertEqual(descriptions[remote.id], "第 8 张，共 20 张")
  }

  @MainActor
  func testZoomStateStorePersistsStatesAndUsesBoundedLRU() throws {
    let first = try item(1)
    let second = try item(2)
    let third = try item(3)
    let store = ImageGalleryZoomStateStore(maximumRetainedStates: 2)
    let firstState = ImageGalleryZoomState(
      scale: 2,
      offset: CGSize(width: 10, height: -5)
    )
    let secondState = ImageGalleryZoomState(scale: 3, offset: .zero)
    let thirdState = ImageGalleryZoomState(scale: 4, offset: .zero)

    store.update(firstState, for: first.id)
    store.update(secondState, for: second.id)
    XCTAssertEqual(store.state(for: first.id), firstState)
    store.update(thirdState, for: third.id)

    XCTAssertEqual(store.state(for: first.id), firstState)
    XCTAssertEqual(store.state(for: second.id), .identity)
    XCTAssertEqual(store.state(for: third.id), thirdState)
    XCTAssertEqual(store.retainedStateCount, 2)

    store.retainOnly([third.id])
    XCTAssertEqual(store.state(for: first.id), .identity)
    XCTAssertEqual(store.retainedStateCount, 1)
  }

  func testIdentityZoomStateDropsOffset() {
    let state = ImageGalleryZoomState(
      scale: 1,
      offset: CGSize(width: 20, height: 20)
    )

    XCTAssertEqual(state, .identity)
  }

  func testPagingControlsAppearOnlyForKnownMultiImageGallery() {
    XCTAssertFalse(ImageViewerControlPolicy.showsPagingControls(itemCount: 0, totalCount: nil))
    XCTAssertFalse(ImageViewerControlPolicy.showsPagingControls(itemCount: 1, totalCount: 1))
    XCTAssertTrue(ImageViewerControlPolicy.showsPagingControls(itemCount: 2, totalCount: nil))
    XCTAssertTrue(ImageViewerControlPolicy.showsPagingControls(itemCount: 1, totalCount: 10))
    XCTAssertFalse(ImageViewerControlPolicy.showsPagingControls(itemCount: -1, totalCount: -2))
  }

  private func item(_ value: Int) throws -> ImageGalleryItem {
    ImageGalleryItem(
      contentOffset: value,
      url: try url("https://example.com/image-\(value).jpg")
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }
}
