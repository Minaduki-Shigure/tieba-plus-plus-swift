import Foundation
import SwiftUI
import UIKit

enum RemoteImageAnimationFormat: Equatable, Sendable {
  case gif
  case webP
  case heics
}

final class RemoteImageAnimationSource: @unchecked Sendable {
  let fileURL: URL
  let compressedByteCount: Int
  private let retainedOwner: AnyObject?

  init(fileURL: URL, compressedByteCount: Int, retainedOwner: AnyObject?) {
    self.fileURL = fileURL
    self.compressedByteCount = max(compressedByteCount, 0)
    self.retainedOwner = retainedOwner
  }

  func withFileURL<Value>(_ operation: (URL) throws -> Value) rethrows -> Value {
    try withExtendedLifetime(retainedOwner) {
      try operation(fileURL)
    }
  }
}

struct RemoteImageAnimationSequence: @unchecked Sendable {
  let id: UUID
  let format: RemoteImageAnimationFormat
  let poster: UIImage
  let frameCount: Int
  let maxPixelSize: Int
  let frameDurations: [TimeInterval]
  let totalPlaythroughs: Int
  let posterDecodedByteCost: Int
  let decodedByteCost: Int
  let source: RemoteImageAnimationSource

  init(
    id: UUID = UUID(),
    format: RemoteImageAnimationFormat,
    poster: UIImage,
    frameCount: Int,
    maxPixelSize: Int,
    frameDurations: [TimeInterval],
    totalPlaythroughs: Int,
    posterDecodedByteCost: Int,
    decodedByteCost: Int,
    source: RemoteImageAnimationSource
  ) {
    precondition(frameCount > 1)
    precondition(frameDurations.count == frameCount)
    precondition(totalPlaythroughs >= 0)
    precondition(posterDecodedByteCost > 0)
    precondition(decodedByteCost > 0)
    self.id = id
    self.format = format
    self.poster = poster
    self.frameCount = frameCount
    self.maxPixelSize = maxPixelSize
    self.frameDurations = frameDurations
    self.totalPlaythroughs = totalPlaythroughs
    self.posterDecodedByteCost = posterDecodedByteCost
    self.decodedByteCost = decodedByteCost
    self.source = source
  }

  func decodedFrame(at index: Int) async throws -> RemoteImageDecodedFrame {
    try Task.checkCancellation()
    guard (0..<frameCount).contains(index) else {
      throw RemoteImageAnimationFrameError.invalidFrameIndex
    }
    if index == 0 {
      try Task.checkCancellation()
      return RemoteImageDecodedFrame(
        image: poster,
        decodedByteCost: posterDecodedByteCost
      )
    }
    return try await RemoteImageAnimationFrameLoader.frame(at: index, in: self)
  }
}

enum RemoteImageAnimationFrameError: Error {
  case invalidFrameIndex
}

enum RemoteImageAnimationPolicy {
  static let fallbackFrameDuration: TimeInterval = 0.1
  static let minimumAcceptedFrameDuration: TimeInterval = 0.02

  static func format(
    sourceTypeIdentifier: String?,
    frameCount: Int,
    hasHEICSSequenceMetadata: Bool
  ) -> RemoteImageAnimationFormat? {
    guard
      let sourceTypeIdentifier,
      frameCount > 1,
      frameCount <= ImageDownsampler.maximumAnimationFrameCount
    else { return nil }

    switch sourceTypeIdentifier {
    case "com.compuserve.gif":
      return .gif
    case "org.webmproject.webp":
      return .webP
    case "public.heics":
      return .heics
    default:
      guard
        hasHEICSSequenceMetadata,
        isHEIFContainer(sourceTypeIdentifier)
      else { return nil }
      return .heics
    }
  }

  static func normalizedFrameDuration(_ rawDuration: TimeInterval?) -> TimeInterval {
    guard
      let rawDuration,
      rawDuration.isFinite,
      rawDuration >= minimumAcceptedFrameDuration
    else { return fallbackFrameDuration }
    return rawDuration
  }

  static func totalPlaythroughs(
    format: RemoteImageAnimationFormat,
    imageIOLoopCount: Int?
  ) -> Int {
    guard let imageIOLoopCount, imageIOLoopCount >= 0 else {
      switch format {
      case .gif, .webP:
        return 1
      case .heics:
        return 0
      }
    }
    return imageIOLoopCount
  }

  static func isHEIFContainer(_ sourceTypeIdentifier: String) -> Bool {
    switch sourceTypeIdentifier {
    case "public.heics", "public.heic", "public.heif", "public.heif-standard":
      true
    default:
      false
    }
  }
}

final class RemoteImageDecodedFrame: NSObject, @unchecked Sendable {
  let image: UIImage
  let decodedByteCost: Int

  init(image: UIImage, decodedByteCost: Int) {
    self.image = image
    self.decodedByteCost = decodedByteCost
  }
}

struct RemoteImageAnimationFrameCacheKey: Hashable, Sendable {
  let sequenceID: UUID
  let frameIndex: Int

  var storageKey: NSString {
    "\(sequenceID.uuidString)|\(frameIndex)" as NSString
  }
}

final class RemoteImageAnimationFrameCache: @unchecked Sendable {
  static let shared = RemoteImageAnimationFrameCache()

  let totalCostLimit: Int
  let countLimit: Int
  private let cache = NSCache<NSString, RemoteImageDecodedFrame>()
  private let lock = NSLock()
  private var generation: UInt64 = 0

  init(
    totalCostLimit: Int = 64 * 1_024 * 1_024,
    countLimit: Int = 1_000
  ) {
    self.totalCostLimit = max(totalCostLimit, 1)
    self.countLimit = max(countLimit, 1)
    cache.totalCostLimit = self.totalCostLimit
    cache.countLimit = self.countLimit
  }

  func cachedFrameAndGeneration(
    for key: RemoteImageAnimationFrameCacheKey
  ) -> (RemoteImageDecodedFrame?, UInt64) {
    lock.lock()
    defer { lock.unlock() }
    return (cache.object(forKey: key.storageKey), generation)
  }

  @discardableResult
  func insert(
    _ frame: RemoteImageDecodedFrame,
    for key: RemoteImageAnimationFrameCacheKey,
    generation expectedGeneration: UInt64
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard generation == expectedGeneration else { return false }
    cache.setObject(
      frame,
      forKey: key.storageKey,
      cost: frame.decodedByteCost
    )
    return true
  }

  func remove(
    _ frame: RemoteImageDecodedFrame,
    for key: RemoteImageAnimationFrameCacheKey,
    generation expectedGeneration: UInt64
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard
      generation == expectedGeneration,
      cache.object(forKey: key.storageKey) === frame
    else { return }
    cache.removeObject(forKey: key.storageKey)
  }

  func removeAllObjects() {
    lock.lock()
    generation &+= 1
    cache.removeAllObjects()
    lock.unlock()
  }
}

private actor RemoteImageDecodePermitPool {
  private let limit: Int
  private var availablePermits: Int
  private var waiterOrder: [UUID] = []
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

  init(limit: Int) {
    self.limit = max(limit, 1)
    self.availablePermits = max(limit, 1)
  }

  func acquire() async throws {
    try Task.checkCancellation()
    if availablePermits > 0 {
      availablePermits -= 1
      if Task.isCancelled {
        release()
        throw CancellationError()
      }
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiterOrder.append(waiterID)
          waiters[waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel(waiterID: waiterID) }
    }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  func release() {
    while let waiterID = waiterOrder.first {
      waiterOrder.removeFirst()
      if let continuation = waiters.removeValue(forKey: waiterID) {
        continuation.resume()
        return
      }
    }
    availablePermits = min(availablePermits + 1, limit)
  }

  private func cancel(waiterID: UUID) {
    guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
    waiterOrder.removeAll { $0 == waiterID }
    continuation.resume(throwing: CancellationError())
  }
}

final class RemoteImageIODecodeScheduler: @unchecked Sendable {
  static let shared = RemoteImageIODecodeScheduler(maxConcurrentDecodes: 2)

  private let permits: RemoteImageDecodePermitPool

  init(maxConcurrentDecodes: Int) {
    permits = RemoteImageDecodePermitPool(limit: maxConcurrentDecodes)
  }

  func decode<Value: Sendable>(
    priority: TaskPriority = .utility,
    operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await permits.acquire()

    let decodeTask = Task.detached(priority: priority) {
      try Task.checkCancellation()
      let value = try operation()
      try Task.checkCancellation()
      return value
    }

    let value: Value
    do {
      value = try await withTaskCancellationHandler {
        try await decodeTask.value
      } onCancel: {
        decodeTask.cancel()
      }
    } catch {
      await permits.release()
      throw error
    }
    await permits.release()
    try Task.checkCancellation()
    return value
  }
}

private enum RemoteImageAnimationFrameLoader {
  static func frame(
    at index: Int,
    in animation: RemoteImageAnimationSequence
  ) async throws -> RemoteImageDecodedFrame {
    try Task.checkCancellation()
    let key = RemoteImageAnimationFrameCacheKey(
      sequenceID: animation.id,
      frameIndex: index
    )
    let (cachedFrame, cacheGeneration) =
      RemoteImageAnimationFrameCache.shared.cachedFrameAndGeneration(for: key)
    if let cachedFrame {
      try Task.checkCancellation()
      return cachedFrame
    }

    let source = animation.source
    let maxPixelSize = animation.maxPixelSize
    let frame = try await RemoteImageIODecodeScheduler.shared.decode {
      try source.withFileURL { fileURL in
        let image = try ImageDownsampler.frame(
          at: fileURL,
          index: index,
          maxPixelSize: maxPixelSize
        )
        guard
          let decodedByteCost = ImageDownsampler.decodedByteCost(of: image),
          decodedByteCost <= ImageDownsampler.maximumAnimationFrameDecodedByteCost
        else {
          throw DownsampledImageError.unreadableImage
        }
        return RemoteImageDecodedFrame(
          image: image,
          decodedByteCost: decodedByteCost
        )
      }
    }
    try Task.checkCancellation()
    let didInsert = RemoteImageAnimationFrameCache.shared.insert(
      frame,
      for: key,
      generation: cacheGeneration
    )
    do {
      try Task.checkCancellation()
    } catch {
      if didInsert {
        RemoteImageAnimationFrameCache.shared.remove(
          frame,
          for: key,
          generation: cacheGeneration
        )
      }
      throw error
    }
    return frame
  }
}

struct RemoteImageAnimationPlaybackRequest: Equatable, Sendable {
  let frameIndex: Int
  let generation: UInt64
}

struct RemoteImageAnimationPlaybackState: Equatable, Sendable {
  private(set) var generation: UInt64
  private(set) var currentFrameIndex = 0
  private(set) var completedPlaythroughs = 0
  private(set) var pendingFrameIndex: Int?
  private(set) var failedFrameIndex: Int?
  private(set) var isFinished = false

  init(generation: UInt64 = 0) {
    self.generation = generation
  }

  mutating func requestNextFrame(
    frameCount: Int,
    totalPlaythroughs: Int
  ) -> RemoteImageAnimationPlaybackRequest? {
    guard
      frameCount > 1,
      pendingFrameIndex == nil,
      failedFrameIndex == nil,
      !isFinished
    else { return nil }

    if currentFrameIndex == frameCount - 1 {
      let completedAfterCurrentFrame = completedPlaythroughs + 1
      if totalPlaythroughs > 0, completedAfterCurrentFrame >= totalPlaythroughs {
        completedPlaythroughs = completedAfterCurrentFrame
        isFinished = true
        return nil
      }
      pendingFrameIndex = 0
    } else {
      pendingFrameIndex = currentFrameIndex + 1
    }
    return RemoteImageAnimationPlaybackRequest(
      frameIndex: pendingFrameIndex ?? 0,
      generation: generation
    )
  }

  mutating func publish(_ request: RemoteImageAnimationPlaybackRequest) -> Bool {
    guard
      request.generation == generation,
      request.frameIndex == pendingFrameIndex
    else { return false }
    if request.frameIndex == 0 {
      completedPlaythroughs += 1
    }
    currentFrameIndex = request.frameIndex
    pendingFrameIndex = nil
    return true
  }

  mutating func fail(_ request: RemoteImageAnimationPlaybackRequest) -> Bool {
    guard
      request.generation == generation,
      request.frameIndex == pendingFrameIndex
    else { return false }
    pendingFrameIndex = nil
    failedFrameIndex = request.frameIndex
    return true
  }

  mutating func cancelPending(newGeneration: UInt64) {
    generation = newGeneration
    pendingFrameIndex = nil
  }

  mutating func reset(newGeneration: UInt64) {
    self = RemoteImageAnimationPlaybackState(generation: newGeneration)
  }
}

struct RemoteImageAnimationPlaybackClock: Equatable, Sendable {
  static let maximumElapsedTimePerTick: TimeInterval = 0.25

  private(set) var previousTimestamp: TimeInterval?
  private(set) var elapsedFrameTime: TimeInterval = 0

  mutating func frameIsDue(
    timestamp: TimeInterval,
    frameDuration: TimeInterval,
    isWaitingForFrame: Bool
  ) -> Bool {
    guard timestamp.isFinite, frameDuration.isFinite, frameDuration > 0 else {
      pause()
      return false
    }
    guard let previousTimestamp else {
      self.previousTimestamp = timestamp
      return false
    }
    self.previousTimestamp = timestamp
    guard !isWaitingForFrame else {
      elapsedFrameTime = 0
      return false
    }
    let elapsed = timestamp - previousTimestamp
    guard elapsed.isFinite, elapsed > 0 else { return false }
    elapsedFrameTime += min(elapsed, Self.maximumElapsedTimePerTick)
    guard elapsedFrameTime >= frameDuration else { return false }
    elapsedFrameTime = 0
    self.previousTimestamp = nil
    return true
  }

  mutating func pause() {
    previousTimestamp = nil
  }

  mutating func didPublishFrame() {
    previousTimestamp = nil
    elapsedFrameTime = 0
  }

  mutating func reset() {
    previousTimestamp = nil
    elapsedFrameTime = 0
  }
}

struct RemoteImageAssetView: View {
  let asset: DownsampledImageAsset
  let contentMode: SwiftUI.ContentMode
  let animationPlaybackEnabled: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var isPresented = false

  init(
    asset: DownsampledImageAsset,
    contentMode: SwiftUI.ContentMode,
    animationPlaybackEnabled: Bool = true
  ) {
    self.asset = asset
    self.contentMode = contentMode
    self.animationPlaybackEnabled = animationPlaybackEnabled
  }

  var body: some View {
    Group {
      if let animation = asset.animation {
        AnimatedRemoteImageRepresentable(
          animation: animation,
          contentMode: contentMode,
          playbackEnabled: animationPlaybackEnabled
            && isPresented
            && scenePhase == .active
            && !reduceMotion,
          showsPosterWhenStopped: reduceMotion || !animationPlaybackEnabled
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Image(uiImage: asset.image)
          .resizable()
          .aspectRatio(contentMode: contentMode)
      }
    }
    .onAppear { isPresented = true }
    .onDisappear { isPresented = false }
  }
}

@MainActor
private struct AnimatedRemoteImageRepresentable: UIViewRepresentable {
  let animation: RemoteImageAnimationSequence
  let contentMode: SwiftUI.ContentMode
  let playbackEnabled: Bool
  let showsPosterWhenStopped: Bool

  func makeUIView(context: Context) -> RemoteImageAnimationImageView {
    RemoteImageAnimationImageView()
  }

  func updateUIView(_ imageView: RemoteImageAnimationImageView, context: Context) {
    imageView.configure(
      animation: animation,
      contentMode: contentMode,
      playbackEnabled: playbackEnabled,
      showsPosterWhenStopped: showsPosterWhenStopped
    )
  }

  static func dismantleUIView(
    _ imageView: RemoteImageAnimationImageView,
    coordinator: Void
  ) {
    imageView.stopPlayback(showsPoster: false)
  }
}

@MainActor
final class RemoteImageAnimationImageView: UIImageView {
  private var animationSequence: RemoteImageAnimationSequence?
  private var displayLink: CADisplayLink?
  private var pendingFrameTask: Task<Void, Never>?
  private var playbackGeneration: UInt64 = 0
  private var playbackState = RemoteImageAnimationPlaybackState()
  private var playbackClock = RemoteImageAnimationPlaybackClock()
  private var playbackEnabled = false
  private var showsPosterWhenStopped = false

  init() {
    super.init(frame: .zero)
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updatePlaybackState()
  }

  func configure(
    animation: RemoteImageAnimationSequence,
    contentMode: SwiftUI.ContentMode,
    playbackEnabled: Bool,
    showsPosterWhenStopped: Bool
  ) {
    self.contentMode = contentMode.uiViewContentMode
    if animationSequence?.id != animation.id {
      stopDisplayLinkAndPendingFrame()
      animationSequence = animation
      resetToPoster(clearsTerminalFailure: true)
    }

    self.playbackEnabled = playbackEnabled
    self.showsPosterWhenStopped = showsPosterWhenStopped
    if showsPosterWhenStopped {
      resetToPoster(clearsTerminalFailure: false)
    }
    updatePlaybackState()
  }

  func stopPlayback(showsPoster: Bool) {
    playbackEnabled = false
    showsPosterWhenStopped = showsPoster
    stopDisplayLinkAndPendingFrame()
    if showsPoster {
      resetToPoster(clearsTerminalFailure: false)
    }
  }

  @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
    guard
      self.displayLink === displayLink,
      playbackEnabled,
      window != nil,
      let animationSequence,
      playbackState.failedFrameIndex == nil,
      !playbackState.isFinished
    else {
      updatePlaybackState()
      return
    }

    let currentFrameIndex = playbackState.currentFrameIndex
    guard animationSequence.frameDurations.indices.contains(currentFrameIndex) else {
      stopDisplayLinkAndPendingFrame()
      return
    }
    guard playbackClock.frameIsDue(
      timestamp: displayLink.timestamp,
      frameDuration: animationSequence.frameDurations[currentFrameIndex],
      isWaitingForFrame: pendingFrameTask != nil
    ) else { return }

    guard let request = playbackState.requestNextFrame(
      frameCount: animationSequence.frameCount,
      totalPlaythroughs: animationSequence.totalPlaythroughs
    ) else {
      if playbackState.isFinished {
        stopDisplayLinkAndPendingFrame()
      }
      return
    }
    requestFrame(request, from: animationSequence)
  }

  private func requestFrame(
    _ request: RemoteImageAnimationPlaybackRequest,
    from animation: RemoteImageAnimationSequence
  ) {
    guard pendingFrameTask == nil else { return }
    pendingFrameTask = Task { [weak self] in
      do {
        let frame = try await animation.decodedFrame(at: request.frameIndex)
        try Task.checkCancellation()
        self?.publish(frame.image, for: request)
      } catch is CancellationError {
        // Cancellation is a lifecycle event; a later generation may resume playback.
      } catch {
        self?.freezeAfterFrameFailure(request)
      }
    }
  }

  private func publish(_ frame: UIImage, for request: RemoteImageAnimationPlaybackRequest) {
    guard playbackState.publish(request) else { return }
    pendingFrameTask = nil
    image = frame
    playbackClock.didPublishFrame()
  }

  private func freezeAfterFrameFailure(_ request: RemoteImageAnimationPlaybackRequest) {
    guard playbackState.fail(request) else { return }
    pendingFrameTask = nil
    displayLink?.invalidate()
    displayLink = nil
    playbackClock.pause()
  }

  private func updatePlaybackState() {
    guard
      playbackEnabled,
      window != nil,
      let animationSequence,
      animationSequence.frameCount > 1,
      playbackState.failedFrameIndex == nil,
      !playbackState.isFinished
    else {
      stopDisplayLinkAndPendingFrame()
      if showsPosterWhenStopped {
        resetToPoster(clearsTerminalFailure: false)
      }
      return
    }
    guard displayLink == nil else { return }
    playbackClock.pause()
    let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
    displayLink.add(to: .main, forMode: .common)
    self.displayLink = displayLink
  }

  private func stopDisplayLinkAndPendingFrame() {
    displayLink?.invalidate()
    displayLink = nil
    pendingFrameTask?.cancel()
    pendingFrameTask = nil
    playbackGeneration &+= 1
    playbackState.cancelPending(newGeneration: playbackGeneration)
    playbackClock.pause()
  }

  private func resetToPoster(clearsTerminalFailure: Bool) {
    guard let animationSequence else { return }
    pendingFrameTask?.cancel()
    pendingFrameTask = nil
    playbackGeneration &+= 1
    if clearsTerminalFailure || playbackState.failedFrameIndex == nil {
      playbackState.reset(newGeneration: playbackGeneration)
    } else {
      playbackState.cancelPending(newGeneration: playbackGeneration)
    }
    playbackClock.reset()
    image = animationSequence.poster
  }
}

private extension SwiftUI.ContentMode {
  var uiViewContentMode: UIView.ContentMode {
    switch self {
    case .fit:
      .scaleAspectFit
    case .fill:
      .scaleAspectFill
    }
  }
}
