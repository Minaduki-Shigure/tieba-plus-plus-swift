import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class FollowedForumCheckInStoreTests: XCTestCase {
  func testLoadsOneCatalogAndProjectsOnlyExactCheckedInIdentities() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(1))
    let vault = FollowedCheckInVaultSpy(session: session)
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(
          checkInCatalog(
            userID: 7,
            targets: [
              checkInTarget(id: 1, name: " Cafe\u{301} ", status: .checkedIn),
              checkInTarget(id: 2, name: "pending", status: .pending),
              checkInTarget(id: 3, name: "unknown", status: .unknown),
            ]
          )
        )
      ]
    )
    let store = makeFollowedCheckInStore(vault: vault, loader: loader)

    store.loadIfNeeded()
    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }

    let lease = FollowedForumsSessionLease(session)
    XCTAssertTrue(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "caf\u{E9}"),
        forumLease: lease
      )
    )
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "renamed"),
        forumLease: lease
      )
    )
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 2, name: "pending"),
        forumLease: lease
      )
    )
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 3, name: "unknown"),
        forumLease: lease
      )
    )
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "caf\u{E9}"),
        forumLease: AccountSessionLease(
          checkInSession(userID: 8, revision: checkInUUID(8))
        )
      )
    )
    store.loadIfNeeded()
    let requests = await loader.requestedRevisions()
    XCTAssertEqual(requests, [session.sessionRevision])
  }

  func testSignedOutAndIncompleteSessionsNeverRequestCatalog() async throws {
    let signedOutVault = FollowedCheckInVaultSpy(session: nil)
    let signedOutLoader = FollowedCheckInCatalogLoaderSpy(responses: [])
    let signedOutStore = makeFollowedCheckInStore(
      vault: signedOutVault,
      loader: signedOutLoader
    )

    signedOutStore.loadIfNeeded()
    try await waitForFollowedCheckInState { signedOutStore.state == .signedOut }
    let signedOutRequests = await signedOutLoader.requestedRevisions()
    XCTAssertTrue(signedOutRequests.isEmpty)

    let incomplete = checkInSession(
      userID: 7,
      revision: checkInUUID(2),
      hasFullCredentials: false
    )
    let incompleteLoader = FollowedCheckInCatalogLoaderSpy(responses: [])
    let incompleteStore = makeFollowedCheckInStore(
      vault: FollowedCheckInVaultSpy(session: incomplete),
      loader: incompleteLoader
    )
    incompleteStore.loadIfNeeded()
    try await waitForFollowedCheckInState { incompleteStore.state == .unavailable }
    let incompleteRequests = await incompleteLoader.requestedRevisions()
    XCTAssertTrue(incompleteRequests.isEmpty)
  }

  func testInvalidCatalogsFailClosedWithoutPublishingBadges() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(3))
    let invalidCatalogs = [
      checkInCatalog(userID: 8, targets: [
        checkInTarget(id: 1, name: "one", status: .checkedIn)
      ]),
      checkInCatalog(userID: 7, targets: [
        checkInTarget(id: 1, name: "one", status: .checkedIn),
        checkInTarget(id: 1, name: "duplicate", status: .checkedIn),
      ]),
      checkInCatalog(userID: 7, targets: [
        checkInTarget(id: 0, name: "invalid", status: .checkedIn)
      ]),
      checkInCatalog(userID: 7, targets: [
        checkInTarget(id: 1, name: "bad\u{0000}name", status: .checkedIn)
      ]),
    ]

    for catalog in invalidCatalogs {
      let loader = FollowedCheckInCatalogLoaderSpy(responses: [.success(catalog)])
      let store = makeFollowedCheckInStore(
        vault: FollowedCheckInVaultSpy(session: session),
        loader: loader
      )
      store.loadIfNeeded()
      try await waitForFollowedCheckInState { store.state == .unavailable }
      XCTAssertNil(store.snapshot)
      XCTAssertFalse(
        store.isCheckedInToday(
          checkInForum(id: 1, name: "one"),
          forumLease: AccountSessionLease(session)
        )
      )
    }
  }

  func testCatalogChangeNotificationValidatesAndNormalizesConfirmedTargets() throws {
    let revision = checkInUUID(30)
    let valid = Notification(
      name: .forumCheckInCatalogDidChange,
      userInfo: [
        "accountID": NSNumber(value: 7),
        "sessionRevision": revision.uuidString,
        "confirmedForumIDs": [NSNumber(value: 1), NSNumber(value: 2)],
        "confirmedForumNames": [" One ", "Cafe\u{301}"],
      ]
    )
    XCTAssertEqual(
      ForumCheckInCatalogChange(valid),
      ForumCheckInCatalogChange(
        accountID: 7,
        sessionRevision: revision,
        confirmedTargets: [
          ForumBatchCheckInTarget(forumID: 1, forumName: "one"),
          ForumBatchCheckInTarget(forumID: 2, forumName: "caf\u{E9}"),
        ]
      )
    )

    for userInfo: [AnyHashable: Any] in [
      [
        "accountID": NSNumber(value: 7),
        "sessionRevision": revision.uuidString,
        "confirmedForumIDs": [NSNumber](),
        "confirmedForumNames": [String](),
      ],
      [
        "accountID": NSNumber(value: 7),
        "sessionRevision": revision.uuidString,
        "confirmedForumIDs": [NSNumber(value: 1), NSNumber(value: 1)],
        "confirmedForumNames": ["one", "one"],
      ],
      [
        "accountID": NSNumber(value: 7),
        "sessionRevision": revision.uuidString,
        "confirmedForumIDs": [NSNumber(value: 1)],
        "confirmedForumNames": ["bad\u{0000}name"],
      ],
    ] {
      XCTAssertNil(
        ForumCheckInCatalogChange(
          Notification(name: .forumCheckInCatalogDidChange, userInfo: userInfo)
        )
      )
    }
  }

  func testAccountRotationClearsImmediatelyAndDiscardsLateCatalog() async throws {
    let oldSession = checkInSession(userID: 7, revision: checkInUUID(4))
    let newSession = checkInSession(userID: 7, revision: checkInUUID(5))
    let vault = FollowedCheckInVaultSpy(session: oldSession)
    let loader = SuspendedFollowedCheckInCatalogLoader(
      suspendedRevision: oldSession.sessionRevision,
      catalogs: [
        oldSession.sessionRevision: checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "old", status: .checkedIn)
        ]),
        newSession.sessionRevision: checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 2, name: "new", status: .checkedIn)
        ]),
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: vault,
      catalogLoader: { try await loader.load(session: $0) },
      now: { followedCheckInStableDate() }
    )

    store.loadIfNeeded()
    await loader.waitUntilSuspendedRequestStarts()
    await vault.setActiveSession(newSession)
    store.accountSessionDidChange(loadImmediately: true)
    try await waitForFollowedCheckInState {
      store.state == .ready
        && store.isCheckedInToday(
          checkInForum(id: 2, name: "new"),
          forumLease: AccountSessionLease(newSession)
        )
    }

    await loader.releaseSuspendedRequest()
    await Task.yield()
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "old"),
        forumLease: AccountSessionLease(oldSession)
      )
    )
    let requests = await loader.requestedRevisions()
    XCTAssertEqual(requests, [oldSession.sessionRevision, newSession.sessionRevision])
  }

  func testConfirmedEventDuringRequestWinsOverStalePendingCatalog() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(6))
    let vault = FollowedCheckInVaultSpy(session: session)
    let loader = SuspendedFollowedCheckInCatalogLoader(
      suspendedRevision: session.sessionRevision,
      catalogs: [
        session.sessionRevision: checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: vault,
      catalogLoader: { try await loader.load(session: $0) },
      now: { followedCheckInStableDate() }
    )
    store.loadIfNeeded()
    await loader.waitUntilSuspendedRequestStarts()

    store.forumCheckInDidChange(
      ForumCheckInChange(
        accountID: 7,
        sessionRevision: session.sessionRevision,
        forumID: 1,
        consecutiveDays: 3,
        rank: 9
      )
    )
    await loader.releaseSuspendedRequest()
    try await waitForFollowedCheckInState { store.state == .ready }

    XCTAssertTrue(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )
  }

  func testCatalogChangeRejectsMismatchesAndSurvivesAStaleRefresh()
    async throws
  {
    let session = checkInSession(userID: 7, revision: checkInUUID(7))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
      ]
    )
    let store = makeFollowedCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      loader: loader
    )
    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }

    for change in [
      ForumCheckInChange(
        accountID: 8,
        sessionRevision: session.sessionRevision,
        forumID: 1,
        consecutiveDays: 1,
        rank: 1
      ),
      ForumCheckInChange(
        accountID: 7,
        sessionRevision: checkInUUID(70),
        forumID: 1,
        consecutiveDays: 1,
        rank: 1
      ),
      ForumCheckInChange(
        accountID: 7,
        sessionRevision: session.sessionRevision,
        forumID: 99,
        consecutiveDays: 1,
        rank: 1
      ),
    ] {
      store.forumCheckInDidChange(change)
    }
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )

    store.forumCheckInCatalogDidChange(
      ForumCheckInCatalogChange(
        accountID: 8,
        sessionRevision: session.sessionRevision,
        confirmedTargets: [ForumBatchCheckInTarget(forumID: 1, forumName: "one")]
      ),
      loadImmediately: true
    )
    let ignoredChangeRequests = await loader.requestedRevisions()
    XCTAssertEqual(ignoredChangeRequests.count, 1)

    store.forumCheckInCatalogDidChange(
      ForumCheckInCatalogChange(
        accountID: 7,
        sessionRevision: session.sessionRevision,
        confirmedTargets: [ForumBatchCheckInTarget(forumID: 1, forumName: "renamed")]
      ),
      loadImmediately: false
    )
    XCTAssertFalse(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )

    store.forumCheckInCatalogDidChange(
      ForumCheckInCatalogChange(
        accountID: 7,
        sessionRevision: session.sessionRevision,
        confirmedTargets: [ForumBatchCheckInTarget(forumID: 1, forumName: "one")]
      ),
      loadImmediately: true
    )
    XCTAssertTrue(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )
    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertTrue(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )
  }

  func testSameDayRefreshCannotDowngradeAnExactCheckedInStatus() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(71))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])),
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
      ]
    )
    let store = makeFollowedCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      loader: loader
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))

    await store.refresh()
    XCTAssertEqual(store.state, .ready)
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))
  }

  func testCrossingTiebaMidnightDropsOldBadgeAndReloadsOnce() async throws {
    let beforeMidnight = Date(timeIntervalSince1970: 1_787_673_570)
    let afterMidnight = Date(timeIntervalSince1970: 1_787_673_630)
    let clock = FollowedCheckInDateBox(beforeMidnight)
    let session = checkInSession(userID: 7, revision: checkInUUID(8))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])),
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { try await loader.load(session: $0) },
      now: { clock.value() },
      calendar: tiebaCheckInTestCalendar()
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))

    clock.set(afterMidnight)
    XCTAssertFalse(store.isCheckedInToday(forum, forumLease: lease))
    store.loadIfNeeded()
    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertFalse(store.isCheckedInToday(forum, forumLease: lease))
  }

  func testForegroundResumeReconcilesAnExistingSameDaySnapshot() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(9))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])),
      ]
    )
    let store = makeFollowedCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      loader: loader,
      minimumForegroundRefreshInterval: 0
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    XCTAssertFalse(store.isCheckedInToday(forum, forumLease: lease))

    store.sceneActivityDidChange(isActive: false, shouldLoad: true)
    store.sceneActivityDidChange(isActive: true, shouldLoad: true)
    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))
  }

  func testForegroundRefreshFailureRetainsTheValidSameDaySnapshot() async throws {
    let initialDate = Date(timeIntervalSince1970: 1_787_640_000)
    let clock = FollowedCheckInDateBox(initialDate)
    let session = checkInSession(userID: 7, revision: checkInUUID(11))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])),
        .failure(FollowedCheckInTestFailure(message: "offline")),
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { try await loader.load(session: $0) },
      now: { clock.value() },
      calendar: tiebaCheckInTestCalendar()
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))

    clock.set(initialDate.addingTimeInterval(301))
    store.sceneActivityDidChange(isActive: false, shouldLoad: true)
    store.sceneActivityDidChange(isActive: true, shouldLoad: true)
    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))

    store.sceneActivityDidChange(isActive: false, shouldLoad: true)
    store.sceneActivityDidChange(isActive: true, shouldLoad: true)
    let requests = await loader.requestedRevisions()
    XCTAssertEqual(requests.count, 2)
  }

  func testRapidForegroundResumeDoesNotReloadTheSameDayCatalog() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(12))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ]))
      ]
    )
    let store = makeFollowedCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      loader: loader
    )

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    store.sceneActivityDidChange(isActive: false, shouldLoad: true)
    store.sceneActivityDidChange(isActive: true, shouldLoad: true)

    let requests = await loader.requestedRevisions()
    XCTAssertEqual(requests, [session.sessionRevision])
  }

  func testSameDayClockRollbackTreatsTheForegroundSnapshotAsStale() async throws {
    let initialDate = Date(timeIntervalSince1970: 1_787_640_300)
    let clock = FollowedCheckInDateBox(initialDate)
    let session = checkInSession(userID: 7, revision: checkInUUID(14))
    let loader = FollowedCheckInCatalogLoaderSpy(
      responses: [
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])),
        .success(checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])),
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { try await loader.load(session: $0) },
      now: { clock.value() },
      calendar: tiebaCheckInTestCalendar()
    )

    store.loadIfNeeded()
    try await waitForFollowedCheckInState { store.state == .ready }
    clock.set(initialDate.addingTimeInterval(-60))
    store.sceneActivityDidChange(isActive: false, shouldLoad: true)
    store.sceneActivityDidChange(isActive: true, shouldLoad: true)

    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertTrue(
      store.isCheckedInToday(
        checkInForum(id: 1, name: "one"),
        forumLease: AccountSessionLease(session)
      )
    )
  }

  func testSignificantTimeChangeCoalescesAnExistingInitialLoad() async throws {
    let session = checkInSession(userID: 7, revision: checkInUUID(15))
    let loader = SuspendedFollowedCheckInCatalogLoader(
      suspendedRevision: session.sessionRevision,
      catalogs: [
        session.sessionRevision: checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { try await loader.load(session: $0) },
      now: { followedCheckInStableDate() },
      calendar: tiebaCheckInTestCalendar()
    )

    store.loadIfNeeded()
    await loader.waitUntilSuspendedRequestStarts()
    store.significantTimeDidChange(shouldLoad: true)
    let requestsBeforeRelease = await loader.requestedRevisions()
    XCTAssertEqual(requestsBeforeRelease, [session.sessionRevision])

    await loader.releaseSuspendedRequest()
    try await waitForFollowedCheckInState { store.state == .ready }
    let requestsAfterRelease = await loader.requestedRevisions()
    XCTAssertEqual(requestsAfterRelease, [session.sessionRevision])
  }

  func testPostMidnightBatchConfirmationSurvivesTheOldCatalogResponse() async throws {
    let beforeMidnight = Date(timeIntervalSince1970: 1_787_673_570)
    let afterMidnight = Date(timeIntervalSince1970: 1_787_673_630)
    let clock = FollowedCheckInDateBox(beforeMidnight)
    let session = checkInSession(userID: 7, revision: checkInUUID(13))
    let loader = SuspendedFollowedCheckInCatalogLoader(
      suspendedRevision: session.sessionRevision,
      catalogs: [
        session.sessionRevision: checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .pending)
        ])
      ]
    )
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { try await loader.load(session: $0) },
      now: { clock.value() },
      calendar: tiebaCheckInTestCalendar()
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    await loader.waitUntilSuspendedRequestStarts()
    clock.set(afterMidnight)
    store.forumCheckInCatalogDidChange(
      ForumCheckInCatalogChange(
        accountID: 7,
        sessionRevision: session.sessionRevision,
        confirmedTargets: [ForumBatchCheckInTarget(forumID: 1, forumName: "one")]
      ),
      loadImmediately: false
    )

    await loader.releaseSuspendedRequest()
    try await waitForFollowedCheckInState {
      await loader.requestedRevisions().count == 2 && store.state == .ready
    }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))
  }

  func testScheduledTiebaMidnightActivelyExpiresThePublishedSnapshot() async throws {
    let beforeMidnight = Date(timeIntervalSince1970: 1_787_673_570)
    let afterMidnight = Date(timeIntervalSince1970: 1_787_673_630)
    let clock = FollowedCheckInDateBox(beforeMidnight)
    let sleeper = ControlledFollowedCheckInExpirationSleeper()
    let session = checkInSession(userID: 7, revision: checkInUUID(10))
    let store = FollowedForumCheckInStore(
      vault: FollowedCheckInVaultSpy(session: session),
      catalogLoader: { _ in
        checkInCatalog(userID: 7, targets: [
          checkInTarget(id: 1, name: "one", status: .checkedIn)
        ])
      },
      now: { clock.value() },
      calendar: tiebaCheckInTestCalendar(),
      expirationSleeper: { try await sleeper.sleep(nanoseconds: $0) }
    )
    let forum = checkInForum(id: 1, name: "one")
    let lease = AccountSessionLease(session)

    store.loadIfNeeded()
    try await waitForFollowedCheckInState {
      let pendingCount = await sleeper.pendingCount()
      return store.state == .ready && pendingCount == 1
    }
    XCTAssertTrue(store.isCheckedInToday(forum, forumLease: lease))

    clock.set(afterMidnight)
    let released = await sleeper.releaseNext()
    XCTAssertTrue(released)
    try await waitForFollowedCheckInState {
      store.snapshot == nil && store.state == .idle
    }
    XCTAssertFalse(store.isCheckedInToday(forum, forumLease: lease))
  }
}

@MainActor
private func makeFollowedCheckInStore(
  vault: any AccountVault,
  loader: FollowedCheckInCatalogLoaderSpy,
  minimumForegroundRefreshInterval: TimeInterval = 300
) -> FollowedForumCheckInStore {
  FollowedForumCheckInStore(
    vault: vault,
    catalogLoader: { try await loader.load(session: $0) },
    now: { followedCheckInStableDate() },
    calendar: tiebaCheckInTestCalendar(),
    minimumForegroundRefreshInterval: minimumForegroundRefreshInterval
  )
}

private func followedCheckInStableDate() -> Date {
  Date(timeIntervalSince1970: 1_787_640_000)
}

private func checkInCatalog(
  userID: Int64,
  targets: [ForumCheckInCatalogTarget]
) -> ForumCheckInCatalogData {
  ForumCheckInCatalogData(
    userID: userID,
    targets: targets,
    officialBatchPolicy: nil
  )
}

private func checkInTarget(
  id: Int64,
  name: String,
  status: ForumCheckInCatalogStatus
) -> ForumCheckInCatalogTarget {
  ForumCheckInCatalogTarget(
    forumID: id,
    forumName: name,
    level: 1,
    status: status,
    isForbidden: false
  )
}

private func checkInForum(id: Int64, name: String) -> FollowedForumItem {
  FollowedForumItem(id: id, name: name, level: 1, experience: 1)
}

private func checkInSession(
  userID: Int64,
  revision: UUID,
  hasFullCredentials: Bool = true
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "user-\(userID)",
    displayName: "User \(userID)",
    portrait: "",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: hasFullCredentials
      ? String(repeating: "s", count: AccountCredentialFormat.stokenLength)
      : nil,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func checkInUUID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func tiebaCheckInTestCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
  return calendar
}

@MainActor
private func waitForFollowedCheckInState(
  timeoutNanoseconds: UInt64 = 2_000_000_000,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
  while !(await condition()) {
    if clock.now >= deadline {
      throw FollowedCheckInTestFailure(message: "timed out waiting for check-in projection")
    }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}

private struct FollowedCheckInTestFailure: Error {
  let message: String
}

private actor FollowedCheckInVaultSpy: AccountVault {
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

  func setActiveSession(_ session: StoredAccountSession?) {
    self.session = session
  }
}

private actor FollowedCheckInCatalogLoaderSpy {
  private var responses: [Result<ForumCheckInCatalogData, FollowedCheckInTestFailure>]
  private var revisions = [UUID]()

  init(responses: [Result<ForumCheckInCatalogData, FollowedCheckInTestFailure>]) {
    self.responses = responses
  }

  func load(session: StoredAccountSession) async throws -> ForumCheckInCatalogData {
    revisions.append(session.sessionRevision)
    guard !responses.isEmpty else {
      throw FollowedCheckInTestFailure(message: "unexpected catalog request")
    }
    return try responses.removeFirst().get()
  }

  func requestedRevisions() -> [UUID] { revisions }
}

private actor SuspendedFollowedCheckInCatalogLoader {
  private let suspendedRevision: UUID
  private let catalogs: [UUID: ForumCheckInCatalogData]
  private var revisions = [UUID]()
  private var continuation: CheckedContinuation<Void, Never>?
  private var didSuspend = false
  private var waiters = [CheckedContinuation<Void, Never>]()

  init(suspendedRevision: UUID, catalogs: [UUID: ForumCheckInCatalogData]) {
    self.suspendedRevision = suspendedRevision
    self.catalogs = catalogs
  }

  func load(session: StoredAccountSession) async throws -> ForumCheckInCatalogData {
    revisions.append(session.sessionRevision)
    if session.sessionRevision == suspendedRevision, !didSuspend {
      didSuspend = true
      let waiters = waiters
      self.waiters = []
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { continuation = $0 }
    }
    guard let catalog = catalogs[session.sessionRevision] else {
      throw FollowedCheckInTestFailure(message: "unexpected catalog revision")
    }
    return catalog
  }

  func waitUntilSuspendedRequestStarts() async {
    if didSuspend { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func releaseSuspendedRequest() {
    continuation?.resume()
    continuation = nil
  }

  func requestedRevisions() -> [UUID] { revisions }
}

private actor ControlledFollowedCheckInExpirationSleeper {
  private var nextIdentifier = 0
  private var order = [Int]()
  private var continuations = [Int: CheckedContinuation<Void, any Error>]()

  func sleep(nanoseconds: UInt64) async throws {
    _ = nanoseconds
    let identifier = nextIdentifier
    nextIdentifier += 1
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

  func pendingCount() -> Int { continuations.count }

  private func cancel(identifier: Int) {
    guard let continuation = continuations.removeValue(forKey: identifier) else { return }
    continuation.resume(throwing: CancellationError())
  }
}

private final class FollowedCheckInDateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func value() -> Date {
    lock.withLock { date }
  }

  func set(_ date: Date) {
    lock.withLock { self.date = date }
  }
}
