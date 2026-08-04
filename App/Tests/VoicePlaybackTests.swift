import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class VoicePlaybackTests: XCTestCase {
  func testURLPolicyAcceptsOnlyBoundedCanonicalVoiceURLs() throws {
    XCTAssertTrue(
      VoicePlaybackURLPolicy.allows(
        try XCTUnwrap(
          URL(string: "https://tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play")
        )
      )
    )
    XCTAssertTrue(
      VoicePlaybackURLPolicy.allows(
        try XCTUnwrap(SecureTiebaURL.voice(md5: "abc&play_from=other"))
      )
    )

    let rejected = [
      "http://tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play",
      "https://user@tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play",
      "https://tiebac.baidu.com:443/c/p/voice?voice_md5=abc&play_from=pb_voice_play",
      "https://example.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play",
      "https://tiebac.baidu.com/other?voice_md5=abc&play_from=pb_voice_play",
      "https://tiebac.baidu.com/c/p/voice?voice_md5=&play_from=pb_voice_play",
      "https://tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=other",
      "https://tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play&extra=1",
      "https://tiebac.baidu.com/c/p/voice?voice_md5=abc&voice_md5=def",
      "https://tiebac.baidu.com/c/p/voice?voice_md5=abc&play_from=pb_voice_play#fragment",
    ]
    for rawValue in rejected {
      XCTAssertFalse(
        VoicePlaybackURLPolicy.allows(try XCTUnwrap(URL(string: rawValue))),
        rawValue
      )
    }

    let oversizedIdentifier = String(repeating: "a", count: 513)
    XCTAssertFalse(
      VoicePlaybackURLPolicy.allows(
        try XCTUnwrap(SecureTiebaURL.voice(md5: oversizedIdentifier))
      )
    )
  }

  func testStartingAnotherItemReplacesTheSingleSessionAndRejectsStaleEvents() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let firstItemID = UUID()
    let secondItemID = UUID()
    let firstURL = try voiceURL("first")
    let secondURL = try voiceURL("second")

    controller.toggle(itemID: firstItemID, url: firstURL, declaredDuration: 10)
    let firstSessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(
      .snapshot(
        sessionID: firstSessionID,
        state: .playing,
        elapsed: 4,
        duration: 11
      )
    )
    XCTAssertEqual(controller.snapshot.itemID, firstItemID)
    XCTAssertEqual(controller.snapshot.state, .playing)
    XCTAssertEqual(controller.snapshot.elapsed, 4)
    XCTAssertEqual(controller.snapshot.duration, 11)

    controller.toggle(itemID: secondItemID, url: secondURL, declaredDuration: 20)
    let secondSessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    XCTAssertNotEqual(secondSessionID, firstSessionID)
    XCTAssertEqual(controller.snapshot.itemID, secondItemID)
    XCTAssertEqual(controller.snapshot.sourceURL, secondURL)
    XCTAssertEqual(controller.snapshot.state, .loading)
    XCTAssertEqual(engine.loadedSessions.map(\.url), [firstURL, secondURL])
    XCTAssertEqual(engine.playCount, 2)

    engine.send(.ended(sessionID: firstSessionID))
    XCTAssertEqual(controller.snapshot.itemID, secondItemID)
    XCTAssertEqual(controller.snapshot.state, .loading)
  }

  func testSameItemPausesAndResumesWithoutReloading() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let itemID = UUID()
    let url = try voiceURL("same")

    controller.toggle(itemID: itemID, url: url, declaredDuration: 8)
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(
      .snapshot(sessionID: sessionID, state: .playing, elapsed: 2, duration: 8)
    )

    controller.toggle(itemID: itemID, url: url, declaredDuration: 8)
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseCount, 1)

    controller.toggle(itemID: itemID, url: url, declaredDuration: 8)
    XCTAssertEqual(controller.snapshot.state, .loading)
    XCTAssertEqual(engine.loadedSessions.count, 1)
    XCTAssertEqual(engine.playCount, 2)
  }

  func testProgressSeekingEndAndInterruptionRemainOwnedByTheActiveItem() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let itemID = UUID()
    let otherItemID = UUID()

    controller.toggle(itemID: itemID, url: try voiceURL("progress"), declaredDuration: 15)
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(
      .snapshot(sessionID: sessionID, state: .playing, elapsed: 50, duration: 12)
    )
    XCTAssertEqual(controller.snapshot.elapsed, 12)
    XCTAssertEqual(controller.snapshot.duration, 12)

    controller.seek(itemID: otherItemID, to: 3)
    XCTAssertTrue(engine.seekTimes.isEmpty)
    controller.seek(itemID: itemID, to: -5)
    controller.seek(itemID: itemID, to: 30)
    XCTAssertEqual(engine.seekTimes, [0, 12])
    XCTAssertEqual(controller.snapshot.elapsed, 12)

    engine.send(.interrupted(sessionID: sessionID))
    XCTAssertEqual(controller.snapshot.state, .paused)
    engine.send(.ended(sessionID: sessionID))
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(controller.snapshot.elapsed, 0)
    engine.send(
      .snapshot(sessionID: sessionID, state: .paused, elapsed: 12, duration: 12)
    )
    XCTAssertEqual(controller.snapshot.elapsed, 0)
    XCTAssertEqual(engine.seekTimes, [0, 12])

    controller.stop(itemID: otherItemID)
    XCTAssertEqual(engine.resetCount, 0)
    controller.stop(itemID: itemID)
    XCTAssertEqual(engine.resetCount, 1)
    XCTAssertEqual(controller.snapshot, .idle)
  }

  func testInvalidURLFailsWithoutLoadingAndCanRetryAValidSource() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let itemID = UUID()
    let invalidURL = try XCTUnwrap(URL(string: "https://example.com/voice.mp3"))

    controller.toggle(itemID: itemID, url: invalidURL, declaredDuration: 3)
    XCTAssertEqual(controller.snapshot.state, .failed("语音地址不可用。"))
    XCTAssertTrue(engine.loadedSessions.isEmpty)
    XCTAssertEqual(engine.resetCount, 1)

    controller.toggle(itemID: itemID, url: try voiceURL("valid"), declaredDuration: 3)
    XCTAssertEqual(controller.snapshot.state, .loading)
    XCTAssertEqual(engine.loadedSessions.count, 1)
  }

  func testInactiveScenePausesLoadingOrPlayingWithoutAutomaticResume() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let itemID = UUID()

    controller.toggle(itemID: itemID, url: try voiceURL("scene"), declaredDuration: 9)
    controller.pauseForInactiveScene()
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(engine.pauseCount, 1)

    controller.pauseForInactiveScene()
    XCTAssertEqual(engine.pauseCount, 1)

    controller.toggle(
      itemID: itemID,
      url: try voiceURL("scene"),
      declaredDuration: 9
    )
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(
      .snapshot(sessionID: sessionID, state: .playing, elapsed: 2, duration: 9)
    )
    controller.pauseForInactiveScene()
    XCTAssertEqual(controller.snapshot.state, .paused)
    XCTAssertEqual(controller.snapshot.elapsed, 2)
    XCTAssertEqual(engine.pauseCount, 2)
  }

  func testEngineFailureUsesAStableGenericPresentation() throws {
    let engine = VoicePlaybackEngineSpy()
    let controller = VoicePlaybackController(engine: engine)
    let itemID = UUID()

    controller.toggle(itemID: itemID, url: try voiceURL("failure"), declaredDuration: 7)
    let sessionID = try XCTUnwrap(engine.loadedSessions.last?.sessionID)
    engine.send(.failed(sessionID: sessionID, message: "sensitive transport details"))

    XCTAssertEqual(controller.snapshot.state, .failed("语音加载失败。"))
    XCTAssertEqual(controller.snapshot.itemID, itemID)
    engine.send(
      .snapshot(sessionID: sessionID, state: .paused, elapsed: 4, duration: 7)
    )
    engine.send(.ended(sessionID: sessionID))
    XCTAssertEqual(controller.snapshot.state, .failed("语音加载失败。"))
    XCTAssertEqual(controller.snapshot.elapsed, 0)
    controller.seek(itemID: itemID, to: 4)
    XCTAssertTrue(engine.seekTimes.isEmpty)
  }

  func testTimeSanitizationAndFormattingAreBounded() {
    XCTAssertEqual(VoicePlaybackTime.sanitizedDuration(.nan), 0)
    XCTAssertEqual(VoicePlaybackTime.sanitizedDuration(-1), 0)
    XCTAssertEqual(
      VoicePlaybackTime.sanitizedDuration(.infinity),
      0
    )
    XCTAssertEqual(
      VoicePlaybackTime.sanitizedDuration(VoicePlaybackTime.maximumDuration + 1),
      VoicePlaybackTime.maximumDuration
    )
    XCTAssertEqual(VoicePlaybackTime.sanitizedElapsed(-1, duration: 20), 0)
    XCTAssertEqual(VoicePlaybackTime.sanitizedElapsed(30, duration: 20), 20)
    XCTAssertEqual(VoicePlaybackTime.formatted(0), "0:00")
    XCTAssertEqual(VoicePlaybackTime.formatted(65.9), "1:05")
    XCTAssertEqual(VoicePlaybackTime.formatted(3_661), "1:01:01")
    XCTAssertEqual(
      VoicePlaybackTime.accessibilityValue(elapsed: 8.9, duration: 10),
      "已播放 8 秒，共 10 秒"
    )
  }

  private func voiceURL(_ identifier: String) throws -> URL {
    try XCTUnwrap(SecureTiebaURL.voice(md5: identifier))
  }
}

@MainActor
private final class VoicePlaybackEngineSpy: VoicePlaybackEngine {
  struct LoadedSession: Equatable {
    let url: URL
    let sessionID: UUID
  }

  var eventHandler: (@MainActor @Sendable (VoicePlaybackEngineEvent) -> Void)?
  private(set) var loadedSessions = [LoadedSession]()
  private(set) var playCount = 0
  private(set) var pauseCount = 0
  private(set) var seekTimes = [TimeInterval]()
  private(set) var resetCount = 0

  func load(url: URL, sessionID: UUID) {
    loadedSessions.append(LoadedSession(url: url, sessionID: sessionID))
  }

  func play() {
    playCount += 1
  }

  func pause() {
    pauseCount += 1
  }

  func seek(to time: TimeInterval) {
    seekTimes.append(time)
  }

  func reset() {
    resetCount += 1
  }

  func send(_ event: VoicePlaybackEngineEvent) {
    eventHandler?(event)
  }
}
