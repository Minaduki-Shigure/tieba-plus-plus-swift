import XCTest
@testable import TiebaPlusPlus

@MainActor
final class ForumBatchCheckInViewModelTests: XCTestCase {
  func testLoadRequiresExplicitConfirmationAndNeverWritesBeforeConfirm() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [session.sessionRevision: catalog(userID: 1)]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(
      viewModel.state,
      .ready(
        summary: ForumBatchCheckInSummary(
          total: 5,
          eligible: 1,
          pending: 2,
          processed: 0,
          succeeded: 0,
          failed: 0,
          skipped: 2,
          stopped: 0
        )
      )
    )
    XCTAssertNil(viewModel.pendingConfirmation)
    var batchRequestCount = await service.batchRequestCount()
    var singleRequestCount = await service.singleRequestCount()
    XCTAssertEqual(batchRequestCount, 0)
    XCTAssertEqual(singleRequestCount, 0)

    viewModel.requestStartConfirmation()

    XCTAssertEqual(
      viewModel.pendingConfirmation,
      ForumBatchCheckInConfirmation(
        targetCount: 2,
        officialBatchEligibleCount: 1,
        minimumOfficialLevel: 4,
        maximumOfficialCount: 1
      )
    )
    batchRequestCount = await service.batchRequestCount()
    singleRequestCount = await service.singleRequestCount()
    XCTAssertEqual(batchRequestCount, 0)
    XCTAssertEqual(singleRequestCount, 0)
    viewModel.cancelStartConfirmation()
    XCTAssertNil(viewModel.pendingConfirmation)
  }

  func testUnknownAndForbiddenTargetsAreSkippedAndNeverWritten() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [session.sessionRevision: catalog(userID: 1)],
      batchResults: [
        session.sessionRevision: .success(
          ForumBatchCheckInData(
            userID: 1,
            results: [batchResult(id: 10, name: "A")]
          )
        )
      ],
      singleResults: [
        20: .success(confirmedSingle(userID: 1, id: 20, name: "B"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let batchRequestCount = await service.batchRequestCount()
    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(batchRequestCount, 1)
    XCTAssertEqual(singleForumIDs, [20])
    XCTAssertEqual(
      viewModel.entries.map(\.outcome),
      [
        .succeeded,
        .succeeded,
        .skipped(message: "贴吧未提供可确认的签到状态，已跳过。"),
        .skipped(message: "贴吧标记该目标禁止签到，已跳过。"),
      ]
    )
    XCTAssertEqual(
      viewModel.state,
      .completed(
        summary: ForumBatchCheckInSummary(
          total: 5,
          eligible: 1,
          pending: 0,
          processed: 2,
          succeeded: 2,
          failed: 0,
          skipped: 2,
          stopped: 0
        )
      )
    )
  }

  func testCheckedInForbiddenTargetIsAlreadyDoneRatherThanSkipped() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: ForumCheckInCatalogData(
          userID: 1,
          targets: [
            target(10, "already", level: 5, status: .checkedIn, forbidden: true)
          ],
          officialBatchPolicy: ForumOfficialBatchCheckInPolicy(
            minimumLevel: 1,
            maximumForumCount: 1
          )
        )
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertTrue(viewModel.entries.isEmpty)
    XCTAssertEqual(
      viewModel.state,
      .ready(
        summary: ForumBatchCheckInSummary(
          total: 1,
          eligible: 0,
          pending: 0,
          processed: 0,
          succeeded: 0,
          failed: 0,
          skipped: 0,
          stopped: 0
        )
      )
    )
    viewModel.requestStartConfirmation()
    XCTAssertNil(viewModel.pendingConfirmation)
  }

  func testMissingRejectedAndMismatchedBatchResultsFallBackToSingleWrites() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let loaded = ForumCheckInCatalogData(
      userID: 1,
      targets: [
        target(10, "A", level: 5, status: .pending),
        target(20, "B", level: 5, status: .pending),
        target(30, "C", level: 5, status: .pending),
      ],
      officialBatchPolicy: ForumOfficialBatchCheckInPolicy(
        minimumLevel: 4,
        maximumForumCount: 3
      )
    )
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [session.sessionRevision: loaded],
      batchResults: [
        session.sessionRevision: .success(
          ForumBatchCheckInData(
            userID: 1,
            results: [
              ForumBatchCheckInResult(
                forumID: 10,
                forumName: "A",
                outcome: .rejected(message: "busy")
              ),
              batchResult(id: 20, name: "wrong name"),
              batchResult(id: 999, name: "extra"),
            ]
          )
        )
      ],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "A")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "B")),
        30: .success(confirmedSingle(userID: 1, id: 30, name: "C")),
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let batchRequestCount = await service.batchRequestCount()
    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(batchRequestCount, 1)
    XCTAssertEqual(singleForumIDs, [10, 20, 30])
    XCTAssertTrue(viewModel.entries.allSatisfy { $0.outcome == .succeeded })
  }

  func testCatalogCanonicalizesForumNamesBeforeAttributingBatchResults() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: ForumCheckInCatalogData(
          userID: 1,
          targets: [target(10, "Cafe\u{301}", level: 5, status: .pending)],
          officialBatchPolicy: ForumOfficialBatchCheckInPolicy(
            minimumLevel: 4,
            maximumForumCount: 1
          )
        )
      ],
      batchResults: [
        session.sessionRevision: .success(
          ForumBatchCheckInData(
            userID: 1,
            results: [batchResult(id: 10, name: "Caf\u{E9}")]
          )
        )
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let singleRequestCount = await service.singleRequestCount()
    XCTAssertEqual(singleRequestCount, 0)
    XCTAssertEqual(viewModel.entries.map(\.forumName), ["Caf\u{E9}"])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.succeeded])
  }

  func testStopBeforeNextDispatchMarksOnlyUnstartedTargetsStopped() async throws {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let loaded = catalogWithoutOfficialBatch(userID: 1, ids: [10, 20, 30])
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [session.sessionRevision: loaded],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "F20")),
        30: .success(confirmedSingle(userID: 1, id: 30, name: "F30")),
      ],
      suspendedSingleForumIDs: [10]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()
    let run = Task { await viewModel.confirmStart() }
    try await waitForBatchCheckInTest { await service.singleForumIDs() == [10] }

    viewModel.requestStop()

    XCTAssertEqual(
      viewModel.state,
      .stopping(
        progress: ForumBatchCheckInProgress(
          total: 3,
          pending: 3,
          processed: 0,
          succeeded: 0,
          failed: 0,
          skipped: 0,
          stopped: 0,
          currentForumName: "F10"
        )
      )
    )
    await service.releaseSingles()
    await run.value

    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.succeeded, .stopped, .stopped])
    XCTAssertEqual(
      viewModel.state,
      .completed(
        summary: ForumBatchCheckInSummary(
          total: 3,
          eligible: 0,
          pending: 0,
          processed: 1,
          succeeded: 1,
          failed: 0,
          skipped: 0,
          stopped: 2
        )
      )
    )
  }

  func testCallerCancellationAfterDispatchDoesNotMisreportCurrentWrite() async throws {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "F20")),
      ],
      suspendedSingleForumIDs: [10]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()
    let run = Task { await viewModel.confirmStart() }
    try await waitForBatchCheckInTest { await service.singleForumIDs() == [10] }

    run.cancel()
    await service.releaseSingles()
    await run.value

    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.succeeded, .stopped])
  }

  func testCancellationDuringInterRequestDelayStopsNextDispatch() async throws {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "F20")),
      ]
    )
    let delayGate = ForumBatchCheckInDelayGate()
    let viewModel = ForumBatchCheckInViewModel(
      access: AccountAccess(vault: vault, service: service),
      interRequestDelay: { await delayGate.wait() }
    )
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()
    let run = Task { await viewModel.confirmStart() }
    try await waitForBatchCheckInTest { await delayGate.waiterCount() == 1 }

    run.cancel()
    await delayGate.release()
    await run.value

    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.succeeded, .stopped])
  }

  func testAccountRevisionChangeDuringDelayPreventsNextWrite() async throws {
    let oldSession = makeBatchSession(userID: 1, revision: UUID())
    let newSession = makeBatchSession(userID: 1, revision: UUID())
    let vault = ForumBatchCheckInVaultSpy(session: oldSession)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        oldSession.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "F20")),
      ]
    )
    let delayGate = ForumBatchCheckInDelayGate()
    let viewModel = ForumBatchCheckInViewModel(
      access: AccountAccess(vault: vault, service: service),
      interRequestDelay: { await delayGate.wait() }
    )
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()
    let run = Task { await viewModel.confirmStart() }
    try await waitForBatchCheckInTest { await delayGate.waiterCount() == 1 }

    await vault.replaceActive(with: newSession)
    await delayGate.release()
    await run.value

    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.entries.isEmpty)
  }

  func testFirstSingleFailureStopsRemainingWithoutAutomaticRetry() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [10: .failure(.init(message: "server rejected"))],
      readbackResults: [
        10: .success(unsignedSingle(userID: 1, id: 10, name: "F10"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(
      viewModel.entries.map(\.outcome),
      [.failed(message: "server rejected"), .stopped]
    )
    XCTAssertEqual(viewModel.errorMessage, "一键签到在首个单吧失败后停止，未自动重试。")
  }

  func testTransportLossReconcilesConfirmedSignedWithoutRetryingWrite() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10])
      ],
      singleResults: [10: .failure(.init(message: "connection lost"))],
      readbackResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let singleForumIDs = await service.singleForumIDs()
    let readbackForumIDs = await service.readbackForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(readbackForumIDs, [10])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.succeeded])
    XCTAssertNil(viewModel.errorMessage)
  }

  func testTransportLossWithUnsignedReadbackPreservesWriteErrorAndStops() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [10: .failure(.init(message: "server rejected"))],
      readbackResults: [
        10: .success(unsignedSingle(userID: 1, id: 10, name: "F10"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let singleForumIDs = await service.singleForumIDs()
    let readbackForumIDs = await service.readbackForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(readbackForumIDs, [10])
    XCTAssertEqual(
      viewModel.entries.map(\.outcome),
      [.failed(message: "server rejected"), .stopped]
    )
  }

  func testTransportLossAndReadbackFailureExposeOutcomeUnknownAndStop() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10, 20])
      ],
      singleResults: [10: .failure(.init(message: "connection lost"))],
      readbackResults: [10: .failure(.init(message: "readback lost"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let singleForumIDs = await service.singleForumIDs()
    let readbackForumIDs = await service.readbackForumIDs()
    XCTAssertEqual(singleForumIDs, [10])
    XCTAssertEqual(readbackForumIDs, [10])
    XCTAssertEqual(
      viewModel.entries.map(\.outcome),
      [
        .failed(
          message: "签到请求已派发，但贴吧未能确认结果。请先重新进入该吧核对，勿立即重试。"
        ),
        .stopped,
      ]
    )
  }

  func testBatchTransportFailureFallsBackWithoutRetryingBatch() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [session.sessionRevision: catalog(userID: 1)],
      batchResults: [session.sessionRevision: .failure(.init(message: "batch lost"))],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "A")),
        20: .success(confirmedSingle(userID: 1, id: 20, name: "B")),
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()

    await viewModel.confirmStart()

    let batchRequestCount = await service.batchRequestCount()
    let singleForumIDs = await service.singleForumIDs()
    XCTAssertEqual(batchRequestCount, 1)
    XCTAssertEqual(singleForumIDs, [10, 20])
  }

  func testAccountRevisionChangeDropsLateWriteResultAndReloadsNewCatalog() async throws {
    let oldSession = makeBatchSession(userID: 1, revision: UUID())
    let newSession = makeBatchSession(userID: 1, revision: UUID())
    let vault = ForumBatchCheckInVaultSpy(session: oldSession)
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        oldSession.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [10]),
        newSession.sessionRevision: catalogWithoutOfficialBatch(userID: 1, ids: [20]),
      ],
      singleResults: [
        10: .success(confirmedSingle(userID: 1, id: 10, name: "F10")),
      ],
      suspendedSingleForumIDs: [10]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.requestStartConfirmation()
    let oldRun = Task { await viewModel.confirmStart() }
    try await waitForBatchCheckInTest { await service.singleForumIDs() == [10] }

    await vault.replaceActive(with: newSession)
    await service.releaseSingles()
    await oldRun.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.entries.isEmpty)
    await viewModel.reload()
    XCTAssertEqual(viewModel.entries.map(\.id), [20])
    XCTAssertEqual(viewModel.entries.map(\.outcome), [.pending])
  }

  func testInvalidCatalogIdentityAndDuplicateTargetsFailClosed() async {
    let session = makeBatchSession(userID: 1)
    let vault = ForumBatchCheckInVaultSpy(session: session)
    let duplicate = ForumCheckInCatalogTarget(
      forumID: 10,
      forumName: "duplicate",
      level: 1,
      status: .pending,
      isForbidden: false
    )
    let service = ForumBatchCheckInServiceSpy(
      catalogs: [
        session.sessionRevision: ForumCheckInCatalogData(
          userID: 2,
          targets: [target(10, "A", level: 1, status: .pending), duplicate],
          officialBatchPolicy: nil
        )
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    guard case .failed(summary: nil) = viewModel.state else {
      return XCTFail("expected a closed catalog failure")
    }
    XCTAssertTrue(viewModel.entries.isEmpty)
    let batchRequestCount = await service.batchRequestCount()
    let singleRequestCount = await service.singleRequestCount()
    XCTAssertEqual(batchRequestCount, 0)
    XCTAssertEqual(singleRequestCount, 0)
  }

  func testInvalidCatalogNamesAndOversizedBatchPolicyFailClosed() async {
    let session = makeBatchSession(userID: 1)
    let invalidCatalogs = [
      ForumCheckInCatalogData(
        userID: 1,
        targets: [target(10, "A\u{0}B", level: 1, status: .pending)],
        officialBatchPolicy: nil
      ),
      ForumCheckInCatalogData(
        userID: 1,
        targets: [
          target(10, String(repeating: "a", count: 1_025), level: 1, status: .pending)
        ],
        officialBatchPolicy: nil
      ),
      ForumCheckInCatalogData(
        userID: 1,
        targets: [target(10, "A", level: 1, status: .pending)],
        officialBatchPolicy: ForumOfficialBatchCheckInPolicy(
          minimumLevel: 1,
          maximumForumCount: 101
        )
      ),
    ]

    for invalidCatalog in invalidCatalogs {
      let vault = ForumBatchCheckInVaultSpy(session: session)
      let service = ForumBatchCheckInServiceSpy(
        catalogs: [session.sessionRevision: invalidCatalog]
      )
      let viewModel = makeViewModel(vault: vault, service: service)

      await viewModel.loadIfNeeded()

      guard case .failed(summary: nil) = viewModel.state else {
        XCTFail("expected an invalid catalog failure")
        continue
      }
      XCTAssertTrue(viewModel.entries.isEmpty)
      let batchRequestCount = await service.batchRequestCount()
      let singleRequestCount = await service.singleRequestCount()
      XCTAssertEqual(batchRequestCount, 0)
      XCTAssertEqual(singleRequestCount, 0)
    }
  }
}

@MainActor
private func makeViewModel(
  vault: ForumBatchCheckInVaultSpy,
  service: ForumBatchCheckInServiceSpy
) -> ForumBatchCheckInViewModel {
  ForumBatchCheckInViewModel(
    access: AccountAccess(vault: vault, service: service),
    interRequestDelay: {}
  )
}

private func catalog(userID: Int64) -> ForumCheckInCatalogData {
  ForumCheckInCatalogData(
    userID: userID,
    targets: [
      target(10, "A", level: 5, status: .pending),
      target(20, "B", level: 2, status: .pending),
      target(30, "C", level: 8, status: .unknown),
      target(40, "D", level: 9, status: .pending, forbidden: true),
      target(50, "E", level: 9, status: .checkedIn),
    ],
    officialBatchPolicy: ForumOfficialBatchCheckInPolicy(
      minimumLevel: 4,
      maximumForumCount: 1
    )
  )
}

private func catalogWithoutOfficialBatch(
  userID: Int64,
  ids: [Int64]
) -> ForumCheckInCatalogData {
  ForumCheckInCatalogData(
    userID: userID,
    targets: ids.map { target($0, "F\($0)", level: 1, status: .pending) },
    officialBatchPolicy: nil
  )
}

private func target(
  _ id: Int64,
  _ name: String,
  level: Int,
  status: ForumCheckInCatalogStatus,
  forbidden: Bool = false
) -> ForumCheckInCatalogTarget {
  ForumCheckInCatalogTarget(
    forumID: id,
    forumName: name,
    level: level,
    status: status,
    isForbidden: forbidden
  )
}

private func batchResult(id: Int64, name: String) -> ForumBatchCheckInResult {
  ForumBatchCheckInResult(
    forumID: id,
    forumName: name,
    outcome: .confirmedSigned
  )
}

private func confirmedSingle(
  userID: Int64,
  id: Int64,
  name: String
) -> ForumAccountStateData {
  ForumAccountStateData(
    membership: ForumMembershipData(
      userID: userID,
      forumID: id,
      forumName: name,
      isFollowed: true
    ),
    checkIn: ForumCheckInData(isCheckedIn: true, consecutiveDays: 3, rank: 4)
  )
}

private func unsignedSingle(
  userID: Int64,
  id: Int64,
  name: String
) -> ForumAccountStateData {
  ForumAccountStateData(
    membership: ForumMembershipData(
      userID: userID,
      forumID: id,
      forumName: name,
      isFollowed: true
    ),
    checkIn: ForumCheckInData(isCheckedIn: false, consecutiveDays: 0, rank: 0)
  )
}

private func makeBatchSession(
  userID: Int64,
  revision: UUID = UUID()
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "user\(userID)",
    displayName: "User \(userID)",
    portrait: "portrait",
    bduss: String(repeating: "a", count: AccountCredentialFormat.bdussLength),
    stoken: String(repeating: "b", count: AccountCredentialFormat.stokenLength),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private struct ForumBatchCheckInTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor ForumBatchCheckInServiceSpy: AccountService {
  private let catalogs: [UUID: ForumCheckInCatalogData]
  private let batchResults: [
    UUID: Result<ForumBatchCheckInData, ForumBatchCheckInTestFailure>
  ]
  private let singleResults: [
    Int64: Result<ForumAccountStateData, ForumBatchCheckInTestFailure>
  ]
  private let readbackResults: [
    Int64: Result<ForumAccountStateData, ForumBatchCheckInTestFailure>
  ]
  private let suspendedSingleForumIDs: Set<Int64>
  private var batchRequests: [UUID] = []
  private var singleRequests: [Int64] = []
  private var readbackRequests: [Int64] = []
  private var singlesReleased = false
  private var singleWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    catalogs: [UUID: ForumCheckInCatalogData],
    batchResults: [
      UUID: Result<ForumBatchCheckInData, ForumBatchCheckInTestFailure>
    ] = [:],
    singleResults: [
      Int64: Result<ForumAccountStateData, ForumBatchCheckInTestFailure>
    ] = [:],
    readbackResults: [
      Int64: Result<ForumAccountStateData, ForumBatchCheckInTestFailure>
    ] = [:],
    suspendedSingleForumIDs: Set<Int64> = []
  ) {
    self.catalogs = catalogs
    self.batchResults = batchResults
    self.singleResults = singleResults
    self.readbackResults = readbackResults
    self.suspendedSingleForumIDs = suspendedSingleForumIDs
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ForumBatchCheckInTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ForumBatchCheckInTestFailure(message: "unexpected followed forums")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ForumBatchCheckInTestFailure(message: "unexpected membership")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    readbackRequests.append(forumID)
    guard let result = readbackResults[forumID] else {
      throw ForumBatchCheckInTestFailure(message: "unexpected account state")
    }
    return try result.get()
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ForumBatchCheckInTestFailure(message: "unexpected membership write")
  }

  func checkInCatalog(
    session: StoredAccountSession
  ) async throws -> ForumCheckInCatalogData {
    guard let catalog = catalogs[session.sessionRevision] else {
      throw ForumBatchCheckInTestFailure(message: "unexpected catalog")
    }
    return catalog
  }

  func batchCheckIn(
    session: StoredAccountSession
  ) async throws -> ForumBatchCheckInData {
    batchRequests.append(session.sessionRevision)
    guard let result = batchResults[session.sessionRevision] else {
      throw ForumBatchCheckInTestFailure(message: "unexpected batch write")
    }
    return try result.get()
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    singleRequests.append(forumID)
    if suspendedSingleForumIDs.contains(forumID), !singlesReleased {
      await withCheckedContinuation { singleWaiters.append($0) }
    }
    guard let result = singleResults[forumID] else {
      throw ForumBatchCheckInTestFailure(message: "unexpected single write")
    }
    return try result.get()
  }

  func releaseSingles() {
    singlesReleased = true
    let waiters = singleWaiters
    singleWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func batchRequestCount() -> Int { batchRequests.count }
  func singleRequestCount() -> Int { singleRequests.count }
  func singleForumIDs() -> [Int64] { singleRequests }
  func readbackForumIDs() -> [Int64] { readbackRequests }
}

private actor ForumBatchCheckInVaultSpy: AccountVault {
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
  func replaceActive(with session: StoredAccountSession?) { self.session = session }
}

private actor ForumBatchCheckInDelayGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    released = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  func waiterCount() -> Int { waiters.count }
}

@MainActor
private func waitForBatchCheckInTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw ForumBatchCheckInTestFailure(message: "timed out waiting for batch check-in")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
