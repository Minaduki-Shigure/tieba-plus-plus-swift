import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ThreadCloudFavoriteStoreTests: XCTestCase {
  func testSignedOutActivationMakesNoAuthenticatedRequest() async {
    let target = favoriteTarget(threadID: 10)
    let vault = ThreadCloudFavoriteVaultSpy()
    let service = ThreadCloudFavoriteStoreServiceSpy()
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)

    await store.activate(target, for: UUID())

    XCTAssertEqual(entry.state, .signedOut)
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(writeCount, 0)
  }

  func testTwoScopesShareSessionResolutionAndOneInFlightRead() async throws {
    let session = favoriteSession(revisionComponent: 1)
    let target = favoriteTarget(threadID: 11)
    let vault = ThreadCloudFavoriteVaultSpy(session: session, suspendsReads: true)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 101))
        ]
      ],
      suspendedReadRevisions: [session.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let firstScope = UUID()
    let secondScope = UUID()

    let first = Task { await store.activate(target, for: firstScope) }
    try await waitForThreadCloudFavoriteStoreTest {
      await vault.activeSessionReadCount() == 1
    }
    let second = Task { await store.activate(target, for: secondScope) }
    for _ in 0..<20 { await Task.yield() }
    let sessionReadCount = await vault.activeSessionReadCount()
    XCTAssertEqual(sessionReadCount, 1)

    await vault.releaseReads()
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount() == 1
    }
    XCTAssertEqual(entry.state, .loading(previous: nil))
    await service.releaseReads(for: session.sessionRevision)
    await first.value
    await second.value

    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(101)))
    XCTAssertTrue(entry === store.entry(for: target))
    let readCount = await service.readCount()
    XCTAssertEqual(readCount, 1)
  }

  func testDeactivatingLastScopeRejectsLateReadResult() async throws {
    let session = favoriteSession(revisionComponent: 2)
    let target = favoriteTarget(threadID: 12)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 102))
        ]
      ],
      suspendedReadRevisions: [session.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let scope = UUID()

    let activation = Task { await store.activate(target, for: scope) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount() == 1
    }
    store.deactivate(scope)
    XCTAssertEqual(entry.state, .unknown)

    await service.releaseReads(for: session.sessionRevision)
    await activation.value
    XCTAssertEqual(entry.state, .unknown)
  }

  func testIdenticalConcurrentMutationsCoalesceAndPostOneChange() async throws {
    let session = favoriteSession(revisionComponent: 3)
    let target = favoriteTarget(threadID: 13)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: nil))
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: 103): [
          .success(favoriteData(session: session, target: target, markedPostID: 103))
        ]
      ],
      suspendedWriteRevisions: [session.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(nil)))

    let recorder = ThreadCloudFavoriteNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadCloudFavoriteDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadCloudFavoriteChange(notification),
        change.sessionRevision == session.sessionRevision,
        change.target == target
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let first = Task { try await store.setMarkedPostID(103, for: target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.writeCount() == 1
    }
    let second = Task { try await store.setMarkedPostID(103, for: target) }
    for _ in 0..<20 { await Task.yield() }
    let countBeforeRelease = await service.writeCount()
    XCTAssertEqual(countBeforeRelease, 1)

    await service.releaseWrites(for: session.sessionRevision)
    let firstSnapshot = try await first.value
    let secondSnapshot = try await second.value

    XCTAssertEqual(firstSnapshot, favoriteSnapshot(103))
    XCTAssertEqual(secondSnapshot, firstSnapshot)
    XCTAssertEqual(entry.state, .ready(firstSnapshot))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(
      recorder.snapshot(),
      [
        ThreadCloudFavoriteChange(
          accountID: session.id,
          sessionRevision: session.sessionRevision,
          target: target,
          snapshot: firstSnapshot
        )
      ]
    )
  }

  func testConflictingMutationWaitsThenRereadsWithoutSecondWrite() async throws {
    let session = favoriteSession(revisionComponent: 4)
    let target = favoriteTarget(threadID: 14)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: nil)),
          .success(favoriteData(session: session, target: target, markedPostID: 104)),
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: 104): [
          .success(favoriteData(session: session, target: target, markedPostID: 104))
        ]
      ],
      suspendedWriteRevisions: [session.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())

    let add = Task { try await store.setMarkedPostID(104, for: target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.writeCount() == 1
    }
    let remove = Task { () -> String? in
      do {
        _ = try await store.setMarkedPostID(nil, for: target)
        return nil
      } catch {
        return error.localizedDescription
      }
    }

    await service.releaseWrites(for: session.sessionRevision)
    let addSnapshot = try await add.value
    XCTAssertEqual(addSnapshot, favoriteSnapshot(104))
    let removeMessage = await remove.value

    XCTAssertNotNil(removeMessage)
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(104)))
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testSameUserNewRevisionRejectsOldReadAndReloadsActiveScope() async throws {
    let oldSession = favoriteSession(revisionComponent: 5)
    let newSession = favoriteSession(revisionComponent: 6)
    let target = favoriteTarget(threadID: 15)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: nil))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 105))
        ],
      ],
      suspendedReadRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let activation = Task { await store.activate(target, for: UUID()) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForThreadCloudFavoriteStoreTest {
      entry.state == .ready(favoriteSnapshot(105))
    }

    await service.releaseReads(for: oldSession.sessionRevision)
    await activation.value
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(105)))
    let oldReads = await service.readCount(for: oldSession.sessionRevision)
    let newReads = await service.readCount(for: newSession.sessionRevision)
    XCTAssertEqual(oldReads, 1)
    XCTAssertEqual(newReads, 1)
  }

  func testLateOldSessionReadFailureBecomesCancellation() async throws {
    let oldSession = favoriteSession(revisionComponent: 17)
    let newSession = favoriteSession(revisionComponent: 18)
    let target = favoriteTarget(threadID: 28)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "old read failed"))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 120))
        ],
      ],
      suspendedReadRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let staleReload = Task { try await store.reload(target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    let current = try await store.reload(target)
    XCTAssertEqual(current, favoriteSnapshot(120))

    await service.releaseReads(for: oldSession.sessionRevision)
    switch await staleReload.result {
    case .success:
      XCTFail("stale read unexpectedly succeeded")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(120)))
  }

  func testCurrentReadLeaseLossCancelsAndRestoresRetryableState() async throws {
    let oldSession = favoriteSession(revisionComponent: 23)
    let newSession = favoriteSession(revisionComponent: 24)
    let target = favoriteTarget(threadID: 32)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: 126))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 127))
        ],
      ],
      suspendedReadRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let staleRead = Task { try await store.reload(target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    await service.releaseReads(for: oldSession.sessionRevision)
    switch await staleRead.result {
    case .success:
      XCTFail("read with a lost lease unexpectedly succeeded")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(
      entry.state,
      .failed(
        previous: nil,
        message: "云端收藏状态尚未确认，请重新读取当前状态。"
      )
    )

    let recovered = try await store.reload(target)
    XCTAssertEqual(recovered, favoriteSnapshot(127))
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(127)))
  }

  func testCurrentMutationLeaseLossRequiresReadOnlyRecovery() async throws {
    let oldSession = favoriteSession(revisionComponent: 25)
    let newSession = favoriteSession(revisionComponent: 26)
    let target = favoriteTarget(threadID: 33)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: nil))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 128))
        ],
      ],
      writeResults: [
        FavoriteWriteKey(session: oldSession, target: target, markedPostID: 128): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: 128))
        ]
      ],
      suspendedWriteRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())
    let uncertainWrite = Task { try await store.setMarkedPostID(128, for: target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.writeCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    await service.releaseWrites(for: oldSession.sessionRevision)
    switch await uncertainWrite.result {
    case .success:
      XCTFail("write with a lost lease unexpectedly succeeded")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(
      entry.state,
      .failed(
        previous: favoriteSnapshot(nil),
        message: "云端收藏结果尚未确认，请重新读取当前状态。"
      )
    )

    let recovered = try await store.reload(target)
    XCTAssertEqual(recovered, favoriteSnapshot(128))
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(128)))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testAccountChangeReloadsActiveTargetsConcurrently() async throws {
    let oldSession = favoriteSession(revisionComponent: 19)
    let newSession = favoriteSession(revisionComponent: 20, userID: 8)
    let firstTarget = favoriteTarget(threadID: 29)
    let secondTarget = favoriteTarget(threadID: 30)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: firstTarget): [
          .success(favoriteData(session: oldSession, target: firstTarget, markedPostID: nil))
        ],
        FavoriteReadKey(session: oldSession, target: secondTarget): [
          .success(favoriteData(session: oldSession, target: secondTarget, markedPostID: nil))
        ],
        FavoriteReadKey(session: newSession, target: firstTarget): [
          .success(favoriteData(session: newSession, target: firstTarget, markedPostID: 121))
        ],
        FavoriteReadKey(session: newSession, target: secondTarget): [
          .success(favoriteData(session: newSession, target: secondTarget, markedPostID: 122))
        ],
      ],
      suspendedReadRevisions: [newSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let firstEntry = store.entry(for: firstTarget)
    let secondEntry = store.entry(for: secondTarget)
    await store.activate(firstTarget, for: UUID())
    await store.activate(secondTarget, for: UUID())

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount(for: newSession.sessionRevision) == 2
    }

    await service.releaseReads(for: newSession.sessionRevision)
    try await waitForThreadCloudFavoriteStoreTest {
      firstEntry.state == .ready(favoriteSnapshot(121))
        && secondEntry.state == .ready(favoriteSnapshot(122))
    }
  }

  func testAccountChangeClearsInactiveCacheAndReloadsOnlyActiveTargets() async throws {
    let oldSession = favoriteSession(revisionComponent: 7)
    let newSession = favoriteSession(revisionComponent: 8, userID: 8)
    let activeTarget = favoriteTarget(threadID: 16)
    let inactiveTarget = favoriteTarget(threadID: 17)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: activeTarget): [
          .success(favoriteData(session: oldSession, target: activeTarget, markedPostID: 106))
        ],
        FavoriteReadKey(session: oldSession, target: inactiveTarget): [
          .success(favoriteData(session: oldSession, target: inactiveTarget, markedPostID: 107))
        ],
        FavoriteReadKey(session: newSession, target: activeTarget): [
          .success(favoriteData(session: newSession, target: activeTarget, markedPostID: nil))
        ],
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let activeEntry = store.entry(for: activeTarget)
    let inactiveEntry = store.entry(for: inactiveTarget)
    await store.activate(activeTarget, for: UUID())
    _ = try await store.reload(inactiveTarget)
    XCTAssertEqual(inactiveEntry.state, .ready(favoriteSnapshot(107)))

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForThreadCloudFavoriteStoreTest {
      activeEntry.state == .ready(favoriteSnapshot(nil))
    }

    XCTAssertEqual(inactiveEntry.state, .unknown)
    let newTargets = await service.readTargets(for: newSession.sessionRevision)
    XCTAssertEqual(newTargets, [activeTarget])
  }

  func testAccountChangeDuringWriteRejectsOldResultAndPostsNoChange() async throws {
    let oldSession = favoriteSession(revisionComponent: 9)
    let newSession = favoriteSession(revisionComponent: 10)
    let target = favoriteTarget(threadID: 18)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: nil))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 108))
        ],
      ],
      writeResults: [
        FavoriteWriteKey(session: oldSession, target: target, markedPostID: 109): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "old write failed"))
        ]
      ],
      suspendedWriteRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    let scope = UUID()
    await store.activate(target, for: scope)

    let recorder = ThreadCloudFavoriteNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadCloudFavoriteDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadCloudFavoriteChange(notification),
        change.sessionRevision == oldSession.sessionRevision,
        change.target == target
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let oldWrite = Task { try await store.setMarkedPostID(109, for: target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.writeCount() == 1
    }
    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForThreadCloudFavoriteStoreTest {
      entry.state == .ready(favoriteSnapshot(108))
    }
    let newReadsBeforeOldWriteSettles = await service.readCount(
      for: newSession.sessionRevision
    )
    XCTAssertEqual(newReadsBeforeOldWriteSettles, 1)

    await service.releaseWrites(for: oldSession.sessionRevision)
    switch await oldWrite.result {
    case .success:
      XCTFail("old-session mutation unexpectedly succeeded")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }

    XCTAssertTrue(recorder.snapshot().isEmpty)
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(108)))
    let oldWrites = await service.writeCount(for: oldSession.sessionRevision)
    XCTAssertEqual(oldWrites, 1)
  }

  func testDifferentAccountCanWriteBeforeOldAccountMutationSettles() async throws {
    let oldSession = favoriteSession(revisionComponent: 21)
    let newSession = favoriteSession(revisionComponent: 22, userID: 8)
    let target = favoriteTarget(threadID: 31)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: nil))
        ],
        FavoriteReadKey(session: newSession, target: target): [
          .success(favoriteData(session: newSession, target: target, markedPostID: nil))
        ],
      ],
      writeResults: [
        FavoriteWriteKey(session: oldSession, target: target, markedPostID: 123): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: 123))
        ],
        FavoriteWriteKey(session: newSession, target: target, markedPostID: 124): [
          .success(favoriteData(session: newSession, target: target, markedPostID: 124))
        ],
      ],
      suspendedWriteRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())
    let oldWrite = Task { try await store.setMarkedPostID(123, for: target) }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.writeCount(for: oldSession.sessionRevision) == 1
    }

    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    try await waitForThreadCloudFavoriteStoreTest {
      entry.state == .ready(favoriteSnapshot(nil))
    }

    let recorder = ThreadCloudFavoriteNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadCloudFavoriteDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadCloudFavoriteChange(notification),
        change.target == target
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let newSnapshot = try await store.setMarkedPostID(124, for: target)
    XCTAssertEqual(newSnapshot, favoriteSnapshot(124))
    let newWritesBeforeRelease = await service.writeCount(for: newSession.sessionRevision)
    XCTAssertEqual(newWritesBeforeRelease, 1)

    await service.releaseWrites(for: oldSession.sessionRevision)
    switch await oldWrite.result {
    case .success:
      XCTFail("old-account mutation unexpectedly succeeded")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(124)))
    XCTAssertEqual(
      recorder.snapshot().map(\.sessionRevision),
      [newSession.sessionRevision]
    )
  }

  func testMismatchedReadIsRejectedWithoutApplyingSnapshot() async {
    let session = favoriteSession(revisionComponent: 11)
    let target = favoriteTarget(threadID: 19)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let mismatched = ThreadCloudFavoriteData(
      userID: session.id + 1,
      target: target,
      snapshot: favoriteSnapshot(110)
    )
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [.success(mismatched)]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)

    await store.activate(target, for: UUID())

    guard case .failed(let previous, _) = entry.state else {
      return XCTFail("mismatched response should leave a retryable failure")
    }
    XCTAssertNil(previous)
  }

  func testWriteFailureKeepsPreviousSnapshotAndExplicitReloadRecovers() async throws {
    let session = favoriteSession(revisionComponent: 12)
    let target = favoriteTarget(threadID: 20)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: nil)),
          .success(favoriteData(session: session, target: target, markedPostID: 111)),
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: 111): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "write failed"))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())

    do {
      _ = try await store.setMarkedPostID(111, for: target)
      XCTFail("mutation should fail")
    } catch {
      XCTAssertEqual(error.localizedDescription, "write failed")
    }
    guard case .failed(let previous, let message) = entry.state else {
      return XCTFail("write failure should preserve the prior snapshot")
    }
    XCTAssertEqual(previous, favoriteSnapshot(nil))
    XCTAssertEqual(message, "write failed")

    let recovered = try await store.reload(target)
    XCTAssertEqual(recovered, favoriteSnapshot(111))
    XCTAssertEqual(entry.state, .ready(favoriteSnapshot(111)))
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testSuccessfulRemovalUsesNilMarkerAndPostsRemovedSnapshot() async throws {
    let session = favoriteSession(revisionComponent: 16)
    let target = favoriteTarget(threadID: 27)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 119))
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: nil): [
          .success(favoriteData(session: session, target: target, markedPostID: nil))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)
    let entry = store.entry(for: target)
    await store.activate(target, for: UUID())

    let recorder = ThreadCloudFavoriteNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadCloudFavoriteDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadCloudFavoriteChange(notification),
        change.sessionRevision == session.sessionRevision,
        change.target == target
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let removed = try await store.setMarkedPostID(nil, for: target)

    XCTAssertEqual(removed, favoriteSnapshot(nil))
    XCTAssertEqual(entry.state, .ready(removed))
    XCTAssertEqual(recorder.snapshot().map(\.snapshot), [removed])
    let requests = await service.writeMarkers(for: session.sessionRevision)
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0])
  }

  func testInvalidMarkerAndUnloadedMutationNeverWrite() async {
    let session = favoriteSession(revisionComponent: 13)
    let target = favoriteTarget(threadID: 21)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy()
    let store = makeFavoriteStore(vault: vault, service: service)

    do {
      _ = try await store.setMarkedPostID(0, for: target)
      XCTFail("zero marker should be rejected")
    } catch {}
    do {
      _ = try await store.setMarkedPostID(112, for: target)
      XCTFail("unloaded state should be rejected")
    } catch {}

    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testBoundedCacheRetainsActiveAndNewlyReturnedEntryUntilActivation() async throws {
    let session = favoriteSession(revisionComponent: 14)
    let target = favoriteTarget(threadID: 22)
    let newTarget = favoriteTarget(threadID: 23)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: nil))
        ],
        FavoriteReadKey(session: session, target: newTarget): [
          .success(favoriteData(session: session, target: newTarget, markedPostID: 125))
        ],
      ]
    )
    let store = ThreadCloudFavoriteStore(
      access: AccountAccess(vault: vault, service: service),
      capacity: 1,
      observesAccountSessionChanges: false
    )
    let retained = store.entry(for: target)
    await store.activate(target, for: UUID())

    let newcomer = store.entry(for: newTarget)
    XCTAssertTrue(newcomer === store.entry(for: newTarget))
    await store.activate(newTarget, for: UUID())

    XCTAssertTrue(retained === store.entry(for: target))
    XCTAssertTrue(newcomer === store.entry(for: newTarget))
    XCTAssertEqual(newcomer.state, .ready(favoriteSnapshot(125)))
  }

  func testPositionAndConfirmationModelsFailClosed() {
    let target = favoriteTarget(threadID: 25)
    let validPost = favoritePost(id: 115, threadID: 25, floor: 6)
    let position = ThreadCloudFavoritePosition(post: validPost, threadID: 25)
    XCTAssertEqual(position, ThreadCloudFavoritePosition(post: validPost, threadID: 25))
    XCTAssertEqual(position?.postID, 115)
    XCTAssertEqual(position?.floor, 6)
    XCTAssertNil(
      ThreadCloudFavoritePosition(
        post: favoritePost(id: 116, threadID: 26, floor: 7),
        threadID: 25
      )
    )
    XCTAssertNil(
      ThreadCloudFavoritePosition(
        post: favoritePost(id: 0, threadID: 25, floor: 7),
        threadID: 25
      )
    )
    XCTAssertNil(
      ThreadCloudFavoritePosition(
        post: favoritePost(id: 117, threadID: 25, floor: 0),
        threadID: 25
      )
    )

    let validPosition = position!
    let add = ThreadCloudFavoritePendingAction.add(target: target, position: validPosition)
    let update = ThreadCloudFavoritePendingAction.update(
      target: target,
      position: validPosition
    )
    let remove = ThreadCloudFavoritePendingAction.remove(target: target)
    XCTAssertEqual(add.requestedMarkedPostID, 115)
    XCTAssertEqual(update.requestedMarkedPostID, 115)
    XCTAssertNil(remove.requestedMarkedPostID)
    XCTAssertFalse(add.isDestructive)
    XCTAssertFalse(update.isDestructive)
    XCTAssertTrue(remove.isDestructive)
    XCTAssertEqual(add.target, target)
    XCTAssertTrue(add.message.contains("第 6 楼"))
  }

  func testLeaseBoundRemovalReadsThenWritesExactlyOnce() async throws {
    let session = favoriteSession(revisionComponent: 16)
    let target = favoriteTarget(threadID: 27)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 127))
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: nil): [
          .success(favoriteData(session: session, target: target, markedPostID: nil))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    let snapshot = try await store.removeCloudFavorite(
      target,
      expectedSession: ThreadCloudFavoriteSessionExpectation(
        userID: session.id,
        sessionRevision: session.sessionRevision
      )
    )

    XCTAssertEqual(snapshot, favoriteSnapshot(nil))
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    let markers = await service.writeMarkers(for: session.sessionRevision)
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(markers, [nil])
    XCTAssertEqual(store.entry(for: target).state, .ready(favoriteSnapshot(nil)))
  }

  func testLeaseBoundRemovalIsIdempotentWhenReadAlreadyShowsRemoved() async throws {
    let session = favoriteSession(revisionComponent: 17)
    let target = favoriteTarget(threadID: 28)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: nil))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    let snapshot = try await store.removeCloudFavorite(
      target,
      expectedSession: ThreadCloudFavoriteSessionExpectation(
        userID: session.id,
        sessionRevision: session.sessionRevision
      )
    )

    XCTAssertEqual(snapshot, favoriteSnapshot(nil))
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(writeCount, 0)
  }

  func testLeaseBoundRemovalRejectsDifferentRevisionBeforeServiceRead() async {
    let expected = favoriteSession(revisionComponent: 18)
    let active = favoriteSession(revisionComponent: 19)
    let target = favoriteTarget(threadID: 29)
    let vault = ThreadCloudFavoriteVaultSpy(session: active)
    let service = ThreadCloudFavoriteStoreServiceSpy()
    let store = makeFavoriteStore(vault: vault, service: service)

    do {
      _ = try await store.removeCloudFavorite(
        target,
        expectedSession: ThreadCloudFavoriteSessionExpectation(
          userID: expected.id,
          sessionRevision: expected.sessionRevision
        )
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // The old list lease must not authorize a read or write for the new session.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(writeCount, 0)
  }

  func testLeaseBoundRemovalReconcilesCommittedWriteFailureWithoutRetry() async throws {
    let session = favoriteSession(revisionComponent: 20)
    let target = favoriteTarget(threadID: 30)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 130)),
          .success(favoriteData(session: session, target: target, markedPostID: nil)),
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: nil): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "connection lost"))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    let snapshot = try await store.removeCloudFavorite(
      target,
      expectedSession: ThreadCloudFavoriteSessionExpectation(
        userID: session.id,
        sessionRevision: session.sessionRevision
      )
    )

    XCTAssertEqual(snapshot, favoriteSnapshot(nil))
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testLeaseBoundRemovalRetainsWriteFailureWhenReadbackStillFavorited() async {
    let session = favoriteSession(revisionComponent: 21)
    let target = favoriteTarget(threadID: 31)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 131)),
          .success(favoriteData(session: session, target: target, markedPostID: 131)),
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: nil): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "server rejected"))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    do {
      _ = try await store.removeCloudFavorite(
        target,
        expectedSession: ThreadCloudFavoriteSessionExpectation(
          userID: session.id,
          sessionRevision: session.sessionRevision
        )
      )
      XCTFail("Expected removal to fail")
    } catch {
      XCTAssertEqual(error.localizedDescription, "server rejected")
    }
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testLeaseBoundRemovalReportsUnknownWhenWriteAndReadbackFail() async {
    let session = favoriteSession(revisionComponent: 22)
    let target = favoriteTarget(threadID: 32)
    let vault = ThreadCloudFavoriteVaultSpy(session: session)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: session, target: target): [
          .success(favoriteData(session: session, target: target, markedPostID: 132)),
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "readback failed")),
        ]
      ],
      writeResults: [
        FavoriteWriteKey(session: session, target: target, markedPostID: nil): [
          .failure(ThreadCloudFavoriteStoreTestFailure(message: "connection lost"))
        ]
      ]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    do {
      _ = try await store.removeCloudFavorite(
        target,
        expectedSession: ThreadCloudFavoriteSessionExpectation(
          userID: session.id,
          sessionRevision: session.sessionRevision
        )
      )
      XCTFail("Expected unknown outcome")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("不会自动重发"))
    }
    let readCount = await service.readCount()
    let writeCount = await service.writeCount()
    XCTAssertEqual(readCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testLeaseBoundRemovalCannotAdoptNewSessionDuringSuspendedPreflight() async throws {
    let oldSession = favoriteSession(revisionComponent: 23)
    let newSession = favoriteSession(revisionComponent: 24, userID: 8)
    let target = favoriteTarget(threadID: 33)
    let vault = ThreadCloudFavoriteVaultSpy(session: oldSession)
    let service = ThreadCloudFavoriteStoreServiceSpy(
      readResults: [
        FavoriteReadKey(session: oldSession, target: target): [
          .success(favoriteData(session: oldSession, target: target, markedPostID: 133))
        ]
      ],
      suspendedReadRevisions: [oldSession.sessionRevision]
    )
    let store = makeFavoriteStore(vault: vault, service: service)

    let removal = Task { () -> Bool in
      do {
        _ = try await store.removeCloudFavorite(
          target,
          expectedSession: ThreadCloudFavoriteSessionExpectation(
            userID: oldSession.id,
            sessionRevision: oldSession.sessionRevision
          )
        )
        return false
      } catch {
        return true
      }
    }
    try await waitForThreadCloudFavoriteStoreTest {
      await service.readCount(for: oldSession.sessionRevision) == 1
    }
    await vault.replaceActive(with: newSession)
    store.accountSessionDidChange()
    await service.releaseReads(for: oldSession.sessionRevision)

    let removalFailed = await removal.value
    XCTAssertTrue(removalFailed)
    let oldWrites = await service.writeCount(for: oldSession.sessionRevision)
    let newWrites = await service.writeCount(for: newSession.sessionRevision)
    XCTAssertEqual(oldWrites, 0)
    XCTAssertEqual(newWrites, 0)
  }

  func testNotificationParserRequiresConsistentStrictPayload() throws {
    let session = favoriteSession(revisionComponent: 15)
    let target = favoriteTarget(threadID: 26)
    let validInfo: [AnyHashable: Any] = [
      "accountID": NSNumber(value: session.id),
      "sessionRevision": session.sessionRevision.uuidString,
      "forumID": NSNumber(value: target.forumID),
      "forumName": target.forumName,
      "threadID": NSNumber(value: target.threadID),
      "isFavorited": NSNumber(value: 1),
      "markedPostID": NSNumber(value: 118),
    ]
    let valid = try XCTUnwrap(
      ThreadCloudFavoriteChange(
        Notification(name: .threadCloudFavoriteDidChange, userInfo: validInfo)
      )
    )
    XCTAssertEqual(valid.accountID, session.id)
    XCTAssertEqual(valid.sessionRevision, session.sessionRevision)
    XCTAssertEqual(valid.target, target)
    XCTAssertEqual(valid.snapshot, favoriteSnapshot(118))

    var missingMarker = validInfo
    missingMarker.removeValue(forKey: "markedPostID")
    XCTAssertNil(
      ThreadCloudFavoriteChange(
        Notification(name: .threadCloudFavoriteDidChange, userInfo: missingMarker)
      )
    )

    var contradictoryRemoval = validInfo
    contradictoryRemoval["isFavorited"] = NSNumber(value: 0)
    XCTAssertNil(
      ThreadCloudFavoriteChange(
        Notification(name: .threadCloudFavoriteDidChange, userInfo: contradictoryRemoval)
      )
    )

    var invalidAccount = validInfo
    invalidAccount["accountID"] = NSNumber(value: 0)
    XCTAssertNil(
      ThreadCloudFavoriteChange(
        Notification(name: .threadCloudFavoriteDidChange, userInfo: invalidAccount)
      )
    )

    var fractionalMarker = validInfo
    fractionalMarker["markedPostID"] = NSNumber(value: 1.5)
    XCTAssertNil(
      ThreadCloudFavoriteChange(
        Notification(name: .threadCloudFavoriteDidChange, userInfo: fractionalMarker)
      )
    )
  }
}

private struct FavoriteReadKey: Hashable, Sendable {
  let revision: UUID
  let target: ThreadCloudFavoriteTarget

  init(session: StoredAccountSession, target: ThreadCloudFavoriteTarget) {
    revision = session.sessionRevision
    self.target = target
  }
}

private struct FavoriteWriteKey: Hashable, Sendable {
  let revision: UUID
  let target: ThreadCloudFavoriteTarget
  let markedPostID: Int64?

  init(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) {
    revision = session.sessionRevision
    self.target = target
    self.markedPostID = markedPostID
  }
}

private struct ThreadCloudFavoriteStoreTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private final class ThreadCloudFavoriteNotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = [ThreadCloudFavoriteChange]()

  func record(_ change: ThreadCloudFavoriteChange) {
    lock.withLock { changes.append(change) }
  }

  func snapshot() -> [ThreadCloudFavoriteChange] {
    lock.withLock { changes }
  }
}

private actor ThreadCloudFavoriteVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private let suspendsReads: Bool
  private var readsReleased = false
  private var readWaiters = [CheckedContinuation<Void, Never>]()
  private var readCount = 0

  init(session: StoredAccountSession? = nil, suspendsReads: Bool = false) {
    self.session = session
    self.suspendsReads = suspendsReads
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    readCount += 1
    if suspendsReads, !readsReleased {
      await withCheckedContinuation { readWaiters.append($0) }
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

  func releaseReads() {
    readsReleased = true
    let waiters = readWaiters
    readWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func activeSessionReadCount() -> Int { readCount }
}

private actor ThreadCloudFavoriteStoreServiceSpy: AccountService {
  private struct ReadRequest: Sendable {
    let userID: Int64
    let revision: UUID
    let target: ThreadCloudFavoriteTarget
  }

  private struct WriteRequest: Sendable {
    let userID: Int64
    let revision: UUID
    let target: ThreadCloudFavoriteTarget
    let markedPostID: Int64?
  }

  private var readResults: [
    FavoriteReadKey: [Result<ThreadCloudFavoriteData, ThreadCloudFavoriteStoreTestFailure>]
  ]
  private var writeResults: [
    FavoriteWriteKey: [Result<ThreadCloudFavoriteData, ThreadCloudFavoriteStoreTestFailure>]
  ]
  private let suspendedReadRevisions: Set<UUID>
  private let suspendedWriteRevisions: Set<UUID>
  private var releasedReadRevisions = Set<UUID>()
  private var releasedWriteRevisions = Set<UUID>()
  private var readWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var writeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var readRequests = [ReadRequest]()
  private var writeRequests = [WriteRequest]()

  init(
    readResults: [
      FavoriteReadKey: [Result<ThreadCloudFavoriteData, ThreadCloudFavoriteStoreTestFailure>]
    ] = [:],
    writeResults: [
      FavoriteWriteKey: [Result<ThreadCloudFavoriteData, ThreadCloudFavoriteStoreTestFailure>]
    ] = [:],
    suspendedReadRevisions: Set<UUID> = [],
    suspendedWriteRevisions: Set<UUID> = []
  ) {
    self.readResults = readResults
    self.writeResults = writeResults
    self.suspendedReadRevisions = suspendedReadRevisions
    self.suspendedWriteRevisions = suspendedWriteRevisions
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected forum-membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected forum-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected forum mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected check-in")
  }

  func threadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteData {
    let revision = session.sessionRevision
    readRequests.append(
      ReadRequest(userID: session.id, revision: revision, target: target)
    )
    if suspendedReadRevisions.contains(revision), !releasedReadRevisions.contains(revision) {
      await withCheckedContinuation { readWaiters[revision, default: []].append($0) }
    }
    let key = FavoriteReadKey(session: session, target: target)
    guard var results = readResults[key], !results.isEmpty else {
      throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected cloud-favorite read")
    }
    let result = results.removeFirst()
    readResults[key] = results
    return try result.get()
  }

  func setThreadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteData {
    let revision = session.sessionRevision
    writeRequests.append(
      WriteRequest(
        userID: session.id,
        revision: revision,
        target: target,
        markedPostID: markedPostID
      )
    )
    if suspendedWriteRevisions.contains(revision), !releasedWriteRevisions.contains(revision) {
      await withCheckedContinuation { writeWaiters[revision, default: []].append($0) }
    }
    let key = FavoriteWriteKey(
      session: session,
      target: target,
      markedPostID: markedPostID
    )
    guard var results = writeResults[key], !results.isEmpty else {
      throw ThreadCloudFavoriteStoreTestFailure(message: "unexpected cloud-favorite write")
    }
    let result = results.removeFirst()
    writeResults[key] = results
    return try result.get()
  }

  func releaseReads(for revision: UUID) {
    releasedReadRevisions.insert(revision)
    let waiters = readWaiters.removeValue(forKey: revision) ?? []
    waiters.forEach { $0.resume() }
  }

  func releaseWrites(for revision: UUID) {
    releasedWriteRevisions.insert(revision)
    let waiters = writeWaiters.removeValue(forKey: revision) ?? []
    waiters.forEach { $0.resume() }
  }

  func readCount() -> Int { readRequests.count }
  func readCount(for revision: UUID) -> Int {
    readRequests.filter { $0.revision == revision }.count
  }
  func readTargets(for revision: UUID) -> [ThreadCloudFavoriteTarget] {
    readRequests.filter { $0.revision == revision }.map(\.target)
  }
  func writeCount() -> Int { writeRequests.count }
  func writeCount(for revision: UUID) -> Int {
    writeRequests.filter { $0.revision == revision }.count
  }
  func writeMarkers(for revision: UUID) -> [Int64?] {
    writeRequests.filter { $0.revision == revision }.map(\.markedPostID)
  }
}

@MainActor
private func makeFavoriteStore(
  vault: ThreadCloudFavoriteVaultSpy,
  service: ThreadCloudFavoriteStoreServiceSpy
) -> ThreadCloudFavoriteStore {
  ThreadCloudFavoriteStore(
    access: AccountAccess(vault: vault, service: service),
    observesAccountSessionChanges: false
  )
}

private func favoriteSession(
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

private func favoriteTarget(threadID: Int64) -> ThreadCloudFavoriteTarget {
  ThreadCloudFavoriteTarget(
    forumID: 42,
    forumName: "swift",
    threadID: threadID
  )!
}

private func favoriteSnapshot(_ markedPostID: Int64?) -> ThreadCloudFavoriteSnapshot {
  ThreadCloudFavoriteSnapshot(markedPostID: markedPostID)!
}

private func favoriteData(
  session: StoredAccountSession,
  target: ThreadCloudFavoriteTarget,
  markedPostID: Int64?
) -> ThreadCloudFavoriteData {
  ThreadCloudFavoriteData(
    userID: session.id,
    target: target,
    snapshot: favoriteSnapshot(markedPostID)
  )
}

private func favoritePost(id: Int64, threadID: Int64, floor: Int) -> BrowsePost {
  BrowsePost(
    id: id,
    threadID: threadID,
    floor: floor,
    authorID: 1,
    authorName: "Tester",
    authorPortraitURL: nil,
    createdAt: nil,
    nestedReplyCount: 0,
    isThreadAuthor: true,
    contents: [.text("post")]
  )
}

@MainActor
private func waitForThreadCloudFavoriteStoreTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw ThreadCloudFavoriteStoreTestFailure(message: "timed out waiting for favorite state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
