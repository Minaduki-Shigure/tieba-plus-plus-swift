import Foundation
import XCTest

@testable import TiebaCore

final class TiebaLiveTests: XCTestCase {
  func testAnonymousForumPostAndCommentFlow() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.3 integration-test")
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
    XCTAssertGreaterThan(try XCTUnwrap(descendingFloors.first), try XCTUnwrap(descendingFloors.last))
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
      configuration: .init(userAgent: "TiebaPlusPlus/0.3 integration-test")
    )
    let forums = try await client.searchForums(query: "swift")
    XCTAssertFalse(forums.isLoggedIn)
    XCTAssertTrue(forums.exactMatch != nil || !forums.fuzzyMatches.isEmpty)

    let threads = try await client.searchThreads(query: "swift", pageSize: 5)
    XCTAssertFalse(threads.isLoggedIn)
    XCTAssertFalse(threads.results.isEmpty)
    XCTAssertEqual(threads.pagination.currentPage, 1)
  }
}
