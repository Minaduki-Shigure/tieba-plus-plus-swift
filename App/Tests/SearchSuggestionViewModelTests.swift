import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SearchSuggestionViewModelTests: XCTestCase {
  @MainActor
  func testDisabledInputAndEnablingAloneDoNotRequestSuggestions() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["swiftui"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)

    viewModel.inputChanged("swift")
    await suggestionDrainMainActor()
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [])

    viewModel.setEnabled(true)
    await suggestionDrainMainActor()
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [])

    viewModel.inputChanged("swiftui")
    try await suggestionWaitUntil { viewModel.suggestions == ["swiftui"] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["swiftui"])
  }

  @MainActor
  func testDebouncesBeforeRequesting() async throws {
    let service = ScriptedSearchSuggestionService()
    let sleeper = ControlledSearchSuggestionSleeper()
    await service.enqueue(.value(["swift result"]))
    let viewModel = SearchSuggestionViewModel(
      service: service,
      sleeper: { try await sleeper.sleep(nanoseconds: $0) }
    )
    viewModel.setEnabled(true)

    viewModel.inputChanged("swift")
    try await suggestionWaitUntil { (await sleeper.snapshot()).pendingCount == 1 }
    let beforeRelease = await sleeper.snapshot()
    XCTAssertEqual(beforeRelease.startedCount, 1)
    XCTAssertEqual(beforeRelease.cancelledCount, 0)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [])

    let didRelease = await sleeper.releaseNext()
    XCTAssertTrue(didRelease)
    try await suggestionWaitUntil { viewModel.suggestions == ["swift result"] }
    let afterRelease = await sleeper.snapshot()
    XCTAssertEqual(afterRelease.pendingCount, 0)
    let completedRequests = await service.requestSnapshot()
    XCTAssertEqual(completedRequests, ["swift"])
  }

  @MainActor
  func testRapidInputRequestsOnlyTheLatestDebouncedQuery() async throws {
    let service = ScriptedSearchSuggestionService()
    let sleeper = ControlledSearchSuggestionSleeper()
    await service.enqueue(.value(["swiftui result"]))
    let viewModel = SearchSuggestionViewModel(
      service: service,
      sleeper: { try await sleeper.sleep(nanoseconds: $0) }
    )
    viewModel.setEnabled(true)

    viewModel.inputChanged("swift")
    try await suggestionWaitUntil { (await sleeper.snapshot()).pendingCount == 1 }
    viewModel.inputChanged("swiftui")
    try await suggestionWaitUntil {
      let snapshot = await sleeper.snapshot()
      return snapshot.startedCount == 2
        && snapshot.cancelledCount == 1
        && snapshot.pendingCount == 1
    }

    let beforeRelease = await service.requestSnapshot()
    XCTAssertEqual(beforeRelease, [])
    let didRelease = await sleeper.releaseNext()
    XCTAssertTrue(didRelease)

    try await suggestionWaitUntil { viewModel.suggestions == ["swiftui result"] }
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["swiftui"])
    let finalSnapshot = await sleeper.snapshot()
    XCTAssertEqual(finalSnapshot.pendingCount, 0)
  }

  @MainActor
  func testEquivalentRawEditRestartsAnActiveDebounce() async throws {
    let service = ScriptedSearchSuggestionService()
    let sleeper = ControlledSearchSuggestionSleeper()
    await service.enqueue(.value(["swift result"]))
    let viewModel = SearchSuggestionViewModel(
      service: service,
      sleeper: { try await sleeper.sleep(nanoseconds: $0) }
    )
    viewModel.setEnabled(true)

    viewModel.inputChanged("swift")
    try await suggestionWaitUntil { (await sleeper.snapshot()).pendingCount == 1 }
    viewModel.inputChanged("swift ")
    try await suggestionWaitUntil {
      let snapshot = await sleeper.snapshot()
      return snapshot.startedCount == 2
        && snapshot.cancelledCount == 1
        && snapshot.pendingCount == 1
    }

    let beforeRelease = await service.requestSnapshot()
    XCTAssertEqual(beforeRelease, [])
    let didRelease = await sleeper.releaseNext()
    XCTAssertTrue(didRelease)

    try await suggestionWaitUntil { viewModel.suggestions == ["swift result"] }
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["swift"])
    let finalSnapshot = await sleeper.snapshot()
    XCTAssertEqual(finalSnapshot.pendingCount, 0)
  }

  @MainActor
  func testEquivalentRawEditDoesNotRestartAnActiveNetworkRequest() async throws {
    let service = ScriptedSearchSuggestionService()
    let sleeper = ControlledSearchSuggestionSleeper()
    await service.enqueue(.suspended(3))
    let viewModel = SearchSuggestionViewModel(
      service: service,
      sleeper: { try await sleeper.sleep(nanoseconds: $0) }
    )
    viewModel.setEnabled(true)

    viewModel.inputChanged("query")
    try await suggestionWaitUntil { (await sleeper.snapshot()).pendingCount == 1 }
    let didRelease = await sleeper.releaseNext()
    XCTAssertTrue(didRelease)
    try await suggestionWaitUntil { await service.requestSnapshot() == ["query"] }

    viewModel.inputChanged("query ")
    await suggestionDrainMainActor()

    let requestsBeforeResponse = await service.requestSnapshot()
    XCTAssertEqual(requestsBeforeResponse, ["query"])
    let sleeperSnapshot = await sleeper.snapshot()
    XCTAssertEqual(sleeperSnapshot.startedCount, 1)
    XCTAssertEqual(sleeperSnapshot.cancelledCount, 0)
    XCTAssertEqual(sleeperSnapshot.pendingCount, 0)

    let didResume = await service.resume(id: 3, returning: ["query result"])
    XCTAssertTrue(didResume)
    try await suggestionWaitUntil { viewModel.suggestions == ["query result"] }
    let finalRequests = await service.requestSnapshot()
    XCTAssertEqual(finalRequests, ["query"])
  }

  @MainActor
  func testLateResponseCannotReplaceNewerSuggestions() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.suspended(1))
    await service.enqueue(.value(["new result"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("old query")
    try await suggestionWaitUntil { await service.requestSnapshot() == ["old query"] }
    viewModel.inputChanged("new query")
    try await suggestionWaitUntil { viewModel.suggestions == ["new result"] }

    let didResume = await service.resume(id: 1, returning: ["old result"])
    XCTAssertTrue(didResume)
    try await suggestionWaitUntil { await service.completionCount() == 2 }
    await suggestionDrainMainActor()

    XCTAssertEqual(viewModel.suggestions, ["new result"])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["old query", "new query"])
  }

  @MainActor
  func testInvalidQueriesNeverReachTheService() async {
    let service = ScriptedSearchSuggestionService()
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("a")
    viewModel.inputChanged(String(repeating: "a", count: 101))
    viewModel.inputChanged("ab\u{0000}cd")
    let oversized = String(repeating: "a\u{0301}\u{0302}\u{0303}\u{0304}", count: 100)
    viewModel.inputChanged(oversized)
    await suggestionDrainMainActor()

    XCTAssertTrue(viewModel.suggestions.isEmpty)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [])
  }

  @MainActor
  func testMaximumValidCharacterAndByteBoundaryIsAccepted() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["valid result"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    let query = String(repeating: "\u{1F600}", count: 100)
    XCTAssertEqual(query.count, 100)
    XCTAssertEqual(query.utf8.count, 400)
    viewModel.setEnabled(true)

    viewModel.inputChanged(query)
    try await suggestionWaitUntil { viewModel.suggestions == ["valid result"] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [query])
  }

  @MainActor
  func testSameTrimmedQueryIsNotRequestedTwice() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["swift result"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("  swift  ")
    try await suggestionWaitUntil { viewModel.suggestions == ["swift result"] }
    viewModel.inputChanged("swift")
    await suggestionDrainMainActor()

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["swift"])
  }

  @MainActor
  func testCancelClearsSuggestionsAndRejectsPendingResponse() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["existing result"]))
    await service.enqueue(.suspended(2))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("existing")
    try await suggestionWaitUntil { viewModel.suggestions == ["existing result"] }
    viewModel.inputChanged("pending")
    try await suggestionWaitUntil { (await service.requestSnapshot()).count == 2 }
    viewModel.cancelAndClear()

    XCTAssertTrue(viewModel.suggestions.isEmpty)
    let didResume = await service.resume(id: 2, returning: ["late result"])
    XCTAssertTrue(didResume)
    try await suggestionWaitUntil { await service.completionCount() == 2 }
    await suggestionDrainMainActor()
    XCTAssertTrue(viewModel.suggestions.isEmpty)
  }

  @MainActor
  func testDisablingClearsAndRequiresAnotherEditAfterReenabling() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["first result"]))
    await service.enqueue(.value(["second result"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)
    viewModel.inputChanged("first query")
    try await suggestionWaitUntil { viewModel.suggestions == ["first result"] }

    viewModel.setEnabled(false)
    XCTAssertTrue(viewModel.suggestions.isEmpty)
    viewModel.setEnabled(true)
    await suggestionDrainMainActor()
    var requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["first query"])

    viewModel.inputChanged("second query")
    try await suggestionWaitUntil { viewModel.suggestions == ["second result"] }
    requests = await service.requestSnapshot()
    XCTAssertEqual(requests, ["first query", "second query"])
  }

  @MainActor
  func testFailureIsSilentAndLeavesSuggestionsEmpty() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["existing result"]))
    await service.enqueue(.failure)
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("existing")
    try await suggestionWaitUntil { viewModel.suggestions == ["existing result"] }
    viewModel.inputChanged("failing")
    try await suggestionWaitUntil { await service.completionCount() == 2 }
    await suggestionDrainMainActor()

    XCTAssertTrue(viewModel.suggestions.isEmpty)
  }

  @MainActor
  func testResponseIsTrimmedFilteredExactlyDeduplicatedAndCapped() async throws {
    let service = ScriptedSearchSuggestionService()
    let oversized = String(repeating: "a\u{0301}\u{0302}\u{0303}\u{0304}", count: 100)
    await service.enqueue(
      .value([
        " alpha ", "alpha", "Alpha", "x", "bad\nvalue", oversized,
        "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
      ])
    )
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("swift")
    try await suggestionWaitUntil { viewModel.suggestions.count == 8 }

    XCTAssertEqual(
      viewModel.suggestions,
      ["alpha", "Alpha", "x", "beta", "gamma", "delta", "epsilon", "zeta"]
    )
  }

  @MainActor
  func testResponseAllowsSingleCharacterSuggestion() async throws {
    let service = ScriptedSearchSuggestionService()
    await service.enqueue(.value(["吧"]))
    let viewModel = SearchSuggestionViewModel(service: service, debounceNanoseconds: 0)
    viewModel.setEnabled(true)

    viewModel.inputChanged("贴吧")
    try await suggestionWaitUntil { viewModel.suggestions == ["吧"] }

    XCTAssertEqual(viewModel.suggestions, ["吧"])
  }
}

private enum SearchSuggestionStub: Sendable {
  case value([String])
  case failure
  case suspended(Int)
}

private struct SearchSuggestionStubFailure: Error, Sendable {}

private actor ScriptedSearchSuggestionService: SearchSuggestionService {
  private var stubs: [SearchSuggestionStub] = []
  private var requests: [String] = []
  private var completedRequests = 0
  private var continuations: [Int: CheckedContinuation<[String], any Error>] = [:]

  func enqueue(_ stub: SearchSuggestionStub) {
    stubs.append(stub)
  }

  func searchSuggestions(query: String) async throws -> [String] {
    requests.append(query)
    defer { completedRequests += 1 }
    guard !stubs.isEmpty else { throw SearchSuggestionStubFailure() }
    switch stubs.removeFirst() {
    case .value(let value):
      return value
    case .failure:
      throw SearchSuggestionStubFailure()
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        continuations[identifier] = continuation
      }
    }
  }

  func resume(id: Int, returning value: [String]) -> Bool {
    guard let continuation = continuations.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func requestSnapshot() -> [String] { requests }
  func completionCount() -> Int { completedRequests }
}

private struct SearchSuggestionSleeperSnapshot: Equatable, Sendable {
  let startedCount: Int
  let cancelledCount: Int
  let pendingCount: Int
}

private actor ControlledSearchSuggestionSleeper {
  private var nextIdentifier = 0
  private var order: [Int] = []
  private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var startedCount = 0
  private var cancelledCount = 0

  func sleep(nanoseconds: UInt64) async throws {
    _ = nanoseconds
    let identifier = nextIdentifier
    nextIdentifier += 1
    startedCount += 1

    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        order.append(identifier)
        continuations[identifier] = continuation
      }
    } onCancel: {
      Task { await self.cancel(identifier: identifier) }
    }
  }

  func releaseNext() -> Bool {
    while !order.isEmpty {
      let identifier = order.removeFirst()
      guard let continuation = continuations.removeValue(forKey: identifier) else { continue }
      continuation.resume()
      return true
    }
    return false
  }

  func snapshot() -> SearchSuggestionSleeperSnapshot {
    SearchSuggestionSleeperSnapshot(
      startedCount: startedCount,
      cancelledCount: cancelledCount,
      pendingCount: continuations.count
    )
  }

  private func cancel(identifier: Int) {
    guard let continuation = continuations.removeValue(forKey: identifier) else { return }
    cancelledCount += 1
    continuation.resume(throwing: CancellationError())
  }
}

private struct SearchSuggestionWaitTimeout: Error {}

@MainActor
private func suggestionWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw SearchSuggestionWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func suggestionDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
