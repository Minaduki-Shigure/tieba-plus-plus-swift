import ImageIO
import UIKit
import UniformTypeIdentifiers
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
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canRenderStoredPhase(
        storedResourceID: stored,
        currentResourceID: .init(
          url: firstURL,
          maxPixelSize: 720,
          urlPolicyID: "forum-avatar"
        )
      )
    )
  }

  func testAttemptIdentityRejectsLateEventsAfterSameResourceReload() {
    let previousAttemptID = UUID()
    let currentAttemptID = UUID()

    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canAcceptEvent(
        activeAttemptID: currentAttemptID,
        eventAttemptID: previousAttemptID
      )
    )
    XCTAssertTrue(
      DownsampledRemoteImageStateDecision.canAcceptEvent(
        activeAttemptID: currentAttemptID,
        eventAttemptID: currentAttemptID
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canAcceptEvent(
        activeAttemptID: nil,
        eventAttemptID: currentAttemptID
      )
    )
  }

  func testLoadProgressCannotMoveBackwardOrLeaveDecodingStage() {
    let twentyPercent = DownsampledRemoteImageLoadProgress.downloading(
      RemoteImageDownloadProgress(receivedByteCount: 20, expectedByteCount: 100)
    )
    let fortyPercent = DownsampledRemoteImageLoadProgress.downloading(
      RemoteImageDownloadProgress(receivedByteCount: 40, expectedByteCount: 100)
    )
    let largerByteCountButLowerPercentage = DownsampledRemoteImageLoadProgress.downloading(
      RemoteImageDownloadProgress(receivedByteCount: 50, expectedByteCount: 250)
    )

    XCTAssertTrue(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: nil,
        to: twentyPercent
      )
    )
    XCTAssertTrue(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: twentyPercent,
        to: fortyPercent
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: fortyPercent,
        to: twentyPercent
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: fortyPercent,
        to: largerByteCountButLowerPercentage
      )
    )
    XCTAssertTrue(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: fortyPercent,
        to: .decoding
      )
    )
    XCTAssertFalse(
      DownsampledRemoteImageStateDecision.canAdvanceProgress(
        from: .decoding,
        to: fortyPercent
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
    let recordedNetworkAccesses = await downloader.recordedNetworkAccesses()
    XCTAssertEqual(recordedNetworkAccesses, [.unrestricted])
  }

  func testEconomicalPolicyUsesEconomicalNetworkAccess() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/economical.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 1_600,
      fetchPolicy: .allowEconomicalNetwork(.preview)
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
    let recordedNetworkAccesses = await downloader.recordedNetworkAccesses()
    XCTAssertEqual(recordedNetworkAccesses, [.economicalOnly])
  }

  func testScopedURLPolicyRejectsInitialURLBeforeDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://example.com/disallowed-avatar.jpg"))

    do {
      _ = try await repository.image(
        at: url,
        maxPixelSize: 160,
        fetchPolicy: .allowNetwork(.preview),
        urlPolicy: .forumAvatar,
        onProgress: { _ in }
      )
      XCTFail("Expected scoped forum-avatar policy to reject the URL")
    } catch DownsampledImageError.invalidResponse {
      // Expected.
    }

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertTrue(recordedKinds.isEmpty)
  }

  func testColdCacheOnlyMissDoesNotStartDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: Data())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cold.jpg"))

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertTrue(recordedKinds.isEmpty)
  }

  func testPersistentCacheOnlyHitSurvivesRepositoryRecreationWithoutNetwork() async throws {
    let environment = try makeDiskCacheEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.rootURL) }
    let url = try XCTUnwrap(URL(string: "https://img.example/persistent-preview.jpg"))
    let firstDownloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let firstCache = RemoteImageDiskCache(
      directoryURL: environment.cacheURL,
      leaseDirectoryURL: environment.leaseURL
    )
    let firstRepository = DownsampledImageRepository(
      downloader: firstDownloader,
      persistentCache: firstCache
    )

    _ = try await firstRepository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )

    let secondDownloader = RecordingRemoteImageDownloader(imageData: Data())
    let recreatedCache = RemoteImageDiskCache(
      directoryURL: environment.cacheURL,
      leaseDirectoryURL: environment.leaseURL
    )
    let recreatedRepository = DownsampledImageRepository(
      downloader: secondDownloader,
      persistentCache: recreatedCache
    )
    let asset = try await recreatedRepository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview)
    )

    let firstKinds = await firstDownloader.recordedKinds()
    let secondKinds = await secondDownloader.recordedKinds()
    XCTAssertGreaterThan(asset.pixelSize.width, 0)
    XCTAssertEqual(firstKinds, [.preview])
    XCTAssertTrue(secondKinds.isEmpty)
  }

  func testUnreadableNetworkResponseIsNeverPersisted() async throws {
    let environment = try makeDiskCacheEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.rootURL) }
    let cache = RemoteImageDiskCache(
      directoryURL: environment.cacheURL,
      leaseDirectoryURL: environment.leaseURL
    )
    let downloader = RecordingRemoteImageDownloader(
      imageData: Data("not-an-image".utf8)
    )
    let repository = DownsampledImageRepository(
      downloader: downloader,
      persistentCache: cache
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/not-an-image"))

    do {
      _ = try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
      XCTFail("Expected the invalid image to be rejected")
    } catch {
      XCTAssertEqual(error as? DownsampledImageError, .unreadableImage)
    }

    let usage = await cache.usage()
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0))
    let cached = try await cache.cachedDownload(from: url, kind: .preview)
    XCTAssertNil(cached)
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
      fetchPolicy: .cacheOnly(.preview)
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testCompletedAnimationIsCachedAsTheSameCompleteAsset() async throws {
    let downloader = RecordingRemoteImageDownloader(
      imageData: try makeAnimatedGIFData(frameDurations: [0.1, 0.2])
    )
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cached-animation.gif"))

    let networkAsset = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    let cachedAsset = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview)
    )

    let networkAnimation = try XCTUnwrap(networkAsset.animation)
    let cachedAnimation = try XCTUnwrap(cachedAsset.animation)
    XCTAssertEqual(networkAnimation.id, cachedAnimation.id)
    XCTAssertEqual(networkAnimation.frameCount, 2)
    XCTAssertEqual(networkAsset.decodedByteCost, networkAnimation.decodedByteCost)
    XCTAssertEqual(cachedAsset.decodedByteCost, networkAsset.decodedByteCost)
    let secondFrame = try await cachedAnimation.decodedFrame(at: 1)
    XCTAssertNotNil(secondFrame.image.cgImage)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedAnimation.source.fileURL.path))
    let frameKey = RemoteImageAnimationFrameCacheKey(
      sequenceID: cachedAnimation.id,
      frameIndex: 1
    )
    let (frameBeforeClear, _) =
      RemoteImageAnimationFrameCache.shared.cachedFrameAndGeneration(for: frameKey)
    XCTAssertNotNil(frameBeforeClear)
    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])

    await repository.clearMemoryCache()
    let (frameAfterClear, _) =
      RemoteImageAnimationFrameCache.shared.cachedFrameAndGeneration(for: frameKey)
    XCTAssertNil(frameAfterClear)
  }

  func testAnimatedAssetRetainsDownloadedLeaseUntilAssetAndCacheRelease() async throws {
    let data = try makeAnimatedGIFData(frameDurations: [0.1, 0.2])
    let downloader = RecordingRemoteImageDownloader(imageData: data)
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/lease-animation.gif"))
    var asset: DownsampledImageAsset? = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    var animation: RemoteImageAnimationSequence? = try XCTUnwrap(asset?.animation)
    let leasedFileURL = try XCTUnwrap(animation?.source.fileURL)
    let poster = try XCTUnwrap(animation?.poster)
    let posterCost = try XCTUnwrap(ImageDownsampler.decodedByteCost(of: poster))

    XCTAssertTrue(FileManager.default.fileExists(atPath: leasedFileURL.path))
    XCTAssertEqual(asset?.decodedByteCost, posterCost + data.count)

    await repository.clearMemoryCache()
    XCTAssertTrue(FileManager.default.fileExists(atPath: leasedFileURL.path))
    asset = nil
    XCTAssertTrue(FileManager.default.fileExists(atPath: leasedFileURL.path))

    animation = nil
    let didRemoveLease = await waitUntilFileIsRemoved(leasedFileURL)
    XCTAssertTrue(didRemoveLease)
  }

  func testClearMemoryCacheEvictsCompletedEntryWithoutStartingDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-completed.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview)
    )

    await repository.clearMemoryCache()

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
  }

  func testClearMemoryCacheIsIdempotentAndDoesNotStartDownload() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: Data())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-cold.jpg"))

    await repository.clearMemoryCache()
    await repository.clearMemoryCache()

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let recordedKinds = await downloader.recordedKinds()
    XCTAssertTrue(recordedKinds.isEmpty)
  }

  func testClearAllImageCachesBlocksCrossLayerReadsUntilDiskClearFinishes() async throws {
    let url = try XCTUnwrap(URL(string: "https://img.example/cross-layer-clear.jpg"))
    let persistentCache = GatedPersistentImageCache(imageData: try makeJPEGData())
    addTeardownBlock { await persistentCache.releaseClear() }
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(
      downloader: downloader,
      persistentCache: persistentCache
    )

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    let readsBeforeClear = await persistentCache.cachedReadCount()
    XCTAssertEqual(readsBeforeClear, 1)

    let clearTask = Task {
      await repository.clearAllImageCaches(using: persistentCache)
    }
    let didEnterClear = await persistentCache.waitUntilClearStarted()
    XCTAssertTrue(didEnterClear)

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let readsDuringClear = await persistentCache.cachedReadCount()
    XCTAssertEqual(readsDuringClear, readsBeforeClear)

    await persistentCache.releaseClear()
    let result = await clearTask.value
    XCTAssertTrue(result.removedAllEntries)
    let networkKinds = await downloader.recordedKinds()
    XCTAssertTrue(networkKinds.isEmpty)
  }

  func testClearDuringInFlightRequestDoesNotCancelOrRepopulateCache() async throws {
    let cancellationProbe = RemoteImageCancellationProbe()
    let downloader = GatedRemoteImageDownloader(
      imageData: try makeJPEGData(),
      cancellationProbe: cancellationProbe
    )
    addTeardownBlock { await downloader.releaseAll() }
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-in-flight.jpg"))
    let request = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didStart)

    await repository.clearMemoryCache()
    await downloader.releaseAll()
    _ = try await request.value

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let requestCount = await downloader.requestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(cancellationProbe.count, 0)
  }

  func testPostClearWaiterCanShareInFlightTransferAndPopulateNewGeneration() async throws {
    let cancellationProbe = RemoteImageCancellationProbe()
    let waiterCountProbe = InFlightWaiterCountProbe()
    let downloader = GatedRemoteImageDownloader(
      imageData: try makeJPEGData(),
      cancellationProbe: cancellationProbe
    )
    addTeardownBlock { await downloader.releaseAll() }
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-joined.jpg"))
    let oldGenerationRequest = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didRegisterOldWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterOldWaiter)
    XCTAssertTrue(didStart)

    await repository.clearMemoryCache()
    let newGenerationRequest = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didJoinNewWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    XCTAssertTrue(didJoinNewWaiter)

    await downloader.releaseAll()
    _ = try await oldGenerationRequest.value
    _ = try await newGenerationRequest.value
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview)
    )

    let requestCount = await downloader.requestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(cancellationProbe.count, 0)
  }

  func testCancellingPostClearWaiterLeavesOldGenerationUnableToPopulateCache() async throws {
    let cancellationProbe = RemoteImageCancellationProbe()
    let waiterCountProbe = InFlightWaiterCountProbe()
    let downloader = GatedRemoteImageDownloader(
      imageData: try makeJPEGData(),
      cancellationProbe: cancellationProbe
    )
    addTeardownBlock { await downloader.releaseAll() }
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-cancel-joined.jpg"))
    let oldGenerationRequest = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didRegisterOldWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterOldWaiter)
    XCTAssertTrue(didStart)

    await repository.clearMemoryCache()
    let newGenerationRequest = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didJoinNewWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    XCTAssertTrue(didJoinNewWaiter)

    newGenerationRequest.cancel()
    let didRemoveNewWaiter = await waiterCountProbe.waitUntilCounts([1, 2, 1])
    XCTAssertTrue(didRemoveNewWaiter)
    await downloader.releaseAll()
    _ = try await oldGenerationRequest.value
    switch await newGenerationRequest.result {
    case .success:
      XCTFail("The cancelled new-generation waiter must not succeed")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }

    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
    let requestCount = await downloader.requestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(cancellationProbe.count, 0)
  }

  func testNetworkFetchAfterClearDownloadsAgainAndPopulatesCache() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/refetch-after-clear.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    await repository.clearMemoryCache()
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview)
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview, .preview])
  }

  func testCacheIsSharedAcrossNetworkAccessPolicies() async throws {
    let downloader = RecordingRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/access-cached.jpg"))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowEconomicalNetwork(.preview)
    )
    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview)
    )

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview])
    let recordedNetworkAccesses = await downloader.recordedNetworkAccesses()
    XCTAssertEqual(recordedNetworkAccesses, [.economicalOnly])
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
      fetchPolicy: .cacheOnly(.preview)
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
    let recordedNetworkAccesses = await downloader.recordedNetworkAccesses()
    XCTAssertEqual(recordedNetworkAccesses, [.unrestricted])
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

  func testDifferentNetworkAccessesDoNotShareInFlightRequest() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/network-access.jpg"))
    let unrestrictedTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let unrestrictedDidStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(unrestrictedDidStart)
    let economicalTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowEconomicalNetwork(.preview)
      )
    }
    let economicalDidStart = await downloader.waitUntilRequestCount(2)
    XCTAssertTrue(economicalDidStart)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview, .preview])
    let recordedNetworkAccesses = await downloader.recordedNetworkAccesses()
    XCTAssertEqual(recordedNetworkAccesses, [.unrestricted, .economicalOnly])

    unrestrictedTask.cancel()
    economicalTask.cancel()
    let didCancelBoth = await downloader.waitUntilCancellationCount(2)
    XCTAssertTrue(didCancelBoth)
    await downloader.releaseAll()
    _ = await unrestrictedTask.result
    _ = await economicalTask.result
  }

  func testCancellingEconomicalTransferDoesNotCancelUnrestrictedTransfer() async throws {
    let downloader = SuspendedRemoteImageDownloader(imageData: try makeJPEGData())
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/access-cancellation.jpg"))
    let unrestrictedTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let unrestrictedDidStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(unrestrictedDidStart)
    let economicalTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowEconomicalNetwork(.preview)
      )
    }
    let economicalDidStart = await downloader.waitUntilRequestCount(2)
    XCTAssertTrue(economicalDidStart)

    economicalTask.cancel()
    let economicalDidCancel = await downloader.waitUntilCancellationCount(1)
    let cancellationCountBeforeRelease = await downloader.cancelledRequestCount()
    XCTAssertTrue(economicalDidCancel)
    XCTAssertEqual(cancellationCountBeforeRelease, 1)

    await downloader.releaseAll()
    _ = try await unrestrictedTask.value
    switch await economicalTask.result {
    case .success:
      XCTFail("The cancelled economical transfer must not succeed")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    let finalCancellationCount = await downloader.cancelledRequestCount()
    XCTAssertEqual(finalCancellationCount, 1)
  }

  func testCancellingOneOfTwoIdenticalWaitersKeepsSharedTransferAlive() async throws {
    let cancellationProbe = RemoteImageCancellationProbe()
    let waiterCountProbe = InFlightWaiterCountProbe()
    let downloader = GatedRemoteImageDownloader(
      imageData: try makeJPEGData(),
      cancellationProbe: cancellationProbe
    )
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in
        waiterCountProbe.record(count)
      }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/shared-waiters.jpg"))

    let firstTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didRegisterFirstWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartRequest = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterFirstWaiter)
    XCTAssertTrue(didStartRequest)

    let secondTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didJoinSecondWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    let joinedRequestCount = await downloader.requestCount()
    XCTAssertTrue(didJoinSecondWaiter)
    XCTAssertEqual(joinedRequestCount, 1)

    firstTask.cancel()
    let didRemoveOnlyFirstWaiter = await waiterCountProbe.waitUntilCounts([1, 2, 1])
    XCTAssertTrue(didRemoveOnlyFirstWaiter)
    XCTAssertEqual(cancellationProbe.count, 0)

    await downloader.releaseAll()
    _ = try await secondTask.value
    let didRemoveCompletedWaiter = await waiterCountProbe.waitUntilCounts([1, 2, 1, 0])
    XCTAssertTrue(didRemoveCompletedWaiter)

    do {
      _ = try await firstTask.value
      XCTFail("Expected the cancelled waiter to throw")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let completedRequestCount = await downloader.requestCount()
    XCTAssertEqual(completedRequestCount, 1)
    XCTAssertEqual(cancellationProbe.count, 0)
  }

  func testFinalWaiterCancellationCancelsTransferAndDoesNotPopulateCache() async throws {
    let cancellationProbe = RemoteImageCancellationProbe()
    let waiterCountProbe = InFlightWaiterCountProbe()
    let downloader = GatedRemoteImageDownloader(
      imageData: try makeJPEGData(),
      cancellationProbe: cancellationProbe
    )
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in
        waiterCountProbe.record(count)
      }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/cancelled.jpg"))
    let networkTask = Task {
      try await repository.image(
        at: url,
        maxPixelSize: 320,
        fetchPolicy: .allowNetwork(.preview)
      )
    }
    let didRegisterWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStart = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterWaiter)
    XCTAssertTrue(didStart)

    networkTask.cancel()
    let didRemoveFinalWaiter = await waiterCountProbe.waitUntilCounts([1, 0])
    XCTAssertTrue(didRemoveFinalWaiter)
    XCTAssertEqual(cancellationProbe.count, 1)
    await downloader.releaseAll()
    _ = await networkTask.result

    let requestCount = await downloader.requestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(cancellationProbe.count, 1)
    await expectCacheMiss(repository, url: url, maxPixelSize: 320)
  }

  func testSharedTransferBroadcastsProgressAndReplaysLatestToLateWaiter() async throws {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    addTeardownBlock { await downloader.releaseAll() }
    let waiterCountProbe = InFlightWaiterCountProbe()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/shared-progress.jpg"))
    let firstProgressProbe = RemoteImageLoadProgressProbe()
    let secondProgressProbe = RemoteImageLoadProgressProbe()
    let tenPercent = RemoteImageDownloadProgress(
      receivedByteCount: 10,
      expectedByteCount: 100
    )
    let fortyPercent = RemoteImageDownloadProgress(
      receivedByteCount: 40,
      expectedByteCount: 100
    )
    let firstCompletionProbe = RemoteImageRequestCompletionProbe()
    let secondCompletionProbe = RemoteImageRequestCompletionProbe()

    let firstTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: firstProgressProbe,
      completionProbe: firstCompletionProbe
    )
    let didRegisterFirstWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartTransfer = await downloader.waitUntilRequestCount(1)
    let didEmitTenPercent = await downloader.emit(tenPercent, forRequestAt: 0)
    let firstWaiterReceivedTenPercent = await firstProgressProbe.waitUntilEvents([
      .downloading(tenPercent)
    ])
    XCTAssertTrue(didRegisterFirstWaiter)
    XCTAssertTrue(didStartTransfer)
    XCTAssertTrue(didEmitTenPercent)
    XCTAssertTrue(firstWaiterReceivedTenPercent)

    let secondTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: secondProgressProbe,
      completionProbe: secondCompletionProbe
    )
    let didRegisterSecondWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    let secondWaiterReceivedLatest = await secondProgressProbe.waitUntilEvents([
      .downloading(tenPercent)
    ])
    let joinedRequestCount = await downloader.requestCount()
    XCTAssertTrue(didRegisterSecondWaiter)
    XCTAssertTrue(secondWaiterReceivedLatest)
    XCTAssertEqual(joinedRequestCount, 1)

    let didEmitFortyPercent = await downloader.emit(fortyPercent, forRequestAt: 0)
    let expectedProgress: [DownsampledRemoteImageLoadProgress] = [
      .downloading(tenPercent),
      .downloading(fortyPercent),
    ]
    let firstWaiterReceivedFortyPercent = await firstProgressProbe.waitUntilEvents(
      expectedProgress
    )
    let secondWaiterReceivedFortyPercent = await secondProgressProbe.waitUntilEvents(
      expectedProgress
    )
    XCTAssertTrue(didEmitFortyPercent)
    XCTAssertTrue(firstWaiterReceivedFortyPercent)
    XCTAssertTrue(secondWaiterReceivedFortyPercent)

    await downloader.releaseAll()
    async let firstCompletion = firstCompletionProbe.waitUntilOutcome(
      timeout: .seconds(10)
    )
    async let secondCompletion = secondCompletionProbe.waitUntilOutcome(
      timeout: .seconds(10)
    )
    let (firstOutcome, secondOutcome) = await (firstCompletion, secondCompletion)
    if firstOutcome == nil { firstTask.cancel() }
    if secondOutcome == nil { secondTask.cancel() }
    XCTAssertEqual(firstOutcome, .some(.success))
    XCTAssertEqual(secondOutcome, .some(.success))
  }

  func testCancellingProgressWaiterStopsItsUpdatesAndOnlyFinalWaiterCancelsTransfer()
    async throws
  {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    addTeardownBlock { await downloader.releaseAll() }
    let waiterCountProbe = InFlightWaiterCountProbe()
    let progressEventProbe = InFlightProgressEventProbe()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) },
      inFlightProgressEventDidProcess: { progress, didAccept in
        progressEventProbe.record(progress, didAccept: didAccept)
      }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/cancel-progress-waiter.jpg"))
    let firstProgressProbe = RemoteImageLoadProgressProbe()
    let secondProgressProbe = RemoteImageLoadProgressProbe()
    let tenPercent = RemoteImageDownloadProgress(
      receivedByteCount: 10,
      expectedByteCount: 100
    )
    let fortyPercent = RemoteImageDownloadProgress(
      receivedByteCount: 40,
      expectedByteCount: 100
    )
    let firstCompletionProbe = RemoteImageRequestCompletionProbe()
    let secondCompletionProbe = RemoteImageRequestCompletionProbe()

    let firstTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: firstProgressProbe,
      completionProbe: firstCompletionProbe
    )
    let didRegisterFirstWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartTransfer = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterFirstWaiter)
    XCTAssertTrue(didStartTransfer)
    let secondTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: secondProgressProbe,
      completionProbe: secondCompletionProbe
    )
    let didRegisterSecondWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    XCTAssertTrue(didRegisterSecondWaiter)

    let didEmitTenPercent = await downloader.emit(tenPercent, forRequestAt: 0)
    let initialProgress: [DownsampledRemoteImageLoadProgress] = [.downloading(tenPercent)]
    let firstWaiterReceivedInitialProgress = await firstProgressProbe.waitUntilEvents(
      initialProgress
    )
    let secondWaiterReceivedInitialProgress = await secondProgressProbe.waitUntilEvents(
      initialProgress
    )
    let didProcessInitialProgress = await progressEventProbe.waitUntilEvents([
      .init(progress: .downloading(tenPercent), didAccept: true)
    ])
    XCTAssertTrue(didEmitTenPercent)
    XCTAssertTrue(firstWaiterReceivedInitialProgress)
    XCTAssertTrue(secondWaiterReceivedInitialProgress)
    XCTAssertTrue(didProcessInitialProgress)

    firstTask.cancel()
    let didRemoveFirstWaiter = await waiterCountProbe.waitUntilCounts([1, 2, 1])
    XCTAssertTrue(didRemoveFirstWaiter)

    let didEmitFortyPercent = await downloader.emit(fortyPercent, forRequestAt: 0)
    let secondWaiterReceivedFortyPercent = await secondProgressProbe.waitUntilEvents([
      .downloading(tenPercent),
      .downloading(fortyPercent),
    ])
    let didProcessProgressAfterCancellation = await progressEventProbe.waitUntilEvents([
      .init(progress: .downloading(tenPercent), didAccept: true),
      .init(progress: .downloading(fortyPercent), didAccept: true),
    ])
    let cancellationCountAfterProgressFence = await downloader.cancellationCount()
    XCTAssertTrue(didEmitFortyPercent)
    XCTAssertTrue(secondWaiterReceivedFortyPercent)
    XCTAssertTrue(didProcessProgressAfterCancellation)
    XCTAssertEqual(firstProgressProbe.events(), initialProgress)
    XCTAssertEqual(cancellationCountAfterProgressFence, 0)

    secondTask.cancel()
    let didRemoveFinalWaiter = await waiterCountProbe.waitUntilCounts([1, 2, 1, 0])
    let didCancelTransfer = await downloader.waitUntilCancellationCount(1)
    XCTAssertTrue(didRemoveFinalWaiter)
    XCTAssertTrue(didCancelTransfer)
    await downloader.releaseAll()
    let firstOutcome = await firstCompletionProbe.waitUntilOutcome()
    let secondOutcome = await secondCompletionProbe.waitUntilOutcome()
    if firstOutcome == nil { firstTask.cancel() }
    if secondOutcome == nil { secondTask.cancel() }
    let finalCancellationCount = await downloader.cancellationCount()
    XCTAssertEqual(firstOutcome, .some(.cancelled))
    XCTAssertEqual(secondOutcome, .some(.cancelled))
    XCTAssertEqual(finalCancellationCount, 1)
  }

  func testRestartedSameKeyTransferRejectsLateProgressFromCancelledTransfer() async throws {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    addTeardownBlock { await downloader.releaseAll() }
    let waiterCountProbe = InFlightWaiterCountProbe()
    let progressEventProbe = InFlightProgressEventProbe()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) },
      inFlightProgressEventDidProcess: { progress, didAccept in
        progressEventProbe.record(progress, didAccept: didAccept)
      }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/restarted-progress.jpg"))
    let oldProgressProbe = RemoteImageLoadProgressProbe()
    let newProgressProbe = RemoteImageLoadProgressProbe()
    let staleNinetyPercent = RemoteImageDownloadProgress(
      receivedByteCount: 90,
      expectedByteCount: 100
    )
    let currentTwentyPercent = RemoteImageDownloadProgress(
      receivedByteCount: 20,
      expectedByteCount: 100
    )
    let oldCompletionProbe = RemoteImageRequestCompletionProbe()
    let newCompletionProbe = RemoteImageRequestCompletionProbe()

    let oldTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: oldProgressProbe,
      completionProbe: oldCompletionProbe
    )
    let didRegisterOldWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartOldTransfer = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterOldWaiter)
    XCTAssertTrue(didStartOldTransfer)

    oldTask.cancel()
    let didRemoveOldWaiter = await waiterCountProbe.waitUntilCounts([1, 0])
    let didCancelOldTransfer = await downloader.waitUntilCancellationCount(1)
    XCTAssertTrue(didRemoveOldWaiter)
    XCTAssertTrue(didCancelOldTransfer)

    let newTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: newProgressProbe,
      completionProbe: newCompletionProbe
    )
    let didRegisterNewWaiter = await waiterCountProbe.waitUntilCounts([1, 0, 1])
    let didStartNewTransfer = await downloader.waitUntilRequestCount(2)
    XCTAssertTrue(didRegisterNewWaiter)
    XCTAssertTrue(didStartNewTransfer)

    let didEmitStaleProgress = await downloader.emit(
      staleNinetyPercent,
      forRequestAt: 0
    )
    let didRejectStaleProgress = await progressEventProbe.waitUntilEvents([
      .init(progress: .downloading(staleNinetyPercent), didAccept: false)
    ])
    XCTAssertTrue(didEmitStaleProgress)
    XCTAssertTrue(didRejectStaleProgress)
    XCTAssertTrue(newProgressProbe.events().isEmpty)

    let didEmitCurrentProgress = await downloader.emit(
      currentTwentyPercent,
      forRequestAt: 1
    )
    let newWaiterReceivedOnlyCurrentProgress = await newProgressProbe.waitUntilEvents([
      .downloading(currentTwentyPercent)
    ])
    let didAcceptCurrentProgress = await progressEventProbe.waitUntilEvents([
      .init(progress: .downloading(staleNinetyPercent), didAccept: false),
      .init(progress: .downloading(currentTwentyPercent), didAccept: true),
    ])
    XCTAssertTrue(didEmitCurrentProgress)
    XCTAssertTrue(newWaiterReceivedOnlyCurrentProgress)
    XCTAssertTrue(didAcceptCurrentProgress)
    XCTAssertTrue(oldProgressProbe.events().isEmpty)

    newTask.cancel()
    let didRemoveNewWaiter = await waiterCountProbe.waitUntilCounts([1, 0, 1, 0])
    let didCancelNewTransfer = await downloader.waitUntilCancellationCount(2)
    XCTAssertTrue(didRemoveNewWaiter)
    XCTAssertTrue(didCancelNewTransfer)
    await downloader.releaseAll()
    let oldOutcome = await oldCompletionProbe.waitUntilOutcome()
    let newOutcome = await newCompletionProbe.waitUntilOutcome()
    if oldOutcome == nil { oldTask.cancel() }
    if newOutcome == nil { newTask.cancel() }
    XCTAssertEqual(oldOutcome, .some(.cancelled))
    XCTAssertEqual(newOutcome, .some(.cancelled))
  }

  func testDecodingRejectsLateDownloadProgressAndReplaysToLateWaiter() async throws {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    let beforeDecoding = SuspendedAsyncGate()
    addTeardownBlock {
      await downloader.releaseAll()
      await beforeDecoding.open()
    }
    let waiterCountProbe = InFlightWaiterCountProbe()
    let progressEventProbe = InFlightProgressEventProbe()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      beforeDecoding: { await beforeDecoding.wait() },
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) },
      inFlightProgressEventDidProcess: { progress, didAccept in
        progressEventProbe.record(progress, didAccept: didAccept)
      }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/decoding-progress.jpg"))
    let firstProgressProbe = RemoteImageLoadProgressProbe()
    let lateProgressProbe = RemoteImageLoadProgressProbe()
    let firstCompletionProbe = RemoteImageRequestCompletionProbe()
    let lateCompletionProbe = RemoteImageRequestCompletionProbe()
    let lateDownloadProgress = RemoteImageDownloadProgress(
      receivedByteCount: 80,
      expectedByteCount: 100
    )

    let firstTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: firstProgressProbe,
      completionProbe: firstCompletionProbe
    )
    let didRegisterFirstWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartTransfer = await downloader.waitUntilRequestCount(1)
    XCTAssertTrue(didRegisterFirstWaiter)
    XCTAssertTrue(didStartTransfer)

    await downloader.release(0)
    let didEnterDecodingGate = await beforeDecoding.waitUntilEntered()
    let firstWaiterEnteredDecoding = await firstProgressProbe.waitUntilEvents([.decoding])
    XCTAssertTrue(didEnterDecodingGate)
    XCTAssertTrue(firstWaiterEnteredDecoding)

    let didEmitLateProgress = await downloader.emit(lateDownloadProgress, forRequestAt: 0)
    let didRejectLateProgress = await progressEventProbe.waitUntilEvents([
      .init(progress: .downloading(lateDownloadProgress), didAccept: false)
    ])
    XCTAssertTrue(didEmitLateProgress)
    XCTAssertTrue(didRejectLateProgress)
    XCTAssertEqual(firstProgressProbe.events(), [.decoding])

    let lateTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: lateProgressProbe,
      completionProbe: lateCompletionProbe
    )
    let didRegisterLateWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    let lateWaiterReceivedDecoding = await lateProgressProbe.waitUntilEvents([.decoding])
    let requestCount = await downloader.requestCount()
    XCTAssertTrue(didRegisterLateWaiter)
    XCTAssertTrue(lateWaiterReceivedDecoding)
    XCTAssertEqual(requestCount, 1)

    await downloader.releaseAll()
    await beforeDecoding.open()
    let firstOutcome = await firstCompletionProbe.waitUntilOutcome()
    let lateOutcome = await lateCompletionProbe.waitUntilOutcome()
    if firstOutcome == nil { firstTask.cancel() }
    if lateOutcome == nil { lateTask.cancel() }
    XCTAssertEqual(firstOutcome, .some(.success))
    XCTAssertEqual(lateOutcome, .some(.success))
  }

  func testPostClearWaiterJoinsTransferAndReceivesLatestProgress() async throws {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    addTeardownBlock { await downloader.releaseAll() }
    let waiterCountProbe = InFlightWaiterCountProbe()
    let repository = DownsampledImageRepository(
      downloader: downloader,
      inFlightWaiterCountDidChange: { count in waiterCountProbe.record(count) }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/clear-progress.jpg"))
    let oldProgressProbe = RemoteImageLoadProgressProbe()
    let newProgressProbe = RemoteImageLoadProgressProbe()
    let thirtyPercent = RemoteImageDownloadProgress(
      receivedByteCount: 30,
      expectedByteCount: 100
    )
    let oldCompletionProbe = RemoteImageRequestCompletionProbe()
    let newCompletionProbe = RemoteImageRequestCompletionProbe()

    let oldGenerationTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: oldProgressProbe,
      completionProbe: oldCompletionProbe
    )
    let didRegisterOldWaiter = await waiterCountProbe.waitUntilCounts([1])
    let didStartTransfer = await downloader.waitUntilRequestCount(1)
    let didEmitThirtyPercent = await downloader.emit(thirtyPercent, forRequestAt: 0)
    let oldWaiterReceivedProgress = await oldProgressProbe.waitUntilEvents([
      .downloading(thirtyPercent)
    ])
    XCTAssertTrue(didRegisterOldWaiter)
    XCTAssertTrue(didStartTransfer)
    XCTAssertTrue(didEmitThirtyPercent)
    XCTAssertTrue(oldWaiterReceivedProgress)

    await repository.clearMemoryCache()
    let newGenerationTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: newProgressProbe,
      completionProbe: newCompletionProbe
    )
    let didRegisterNewWaiter = await waiterCountProbe.waitUntilCounts([1, 2])
    let newWaiterReceivedLatestProgress = await newProgressProbe.waitUntilEvents([
      .downloading(thirtyPercent)
    ])
    let requestCountAfterClear = await downloader.requestCount()
    XCTAssertTrue(didRegisterNewWaiter)
    XCTAssertTrue(newWaiterReceivedLatestProgress)
    XCTAssertEqual(requestCountAfterClear, 1)

    await downloader.releaseAll()
    let oldOutcome = await oldCompletionProbe.waitUntilOutcome()
    let newOutcome = await newCompletionProbe.waitUntilOutcome()
    if oldOutcome == nil { oldGenerationTask.cancel() }
    if newOutcome == nil { newGenerationTask.cancel() }
    XCTAssertEqual(oldOutcome, .some(.success))
    XCTAssertEqual(newOutcome, .some(.success))
  }

  func testCacheHitDoesNotReportProgressOrStartAnotherTransfer() async throws {
    let downloader = ControlledProgressRemoteImageDownloader(imageData: try makeJPEGData())
    addTeardownBlock { await downloader.releaseAll() }
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/cached-progress.jpg"))
    let networkProgressProbe = RemoteImageLoadProgressProbe()
    let cachedProgressProbe = RemoteImageLoadProgressProbe()
    let halfway = RemoteImageDownloadProgress(
      receivedByteCount: 50,
      expectedByteCount: 100
    )
    let networkCompletionProbe = RemoteImageRequestCompletionProbe()

    let networkTask = startRemoteImageRequest(
      repository: repository,
      url: url,
      maxPixelSize: 320,
      fetchPolicy: .allowNetwork(.preview),
      progressProbe: networkProgressProbe,
      completionProbe: networkCompletionProbe
    )
    let didStartTransfer = await downloader.waitUntilRequestCount(1)
    let didEmitHalfway = await downloader.emit(halfway, forRequestAt: 0)
    let networkWaiterReceivedProgress = await networkProgressProbe.waitUntilEvents([
      .downloading(halfway)
    ])
    XCTAssertTrue(didStartTransfer)
    XCTAssertTrue(didEmitHalfway)
    XCTAssertTrue(networkWaiterReceivedProgress)
    await downloader.releaseAll()
    let networkOutcome = await networkCompletionProbe.waitUntilOutcome(
      timeout: .seconds(10)
    )
    if networkOutcome == nil { networkTask.cancel() }
    XCTAssertEqual(networkOutcome, .some(.success))

    _ = try await repository.image(
      at: url,
      maxPixelSize: 320,
      fetchPolicy: .cacheOnly(.preview),
      onProgress: { progress in cachedProgressProbe.record(progress) }
    )

    XCTAssertTrue(cachedProgressProbe.events().isEmpty)
    let finalRequestCount = await downloader.requestCount()
    XCTAssertEqual(finalRequestCount, 1)
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
        fetchPolicy: .cacheOnly(.preview)
      )
      XCTFail("Expected a cache miss")
    } catch DownsampledImageError.cacheMiss {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func waitUntilFileIsRemoved(
    _ fileURL: URL,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while FileManager.default.fileExists(atPath: fileURL.path), clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return !FileManager.default.fileExists(atPath: fileURL.path)
  }

  private func makeDiskCacheEnvironment() throws -> (
    rootURL: URL,
    cacheURL: URL,
    leaseURL: URL
  ) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("DownsampledImageDiskCacheTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    return (
      rootURL,
      rootURL.appendingPathComponent("cache", isDirectory: true),
      rootURL.appendingPathComponent("leases", isDirectory: true)
    )
  }

  private func makeJPEGData() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
    let image = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
  }

  private func makeAnimatedGIFData(frameDurations: [TimeInterval]) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data,
        UTType.gif.identifier as CFString,
        frameDurations.count,
        nil
      )
    )
    CGImageDestinationSetProperties(
      destination,
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFLoopCount: 0
        ]
      ] as CFDictionary
    )
    for (index, duration) in frameDurations.enumerated() {
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
      let image = renderer.image { context in
        (index.isMultiple(of: 2) ? UIColor.systemBlue : UIColor.systemRed).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
      }
      CGImageDestinationAddImage(
        destination,
        try XCTUnwrap(image.cgImage),
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: duration,
            kCGImagePropertyGIFUnclampedDelayTime: duration,
          ]
        ] as CFDictionary
      )
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private actor GatedPersistentImageCache: RemoteImagePersistentCacheProviding {
  private let imageData: Data
  private var cachedReads = 0
  private var clearStarted = false
  private var clearContinuation: CheckedContinuation<Void, Never>?
  private var clearReleased = false

  init(imageData: Data) {
    self.imageData = imageData
  }

  func cachedDownload(
    from url: URL,
    kind: RemoteImageDownloadKind
  ) async throws -> RemoteImageFileLease? {
    cachedReads += 1
    return try makeLease(imageData: imageData, sourceURL: url)
  }

  func currentGenerationToken() async -> RemoteImageDiskCacheGenerationToken {
    await RemoteImageDiskCache.shared.currentGenerationToken()
  }

  func storeValidated(
    _ lease: RemoteImageFileLease,
    requestedURL: URL,
    kind: RemoteImageDownloadKind,
    generationToken: RemoteImageDiskCacheGenerationToken
  ) async throws {}

  func usage() async -> RemoteImageDiskCacheUsage {
    RemoteImageDiskCacheUsage(entryCount: 1, byteCount: Int64(imageData.count))
  }

  func clear() async -> RemoteImageDiskCacheClearResult {
    clearStarted = true
    if !clearReleased {
      await withCheckedContinuation { continuation in
        clearContinuation = continuation
      }
    }
    return RemoteImageDiskCacheClearResult(
      removedEntryCount: 1,
      removedByteCount: Int64(imageData.count),
      removedAllEntries: true
    )
  }

  func cachedReadCount() -> Int {
    cachedReads
  }

  func waitUntilClearStarted(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !clearStarted, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return clearStarted
  }

  func releaseClear() {
    clearReleased = true
    clearContinuation?.resume()
    clearContinuation = nil
  }
}

private actor RecordingRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private var kinds: [RemoteImageDownloadKind] = []
  private var networkAccesses: [RemoteImageNetworkAccess] = []

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease
  {
    kinds.append(kind)
    networkAccesses.append(networkAccess)
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

  func recordedNetworkAccesses() -> [RemoteImageNetworkAccess] {
    networkAccesses
  }
}

private actor SuspendedRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private var kinds: [RemoteImageDownloadKind] = []
  private var networkAccesses: [RemoteImageNetworkAccess] = []
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var cancelledRequests = 0
  private var isReleased = false

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease
  {
    kinds.append(kind)
    networkAccesses.append(networkAccess)
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

  func recordedNetworkAccesses() -> [RemoteImageNetworkAccess] {
    networkAccesses
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

private final class RemoteImageCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellationCount = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellationCount
  }

  func recordCancellation() {
    lock.lock()
    cancellationCount += 1
    lock.unlock()
  }
}

private final class InFlightWaiterCountProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [Int] = []

  func record(_ count: Int) {
    lock.lock()
    counts.append(count)
    lock.unlock()
  }

  func waitUntilCounts(
    _ expectedCounts: [Int],
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while snapshot() != expectedCounts, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return snapshot() == expectedCounts
  }

  private func snapshot() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return counts
  }
}

private final class RemoteImageLoadProgressProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [DownsampledRemoteImageLoadProgress] = []

  func record(_ progress: DownsampledRemoteImageLoadProgress) {
    lock.lock()
    recordedEvents.append(progress)
    lock.unlock()
  }

  func events() -> [DownsampledRemoteImageLoadProgress] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  func waitUntilEvents(
    _ expectedEvents: [DownsampledRemoteImageLoadProgress],
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while events() != expectedEvents, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return events() == expectedEvents
  }
}

private final class InFlightProgressEventProbe: @unchecked Sendable {
  struct Event: Equatable, Sendable {
    let progress: DownsampledRemoteImageLoadProgress
    let didAccept: Bool
  }

  private let lock = NSLock()
  private var recordedEvents: [Event] = []

  func record(_ progress: DownsampledRemoteImageLoadProgress, didAccept: Bool) {
    lock.lock()
    recordedEvents.append(Event(progress: progress, didAccept: didAccept))
    lock.unlock()
  }

  func waitUntilEvents(
    _ expectedEvents: [Event],
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while snapshot() != expectedEvents, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return snapshot() == expectedEvents
  }

  private func snapshot() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }
}

private enum RemoteImageRequestOutcome: Equatable, Sendable {
  case success
  case cancelled
  case failure(String)
}

private final class RemoteImageRequestCompletionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedOutcome: RemoteImageRequestOutcome?

  func record(_ outcome: RemoteImageRequestOutcome) {
    lock.lock()
    if recordedOutcome == nil {
      recordedOutcome = outcome
    }
    lock.unlock()
  }

  func waitUntilOutcome(
    timeout: Duration = .seconds(2)
  ) async -> RemoteImageRequestOutcome? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while outcome() == nil, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return nil
      }
    }
    return outcome()
  }

  private func outcome() -> RemoteImageRequestOutcome? {
    lock.lock()
    defer { lock.unlock() }
    return recordedOutcome
  }
}

private func startRemoteImageRequest(
  repository: DownsampledImageRepository,
  url: URL,
  maxPixelSize: Int,
  fetchPolicy: DownsampledImageFetchPolicy,
  progressProbe: RemoteImageLoadProgressProbe,
  completionProbe: RemoteImageRequestCompletionProbe
) -> Task<Void, Never> {
  Task {
    do {
      _ = try await repository.image(
        at: url,
        maxPixelSize: maxPixelSize,
        fetchPolicy: fetchPolicy,
        onProgress: { progress in progressProbe.record(progress) }
      )
      completionProbe.record(.success)
    } catch is CancellationError {
      completionProbe.record(.cancelled)
    } catch {
      completionProbe.record(.failure(String(describing: error)))
    }
  }
}

private actor ControlledProgressRemoteImageDownloader: RemoteImageDownloading {
  private struct Request {
    let onProgress: @Sendable (RemoteImageDownloadProgress) -> Void
  }

  private let imageData: Data
  private var requests: [Request] = []
  private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var releasedRequests: Set<Int> = []
  private let cancellationProbe = RemoteImageCancellationProbe()
  private var isReleased = false

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    try await download(
      from: url,
      kind: kind,
      networkAccess: networkAccess,
      onProgress: { _ in }
    )
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) async throws -> RemoteImageFileLease {
    let requestIndex = requests.count
    requests.append(Request(onProgress: onProgress))
    let cancellationProbe = cancellationProbe
    await withTaskCancellationHandler {
      await waitForRelease(requestIndex)
    } onCancel: {
      cancellationProbe.recordCancellation()
    }
    return try makeLease(imageData: imageData, sourceURL: url)
  }

  func emit(_ progress: RemoteImageDownloadProgress, forRequestAt index: Int) -> Bool {
    guard requests.indices.contains(index) else { return false }
    requests[index].onProgress(progress)
    return true
  }

  func release(_ index: Int) {
    releasedRequests.insert(index)
    releaseWaiters.removeValue(forKey: index)?.resume()
  }

  func releaseAll() {
    isReleased = true
    let continuations = Array(releaseWaiters.values)
    releaseWaiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func requestCount() -> Int {
    requests.count
  }

  func cancellationCount() -> Int {
    cancellationProbe.count
  }

  func waitUntilRequestCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while requests.count < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return requests.count >= expectedCount
  }

  func waitUntilCancellationCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while cancellationProbe.count < expectedCount, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return cancellationProbe.count >= expectedCount
  }

  private func waitForRelease(_ requestIndex: Int) async {
    guard !isReleased, !releasedRequests.contains(requestIndex) else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters[requestIndex] = continuation
    }
  }
}

private actor GatedRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private let cancellationProbe: RemoteImageCancellationProbe
  private var kinds: [RemoteImageDownloadKind] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false

  init(imageData: Data, cancellationProbe: RemoteImageCancellationProbe) {
    self.imageData = imageData
    self.cancellationProbe = cancellationProbe
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease
  {
    kinds.append(kind)
    let cancellationProbe = cancellationProbe
    await withTaskCancellationHandler {
      await waitForRelease()
    } onCancel: {
      cancellationProbe.recordCancellation()
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

  func releaseAll() {
    isReleased = true
    let continuations = releaseWaiters
    releaseWaiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func requestCount() -> Int {
    kinds.count
  }

  private func waitForRelease() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
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
