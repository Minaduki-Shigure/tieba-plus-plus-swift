import XCTest

@testable import TiebaPlusPlus

final class ReplyModelsTests: XCTestCase {
  func testDesignatedTargetInitializerKeepsFirstPostParentDistinctFromItsSubposts() throws {
    let thread = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "  e\u{301}  ",
        threadID: 70,
        firstPostID: 700,
        destination: .thread(firstPostID: 700)
      )
    )
    XCTAssertEqual(thread.forumName, "\u{e9}")
    XCTAssertEqual(thread.firstPostID, 700)

    XCTAssertNil(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 70,
        firstPostID: 700,
        destination: .thread(firstPostID: 701)
      )
    )
    XCTAssertNil(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 70,
        firstPostID: 700,
        destination: .post(postID: 700)
      )
    )
    XCTAssertEqual(
      try XCTUnwrap(
        TextReplyTarget(
          forumID: 7,
          forumName: "swift",
          threadID: 70,
          firstPostID: 700,
          destination: .subpost(parentPostID: 700, subpostID: 702)
        )
      ).destination,
      .subpost(parentPostID: 700, subpostID: 702)
    )
    XCTAssertNil(
      TextReplyTarget(
        forumID: 7,
        forumName: "swift",
        threadID: 70,
        firstPostID: 700,
        destination: .subpost(parentPostID: 700, subpostID: 700)
      )
    )
  }

  func testBrowseFactoriesBindExactThreadAndRejectFirstPostAsPost() throws {
    let thread = replyThread()
    let firstPost = replyPost(id: 700, threadID: 70, floor: 1)
    let secondPost = replyPost(id: 701, threadID: 70, floor: 2)

    XCTAssertEqual(
      try XCTUnwrap(TextReplyTarget(thread: thread, firstPost: firstPost)).destination,
      .thread(firstPostID: 700)
    )
    XCTAssertNil(TextReplyTarget(thread: thread, post: firstPost))
    XCTAssertEqual(
      try XCTUnwrap(TextReplyTarget(thread: thread, post: secondPost)).destination,
      .post(postID: 701)
    )
    XCTAssertNil(
      TextReplyTarget(
        thread: thread,
        post: replyPost(id: 701, threadID: 71, floor: 2)
      )
    )

    let firstParent = replyParentPost(id: 700, floor: 1)
    let secondParent = replyParentPost(id: 701, floor: 2)
    XCTAssertNil(TextReplyTarget(thread: thread, parentPost: firstParent))
    XCTAssertEqual(
      try XCTUnwrap(TextReplyTarget(thread: thread, parentPost: secondParent)).destination,
      .post(postID: 701)
    )
  }

  func testSubpostFactoryAcceptsFirstParentAndRequiresExactParentAndThread() throws {
    let thread = replyThread()
    let comment = replyComment(id: 702, threadID: 70, parentPostID: 701)
    XCTAssertEqual(
      try XCTUnwrap(
        TextReplyTarget(thread: thread, parentPostID: 701, comment: comment)
      ).destination,
      .subpost(parentPostID: 701, subpostID: 702)
    )
    let firstFloorComment = replyComment(id: 703, threadID: 70, parentPostID: 700)
    XCTAssertEqual(
      try XCTUnwrap(
        TextReplyTarget(thread: thread, parentPostID: 700, comment: firstFloorComment)
      ).destination,
      .subpost(parentPostID: 700, subpostID: 703)
    )
    XCTAssertEqual(
      try XCTUnwrap(
        TextReplyComposerContext(
          thread: thread,
          parentPostID: 700,
          comment: firstFloorComment
        )
      ).kind,
      .subpost
    )
    XCTAssertNil(TextReplyTarget(thread: thread, parentPostID: 700, comment: comment))
    XCTAssertNil(
      TextReplyTarget(
        thread: thread,
        parentPostID: 701,
        comment: replyComment(id: 702, threadID: 71, parentPostID: 701)
      )
    )
    XCTAssertNil(
      TextReplyTarget(
        thread: thread,
        parentPostID: 701,
        comment: replyComment(id: 702, threadID: 70, parentPostID: 703)
      )
    )
  }

  func testExactPostSubpostFactoryRequiresCurrentCommentSnapshot() throws {
    let thread = replyThread()
    let comment = replyComment(id: 702, threadID: 70, parentPostID: 701)
    let parent = replyPost(
      id: 701,
      threadID: 70,
      floor: 2,
      inlineComments: [comment]
    )

    let context = try XCTUnwrap(
      TextReplyComposerContext(
        thread: thread,
        parentPost: parent,
        comment: comment
      )
    )
    XCTAssertEqual(
      context.target.destination,
      .subpost(parentPostID: 701, subpostID: 702)
    )
    XCTAssertEqual(context.replyingToUserID, comment.authorID)
    XCTAssertNil(
      TextReplyComposerContext(
        thread: thread,
        parentPost: parent,
        comment: replyComment(id: 703, threadID: 70, parentPostID: 701)
      )
    )
  }

  func testComposerContextKeepsDisplayMetadataOutOfTargetIdentity() throws {
    let thread = replyThread()
    let first = try XCTUnwrap(
      TextReplyComposerContext(
        thread: thread,
        firstPost: replyPost(id: 700, threadID: 70, floor: 1)
      )
    )
    XCTAssertEqual(first.kind, .thread)
    XCTAssertNil(first.floor)
    XCTAssertNil(first.replyingToName)

    let post = try XCTUnwrap(
      TextReplyComposerContext(
        thread: thread,
        post: replyPost(
          id: 701,
          threadID: 70,
          floor: 2,
          authorName: "  Alice  ",
          authorUsername: "alice-id"
        )
      )
    )
    XCTAssertEqual(post.kind, .post)
    XCTAssertEqual(post.floor, 2)
    XCTAssertEqual(post.replyingToName, "Alice")
    XCTAssertEqual(post.target.destination, .post(postID: 701))
  }

  func testFirstFloorParentComposerMapsToThreadWithoutRelaxingPostTarget() throws {
    let thread = replyThread()
    let firstParent = replyParentPost(id: 700, floor: 1)

    XCTAssertNil(TextReplyTarget(thread: thread, parentPost: firstParent))
    let context = try XCTUnwrap(
      TextReplyComposerContext(thread: thread, parentPost: firstParent)
    )
    XCTAssertEqual(context.kind, .thread)
    XCTAssertEqual(context.target.destination, .thread(firstPostID: 700))
    XCTAssertNil(context.floor)
    XCTAssertNil(context.replyingToName)
  }

  func testContentPolicyPreservesRawTextAndRejectsUnsafeInput() throws {
    let raw = "  第一行\nCafe\u{301}\t末尾  "
    XCTAssertTrue(TextReplyContentPolicy.isValid(raw))
    XCTAssertEqual(try XCTUnwrap(TextReplySubmission(target: replyTarget(), content: raw)).content, raw)

    XCTAssertFalse(TextReplyContentPolicy.isValid(" \n\t "))
    XCTAssertFalse(TextReplyContentPolicy.isValid("文本 #(pic,1,2,3)"))
    XCTAssertFalse(TextReplyContentPolicy.isValid("a\u{0}b"))
    XCTAssertFalse(
      TextReplyContentPolicy.isValid(
        String(repeating: "a", count: TextReplyContentPolicy.maximumCharacterCount + 1)
      )
    )
    XCTAssertFalse(
      TextReplyContentPolicy.isValid(
        String(repeating: "你", count: TextReplyContentPolicy.maximumUTF8ByteCount / 3 + 1)
      )
    )
  }

  func testDirectThreadReplySupportsOrderedImageOnlyAndNineImageBoundary() throws {
    let target = replyTarget()
    let attachments = (1...ComposerImageDraftPolicy.maximumAttachmentCount).map {
      replyModelAttachment(UInt8($0))
    }
    let imageOnly = try XCTUnwrap(
      TextReplySubmission(
        id: replyModelUUID(20),
        target: target,
        content: "",
        attachments: attachments
      )
    )
    let textAndImages = try XCTUnwrap(
      TextReplySubmission(
        id: replyModelUUID(21),
        target: target,
        content: "正文 #(滑稽)",
        attachments: Array(attachments.reversed())
      )
    )
    let reorderedIdentity = try XCTUnwrap(
      TextReplySubmission(
        id: imageOnly.id,
        target: target,
        content: "",
        attachments: Array(attachments.reversed())
      )
    )

    XCTAssertEqual(imageOnly.attachments, attachments)
    XCTAssertEqual(textAndImages.attachments, Array(attachments.reversed()))
    XCTAssertNotEqual(imageOnly, reorderedIdentity)
    XCTAssertEqual(Set([imageOnly, reorderedIdentity]).count, 2)
    XCTAssertNil(
      TextReplySubmission(
        target: target,
        content: "",
        attachments: attachments + [replyModelAttachment(10)]
      )
    )
    XCTAssertNil(
      TextReplySubmission(
        target: target,
        content: "",
        attachments: [attachments[0], attachments[0]]
      )
    )
  }

  func testReplyImagesRejectNonThreadTargetsWithoutMakingEditingDraftLossy() {
    let attachment = replyModelAttachment(1)

    XCTAssertNil(
      TextReplySubmission(
        target: replyTarget(destination: .post(postID: 701)),
        content: "正文",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplySubmission(
        target: replyTarget(
          destination: .subpost(parentPostID: 701, subpostID: 702)
        ),
        content: "正文",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplySubmission(
        target: replyTarget(),
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplySubmission(
        target: replyTarget(),
        content: " \n\t ",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplySubmission(
        target: replyTarget(),
        content: String(
          repeating: "a",
          count: TextReplyContentPolicy.maximumCharacterCount - 1
        ),
        attachments: [attachment]
      )
    )
    let key = TextReplyDraftKey(userID: 9, target: replyTarget())!
    XCTAssertNotNil(
      TextReplyDraft(
        key: key,
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment]
      )
    )
    XCTAssertNotNil(
      TextReplyDraft(
        key: key,
        content: String(
          repeating: "a",
          count: TextReplyContentPolicy.maximumCharacterCount + 1
        ),
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplyDraft(
        key: key,
        content: "文本 #(pic,1,2,3)",
        attachments: [attachment],
        disposition: .submissionPending(submissionID: UUID())
      )
    )
  }

  func testOutcomesRequireExactTargetShape() throws {
    let threadTarget = replyTarget(destination: .thread(firstPostID: 700))
    let postTarget = replyTarget(destination: .post(postID: 701))
    let subpostTarget = replyTarget(
      destination: .subpost(parentPostID: 701, subpostID: 702)
    )
    let submissionID = UUID()

    XCTAssertNotNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: threadTarget,
        outcome: .confirmed(.post(postID: 703, floor: 3))
      )
    )
    XCTAssertNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: threadTarget,
        outcome: .confirmed(.post(postID: 700, floor: 1))
      )
    )
    XCTAssertNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: threadTarget,
        outcome: .confirmed(.post(postID: 703, floor: 1))
      )
    )
    XCTAssertNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: threadTarget,
        outcome: .confirmed(.subpost(parentPostID: 701, subpostID: 703))
      )
    )
    XCTAssertNotNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: postTarget,
        outcome: .acceptedAwaitingVisibility(
          .subpost(parentPostID: 701, subpostID: 703)
        )
      )
    )
    XCTAssertNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: subpostTarget,
        outcome: .acceptedAwaitingVisibility(
          .subpost(parentPostID: 704, subpostID: 705)
        )
      )
    )
    XCTAssertNil(
      TextReplyResult(
        submissionID: submissionID,
        userID: 9,
        target: subpostTarget,
        outcome: .acceptedAwaitingVisibility(
          .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )
  }

  func testDraftKeySeparatesAccountsAndExactDestinations() throws {
    let thread = replyTarget(destination: .thread(firstPostID: 700))
    let post = replyTarget(destination: .post(postID: 701))
    let firstUserThread = try XCTUnwrap(TextReplyDraftKey(userID: 1, target: thread))
    let secondUserThread = try XCTUnwrap(TextReplyDraftKey(userID: 2, target: thread))
    let firstUserPost = try XCTUnwrap(TextReplyDraftKey(userID: 1, target: post))

    XCTAssertNotEqual(firstUserThread, secondUserThread)
    XCTAssertNotEqual(firstUserThread, firstUserPost)
    XCTAssertEqual(firstUserThread.firstPostID, 700)
  }

  func testPendingDraftRejectsReceiptsThatReuseTheRepliedObject() throws {
    let submissionID = UUID()
    let threadKey = try XCTUnwrap(
      TextReplyDraftKey(
        userID: 9,
        target: replyTarget(destination: .thread(firstPostID: 700))
      )
    )
    XCTAssertNil(
      TextReplyDraft(
        key: threadKey,
        content: "正文",
        disposition: .acceptedAwaitingVisibility(
          submissionID: submissionID,
          receipt: .post(postID: 700)
        )
      )
    )

    let subpostKey = try XCTUnwrap(
      TextReplyDraftKey(
        userID: 9,
        target: replyTarget(
          destination: .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )
    XCTAssertNil(
      TextReplyDraft(
        key: subpostKey,
        content: "正文",
        disposition: .acceptedAwaitingVisibility(
          submissionID: submissionID,
          receipt: .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )
  }

  func testChallengeTombstoneMayClearContentWithoutBecomingEditingDraft() throws {
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    XCTAssertNil(TextReplyDraft(key: key, content: ""))
    let tombstone = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "",
        disposition: .challengeRequired(
          submissionID: UUID(),
          sessionRevision: UUID()
        )
      )
    )
    XCTAssertEqual(tombstone.content, "")
    guard case .challengeRequired = tombstone.disposition else {
      XCTFail("Expected a persisted challenge tombstone")
      return
    }
  }

  func testDraftBindsImagesOnlyToDirectThreadTargetAndPreservesOrderInIdentity() throws {
    let threadKey = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    let postKey = try XCTUnwrap(
      TextReplyDraftKey(
        userID: 9,
        target: replyTarget(destination: .post(postID: 701))
      )
    )
    let subpostKey = try XCTUnwrap(
      TextReplyDraftKey(
        userID: 9,
        target: replyTarget(
          destination: .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )
    let first = replyModelAttachment(1)
    let second = replyModelAttachment(2)
    let date = Date(timeIntervalSince1970: 100)
    let imageOnly = try XCTUnwrap(
      TextReplyDraft(
        key: threadKey,
        content: "",
        attachments: [first, second],
        updatedAt: date
      )
    )
    let reordered = try XCTUnwrap(
      TextReplyDraft(
        key: threadKey,
        content: "",
        attachments: [second, first],
        updatedAt: date
      )
    )

    XCTAssertEqual(imageOnly.attachments, [first, second])
    XCTAssertNotEqual(imageOnly, reordered)
    XCTAssertEqual(Set([imageOnly, reordered]).count, 2)
    XCTAssertNil(TextReplyDraft(key: postKey, content: "正文", attachments: [first]))
    XCTAssertNil(TextReplyDraft(key: subpostKey, content: "正文", attachments: [first]))
    XCTAssertNil(TextReplyDraft(key: threadKey, content: "", attachments: [first, first]))
    XCTAssertNil(
      TextReplyDraft(
        key: threadKey,
        content: "#(pic,1,2,3)",
        attachments: [first],
        disposition: .submissionPending(submissionID: UUID())
      )
    )
  }

  func testPureTextDraftDispositionsRejectImageAttachments() throws {
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    let attachment = replyModelAttachment(1)
    let submissionID = replyModelUUID(20)
    let sessionRevision = replyModelUUID(21)
    let dispositions: [TextReplyDraftDisposition] = [
      .submissionPending(submissionID: submissionID),
      .challengeRequired(submissionID: submissionID, sessionRevision: sessionRevision),
      .acceptedAwaitingVisibility(
        submissionID: submissionID,
        receipt: .post(postID: 701)
      ),
      .outcomeUnknown(submissionID: submissionID),
    ]

    for disposition in dispositions {
      XCTAssertNil(
        TextReplyDraft(
          key: key,
          content: "正文",
          attachments: [attachment],
          disposition: disposition
        )
      )
    }
  }

  func testImageDraftStatesRequireNonemptyValidAttachments() throws {
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: replyModelUUID(20),
        sessionRevision: replyModelUUID(21)
      )
    )
    let attachment = replyModelAttachment(1)
    let dispositions: [TextReplyDraftDisposition] = [
      .imagePreparationPending(reference: reference),
      .imagePipeline(reference: reference),
      .imageAcceptedAwaitingVisibility(
        reference: reference,
        receipt: .post(postID: 701)
      ),
      .imageConfirmed(
        reference: reference,
        created: .post(postID: 701, floor: 2)
      ),
    ]

    for disposition in dispositions {
      XCTAssertNil(
        TextReplyDraft(key: key, content: "正文", disposition: disposition)
      )
      XCTAssertNil(
        TextReplyDraft(
          key: key,
          content: "正文",
          attachments: [attachment, attachment],
          disposition: disposition
        )
      )
      let draft = try XCTUnwrap(
        TextReplyDraft(
          key: key,
          content: "正文",
          attachments: [attachment],
          disposition: disposition
        )
      )
      XCTAssertEqual(draft.disposition.imageSubmissionReference, reference)
    }
  }

  func testImageAcceptedDraftRequiresReceiptForExactDirectThreadTarget() throws {
    let threadKey = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: replyModelUUID(20),
        sessionRevision: replyModelUUID(21)
      )
    )
    let attachment = replyModelAttachment(1)

    XCTAssertNotNil(
      TextReplyDraft(
        key: threadKey,
        content: "",
        attachments: [attachment],
        disposition: .imageAcceptedAwaitingVisibility(
          reference: reference,
          receipt: .post(postID: 701)
        )
      )
    )
    for receipt in [
      TextReplyReceipt.post(postID: 0),
      .post(postID: 700),
      .subpost(parentPostID: 701, subpostID: 702),
    ] {
      XCTAssertNil(
        TextReplyDraft(
          key: threadKey,
          content: "",
          attachments: [attachment],
          disposition: .imageAcceptedAwaitingVisibility(
            reference: reference,
            receipt: receipt
          )
        )
      )
    }
  }

  func testImageConfirmedDraftRequiresCreatedReplyForExactDirectThreadTarget() throws {
    let threadKey = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: replyTarget()))
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: replyModelUUID(20),
        sessionRevision: replyModelUUID(21)
      )
    )
    let attachment = replyModelAttachment(1)

    let confirmed = try XCTUnwrap(
      TextReplyDraft(
        key: threadKey,
        content: "正文",
        attachments: [attachment],
        disposition: .imageConfirmed(
          reference: reference,
          created: .post(postID: 701, floor: 2)
        )
      )
    )
    XCTAssertEqual(confirmed.disposition.imageSubmissionReference, reference)
    for created in [
      CreatedTextReply.post(postID: 0, floor: 2),
      .post(postID: 700, floor: 2),
      .subpost(parentPostID: 701, subpostID: 702),
    ] {
      XCTAssertNil(
        TextReplyDraft(
          key: threadKey,
          content: "正文",
          attachments: [attachment],
          disposition: .imageConfirmed(reference: reference, created: created)
        )
      )
    }
  }

  func testVisibilityConfirmationRequiresValidAuthorContentAndCreatedReply() {
    let attachment = replyModelAttachment(20)
    XCTAssertNotNil(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 703, floor: 3),
        authorUserID: 9,
        content: "正文"
      )
    )
    let imageOnlyConfirmation = TextReplyVisibilityConfirmation(
      created: .post(postID: 704, floor: 4),
      authorUserID: 9,
      content: "",
      attachments: [attachment]
    )
    XCTAssertEqual(imageOnlyConfirmation?.attachments, [attachment])
    XCTAssertNil(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 704, floor: 4),
        authorUserID: 9,
        content: " \n\t ",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplyVisibilityConfirmation(
        created: .subpost(parentPostID: 703, subpostID: 704),
        authorUserID: 9,
        content: "正文",
        attachments: [attachment]
      )
    )
    XCTAssertNil(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 0, floor: 3),
        authorUserID: 9,
        content: "正文"
      )
    )
    XCTAssertNil(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 703, floor: 3),
        authorUserID: 0,
        content: "正文"
      )
    )
    XCTAssertNil(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 703, floor: 3),
        authorUserID: 9,
        content: "   "
      )
    )
  }

  func testSensitiveReplyModelsRedactContentAndForumFromStringsAndMirrors() throws {
    let target = try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "secret-forum-name",
        threadID: 70,
        firstPostID: 700,
        destination: .thread(firstPostID: 700)
      )
    )
    let attachment = replyModelAttachment(30)
    let submission = try XCTUnwrap(
      TextReplySubmission(
        target: target,
        content: "secret-reply-content",
        attachments: [attachment]
      )
    )
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: target))
    let draft = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "secret-draft-content",
        attachments: [attachment]
      )
    )
    let confirmation = try XCTUnwrap(
      TextReplyVisibilityConfirmation(
        created: .post(postID: 701, floor: 2),
        authorUserID: 9,
        content: "secret-proof-content"
      )
    )

    let sensitiveValues: [Any] = [target, submission, draft, confirmation]
    for value in sensitiveValues {
      let description = String(describing: value)
      let debugDescription = String(reflecting: value)
      XCTAssertFalse(description.contains("secret"))
      XCTAssertFalse(debugDescription.contains("secret"))
      XCTAssertFalse(description.contains(attachment.sha256))
      XCTAssertFalse(debugDescription.contains(attachment.sha256))
      XCTAssertFalse(description.contains(attachment.relativePrivateFilename))
      XCTAssertFalse(debugDescription.contains(attachment.relativePrivateFilename))
      XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
    }
  }
}

private func replyThread() -> BrowseThread {
  BrowseThread(
    id: 70,
    forumID: 7,
    forumName: "swift",
    title: "Thread",
    excerpt: "",
    authorName: "Author",
    replyCount: 2,
    viewCount: 3,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [.text("first")],
    firstPostID: 700
  )
}

private func replyPost(
  id: Int64,
  threadID: Int64,
  floor: Int,
  authorName: String = "Author",
  authorUsername: String = "author-id",
  inlineComments: [BrowseComment] = []
) -> BrowsePost {
  BrowsePost(
    id: id,
    threadID: threadID,
    floor: floor,
    authorID: 9,
    authorName: authorName,
    authorPortraitURL: nil,
    createdAt: nil,
    nestedReplyCount: 0,
    isThreadAuthor: floor == 1,
    contents: [.text("post")],
    authorUsername: authorUsername,
    inlineComments: inlineComments
  )
}

private func replyParentPost(id: Int64, floor: Int) -> CommentParentPostContext {
  CommentParentPostContext(
    id: id,
    threadID: 70,
    floor: floor,
    authorID: 9,
    authorName: "Author",
    authorPortraitURL: nil,
    createdAt: nil,
    isThreadAuthor: floor == 1,
    contents: [.text("parent")]
  )
}

private func replyComment(
  id: Int64,
  threadID: Int64,
  parentPostID: Int64
) -> BrowseComment {
  BrowseComment(
    id: id,
    authorID: 10,
    authorName: "Commenter",
    authorPortraitURL: nil,
    createdAt: nil,
    contents: [.text("comment")],
    threadID: threadID,
    parentPostID: parentPostID
  )
}

private func replyTarget(
  destination: TextReplyTarget.Destination = .thread(firstPostID: 700)
) -> TextReplyTarget {
  TextReplyTarget(
    forumID: 7,
    forumName: "swift",
    threadID: 70,
    firstPostID: 700,
    destination: destination
  )!
}

private func replyModelUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func replyModelAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: replyModelUUID(value),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(100 + Int(value)),
    pixelWidth: 20,
    pixelHeight: 10,
    quality: .standard
  )!
}
