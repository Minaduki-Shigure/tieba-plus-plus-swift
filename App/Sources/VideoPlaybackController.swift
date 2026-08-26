@preconcurrency import AVFoundation
@preconcurrency import AVKit
import Combine
import Foundation
import ObjectiveC
import SwiftUI
import UIKit

enum VideoPlaybackState: Equatable, Sendable {
  case idle
  case loading
  case playing
  case paused
  case failed(String)
}

struct VideoPlaybackSnapshot: Equatable, Sendable {
  static let idle = VideoPlaybackSnapshot(
    ownerID: nil,
    sourceURL: nil,
    sessionID: nil,
    state: .idle
  )

  let ownerID: UUID?
  let sourceURL: URL?
  let sessionID: UUID?
  let state: VideoPlaybackState
}

enum VideoFullScreenState: Equatable, Sendable {
  case inline
  case enteringFullScreen
  case fullScreen
  case exitingFullScreen
}

enum VideoPlaybackEngineState: Equatable, Sendable {
  case loading
  case playing
  case paused
}

enum VideoPlaybackEngineEvent: Equatable, Sendable {
  case snapshot(sessionID: UUID, state: VideoPlaybackEngineState)
  case ended(sessionID: UUID)
  case failed(sessionID: UUID, message: String)
  case interrupted(sessionID: UUID)
}

@MainActor
protocol VideoPlaybackEngine: AnyObject {
  var eventHandler: (@MainActor @Sendable (VideoPlaybackEngineEvent) -> Void)? { get set }
  var player: AVPlayer? { get }

  func load(url: URL, sessionID: UUID)
  func play()
  func pause(deactivateAudioSession: Bool)
  func reset(deactivateAudioSession: Bool)
}

enum VideoPlaybackURLPolicy {
  static let maximumAbsoluteURLBytes = 8_192

  static func allows(_ url: URL) -> Bool {
    let absoluteString = url.absoluteString
    guard
      absoluteString.lengthOfBytes(using: .utf8) <= maximumAbsoluteURLBytes,
      !absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.fragment == nil
    else { return false }
    return true
  }
}

@MainActor
final class VideoPlaybackController: ObservableObject, MediaPlaybackParticipant {
  @Published private(set) var snapshot = VideoPlaybackSnapshot.idle
  @Published private(set) var fullScreenState = VideoFullScreenState.inline

  private let coordinator: MediaPlaybackCoordinator
  private let engine: any VideoPlaybackEngine
  private var lease: MediaPlaybackLease?
  private var completedSessionID: UUID?
  private var failedSessionID: UUID?
  private var pendingStopSessionID: UUID?

  convenience init(coordinator: MediaPlaybackCoordinator) {
    self.init(coordinator: coordinator, engine: AVPlayerVideoPlaybackEngine())
  }

  init(
    coordinator: MediaPlaybackCoordinator,
    engine: any VideoPlaybackEngine
  ) {
    self.coordinator = coordinator
    self.engine = engine
    engine.eventHandler = { [weak self] event in
      self?.handle(event)
    }
  }

  @discardableResult
  func start(ownerID: UUID, url: URL) -> Bool {
    guard VideoPlaybackURLPolicy.allows(url) else {
      recordInvalidSource(ownerID: ownerID, url: url)
      return false
    }

    if snapshot.ownerID == ownerID,
       snapshot.sourceURL == url,
       snapshot.sessionID != nil
    {
      switch snapshot.state {
      case .loading, .playing:
        return true
      case .paused:
        return resumeCurrentSession(ownerID: ownerID)
      case .failed, .idle:
        break
      }
    }

    // Replacing the player item during a system full-screen transition can make
    // the presented controller display the next owner's media. The next owner
    // can retry after the current presentation returns inline.
    guard fullScreenState == .inline else { return false }
    guard let newLease = acquireLease(ownerID: ownerID) else { return false }

    lease = newLease
    engine.reset(deactivateAudioSession: false)

    let sessionID = UUID()
    completedSessionID = nil
    failedSessionID = nil
    pendingStopSessionID = nil
    snapshot = VideoPlaybackSnapshot(
      ownerID: ownerID,
      sourceURL: url,
      sessionID: sessionID,
      state: .loading
    )
    engine.load(url: url, sessionID: sessionID)
    engine.play()
    return true
  }

  func player(for ownerID: UUID, url: URL) -> AVPlayer? {
    guard
      snapshot.ownerID == ownerID,
      snapshot.sourceURL == url,
      snapshot.sessionID != nil
    else { return nil }
    if case .failed = snapshot.state { return nil }
    return engine.player
  }

  func sourceDidChange(ownerID: UUID, to newURL: URL?) {
    guard
      snapshot.ownerID == ownerID,
      snapshot.sourceURL != newURL
    else { return }
    stopOrDefer(ownerID: ownerID)
  }

  func ownerDidDisappear(_ ownerID: UUID) {
    guard snapshot.ownerID == ownerID else { return }
    stopOrDefer(ownerID: ownerID)
  }

  func pauseForInactiveScene() {
    guard snapshot.sessionID != nil else { return }
    switch snapshot.state {
    case .loading, .playing:
      pauseCurrentSession(deactivateAudioSessionIfCurrent: true)
    case .idle, .paused, .failed:
      break
    }
  }

  func fullScreenPresentationWillBegin(ownerID: UUID, sessionID: UUID) {
    guard owns(ownerID: ownerID, sessionID: sessionID) else { return }
    switch fullScreenState {
    case .inline:
      fullScreenState = .enteringFullScreen
    case .enteringFullScreen, .fullScreen, .exitingFullScreen:
      break
    }
  }

  func fullScreenPresentationDidFinishBeginning(
    ownerID: UUID,
    sessionID: UUID,
    cancelled: Bool
  ) {
    guard owns(ownerID: ownerID, sessionID: sessionID) else { return }
    guard fullScreenState == .enteringFullScreen else { return }
    fullScreenState = cancelled ? .inline : .fullScreen
    if cancelled {
      completePendingStopIfPossible(sessionID: sessionID)
    }
  }

  func fullScreenPresentationWillEnd(ownerID: UUID, sessionID: UUID) {
    guard owns(ownerID: ownerID, sessionID: sessionID) else { return }
    switch fullScreenState {
    case .enteringFullScreen, .fullScreen:
      fullScreenState = .exitingFullScreen
    case .inline, .exitingFullScreen:
      break
    }
  }

  func fullScreenPresentationDidFinishEnding(
    ownerID: UUID,
    sessionID: UUID,
    cancelled: Bool
  ) {
    guard owns(ownerID: ownerID, sessionID: sessionID) else { return }
    guard fullScreenState == .exitingFullScreen else { return }
    fullScreenState = cancelled ? .fullScreen : .inline
    if !cancelled {
      completePendingStopIfPossible(sessionID: sessionID)
    }
  }

  func playerViewDelegateLifetimeDidEnd(ownerID: UUID, sessionID: UUID) {
    guard owns(ownerID: ownerID, sessionID: sessionID) else { return }
    if fullScreenState != .inline {
      fullScreenState = .inline
    }
    completePendingStopIfPossible(sessionID: sessionID)
  }

  func mediaPlaybackWasRevoked(
    lease: MediaPlaybackLease,
    reason: MediaPlaybackRevocationReason
  ) {
    guard self.lease == lease else { return }
    self.lease = nil
    let shouldDeactivateAudioSession: Bool
    switch reason {
    case .superseded:
      shouldDeactivateAudioSession = false
    case .sceneInactive, .surfaceInactive:
      shouldDeactivateAudioSession = true
    }
    engine.pause(deactivateAudioSession: shouldDeactivateAudioSession)
    if snapshot.sessionID != nil {
      snapshot = replacingState(.paused)
    }
  }

  private func recordInvalidSource(ownerID: UUID, url: URL) {
    // A malformed URL in a different cell must not stop the current video or
    // revoke an unrelated voice lease.
    guard snapshot.ownerID == nil || snapshot.ownerID == ownerID else { return }
    guard fullScreenState == .inline else { return }

    let shouldDeactivateAudioSession = releaseLeaseIfCurrent()
    engine.reset(deactivateAudioSession: shouldDeactivateAudioSession)
    completedSessionID = nil
    failedSessionID = nil
    pendingStopSessionID = nil
    snapshot = VideoPlaybackSnapshot(
      ownerID: ownerID,
      sourceURL: url,
      sessionID: nil,
      state: .failed("视频地址不可用。")
    )
  }

  private func resumeCurrentSession(ownerID: UUID) -> Bool {
    guard let newLease = acquireLease(ownerID: ownerID) else { return false }
    lease = newLease
    completedSessionID = nil
    failedSessionID = nil
    snapshot = replacingState(.loading)
    engine.play()
    return true
  }

  private func acquireLease(ownerID: UUID) -> MediaPlaybackLease? {
    guard
      let lease = coordinator.acquire(
        kind: .video,
        ownerID: ownerID,
        participant: self
      ),
      coordinator.isCurrent(lease)
    else { return nil }
    return lease
  }

  private func stopOrDefer(ownerID: UUID) {
    guard snapshot.ownerID == ownerID else { return }
    guard let sessionID = snapshot.sessionID else {
      resetCurrentSession(deactivateAudioSessionIfCurrent: true)
      return
    }

    if fullScreenState != .inline {
      pendingStopSessionID = sessionID
      pauseCurrentSession(deactivateAudioSessionIfCurrent: true)
      return
    }
    resetCurrentSession(deactivateAudioSessionIfCurrent: true)
  }

  private func pauseCurrentSession(deactivateAudioSessionIfCurrent: Bool) {
    let wasCurrent = releaseLeaseIfCurrent()
    engine.pause(
      deactivateAudioSession: deactivateAudioSessionIfCurrent && wasCurrent
    )
    snapshot = replacingState(.paused)
  }

  private func resetCurrentSession(deactivateAudioSessionIfCurrent: Bool) {
    let wasCurrent = releaseLeaseIfCurrent()
    engine.reset(
      deactivateAudioSession: deactivateAudioSessionIfCurrent && wasCurrent
    )
    completedSessionID = nil
    failedSessionID = nil
    pendingStopSessionID = nil
    snapshot = .idle
    fullScreenState = .inline
  }

  private func releaseLeaseIfCurrent() -> Bool {
    guard let lease else { return false }
    let wasCurrent = coordinator.isCurrent(lease)
    self.lease = nil
    coordinator.relinquish(lease)
    return wasCurrent
  }

  private func completePendingStopIfPossible(sessionID: UUID) {
    guard
      fullScreenState == .inline,
      pendingStopSessionID == sessionID,
      snapshot.sessionID == sessionID
    else { return }
    resetCurrentSession(deactivateAudioSessionIfCurrent: true)
  }

  private func owns(ownerID: UUID, sessionID: UUID) -> Bool {
    snapshot.ownerID == ownerID && snapshot.sessionID == sessionID
  }

  private func handle(_ event: VideoPlaybackEngineEvent) {
    switch event {
    case .snapshot(let eventSessionID, let state):
      guard
        eventSessionID == snapshot.sessionID,
        eventSessionID != failedSessionID
      else { return }
      if pendingStopSessionID == eventSessionID {
        if state != .paused {
          engine.pause(deactivateAudioSession: !coordinator.hasCurrentLease)
          snapshot = replacingState(.paused)
        }
        return
      }
      if eventSessionID == completedSessionID {
        guard state != .paused else { return }
        completedSessionID = nil
      }
      handleEngineState(state)
    case .ended(let eventSessionID):
      guard
        eventSessionID == snapshot.sessionID,
        eventSessionID != completedSessionID,
        eventSessionID != failedSessionID
      else { return }
      completedSessionID = eventSessionID
      let shouldDeactivateAudioSession = releaseLeaseIfCurrent()
      engine.pause(deactivateAudioSession: shouldDeactivateAudioSession)
      snapshot = replacingState(.paused)
    case .failed(let eventSessionID, _):
      guard
        eventSessionID == snapshot.sessionID,
        eventSessionID != completedSessionID
      else { return }
      failedSessionID = eventSessionID
      let shouldDeactivateAudioSession = releaseLeaseIfCurrent()
      engine.pause(deactivateAudioSession: shouldDeactivateAudioSession)
      snapshot = replacingState(.failed("视频加载失败。"))
    case .interrupted(let eventSessionID):
      guard
        eventSessionID == snapshot.sessionID,
        eventSessionID != completedSessionID,
        eventSessionID != failedSessionID
      else { return }
      let shouldDeactivateAudioSession = releaseLeaseIfCurrent()
      engine.pause(deactivateAudioSession: shouldDeactivateAudioSession)
      snapshot = replacingState(.paused)
    }
  }

  private func handleEngineState(_ state: VideoPlaybackEngineState) {
    switch state {
    case .loading, .playing:
      var acquiredForNativePlayback = false
      if lease.map(coordinator.isCurrent) != true {
        guard
          let ownerID = snapshot.ownerID,
          let newLease = acquireLease(ownerID: ownerID)
        else {
          // An inactive scene owns no lease, while an active coordinator can
          // return nil after a reentrant claimant supersedes this request.
          engine.pause(deactivateAudioSession: !coordinator.isSceneActive)
          snapshot = replacingState(.paused)
          return
        }
        lease = newLease
        acquiredForNativePlayback = true
      }
      if acquiredForNativePlayback {
        // Native AVPlayerViewController controls bypass start/resume. Re-enter
        // the engine after arbitration so it configures movie playback audio.
        engine.play()
      }
      snapshot = replacingState(state == .playing ? .playing : .loading)
    case .paused:
      guard snapshot.state != .paused || lease != nil else { return }
      let shouldDeactivateAudioSession = releaseLeaseIfCurrent()
      engine.pause(deactivateAudioSession: shouldDeactivateAudioSession)
      snapshot = replacingState(.paused)
    }
  }

  private func replacingState(_ state: VideoPlaybackState) -> VideoPlaybackSnapshot {
    VideoPlaybackSnapshot(
      ownerID: snapshot.ownerID,
      sourceURL: snapshot.sourceURL,
      sessionID: snapshot.sessionID,
      state: state
    )
  }
}

// KVO and notification tokens are confined to the main-actor engine. The bag
// performs synchronous teardown and never crosses an actor boundary itself.
private final class AVPlayerVideoPlaybackObserverBag: @unchecked Sendable {
  private let player: AVPlayer
  private var notificationObservers = [NSObjectProtocol]()
  private var playerStateObservation: NSKeyValueObservation?
  private var itemStateObservation: NSKeyValueObservation?

  init(player: AVPlayer) {
    self.player = player
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
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    _ = player
  }
}

struct VideoPlaybackIntentTracker {
  private(set) var isPlaybackRequested = false
  private(set) var hasObservedPlaybackAfterRequest = false

  mutating func requestPlay() {
    if !isPlaybackRequested {
      hasObservedPlaybackAfterRequest = false
    }
    isPlaybackRequested = true
  }

  mutating func stop() {
    isPlaybackRequested = false
    hasObservedPlaybackAfterRequest = false
  }

  mutating func state(
    for timeControlStatus: AVPlayer.TimeControlStatus,
    itemIsReady: Bool
  ) -> VideoPlaybackEngineState {
    switch timeControlStatus {
    case .playing:
      isPlaybackRequested = true
      hasObservedPlaybackAfterRequest = true
      return itemIsReady ? .playing : .loading
    case .waitingToPlayAtSpecifiedRate:
      isPlaybackRequested = true
      hasObservedPlaybackAfterRequest = true
      return .loading
    case .paused:
      if isPlaybackRequested, !hasObservedPlaybackAfterRequest {
        return .loading
      }
      stop()
      return .paused
    @unknown default:
      stop()
      return .paused
    }
  }
}

@MainActor
final class AVPlayerVideoPlaybackEngine: VideoPlaybackEngine {
  var eventHandler: (@MainActor @Sendable (VideoPlaybackEngineEvent) -> Void)?
  private(set) var player: AVPlayer?

  private let playerFactory: @MainActor () -> AVPlayer
  private let audioSession = AVAudioSession.sharedInstance()
  private var observerBag: AVPlayerVideoPlaybackObserverBag?
  private var sessionID: UUID?
  private var currentItemIdentifier: ObjectIdentifier?
  private var completedSessionID: UUID?
  private var failedSessionID: UUID?
  private var playbackIntent = VideoPlaybackIntentTracker()

  init(playerFactory: @escaping @MainActor () -> AVPlayer = { AVPlayer() }) {
    self.playerFactory = playerFactory
  }

  func load(url: URL, sessionID: UUID) {
    let player = ensurePlayer()
    playbackIntent.stop()
    player.pause()
    let item = AVPlayerItem(url: url)
    let itemIdentifier = ObjectIdentifier(item)
    self.sessionID = sessionID
    currentItemIdentifier = itemIdentifier
    completedSessionID = nil
    failedSessionID = nil
    player.replaceCurrentItem(with: item)
    observerBag?.replaceItemStateObservation(
      item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.handleItemStateChange(
            itemIdentifier: itemIdentifier,
            sessionID: sessionID
          )
        }
      }
    )
    emit(.snapshot(sessionID: sessionID, state: .loading))
  }

  func play() {
    guard let player, let sessionID, player.currentItem != nil else { return }
    if completedSessionID == sessionID {
      completedSessionID = nil
    }
    playbackIntent.requestPlay()
    prepareAudioSession()
    player.play()
    emit(.snapshot(sessionID: sessionID, state: .loading))
  }

  func pause(deactivateAudioSession: Bool) {
    playbackIntent.stop()
    player?.pause()
    if deactivateAudioSession {
      self.deactivateAudioSession()
    }
  }

  func reset(deactivateAudioSession: Bool) {
    playbackIntent.stop()
    observerBag?.replaceItemStateObservation(nil)
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    sessionID = nil
    currentItemIdentifier = nil
    completedSessionID = nil
    failedSessionID = nil
    if deactivateAudioSession {
      self.deactivateAudioSession()
    }
  }

  private func ensurePlayer() -> AVPlayer {
    if let player { return player }
    let player = playerFactory()
    self.player = player
    let observerBag = AVPlayerVideoPlaybackObserverBag(player: player)
    self.observerBag = observerBag
    installObservers(player: player, observerBag: observerBag)
    return player
  }

  private func installObservers(
    player: AVPlayer,
    observerBag: AVPlayerVideoPlaybackObserverBag
  ) {
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
      self.sessionID == sessionID,
      currentItemIdentifier == itemIdentifier
    else { return }
    publishCurrentSnapshot()
  }

  private func publishCurrentSnapshot() {
    guard
      let player,
      let item = player.currentItem,
      let sessionID,
      sessionID != failedSessionID
    else { return }

    if sessionID == completedSessionID {
      switch player.timeControlStatus {
      case .playing, .waitingToPlayAtSpecifiedRate:
        completedSessionID = nil
      case .paused:
        return
      @unknown default:
        return
      }
    }

    switch item.status {
    case .unknown, .readyToPlay:
      let state = playbackIntent.state(
        for: player.timeControlStatus,
        itemIsReady: item.status == .readyToPlay
      )
      emit(.snapshot(sessionID: sessionID, state: state))
    case .failed:
      handleFailure(itemIdentifier: ObjectIdentifier(item))
    @unknown default:
      handleFailure(itemIdentifier: ObjectIdentifier(item))
    }
  }

  private func handleEnded(itemIdentifier: ObjectIdentifier?) {
    guard
      itemIdentifier == currentItemIdentifier,
      let sessionID,
      sessionID != failedSessionID,
      sessionID != completedSessionID
    else { return }
    completedSessionID = sessionID
    playbackIntent.stop()
    player?.pause()
    player?.seek(to: .zero)
    emit(.ended(sessionID: sessionID))
  }

  private func handleFailure(itemIdentifier: ObjectIdentifier?) {
    guard
      itemIdentifier == currentItemIdentifier,
      let sessionID,
      sessionID != completedSessionID,
      sessionID != failedSessionID
    else { return }
    failedSessionID = sessionID
    playbackIntent.stop()
    player?.pause()
    emit(.failed(sessionID: sessionID, message: "player item failed"))
  }

  private func interruptPlayback() {
    guard
      let sessionID,
      sessionID != completedSessionID,
      sessionID != failedSessionID
    else { return }
    playbackIntent.stop()
    player?.pause()
    emit(.interrupted(sessionID: sessionID))
  }

  private func prepareAudioSession() {
    do {
      try audioSession.setCategory(.playback, mode: .moviePlayback)
      try audioSession.setActive(true)
    } catch {
      // AVPlayer still reports a concrete playback failure if the route cannot
      // be activated; transport details are intentionally not surfaced in UI.
    }
  }

  private func deactivateAudioSession() {
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func emit(_ event: VideoPlaybackEngineEvent) {
    eventHandler?(event)
  }
}

@MainActor
enum AVPlayerViewControllerDelegateRetention {
  // AVKit's delegate is weak, while a full-screen presentation can outlive the
  // SwiftUI representable that created its coordinator.
  private static let associationKeyObject = NSObject()

  static func retain(
    _ delegate: (any AVPlayerViewControllerDelegate)?,
    on viewController: AVPlayerViewController
  ) {
    let key = UnsafeRawPointer(Unmanaged.passUnretained(associationKeyObject).toOpaque())
    objc_setAssociatedObject(
      viewController,
      key,
      delegate,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    viewController.delegate = delegate
  }
}

struct InlineVideoPlayer: UIViewControllerRepresentable {
  let player: AVPlayer
  let ownerID: UUID
  let sessionID: UUID
  @ObservedObject var controller: VideoPlaybackController

  func makeCoordinator() -> Coordinator {
    Coordinator(
      controller: controller,
      ownerID: ownerID,
      sessionID: sessionID
    )
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let viewController = AVPlayerViewController()
    configure(viewController, coordinator: context.coordinator)
    return viewController
  }

  func updateUIViewController(
    _ viewController: AVPlayerViewController,
    context: Context
  ) {
    context.coordinator.update(
      controller: controller,
      ownerID: ownerID,
      sessionID: sessionID
    )
    configure(viewController, coordinator: context.coordinator)
  }

  private func configure(
    _ viewController: AVPlayerViewController,
    coordinator: Coordinator
  ) {
    AVPlayerViewControllerDelegateRetention.retain(coordinator, on: viewController)
    viewController.player = player
    viewController.showsPlaybackControls = true
    viewController.videoGravity = .resizeAspect
    viewController.allowsPictureInPicturePlayback = false
    viewController.canStartPictureInPictureAutomaticallyFromInline = false
    viewController.updatesNowPlayingInfoCenter = false
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private weak var controller: VideoPlaybackController?
    private var ownerID: UUID
    private var sessionID: UUID

    init(
      controller: VideoPlaybackController,
      ownerID: UUID,
      sessionID: UUID
    ) {
      self.controller = controller
      self.ownerID = ownerID
      self.sessionID = sessionID
    }

    deinit {
      let controller = controller
      let ownerID = ownerID
      let sessionID = sessionID
      Task { @MainActor in
        controller?.playerViewDelegateLifetimeDidEnd(
          ownerID: ownerID,
          sessionID: sessionID
        )
      }
    }

    func update(
      controller: VideoPlaybackController,
      ownerID: UUID,
      sessionID: UUID
    ) {
      self.controller = controller
      self.ownerID = ownerID
      self.sessionID = sessionID
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willBeginFullScreenPresentationWithAnimationCoordinator transitionCoordinator:
        any UIViewControllerTransitionCoordinator
    ) {
      let ownerID = ownerID
      let sessionID = sessionID
      let controller = controller
      controller?.fullScreenPresentationWillBegin(
        ownerID: ownerID,
        sessionID: sessionID
      )
      transitionCoordinator.animate(alongsideTransition: nil) { context in
        let cancelled = context.isCancelled
        Task { @MainActor in
          controller?.fullScreenPresentationDidFinishBeginning(
            ownerID: ownerID,
            sessionID: sessionID,
            cancelled: cancelled
          )
        }
      }
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willEndFullScreenPresentationWithAnimationCoordinator transitionCoordinator:
        any UIViewControllerTransitionCoordinator
    ) {
      let ownerID = ownerID
      let sessionID = sessionID
      let controller = controller
      controller?.fullScreenPresentationWillEnd(
        ownerID: ownerID,
        sessionID: sessionID
      )
      transitionCoordinator.animate(alongsideTransition: nil) { context in
        let cancelled = context.isCancelled
        Task { @MainActor in
          controller?.fullScreenPresentationDidFinishEnding(
            ownerID: ownerID,
            sessionID: sessionID,
            cancelled: cancelled
          )
        }
      }
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      restoreUserInterfaceForFullScreenExitWithCompletionHandler completionHandler:
        @escaping @Sendable (Bool) -> Void
    ) {
      completionHandler(true)
    }
  }
}
