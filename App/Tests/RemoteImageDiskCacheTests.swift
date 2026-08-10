import Foundation
import XCTest

@testable import TiebaPlusPlus

final class RemoteImageDiskCacheTests: XCTestCase {
  func testPersistentHitSurvivesCacheRecreationWithoutCallingNetwork() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let requestedURL = try XCTUnwrap(URL(string: "https://img.example/persistent.jpg"))
    let data = Data("persistent-image".utf8)

    let firstCache = environment.makeCache()
    try await store(data, for: requestedURL, in: firstCache, environment: environment)

    let network = DiskCacheNetworkSpy(
      data: Data("network".utf8),
      directoryURL: environment.networkDirectoryURL
    )
    let recreatedCache = environment.makeCache()
    let downloader = PersistentRemoteImageDownloader(
      cache: recreatedCache,
      networkDownloader: network
    )

    let lease = try await downloader.download(
      from: requestedURL,
      kind: .preview,
      networkAccess: .economicalOnly
    )

    XCTAssertEqual(try Data(contentsOf: lease.fileURL), data)
    XCTAssertEqual(lease.sourceURL, requestedURL)
    XCTAssertNil(lease.mimeType)
    XCTAssertNil(lease.suggestedFilename)
    let networkCallCount = await network.callCount()
    XCTAssertEqual(networkCallCount, 0)
  }

  func testCacheOnlyMissNeverCallsNetwork() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let network = DiskCacheNetworkSpy(
      data: Data("network".utf8),
      directoryURL: environment.networkDirectoryURL
    )
    let downloader = PersistentRemoteImageDownloader(
      cache: environment.makeCache(),
      networkDownloader: network
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/missing.jpg"))

    let result = try await downloader.cachedDownload(from: url, kind: .preview)

    XCTAssertNil(result)
    let networkCallCount = await network.callCount()
    XCTAssertEqual(networkCallCount, 0)
  }

  func testDifferentRequestedURLsAreIsolated() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/image?a=1"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/image?a=2"))
    let data = Data("first".utf8)
    try await store(data, for: firstURL, in: cache, environment: environment)

    let secondHit = try await cache.cachedDownload(from: secondURL, kind: .preview)
    XCTAssertNil(secondHit)
    let optionalFirstHit = try await cache.cachedDownload(from: firstURL, kind: .preview)
    let firstHit = try XCTUnwrap(optionalFirstHit)
    XCTAssertEqual(try Data(contentsOf: firstHit.fileURL), data)
  }

  func testPreviewLookupRejectsAndEvictsEntryLargerThanSixteenMiB() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let url = try XCTUnwrap(URL(string: "https://img.example/large-original"))
    let byteCount = RemoteImageDownloadPolicy.previewMaximumResponseBytes + 1
    let lease = try environment.makeSparseLease(
      byteCount: byteCount,
      sourceURL: url
    )
    let token = await cache.currentGenerationToken()
    try await cache.storeValidated(
      lease,
      requestedURL: url,
      kind: .original,
      generationToken: token
    )

    let previewHit = try await cache.cachedDownload(from: url, kind: .preview)
    let usage = await cache.usage()
    XCTAssertNil(previewHit)
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0))
  }

  func testCorruptMetadataPayloadAndSymlinkAreEvictedFailClosed() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let metadataURL = try XCTUnwrap(URL(string: "https://img.example/bad-metadata"))
    let payloadURL = try XCTUnwrap(URL(string: "https://img.example/bad-payload"))
    let symlinkURL = try XCTUnwrap(URL(string: "https://img.example/symlink"))
    try await store(Data("metadata".utf8), for: metadataURL, in: cache, environment: environment)
    try await store(Data("payload".utf8), for: payloadURL, in: cache, environment: environment)
    try await store(Data("symlink".utf8), for: symlinkURL, in: cache, environment: environment)

    try Data("not-json".utf8).write(
      to: entryDirectory(for: metadataURL, environment: environment)
        .appendingPathComponent("metadata.json")
    )
    let damagedPayload = entryDirectory(for: payloadURL, environment: environment)
      .appendingPathComponent("payload")
    try Data("damaged".utf8).write(to: damagedPayload)

    let outsideURL = environment.rootURL.appendingPathComponent("outside")
    try Data("outside-must-survive".utf8).write(to: outsideURL)
    let linkedPayload = entryDirectory(for: symlinkURL, environment: environment)
      .appendingPathComponent("payload")
    try FileManager.default.removeItem(at: linkedPayload)
    try FileManager.default.createSymbolicLink(
      at: linkedPayload,
      withDestinationURL: outsideURL
    )

    let badMetadataHit = try await cache.cachedDownload(from: metadataURL, kind: .preview)
    let badPayloadHit = try await cache.cachedDownload(from: payloadURL, kind: .preview)
    let symlinkHit = try await cache.cachedDownload(from: symlinkURL, kind: .preview)
    let usage = await cache.usage()
    XCTAssertNil(badMetadataHit)
    XCTAssertNil(badPayloadHit)
    XCTAssertNil(symlinkHit)
    XCTAssertEqual(try Data(contentsOf: outsideURL), Data("outside-must-survive".utf8))
    XCTAssertEqual(usage.entryCount, 0)
  }

  func testExpiredEntryIsRemoved() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let clock = DiskCacheTestClock(Date(timeIntervalSince1970: 10_000))
    let cache = environment.makeCache(
      limits: RemoteImageDiskCacheLimits(
        maximumByteCount: 1_024,
        maximumEntryCount: 10,
        entryLifetime: 60
      ),
      now: { clock.now() }
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/expired"))
    try await store(Data("image".utf8), for: url, in: cache, environment: environment)
    clock.advance(by: 60)

    let hit = try await cache.cachedDownload(from: url, kind: .preview)
    let usage = await cache.usage()
    XCTAssertNil(hit)
    XCTAssertEqual(usage.entryCount, 0)
  }

  func testSubmillisecondDateRoundTripAndClockSkewRemainValid() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let clock = DiskCacheTestClock(Date(timeIntervalSince1970: 15_000.000_75))
    let cache = environment.makeCache(now: { clock.now() })
    let url = try XCTUnwrap(URL(string: "https://img.example/submillisecond"))
    let data = Data("submillisecond-image".utf8)
    try await store(data, for: url, in: cache, environment: environment)

    clock.advance(by: -0.000_25)
    let hit = try await cache.cachedDownload(from: url, kind: .preview)
    let usage = await cache.usage()

    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(hit).fileURL), data)
    XCTAssertEqual(usage.entryCount, 1)
  }

  func testMetadataTimestampBeyondSubmillisecondToleranceIsRejected() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let clock = DiskCacheTestClock(Date(timeIntervalSince1970: 16_000.000_75))
    let cache = environment.makeCache(now: { clock.now() })
    let url = try XCTUnwrap(URL(string: "https://img.example/future-metadata"))
    try await store(
      Data("future-image".utf8),
      for: url,
      in: cache,
      environment: environment
    )

    clock.advance(by: -0.003)
    let hit = try await cache.cachedDownload(from: url, kind: .preview)
    let usage = await cache.usage()

    XCTAssertNil(hit)
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0))
  }

  func testLRUEntryCountTrimUsesPersistedLastAccess() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let clock = DiskCacheTestClock(Date(timeIntervalSince1970: 20_000))
    let limits = RemoteImageDiskCacheLimits(
      maximumByteCount: 1_024,
      maximumEntryCount: 2,
      entryLifetime: 600
    )
    let cache = environment.makeCache(limits: limits, now: { clock.now() })
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/first"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/second"))
    let thirdURL = try XCTUnwrap(URL(string: "https://img.example/third"))

    try await store(Data("one".utf8), for: firstURL, in: cache, environment: environment)
    clock.advance(by: 1)
    try await store(Data("two".utf8), for: secondURL, in: cache, environment: environment)
    clock.advance(by: 1)
    _ = try await cache.cachedDownload(from: firstURL, kind: .preview)
    clock.advance(by: 1)
    try await store(Data("three".utf8), for: thirdURL, in: cache, environment: environment)

    let firstHit = try await cache.cachedDownload(from: firstURL, kind: .preview)
    let secondHit = try await cache.cachedDownload(from: secondURL, kind: .preview)
    let thirdHit = try await cache.cachedDownload(from: thirdURL, kind: .preview)
    let usage = await cache.usage()
    XCTAssertNotNil(firstHit)
    XCTAssertNil(secondHit)
    XCTAssertNotNil(thirdHit)
    XCTAssertEqual(usage.entryCount, 2)

    let recreated = environment.makeCache(limits: limits, now: { clock.now() })
    let recreatedHit = try await recreated.cachedDownload(from: firstURL, kind: .preview)
    XCTAssertNotNil(recreatedHit)
  }

  func testByteCapacityTrimRemovesOldestEntry() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let clock = DiskCacheTestClock(Date(timeIntervalSince1970: 30_000))
    let cache = environment.makeCache(
      limits: RemoteImageDiskCacheLimits(
        maximumByteCount: 8,
        maximumEntryCount: 10,
        entryLifetime: 600
      ),
      now: { clock.now() }
    )
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/four-bytes"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/five-bytes"))
    try await store(Data("1234".utf8), for: firstURL, in: cache, environment: environment)
    clock.advance(by: 1)
    try await store(Data("12345".utf8), for: secondURL, in: cache, environment: environment)

    let firstHit = try await cache.cachedDownload(from: firstURL, kind: .preview)
    let secondHit = try await cache.cachedDownload(from: secondURL, kind: .preview)
    let usage = await cache.usage()
    XCTAssertNil(firstHit)
    XCTAssertNotNil(secondHit)
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 1, byteCount: 5))
  }

  func testClearGenerationRejectsStoreThatWasAlreadyPrepared() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let gate = DiskCachePublicationGate()
    let cache = environment.makeCache(beforeStorePublication: { await gate.wait() })
    let url = try XCTUnwrap(URL(string: "https://img.example/late-store"))
    let lease = try environment.makeLease(data: Data("late".utf8), sourceURL: url)
    let token = await cache.currentGenerationToken()
    let task = Task {
      try await cache.storeValidated(
        lease,
        requestedURL: url,
        kind: .preview,
        generationToken: token
      )
    }
    let storeReachedGate = await gate.waitUntilArrivalCount(1)
    XCTAssertTrue(storeReachedGate)

    _ = await cache.clear()
    await gate.releaseAll()

    do {
      try await task.value
      XCTFail("Expected the pre-clear store to be rejected")
    } catch RemoteImageDiskCacheError.staleGeneration {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let hit = try await cache.cachedDownload(from: url, kind: .preview)
    XCTAssertNil(hit)
  }

  func testCancellationDoesNotPublishPreparedStagingEntry() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let gate = DiskCachePublicationGate()
    let cache = environment.makeCache(beforeStorePublication: { await gate.wait() })
    let url = try XCTUnwrap(URL(string: "https://img.example/cancelled-store"))
    let lease = try environment.makeLease(data: Data("cancel".utf8), sourceURL: url)
    let token = await cache.currentGenerationToken()
    let task = Task {
      try await cache.storeValidated(
        lease,
        requestedURL: url,
        kind: .preview,
        generationToken: token
      )
    }
    let storeReachedGate = await gate.waitUntilArrivalCount(1)
    XCTAssertTrue(storeReachedGate)

    task.cancel()
    await gate.releaseAll()

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let hit = try await cache.cachedDownload(from: url, kind: .preview)
    XCTAssertNil(hit)
  }

  func testOlderRequestCannotOverwriteNewerPublishedResponse() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let gate = DiskCacheIndexedPublicationGate()
    let cache = environment.makeCache(beforeStorePublication: { await gate.wait() })
    let url = try XCTUnwrap(URL(string: "https://img.example/raced"))
    let oldLease = try environment.makeLease(data: Data("old".utf8), sourceURL: url)
    let newLease = try environment.makeLease(data: Data("new".utf8), sourceURL: url)
    let oldToken = await cache.currentGenerationToken()
    let newToken = await cache.currentGenerationToken()

    let oldTask = Task {
      try await cache.storeValidated(
        oldLease,
        requestedURL: url,
        kind: .preview,
        generationToken: oldToken
      )
    }
    let oldStoreReachedGate = await gate.waitUntilArrivalCount(1)
    XCTAssertTrue(oldStoreReachedGate)
    let newTask = Task {
      try await cache.storeValidated(
        newLease,
        requestedURL: url,
        kind: .preview,
        generationToken: newToken
      )
    }
    let newStoreReachedGate = await gate.waitUntilArrivalCount(2)
    XCTAssertTrue(newStoreReachedGate)

    await gate.release(index: 1)
    try await newTask.value
    await gate.release(index: 0)
    do {
      try await oldTask.value
      XCTFail("Expected the older write to be superseded")
    } catch RemoteImageDiskCacheError.staleGeneration {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let optionalHit = try await cache.cachedDownload(from: url, kind: .preview)
    let hit = try XCTUnwrap(optionalHit)
    XCTAssertEqual(try Data(contentsOf: hit.fileURL), Data("new".utf8))
  }

  func testDifferentURLsCanPublishInReverseRequestOrder() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let gate = DiskCacheIndexedPublicationGate()
    let cache = environment.makeCache(beforeStorePublication: { await gate.wait() })
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/reverse-first"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/reverse-second"))
    let firstLease = try environment.makeLease(data: Data("first".utf8), sourceURL: firstURL)
    let secondLease = try environment.makeLease(data: Data("second".utf8), sourceURL: secondURL)
    let firstToken = await cache.currentGenerationToken()
    let secondToken = await cache.currentGenerationToken()

    let firstTask = Task {
      try await cache.storeValidated(
        firstLease,
        requestedURL: firstURL,
        kind: .preview,
        generationToken: firstToken
      )
    }
    let firstReachedGate = await gate.waitUntilArrivalCount(1)
    XCTAssertTrue(firstReachedGate)
    let secondTask = Task {
      try await cache.storeValidated(
        secondLease,
        requestedURL: secondURL,
        kind: .preview,
        generationToken: secondToken
      )
    }
    let secondReachedGate = await gate.waitUntilArrivalCount(2)
    XCTAssertTrue(secondReachedGate)

    await gate.release(index: 1)
    try await secondTask.value
    await gate.release(index: 0)
    try await firstTask.value

    let firstHit = try await cache.cachedDownload(from: firstURL, kind: .preview)
    let secondHit = try await cache.cachedDownload(from: secondURL, kind: .preview)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(firstHit).fileURL), Data("first".utf8))
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(secondHit).fileURL), Data("second".utf8))
  }

  func testRequestSequenceWindowAcceptsBoundaryAndRejectsOlderToken() async throws {
    let acceptedEnvironment = try DiskCacheTestEnvironment()
    defer { acceptedEnvironment.remove() }
    let acceptedCache = acceptedEnvironment.makeCache()
    let acceptedURL = try XCTUnwrap(URL(string: "https://img.example/window-boundary"))
    let acceptedLease = try acceptedEnvironment.makeLease(
      data: Data("accepted".utf8),
      sourceURL: acceptedURL
    )
    let boundaryToken = await acceptedCache.currentGenerationToken()
    for _ in 0..<2_047 {
      _ = await acceptedCache.currentGenerationToken()
    }
    try await acceptedCache.storeValidated(
      acceptedLease,
      requestedURL: acceptedURL,
      kind: .preview,
      generationToken: boundaryToken
    )
    let boundaryHit = try await acceptedCache.cachedDownload(
      from: acceptedURL,
      kind: .preview
    )
    XCTAssertNotNil(boundaryHit)

    let rejectedEnvironment = try DiskCacheTestEnvironment()
    defer { rejectedEnvironment.remove() }
    let rejectedCache = rejectedEnvironment.makeCache()
    let rejectedURL = try XCTUnwrap(URL(string: "https://img.example/window-expired"))
    let rejectedLease = try rejectedEnvironment.makeLease(
      data: Data("rejected".utf8),
      sourceURL: rejectedURL
    )
    let expiredToken = await rejectedCache.currentGenerationToken()
    for _ in 0..<2_048 {
      _ = await rejectedCache.currentGenerationToken()
    }

    do {
      try await rejectedCache.storeValidated(
        rejectedLease,
        requestedURL: rejectedURL,
        kind: .preview,
        generationToken: expiredToken
      )
      XCTFail("Expected a token outside the bounded sequence window to be rejected")
    } catch RemoteImageDiskCacheError.staleGeneration {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let rejectedHit = try await rejectedCache.cachedDownload(
      from: rejectedURL,
      kind: .preview
    )
    XCTAssertNil(rejectedHit)
  }

  func testPublishedGenerationTokenCannotBeReusedForAnotherEntry() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/token-first"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/token-second"))
    let firstLease = try environment.makeLease(data: Data("first".utf8), sourceURL: firstURL)
    let secondLease = try environment.makeLease(data: Data("second".utf8), sourceURL: secondURL)
    let token = await cache.currentGenerationToken()
    try await cache.storeValidated(
      firstLease,
      requestedURL: firstURL,
      kind: .preview,
      generationToken: token
    )

    do {
      try await cache.storeValidated(
        secondLease,
        requestedURL: secondURL,
        kind: .preview,
        generationToken: token
      )
      XCTFail("Expected a consumed token to be rejected")
    } catch RemoteImageDiskCacheError.staleGeneration {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let firstHit = try await cache.cachedDownload(from: firstURL, kind: .preview)
    let secondHit = try await cache.cachedDownload(from: secondURL, kind: .preview)
    XCTAssertNotNil(firstHit)
    XCTAssertNil(secondHit)
  }

  func testValidatedStoreReplacesExistingEntry() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let url = try XCTUnwrap(URL(string: "https://img.example/replaced"))
    try await store(Data("old".utf8), for: url, in: cache, environment: environment)
    try await store(Data("new-value".utf8), for: url, in: cache, environment: environment)

    let optionalHit = try await cache.cachedDownload(from: url, kind: .preview)
    let hit = try XCTUnwrap(optionalHit)
    XCTAssertEqual(try Data(contentsOf: hit.fileURL), Data("new-value".utf8))
    let usage = await cache.usage()
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 1, byteCount: 9))
  }

  func testHitLeaseSurvivesCacheClearAndCleansOnlyItsTemporaryDirectory() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let url = try XCTUnwrap(URL(string: "https://img.example/leased"))
    let data = Data("leased-data".utf8)
    try await store(data, for: url, in: cache, environment: environment)

    var lease: RemoteImageFileLease? = try await cache.cachedDownload(from: url, kind: .preview)
    let leaseFileURL = try XCTUnwrap(lease).fileURL
    let leaseDirectoryURL = leaseFileURL.deletingLastPathComponent()
    XCTAssertNotEqual(leaseFileURL.deletingLastPathComponent(), entryDirectory(for: url, environment: environment))

    let cachedPayloadURL = entryDirectory(for: url, environment: environment)
      .appendingPathComponent("payload")
    try Data("XXXXXXXXXXX".utf8).write(to: cachedPayloadURL)
    XCTAssertEqual(try Data(contentsOf: leaseFileURL), data)

    _ = await cache.clear()

    XCTAssertEqual(try Data(contentsOf: leaseFileURL), data)
    XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectoryURL.path))
    lease = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectoryURL.path))
  }

  func testUsageAndClearReportEntryAndPayloadTotals() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let firstURL = try XCTUnwrap(URL(string: "https://img.example/usage-one"))
    let secondURL = try XCTUnwrap(URL(string: "https://img.example/usage-two"))
    try await store(Data("123".utf8), for: firstURL, in: cache, environment: environment)
    try await store(Data("12345".utf8), for: secondURL, in: cache, environment: environment)

    let usage = await cache.usage()
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 2, byteCount: 8))
    let clearResult = await cache.clear()
    XCTAssertEqual(
      clearResult,
      RemoteImageDiskCacheClearResult(
        removedEntryCount: 2,
        removedByteCount: 8,
        removedAllEntries: true
      )
    )
    let clearedUsage = await cache.usage()
    XCTAssertEqual(clearedUsage, RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0))
  }

  func testURLAndResponseMetadataNeverLeakIntoCacheNamesOrMetadata() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let requestedURL = try XCTUnwrap(
      URL(string: "https://private.example/account/avatar?token=request-secret")
    )
    let sourceURL = try XCTUnwrap(
      URL(string: "https://cdn.example/final?signature=source-secret")
    )
    let lease = try environment.makeLease(
      data: Data("pixels".utf8),
      sourceURL: sourceURL,
      mimeType: "image/secret",
      suggestedFilename: "filename-secret.jpg"
    )
    let token = await cache.currentGenerationToken()
    try await cache.storeValidated(
      lease,
      requestedURL: requestedURL,
      kind: .preview,
      generationToken: token
    )

    let entries = try FileManager.default.contentsOfDirectory(
      at: environment.cacheDirectoryURL,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(entries.map(\.lastPathComponent), [RemoteImageDiskCache.cacheKey(for: requestedURL)])
    let entry = try XCTUnwrap(entries.first)
    let childNames = try FileManager.default.contentsOfDirectory(atPath: entry.path).sorted()
    XCTAssertEqual(childNames, ["metadata.json", "payload"])
    let metadataText = try String(
      contentsOf: entry.appendingPathComponent("metadata.json"),
      encoding: .utf8
    )
    for secret in [
      "private.example", "request-secret", "cdn.example", "source-secret",
      "image/secret", "filename-secret",
    ] {
      XCTAssertFalse(metadataText.contains(secret), secret)
      XCTAssertFalse(entries.map(\.path).joined().contains(secret), secret)
    }
  }

  func testInvalidURLsAndMismatchedOrEmptyFilesAreRejected() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let validURL = try XCTUnwrap(URL(string: "https://img.example/valid"))
    let invalidRequestedURL = try XCTUnwrap(URL(string: "http://img.example/insecure"))
    let fragmentedURL = try XCTUnwrap(URL(string: "https://img.example/image#fragment"))
    let oversizedURL = try XCTUnwrap(
      URL(string: "https://img.example/\(String(repeating: "a", count: 8_193))")
    )
    let invalidSourceURL = try XCTUnwrap(URL(string: "https://user:password@img.example/image"))
    let validLease = try environment.makeLease(data: Data("valid".utf8), sourceURL: validURL)
    let sourceRejectedLease = try environment.makeLease(
      data: Data("source".utf8),
      sourceURL: invalidSourceURL
    )

    await assertStoreError(.invalidURL) {
      let token = await cache.currentGenerationToken()
      try await cache.storeValidated(
        validLease,
        requestedURL: invalidRequestedURL,
        kind: .preview,
        generationToken: token
      )
    }
    await assertStoreError(.invalidURL) {
      let token = await cache.currentGenerationToken()
      try await cache.storeValidated(
        sourceRejectedLease,
        requestedURL: validURL,
        kind: .preview,
        generationToken: token
      )
    }
    for rejectedURL in [fragmentedURL, oversizedURL] {
      await assertStoreError(.invalidURL) {
        let token = await cache.currentGenerationToken()
        try await cache.storeValidated(
          validLease,
          requestedURL: rejectedURL,
          kind: .preview,
          generationToken: token
        )
      }
      let hit = try await cache.cachedDownload(from: rejectedURL, kind: .preview)
      XCTAssertNil(hit)
    }

    let emptyLease = try environment.makeLease(data: Data(), sourceURL: validURL)
    await assertStoreError(.invalidFile) {
      let token = await cache.currentGenerationToken()
      try await cache.storeValidated(
        emptyLease,
        requestedURL: validURL,
        kind: .preview,
        generationToken: token
      )
    }
    let mismatchedLease = try environment.makeLease(
      data: Data("1234".utf8),
      sourceURL: validURL,
      declaredByteCount: 3
    )
    await assertStoreError(.invalidFile) {
      let token = await cache.currentGenerationToken()
      try await cache.storeValidated(
        mismatchedLease,
        requestedURL: validURL,
        kind: .preview,
        generationToken: token
      )
    }

    let invalidHit = try await cache.cachedDownload(from: invalidRequestedURL, kind: .preview)
    XCTAssertNil(invalidHit)
  }

  func testWrapperDoesNotPersistUnvalidatedNetworkResponse() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let network = DiskCacheNetworkSpy(
      data: Data("<html>not an image</html>".utf8),
      directoryURL: environment.networkDirectoryURL
    )
    let downloader = PersistentRemoteImageDownloader(
      cache: cache,
      networkDownloader: network
    )
    let url = try XCTUnwrap(URL(string: "https://img.example/unvalidated"))

    _ = try await downloader.download(
      from: url,
      kind: .preview,
      networkAccess: .unrestricted
    )

    let networkCallCount = await network.callCount()
    let usage = await cache.usage()
    XCTAssertEqual(networkCallCount, 1)
    XCTAssertEqual(usage, RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0))
  }

  func testCacheHitProgressReportsExactlyOneCompletion() async throws {
    let environment = try DiskCacheTestEnvironment()
    defer { environment.remove() }
    let cache = environment.makeCache()
    let url = try XCTUnwrap(URL(string: "https://img.example/progress"))
    let data = Data("progress".utf8)
    try await store(data, for: url, in: cache, environment: environment)
    let network = DiskCacheNetworkSpy(
      data: Data("network".utf8),
      directoryURL: environment.networkDirectoryURL
    )
    let downloader = PersistentRemoteImageDownloader(
      cache: cache,
      networkDownloader: network
    )
    let recorder = DiskCacheProgressRecorder()

    _ = try await downloader.download(
      from: url,
      kind: .preview,
      networkAccess: .unrestricted,
      onProgress: { recorder.record($0) }
    )

    XCTAssertEqual(
      recorder.values(),
      [
        RemoteImageDownloadProgress(
          receivedByteCount: Int64(data.count),
          expectedByteCount: Int64(data.count)
        )
      ]
    )
    let networkCallCount = await network.callCount()
    XCTAssertEqual(networkCallCount, 0)
  }
}

private func store(
  _ data: Data,
  for requestedURL: URL,
  in cache: RemoteImageDiskCache,
  environment: DiskCacheTestEnvironment,
  kind: RemoteImageDownloadKind = .preview
) async throws {
  let lease = try environment.makeLease(data: data, sourceURL: requestedURL)
  let token = await cache.currentGenerationToken()
  try await cache.storeValidated(
    lease,
    requestedURL: requestedURL,
    kind: kind,
    generationToken: token
  )
}

private func entryDirectory(
  for url: URL,
  environment: DiskCacheTestEnvironment
) -> URL {
  environment.cacheDirectoryURL.appendingPathComponent(
    RemoteImageDiskCache.cacheKey(for: url),
    isDirectory: true
  )
}

private func assertStoreError(
  _ expected: RemoteImageDiskCacheError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)")
  } catch let error as RemoteImageDiskCacheError {
    XCTAssertEqual(error, expected)
  } catch {
    XCTFail("Unexpected error: \(error)")
  }
}

private final class DiskCacheTestEnvironment: @unchecked Sendable {
  let rootURL: URL
  let cacheDirectoryURL: URL
  let leaseDirectoryURL: URL
  let sourceDirectoryURL: URL
  let networkDirectoryURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteImageDiskCacheTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    cacheDirectoryURL = rootURL.appendingPathComponent("cache", isDirectory: true)
    leaseDirectoryURL = rootURL.appendingPathComponent("leases", isDirectory: true)
    sourceDirectoryURL = rootURL.appendingPathComponent("sources", isDirectory: true)
    networkDirectoryURL = rootURL.appendingPathComponent("network", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: networkDirectoryURL, withIntermediateDirectories: true)
  }

  func makeCache(
    limits: RemoteImageDiskCacheLimits = .standard,
    now: @escaping @Sendable () -> Date = { Date() },
    beforeStorePublication: (@Sendable () async -> Void)? = nil
  ) -> RemoteImageDiskCache {
    RemoteImageDiskCache(
      directoryURL: cacheDirectoryURL,
      leaseDirectoryURL: leaseDirectoryURL,
      limits: limits,
      now: now,
      beforeStorePublication: beforeStorePublication
    )
  }

  func makeLease(
    data: Data,
    sourceURL: URL,
    mimeType: String? = "image/jpeg",
    suggestedFilename: String? = "image.jpg",
    declaredByteCount: Int64? = nil
  ) throws -> RemoteImageFileLease {
    let directoryURL = sourceDirectoryURL.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let fileURL = directoryURL.appendingPathComponent("source", isDirectory: false)
    try data.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directoryURL,
      sourceURL: sourceURL,
      mimeType: mimeType,
      suggestedFilename: suggestedFilename,
      byteCount: declaredByteCount ?? Int64(data.count)
    )
  }

  func makeSparseLease(byteCount: Int64, sourceURL: URL) throws -> RemoteImageFileLease {
    let directoryURL = sourceDirectoryURL.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let fileURL = directoryURL.appendingPathComponent("source", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.truncate(atOffset: UInt64(byteCount))
    try handle.close()
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directoryURL,
      sourceURL: sourceURL,
      mimeType: "image/jpeg",
      suggestedFilename: "large.jpg",
      byteCount: byteCount
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private final class DiskCacheTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      value = value.addingTimeInterval(interval)
    }
  }
}

private actor DiskCachePublicationGate {
  private var arrivals = 0
  private var isOpen = false
  private var continuations = [CheckedContinuation<Void, Never>]()

  func wait() async {
    arrivals += 1
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitUntilArrivalCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while arrivals < expected, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return arrivals >= expected
  }

  func releaseAll() {
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}

private actor DiskCacheIndexedPublicationGate {
  private var continuations = [CheckedContinuation<Void, Never>?]()
  private var releasedIndices = Set<Int>()

  func wait() async {
    let index = continuations.count
    continuations.append(nil)
    guard !releasedIndices.contains(index) else { return }
    await withCheckedContinuation { continuation in
      continuations[index] = continuation
    }
  }

  func waitUntilArrivalCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while continuations.count < expected, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return continuations.count >= expected
  }

  func release(index: Int) {
    releasedIndices.insert(index)
    guard continuations.indices.contains(index), let continuation = continuations[index] else {
      return
    }
    continuations[index] = nil
    continuation.resume()
  }
}

private actor DiskCacheNetworkSpy: RemoteImageDownloading {
  private let data: Data
  private let directoryURL: URL
  private var calls = 0

  init(data: Data, directoryURL: URL) {
    self.data = data
    self.directoryURL = directoryURL
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    calls += 1
    let leaseDirectoryURL = directoryURL.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: leaseDirectoryURL,
      withIntermediateDirectories: false
    )
    let fileURL = leaseDirectoryURL.appendingPathComponent("download")
    try data.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: leaseDirectoryURL,
      sourceURL: url,
      mimeType: "text/html",
      suggestedFilename: "response.html",
      byteCount: Int64(data.count)
    )
  }

  func callCount() -> Int {
    calls
  }
}

private final class DiskCacheProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues = [RemoteImageDownloadProgress]()

  func record(_ progress: RemoteImageDownloadProgress) {
    lock.withLock {
      recordedValues.append(progress)
    }
  }

  func values() -> [RemoteImageDownloadProgress] {
    lock.withLock { recordedValues }
  }
}
