import Foundation
import XCTest

@testable import TiebaCore

final class TiebaLiveTests: XCTestCase {
  func testAnonymousForumPostAndCommentFlow() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.2 integration-test")
    )
    let threads = try await client.getThreads(forumName: "starry", pageSize: 10)
    XCTAssertFalse(threads.threads.isEmpty)

    let creationSorted = try await client.getThreads(
      forumName: "starry",
      pageSize: 5,
      sort: .creationTime
    )
    XCTAssertFalse(creationSorted.threads.isEmpty)

    _ = try await client.getThreads(
      forumName: "starry",
      pageSize: 5,
      featuredOnly: true
    )

    let thread = try XCTUnwrap(threads.threads.max { $0.replyCount < $1.replyCount })
    let posts = try await client.getPosts(threadID: thread.id, pageSize: 10)
    XCTAssertFalse(posts.posts.isEmpty)

    let descendingPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      sort: .descending
    )
    XCTAssertFalse(descendingPosts.posts.isEmpty)

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
      configuration: .init(userAgent: "TiebaPlusPlus/0.2 integration-test")
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
