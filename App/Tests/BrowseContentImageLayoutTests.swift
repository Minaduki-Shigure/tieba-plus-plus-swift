import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class BrowseContentImageLayoutTests: XCTestCase {
  func testBlocksGroupOnlyConsecutiveImagesAndPreserveOriginalOffsets() throws {
    let firstImageURL = try url("https://example.com/first.jpg")
    let firstFullSizeURL = try url("https://example.com/first-full.jpg")
    let secondImageURL = try url("https://example.com/second.jpg")
    let thirdImageURL = try url("https://example.com/third.jpg")
    let fourthImageURL = try url("https://example.com/fourth.jpg")
    let videoURL = try url("https://example.com/video.mp4")
    let voiceURL = try url("https://example.com/voice.mp3")
    let contents: [BrowseContent] = [
      .text("before"),
      .image(
        thumbnail: firstImageURL,
        fullSize: firstFullSizeURL,
        original: nil,
        width: 100,
        height: 80
      ),
      .image(
        thumbnail: secondImageURL,
        fullSize: nil,
        original: nil,
        width: 80,
        height: 100
      ),
      .unsupported(label: "separator"),
      .image(
        thumbnail: thirdImageURL,
        fullSize: nil,
        original: nil,
        width: 200,
        height: 100
      ),
      .video(url: videoURL, cover: nil, width: 1_280, height: 720),
      .image(
        thumbnail: fourthImageURL,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 200
      ),
      .voice(url: voiceURL, duration: 4),
      .text("after"),
    ]

    let blocks = BrowseContentBlock.makeBlocks(contents)

    XCTAssertEqual(
      blocks,
      [
        .inline(contentOffset: 0, contents: [.text("before")]),
        .imageRun([
          BrowseContentImageItem(
            contentOffset: 1,
            thumbnailURL: firstImageURL,
            fullSizeURL: firstFullSizeURL,
            width: 100,
            height: 80
          ),
          BrowseContentImageItem(
            contentOffset: 2,
            thumbnailURL: secondImageURL,
            fullSizeURL: nil,
            width: 80,
            height: 100
          ),
        ]),
        .inline(contentOffset: 3, contents: [.unsupported(label: "separator")]),
        .imageRun([
          BrowseContentImageItem(
            contentOffset: 4,
            thumbnailURL: thirdImageURL,
            fullSizeURL: nil,
            width: 200,
            height: 100
          )
        ]),
        .standalone(
          contentOffset: 5,
          content: .video(url: videoURL, cover: nil, width: 1_280, height: 720)
        ),
        .imageRun([
          BrowseContentImageItem(
            contentOffset: 6,
            thumbnailURL: fourthImageURL,
            fullSizeURL: nil,
            width: 100,
            height: 200
          )
        ]),
        .standalone(contentOffset: 7, content: .voice(url: voiceURL, duration: 4)),
        .inline(contentOffset: 8, contents: [.text("after")]),
      ]
    )
    XCTAssertEqual(
      blocks.map(\.id),
      [
        .inline(0),
        .imageRun(1),
        .inline(3),
        .imageRun(4),
        .standalone(5),
        .imageRun(6),
        .standalone(7),
        .inline(8),
      ]
    )
  }

  func testBlocksKeepDuplicateImageURLsAsDistinctItems() throws {
    let repeatedURL = try url("https://example.com/repeated.jpg")
    let blocks = BrowseContentBlock.makeBlocks([
      .image(
        thumbnail: repeatedURL,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      ),
      .image(
        thumbnail: repeatedURL,
        fullSize: nil,
        original: repeatedURL,
        width: 100,
        height: 100
      ),
    ])

    guard case .imageRun(let images) = try XCTUnwrap(blocks.first) else {
      return XCTFail("Expected an image run")
    }
    XCTAssertEqual(images.map(\.id), [0, 1])
    XCTAssertEqual(images.map(\.thumbnailURL), [repeatedURL, repeatedURL])
  }

  func testEmptyContentsProduceNoBlocks() {
    XCTAssertTrue(BrowseContentBlock.makeBlocks([]).isEmpty)
  }

  func testAspectRatioUsesFallbackAndClampsServerDimensions() {
    XCTAssertEqual(
      BrowseImageMasonryGeometry.sanitizedAspectRatio(width: 400, height: 200),
      2
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.sanitizedAspectRatio(width: 800, height: 200),
      2
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.sanitizedAspectRatio(width: 100, height: 400),
      0.5
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.sanitizedAspectRatio(width: 0, height: 400),
      4 / 3,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.sanitizedAspectRatio(width: -1, height: 400),
      4 / 3,
      accuracy: 0.000_001
    )
    XCTAssertEqual(BrowseImageMasonryGeometry.sanitizedAspectRatio(.nan), 4 / 3)
    XCTAssertEqual(BrowseImageMasonryGeometry.sanitizedAspectRatio(.infinity), 4 / 3)
  }

  func testVeryTallImagePlanReservesItsEntireClampedPreviewFrame() {
    let aspectRatio = BrowseImageMasonryGeometry.sanitizedAspectRatio(
      width: 412,
      height: 2_343
    )
    let plan = BrowseImageMasonryGeometry.plan(
      availableWidth: 358,
      aspectRatios: [aspectRatio],
      imageLayout: .responsive
    )

    XCTAssertEqual(aspectRatio, 0.5)
    XCTAssertEqual(plan.frames, [CGRect(x: 0, y: 0, width: 358, height: 716)])
    XCTAssertEqual(plan.size.height, plan.frames[0].maxY)
  }

  @MainActor
  func testPreviewFrameSizeIsIndependentOfOversizedImageContent() {
    let host = UIHostingController(
      rootView: BrowseImagePreviewFrame(aspectRatio: 0.5) {
        Color.red.frame(width: 358, height: 4_096)
      }
      .frame(width: 358)
    )

    let size = host.sizeThatFits(
      in: CGSize(width: 358, height: 10_000)
    )

    XCTAssertEqual(size.width, 358, accuracy: 0.5)
    XCTAssertEqual(size.height, 716, accuracy: 0.5)
  }

  func testResponsiveColumnThresholdsAndItemCap() {
    XCTAssertEqual(columns(width: 599.999, itemCount: 4), 1)
    XCTAssertEqual(columns(width: 600, itemCount: 4), 2)
    XCTAssertEqual(columns(width: 839.999, itemCount: 4), 2)
    XCTAssertEqual(columns(width: 840, itemCount: 4), 3)
    XCTAssertEqual(columns(width: 1_024, itemCount: 1), 1)
    XCTAssertEqual(columns(width: 1_024, itemCount: 2), 2)
    XCTAssertEqual(columns(width: 1_024, itemCount: 0), 0)
    XCTAssertEqual(columns(width: -CGFloat.infinity, itemCount: 4), 1)
    XCTAssertEqual(columns(width: .infinity, itemCount: 4), 1)
    XCTAssertEqual(columns(width: .nan, itemCount: 4), 1)
  }

  func testOnlyAccessibilityDynamicTypeForcesOneColumn() {
    XCTAssertFalse(DynamicTypeSize.xxLarge.isAccessibilitySize)
    XCTAssertTrue(DynamicTypeSize.accessibility1.isAccessibilitySize)
    XCTAssertEqual(
      columns(
        width: 840,
        itemCount: 4,
        forcesSingleColumn: DynamicTypeSize.xxLarge.isAccessibilitySize
      ),
      3
    )
    XCTAssertEqual(
      columns(
        width: 840,
        itemCount: 4,
        forcesSingleColumn: DynamicTypeSize.accessibility1.isAccessibilitySize
      ),
      1
    )
  }

  func testExplicitSingleColumnIgnoresResponsiveThresholds() {
    XCTAssertEqual(
      BrowseImageMasonryGeometry.columnCount(
        availableWidth: 1_024,
        itemCount: 4,
        imageLayout: .singleColumn
      ),
      1
    )
  }

  func testUnspecifiedAndNonFiniteProposalsResolveToFiniteBoundedWidth() {
    XCTAssertEqual(
      BrowseImageMasonryGeometry.resolvedWidth(proposedWidth: nil),
      560
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.resolvedWidth(
        proposedWidth: nil,
        idealWidths: [320, .nan, .infinity]
      ),
      320
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.resolvedWidth(
        proposedWidth: .infinity,
        idealWidths: [900]
      ),
      560
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.resolvedWidth(
        proposedWidth: -1,
        idealWidths: []
      ),
      560
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.resolvedWidth(proposedWidth: 840),
      840
    )
  }

  func testGreedyAssignmentUsesShortestColumnAndStableTieBreaking() {
    XCTAssertEqual(
      BrowseImageMasonryGeometry.columnAssignments(
        aspectRatios: [1, 2, 0.5, 1],
        columnCount: 2
      ),
      [0, 1, 1, 0]
    )
    XCTAssertEqual(
      BrowseImageMasonryGeometry.columnAssignments(
        aspectRatios: [1, 1, 1, 1],
        columnCount: 2
      ),
      [0, 1, 0, 1]
    )
  }

  func testEmptyPlanKeepsFiniteContainerWidthAndHasNoPlacements() {
    let plan = BrowseImageMasonryGeometry.plan(
      availableWidth: 608,
      aspectRatios: [],
      imageLayout: .responsive
    )

    XCTAssertEqual(plan.columnCount, 0)
    XCTAssertTrue(plan.assignments.isEmpty)
    XCTAssertTrue(plan.frames.isEmpty)
    XCTAssertEqual(plan.size, CGSize(width: 608, height: 0))
  }

  func testPlanUsesStableSpacingAndReportsTallestColumn() {
    let plan = BrowseImageMasonryGeometry.plan(
      availableWidth: 608,
      aspectRatios: [1, 2, 1],
      imageLayout: .responsive
    )

    XCTAssertEqual(plan.columnCount, 2)
    XCTAssertEqual(plan.assignments, [0, 1, 1])
    XCTAssertEqual(
      plan.frames,
      [
        CGRect(x: 0, y: 0, width: 300, height: 300),
        CGRect(x: 308, y: 0, width: 300, height: 150),
        CGRect(x: 308, y: 158, width: 300, height: 300),
      ]
    )
    XCTAssertEqual(plan.size, CGSize(width: 608, height: 458))
  }

  func testSingleColumnPlansRetainTheExistingMaximumImageWidth() {
    let explicitPlan = BrowseImageMasonryGeometry.plan(
      availableWidth: 1_024,
      aspectRatios: [1, 2],
      imageLayout: .singleColumn
    )
    let itemCappedResponsivePlan = BrowseImageMasonryGeometry.plan(
      availableWidth: 1_024,
      aspectRatios: [1],
      imageLayout: .responsive
    )

    XCTAssertEqual(explicitPlan.columnCount, 1)
    XCTAssertEqual(explicitPlan.frames[0], CGRect(x: 0, y: 0, width: 560, height: 560))
    XCTAssertEqual(explicitPlan.frames[1], CGRect(x: 0, y: 568, width: 560, height: 280))
    XCTAssertEqual(explicitPlan.size, CGSize(width: 1_024, height: 848))
    XCTAssertEqual(itemCappedResponsivePlan.columnCount, 1)
    XCTAssertEqual(itemCappedResponsivePlan.frames[0].width, 560)
  }

  func testNonFiniteSpacingIsNormalizedToZero() {
    let plan = BrowseImageMasonryGeometry.plan(
      availableWidth: 600,
      aspectRatios: [1, 1, 1],
      imageLayout: .responsive,
      horizontalSpacing: .nan,
      verticalSpacing: .infinity
    )

    XCTAssertEqual(plan.frames[0], CGRect(x: 0, y: 0, width: 300, height: 300))
    XCTAssertEqual(plan.frames[1], CGRect(x: 300, y: 0, width: 300, height: 300))
    XCTAssertEqual(plan.frames[2], CGRect(x: 0, y: 300, width: 300, height: 300))
    XCTAssertEqual(plan.size, CGSize(width: 600, height: 600))
  }

  func testMultiColumnFramesAreFiniteInBoundsAndDoNotOverlapWithinAColumn() {
    let plan = BrowseImageMasonryGeometry.plan(
      availableWidth: 900,
      aspectRatios: [0, .nan, 0.5, 1, 2, .infinity, -1],
      imageLayout: .responsive
    )

    XCTAssertEqual(plan.columnCount, 3)
    XCTAssertEqual(plan.frames.count, 7)
    for frame in plan.frames {
      XCTAssertTrue(frame.minX.isFinite)
      XCTAssertTrue(frame.minY.isFinite)
      XCTAssertTrue(frame.width.isFinite)
      XCTAssertTrue(frame.height.isFinite)
      XCTAssertGreaterThanOrEqual(frame.minX, 0)
      XCTAssertGreaterThanOrEqual(frame.minY, 0)
      XCTAssertLessThanOrEqual(frame.maxX, plan.size.width + 0.000_001)
      XCTAssertLessThanOrEqual(frame.maxY, plan.size.height + 0.000_001)
    }
    for column in 0..<plan.columnCount {
      let columnFrames = zip(plan.assignments, plan.frames)
        .filter { $0.0 == column }
        .map { $0.1 }
      for pair in zip(columnFrames, columnFrames.dropFirst()) {
        XCTAssertLessThanOrEqual(pair.0.maxY, pair.1.minY)
      }
    }
  }

  func testWidthTransitionsDoNotChangeImageSourceIdentity() throws {
    let urls = try (0..<3).map { index in
      try url("https://example.com/\(index).jpg")
    }
    let blocks = BrowseContentBlock.makeBlocks(
      urls.map {
        .image(thumbnail: $0, fullSize: nil, original: nil, width: 100, height: 100)
      }
    )
    guard case .imageRun(let images) = try XCTUnwrap(blocks.first) else {
      return XCTFail("Expected an image run")
    }

    let plans = [599, 600, 840].map { width in
      BrowseImageMasonryGeometry.plan(
        availableWidth: CGFloat(width),
        aspectRatios: images.map(\.aspectRatio),
        imageLayout: .responsive
      )
    }

    XCTAssertEqual(images.map(\.id), [0, 1, 2])
    XCTAssertEqual(plans.map(\.columnCount), [1, 2, 3])
    XCTAssertTrue(plans.allSatisfy { $0.frames.count == images.count })
  }

  private func columns(
    width: CGFloat,
    itemCount: Int,
    forcesSingleColumn: Bool = false
  ) -> Int {
    BrowseImageMasonryGeometry.columnCount(
      availableWidth: width,
      itemCount: itemCount,
      imageLayout: .responsive,
      forcesSingleColumn: forcesSingleColumn
    )
  }

  private func url(_ value: String) throws -> URL {
    try XCTUnwrap(URL(string: value))
  }
}
