import Darwin
import Foundation
import XCTest

@testable import TiebaPlusPlus

final class OwnedContentDeletionLedgerTests: XCTestCase {
  func testFileLedgerRoundTripsPendingUnknownAndAcceptedRecords() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let pendingTarget = try ownedContentDeletionLedgerTarget(objectID: 102, floor: 2)
    let pendingOperationID = ownedContentDeletionLedgerUUID(1)
    let pendingSessionRevision = ownedContentDeletionLedgerUUID(2)
    let createdAt = Date(timeIntervalSince1970: 100.123_456)
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    let pending = try await ledger.prepare(
      target: pendingTarget,
      accountID: pendingTarget.authorID,
      sessionRevision: pendingSessionRevision,
      operationID: pendingOperationID,
      at: createdAt
    )

    XCTAssertEqual(pending.phase, .dispatchPending)
    XCTAssertEqual(pending.restoredTerminal, .outcomeUnknown)
    XCTAssertEqual(try pending.reconstructedTarget(), pendingTarget)
    let loadedPending = try await ledger.record(for: pending.key)
    let loadedRecords = try await ledger.records()
    XCTAssertEqual(loadedPending, pending)
    XCTAssertEqual(loadedRecords, [pending])
    XCTAssertEqual(
      try location.file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup,
      true
    )
    #if os(iOS) && !targetEnvironment(simulator)
      let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
      XCTAssertEqual(
        attributes[.protectionKey] as? FileProtectionType,
        .completeUntilFirstUserAuthentication
      )
    #endif

    let reopenedPending = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let restoredPendingCandidate = try await reopenedPending.record(for: pending.key)
    let restoredPending = try XCTUnwrap(restoredPendingCandidate)
    XCTAssertEqual(restoredPending, pending)
    XCTAssertEqual(restoredPending.restoredTerminal, .outcomeUnknown)

    let unknown = try await reopenedPending.transition(
      for: pending.key,
      operationID: pendingOperationID,
      to: .outcomeUnknown,
      at: Date(timeIntervalSince1970: 101)
    )
    XCTAssertEqual(unknown.phase, .outcomeUnknown)
    XCTAssertEqual(unknown.restoredTerminal, .outcomeUnknown)

    let acceptedTarget = try ownedContentDeletionLedgerTarget(objectID: 103, floor: 3)
    let acceptedPending = try await reopenedPending.prepare(
      target: acceptedTarget,
      accountID: acceptedTarget.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(3),
      operationID: ownedContentDeletionLedgerUUID(4),
      at: Date(timeIntervalSince1970: 102)
    )
    let accepted = try await reopenedPending.transition(
      for: acceptedPending.key,
      operationID: acceptedPending.operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 103)
    )

    let reopenedTerminal = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let restoredUnknown = try await reopenedTerminal.record(for: pending.key)
    let restoredAccepted = try await reopenedTerminal.record(for: accepted.key)
    XCTAssertEqual(restoredUnknown?.phase, .outcomeUnknown)
    XCTAssertEqual(restoredAccepted?.restoredTerminal, .accepted)
    XCTAssertEqual(try accepted.reconstructedTarget(), acceptedTarget)
  }

  func testStableKeyIgnoresForumNameAndFloorButPrepareNeverOverwritesExistingResource() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let original = try ownedContentDeletionLedgerTarget(
      forumName: "swift",
      objectID: 202,
      floor: 2
    )
    let changedMetadata = try ownedContentDeletionLedgerTarget(
      forumName: "swift-renamed",
      objectID: 202,
      floor: 19
    )
    let originalKey = try XCTUnwrap(
      OwnedContentDeletionLedgerKey(userID: original.authorID, target: original)
    )
    let changedKey = try XCTUnwrap(
      OwnedContentDeletionLedgerKey(userID: changedMetadata.authorID, target: changedMetadata)
    )
    XCTAssertEqual(originalKey, changedKey)

    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let first = try await ledger.prepare(
      target: original,
      accountID: original.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(10),
      operationID: ownedContentDeletionLedgerUUID(11),
      at: Date(timeIntervalSince1970: 200)
    )
    let originalArchive = try Data(contentsOf: location.file)

    await assertOwnedContentDeletionLedgerError(.resourceLocked) {
      try await ledger.prepare(
        target: changedMetadata,
        accountID: changedMetadata.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(12),
        operationID: ownedContentDeletionLedgerUUID(13),
        at: Date(timeIntervalSince1970: 201)
      )
    }
    await assertOwnedContentDeletionLedgerError(.resourceLocked) {
      try await ledger.prepare(
        target: original,
        accountID: original.authorID,
        sessionRevision: first.originSessionRevision,
        operationID: first.operationID,
        at: Date(timeIntervalSince1970: 202)
      )
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalArchive)
    let retainedRecords = try await ledger.records()
    XCTAssertEqual(retainedRecords, [first])
  }

  func testTwoFileLedgersDoNotLoseDifferentResourcesDuringConcurrentPrepare() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let gate = OwnedContentDeletionLedgerRaceGate()
    let firstTarget = try ownedContentDeletionLedgerTarget(objectID: 212, floor: 2)
    let secondTarget = try ownedContentDeletionLedgerTarget(objectID: 213, floor: 3)
    let firstLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: gate.blockFirstMutation
    )
    let secondLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      onExclusiveLockContention: gate.noteSecondLockContention
    )

    let firstTask = Task {
      try await firstLedger.prepare(
        target: firstTarget,
        accountID: firstTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(14),
        operationID: ownedContentDeletionLedgerUUID(15),
        at: Date(timeIntervalSince1970: 210)
      )
    }
    defer { gate.releaseFirstMutation() }
    XCTAssertTrue(gate.waitUntilFirstMutationIsBlocked())

    let secondTask = Task {
      try await secondLedger.prepare(
        target: secondTarget,
        accountID: secondTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(16),
        operationID: ownedContentDeletionLedgerUUID(17),
        at: Date(timeIntervalSince1970: 211)
      )
    }
    XCTAssertTrue(gate.waitUntilSecondLockContention())
    gate.releaseFirstMutation()

    let first = try await firstTask.value
    let second = try await secondTask.value
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let records = try await reopened.records()
    XCTAssertEqual(Set(records), Set([first, second]))
  }

  func testContendedFileLedgerWaitHonorsTaskCancellationWithoutWriting() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let gate = OwnedContentDeletionLedgerRaceGate()
    let firstTarget = try ownedContentDeletionLedgerTarget(objectID: 218, floor: 2)
    let cancelledTarget = try ownedContentDeletionLedgerTarget(objectID: 219, floor: 3)
    let firstLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: gate.blockFirstMutation
    )
    let waitingLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      onExclusiveLockContention: gate.noteSecondLockContention
    )

    let firstTask = Task {
      try await firstLedger.prepare(
        target: firstTarget,
        accountID: firstTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(141),
        operationID: ownedContentDeletionLedgerUUID(142),
        at: Date(timeIntervalSince1970: 215)
      )
    }
    defer { gate.releaseFirstMutation() }
    XCTAssertTrue(gate.waitUntilFirstMutationIsBlocked())

    let waitingTask = Task {
      try await waitingLedger.prepare(
        target: cancelledTarget,
        accountID: cancelledTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(143),
        operationID: ownedContentDeletionLedgerUUID(144),
        at: Date(timeIntervalSince1970: 216)
      )
    }
    XCTAssertTrue(gate.waitUntilSecondLockContention())
    waitingTask.cancel()
    guard case .failure(let cancellation) = await waitingTask.result else {
      return XCTFail("the cancelled waiter must not acquire the deletion ledger lock")
    }
    XCTAssertTrue(cancellation is CancellationError)
    gate.releaseFirstMutation()

    let first = try await firstTask.value
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let records = try await reopened.records()
    XCTAssertEqual(records, [first])
    XCTAssertFalse(records.contains(where: { $0.key.objectID == cancelledTarget.objectID }))
  }

  func testTwoFileLedgersAllowOnlyOneConcurrentPrepareForTheSameResource() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let gate = OwnedContentDeletionLedgerRaceGate()
    let target = try ownedContentDeletionLedgerTarget(objectID: 222, floor: 2)
    let firstLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: gate.blockFirstMutation
    )
    let secondLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      onExclusiveLockContention: gate.noteSecondLockContention
    )

    let firstTask = Task {
      try await firstLedger.prepare(
        target: target,
        accountID: target.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(18),
        operationID: ownedContentDeletionLedgerUUID(19),
        at: Date(timeIntervalSince1970: 220)
      )
    }
    defer { gate.releaseFirstMutation() }
    XCTAssertTrue(gate.waitUntilFirstMutationIsBlocked())

    let secondTask = Task { () -> OwnedContentDeletionLedgerError? in
      do {
        _ = try await secondLedger.prepare(
          target: target,
          accountID: target.authorID,
          sessionRevision: ownedContentDeletionLedgerUUID(20),
          operationID: ownedContentDeletionLedgerUUID(21),
          at: Date(timeIntervalSince1970: 221)
        )
        return nil
      } catch let error as OwnedContentDeletionLedgerError {
        return error
      } catch {
        return .writeFailed
      }
    }
    XCTAssertTrue(gate.waitUntilSecondLockContention())
    gate.releaseFirstMutation()

    let first = try await firstTask.value
    let secondError = await secondTask.value
    XCTAssertEqual(secondError, .resourceLocked)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let records = try await reopened.records()
    XCTAssertEqual(records, [first])
  }

  func testConcurrentMutationCannotRollAcceptedTerminalBackToPending() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let originalTarget = try ownedContentDeletionLedgerTarget(objectID: 232, floor: 2)
    let addedTarget = try ownedContentDeletionLedgerTarget(objectID: 233, floor: 3)
    let seedLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let pending = try await seedLedger.prepare(
      target: originalTarget,
      accountID: originalTarget.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(23),
      operationID: ownedContentDeletionLedgerUUID(24),
      at: Date(timeIntervalSince1970: 230)
    )

    let gate = OwnedContentDeletionLedgerRaceGate()
    let addingLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: gate.blockFirstMutation
    )
    let terminalLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      onExclusiveLockContention: gate.noteSecondLockContention
    )
    let addTask = Task {
      try await addingLedger.prepare(
        target: addedTarget,
        accountID: addedTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(25),
        operationID: ownedContentDeletionLedgerUUID(26),
        at: Date(timeIntervalSince1970: 231)
      )
    }
    defer { gate.releaseFirstMutation() }
    XCTAssertTrue(gate.waitUntilFirstMutationIsBlocked())

    let terminalTask = Task {
      try await terminalLedger.transition(
        for: pending.key,
        operationID: pending.operationID,
        to: .accepted,
        at: Date(timeIntervalSince1970: 232)
      )
    }
    XCTAssertTrue(gate.waitUntilSecondLockContention())
    gate.releaseFirstMutation()

    let added = try await addTask.value
    let accepted = try await terminalTask.value
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let records = try await reopened.records()
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records.contains(added))
    XCTAssertEqual(records.first(where: { $0.key == pending.key }), accepted)
    XCTAssertEqual(accepted.phase, .accepted)
  }

  func testTransitionClampsWallClockRollbackWithoutLosingTerminal() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 242, floor: 2)
    let pending = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(27),
      operationID: ownedContentDeletionLedgerUUID(28),
      at: Date(timeIntervalSince1970: 240)
    )

    let accepted = try await ledger.transition(
      for: pending.key,
      operationID: pending.operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 140)
    )

    XCTAssertEqual(accepted.phase, .accepted)
    XCTAssertEqual(accepted.updatedAt, pending.updatedAt)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let restored = try await reopened.record(for: pending.key)
    XCTAssertEqual(restored, accepted)
  }

  func testPersistentLockKeepsTheSameInodeAcrossLedgerReconstruction() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let target = try ownedContentDeletionLedgerTarget(objectID: 252, floor: 2)
    let firstLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let pending = try await firstLedger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(29),
      operationID: ownedContentDeletionLedgerUUID(30),
      at: Date(timeIntervalSince1970: 250)
    )
    let lockURL = location.directory.appendingPathComponent(
      FileOwnedContentDeletionLedger.lockFilename,
      isDirectory: false
    )
    let initialLockStatus = try ownedContentDeletionLedgerStatus(at: lockURL)

    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    _ = try await reopened.transition(
      for: pending.key,
      operationID: pending.operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 251)
    )
    let finalLockStatus = try ownedContentDeletionLedgerStatus(at: lockURL)

    XCTAssertEqual(initialLockStatus.st_dev, finalLockStatus.st_dev)
    XCTAssertEqual(initialLockStatus.st_ino, finalLockStatus.st_ino)
    XCTAssertEqual(finalLockStatus.st_nlink, 1)
    XCTAssertEqual(
      finalLockStatus.st_mode & mode_t(S_IFMT),
      mode_t(S_IFREG)
    )
  }

  func testHostilePersistentLockPathsFailClosedWithoutTouchingTheirTargets() async throws {
    for kind in OwnedContentDeletionLedgerHostileLockKind.allCases {
      let location = try makeOwnedContentDeletionLedgerLocation()
      let lockURL = location.directory.appendingPathComponent(
        FileOwnedContentDeletionLedger.lockFilename,
        isDirectory: false
      )
      let sentinelURL = location.directory.appendingPathComponent(
        "sentinel-\(kind.rawValue)",
        isDirectory: false
      )
      let sentinel = Data("sentinel-\(kind.rawValue)".utf8)
      do {
        defer { try? FileManager.default.removeItem(at: location.directory) }
        switch kind {
        case .symbolicLink:
          try sentinel.write(to: sentinelURL)
          try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: sentinelURL
          )
        case .directory:
          try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        case .fifo:
          try createOwnedContentDeletionLedgerFIFO(at: lockURL)
        case .hardLink:
          try sentinel.write(to: sentinelURL)
          try FileManager.default.linkItem(at: sentinelURL, to: lockURL)
        }

        let ledger = FileOwnedContentDeletionLedger(
          fileURL: location.file,
          testingKey: ownedContentDeletionLedgerTestingKey
        )
        await assertOwnedContentDeletionLedgerError(.unsafeStorage) {
          try await ledger.records()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
        if kind == .symbolicLink || kind == .hardLink {
          XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        }
      }
    }
  }

  func testOperationIDCASAndTerminalTransitionsFailClosed() async throws {
    let target = try ownedContentDeletionLedgerTarget(objectID: 302, floor: 4)
    let operationID = ownedContentDeletionLedgerUUID(20)
    let wrongOperationID = ownedContentDeletionLedgerUUID(21)
    let ledger = TransientOwnedContentDeletionLedger()
    let pending = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(22),
      operationID: operationID,
      at: Date(timeIntervalSince1970: 300)
    )

    await assertOwnedContentDeletionLedgerError(.operationMismatch) {
      try await ledger.transition(
        for: pending.key,
        operationID: wrongOperationID,
        to: .accepted,
        at: Date(timeIntervalSince1970: 301)
      )
    }
    await assertOwnedContentDeletionLedgerError(.invalidTransition) {
      try await ledger.transition(
        for: pending.key,
        operationID: operationID,
        to: .dispatchPending,
        at: Date(timeIntervalSince1970: 301)
      )
    }

    let accepted = try await ledger.transition(
      for: pending.key,
      operationID: operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 302)
    )
    XCTAssertEqual(accepted.phase, .accepted)
    let repeatedAccepted = try await ledger.transition(
      for: pending.key,
      operationID: operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 303)
    )
    XCTAssertEqual(repeatedAccepted, accepted)
    await assertOwnedContentDeletionLedgerError(.invalidTransition) {
      try await ledger.transition(
        for: pending.key,
        operationID: operationID,
        to: .outcomeUnknown,
        at: Date(timeIntervalSince1970: 304)
      )
    }
    await assertOwnedContentDeletionLedgerError(.invalidTransition) {
      try await ledger.removeDispatchPending(for: pending.key, operationID: operationID)
    }
  }

  func testDispatchPendingCanOnlyBeRemovedByMatchingOperation() async throws {
    let target = try ownedContentDeletionLedgerTarget(objectID: 402, floor: 5)
    let operationID = ownedContentDeletionLedgerUUID(30)
    let ledger = TransientOwnedContentDeletionLedger()
    let pending = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(31),
      operationID: operationID,
      at: Date(timeIntervalSince1970: 400)
    )

    await assertOwnedContentDeletionLedgerError(.operationMismatch) {
      try await ledger.removeDispatchPending(
        for: pending.key,
        operationID: ownedContentDeletionLedgerUUID(32)
      )
    }
    try await ledger.removeDispatchPending(for: pending.key, operationID: operationID)
    let removed = try await ledger.record(for: pending.key)
    XCTAssertNil(removed)
  }

  func testOperationIDCannotBeReusedForAnotherResource() async throws {
    let ledger = TransientOwnedContentDeletionLedger()
    let operationID = ownedContentDeletionLedgerUUID(40)
    let first = try ownedContentDeletionLedgerTarget(objectID: 502, floor: 2)
    let second = try ownedContentDeletionLedgerTarget(objectID: 503, floor: 3)
    _ = try await ledger.prepare(
      target: first,
      accountID: first.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(41),
      operationID: operationID,
      at: Date(timeIntervalSince1970: 500)
    )

    await assertOwnedContentDeletionLedgerError(.operationIDConflict) {
      try await ledger.prepare(
        target: second,
        accountID: second.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(42),
        operationID: operationID,
        at: Date(timeIntervalSince1970: 501)
      )
    }
  }

  func testCapacityRefusesNewRecordWithoutEvictingOrRewritingExistingRecord() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      maximumRecords: 1
    )
    let firstTarget = try ownedContentDeletionLedgerTarget(objectID: 602, floor: 2)
    let first = try await ledger.prepare(
      target: firstTarget,
      accountID: firstTarget.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(50),
      operationID: ownedContentDeletionLedgerUUID(51),
      at: Date(timeIntervalSince1970: 600)
    )
    let originalArchive = try Data(contentsOf: location.file)
    let secondTarget = try ownedContentDeletionLedgerTarget(objectID: 603, floor: 3)

    await assertOwnedContentDeletionLedgerError(.tooManyRecords) {
      try await ledger.prepare(
        target: secondTarget,
        accountID: secondTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(52),
        operationID: ownedContentDeletionLedgerUUID(53),
        at: Date(timeIntervalSince1970: 601)
      )
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalArchive)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      maximumRecords: 1
    )
    let retainedRecords = try await reopened.records()
    XCTAssertEqual(retainedRecords, [first])
  }

  func testCorruptedArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let corrupted = Data(#"{"records":["#.utf8)
    try corrupted.write(to: location.file)
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    await assertOwnedContentDeletionLedgerError(.corruptedArchive) {
      try await ledger.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .corruptedArchive,
      originalData: corrupted,
      location: location,
      ledger: ledger
    )
  }

  func testFutureSchemaFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let futurePayload = Data(#"{"records":[],"schemaVersion":99}"#.utf8)
    let future = try ownedContentDeletionLedgerEnvelope(
      canonicalPayload: futurePayload
    )
    try future.write(to: location.file)
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    await assertOwnedContentDeletionLedgerError(.unsupportedSchemaVersion(99)) {
      try await ledger.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .unsupportedSchemaVersion(99),
      originalData: future,
      location: location,
      ledger: ledger
    )
  }

  func testOversizedArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let oversized = Data(repeating: 0x41, count: 1_025)
    try oversized.write(to: location.file)
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      maximumArchiveBytes: 1_024
    )

    await assertOwnedContentDeletionLedgerError(.archiveTooLarge) {
      try await ledger.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .archiveTooLarge,
      originalData: oversized,
      location: location,
      ledger: ledger
    )
  }

  func testDuplicateStableKeyArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 702, floor: 2)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(60),
      operationID: ownedContentDeletionLedgerUUID(61),
      at: Date(timeIntervalSince1970: 700)
    )
    var archive = try ownedContentDeletionLedgerJSONObject(at: location.file)
    var records = try XCTUnwrap(archive["records"] as? [[String: Any]])
    records.append(try XCTUnwrap(records.first))
    archive["records"] = records
    let duplicatePayload = try JSONSerialization.data(
      withJSONObject: archive,
      options: [.sortedKeys]
    )
    let duplicate = try ownedContentDeletionLedgerEnvelope(
      canonicalPayload: duplicatePayload
    )
    try duplicate.write(to: location.file)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    await assertOwnedContentDeletionLedgerError(.corruptedArchive) {
      try await reopened.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .corruptedArchive,
      originalData: duplicate,
      location: location,
      ledger: reopened
    )
  }

  func testInvalidTargetSnapshotArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 802, floor: 8)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(70),
      operationID: ownedContentDeletionLedgerUUID(71),
      at: Date(timeIntervalSince1970: 800)
    )
    var archive = try ownedContentDeletionLedgerJSONObject(at: location.file)
    var records = try XCTUnwrap(archive["records"] as? [[String: Any]])
    var record = try XCTUnwrap(records.first)
    var snapshot = try XCTUnwrap(record["targetSnapshot"] as? [String: Any])
    snapshot["floor"] = 1
    record["targetSnapshot"] = snapshot
    records[0] = record
    archive["records"] = records
    let invalidPayload = try JSONSerialization.data(
      withJSONObject: archive,
      options: [.sortedKeys]
    )
    let invalid = try ownedContentDeletionLedgerEnvelope(canonicalPayload: invalidPayload)
    try invalid.write(to: location.file)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    await assertOwnedContentDeletionLedgerError(.corruptedArchive) {
      try await reopened.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .corruptedArchive,
      originalData: invalid,
      location: location,
      ledger: reopened
    )
  }

  func testTamperedAuthenticatedPayloadFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 852, floor: 8)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(75),
      operationID: ownedContentDeletionLedgerUUID(76),
      at: Date(timeIntervalSince1970: 850)
    )
    let originalEnvelope = try ownedContentDeletionLedgerDecodedEnvelope(at: location.file)
    let originalPayload = try XCTUnwrap(
      String(data: originalEnvelope.canonicalPayload, encoding: .utf8)
    )
    let tamperedPayload = Data(
      originalPayload.replacingOccurrences(of: "swift", with: "twift").utf8
    )
    XCTAssertNotEqual(tamperedPayload, originalEnvelope.canonicalPayload)
    let tampered = try ownedContentDeletionLedgerEncodeEnvelope(
      OwnedContentDeletionLedgerTestEnvelope(
        schemaVersion: originalEnvelope.schemaVersion,
        canonicalPayload: tamperedPayload,
        authenticationCode: originalEnvelope.authenticationCode
      )
    )
    try tampered.write(to: location.file)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )

    await assertOwnedContentDeletionLedgerError(.authenticationFailed) {
      try await reopened.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .authenticationFailed,
      originalData: tampered,
      location: location,
      ledger: reopened
    )
  }

  func testWrongAuthenticationKeyFailsClosedAndUsesIndependentDomain() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 862, floor: 8)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(77),
      operationID: ownedContentDeletionLedgerUUID(78),
      at: Date(timeIntervalSince1970: 860)
    )
    let originalData = try Data(contentsOf: location.file)
    let wrongKey = Data(repeating: 0x7E, count: 32)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: wrongKey
    )

    await assertOwnedContentDeletionLedgerError(.authenticationFailed) {
      try await reopened.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .authenticationFailed,
      originalData: originalData,
      location: location,
      ledger: reopened
    )

    let payload = Data("same-payload".utf8)
    let deletionCode = try OwnedContentDeletionLedgerHMACAuthenticator(
      testingKey: ownedContentDeletionLedgerTestingKey
    ).authenticationCode(for: payload)
    let uploadCode = try ComposerImageUploadLedgerHMACAuthenticator(
      testingKey: ownedContentDeletionLedgerTestingKey
    ).authenticationCode(for: payload)
    XCTAssertNotEqual(deletionCode, uploadCode)
  }

  func testMissingAuthenticationKeyFailsClosedAndDoesNotOverwrite() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let ledger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let target = try ownedContentDeletionLedgerTarget(objectID: 872, floor: 8)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(79),
      operationID: ownedContentDeletionLedgerUUID(80),
      at: Date(timeIntervalSince1970: 870)
    )
    let originalData = try Data(contentsOf: location.file)
    let missingKeyAuthenticator = OwnedContentDeletionLedgerHMACAuthenticator(
      keyStore: MissingOwnedContentDeletionLedgerKeyStore()
    )
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      authenticator: missingKeyAuthenticator
    )

    await assertOwnedContentDeletionLedgerError(.authenticationUnavailable) {
      try await reopened.records()
    }
    await assertPrepareDoesNotOverwrite(
      expectedError: .authenticationUnavailable,
      originalData: originalData,
      location: location,
      ledger: reopened
    )
  }

  func testStagedDurabilityFailureDoesNotPublishPartialArchive() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let initialLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let firstTarget = try ownedContentDeletionLedgerTarget(objectID: 902, floor: 2)
    let first = try await initialLedger.prepare(
      target: firstTarget,
      accountID: firstTarget.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(80),
      operationID: ownedContentDeletionLedgerUUID(81),
      at: Date(timeIntervalSince1970: 900)
    )
    let originalArchive = try Data(contentsOf: location.file)
    let failingLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .stagedFile {
          throw OwnedContentDeletionLedgerTestError.injectedFailure
        }
      }
    )
    let secondTarget = try ownedContentDeletionLedgerTarget(objectID: 903, floor: 3)

    await assertOwnedContentDeletionLedgerError(.writeFailed) {
      try await failingLedger.prepare(
        target: secondTarget,
        accountID: secondTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(82),
        operationID: ownedContentDeletionLedgerUUID(83),
        at: Date(timeIntervalSince1970: 901)
      )
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalArchive)
    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let retainedRecords = try await reopened.records()
    XCTAssertEqual(retainedRecords, [first])
  }

  func testParentDirectoryDurabilityFailurePublishesCompletePendingRecord() async throws {
    let location = try makeOwnedContentDeletionLedgerLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let initialLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let firstTarget = try ownedContentDeletionLedgerTarget(objectID: 952, floor: 2)
    let first = try await initialLedger.prepare(
      target: firstTarget,
      accountID: firstTarget.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(84),
      operationID: ownedContentDeletionLedgerUUID(85),
      at: Date(timeIntervalSince1970: 950)
    )
    let failingLedger = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .parentDirectory {
          throw OwnedContentDeletionLedgerTestError.injectedFailure
        }
      }
    )
    let secondTarget = try ownedContentDeletionLedgerTarget(objectID: 953, floor: 3)
    let secondOperationID = ownedContentDeletionLedgerUUID(86)
    let secondKey = try XCTUnwrap(
      OwnedContentDeletionLedgerKey(userID: secondTarget.authorID, target: secondTarget)
    )

    await assertOwnedContentDeletionLedgerError(.writeFailed) {
      try await failingLedger.prepare(
        target: secondTarget,
        accountID: secondTarget.authorID,
        sessionRevision: ownedContentDeletionLedgerUUID(87),
        operationID: secondOperationID,
        at: Date(timeIntervalSince1970: 951)
      )
    }

    let reopened = FileOwnedContentDeletionLedger(
      fileURL: location.file,
      testingKey: ownedContentDeletionLedgerTestingKey
    )
    let records = try await reopened.records()
    let publishedPendingCandidate = try await reopened.record(for: secondKey)
    let publishedPending = try XCTUnwrap(publishedPendingCandidate)
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records.contains(first))
    XCTAssertEqual(publishedPending.operationID, secondOperationID)
    XCTAssertEqual(publishedPending.phase, .dispatchPending)
    XCTAssertEqual(publishedPending.restoredTerminal, .outcomeUnknown)
    XCTAssertEqual(try publishedPending.reconstructedTarget(), secondTarget)
  }

  func testTransientLedgerValidatesSeedAndKeepsFileLedgerSemantics() async throws {
    let target = try ownedContentDeletionLedgerTarget(objectID: 1_002, floor: 2)
    let firstLedger = TransientOwnedContentDeletionLedger()
    let pending = try await firstLedger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(90),
      operationID: ownedContentDeletionLedgerUUID(91),
      at: Date(timeIntervalSince1970: 1_000)
    )
    let rebuilt = try TransientOwnedContentDeletionLedger(records: [pending])

    let rebuiltRecords = try await rebuilt.records()
    let rebuiltPending = try await rebuilt.record(for: pending.key)
    XCTAssertEqual(rebuiltRecords, [pending])
    XCTAssertEqual(rebuiltPending?.restoredTerminal, .outcomeUnknown)
    let accepted = try await rebuilt.transition(
      for: pending.key,
      operationID: pending.operationID,
      to: .accepted,
      at: Date(timeIntervalSince1970: 1_001)
    )
    XCTAssertEqual(accepted.restoredTerminal, .accepted)

    XCTAssertThrowsError(
      try TransientOwnedContentDeletionLedger(records: [pending, pending])
    ) { error in
      XCTAssertEqual(error as? OwnedContentDeletionLedgerError, .corruptedArchive)
    }
  }
}

private enum OwnedContentDeletionLedgerTestError: Error {
  case injectedFailure
  case timedOut
}

private final class OwnedContentDeletionLedgerRaceGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var firstMutationIsBlocked = false
  private var secondLockContended = false
  private var firstMutationIsReleased = false

  func blockFirstMutation(_ checkpoint: ComposerDraftDurabilityCheckpoint) throws {
    guard checkpoint == .stagedFile else { return }
    condition.lock()
    firstMutationIsBlocked = true
    condition.broadcast()
    let deadline = Date().addingTimeInterval(5)
    while !firstMutationIsReleased {
      guard condition.wait(until: deadline) else {
        condition.unlock()
        throw OwnedContentDeletionLedgerTestError.timedOut
      }
    }
    condition.unlock()
  }

  func noteSecondLockContention() {
    condition.lock()
    secondLockContended = true
    condition.broadcast()
    condition.unlock()
  }

  func waitUntilFirstMutationIsBlocked() -> Bool {
    waitUntil { firstMutationIsBlocked }
  }

  func waitUntilSecondLockContention() -> Bool {
    waitUntil { secondLockContended }
  }

  func releaseFirstMutation() {
    condition.lock()
    firstMutationIsReleased = true
    condition.broadcast()
    condition.unlock()
  }

  private func waitUntil(_ predicate: () -> Bool) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
}

private enum OwnedContentDeletionLedgerHostileLockKind: String, CaseIterable, Equatable {
  case symbolicLink
  case directory
  case fifo
  case hardLink
}

private func createOwnedContentDeletionLedgerFIFO(at url: URL) throws {
  let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path else { return -1 }
    return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
  }
  guard result == 0 else { throw OwnedContentDeletionLedgerTestError.injectedFailure }
}

private func ownedContentDeletionLedgerStatus(at url: URL) throws -> stat {
  var status = stat()
  let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path else { return -1 }
    return Darwin.lstat(path, &status)
  }
  guard result == 0 else { throw OwnedContentDeletionLedgerTestError.injectedFailure }
  return status
}

private let ownedContentDeletionLedgerTestingKey = Data(repeating: 0x5D, count: 32)

private struct MissingOwnedContentDeletionLedgerKeyStore:
  ComposerImageUploadLedgerKeyStoring, Sendable
{
  func existingKey() throws -> Data? { nil }

  func existingOrNewKey() throws -> Data {
    throw OwnedContentDeletionLedgerTestError.injectedFailure
  }
}

private struct OwnedContentDeletionLedgerTestEnvelope: Codable {
  let schemaVersion: Int
  let canonicalPayload: Data
  let authenticationCode: Data
}

private struct OwnedContentDeletionLedgerTestLocation {
  let directory: URL
  let file: URL
}

private func makeOwnedContentDeletionLedgerLocation() throws
  -> OwnedContentDeletionLedgerTestLocation
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "OwnedContentDeletionLedgerTests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return OwnedContentDeletionLedgerTestLocation(
    directory: directory,
    file: directory.appendingPathComponent("ledger.json", isDirectory: false)
  )
}

private func ownedContentDeletionLedgerTarget(
  forumName: String = "swift",
  objectID: Int64,
  floor: Int,
  userID: Int64 = 7
) throws -> OwnedContentDeletionTarget {
  try XCTUnwrap(
    OwnedContentDeletionTarget(
      kind: .post,
      forumID: 42,
      forumName: forumName,
      threadID: 100,
      objectID: objectID,
      authorID: userID,
      floor: floor
    )
  )
}

private func ownedContentDeletionLedgerUUID(_ value: Int) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-0000-0000-%012llx",
      Int64(value)
    )
  )!
}

private func ownedContentDeletionLedgerJSONObject(at url: URL) throws -> [String: Any] {
  let envelope = try ownedContentDeletionLedgerDecodedEnvelope(at: url)
  return try XCTUnwrap(
    JSONSerialization.jsonObject(with: envelope.canonicalPayload) as? [String: Any]
  )
}

private func ownedContentDeletionLedgerEnvelope(
  canonicalPayload: Data,
  testingKey: Data = ownedContentDeletionLedgerTestingKey
) throws -> Data {
  let authenticationCode = try OwnedContentDeletionLedgerHMACAuthenticator(
    testingKey: testingKey
  ).authenticationCode(for: canonicalPayload)
  return try ownedContentDeletionLedgerEncodeEnvelope(
    OwnedContentDeletionLedgerTestEnvelope(
      schemaVersion: FileOwnedContentDeletionLedger.schemaVersion,
      canonicalPayload: canonicalPayload,
      authenticationCode: authenticationCode
    )
  )
}

private func ownedContentDeletionLedgerDecodedEnvelope(
  at url: URL
) throws -> OwnedContentDeletionLedgerTestEnvelope {
  try JSONDecoder().decode(
    OwnedContentDeletionLedgerTestEnvelope.self,
    from: Data(contentsOf: url)
  )
}

private func ownedContentDeletionLedgerEncodeEnvelope(
  _ envelope: OwnedContentDeletionLedgerTestEnvelope
) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(envelope)
}

private func assertPrepareDoesNotOverwrite(
  expectedError: OwnedContentDeletionLedgerError,
  originalData: Data,
  location: OwnedContentDeletionLedgerTestLocation,
  ledger: FileOwnedContentDeletionLedger,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    let target = try ownedContentDeletionLedgerTarget(objectID: 9_999, floor: 9)
    _ = try await ledger.prepare(
      target: target,
      accountID: target.authorID,
      sessionRevision: ownedContentDeletionLedgerUUID(9_998),
      operationID: ownedContentDeletionLedgerUUID(9_999),
      at: Date(timeIntervalSince1970: 9_999)
    )
    XCTFail("Expected prepare to fail closed", file: file, line: line)
  } catch let error as OwnedContentDeletionLedgerError {
    XCTAssertEqual(error, expectedError, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
  do {
    XCTAssertEqual(try Data(contentsOf: location.file), originalData, file: file, line: line)
  } catch {
    XCTFail("Unable to re-read archive: \(error)", file: file, line: line)
  }
}

private func assertOwnedContentDeletionLedgerError<T>(
  _ expected: OwnedContentDeletionLedgerError,
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () async throws -> T
) async {
  do {
    _ = try await operation()
    XCTFail("Expected deletion ledger error", file: file, line: line)
  } catch let error as OwnedContentDeletionLedgerError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
