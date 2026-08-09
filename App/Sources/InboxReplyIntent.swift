import Foundation

enum InboxReplyIntentAdmissionPolicy {
  static func admittedIntent(
    _ intent: InboxReplyIntent?,
    hidesReplyEntryPoints: Bool
  ) -> InboxReplyIntent? {
    guard
      ReplyEntryVisibilityPolicy(
        preferenceHidden: hidesReplyEntryPoints,
        pureReading: false,
        contextAvailable: intent != nil
      ).showsReplyEntry
    else { return nil }
    return intent
  }

  static func activeSession(
    for intent: InboxReplyIntent?,
    hidesReplyEntryPoints: Bool,
    vault: any AccountVault
  ) async throws -> StoredAccountSession? {
    guard
      admittedIntent(
        intent,
        hidesReplyEntryPoints: hidesReplyEntryPoints
      ) != nil
    else { return nil }
    return try await vault.activeSession()
  }
}

struct InboxReplyIntentResolutionTaskID: Equatable {
  let loadState: LoadState
  let hidesReplyEntryPoints: Bool
}

struct InboxReplyIntent:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  enum Target:
    Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
  {
    case post(id: Int64)
    case subpost(id: Int64)

    var id: Int64 {
      switch self {
      case .post(let id), .subpost(let id):
        id
      }
    }

    var description: String { "InboxReplyIntent.Target(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
  }

  let userID: Int64
  let sessionRevision: UUID
  let threadID: Int64
  let senderUserID: Int64
  let target: Target

  var accountID: Int64 { userID }
  var targetID: Int64 { target.id }

  var description: String { "InboxReplyIntent(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  init?(
    message: InboxMessage,
    userID: Int64,
    sessionRevision: UUID
  ) {
    guard
      userID > 0,
      message.id == message.postID,
      message.threadID > 0,
      message.postID > 0,
      message.sender.id > 0
    else { return nil }

    self.userID = userID
    self.sessionRevision = sessionRevision
    self.threadID = message.threadID
    self.senderUserID = message.sender.id
    self.target = message.isFloorReply
      ? .subpost(id: message.postID)
      : .post(id: message.postID)
  }

  init?(message: InboxMessage, session: StoredAccountSession) {
    self.init(
      message: message,
      userID: session.id,
      sessionRevision: session.sessionRevision
    )
  }

  func isBound(to session: StoredAccountSession) -> Bool {
    session.id == userID && session.sessionRevision == sessionRevision
  }

  func composerContext(
    session: StoredAccountSession,
    thread: BrowseThread,
    post: BrowsePost
  ) -> TextReplyComposerContext? {
    guard
      isBound(to: session),
      case .post(let postID) = target,
      thread.id == threadID,
      post.id == postID,
      post.threadID == threadID,
      post.authorID == senderUserID,
      thread.localVisibility == .visible,
      post.localVisibility == .visible
    else { return nil }

    if post.id == thread.firstPostID {
      return TextReplyComposerContext(thread: thread, firstPost: post)
    }
    return TextReplyComposerContext(thread: thread, post: post)
  }

  func composerContext(
    session: StoredAccountSession,
    thread: BrowseThread,
    parentPost: CommentParentPostContext,
    comment: BrowseComment
  ) -> TextReplyComposerContext? {
    guard
      isBound(to: session),
      case .subpost(let subpostID) = target,
      thread.id == threadID,
      parentPost.threadID == threadID,
      comment.id == subpostID,
      comment.threadID == threadID,
      comment.parentPostID == parentPost.id,
      comment.authorID == senderUserID,
      thread.localVisibility == .visible,
      parentPost.localVisibility == .visible,
      comment.localVisibility == .visible,
      TextReplyComposerContext(thread: thread, parentPost: parentPost) != nil
    else { return nil }

    return TextReplyComposerContext(
      thread: thread,
      parentPostID: parentPost.id,
      comment: comment
    )
  }
}
