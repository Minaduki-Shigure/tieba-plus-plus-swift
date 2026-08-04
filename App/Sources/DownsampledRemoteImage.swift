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

enum DownsampledRemoteImageLoadProgress: Equatable, Sendable {
  case downloading(RemoteImageDownloadProgress)
  case decoding
}

enum DownsampledImageFetchPolicy: Hashable, Sendable {
  case cacheOnly
  case allowNetwork(RemoteImageDownloadKind)
  case allowEconomicalNetwork(RemoteImageDownloadKind)
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

  static func canAcceptEvent(activeAttemptID: UUID?, eventAttemptID: UUID) -> Bool {
    activeAttemptID == eventAttemptID
  }

  static func canAdvanceProgress(
    from current: DownsampledRemoteImageLoadProgress?,
    to incoming: DownsampledRemoteImageLoadProgress
  ) -> Bool {
    guard let current else { return true }
    switch (current, incoming) {
    case (.downloading(let currentDownload), .downloading(let incomingDownload)):
      guard incomingDownload.receivedByteCount >= currentDownload.receivedByteCount else {
        return false
      }
      if
        let currentPercentage = currentDownload.percentageCompleted,
        let incomingPercentage = incomingDownload.percentageCompleted
      {
        return incomingPercentage >= currentPercentage
      }
      return true
    case (.downloading, .decoding):
      return true
    case (.decoding, _):
      return false
    }
  }
}

struct DownsampledRemoteImage<Content: View>: View {
  let url: URL?
  let maxPixelSize: Int
  let fetchPolicy: DownsampledImageFetchPolicy
  let reloadID: Int
  let onAttemptCompletion: @MainActor (DownsampledRemoteImageAttemptOutcome) -> Void
  @ViewBuilder let content: (
    DownsampledRemoteImagePhase,
    DownsampledRemoteImageLoadProgress?
  ) -> Content

  @State private var phase: DownsampledRemoteImagePhase = .empty
  @State private var phaseResourceID: DownsampledRemoteImageResourceID?
  @State private var loadProgress: DownsampledRemoteImageLoadProgress?
  @State private var progressRequestID: RequestID?
  @State private var attemptID: UUID?

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
    self.content = { phase, _ in content(phase) }
  }

  init(
    url: URL?,
    maxPixelSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    reloadID: Int = 0,
    onAttemptCompletion: @escaping @MainActor (
      DownsampledRemoteImageAttemptOutcome
    ) -> Void = { _ in },
    @ViewBuilder progressContent: @escaping (
      DownsampledRemoteImagePhase,
      DownsampledRemoteImageLoadProgress?
    ) -> Content
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.fetchPolicy = fetchPolicy
    self.reloadID = reloadID
    self.onAttemptCompletion = onAttemptCompletion
    self.content = progressContent
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
    let canRenderStoredState = DownsampledRemoteImageStateDecision.canRenderStoredPhase(
      storedResourceID: phaseResourceID,
      currentResourceID: resourceID
    )
    content(
      canRenderStoredState ? phase : .empty,
      canRenderStoredState && progressRequestID == requestID ? loadProgress : nil
    )
      .task(id: requestID) {
        let activeAttemptID = UUID()
        let activeResourceID = resourceID
        let activeRequestID = requestID
        attemptID = activeAttemptID
        progressRequestID = activeRequestID
        loadProgress = nil
        if phaseResourceID != activeResourceID || !hasSuccessfulPhase {
          phase = .empty
        }
        phaseResourceID = activeResourceID
        guard let url else {
          guard DownsampledRemoteImageStateDecision.canAcceptEvent(
            activeAttemptID: attemptID,
            eventAttemptID: activeAttemptID
          ) else { return }
          attemptID = nil
          phase = .failure
          onAttemptCompletion(.failure)
          return
        }
        do {
          let asset = try await DownsampledImageRepository.shared.image(
            at: url,
            maxPixelSize: maxPixelSize,
            fetchPolicy: fetchPolicy,
            onProgress: { progress in
              Task { @MainActor in
                guard DownsampledRemoteImageStateDecision.canAcceptEvent(
                  activeAttemptID: attemptID,
                  eventAttemptID: activeAttemptID
                ), DownsampledRemoteImageStateDecision.canAdvanceProgress(
                  from: loadProgress,
                  to: progress
                ) else { return }
                loadProgress = progress
              }
            }
          )
          try Task.checkCancellation()
          guard DownsampledRemoteImageStateDecision.canAcceptEvent(
            activeAttemptID: attemptID,
            eventAttemptID: activeAttemptID
          ) else { return }
          attemptID = nil
          loadProgress = nil
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
          guard DownsampledRemoteImageStateDecision.canAcceptEvent(
            activeAttemptID: attemptID,
            eventAttemptID: activeAttemptID
          ) else { return }
          attemptID = nil
          loadProgress = nil
          onAttemptCompletion(.cancelled)
          return
        } catch {
          if Task.isCancelled {
            guard DownsampledRemoteImageStateDecision.canAcceptEvent(
              activeAttemptID: attemptID,
              eventAttemptID: activeAttemptID
            ) else { return }
            attemptID = nil
            loadProgress = nil
            onAttemptCompletion(.cancelled)
            return
          }
          guard DownsampledRemoteImageStateDecision.canAcceptEvent(
            activeAttemptID: attemptID,
            eventAttemptID: activeAttemptID
          ) else { return }
          attemptID = nil
          loadProgress = nil
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
    let networkAccess: RemoteImageNetworkAccess
  }

  private struct InFlightRequest {
    struct Waiter {
      let onProgress: @Sendable (DownsampledRemoteImageLoadProgress) -> Void
    }

    enum Stage: Equatable {
      case downloading
      case decoding
    }

    let transferID: UUID
    let task: Task<DownsampledImageAsset, Error>
    var waiters: [UUID: Waiter]
    var latestProgress: DownsampledRemoteImageLoadProgress?
    var stage: Stage
  }

  static let shared = DownsampledImageRepository()

  private let downloader: any RemoteImageDownloading
  private let beforeDownload: @Sendable () async -> Void
  private let beforeDecoding: @Sendable () async -> Void
  private let inFlightWaiterCountDidChange: @Sendable (Int) -> Void
  private let inFlightProgressEventDidProcess: @Sendable (
    DownsampledRemoteImageLoadProgress,
    Bool
  ) -> Void
  private let cache = NSCache<NSString, UIImage>()
  private var cacheGeneration: UInt64 = 0
  private var inFlight: [InFlightKey: InFlightRequest] = [:]

  init(
    downloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared,
    beforeDownload: @escaping @Sendable () async -> Void = {},
    beforeDecoding: @escaping @Sendable () async -> Void = {},
    inFlightWaiterCountDidChange: @escaping @Sendable (Int) -> Void = { _ in },
    inFlightProgressEventDidProcess: @escaping @Sendable (
      DownsampledRemoteImageLoadProgress,
      Bool
    ) -> Void = { _, _ in }
  ) {
    self.downloader = downloader
    self.beforeDownload = beforeDownload
    self.beforeDecoding = beforeDecoding
    self.inFlightWaiterCountDidChange = inFlightWaiterCountDidChange
    self.inFlightProgressEventDidProcess = inFlightProgressEventDidProcess
    cache.totalCostLimit = 96 * 1_024 * 1_024
    cache.countLimit = 80
  }

  func clearMemoryCache() {
    cacheGeneration &+= 1
    cache.removeAllObjects()
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
    try await image(
      at: url,
      maxPixelSize: requestedSize,
      fetchPolicy: fetchPolicy,
      onProgress: { _ in }
    )
  }

  func image(
    at url: URL,
    maxPixelSize requestedSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    onProgress: @escaping @Sendable (DownsampledRemoteImageLoadProgress) -> Void
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
    let downloadKind: RemoteImageDownloadKind
    let networkAccess: RemoteImageNetworkAccess
    switch fetchPolicy {
    case .cacheOnly:
      throw DownsampledImageError.cacheMiss
    case .allowNetwork(let kind):
      downloadKind = kind
      networkAccess = .unrestricted
    case .allowEconomicalNetwork(let kind):
      downloadKind = kind
      networkAccess = .economicalOnly
    }
    let waiterCacheGeneration = cacheGeneration

    let inFlightKey = InFlightKey(
      cacheKey: cacheKey,
      downloadKind: downloadKind,
      networkAccess: networkAccess
    )
    let waiterID = UUID()
    let waiter = InFlightRequest.Waiter(onProgress: onProgress)
    let transferID: UUID
    let task: Task<DownsampledImageAsset, Error>
    if var request = inFlight[inFlightKey] {
      request.waiters[waiterID] = waiter
      inFlight[inFlightKey] = request
      inFlightWaiterCountDidChange(request.waiters.count)
      if let latestProgress = request.latestProgress {
        onProgress(latestProgress)
      }
      transferID = request.transferID
      task = request.task
    } else {
      let downloader = downloader
      let beforeDownload = beforeDownload
      let beforeDecoding = beforeDecoding
      let newTransferID = UUID()
      transferID = newTransferID
      task = Task<DownsampledImageAsset, Error> {
        try Task.checkCancellation()
        await beforeDownload()
        try Task.checkCancellation()
        let lease: RemoteImageFileLease
        do {
          lease = try await downloader.download(
            from: url,
            kind: downloadKind,
            networkAccess: networkAccess,
            onProgress: { progress in
              Task {
                await self.receive(
                  .downloading(progress),
                  forKey: inFlightKey,
                  transferID: newTransferID
                )
              }
            }
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
        await self.beginDecoding(forKey: inFlightKey, transferID: newTransferID)
        await beforeDecoding()
        try Task.checkCancellation()
        let asset = try await Task.detached(priority: .utility) {
          try withExtendedLifetime(lease) {
            try ImageDownsampler.image(at: lease.fileURL, maxPixelSize: maxPixelSize)
          }
        }.value
        try Task.checkCancellation()
        return asset
      }
      inFlight[inFlightKey] = InFlightRequest(
        transferID: newTransferID,
        task: task,
        waiters: [waiterID: waiter],
        latestProgress: nil,
        stage: .downloading
      )
      inFlightWaiterCountDidChange(1)
    }

    return try await withTaskCancellationHandler {
      defer {
        removeWaiter(waiterID, forKey: inFlightKey, transferID: transferID)
      }
      let asset = try await task.value
      try Task.checkCancellation()
      if waiterCacheGeneration == cacheGeneration {
        let pixelWidth = asset.image.cgImage?.width ?? 0
        let pixelHeight = asset.image.cgImage?.height ?? 0
        cache.setObject(
          asset.image,
          forKey: cacheKey.storageKey,
          cost: pixelWidth * pixelHeight * 4
        )
      }
      return asset
    } onCancel: {
      Task {
        await self.removeWaiter(
          waiterID,
          forKey: inFlightKey,
          transferID: transferID
        )
      }
    }
  }

  private func receive(
    _ progress: DownsampledRemoteImageLoadProgress,
    forKey key: InFlightKey,
    transferID: UUID
  ) {
    var didAccept = false
    defer { inFlightProgressEventDidProcess(progress, didAccept) }
    guard
      var request = inFlight[key],
      request.transferID == transferID,
      request.stage == .downloading,
      case .downloading(let downloadProgress) = progress
    else { return }
    if case .downloading(let latestDownloadProgress) = request.latestProgress,
       downloadProgress.receivedByteCount < latestDownloadProgress.receivedByteCount
    {
      return
    }
    guard request.latestProgress != progress else { return }
    request.latestProgress = progress
    inFlight[key] = request
    request.waiters.values.forEach { $0.onProgress(progress) }
    didAccept = true
  }

  private func beginDecoding(forKey key: InFlightKey, transferID: UUID) {
    guard
      var request = inFlight[key],
      request.transferID == transferID,
      request.stage == .downloading
    else { return }
    request.stage = .decoding
    request.latestProgress = .decoding
    inFlight[key] = request
    request.waiters.values.forEach { $0.onProgress(.decoding) }
  }

  private func removeWaiter(
    _ waiterID: UUID,
    forKey key: InFlightKey,
    transferID: UUID
  ) {
    guard
      var request = inFlight[key],
      request.transferID == transferID,
      request.waiters.removeValue(forKey: waiterID) != nil
    else {
      return
    }
    if request.waiters.isEmpty {
      inFlight[key] = nil
      inFlightWaiterCountDidChange(0)
      request.task.cancel()
    } else {
      inFlight[key] = request
      inFlightWaiterCountDidChange(request.waiters.count)
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
