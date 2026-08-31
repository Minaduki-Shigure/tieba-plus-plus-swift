import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ContentAgreementStoreTests: XCTestCase {
  func testSignedOutScopeMakesNoAuthenticatedRequestAndMarksCachedEntriesSignedOut() async {
    let target = agreementTarget(objectID: 100)
    let service = ContentAgreementStoreServiceSpy()
    let vault = ContentAgreementStoreVaultSpy()
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())

    XCTAssertEqual(entry.state, .signedOut)
    let batchReadCount = await service.batchReadCount()
    let singleReadCount = await service.singleReadCount()
    XCTAssertEqual(batchReadCount, 0)
    XCTAssertEqual(singleReadCount, 0)
  }

  func testTwoScopesShareOneInFlightBatchAndOneEntry() async throws {
    let active = agreementSession(revisionComponent: 1)
    let target = agreementTarget(objectID: 100)
    let page = agreementPage(session: active, target: target, isAgreed: true, score: 8)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page],
      suspendedBatchRevisions: [active.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let firstEntry = store.entry(for: target)
    let descriptor = agreementDescriptor(target: target)

    await store.replaceDescriptors([descriptor], for: UUID())
    await store.replaceDescriptors([descriptor], for: UUID())
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount() == 1
    }
    await service.releaseBatchReads()
    try await waitForContentAgreementStoreTest {
      firstEntry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 8))
    }

    XCTAssertTrue(firstEntry === store.entry(for: target))
    let batchReadCount = await service.batchReadCount()
    XCTAssertEqual(batchReadCount, 1)
  }

  func testExplicitDescriptorRefreshAddsOneBatchReadAndNoSingleReads() async throws {
    let active = agreementSession(revisionComponent: 13)
    let target = agreementTarget(objectID: 113)
    let page = agreementPage(session: active, target: target, isAgreed: true, score: 8)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let scope = UUID()
    let sharedScope = UUID()
    let entry = store.entry(for: target)
    let descriptor = agreementDescriptor(target: target)
    await store.replaceDescriptors([descriptor], for: scope)
    await store.replaceDescriptors([descriptor], for: sharedScope)
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 8))
    }
    let initialBatchReadCount = await service.batchReadCount()
    XCTAssertEqual(initialBatchReadCount, 1)

    await store.refreshDescriptors(for: scope)
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount() == 2
    }
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 8))
    }

    let finalBatchReadCount = await service.batchReadCount()
    let singleReadCount = await service.singleReadCount()
    XCTAssertEqual(finalBatchReadCount, initialBatchReadCount + 1)
    XCTAssertEqual(singleReadCount, 0)
    XCTAssertEqual(entry.state, .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 8)))
  }

  func testRemovingOneScopeRestartsShrunkSharedRequestForRemainingScope() async throws {
    let active = agreementSession(revisionComponent: 7)
    let firstTarget = agreementTarget(objectID: 105)
    let secondTarget = agreementTarget(objectID: 106)
    let page = ContentAgreementPageData(
      userID: active.id,
      forumID: firstTarget.forumID,
      threadID: firstTarget.threadID,
      agreements: [
        agreementData(
          session: active,
          target: firstTarget,
          isAgreed: true,
          score: 7
        ),
        agreementData(
          session: active,
          target: secondTarget,
          isAgreed: false,
          score: 2
        ),
      ]
    )
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page],
      suspendedBatchRevisions: [active.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let firstEntry = store.entry(for: firstTarget)
    let firstScope = UUID()
    let secondScope = UUID()
    await store.replaceDescriptors(
      [agreementDescriptor(target: firstTarget)],
      for: firstScope
    )
    await store.replaceDescriptors(
      [agreementDescriptor(target: secondTarget)],
      for: secondScope
    )
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount() >= 2
    }

    store.removeScope(secondScope)
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount() >= 3
    }
    let descriptors = await service.batchDescriptors()
    XCTAssertEqual(descriptors.last?.expectedTargets, Set([firstTarget]))
    await service.releaseBatchReads()
    try await waitForContentAgreementStoreTest {
      firstEntry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 7))
    }

    let batchReadCount = await service.batchReadCount()
    XCTAssertEqual(batchReadCount, 3)
  }

  func testBatchStartedDuringWriteCannotOverwriteMutationResult() async throws {
    let active = agreementSession(revisionComponent: 2)
    let target = agreementTarget(objectID: 101)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: false,
          score: 4
        )
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: true,
          score: 5
        )
      ],
      suspendedWriteRevisions: [active.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)
    let firstScope = UUID()
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: firstScope)
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 4))
    }

    let write = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest {
      if case .mutating = entry.state { return true }
      return false
    }
    await store.replaceDescriptors(
      [agreementDescriptor(target: target, page: 2)],
      for: UUID()
    )
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount() == 2
    }
    XCTAssertEqual(
      entry.state,
      .mutating(
        previous: ContentAgreementSnapshot(isAgreed: false, agreeScore: 4),
        targetAgreed: true
      )
    )

    await service.releaseWrites()
    let result = try await write.value

    XCTAssertEqual(result, ContentAgreementSnapshot(isAgreed: true, agreeScore: 5))
    XCTAssertEqual(entry.state, .ready(result))
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(entry.state, .ready(result))
    let batchReadCount = await service.batchReadCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(batchReadCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testSameTargetRequestsShareFlightBeforeActiveSessionReadCompletes() async throws {
    let active = agreementSession(revisionComponent: 14)
    let target = agreementTarget(objectID: 114)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: false,
          score: 75
        )
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: true,
          score: 76
        )
      ]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 75))
    }
    await vault.suspendActiveSessionReads()

    let first = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest {
      await vault.activeSessionWaiterCount() == 1
    }
    let second = Task { try await store.setAgreed(true, for: target) }
    try await Task.sleep(nanoseconds: 30_000_000)

    let activeSessionWaiterCount = await vault.activeSessionWaiterCount()
    XCTAssertEqual(activeSessionWaiterCount, 1)
    XCTAssertEqual(
      entry.state,
      .mutating(
        previous: ContentAgreementSnapshot(isAgreed: false, agreeScore: 75),
        targetAgreed: true
      )
    )

    await vault.releaseActiveSessionReads()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(firstResult, ContentAgreementSnapshot(isAgreed: true, agreeScore: 76))
    XCTAssertEqual(secondResult, firstResult)
    XCTAssertEqual(entry.state, .ready(firstResult))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testReconciliationAppliesFirstMatchingReadAndStops() async throws {
    let active = agreementSession(revisionComponent: 20)
    let target = agreementTarget(objectID: 120)
    let scope = UUID()
    let optimistic = ContentAgreementSnapshot(isAgreed: true, agreeScore: 76)
    let authoritative = ContentAgreementSnapshot(isAgreed: true, agreeScore: 83)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: false,
          score: 75
        )
      ],
      singleReadSteps: [
        active.sessionRevision: [
          .success(
            agreementData(
              session: active,
              target: target,
              isAgreed: authoritative.isAgreed,
              score: authoritative.agreeScore
            )
          )
        ]
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: optimistic.isAgreed,
          score: optimistic.agreeScore
        )
      ]
    )
    let sleeper = ContentAgreementReconciliationSleeper()
    let store = reconciliationStore(
      active: active,
      service: service,
      sleeper: sleeper
    )
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: scope)
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 75))
    }

    let mutation = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await sleeper.waiterCount() == 1 }
    XCTAssertEqual(entry.state, .reconciling(optimistic))
    let readsBeforeDelay = await service.singleReadCount()
    XCTAssertEqual(readsBeforeDelay, 0)

    await sleeper.advanceOne()
    let written = try await mutation.value
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(authoritative)
    }

    XCTAssertEqual(written, authoritative)
    let finalReadCount = await service.singleReadCount()
    let finalWaiterCount = await sleeper.waiterCount()
    XCTAssertEqual(finalReadCount, 1)
    XCTAssertEqual(finalWaiterCount, 0)
  }

  func testReconciliationRetriesOneStaleReadThenAppliesMatchingRead() async throws {
    let active = agreementSession(revisionComponent: 21)
    let target = agreementTarget(objectID: 121)
    let scope = UUID()
    let initial = ContentAgreementSnapshot(isAgreed: false, agreeScore: 75)
    let optimistic = ContentAgreementSnapshot(isAgreed: true, agreeScore: 76)
    let authoritative = ContentAgreementSnapshot(isAgreed: true, agreeScore: 84)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: initial.isAgreed,
          score: initial.agreeScore
        )
      ],
      singleReadSteps: [
        active.sessionRevision: [
          .success(
            agreementData(
              session: active,
              target: target,
              isAgreed: initial.isAgreed,
              score: initial.agreeScore
            )
          ),
          .success(
            agreementData(
              session: active,
              target: target,
              isAgreed: authoritative.isAgreed,
              score: authoritative.agreeScore
            )
          ),
        ]
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: optimistic.isAgreed,
          score: optimistic.agreeScore
        )
      ]
    )
    let sleeper = ContentAgreementReconciliationSleeper()
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = reconciliationStore(vault: vault, service: service, sleeper: sleeper)
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: scope)
    try await waitForContentAgreementStoreTest { entry.state == .ready(initial) }
    let mutation = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await sleeper.waiterCount() == 1 }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      let readCount = await service.singleReadCount()
      let waiterCount = await sleeper.waiterCount()
      return readCount == 1 && waiterCount == 1
    }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    let written = try await mutation.value
    try await waitForContentAgreementStoreTest { entry.state == .ready(authoritative) }

    XCTAssertEqual(written, authoritative)
    let finalReadCount = await service.singleReadCount()
    let finalWaiterCount = await sleeper.waiterCount()
    XCTAssertEqual(finalReadCount, 2)
    XCTAssertEqual(finalWaiterCount, 0)
  }

  func testReconciliationRollsBackAndThrowsAfterFinalMismatchingRead() async throws {
    let active = agreementSession(revisionComponent: 22)
    let target = agreementTarget(objectID: 122)
    let scope = UUID()
    let initial = ContentAgreementSnapshot(isAgreed: false, agreeScore: 75)
    let optimistic = ContentAgreementSnapshot(isAgreed: true, agreeScore: 76)
    let finalAuthoritative = ContentAgreementSnapshot(isAgreed: false, agreeScore: 74)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: initial.isAgreed,
          score: initial.agreeScore
        )
      ],
      singleReadSteps: [
        active.sessionRevision: [
          .success(
            agreementData(
              session: active,
              target: target,
              isAgreed: initial.isAgreed,
              score: initial.agreeScore
            )
          ),
          .success(
            agreementData(
              session: active,
              target: target,
              isAgreed: finalAuthoritative.isAgreed,
              score: finalAuthoritative.agreeScore
            )
          ),
        ]
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: optimistic.isAgreed,
          score: optimistic.agreeScore
        )
      ]
    )
    let sleeper = ContentAgreementReconciliationSleeper()
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = reconciliationStore(vault: vault, service: service, sleeper: sleeper)
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: scope)
    try await waitForContentAgreementStoreTest { entry.state == .ready(initial) }
    let mutation = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await sleeper.waiterCount() == 1 }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      let readCount = await service.singleReadCount()
      let waiterCount = await sleeper.waiterCount()
      return readCount == 1 && waiterCount == 1
    }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(finalAuthoritative)
    }
    do {
      _ = try await mutation.value
      XCTFail("Expected a final reconciliation mismatch to throw")
    } catch is CancellationError {
      XCTFail("A stable-account mismatch must not be reported as cancellation")
    } catch {}

    let readCount = await service.singleReadCount()
    XCTAssertEqual(readCount, 2)
  }

  func testReconciliationFailsAfterTwoReadErrorsAndThrowsUnableToConfirm() async throws {
    let active = agreementSession(revisionComponent: 23)
    let target = agreementTarget(objectID: 123)
    let scope = UUID()
    let initial = ContentAgreementSnapshot(isAgreed: false, agreeScore: 75)
    let optimistic = ContentAgreementSnapshot(isAgreed: true, agreeScore: 76)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: initial.isAgreed,
          score: initial.agreeScore
        )
      ],
      singleReadSteps: [
        active.sessionRevision: [
          .failure("first reconciliation read failed"),
          .failure("second reconciliation read failed"),
        ]
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: optimistic.isAgreed,
          score: optimistic.agreeScore
        )
      ]
    )
    let sleeper = ContentAgreementReconciliationSleeper()
    let store = reconciliationStore(active: active, service: service, sleeper: sleeper)
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: scope)
    try await waitForContentAgreementStoreTest { entry.state == .ready(initial) }
    let mutation = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await sleeper.waiterCount() == 1 }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      let readCount = await service.singleReadCount()
      let waiterCount = await sleeper.waiterCount()
      return readCount == 1 && waiterCount == 1
    }
    XCTAssertEqual(entry.state, .reconciling(optimistic))

    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      entry.state == .failed(previous: optimistic)
    }
    do {
      _ = try await mutation.value
      XCTFail("Expected two reconciliation failures to throw")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("无法从服务器确认"))
    }

    let readCount = await service.singleReadCount()
    XCTAssertEqual(readCount, 2)
  }

  func testOldReconciliationReadCannotOverwriteNewAccountState() async throws {
    let active = agreementSession(revisionComponent: 24)
    let replacement = agreementSession(revisionComponent: 25, userID: 8)
    let target = agreementTarget(objectID: 124)
    let scope = UUID()
    let initial = ContentAgreementSnapshot(isAgreed: false, agreeScore: 75)
    let optimistic = ContentAgreementSnapshot(isAgreed: true, agreeScore: 76)
    let replacementSnapshot = ContentAgreementSnapshot(isAgreed: false, agreeScore: 40)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: initial.isAgreed,
          score: initial.agreeScore
        ),
        replacement.sessionRevision: agreementPage(
          session: replacement,
          target: target,
          isAgreed: replacementSnapshot.isAgreed,
          score: replacementSnapshot.agreeScore
        )
      ],
      singleReadSteps: [
        active.sessionRevision: [
          .suspendedSuccess(
            agreementData(
              session: active,
              target: target,
              isAgreed: true,
              score: 999
            )
          ),
        ]
      ],
      writeResults: [
        active.sessionRevision: agreementData(
          session: active,
          target: target,
          isAgreed: optimistic.isAgreed,
          score: optimistic.agreeScore
        )
      ],
      suspendedBatchRevisions: [replacement.sessionRevision]
    )
    let sleeper = ContentAgreementReconciliationSleeper()
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = reconciliationStore(vault: vault, service: service, sleeper: sleeper)
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: scope)
    try await waitForContentAgreementStoreTest { entry.state == .ready(initial) }
    let mutation = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await sleeper.waiterCount() == 1 }
    XCTAssertEqual(entry.state, .reconciling(optimistic))
    await sleeper.advanceOne()
    try await waitForContentAgreementStoreTest {
      await service.suspendedSingleReadCount() == 1
    }

    await vault.replaceActive(with: replacement)
    store.accountSessionDidChange()
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount(for: replacement.sessionRevision) == 1
    }
    await service.releaseSuspendedSingleReads()
    do {
      _ = try await mutation.value
      XCTFail("Expected the old-account reconciliation to be cancelled")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    await service.releaseBatchReads()
    try await waitForContentAgreementStoreTest { entry.state == .ready(replacementSnapshot) }

    let writeCount = await service.writeCount()
    let readCount = await service.singleReadCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(readCount, 1)
    XCTAssertNotEqual(entry.state, .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 999)))
  }

  func testOppositeRequestWaitsThenPerformsOneReadOnlyRefreshWithoutSecondWrite() async throws {
    let active = agreementSession(revisionComponent: 3)
    let target = agreementTarget(objectID: 102)
    let current = agreementData(
      session: active,
      target: target,
      isAgreed: true,
      score: 6
    )
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: false,
          score: 5
        )
      ],
      singleReads: [active.sessionRevision: current],
      writeResults: [active.sessionRevision: current],
      suspendedWriteRevisions: [active.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 5))
    }

    let first = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await service.writeCount() == 1 }
    let opposite = Task { () -> String? in
      do {
        _ = try await store.setAgreed(false, for: target)
        return nil
      } catch {
        return error.localizedDescription
      }
    }
    await service.releaseWrites()
    _ = try await first.value
    let oppositeMessage = await opposite.value

    XCTAssertNotNil(oppositeMessage)
    let writeCount = await service.writeCount()
    let singleReadCount = await service.singleReadCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(singleReadCount, 1)
    XCTAssertEqual(
      entry.state,
      .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 6))
    )
  }

  func testAccountSwitchDuringWriteRestartsSkippedDescriptorAfterOldWriteSettles() async throws {
    let oldSession = agreementSession(revisionComponent: 4)
    let newSession = agreementSession(revisionComponent: 5, userID: 8)
    XCTAssertNotEqual(oldSession.id, newSession.id)
    let target = agreementTarget(objectID: 103)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        oldSession.sessionRevision: agreementPage(
          session: oldSession,
          target: target,
          isAgreed: false,
          score: 1
        ),
        newSession.sessionRevision: agreementPage(
          session: newSession,
          target: target,
          isAgreed: true,
          score: 99
        ),
      ],
      writeResults: [
        oldSession.sessionRevision: agreementData(
          session: oldSession,
          target: target,
          isAgreed: true,
          score: 2
        )
      ],
      suspendedBatchRevisions: [newSession.sessionRevision],
      suspendedWriteRevisions: [oldSession.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: oldSession)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 1))
    }

    let oldWrite = Task { try await store.setAgreed(true, for: target) }
    try await waitForContentAgreementStoreTest { await service.writeCount() == 1 }
    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount(for: newSession.sessionRevision) == 1
    }

    await service.releaseWrites()
    do {
      _ = try await oldWrite.value
      XCTFail("Expected the old-account write result to be discarded")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount(for: newSession.sessionRevision) >= 2
    }
    await service.releaseBatchReads()
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 99))
    }

    let writeCount = await service.writeCount()
    let newSessionRequestUserIDs = await service.batchUserIDs(
      for: newSession.sessionRevision
    )
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(Set(newSessionRequestUserIDs), Set([newSession.id]))
  }

  func testSameUserNewSessionRevisionRejectsOldBatchResult() async throws {
    let oldSession = agreementSession(revisionComponent: 8)
    let newSession = agreementSession(revisionComponent: 9)
    let target = agreementTarget(objectID: 107)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        oldSession.sessionRevision: agreementPage(
          session: oldSession,
          target: target,
          isAgreed: false,
          score: 1
        ),
        newSession.sessionRevision: agreementPage(
          session: newSession,
          target: target,
          isAgreed: true,
          score: 99
        ),
      ],
      suspendedBatchRevisions: [oldSession.sessionRevision, newSession.sessionRevision]
    )
    let vault = ContentAgreementStoreVaultSpy(session: oldSession)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForContentAgreementStoreTest {
      await service.batchReadCount(for: newSession.sessionRevision) == 1
    }
    await service.releaseBatchReads()
    try await waitForContentAgreementStoreTest {
      entry.state == .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 99))
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(entry.state, .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 99)))
  }

  func testBatchIgnoresExtraTargetOutsideDescriptorIntersection() async throws {
    let active = agreementSession(revisionComponent: 10)
    let expected = agreementTarget(objectID: 108)
    let extra = agreementTarget(objectID: 109)
    let page = ContentAgreementPageData(
      userID: active.id,
      forumID: expected.forumID,
      threadID: expected.threadID,
      agreements: [
        agreementData(session: active, target: extra, isAgreed: true, score: 91),
        agreementData(session: active, target: expected, isAgreed: false, score: 4),
      ]
    )
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let expectedEntry = store.entry(for: expected)
    let extraEntry = store.entry(for: extra)

    await store.replaceDescriptors([agreementDescriptor(target: expected)], for: UUID())
    try await waitForContentAgreementStoreTest {
      expectedEntry.state == .ready(ContentAgreementSnapshot(isAgreed: false, agreeScore: 4))
    }

    XCTAssertEqual(extraEntry.state, .unknown)
  }

  func testBatchRejectsDuplicateExpectedTarget() async throws {
    let active = agreementSession(revisionComponent: 11)
    let target = agreementTarget(objectID: 110)
    let page = ContentAgreementPageData(
      userID: active.id,
      forumID: target.forumID,
      threadID: target.threadID,
      agreements: [
        agreementData(session: active, target: target, isAgreed: false, score: 4),
        agreementData(session: active, target: target, isAgreed: true, score: 5),
      ]
    )
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let entry = store.entry(for: target)

    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      if case .failed = entry.state { return true }
      return false
    }

    XCTAssertEqual(
      entry.state,
      .failed(previous: ContentAgreementSnapshot(isAgreed: false, agreeScore: 4))
    )
  }

  func testBatchMarksMissingExpectedTargetFailed() async throws {
    let active = agreementSession(revisionComponent: 12)
    let present = agreementTarget(objectID: 111)
    let missing = agreementTarget(objectID: 112)
    let page = ContentAgreementPageData(
      userID: active.id,
      forumID: present.forumID,
      threadID: present.threadID,
      agreements: [
        agreementData(session: active, target: present, isAgreed: true, score: 7)
      ]
    )
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [active.sessionRevision: page]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      observesAccountSessionChanges: false
    )
    let presentEntry = store.entry(for: present)
    let missingEntry = store.entry(for: missing)
    let request = agreementDescriptor(target: present).request
    let descriptor = ContentAgreementReadDescriptor(
      request: request,
      expectedTargets: [present, missing]
    )!

    await store.replaceDescriptors([descriptor], for: UUID())
    try await waitForContentAgreementStoreTest {
      if case .failed = missingEntry.state { return true }
      return false
    }

    XCTAssertEqual(
      presentEntry.state,
      .ready(ContentAgreementSnapshot(isAgreed: true, agreeScore: 7))
    )
    XCTAssertEqual(missingEntry.state, .failed(previous: nil))
  }

  func testActiveScopeEntryIsNotEvictedByBoundedCache() async throws {
    let active = agreementSession(revisionComponent: 6)
    let target = agreementTarget(objectID: 104)
    let service = ContentAgreementStoreServiceSpy(
      batchPages: [
        active.sessionRevision: agreementPage(
          session: active,
          target: target,
          isAgreed: false,
          score: 1
        )
      ]
    )
    let vault = ContentAgreementStoreVaultSpy(session: active)
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      capacity: 1,
      observesAccountSessionChanges: false
    )
    let retained = store.entry(for: target)
    await store.replaceDescriptors([agreementDescriptor(target: target)], for: UUID())
    try await waitForContentAgreementStoreTest {
      if case .ready = retained.state { return true }
      return false
    }

    _ = store.entry(for: agreementTarget(objectID: 200))
    _ = store.entry(for: agreementTarget(objectID: 201))

    XCTAssertTrue(retained === store.entry(for: target))
  }

  func testAllActiveEntriesRemainStableAboveCapacityUntilScopeIsRemoved() async {
    let targets = (300...302).map { agreementTarget(objectID: Int64($0)) }
    let service = ContentAgreementStoreServiceSpy()
    let vault = ContentAgreementStoreVaultSpy()
    let store = ContentAgreementStore(
      access: AccountAccess(vault: vault, service: service),
      capacity: 2,
      observesAccountSessionChanges: false
    )
    let scope = UUID()
    await store.replaceDescriptors(
      targets.enumerated().map { index, target in
        agreementDescriptor(target: target, page: index + 1)
      },
      for: scope
    )

    let entries = targets.map { store.entry(for: $0) }

    XCTAssertTrue(entries[0] === store.entry(for: targets[0]))
    XCTAssertTrue(entries[1] === store.entry(for: targets[1]))
    XCTAssertTrue(entries[2] === store.entry(for: targets[2]))
    XCTAssertEqual(store.evictionCandidateScanCount, 0)

    store.removeScope(scope)

    XCTAssertEqual(store.evictionCandidateScanCount, 1)
    XCTAssertFalse(entries[0] === store.entry(for: targets[0]))
  }
}

private enum ContentAgreementSingleReadStep: Sendable {
  case success(ContentAgreementData)
  case failure(String)
  case suspendedSuccess(ContentAgreementData)
}

private struct ContentAgreementStoreTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor ContentAgreementStoreVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var suspendsActiveSessionReads = false
  private var activeSessionWaiters: [CheckedContinuation<Void, Never>] = []

  init(session: StoredAccountSession? = nil) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? {
    if suspendsActiveSessionReads {
      await withCheckedContinuation { activeSessionWaiters.append($0) }
    }
    return session
  }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func suspendActiveSessionReads() {
    suspendsActiveSessionReads = true
  }

  func activeSessionWaiterCount() -> Int {
    activeSessionWaiters.count
  }

  func releaseActiveSessionReads() {
    suspendsActiveSessionReads = false
    let waiters = activeSessionWaiters
    activeSessionWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private actor ContentAgreementStoreServiceSpy: AccountService {
  private struct BatchRequest: Sendable {
    let userID: Int64
    let revision: UUID
    let descriptor: ContentAgreementReadDescriptor
  }

  private struct SuspendedSingleRead {
    let result: ContentAgreementData
    let continuation: CheckedContinuation<ContentAgreementData, Error>
  }

  private let batchPages: [UUID: ContentAgreementPageData]
  private let singleReads: [UUID: ContentAgreementData]
  private var singleReadSteps: [UUID: [ContentAgreementSingleReadStep]]
  private let writeResults: [UUID: ContentAgreementData]
  private let suspendedBatchRevisions: Set<UUID>
  private let suspendedWriteRevisions: Set<UUID>
  private var releasedBatchRevisions = Set<UUID>()
  private var releasedWriteRevisions = Set<UUID>()
  private var batchWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var writeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var batchRequests: [BatchRequest] = []
  private var singleReadRequests: [UUID] = []
  private var suspendedSingleReads: [SuspendedSingleRead] = []
  private var writeRequests: [(UUID, Bool)] = []

  init(
    batchPages: [UUID: ContentAgreementPageData] = [:],
    singleReads: [UUID: ContentAgreementData] = [:],
    singleReadSteps: [UUID: [ContentAgreementSingleReadStep]] = [:],
    writeResults: [UUID: ContentAgreementData] = [:],
    suspendedBatchRevisions: Set<UUID> = [],
    suspendedWriteRevisions: Set<UUID> = []
  ) {
    self.batchPages = batchPages
    self.singleReads = singleReads
    self.singleReadSteps = singleReadSteps
    self.writeResults = writeResults
    self.suspendedBatchRevisions = suspendedBatchRevisions
    self.suspendedWriteRevisions = suspendedWriteRevisions
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ContentAgreementStoreTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ContentAgreementStoreTestFailure(message: "unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ContentAgreementStoreTestFailure(message: "unexpected forum-membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ContentAgreementStoreTestFailure(message: "unexpected forum-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ContentAgreementStoreTestFailure(message: "unexpected forum mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ContentAgreementStoreTestFailure(message: "unexpected check-in")
  }

  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData {
    let revision = session.sessionRevision
    singleReadRequests.append(revision)
    if var steps = singleReadSteps[revision], !steps.isEmpty {
      let step = steps.removeFirst()
      singleReadSteps[revision] = steps
      switch step {
      case .success(let result):
        guard result.target == target else {
          throw ContentAgreementStoreTestFailure(message: "mismatched single agreement read")
        }
        return result
      case .failure(let message):
        throw ContentAgreementStoreTestFailure(message: message)
      case .suspendedSuccess(let result):
        guard result.target == target else {
          throw ContentAgreementStoreTestFailure(message: "mismatched single agreement read")
        }
        return try await withCheckedThrowingContinuation { continuation in
          suspendedSingleReads.append(
            SuspendedSingleRead(result: result, continuation: continuation)
          )
        }
      }
    }
    guard let result = singleReads[revision], result.target == target else {
      throw ContentAgreementStoreTestFailure(message: "unexpected single agreement read")
    }
    return result
  }

  func contentAgreements(
    session: StoredAccountSession,
    descriptor: ContentAgreementReadDescriptor
  ) async throws -> ContentAgreementPageData {
    let revision = session.sessionRevision
    batchRequests.append(
      BatchRequest(userID: session.id, revision: revision, descriptor: descriptor)
    )
    if suspendedBatchRevisions.contains(revision), !releasedBatchRevisions.contains(revision) {
      await withCheckedContinuation { batchWaiters[revision, default: []].append($0) }
    }
    guard let result = batchPages[revision] else {
      throw ContentAgreementStoreTestFailure(message: "unexpected agreement page read")
    }
    return result
  }

  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData {
    let revision = session.sessionRevision
    writeRequests.append((revision, isAgreed))
    if suspendedWriteRevisions.contains(revision), !releasedWriteRevisions.contains(revision) {
      await withCheckedContinuation { writeWaiters[revision, default: []].append($0) }
    }
    guard let result = writeResults[revision], result.target == target else {
      throw ContentAgreementStoreTestFailure(message: "unexpected agreement write")
    }
    return result
  }

  func releaseBatchReads() {
    releasedBatchRevisions.formUnion(suspendedBatchRevisions)
    let waiters = batchWaiters.values.flatMap { $0 }
    batchWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func releaseWrites() {
    releasedWriteRevisions.formUnion(suspendedWriteRevisions)
    let waiters = writeWaiters.values.flatMap { $0 }
    writeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func suspendedSingleReadCount() -> Int { suspendedSingleReads.count }

  func releaseSuspendedSingleReads() {
    let reads = suspendedSingleReads
    suspendedSingleReads.removeAll()
    reads.forEach { $0.continuation.resume(returning: $0.result) }
  }

  func batchReadCount() -> Int { batchRequests.count }
  func batchReadCount(for revision: UUID) -> Int {
    batchRequests.filter { $0.revision == revision }.count
  }
  func batchDescriptors() -> [ContentAgreementReadDescriptor] {
    batchRequests.map(\.descriptor)
  }
  func batchUserIDs(for revision: UUID) -> [Int64] {
    batchRequests.filter { $0.revision == revision }.map(\.userID)
  }
  func singleReadCount() -> Int { singleReadRequests.count }
  func writeCount() -> Int { writeRequests.count }
}

private actor ContentAgreementReconciliationSleeper {
  private struct Waiter {
    let duration: Duration
    let continuation: CheckedContinuation<Void, Error>
  }

  private var waiters: [Waiter] = []

  func sleep(for duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      waiters.append(Waiter(duration: duration, continuation: continuation))
    }
  }

  func waiterCount() -> Int { waiters.count }

  func requestedDurations() -> [Duration] { waiters.map(\.duration) }

  func advanceOne() {
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().continuation.resume()
  }
}

@MainActor
private func reconciliationStore(
  active: StoredAccountSession,
  service: ContentAgreementStoreServiceSpy,
  sleeper: ContentAgreementReconciliationSleeper
) -> ContentAgreementStore {
  reconciliationStore(
    vault: ContentAgreementStoreVaultSpy(session: active),
    service: service,
    sleeper: sleeper
  )
}

@MainActor
private func reconciliationStore(
  vault: ContentAgreementStoreVaultSpy,
  service: ContentAgreementStoreServiceSpy,
  sleeper: ContentAgreementReconciliationSleeper
) -> ContentAgreementStore {
  ContentAgreementStore(
    access: AccountAccess(vault: vault, service: service),
    capacity: 512,
    observesAccountSessionChanges: false,
    reconciliationDelays: [Duration.seconds(1), Duration.seconds(2)],
    reconciliationSleep: { duration in
      try await sleeper.sleep(for: duration)
    }
  )
}

private func agreementSession(
  revisionComponent: Int,
  userID: Int64 = 7
) -> StoredAccountSession {
  let revision = UUID(
    uuidString: String(format: "00000000-0000-0000-0000-%012d", revisionComponent)
  )!
  return StoredAccountSession(
    id: userID,
    username: "tester-\(userID)",
    displayName: "Tester \(userID)",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func agreementTarget(objectID: Int64) -> ContentAgreementTarget {
  ContentAgreementTarget(
    kind: objectID == 100 ? .topic : .post,
    forumID: 42,
    forumName: "swift",
    threadID: 10,
    objectID: objectID
  )!
}

private func agreementDescriptor(
  target: ContentAgreementTarget,
  page: Int = 1
) -> ContentAgreementReadDescriptor {
  let request = ContentAgreementPostPageRequest(
    forumID: target.forumID,
    forumName: target.forumName,
    threadID: target.threadID,
    page: page,
    pageSize: 30,
    options: ThreadBrowseOptions(),
    location: nil
  )!
  return ContentAgreementReadDescriptor(
    request: .postPage(request),
    expectedTargets: [target]
  )!
}

private func agreementData(
  session: StoredAccountSession,
  target: ContentAgreementTarget,
  isAgreed: Bool,
  score: Int
) -> ContentAgreementData {
  ContentAgreementData(
    userID: session.id,
    target: target,
    isAgreed: isAgreed,
    agreeScore: score
  )
}

private func agreementPage(
  session: StoredAccountSession,
  target: ContentAgreementTarget,
  isAgreed: Bool,
  score: Int
) -> ContentAgreementPageData {
  ContentAgreementPageData(
    userID: session.id,
    forumID: target.forumID,
    threadID: target.threadID,
    agreements: [
      agreementData(
        session: session,
        target: target,
        isAgreed: isAgreed,
        score: score
      )
    ]
  )
}

@MainActor
private func waitForContentAgreementStoreTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw ContentAgreementStoreTestFailure(message: "timed out waiting for agreement state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
