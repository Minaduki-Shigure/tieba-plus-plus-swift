import Foundation
import ImageIO
import SwiftUI
import UIKit

enum DownsampledRemoteImagePhase {
  case empty
  case success(Image, pixelSize: CGSize)
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
          phase = .success(
            Image(uiImage: asset.image),
            pixelSize: CGSize(
              width: asset.image.cgImage?.width ?? 0,
              height: asset.image.cgImage?.height ?? 0
            )
          )
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

  private let downloader: any RemoteImageDownloading
  private let cache = NSCache<NSString, UIImage>()
  private var inFlight: [String: InFlightRequest] = [:]

  init(
    downloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared
  ) {
    self.downloader = downloader
    cache.totalCostLimit = 96 * 1_024 * 1_024
    cache.countLimit = 80
  }

  func image(at url: URL, maxPixelSize requestedSize: Int) async throws
    -> DownsampledImageAsset
  {
    guard RemoteImageURLPolicy.allows(url) else {
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
      let downloader = downloader
      task = Task<DownsampledImageAsset, Error> {
        let lease: RemoteImageFileLease
        do {
          lease = try await downloader.download(
            from: url,
            kind: RemoteImageDownloadPolicy.kind(forMaxPixelSize: maxPixelSize)
          )
        } catch let error as RemoteImageDownloadError {
          switch error {
          case .responseTooLarge:
            throw DownsampledImageError.responseTooLarge
          case .invalidURL, .invalidResponse, .cannotPersistDownload:
            throw DownsampledImageError.invalidResponse
          }
        }
        return try await Task.detached(priority: .utility) {
          try withExtendedLifetime(lease) {
            try ImageDownsampler.image(at: lease.fileURL, maxPixelSize: maxPixelSize)
          }
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
