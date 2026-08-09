import XCTest

@testable import TiebaPlusPlus

final class InboxReplyIntentTests: XCTestCase {
  func testInitializerBindsStableAccountAndNotificationIdentity() throws {
    let revision = uuid(1)
    let account = session(userID: 41, revision: revision)
    let intent = try XCTUnwrap(
      InboxReplyIntent(message: message(), session: account)
    )

    XCTAssertEqual(intent.userID, 41)
    XCTAssertEqual(intent.accountID, 41)
    XCTAssertEqual(intent.sessionRevision, revision)
    XCTAssertEqual(intent.threadID, 70)
    XCTAssertEqual(intent.senderUserID, 9)
    XCTAssertEqual(intent.target, .post(id: 701))
    XCTAssertEqual(intent.targetID, 701)
    let leaseIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(),
        userID: 41,
        sessionRevision: revision
      )
    )
    XCTAssertEqual(intent, leaseIntent)

    XCTAssertNil(InboxReplyIntent(message: message(messageID: 702), session: account))
    XCTAssertNil(InboxReplyIntent(message: message(threadID: 0), session: account))
    XCTAssertNil(InboxReplyIntent(message: message(postID: 0), session: account))
    XCTAssertNil(InboxReplyIntent(message: message(senderUserID: 0), session: account))
    XCTAssertNil(
      InboxReplyIntent(message: message(), session: session(userID: 0, revision: revision))
    )
    XCTAssertNil(
      InboxReplyIntent(message: message(), userID: 0, sessionRevision: revision)
    )
  }

  func testQuotePostIDAndDisplayContentCannotInfluenceOrLeakFromIntent() throws {
    let account = session(userID: 41, revision: uuid(2))
    let first = try XCTUnwrap(
      InboxReplyIntent(
        message: message(
          quotePostID: 700,
          title: "secret-title",
          content: "secret-content",
          senderName: "secret-sender"
        ),
        session: account
      )
    )
    let second = try XCTUnwrap(
      InboxReplyIntent(
        message: message(
          quotePostID: 99_999,
          title: "different-secret-title",
          content: "different-secret-content",
          senderName: "different-secret-sender"
        ),
        session: account
      )
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(Set([first, second]).count, 1)
    requireSendable(first)

    let redactedValues: [Any] = [first, first.target]
    for value in redactedValues {
      XCTAssertFalse(String(describing: value).contains("secret"))
      XCTAssertFalse(String(reflecting: value).contains("secret"))
      XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
    }
  }

  func testSessionBindingRequiresBothUserAndRevision() throws {
    let revision = uuid(3)
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(),
        session: session(userID: 41, revision: revision)
      )
    )

    XCTAssertTrue(intent.isBound(to: session(userID: 41, revision: revision)))
    XCTAssertFalse(intent.isBound(to: session(userID: 42, revision: revision)))
    XCTAssertFalse(intent.isBound(to: session(userID: 41, revision: uuid(4))))
  }

  func testPostResolutionReturnsComposerForExactModels() throws {
    let account = session(userID: 41, revision: uuid(5))
    let intent = try XCTUnwrap(
      InboxReplyIntent(message: message(), session: account)
    )
    let context = try XCTUnwrap(
      intent.composerContext(
        session: account,
        thread: thread(),
        post: post()
      )
    )

    XCTAssertEqual(context.kind, .post)
    XCTAssertEqual(context.floor, 2)
    XCTAssertEqual(context.replyingToName, "Sender")
    XCTAssertEqual(context.target.destination, .post(postID: 701))
  }

  func testPostResolutionUsesCanonicalModelsRatherThanFirstPostHint() throws {
    let account = session(userID: 41, revision: uuid(11))
    let firstPostIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(postID: 700, isFirstPost: false),
        session: account
      )
    )
    let firstPostContext = try XCTUnwrap(
      firstPostIntent.composerContext(
        session: account,
        thread: thread(),
        post: post(id: 700, floor: 1)
      )
    )

    XCTAssertEqual(firstPostContext.kind, .thread)
    XCTAssertEqual(firstPostContext.target.destination, .thread(firstPostID: 700))

    let ordinaryPostIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(isFirstPost: true),
        session: account
      )
    )
    let ordinaryPostContext = try XCTUnwrap(
      ordinaryPostIntent.composerContext(
        session: account,
        thread: thread(),
        post: post()
      )
    )
    XCTAssertEqual(ordinaryPostContext.kind, .post)
  }

  func testPostResolutionRejectsEveryMismatchedIdentityBoundary() throws {
    let account = session(userID: 41, revision: uuid(6))
    let intent = try XCTUnwrap(
      InboxReplyIntent(message: message(), session: account)
    )

    XCTAssertNil(
      intent.composerContext(
        session: session(userID: 41, revision: uuid(7)),
        thread: thread(),
        post: post()
      )
    )
    XCTAssertNil(
      intent.composerContext(session: account, thread: thread(id: 71), post: post())
    )
    XCTAssertNil(
      intent.composerContext(session: account, thread: thread(), post: post(id: 702))
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        post: post(threadID: 71)
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        post: post(authorUserID: 10)
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        post: post(id: 701, floor: 1)
      )
    )
  }

  func testPostResolutionRejectsLocallyNonvisibleThreadOrPost() throws {
    let account = session(userID: 41, revision: uuid(12))
    let intent = try XCTUnwrap(
      InboxReplyIntent(message: message(), session: account)
    )

    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      XCTAssertNil(
        intent.composerContext(
          session: account,
          thread: thread(localVisibility: visibility),
          post: post()
        )
      )
      XCTAssertNil(
        intent.composerContext(
          session: account,
          thread: thread(),
          post: post(localVisibility: visibility)
        )
      )
    }
  }

  func testSubpostResolutionReturnsComposerForExactModels() throws {
    let account = session(userID: 41, revision: uuid(8))
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(postID: 702, isFloorReply: true),
        session: account
      )
    )
    let context = try XCTUnwrap(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment()
      )
    )

    XCTAssertEqual(intent.target, .subpost(id: 702))
    XCTAssertEqual(context.kind, .subpost)
    XCTAssertEqual(context.replyingToName, "Sender")
    XCTAssertEqual(
      context.target.destination,
      .subpost(parentPostID: 701, subpostID: 702)
    )
  }

  func testSubpostResolutionRejectsEveryMismatchedIdentityBoundary() throws {
    let account = session(userID: 41, revision: uuid(9))
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(postID: 702, isFloorReply: true),
        session: account
      )
    )

    XCTAssertNil(
      intent.composerContext(
        session: session(userID: 42, revision: account.sessionRevision),
        thread: thread(),
        parentPost: parentPost(),
        comment: comment()
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(id: 71),
        parentPost: parentPost(),
        comment: comment()
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(threadID: 71),
        comment: comment()
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(id: 703),
        comment: comment()
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment(id: 703)
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment(threadID: 71)
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment(parentPostID: 700)
      )
    )
    XCTAssertNil(
      intent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment(authorUserID: 10)
      )
    )
  }

  func testSubpostResolutionRejectsEveryLocallyNonvisibleModel() throws {
    let account = session(userID: 41, revision: uuid(13))
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(postID: 702, isFloorReply: true),
        session: account
      )
    )

    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      XCTAssertNil(
        intent.composerContext(
          session: account,
          thread: thread(localVisibility: visibility),
          parentPost: parentPost(),
          comment: comment()
        )
      )
      XCTAssertNil(
        intent.composerContext(
          session: account,
          thread: thread(),
          parentPost: parentPost(localVisibility: visibility),
          comment: comment()
        )
      )
      XCTAssertNil(
        intent.composerContext(
          session: account,
          thread: thread(),
          parentPost: parentPost(),
          comment: comment(localVisibility: visibility)
        )
      )
    }
  }

  func testPostAndSubpostResolversCannotCrossTargetKinds() throws {
    let account = session(userID: 41, revision: uuid(10))
    let postIntent = try XCTUnwrap(
      InboxReplyIntent(message: message(), session: account)
    )
    let subpostIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(postID: 702, isFloorReply: true),
        session: account
      )
    )

    XCTAssertNil(
      postIntent.composerContext(
        session: account,
        thread: thread(),
        parentPost: parentPost(),
        comment: comment(id: 701)
      )
    )
    XCTAssertNil(
      subpostIntent.composerContext(
        session: account,
        thread: thread(),
        post: post(id: 702)
      )
    )
  }
}

private func requireSendable<T: Sendable>(_ value: T) {}

private func session(userID: Int64, revision: UUID) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "account-name",
    displayName: "Account Name",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    stoken: String(repeating: "s", count: 64),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func message(
  messageID: Int64? = nil,
  threadID: Int64 = 70,
  postID: Int64 = 701,
  senderUserID: Int64 = 9,
  quotePostID: Int64? = nil,
  isFloorReply: Bool = false,
  isFirstPost: Bool = false,
  title: String = "Thread",
  content: String = "Reply",
  senderName: String = "Sender"
) -> InboxMessage {
  InboxMessage(
    id: messageID ?? postID,
    sender: InboxSender(
      id: senderUserID,
      username: "sender-id",
      displayName: senderName,
      portraitURL: nil,
      isFriend: false,
      isFan: false
    ),
    quotedUser: nil,
    threadID: threadID,
    postID: postID,
    quotedPostID: quotePostID,
    title: title,
    content: content,
    quotedContent: "quoted-secret-content",
    forumName: "secret-forum-name",
    createdAt: Date(timeIntervalSince1970: 3),
    isFloorReply: isFloorReply,
    isFirstPost: isFirstPost,
    isUnread: true,
    threadType: 0
  )
}

private func thread(
  id: Int64 = 70,
  localVisibility: LocalContentVisibility = .visible
) -> BrowseThread {
  BrowseThread(
    id: id,
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
    firstPostID: 700,
    localVisibility: localVisibility
  )
}

private func post(
  id: Int64 = 701,
  threadID: Int64 = 70,
  floor: Int = 2,
  authorUserID: Int64 = 9,
  localVisibility: LocalContentVisibility = .visible
) -> BrowsePost {
  BrowsePost(
    id: id,
    threadID: threadID,
    floor: floor,
    authorID: authorUserID,
    authorName: "Sender",
    authorPortraitURL: nil,
    createdAt: nil,
    nestedReplyCount: 0,
    isThreadAuthor: false,
    contents: [.text("post")],
    localVisibility: localVisibility
  )
}

private func parentPost(
  id: Int64 = 701,
  threadID: Int64 = 70,
  floor: Int = 2,
  localVisibility: LocalContentVisibility = .visible
) -> CommentParentPostContext {
  CommentParentPostContext(
    id: id,
    threadID: threadID,
    floor: floor,
    authorID: 8,
    authorName: "Parent Author",
    authorPortraitURL: nil,
    createdAt: nil,
    isThreadAuthor: false,
    contents: [.text("parent")],
    localVisibility: localVisibility
  )
}

private func comment(
  id: Int64 = 702,
  threadID: Int64 = 70,
  parentPostID: Int64 = 701,
  authorUserID: Int64 = 9,
  localVisibility: LocalContentVisibility = .visible
) -> BrowseComment {
  BrowseComment(
    id: id,
    authorID: authorUserID,
    authorName: "Sender",
    authorPortraitURL: nil,
    createdAt: nil,
    contents: [.text("comment")],
    localVisibility: localVisibility,
    threadID: threadID,
    parentPostID: parentPostID
  )
}

private func uuid(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}
