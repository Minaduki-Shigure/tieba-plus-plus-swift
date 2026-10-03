import XCTest

@testable import TiebaPlusPlus

@MainActor
final class HomeRefreshCoordinatorTests: XCTestCase {
  func testRepeatedEntrySharesWholeOperationAndCancellingOneWaiterDoesNotCancelIt() async {
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeRefreshTestGate()
    defer { gate.release() }
    var calls = 0
    var operationWasCancelled = false
    let operation: @MainActor () async -> Void = {
      calls += 1
      await gate.wait()
      operationWasCancelled = Task.isCancelled
    }
    let first = Task { await coordinator.refresh(operation: operation) }
    await waitUntil { calls == 1 }
    var secondEntered = false
    let second = Task {
      secondEntered = true
      await coordinator.refresh(operation: operation)
    }
    await waitUntil { secondEntered }
    first.cancel()
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(coordinator.isRefreshing)
    gate.release()
    await first.value
    await second.value
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(operationWasCancelled)
    XCTAssertFalse(coordinator.isRefreshing)
    await coordinator.refresh(operation: operation)
    XCTAssertEqual(calls, 2, "A new explicit refresh is allowed after the shared one completes.")
  }

  func testInvalidatedWaiterCannotClearNewAccountsRefresh() async {
    let coordinator = HomeRefreshCoordinator()
    let oldGate = HomeRefreshTestGate()
    let newGate = HomeRefreshTestGate()
    defer { oldGate.release(); newGate.release() }
    var oldCalls = 0
    var newCalls = 0
    let old = Task {
      await coordinator.refresh {
        oldCalls += 1
        // Deliberately non-cooperative, like a shared store request owned elsewhere.
        await oldGate.wait()
      }
    }
    await waitUntil { oldCalls == 1 }
    coordinator.invalidate()
    XCTAssertFalse(coordinator.isRefreshing)
    let new = Task {
      await coordinator.refresh {
        newCalls += 1
        await newGate.wait()
      }
    }
    await waitUntil { newCalls == 1 }
    oldGate.release()
    await old.value
    XCTAssertTrue(coordinator.isRefreshing)
    var joined = false
    let another = Task {
      joined = true
      await coordinator.refresh { newCalls += 1 }
    }
    await waitUntil { joined }
    XCTAssertEqual(newCalls, 1, "The obsolete operation must not discard the new operation's gate.")
    newGate.release()
    await new.value
    await another.value
    XCTAssertFalse(coordinator.isRefreshing)
  }

  func testAlreadyCancelledEntryCannotStartAnOperation() async {
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeRefreshTestGate()
    defer { gate.release() }
    var entered = false
    var calls = 0
    let caller = Task {
      entered = true
      await gate.wait()
      await coordinator.refresh { calls += 1 }
    }
    await waitUntil { entered }
    caller.cancel()
    gate.release()
    await caller.value
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(coordinator.isRefreshing)
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

@MainActor
private final class HomeRefreshTestGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
