import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class DownsampledRemoteImageTests: XCTestCase {
  func testAutomaticPreviewUsesLowerTransferLimit() {
    XCTAssertEqual(
      RemoteImageDownloadPolicy.maximumResponseBytes(for: 720),
      16 * 1_024 * 1_024
    )
    XCTAssertEqual(
      RemoteImageDownloadPolicy.maximumResponseBytes(for: 721),
      80 * 1_024 * 1_024
    )
    XCTAssertEqual(RemoteImageDownloadPolicy.kind(forMaxPixelSize: 720), .preview)
    XCTAssertEqual(RemoteImageDownloadPolicy.kind(forMaxPixelSize: 721), .original)
  }

  func testTransferLimitRejectsDeclaredOrObservedOversizeResponses() {
    let limit: Int64 = 16 * 1_024 * 1_024

    XCTAssertTrue(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: 1,
        totalBytesExpected: limit + 1,
        maximumResponseBytes: limit
      )
    )
    XCTAssertTrue(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: limit + 1,
        totalBytesExpected: -1,
        maximumResponseBytes: limit
      )
    )
    XCTAssertFalse(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: limit,
        totalBytesExpected: -1,
        maximumResponseBytes: limit
      )
    )
  }

  func testStoredPhaseIsVisibleOnlyForTheSameResourceIdentity() throws {
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/first.jpg"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/second.jpg"))
    let stored = DownsampledRemoteImageResourceID(url: firstURL, maxPixelSize: 720)

    XCTAssertTrue(
      DownsampledRemoteImageStateDecision.canRenderStoredPhase(
        storedResourceID: stored,
        currentResourceID: stored
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canRenderStoredPhase(
        storedResourceID: stored,
        currentResourceID: .init(url: secondURL, maxPixelSize: 720)
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canRenderStoredPhase(
        storedResourceID: stored,
        currentResourceID: .init(url: firstURL, maxPixelSize: 721)
      )
    )
  }

  func testExplicitPreviewPolicyAt1600PixelsStillUsesPreviewTransportLimit() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/image.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 1_600,
      fetchPolicy: .allowNetwork(.preview)
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testColdCacheOnlyMissDoesNotStartDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: Data())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cold.jpg"))

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertTrue(recordedKinds.isEmpty)
  }

  func testCompletedNetworkImageCanBeReadFromExactCacheWithoutNewDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cached.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testCacheKeyUsesNormalizedPixelSize() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/normalized.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 1,
      fetchPolicy: .allowNetwork(.preview)
    )
    _ = try await repository.image(
      at: url,
      maxPixelSize: 63,
      fetchPolicy: .cacheOnly
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testDifferentNormalizedPixelSizeMissesCache() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/different-size.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 128,
      fetchPolicy: .allowNetwork(.preview)
    )
    await expectCacheMiss(repository, url: url, maxPixelSize: 129)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testDifferentURLMissesCache() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let cachedURL = try XCTUnwrap(URL(string: "https://img.example/cached-url.jpg"))
    let otherURL = try XCTUnwrap(URL(string: "https://img.example/other-url.jpg"))

    _ = try await repository.image(
      at: cachedURL,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    await expectCacheMiss(repository, url: otherURL, maxPixelSize: 320)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testCacheOnlyMissDoesNotJoinInFlightDownload() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/in-flight.jpg"))
    let networkTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didStart)

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let requestCount = await downloader.requestCount()
    XCTAssertEqual(requestCount, 1)

    networkTask.cancel()
    let didCancel = await downloader.waitUntilCancellationCount(1)
    XCTAssertTrue(didCancel)
    await downloader.releaseAll()
    _ = await networkTask.result
  }

  func testCancellationBeforeDownloaderStartsDoesNotCallDownloader() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: Data())
    let beforeDownload = SuspendedAsyncGate()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      beforeDownload: { await beforeDownload.wait() }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/pre-start-cancel.jpg"))
    let networkTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didEnterGate = await beforeDownload.waitUntilEntered()
    XCTAssertTrue(didEnterGate)

    networkTask.cancel()
    let didCancelGate = await beforeDownload.waitUntilCancellationCount(1)
    XCTAssertTrue(didCancelGate)
    await beforeDownload.open()

    do {
      _ = try await networkTask.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let recordedKinds = await downloader.recordedKinds()
    XCTAssertTrue(recordedKinds.isEmpty)
  }

  func testSuspendedDownloaderReleaseIsPermanentForLateRequest() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let url = try XCTUnwrap(URL(string: "https://img.example/late-request.jpg"))

    await downloader.releaseAll()
    let lease = try await downloader.download(from: url, kind: .preview)

    XCTAssertEqual(lease.sourceURL, url)
    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testDifferentDownloadKindsDoNotShareInFlightRequest() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/kinds.jpg"))
    let previewTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 1_600,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let previewDidStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(previewDidStart)
    let originalTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 1_600,
        fetchPolicy: .allowNetwork(.original)
      )
    }
    let originalDidStart = await downloader.waitUntilRequestCount(2)
    XCTAssertTrue(originalDidStart)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview, .original])

    previewTask.cancel()
    originalTask.cancel()
    let didCancelBoth = await downloader.waitUntilCancellationCount(2)
    XCTAssertTrue(didCancelBoth)
    await downloader.releaseAll()
    _ = await previewTask.result
    _ = await originalTask.result
  }

  func testFinalWaiterCancellationCancelsTransferAndDoesNotPopulateCache() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cancelled.jpg"))
    let networkTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didStart)

    networkTask.cancel()
    let didCancel = await downloader.waitUntilCancellationCount(1)
    XCTAssertTrue(didCancel)
    await downloader.releaseAll()
    _ = await networkTask.result

    let cancellationCount = await downloader.cancelledRequestCount()
    XCTAssertEqual(cancellationCount, 1)
    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
  }

  private func expectCacheMiss(
    _ repository: DownsampledImageRepository,
    url: URL,
    maxPixelSize: Int
  ) async {
    do {
      _ = try await repository.image(
        at: url,
        maxPixelSize: maxPixelSize,
        fetchPolicy: .cacheOnly
      )
      XCTFail("Expected a cache miss")
    } catch DownsampledImageError.cacheMiss {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeJPEGData() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
    let image = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
  }
}

private actor RecordingRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private var kinds: [RemoteImageDownloadKind] = []

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(from url: URL, kind: RemoteImageDownloadKind) async throws
    -> RemoteImageFileLease
  {
    kinds.append(kind)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecordingRemoteImageDownloader", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("image.jpg")
    try imageData.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      mimeType: "image/jpeg",
      suggestedFilename: "image.jpg",
      byteCount: Int64(imageData.count)
    )
  }

  func recordedKinds() -> [RemoteImageDownloadKind] {
    kinds
  }
}

private actor SuspendedRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private var kinds: [RemoteImageDownloadKind] = []
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var cancelledRequests = 0
  private var isReleased = false

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(from url: URL, kind: RemoteImageDownloadKind) async throws
    -> RemoteImageFileLease
  {
    kinds.append(kind)
    await withTaskCancellationHandler {
      await waitForRelease()
    } onCancel: {
      Task { await self.recordCancellation() }
    }
    return try makeLease(imageData: imageData, sourceURL: url)
  }

  func waitUntilRequestCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while kinds.count < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return kinds.count >= expectedCount
  }

  func waitUntilCancellationCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while cancelledRequests < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return cancelledRequests >= expectedCount
  }

  func releaseAll() {
    isReleased = true
    let continuations = pending
    pending.removeAll()
    continuations.forEach { $0.resume() }
  }

  func requestCount() -> Int {
    kinds.count
  }

  func recordedKinds() -> [RemoteImageDownloadKind] {
    kinds
  }

  func cancelledRequestCount() -> Int {
    cancelledRequests
  }

  private func waitForRelease() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      pending.append(continuation)
    }
  }

  private func recordCancellation() {
    cancelledRequests += 1
  }
}

private actor SuspendedAsyncGate {
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var enteredCount = 0
  private var cancellationCount = 0
  private var isOpen = false

  func wait() async {
    enteredCount += 1
    await withTaskCancellationHandler {
      await waitForOpen()
    } onCancel: {
      Task { await self.recordCancellation() }
    }
  }

  func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while enteredCount == 0, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return enteredCount > 0
  }

  func waitUntilCancellationCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while cancellationCount < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return cancellationCount >= expectedCount
  }

  func open() {
    isOpen = true
    let continuations = pending
    pending.removeAll()
    continuations.forEach { $0.resume() }
  }

  private func waitForOpen() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      pending.append(continuation)
    }
  }

  private func recordCancellation() {
    cancellationCount += 1
  }
}

private func makeLease(imageData: Data, sourceURL: URL) throws -> RemoteImageFileLease {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("DownsampledRemoteImageTests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let fileURL = directory.appendingPathComponent("image.jpg")
  try imageData.write(to: fileURL)
  return RemoteImageFileLease(
    fileURL: fileURL,
    cleanupDirectoryURL: directory,
    sourceURL: sourceURL,
    mimeType: "image/jpeg",
    suggestedFilename: "image.jpg",
    byteCount: Int64(imageData.count)
  )
}
