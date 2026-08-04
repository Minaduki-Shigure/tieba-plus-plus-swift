import Combine
import Foundation

enum MediaPlaybackKind: Hashable, Sendable {
  case voice
  case video
}

enum MediaPlaybackRevocationReason: Hashable, Sendable {
  case superseded(by: MediaPlaybackKind)
  case sceneInactive
}

struct MediaPlaybackLease: Hashable, Sendable {
  fileprivate let nonce: UUID

  let kind: MediaPlaybackKind
  let ownerID: UUID
}

@MainActor
protocol MediaPlaybackParticipant: AnyObject {
  func mediaPlaybackWasRevoked(
    lease: MediaPlaybackLease,
    reason: MediaPlaybackRevocationReason
  )
}

@MainActor
final class MediaPlaybackCoordinator: ObservableObject {
  @Published private(set) var isSceneActive: Bool

  private var currentLease: MediaPlaybackLease?
  private weak var currentParticipant: (any MediaPlaybackParticipant)?

  var hasCurrentLease: Bool {
    currentLease != nil
  }

  init(isSceneActive: Bool = true) {
    self.isSceneActive = isSceneActive
  }

  func acquire(
    kind: MediaPlaybackKind,
    ownerID: UUID,
    participant: any MediaPlaybackParticipant
  ) -> MediaPlaybackLease? {
    guard isSceneActive else { return nil }

    if
      let currentLease,
      currentLease.kind == kind,
      currentLease.ownerID == ownerID,
      currentParticipant === participant
    {
      return currentLease
    }

    let previousLease = currentLease
    let previousParticipant = currentParticipant
    let lease = MediaPlaybackLease(nonce: UUID(), kind: kind, ownerID: ownerID)

    // Publish ownership before revocation so a reentrant claim cannot be overwritten.
    currentLease = lease
    currentParticipant = participant

    if let previousLease {
      previousParticipant?.mediaPlaybackWasRevoked(
        lease: previousLease,
        reason: .superseded(by: kind)
      )
    }

    guard currentLease == lease, currentParticipant === participant else {
      return nil
    }
    return lease
  }

  func relinquish(_ lease: MediaPlaybackLease) {
    guard currentLease == lease else { return }
    currentLease = nil
    currentParticipant = nil
  }

  func isCurrent(_ lease: MediaPlaybackLease) -> Bool {
    currentLease == lease
  }

  func setSceneActive(_ isActive: Bool) {
    guard isSceneActive != isActive else { return }
    isSceneActive = isActive
    guard !isActive, let lease = currentLease else { return }

    let participant = currentParticipant
    currentLease = nil
    currentParticipant = nil
    participant?.mediaPlaybackWasRevoked(lease: lease, reason: .sceneInactive)
  }
}
