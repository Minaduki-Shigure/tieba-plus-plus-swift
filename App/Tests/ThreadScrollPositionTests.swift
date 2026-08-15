import CoreGraphics
import XCTest

@testable import TiebaPlusPlus

final class ThreadScrollPositionTests: XCTestCase {
  @MainActor
  func testCoalescerPublishesOnlyLatestPositionAfterBurst() async throws {
    let coalescer = ThreadScrollPositionCoalescer(delayNanoseconds: 1_000_000)
    let first = ThreadScrollPosition(readingProgressPostID: 1, prependAnchorPostID: 1)
    let latest = ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 2)
    var published: [ThreadScrollPosition] = []

    coalescer.submit(first) { published.append($0) }
    coalescer.submit(
      ThreadScrollPosition(readingProgressPostID: 2, prependAnchorPostID: 2)
    ) { published.append($0) }
    coalescer.submit(latest) { published.append($0) }
    try await Task.sleep(nanoseconds: 30_000_000)

    XCTAssertEqual(coalescer.latestPosition, latest)
    XCTAssertEqual(coalescer.publicationCount, 1)
    XCTAssertEqual(published, [latest])
  }

  @MainActor
  func testCoalescerCanRescheduleSamePositionAfterCancellation() async throws {
    let coalescer = ThreadScrollPositionCoalescer(delayNanoseconds: 1_000_000)
    let position = ThreadScrollPosition(readingProgressPostID: 7, prependAnchorPostID: 7)
    var published: [ThreadScrollPosition] = []

    coalescer.submit(position) { published.append($0) }
    coalescer.cancelPendingPublication()
    coalescer.submit(position) { published.append($0) }
    try await Task.sleep(nanoseconds: 30_000_000)

    XCTAssertEqual(coalescer.publicationCount, 1)
    XCTAssertEqual(published, [position])
  }

  func testVisibilityRequiresPositiveIntersectionWithViewport() {
    XCTAssertEqual(
      position(frame: CGRect(x: 0, y: -20, width: 100, height: 40)),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: 41)
    )
    XCTAssertEqual(
      position(frame: CGRect(x: 0, y: 599, width: 100, height: 40)),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: 41)
    )

    let excludedFrames = [
      CGRect(x: 0, y: -40, width: 100, height: 40),
      CGRect(x: 0, y: 600, width: 100, height: 40),
      CGRect(x: 0, y: 100, width: 100, height: 0),
    ]
    for frame in excludedFrames {
      XCTAssertEqual(position(frame: frame), .empty)
    }
  }

  func testVisibilityKeepsProgressAndPrependEligibilityIndependent() {
    XCTAssertEqual(
      position(tracksReadingProgress: true, tracksPrependAnchor: false),
      ThreadScrollPosition(readingProgressPostID: 41, prependAnchorPostID: nil)
    )
    XCTAssertEqual(
      position(tracksReadingProgress: false, tracksPrependAnchor: true),
      ThreadScrollPosition(readingProgressPostID: nil, prependAnchorPostID: 41)
    )
    XCTAssertEqual(
      position(tracksReadingProgress: false, tracksPrependAnchor: false),
      .empty
    )
  }

  func testPixelMovementWithinViewportKeepsStablePreferenceValue() {
    let initial = position(frame: CGRect(x: 0, y: 100, width: 100, height: 40))

    for y in stride(from: CGFloat(-39), through: 599, by: 17) {
      XCTAssertEqual(
        position(frame: CGRect(x: 0, y: y, width: 100, height: 40)),
        initial
      )
    }
  }

  func testPreferenceReductionUsesLastVisibleProgressPostAndFirstReplyAnchor() {
    var reduced = ThreadScrollPositionPreferenceKey.defaultValue
    let values = [
      ThreadScrollPosition(readingProgressPostID: 1, prependAnchorPostID: nil),
      ThreadScrollPosition(readingProgressPostID: 2, prependAnchorPostID: 2),
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 3),
    ]

    for value in values {
      ThreadScrollPositionPreferenceKey.reduce(value: &reduced) { value }
    }

    XCTAssertEqual(
      reduced,
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 2)
    )
  }

  func testNativeResolverUsesLastVisibleProgressPostAndFirstReplyAnchor() {
    XCTAssertEqual(
      ThreadScrollPositionResolver.position(
        visiblePostIDs: [3, 2, 2, 99, 1],
        targetsByPostID: [
          1: target(order: 0, tracksPrependAnchor: false),
          2: target(order: 1),
          3: target(order: 2),
        ],
        hidesLocallyFilteredContent: false
      ),
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 2)
    )
  }

  func testNativeResolverIgnoresUnknownHiddenAndInvalidTargets() {
    XCTAssertEqual(
      ThreadScrollPositionResolver.position(
        visiblePostIDs: [0, -1, 10, 11, 12, 404],
        targetsByPostID: [
          10: target(order: 0, visibility: .hidden, tracksPrependAnchor: false),
          11: target(order: 1, visibility: .placeholder),
          12: target(order: 2),
        ],
        hidesLocallyFilteredContent: false
      ),
      ThreadScrollPosition(readingProgressPostID: 12, prependAnchorPostID: 11)
    )
    XCTAssertEqual(
      ThreadScrollPositionResolver.position(
        visiblePostIDs: [20, 21],
        targetsByPostID: [:],
        hidesLocallyFilteredContent: false
      ),
      .empty
    )
  }

  func testNativeResolverHidesFilteredTargetsInPureReadingMode() {
    XCTAssertEqual(
      ThreadScrollPositionResolver.position(
        visiblePostIDs: [1, 2, 3],
        targetsByPostID: [
          1: target(order: 0, tracksPrependAnchor: false),
          2: target(order: 1, visibility: .placeholder),
          3: target(order: 2),
        ],
        hidesLocallyFilteredContent: true
      ),
      ThreadScrollPosition(readingProgressPostID: 3, prependAnchorPostID: 3)
    )
  }

  @MainActor
  func testVisiblePostTrackerPublishesOnlyMembershipChanges() {
    let tracker = ThreadVisiblePostTracker()

    XCTAssertEqual(Set(tracker.update(postID: 2, isVisible: true) ?? []), [2])
    XCTAssertNil(tracker.update(postID: 2, isVisible: true))
    XCTAssertEqual(Set(tracker.update(postID: 3, isVisible: true) ?? []), [2, 3])
    XCTAssertEqual(Set(tracker.update(postID: 2, isVisible: false) ?? []), [3])
    XCTAssertNil(tracker.update(postID: 2, isVisible: false))
    XCTAssertNil(tracker.update(postID: 0, isVisible: true))

    tracker.reset()
    XCTAssertTrue(tracker.visiblePostIDs.isEmpty)
  }

  func testVisibilityRejectsInvalidIdentityAndViewport() {
    XCTAssertEqual(position(postID: 0), .empty)
    XCTAssertEqual(position(viewportHeight: 0), .empty)
    XCTAssertEqual(position(viewportHeight: .infinity), .empty)
  }

  private func position(
    postID: Int64 = 41,
    frame: CGRect = CGRect(x: 0, y: 100, width: 100, height: 40),
    viewportHeight: CGFloat = 600,
    tracksReadingProgress: Bool = true,
    tracksPrependAnchor: Bool = true
  ) -> ThreadScrollPosition {
    ThreadPostVisibilityPolicy.position(
      postID: postID,
      frame: frame,
      viewportHeight: viewportHeight,
      tracksReadingProgress: tracksReadingProgress,
      tracksPrependAnchor: tracksPrependAnchor
    )
  }

  private func target(
    order: Int,
    visibility: LocalContentVisibility = .visible,
    tracksPrependAnchor: Bool = true
  ) -> ThreadScrollTargetDescriptor {
    ThreadScrollTargetDescriptor(
      order: order,
      localVisibility: visibility,
      tracksPrependAnchor: tracksPrependAnchor
    )
  }
}
