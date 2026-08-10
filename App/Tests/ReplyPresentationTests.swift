import XCTest

@testable import TiebaPlusPlus

final class ReplyPresentationTests: XCTestCase {
  func testReadyPresentationAllowsEditingAndSubmission() {
    let presentation = TextReplyComposerPresentation(state: .ready)

    XCTAssertTrue(presentation.allowsEditing)
    XCTAssertTrue(presentation.allowsSubmission)
    XCTAssertFalse(presentation.allowsVisibilityCheck)
    XCTAssertNil(presentation.status)
  }

  func testSubmittingPresentationPreventsSecondSubmission() {
    let presentation = TextReplyComposerPresentation(state: .submitting(UUID()))

    XCTAssertFalse(presentation.allowsEditing)
    XCTAssertFalse(presentation.allowsSubmission)
    XCTAssertFalse(presentation.allowsVisibilityCheck)
  }

  func testAcceptedPresentationOnlyAllowsVisibilityCheck() {
    let presentation = TextReplyComposerPresentation(
      state: .acceptedAwaitingVisibility(.post(postID: 91))
    )

    XCTAssertFalse(presentation.allowsEditing)
    XCTAssertFalse(presentation.allowsSubmission)
    XCTAssertTrue(presentation.allowsVisibilityCheck)
  }

  func testUnknownChallengeAndAccountChangeNeverAllowResubmission() {
    for state in [
      TextReplySubmissionState.outcomeUnknown,
      .challengeRequired,
      .accountChanged,
    ] {
      let presentation = TextReplyComposerPresentation(state: state)
      XCTAssertFalse(presentation.allowsSubmission)
      XCTAssertFalse(presentation.allowsVisibilityCheck)
    }
  }

  func testMissingFullCredentialsAllowsDraftEditingButNotSubmission() {
    let presentation = TextReplyComposerPresentation(
      state: .failed(.fullCredentialsRequired)
    )

    XCTAssertTrue(presentation.allowsEditing)
    XCTAssertFalse(presentation.allowsSubmission)
  }

  func testCancelledInteractivePopInvalidatesPendingDeactivation() throws {
    var gate = ReplyComposerLifecycleGate()
    _ = gate.beginAppearance()
    XCTAssertTrue(gate.isActive)
    let disappearingLifecycle = try XCTUnwrap(gate.scheduleDeactivation())
    XCTAssertFalse(gate.isActive)

    _ = gate.beginAppearance()

    XCTAssertTrue(gate.isActive)
    XCTAssertFalse(gate.isCurrent(disappearingLifecycle))
    XCTAssertNotNil(gate.scheduleDeactivation())
    XCTAssertNil(gate.scheduleDeactivation())
  }

  func testExactPlainTextProofPreservesWhitespaceAndJoinsOnlyTextFragments() {
    let content = TextReplyVisibilityProof.exactPlainText(
      from: [.text("  first\n"), .text("second  ")]
    )

    XCTAssertEqual(content, "  first\nsecond  ")
  }

  func testExactPlainTextProofRejectsProjectedMentionsAndRichContent() {
    XCTAssertNil(
      TextReplyVisibilityProof.exactPlainText(
        from: [.mention(name: "target", userID: 7), .text(" body")]
      )
    )
    XCTAssertNil(TextReplyVisibilityProof.exactPlainText(from: [.unsupported(label: "unknown")]))
  }

  func testNestedReplyProofUsesStructuredMarkerAndPreservesExactBody() {
    let comment = BrowseComment(
      id: 103,
      authorID: 11,
      authorName: "current-user",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [
        .text("回复 "),
        .mention(name: "target", userID: 9),
        .text(":  first\n"),
        .text("second  "),
      ],
      replyToUserID: 9,
      replyToUserName: "target",
      threadID: 100,
      parentPostID: 102
    )

    XCTAssertEqual(
      TextReplyVisibilityProof.exactNestedReplyBody(
        from: comment,
        expectedReplyToUserID: 9
      ),
      "  first\nsecond  "
    )
  }

  func testNestedReplyProofRejectsWrongTargetOrUnstructuredPrefix() {
    let wrongTarget = BrowseComment(
      id: 103,
      authorID: 11,
      authorName: "current-user",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [
        .text("回复 "),
        .mention(name: "target", userID: 9),
        .text(":body"),
      ],
      replyToUserID: 9,
      threadID: 100,
      parentPostID: 102
    )
    let projectedPrefix = BrowseComment(
      id: 104,
      authorID: 11,
      authorName: "current-user",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("回复 @target:body")],
      replyToUserID: 9,
      threadID: 100,
      parentPostID: 102
    )

    XCTAssertNil(
      TextReplyVisibilityProof.exactNestedReplyBody(
        from: wrongTarget,
        expectedReplyToUserID: 8
      )
    )
    XCTAssertNil(
      TextReplyVisibilityProof.exactNestedReplyBody(
        from: projectedPrefix,
        expectedReplyToUserID: 9
      )
    )
  }

  func testNestedReplyProofAcceptsProtocolDelimiterSpaceWithoutTrimmingBody() {
    let comment = BrowseComment(
      id: 105,
      authorID: 11,
      authorName: "current-user",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [
        .text("回复 "),
        .mention(name: "target", userID: 9),
        .text(" : body"),
      ],
      replyToUserID: 9,
      threadID: 100,
      parentPostID: 102
    )

    XCTAssertEqual(
      TextReplyVisibilityProof.exactNestedReplyBody(
        from: comment,
        expectedReplyToUserID: 9
      ),
      " body"
    )
  }

  func testFirstFloorParentComposerRepliesToThreadInsteadOfPostingUnderFirstFloor() throws {
    let thread = makeThread(firstPostID: 101)
    let parent = makeParentPost(id: 101, threadID: thread.id, floor: 1)

    let context = try XCTUnwrap(TextReplyComposerContext(thread: thread, parentPost: parent))

    XCTAssertEqual(context.kind, .thread)
    XCTAssertEqual(context.composerTitle, "回复主题")
    XCTAssertEqual(context.target.destination, .thread(firstPostID: parent.id))
  }

  func testOrdinaryParentAndNestedCommentHaveSpecificComposerTitles() throws {
    let thread = makeThread(firstPostID: 101)
    let parent = makeParentPost(id: 102, threadID: thread.id, floor: 2)
    let comment = BrowseComment(
      id: 103,
      authorID: 9,
      authorName: "nested-author",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("nested")],
      threadID: thread.id,
      parentPostID: parent.id
    )

    let parentContext = try XCTUnwrap(
      TextReplyComposerContext(thread: thread, parentPost: parent)
    )
    let nestedContext = try XCTUnwrap(
      TextReplyComposerContext(
        thread: thread,
        parentPostID: parent.id,
        comment: comment
      )
    )

    XCTAssertEqual(parentContext.composerTitle, "回复第 2 楼")
    XCTAssertEqual(nestedContext.composerTitle, "回复 nested-author")
  }

  private func makeThread(firstPostID: Int64) -> BrowseThread {
    BrowseThread(
      id: 100,
      forumID: 10,
      forumName: "Swift",
      title: "Thread",
      excerpt: "",
      authorName: "author",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("thread")],
      firstPostID: firstPostID
    )
  }

  private func makeParentPost(
    id: Int64,
    threadID: Int64,
    floor: Int
  ) -> CommentParentPostContext {
    CommentParentPostContext(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: 8,
      authorName: "parent-author",
      authorPortraitURL: nil,
      createdAt: nil,
      isThreadAuthor: floor == 1,
      contents: [.text("parent")]
    )
  }
}
