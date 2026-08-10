import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AnimatedRemoteImageTests: XCTestCase {
  func testPlaybackStateAdvancesOneDecodedFrameAtATime() throws {
    var state = RemoteImageAnimationPlaybackState(generation: 7)

    let secondFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 3, totalPlaythroughs: 0)
    )
    XCTAssertEqual(secondFrame, .init(frameIndex: 1, generation: 7))
    XCTAssertNil(state.requestNextFrame(frameCount: 3, totalPlaythroughs: 0))
    XCTAssertTrue(state.publish(secondFrame))
    XCTAssertEqual(state.currentFrameIndex, 1)

    let thirdFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 3, totalPlaythroughs: 0)
    )
    XCTAssertEqual(thirdFrame.frameIndex, 2)
    XCTAssertTrue(state.publish(thirdFrame))

    let firstFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 3, totalPlaythroughs: 0)
    )
    XCTAssertEqual(firstFrame.frameIndex, 0)
    XCTAssertTrue(state.publish(firstFrame))
    XCTAssertEqual(state.currentFrameIndex, 0)
    XCTAssertEqual(state.completedPlaythroughs, 1)
  }

  func testFinitePlaybackStopsAfterLastFrameDuration() throws {
    var state = RemoteImageAnimationPlaybackState()
    let lastFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 1)
    )
    XCTAssertTrue(state.publish(lastFrame))

    XCTAssertNil(state.requestNextFrame(frameCount: 2, totalPlaythroughs: 1))
    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.currentFrameIndex, 1)
    XCTAssertEqual(state.completedPlaythroughs, 1)
  }

  func testFinitePlaybackCanBeginAnotherPlaythroughBeforeStopping() throws {
    var state = RemoteImageAnimationPlaybackState()
    let firstLastFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 2)
    )
    XCTAssertTrue(state.publish(firstLastFrame))
    let secondPoster = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 2)
    )
    XCTAssertEqual(secondPoster.frameIndex, 0)
    XCTAssertTrue(state.publish(secondPoster))
    XCTAssertEqual(state.completedPlaythroughs, 1)

    let secondLastFrame = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 2)
    )
    XCTAssertTrue(state.publish(secondLastFrame))
    XCTAssertNil(state.requestNextFrame(frameCount: 2, totalPlaythroughs: 2))
    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.completedPlaythroughs, 2)
  }

  func testPauseAndSlowDecodeDoNotCreateCatchUpFrames() {
    var clock = RemoteImageAnimationPlaybackClock()
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 1, frameDuration: 0.1, isWaitingForFrame: false)
    )
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 1.05, frameDuration: 0.1, isWaitingForFrame: false)
    )

    clock.pause()
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 100, frameDuration: 0.1, isWaitingForFrame: false)
    )
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 100.04, frameDuration: 0.1, isWaitingForFrame: false)
    )
    XCTAssertTrue(
      clock.frameIsDue(timestamp: 100.06, frameDuration: 0.1, isWaitingForFrame: false)
    )

    XCTAssertFalse(
      clock.frameIsDue(timestamp: 200, frameDuration: 0.1, isWaitingForFrame: true)
    )
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 300, frameDuration: 0.1, isWaitingForFrame: true)
    )
    clock.didPublishFrame()
    XCTAssertFalse(
      clock.frameIsDue(timestamp: 400, frameDuration: 0.1, isWaitingForFrame: false)
    )
  }

  func testGenerationRejectsLatePublicationAndFailureIsTerminalUntilReset() throws {
    var state = RemoteImageAnimationPlaybackState(generation: 1)
    let staleRequest = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 0)
    )

    state.cancelPending(newGeneration: 2)
    XCTAssertFalse(state.publish(staleRequest))
    XCTAssertEqual(state.currentFrameIndex, 0)

    let failingRequest = try XCTUnwrap(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 0)
    )
    XCTAssertTrue(state.fail(failingRequest))
    state.cancelPending(newGeneration: 3)
    XCTAssertEqual(state.failedFrameIndex, 1)
    XCTAssertNil(state.requestNextFrame(frameCount: 2, totalPlaythroughs: 0))

    state.reset(newGeneration: 4)
    XCTAssertNil(state.failedFrameIndex)
    XCTAssertEqual(
      state.requestNextFrame(frameCount: 2, totalPlaythroughs: 0),
      RemoteImageAnimationPlaybackRequest(frameIndex: 1, generation: 4)
    )
  }

  func testFrameCacheUsesExactCostAndRejectsLateInsertionAfterClear() throws {
    let cache = RemoteImageAnimationFrameCache(
      totalCostLimit: 1_024 * 1_024,
      countLimit: 17
    )
    XCTAssertEqual(cache.totalCostLimit, 1_024 * 1_024)
    XCTAssertEqual(cache.countLimit, 17)
    let key = RemoteImageAnimationFrameCacheKey(sequenceID: UUID(), frameIndex: 1)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 13, height: 7)).image {
      context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 13, height: 7))
    }
    let cost = try XCTUnwrap(ImageDownsampler.decodedByteCost(of: image))
    let frame = RemoteImageDecodedFrame(image: image, decodedByteCost: cost)
    let (_, generation) = cache.cachedFrameAndGeneration(for: key)

    XCTAssertTrue(cache.insert(frame, for: key, generation: generation))
    let (cached, _) = cache.cachedFrameAndGeneration(for: key)
    XCTAssertTrue(cached === frame)
    let cgImage = try XCTUnwrap(image.cgImage)
    XCTAssertEqual(cached?.decodedByteCost, cgImage.bytesPerRow * cgImage.height)

    cache.removeAllObjects()
    let (cleared, newGeneration) = cache.cachedFrameAndGeneration(for: key)
    XCTAssertNil(cleared)
    XCTAssertNotEqual(newGeneration, generation)
    XCTAssertFalse(cache.insert(frame, for: key, generation: generation))
  }

  func testDecodeSchedulerLimitsConcurrencyAndCancelsQueuedWork() async throws {
    let scheduler = RemoteImageIODecodeScheduler(maxConcurrentDecodes: 2)
    let probe = DecodeConcurrencyProbe()
    let first = Task.detached {
      try await scheduler.decode { try probe.run(value: 1) }
    }
    let second = Task.detached {
      try await scheduler.decode { try probe.run(value: 2) }
    }
    defer {
      first.cancel()
      second.cancel()
      probe.releaseAll()
    }
    let didEnterTwoDecodes = await probe.waitUntilEntered(2)
    XCTAssertTrue(didEnterTwoDecodes)

    let queued = Task.detached {
      try await scheduler.decode { try probe.run(value: 3) }
    }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(probe.enteredCount, 2)
    XCTAssertEqual(probe.peakActiveCount, 2)

    queued.cancel()
    switch await queued.result {
    case .success:
      XCTFail("Cancelled queued decode must not run")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }

    probe.releaseAll()
    let firstValue = try await first.value
    let secondValue = try await second.value
    let fourthValue = try await scheduler.decode { try probe.run(value: 4) }
    XCTAssertEqual(firstValue, 1)
    XCTAssertEqual(secondValue, 2)
    XCTAssertEqual(fourthValue, 4)
    XCTAssertEqual(probe.peakActiveCount, 2)
  }

  func testDecodeSchedulerCancelsActiveDetachedWork() async throws {
    let scheduler = RemoteImageIODecodeScheduler(maxConcurrentDecodes: 1)
    let probe = DecodeConcurrencyProbe()
    let request = Task.detached {
      try await scheduler.decode { try probe.run(value: 1) }
    }
    defer {
      request.cancel()
      probe.releaseAll()
    }
    let didEnterDecode = await probe.waitUntilEntered(1)
    XCTAssertTrue(didEnterDecode)

    request.cancel()
    switch await request.result {
    case .success:
      XCTFail("Cancelled active decode must not succeed")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    let didExitDecode = await probe.waitUntilActiveCount(0)
    XCTAssertTrue(didExitDecode)

    probe.releaseAll()
    let nextValue = try await scheduler.decode { try probe.run(value: 2) }
    XCTAssertEqual(nextValue, 2)
  }
}

private final class DecodeConcurrencyProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private var activeCount = 0
  private var peakCount = 0
  private var totalEntered = 0
  private var isReleased = false

  var enteredCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return totalEntered
  }

  var peakActiveCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return peakCount
  }

  func run(value: Int) throws -> Int {
    condition.lock()
    activeCount += 1
    totalEntered += 1
    peakCount = max(peakCount, activeCount)
    condition.broadcast()
    while !isReleased, !Task.isCancelled {
      _ = condition.wait(until: Date(timeIntervalSinceNow: 0.005))
    }
    activeCount -= 1
    condition.broadcast()
    condition.unlock()
    try Task.checkCancellation()
    return value
  }

  func releaseAll() {
    condition.lock()
    isReleased = true
    condition.broadcast()
    condition.unlock()
  }

  func waitUntilEntered(
    _ expectedCount: Int,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    await waitUntil(timeout: timeout) { self.enteredCount >= expectedCount }
  }

  func waitUntilActiveCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    await waitUntil(timeout: timeout) {
      self.currentActiveCount == expectedCount
    }
  }

  private var currentActiveCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return activeCount
  }

  private func waitUntil(
    timeout: Duration,
    condition predicate: @escaping @Sendable () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate(), clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return predicate()
  }
}
