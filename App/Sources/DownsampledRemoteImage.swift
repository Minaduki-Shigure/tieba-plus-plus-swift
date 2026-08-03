import Foundation
import ImageIO
import SwiftUI
import UIKit

enum DownsampledRemoteImagePhase {
  case empty
  case success(Image, pixelSize: CGSize)
  case failure
}

enum DownsampledRemoteImageAttemptOutcome: Equatable, Sendable {
  case success
  case failure
  case cancelled
}

enum DownsampledImageFetchPolicy: Hashable, Sendable {
  case cacheOnly
  case allowNetwork(RemoteImageDownloadKind)
}

struct DownsampledRemoteImageResourceID: Hashable, Sendable {
  let url: URL?
  let maxPixelSize: Int
}

enum DownsampledRemoteImageStateDecision {
  static func canRenderStoredPhase(
    storedResourceID: DownsampledRemoteImageResourceID?,
    currentResourceID: DownsampledRemoteImageResourceID
  ) -> Bool {
    storedResourceID == currentResourceID
  }
}

struct DownsampledRemoteImage<Content: View>: View {
  let url: URL?
  let maxPixelSize: Int
  let fetchPolicy: DownsampledImageFetchPolicy
  let reloadID: Int
  let onAttemptCompletion: @MainActor (DownsampledRemoteImageAttemptOutcome) -> Void
  @ViewBuilder let content: (DownsampledRemoteImagePhase) -> Content

  @State private var phase: DownsampledRemoteImagePhase = .empty
  @State private var phaseResourceID: DownsampledRemoteImageResourceID?

  private struct RequestID: Hashable {
    let url: URL?
    let maxPixelSize: Int
    let fetchPolicy: DownsampledImageFetchPolicy
    let reloadID: Int
  }

  init(
    url: URL?,
    maxPixelSize: Int,
    @ViewBuilder content: @escaping (DownsampledRemoteImagePhase) -> Content
  ) {
    self.init(
      url: url,
      maxPixelSize: maxPixelSize,
      fetchPolicy: .allowNetwork(
        RemoteImageDownloadPolicy.kind(forMaxPixelSize: maxPixelSize)
      ),
      onAttemptCompletion: { _ in },
      content: content
    )
  }

  init(
    url: URL?,
    maxPixelSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    reloadID: Int = 0,
    onAttemptCompletion: @escaping @MainActor (
      DownsampledRemoteImageAttemptOutcome
    ) -> Void = { _ in },
    @ViewBuilder content: @escaping (DownsampledRemoteImagePhase) -> Content
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.fetchPolicy = fetchPolicy
    self.reloadID = reloadID
    self.onAttemptCompletion = onAttemptCompletion
    self.content = content
  }

  private var requestID: RequestID {
    RequestID(
      url: url,
      maxPixelSize: maxPixelSize,
      fetchPolicy: fetchPolicy,
      reloadID: reloadID
    )
  }

  private var resourceID: DownsampledRemoteImageResourceID {
    DownsampledRemoteImageResourceID(url: url, maxPixelSize: maxPixelSize)
  }

  private var hasSuccessfulPhase: Bool {
    if case .success = phase { return true }
    return false
  }

  var body: some View {
    content(
      DownsampledRemoteImageStateDecision.canRenderStoredPhase(
        storedResourceID: phaseResourceID,
        currentResourceID: resourceID
      ) ? phase : .empty
    )
      .task(id: requestID) {
        let activeResourceID = resourceID
        if phaseResourceID != activeResourceID || !hasSuccessfulPhase {
          phase = .empty
        }
        phaseResourceID = activeResourceID
        guard let url else {
          phase = .failure
          onAttemptCompletion(.failure)
          return
        }
        do {
          let asset = try await DownsampledImageRepository.shared.image(
            at: url,
            maxPixelSize: maxPixelSize,
            fetchPolicy: fetchPolicy
          )
          try Task.checkCancellation()
          phaseResourceID = activeResourceID
          phase = .success(
            Image(uiImage: asset.image),
            pixelSize: CGSize(
              width: asset.image.cgImage?.width ?? 0,
              height: asset.image.cgImage?.height ?? 0
            )
          )
          onAttemptCompletion(.success)
        } catch is CancellationError {
          onAttemptCompletion(.cancelled)
          return
        } catch {
          if Task.isCancelled {
            onAttemptCompletion(.cancelled)
            return
          }
          phaseResourceID = activeResourceID
          phase = .failure
          onAttemptCompletion(.failure)
        }
      }
  }
}

struct DownsampledImageAsset: @unchecked Sendable {
  let image: UIImage
}

enum DownsampledImageError: Error {
  case cacheMiss
  case invalidResponse
  case responseTooLarge
  case unreadableImage
}

actor DownsampledImageRepository {
  private struct CacheKey: Hashable, Sendable {
    let urlString: String
    let maxPixelSize: Int

    var storageKey: NSString {
      "\(maxPixelSize)|\(urlString)" as NSString
    }
  }

  private struct InFlightKey: Hashable, Sendable {
    let cacheKey: CacheKey
    let downloadKind: RemoteImageDownloadKind
  }

  private struct InFlightRequest {
    let task: Task<DownsampledImageAsset, Error>
    var waiters: Set<UUID>
  }

  static let shared = DownsampledImageRepository()

  private let downloader: any RemoteImageDownloading
  private let beforeDownload: @Sendable () async -> Void
  private let cache = NSCache<NSString, UIImage>()
  private var inFlight: [InFlightKey: InFlightRequest] = [:]

  init(
    downloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared,
    beforeDownload: @escaping @Sendable () async -> Void = {}
  ) {
    self.downloader = downloader
    self.beforeDownload = beforeDownload
    cache.totalCostLimit = 96 * 1_024 * 1_024
    cache.countLimit = 80
  }

  func image(at url: URL, maxPixelSize requestedSize: Int) async throws
    -> DownsampledImageAsset
  {
    try await image(
      at: url,
      maxPixelSize: requestedSize,
      fetchPolicy: .allowNetwork(
        RemoteImageDownloadPolicy.kind(forMaxPixelSize: requestedSize)
      )
    )
  }

  func image(
    at url: URL,
    maxPixelSize requestedSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy
  ) async throws -> DownsampledImageAsset {
    try Task.checkCancellation()
    guard RemoteImageURLPolicy.allows(url) else {
      throw DownsampledImageError.invalidResponse
    }
    let maxPixelSize = min(max(requestedSize, 64), 4_096)
    let cacheKey = CacheKey(
      urlString: url.absoluteString,
      maxPixelSize: maxPixelSize
    )
    if let cached = cache.object(forKey: cacheKey.storageKey) {
      return DownsampledImageAsset(image: cached)
    }
    guard case .allowNetwork(let downloadKind) = fetchPolicy else {
      throw DownsampledImageError.cacheMiss
    }

    let inFlightKey = InFlightKey(cacheKey: cacheKey, downloadKind: downloadKind)
    let waiterID = UUID()
    let task: Task<DownsampledImageAsset, Error>
    if var request = inFlight[inFlightKey] {
      request.waiters.insert(waiterID)
      inFlight[inFlightKey] = request
      task = request.task
    } else {
      let downloader = downloader
      let beforeDownload = beforeDownload
      task = Task<DownsampledImageAsset, Error> {
        try Task.checkCancellation()
        await beforeDownload()
        try Task.checkCancellation()
        let lease: RemoteImageFileLease
        do {
          lease = try await downloader.download(
            from: url,
            kind: downloadKind
          )
        } catch let error as RemoteImageDownloadError {
          switch error {
          case .responseTooLarge:
            throw DownsampledImageError.responseTooLarge
          case .invalidURL, .invalidResponse, .cannotPersistDownload:
            throw DownsampledImageError.invalidResponse
          }
        }
        try Task.checkCancellation()
        let asset = try await Task.detached(priority: .utility) {
          try withExtendedLifetime(lease) {
            try ImageDownsampler.image(at: lease.fileURL, maxPixelSize: maxPixelSize)
          }
        }.value
        try Task.checkCancellation()
        return asset
      }
      inFlight[inFlightKey] = InFlightRequest(task: task, waiters: [waiterID])
    }

    return try await withTaskCancellationHandler {
      defer { removeWaiter(waiterID, forKey: inFlightKey) }
      let asset = try await task.value
      try Task.checkCancellation()
      let pixelWidth = asset.image.cgImage?.width ?? 0
      let pixelHeight = asset.image.cgImage?.height ?? 0
      cache.setObject(
        asset.image,
        forKey: cacheKey.storageKey,
        cost: pixelWidth * pixelHeight * 4
      )
      return asset
    } onCancel: {
      Task { await self.removeWaiter(waiterID, forKey: inFlightKey) }
    }
  }

  private func removeWaiter(_ waiterID: UUID, forKey key: InFlightKey) {
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
