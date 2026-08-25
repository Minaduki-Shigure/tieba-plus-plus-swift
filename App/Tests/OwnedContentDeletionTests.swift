import Foundation
import XCTest

@testable import TiebaPlusPlus

final class OwnedContentDeletionTargetTests: XCTestCase {
  func testTopicAndOrdinaryPostTargetsRequireExactVisibleOwnershipMetadata() throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let reply = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 8)

    let topic = try XCTUnwrap(OwnedContentDeletionTarget(thread: thread, post: firstPost))
    XCTAssertEqual(topic.kind, .topic)
    XCTAssertEqual(topic.objectID, firstPost.id)
    XCTAssertEqual(topic.authorID, thread.authorID)
    XCTAssertEqual(topic.floor, 1)

    let ordinaryPost = try XCTUnwrap(
      OwnedContentDeletionTarget(thread: thread, post: reply)
    )
    XCTAssertEqual(ordinaryPost.kind, .post)
    XCTAssertEqual(ordinaryPost.objectID, reply.id)
    XCTAssertEqual(ordinaryPost.authorID, reply.authorID)
    XCTAssertEqual(ordinaryPost.floor, 2)
  }

  func testTargetConstructionFailsClosedForConflictingOrHiddenContent() {
    let thread = deletionThread()

    XCTAssertNil(
      OwnedContentDeletionTarget(
        thread: thread,
        post: deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 99)
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        thread: thread,
        post: deletionPost(id: 999, threadID: thread.id, floor: 1, authorID: 7)
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        thread: thread,
        post: deletionPost(id: 102, threadID: thread.id + 1, floor: 2, authorID: 7)
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        thread: thread,
        post: deletionPost(
          id: 102,
          threadID: thread.id,
          floor: 2,
          authorID: 7,
          visibility: .hidden
        )
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        thread: deletionThread(visibility: .placeholder),
        post: deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
      )
    )
  }

  func testExplicitTargetValidationRejectsMalformedServerIdentity() {
    XCTAssertNil(
      OwnedContentDeletionTarget(
        kind: .topic,
        forumID: 42,
        forumName: "swift",
        threadID: 10,
        objectID: 101,
        authorID: 7,
        floor: 2
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        kind: .post,
        forumID: 42,
        forumName: "swift",
        threadID: 10,
        objectID: 102,
        authorID: 7,
        floor: 1
      )
    )
    XCTAssertNil(
      OwnedContentDeletionTarget(
        kind: .post,
        forumID: 42,
        forumName: "bad\nforum",
        threadID: 10,
        objectID: 102,
        authorID: 7,
        floor: 2
      )
    )
  }
}

@MainActor
final class OwnedContentDeletionStoreTests: XCTestCase {
  func testOnlyExactOwnerWithFullCredentialsGetsADeletionRequest() async throws {
    let session = deletionSession(revisionComponent: 1, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy()
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )

    await store.reloadActiveSession()

    XCTAssertEqual(store.entry(for: target).state, .ready(AccountSessionLease(session)))
    XCTAssertEqual(store.pendingRequest(for: target)?.target, target)

    let foreignTarget = deletionTarget(authorID: session.id + 1)
    XCTAssertEqual(store.entry(for: foreignTarget).state, .unavailable)
    XCTAssertNil(store.pendingRequest(for: foreignTarget))
    let ownerWriteCount = await service.writeCount()
    XCTAssertEqual(ownerWriteCount, 0)

    let limitedSession = deletionSession(
      revisionComponent: 11,
      userID: session.id,
      hasFullCredentials: false
    )
    let limitedStore = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: limitedSession),
        service: service
      ),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )
    await limitedStore.reloadActiveSession()
    XCTAssertEqual(limitedStore.entry(for: target).state, .unavailable)
    XCTAssertNil(limitedStore.pendingRequest(for: target))
  }

  func testStaleLeaseIsRejectedBeforeDispatchAndFreshLeaseMustBeConfirmedAgain() async throws {
    let original = deletionSession(revisionComponent: 2, userID: 7)
    let replacement = deletionSession(revisionComponent: 3, userID: 7)
    let target = deletionTarget(authorID: original.id)
    let vault = OwnedContentDeletionVaultSpy(session: original)
    let service = OwnedContentDeletionServiceSpy()
    let store = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let staleRequest = try XCTUnwrap(store.pendingRequest(for: target))

    await vault.replaceActive(with: replacement)
    do {
      _ = try await store.delete(staleRequest)
      XCTFail("expected stale account lease to be rejected")
    } catch let error as OwnedContentDeletionError {
      guard case .unavailable = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)
    XCTAssertEqual(store.entry(for: target).state, .ready(AccountSessionLease(replacement)))
    let refreshedRequest = try XCTUnwrap(store.pendingRequest(for: target))
    XCTAssertEqual(refreshedRequest.lease, AccountSessionLease(replacement))
    XCTAssertNotEqual(refreshedRequest.lease, staleRequest.lease)
  }

  func testOutcomeUnknownBecomesTerminalAndNeverResendsSameOperation() async throws {
    let session = deletionSession(revisionComponent: 4, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .outcomeUnknown)
    let vault = OwnedContentDeletionVaultSpy(session: session)
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: vault,
        service: service
      ),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected an unknown deletion outcome")
    } catch let error as OwnedContentDeletionError {
      XCTAssertEqual(error, .outcomeUnknown)
    }
    let initialWriteCount = await service.writeCount()
    XCTAssertEqual(initialWriteCount, 1)
    guard case .outcomeUnknown(let lease, _) = store.entry(for: target).state else {
      return XCTFail("expected a terminal outcome-unknown state")
    }
    XCTAssertEqual(lease, AccountSessionLease(session))
    XCTAssertNil(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected the terminal operation to reject a retry")
    } catch {
      // The exact presentation error may evolve; the invariant is no second write.
    }
    let finalWriteCount = await service.writeCount()
    XCTAssertEqual(finalWriteCount, 1)

    let rotated = deletionSession(revisionComponent: 14, userID: session.id)
    await vault.replaceActive(with: rotated)
    await store.reloadActiveSession()
    guard case .outcomeUnknown(let rotatedLease, _) = store.entry(for: target).state else {
      return XCTFail("expected outcome-unknown to survive same-UID credential rotation")
    }
    XCTAssertEqual(rotatedLease, AccountSessionLease(rotated))
    XCTAssertNil(store.pendingRequest(for: target))
  }

  func testConcurrentEquivalentConfirmationsShareOneDeletionWrite() async throws {
    let session = deletionSession(revisionComponent: 5, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .suspendedAccepted)
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    let first = Task { try await store.delete(request) }
    let second = Task { try await store.delete(request) }
    try await waitForOwnedContentDeletionTest {
      await service.writeCount() == 1
    }
    let suspendedWriteCount = await service.writeCount()
    XCTAssertEqual(suspendedWriteCount, 1)

    await service.releaseWrites()
    let firstReceipt = try await first.value
    let secondReceipt = try await second.value

    XCTAssertEqual(firstReceipt, secondReceipt)
    XCTAssertEqual(firstReceipt.target, target)
    let finalWriteCount = await service.writeCount()
    XCTAssertEqual(finalWriteCount, 1)
    XCTAssertEqual(store.entry(for: target).state, .accepted(firstReceipt))
  }

  func testConcurrentWaitersAllRejectAMismatchedReceipt() async throws {
    let session = deletionSession(revisionComponent: 6, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .suspendedMismatchedReceipt)
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: TransientOwnedContentDeletionLedger(),
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    let first = Task { try await store.delete(request) }
    let second = Task { try await store.delete(request) }
    try await waitForOwnedContentDeletionTest { await service.writeCount() == 1 }
    await service.releaseWrites()

    for result in [await first.result, await second.result] {
      guard case .failure(let error) = result else {
        return XCTFail("expected every shared waiter to reject the mismatched receipt")
      }
      XCTAssertEqual(error as? OwnedContentDeletionError, .outcomeUnknown)
    }
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
    guard case .outcomeUnknown = store.entry(for: target).state else {
      return XCTFail("expected mismatched receipt to lock the target")
    }
  }

  func testCancellingCallerDoesNotCancelAcceptedFinalizerOrPermitAnotherWrite() async throws {
    let session = deletionSession(revisionComponent: 7, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .suspendedAccepted)
    let vault = OwnedContentDeletionVaultSpy(session: session)
    let ledger = TransientOwnedContentDeletionLedger()
    let store = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    let caller = Task { try await store.delete(request) }
    try await waitForOwnedContentDeletionTest { await service.writeCount() == 1 }
    caller.cancel()
    XCTAssertTrue(caller.isCancelled)
    await service.releaseWrites()
    _ = await caller.result

    try await waitForOwnedContentDeletionTest {
      guard let records = try? await ledger.records() else { return false }
      return records.count == 1 && records[0].phase == .accepted
    }
    guard case .accepted = store.entry(for: target).state else {
      return XCTFail("the store-owned finalizer must publish accepted after caller cancellation")
    }

    let restored = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await restored.reloadActiveSession()
    let restoredReceipt = try await restored.delete(request)

    XCTAssertEqual(restoredReceipt.target, target)
    let restoredWriteCount = await service.writeCount()
    XCTAssertEqual(restoredWriteCount, 1)
    XCTAssertNil(restored.pendingRequest(for: target))
  }

  func testPrepareThatPublishesThenThrowsIsReadBackAsUnknownWithoutServiceWrite() async throws {
    let session = deletionSession(revisionComponent: 8, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy()
    let backing = TransientOwnedContentDeletionLedger()
    let ledger = OwnedContentDeletionPublishedPrepareFailureLedger(backing: backing)
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected the published-but-reported-failed prepare to lock the target")
    } catch let error as OwnedContentDeletionError {
      XCTAssertEqual(error, .outcomeUnknown)
    }

    let records = try await backing.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].phase, .outcomeUnknown)
    let prepareFailureWriteCount = await service.writeCount()
    XCTAssertEqual(prepareFailureWriteCount, 0)
    XCTAssertNil(store.pendingRequest(for: target))
    guard case .outcomeUnknown = store.entry(for: target).state else {
      return XCTFail("a possibly durable prepare marker must fail closed")
    }
  }

  func testAccountRotationAfterPrepareCleansMarkerBeforeDispatchAndAllowsReconfirmation()
    async throws
  {
    let original = deletionSession(revisionComponent: 9, userID: 7)
    let replacement = deletionSession(revisionComponent: 19, userID: original.id)
    let target = deletionTarget(authorID: original.id)
    let vault = OwnedContentDeletionVaultSpy(session: original)
    let service = OwnedContentDeletionServiceSpy()
    let backing = TransientOwnedContentDeletionLedger()
    let ledger = OwnedContentDeletionPrepareGateLedger(backing: backing)
    let store = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    let deletion = Task { try await store.delete(request) }
    try await waitForOwnedContentDeletionTest { await ledger.hasPublishedPrepare() }
    await vault.replaceActive(with: replacement)
    await ledger.releasePrepare()

    guard case .failure(let failure) = await deletion.result else {
      return XCTFail("the stale confirmed lease must not dispatch after account rotation")
    }
    guard
      let deletionError = failure as? OwnedContentDeletionError,
      case .unavailable = deletionError
    else {
      return XCTFail("unexpected error: \(failure)")
    }

    let staleLeaseWriteCount = await service.writeCount()
    let retainedRecords = try await backing.records()
    XCTAssertEqual(staleLeaseWriteCount, 0)
    XCTAssertTrue(retainedRecords.isEmpty)
    let refreshedRequest = try XCTUnwrap(store.pendingRequest(for: target))
    XCTAssertEqual(refreshedRequest.lease, AccountSessionLease(replacement))
    XCTAssertNotEqual(refreshedRequest.lease, request.lease)
  }

  func testAmbiguousServiceFailuresAfterPreparePersistOutcomeUnknown() async throws {
    let behaviors: [OwnedContentDeletionServiceBehavior] = [
      .unavailable,
      .cancellation,
    ]

    for (index, behavior) in behaviors.enumerated() {
      let session = deletionSession(revisionComponent: 20 + index, userID: 7)
      let target = deletionTarget(authorID: session.id)
      let service = OwnedContentDeletionServiceSpy(behavior: behavior)
      let ledger = TransientOwnedContentDeletionLedger()
      let store = OwnedContentDeletionStore(
        access: AccountAccess(
          vault: OwnedContentDeletionVaultSpy(session: session),
          service: service
        ),
        ledger: ledger,
        observesAccountSessionChanges: false
      )
      await store.reloadActiveSession()
      let request = try XCTUnwrap(store.pendingRequest(for: target))

      do {
        _ = try await store.delete(request)
        XCTFail("expected \(behavior) to become outcome unknown")
      } catch let error as OwnedContentDeletionError {
        XCTAssertEqual(error, .outcomeUnknown, "behavior: \(behavior)")
      }

      let records = try await ledger.records()
      let writeCount = await service.writeCount()
      XCTAssertEqual(records.count, 1, "behavior: \(behavior)")
      XCTAssertEqual(records.first?.phase, .outcomeUnknown, "behavior: \(behavior)")
      XCTAssertEqual(writeCount, 1, "behavior: \(behavior)")
      XCTAssertNil(store.pendingRequest(for: target), "behavior: \(behavior)")
    }
  }

  func testOutcomeUnknownRestoresAcrossStoreReconstructionWithoutAnotherWrite() async throws {
    let session = deletionSession(revisionComponent: 30, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .outcomeUnknown)
    let vault = OwnedContentDeletionVaultSpy(session: session)
    let ledger = TransientOwnedContentDeletionLedger()
    var store: OwnedContentDeletionStore? = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store?.reloadActiveSession()
    let request = try XCTUnwrap(store?.pendingRequest(for: target))

    do {
      _ = try await store?.delete(request)
      XCTFail("expected an unknown outcome")
    } catch let error as OwnedContentDeletionError {
      XCTAssertEqual(error, .outcomeUnknown)
    }
    store = nil

    let restored = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await restored.reloadActiveSession()
    guard case .outcomeUnknown = restored.entry(for: target).state else {
      return XCTFail("expected the durable unknown terminal after reconstruction")
    }
    XCTAssertNil(restored.pendingRequest(for: target))
    XCTAssertEqual(
      restored.outcomeUnknownTarget(threadID: target.threadID),
      target
    )
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testAcceptedTerminalAndFloorTombstoneRestoreAcrossStoreReconstruction() async throws {
    let original = deletionSession(revisionComponent: 31, userID: 7)
    let rotated = deletionSession(revisionComponent: 41, userID: 7)
    let target = deletionTarget(authorID: original.id)
    let service = OwnedContentDeletionServiceSpy()
    let vault = OwnedContentDeletionVaultSpy(session: original)
    let ledger = TransientOwnedContentDeletionLedger()
    var store: OwnedContentDeletionStore? = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store?.reloadActiveSession()
    let request = try XCTUnwrap(store?.pendingRequest(for: target))
    _ = try await store?.delete(request)
    store = nil

    await vault.replaceActive(with: rotated)
    let restored = OwnedContentDeletionStore(
      access: AccountAccess(vault: vault, service: service),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await restored.reloadActiveSession()
    guard case .accepted(let receipt) = restored.entry(for: target).state else {
      return XCTFail("expected the durable accepted terminal after reconstruction")
    }
    XCTAssertEqual(receipt.accountID, rotated.id)
    XCTAssertEqual(receipt.sessionRevision, rotated.sessionRevision)
    XCTAssertEqual(receipt.target, target)
    let restoredTargets = await restored.restoredTargets(threadID: target.threadID)
    XCTAssertEqual(restoredTargets.accepted, [target])
    XCTAssertNil(restoredTargets.outcomeUnknown)

    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let deletedPost = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let stalePage = PostPageData(
      thread: thread,
      posts: [deletedPost],
      currentPage: 1,
      hasMore: false,
      firstPost: firstPost
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: OwnedContentDeletionBrowseService(pages: [stalePage, stalePage])
    )
    XCTAssertTrue(viewModel.stageAcceptedContentDeletion(restoredTargets.accepted[0]))
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    XCTAssertNil(viewModel.post(withID: deletedPost.id))
    viewModel.reload()
    await viewModel.waitForCurrentLoad()
    XCTAssertNil(viewModel.post(withID: deletedPost.id))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testRecoveredDispatchPendingIsUnknownAndNeverCallsService() async throws {
    let session = deletionSession(revisionComponent: 32, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy()
    let ledger = TransientOwnedContentDeletionLedger()
    _ = try await ledger.prepare(
      target: target,
      accountID: session.id,
      sessionRevision: session.sessionRevision,
      operationID: UUID(),
      at: Date(timeIntervalSince1970: 10)
    )
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: ledger,
      observesAccountSessionChanges: false
    )

    await store.reloadActiveSession()

    guard case .outcomeUnknown = store.entry(for: target).state else {
      return XCTFail("a recovered dispatch marker must fail closed as unknown")
    }
    XCTAssertNil(store.pendingRequest(for: target))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testLedgerCapacityFailureHappensBeforeDeletionService() async throws {
    let session = deletionSession(revisionComponent: 33, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let occupiedTarget = try XCTUnwrap(
      OwnedContentDeletionTarget(
        kind: .post,
        forumID: 43,
        forumName: "occupied",
        threadID: 11,
        objectID: 202,
        authorID: session.id,
        floor: 3
      )
    )
    let ledger = TransientOwnedContentDeletionLedger(maximumRecords: 1)
    _ = try await ledger.prepare(
      target: occupiedTarget,
      accountID: session.id,
      sessionRevision: session.sessionRevision,
      operationID: UUID(),
      at: Date(timeIntervalSince1970: 10)
    )
    let service = OwnedContentDeletionServiceSpy()
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected the full ledger to reject the operation")
    } catch let error as OwnedContentDeletionError {
      guard case .unavailable = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)
    let retainedCapacityRecords = try await ledger.records()
    XCTAssertEqual(retainedCapacityRecords.count, 1)
  }

  func testDefiniteFailureRemovesDispatchMarkerAndAllowsFreshConfirmation() async throws {
    let session = deletionSession(revisionComponent: 34, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy(behavior: .definiteFailure)
    let ledger = TransientOwnedContentDeletionLedger()
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: ledger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected a definite rejection")
    } catch let error as OwnedContentDeletionError {
      guard case .rejected = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let retainedFailureRecords = try await ledger.records()
    XCTAssertTrue(retainedFailureRecords.isEmpty)
    XCTAssertNotNil(store.pendingRequest(for: target))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testTerminalPersistenceFailureLeavesPendingMarkerAndPublishesUnknown() async throws {
    let session = deletionSession(revisionComponent: 35, userID: 7)
    let target = deletionTarget(authorID: session.id)
    let service = OwnedContentDeletionServiceSpy()
    let durableRecords = TransientOwnedContentDeletionLedger()
    let failingLedger = OwnedContentDeletionTerminalFailureLedger(
      backing: durableRecords
    )
    let store = OwnedContentDeletionStore(
      access: AccountAccess(
        vault: OwnedContentDeletionVaultSpy(session: session),
        service: service
      ),
      ledger: failingLedger,
      observesAccountSessionChanges: false
    )
    await store.reloadActiveSession()
    let request = try XCTUnwrap(store.pendingRequest(for: target))

    do {
      _ = try await store.delete(request)
      XCTFail("expected terminal persistence failure to become unknown")
    } catch let error as OwnedContentDeletionError {
      XCTAssertEqual(error, .outcomeUnknown)
    }

    let records = try await durableRecords.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].phase, .dispatchPending)
    guard case .outcomeUnknown = store.entry(for: target).state else {
      return XCTFail("pending-on-disk must remain locked as unknown in memory")
    }
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }
}

@MainActor
final class OwnedContentDeletionThreadViewModelTests: XCTestCase {
  func testAcceptedPostDeletionRemovesOnlyExactPostAndRebuildsDerivedIndexes() async throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let deletedPost = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let retainedPost = deletionPost(id: 103, threadID: thread.id, floor: 3, authorID: 8)
    let deletedAgreement = try XCTUnwrap(ContentAgreementTarget(thread: thread, post: deletedPost))
    let retainedAgreement = try XCTUnwrap(ContentAgreementTarget(thread: thread, post: retainedPost))
    let descriptor = try XCTUnwrap(
      ContentAgreementReadDescriptor(
        request: .postPage(
          try XCTUnwrap(
            ContentAgreementPostPageRequest(
              forumID: thread.forumID,
              forumName: thread.forumName,
              threadID: thread.id,
              page: 1,
              pageSize: 30,
              options: ThreadBrowseOptions(),
              location: nil
            )
          )
        ),
        expectedTargets: [deletedAgreement, retainedAgreement]
      )
    )
    let service = OwnedContentDeletionBrowseService(
      page: PostPageData(
        thread: thread,
        posts: [deletedPost, retainedPost],
        currentPage: 1,
        hasMore: false,
        totalPages: 1,
        totalCount: 3,
        firstPost: firstPost,
        agreementReadDescriptor: descriptor
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    let target = try XCTUnwrap(
      OwnedContentDeletionTarget(thread: thread, post: deletedPost)
    )
    let rebuildCountBeforeDeletion = viewModel.fullPostIndexRebuildCount

    XCTAssertTrue(viewModel.applyAcceptedContentDeletion(target))

    XCTAssertEqual(viewModel.posts.map(\.id), [retainedPost.id])
    XCTAssertNil(viewModel.post(withID: deletedPost.id))
    XCTAssertNil(viewModel.scrollTargetsByPostID[deletedPost.id])
    XCTAssertEqual(viewModel.post(withID: retainedPost.id), retainedPost)
    XCTAssertEqual(
      Set(viewModel.agreementReadDescriptors.flatMap { $0.expectedTargets }),
      Set([retainedAgreement])
    )
    XCTAssertEqual(viewModel.fullPostIndexRebuildCount, rebuildCountBeforeDeletion + 1)
    XCTAssertFalse(viewModel.applyAcceptedContentDeletion(target))
  }

  func testAcceptedDeletionRejectsTopicAndConflictingPostWithoutChangingSnapshot() async throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let reply = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let service = OwnedContentDeletionBrowseService(
      page: PostPageData(
        thread: thread,
        posts: [reply],
        currentPage: 1,
        hasMore: false,
        firstPost: firstPost
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    let originalIDs = viewModel.posts.map(\.id)
    let topic = try XCTUnwrap(OwnedContentDeletionTarget(thread: thread, post: firstPost))
    let conflicting = try XCTUnwrap(
      OwnedContentDeletionTarget(
        kind: .post,
        forumID: thread.forumID,
        forumName: thread.forumName,
        threadID: thread.id,
        objectID: reply.id,
        authorID: reply.authorID,
        floor: reply.floor + 1
      )
    )

    XCTAssertFalse(viewModel.applyAcceptedContentDeletion(topic))
    XCTAssertFalse(viewModel.applyAcceptedContentDeletion(conflicting))
    XCTAssertEqual(viewModel.posts.map(\.id), originalIDs)
    XCTAssertEqual(viewModel.post(withID: reply.id), reply)
  }

  func testAcceptedDeletionTombstoneRejectsAStaleReloadResponse() async throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let reply = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let page = PostPageData(
      thread: thread,
      posts: [reply],
      currentPage: 1,
      hasMore: false,
      firstPost: firstPost
    )
    let service = OwnedContentDeletionBrowseService(pages: [page, page])
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    let target = try XCTUnwrap(OwnedContentDeletionTarget(thread: thread, post: reply))

    XCTAssertTrue(viewModel.applyAcceptedContentDeletion(target))
    viewModel.reload()
    await viewModel.waitForCurrentLoad()

    XCTAssertNil(viewModel.post(withID: reply.id))
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  func testAcceptedDeletionStillCreatesTombstoneWhenRefreshAlreadyRemovedTarget() async throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let reply = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let stalePage = PostPageData(
      thread: thread,
      posts: [reply],
      currentPage: 1,
      hasMore: false,
      firstPost: firstPost
    )
    let alreadyRemovedPage = PostPageData(
      thread: thread,
      posts: [],
      currentPage: 1,
      hasMore: false,
      firstPost: firstPost
    )
    let service = OwnedContentDeletionBrowseService(
      pages: [stalePage, alreadyRemovedPage, stalePage]
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    let target = try XCTUnwrap(OwnedContentDeletionTarget(thread: thread, post: reply))

    viewModel.reload()
    await viewModel.waitForCurrentLoad()
    XCTAssertNil(viewModel.post(withID: reply.id))
    XCTAssertTrue(viewModel.applyAcceptedContentDeletion(target))

    viewModel.reload()
    await viewModel.waitForCurrentLoad()
    XCTAssertNil(viewModel.post(withID: reply.id))
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  func testAcceptedPostStagedBeforeInitialLoadIsAbsentFromFirstLoadedSnapshot() async throws {
    let thread = deletionThread()
    let firstPost = deletionPost(id: 101, threadID: thread.id, floor: 1, authorID: 7)
    let deletedPost = deletionPost(id: 102, threadID: thread.id, floor: 2, authorID: 7)
    let retainedPost = deletionPost(id: 103, threadID: thread.id, floor: 3, authorID: 8)
    let service = OwnedContentDeletionBrowseService(
      page: PostPageData(
        thread: thread,
        posts: [deletedPost, retainedPost],
        currentPage: 1,
        hasMore: false,
        firstPost: firstPost
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    let target = try XCTUnwrap(
      OwnedContentDeletionTarget(thread: thread, post: deletedPost)
    )

    XCTAssertTrue(viewModel.stageAcceptedContentDeletion(target))
    XCTAssertTrue(viewModel.posts.isEmpty)
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.posts.map(\.id), [retainedPost.id])
    XCTAssertNil(viewModel.post(withID: deletedPost.id))
    XCTAssertEqual(viewModel.post(withID: retainedPost.id), retainedPost)
  }

  func testDeepLinkPlaceholderStagesAcceptedPostUntilResolvedIdentityIsValidated() async throws {
    let resolvedThread = deletionThread()
    let placeholder = TiebaThreadRoute(threadID: resolvedThread.id).placeholderThread
    let firstPost = deletionPost(
      id: resolvedThread.firstPostID,
      threadID: resolvedThread.id,
      floor: 1,
      authorID: resolvedThread.authorID
    )
    let deletedPost = deletionPost(
      id: 102,
      threadID: resolvedThread.id,
      floor: 2,
      authorID: 7
    )
    let target = try XCTUnwrap(
      OwnedContentDeletionTarget(thread: resolvedThread, post: deletedPost)
    )
    let viewModel = ThreadViewModel(
      thread: placeholder,
      service: OwnedContentDeletionBrowseService(
        page: PostPageData(
          thread: resolvedThread,
          posts: [deletedPost],
          currentPage: 1,
          hasMore: false,
          firstPost: firstPost
        )
      )
    )

    XCTAssertTrue(
      viewModel.stageAcceptedContentDeletion(
        target,
        allowsUnresolvedThreadIdentity: true
      )
    )
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.thread, resolvedThread)
    XCTAssertNil(viewModel.post(withID: deletedPost.id))
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  func testDeepLinkPlaceholderFailsClosedWhenResponseIdentityRemainsIncomplete() async throws {
    let resolvedThread = deletionThread()
    let placeholder = TiebaThreadRoute(threadID: resolvedThread.id).placeholderThread
    let deletedPost = deletionPost(
      id: 102,
      threadID: resolvedThread.id,
      floor: 2,
      authorID: 7
    )
    let target = try XCTUnwrap(
      OwnedContentDeletionTarget(thread: resolvedThread, post: deletedPost)
    )
    let viewModel = ThreadViewModel(
      thread: placeholder,
      service: OwnedContentDeletionBrowseService(
        page: PostPageData(
          thread: placeholder,
          posts: [deletedPost],
          currentPage: 1,
          hasMore: false
        )
      )
    )

    XCTAssertTrue(
      viewModel.stageAcceptedContentDeletion(
        target,
        allowsUnresolvedThreadIdentity: true
      )
    )
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回的主题身份不足，无法安全恢复已删除楼层。")
    )
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  func testDeepLinkPlaceholderStagedDeletionFailsClosedOnResolvedIdentityConflict()
    async throws
  {
    let resolvedThread = deletionThread()
    let placeholder = TiebaThreadRoute(threadID: resolvedThread.id).placeholderThread
    let firstPost = deletionPost(
      id: resolvedThread.firstPostID,
      threadID: resolvedThread.id,
      floor: 1,
      authorID: resolvedThread.authorID
    )
    let reply = deletionPost(id: 102, threadID: resolvedThread.id, floor: 2, authorID: 7)
    let conflictingTarget = try XCTUnwrap(
      OwnedContentDeletionTarget(
        kind: .post,
        forumID: resolvedThread.forumID + 1,
        forumName: resolvedThread.forumName,
        threadID: resolvedThread.id,
        objectID: reply.id,
        authorID: reply.authorID,
        floor: reply.floor
      )
    )
    let viewModel = ThreadViewModel(
      thread: placeholder,
      service: OwnedContentDeletionBrowseService(
        page: PostPageData(
          thread: resolvedThread,
          posts: [reply],
          currentPage: 1,
          hasMore: false,
          firstPost: firstPost
        )
      )
    )

    XCTAssertTrue(
      viewModel.stageAcceptedContentDeletion(
        conflictingTarget,
        allowsUnresolvedThreadIdentity: true
      )
    )
    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.post(withID: reply.id), reply)
    XCTAssertEqual(viewModel.posts.map(\.id), [reply.id])
  }
}

private enum OwnedContentDeletionTestError: LocalizedError, Sendable {
  case unexpectedRequest

  var errorDescription: String? { "unexpected test request" }
}

private actor OwnedContentDeletionVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? { session }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }
}

private enum OwnedContentDeletionServiceBehavior: Equatable, Sendable {
  case accepted
  case unavailable
  case cancellation
  case definiteFailure
  case outcomeUnknown
  case suspendedAccepted
  case suspendedMismatchedReceipt
}

private actor OwnedContentDeletionServiceSpy: AccountService {
  private let behavior: OwnedContentDeletionServiceBehavior
  private var requests: [(AccountSessionLease, OwnedContentDeletionTarget)] = []
  private var writeWaiters: [CheckedContinuation<Void, Never>] = []
  private var writesReleased = false

  init(behavior: OwnedContentDeletionServiceBehavior = .accepted) {
    self.behavior = behavior
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func contentAgreements(
    session: StoredAccountSession,
    descriptor: ContentAgreementReadDescriptor
  ) async throws -> ContentAgreementPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func deleteOwnedContent(
    session: StoredAccountSession,
    target: OwnedContentDeletionTarget
  ) async throws -> OwnedContentDeletionReceipt {
    requests.append((AccountSessionLease(session), target))
    if (behavior == .suspendedAccepted || behavior == .suspendedMismatchedReceipt),
      !writesReleased
    {
      await withCheckedContinuation { writeWaiters.append($0) }
    }
    switch behavior {
    case .accepted, .suspendedAccepted:
      return OwnedContentDeletionReceipt(
        accountID: session.id,
        sessionRevision: session.sessionRevision,
        target: target
      )
    case .unavailable:
      throw OwnedContentDeletionError.unavailable("temporary service failure")
    case .cancellation:
      throw CancellationError()
    case .definiteFailure:
      throw OwnedContentDeletionError.rejected(code: 123)
    case .outcomeUnknown:
      throw OwnedContentDeletionError.outcomeUnknown
    case .suspendedMismatchedReceipt:
      return OwnedContentDeletionReceipt(
        accountID: session.id,
        sessionRevision: UUID(),
        target: target
      )
    }
  }

  func releaseWrites() {
    writesReleased = true
    let waiters = writeWaiters
    writeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func writeCount() -> Int { requests.count }
}

private actor OwnedContentDeletionPublishedPrepareFailureLedger:
  OwnedContentDeletionLedgerRepository
{
  private let backing: TransientOwnedContentDeletionLedger

  init(backing: TransientOwnedContentDeletionLedger) {
    self.backing = backing
  }

  func records() async throws -> [OwnedContentDeletionLedgerRecord] {
    try await backing.records()
  }

  func record(
    for key: OwnedContentDeletionLedgerKey
  ) async throws -> OwnedContentDeletionLedgerRecord? {
    try await backing.record(for: key)
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    _ = try await backing.prepare(
      target: target,
      accountID: accountID,
      sessionRevision: sessionRevision,
      operationID: operationID,
      at: date
    )
    throw OwnedContentDeletionLedgerError.writeFailed
  }

  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await backing.transition(
      for: key,
      operationID: operationID,
      to: phase,
      at: date
    )
  }

  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws {
    try await backing.removeDispatchPending(for: key, operationID: operationID)
  }
}

private actor OwnedContentDeletionPrepareGateLedger: OwnedContentDeletionLedgerRepository {
  private let backing: TransientOwnedContentDeletionLedger
  private var preparePublished = false
  private var prepareReleased = false
  private var prepareWaiters: [CheckedContinuation<Void, Never>] = []

  init(backing: TransientOwnedContentDeletionLedger) {
    self.backing = backing
  }

  func records() async throws -> [OwnedContentDeletionLedgerRecord] {
    try await backing.records()
  }

  func record(
    for key: OwnedContentDeletionLedgerKey
  ) async throws -> OwnedContentDeletionLedgerRecord? {
    try await backing.record(for: key)
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    let record = try await backing.prepare(
      target: target,
      accountID: accountID,
      sessionRevision: sessionRevision,
      operationID: operationID,
      at: date
    )
    preparePublished = true
    if !prepareReleased {
      await withCheckedContinuation { prepareWaiters.append($0) }
    }
    return record
  }

  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await backing.transition(
      for: key,
      operationID: operationID,
      to: phase,
      at: date
    )
  }

  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws {
    try await backing.removeDispatchPending(for: key, operationID: operationID)
  }

  func hasPublishedPrepare() -> Bool { preparePublished }

  func releasePrepare() {
    prepareReleased = true
    let waiters = prepareWaiters
    prepareWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private actor OwnedContentDeletionTerminalFailureLedger:
  OwnedContentDeletionLedgerRepository
{
  private let backing: TransientOwnedContentDeletionLedger

  init(backing: TransientOwnedContentDeletionLedger) {
    self.backing = backing
  }

  func records() async throws -> [OwnedContentDeletionLedgerRecord] {
    try await backing.records()
  }

  func record(
    for key: OwnedContentDeletionLedgerKey
  ) async throws -> OwnedContentDeletionLedgerRecord? {
    try await backing.record(for: key)
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await backing.prepare(
      target: target,
      accountID: accountID,
      sessionRevision: sessionRevision,
      operationID: operationID,
      at: date
    )
  }

  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    throw OwnedContentDeletionLedgerError.writeFailed
  }

  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws {
    try await backing.removeDispatchPending(for: key, operationID: operationID)
  }
}

private actor OwnedContentDeletionBrowseService: BrowseService {
  private var pages: [PostPageData]

  init(page: PostPageData) {
    pages = [page]
  }

  init(pages: [PostPageData]) {
    self.pages = pages
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    guard !pages.isEmpty else { throw OwnedContentDeletionTestError.unexpectedRequest }
    return pages.removeFirst()
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }

  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData {
    throw OwnedContentDeletionTestError.unexpectedRequest
  }
}

private func deletionSession(
  revisionComponent: Int,
  userID: Int64,
  hasFullCredentials: Bool = true
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester-\(userID)",
    displayName: "Tester \(userID)",
    portrait: "portrait",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: hasFullCredentials
      ? String(repeating: "s", count: AccountCredentialFormat.stokenLength)
      : nil,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID(
      uuidString: String(format: "00000000-0000-0000-0000-%012d", revisionComponent)
    )!
  )
}

private func deletionThread(
  visibility: LocalContentVisibility = .visible
) -> BrowseThread {
  BrowseThread(
    id: 10,
    forumID: 42,
    forumName: "swift",
    title: "Deletion contract",
    excerpt: "",
    authorName: "owner",
    replyCount: 2,
    viewCount: 3,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [.text("first post")],
    authorID: 7,
    firstPostID: 101,
    localVisibility: visibility
  )
}

private func deletionPost(
  id: Int64,
  threadID: Int64,
  floor: Int,
  authorID: Int64,
  visibility: LocalContentVisibility = .visible
) -> BrowsePost {
  BrowsePost(
    id: id,
    threadID: threadID,
    floor: floor,
    authorID: authorID,
    authorName: "author-\(authorID)",
    authorPortraitURL: nil,
    createdAt: nil,
    nestedReplyCount: 0,
    isThreadAuthor: authorID == 7,
    contents: [.text("post-\(id)")],
    localVisibility: visibility
  )
}

private func deletionTarget(authorID: Int64) -> OwnedContentDeletionTarget {
  OwnedContentDeletionTarget(
    kind: .post,
    forumID: 42,
    forumName: "swift",
    threadID: 10,
    objectID: 102,
    authorID: authorID,
    floor: 2
  )!
}

@MainActor
private func waitForOwnedContentDeletionTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw OwnedContentDeletionTestError.unexpectedRequest
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
