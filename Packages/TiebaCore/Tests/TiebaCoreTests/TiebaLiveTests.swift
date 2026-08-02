import Foundation
import XCTest

@testable import TiebaCore

final class TiebaLiveTests: XCTestCase {
  func testAnonymousForumPostAndCommentFlow() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.10 integration-test")
    )
    let threads = try await client.getThreads(forumName: "starry", pageSize: 10)
    XCTAssertFalse(threads.threads.isEmpty)

    let creationSorted = try await client.getThreads(
      forumName: "starry",
      pageSize: 5,
      sort: .creationTime
    )
    XCTAssertFalse(creationSorted.threads.isEmpty)

    if let classification = threads.forum.featuredClassifications.first {
      _ = try await client.getThreads(
        forumName: "starry",
        pageSize: 5,
        featuredOnly: true,
        featuredClassificationID: classification.id
      )
    } else {
      _ = try await client.getThreads(
        forumName: "starry",
        pageSize: 5,
        featuredOnly: true
      )
    }

    let thread = try XCTUnwrap(threads.threads.max { $0.replyCount < $1.replyCount })
    let posts = try await client.getPosts(threadID: thread.id, pageSize: 10)
    XCTAssertFalse(posts.posts.isEmpty)

    let resumePost = try XCTUnwrap(posts.posts.last)
    let resumedPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      location: .postID(resumePost.id)
    )
    XCTAssertTrue(resumedPosts.posts.contains(where: { $0.id == resumePost.id }))

    let descendingPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      sort: .descending
    )
    XCTAssertFalse(descendingPosts.posts.isEmpty)
    let descendingFloors = descendingPosts.posts.map(\.floor).filter { $0 > 0 }
    XCTAssertGreaterThan(descendingFloors.count, 1)
    XCTAssertGreaterThan(
      try XCTUnwrap(descendingFloors.first),
      try XCTUnwrap(descendingFloors.last)
    )
    XCTAssertTrue(
      zip(descendingFloors, descendingFloors.dropFirst()).allSatisfy { pair in
        pair.0 >= pair.1
      }
    )

    XCTAssertGreaterThan(descendingPosts.pagination.totalPages, 1)
    let cursor = try XCTUnwrap(descendingPosts.thread.pagePostIDs.first)
    let continuationPage = max(
      descendingPosts.pagination.totalPages - descendingPosts.pagination.currentPage,
      0
    )
    let continuedPosts = try await client.getPosts(
      threadID: thread.id,
      page: continuationPage,
      pageSize: 10,
      sort: .descending,
      location: .pageCursor(cursor)
    )
    XCTAssertFalse(continuedPosts.posts.isEmpty)
    let continuedFloors = continuedPosts.posts.map(\.floor).filter { $0 > 0 }
    XCTAssertGreaterThan(continuedFloors.count, 1)
    XCTAssertTrue(
      zip(continuedFloors, continuedFloors.dropFirst()).allSatisfy { pair in
        pair.0 >= pair.1
      }
    )
    let initialPostIDs = Set(descendingPosts.posts.map(\.id))
    let uniqueContinuedPosts = continuedPosts.posts.filter { !initialPostIDs.contains($0.id) }
    XCTAssertFalse(uniqueContinuedPosts.isEmpty)
    if let initialNewestFloor = descendingFloors.max(),
      let continuedNewestFloor = uniqueContinuedPosts.map(\.floor).filter({ $0 > 0 }).max()
    {
      XCTAssertLessThan(continuedNewestFloor, initialNewestFloor)
    }

    let hotAuthorPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      sort: .hot,
      onlyThreadAuthor: true
    )
    XCTAssertFalse(hotAuthorPosts.posts.isEmpty)

    guard let post = posts.posts.first(where: { $0.commentCount > 0 }) else {
      throw XCTSkip("The sampled live posts have no nested comments.")
    }
    let comments = try await client.getComments(threadID: thread.id, postID: post.id)
    XCTAssertEqual(comments.thread.id, thread.id)
    XCTAssertEqual(comments.parentPost.id, post.id)
  }

  func testAnonymousForumAndThreadSearch() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.10 integration-test")
    )
    let forums = try await client.searchForums(query: "swift")
    XCTAssertFalse(forums.isLoggedIn)
    XCTAssertTrue(forums.exactMatch != nil || !forums.fuzzyMatches.isEmpty)

    let threads = try await client.searchThreads(query: "swift", pageSize: 5)
    XCTAssertFalse(threads.isLoggedIn)
    XCTAssertFalse(threads.results.isEmpty)
    XCTAssertEqual(threads.pagination.currentPage, 1)

    let scopedThreads = try await client.searchForumPosts(
      query: "游戏",
      forumName: "minecraft",
      pageSize: 5,
      sort: .relevance,
      filter: .threadsOnly
    )
    XCTAssertFalse(scopedThreads.isLoggedIn)
    XCTAssertFalse(scopedThreads.results.isEmpty)
    XCTAssertEqual(scopedThreads.pagination.currentPage, 1)
    XCTAssertTrue(scopedThreads.results.allSatisfy { $0.target == .thread })

    let scopedAllContent = try await client.searchForumPosts(
      query: "游戏",
      forumName: "minecraft",
      pageSize: 20,
      sort: .newest,
      filter: .all
    )
    XCTAssertFalse(scopedAllContent.results.isEmpty)
    let containsReply = scopedAllContent.results.contains(where: { result in
      if case .post = result.target { return true }
      return false
    })
    XCTAssertTrue(containsReply)

    if scopedThreads.pagination.hasMore {
      let nextScopedPage = try await client.searchForumPosts(
        query: "游戏",
        forumName: "minecraft",
        page: 2,
        pageSize: 5,
        sort: .relevance,
        filter: .threadsOnly
      )
      XCTAssertEqual(nextScopedPage.pagination.currentPage, 2)
      XCTAssertFalse(nextScopedPage.results.isEmpty)
    }

    let users = try await client.searchUsers(query: "swift")
    XCTAssertTrue(users.exactMatch != nil || !users.fuzzyMatches.isEmpty)
    XCTAssertTrue(users.fuzzyMatches.allSatisfy { $0.id > 0 && !$0.preferredName.isEmpty })
  }

  func testAnonymousHotTopicListDetailAndPagination() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.10 integration-test")
    )
    let topics = try await client.getHotTopics()
    let topic = try XCTUnwrap(topics.first)
    XCTAssertGreaterThan(topic.id, 0)
    XCTAssertFalse(topic.name.isEmpty)
    XCTAssertGreaterThan(topic.rank, 0)

    let firstPage = try await client.getHotTopic(
      topicID: topic.id,
      topicName: topic.name,
      pageSize: 10
    )
    XCTAssertEqual(firstPage.topic.id, topic.id)
    XCTAssertFalse(firstPage.topic.name.isEmpty)
    XCTAssertFalse(firstPage.threads.isEmpty && firstPage.relatedForums.isEmpty)
    XCTAssertTrue(firstPage.threads.allSatisfy { $0.threadID > 0 })

    if firstPage.pagination.hasMore, let cursor = firstPage.nextPageCursor {
      let secondPage = try await client.getHotTopic(
        topicID: topic.id,
        topicName: topic.name,
        page: 2,
        pageSize: 10,
        lastID: cursor
      )
      XCTAssertEqual(secondPage.pagination.currentPage, 2)
      XCTAssertTrue(secondPage.threads.allSatisfy { $0.threadID > 0 })
    }
  }

  func testAnonymousPublicUserProfileAndThreads() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let userID: Int64 = 957_339_815
    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.10 integration-test")
    )

    let profile = try await client.getUserProfile(userID: userID)
    XCTAssertEqual(profile.user.id, userID)
    XCTAssertFalse(profile.user.preferredName.isEmpty)
    XCTAssertFalse(profile.user.portrait.isEmpty)

    let activity = try await client.getUserThreads(userID: userID, page: 1, pageSize: 20)
    XCTAssertEqual(activity.userID, userID)
    XCTAssertEqual(activity.pagination.currentPage, 1)
    XCTAssertFalse(activity.isHidden)
    XCTAssertFalse(activity.threads.isEmpty)
    XCTAssertTrue(activity.threads.allSatisfy { $0.id > 0 && $0.forumID > 0 })
  }

  func testAnonymousPublicForumOverviewModeratorsAndRules() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.10 integration-test")
    )
    let forumID: Int64 = 2_432_903

    let overview = try await client.getForumOverview(forumID: forumID)
    XCTAssertEqual(overview.forum.id, forumID)
    XCTAssertEqual(overview.forum.name.lowercased(), "minecraft")
    XCTAssertFalse(overview.introduction.isEmpty)
    XCTAssertGreaterThan(overview.forum.memberCount, 0)

    let moderatorRoles = try await client.getForumModerators(forumID: forumID)
    XCTAssertFalse(moderatorRoles.isEmpty)
    XCTAssertTrue(moderatorRoles.contains { !$0.moderators.isEmpty })

    let rules = try await client.getForumRules(forumID: forumID)
    XCTAssertEqual(rules.forum.id, forumID)
    XCTAssertFalse(rules.title.isEmpty)
    XCTAssertFalse(rules.rules.isEmpty)
    XCTAssertTrue(rules.rules.contains { !$0.content.fragments.isEmpty })
  }
}
