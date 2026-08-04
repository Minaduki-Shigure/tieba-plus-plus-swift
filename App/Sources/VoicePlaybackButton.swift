@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI

enum VoicePlaybackState: Equatable, Sendable {
  case idle
  case loading
  case playing
  case paused
  case failed(String)
}

struct VoicePlaybackSnapshot: Equatable, Sendable {
  static let idle = VoicePlaybackSnapshot(
    itemID: nil,
    sourceURL: nil,
    state: .idle,
    elapsed: 0,
    duration: 0
  )

  let itemID: UUID?
  let sourceURL: URL?
  let state: VoicePlaybackState
  let elapsed: TimeInterval
  let duration: TimeInterval
}

enum VoicePlaybackEngineState: Equatable, Sendable {
  case loading
  case playing
  case paused
}

enum VoicePlaybackEngineEvent: Equatable, Sendable {
  case snapshot(
    sessionID: UUID,
    state: VoicePlaybackEngineState,
    elapsed: TimeInterval,
    duration: TimeInterval?
  )
  case ended(sessionID: UUID)
  case failed(sessionID: UUID, message: String)
  case interrupted(sessionID: UUID)
}

@MainActor
protocol VoicePlaybackEngine: AnyObject {
  var eventHandler: (@MainActor @Sendable (VoicePlaybackEngineEvent) -> Void)? { get set }

  func load(url: URL, sessionID: UUID)
  func play()
  func pause()
  func seek(to time: TimeInterval)
  func reset()
}

enum VoicePlaybackURLPolicy {
  static let maximumVoiceIdentifierBytes = 512

  static func allows(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "tiebac.baidu.com",
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.path == "/c/p/voice",
      components.fragment == nil,
      let queryItems = components.queryItems,
      queryItems.count == 2
    else { return false }

    let voiceIdentifiers = queryItems.filter { $0.name == "voice_md5" }.compactMap(\.value)
    let playSources = queryItems.filter { $0.name == "play_from" }.compactMap(\.value)
    guard
      voiceIdentifiers.count == 1,
      playSources == ["pb_voice_play"],
      queryItems.allSatisfy({ $0.name == "voice_md5" || $0.name == "play_from" })
    else { return false }

    let identifier = voiceIdentifiers[0].trimmingCharacters(in: .whitespacesAndNewlines)
    return !identifier.isEmpty
      && identifier.lengthOfBytes(using: .utf8) <= maximumVoiceIdentifierBytes
      && !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

enum VoicePlaybackTime {
  static let maximumDuration: TimeInterval = 24 * 60 * 60

  static func sanitizedDuration(_ value: TimeInterval) -> TimeInterval {
    guard value.isFinite, value > 0 else { return 0 }
    return min(value, maximumDuration)
  }

  static func sanitizedElapsed(
    _ value: TimeInterval,
    duration: TimeInterval
  ) -> TimeInterval {
    guard value.isFinite, value > 0 else { return 0 }
    let duration = sanitizedDuration(duration)
    return duration > 0 ? min(value, duration) : min(value, maximumDuration)
  }

  static func formatted(_ value: TimeInterval) -> String {
    let totalSeconds = Int(sanitizedDuration(value).rounded(.down))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }

  static func accessibilityValue(elapsed: TimeInterval, duration: TimeInterval) -> String {
    let elapsedSeconds = Int(sanitizedElapsed(elapsed, duration: duration).rounded(.down))
    let durationSeconds = Int(sanitizedDuration(duration).rounded(.down))
    return "已播放 \(elapsedSeconds) 秒，共 \(durationSeconds) 秒"
  }
}

@MainActor
final class VoicePlaybackController: ObservableObject {
  @Published private(set) var snapshot = VoicePlaybackSnapshot.idle

  private let engine: any VoicePlaybackEngine
  private var sessionID: UUID?
  private var completedSessionID: UUID?
  private var failedSessionID: UUID?

  convenience init() {
    self.init(engine: AVPlayerVoicePlaybackEngine())
  }

  init(engine: any VoicePlaybackEngine) {
    self.engine = engine
    engine.eventHandler = { [weak self] event in
      self?.handle(event)
    }
  }

  func toggle(itemID: UUID, url: URL, declaredDuration: Int) {
    if snapshot.itemID == itemID, snapshot.sourceURL == url {
      switch snapshot.state {
      case .loading, .playing:
        engine.pause()
        snapshot = replacingState(.paused)
      case .paused:
        completedSessionID = nil
        failedSessionID = nil
        snapshot = replacingState(.loading)
        engine.play()
      case .failed, .idle:
        start(itemID: itemID, url: url, declaredDuration: declaredDuration)
      }
      return
    }

    start(itemID: itemID, url: url, declaredDuration: declaredDuration)
  }

  func seek(itemID: UUID, to value: TimeInterval) {
    guard snapshot.itemID == itemID, snapshot.duration > 0 else { return }
    switch snapshot.state {
    case .playing, .paused:
      break
    case .idle, .loading, .failed:
      return
    }
    let elapsed = VoicePlaybackTime.sanitizedElapsed(value, duration: snapshot.duration)
    completedSessionID = nil
    engine.seek(to: elapsed)
    snapshot = VoicePlaybackSnapshot(
      itemID: snapshot.itemID,
      sourceURL: snapshot.sourceURL,
      state: snapshot.state,
      elapsed: elapsed,
      duration: snapshot.duration
    )
  }

  func stop(itemID: UUID) {
    guard snapshot.itemID == itemID else { return }
    engine.reset()
    sessionID = nil
    completedSessionID = nil
    failedSessionID = nil
    snapshot = .idle
  }

  func pauseForInactiveScene() {
    switch snapshot.state {
    case .loading, .playing:
      engine.pause()
      snapshot = replacingState(.paused)
    case .idle, .paused, .failed:
      break
    }
  }

  private func start(itemID: UUID, url: URL, declaredDuration: Int) {
    let declaredDuration = VoicePlaybackTime.sanitizedDuration(TimeInterval(declaredDuration))
    guard VoicePlaybackURLPolicy.allows(url) else {
      engine.reset()
      sessionID = nil
      completedSessionID = nil
      failedSessionID = nil
      snapshot = VoicePlaybackSnapshot(
        itemID: itemID,
        sourceURL: url,
        state: .failed("语音地址不可用。"),
        elapsed: 0,
        duration: declaredDuration
      )
      return
    }

    let sessionID = UUID()
    self.sessionID = sessionID
    completedSessionID = nil
    failedSessionID = nil
    snapshot = VoicePlaybackSnapshot(
      itemID: itemID,
      sourceURL: url,
      state: .loading,
      elapsed: 0,
      duration: declaredDuration
    )
    engine.load(url: url, sessionID: sessionID)
    engine.play()
  }

  private func handle(_ event: VoicePlaybackEngineEvent) {
    switch event {
    case .snapshot(let eventSessionID, let state, let elapsed, let actualDuration):
      guard
        eventSessionID == sessionID,
        eventSessionID != completedSessionID,
        eventSessionID != failedSessionID
      else { return }
      let duration = resolvedDuration(actualDuration)
      snapshot = VoicePlaybackSnapshot(
        itemID: snapshot.itemID,
        sourceURL: snapshot.sourceURL,
        state: playbackState(state),
        elapsed: VoicePlaybackTime.sanitizedElapsed(elapsed, duration: duration),
        duration: duration
      )
    case .ended(let eventSessionID):
      guard
        eventSessionID == sessionID,
        eventSessionID != failedSessionID
      else { return }
      completedSessionID = eventSessionID
      snapshot = VoicePlaybackSnapshot(
        itemID: snapshot.itemID,
        sourceURL: snapshot.sourceURL,
        state: .paused,
        elapsed: 0,
        duration: snapshot.duration
      )
    case .failed(let eventSessionID, _):
      guard
        eventSessionID == sessionID,
        eventSessionID != completedSessionID
      else { return }
      failedSessionID = eventSessionID
      snapshot = replacingState(.failed("语音加载失败。"))
    case .interrupted(let eventSessionID):
      guard
        eventSessionID == sessionID,
        eventSessionID != completedSessionID,
        eventSessionID != failedSessionID
      else { return }
      snapshot = replacingState(.paused)
    }
  }

  private func resolvedDuration(_ actualDuration: TimeInterval?) -> TimeInterval {
    guard let actualDuration else { return snapshot.duration }
    let duration = VoicePlaybackTime.sanitizedDuration(actualDuration)
    return duration > 0 ? duration : snapshot.duration
  }

  private func replacingState(_ state: VoicePlaybackState) -> VoicePlaybackSnapshot {
    VoicePlaybackSnapshot(
      itemID: snapshot.itemID,
      sourceURL: snapshot.sourceURL,
      state: state,
      elapsed: snapshot.elapsed,
      duration: snapshot.duration
    )
  }

  private func playbackState(_ state: VoicePlaybackEngineState) -> VoicePlaybackState {
    switch state {
    case .loading:
      .loading
    case .playing:
      .playing
    case .paused:
      .paused
    }
  }
}

// AVFoundation observer tokens lack Sendable conformance. This bag is mutated
// only by the main-actor engine and owns synchronous cleanup without making the
// player engine itself unchecked Sendable.
private final class AVPlayerVoicePlaybackObserverBag: @unchecked Sendable {
  private let player: AVPlayer
  private var timeObserver: Any?
  private var notificationObservers = [NSObjectProtocol]()
  private var playerStateObservation: NSKeyValueObservation?
  private var itemStateObservation: NSKeyValueObservation?

  init(player: AVPlayer) {
    self.player = player
  }

  func storeTimeObserver(_ observer: Any) {
    precondition(Thread.isMainThread)
    timeObserver = observer
  }

  func storeNotificationObserver(_ observer: NSObjectProtocol) {
    precondition(Thread.isMainThread)
    notificationObservers.append(observer)
  }

  func storePlayerStateObservation(_ observation: NSKeyValueObservation) {
    precondition(Thread.isMainThread)
    playerStateObservation?.invalidate()
    playerStateObservation = observation
  }

  func replaceItemStateObservation(_ observation: NSKeyValueObservation?) {
    precondition(Thread.isMainThread)
    itemStateObservation?.invalidate()
    itemStateObservation = observation
  }

  deinit {
    itemStateObservation?.invalidate()
    playerStateObservation?.invalidate()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

@MainActor
private final class AVPlayerVoicePlaybackEngine: VoicePlaybackEngine {
  var eventHandler: (@MainActor @Sendable (VoicePlaybackEngineEvent) -> Void)?

  private let player: AVPlayer
  private let audioSession = AVAudioSession.sharedInstance()
  private let observerBag: AVPlayerVoicePlaybackObserverBag
  private var sessionID: UUID?
  private var currentItemIdentifier: ObjectIdentifier?
  private var didReportFailure = false
  private var endRewindID: UUID?

  private var isRewindingAfterEnd: Bool {
    endRewindID != nil
  }

  init() {
    let player = AVPlayer()
    self.player = player
    observerBag = AVPlayerVoicePlaybackObserverBag(player: player)
    installObservers()
  }

  func load(url: URL, sessionID: UUID) {
    player.pause()
    let item = AVPlayerItem(url: url)
    let itemIdentifier = ObjectIdentifier(item)
    self.sessionID = sessionID
    currentItemIdentifier = itemIdentifier
    didReportFailure = false
    endRewindID = nil
    player.replaceCurrentItem(with: item)
    observerBag.replaceItemStateObservation(
      item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.handleItemStateChange(
            itemIdentifier: itemIdentifier,
            sessionID: sessionID
          )
        }
      }
    )
    emitSnapshot(state: .loading, elapsed: 0)
  }

  func play() {
    guard sessionID != nil, player.currentItem != nil else { return }
    endRewindID = nil
    prepareAudioSession()
    player.play()
    emitSnapshot(state: .loading, elapsed: player.currentTime().seconds)
  }

  func pause() {
    guard sessionID != nil else { return }
    player.pause()
    deactivateAudioSession()
    emitSnapshot(state: .paused, elapsed: player.currentTime().seconds)
  }

  func seek(to time: TimeInterval) {
    guard sessionID != nil, time.isFinite, time >= 0 else { return }
    endRewindID = nil
    player.seek(
      to: CMTime(seconds: time, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  func reset() {
    observerBag.replaceItemStateObservation(nil)
    player.pause()
    player.replaceCurrentItem(with: nil)
    sessionID = nil
    currentItemIdentifier = nil
    didReportFailure = false
    endRewindID = nil
    deactivateAudioSession()
  }

  private func installObservers() {
    observerBag.storeTimeObserver(
      player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.publishCurrentSnapshot()
        }
      }
    )
    observerBag.storePlayerStateObservation(
      player.observe(\.timeControlStatus, options: [.initial, .new]) {
        [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.publishCurrentSnapshot()
        }
      }
    )

    let center = NotificationCenter.default
    observerBag.storeNotificationObserver(
      center.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let itemIdentifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
          self?.handleEnded(itemIdentifier: itemIdentifier)
        }
      }
    )
    observerBag.storeNotificationObserver(
      center.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let itemIdentifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
          self?.handleFailure(itemIdentifier: itemIdentifier)
        }
      }
    )
    observerBag.storeNotificationObserver(
      center.addObserver(
        forName: AVPlayerItem.playbackStalledNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let itemIdentifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
          self?.handleStalled(itemIdentifier: itemIdentifier)
        }
      }
    )
    observerBag.storeNotificationObserver(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
        let rawType = (value as? NSNumber)?.uintValue ?? (value as? UInt)
        Task { @MainActor [weak self] in
          guard rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
          self?.interruptPlayback()
        }
      }
    )
    observerBag.storeNotificationObserver(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
        let rawReason = (value as? NSNumber)?.uintValue ?? (value as? UInt)
        Task { @MainActor [weak self] in
          guard rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else {
            return
          }
          self?.interruptPlayback()
        }
      }
    )
  }

  private func handleItemStateChange(
    itemIdentifier: ObjectIdentifier,
    sessionID: UUID
  ) {
    guard
      sessionID == self.sessionID,
      itemIdentifier == currentItemIdentifier
    else { return }
    publishCurrentSnapshot()
  }

  private func publishCurrentSnapshot() {
    guard
      let sessionID,
      let item = player.currentItem,
      !isRewindingAfterEnd,
      !didReportFailure
    else { return }
    let elapsed = player.currentTime().seconds
    switch item.status {
    case .unknown:
      emitSnapshot(state: .loading, elapsed: elapsed)
    case .readyToPlay:
      let state: VoicePlaybackEngineState
      switch player.timeControlStatus {
      case .playing:
        state = .playing
      case .waitingToPlayAtSpecifiedRate:
        state = .loading
      case .paused:
        state = .paused
      @unknown default:
        state = .loading
      }
      eventHandler?(
        .snapshot(
          sessionID: sessionID,
          state: state,
          elapsed: elapsed,
          duration: finiteDuration(item.duration.seconds)
        )
      )
    case .failed:
      reportFailure()
    @unknown default:
      emitSnapshot(state: .loading, elapsed: elapsed)
    }
  }

  private func handleEnded(itemIdentifier: ObjectIdentifier?) {
    guard
      let sessionID,
      itemIdentifier == currentItemIdentifier,
      !didReportFailure,
      !isRewindingAfterEnd
    else { return }
    let rewindID = UUID()
    endRewindID = rewindID
    player.pause()
    deactivateAudioSession()
    player.seek(
      to: .zero,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      Task { @MainActor [weak self] in
        self?.finishRewindAfterEnd(
          itemIdentifier: itemIdentifier,
          sessionID: sessionID,
          rewindID: rewindID,
          finished: finished
        )
      }
    }
  }

  private func finishRewindAfterEnd(
    itemIdentifier: ObjectIdentifier?,
    sessionID: UUID,
    rewindID: UUID,
    finished: Bool
  ) {
    guard
      endRewindID == rewindID,
      sessionID == self.sessionID,
      itemIdentifier == currentItemIdentifier
    else { return }
    endRewindID = nil
    guard finished, !didReportFailure else {
      if !didReportFailure {
        reportFailure()
      }
      return
    }
    eventHandler?(.ended(sessionID: sessionID))
  }

  private func handleFailure(itemIdentifier: ObjectIdentifier?) {
    guard itemIdentifier == currentItemIdentifier else { return }
    reportFailure()
  }

  private func handleStalled(itemIdentifier: ObjectIdentifier?) {
    guard
      itemIdentifier == currentItemIdentifier,
      !didReportFailure,
      !isRewindingAfterEnd,
      player.timeControlStatus != .paused
    else { return }
    emitSnapshot(state: .loading, elapsed: player.currentTime().seconds)
  }

  private func interruptPlayback() {
    guard
      let sessionID,
      player.currentItem != nil,
      !didReportFailure,
      !isRewindingAfterEnd
    else { return }
    player.pause()
    deactivateAudioSession()
    eventHandler?(.interrupted(sessionID: sessionID))
  }

  private func reportFailure() {
    guard let sessionID, !didReportFailure else { return }
    didReportFailure = true
    endRewindID = nil
    player.pause()
    deactivateAudioSession()
    eventHandler?(
      .failed(
        sessionID: sessionID,
        message: "语音加载失败。"
      )
    )
  }

  private func emitSnapshot(state: VoicePlaybackEngineState, elapsed: TimeInterval) {
    guard
      let sessionID,
      !isRewindingAfterEnd,
      !didReportFailure
    else { return }
    eventHandler?(
      .snapshot(
        sessionID: sessionID,
        state: state,
        elapsed: elapsed.isFinite ? elapsed : 0,
        duration: player.currentItem.flatMap { finiteDuration($0.duration.seconds) }
      )
    )
  }

  private func finiteDuration(_ value: TimeInterval) -> TimeInterval? {
    value.isFinite && value > 0 ? value : nil
  }

  private func prepareAudioSession() {
    try? audioSession.setCategory(.playback, mode: .spokenAudio)
    try? audioSession.setActive(true)
  }

  private func deactivateAudioSession() {
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
  }
}

struct VoicePlaybackButton: View {
  let url: URL
  let duration: Int

  @EnvironmentObject private var controller: VoicePlaybackController
  @State private var itemID = UUID()
  @State private var pendingSeek: TimeInterval?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Button(action: togglePlayback) {
          ZStack {
            if isLoading {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: playbackSymbol)
                .frame(width: 18, height: 18)
            }
          }
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackAccessibilityLabel)
        .accessibilityValue(playbackAccessibilityValue)
        .help(playbackAccessibilityLabel)

        Text(statusText)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(hasFailed ? Color.red : Color.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)
      }

      Slider(
        value: seekBinding,
        in: 0...max(displayedDuration, 1),
        onEditingChanged: seekEditingChanged
      )
      .disabled(!canSeek)
      .accessibilityLabel("语音播放进度")
      .accessibilityValue(
        VoicePlaybackTime.accessibilityValue(
          elapsed: displayedElapsed,
          duration: displayedDuration
        )
      )
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: 320, minHeight: 72, alignment: .leading)
    .background(Color(uiColor: .secondarySystemFill))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .onChange(of: controller.snapshot.itemID) { activeItemID in
      if activeItemID != itemID { pendingSeek = nil }
    }
    .onChange(of: activeState) { state in
      switch state {
      case .playing, .paused:
        break
      case .idle, .loading, .failed:
        pendingSeek = nil
      }
    }
    .onChange(of: url) { _ in
      controller.stop(itemID: itemID)
      pendingSeek = nil
    }
    .onDisappear {
      controller.stop(itemID: itemID)
      pendingSeek = nil
    }
  }

  private var isActive: Bool {
    controller.snapshot.itemID == itemID && controller.snapshot.sourceURL == url
  }

  private var activeState: VoicePlaybackState {
    isActive ? controller.snapshot.state : .idle
  }

  private var isLoading: Bool {
    activeState == .loading
  }

  private var hasFailed: Bool {
    if case .failed = activeState { return true }
    return false
  }

  private var displayedDuration: TimeInterval {
    if isActive, controller.snapshot.duration > 0 {
      return controller.snapshot.duration
    }
    return VoicePlaybackTime.sanitizedDuration(TimeInterval(duration))
  }

  private var displayedElapsed: TimeInterval {
    pendingSeek ?? (isActive ? controller.snapshot.elapsed : 0)
  }

  private var canSeek: Bool {
    guard isActive, displayedDuration > 0 else { return false }
    switch activeState {
    case .playing, .paused:
      return true
    case .idle, .loading, .failed:
      return false
    }
  }

  private var playbackSymbol: String {
    switch activeState {
    case .playing:
      "pause.fill"
    case .failed:
      "arrow.clockwise"
    case .idle, .loading, .paused:
      "play.fill"
    }
  }

  private var statusText: String {
    switch activeState {
    case .idle:
      "语音 \(VoicePlaybackTime.formatted(displayedDuration))"
    case .loading:
      "正在加载 · \(VoicePlaybackTime.formatted(displayedDuration))"
    case .playing, .paused:
      "\(VoicePlaybackTime.formatted(displayedElapsed))"
        + " / \(VoicePlaybackTime.formatted(displayedDuration))"
    case .failed:
      "语音加载失败"
    }
  }

  private var playbackAccessibilityLabel: String {
    switch activeState {
    case .playing, .loading:
      "暂停语音"
    case .failed:
      "重新加载语音"
    case .idle, .paused:
      "播放语音"
    }
  }

  private var playbackAccessibilityValue: String {
    switch activeState {
    case .loading:
      "正在加载"
    case .failed(let message):
      message
    case .idle, .playing, .paused:
      VoicePlaybackTime.accessibilityValue(
        elapsed: displayedElapsed,
        duration: displayedDuration
      )
    }
  }

  private var seekBinding: Binding<TimeInterval> {
    Binding(
      get: { displayedElapsed },
      set: { pendingSeek = $0 }
    )
  }

  private func togglePlayback() {
    pendingSeek = nil
    controller.toggle(itemID: itemID, url: url, declaredDuration: duration)
  }

  private func seekEditingChanged(_ isEditing: Bool) {
    guard !isEditing, let pendingSeek else { return }
    controller.seek(itemID: itemID, to: pendingSeek)
    self.pendingSeek = nil
  }
}
