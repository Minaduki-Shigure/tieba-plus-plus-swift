import Darwin
import Foundation
import XCTest

@testable import TiebaPlusPlus

final class CloudFavoriteMutationLedgerTests: XCTestCase {
  func testKeysContainOnlyPositiveAccountAndThreadIDs() throws {
    XCTAssertNil(CloudFavoriteMutationLedgerKey(userID: 0, threadID: 10))
    XCTAssertNil(CloudFavoriteMutationLedgerKey(userID: 7, threadID: -1))
    let encoded = try JSONEncoder().encode(key())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["userID", "threadID"])
  }

  func testRestartRestoresPendingAsUnknownAndKeepsCrossSessionResourceLock() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let originalSession = UUID()
    let pending = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: originalSession, now: date)
    let archive = try Data(contentsOf: fixture.file)
    let reopened = fixture.ledger()
    let restored = try await reopened.record(for: key())
    XCTAssertEqual(restored, pending)
    XCTAssertEqual(restored?.originSessionRevision, originalSession)
    XCTAssertEqual(restored?.restoredPhase, .outcomeUnknown)
    XCTAssertEqual(restored?.blocksWrites, true)
    XCTAssertEqual(restored?.receiptAcknowledged, false)
    let records = try await reopened.records()
    XCTAssertEqual(records, [pending])
    await assertError(.resourceLocked) {
      try await reopened.prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), archive)
  }

  func testAbsenceAloneDoesNotInventReceiptAndAllowsNewOperation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for ledger: any CloudFavoriteMutationLedgerRepository in [
      fixture.ledger(), TransientCloudFavoriteMutationLedger(),
    ] {
      let pending = try await ledger.prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
      _ = try await ledger.transition(
        key: key(), operationID: pending.operationID, phase: .outcomeUnknown, now: date)
      await assertError(.resourceLocked) {
        try await ledger.prepare(
          key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
      }
      let verified = try await ledger.transition(
        key: key(), operationID: pending.operationID, phase: .observedAbsent,
        now: date.addingTimeInterval(5))
      XCTAssertFalse(verified.receiptAcknowledged)
      XCTAssertFalse(verified.blocksWrites)
      XCTAssertEqual(verified.createdAt, date)
      XCTAssertEqual(verified.updatedAt, date.addingTimeInterval(5))
      await assertError(.operationMismatch) {
        try await ledger.prepare(
          key: key(), operationID: pending.operationID, sessionRevision: UUID(), now: date)
      }
      let replacement = try await ledger.prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date.addingTimeInterval(6))
      XCTAssertNotEqual(replacement.operationID, pending.operationID)
      XCTAssertTrue(replacement.blocksWrites)
      await assertError(.operationMismatch) {
        try await ledger.transition(
          key: key(), operationID: pending.operationID, phase: .observedAbsent, now: date)
      }
    }
  }

  func testAcceptanceStaysLockedAndReceiptSurvivesVerificationAndRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pending = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let accepted = try await fixture.ledger().transition(
      key: key(), operationID: pending.operationID, phase: .acceptedAwaitingVerification, now: date)
    XCTAssertTrue(accepted.receiptAcknowledged)
    XCTAssertTrue(accepted.blocksWrites)
    await assertError(.resourceLocked) {
      try await fixture.ledger().prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    }
    let verified = try await fixture.ledger().transition(
      key: key(), operationID: pending.operationID, phase: .observedAbsent, now: date)
    XCTAssertTrue(verified.receiptAcknowledged)
    XCTAssertFalse(verified.blocksWrites)
    let reopened = try await fixture.ledger().record(for: key())
    XCTAssertEqual(reopened, verified)
  }

  func testDefiniteFailureCanRemoveOnlyExactPendingOperation() async throws {
    let ledger = TransientCloudFavoriteMutationLedger()
    let pending = try await ledger.prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    await assertError(.operationMismatch) {
      try await ledger.removeAfterDefiniteFailure(key: key(), operationID: UUID())
    }
    try await ledger.removeAfterDefiniteFailure(key: key(), operationID: pending.operationID)
    let absent = try await ledger.record(for: key())
    XCTAssertNil(absent)
    await assertError(.missingRecord) {
      try await ledger.removeAfterDefiniteFailure(key: key(), operationID: pending.operationID)
    }
    for phase in [
      CloudFavoriteMutationLedgerPhase.outcomeUnknown, .acceptedAwaitingVerification,
      .observedAbsent,
    ] {
      let candidate = try await ledger.prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
      _ = try await ledger.transition(
        key: key(), operationID: candidate.operationID, phase: phase, now: date)
      await assertError(.invalidTransition) {
        try await ledger.removeAfterDefiniteFailure(key: key(), operationID: candidate.operationID)
      }
      _ = try await ledger.transition(
        key: key(), operationID: candidate.operationID, phase: .observedAbsent, now: date)
    }
  }

  func testTransitionsNeverRegressAndLateReceiptRequiresSameOperation() async throws {
    let ledger = TransientCloudFavoriteMutationLedger()
    let pending = try await ledger.prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    _ = try await ledger.transition(
      key: key(), operationID: pending.operationID, phase: .outcomeUnknown, now: date)
    let accepted = try await ledger.transition(
      key: key(), operationID: pending.operationID, phase: .acceptedAwaitingVerification,
      now: date.addingTimeInterval(-1))
    XCTAssertEqual(accepted.updatedAt, date)
    for invalid in [CloudFavoriteMutationLedgerPhase.dispatchPending, .outcomeUnknown] {
      await assertError(.invalidTransition) {
        try await ledger.transition(
          key: key(), operationID: pending.operationID, phase: invalid, now: date)
      }
    }
    let repeatACK = try await ledger.transition(
      key: key(), operationID: pending.operationID, phase: .acceptedAwaitingVerification,
      now: date.addingTimeInterval(10))
    XCTAssertEqual(repeatACK, accepted)
    _ = try await ledger.transition(
      key: key(), operationID: pending.operationID, phase: .observedAbsent, now: date)
    await assertError(.invalidTransition) {
      try await ledger.transition(
        key: key(), operationID: pending.operationID, phase: .acceptedAwaitingVerification,
        now: date)
    }
  }

  func testDistinctAccountAndThreadResourcesRemainIndependent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    for resource in [key(), key(userID: 8), key(threadID: 101)] {
      _ = try await ledger.prepare(
        key: resource, operationID: UUID(), sessionRevision: UUID(), now: date)
    }
    let records = try await ledger.records()
    XCTAssertEqual(records.map(\.key), [key(), key(threadID: 101), key(userID: 8)])
    await assertError(.operationMismatch) {
      try await ledger.prepare(
        key: key(userID: 9), operationID: records[0].operationID, sessionRevision: UUID(), now: date
      )
    }
  }

  func testCorruptTruncatedEmptyAndWrongKeyArchivesAreNeverOverwritten() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let original = try Data(contentsOf: fixture.file)
    for corrupt in [Data(), Data(original.dropLast()), Data("{}".utf8)] {
      try corrupt.write(to: fixture.file)
      await assertError(.corruptedArchive) { try await fixture.ledger().records() }
      await assertError(.corruptedArchive) {
        try await fixture.ledger().prepare(
          key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.file), corrupt)
    }
    try original.write(to: fixture.file)
    let wrongKey = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file, testingKey: Data(repeating: 0, count: 32))
    await assertError(.corruptedArchive) { try await wrongKey.records() }
    XCTAssertEqual(try Data(contentsOf: fixture.file), original)
  }

  func testTamperedPhaseAndAuthenticatedInvalidRecordsFailClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let original = try Data(contentsOf: fixture.file)
    let originalEnvelope = try object(original)
    let originalPayload = try XCTUnwrap(
      Data(base64Encoded: try XCTUnwrap(originalEnvelope["canonicalPayload"] as? String)))
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["phase"] = "acceptedAwaitingVerification" },  // Missing receipt evidence.
      { $0["receiptAcknowledged"] = true },  // Pending cannot carry ACK evidence.
      { $0["key"] = ["userID": 0, "threadID": 100] },
      { $0["unexpected"] = "field" },
      { $0["updatedAtMilliseconds"] = -1 },
    ]
    for signed in [false, true] {
      for mutate in mutations {
        var payload = try object(originalPayload)
        var records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        mutate(&records[0])
        payload["records"] = records
        let bytes = try canonical(payload)
        var envelope = originalEnvelope
        envelope["canonicalPayload"] = bytes.base64EncodedString()
        if signed {
          envelope["authenticationCode"] = try authenticator.authenticationCode(for: bytes)
            .base64EncodedString()
        }
        let corrupt = try canonical(envelope)
        try corrupt.write(to: fixture.file)
        await assertError(.corruptedArchive) { try await fixture.ledger().records() }
        await assertError(.corruptedArchive) {
          try await fixture.ledger().prepare(
            key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), corrupt)
      }
    }
  }

  func testWrongDomainAndUnavailableVerificationKeyCannotUnlockArchive() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let bytes = try Data(contentsOf: fixture.file)
    let wrongDomain = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file,
      authenticator: ComposerImageUploadLedgerHMACAuthenticator(testingKey: testingKey))
    await assertError(.corruptedArchive) { try await wrongDomain.records() }
    let missingKey = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file,
      authenticator: CloudFavoriteMutationLedgerHMACAuthenticator(keyStore: UnavailableKeyStore()))
    await assertError(.authenticationUnavailable) { try await missingKey.records() }
    await assertError(.authenticationUnavailable) {
      try await missingKey.prepare(
        key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
  }

  func testRecordAndFileLimitsDoNotDiscardExistingLocks() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let limited = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file, testingKey: testingKey, maximumRecords: 1)
    _ = try await limited.prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let original = try Data(contentsOf: fixture.file)
    await assertError(.capacityExceeded) {
      try await limited.prepare(
        key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), original)
    let oversized = Data(repeating: 32, count: 1_025)
    try oversized.write(to: fixture.file)
    let sizeLimited = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file, testingKey: testingKey, maximumArchiveBytes: 1_024)
    await assertError(.capacityExceeded) { try await sizeLimited.records() }
    XCTAssertEqual(try Data(contentsOf: fixture.file), oversized)
  }

  func testFailedPrepareNeverReturnsDispatchAuthorityAndPublishedPendingStaysLocked() async throws {
    for checkpoint in [ComposerDraftDurabilityCheckpoint.stagedFile, .parentDirectory] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      _ = try await fixture.ledger().prepare(
        key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
      let original = try Data(contentsOf: fixture.file)
      let failing = FileCloudFavoriteMutationLedger(
        fileURL: fixture.file, testingKey: testingKey,
        beforeDurabilitySync: { if $0 == checkpoint { throw TestFailure.injected } })
      await assertError(.writeFailed) {
        try await failing.prepare(
          key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
      }
      let restored = try await fixture.ledger().record(for: key(threadID: 101))
      if checkpoint == .stagedFile {
        XCTAssertNil(restored)
        XCTAssertEqual(try Data(contentsOf: fixture.file), original)
      } else {
        XCTAssertEqual(restored?.restoredPhase, .outcomeUnknown)
        XCTAssertEqual(restored?.blocksWrites, true)
        await assertError(.resourceLocked) {
          try await fixture.ledger().prepare(
            key: key(threadID: 101), operationID: UUID(), sessionRevision: UUID(), now: date)
        }
      }
    }
  }

  func testFailedReceiptPersistenceLeavesPendingLockRecoverable() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pending = try await fixture.ledger().prepare(
      key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
    let original = try Data(contentsOf: fixture.file)
    let failing = FileCloudFavoriteMutationLedger(
      fileURL: fixture.file, testingKey: testingKey,
      prepareStagedFile: { _ in throw TestFailure.injected })
    await assertError(.writeFailed) {
      try await failing.transition(
        key: key(), operationID: pending.operationID, phase: .acceptedAwaitingVerification,
        now: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), original)
    let recovered = try await fixture.ledger().record(for: key())
    XCTAssertEqual(recovered?.restoredPhase, .outcomeUnknown)
    XCTAssertEqual(recovered?.blocksWrites, true)
  }

  func testTwoInstancesSerializeSameAndDifferentResourcesWithoutLosingRecords() async throws {
    for sameResource in [true, false] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let gate = RaceGate()
      defer { gate.release() }
      let first = FileCloudFavoriteMutationLedger(
        fileURL: fixture.file, testingKey: testingKey,
        beforeDurabilitySync: { try gate.blockFirst($0) })
      let second = FileCloudFavoriteMutationLedger(
        fileURL: fixture.file, testingKey: testingKey,
        onExclusiveLockContention: { gate.contended() })
      let firstTask = Task.detached {
        try await first.prepare(key: key(), operationID: UUID(), sessionRevision: UUID(), now: date)
      }
      let reachedFirst = await Task.detached { gate.waitForFirst() }.value
      XCTAssertTrue(reachedFirst)
      let secondTask = Task.detached {
        try await second.prepare(
          key: key(userID: sameResource ? 7 : 8), operationID: UUID(), sessionRevision: UUID(),
          now: date)
      }
      let reachedContention = await Task.detached { gate.waitForContention() }.value
      XCTAssertTrue(reachedContention)
      gate.release()
      _ = try await firstTask.value
      if sameResource {
        await assertError(.resourceLocked) { try await secondTask.value }
      } else {
        _ = try await secondTask.value
      }
      let records = try await fixture.ledger().records()
      XCTAssertEqual(records.count, sameResource ? 1 : 2)
    }
  }

  func testSymlinkArchivesAndLockFilesFailClosed() async throws {
    for lockPath in [false, true] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let destination = fixture.directory.appendingPathComponent("untouched.json")
      let bytes = Data("untouched".utf8)
      try bytes.write(to: destination)
      let link =
        lockPath
        ? fixture.directory.appendingPathComponent(FileCloudFavoriteMutationLedger.lockFilename)
        : fixture.file
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
      await assertError(.unsafeStorage) { try await fixture.ledger().records() }
      XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }
  }

  func testDirectoryArchiveAndInvalidTimestampsDoNotCreateAuthority() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
    await assertError(.unsafeStorage) { try await fixture.ledger().records() }
    let transient = TransientCloudFavoriteMutationLedger()
    for invalid in [-1.0, Double.nan, Double.infinity] {
      await assertError(.invalidRecord) {
        try await transient.prepare(
          key: key(), operationID: UUID(), sessionRevision: UUID(),
          now: Date(timeIntervalSince1970: invalid))
      }
    }
    let records = await transient.records()
    XCTAssertTrue(records.isEmpty)
  }
}

private let testingKey = Data(repeating: 0x6B, count: 32)
private let date = Date(timeIntervalSince1970: 100)
private let authenticator = CloudFavoriteMutationLedgerHMACAuthenticator(testingKey: testingKey)
private func key(userID: Int64 = 7, threadID: Int64 = 100) -> CloudFavoriteMutationLedgerKey {
  CloudFavoriteMutationLedgerKey(userID: userID, threadID: threadID)!
}
private func object(_ data: Data) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private func canonical(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private enum TestFailure: Error { case injected }
private struct UnavailableKeyStore: ComposerImageUploadLedgerKeyStoring {
  func existingKey() throws -> Data? { nil }
  func existingOrNewKey() throws -> Data { throw TestFailure.injected }
}
private struct Fixture: Sendable {
  let directory: URL
  var file: URL { directory.appendingPathComponent("cloud-favorite-mutation-ledger.json") }
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func ledger() -> FileCloudFavoriteMutationLedger {
    FileCloudFavoriteMutationLedger(fileURL: file, testingKey: testingKey)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
private func assertError<T>(
  _ expected: CloudFavoriteMutationLedgerError, file: StaticString = #filePath, line: UInt = #line,
  _ operation: () async throws -> T
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as CloudFavoriteMutationLedgerError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected \(error)", file: file, line: line)
  }
}
private final class RaceGate: @unchecked Sendable {
  private let first = DispatchSemaphore(value: 0)
  private let contention = DispatchSemaphore(value: 0)
  private let proceed = DispatchSemaphore(value: 0)
  func blockFirst(_ checkpoint: ComposerDraftDurabilityCheckpoint) throws {
    guard checkpoint == .stagedFile else { return }
    first.signal()
    guard proceed.wait(timeout: .now() + 5) == .success else { throw TestFailure.injected }
  }
  func contended() { contention.signal() }
  func waitForFirst() -> Bool { first.wait(timeout: .now() + 5) == .success }
  func waitForContention() -> Bool { contention.wait(timeout: .now() + 5) == .success }
  func release() { proceed.signal() }
}
