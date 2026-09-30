import Combine
import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AutomaticForumCheckInRuntimeTests: XCTestCase {
  func testDefaultOffDoesNotRegisterScheduleOrRunUntilExplicitlyConfigured() async throws {
    let fixture = makeFixture()
    XCTAssertFalse(fixture.runtime.isEnabled)
    XCTAssertEqual(fixture.runtime.minuteOfDay, 540)
    XCTAssertEqual(fixture.system.registrations, 0)
    XCTAssertTrue(fixture.system.submissions.isEmpty)
    fixture.runtime.sceneDidBecomeActive("main")
    await drainTasks()
    XCTAssertEqual(fixture.system.registrations, 0)
    XCTAssertTrue(fixture.system.submissions.isEmpty)
    XCTAssertEqual(fixture.runner.runCount, 0)

    fixture.runtime.register()
    fixture.runtime.register()
    fixture.runtime.register()
    XCTAssertEqual(fixture.system.registrations, 1)
    XCTAssertTrue(fixture.system.submissions.isEmpty)
    XCTAssertEqual(fixture.runner.runCount, 0)
  }

  func testForegroundBeforeThresholdWaitsThenRunsOnceAtThreshold() async throws {
    let fixture = makeFixture(enabled: true, date: runtimeInstant("2026-09-30T00:59:00Z"))
    fixture.runtime.sceneDidBecomeActive("main")
    try await waitUntil { await fixture.sleeper.pendingDelays.contains(60) }
    XCTAssertEqual(fixture.runner.runCount, 0)

    fixture.clock.set(runtimeInstant("2026-09-30T01:00:00Z"))
    await fixture.sleeper.release(interval: 60)
    try await waitUntil { fixture.runner.runCount == 1 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    fixture.runtime.sceneDidBecomeActive("main")
    fixture.runtime.sceneDidBecomeActive("second")
    await drainTasks()
    XCTAssertEqual(fixture.runner.runCount, 1)

    fixture.runner.finishNext(.finishedForToday)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)
    XCTAssertEqual(fixture.runner.runCount, 1)
    try await waitUntil { await fixture.sleeper.pendingDelays.contains(86_400) }
  }

  func testLateForegroundCatchUpAndBackgroundCannotOverlapAnUnsettledRun() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.register()
    fixture.runtime.sceneDidBecomeActive("main")
    try await waitUntil { fixture.runner.runCount == 1 }
    var backgroundResults: [Bool] = []
    let completion = AutomaticForumCheckInBackgroundCompletion { backgroundResults.append($0) }

    fixture.runtime.handleBackgroundRefresh(completion)
    fixture.runtime.sceneDidBecomeActive("second")
    fixture.runtime.reconcile()
    await drainTasks()
    XCTAssertEqual(backgroundResults, [false])
    XCTAssertEqual(fixture.runner.runCount, 1)
    XCTAssertEqual(fixture.runner.reconcileCount, 0)
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)

    fixture.runtime.sceneDidEnterBackground("main")
    XCTAssertTrue(
      fixture.runner.isAuthorized(at: 0), "Another active scene still owns foreground work")
    fixture.runtime.sceneDidEnterBackground("second")
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(
      fixture.runtime.hasActiveOperation, "Cancellation must not release an unsettled worker")
    fixture.runner.finishNext(.needsResume)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
  }

  func testDisableAndReenableInvalidateAuthorizationButKeepOperationLockUntilSettlement()
    async throws
  {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.sceneDidBecomeActive("main")
    try await waitUntil { fixture.runner.runCount == 1 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 0))

    fixture.runtime.setEnabled(false)
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    XCTAssertFalse(fixture.defaults.bool(forKey: AutomaticForumCheckInRuntime.enabledKey))
    fixture.runtime.setEnabled(true)
    fixture.runtime.sceneDidBecomeActive("main")
    await drainTasks()
    XCTAssertEqual(fixture.runner.runCount, 1)
    XCTAssertFalse(
      fixture.runner.isAuthorized(at: 0), "Re-enabling cannot revive the old authorization")

    fixture.runner.finishNext(.needsResume)
    try await waitUntil { fixture.runner.runCount == 2 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 1))
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)
  }

  func testAccountChangeInvalidatesOldAuthorizationAndWaitsForUncooperativeRunner() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.sceneDidBecomeActive("main")
    try await waitUntil { fixture.runner.runCount == 1 }

    fixture.runtime.accountSessionDidChange()
    fixture.runtime.sceneDidBecomeActive("main")
    await drainTasks()
    XCTAssertEqual(fixture.runner.accountChanges, 1)
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    XCTAssertEqual(fixture.runner.runCount, 1)

    fixture.runner.finishNext(.finishedForToday)
    try await waitUntil { fixture.runner.runCount == 2 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 1))
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)
  }

  func testBackgroundExpirationCompletesOnceAndKeepsNextAppointmentAndWorkerLock() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.register()
    let initialAppointments = fixture.system.submissions.count
    var results: [Bool] = []
    var appointmentsAtCompletion = 0
    let completion = AutomaticForumCheckInBackgroundCompletion {
      results.append($0)
      appointmentsAtCompletion = fixture.system.submissions.count
    }
    fixture.runtime.handleBackgroundRefresh(completion)
    try await waitUntil { fixture.runner.runCount == 1 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 0))
    XCTAssertEqual(fixture.system.submissions.last, fixture.clock.read().addingTimeInterval(900))

    fixture.runtime.expireBackgroundRefresh(completion)
    fixture.runtime.expireBackgroundRefresh(completion)
    XCTAssertEqual(results, [false])
    XCTAssertGreaterThan(appointmentsAtCompletion, initialAppointments)
    XCTAssertTrue(completion.isExpired)
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)

    fixture.runtime.sceneDidBecomeActive("main")
    await drainTasks()
    XCTAssertEqual(fixture.runner.runCount, 1)
    fixture.runner.finishNext(.needsResume)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
    XCTAssertEqual(results, [false])
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)
  }

  func testBackgroundBudgetExpiresWithoutWaitingForTheRunnerToCooperate() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.register()
    var results: [Bool] = []
    let completion = AutomaticForumCheckInBackgroundCompletion { results.append($0) }
    fixture.runtime.handleBackgroundRefresh(completion)
    try await waitUntil { fixture.runner.runCount == 1 }
    try await waitUntil {
      await fixture.sleeper.pendingDelays.contains(AutomaticForumCheckInRuntime.backgroundBudget)
    }
    await fixture.sleeper.release(interval: AutomaticForumCheckInRuntime.backgroundBudget)
    try await waitUntil { completion.isFinished }
    XCTAssertEqual(results, [false])
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    fixture.runner.finishNext(.finishedForToday)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
    XCTAssertEqual(
      results, [false], "A late successful response must not complete the BG task again")
  }

  func testReadOnlyReconciliationWorksWhenDisabledWithoutStartingWriteRun() async throws {
    let fixture = makeFixture()
    fixture.runtime.reconcile()
    fixture.runtime.reconcile()
    try await waitUntil { fixture.runner.reconcileCount == 1 }
    XCTAssertEqual(fixture.runner.runCount, 0)
    XCTAssertTrue(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.system.submissions.isEmpty)
    fixture.runner.finishNext(.needsReview)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
    XCTAssertEqual(fixture.runner.runCount, 0)
    XCTAssertFalse(fixture.runtime.isEnabled)
  }

  func testPreferenceAndClockChangesRescheduleButRepeatedActivationDoesNotPushAppointmentBack()
    async throws
  {
    let fixture = makeFixture(enabled: true, date: runtimeInstant("2026-09-30T00:00:00Z"))
    fixture.runtime.register()
    XCTAssertEqual(fixture.system.submissions, [runtimeInstant("2026-09-30T01:00:00Z")])
    fixture.runtime.sceneDidBecomeActive("main")
    fixture.runtime.sceneDidBecomeActive("main")
    XCTAssertEqual(fixture.system.submissions.count, 1)

    fixture.runtime.setMinuteOfDay(10 * 60)
    XCTAssertEqual(fixture.system.submissions.last, runtimeInstant("2026-09-30T02:00:00Z"))
    XCTAssertEqual(fixture.defaults.integer(forKey: AutomaticForumCheckInRuntime.minuteKey), 600)
    fixture.runtime.setMinuteOfDay(8 * 60 + 30)
    XCTAssertEqual(fixture.system.submissions.last, runtimeInstant("2026-09-30T00:30:00Z"))

    fixture.clock.set(runtimeInstant("2026-09-29T00:00:00Z"))
    fixture.runtime.clockDidChange()
    XCTAssertEqual(fixture.system.submissions.last, runtimeInstant("2026-09-29T00:30:00Z"))
    fixture.clock.set(runtimeInstant("2026-10-01T00:00:00Z"))
    fixture.runtime.clockDidChange()
    XCTAssertEqual(fixture.system.submissions.last, runtimeInstant("2026-10-01T00:30:00Z"))
    XCTAssertEqual(fixture.runner.runCount, 0)
  }

  func testUnavailableOrFailedBackgroundRegistrationRetainsForegroundBehavior() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.system.registrationResult = false
    fixture.runtime.register()
    fixture.runtime.register()
    XCTAssertEqual(fixture.system.registrations, 1)
    XCTAssertTrue(fixture.system.submissions.isEmpty)
    XCTAssertNotNil(fixture.runtime.schedulingMessage)
    fixture.runtime.sceneDidBecomeActive("main")
    try await waitUntil { fixture.runner.runCount == 1 }
    XCTAssertTrue(fixture.runner.isAuthorized(at: 0))

    let unavailable = makeFixture(enabled: true)
    unavailable.system.backgroundAvailable = false
    unavailable.runtime.register()
    XCTAssertTrue(unavailable.system.submissions.isEmpty)
    unavailable.runtime.sceneDidBecomeActive("main")
    try await waitUntil { unavailable.runner.runCount == 1 }
    XCTAssertNotNil(unavailable.runtime.schedulingMessage)
  }

  func testBackgroundOptOutInvalidatesOnlyBackgroundWorkAndPreventsNewAppointments() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.register()
    var results: [Bool] = []
    let completion = AutomaticForumCheckInBackgroundCompletion { results.append($0) }
    fixture.runtime.handleBackgroundRefresh(completion)
    try await waitUntil { fixture.runner.runCount == 1 }

    fixture.runtime.setUsesBackgroundRefresh(false)
    XCTAssertEqual(results, [false])
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    XCTAssertFalse(fixture.defaults.bool(forKey: AutomaticForumCheckInRuntime.backgroundKey))
    let requests = fixture.system.submissions.count
    fixture.runtime.sceneDidBecomeActive("main")
    XCTAssertEqual(fixture.system.submissions.count, requests)
    fixture.runner.finishNext(.needsResume)
    try await waitUntil { fixture.runner.runCount == 2 }
    XCTAssertTrue(
      fixture.runner.isAuthorized(at: 1), "Background opt-out retains foreground check-in")
    XCTAssertEqual(fixture.runner.maximumConcurrentOperations, 1)
  }

  func testChangingTimeReplacesBackgroundAppointmentBeforeCompletingOldTask() async throws {
    let fixture = makeFixture(enabled: true)
    fixture.runtime.register()
    var results: [Bool] = []
    var appointmentAtCompletion: Date?
    let completion = AutomaticForumCheckInBackgroundCompletion {
      results.append($0)
      appointmentAtCompletion = fixture.system.submissions.last
    }
    fixture.runtime.handleBackgroundRefresh(completion)
    try await waitUntil { fixture.runner.runCount == 1 }

    fixture.runtime.setMinuteOfDay(14 * 60)
    XCTAssertEqual(results, [false])
    XCTAssertEqual(appointmentAtCompletion, runtimeInstant("2026-09-30T06:00:00Z"))
    XCTAssertFalse(fixture.runner.isAuthorized(at: 0))
    XCTAssertTrue(fixture.runtime.hasActiveOperation)
    fixture.runner.finishNext(.finishedForToday)
    try await waitUntil { !fixture.runtime.hasActiveOperation }
    XCTAssertEqual(results, [false])
  }

  private func makeFixture(
    enabled: Bool = false, date: Date = runtimeInstant("2026-09-30T04:00:00Z")
  ) -> AutomaticRuntimeFixture {
    let fixture = AutomaticRuntimeFixture(enabled: enabled, date: date)
    addTeardownBlock { @MainActor in await fixture.close() }
    return fixture
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () async -> Bool
  ) async throws {
    for _ in 0..<2_000 {
      if await condition() { return }
      await Task.yield()
    }
    XCTFail("Runtime did not reach the expected state", file: file, line: line)
    throw AutomaticRuntimeTestError.timedOut
  }

  private func drainTasks() async {
    for _ in 0..<20 { await Task.yield() }
  }
}

private enum AutomaticRuntimeTestError: Error { case timedOut }

private func runtimeInstant(_ string: String) -> Date {
  ISO8601DateFormatter().date(from: string)!
}

@MainActor
private final class AutomaticRuntimeFixture {
  let suite = "AutomaticForumCheckInRuntimeTests.\(UUID().uuidString)"
  let defaults: UserDefaults
  let clock: AutomaticRuntimeClock
  let sleeper = AutomaticRuntimeSleeper()
  let runner = AutomaticRuntimeRunner()
  let system = AutomaticRuntimeSystem()
  let runtime: AutomaticForumCheckInRuntime

  init(enabled: Bool, date: Date) {
    defaults = UserDefaults(suiteName: suite)!
    defaults.set(enabled, forKey: AutomaticForumCheckInRuntime.enabledKey)
    clock = AutomaticRuntimeClock(date)
    let clock = clock
    let sleeper = sleeper
    let system = system
    runtime = AutomaticForumCheckInRuntime(
      defaults: defaults,
      coordinator: runner,
      now: { clock.read() },
      sleep: { try await sleeper.sleep($0) },
      registerTask: { _ in
        system.registrations += 1
        return system.registrationResult
      },
      backgroundIsAvailable: { system.backgroundAvailable },
      submit: { system.submissions.append($0) },
      cancelScheduled: { system.cancellations += 1 }
    )
  }

  func close() async {
    runtime.setEnabled(false)
    runtime.sceneDidEnterBackground("main")
    runtime.sceneDidEnterBackground("second")
    runner.finishAll(.notStarted)
    for _ in 0..<100 where runtime.hasActiveOperation { await Task.yield() }
    await sleeper.cancelAll()
    defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor
private final class AutomaticRuntimeSystem {
  var registrationResult = true
  var backgroundAvailable = true
  var registrations = 0
  var submissions: [Date] = []
  var cancellations = 0
}

/// Deliberately ignores task cancellation until the test delivers an external response.
@MainActor
private final class AutomaticRuntimeRunner: AutomaticForumCheckInRunning {
  let objectWillChange = ObservableObjectPublisher()
  var statusMessage = "fixture"
  var resultDay: String?
  var summary: ForumBatchCheckInSummary?
  var entries: [ForumBatchCheckInEntry] = []
  var isRunning: Bool { !continuations.isEmpty }
  private(set) var runCount = 0
  private(set) var reconcileCount = 0
  private(set) var cancellations = 0
  private(set) var accountChanges = 0
  private(set) var maximumConcurrentOperations = 0
  private var authorizations: [@MainActor () -> Bool] = []
  private var continuations:
    [CheckedContinuation<AutomaticForumCheckInCoordinator.Outcome, Never>] = []

  func run(
    policy: ForumBatchCheckInExecutionPolicy,
    authorization: @escaping @MainActor () -> Bool
  ) async -> AutomaticForumCheckInCoordinator.Outcome {
    runCount += 1
    return await suspend(authorization: authorization)
  }

  func reconcile(
    authorization: @escaping @MainActor () -> Bool
  ) async -> AutomaticForumCheckInCoordinator.Outcome {
    reconcileCount += 1
    return await suspend(authorization: authorization)
  }

  private func suspend(
    authorization: @escaping @MainActor () -> Bool
  ) async -> AutomaticForumCheckInCoordinator.Outcome {
    authorizations.append(authorization)
    return await withCheckedContinuation {
      continuations.append($0)
      maximumConcurrentOperations = max(maximumConcurrentOperations, continuations.count)
    }
  }

  func cancel() { cancellations += 1 }
  func accountSessionDidChange() { accountChanges += 1 }
  func isAuthorized(at index: Int) -> Bool { authorizations[index]() }
  func finishNext(_ result: AutomaticForumCheckInCoordinator.Outcome) {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume(returning: result)
  }
  func finishAll(_ result: AutomaticForumCheckInCoordinator.Outcome) {
    while !continuations.isEmpty { finishNext(result) }
  }
}

private final class AutomaticRuntimeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date
  init(_ date: Date) { self.date = date }
  func read() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }
  func set(_ date: Date) {
    lock.lock()
    defer { lock.unlock() }
    self.date = date
  }
}

private actor AutomaticRuntimeSleeper {
  private struct Pending {
    let interval: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
  }
  private var pending: [UUID: Pending] = [:]
  var pendingDelays: [TimeInterval] { pending.values.map(\.interval) }

  func sleep(_ interval: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[id] = Pending(interval: interval, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func release(interval: TimeInterval) {
    let matches = pending.filter { $0.value.interval == interval }
    for (id, value) in matches {
      pending.removeValue(forKey: id)
      value.continuation.resume()
    }
  }

  func cancelAll() {
    let values = pending.values
    pending.removeAll()
    for value in values { value.continuation.resume(throwing: CancellationError()) }
  }

  private func cancel(_ id: UUID) {
    pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}
