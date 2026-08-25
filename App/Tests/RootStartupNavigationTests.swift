import Foundation
import XCTest

@testable import TiebaPlusPlus

final class RootStartupNavigationTests: XCTestCase {
  func testExploreSectionsKeepStableOrderAndTitles() {
    XCTAssertEqual(ExploreSection.allCases, [.concern, .personalized, .hot])
    XCTAssertEqual(
      ExploreSection.allCases.map(\.rawValue),
      ["concern", "personalized", "hot"]
    )
    XCTAssertEqual(ExploreSection.allCases.map(\.title), ["关注", "推荐", "热门"])
    XCTAssertEqual(
      ExploreSection.available(hasActiveAccount: false),
      [.personalized, .hot]
    )
    XCTAssertEqual(
      ExploreSection.available(hasActiveAccount: true),
      [.concern, .personalized, .hot]
    )
  }

  func testStartDestinationCreatesExpectedInitialPath() {
    let cases: [(destination: AppStartDestination, expected: [RootDestination])] = [
      (.home, []),
      (.discovery, [.explore(.personalized)]),
      (.hotThreads, [.explore(.hot)]),
      (.hotTopics, [.hotTopics]),
      (.notifications, [.notifications(.replies)]),
      (.favorites, [.favorites]),
      (.history, [.history]),
    ]

    for testCase in cases {
      XCTAssertEqual(
        RootStartupNavigation.initialPath(startDestination: testCase.destination),
        testCase.expected
      )
    }
  }

  func testAppRoutesRemainTopmostForEveryStartDestination() {
    let routes: [(route: TiebaAppRoute, expected: RootDestination)] = [
      (.search, .search("")),
      (.history, .history),
      (.cloudFavorites, .cloudFavorites),
      (.batchCheckIn, .batchCheckIn),
      (.notifications(.replies), .notifications(.replies)),
      (.notifications(.mentions), .notifications(.mentions)),
    ]

    for startDestination in AppStartDestination.allCases {
      let initialPath = RootStartupNavigation.initialPath(
        startDestination: startDestination
      )
      for route in routes {
        let path = RootStartupNavigation.appending(
          appRoute: route.route,
          to: initialPath
        )

        XCTAssertEqual(Array(path.dropLast()), initialPath)
        XCTAssertEqual(path.last, route.expected)
      }
    }
  }

  func testURLRoutingAcceptsContentAndAppRoutesWithoutReplacingTheExistingPath() throws {
    let existingPath: [RootDestination] = [.history]
    let cases: [(value: String, expected: RootDestination)] = [
      ("https://tieba.baidu.com/f?kw=swift", .forum("swift")),
      ("tieba-plus-plus://thread/42", .linkedThread(TiebaThreadRoute(threadID: 42))),
      ("tieba-plus-plus://search", .search("")),
      ("tieba-plus-plus://favorite", .cloudFavorites),
      ("tieba-plus-plus://check-in", .batchCheckIn),
      ("tieba-plus-plus://notifications/1", .notifications(.mentions)),
    ]

    for testCase in cases {
      let url = try XCTUnwrap(URL(string: testCase.value))
      let path = try XCTUnwrap(
        RootStartupNavigation.appending(url: url, to: existingPath)
      )
      XCTAssertEqual(Array(path.dropLast()), existingPath)
      XCTAssertEqual(path.last, testCase.expected)
    }
  }

  func testURLRoutingRejectsInvalidOrNoncanonicalURLsWithoutProducingAPath() throws {
    let existingPath: [RootDestination] = [.history]
    let values = [
      "https://example.com/path",
      "tieba-plus-plus://search?",
      "tieba-plus-plus://notifications/2",
      "tieba-plus-plus://favorite/",
      "tieba-plus-plus://check-in/",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(RootStartupNavigation.appending(url: url, to: existingPath), value)
    }
  }

  func testQuickActionsReplaceMatchingNonCheckInNavigationWithFreshLanding() {
    let cases: [(action: HomeScreenQuickAction, destination: RootDestination)] = [
      (.search, .search("")),
      (.cloudFavorites, .cloudFavorites),
      (.notificationReplies, .notifications(.replies)),
    ]

    for (index, testCase) in cases.enumerated() {
      let path: [RootDestination] = [.history, testCase.destination]
      let invocation = rootQuickActionInvocation(index + 1, action: testCase.action)
      XCTAssertEqual(
        RootStartupNavigation.applyingQuickAction(
          invocation: invocation,
          to: path
        ),
        [.homeScreenQuickAction(invocation)]
      )
    }
  }

  func testQuickActionReplacesAnOlderMatchingActivation() {
    let oldInvocation = rootQuickActionInvocation(1, action: .search)
    let newInvocation = rootQuickActionInvocation(2, action: .search)

    XCTAssertEqual(
      RootStartupNavigation.applyingQuickAction(
        invocation: newInvocation,
        to: [.history, .homeScreenQuickAction(oldInvocation)]
      ),
      [.homeScreenQuickAction(newInvocation)]
    )
  }

  func testBatchCheckInQuickActionPreservesMatchingPageSoAnActiveRunIsNotStopped() {
    let invocation = rootQuickActionInvocation(1, action: .batchCheckIn)
    let paths: [[RootDestination]] = [
      [.history, .batchCheckIn],
      [.history, .homeScreenQuickAction(invocation)],
    ]

    for path in paths {
      XCTAssertEqual(
        RootStartupNavigation.applyingQuickAction(
          invocation: rootQuickActionInvocation(2, action: .batchCheckIn),
          to: path
        ),
        path
      )
    }
  }

  func testQuickActionsReplaceADifferentCurrentDestination() {
    let path: [RootDestination] = [.forum("swift")]
    let invocation = rootQuickActionInvocation(1, action: .batchCheckIn)

    XCTAssertEqual(
      RootStartupNavigation.applyingQuickAction(
        invocation: invocation,
        to: path
      ),
      [.homeScreenQuickAction(invocation)]
    )
  }

  func testQuickActionSetsItsUniqueLandingOnAnEmptyColdStartPath() {
    let invocation = rootQuickActionInvocation(1, action: .search)

    XCTAssertEqual(
      RootStartupNavigation.applyingQuickAction(invocation: invocation, to: []),
      [.homeScreenQuickAction(invocation)]
    )
  }

  func testLinkTargetsRemainTopmostForEveryStartDestination() {
    let route = TiebaThreadRoute(threadID: 42, postID: 43)
    let targets: [(target: TiebaLinkTarget, expected: RootDestination)] = [
      (.forum("swift"), .forum("swift")),
      (.thread(route), .linkedThread(route)),
      (.user(44), .user(44)),
    ]

    for startDestination in AppStartDestination.allCases {
      let initialPath = RootStartupNavigation.initialPath(
        startDestination: startDestination
      )
      for target in targets {
        let path = RootStartupNavigation.appending(
          target: target.target,
          to: initialPath
        )

        XCTAssertEqual(Array(path.dropLast()), initialPath)
        XCTAssertEqual(path.last, target.expected)
      }
    }
  }

  func testFollowedForumsActivationOnlyKeepsEmptyRootPathActive() {
    XCTAssertTrue(RootFollowedForumsActivationPolicy.isActive(path: []))
  }

  func testFollowedForumsActivationTreatsEveryDestinationAsInactive() {
    let route = TiebaThreadRoute(threadID: 42, postID: 43)
    let thread = ThreadHistorySnapshot(
      threadID: 42,
      forumName: "swift",
      title: "Swift concurrency"
    )
    let destinations: [RootDestination] = [
      .forum("swift"),
      .search("query"),
      .hotTopics,
      .explore(.personalized),
      .history,
      .favorites,
      .followedForums,
      .batchCheckIn,
      .notifications(.replies),
      .notifications(.mentions),
      .cloudFavorites,
      .homeScreenQuickAction(rootQuickActionInvocation(1, action: .search)),
      .account,
      .settings,
      .thread(thread),
      .linkedThread(route),
      .user(7),
    ]

    for destination in destinations {
      XCTAssertFalse(
        RootFollowedForumsActivationPolicy.isActive(path: [destination])
      )
    }
    XCTAssertFalse(
      RootFollowedForumsActivationPolicy.isActive(
        path: [.forum("swift"), .followedForums]
      )
    )
  }

  func testUnreadSummaryActivationIsLimitedToVisibleHomeAndAccountSurfaces() {
    XCTAssertTrue(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        path: [],
        accountSurfaceIsVisible: false
      )
    )
    XCTAssertTrue(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        path: [.history, .account],
        accountSurfaceIsVisible: true
      )
    )

    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        path: [.account],
        accountSurfaceIsVisible: false
      )
    )

    let hiddenPaths: [[RootDestination]] = [
      [.forum("swift")],
      [.notifications(.replies)],
      [.account, .notifications(.mentions)],
      [.settings],
    ]
    for path in hiddenPaths {
      XCTAssertFalse(
        RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: true,
          path: path,
          accountSurfaceIsVisible: false
        )
      )
    }

    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: false,
        path: [],
        accountSurfaceIsVisible: false
      )
    )
    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: false,
        path: [.account],
        accountSurfaceIsVisible: true
      )
    )
  }

  func testHomeBatchCheckInShortcutRequiresActiveFullCredentials() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let account: (_ isActive: Bool, _ hasFullCredentials: Bool) -> AccountSummary = {
      isActive, hasFullCredentials in
      AccountSummary(
        id: 7,
        username: "tester",
        displayName: "Tester",
        portraitURL: nil,
        isActive: isActive,
        hasFullCredentials: hasFullCredentials,
        updatedAt: updatedAt
      )
    }

    XCTAssertFalse(
      RootAccountActionPolicy.showsBatchCheckIn(for: nil, state: .loaded)
    )
    XCTAssertFalse(
      RootAccountActionPolicy.showsBatchCheckIn(
        for: account(false, true),
        state: .loaded
      )
    )
    XCTAssertFalse(
      RootAccountActionPolicy.showsBatchCheckIn(
        for: account(true, false),
        state: .loaded
      )
    )
    XCTAssertTrue(
      RootAccountActionPolicy.showsBatchCheckIn(
        for: account(true, true),
        state: .loaded
      )
    )
    for state in [LoadState.idle, .loading, .failed("unreadable")] {
      XCTAssertFalse(
        RootAccountActionPolicy.showsBatchCheckIn(
          for: account(true, true),
          state: state
        )
      )
    }
  }

  func testFavoriteForumDestinationIsUnaffectedByThreadOverrides() {
    let forum = ForumHistorySnapshot(
      forumID: 12,
      name: "swift",
      displayName: "Swift"
    )
    let overrides = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    )

    XCTAssertEqual(
      RootFavoriteNavigation.destination(for: .forum(forum), overrides: overrides),
      .forum("swift")
    )
  }

  func testFavoriteThreadDestinationAppliesOverridesWithoutLosingSnapshotData() throws {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let lastReplyAt = Date(timeIntervalSince1970: 1_700_000_100)
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portrait/item/test.jpg")
    )
    let thread = ThreadHistorySnapshot(
      threadID: 42,
      forumID: 7,
      forumName: "swift",
      title: "Swift concurrency",
      excerpt: "Actors and tasks",
      authorName: "Display Name",
      authorUsername: "author",
      replyCount: 18,
      viewCount: 256,
      createdAt: createdAt,
      lastReplyAt: lastReplyAt,
      authorAvatarURL: authorAvatarURL,
      browseOptions: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false),
      lastPostID: 99,
      lastFloor: 15
    )
    let overrides = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    )

    let destination = RootFavoriteNavigation.destination(
      for: .thread(thread),
      overrides: overrides
    )
    let routedThread = try XCTUnwrap(destination.threadSnapshot)

    XCTAssertEqual(routedThread.threadID, thread.threadID)
    XCTAssertEqual(routedThread.forumID, thread.forumID)
    XCTAssertEqual(routedThread.forumName, thread.forumName)
    XCTAssertEqual(routedThread.title, thread.title)
    XCTAssertEqual(routedThread.excerpt, thread.excerpt)
    XCTAssertEqual(routedThread.authorName, thread.authorName)
    XCTAssertEqual(routedThread.authorUsername, thread.authorUsername)
    XCTAssertEqual(routedThread.replyCount, thread.replyCount)
    XCTAssertEqual(routedThread.viewCount, thread.viewCount)
    XCTAssertEqual(routedThread.createdAt, createdAt)
    XCTAssertEqual(routedThread.lastReplyAt, lastReplyAt)
    XCTAssertEqual(routedThread.authorAvatarURL, thread.authorAvatarURL)
    XCTAssertEqual(routedThread.lastPostID, 99)
    XCTAssertEqual(routedThread.lastFloor, 15)
    XCTAssertEqual(
      routedThread.browseOptions,
      ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    )
  }

  func testFavoriteRoutingDoesNotDirectlyMutateExistingHistorySnapshot() throws {
    let thread = ThreadHistorySnapshot(
      threadID: 84,
      forumName: "swift",
      title: "Saved history mode",
      browseOptions: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false),
      lastPostID: 100,
      lastFloor: 16
    )

    let overrides = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    )
    let historyDestination = RootDestination.thread(thread)
    let favoriteDestination = RootFavoriteNavigation.destination(
      for: .thread(thread),
      overrides: overrides
    )
    let routedThread = try XCTUnwrap(historyDestination.threadSnapshot)
    let favoriteThread = try XCTUnwrap(favoriteDestination.threadSnapshot)

    XCTAssertEqual(routedThread, thread)
    XCTAssertEqual(routedThread.browseOptions.sort, .hot)
    XCTAssertFalse(routedThread.browseOptions.onlyThreadAuthor)
    XCTAssertEqual(favoriteThread.browseOptions.sort, .descending)
    XCTAssertTrue(favoriteThread.browseOptions.onlyThreadAuthor)
  }
}

private func rootQuickActionInvocation(
  _ value: Int,
  action: HomeScreenQuickAction
) -> HomeScreenQuickActionInvocation {
  precondition((0...255).contains(value))
  return HomeScreenQuickActionInvocation(
    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value))),
    action: action
  )
}

private extension RootDestination {
  var threadSnapshot: ThreadHistorySnapshot? {
    guard case .thread(let thread) = self else { return nil }
    return thread
  }
}
