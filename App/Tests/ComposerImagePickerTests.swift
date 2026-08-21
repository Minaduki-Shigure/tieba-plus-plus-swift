import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerImagePickerTests: XCTestCase {
  func testMaximumAttachmentCountIsNine() {
    XCTAssertEqual(ComposerImagePickerPolicy.maximumAttachmentCount, 9)
  }

  func testRemainingCapacityClampsInvalidAndOverfullCounts() {
    XCTAssertEqual(
      ComposerImagePickerPolicy.remainingCapacity(existingCount: -1),
      ComposerImagePickerPolicy.maximumAttachmentCount
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.remainingCapacity(existingCount: 4),
      ComposerImagePickerPolicy.maximumAttachmentCount - 4
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.remainingCapacity(
        existingCount: ComposerImagePickerPolicy.maximumAttachmentCount
      ),
      0
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.remainingCapacity(
        existingCount: ComposerImagePickerPolicy.maximumAttachmentCount + 1
      ),
      0
    )
  }

  func testAcceptedSelectionCountNeverExceedsRemainingCapacity() {
    XCTAssertEqual(
      ComposerImagePickerPolicy.acceptedSelectionCount(requestedCount: 8, existingCount: 4),
      5
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.acceptedSelectionCount(requestedCount: 2, existingCount: 4),
      2
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.acceptedSelectionCount(requestedCount: -1, existingCount: 4),
      0
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.acceptedSelectionCount(
        requestedCount: 1,
        existingCount: ComposerImagePickerPolicy.maximumAttachmentCount
      ),
      0
    )
  }

  func testMovingPreservesStableOrderAndRejectsOutOfBoundsMoves() {
    let original = ["first", "second", "third"]

    XCTAssertEqual(
      ComposerImagePickerPolicy.moving(original, from: 1, by: -1),
      ["second", "first", "third"]
    )
    XCTAssertEqual(
      ComposerImagePickerPolicy.moving(original, from: 1, by: 1),
      ["first", "third", "second"]
    )
    XCTAssertEqual(ComposerImagePickerPolicy.moving(original, from: 0, by: -1), original)
    XCTAssertEqual(ComposerImagePickerPolicy.moving(original, from: 2, by: 1), original)
    XCTAssertEqual(ComposerImagePickerPolicy.moving(original, from: 9, by: -1), original)
  }

  func testFailedRemovalRestoresOriginalOrderOnlyWhenSnapshotIsStillCurrent() {
    XCTAssertEqual(
      ComposerImagePickerPolicy.restoring(
        "second",
        at: 1,
        currentItems: ["first", "third"],
        expectedItems: ["first", "third"]
      ),
      ["first", "second", "third"]
    )
    XCTAssertNil(
      ComposerImagePickerPolicy.restoring(
        "second",
        at: 1,
        currentItems: ["newer", "snapshot"],
        expectedItems: ["first", "third"]
      )
    )
  }

  func testQualityOptionsUseProductWordingAndStableOrder() {
    XCTAssertEqual(ComposerImagePickerPolicy.qualityOptions, [.standard, .highQuality])
    XCTAssertEqual(ComposerImagePickerPolicy.label(for: .standard), "标准")
    XCTAssertEqual(ComposerImagePickerPolicy.label(for: .highQuality), "高清")
  }

  func testWatermarkOptionsUseProductWordingAndStableOrder() {
    XCTAssertEqual(ComposerImagePickerPolicy.watermarkOptions, [.forumName, .username, .none])
    XCTAssertEqual(ComposerImagePickerPolicy.label(for: .forumName), "吧名")
    XCTAssertEqual(ComposerImagePickerPolicy.label(for: .username), "用户名")
    XCTAssertEqual(ComposerImagePickerPolicy.label(for: .none), "无水印")
  }

  func testCleanupCandidatesForgetOnlyAttachmentsConfirmedBySavedDraft() {
    let first = pickerTestAttachment(1)
    let second = pickerTestAttachment(2)
    var candidates = ComposerImageCleanupCandidates()

    candidates.observe(first, userID: 7)
    candidates.observe(second, userID: 7)
    candidates.observe(first, userID: 7)
    candidates.observe(first, userID: 8)
    XCTAssertEqual(candidates.attachments(for: 7), [first, second])
    XCTAssertEqual(candidates.attachments(for: 8), [first])

    candidates.markPersisted([first], userID: 7)
    XCTAssertEqual(candidates.attachments(for: 7), [second])
    XCTAssertEqual(candidates.attachments(for: 8), [first])
  }

  @MainActor
  func testRemovalPersistsCompleteRemainingSnapshotBeforeCleanup() async throws {
    let removed = pickerTestAttachment(3)
    let remaining = [pickerTestAttachment(4), pickerTestAttachment(5)]
    var events = [String]()

    try await ComposerImageRemovalCoordinator.persistRemovalThenCleanCandidate(
      removedAttachment: removed,
      remainingAttachments: remaining,
      persist: { snapshot in
        XCTAssertEqual(snapshot, remaining)
        events.append("persist")
      },
      cleanCandidate: { candidates in
        XCTAssertEqual(candidates, [removed])
        events.append("cleanup")
      }
    )

    XCTAssertEqual(events, ["persist", "cleanup"])
  }

  @MainActor
  func testRemovalPersistenceFailureRetainsFileCandidate() async {
    let removed = pickerTestAttachment(6)
    var didRequestCleanup = false

    do {
      try await ComposerImageRemovalCoordinator.persistRemovalThenCleanCandidate(
        removedAttachment: removed,
        remainingAttachments: [],
        persist: { _ in throw ComposerImageRemovalTestError.persistenceFailed },
        cleanCandidate: { _ in didRequestCleanup = true }
      )
      XCTFail("Expected persistence failure")
    } catch ComposerImageRemovalTestError.persistenceFailed {
      // Expected: cleanup must not run when the durable snapshot write fails.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertFalse(didRequestCleanup)
  }

  func testImportDrainWaitIsBoundedToTwoSeconds() {
    XCTAssertEqual(
      ComposerImageImportDrainPolicy.pollIntervalNanoseconds
        * UInt64(ComposerImageImportDrainPolicy.maximumPollCount),
      2_000_000_000
    )
    XCTAssertTrue(
      ComposerImageImportDrainPolicy.shouldContinueWaiting(
        isBusy: true,
        completedPollCount: ComposerImageImportDrainPolicy.maximumPollCount - 1
      )
    )
    XCTAssertFalse(
      ComposerImageImportDrainPolicy.shouldContinueWaiting(
        isBusy: true,
        completedPollCount: ComposerImageImportDrainPolicy.maximumPollCount
      )
    )
    XCTAssertFalse(
      ComposerImageImportDrainPolicy.shouldContinueWaiting(
        isBusy: false,
        completedPollCount: 0
      )
    )
  }

  @MainActor
  func testImportCancellationControllerCancelsOnlyActiveOperation() {
    let controller = ComposerImageImportCancellationController()
    var cancellationCount = 0
    let completedID = pickerTestUUID(7)

    controller.register(id: completedID) { cancellationCount += 1 }
    XCTAssertTrue(controller.hasActiveImport)
    controller.finish(id: completedID)
    controller.cancel()
    XCTAssertEqual(cancellationCount, 0)

    controller.register(id: pickerTestUUID(8)) { cancellationCount += 1 }
    controller.cancel()
    controller.cancel()
    XCTAssertEqual(cancellationCount, 1)
    XCTAssertFalse(controller.hasActiveImport)
  }
}

private enum ComposerImageRemovalTestError: Error {
  case persistenceFailed
}

private func pickerTestUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func pickerTestAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: pickerTestUUID(value),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(2_000 + Int(value)),
    pixelWidth: 120,
    pixelHeight: 90,
    quality: .standard
  )!
}
