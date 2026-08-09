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
      (.hotThreads, [.explore(.hot)]),
      (.hotTopics, [.hotTopics]),
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

private extension RootDestination {
  var threadSnapshot: ThreadHistorySnapshot? {
    guard case .thread(let thread) = self else { return nil }
    return thread
  }
}
