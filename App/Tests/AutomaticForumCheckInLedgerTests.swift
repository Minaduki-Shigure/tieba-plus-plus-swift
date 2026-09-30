import Darwin
import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AutomaticForumCheckInLedgerTests: XCTestCase {
  func testClaimSurvivesReopenAndNewRunCannotBypassAccountDayTarget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let run = UUID()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    let targets = [target(42), target(43)]
    let claimed = try await fixture.ledger().claimTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: targets, at: date
    )
    XCTAssertEqual(claimed.unconfirmedCount, 2)
    let restored = try await fixture.ledger().load(userID: 7, day: "2026-09-30")
    XCTAssertEqual(restored, claimed)
    XCTAssertEqual(restored?.entries.map(\.phase), [.outcomeUnknown, .outcomeUnknown])
    let bytes = try Data(contentsOf: fixture.file)
    await assertError(.alreadyClaimed) {
      try await fixture.ledger().claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date
      )
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    // Credential/session revisions are deliberately absent from the stable key.
    _ = try await fixture.ledger().claimTargets(
      userID: 8, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date
    )
    _ = try await fixture.ledger().claimTargets(
      userID: 7, day: "2026-10-01", runID: UUID(), targets: [target(42)],
      at: timestamp("2026-10-01T09:00:00+08:00")
    )
    let yesterday = try await fixture.ledger().load(userID: 7, day: "2026-09-30")
    XCTAssertEqual(yesterday, claimed)
  }

  func testBatchClaimIsAllOrNothingAndNameConflictsFailClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    let ledger = fixture.ledger()
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    let bytes = try Data(contentsOf: fixture.file)
    await assertError(.alreadyClaimed) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43), target(42)], at: date)
    }
    await assertError(.targetConflict) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42, "another")], at: date)
    }
    await assertError(.targetConflict) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43), target(43)], at: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    let record = try await ledger.load(userID: 7, day: "2026-09-30")
    XCTAssertEqual(record?.entries.map(\.forumID), [42])
    _ = try await ledger.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(42)], at: date)
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43)], at: date)
  }

  func testOnlyExactLiveRunCanReleaseUnsettledUndispatchedClaim() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    let run = UUID()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: [target(42), target(43)], at: date)
    await assertError(.operationMismatch) {
      try await ledger.releaseUndispatchedTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    }
    await assertError(.targetConflict) {
      try await ledger.releaseUndispatchedTargets(
        userID: 7, day: "2026-09-30", runID: run, targets: [target(42, "other")], at: date)
    }
    _ = try await ledger.settleResults(
      userID: 7, day: "2026-09-30", runID: run,
      results: [.init(target: target(43), phase: .outcomeUnknown)], at: date
    )
    // A mixed release cannot remove the first claim when another was dispatched.
    await assertError(.invalidTransition) {
      try await ledger.releaseUndispatchedTargets(
        userID: 7, day: "2026-09-30", runID: run, targets: [target(42), target(43)], at: date)
    }
    let released = try await ledger.releaseUndispatchedTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: [target(42)], at: date
    )
    XCTAssertEqual(released.entries.map(\.forumID), [43])
    await assertError(.invalidTransition) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    }
    _ = try await ledger.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(43)], at: date)
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    await assertError(.alreadyClaimed) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43)], at: date)
    }
  }

  func testSettlementRequiresRunAndExactTargetsAndCannotRollbackConfirmedState() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    let run = UUID()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: [target(42), target(43)], at: date)
    await assertError(.operationMismatch) {
      try await ledger.settleResults(
        userID: 7, day: "2026-09-30", runID: UUID(),
        results: [.init(target: target(42), phase: .confirmed)], at: date)
    }
    await assertError(.targetConflict) {
      try await ledger.settleResults(
        userID: 7, day: "2026-09-30", runID: run,
        results: [.init(target: target(42, "wrong"), phase: .confirmed)], at: date)
    }
    let result = try await ledger.settleResults(
      userID: 7, day: "2026-09-30", runID: run,
      results: [
        .init(target: target(42), phase: .confirmed), .init(target: target(43), phase: .failed),
      ], at: date
    )
    XCTAssertEqual(result.confirmedCount, 1)
    XCTAssertEqual(result.failedCount, 1)
    XCTAssertEqual(result.unconfirmedCount, 0)
    for targetPhase in [AutomaticForumCheckInTargetPhase.failed, .outcomeUnknown] {
      await assertError(.invalidTransition) {
        try await ledger.settleResults(
          userID: 7, day: "2026-09-30", runID: run,
          results: [.init(target: target(42), phase: targetPhase)], at: date)
      }
    }
    await assertError(.invalidTransition) {
      try await ledger.finishDay(
        userID: 7, day: "2026-09-30", runID: run, state: .completed, at: date)
    }
    let reviewed = try await ledger.finishDay(
      userID: 7, day: "2026-09-30", runID: run, state: .needsReview,
      pausedReason: "部分贴吧未完成签到。", at: date
    )
    let restored = try await fixture.ledger().load(userID: 7, day: "2026-09-30")
    XCTAssertEqual(restored, reviewed)
  }

  func testReadBackConfirmsOldRunWithoutReclaimAndNeverAppliesTomorrowToYesterday() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42), target(43)], at: date)
    await assertError(.recordNotFound) {
      try await ledger.confirmReadBack(
        userID: 7, day: "2026-09-30", targets: [target(44)], at: date)
    }
    await assertError(.invalidDay) {
      try await ledger.confirmReadBack(
        userID: 7, day: "2026-09-30", targets: [target(42)],
        at: timestamp("2026-10-01T00:00:00+08:00"))
    }
    let confirmed = try await ledger.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(42)], at: date)
    XCTAssertEqual(confirmed.confirmedCount, 1)
    XCTAssertEqual(confirmed.unconfirmedCount, 1)
    _ = try await ledger.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(43)], at: date)
    let complete = try await ledger.finishDay(
      userID: 7, day: "2026-09-30", runID: UUID(), state: .completed, at: date)
    XCTAssertEqual(complete.state, .completed)
    await assertError(.alreadyClaimed) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(44)], at: date)
    }
  }

  func testLateReceiptChangesOnlyOriginalDayAndEmptyDayCompletionPersists() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    let oldRun = UUID()
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: oldRun, targets: [target(42)],
      at: timestamp("2026-09-30T23:59:59+08:00"))
    let nextDate = try timestamp("2026-10-01T00:00:01+08:00")
    let nextDay = try await ledger.claimTargets(
      userID: 7, day: "2026-10-01", runID: UUID(), targets: [target(42)], at: nextDate)
    _ = try await ledger.settleResults(
      userID: 7, day: "2026-09-30", runID: oldRun,
      results: [.init(target: target(42), phase: .confirmed)], at: nextDate)
    let nextReloaded = try await ledger.load(userID: 7, day: "2026-10-01")
    XCTAssertEqual(nextReloaded, nextDay)
    let empty = try await ledger.finishDay(
      userID: 8, day: "2026-10-01", runID: UUID(), state: .completed, at: nextDate)
    XCTAssertTrue(empty.entries.isEmpty)
    XCTAssertEqual(empty.state, .completed)
    let emptyReloaded = try await fixture.ledger().load(userID: 8, day: "2026-10-01")
    XCTAssertEqual(emptyReloaded, empty)
  }

  func testInvalidCalendarKeysAndNameInputsNeverCreateArchive() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    for day in ["2026-9-30", "2026-02-29", "2026-09-31", "2026-09-29", "0000-01-01", "２０２６-09-30"] {
      await assertError(.invalidDay) {
        try await ledger.claimTargets(
          userID: 7, day: day, runID: UUID(), targets: [target(42)], at: date)
      }
    }
    for invalid in [
      target(0), target(42, "\u{0000}"), target(42, "  "),
      target(42, String(repeating: "a", count: 1_025)),
    ] {
      await assertError(.invalidTarget) {
        try await ledger.claimTargets(
          userID: 7, day: "2026-09-30", runID: UUID(), targets: [invalid], at: date)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  func testRetentionKeepsRecentUnknownsAndBlocksReplayIntoPrunedDays() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger()
    for day in ["2026-08-30", "2026-09-01", "2026-09-30"] {
      _ = try await ledger.claimTargets(
        userID: 7, day: day, runID: UUID(), targets: [target(42)],
        at: timestamp("\(day)T09:00:00+08:00"))
    }
    let retained = try await ledger.load(userID: 7, day: "2026-09-01")
    XCTAssertEqual(retained?.unconfirmedCount, 1)
    await assertError(.expiredDay) { try await ledger.load(userID: 7, day: "2026-08-30") }
    await assertError(.expiredDay) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-08-30", runID: UUID(), targets: [target(42)],
        at: timestamp("2026-08-30T09:00:00+08:00"))
    }
    await assertError(.expiredDay) {
      try await fixture.ledger().claimTargets(
        userID: 8, day: "2026-08-30", runID: UUID(), targets: [target(42)],
        at: timestamp("2026-08-30T09:00:00+08:00"))
    }
  }

  func testCapacityFailureDoesNotPartiallyClaimOrOverwriteExistingTargets() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let ledger = fixture.ledger(maximumEntries: 2)
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    _ = try await ledger.claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    _ = try await ledger.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(42)], at: date)
    let bytes = try Data(contentsOf: fixture.file)
    await assertError(.capacityExceeded) {
      try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43), target(44)], at: date)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
  }

  func testStaleWorkerCannotDispatchPastAnotherWorkersUnknownOrPausedDay() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = fixture.ledger()
    let stale = fixture.ledger()
    let run = UUID()
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    let empty = try await stale.load(userID: 7, day: "2026-09-30")
    XCTAssertNil(empty)
    _ = try await first.claimTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: [target(42)], at: date)
    for nextRun in [run, UUID()] {
      await assertError(.invalidTransition) {
        try await stale.claimTargets(
          userID: 7, day: "2026-09-30", runID: nextRun, targets: [target(43)], at: date)
      }
    }
    _ = try await first.finishDay(
      userID: 7, day: "2026-09-30", runID: run, state: .needsReview, at: date)
    _ = try await first.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(42)], at: date)
    // Positive same-day readback permits the original run to continue a new target.
    _ = try await first.claimTargets(
      userID: 7, day: "2026-09-30", runID: run, targets: [target(43)], at: date)
    _ = try await first.confirmReadBack(
      userID: 7, day: "2026-09-30", targets: [target(43)], at: date)
    let paused = try await first.finishDay(
      userID: 7, day: "2026-09-30", runID: run, state: .paused,
      pausedReason: "需要手动检查。", at: date)
    for state in [AutomaticForumCheckInDayState.inProgress, .completed, .needsReview] {
      await assertError(.invalidTransition) {
        try await stale.finishDay(
          userID: 7, day: "2026-09-30", runID: UUID(), state: state, at: date)
      }
    }
    await assertError(.invalidTransition) {
      try await stale.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(44)], at: date)
    }
    let restored = try await stale.load(userID: 7, day: "2026-09-30")
    XCTAssertEqual(restored, paused)
  }

  func testCorruptionAuthenticationAndCanonicalErrorsNeverBecomeEmptyRecords() async throws {
    for alteration in [
      "garbage", "authentication", "duplicateTarget", "extraField", "explicitNull", "futureSchema",
    ] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let ledger = fixture.ledger()
      let date = try timestamp("2026-09-30T09:00:00+08:00")
      _ = try await ledger.claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
      let original = try Data(contentsOf: fixture.file)
      var envelope = try JSONDecoder().decode(TestEnvelope.self, from: original)
      var payload = try XCTUnwrap(
        JSONSerialization.jsonObject(with: envelope.canonicalPayload) as? [String: Any])
      switch alteration {
      case "garbage": try Data("not json".utf8).write(to: fixture.file)
      case "authentication":
        envelope.canonicalPayload.append(0x20)
        try encode(envelope).write(to: fixture.file)
      case "futureSchema":
        envelope.schemaVersion = 999
        try encode(envelope).write(to: fixture.file)
      default:
        var days = try XCTUnwrap(payload["days"] as? [[String: Any]])
        if alteration == "extraField" { days[0]["sessionRevision"] = UUID().uuidString }
        if alteration == "explicitNull" { days[0]["pausedReason"] = NSNull() }
        if alteration == "duplicateTarget" {
          let entries = try XCTUnwrap(days[0]["entries"] as? [[String: Any]])
          days[0]["entries"] = entries + entries
        }
        payload["days"] = days
        envelope.canonicalPayload = try JSONSerialization.data(
          withJSONObject: payload, options: [.sortedKeys])
        envelope.authenticationCode = try AutomaticForumCheckInLedgerHMACAuthenticator(
          testingKey: testingKey
        )
        .authenticationCode(for: envelope.canonicalPayload)
        try encode(envelope).write(to: fixture.file)
      }
      let damaged = try Data(contentsOf: fixture.file)
      let expected: AutomaticForumCheckInLedgerError =
        alteration == "authentication"
        ? .authenticationFailed
        : (alteration == "futureSchema" ? .unsupportedSchemaVersion(999) : .corruptedArchive)
      await assertError(expected) { try await ledger.load(userID: 7, day: "2026-09-30") }
      await assertError(expected) {
        try await ledger.claimTargets(
          userID: 8, day: "2026-09-30", runID: UUID(), targets: [target(43)], at: date)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.file), damaged)
    }
  }

  func testIndependentAuthenticationDomainAndMissingKeyFailClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let date = try timestamp("2026-09-30T09:00:00+08:00")
    _ = try await fixture.ledger().claimTargets(
      userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
    let bytes = try Data(contentsOf: fixture.file)
    let envelope = try JSONDecoder().decode(TestEnvelope.self, from: bytes)
    XCTAssertFalse(
      try ComposerImageUploadLedgerHMACAuthenticator(testingKey: testingKey)
        .isValidAuthenticationCode(envelope.authenticationCode, for: envelope.canonicalPayload))
    let unavailable = FileAutomaticForumCheckInLedger(
      fileURL: fixture.file, authenticator: UnavailableAuthenticator())
    await assertError(.authenticationUnavailable) {
      try await unavailable.load(userID: 7, day: "2026-09-30")
    }
    let wrong = FileAutomaticForumCheckInLedger(
      fileURL: fixture.file, testingKey: Data(repeating: 0, count: 32))
    await assertError(.authenticationFailed) { try await wrong.load(userID: 7, day: "2026-09-30") }
    XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
  }

  func testDurabilityFailuresNeverGrantDispatchAndPublishedUnknownRemainsLocked() async throws {
    for checkpoint in [ComposerDraftDurabilityCheckpoint.stagedFile, .parentDirectory] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let date = try timestamp("2026-09-30T09:00:00+08:00")
      _ = try await fixture.ledger().claimTargets(
        userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
      _ = try await fixture.ledger().confirmReadBack(
        userID: 7, day: "2026-09-30", targets: [target(42)], at: date)
      let prior = try Data(contentsOf: fixture.file)
      let failing = FileAutomaticForumCheckInLedger(
        fileURL: fixture.file, testingKey: testingKey,
        beforeDurabilitySync: { if $0 == checkpoint { throw TestFailure.injected } }
      )
      await assertError(.writeFailed) {
        try await failing.claimTargets(
          userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43)], at: date)
      }
      let restored = try await fixture.ledger().load(userID: 7, day: "2026-09-30")
      if checkpoint == .stagedFile {
        XCTAssertEqual(try Data(contentsOf: fixture.file), prior)
        XCTAssertEqual(restored?.entries.map(\.forumID), [42])
      } else {
        XCTAssertEqual(restored?.entries.map(\.forumID), [42, 43])
        XCTAssertEqual(restored?.unconfirmedCount, 1)
        await assertError(.alreadyClaimed) {
          try await fixture.ledger().claimTargets(
            userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(43)], at: date)
        }
      }
    }
  }

  func testTwoInstancesCannotConcurrentlyClaimSameTargetOrLoseDifferentAccounts() async throws {
    for sameTarget in [true, false] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let date = try timestamp("2026-09-30T09:00:00+08:00")
      let gate = RaceGate()
      let first = FileAutomaticForumCheckInLedger(
        fileURL: fixture.file, testingKey: testingKey,
        beforeDurabilitySync: { try gate.blockFirst($0) }
      )
      let second = FileAutomaticForumCheckInLedger(
        fileURL: fixture.file, testingKey: testingKey,
        onExclusiveLockContention: { gate.contended() }
      )
      let firstTask = Task.detached {
        try await first.claimTargets(
          userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)], at: date)
      }
      let firstReached = await Task.detached { gate.waitForFirst() }.value
      XCTAssertTrue(firstReached)
      let secondTask = Task.detached {
        try await second.claimTargets(
          userID: sameTarget ? 7 : 8, day: "2026-09-30", runID: UUID(),
          targets: [target(sameTarget ? 42 : 43)],
          at: date)
      }
      let didContend = await Task.detached { gate.waitForContention() }.value
      XCTAssertTrue(didContend)
      gate.release()
      _ = try await firstTask.value
      if sameTarget {
        await assertError(.alreadyClaimed) { try await secondTask.value }
      } else {
        _ = try await secondTask.value
      }
      let record = try await fixture.ledger().load(userID: 7, day: "2026-09-30")
      XCTAssertEqual(record?.entries.map(\.forumID), [42])
      if !sameTarget {
        let other = try await fixture.ledger().load(userID: 8, day: "2026-09-30")
        XCTAssertEqual(other?.entries.map(\.forumID), [43])
      }
    }
  }

  func testSymlinkArchiveAndPersistentLockFailClosedWithoutTouchingDestination() async throws {
    for lockPath in [true, false] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let destination = fixture.directory.appendingPathComponent("untouched")
      let original = Data("unchanged".utf8)
      try original.write(to: destination)
      let malicious =
        lockPath
        ? fixture.directory.appendingPathComponent(FileAutomaticForumCheckInLedger.lockFilename)
        : fixture.file
      try FileManager.default.createSymbolicLink(at: malicious, withDestinationURL: destination)
      await assertError(.unsafeStorage) {
        try await fixture.ledger().claimTargets(
          userID: 7, day: "2026-09-30", runID: UUID(), targets: [target(42)],
          at: timestamp("2026-09-30T09:00:00+08:00"))
      }
      XCTAssertEqual(try Data(contentsOf: destination), original)
    }
  }

  private func assertError<T: Sendable>(
    _ expected: AutomaticForumCheckInLedgerError,
    operation: @MainActor () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? AutomaticForumCheckInLedgerError, expected, file: file, line: line)
    }
  }
}

private let testingKey = Data(repeating: 0x69, count: 32)
private enum TestFailure: Error { case injected, timedOut }
private struct TestEnvelope: Codable {
  var schemaVersion: Int
  var canonicalPayload: Data
  var authenticationCode: Data
}
private struct UnavailableAuthenticator: ComposerImageUploadLedgerAuthenticating {
  func authenticationCode(for canonicalPayload: Data) throws -> Data { throw TestFailure.injected }
  func isValidAuthenticationCode(_ authenticationCode: Data, for canonicalPayload: Data) throws
    -> Bool
  { throw TestFailure.injected }
}
private struct Fixture: Sendable {
  let directory: URL
  var file: URL { directory.appendingPathComponent("ledger.json") }
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AutomaticCheckInLedgerTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func ledger(maximumEntries: Int = FileAutomaticForumCheckInLedger.defaultMaximumEntries)
    -> FileAutomaticForumCheckInLedger
  {
    FileAutomaticForumCheckInLedger(
      fileURL: file, testingKey: testingKey, maximumEntries: maximumEntries)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
private func target(_ id: Int64, _ name: String = "swift") -> ForumBatchCheckInTarget {
  ForumBatchCheckInTarget(forumID: id, forumName: name)
}
private func timestamp(_ value: String) throws -> Date {
  try XCTUnwrap(ISO8601DateFormatter().date(from: value))
}
private func encode<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}
private final class RaceGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var blocked = false
  private var contention = false
  private var released = false
  func blockFirst(_ checkpoint: ComposerDraftDurabilityCheckpoint) throws {
    guard checkpoint == .stagedFile else { return }
    condition.lock()
    defer { condition.unlock() }
    blocked = true
    condition.broadcast()
    let deadline = Date().addingTimeInterval(5)
    while !released {
      guard condition.wait(until: deadline) else { throw TestFailure.timedOut }
    }
  }
  func contended() {
    condition.lock()
    defer { condition.unlock() }
    contention = true
    condition.broadcast()
  }
  func release() {
    condition.lock()
    defer { condition.unlock() }
    released = true
    condition.broadcast()
  }
  func waitForFirst() -> Bool { wait { blocked } }
  func waitForContention() -> Bool { wait { contention } }
  private func wait(_ predicate: () -> Bool) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }
}
