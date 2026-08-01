import Foundation
import XCTest

@testable import TiebaCore

final class TiebaLiveTests: XCTestCase {
  func testAnonymousForumPostAndCommentFlow() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.1 integration-test")
    )
    let threads = try await client.getThreads(forumName: "starry", pageSize: 10)
    XCTAssertFalse(threads.threads.isEmpty)

    let thread = try XCTUnwrap(threads.threads.max { $0.replyCount < $1.replyCount })
    let posts = try await client.getPosts(threadID: thread.id, pageSize: 10)
    XCTAssertFalse(posts.posts.isEmpty)

    guard let post = posts.posts.first(where: { $0.commentCount > 0 }) else {
      throw XCTSkip("The sampled live posts have no nested comments.")
    }
    let comments = try await client.getComments(threadID: thread.id, postID: post.id)
    XCTAssertEqual(comments.thread.id, thread.id)
    XCTAssertEqual(comments.parentPost.id, post.id)
  }
}
