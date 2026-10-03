import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AppIconModelTests: XCTestCase {
  func testInitializationAndRefreshReadSystemChoiceWithoutWriting() {
    let system = FakeAppIconSystem()
    system.alternateIconName = "AppIconDark"
    let model = AppIconModel(system: system)
    XCTAssertEqual(model.selectedChoice, .dark)

    system.alternateIconName = "UnexpectedHostIcon"
    model.refresh()
    XCTAssertNil(model.selectedChoice)
    system.alternateIconName = nil
    XCTAssertEqual(AppIconModel(system: system).selectedChoice, .classic)
    XCTAssertTrue(system.requests.isEmpty)
  }

  func testSuccessAndRestoringPrimaryUseOnlyExactSystemNames() async {
    let system = FakeAppIconSystem()
    let model = AppIconModel(system: system)
    await model.select(.light)
    XCTAssertEqual(model.selectedChoice, .light)
    XCTAssertNil(model.issue)
    await model.select(.light)
    XCTAssertEqual(system.requests.count, 1, "Selecting the current icon is a no-op")
    await model.select(.classic)
    XCTAssertEqual(system.requests, ["AppIconLight", nil])
    XCTAssertEqual(model.selectedChoice, .classic)
    XCTAssertNil(model.requestedChoice)
    XCTAssertNil(model.issue)
  }

  func testUnsupportedAndInactiveStatesNeverDispatch() async {
    let system = FakeAppIconSystem()
    let model = AppIconModel(system: system)
    system.supportsAlternateIcons = false
    await model.select(.dark)
    XCTAssertEqual(model.issue, .unavailable)
    XCTAssertFalse(model.supportsAlternateIcons)
    XCTAssertTrue(system.requests.isEmpty)

    system.supportsAlternateIcons = true
    system.isActive = false
    await model.select(.dark)
    XCTAssertEqual(model.issue, .inactive)
    XCTAssertTrue(system.requests.isEmpty)
    XCTAssertEqual(model.selectedChoice, .classic)
    XCTAssertNil(model.requestedChoice)
  }

  func testPendingChangeDoesNotOptimisticallySelectOrAllowASecondRequest() async {
    let system = FakeAppIconSystem()
    system.pausesRequest = true
    let model = AppIconModel(system: system)
    let request = Task { await model.select(.light) }
    await system.waitForRequest()
    XCTAssertEqual(model.requestedChoice, .light)
    XCTAssertEqual(model.selectedChoice, .classic)

    // Another screen and a foreground refresh use the same in-flight model.
    let otherScreenModel = model
    otherScreenModel.refresh()
    await otherScreenModel.select(.dark)
    XCTAssertEqual(system.requests, ["AppIconLight"])
    XCTAssertEqual(model.requestedChoice, .light)

    system.releaseRequest()
    await request.value
    XCTAssertEqual(model.selectedChoice, .light)
    XCTAssertNil(model.requestedChoice)
  }

  func testFailureRereadsActualStateAndPermitsAnExplicitRetry() async {
    let system = FakeAppIconSystem()
    system.error = .denied
    system.pausesRequest = true
    let model = AppIconModel(system: system)
    let request = Task { await model.select(.dark) }
    await system.waitForRequest()
    system.alternateIconName = "AppIconLight"
    system.releaseRequest()
    await request.value
    XCTAssertEqual(model.issue, .failed)
    XCTAssertEqual(model.selectedChoice, .light, "The failure path must reread system state")
    XCTAssertNil(model.requestedChoice)

    model.clearIssue()
    XCTAssertNil(model.issue)
    system.error = nil
    system.pausesRequest = false
    await model.select(.dark)
    XCTAssertEqual(system.requests, ["AppIconDark", "AppIconDark"])
    XCTAssertEqual(model.selectedChoice, .dark)
    XCTAssertNil(model.issue)
  }

  func testSuccessCallbackWithoutChangedSystemNameDoesNotClaimSuccess() async {
    let system = FakeAppIconSystem()
    system.appliesChange = false
    let model = AppIconModel(system: system)
    await model.select(.dark)
    XCTAssertEqual(model.selectedChoice, .classic)
    XCTAssertEqual(model.issue, .notApplied)
    XCTAssertNil(model.requestedChoice)
  }

  func testCancellationBeforeDispatchDoesNotWriteButAfterDispatchStillReconciles() async {
    let system = FakeAppIconSystem()
    let model = AppIconModel(system: system)
    let cancelled = Task { await model.select(.dark) }
    cancelled.cancel()
    await cancelled.value
    XCTAssertTrue(system.requests.isEmpty)

    system.pausesRequest = true
    let dispatched = Task { await model.select(.light) }
    await system.waitForRequest()
    dispatched.cancel()
    system.releaseRequest()
    await dispatched.value
    XCTAssertEqual(system.requests, ["AppIconLight"])
    XCTAssertEqual(model.selectedChoice, .light)
    XCTAssertNil(model.requestedChoice)
  }
}

@MainActor
private final class FakeAppIconSystem: AppIconSystem {
  enum Failure: Error { case denied }

  var supportsAlternateIcons = true
  var alternateIconName: String?
  var isActive = true
  var requests: [String?] = []
  var appliesChange = true
  var error: Failure?
  var pausesRequest = false
  private var pendingRequest: CheckedContinuation<Void, Never>?
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []

  func setAlternateIconName(_ name: String?) async throws {
    requests.append(name)
    if pausesRequest {
      await withCheckedContinuation { continuation in
        pendingRequest = continuation
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
      }
    }
    if let error { throw error }
    if appliesChange { alternateIconName = name }
  }

  func waitForRequest() async {
    guard requests.isEmpty else { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }

  func releaseRequest() {
    pendingRequest?.resume()
    pendingRequest = nil
  }
}
