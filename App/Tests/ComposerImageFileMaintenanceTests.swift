import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerImageFileMaintenanceTests: XCTestCase {
  func testDeletionTombstoneSurvivesReconstructionAndAuditNeverDeletesFile() async throws {
    let environment = try FileMaintenanceTestEnvironment()
    defer { environment.remove() }
    let attachment = maintenanceAttachment(1)
    let fileURL = environment.attachmentURL(for: attachment)
    try Data("retained-private-image".utf8).write(to: fileURL)
    let first = ComposerImageAttachmentDeletionCoordinator(
      journalFileURL: environment.journalURL,
      referenceProvider: { [] }
    )

    try await first.scheduleDeletion(of: [attachment])
    let firstPendingCount = try await first.pendingDeletionCount()
    XCTAssertEqual(firstPendingCount, 1)

    let rebuilt = ComposerImageAttachmentDeletionCoordinator(
      journalFileURL: environment.journalURL,
      referenceProvider: { [] }
    )
    let report = try await rebuilt.performMaintenance()

    XCTAssertEqual(
      report,
      ComposerImageAttachmentDeletionMaintenanceReport(
        auditedTombstoneCount: 1,
        retainedReferenceCount: 0,
        remainingTombstoneCount: 1
      )
    )
    XCTAssertEqual(try Data(contentsOf: fileURL), Data("retained-private-image".utf8))
    let rebuiltPendingCount = try await rebuilt.pendingDeletionCount()
    XCTAssertEqual(rebuiltPendingCount, 1)
  }

  func testReferenceAuditFailureRetainsEveryTombstone() async throws {
    let environment = try FileMaintenanceTestEnvironment()
    defer { environment.remove() }
    let attachment = maintenanceAttachment(2)
    let coordinator = ComposerImageAttachmentDeletionCoordinator(
      journalFileURL: environment.journalURL,
      referenceProvider: { throw FileMaintenanceTestError.referenceReadFailed }
    )
    try await coordinator.scheduleDeletion(of: [attachment])

    do {
      _ = try await coordinator.performMaintenance()
      XCTFail("Expected a failed global reference audit.")
    } catch {
      XCTAssertEqual(
        error as? ComposerImageAttachmentDeletionCoordinatorError,
        .referenceAuditUnavailable
      )
    }
    let pendingCount = try await coordinator.pendingDeletionCount()
    XCTAssertEqual(pendingCount, 1)
  }

  func testTombstoneArchiveRotatesOldestAuditRecordWithoutDeletingFiles() async throws {
    let environment = try FileMaintenanceTestEnvironment()
    defer { environment.remove() }
    let coordinator = ComposerImageAttachmentDeletionCoordinator(
      journalFileURL: environment.journalURL,
      referenceProvider: { [] }
    )
    let accepted = (1...ComposerImageAttachmentDeletionCoordinator.maximumTombstoneCount).map {
      maintenanceAttachment($0)
    }
    try await coordinator.scheduleDeletion(of: accepted)

    let newest = maintenanceAttachment(
      ComposerImageAttachmentDeletionCoordinator.maximumTombstoneCount + 1
    )
    try await coordinator.scheduleDeletion(of: [newest])
    let pendingCount = try await coordinator.pendingDeletionCount()
    XCTAssertEqual(
      pendingCount,
      ComposerImageAttachmentDeletionCoordinator.maximumTombstoneCount
    )
    let pendingIDs = try await coordinator.pendingDeletionIDs()
    XCTAssertFalse(pendingIDs.contains(accepted[0].id))
    XCTAssertTrue(pendingIDs.contains(newest.id))
  }

  func testReferencePolicyProtectsRecoverableStatesAndReleasesOnlyTerminalProofs()
    throws
  {
    let submissionID = maintenanceUUID(220)
    let sessionRevision = maintenanceUUID(221)
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: submissionID,
        sessionRevision: sessionRevision
      )
    )
    let threadReceipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let replyReceipt = TextReplyReceipt.post(postID: 701)

    XCTAssertFalse(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.imageConfirmed(
          reference: reference,
          receipt: threadReceipt
        )
      )
    )
    XCTAssertFalse(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.confirmed(
          submissionID: submissionID,
          receipt: threadReceipt
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.imageAcceptedAwaitingVisibility(
          reference: reference,
          receipt: threadReceipt
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.imagePipeline(reference: reference)
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.challengeRequired(
          submissionID: submissionID,
          sessionRevision: sessionRevision
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        NewThreadDraftDisposition.outcomeUnknown(submissionID: submissionID)
      )
    )

    XCTAssertFalse(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        TextReplyDraftDisposition.imageConfirmed(
          reference: reference,
          created: .post(postID: 701, floor: 2)
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        TextReplyDraftDisposition.imageAcceptedAwaitingVisibility(
          reference: reference,
          receipt: replyReceipt
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        TextReplyDraftDisposition.imagePreparationPending(reference: reference)
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        TextReplyDraftDisposition.challengeRequired(
          submissionID: submissionID,
          sessionRevision: sessionRevision
        )
      )
    )
    XCTAssertTrue(
      ComposerImageAttachmentReferencePolicy.retainsFiles(
        TextReplyDraftDisposition.outcomeUnknown(submissionID: submissionID)
      )
    )
  }

  func testTemporaryDirectoryCleanupExpiresOnlyBoundedStrictlyNamedDirectories() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerImageTemporaryDirectoryCleanerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let now = oldDate.addingTimeInterval(
      ComposerImageTemporaryDirectoryCleaner.expirationInterval * 2
    )
    let outsideURL = rootURL.appendingPathComponent("outside-must-survive")
    let outsideData = Data("outside".utf8)
    try outsideData.write(to: outsideURL)

    var oldDirectories = [URL]()
    for index in 1...40 {
      let directory = rootURL.appendingPathComponent(
        ComposerImageTemporaryDirectoryCleaner.directoryPrefix
          + maintenanceUUID(index).uuidString.lowercased(),
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let selected = directory.appendingPathComponent(
        ComposerImageTemporaryDirectoryCleaner.selectedImageFilename
      )
      if index == 1 {
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outsideURL)
      } else {
        try Data("temporary".utf8).write(to: selected)
      }
      try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: directory.path
      )
      oldDirectories.append(directory)
    }
    let freshDirectory = rootURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.directoryPrefix
        + maintenanceUUID(200).uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: false)
    try Data("fresh".utf8).write(
      to: freshDirectory.appendingPathComponent(
        ComposerImageTemporaryDirectoryCleaner.selectedImageFilename
      )
    )
    try FileManager.default.setAttributes(
      [.modificationDate: now],
      ofItemAtPath: freshDirectory.path
    )
    let invalidDirectory = rootURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.directoryPrefix + "not-a-uuid",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: invalidDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: invalidDirectory.path
    )
    let cleaner = ComposerImageTemporaryDirectoryCleaner(rootURL: rootURL)

    let first = cleaner.cleanup(now: now)
    XCTAssertEqual(first.removedDirectoryCount, 32)
    XCTAssertEqual(
      oldDirectories.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
      8
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: freshDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalidDirectory.path))
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)

    let second = cleaner.cleanup(now: now)
    XCTAssertEqual(second.removedDirectoryCount, 8)
    XCTAssertFalse(oldDirectories.contains { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: freshDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalidDirectory.path))
  }

  func testTemporaryCleanupDoesNotRecursivelyRemoveMalformedDirectory() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerImageTemporaryDirectoryMalformedTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let directory = rootURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.directoryPrefix
        + maintenanceUUID(210).uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data("temporary".utf8).write(
      to: directory.appendingPathComponent(
        ComposerImageTemporaryDirectoryCleaner.selectedImageFilename
      )
    )
    let unexpected = directory.appendingPathComponent("unexpected")
    try Data("retain".utf8).write(to: unexpected)
    let oldDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: directory.path
    )

    let report = ComposerImageTemporaryDirectoryCleaner(rootURL: rootURL).cleanup(
      now: oldDate.addingTimeInterval(
        ComposerImageTemporaryDirectoryCleaner.expirationInterval * 2
      )
    )

    XCTAssertEqual(report.expiredCandidateCount, 1)
    XCTAssertEqual(report.removedDirectoryCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertEqual(try Data(contentsOf: unexpected), Data("retain".utf8))
  }
}

struct ImmediateComposerImageAttachmentDeletionScheduler:
  ComposerImageAttachmentDeletionScheduling
{
  let store: ComposerImageAttachmentStore

  func scheduleDeletion(of attachments: [ComposerImageAttachment]) async throws {
    for attachment in attachments {
      try await store.remove(attachment)
    }
  }
}

private struct FileMaintenanceTestEnvironment {
  let rootURL: URL
  let attachmentDirectoryURL: URL
  let journalURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComposerImageFileMaintenanceTests-\(UUID().uuidString)",
      isDirectory: true
    )
    attachmentDirectoryURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    journalURL = rootURL.appendingPathComponent("deletion-tombstones.json")
    try FileManager.default.createDirectory(
      at: attachmentDirectoryURL,
      withIntermediateDirectories: true
    )
  }

  func attachmentURL(for attachment: ComposerImageAttachment) -> URL {
    attachmentDirectoryURL.appendingPathComponent(attachment.relativePrivateFilename)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private enum FileMaintenanceTestError: Error {
  case referenceReadFailed
}

private func maintenanceUUID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

private func maintenanceAttachment(_ value: Int) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: maintenanceUUID(value),
    sha256: String(repeating: String(format: "%02x", value % 256), count: 32),
    byteCount: Int64(2_000 + value),
    pixelWidth: 120,
    pixelHeight: 90,
    quality: .standard
  )!
}
