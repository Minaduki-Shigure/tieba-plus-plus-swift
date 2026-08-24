import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ThreadSummaryImageGalleryTests: XCTestCase {
  func testAppPictureSourceMappingPreservesEveryTypedValue() {
    XCTAssertEqual(TiebaCoreBrowseService.mapPicturePageSource(.post), .post)
    XCTAssertEqual(TiebaCoreBrowseService.mapPicturePageSource(.forum), .forum)
    XCTAssertEqual(TiebaCoreBrowseService.mapPicturePageSource(.index), .index)
  }

  func testCoordinatorPreservesTappedOffsetAndUsesIndexPictureSource() async throws {
    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: ThreadSummaryPictureGalleryServiceStub(),
      contentFilterRepository: ThreadSummaryContentFilterRepositoryStub(snapshotValue: .empty)
    )
    let thread = try makeThread(contentPostID: 77)

    XCTAssertTrue(coordinator.open(thread: thread, contentOffset: 3))
    let route = try XCTUnwrap(coordinator.route)
    guard case .thread(let threadRoute) = route.content else {
      return XCTFail("Expected a thread-aware gallery route")
    }

    XCTAssertEqual(threadRoute.viewModel.context.threadID, 42)
    XCTAssertEqual(threadRoute.viewModel.context.source, .index)
    XCTAssertEqual(
      threadRoute.viewModel.occurrences.map(\.id),
      [
        .local(postID: 77, contentOffset: 1),
        .local(postID: 77, contentOffset: 3),
      ]
    )
    XCTAssertEqual(
      threadRoute.viewModel.selectedID,
      .local(postID: 77, contentOffset: 3)
    )
    XCTAssertFalse(threadRoute.viewModel.isRemoteLoadingEnabled)

    await coordinator.waitForPolicyEvaluation()
    XCTAssertTrue(threadRoute.viewModel.isRemoteLoadingEnabled)
    coordinator.dismiss()
    XCTAssertNil(coordinator.route)
  }

  func testCoordinatorFailsClosedWhenContentFilteringIsActive() async throws {
    let filteredSnapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked", list: .block)]
    )
    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: ThreadSummaryPictureGalleryServiceStub(),
      contentFilterRepository: ThreadSummaryContentFilterRepositoryStub(
        snapshotValue: filteredSnapshot
      )
    )

    XCTAssertTrue(coordinator.open(thread: try makeThread(contentPostID: 77), contentOffset: 1))
    let route = try XCTUnwrap(coordinator.route)
    guard case .thread(let threadRoute) = route.content else {
      return XCTFail("Expected a thread-aware gallery route")
    }

    await coordinator.waitForPolicyEvaluation()
    XCTAssertFalse(threadRoute.viewModel.isRemoteLoadingEnabled)
  }

  func testPolicyReadFailureKeepsTheSameContentGalleryRemoteDisabled() async throws {
    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: ThreadSummaryPictureGalleryServiceStub(),
      contentFilterRepository: ThreadSummaryFailingContentFilterRepositoryStub()
    )

    XCTAssertTrue(coordinator.open(thread: try makeThread(contentPostID: 77), contentOffset: 1))
    let route = try XCTUnwrap(coordinator.route)
    guard case .thread(let threadRoute) = route.content else {
      return XCTFail("Expected a thread-aware gallery route")
    }

    await coordinator.waitForPolicyEvaluation()
    XCTAssertFalse(threadRoute.viewModel.isRemoteLoadingEnabled)
    XCTAssertEqual(threadRoute.viewModel.occurrences.count, 2)
  }

  func testLatePolicyResultCannotEnableAReplacementRoute() async throws {
    let repository = ThreadSummaryControlledContentFilterRepositoryStub()
    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: ThreadSummaryPictureGalleryServiceStub(),
      contentFilterRepository: repository
    )

    XCTAssertTrue(coordinator.open(thread: try makeThread(contentPostID: 77), contentOffset: 1))
    let firstRoute = try XCTUnwrap(coordinator.route)
    guard case .thread(let firstThreadRoute) = firstRoute.content else {
      return XCTFail("Expected the first thread-aware route")
    }
    try await repository.waitForRequestCount(1)

    coordinator.contentFilterDidChange()
    XCTAssertNil(coordinator.route)
    XCTAssertTrue(coordinator.open(thread: try makeThread(contentPostID: 77), contentOffset: 3))
    let secondRoute = try XCTUnwrap(coordinator.route)
    guard case .thread(let secondThreadRoute) = secondRoute.content else {
      return XCTFail("Expected the replacement thread-aware route")
    }
    try await repository.waitForRequestCount(2)

    await repository.resumeNext(with: .empty)
    await Task.yield()
    XCTAssertFalse(firstThreadRoute.viewModel.isRemoteLoadingEnabled)
    XCTAssertFalse(secondThreadRoute.viewModel.isRemoteLoadingEnabled)
    XCTAssertEqual(coordinator.route?.id, secondRoute.id)

    await repository.resumeNext(with: .empty)
    await coordinator.waitForPolicyEvaluation()
    XCTAssertTrue(secondThreadRoute.viewModel.isRemoteLoadingEnabled)
  }

  func testMissingContentPostIDFallsBackToTheCompleteLocalGallery() throws {
    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: ThreadSummaryPictureGalleryServiceStub(),
      contentFilterRepository: ThreadSummaryContentFilterRepositoryStub(snapshotValue: .empty)
    )

    let thread = try makeThread(contentPostID: nil)
    XCTAssertEqual(thread.firstPostID, 51)
    XCTAssertEqual(thread.contentPostID, 0)
    XCTAssertTrue(coordinator.open(thread: thread, contentOffset: 3))
    let route = try XCTUnwrap(coordinator.route)
    guard case .local(let presentation) = route.content else {
      return XCTFail("Expected a same-content gallery fallback")
    }

    XCTAssertEqual(presentation.items.map(\.contentOffset), [1, 3])
    XCTAssertEqual(presentation.initialIndex, 1)
    XCTAssertEqual(
      presentation.items.map(\.url.absoluteString),
      ["https://example.com/1-original.jpg", "https://example.com/2-original.jpg"]
    )
  }

  func testUnavailableActionAndHiddenThreadDoNotConsumeTheRowTap() throws {
    XCTAssertFalse(ThreadSummaryImageOpenAction.unavailable.isAvailable)
    XCTAssertFalse(
      ThreadSummaryImageOpenAction.unavailable(
        thread: try makeThread(contentPostID: 77),
        contentOffset: 1
      )
    )

    let coordinator = ThreadSummaryImageGalleryCoordinator(
      remoteService: nil,
      contentFilterRepository: ThreadSummaryContentFilterRepositoryStub(snapshotValue: .empty)
    )
    let hidden = try makeThread(contentPostID: 77).withLocalVisibility(.hidden)
    XCTAssertFalse(coordinator.open(thread: hidden, contentOffset: 1))
    XCTAssertNil(coordinator.route)
  }

  private func makeThread(contentPostID: Int64?) throws -> BrowseThread {
    let firstThumbnail = try XCTUnwrap(URL(string: "https://example.com/1-preview.jpg"))
    let firstOriginal = try XCTUnwrap(URL(string: "https://example.com/1-original.jpg"))
    let secondThumbnail = try XCTUnwrap(URL(string: "https://example.com/2-preview.jpg"))
    let secondOriginal = try XCTUnwrap(URL(string: "https://example.com/2-original.jpg"))
    return BrowseThread(
      id: 42,
      forumID: 7,
      forumName: "swift",
      title: "Gallery thread",
      excerpt: "Excerpt",
      authorName: "Author",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [
        .text("before"),
        .image(
          thumbnail: firstThumbnail,
          fullSize: nil,
          original: firstOriginal,
          width: 640,
          height: 480
        ),
        .text("between"),
        .image(
          thumbnail: secondThumbnail,
          fullSize: nil,
          original: secondOriginal,
          width: 800,
          height: 600
        ),
      ],
      firstPostID: 51,
      contentPostID: contentPostID
    )
  }
}

private struct ThreadSummaryPictureGalleryServiceStub: ThreadPictureGalleryService {
  func pictureIdentifier(for imageURL: URL) -> String? {
    String(repeating: "a", count: 40)
  }

  func picturePage(for request: ThreadPicturePageRequest) async throws -> ThreadPicturePage {
    throw BrowseError.unavailable("No remote response in unit tests")
  }
}

private struct ThreadSummaryContentFilterRepositoryStub: ContentFilterRepository {
  let snapshotValue: ContentFilterSnapshot

  func snapshot() async throws -> ContentFilterSnapshot { snapshotValue }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws { throw ContentFilterStoreError.unavailable }
  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func reset() async throws { throw ContentFilterStoreError.unavailable }
}

private struct ThreadSummaryFailingContentFilterRepositoryStub: ContentFilterRepository {
  func snapshot() async throws -> ContentFilterSnapshot {
    throw ContentFilterStoreError.readFailed
  }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws { throw ContentFilterStoreError.unavailable }
  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func reset() async throws { throw ContentFilterStoreError.unavailable }
}

private actor ThreadSummaryControlledContentFilterRepositoryStub: ContentFilterRepository {
  private var continuations: [CheckedContinuation<ContentFilterSnapshot, any Error>] = []

  func snapshot() async throws -> ContentFilterSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForRequestCount(_ count: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while continuations.count < count {
      try Task.checkCancellation()
      guard clock.now < deadline else {
        throw ThreadSummaryControlledRepositoryError.timeout
      }
      await Task.yield()
    }
  }

  func resumeNext(with snapshot: ContentFilterSnapshot) {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume(returning: snapshot)
  }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws { throw ContentFilterStoreError.unavailable }
  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }
  func reset() async throws { throw ContentFilterStoreError.unavailable }
}

private enum ThreadSummaryControlledRepositoryError: Error {
  case timeout
}
