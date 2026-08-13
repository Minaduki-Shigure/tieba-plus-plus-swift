import Foundation
import ImageIO
import SwiftUI
import UIKit

enum DownsampledRemoteImagePhase {
  case empty
  case success(DownsampledImageAsset, pixelSize: CGSize)
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
  case cacheOnly(RemoteImageDownloadKind)
  case allowNetwork(RemoteImageDownloadKind)
  case allowEconomicalNetwork(RemoteImageDownloadKind)
}

enum DownsampledImageURLPolicy: String, Hashable, Sendable {
  case remoteImage = "remote-image"
  case forumAvatar = "forum-avatar"

  var id: String { rawValue }

  func allows(_ url: URL) -> Bool {
    switch self {
    case .remoteImage:
      RemoteImageURLPolicy.allows(url)
    case .forumAvatar:
      ForumAvatarDisplayPolicy.allows(url)
    }
  }
}

struct DownsampledRemoteImageResourceID: Hashable, Sendable {
  let url: URL?
  let maxPixelSize: Int
  let urlPolicyID: String

  init(
    url: URL?,
    maxPixelSize: Int,
    urlPolicyID: String = DownsampledImageURLPolicy.remoteImage.id
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.urlPolicyID = urlPolicyID
  }
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
  let urlPolicy: DownsampledImageURLPolicy
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
    let urlPolicyID: String
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
      urlPolicy: .remoteImage,
      onAttemptCompletion: { _ in },
      content: content
    )
  }

  init(
    url: URL?,
    maxPixelSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    urlPolicy: DownsampledImageURLPolicy = .remoteImage,
    reloadID: Int = 0,
    onAttemptCompletion: @escaping @MainActor (
      DownsampledRemoteImageAttemptOutcome
    ) -> Void = { _ in },
    @ViewBuilder content: @escaping (DownsampledRemoteImagePhase) -> Content
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.fetchPolicy = fetchPolicy
    self.urlPolicy = urlPolicy
    self.reloadID = reloadID
    self.onAttemptCompletion = onAttemptCompletion
    self.content = { phase, _ in content(phase) }
  }

  init(
    url: URL?,
    maxPixelSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    urlPolicy: DownsampledImageURLPolicy = .remoteImage,
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
    self.urlPolicy = urlPolicy
    self.reloadID = reloadID
    self.onAttemptCompletion = onAttemptCompletion
    self.content = progressContent
  }

  private var requestID: RequestID {
    RequestID(
      url: url,
      maxPixelSize: maxPixelSize,
      fetchPolicy: fetchPolicy,
      urlPolicyID: urlPolicy.id,
      reloadID: reloadID
    )
  }

  private var resourceID: DownsampledRemoteImageResourceID {
    DownsampledRemoteImageResourceID(
      url: url,
      maxPixelSize: maxPixelSize,
      urlPolicyID: urlPolicy.id
    )
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
            urlPolicy: urlPolicy,
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
            asset,
            pixelSize: asset.pixelSize
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
  let animation: RemoteImageAnimationSequence?

  init(image: UIImage, animation: RemoteImageAnimationSequence? = nil) {
    self.image = image
    self.animation = animation
  }

  var pixelSize: CGSize {
    CGSize(
      width: image.cgImage?.width ?? 0,
      height: image.cgImage?.height ?? 0
    )
  }

  var decodedByteCost: Int {
    animation?.decodedByteCost ?? ImageDownsampler.decodedByteCost(of: image) ?? 0
  }
}

private final class DownsampledImageAssetBox: NSObject {
  let asset: DownsampledImageAsset

  init(_ asset: DownsampledImageAsset) {
    self.asset = asset
  }
}

enum DownsampledImageError: Error, Equatable {
  case cacheMiss
  case invalidResponse
  case responseTooLarge
  case unreadableImage
}

actor DownsampledImageRepository {
  private struct CacheKey: Hashable, Sendable {
    let urlString: String
    let maxPixelSize: Int
    let urlPolicyID: String

    var storageKey: NSString {
      "\(urlPolicyID)|\(maxPixelSize)|\(urlString)" as NSString
    }
  }

  private struct InFlightKey: Hashable, Sendable {
    let cacheKey: CacheKey
    let fetchPolicy: DownsampledImageFetchPolicy
    let urlPolicyID: String
  }

  private struct LoadedImage: @unchecked Sendable {
    let asset: DownsampledImageAsset
    let sourceLease: RemoteImageFileLease
    let shouldPersist: Bool
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
    let task: Task<LoadedImage, Error>
    var waiters: [UUID: Waiter]
    var latestProgress: DownsampledRemoteImageLoadProgress?
    var stage: Stage
  }

  static let shared = DownsampledImageRepository(
    persistentCache: RemoteImageDiskCache.shared
  )

  private let downloader: any RemoteImageDownloading
  private let persistentCache: (any RemoteImagePersistentCacheProviding)?
  private let beforeDownload: @Sendable () async -> Void
  private let beforeDecoding: @Sendable () async -> Void
  private let inFlightWaiterCountDidChange: @Sendable (Int) -> Void
  private let inFlightProgressEventDidProcess: @Sendable (
    DownsampledRemoteImageLoadProgress,
    Bool
  ) -> Void
  private let cache = NSCache<NSString, DownsampledImageAssetBox>()
  private var cacheGeneration: UInt64 = 0
  private var activeCacheClearCount = 0
  private var inFlight: [InFlightKey: InFlightRequest] = [:]

  private var isClearingAllCaches: Bool {
    activeCacheClearCount > 0
  }

  init(
    downloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared,
    persistentCache: (any RemoteImagePersistentCacheProviding)? = nil,
    beforeDownload: @escaping @Sendable () async -> Void = {},
    beforeDecoding: @escaping @Sendable () async -> Void = {},
    inFlightWaiterCountDidChange: @escaping @Sendable (Int) -> Void = { _ in },
    inFlightProgressEventDidProcess: @escaping @Sendable (
      DownsampledRemoteImageLoadProgress,
      Bool
    ) -> Void = { _, _ in }
  ) {
    self.downloader = downloader
    self.persistentCache = persistentCache
    self.beforeDownload = beforeDownload
    self.beforeDecoding = beforeDecoding
    self.inFlightWaiterCountDidChange = inFlightWaiterCountDidChange
    self.inFlightProgressEventDidProcess = inFlightProgressEventDidProcess
    cache.totalCostLimit = 96 * 1_024 * 1_024
    cache.countLimit = 80
  }

  func clearMemoryCache() {
    evictDecodedCaches()
  }

  func clearAllImageCaches(
    using persistentCache: any RemoteImagePersistentCacheProviding
  ) async -> RemoteImageDiskCacheClearResult {
    activeCacheClearCount += 1
    evictDecodedCaches()
    let result = await persistentCache.clear()
    evictDecodedCaches()
    activeCacheClearCount -= 1
    return result
  }

  private func evictDecodedCaches() {
    cacheGeneration &+= 1
    cache.removeAllObjects()
    RemoteImageAnimationFrameCache.shared.removeAllObjects()
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
      urlPolicy: .remoteImage,
      onProgress: { _ in }
    )
  }

  func image(
    at url: URL,
    maxPixelSize requestedSize: Int,
    fetchPolicy: DownsampledImageFetchPolicy,
    urlPolicy: DownsampledImageURLPolicy = .remoteImage,
    onProgress: @escaping @Sendable (DownsampledRemoteImageLoadProgress) -> Void
  ) async throws -> DownsampledImageAsset {
    try Task.checkCancellation()
    guard RemoteImageURLPolicy.allows(url), urlPolicy.allows(url) else {
      throw DownsampledImageError.invalidResponse
    }
    let maxPixelSize = min(max(requestedSize, 64), 4_096)
    let cacheKey = CacheKey(
      urlString: url.absoluteString,
      maxPixelSize: maxPixelSize,
      urlPolicyID: urlPolicy.id
    )
    if !isClearingAllCaches, let cached = cache.object(forKey: cacheKey.storageKey) {
      return cached.asset
    }
    let downloadKind: RemoteImageDownloadKind
    let networkAccess: RemoteImageNetworkAccess?
    switch fetchPolicy {
    case .cacheOnly(let kind):
      downloadKind = kind
      networkAccess = nil
    case .allowNetwork(let kind):
      downloadKind = kind
      networkAccess = .unrestricted
    case .allowEconomicalNetwork(let kind):
      downloadKind = kind
      networkAccess = .economicalOnly
    }
    let waiterCacheGeneration = cacheGeneration
    let persistentGenerationToken: RemoteImageDiskCacheGenerationToken?
    let requestPersistentCache = isClearingAllCaches ? nil : persistentCache
    if networkAccess != nil, let requestPersistentCache {
      persistentGenerationToken = await requestPersistentCache.currentGenerationToken()
    } else {
      persistentGenerationToken = nil
    }

    if !isClearingAllCaches, let cached = cache.object(forKey: cacheKey.storageKey) {
      return cached.asset
    }

    let inFlightKey = InFlightKey(
      cacheKey: cacheKey,
      fetchPolicy: fetchPolicy,
      urlPolicyID: urlPolicy.id
    )
    let waiterID = UUID()
    let waiter = InFlightRequest.Waiter(onProgress: onProgress)
    let transferID: UUID
    let task: Task<LoadedImage, Error>
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
      let persistentCache = requestPersistentCache
      let beforeDownload = beforeDownload
      let beforeDecoding = beforeDecoding
      let newTransferID = UUID()
      transferID = newTransferID
      task = Task<LoadedImage, Error> {
        try Task.checkCancellation()
        if let persistentCache {
          let cachedLease: RemoteImageFileLease?
          do {
            cachedLease = try await persistentCache.cachedDownload(
              from: url,
              kind: downloadKind,
              namespace: urlPolicy.id
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            cachedLease = nil
          }
          if let cachedLease {
            do {
              await beforeDecoding()
              try Task.checkCancellation()
              let cachedAsset = try await RemoteImageIODecodeScheduler.shared.decode {
                try withExtendedLifetime(cachedLease) {
                  try ImageDownsampler.image(
                    at: cachedLease.fileURL,
                    maxPixelSize: maxPixelSize,
                    sourceOwner: cachedLease,
                    sourceByteCount: cachedLease.byteCount
                  )
                }
              }
              try Task.checkCancellation()
              await self.beginDecoding(
                forKey: inFlightKey,
                transferID: newTransferID
              )
              return LoadedImage(
                asset: cachedAsset,
                sourceLease: cachedLease,
                shouldPersist: false
              )
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              if networkAccess == nil {
                throw DownsampledImageError.cacheMiss
              }
              // A validated cache entry that no longer decodes is treated as a miss.
            }
          }
        }

        guard let networkAccess else {
          throw DownsampledImageError.cacheMiss
        }
        await beforeDownload()
        try Task.checkCancellation()
        let lease: RemoteImageFileLease
        do {
          lease = try await downloader.download(
            from: url,
            kind: downloadKind,
            networkAccess: networkAccess,
            redirectURLValidator: urlPolicy.allows,
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
          guard
            RemoteImageURLPolicy.allows(lease.sourceURL),
            urlPolicy.allows(lease.sourceURL)
          else { throw RemoteImageDownloadError.invalidResponse }
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
        let asset = try await RemoteImageIODecodeScheduler.shared.decode {
          try withExtendedLifetime(lease) {
            try ImageDownsampler.image(
              at: lease.fileURL,
              maxPixelSize: maxPixelSize,
              sourceOwner: lease,
              sourceByteCount: lease.byteCount
            )
          }
        }
        try Task.checkCancellation()
        return LoadedImage(asset: asset, sourceLease: lease, shouldPersist: true)
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
      let loaded = try await task.value
      try Task.checkCancellation()
      if
        loaded.shouldPersist,
        let persistentCache,
        let persistentGenerationToken
      {
        do {
          try await persistentCache.storeValidated(
            loaded.sourceLease,
            requestedURL: url,
            kind: downloadKind,
            namespace: urlPolicy.id,
            generationToken: persistentGenerationToken
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Image rendering remains available when the optional disk cache fails.
        }
      }
      try Task.checkCancellation()
      if !isClearingAllCaches, waiterCacheGeneration == cacheGeneration {
        cache.setObject(
          DownsampledImageAssetBox(loaded.asset),
          forKey: cacheKey.storageKey,
          cost: loaded.asset.decodedByteCost
        )
      }
      return loaded.asset
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
  static let maximumAnimationFrameCount = 500
  static let maximumAnimationFrameDecodedByteCost = 16 * 1_024 * 1_024

  static func image(
    at fileURL: URL,
    maxPixelSize: Int,
    sourceOwner: AnyObject? = nil,
    sourceByteCount: Int64? = nil,
    animationDecodedByteBudget: Int = maximumAnimationFrameDecodedByteCost
  ) throws -> DownsampledImageAsset {
    try Task.checkCancellation()
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
      throw DownsampledImageError.unreadableImage
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else {
      throw DownsampledImageError.unreadableImage
    }
    let requestedPixelSize = min(max(maxPixelSize, 64), 4_096)
    let sourceTypeIdentifier = CGImageSourceGetType(source) as String?
    let sourceProperties = properties(of: source)
    let hasHEICSSequenceMetadata = hasHEICSSequenceMetadata(
      sourceProperties,
      frameCount: frameCount
    )

    if let format = RemoteImageAnimationPolicy.format(
      sourceTypeIdentifier: sourceTypeIdentifier,
      frameCount: frameCount,
      hasHEICSSequenceMetadata: hasHEICSSequenceMetadata
    ), let animationPixelSize = animationPixelLimit(
      requestedPixelSize: requestedPixelSize,
      frameCount: frameCount,
      decodedByteBudget: animationDecodedByteBudget
    ) {
      try Task.checkCancellation()
      let poster = try thumbnail(
        source: source,
        index: 0,
        maxPixelSize: animationPixelSize
      )
      try Task.checkCancellation()
      guard
        let posterCost = decodedByteCost(of: poster),
        posterCost <= animationDecodedByteBudget
      else {
        return DownsampledImageAsset(image: poster)
      }
      let frameDurations = try animationFrameDurations(
        source: source,
        format: format,
        frameCount: frameCount,
        sourceProperties: sourceProperties
      )
      try Task.checkCancellation()
      let source = RemoteImageAnimationSource(
        fileURL: fileURL,
        compressedByteCount: compressedByteCost(
          at: fileURL,
          suppliedByteCount: sourceByteCount
        ),
        retainedOwner: sourceOwner
      )
      let retainedCost = addingClamped(posterCost, source.compressedByteCount)
      let animation = RemoteImageAnimationSequence(
        format: format,
        poster: poster,
        frameCount: frameCount,
        maxPixelSize: animationPixelSize,
        frameDurations: frameDurations,
        totalPlaythroughs: RemoteImageAnimationPolicy.totalPlaythroughs(
          format: format,
          imageIOLoopCount: imageIOLoopCount(
            format: format,
            sourceProperties: sourceProperties
          )
        ),
        posterDecodedByteCost: posterCost,
        decodedByteCost: retainedCost,
        source: source
      )
      return DownsampledImageAsset(image: poster, animation: animation)
    }

    try Task.checkCancellation()
    let primaryIndex = staticPosterIndex(
      sourceTypeIdentifier: sourceTypeIdentifier,
      source: source,
      frameCount: frameCount
    )
    let poster = try thumbnail(
      source: source,
      index: primaryIndex,
      maxPixelSize: requestedPixelSize
    )
    try Task.checkCancellation()
    return DownsampledImageAsset(image: poster)
  }

  static func animationPixelLimit(
    requestedPixelSize: Int,
    frameCount: Int,
    decodedByteBudget: Int = maximumAnimationFrameDecodedByteCost
  ) -> Int? {
    guard
      frameCount > 1,
      frameCount <= maximumAnimationFrameCount,
      decodedByteBudget > 0
    else { return nil }

    let pixelsPerFrame = decodedByteBudget / 4
    let budgetedPixelSize = Int(Double(pixelsPerFrame).squareRoot().rounded(.down))
    guard budgetedPixelSize >= 64 else { return nil }
    return min(min(max(requestedPixelSize, 64), 4_096), budgetedPixelSize)
  }

  static func decodedByteCost(of image: UIImage) -> Int? {
    guard let cgImage = image.cgImage else { return nil }
    return decodedByteCost(bytesPerRow: cgImage.bytesPerRow, height: cgImage.height)
  }

  static func decodedByteCost(bytesPerRow: Int, height: Int) -> Int? {
    guard bytesPerRow > 0, height > 0, bytesPerRow <= Int.max / height else {
      return nil
    }
    return bytesPerRow * height
  }

  static func frame(
    at fileURL: URL,
    index: Int,
    maxPixelSize: Int
  ) throws -> UIImage {
    try Task.checkCancellation()
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
      throw DownsampledImageError.unreadableImage
    }
    guard (0..<CGImageSourceGetCount(source)).contains(index) else {
      throw RemoteImageAnimationFrameError.invalidFrameIndex
    }
    let image = try thumbnail(source: source, index: index, maxPixelSize: maxPixelSize)
    try Task.checkCancellation()
    return image
  }

  static func addingClamped(_ first: Int, _ second: Int) -> Int {
    guard first >= 0, second >= 0, first <= Int.max - second else { return Int.max }
    return first + second
  }

  static func compressedByteCost(at fileURL: URL, suppliedByteCount: Int64?) -> Int {
    if let suppliedByteCount {
      guard suppliedByteCount > 0 else { return 0 }
      return suppliedByteCount > Int64(Int.max) ? Int.max : Int(suppliedByteCount)
    }
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
      let fileSize = values.fileSize,
      fileSize > 0
    else { return 0 }
    return fileSize
  }

  private static func animationFrameDurations(
    source: CGImageSource,
    format: RemoteImageAnimationFormat,
    frameCount: Int,
    sourceProperties: [CFString: Any]
  ) throws -> [TimeInterval] {
    var durations = [TimeInterval]()
    durations.reserveCapacity(frameCount)

    for index in 0..<frameCount {
      try Task.checkCancellation()
      durations.append(
        RemoteImageAnimationPolicy.normalizedFrameDuration(
          rawFrameDuration(
            source: source,
            index: index,
            format: format,
            sourceProperties: sourceProperties
          )
        )
      )
      try Task.checkCancellation()
    }
    return durations
  }

  private static func thumbnail(
    source: CGImageSource,
    index: Int,
    maxPixelSize: Int
  ) throws -> UIImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(maxPixelSize, 64), 4_096),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    else {
      throw DownsampledImageError.unreadableImage
    }
    return UIImage(cgImage: image)
  }

  private static func properties(of source: CGImageSource) -> [CFString: Any] {
    CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
  }

  private static func frameProperties(
    source: CGImageSource,
    index: Int
  ) -> [CFString: Any] {
    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
  }

  private static func staticPosterIndex(
    sourceTypeIdentifier: String?,
    source: CGImageSource,
    frameCount: Int
  ) -> Int {
    guard
      let sourceTypeIdentifier,
      RemoteImageAnimationPolicy.isHEIFContainer(sourceTypeIdentifier)
    else { return 0 }
    let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
    return (0..<frameCount).contains(primaryIndex) ? primaryIndex : 0
  }

  private static func hasHEICSSequenceMetadata(
    _ sourceProperties: [CFString: Any],
    frameCount: Int
  ) -> Bool {
    guard
      let dictionary = sourceProperties[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
      let frameInformation = dictionary[kCGImagePropertyHEICSFrameInfoArray] as? [Any]
    else { return false }
    return frameInformation.count == frameCount && frameCount > 1
  }

  private static func rawFrameDuration(
    source: CGImageSource,
    index: Int,
    format: RemoteImageAnimationFormat,
    sourceProperties: [CFString: Any]
  ) -> TimeInterval? {
    let properties = frameProperties(source: source, index: index)
    let dictionaryKey: CFString
    let unclampedDelayKey: CFString
    let delayKey: CFString
    let frameInformationKey: CFString
    switch format {
    case .gif:
      dictionaryKey = kCGImagePropertyGIFDictionary
      unclampedDelayKey = kCGImagePropertyGIFUnclampedDelayTime
      delayKey = kCGImagePropertyGIFDelayTime
      frameInformationKey = kCGImagePropertyGIFFrameInfoArray
    case .webP:
      dictionaryKey = kCGImagePropertyWebPDictionary
      unclampedDelayKey = kCGImagePropertyWebPUnclampedDelayTime
      delayKey = kCGImagePropertyWebPDelayTime
      frameInformationKey = kCGImagePropertyWebPFrameInfoArray
    case .heics:
      dictionaryKey = kCGImagePropertyHEICSDictionary
      unclampedDelayKey = kCGImagePropertyHEICSUnclampedDelayTime
      delayKey = kCGImagePropertyHEICSDelayTime
      frameInformationKey = kCGImagePropertyHEICSFrameInfoArray
    }

    if let dictionary = properties[dictionaryKey] as? [CFString: Any] {
      if let duration = number(dictionary[unclampedDelayKey]) { return duration }
      if let duration = number(dictionary[delayKey]) { return duration }
    }
    guard
      let sourceDictionary = sourceProperties[dictionaryKey] as? [CFString: Any],
      let frameInformation = sourceDictionary[frameInformationKey] as? [Any],
      frameInformation.indices.contains(index),
      let dictionary = frameInformation[index] as? [CFString: Any]
    else { return nil }
    return number(dictionary[unclampedDelayKey]) ?? number(dictionary[delayKey])
  }

  private static func imageIOLoopCount(
    format: RemoteImageAnimationFormat,
    sourceProperties: [CFString: Any]
  ) -> Int? {
    let dictionaryKey: CFString
    let loopCountKey: CFString
    switch format {
    case .gif:
      dictionaryKey = kCGImagePropertyGIFDictionary
      loopCountKey = kCGImagePropertyGIFLoopCount
    case .webP:
      dictionaryKey = kCGImagePropertyWebPDictionary
      loopCountKey = kCGImagePropertyWebPLoopCount
    case .heics:
      dictionaryKey = kCGImagePropertyHEICSDictionary
      loopCountKey = kCGImagePropertyHEICSLoopCount
    }
    guard
      let dictionary = sourceProperties[dictionaryKey] as? [CFString: Any],
      let value = dictionary[loopCountKey] as? NSNumber,
      value.int64Value >= 0,
      value.int64Value <= Int64(Int.max)
    else { return nil }
    return Int(value.int64Value)
  }

  private static func number(_ value: Any?) -> TimeInterval? {
    (value as? NSNumber)?.doubleValue
  }
}
