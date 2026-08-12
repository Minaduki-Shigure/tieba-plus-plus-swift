import AVFoundation
import AVKit
import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class VideoPlaybackTests: XCTestCase {
  func testVideoPresentationPrefersValidPlaybackThenFallsBackToPage() throws {
    let streamURL = try XCTUnwrap(URL(string: "https://video.example/movie.mp4"))
    let pageURL = try XCTUnwrap(URL(string: "https://video.example/watch/42"))
    let playable = BrowseVideoContent(
      url: streamURL,
      cover: nil,
      width: 1_280,
      height: 720,
      pageURL: pageURL
    )

    XCTAssertEqual(
      BrowseVideoPresentationPolicy.primaryAction(for: playable),
      .play(streamURL)
    )

    let invalidStream = BrowseVideoContent(
      url: try XCTUnwrap(URL(string: "http://video.example/movie.mp4")),
      cover: nil,
      width: 0,
      height: 0,
      pageURL: pageURL
    )
    XCTAssertEqual(
      BrowseVideoPresentationPolicy.primaryAction(for: invalidStream),
      .openPage(pageURL)
    )

    let pageOnly = BrowseVideoContent(
      url: nil,
      cover: nil,
      width: 0,
      height: 0,
      pageURL: pageURL
    )
    XCTAssertEqual(
      BrowseVideoPresentationPolicy.primaryAction(for: pageOnly),
      .openPage(pageURL)
    )
  }

  func testVideoPresentationNeverUsesUnsafePageOrStream() throws {
    let invalid = BrowseVideoContent(
      url: try XCTUnwrap(URL(string: "https://user@video.example/movie.mp4")),
      cover: nil,
      width: 0,
      height: 0,
      pageURL: try XCTUnwrap(URL(string: "javascript:alert(1)"))
    )

    XCTAssertNil(BrowseVideoPresentationPolicy.playbackURL(for: invalid))
    XCTAssertNil(BrowseVideoPresentationPolicy.pageURL(for: invalid))
    XCTAssertEqual(
      BrowseVideoPresentationPolicy.primaryAction(for: invalid),
      .unavailable
    )
  }

  func testVideoFailureOffersPageOnlyAfterAPlayableStreamFails() throws {
    let streamURL = try XCTUnwrap(URL(string: "https://video.example/movie.mp4"))
    let pageURL = try XCTUnwrap(URL(string: "https://video.example/watch/42"))
    let video = BrowseVideoContent(
      url: streamURL,
      cover: nil,
      width: 1_280,
      height: 720,
      pageURL: pageURL
    )

    XCTAssertFalse(
      BrowseVideoPresentationPolicy.showsFailurePageAction(for: video, state: .idle)
    )
    XCTAssertFalse(
      BrowseVideoPresentationPolicy.showsFailurePageAction(for: video, state: .loading)
    )
    XCTAssertTrue(
      BrowseVideoPresentationPolicy.showsFailurePageAction(
        for: video,
        state: .failed("视频加载失败。")
      )
    )

    let pageOnly = BrowseVideoContent(
      url: nil,
      cover: nil,
      width: 0,
      height: 0,
      pageURL: pageURL
    )
    XCTAssertFalse(
      BrowseVideoPresentationPolicy.showsFailurePageAction(
        for: pageOnly,
        state: .failed("不应出现")
      )
    )
  }

  func testURLPolicyAllowsOnlyCredentialFreeHTTPSWithoutFragments() throws {
    XCTAssertTrue(
      VideoPlaybackURLPolicy.allows(
        try XCTUnwrap(URL(string: "https://video.example/path/movie.mp4?token=value"))
      )
    )

    let rejected = [
      "http://video.example/movie.mp4",
      "file:///tmp/movie.mp4",
      "data:video/mp4;base64,AAAA",
      "https://user@video.example/movie.mp4",
      "https://user:password@video.example/movie.mp4",
      "https://video.example:443/movie.mp4",
      "https:///movie.mp4",
      "https://video.example/movie.mp4#fragment",
    ]
    for rawValue in rejected {
      XCTAssertFalse(
        VideoPlaybackURLPolicy.allows(try XCTUnwrap(URL(string: rawValue))),
        rawValue
      )
    }

    let oversizedURL = try XCTUnwrap(
      URL(string: "https://video.example/\(String(repeating: "a", count: 8_192))")
    )
    XCTAssertFalse(VideoPlaybackURLPolicy.allows(oversizedURL))
  }

  func testAVPlayerEngineRemainsLazyUntilTheFirstValidLoadAndReusesItsPlayer() throws {
    var factoryCallCount = 0
    let engine = AVPlayerVideoPlaybackEngine {
      factoryCallCount += 1
      return AVPlayer()
    }

    XCTAssertNil(engine.player)
    XCTAssertEqual(factoryCallCount, 0)
    engine.pause(deactivateAudioSession: false)
    engine.reset(deactivateAudioSession: false)
    XCTAssertNil(engine.player)
    XCTAssertEqual(factoryCallCount, 0)

    engine.load(url: try videoURL("first"), sessionID: UUID())
    let firstPlayer = try XCTUnwrap(engine.player)
    XCTAssertEqual(factoryCallCount, 1)
    engine.reset(deactivateAudioSession: false)
    engine.load(url: try videoURL("second"), sessionID: UUID())
    XCTAssertTrue(engine.player === firstPlayer)
    XCTAssertEqual(factoryCallCount, 1)
  }

  func testPlaybackIntentDoesNotReviveARevokedUnknownItem() {
    var intent = VideoPlaybackIntentTracker()

    intent.requestPlay()
    XCTAssertEqual(intent.state(for: .paused, itemIsReady: false), .loading)
    XCTAssertEqual(
      intent.state(for: .waitingToPlayAtSpecifiedRate, itemIsReady: false),
      .loading
    )
    XCTAssertEqual(intent.state(for: .paused, itemIsReady: false), .paused)

    intent.requestPlay()
    intent.stop()
    XCTAssertEqual(intent.state(for: .paused, itemIsReady: false), .paused)
    XCTAssertFalse(intent.isPlaybackRequested)
  }

  func testStartingASecondOwnerReplacesTheSingleSessionAndRejectsStaleEvents() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let firstOwnerID = UUID()
    let secondOwnerID = UUID()
    let firstURL = try videoURL("first")
    let secondURL = try videoURL("second")

    XCTAssertTrue(controller.start(ownerID: firstOwnerID, url: firstURL))
    let firstSessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(.snapshot(sessionID: firstSessionID, state: .playing))
    XCTAssertEqual(controller.snapshot.state, .playing)

    XCTAssertTrue(controller.start(ownerID: secondOwnerID, url: secondURL))
    let secondSessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    XCTAssertNotEqual(secondSessionID, firstSessionID)
    XCTAssertEqual(controller.snapshot.ownerID, secondOwnerID)
    XCTAssertEqual(controller.snapshot.sourceURL, secondURL)
    XCTAssertEqual(controller.snapshot.state, .loading)
    XCTAssertEqual(engine.loadedSessions.map(\.url), [firstURL, secondURL])
    XCTAssertEqual(engine.playCount, 2)
    XCTAssertEqual(engine.pauseAudioDeactivation, [false])
    XCTAssertEqual(engine.resetAudioDeactivation, [false, false])

    engine.send(.failed(sessionID: firstSessionID, message: "stale"))
    engine.send(.ended(sessionID: firstSessionID))
    XCTAssertEqual(controller.snapshot.ownerID, secondOwnerID)
    XCTAssertEqual(controller.snapshot.state, .loading)
    XCTAssertNil(controller.player(for: firstOwnerID, url: firstURL))
    XCTAssertTrue(controller.player(for: secondOwnerID, url: secondURL) === engine.player)
  }

  func testNativePauseReleasesTheLeaseAndNativePlayReacquiresIt() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()
    let url = try videoURL("native-controls")

    XCTAssertTrue(controller.start(ownerID: ownerID, url: url))
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(.snapshot(sessionID: sessionID, state: .playing))
    engine.send(.snapshot(sessionID: sessionID, state: .paused))
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseAudioDeactivation, [true])

    let voiceParticipant = VideoMediaParticipantSpy()
    let voiceLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: voiceParticipant
      )
    )
    engine.send(.snapshot(sessionID: sessionID, state: .playing))

    XCTAssertFalse(coordinator.isCurrent(voiceLease))
    XCTAssertEqual(voiceParticipant.revocationReasons, [.superseded(by: .video)])
    XCTAssertEqual(controller.snapshot.state, .playing)
    XCTAssertEqual(engine.playCount, 2)
  }

  func testSceneInactivityPausesWithoutAutomaticResumeAndRejectsNativePlay() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("scene")))
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(.snapshot(sessionID: sessionID, state: .playing))

    coordinator.setSceneActive(false)
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseAudioDeactivation, [true])

    coordinator.setSceneActive(true)
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.playCount, 1)

    coordinator.setSceneActive(false)
    engine.send(.snapshot(sessionID: sessionID, state: .playing))
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseAudioDeactivation, [true, true])
  }

  func testInvalidSourceDoesNotRevokeAnotherMediaParticipantOrCreateAPlayer() throws {
    let coordinator = MediaPlaybackCoordinator()
    let voiceParticipant = VideoMediaParticipantSpy()
    let voiceLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: voiceParticipant
      )
    )
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let invalidURL = try XCTUnwrap(URL(string: "http://video.example/movie.mp4"))

    XCTAssertFalse(controller.start(ownerID: UUID(), url: invalidURL))

    XCTAssertTrue(coordinator.isCurrent(voiceLease))
    XCTAssertTrue(voiceParticipant.revocationReasons.isEmpty)
    XCTAssertTrue(engine.loadedSessions.isEmpty)
    XCTAssertEqual(controller.snapshot.state, .failed("视频地址不可用。"))
    XCTAssertEqual(engine.resetAudioDeactivation, [false])
  }

  func testOnlyTheActiveOwnerCanStopOrReactToASourceChange() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()
    let otherOwnerID = UUID()
    let url = try videoURL("ownership")

    XCTAssertTrue(controller.start(ownerID: ownerID, url: url))
    controller.ownerDidDisappear(otherOwnerID)
    controller.sourceDidChange(ownerID: otherOwnerID, to: try videoURL("other"))
    XCTAssertEqual(controller.snapshot.ownerID, ownerID)
    XCTAssertEqual(engine.resetAudioDeactivation, [false])

    controller.sourceDidChange(ownerID: ownerID, to: try videoURL("replacement"))
    XCTAssertEqual(controller.snapshot, .idle)
    XCTAssertEqual(engine.resetAudioDeactivation, [false, true])
  }

  func testFullScreenOwnerDisappearanceDefersResetUntilExitCompletes() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("fullscreen")))
    let sessionID = try XCTUnwrap(controller.snapshot.sessionID)
    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    XCTAssertEqual(controller.fullScreenState, .enteringFullScreen)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    XCTAssertEqual(controller.fullScreenState, .fullScreen)

    controller.ownerDidDisappear(ownerID)
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(controller.fullScreenState, .fullScreen)
    XCTAssertEqual(engine.resetAudioDeactivation, [false])

    controller.fullScreenPresentationWillEnd(ownerID: ownerID, sessionID: sessionID)
    XCTAssertEqual(controller.fullScreenState, .exitingFullScreen)
    controller.fullScreenPresentationDidFinishEnding(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    XCTAssertEqual(controller.fullScreenState, .inline)
    XCTAssertEqual(controller.snapshot, .idle)
    XCTAssertEqual(engine.resetAudioDeactivation, [false, false])
  }

  func testPendingFullScreenStopRejectsNativeReplayWithoutAffectingReplacementMedia() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("pending-replay")))
    let sessionID = try XCTUnwrap(controller.snapshot.sessionID)
    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    controller.ownerDidDisappear(ownerID)

    let voiceParticipant = VideoMediaParticipantSpy()
    let voiceLease = try XCTUnwrap(
      coordinator.acquire(kind: .voice, ownerID: UUID(), participant: voiceParticipant)
    )
    engine.send(.snapshot(sessionID: sessionID, state: .playing))

    XCTAssertTrue(coordinator.isCurrent(voiceLease))
    XCTAssertTrue(voiceParticipant.revocationReasons.isEmpty)
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseAudioDeactivation, [true, false])
  }

  func testCancelledFullScreenTransitionsPreserveCorrectStateAndPendingStop() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("cancel")))
    let sessionID = try XCTUnwrap(controller.snapshot.sessionID)
    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: true
    )
    XCTAssertEqual(controller.fullScreenState, .inline)

    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    controller.ownerDidDisappear(ownerID)
    controller.fullScreenPresentationWillEnd(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishEnding(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: true
    )
    XCTAssertEqual(controller.fullScreenState, .fullScreen)
    XCTAssertNotEqual(controller.snapshot, .idle)

    controller.fullScreenPresentationWillEnd(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishEnding(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    XCTAssertEqual(controller.snapshot, .idle)
    XCTAssertEqual(controller.fullScreenState, .inline)
  }

  func testDelegateLifetimeFallbackCompletesPendingFullScreenStop() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("delegate-stop")))
    let sessionID = try XCTUnwrap(controller.snapshot.sessionID)
    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    controller.ownerDidDisappear(ownerID)

    controller.playerViewDelegateLifetimeDidEnd(ownerID: ownerID, sessionID: sessionID)

    XCTAssertEqual(controller.fullScreenState, .inline)
    XCTAssertEqual(controller.snapshot, .idle)
  }

  func testDelegateLifetimeFallbackNormalizesFullScreenFailureWithoutPendingStop() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("delegate-failure")))
    let sessionID = try XCTUnwrap(controller.snapshot.sessionID)
    controller.fullScreenPresentationWillBegin(ownerID: ownerID, sessionID: sessionID)
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: ownerID,
      sessionID: sessionID,
      cancelled: false
    )
    engine.send(.failed(sessionID: sessionID, message: "failure"))

    controller.playerViewDelegateLifetimeDidEnd(ownerID: ownerID, sessionID: sessionID)

    XCTAssertEqual(controller.fullScreenState, .inline)
    XCTAssertEqual(controller.snapshot.state, .failed("视频加载失败。"))
  }

  func testPlayerViewControllerRetainsItsWeakAVKitDelegate() {
    let controller = VideoPlaybackController(
      coordinator: MediaPlaybackCoordinator(),
      engine: VideoPlaybackEngineSpy()
    )
    var delegate: InlineVideoPlayer.Coordinator? = .init(
      controller: controller,
      ownerID: UUID(),
      sessionID: UUID()
    )
    weak var weakDelegate = delegate
    let viewController = AVPlayerViewController()

    AVPlayerViewControllerDelegateRetention.retain(delegate, on: viewController)
    delegate = nil
    XCTAssertNotNil(weakDelegate)

    AVPlayerViewControllerDelegateRetention.retain(nil, on: viewController)
    XCTAssertNil(weakDelegate)
  }

  func testOldFullScreenCallbacksAndTerminalEventsCannotAffectReplacement() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let firstOwnerID = UUID()
    let secondOwnerID = UUID()

    XCTAssertTrue(controller.start(ownerID: firstOwnerID, url: try videoURL("old")))
    let firstSessionID = try XCTUnwrap(controller.snapshot.sessionID)
    XCTAssertTrue(controller.start(ownerID: secondOwnerID, url: try videoURL("new")))
    let secondSessionID = try XCTUnwrap(controller.snapshot.sessionID)

    controller.fullScreenPresentationWillBegin(
      ownerID: firstOwnerID,
      sessionID: firstSessionID
    )
    controller.fullScreenPresentationDidFinishBeginning(
      ownerID: firstOwnerID,
      sessionID: firstSessionID,
      cancelled: false
    )
    engine.send(.failed(sessionID: firstSessionID, message: "stale"))
    engine.send(.ended(sessionID: firstSessionID))

    XCTAssertEqual(controller.fullScreenState, .inline)
    XCTAssertEqual(controller.snapshot.ownerID, secondOwnerID)
    XCTAssertEqual(controller.snapshot.sessionID, secondSessionID)
    XCTAssertEqual(controller.snapshot.state, .loading)
  }

  func testTerminalEventAfterVoiceSupersedesVideoCannotDeactivateVoiceAudio() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)

    XCTAssertTrue(controller.start(ownerID: UUID(), url: try videoURL("superseded")))
    let videoSessionID = try XCTUnwrap(controller.snapshot.sessionID)
    let voiceParticipant = VideoMediaParticipantSpy()
    let voiceLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: voiceParticipant
      )
    )
    XCTAssertEqual(engine.pauseAudioDeactivation, [false])

    engine.send(.ended(sessionID: videoSessionID))

    XCTAssertTrue(coordinator.isCurrent(voiceLease))
    XCTAssertEqual(engine.pauseAudioDeactivation, [false, false])
  }

  func testFailureAndEndAreTerminalForLateSnapshots() throws {
    let coordinator = MediaPlaybackCoordinator()
    let engine = VideoPlaybackEngineSpy()
    let controller = VideoPlaybackController(coordinator: coordinator, engine: engine)
    let ownerID = UUID()

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("failure")))
    let failedSessionID = try XCTUnwrap(controller.snapshot.sessionID)
    engine.send(.failed(sessionID: failedSessionID, message: "transport details"))
    engine.send(.snapshot(sessionID: failedSessionID, state: .playing))
    engine.send(.ended(sessionID: failedSessionID))
    XCTAssertEqual(controller.snapshot.state, .failed("视频加载失败。"))

    XCTAssertTrue(controller.start(ownerID: ownerID, url: try videoURL("ended")))
    let endedSessionID = try XCTUnwrap(controller.snapshot.sessionID)
    engine.send(.ended(sessionID: endedSessionID))
    XCTAssertEqual(controller.snapshot.state, .paused)
    let playCountBeforeNativeReplay = engine.playCount
    engine.send(.snapshot(sessionID: endedSessionID, state: .playing))
    XCTAssertEqual(controller.snapshot.state, .playing)
    XCTAssertEqual(engine.playCount, playCountBeforeNativeReplay + 1)
  }

  private func videoURL(_ identifier: String) throws -> URL {
    try XCTUnwrap(URL(string: "https://video.example/\(identifier).mp4"))
  }
}

@MainActor
private final class VideoPlaybackEngineSpy: VideoPlaybackEngine {
  struct LoadedSession: Equatable {
    let url: URL
    let sessionID: UUID
  }

  var eventHandler: (@MainActor @Sendable (VideoPlaybackEngineEvent) -> Void)?
  let player: AVPlayer? = AVPlayer()
  private(set) var loadedSessions = [LoadedSession]()
  private(set) var playCount = 0
  private(set) var pauseAudioDeactivation = [Bool]()
  private(set) var resetAudioDeactivation = [Bool]()

  func load(url: URL, sessionID: UUID) {
    loadedSessions.append(.init(url: url, sessionID: sessionID))
  }

  func play() {
    playCount += 1
  }

  func pause(deactivateAudioSession: Bool) {
    pauseAudioDeactivation.append(deactivateAudioSession)
  }

  func reset(deactivateAudioSession: Bool) {
    resetAudioDeactivation.append(deactivateAudioSession)
  }

  func send(_ event: VideoPlaybackEngineEvent) {
    eventHandler?(event)
  }
}

@MainActor
private final class VideoMediaParticipantSpy: MediaPlaybackParticipant {
  private(set) var revocationReasons = [MediaPlaybackRevocationReason]()

  func mediaPlaybackWasRevoked(
    lease: MediaPlaybackLease,
    reason: MediaPlaybackRevocationReason
  ) {
    revocationReasons.append(reason)
  }
}
