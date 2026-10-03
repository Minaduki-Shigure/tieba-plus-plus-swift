import Foundation
import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class InlineEmoticonImageLoaderTests: XCTestCase {
  func testRequestHasStableUniqueCatalogURLsAndPolicyIdentity() throws {
    let urls = try catalogURLs(count: 3)
    let first = InlineEmoticonImageRequest(
      urls: [urls[2], urls[0], urls[1], urls[0]], fetchPolicy: .cacheOnly(.preview))
    let second = InlineEmoticonImageRequest(
      urls: [urls[1], urls[2], urls[0]], fetchPolicy: .cacheOnly(.preview))

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.urls, urls.sorted { $0.absoluteString < $1.absoluteString })
    XCTAssertNotEqual(
      first, InlineEmoticonImageRequest(urls: urls, fetchPolicy: .allowNetwork(.preview)))
  }

  func testRepeatedTokensLoadOnceAndUntrustedURLsNeverReachLoader() async throws {
    let urls = try catalogURLs(count: 2)
    let rejected = try [
      "https://example.com/emoticon.png",
      "https://tb3.bdstatic.com/emoji/image_emoticon999@2x.png",
      "https://tb3.bdstatic.com/emoji/image_emoticon@2x.png?tracking=1",
      "https://tb3.bdstatic.com/emoji/image_emoticon@2x.png#fragment",
      "http://tb3.bdstatic.com/emoji/image_emoticon@2x.png",
      "file:///tmp/emoticon.png",
    ].map { try XCTUnwrap(URL(string: $0)) }
    let loader = ControlledInlineEmoticonLoader(asset: DownsampledImageAsset(image: UIImage()))
    let request = InlineEmoticonImageRequest(
      urls: rejected + [urls[0], urls[1], urls[0], urls[1]],
      fetchPolicy: .allowNetwork(.preview))

    let result = await InlineEmoticonImageLoader.load(request, using: loader)
    let snapshot = await loader.snapshot()

    XCTAssertEqual(Set(result.keys), Set(urls))
    XCTAssertEqual(Set(snapshot.requests.map(\.url)), Set(urls))
    XCTAssertEqual(snapshot.requests.count, 2)
  }

  func testEmptyOrEntirelyRejectedRequestDoesNotCallLoader() async throws {
    let loader = ControlledInlineEmoticonLoader(asset: DownsampledImageAsset(image: UIImage()))
    for urls in [[], [try XCTUnwrap(URL(string: "https://example.com/emoji.png"))]] {
      let result = await InlineEmoticonImageLoader.load(
        .init(urls: urls, fetchPolicy: .allowNetwork(.preview)), using: loader)
      XCTAssertTrue(result.isEmpty)
    }
    let snapshot = await loader.snapshot()
    XCTAssertTrue(snapshot.requests.isEmpty)
  }

  func testIndividualFailureKeepsOtherImagesAndContinuesRemainingBatch() async throws {
    let urls = try catalogURLs(count: 7)
    let failedURLs: Set<URL> = [urls[0], urls[3], urls[6]]
    let loader = ControlledInlineEmoticonLoader(
      asset: DownsampledImageAsset(image: UIImage()), failedURLs: failedURLs)

    let result = await InlineEmoticonImageLoader.load(
      .init(urls: urls, fetchPolicy: .allowNetwork(.preview)), using: loader)
    let snapshot = await loader.snapshot()

    XCTAssertEqual(Set(result.keys), Set(urls).subtracting(failedURLs))
    XCTAssertEqual(snapshot.requests.count, urls.count)
  }

  func testFetchPoliciesAreForwardedWithoutNetworkEscalation() async throws {
    let urls = try catalogURLs(count: 2)
    for policy: DownsampledImageFetchPolicy in [
      .cacheOnly(.preview), .allowEconomicalNetwork(.preview), .allowNetwork(.preview),
    ] {
      let loader = ControlledInlineEmoticonLoader(asset: DownsampledImageAsset(image: UIImage()))
      let result = await InlineEmoticonImageLoader.load(
        .init(urls: urls, fetchPolicy: policy), using: loader)
      let snapshot = await loader.snapshot()

      XCTAssertEqual(result.count, urls.count)
      XCTAssertEqual(snapshot.requests.map(\.fetchPolicy), Array(repeating: policy, count: 2))
    }
  }

  func testProductionAdapterDoesNotDownloadAnUncachedCacheOnlyImage() async throws {
    let urls = try catalogURLs(count: 1)
    let transport = InlineEmoticonImageTestTransport(imageData: Data())
    let repository = DownsampledImageRepository(downloader: transport)
    let result = await InlineEmoticonImageLoader.load(
      .init(urls: urls, fetchPolicy: .cacheOnly(.preview)),
      using: DefaultInlineEmoticonImageLoader(repository: repository))
    let requests = await transport.recordedRequests()

    XCTAssertTrue(result.isEmpty)
    XCTAssertTrue(requests.isEmpty)
  }

  func testProductionAdapterBoundsDecodedSizePreservesEconomicalAccessAndReusesCache() async throws
  {
    let url = try XCTUnwrap(catalogURLs(count: 1).first)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256))
    let data = renderer.pngData { context in
      UIColor.systemYellow.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
    }
    let transport = InlineEmoticonImageTestTransport(imageData: data)
    let repository = DownsampledImageRepository(downloader: transport)
    let loader = DefaultInlineEmoticonImageLoader(repository: repository)

    for policy: DownsampledImageFetchPolicy in [
      .allowEconomicalNetwork(.preview), .cacheOnly(.preview),
    ] {
      let result = await InlineEmoticonImageLoader.load(
        .init(urls: [url], fetchPolicy: policy), using: loader)
      let asset = try XCTUnwrap(result[url])
      XCTAssertGreaterThan(asset.pixelSize.width, 0)
      XCTAssertGreaterThan(asset.pixelSize.height, 0)
      XCTAssertLessThanOrEqual(asset.pixelSize.width, 120)
      XCTAssertLessThanOrEqual(asset.pixelSize.height, 120)
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests, [.init(url: url, kind: .preview, networkAccess: .economicalOnly)])
  }

  func testProductionAdapterEnforcesCatalogPolicyEvenWhenCalledDirectly() async throws {
    let transport = InlineEmoticonImageTestTransport(imageData: Data())
    let loader = DefaultInlineEmoticonImageLoader(
      repository: DownsampledImageRepository(downloader: transport))
    let url = try XCTUnwrap(URL(string: "https://tb3.bdstatic.com/emoji/unknown.png"))

    do {
      _ = try await loader.image(at: url, fetchPolicy: .allowNetwork(.preview))
      XCTFail("The repository adapter must reject URLs outside the compiled catalog")
    } catch DownsampledImageError.invalidResponse {
      // Production enforces the catalog again at the repository boundary.
    }
    let requests = await transport.recordedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testSynchronousSnapshotContainsOnlyWarmCatalogImagesAndRetainsImageIdentity() async throws {
    let urls = try catalogURLs(count: 2)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
    let data = renderer.pngData { context in
      UIColor.systemYellow.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
    }
    let transport = InlineEmoticonImageTestTransport(imageData: data)
    let repository = DownsampledImageRepository(downloader: transport)
    let loader = DefaultInlineEmoticonImageLoader(repository: repository)
    let cached = try await loader.image(at: urls[0], fetchPolicy: .allowNetwork(.preview))

    for policy: DownsampledImageFetchPolicy in [
      .cacheOnly(.preview), .allowEconomicalNetwork(.preview), .allowNetwork(.preview),
    ] {
      let request = InlineEmoticonImageRequest(urls: urls, fetchPolicy: policy)
      let snapshot = loader.cachedImages(for: request)
      XCTAssertEqual(Set(snapshot.keys), [urls[0]])
      XCTAssertTrue(try XCTUnwrap(snapshot[urls[0]]).image === cached.image)
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1, "Taking a snapshot must never fetch the cold second image")

    await repository.clearMemoryCache()
    XCTAssertTrue(
      loader.cachedImages(for: .init(urls: urls, fetchPolicy: .allowNetwork(.preview))).isEmpty)
    let requestsAfterClear = await transport.recordedRequests()
    XCTAssertEqual(requestsAfterClear.count, 1)
  }

  func testAtMostFourImagesRunConcurrentlyAndCompletionRefillsOneSlot() async throws {
    let urls = try catalogURLs(count: 9)
    let firstWave = expectation(description: "Four distinct image loads reached the gate")
    let replacement = expectation(description: "One completed load admits the fifth image")
    let loader = ControlledInlineEmoticonLoader(
      asset: DownsampledImageAsset(image: UIImage()), isBlocked: true,
      onRequest: { count in
        if count == 4 { firstWave.fulfill() }
        if count == 5 { replacement.fulfill() }
      })
    let task = Task {
      await InlineEmoticonImageLoader.load(
        .init(urls: urls, fetchPolicy: .allowNetwork(.preview)), using: loader)
    }
    await fulfillment(of: [firstWave], timeout: 3)
    let firstSnapshot = await loader.snapshot()
    XCTAssertEqual(firstSnapshot.requests.count, 4)
    XCTAssertEqual(firstSnapshot.activeCount, 4)

    await loader.release(url: urls[0])
    await fulfillment(of: [replacement], timeout: 3)
    let refilledSnapshot = await loader.snapshot()
    XCTAssertEqual(refilledSnapshot.requests.count, 5)
    XCTAssertEqual(refilledSnapshot.activeCount, 4)

    await loader.releaseAll()
    let result = await task.value
    let finalSnapshot = await loader.snapshot()
    XCTAssertEqual(Set(result.keys), Set(urls))
    XCTAssertEqual(finalSnapshot.requests.count, urls.count)
    XCTAssertEqual(finalSnapshot.maximumActiveCount, 4)
    XCTAssertEqual(finalSnapshot.activeCount, 0)
  }

  func testCancellationDropsCompletedAndLateImagesWithoutStartingRemainingURLs() async throws {
    let urls = try catalogURLs(count: 9)
    let fifthImage = expectation(description: "One successful image and four blocked images")
    let loader = ControlledInlineEmoticonLoader(
      asset: DownsampledImageAsset(image: UIImage()), isBlocked: true,
      releasedURLs: [urls[0]],
      onRequest: { count in if count == 5 { fifthImage.fulfill() } })
    let task = Task {
      await InlineEmoticonImageLoader.load(
        .init(urls: urls, fetchPolicy: .allowNetwork(.preview)), using: loader)
    }
    await fulfillment(of: [fifthImage], timeout: 3)
    task.cancel()
    // The mock deliberately ignores cancellation and returns successful images
    // after release, exercising the batch's own stale-result protection.
    await loader.releaseAll()
    let result = await task.value
    let snapshot = await loader.snapshot()

    XCTAssertTrue(result.isEmpty)
    XCTAssertEqual(snapshot.requests.count, 5)
    XCTAssertEqual(snapshot.activeCount, 0)
  }

  func testAlreadyCancelledTaskDoesNotStartAnyImage() async throws {
    let urls = try catalogURLs(count: 2)
    let gate = InlineEmoticonTestGate()
    let loader = ControlledInlineEmoticonLoader(asset: DownsampledImageAsset(image: UIImage()))
    let task = Task {
      await gate.wait()
      return await InlineEmoticonImageLoader.load(
        .init(urls: urls, fetchPolicy: .allowNetwork(.preview)), using: loader)
    }
    task.cancel()
    await gate.open()
    let result = await task.value
    let snapshot = await loader.snapshot()

    XCTAssertTrue(result.isEmpty)
    XCTAssertTrue(snapshot.requests.isEmpty)
  }

  private func catalogURLs(count: Int) throws -> [URL] {
    let urls = Array(
      Set(TiebaClassicEmoticonCatalog.entries.compactMap(\.thumbnailURL))
        .sorted { $0.absoluteString < $1.absoluteString }.prefix(count))
    XCTAssertEqual(urls.count, count)
    return urls
  }
}

private actor ControlledInlineEmoticonLoader: InlineEmoticonImageLoading {
  struct Request: Sendable {
    let url: URL
    let fetchPolicy: DownsampledImageFetchPolicy
  }

  struct Snapshot: Sendable {
    let requests: [Request]
    let activeCount: Int
    let maximumActiveCount: Int
  }

  private let asset: DownsampledImageAsset
  private let failedURLs: Set<URL>
  private let onRequest: @Sendable (Int) -> Void
  private var isBlocked: Bool
  private var releasedURLs: Set<URL>
  private var requests: [Request] = []
  private var activeCount = 0
  private var maximumActiveCount = 0
  private var releaseWaiters: [URL: CheckedContinuation<Void, Never>] = [:]

  init(
    asset: DownsampledImageAsset,
    failedURLs: Set<URL> = [],
    isBlocked: Bool = false,
    releasedURLs: Set<URL> = [],
    onRequest: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.asset = asset
    self.failedURLs = failedURLs
    self.isBlocked = isBlocked
    self.releasedURLs = releasedURLs
    self.onRequest = onRequest
  }

  func image(
    at url: URL,
    fetchPolicy: DownsampledImageFetchPolicy
  ) async throws -> DownsampledImageAsset {
    requests.append(Request(url: url, fetchPolicy: fetchPolicy))
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    defer { activeCount -= 1 }
    onRequest(requests.count)
    if isBlocked, !releasedURLs.contains(url) {
      await withCheckedContinuation { releaseWaiters[url] = $0 }
    }
    if failedURLs.contains(url) { throw DownsampledImageError.unreadableImage }
    return asset
  }

  func snapshot() -> Snapshot {
    Snapshot(
      requests: requests, activeCount: activeCount, maximumActiveCount: maximumActiveCount)
  }

  func release(url: URL) {
    releasedURLs.insert(url)
    releaseWaiters.removeValue(forKey: url)?.resume()
  }

  func releaseAll() {
    isBlocked = false
    let continuations = Array(releaseWaiters.values)
    releaseWaiters.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

private actor InlineEmoticonTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

actor InlineEmoticonImageTestTransport: RemoteImageDownloading {
  struct Request: Equatable, Sendable {
    let url: URL
    let kind: RemoteImageDownloadKind
    let networkAccess: RemoteImageNetworkAccess
  }

  private let imageData: Data
  private var requests: [Request] = []

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    requests.append(Request(url: url, kind: kind, networkAccess: networkAccess))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("InlineEmoticonImageLoaderTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("thumbnail.png")
    try imageData.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      mimeType: "image/png",
      suggestedFilename: "thumbnail.png",
      byteCount: Int64(imageData.count)
    )
  }

  func recordedRequests() -> [Request] { requests }
}
