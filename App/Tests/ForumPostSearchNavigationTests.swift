import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumPostSearchNavigationTests: XCTestCase {
  func testPrimaryDestinationsUseExplicitThreadRoutesAndCommentResolution() {
    let threadResult = item(target: .thread)
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.primaryDestination(for: threadResult),
      .thread(
        thread: threadResult.thread,
        route: TiebaThreadRoute(threadID: threadResult.thread.id)
      )
    )

    let postResult = item(target: .post(201))
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.primaryDestination(for: postResult),
      .thread(
        thread: postResult.thread,
        route: TiebaThreadRoute(threadID: postResult.thread.id, postID: 201)
      )
    )

    let commentResult = item(target: .comment(postID: 0, commentID: 301))
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.primaryDestination(for: commentResult),
      .resolvingComment(threadID: commentResult.thread.id, commentID: 301)
    )
  }

  func testPrimaryDestinationsRejectInvalidIdentityAndFilteredRows() {
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(
        for: item(threadID: 0, target: .thread)
      )
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(for: item(target: .post(0)))
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(for: item(target: .post(-1)))
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(
        for: item(target: .comment(postID: 202, commentID: 0))
      )
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(
        for: item(target: .thread, visibility: .placeholder)
      )
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.primaryDestination(
        for: item(target: .thread, visibility: .hidden)
      )
    )
  }

  func testCommentContextsNavigateParentPostAndMainTopicIndependently() {
    let parent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202
    )
    let main = context(target: .mainPost(threadID: 42), summaryPostID: 100)
    let result = item(
      target: .comment(postID: 202, commentID: 301),
      contexts: [parent, main]
    )

    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(for: result, context: parent),
      .thread(
        thread: result.thread,
        route: TiebaThreadRoute(threadID: 42, postID: 202)
      )
    )
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(for: result, context: main),
      .thread(thread: result.thread, route: TiebaThreadRoute(threadID: 42))
    )
  }

  func testPostMainContextNavigatesTopicRootWithoutHistoryResume() {
    let main = context(target: .mainPost(threadID: 42), summaryPostID: 100)
    let result = item(target: .post(201), contexts: [main])

    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(for: result, context: main),
      .thread(thread: result.thread, route: TiebaThreadRoute(threadID: 42))
    )
  }

  func testContextDestinationsRejectCrossThreadConflictingAndFilteredContexts() {
    let validParent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202
    )
    let crossThreadParent = context(
      target: .parentPost(threadID: 43, postID: 202),
      summaryPostID: 202
    )
    let conflictingParent = context(
      target: .parentPost(threadID: 42, postID: 203),
      summaryPostID: 203
    )
    let mismatchedSummary = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 203
    )
    let filteredParent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202,
      visibility: .placeholder
    )
    let hiddenParent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202,
      visibility: .hidden
    )
    let crossThreadMain = context(target: .mainPost(threadID: 43), summaryPostID: 100)
    let result = item(
      target: .comment(postID: 202, commentID: 301),
      contexts: [
        validParent,
        crossThreadParent,
        conflictingParent,
        mismatchedSummary,
        filteredParent,
        hiddenParent,
        crossThreadMain,
      ]
    )

    for invalid in [
      crossThreadParent,
      conflictingParent,
      mismatchedSummary,
      filteredParent,
      hiddenParent,
      crossThreadMain,
    ] {
      XCTAssertNil(
        ForumPostSearchNavigationPolicy.contextDestination(for: result, context: invalid)
      )
    }

    let absent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202,
      title: "not retained"
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.contextDestination(for: result, context: absent)
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.contextDestination(
        for: item(target: .thread, contexts: [crossThreadMain]),
        context: crossThreadMain
      )
    )
  }

  func testValidContextRemainsIndependentFromInvalidPrimaryTarget() {
    let main = context(target: .mainPost(threadID: 42), summaryPostID: 100)
    let invalidPost = item(target: .post(0), contexts: [main])

    XCTAssertNil(ForumPostSearchNavigationPolicy.primaryDestination(for: invalidPost))
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(for: invalidPost, context: main),
      .thread(thread: invalidPost.thread, route: TiebaThreadRoute(threadID: 42))
    )

    let parent = context(
      target: .parentPost(threadID: 42, postID: 202),
      summaryPostID: 202
    )
    let invalidComment = item(
      target: .comment(postID: 202, commentID: 0),
      contexts: [parent]
    )
    XCTAssertNil(ForumPostSearchNavigationPolicy.primaryDestination(for: invalidComment))
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(
        for: invalidComment,
        context: parent
      ),
      .thread(
        thread: invalidComment.thread,
        route: TiebaThreadRoute(threadID: 42, postID: 202)
      )
    )
  }

  func testAuthorDestinationRequiresVisiblePositiveIdentity() {
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.authorDestination(for: item(target: .thread)),
      .user(7)
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.authorDestination(
        for: item(target: .thread, authorID: 0)
      )
    )
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.authorDestination(
        for: item(target: .thread, visibility: .placeholder)
      )
    )
  }

  private func item(
    threadID: Int64 = 42,
    target: ForumPostSearchTarget,
    contexts: [ForumPostSearchContext] = [],
    visibility: LocalContentVisibility = .visible,
    authorID: Int64 = 7
  ) -> ForumPostSearchItem {
    ForumPostSearchItem(
      thread: BrowseThread(
        id: threadID,
        forumID: 8,
        forumName: "swift",
        title: "Thread",
        excerpt: "Opening content",
        authorName: "Topic author",
        replyCount: 10,
        viewCount: 20,
        createdAt: nil,
        lastReplyAt: nil,
        contents: []
      ),
      target: target,
      matchedTitle: "Match",
      matchedExcerpt: "Matched content",
      matchedAuthorID: authorID,
      matchedAuthorName: "Matched author",
      matchedAuthorPortraitURL: nil,
      matchedAt: nil,
      replyCount: 1,
      likeCount: 2,
      shareCount: 3,
      matchedContents: [],
      contexts: contexts,
      localVisibility: visibility
    )
  }

  private func context(
    target: ForumPostSearchContextTarget,
    summaryPostID: Int64,
    visibility: LocalContentVisibility = .visible,
    title: String = "Context"
  ) -> ForumPostSearchContext {
    ForumPostSearchContext(
      target: target,
      summary: ForumPostSearchSummary(
        postID: summaryPostID,
        title: title,
        excerpt: "Context content",
        authorID: 9,
        authorName: "Context author",
        localVisibility: visibility
      )
    )
  }
}
