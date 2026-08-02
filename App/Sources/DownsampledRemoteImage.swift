import Foundation
import ImageIO
import SwiftUI
import UIKit

enum DownsampledRemoteImagePhase {
  case empty
  case success(Image)
  case failure
}

struct DownsampledRemoteImage<Content: View>: View {
  let url: URL?
  let maxPixelSize: Int
  @ViewBuilder let content: (DownsampledRemoteImagePhase) -> Content

  @State private var phase: DownsampledRemoteImagePhase = .empty

  private var requestID: String {
    "\(maxPixelSize)|\(url?.absoluteString ?? "")"
  }

  var body: some View {
    content(phase)
      .task(id: requestID) {
        phase = .empty
        guard let url else {
          phase = .failure
          return
        }
        do {
          let asset = try await DownsampledImageRepository.shared.image(
            at: url,
            maxPixelSize: maxPixelSize
          )
          try Task.checkCancellation()
          phase = .success(Image(uiImage: asset.image))
        } catch is CancellationError {
          return
        } catch {
          phase = .failure
        }
      }
  }
}

struct DownsampledImageAsset: @unchecked Sendable {
  let image: UIImage
}

enum DownsampledImageError: Error {
  case invalidResponse
  case responseTooLarge
  case unreadableImage
}

actor DownsampledImageRepository {
  private struct InFlightRequest {
    let task: Task<DownsampledImageAsset, Error>
    var waiters: Set<UUID>
  }

  static let shared = DownsampledImageRepository()

  private let session: URLSession
  private let cache = NSCache<NSString, UIImage>()
  private var inFlight: [String: InFlightRequest] = [:]

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    session = URLSession(configuration: configuration)
    cache.totalCostLimit = 96 * 1_024 * 1_024
    cache.countLimit = 80
  }

  func image(at url: URL, maxPixelSize requestedSize: Int) async throws
    -> DownsampledImageAsset
  {
    guard url.scheme?.lowercased() == "https" else {
      throw DownsampledImageError.invalidResponse
    }
    let maxPixelSize = min(max(requestedSize, 64), 4_096)
    let key = "\(maxPixelSize)|\(url.absoluteString)"
    if let cached = cache.object(forKey: key as NSString) {
      return DownsampledImageAsset(image: cached)
    }
    let waiterID = UUID()
    let task: Task<DownsampledImageAsset, Error>
    if var request = inFlight[key] {
      request.waiters.insert(waiterID)
      inFlight[key] = request
      task = request.task
    } else {
      let session = session
      task = Task<DownsampledImageAsset, Error> {
        let maximumResponseBytes = RemoteImageDownloadPolicy.maximumResponseBytes(
          for: maxPixelSize
        )
        let delegate = BoundedHTTPSMediaTaskDelegate(
          maximumResponseBytes: maximumResponseBytes
        )
        let (fileURL, response) = try await session.download(from: url, delegate: delegate)
        guard
          let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode),
          response.url?.scheme?.lowercased() == "https"
        else { throw DownsampledImageError.invalidResponse }

        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(fileSize) <= maximumResponseBytes else {
          throw DownsampledImageError.responseTooLarge
        }
        return try await Task.detached(priority: .utility) {
          try ImageDownsampler.image(at: fileURL, maxPixelSize: maxPixelSize)
        }.value
      }
      inFlight[key] = InFlightRequest(task: task, waiters: [waiterID])
    }

    return try await withTaskCancellationHandler {
      defer { removeWaiter(waiterID, forKey: key) }
      let asset = try await task.value
      try Task.checkCancellation()
      let pixelWidth = asset.image.cgImage?.width ?? 0
      let pixelHeight = asset.image.cgImage?.height ?? 0
      cache.setObject(
        asset.image,
        forKey: key as NSString,
        cost: pixelWidth * pixelHeight * 4
      )
      return asset
    } onCancel: {
      Task { await self.removeWaiter(waiterID, forKey: key) }
    }
  }

  private func removeWaiter(_ waiterID: UUID, forKey key: String) {
    guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
      return
    }
    if request.waiters.isEmpty {
      request.task.cancel()
      inFlight[key] = nil
    } else {
      inFlight[key] = request
    }
  }
}

enum RemoteImageDownloadPolicy {
  static let previewMaximumResponseBytes: Int64 = 16 * 1_024 * 1_024
  static let fullSizeMaximumResponseBytes: Int64 = 80 * 1_024 * 1_024

  static func maximumResponseBytes(for maxPixelSize: Int) -> Int64 {
    maxPixelSize <= 720 ? previewMaximumResponseBytes : fullSizeMaximumResponseBytes
  }

  static func exceedsLimit(
    totalBytesWritten: Int64,
    totalBytesExpected: Int64,
    maximumResponseBytes: Int64
  ) -> Bool {
    totalBytesWritten > maximumResponseBytes
      || (totalBytesExpected > 0 && totalBytesExpected > maximumResponseBytes)
  }
}

enum ImageDownsampler {
  static func image(at fileURL: URL, maxPixelSize: Int) throws -> DownsampledImageAsset {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
      throw DownsampledImageError.unreadableImage
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(maxPixelSize, 64), 4_096),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw DownsampledImageError.unreadableImage
    }
    return DownsampledImageAsset(image: UIImage(cgImage: image))
  }
}

private final class BoundedHTTPSMediaTaskDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let maximumResponseBytes: Int64

  init(maximumResponseBytes: Int64) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if RemoteImageDownloadPolicy.exceedsLimit(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpected: totalBytesExpectedToWrite,
      maximumResponseBytes: maximumResponseBytes
    ) {
      downloadTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}
