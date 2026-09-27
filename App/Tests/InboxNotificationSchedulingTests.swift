import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class InboxNotificationSchedulingTests: XCTestCase {
  func testBackgroundWorkCanCompleteOnlyAfterNextRequestIsSubmitted() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    var finished = false
    let work = Task {
      let result = await fixture.scheduler.refreshAuthorizationAndSchedule()
      finished = true
      return result
    }
    try await fixture.waitForAuthorization(count: 1)
    XCTAssertFalse(finished)
    XCTAssertTrue(fixture.requests.isEmpty)

    fixture.resolveAuthorization(at: 0, authorized: true)
    let result = await work.value

    XCTAssertEqual(result, .scheduled)
    XCTAssertTrue(finished)
    XCTAssertEqual(fixture.requests, [fixture.date.addingTimeInterval(30 * 60)])
  }

  func testBackgroundTransitionSubmitsSynchronouslyUsingLastPermission() async {
    let fixture = InboxSchedulingFixture()
    let initial = await fixture.scheduler.refreshAuthorizationAndSchedule()
    XCTAssertEqual(initial, .scheduled)
    let checks = fixture.authorizationChecks
    fixture.date = fixture.date.addingTimeInterval(60)
    fixture.suspendsAuthorization = true

    let result = fixture.scheduler.scheduleUsingCachedAuthorization()

    XCTAssertEqual(result, .scheduled)
    XCTAssertEqual(fixture.requests.count, 2)
    XCTAssertEqual(fixture.requests.last, fixture.date.addingTimeInterval(30 * 60))
    XCTAssertEqual(fixture.authorizationChecks, checks)
  }

  func testRevokedPermissionCancelsExistingRequestAndCannotRepeatBackgroundWakeup() async {
    let fixture = InboxSchedulingFixture()
    _ = await fixture.scheduler.refreshAuthorizationAndSchedule()
    XCTAssertNotNil(fixture.pendingRequest)
    fixture.authorized = false

    let result = await fixture.scheduler.refreshAuthorizationAndSchedule()
    let later = fixture.scheduler.scheduleUsingCachedAuthorization()

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(later, .skipped)
    XCTAssertNil(fixture.pendingRequest)
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertEqual(fixture.authorizationChecks, 2)
  }

  func testDisableWhilePermissionLookupIsSuspendedPreventsLateRequest() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let work = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    fixture.scheduler.setEnabled(false)
    fixture.resolveAuthorization(at: 0, authorized: true)
    let result = await work.value

    XCTAssertEqual(result, .skipped)
    XCTAssertFalse(fixture.scheduler.isEnabled)
    XCTAssertTrue(fixture.requests.isEmpty)
    XCTAssertNil(fixture.pendingRequest)
  }

  func testDisableAndReenableCannotReuseOldPermissionLookup() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let work = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    fixture.scheduler.setEnabled(false)
    fixture.scheduler.setEnabled(true)
    fixture.resolveAuthorization(at: 0, authorized: true)
    let result = await work.value

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(fixture.scheduler.scheduleUsingCachedAuthorization(), .skipped)
    XCTAssertTrue(fixture.requests.isEmpty)
  }

  func testNewestPermissionResultWinsWhenCallbacksReturnOutOfOrder() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let older = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)
    let newer = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 2)

    fixture.resolveAuthorization(at: 1, authorized: false)
    let newResult = await newer.value
    fixture.resolveAuthorization(at: 0, authorized: true)
    let oldResult = await older.value

    XCTAssertEqual(newResult, .skipped)
    XCTAssertEqual(oldResult, .skipped)
    XCTAssertEqual(fixture.scheduler.scheduleUsingCachedAuthorization(), .skipped)
    XCTAssertTrue(fixture.requests.isEmpty)
  }

  func testFreshPromptResultSchedulesBeforeBaselineAndRejectsOlderSettingsLookup() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let oldLookup = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    let promptResult = fixture.scheduler.authorizationDidChange(true)

    XCTAssertEqual(promptResult, .scheduled)
    XCTAssertNotNil(fixture.pendingRequest)
    fixture.resolveAuthorization(at: 0, authorized: false)
    let oldResult = await oldLookup.value
    XCTAssertEqual(oldResult, .skipped)
    XCTAssertNotNil(fixture.pendingRequest)
    XCTAssertEqual(fixture.requests.count, 1)
  }

  func testCancelledLookupCannotScheduleEvenWhenProviderIgnoresCancellation() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let work = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    work.cancel()
    fixture.resolveAuthorization(at: 0, authorized: true)
    let result = await work.value

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(fixture.scheduler.scheduleUsingCachedAuthorization(), .skipped)
    XCTAssertTrue(fixture.requests.isEmpty)
  }

  func testAccountChangeInvalidatesLookupButRetainsKnownSystemPermission() async throws {
    let fixture = InboxSchedulingFixture()
    _ = await fixture.scheduler.refreshAuthorizationAndSchedule()
    fixture.suspendsAuthorization = true
    let work = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    fixture.scheduler.invalidate()
    XCTAssertNil(fixture.pendingRequest)
    fixture.resolveAuthorization(at: 0, authorized: false)
    let result = await work.value

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(fixture.scheduler.scheduleUsingCachedAuthorization(), .scheduled)
    XCTAssertEqual(fixture.requests.count, 2)
  }

  func testBackgroundRefreshBecomingUnavailableDuringLookupPreventsSubmission() async throws {
    let fixture = InboxSchedulingFixture()
    fixture.suspendsAuthorization = true
    let work = Task { await fixture.scheduler.refreshAuthorizationAndSchedule() }
    try await fixture.waitForAuthorization(count: 1)

    fixture.backgroundRefreshAvailable = false
    fixture.resolveAuthorization(at: 0, authorized: true)
    let result = await work.value

    XCTAssertEqual(result, .skipped)
    XCTAssertTrue(fixture.requests.isEmpty)
    XCTAssertNil(fixture.pendingRequest)
  }

  func testSubmissionFailureIsReportedWithoutRetry() async {
    let fixture = InboxSchedulingFixture()
    fixture.failsSubmission = true

    let result = await fixture.scheduler.refreshAuthorizationAndSchedule()

    XCTAssertEqual(result, .failed)
    XCTAssertEqual(fixture.submissionAttempts, 1)
    XCTAssertNil(fixture.pendingRequest)
  }

  func testColdLaunchDoesNotEraseExistingRequestBeforePermissionIsKnown() {
    let fixture = InboxSchedulingFixture()
    fixture.pendingRequest = fixture.date.addingTimeInterval(900)

    let result = fixture.scheduler.scheduleUsingCachedAuthorization()

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(fixture.pendingRequest, fixture.date.addingTimeInterval(900))
    XCTAssertEqual(fixture.authorizationChecks, 0)
  }

  func testDisabledPreferenceDoesNotReadPermissionOrSchedule() async {
    let fixture = InboxSchedulingFixture()
    fixture.scheduler.setEnabled(false)

    let result = await fixture.scheduler.refreshAuthorizationAndSchedule()

    XCTAssertEqual(result, .skipped)
    XCTAssertEqual(fixture.authorizationChecks, 0)
    XCTAssertEqual(fixture.submissionAttempts, 0)
  }
}

@MainActor
private final class InboxSchedulingFixture {
  var date = Date(timeIntervalSince1970: 1_000)
  var authorized = true
  var backgroundRefreshAvailable = true
  var suspendsAuthorization = false
  var failsSubmission = false
  var authorizationChecks = 0
  var submissionAttempts = 0
  var requests: [Date] = []
  var pendingRequest: Date?
  private var continuations: [CheckedContinuation<Bool, Never>?] = []

  lazy var scheduler = InboxNotificationScheduling(
    enabled: true,
    now: { self.date },
    isBackgroundRefreshAvailable: { self.backgroundRefreshAvailable },
    isAuthorized: {
      self.authorizationChecks += 1
      guard self.suspendsAuthorization else { return self.authorized }
      return await withCheckedContinuation { self.continuations.append($0) }
    },
    submit: { date in
      self.submissionAttempts += 1
      if self.failsSubmission { throw InboxSchedulingTestError.submissionFailed }
      self.requests.append(date)
      self.pendingRequest = date
    },
    cancel: { self.pendingRequest = nil }
  )

  func resolveAuthorization(at index: Int, authorized: Bool) {
    let continuation = continuations[index]
    continuations[index] = nil
    continuation?.resume(returning: authorized)
  }

  func waitForAuthorization(count: Int) async throws {
    for _ in 0..<200 {
      if continuations.count >= count { return }
      await Task.yield()
    }
    for continuation in continuations { continuation?.resume(returning: false) }
    continuations.removeAll()
    throw InboxSchedulingTestError.lookupDidNotStart
  }
}

private enum InboxSchedulingTestError: Error {
  case submissionFailed, lookupDidNotStart
}
