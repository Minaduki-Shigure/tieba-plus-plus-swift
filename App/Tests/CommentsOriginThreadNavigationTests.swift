import XCTest

@testable import TiebaPlusPlus

final class CommentsOriginThreadNavigationTests: XCTestCase {
  func testLoadedStandalonePageUsesExactValidatedParentFloorRoute() throws {
    let parent = makeParentPost(threadID: 10, postID: 20, floor: 7)

    let presentation = try XCTUnwrap(
      CommentsOriginThreadNavigationPolicy.loadedPresentation(
        presentationContext: .navigation,
        state: .loaded,
        expectedThreadID: 10,
        thread: makeThread(id: 10),
        parentPost: parent
      )
    )

    XCTAssertEqual(
      presentation.route,
      TiebaThreadRoute(threadID: 10, postID: 20)
    )
    XCTAssertEqual(presentation.accessibilityHint, "跳转到第 7 楼")
  }

  func testLoadedRouteAcceptsMissingOptionalThreadSummary() throws {
    let presentation = try XCTUnwrap(
      CommentsOriginThreadNavigationPolicy.loadedPresentation(
        presentationContext: .navigation,
        state: .loaded,
        expectedThreadID: 10,
        thread: nil,
        parentPost: makeParentPost(threadID: 10, postID: 20, floor: 0)
      )
    )

    XCTAssertEqual(
      presentation.route,
      TiebaThreadRoute(threadID: 10, postID: 20)
    )
    XCTAssertEqual(presentation.accessibilityHint, "跳转到原帖中的父楼")
  }

  func testLoadedRouteIsSuppressedForSheetAndNonloadedStates() {
    let parent = makeParentPost(threadID: 10, postID: 20)

    XCTAssertTrue(CommentsPresentationContext.sheet.showsDismissButton)
    XCTAssertFalse(CommentsPresentationContext.navigation.showsDismissButton)
    XCTAssertNil(
      CommentsOriginThreadNavigationPolicy.loadedPresentation(
        presentationContext: .sheet,
        state: .loaded,
        expectedThreadID: 10,
        thread: makeThread(id: 10),
        parentPost: parent
      )
    )
    for state in [LoadState.idle, .loading, .failed("unavailable")] {
      XCTAssertNil(
        CommentsOriginThreadNavigationPolicy.loadedPresentation(
          presentationContext: .navigation,
          state: state,
          expectedThreadID: 10,
          thread: makeThread(id: 10),
          parentPost: parent
        )
      )
    }
  }

  func testLoadedRouteRejectsInvalidOrConflictingIdentities() {
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 0,
        parentPost: makeParentPost(threadID: 0, postID: 20)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: -1,
        parentPost: makeParentPost(threadID: -1, postID: 20)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 10,
        parentPost: makeParentPost(threadID: 10, postID: 0)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 10,
        parentPost: makeParentPost(threadID: 10, postID: -1)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 10,
        parentPost: makeParentPost(threadID: 11, postID: 20)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 10,
        thread: makeThread(id: 11),
        parentPost: makeParentPost(threadID: 10, postID: 20)
      )
    )
    XCTAssertNil(
      loadedPresentation(
        expectedThreadID: 10,
        parentPost: nil
      )
    )
  }

  func testLoadedRouteRespectsLocalFiltering() {
    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      XCTAssertNil(
        loadedPresentation(
          expectedThreadID: 10,
          parentPost: makeParentPost(
            threadID: 10,
            postID: 20,
            visibility: visibility
          )
        )
      )
      XCTAssertNil(
        loadedPresentation(
          expectedThreadID: 10,
          thread: makeThread(id: 10, visibility: visibility),
          parentPost: makeParentPost(threadID: 10, postID: 20)
        )
      )
    }
  }

  func testFailureFallbackIsStandaloneRootOnlyAndFailsClosed() {
    let route = CommentsOriginThreadNavigationPolicy.failureFallbackRoute(
      presentationContext: .navigation,
      recordsOwningThreadVisit: true,
      state: .failed("missing comment"),
      threadID: 10
    )
    XCTAssertEqual(route, TiebaThreadRoute(threadID: 10))
    XCTAssertNil(route?.postID)

    XCTAssertNil(
      CommentsOriginThreadNavigationPolicy.failureFallbackRoute(
        presentationContext: .sheet,
        recordsOwningThreadVisit: true,
        state: .failed("missing comment"),
        threadID: 10
      )
    )
    XCTAssertNil(
      CommentsOriginThreadNavigationPolicy.failureFallbackRoute(
        presentationContext: .navigation,
        recordsOwningThreadVisit: false,
        state: .failed("missing comment"),
        threadID: 10
      )
    )
    for state in [LoadState.idle, .loading, .loaded] {
      XCTAssertNil(
        CommentsOriginThreadNavigationPolicy.failureFallbackRoute(
          presentationContext: .navigation,
          recordsOwningThreadVisit: true,
          state: state,
          threadID: 10
        )
      )
    }
    for threadID in [Int64.zero, -1] {
      XCTAssertNil(
        CommentsOriginThreadNavigationPolicy.failureFallbackRoute(
          presentationContext: .navigation,
          recordsOwningThreadVisit: true,
          state: .failed("missing comment"),
          threadID: threadID
        )
      )
    }
  }

  private func loadedPresentation(
    expectedThreadID: Int64,
    thread: BrowseThread? = nil,
    parentPost: CommentParentPostContext?
  ) -> CommentsOriginThreadPresentation? {
    CommentsOriginThreadNavigationPolicy.loadedPresentation(
      presentationContext: .navigation,
      state: .loaded,
      expectedThreadID: expectedThreadID,
      thread: thread,
      parentPost: parentPost
    )
  }
}

private func makeThread(
  id: Int64,
  visibility: LocalContentVisibility = .visible
) -> BrowseThread {
  BrowseThread(
    id: id,
    forumID: 1,
    forumName: "swift",
    title: "thread",
    excerpt: "",
    authorName: "author",
    replyCount: 1,
    viewCount: 1,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [],
    localVisibility: visibility
  )
}

private func makeParentPost(
  threadID: Int64,
  postID: Int64,
  floor: Int = 2,
  visibility: LocalContentVisibility = .visible
) -> CommentParentPostContext {
  CommentParentPostContext(
    id: postID,
    threadID: threadID,
    floor: floor,
    authorID: 1,
    authorName: "author",
    authorPortraitURL: nil,
    createdAt: nil,
    isThreadAuthor: false,
    contents: [],
    localVisibility: visibility
  )
}
