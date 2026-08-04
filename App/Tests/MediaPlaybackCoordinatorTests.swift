import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class MediaPlaybackCoordinatorTests: XCTestCase {
  func testAcquireCreatesCurrentLeaseWithReadableOwnership() throws {
    let coordinator = MediaPlaybackCoordinator()
    let participant = MediaPlaybackParticipantSpy()
    let ownerID = UUID()

    let lease = try XCTUnwrap(
      coordinator.acquire(kind: .voice, ownerID: ownerID, participant: participant)
    )

    XCTAssertEqual(lease.kind, .voice)
    XCTAssertEqual(lease.ownerID, ownerID)
    XCTAssertTrue(coordinator.hasCurrentLease)
    XCTAssertTrue(coordinator.isCurrent(lease))
    XCTAssertTrue(participant.revocations.isEmpty)
  }

  func testSameParticipantKindAndOwnerReusesLeaseWithoutRevoking() throws {
    let coordinator = MediaPlaybackCoordinator()
    let participant = MediaPlaybackParticipantSpy()
    let ownerID = UUID()
    let firstLease = try XCTUnwrap(
      coordinator.acquire(kind: .video, ownerID: ownerID, participant: participant)
    )

    let secondLease = try XCTUnwrap(
      coordinator.acquire(kind: .video, ownerID: ownerID, participant: participant)
    )

    XCTAssertEqual(secondLease, firstLease)
    XCTAssertTrue(coordinator.isCurrent(firstLease))
    XCTAssertTrue(participant.revocations.isEmpty)
  }

  func testChangingAnyOwnershipDimensionCreatesAReplacementLease() throws {
    let coordinator = MediaPlaybackCoordinator()
    let firstParticipant = MediaPlaybackParticipantSpy()
    let secondParticipant = MediaPlaybackParticipantSpy()
    let firstOwnerID = UUID()
    let secondOwnerID = UUID()
    let firstLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: firstOwnerID,
        participant: firstParticipant
      )
    )

    let ownerReplacement = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: secondOwnerID,
        participant: firstParticipant
      )
    )
    let kindReplacement = try XCTUnwrap(
      coordinator.acquire(
        kind: .video,
        ownerID: secondOwnerID,
        participant: firstParticipant
      )
    )
    let participantReplacement = try XCTUnwrap(
      coordinator.acquire(
        kind: .video,
        ownerID: secondOwnerID,
        participant: secondParticipant
      )
    )

    XCTAssertNotEqual(ownerReplacement, firstLease)
    XCTAssertNotEqual(kindReplacement, ownerReplacement)
    XCTAssertNotEqual(participantReplacement, kindReplacement)
    XCTAssertEqual(
      firstParticipant.revocations,
      [
        .init(lease: firstLease, reason: .superseded(by: .voice)),
        .init(lease: ownerReplacement, reason: .superseded(by: .video)),
        .init(lease: kindReplacement, reason: .superseded(by: .video)),
      ]
    )
    XCTAssertTrue(secondParticipant.revocations.isEmpty)
    XCTAssertTrue(coordinator.isCurrent(participantReplacement))
  }

  func testReplacementIsInstalledBeforePreviousParticipantIsRevoked() throws {
    let coordinator = MediaPlaybackCoordinator()
    let firstParticipant = MediaPlaybackParticipantSpy()
    let secondParticipant = MediaPlaybackParticipantSpy()
    let reentrantParticipant = MediaPlaybackParticipantSpy()
    let firstLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: firstParticipant
      )
    )
    var reentrantLease: MediaPlaybackLease?

    firstParticipant.onRevocation = { _, _ in
      reentrantLease = coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: reentrantParticipant
      )
    }

    let supersededRequest = coordinator.acquire(
      kind: .video,
      ownerID: UUID(),
      participant: secondParticipant
    )

    XCTAssertNil(supersededRequest)
    XCTAssertFalse(coordinator.isCurrent(firstLease))
    XCTAssertEqual(
      firstParticipant.revocations,
      [.init(lease: firstLease, reason: .superseded(by: .video))]
    )
    XCTAssertEqual(secondParticipant.revocations.count, 1)
    XCTAssertEqual(secondParticipant.revocations.first?.reason, .superseded(by: .voice))
    XCTAssertTrue(coordinator.isCurrent(try XCTUnwrap(reentrantLease)))
  }

  func testLateRelinquishCannotClearReplacementLease() throws {
    let coordinator = MediaPlaybackCoordinator()
    let firstParticipant = MediaPlaybackParticipantSpy()
    let secondParticipant = MediaPlaybackParticipantSpy()
    let firstLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: firstParticipant
      )
    )
    let secondLease = try XCTUnwrap(
      coordinator.acquire(
        kind: .video,
        ownerID: UUID(),
        participant: secondParticipant
      )
    )

    coordinator.relinquish(firstLease)

    XCTAssertFalse(coordinator.isCurrent(firstLease))
    XCTAssertTrue(coordinator.isCurrent(secondLease))
    coordinator.relinquish(secondLease)
    XCTAssertFalse(coordinator.hasCurrentLease)
    XCTAssertFalse(coordinator.isCurrent(secondLease))
  }

  func testCoordinatorDoesNotRetainCurrentParticipant() throws {
    let coordinator = MediaPlaybackCoordinator()
    var participant: MediaPlaybackParticipantSpy? = MediaPlaybackParticipantSpy()
    weak var weakParticipant = participant
    let lease = try XCTUnwrap(
      coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: try XCTUnwrap(participant)
      )
    )

    participant = nil

    XCTAssertNil(weakParticipant)
    XCTAssertTrue(coordinator.isCurrent(lease))

    let replacement = try XCTUnwrap(
      coordinator.acquire(
        kind: .video,
        ownerID: UUID(),
        participant: MediaPlaybackParticipantSpy()
      )
    )
    XCTAssertTrue(coordinator.isCurrent(replacement))
  }

  func testInactiveSceneClearsBeforeRevocationAndRejectsReentrantClaims() throws {
    let coordinator = MediaPlaybackCoordinator()
    let participant = MediaPlaybackParticipantSpy()
    let reentrantParticipant = MediaPlaybackParticipantSpy()
    let lease = try XCTUnwrap(
      coordinator.acquire(
        kind: .video,
        ownerID: UUID(),
        participant: participant
      )
    )
    var wasCurrentDuringCallback: Bool?
    var reentrantLease: MediaPlaybackLease?
    participant.onRevocation = { revokedLease, _ in
      wasCurrentDuringCallback = coordinator.isCurrent(revokedLease)
      reentrantLease = coordinator.acquire(
        kind: .voice,
        ownerID: UUID(),
        participant: reentrantParticipant
      )
    }

    coordinator.setSceneActive(false)

    XCTAssertEqual(wasCurrentDuringCallback, false)
    XCTAssertNil(reentrantLease)
    XCTAssertFalse(coordinator.isCurrent(lease))
    XCTAssertEqual(
      participant.revocations,
      [.init(lease: lease, reason: .sceneInactive)]
    )

    coordinator.setSceneActive(false)
    XCTAssertEqual(participant.revocations.count, 1)
  }

  func testSceneRecoveryDoesNotRestoreOldLeaseButAllowsANewClaim() throws {
    let coordinator = MediaPlaybackCoordinator()
    let participant = MediaPlaybackParticipantSpy()
    let ownerID = UUID()
    let oldLease = try XCTUnwrap(
      coordinator.acquire(kind: .voice, ownerID: ownerID, participant: participant)
    )

    coordinator.setSceneActive(false)

    XCTAssertNil(
      coordinator.acquire(kind: .voice, ownerID: ownerID, participant: participant)
    )

    coordinator.setSceneActive(true)

    let lease = try XCTUnwrap(
      coordinator.acquire(kind: .voice, ownerID: ownerID, participant: participant)
    )
    XCTAssertNotEqual(lease, oldLease)
    XCTAssertFalse(coordinator.isCurrent(oldLease))
    XCTAssertTrue(coordinator.isCurrent(lease))
    XCTAssertEqual(
      participant.revocations,
      [.init(lease: oldLease, reason: .sceneInactive)]
    )
  }
}

@MainActor
private final class MediaPlaybackParticipantSpy: MediaPlaybackParticipant {
  struct Revocation: Equatable {
    let lease: MediaPlaybackLease
    let reason: MediaPlaybackRevocationReason
  }

  private(set) var revocations = [Revocation]()
  var onRevocation: (@MainActor (MediaPlaybackLease, MediaPlaybackRevocationReason) -> Void)?

  func mediaPlaybackWasRevoked(
    lease: MediaPlaybackLease,
    reason: MediaPlaybackRevocationReason
  ) {
    revocations.append(.init(lease: lease, reason: reason))
    onRevocation?(lease, reason)
  }
}
