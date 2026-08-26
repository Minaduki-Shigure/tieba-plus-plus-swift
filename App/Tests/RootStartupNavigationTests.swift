import Foundation
import XCTest

@testable import TiebaPlusPlus

final class RootStartupNavigationTests: XCTestCase {
  func testMainTabsKeepTiebaLiteOrderTitlesAndStableValues() {
    XCTAssertEqual(RootMainTab.allCases, [.home, .explore, .notifications, .account])
    XCTAssertEqual(
      RootMainTab.allCases.map(\.rawValue),
      ["home", "explore", "notifications", "account"]
    )
    XCTAssertEqual(
      RootMainTab.allCases.map(\.title),
      ["首页", "发现", "消息", "我的"]
    )
    XCTAssertEqual(
      RootMainTab.allCases.map(\.systemImage),
      ["house.fill", "sparkles", "bell.fill", "person.crop.circle.fill"]
    )
  }

  func testMainNavigationKeepsIndependentStacksAndRootSelectionClearsOnlyTarget() {
    var navigation = RootMainNavigationState(
      selectedTab: .home,
      homePath: [.history],
      explorePath: [.hotTopics],
      notificationsPath: [.user(7)],
      accountPath: [.settings]
    )

    navigation.append(.forum("swift"), to: .explore)
    XCTAssertEqual(navigation.path(for: .home), [.history])
    XCTAssertEqual(navigation.path(for: .explore), [.hotTopics, .forum("swift")])
    XCTAssertEqual(navigation.path(for: .notifications), [.user(7)])
    XCTAssertEqual(navigation.path(for: .account), [.settings])

    navigation.selectRoot(.explore)
    XCTAssertEqual(navigation.selectedTab, .explore)
    XCTAssertTrue(navigation.path(for: .explore).isEmpty)
    XCTAssertEqual(navigation.path(for: .home), [.history])
    XCTAssertEqual(navigation.path(for: .notifications), [.user(7)])
    XCTAssertEqual(navigation.path(for: .account), [.settings])
  }

  func testExploreActivationSelectsRequestedRootWithFreshIdentity() {
    var navigation = RootMainNavigationState(
      selectedTab: .home,
      exploreSection: .hot,
      exploreActivationID: 7,
      explorePath: [.hotTopics]
    )

    navigation.activateExplore(.personalized)

    XCTAssertEqual(navigation.selectedTab, .explore)
    XCTAssertEqual(navigation.exploreSection, .personalized)
    XCTAssertEqual(navigation.exploreActivationID, 8)
    XCTAssertTrue(navigation.path(for: .explore).isEmpty)
  }

  func testPrimarySurfaceChangesOnlyWhenSelectedTabChanges() {
    let initial = RootMainNavigationState(
      selectedTab: .notifications,
      inboxKind: .mentions,
      inboxActivationID: 4
    )
    var pathOnly = initial
    pathOnly.append(.user(7), to: .notifications)
    XCTAssertEqual(pathOnly.primarySurface, initial.primarySurface)

    var inboxOnly = initial
    inboxOnly.activateInbox(.replies)
    XCTAssertEqual(inboxOnly.primarySurface, initial.primarySurface)

    var tabChange = initial
    tabChange.selectRoot(.account)
    XCTAssertNotEqual(tabChange.primarySurface, initial.primarySurface)
  }

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

  func testStartDestinationCreatesExpectedMainTabState() {
    let cases: [(destination: AppStartDestination, expected: RootMainNavigationState)] = [
      (.home, RootMainNavigationState(selectedTab: .home)),
      (
        .discovery,
        RootMainNavigationState(selectedTab: .explore, exploreSection: .personalized)
      ),
      (.hotThreads, RootMainNavigationState(selectedTab: .explore, exploreSection: .hot)),
      (
        .hotTopics,
        RootMainNavigationState(selectedTab: .explore, explorePath: [.hotTopics])
      ),
      (
        .notifications,
        RootMainNavigationState(selectedTab: .notifications, inboxKind: .replies)
      ),
      (.favorites, RootMainNavigationState(selectedTab: .home, homePath: [.favorites])),
      (.history, RootMainNavigationState(selectedTab: .home, homePath: [.history])),
    ]

    for testCase in cases {
      XCTAssertEqual(
        RootStartupNavigation.initialState(startDestination: testCase.destination),
        testCase.expected
      )
    }
  }

  func testAppRoutesRemainTopmostForEveryStartDestination() {
    let homeRoutes: [(route: TiebaAppRoute, expected: RootDestination)] = [
      (.search, .search("")),
      (.history, .history),
      (.cloudFavorites, .cloudFavorites),
      (.batchCheckIn, .batchCheckIn),
    ]

    for startDestination in AppStartDestination.allCases {
      let initial = RootStartupNavigation.initialState(
        startDestination: startDestination
      )
      for route in homeRoutes {
        let result = RootStartupNavigation.appending(
          appRoute: route.route,
          to: initial
        )

        XCTAssertEqual(result.selectedTab, .home)
        XCTAssertEqual(Array(result.path(for: .home).dropLast()), initial.path(for: .home))
        XCTAssertEqual(result.path(for: .home).last, route.expected)
        XCTAssertEqual(result.path(for: .explore), initial.path(for: .explore))
        XCTAssertEqual(result.path(for: .notifications), initial.path(for: .notifications))
        XCTAssertEqual(result.path(for: .account), initial.path(for: .account))
      }
    }
  }

  func testNotificationAppRoutesActivateExactRootKindAndDiscardOldNotificationPath() {
    var initial = RootMainNavigationState(
      selectedTab: .account,
      inboxKind: .replies,
      inboxActivationID: 7,
      notificationsPath: [.user(42)],
      accountPath: [.settings]
    )
    initial.append(.history, to: .home)

    let mentions = RootStartupNavigation.appending(
      appRoute: .notifications(.mentions),
      to: initial
    )
    XCTAssertEqual(mentions.selectedTab, .notifications)
    XCTAssertEqual(mentions.inboxKind, .mentions)
    XCTAssertEqual(mentions.inboxActivationID, 8)
    XCTAssertTrue(mentions.path(for: .notifications).isEmpty)
    XCTAssertEqual(mentions.path(for: .home), [.history])
    XCTAssertEqual(mentions.path(for: .account), [.settings])

    let replies = RootStartupNavigation.appending(
      appRoute: .notifications(.replies),
      to: mentions
    )
    XCTAssertEqual(replies.selectedTab, .notifications)
    XCTAssertEqual(replies.inboxKind, .replies)
    XCTAssertEqual(replies.inboxActivationID, 9)
    XCTAssertTrue(replies.path(for: .notifications).isEmpty)
  }

  func testURLRoutingAcceptsContentAndAppRoutesWithoutReplacingTheExistingPath() throws {
    let existing = RootMainNavigationState(
      selectedTab: .account,
      accountPath: [.history]
    )
    let contentCases: [(value: String, expected: RootDestination)] = [
      ("https://tieba.baidu.com/f?kw=swift", .forum("swift")),
      ("tieba-plus-plus://thread/42", .linkedThread(TiebaThreadRoute(threadID: 42))),
    ]

    for testCase in contentCases {
      let url = try XCTUnwrap(URL(string: testCase.value))
      let result = try XCTUnwrap(
        RootStartupNavigation.appending(url: url, to: existing)
      )
      XCTAssertEqual(result.selectedTab, .account)
      XCTAssertEqual(Array(result.path(for: .account).dropLast()), [.history])
      XCTAssertEqual(result.path(for: .account).last, testCase.expected)
    }

    let search = try XCTUnwrap(
      RootStartupNavigation.appending(
        url: try XCTUnwrap(URL(string: "tieba-plus-plus://search")),
        to: existing
      )
    )
    XCTAssertEqual(search.selectedTab, .home)
    XCTAssertEqual(search.path(for: .home), [.search("")])
    XCTAssertEqual(search.path(for: .account), [.history])

    let mentions = try XCTUnwrap(
      RootStartupNavigation.appending(
        url: try XCTUnwrap(URL(string: "tieba-plus-plus://notifications/1")),
        to: existing
      )
    )
    XCTAssertEqual(mentions.selectedTab, .notifications)
    XCTAssertEqual(mentions.inboxKind, .mentions)
    XCTAssertTrue(mentions.path(for: .notifications).isEmpty)
    XCTAssertEqual(mentions.path(for: .account), [.history])
  }

  func testAppURLRoutesSelectHomeForExistingNonInboxDestinations() throws {
    let existing = RootMainNavigationState(selectedTab: .explore, explorePath: [.user(5)])
    let cases: [(value: String, expected: RootDestination)] = [
      ("tieba-plus-plus://favorite", .cloudFavorites),
      ("tieba-plus-plus://check-in", .batchCheckIn),
    ]
    for testCase in cases {
      let result = try XCTUnwrap(
        RootStartupNavigation.appending(
          url: try XCTUnwrap(URL(string: testCase.value)),
          to: existing
        )
      )
      XCTAssertEqual(result.selectedTab, .home)
      XCTAssertEqual(result.path(for: .home).last, testCase.expected)
      XCTAssertEqual(result.path(for: .explore), [.user(5)])
    }
  }

  func testURLRoutingRejectsInvalidOrNoncanonicalURLsWithoutProducingAPath() throws {
    let existing = RootMainNavigationState(selectedTab: .home, homePath: [.history])
    let values = [
      "https://example.com/path",
      "tieba-plus-plus://search?",
      "tieba-plus-plus://notifications/2",
      "tieba-plus-plus://favorite/",
      "tieba-plus-plus://check-in/",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(RootStartupNavigation.appending(url: url, to: existing), value)
    }
  }

  func testQuickActionsReplaceMatchingNonCheckInNavigationWithFreshLanding() {
    let actions: [HomeScreenQuickAction] = [.search, .cloudFavorites]
    let initial = RootMainNavigationState(
      selectedTab: .account,
      homePath: [.history],
      accountPath: [.user(7)]
    )

    for (index, action) in actions.enumerated() {
      let invocation = rootQuickActionInvocation(index + 1, action: action)
      let result = RootStartupNavigation.applyingQuickAction(
        invocation: invocation,
        to: initial
      )
      XCTAssertEqual(result.selectedTab, .home)
      XCTAssertEqual(result.path(for: .home), [.homeScreenQuickAction(invocation)])
      XCTAssertEqual(result.path(for: .account), [.user(7)])
    }
  }

  func testNotificationQuickActionActivatesFreshRepliesRoot() {
    let initial = RootMainNavigationState(
      selectedTab: .notifications,
      inboxKind: .mentions,
      inboxActivationID: 9,
      notificationsPath: [.user(8)]
    )
    let invocation = rootQuickActionInvocation(1, action: .notificationReplies)
    let result = RootStartupNavigation.applyingQuickAction(
      invocation: invocation,
      to: initial
    )

    XCTAssertEqual(result.selectedTab, .notifications)
    XCTAssertEqual(result.inboxKind, .replies)
    XCTAssertEqual(result.inboxActivationID, 10)
    XCTAssertTrue(result.path(for: .notifications).isEmpty)
  }

  func testQuickActionReplacesAnOlderMatchingActivation() {
    let oldInvocation = rootQuickActionInvocation(1, action: .search)
    let newInvocation = rootQuickActionInvocation(2, action: .search)

    XCTAssertEqual(
      RootStartupNavigation.applyingQuickAction(
        invocation: newInvocation,
        to: RootMainNavigationState(
          selectedTab: .home,
          homePath: [.history, .homeScreenQuickAction(oldInvocation)]
        )
      ).path(for: .home),
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
      let initial = RootMainNavigationState(selectedTab: .home, homePath: path)
      XCTAssertEqual(
        RootStartupNavigation.applyingQuickAction(
          invocation: rootQuickActionInvocation(2, action: .batchCheckIn),
          to: initial
        ),
        initial
      )
    }
  }

  func testQuickActionsReplaceADifferentCurrentDestination() {
    let initial = RootMainNavigationState(
      selectedTab: .explore,
      homePath: [.forum("swift")],
      explorePath: [.user(7)]
    )
    let invocation = rootQuickActionInvocation(1, action: .batchCheckIn)

    let result = RootStartupNavigation.applyingQuickAction(
      invocation: invocation,
      to: initial
    )
    XCTAssertEqual(result.selectedTab, .home)
    XCTAssertEqual(result.path(for: .home), [.homeScreenQuickAction(invocation)])
    XCTAssertEqual(result.path(for: .explore), [.user(7)])
  }

  func testQuickActionSetsItsUniqueLandingOnAnEmptyColdStartPath() {
    let invocation = rootQuickActionInvocation(1, action: .search)

    let result = RootStartupNavigation.applyingQuickAction(
      invocation: invocation,
      to: RootMainNavigationState()
    )
    XCTAssertEqual(result.selectedTab, .home)
    XCTAssertEqual(result.path(for: .home), [.homeScreenQuickAction(invocation)])
  }

  func testLinkTargetsRemainTopmostForEveryStartDestination() {
    let route = TiebaThreadRoute(threadID: 42, postID: 43)
    let targets: [(target: TiebaLinkTarget, expected: RootDestination)] = [
      (.forum("swift"), .forum("swift")),
      (.thread(route), .linkedThread(route)),
      (.user(44), .user(44)),
    ]

    for startDestination in AppStartDestination.allCases {
      let initial = RootStartupNavigation.initialState(
        startDestination: startDestination
      )
      for target in targets {
        let result = RootStartupNavigation.appending(
          target: target.target,
          to: initial
        )

        let tab = initial.selectedTab
        XCTAssertEqual(result.selectedTab, tab)
        XCTAssertEqual(Array(result.path(for: tab).dropLast()), initial.path(for: tab))
        XCTAssertEqual(result.path(for: tab).last, target.expected)
      }
    }
  }

  func testFollowedForumsActivationOnlyKeepsEmptyRootPathActive() {
    XCTAssertTrue(
      RootFollowedForumsActivationPolicy.isActive(
        navigation: RootMainNavigationState(selectedTab: .home)
      )
    )
  }

  func testRootTabActivationRequiresForegroundSelectedEmptyRoot() {
    let navigation = RootMainNavigationState(selectedTab: .explore)
    XCTAssertTrue(
      RootMainTabActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: navigation,
        tab: .explore
      )
    )
    XCTAssertFalse(
      RootMainTabActivationPolicy.isActive(
        sceneIsActive: false,
        navigation: navigation,
        tab: .explore
      )
    )
    XCTAssertFalse(
      RootMainTabActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: navigation,
        tab: .account
      )
    )
    XCTAssertFalse(
      RootMainTabActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: RootMainNavigationState(
          selectedTab: .explore,
          explorePath: [.hotTopics]
        ),
        tab: .explore
      )
    )
    XCTAssertTrue(
      RootMainTabActivationPolicy.isForeground(
        sceneIsActive: true,
        navigation: RootMainNavigationState(
          selectedTab: .explore,
          explorePath: [.hotTopics]
        ),
        tab: .explore
      )
    )
    XCTAssertFalse(
      RootMainTabActivationPolicy.isForeground(
        sceneIsActive: false,
        navigation: navigation,
        tab: .explore
      )
    )
  }

  func testFollowedForumsActivationTreatsEveryDestinationAndOtherTabAsInactive() {
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
      .about,
      .thread(thread),
      .linkedThread(route),
      .user(7),
    ]

    for destination in destinations {
      XCTAssertFalse(
        RootFollowedForumsActivationPolicy.isActive(
          navigation: RootMainNavigationState(
            selectedTab: .home,
            homePath: [destination]
          )
        )
      )
    }
    for tab in [RootMainTab.explore, .notifications, .account] {
      XCTAssertFalse(
        RootFollowedForumsActivationPolicy.isActive(
          navigation: RootMainNavigationState(selectedTab: tab)
        )
      )
    }
  }

  func testUnreadSummaryActivationIsLimitedToVisibleHomeAndAccountSurfaces() {
    XCTAssertTrue(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: RootMainNavigationState(selectedTab: .home),
        accountSurfaceIsVisible: false
      )
    )
    XCTAssertTrue(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: RootMainNavigationState(selectedTab: .account),
        accountSurfaceIsVisible: true
      )
    )

    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: true,
        navigation: RootMainNavigationState(selectedTab: .account),
        accountSurfaceIsVisible: false
      )
    )

    let hiddenStates = [
      RootMainNavigationState(selectedTab: .home, homePath: [.forum("swift")]),
      RootMainNavigationState(selectedTab: .explore),
      RootMainNavigationState(selectedTab: .notifications),
      RootMainNavigationState(selectedTab: .account, accountPath: [.settings]),
    ]
    for navigation in hiddenStates {
      XCTAssertFalse(
        RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: true,
          navigation: navigation,
          accountSurfaceIsVisible: true
        )
      )
    }

    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: false,
        navigation: RootMainNavigationState(selectedTab: .home),
        accountSurfaceIsVisible: false
      )
    )
    XCTAssertFalse(
      RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: false,
        navigation: RootMainNavigationState(selectedTab: .account),
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
