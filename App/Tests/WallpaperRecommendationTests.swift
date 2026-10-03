import Foundation
import XCTest

@testable import TiebaPlusPlus

final class WallpaperRecommendationTests: XCTestCase {
  private let imageURL = URL(string: "https://ftp.bmp.ovh/imgs/2021/07/1191f3c3c2c3e364.jpg")!

  func testCatalogRetainsUpstreamOrderingAndFiltersUnsafeDuplicates() throws {
    let second = "https://ftp.bmp.ovh/imgs/2021/07/d7a1c065149c5423.jpg"
    let catalog = try WallpaperRecommendationPolicy.decodeCatalog(
      JSONEncoder().encode([
        imageURL.absoluteString, "http://ftp.bmp.ovh/imgs/1.jpg", imageURL.absoluteString,
        "https://unrelated.example/imgs/1.jpg", "https://user:secret@ftp.bmp.ovh/imgs/1.jpg",
        "https://ftp.bmp.ovh/imgs/../secret.jpg", second,
      ]))
    XCTAssertEqual(catalog.map(\.url.absoluteString), [imageURL.absoluteString, second])
    XCTAssertEqual(catalog.map(\.title), ["壁纸 1", "壁纸 2"])
  }

  func testCatalogRejectsOversizeAndWrongEnvelopes() throws {
    for bytes in [
      Data(repeating: 32, count: WallpaperRecommendationPolicy.maximumCatalogBytes + 1),
      Data("{}".utf8), Data("[]".utf8),
      try JSONEncoder().encode(Array(repeating: imageURL.absoluteString, count: 65)),
    ] {
      XCTAssertThrowsError(try WallpaperRecommendationPolicy.decodeCatalog(bytes))
    }
  }

  func testOriginalCatalogFailureUsesOnlyVerifiedStaticFallback() async throws {
    let downloader = WallpaperCatalogDownloader(
      catalogData: try JSONEncoder().encode([imageURL.absoluteString]), failOriginal: true)
    let service = WallpaperRecommendationService(
      catalogDownloader: downloader, imageDownloader: downloader)
    let items = try await service.fetchCatalog()
    XCTAssertEqual(items.map(\.url), [imageURL])
    let calls = await downloader.requestURLs
    XCTAssertEqual(
      calls,
      [
        WallpaperRecommendationPolicy.catalogURL,
        WallpaperRecommendationPolicy.staticCatalogURL,
      ])
    let image = try await service.fetchImage(items[0])
    XCTAssertEqual(image, Data([1, 2, 3]))
  }

  func testCancellationDoesNotStartFallbackOrImageDownload() async throws {
    let downloader = WallpaperCatalogDownloader(catalogData: Data(), cancellation: true)
    let service = WallpaperRecommendationService(
      catalogDownloader: downloader, imageDownloader: downloader)
    do {
      _ = try await service.fetchCatalog()
      XCTFail("Expected cancellation")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let calls = await downloader.requestURLs
    XCTAssertEqual(calls, [WallpaperRecommendationPolicy.catalogURL])
    do {
      _ = try await service.fetchImage(
        .init(id: imageURL.absoluteString, url: imageURL, title: "壁纸 1"))
      XCTFail("A URL absent from the verified catalog cannot be downloaded")
    } catch { XCTAssertEqual(error as? WallpaperRecommendationError, .invalidImage) }
    let after = await downloader.requestURLs
    XCTAssertEqual(after, calls)
  }

  func testAlreadyCancelledImageSelectionDoesNotDispatch() async throws {
    let downloader = WallpaperCatalogDownloader(
      catalogData: try JSONEncoder().encode([imageURL.absoluteString]))
    let service = WallpaperRecommendationService(
      catalogDownloader: downloader, imageDownloader: downloader)
    let items = try await service.fetchCatalog()
    let item = try XCTUnwrap(items.first)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.fetchImage(item)
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation before dispatch")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let calls = await downloader.requestURLs
    XCTAssertEqual(calls, [WallpaperRecommendationPolicy.catalogURL])
  }

  func testRealTransportDelegateRejectsHTTPDowngradeAndStripsCredentialHeaders() throws {
    let source = WallpaperRecommendationPolicy.catalogURL
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.downloadTask(with: source)
    let response = try XCTUnwrap(
      HTTPURLResponse(url: source, statusCode: 301, httpVersion: nil, headerFields: nil))
    for target in [
      "http://pages.huanchengfly.top/TiebaLite/wallpapers.json",
      "https://other.example/wallpapers.json",
      WallpaperRecommendationPolicy.staticCatalogURL.absoluteString,
    ] {
      let recorder = WallpaperRedirectRecorder()
      let delegate = BoundedHTTPSRemoteImageTaskDelegate(
        maximumResponseBytes: Int64(WallpaperRecommendationPolicy.maximumCatalogBytes),
        networkAccess: .unrestricted,
        redirectURLValidator: WallpaperRecommendationPolicy.allowsCatalogURL,
        onProgress: { _ in })
      var request = URLRequest(url: try XCTUnwrap(URL(string: target)))
      request.setValue("private", forHTTPHeaderField: "Cookie")
      request.setValue("private", forHTTPHeaderField: "Authorization")
      delegate.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) {
        recorder.record($0)
      }
      if target == WallpaperRecommendationPolicy.staticCatalogURL.absoluteString {
        let result = try XCTUnwrap(recorder.request)
        XCTAssertNil(result.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(result.value(forHTTPHeaderField: "Authorization"))
      } else {
        XCTAssertNil(recorder.request)
      }
    }
    task.cancel()
    let config = BoundedHTTPSRemoteImageTransport.hardenedConfiguration(from: .default)
    XCTAssertNil(config.httpCookieStorage)
    XCTAssertNil(config.urlCredentialStorage)
    XCTAssertNil(config.urlCache)
    XCTAssertEqual(config.timeoutIntervalForResource, 60)
  }
}

private actor WallpaperCatalogDownloader: RemoteImageDownloading {
  let catalogData: Data
  let failOriginal: Bool
  let cancellation: Bool
  private(set) var requestURLs: [URL] = []

  init(catalogData: Data, failOriginal: Bool = false, cancellation: Bool = false) {
    self.catalogData = catalogData
    self.failOriginal = failOriginal
    self.cancellation = cancellation
  }

  func download(
    from url: URL, kind: RemoteImageDownloadKind, networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    requestURLs.append(url)
    if cancellation { throw CancellationError() }
    if failOriginal && url == WallpaperRecommendationPolicy.catalogURL {
      throw URLError(.badServerResponse)
    }
    let data = WallpaperRecommendationPolicy.allowsCatalogURL(url) ? catalogData : Data([1, 2, 3])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("response")
    try data.write(to: file)
    return RemoteImageFileLease(
      fileURL: file, cleanupDirectoryURL: directory, sourceURL: url,
      mimeType: nil, suggestedFilename: nil, byteCount: Int64(data.count))
  }
}

private final class WallpaperRedirectRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: URLRequest?
  var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }
  func record(_ request: URLRequest?) {
    lock.lock()
    storedRequest = request
    lock.unlock()
  }
}
