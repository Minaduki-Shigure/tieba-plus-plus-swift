import Foundation
import UIKit
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

  func testZoomGeometryExposesTheSameValidatedPanLimitsUsedForClamping() {
    let viewport = CGSize(width: 200, height: 200)
    let fittedImage = CGSize(width: 200, height: 100)

    XCTAssertEqual(
      ImageZoomGeometry.panLimits(
        scale: 2,
        viewportSize: viewport,
        fittedImageSize: fittedImage
      ),
      ImageZoomPanLimits(horizontal: 100, vertical: 0)
    )
    XCTAssertEqual(
      ImageZoomGeometry.panLimits(
        scale: 1,
        viewportSize: viewport,
        fittedImageSize: fittedImage
      ),
      ImageZoomPanLimits(horizontal: 0, vertical: 0)
    )
    XCTAssertNil(
      ImageZoomGeometry.panLimits(
        scale: 2,
        viewportSize: .zero,
        fittedImageSize: fittedImage
      )
    )
    XCTAssertNil(
      ImageZoomGeometry.panLimits(
        scale: 2,
        viewportSize: viewport,
        fittedImageSize: CGSize(width: CGFloat.infinity, height: 100)
      )
    )
    for invalidScale in [CGFloat.nan, .infinity, 0.5, 6] {
      XCTAssertNil(
        ImageZoomGeometry.panLimits(
          scale: invalidScale,
          viewportSize: viewport,
          fittedImageSize: fittedImage
        )
      )
    }
  }

  func testPanOwnershipKeepsInteriorGestureWithImageForItsWholeLifetime() {
    let limits = ImageZoomPanLimits(horizontal: 100, vertical: 50)

    XCTAssertEqual(
      panOwnership(limits: limits, offset: .zero, velocity: CGSize(width: 30, height: 1)),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: .zero,
        velocity: .zero,
        translation: CGSize(width: 1_000, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(limits: limits, offset: .zero, velocity: CGSize(width: 1, height: -30)),
      .image
    )
  }

  func testPanOwnershipYieldsOnlyForOutwardMovementAtCurrentEdge() {
    let limits = ImageZoomPanLimits(horizontal: 100, vertical: 50)

    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100, height: 0),
        velocity: CGSize(width: 20, height: 0)
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100, height: 0),
        velocity: CGSize(width: -20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: -100, height: 0),
        velocity: CGSize(width: -20, height: 0)
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: -100, height: 0),
        velocity: CGSize(width: 20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 0, height: 50),
        velocity: CGSize(width: 0, height: 20)
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 0, height: -50),
        velocity: CGSize(width: 0, height: -20)
      ),
      .pager
    )
  }

  func testPanOwnershipMatchesTiebaLiteAxisAndRoundedEdgeRules() {
    let limits = ImageZoomPanLimits(horizontal: 100.2, vertical: 50)

    // Equal movement resolves vertically, so the horizontal edge does not yield.
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100.2, height: 0),
        velocity: CGSize(width: 10, height: 10)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100.2, height: 0),
        velocity: CGSize(width: 11, height: 10)
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 99.6, height: 0),
        velocity: CGSize(width: 20, height: 0),
        displayScale: 1
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 99.6, height: 0),
        velocity: CGSize(width: 20, height: 0),
        displayScale: 3
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100.2, height: 0),
        velocity: CGSize(width: 20, height: 0),
        displayScale: 3
      ),
      .pager
    )
    XCTAssertEqual(
      panOwnership(
        limits: ImageZoomPanLimits(horizontal: 100.8, vertical: 50),
        offset: CGSize(width: 100.4, height: 0),
        velocity: CGSize(width: 20, height: 0),
        displayScale: 1
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: ImageZoomPanLimits(horizontal: 100.5, vertical: 50),
        offset: CGSize(width: -100.4, height: 0),
        velocity: CGSize(width: -20, height: 0),
        displayScale: 1
      ),
      .pager
    )
    for displayScale in [CGFloat(1), 2, 3] {
      XCTAssertEqual(
        panOwnership(
          limits: ImageZoomPanLimits(horizontal: 0.4, vertical: 50),
          offset: .zero,
          velocity: CGSize(width: 20, height: 0),
          displayScale: displayScale
        ),
        displayScale == 1 ? .pager : .image
      )
    }
  }

  func testPanOwnershipFailsClosedForMissingOrInvalidState() {
    let limits = ImageZoomPanLimits(horizontal: 100, vertical: 50)

    XCTAssertEqual(
      panOwnership(limits: nil, offset: .zero, velocity: CGSize(width: 20, height: 0)),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: CGFloat.nan, height: 0),
        velocity: CGSize(width: 20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: ImageZoomPanLimits(horizontal: -1, vertical: 50),
        offset: .zero,
        velocity: CGSize(width: 20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(limits: limits, offset: .zero, velocity: .zero),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: .zero,
        velocity: CGSize(width: CGFloat.nan, height: 0),
        translation: CGSize(width: 20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: .zero,
        velocity: CGSize(width: 20, height: 0),
        translation: CGSize(width: CGFloat.infinity, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: ImageZoomPanLimits(horizontal: 3_000_000_000, vertical: 50),
        offset: CGSize(width: 3_000_000_000, height: 0),
        velocity: CGSize(width: 20, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: .zero,
        velocity: CGSize(width: 20, height: 0),
        displayScale: .nan
      ),
      .image
    )
  }

  func testPanOwnershipPrefersVelocityOverConflictingTranslation() {
    let limits = ImageZoomPanLimits(horizontal: 100, vertical: 50)

    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100, height: 0),
        velocity: CGSize(width: -20, height: 0),
        translation: CGSize(width: 200, height: 0)
      ),
      .image
    )
    XCTAssertEqual(
      panOwnership(
        limits: limits,
        offset: CGSize(width: 100, height: 0),
        velocity: CGSize(width: 20, height: 0),
        translation: CGSize(width: -200, height: 0)
      ),
      .pager
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

  @MainActor
  func testCoordinatorKeepsNativePagerEnabledForSingleFingerEdgeDrags() throws {
    let pageViewController = ImageGalleryPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: nil
    )
    let pagingScrollView = try XCTUnwrap(pageViewController.pagingScrollView)
    pagingScrollView.isScrollEnabled = false
    pagingScrollView.isDirectionalLockEnabled = false
    pagingScrollView.panGestureRecognizer.maximumNumberOfTouches = 4

    let coordinator = ImageGalleryPager.Coordinator()
    coordinator.attach(to: pageViewController, axis: .horizontal)

    XCTAssertTrue(pagingScrollView.isScrollEnabled)
    XCTAssertTrue(pagingScrollView.isDirectionalLockEnabled)
    XCTAssertEqual(pagingScrollView.panGestureRecognizer.maximumNumberOfTouches, 1)
    coordinator.detach()
  }

  @MainActor
  func testImagePanRecognizerArbitratesWithItsEnclosingPager() throws {
    let pageViewController = ImageGalleryPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: nil
    )
    let pagingScrollView = try XCTUnwrap(pageViewController.pagingScrollView)
    let overlayView = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    pagingScrollView.addSubview(overlayView)

    let coordinator = ImageZoomPanGestureOverlay.Coordinator()
    let imagePan = coordinator.panGestureRecognizer
    overlayView.addGestureRecognizer(imagePan)
    coordinator.update(
      from: panOverlay(
        scale: 2,
        offset: .zero,
        viewportSize: overlayView.bounds.size,
        fittedImageSize: overlayView.bounds.size
      )
    )

    XCTAssertEqual(imagePan.minimumNumberOfTouches, 1)
    XCTAssertEqual(imagePan.maximumNumberOfTouches, 1)
    XCTAssertFalse(imagePan.cancelsTouchesInView)
    XCTAssertTrue(
      coordinator.shouldImagePanBegin(
        velocity: .zero,
        translation: CGSize(width: 20, height: 0)
      )
    )
    XCTAssertTrue(
      coordinator.gestureRecognizer(
        imagePan,
        shouldBeRequiredToFailBy: pagingScrollView.panGestureRecognizer
      )
    )
    XCTAssertFalse(
      coordinator.gestureRecognizer(
        imagePan,
        shouldRecognizeSimultaneouslyWith: pagingScrollView.panGestureRecognizer
      )
    )

    coordinator.update(
      from: panOverlay(
        scale: 2,
        offset: CGSize(width: 100, height: 0),
        viewportSize: overlayView.bounds.size,
        fittedImageSize: overlayView.bounds.size
      )
    )
    XCTAssertFalse(
      coordinator.shouldImagePanBegin(
        velocity: .zero,
        translation: CGSize(width: 20, height: 0)
      )
    )

    coordinator.update(
      from: panOverlay(
        scale: 1.001,
        offset: .zero,
        viewportSize: CGSize(width: 2_000, height: 2_000),
        fittedImageSize: CGSize(width: 2_000, height: 2_000)
      )
    )
    XCTAssertFalse(
      coordinator.shouldImagePanBegin(
        velocity: .zero,
        translation: CGSize(width: 20, height: 0)
      )
    )

    for invalidScale in [CGFloat.nan, .infinity, 0.5, 6] {
      coordinator.update(
        from: panOverlay(
          scale: invalidScale,
          offset: .zero,
          viewportSize: overlayView.bounds.size,
          fittedImageSize: overlayView.bounds.size
        )
      )
      XCTAssertTrue(
        coordinator.shouldImagePanBegin(
          velocity: .zero,
          translation: CGSize(width: 20, height: 0)
        )
      )
    }

    let pinch = UIPinchGestureRecognizer()
    overlayView.addGestureRecognizer(pinch)
    XCTAssertTrue(
      coordinator.gestureRecognizer(
        imagePan,
        shouldRecognizeSimultaneouslyWith: pinch
      )
    )

    let unrelatedScrollView = UIScrollView()
    XCTAssertFalse(
      coordinator.gestureRecognizer(
        imagePan,
        shouldBeRequiredToFailBy: unrelatedScrollView.panGestureRecognizer
      )
    )
    coordinator.detach()
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

  func testIDMigrationValidatesRetiredSourcesExistingTargetsAndUniqueDestinations() {
    let firstSource = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let secondSource = ImageGalleryItem.ID.local(postID: 1, contentOffset: 1)
    let retainedSource = ImageGalleryItem.ID.local(postID: 1, contentOffset: 2)
    let target = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "target",
      postID: 1
    )
    let missingTarget = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "missing",
      postID: 1
    )

    let conflicting = ImageGalleryItemIDMigration([
      firstSource: target,
      secondSource: target,
    ]).normalized(for: [target])
    XCTAssertTrue(conflicting.destinations.isEmpty)

    let invalidEndpoints = ImageGalleryItemIDMigration([
      firstSource: missingTarget,
      retainedSource: target,
    ]).normalized(for: [retainedSource, target])
    XCTAssertTrue(invalidEndpoints.destinations.isEmpty)
  }

  func testPagerUpdateComposesDeltaMigrationsAndLatestCumulativeSourceWins() throws {
    let localID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let intermediateID = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "intermediate",
      postID: 1
    )
    let finalID = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "final",
      postID: 1
    )
    let cumulativeID = ImageGalleryItem.ID.remote(
      overallIndex: 3,
      pictureID: "cumulative",
      postID: 1
    )
    let intermediate = ImageGalleryPagerUpdate(
      snapshot: ImageGalleryPagerSnapshot(
        items: [try item(id: intermediateID, value: 1)],
        requestedSelection: intermediateID
      ),
      idMigrations: [localID: intermediateID],
      accessibilityPageDescriptions: [intermediateID: "intermediate"]
    ).normalized()
    let final = ImageGalleryPagerUpdate(
      snapshot: ImageGalleryPagerSnapshot(
        items: [try item(id: finalID, value: 2)],
        requestedSelection: finalID
      ),
      idMigrations: [intermediateID: finalID],
      accessibilityPageDescriptions: [finalID: "final"]
    )

    let composed = intermediate.merging(final)
    XCTAssertEqual(composed.migration.destinations, [localID: finalID])
    XCTAssertEqual(composed.accessibilityPageDescriptions, [finalID: "final"])
    XCTAssertEqual(composed.normalized(), composed)

    let cumulative = ImageGalleryPagerUpdate(
      snapshot: ImageGalleryPagerSnapshot(
        items: [try item(id: cumulativeID, value: 3)],
        requestedSelection: cumulativeID
      ),
      idMigrations: [localID: cumulativeID],
      accessibilityPageDescriptions: [cumulativeID: "cumulative"]
    )
    let overridden = composed.merging(cumulative)
    XCTAssertEqual(overridden.migration.destinations, [localID: cumulativeID])
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

  func testInteractiveTransitionResolvesSelectionsInMigratedIDNamespace() throws {
    let localFirst = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let localSecond = ImageGalleryItem.ID.local(postID: 1, contentOffset: 1)
    let remoteFirst = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "first",
      postID: 1
    )
    let remoteSecond = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "second",
      postID: 1
    )
    let update = ImageGalleryPagerUpdate(
      snapshot: ImageGalleryPagerSnapshot(
        items: [
          try item(id: remoteFirst, value: 1),
          try item(id: remoteSecond, value: 2),
        ],
        requestedSelection: remoteFirst
      ),
      idMigrations: [
        localFirst: remoteFirst,
        localSecond: remoteSecond,
      ],
      accessibilityPageDescriptions: [:]
    ).normalized()

    XCTAssertEqual(
      ImageGalleryInteractiveTransitionPolicy.resolve(
        completed: true,
        pendingUpdate: update,
        startingSelection: localFirst,
        visibleSelection: localSecond
      ),
      ImageGalleryInteractiveTransitionResolution(
        selectionToPublish: remoteSecond,
        preferredVisibleSelection: remoteSecond
      )
    )
    XCTAssertEqual(
      ImageGalleryInteractiveTransitionPolicy.resolve(
        completed: false,
        pendingUpdate: update,
        startingSelection: localFirst,
        visibleSelection: localFirst
      ),
      ImageGalleryInteractiveTransitionResolution(
        selectionToPublish: nil,
        preferredVisibleSelection: remoteFirst
      )
    )

    let newerSelection = ImageGalleryPagerUpdate(
      snapshot: ImageGalleryPagerSnapshot(
        items: update.snapshot.items,
        requestedSelection: remoteSecond
      ),
      idMigrations: update.migration.destinations,
      accessibilityPageDescriptions: [:]
    ).normalized()
    XCTAssertEqual(
      ImageGalleryInteractiveTransitionPolicy.resolve(
        completed: true,
        pendingUpdate: newerSelection,
        startingSelection: localFirst,
        visibleSelection: localSecond
      ),
      ImageGalleryInteractiveTransitionResolution(
        selectionToPublish: nil,
        preferredVisibleSelection: nil
      )
    )
  }

  func testAnimationPlaybackOwnershipTransfersOnlyAfterInteractiveCompletion() throws {
    let first = try item(1)
    let second = try item(2)
    let validIDs = Set([first.id, second.id])
    var ownership = ImageGalleryAnimationPlaybackOwnership()

    ownership.reconcileVisible(first.id, validIDs: validIDs)
    XCTAssertEqual(ownership.ownerID, first.id)
    XCTAssertEqual(ownership.enabledIDs, [first.id])

    ownership.beginInteractive(visibleID: first.id, validIDs: validIDs)
    ownership.reconcileVisible(second.id, validIDs: validIDs)
    XCTAssertEqual(ownership.ownerID, first.id)
    XCTAssertEqual(ownership.enabledIDs, [first.id])

    ownership.finishInteractive(
      completed: false,
      visibleID: second.id,
      validIDs: validIDs
    )
    XCTAssertEqual(ownership.ownerID, first.id)
    XCTAssertEqual(ownership.enabledIDs, [first.id])

    ownership.beginInteractive(visibleID: first.id, validIDs: validIDs)
    ownership.finishInteractive(
      completed: true,
      visibleID: second.id,
      validIDs: validIDs
    )
    XCTAssertEqual(ownership.ownerID, second.id)
    XCTAssertEqual(ownership.enabledIDs, [second.id])
    XCTAssertLessThanOrEqual(ownership.enabledIDs.count, 1)
  }

  func testAnimationPlaybackOwnershipKeepsSourceDuringProgrammaticTransition() throws {
    let first = try item(1)
    let second = try item(2)
    let validIDs = Set([first.id, second.id])
    var ownership = ImageGalleryAnimationPlaybackOwnership()

    ownership.reconcileVisible(first.id, validIDs: validIDs)
    ownership.beginProgrammatic(
      targetID: second.id,
      visibleID: first.id,
      validIDs: validIDs
    )
    ownership.reconcileVisible(second.id, validIDs: validIDs)
    XCTAssertEqual(ownership.ownerID, first.id)
    XCTAssertEqual(ownership.enabledIDs, [first.id])

    ownership.finishProgrammatic(
      completed: false,
      visibleID: first.id,
      validIDs: validIDs
    )
    XCTAssertEqual(ownership.ownerID, first.id)

    ownership.beginProgrammatic(
      targetID: second.id,
      visibleID: first.id,
      validIDs: validIDs
    )
    ownership.finishProgrammatic(
      completed: true,
      visibleID: second.id,
      validIDs: validIDs
    )
    XCTAssertEqual(ownership.ownerID, second.id)
    XCTAssertEqual(ownership.enabledIDs, [second.id])
    XCTAssertLessThanOrEqual(ownership.enabledIDs.count, 1)
  }

  func testAnimationPlaybackOwnershipMigratesPrunesAndDetaches() {
    let localID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let remoteID = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "remote",
      postID: 1
    )
    let otherID = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "other",
      postID: 1
    )
    var ownership = ImageGalleryAnimationPlaybackOwnership()

    ownership.reconcileVisible(localID, validIDs: [localID, otherID])
    ownership.beginInteractive(visibleID: localID, validIDs: [localID, otherID])
    ownership.migrate(
      ImageGalleryItemIDMigration([localID: remoteID]),
      validIDs: [remoteID, otherID]
    )
    XCTAssertEqual(ownership.ownerID, remoteID)
    XCTAssertEqual(
      ownership.transition,
      .interactive(startingOwnerID: remoteID)
    )
    XCTAssertEqual(ownership.enabledIDs, [remoteID])

    ownership.finishInteractive(
      completed: false,
      visibleID: otherID,
      validIDs: [remoteID, otherID]
    )
    XCTAssertEqual(ownership.ownerID, remoteID)
    ownership.retainOnly([otherID])
    XCTAssertNil(ownership.ownerID)
    XCTAssertTrue(ownership.enabledIDs.isEmpty)

    ownership.reconcileVisible(otherID, validIDs: [otherID])
    ownership.detach()
    XCTAssertNil(ownership.ownerID)
    XCTAssertEqual(ownership.transition, .idle)
    XCTAssertTrue(ownership.enabledIDs.isEmpty)
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

  @MainActor
  func testZoomStateMigrationPreservesLRUAndLetsExistingDestinationWin() throws {
    let source = try item(1)
    let destination = try item(2)
    let other = try item(3)
    let newest = try item(4)
    let sourceState = ImageGalleryZoomState(scale: 2, offset: .zero)
    let destinationState = ImageGalleryZoomState(scale: 3, offset: .zero)
    let otherState = ImageGalleryZoomState(scale: 4, offset: .zero)
    let migration = ImageGalleryItemIDMigration([source.id: destination.id])
      .normalized(for: [destination.id, other.id, newest.id])

    let targetWinsStore = ImageGalleryZoomStateStore(maximumRetainedStates: 2)
    targetWinsStore.update(sourceState, for: source.id)
    targetWinsStore.update(destinationState, for: destination.id)
    targetWinsStore.migrate(migration)
    targetWinsStore.retainOnly([destination.id])
    XCTAssertEqual(targetWinsStore.state(for: source.id), .identity)
    XCTAssertEqual(targetWinsStore.state(for: destination.id), destinationState)
    XCTAssertEqual(targetWinsStore.retainedStateCount, 1)

    let visibleIdentityTargetStore = ImageGalleryZoomStateStore(maximumRetainedStates: 2)
    visibleIdentityTargetStore.update(sourceState, for: source.id)
    visibleIdentityTargetStore.migrate(migration, destinationWins: [destination.id])
    visibleIdentityTargetStore.retainOnly([destination.id])
    XCTAssertEqual(visibleIdentityTargetStore.state(for: source.id), .identity)
    XCTAssertEqual(visibleIdentityTargetStore.state(for: destination.id), .identity)
    XCTAssertEqual(visibleIdentityTargetStore.retainedStateCount, 0)

    let lruStore = ImageGalleryZoomStateStore(maximumRetainedStates: 2)
    lruStore.update(sourceState, for: source.id)
    lruStore.update(otherState, for: other.id)
    lruStore.migrate(migration)
    lruStore.retainOnly([destination.id, other.id, newest.id])
    lruStore.update(ImageGalleryZoomState(scale: 5, offset: .zero), for: newest.id)
    XCTAssertEqual(lruStore.state(for: destination.id), .identity)
    XCTAssertEqual(lruStore.state(for: other.id), otherState)
    XCTAssertEqual(lruStore.retainedStateCount, 2)

    let idempotentStore = ImageGalleryZoomStateStore(maximumRetainedStates: 2)
    idempotentStore.update(sourceState, for: source.id)
    idempotentStore.migrate(migration)
    idempotentStore.retainOnly([destination.id])
    idempotentStore.migrate(migration)
    idempotentStore.retainOnly([destination.id])
    XCTAssertEqual(idempotentStore.state(for: destination.id), sourceState)
    XCTAssertEqual(idempotentStore.retainedStateCount, 1)
  }

  @MainActor
  func testCoordinatorDefersMigrationUntilInteractiveTransitionFinishes() throws {
    let localFirstID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let localSecondID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 1)
    let remoteFirstID = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "first",
      postID: 1
    )
    let remoteSecondID = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "second",
      postID: 1
    )
    let localItems = [
      try item(id: localFirstID, value: 1),
      try item(id: localSecondID, value: 2),
    ]
    let remoteItems = [
      try item(id: remoteFirstID, value: 1),
      try item(id: remoteSecondID, value: 2),
    ]
    let store = ImageGalleryZoomStateStore()
    let coordinator = ImageGalleryPager.Coordinator()
    let pageViewController = ControllableImageGalleryPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: nil
    )
    var publishedSelections = [ImageGalleryItem.ID]()
    coordinator.attach(to: pageViewController, axis: .horizontal)
    coordinator.receive(
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: localItems,
          requestedSelection: localFirstID
        ),
        accessibilityPageDescriptions: [:]
      ),
      zoomStateStore: store,
      onSelectionChange: { id in
        if let id { publishedSelections.append(id) }
      }
    )
    XCTAssertEqual(pageViewController.pendingProgrammaticCompletionCount, 1)
    XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))

    let sourceState = ImageGalleryZoomState(
      scale: 2,
      offset: CGSize(width: 8, height: -4)
    )
    store.update(sourceState, for: localFirstID)
    let visibleController = try XCTUnwrap(pageViewController.viewControllers?.first)
    let pendingController = try XCTUnwrap(
      coordinator.pageViewController(
        pageViewController,
        viewControllerAfter: visibleController
      )
    )
    coordinator.pageViewController(
      pageViewController,
      willTransitionTo: [pendingController]
    )
    coordinator.receive(
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: remoteItems,
          requestedSelection: remoteFirstID
        ),
        idMigrations: [
          localFirstID: remoteFirstID,
          localSecondID: remoteSecondID,
        ],
        accessibilityPageDescriptions: [:]
      ),
      zoomStateStore: store,
      onSelectionChange: { id in
        if let id { publishedSelections.append(id) }
      }
    )

    XCTAssertEqual(store.state(for: localFirstID), sourceState)
    XCTAssertEqual(store.state(for: remoteFirstID), .identity)
    XCTAssertTrue(publishedSelections.isEmpty)

    pageViewController.setViewControllers(
      [pendingController],
      direction: .forward,
      animated: false,
      completion: nil
    )
    coordinator.pageViewController(
      pageViewController,
      didFinishAnimating: true,
      previousViewControllers: [visibleController],
      transitionCompleted: true
    )

    XCTAssertEqual(store.state(for: localFirstID), .identity)
    XCTAssertEqual(store.state(for: remoteFirstID), sourceState)
    XCTAssertEqual(publishedSelections, [remoteSecondID])
    XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))
    coordinator.detach()
  }

  @MainActor
  func testCoordinatorAllowsOnlyCurrentPageToOwnAnimationPlayback() throws {
    let first = try item(1)
    let second = try item(2)
    let items = [first, second]
    let store = ImageGalleryZoomStateStore()
    let coordinator = ImageGalleryPager.Coordinator()
    let pageViewController = ControllableImageGalleryPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: nil
    )
    coordinator.attach(to: pageViewController, axis: .horizontal)
    coordinator.receive(
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: items,
          requestedSelection: first.id
        ),
        accessibilityPageDescriptions: [:]
      ),
      zoomStateStore: store,
      onSelectionChange: { _ in }
    )

    XCTAssertNil(coordinator.animationPlaybackOwnerID)
    XCTAssertTrue(coordinator.animationPlaybackEnabledControllerIDs.isEmpty)
    XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))
    XCTAssertEqual(coordinator.animationPlaybackOwnerID, first.id)
    XCTAssertEqual(coordinator.animationPlaybackEnabledControllerIDs, [first.id])

    let visibleController = try XCTUnwrap(pageViewController.viewControllers?.first)
    let pendingController = try XCTUnwrap(
      coordinator.pageViewController(
        pageViewController,
        viewControllerAfter: visibleController
      )
    )
    coordinator.pageViewController(
      pageViewController,
      willTransitionTo: [pendingController]
    )
    XCTAssertEqual(coordinator.animationPlaybackEnabledControllerIDs, [first.id])
    coordinator.pageViewController(
      pageViewController,
      didFinishAnimating: true,
      previousViewControllers: [visibleController],
      transitionCompleted: false
    )
    XCTAssertEqual(coordinator.animationPlaybackOwnerID, first.id)
    XCTAssertEqual(coordinator.animationPlaybackEnabledControllerIDs, [first.id])

    coordinator.pageViewController(
      pageViewController,
      willTransitionTo: [pendingController]
    )
    pageViewController.setViewControllers(
      [pendingController],
      direction: .forward,
      animated: false,
      completion: nil
    )
    coordinator.pageViewController(
      pageViewController,
      didFinishAnimating: true,
      previousViewControllers: [visibleController],
      transitionCompleted: true
    )
    XCTAssertEqual(coordinator.animationPlaybackOwnerID, second.id)
    XCTAssertEqual(coordinator.animationPlaybackEnabledControllerIDs, [second.id])

    coordinator.receive(
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: items,
          requestedSelection: first.id
        ),
        accessibilityPageDescriptions: [:]
      ),
      zoomStateStore: store,
      onSelectionChange: { _ in }
    )
    XCTAssertEqual(pageViewController.pendingProgrammaticCompletionCount, 1)
    XCTAssertEqual(coordinator.animationPlaybackOwnerID, second.id)
    XCTAssertEqual(coordinator.animationPlaybackEnabledControllerIDs, [second.id])

    coordinator.detach()
    XCTAssertNil(coordinator.animationPlaybackOwnerID)
    XCTAssertTrue(coordinator.animationPlaybackEnabledControllerIDs.isEmpty)
    XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))
    XCTAssertNil(coordinator.animationPlaybackOwnerID)
    XCTAssertTrue(coordinator.animationPlaybackEnabledControllerIDs.isEmpty)
  }

  @MainActor
  func testCoordinatorDrainsMigrationAfterCompletedOrInterruptedProgrammaticTransition() throws {
    let localFirstID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 0)
    let localSecondID = ImageGalleryItem.ID.local(postID: 1, contentOffset: 1)
    let remoteFirstID = ImageGalleryItem.ID.remote(
      overallIndex: 1,
      pictureID: "first",
      postID: 1
    )
    let remoteSecondID = ImageGalleryItem.ID.remote(
      overallIndex: 2,
      pictureID: "second",
      postID: 1
    )
    let localItems = [
      try item(id: localFirstID, value: 1),
      try item(id: localSecondID, value: 2),
    ]
    let remoteItems = [
      try item(id: remoteFirstID, value: 1),
      try item(id: remoteSecondID, value: 2),
    ]
    let sourceState = ImageGalleryZoomState(
      scale: 2,
      offset: CGSize(width: 8, height: -4)
    )

    for completed in [true, false] {
      let store = ImageGalleryZoomStateStore()
      let coordinator = ImageGalleryPager.Coordinator()
      let pageViewController = ControllableImageGalleryPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: nil
      )
      coordinator.attach(to: pageViewController, axis: .horizontal)
      coordinator.receive(
        ImageGalleryPagerUpdate(
          snapshot: ImageGalleryPagerSnapshot(
            items: localItems,
            requestedSelection: localFirstID
          ),
          accessibilityPageDescriptions: [:]
        ),
        zoomStateStore: store,
        onSelectionChange: { _ in }
      )
      XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))
      store.update(sourceState, for: localSecondID)

      coordinator.receive(
        ImageGalleryPagerUpdate(
          snapshot: ImageGalleryPagerSnapshot(
            items: localItems,
            requestedSelection: localSecondID
          ),
          accessibilityPageDescriptions: [:]
        ),
        zoomStateStore: store,
        onSelectionChange: { _ in }
      )
      XCTAssertEqual(pageViewController.pendingProgrammaticCompletionCount, 1)
      coordinator.receive(
        ImageGalleryPagerUpdate(
          snapshot: ImageGalleryPagerSnapshot(
            items: remoteItems,
            requestedSelection: remoteSecondID
          ),
          idMigrations: [
            localFirstID: remoteFirstID,
            localSecondID: remoteSecondID,
          ],
          accessibilityPageDescriptions: [:]
        ),
        zoomStateStore: store,
        onSelectionChange: { _ in }
      )

      XCTAssertEqual(store.state(for: localSecondID), sourceState)
      XCTAssertEqual(store.state(for: remoteSecondID), .identity)
      XCTAssertTrue(
        pageViewController.completeNextProgrammaticTransition(completed: completed)
      )
      XCTAssertEqual(store.state(for: localSecondID), .identity)
      XCTAssertEqual(store.state(for: remoteSecondID), sourceState)

      if completed {
        XCTAssertEqual(pageViewController.pendingProgrammaticCompletionCount, 1)
        XCTAssertTrue(pageViewController.completeNextProgrammaticTransition(completed: true))
      } else {
        XCTAssertEqual(pageViewController.pendingProgrammaticCompletionCount, 0)
      }
      coordinator.detach()
    }
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

  private func item(id: ImageGalleryItem.ID, value: Int) throws -> ImageGalleryItem {
    ImageGalleryItem(
      id: id,
      contentOffset: value,
      url: try url("https://example.com/image-\(value).jpg")
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }

  private func panOwnership(
    limits: ImageZoomPanLimits?,
    offset: CGSize,
    velocity: CGSize,
    translation: CGSize = .zero,
    displayScale: CGFloat = 1
  ) -> ImageZoomPanOwnership {
    ImageZoomPanOwnershipPolicy.resolve(
      limits: limits,
      offset: offset,
      velocity: velocity,
      translation: translation,
      displayScale: displayScale
    )
  }

  @MainActor
  private func panOverlay(
    scale: CGFloat,
    offset: CGSize,
    viewportSize: CGSize,
    fittedImageSize: CGSize
  ) -> ImageZoomPanGestureOverlay {
    ImageZoomPanGestureOverlay(
      scale: scale,
      offset: offset,
      viewportSize: viewportSize,
      fittedImageSize: fittedImageSize,
      displayScale: 3,
      onChanged: { _ in },
      onEnded: { _ in }
    )
  }
}

@MainActor
private final class ControllableImageGalleryPageViewController:
  ImageGalleryPageViewController
{
  private var programmaticCompletions = [((Bool) -> Void)]()

  var pendingProgrammaticCompletionCount: Int {
    programmaticCompletions.count
  }

  override func setViewControllers(
    _ viewControllers: [UIViewController]?,
    direction: UIPageViewController.NavigationDirection,
    animated: Bool,
    completion: ((Bool) -> Void)?
  ) {
    // Install the visible controller synchronously; the test drives completion separately.
    super.setViewControllers(
      viewControllers,
      direction: direction,
      animated: false,
      completion: nil
    )
    if let completion {
      programmaticCompletions.append(completion)
    }
  }

  @discardableResult
  func completeNextProgrammaticTransition(completed: Bool) -> Bool {
    guard !programmaticCompletions.isEmpty else { return false }
    programmaticCompletions.removeFirst()(completed)
    return true
  }
}
