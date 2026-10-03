import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class CloudFavoritesViewModelTests: XCTestCase {
  func testCloudFavoriteRoutePreservesAnchorAndAppliesOpenPreferences() {
    let thread = CloudFavoriteThread(
      id: 42,
      title: "A saved thread",
      forumName: "swift",
      author: cloudFavoriteAuthor(userID: 7, displayName: "author"),
      markPostID: 99,
      latestPostID: 100,
      latestFloor: 8,
      hasUpdates: true,
      isDeleted: false,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let combinations: [(Bool, Bool, ThreadPostSort, Bool)] = [
      (false, false, .ascending, false),
      (true, false, .ascending, true),
      (false, true, .descending, false),
      (true, true, .descending, true),
    ]

    for (onlyThreadAuthor, descending, expectedSort, expectedOnlyThreadAuthor) in combinations {
      let navigation = thread.navigation(
        applying: FavoriteThreadOpenOverrides(
          onlyThreadAuthor: onlyThreadAuthor,
          descending: descending
        )
      )

      XCTAssertEqual(navigation.route.threadID, 42)
      XCTAssertEqual(navigation.route.postID, 99)
      XCTAssertEqual(navigation.options.sort, expectedSort)
      XCTAssertEqual(navigation.options.onlyThreadAuthor, expectedOnlyThreadAuthor)
      XCTAssertEqual(navigation.update?.route.threadID, 42)
      XCTAssertEqual(navigation.update?.route.postID, 100)
      XCTAssertEqual(navigation.update?.floor, 8)
    }
  }

  func testCloudFavoriteUpdateRequiresConsistentUsableMetadata() {
    let overrides = FavoriteThreadOpenOverrides()
    let validWithoutMarkedPosition = cloudUpdateItem(markPostID: nil)
      .navigation(applying: overrides)
    XCTAssertEqual(validWithoutMarkedPosition.update?.route.postID, 100)
    XCTAssertEqual(validWithoutMarkedPosition.update?.floor, 8)

    let rejected = [
      cloudUpdateItem(id: 0),
      cloudUpdateItem(latestPostID: nil),
      cloudUpdateItem(latestPostID: 0),
      cloudUpdateItem(latestPostID: 99),
      cloudUpdateItem(latestFloor: nil),
      cloudUpdateItem(latestFloor: 0),
      cloudUpdateItem(hasUpdates: false),
      cloudUpdateItem(isDeleted: true),
    ]
    for thread in rejected {
      XCTAssertNil(thread.navigation(applying: overrides).update)
    }
  }

  func testPaginationReplacesDuplicateWithNewServerDataAndStopsAfterEmptyPage() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "旧标题"), cloudItem(id: 12)],
              nextOffset: 2,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 2, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "新标题", latestFloor: 9), cloudItem(id: 13)],
              nextOffset: 4,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 4, pageSize: 2): [
          .page(cloudPage(userID: 7, items: [], nextOffset: 6, hasMore: true))
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault, pageSize: 2)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.threads.map(\.id), [11, 12])

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12, 13] }
    XCTAssertEqual(viewModel.threads.first?.title, "新标题")
    XCTAssertEqual(viewModel.threads.first?.latestFloor, 9)
    XCTAssertEqual(viewModel.threads.first?.hasUpdates, true)

    let last = try XCTUnwrap(viewModel.threads.last)
    viewModel.loadMoreIfNeeded(current: last)
    try await waitForCloudFavoritesTest {
      await service.requestCount() == 3 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: last)
    for _ in 0..<20 { await Task.yield() }

    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 2, 4])
    XCTAssertEqual(requests.map(\.pageSize), [2, 2, 2])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testLoadMoreFailureCanRetryWithoutDroppingExistingItems() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11)],
              nextOffset: 30,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 30): [
          .failure("网络暂时不可用"),
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 12)],
              nextOffset: nil,
              hasMore: false
            )
          ),
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForCloudFavoritesTest { viewModel.loadMoreError == "网络暂时不可用" }
    XCTAssertEqual(viewModel.threads.map(\.id), [11])

    viewModel.retryLoadMore()
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 30, 30])
  }

  func testDuplicateOnlyPageUpdatesItemAndRequiresExplicitContinuation() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "旧标题"), cloudItem(id: 12)],
              nextOffset: 2,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 2, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 11, title: "新标题")],
              nextOffset: 4,
              hasMore: true
            )
          )
        ],
        .init(userID: 7, offset: 4, pageSize: 2): [
          .page(
            cloudPage(
              userID: 7,
              items: [cloudItem(id: 13)],
              nextOffset: 6,
              hasMore: true
            )
          )
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault, pageSize: 2)

    await viewModel.refresh()
    let last = try XCTUnwrap(viewModel.threads.last)
    viewModel.loadMoreIfNeeded(current: last)
    try await waitForCloudFavoritesTest {
      await service.requestCount() == 2 && !viewModel.isLoadingMore
    }

    XCTAssertEqual(viewModel.threads.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.threads.first?.title, "新标题")
    XCTAssertEqual(viewModel.loadMoreError, "云端收藏列表已发生变化，请继续加载。")

    viewModel.retryLoadMore()
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [11, 12, 13] }
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 2, 4])
  }

  func testAccountChangeClearsImmediatelyAndOldResponseCannotOverwriteNewAccount() async throws {
    let oldSession = cloudSession(userID: 7, revision: cloudUUID(7))
    let newSession = cloudSession(userID: 8, revision: cloudUUID(8))
    let vault = CloudFavoritesVaultSpy(session: oldSession)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 71)], nextOffset: nil, hasMore: false),
            delayNanoseconds: 120_000_000
          )
        ],
        .init(userID: 8, offset: 0): [
          .page(
            cloudPage(userID: 8, items: [cloudItem(id: 81)], nextOffset: nil, hasMore: false)
          )
        ],
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    let oldRefresh = Task { await viewModel.refresh() }
    try await waitForCloudFavoritesTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForCloudFavoritesTest { viewModel.threads.map(\.id) == [81] }
    await oldRefresh.value

    XCTAssertEqual(viewModel.threads.map(\.id), [81])
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
  }

  func testSessionRevisionChangingDuringRequestDiscardsResponse() async throws {
    let oldSession = cloudSession(userID: 7, revision: cloudUUID(7))
    let rotatedSession = cloudSession(userID: 7, revision: cloudUUID(8))
    let vault = CloudFavoritesVaultSpy(session: oldSession)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 71)], nextOffset: nil, hasMore: false),
            delayNanoseconds: 80_000_000
          )
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    let refresh = Task { await viewModel.refresh() }
    try await waitForCloudFavoritesTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: rotatedSession)
    await refresh.value

    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
  }

  func testLegacySessionServiceErrorAsksUserToLogInAgain() async {
    let legacy = cloudSession(userID: 7, stoken: nil)
    let vault = CloudFavoritesVaultSpy(session: legacy)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [.requiresRelogin]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.state, .failed("此账户需要重新登录，才能安全读取贴吧收藏。"))
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  func testMismatchedUserAndNonAdvancingOffsetAreRejected() async throws {
    let active = cloudSession(userID: 7)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(
            cloudPage(userID: 8, items: [cloudItem(id: 11)], nextOffset: nil, hasMore: false)
          ),
          .page(
            cloudPage(userID: 7, items: [cloudItem(id: 11)], nextOffset: 0, hasMore: true)
          ),
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)

    await viewModel.refresh()
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了不匹配的账户收藏，请重新加载后再试。")
    )

    await viewModel.refresh()
    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了异常的收藏分页位置，请重新加载后再试。")
    )
  }

  func testConfirmedRecordRemovalUsesExactThreadOnceWithoutResolverAndReloadsFromZero() async throws
  {
    let active = cloudSession(userID: 7, revision: cloudUUID(31))
    for item in [
      cloudItem(id: 11), cloudItem(id: 12, isDeleted: true), cloudItem(id: 13, forumName: ""),
    ] {
      let vault = CloudFavoritesVaultSpy(session: active)
      let service = CloudFavoritesServiceSpy(
        scripts: [
          .init(userID: 7, offset: 0): [
            .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false)),
            .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
          ]
        ],
        removalScripts: [
          .status(cloudRemovalStatus(threadID: item.id, phase: .observedAbsent, acknowledged: true))
        ]
      )
      let browse = CloudFavoritesRemovalBrowseSpy(
        result: .failure(CloudFavoritesTestFailure(message: "Resolver must not run")))
      let viewModel = CloudFavoritesViewModel(service: service, vault: vault, browseService: browse)
      await viewModel.refresh()
      viewModel.requestRemoval(of: item)
      XCTAssertEqual(viewModel.pendingRemoval?.thread, item)
      let before = await service.removalRequestsSnapshot()
      XCTAssertTrue(before.isEmpty)
      viewModel.confirmPendingRemoval()
      viewModel.confirmPendingRemoval()
      try await waitForCloudFavoritesTest {
        let count = await service.requestCount()
        return viewModel.removingThreadID == nil && viewModel.state == .loaded
          && viewModel.threads.isEmpty && count == 2
      }
      let writes = await service.removalRequestsSnapshot()
      XCTAssertEqual(
        writes,
        [
          CloudFavoriteRecordTarget(
            userID: active.id, threadID: item.id, sessionRevision: active.sessionRevision)!
        ])
      let listRequests = await service.requestsSnapshot()
      XCTAssertEqual(listRequests.map(\.offset), [0, 0])
      let resolverCount = await browse.requestCount()
      let forumRequests = await browse.forumRequestSnapshot()
      let oldReads = await service.threadReadCount()
      let oldWrites = await service.threadWriteCount()
      XCTAssertEqual(resolverCount, 0)
      XCTAssertTrue(forumRequests.isEmpty)
      XCTAssertEqual(oldReads, 0)
      XCTAssertEqual(oldWrites, 0)
      XCTAssertNil(viewModel.removalFailure)
    }
  }

  func testUnknownAndAcceptedResultsKeepRowUntilExplicitReadOnlyVerification() async throws {
    for phase in [CloudFavoriteMutationLedgerPhase.outcomeUnknown, .acceptedAwaitingVerification] {
      let active = cloudSession(userID: 7)
      let item = cloudItem(id: 111, isDeleted: true)
      let acknowledged = phase == .acceptedAwaitingVerification
      let pending = cloudRemovalStatus(threadID: item.id, phase: phase, acknowledged: acknowledged)
      let service = CloudFavoritesServiceSpy(
        scripts: [
          .init(userID: 7, offset: 0): [
            .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false)),
            .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
          ]
        ],
        removalScripts: [.status(pending)],
        verificationScripts: [
          .status(
            cloudRemovalStatus(
              threadID: item.id, phase: .observedAbsent, acknowledged: acknowledged))
        ]
      )
      let viewModel = CloudFavoritesViewModel(
        service: service, vault: CloudFavoritesVaultSpy(session: active))
      await viewModel.refresh()
      viewModel.requestRemoval(of: item)
      viewModel.confirmPendingRemoval()
      try await waitForCloudFavoritesTest {
        viewModel.removingThreadID == nil && viewModel.removalStatuses == [pending]
      }
      XCTAssertEqual(viewModel.threads, [item])
      XCTAssertEqual(viewModel.removalNotice, pending.message)
      let priorVerifications = await service.verificationRequestsSnapshot()
      let priorListCount = await service.requestCount()
      XCTAssertTrue(priorVerifications.isEmpty)
      XCTAssertEqual(priorListCount, 1)

      viewModel.verifyRemoval(threadID: item.id)
      viewModel.verifyRemoval(threadID: item.id)
      try await waitForCloudFavoritesTest {
        viewModel.state == .loaded && viewModel.threads.isEmpty && viewModel.removingThreadID == nil
      }
      let writes = await service.removalRequestsSnapshot()
      let reads = await service.verificationRequestsSnapshot()
      XCTAssertEqual(writes.count, 1)
      XCTAssertEqual(reads, writes)
      XCTAssertTrue(viewModel.removalStatuses.isEmpty)
      XCTAssertNil(viewModel.removalFailure)
    }
  }

  func testRefreshDuringUnknownRemovalWaitsAndReloadsFromOffsetZero() async throws {
    let active = cloudSession(userID: 7)
    let item = cloudItem(id: 114)
    let updated = cloudItem(id: 114, title: "服务器新标题")
    let unknown = cloudRemovalStatus(threadID: item.id, phase: .outcomeUnknown)
    let gate = CloudFavoritesTestGate()
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false)),
          .page(cloudPage(userID: 7, items: [updated], nextOffset: nil, hasMore: false)),
        ]
      ],
      removalScripts: [.status(unknown, gate: gate)]
    )
    let viewModel = CloudFavoritesViewModel(
      service: service, vault: CloudFavoritesVaultSpy(session: active))
    await viewModel.refresh()
    viewModel.requestRemoval(of: item)
    viewModel.confirmPendingRemoval()
    try await waitForCloudFavoritesTest { await service.recordOperationCount() == 1 }
    var refreshStarted = false
    let refresh = Task { @MainActor in
      refreshStarted = true
      await viewModel.refresh()
    }
    try await waitForCloudFavoritesTest { refreshStarted }
    let requestCountBeforeSettlement = await service.requestCount()
    XCTAssertEqual(requestCountBeforeSettlement, 1)
    await gate.release()
    await refresh.value

    XCTAssertEqual(viewModel.threads, [updated])
    XCTAssertEqual(viewModel.removalStatuses, [unknown])
    XCTAssertNil(viewModel.removalFailure)
    let listRequests = await service.requestsSnapshot()
    let writes = await service.removalRequestsSnapshot()
    let verifications = await service.verificationRequestsSnapshot()
    XCTAssertEqual(listRequests.map(\.offset), [0, 0])
    XCTAssertEqual(writes.count, 1)
    XCTAssertTrue(verifications.isEmpty)
  }

  func testRestartedPendingCanBeVerifiedEvenWhenFavoriteListIsEmpty() async throws {
    let active = cloudSession(userID: 7, revision: cloudUUID(39))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("cloud-favorite-ledger.json")
    let testKey = Data(repeating: 0x72, count: 32)
    let original = FileCloudFavoriteMutationLedger(fileURL: file, testingKey: testKey)
    _ = try await original.prepare(
      key: CloudFavoriteMutationLedgerKey(userID: 7, threadID: 112)!, operationID: UUID(),
      sessionRevision: cloudUUID(38), now: Date())
    let restored = try await FileCloudFavoriteMutationLedger(fileURL: file, testingKey: testKey)
      .records()
    let statuses = restored.map {
      cloudRemovalStatus(
        threadID: $0.key.threadID, phase: $0.restoredPhase, acknowledged: $0.receiptAcknowledged)
    }
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
          .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
        ]
      ],
      verificationScripts: [.status(cloudRemovalStatus(threadID: 112, phase: .observedAbsent))],
      removalStatuses: statuses
    )
    let viewModel = CloudFavoritesViewModel(
      service: service, vault: CloudFavoritesVaultSpy(session: active))
    await viewModel.refresh()
    XCTAssertTrue(viewModel.threads.isEmpty)
    XCTAssertEqual(viewModel.removalStatuses, statuses)
    viewModel.verifyRemoval(threadID: 112)
    try await waitForCloudFavoritesTest {
      viewModel.removingThreadID == nil && viewModel.removalStatuses.isEmpty
    }
    let writes = await service.removalRequestsSnapshot()
    let reads = await service.verificationRequestsSnapshot()
    XCTAssertTrue(writes.isEmpty)
    XCTAssertEqual(
      reads,
      [
        CloudFavoriteRecordTarget(
          userID: 7, threadID: 112, sessionRevision: active.sessionRevision)!
      ])
  }

  func testCancelConfirmationAndStaleLeaseSendNoRecordMutationOrVerification() async throws {
    let active = cloudSession(userID: 7, revision: cloudUUID(32))
    let rotated = cloudSession(userID: 7, revision: cloudUUID(33))
    let item = cloudItem(id: 12)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false))
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.requestRemoval(of: item)
    viewModel.cancelPendingRemoval()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(viewModel.pendingRemoval)
    let cancelledRequests = await service.removalRequestsSnapshot()
    XCTAssertTrue(cancelledRequests.isEmpty)

    viewModel.requestRemoval(of: item)
    await vault.replaceActive(with: rotated)
    viewModel.confirmPendingRemoval()
    try await waitForCloudFavoritesTest { viewModel.removingThreadID == nil }

    let writes = await service.removalRequestsSnapshot()
    let reads = await service.verificationRequestsSnapshot()
    XCTAssertTrue(writes.isEmpty)
    XCTAssertTrue(reads.isEmpty)
  }

  func testUnreadableRemovalHistoryPreservesListButDisablesRemoval() async throws {
    let active = cloudSession(userID: 7, revision: cloudUUID(34))
    let item = cloudItem(id: 13)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false))
        ]
      ],
      historyFailure: "ledger unreadable"
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    await viewModel.refresh()
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertTrue(viewModel.removalHistoryError?.contains("ledger unreadable") == true)
    viewModel.requestRemoval(of: item)
    XCTAssertNil(viewModel.pendingRemoval)
    viewModel.confirmPendingRemoval()
    XCTAssertEqual(viewModel.threads, [item])
    XCTAssertEqual(viewModel.removalFailure?.message, viewModel.removalHistoryError)
    let writes = await service.removalRequestsSnapshot()
    let reads = await service.verificationRequestsSnapshot()
    XCTAssertTrue(writes.isEmpty)
    XCTAssertTrue(reads.isEmpty)
  }

  func testOldLeaseRemovalOrVerificationResponseCannotUpdateNewAccount() async throws {
    for verificationOnly in [false, true] {
      let active = cloudSession(userID: 7, revision: cloudUUID(37))
      let replacement = cloudSession(userID: 8, revision: cloudUUID(38))
      let oldItem = cloudItem(id: 71)
      let newItem = cloudItem(id: 81)
      let vault = CloudFavoritesVaultSpy(session: active)
      let gate = CloudFavoritesTestGate()
      let delayed = CloudFavoriteRemovalScript.status(
        cloudRemovalStatus(threadID: oldItem.id, phase: .observedAbsent), gate: gate)
      let service = CloudFavoritesServiceSpy(
        scripts: [
          .init(userID: 7, offset: 0): [
            .page(cloudPage(userID: 7, items: [oldItem], nextOffset: nil, hasMore: false))
          ],
          .init(userID: 8, offset: 0): [
            .page(cloudPage(userID: 8, items: [newItem], nextOffset: nil, hasMore: false))
          ],
        ],
        removalScripts: verificationOnly ? [] : [delayed],
        verificationScripts: verificationOnly ? [delayed] : [],
        removalStatuses: verificationOnly
          ? [cloudRemovalStatus(threadID: oldItem.id, phase: .outcomeUnknown)] : []
      )
      let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
      await viewModel.refresh()
      if verificationOnly {
        viewModel.verifyRemoval(threadID: oldItem.id)
      } else {
        viewModel.requestRemoval(of: oldItem)
        viewModel.confirmPendingRemoval()
      }
      try await waitForCloudFavoritesTest { await service.recordOperationCount() == 1 }
      await vault.replaceActive(with: replacement)
      await service.replaceRemovalStatuses([])
      viewModel.accountSessionDidChange()
      try await waitForCloudFavoritesTest { viewModel.threads == [newItem] }
      await gate.release()
      try await waitForCloudFavoritesTest { await service.completedRecordOperationCount() == 1 }
      for _ in 0..<20 { await Task.yield() }
      XCTAssertEqual(viewModel.threads, [newItem])
      XCTAssertNil(viewModel.removalNotice)
      XCTAssertNil(viewModel.removalFailure)
      XCTAssertTrue(viewModel.removalStatuses.isEmpty)
      let requests = await service.requestsSnapshot()
      XCTAssertEqual(requests.map(\.userID), [7, 8])
    }
  }

  func testDefiniteServerRejectionRetainsRowAndShowsError() async throws {
    let active = cloudSession(userID: 7)
    let item = cloudItem(id: 113, isDeleted: true)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false))
        ]
      ],
      removalScripts: [.failure("server rejected")])
    let viewModel = CloudFavoritesViewModel(
      service: service, vault: CloudFavoritesVaultSpy(session: active))
    await viewModel.refresh()
    viewModel.requestRemoval(of: item)
    viewModel.confirmPendingRemoval()
    try await waitForCloudFavoritesTest { viewModel.removalFailure != nil }
    XCTAssertEqual(viewModel.threads, [item])
    XCTAssertEqual(viewModel.removalFailure?.message, "server rejected")
    XCTAssertTrue(viewModel.removalStatuses.isEmpty)
    let requests = await service.removalRequestsSnapshot()
    XCTAssertEqual(requests.count, 1)
  }

  func testCloudFavoriteChangeRequiresExactLeaseAndRestartsAtOffsetZero() async throws {
    let active = cloudSession(userID: 7, revision: cloudUUID(35))
    let item = cloudItem(id: 14)
    let vault = CloudFavoritesVaultSpy(session: active)
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .page(cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false)),
          .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    await viewModel.refresh()
    let target = ThreadCloudFavoriteTarget(forumID: 42, forumName: "swift", threadID: item.id)!

    viewModel.threadCloudFavoriteDidChange(
      ThreadCloudFavoriteChange(
        accountID: active.id,
        sessionRevision: cloudUUID(99),
        target: target,
        snapshot: ThreadCloudFavoriteSnapshot(markedPostID: nil)!
      )
    )
    for _ in 0..<20 { await Task.yield() }
    let requestCountAfterStaleChange = await service.requestCount()
    XCTAssertEqual(requestCountAfterStaleChange, 1)

    viewModel.threadCloudFavoriteDidChange(
      ThreadCloudFavoriteChange(
        accountID: active.id,
        sessionRevision: active.sessionRevision,
        target: target,
        snapshot: ThreadCloudFavoriteSnapshot(markedPostID: nil)!
      )
    )
    try await waitForCloudFavoritesTest {
      let requestCount = await service.requestCount()
      return viewModel.state == .loaded && viewModel.threads.isEmpty && requestCount == 2
    }
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 0])
  }

  func testChangeDuringInitialLoadInvalidatesStaleResponseAndReadsFromZeroAgain() async throws {
    let active = cloudSession(userID: 7, revision: cloudUUID(36))
    let item = cloudItem(id: 15)
    let vault = CloudFavoritesVaultSpy(session: active)
    let firstPageGate = CloudFavoritesTestGate()
    let service = CloudFavoritesServiceSpy(
      scripts: [
        .init(userID: 7, offset: 0): [
          .gatedPage(
            cloudPage(userID: 7, items: [item], nextOffset: nil, hasMore: false),
            gate: firstPageGate
          ),
          .page(cloudPage(userID: 7, items: [], nextOffset: nil, hasMore: false)),
        ]
      ]
    )
    let viewModel = CloudFavoritesViewModel(service: service, vault: vault)
    let target = ThreadCloudFavoriteTarget(forumID: 42, forumName: "swift", threadID: item.id)!

    viewModel.loadIfNeeded()
    try await waitForCloudFavoritesTest { await service.requestCount() == 1 }
    XCTAssertEqual(viewModel.state, .loading)
    viewModel.threadCloudFavoriteDidChange(
      ThreadCloudFavoriteChange(
        accountID: active.id,
        sessionRevision: active.sessionRevision,
        target: target,
        snapshot: ThreadCloudFavoriteSnapshot(markedPostID: nil)!
      )
    )
    await firstPageGate.release()

    try await waitForCloudFavoritesTest {
      let requestCount = await service.requestCount()
      return requestCount == 2 && viewModel.state == .loaded && viewModel.threads.isEmpty
    }
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.offset), [0, 0])
  }
}

private struct CloudFavoritesRequest: Hashable, Sendable {
  let userID: Int64
  let offset: Int
  let pageSize: Int

  init(userID: Int64, offset: Int, pageSize: Int = 30) {
    self.userID = userID
    self.offset = offset
    self.pageSize = pageSize
  }
}

private enum CloudFavoritesScript: Sendable {
  case page(CloudFavoritePage, delayNanoseconds: UInt64 = 0)
  case gatedPage(CloudFavoritePage, gate: CloudFavoritesTestGate)
  case failure(String)
  case requiresRelogin
}

private enum CloudFavoriteRemovalScript: Sendable {
  case status(CloudFavoriteRecordRemovalStatus, gate: CloudFavoritesTestGate? = nil)
  case failure(String)
}

private actor CloudFavoritesTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isReleased = false

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    guard !isReleased else { return }
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}

private struct CloudFavoritesTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor CloudFavoritesServiceSpy: AccountService {
  private var scripts: [CloudFavoritesRequest: [CloudFavoritesScript]]
  private var requests: [CloudFavoritesRequest] = []
  private var removalScripts: [CloudFavoriteRemovalScript]
  private var verificationScripts: [CloudFavoriteRemovalScript]
  private var removalStatuses: [CloudFavoriteRecordRemovalStatus]
  private let historyFailure: String?
  private var removalRequests: [CloudFavoriteRecordTarget] = []
  private var verificationRequests: [CloudFavoriteRecordTarget] = []
  private var completedRecordOperations = 0
  private var threadReads: [Int64: [Result<ThreadCloudFavoriteData, CloudFavoritesTestFailure>]]
  private var threadWrites: [Int64: [Result<ThreadCloudFavoriteData, CloudFavoritesTestFailure>]]
  private var threadReadRequests: [ThreadCloudFavoriteTarget] = []
  private var threadWriteRequests: [(ThreadCloudFavoriteTarget, Int64?)] = []

  init(
    scripts: [CloudFavoritesRequest: [CloudFavoritesScript]],
    threadReads: [Int64: [Result<ThreadCloudFavoriteData, CloudFavoritesTestFailure>]] = [:],
    threadWrites: [Int64: [Result<ThreadCloudFavoriteData, CloudFavoritesTestFailure>]] = [:],
    removalScripts: [CloudFavoriteRemovalScript] = [],
    verificationScripts: [CloudFavoriteRemovalScript] = [],
    removalStatuses: [CloudFavoriteRecordRemovalStatus] = [],
    historyFailure: String? = nil
  ) {
    self.scripts = scripts
    self.threadReads = threadReads
    self.threadWrites = threadWrites
    self.removalScripts = removalScripts
    self.verificationScripts = verificationScripts
    self.removalStatuses = removalStatuses
    self.historyFailure = historyFailure
  }

  func cloudFavoriteRecordRemovalStatuses(
    session: StoredAccountSession
  ) async throws -> [CloudFavoriteRecordRemovalStatus] {
    if let historyFailure { throw CloudFavoritesTestFailure(message: historyFailure) }
    return removalStatuses
  }

  func removeCloudFavoriteRecord(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    removalRequests.append(target)
    guard target.matches(session), !removalScripts.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Unexpected record mutation")
    }
    let script = removalScripts.removeFirst()
    return try await execute(script)
  }

  func verifyCloudFavoriteRecordRemoval(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    verificationRequests.append(target)
    guard target.matches(session), !verificationScripts.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Unexpected record verification")
    }
    let script = verificationScripts.removeFirst()
    return try await execute(script)
  }

  private func execute(_ script: CloudFavoriteRemovalScript) async throws
    -> CloudFavoriteRecordRemovalStatus
  {
    defer { completedRecordOperations += 1 }
    switch script {
    case .status(let status, let gate):
      if let gate { await gate.wait() }
      removalStatuses.removeAll { $0.threadID == status.threadID }
      if status.requiresVerification { removalStatuses.append(status) }
      return status
    case .failure(let message):
      throw CloudFavoritesTestFailure(message: message)
    }
  }

  func replaceRemovalStatuses(_ statuses: [CloudFavoriteRecordRemovalStatus]) {
    removalStatuses = statuses
  }

  func cloudFavorites(
    session: StoredAccountSession,
    offset: Int,
    pageSize: Int
  ) async throws -> CloudFavoritePage {
    let request = CloudFavoritesRequest(userID: session.id, offset: offset, pageSize: pageSize)
    requests.append(request)
    guard var pending = scripts[request], !pending.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Missing cloud favorites script")
    }
    let script = pending.removeFirst()
    scripts[request] = pending
    switch script {
    case .page(let page, let delayNanoseconds):
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      return page
    case .gatedPage(let page, let gate):
      await gate.wait()
      return page
    case .failure(let message):
      throw CloudFavoritesTestFailure(message: message)
    case .requiresRelogin:
      guard session.stoken == nil else {
        throw CloudFavoritesTestFailure(message: "Expected a legacy session")
      }
      throw CloudFavoritesTestFailure(
        message: "此账户需要重新登录，才能安全读取贴吧收藏。"
      )
    }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw CloudFavoritesTestFailure(message: "Unexpected validation")
  }

  func threadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteData {
    threadReadRequests.append(target)
    guard var results = threadReads[target.threadID], !results.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Unexpected cloud-favorite read")
    }
    let result = results.removeFirst()
    threadReads[target.threadID] = results
    return try result.get()
  }

  func setThreadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteData {
    threadWriteRequests.append((target, markedPostID))
    guard var results = threadWrites[target.threadID], !results.isEmpty else {
      throw CloudFavoritesTestFailure(message: "Unexpected cloud-favorite write")
    }
    let result = results.removeFirst()
    threadWrites[target.threadID] = results
    return try result.get()
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw CloudFavoritesTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw CloudFavoritesTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw CloudFavoritesTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw CloudFavoritesTestFailure(message: "Unexpected check-in")
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [CloudFavoritesRequest] { requests }
  func threadReadCount() -> Int { threadReadRequests.count }
  func threadWriteCount() -> Int { threadWriteRequests.count }
  func removalRequestsSnapshot() -> [CloudFavoriteRecordTarget] { removalRequests }
  func verificationRequestsSnapshot() -> [CloudFavoriteRecordTarget] { verificationRequests }
  func recordOperationCount() -> Int { removalRequests.count + verificationRequests.count }
  func completedRecordOperationCount() -> Int { completedRecordOperations }
}

private struct CloudFavoritesRemovalTargetRequest: Equatable, Sendable {
  let threadID: Int64
  let expectedForumName: String
}

private actor CloudFavoritesRemovalBrowseSpy: BrowseService {
  private let result: Result<BrowseThreadIdentity, CloudFavoritesTestFailure>
  private let forumResult: Result<BrowseForumIdentity, CloudFavoritesTestFailure>
  private let forumGate: CloudFavoritesForumIdentityGate?
  private var requests: [CloudFavoritesRemovalTargetRequest] = []
  private var forumRequests: [String] = []

  init(
    result: Result<BrowseThreadIdentity, CloudFavoritesTestFailure>,
    forumResult: Result<BrowseForumIdentity, CloudFavoritesTestFailure> = .failure(
      CloudFavoritesTestFailure(message: "Unexpected forum identity request")
    ),
    forumGate: CloudFavoritesForumIdentityGate? = nil
  ) {
    self.result = result
    self.forumResult = forumResult
    self.forumGate = forumGate
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected thread-list request")
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected post request")
  }

  func resolveThreadIdentity(
    threadID: Int64,
    expectedForumName: String
  ) async throws -> BrowseThreadIdentity {
    requests.append(.init(threadID: threadID, expectedForumName: expectedForumName))
    return try result.get()
  }

  func resolveForumIdentity(forumName: String) async throws -> BrowseForumIdentity {
    forumRequests.append(forumName)
    if let forumGate { await forumGate.suspend() }
    return try forumResult.get()
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected comment request")
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected comment request")
  }

  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData {
    throw CloudFavoritesTestFailure(message: "Unexpected comment request")
  }

  func requestCount() -> Int { requests.count }
  func requestSnapshot() -> [CloudFavoritesRemovalTargetRequest] { requests }
  func forumRequestSnapshot() -> [String] { forumRequests }
}

private actor CloudFavoritesForumIdentityGate {
  private var didSuspend = false
  private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    didSuspend = true
    let waiters = suspensionWaiters
    suspensionWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilSuspended() async {
    guard !didSuspend else { return }
    await withCheckedContinuation { continuation in
      suspensionWaiters.append(continuation)
    }
  }

  func resume() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor CloudFavoritesVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? { session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

private func cloudSession(
  userID: Int64,
  revision: UUID = UUID(),
  stoken: String? = String(repeating: "s", count: 64)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "user-\(userID)",
    displayName: "User \(userID)",
    portrait: "portrait-\(userID)",
    bduss: String(repeating: "b", count: 192),
    stoken: stoken,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func cloudPage(
  userID: Int64,
  items: [CloudFavoriteThread],
  nextOffset: Int?,
  hasMore: Bool
) -> CloudFavoritePage {
  CloudFavoritePage(
    userID: userID,
    items: items,
    nextOffset: nextOffset,
    hasMore: hasMore
  )
}

private func cloudItem(
  id: Int64,
  title: String? = nil,
  latestFloor: Int? = 3,
  isDeleted: Bool = false,
  forumName: String = "swift"
) -> CloudFavoriteThread {
  CloudFavoriteThread(
    id: id,
    title: title ?? "Thread \(id)",
    forumName: forumName,
    author: cloudFavoriteAuthor(
      userID: id + 100,
      username: "author-account-\(id)",
      displayName: "author-\(id)"
    ),
    markPostID: 1_000 + id,
    latestPostID: 2_000 + id,
    latestFloor: latestFloor,
    hasUpdates: latestFloor != nil,
    isDeleted: isDeleted,
    updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
  )
}

private func cloudUpdateItem(
  id: Int64 = 42,
  markPostID: Int64? = 99,
  latestPostID: Int64? = 100,
  latestFloor: Int? = 8,
  hasUpdates: Bool = true,
  isDeleted: Bool = false
) -> CloudFavoriteThread {
  CloudFavoriteThread(
    id: id,
    title: "Thread \(id)",
    forumName: "swift",
    author: cloudFavoriteAuthor(userID: 7, displayName: "author"),
    markPostID: markPostID,
    latestPostID: latestPostID,
    latestFloor: latestFloor,
    hasUpdates: hasUpdates,
    isDeleted: isDeleted,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}

private func cloudFavoriteAuthor(
  userID: Int64?,
  username: String = "author-account",
  displayName: String = "author",
  portraitURL: URL? = nil
) -> CloudFavoriteAuthor {
  CloudFavoriteAuthor(
    userID: userID,
    username: username,
    displayName: displayName,
    portraitURL: portraitURL
  )
}

private func cloudFavoriteData(
  session: StoredAccountSession,
  target: ThreadCloudFavoriteTarget,
  markedPostID: Int64?
) -> ThreadCloudFavoriteData {
  ThreadCloudFavoriteData(
    userID: session.id,
    target: target,
    snapshot: ThreadCloudFavoriteSnapshot(markedPostID: markedPostID)!
  )
}

private func cloudUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func cloudRemovalStatus(
  threadID: Int64, phase: CloudFavoriteMutationLedgerPhase, acknowledged: Bool = false
) -> CloudFavoriteRecordRemovalStatus {
  CloudFavoriteRecordRemovalStatus(
    threadID: threadID, phase: phase, receiptAcknowledged: acknowledged,
    observation: phase == .observedAbsent ? .observedAbsent : nil)
}

@MainActor
private func waitForCloudFavoritesTest(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
  while !(await condition()) {
    if ContinuousClock.now >= deadline {
      XCTFail("Timed out waiting for cloud favorites test condition")
      return
    }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
