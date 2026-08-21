import Foundation
import TiebaCore

struct TextReplyTarget:
  Identifiable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  enum Destination: Hashable, Codable, Sendable {
    case thread(firstPostID: Int64)
    case post(postID: Int64)
    case subpost(parentPostID: Int64, subpostID: Int64)

    fileprivate var identityComponent: String {
      switch self {
      case .thread(let firstPostID):
        "thread:\(firstPostID)"
      case .post(let postID):
        "post:\(postID)"
      case .subpost(let parentPostID, let subpostID):
        "subpost:\(parentPostID):\(subpostID)"
      }
    }
  }

  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let firstPostID: Int64
  let destination: Destination

  var id: String {
    "forum:\(forumID):thread:\(threadID):first:\(firstPostID):\(destination.identityComponent)"
  }

  var description: String { "TextReplyTarget(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  init?(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    destination: Destination
  ) {
    let forumName = Self.normalizedForumName(forumName)
    guard
      forumID > 0,
      threadID > 0,
      firstPostID > 0,
      Self.isValidForumName(forumName),
      Self.isValid(destination, firstPostID: firstPostID)
    else { return nil }
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.firstPostID = firstPostID
    self.destination = destination
  }

  init?(thread: BrowseThread, firstPost: BrowsePost) {
    guard
      thread.id > 0,
      thread.firstPostID > 0,
      firstPost.id == thread.firstPostID,
      firstPost.threadID == thread.id,
      firstPost.floor == 1
    else { return nil }
    self.init(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      firstPostID: thread.firstPostID,
      destination: .thread(firstPostID: firstPost.id)
    )
  }

  init?(thread: BrowseThread, post: BrowsePost) {
    guard
      post.id > 0,
      post.threadID == thread.id,
      post.floor > 1,
      thread.firstPostID > 0,
      post.id != thread.firstPostID
    else { return nil }
    self.init(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      firstPostID: thread.firstPostID,
      destination: .post(postID: post.id)
    )
  }

  init?(thread: BrowseThread, parentPost: CommentParentPostContext) {
    guard
      parentPost.id > 0,
      parentPost.threadID == thread.id,
      parentPost.floor > 1,
      thread.firstPostID > 0,
      parentPost.id != thread.firstPostID
    else { return nil }
    self.init(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      firstPostID: thread.firstPostID,
      destination: .post(postID: parentPost.id)
    )
  }

  init?(
    thread: BrowseThread,
    parentPostID: Int64,
    comment: BrowseComment
  ) {
    guard
      parentPostID > 0,
      thread.firstPostID > 0,
      comment.id > 0,
      comment.threadID == thread.id,
      comment.parentPostID == parentPostID,
      comment.id != parentPostID
    else { return nil }
    self.init(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      firstPostID: thread.firstPostID,
      destination: .subpost(parentPostID: parentPostID, subpostID: comment.id)
    )
  }

  fileprivate static func isValid(
    _ destination: Destination,
    firstPostID: Int64
  ) -> Bool {
    switch destination {
    case .thread(let targetFirstPostID):
      targetFirstPostID == firstPostID
    case .post(let postID):
      postID > 0 && postID != firstPostID
    case .subpost(let parentPostID, let subpostID):
      parentPostID > 0
        && subpostID > 0
        && parentPostID != subpostID
    }
  }

  private static func normalizedForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private static func isValidForumName(_ value: String) -> Bool {
    !value.isEmpty
      && value.count <= 100
      && value.utf8.count <= 1_024
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct TextReplyComposerContext: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case thread
    case post
    case subpost
  }

  let target: TextReplyTarget
  let kind: Kind
  let floor: Int?
  let replyingToName: String?
  let replyingToUserID: Int64?

  var id: String { target.id }

  init?(thread: BrowseThread, firstPost: BrowsePost) {
    guard let target = TextReplyTarget(thread: thread, firstPost: firstPost) else {
      return nil
    }
    self.target = target
    self.kind = .thread
    self.floor = nil
    self.replyingToName = nil
    self.replyingToUserID = nil
  }

  init?(thread: BrowseThread, post: BrowsePost) {
    guard let target = TextReplyTarget(thread: thread, post: post) else { return nil }
    self.target = target
    self.kind = .post
    self.floor = post.floor
    self.replyingToName = Self.preferredName(post.authorName, fallback: post.authorUsername)
    self.replyingToUserID = nil
  }

  init?(thread: BrowseThread, parentPost: CommentParentPostContext) {
    if
      parentPost.id == thread.firstPostID,
      parentPost.threadID == thread.id,
      parentPost.floor == 1,
      let target = TextReplyTarget(
        forumID: thread.forumID,
        forumName: thread.forumName,
        threadID: thread.id,
        firstPostID: thread.firstPostID,
        destination: .thread(firstPostID: thread.firstPostID)
      )
    {
      self.target = target
      self.kind = .thread
      self.floor = nil
      self.replyingToName = nil
      self.replyingToUserID = nil
      return
    }
    guard let target = TextReplyTarget(thread: thread, parentPost: parentPost) else {
      return nil
    }
    self.target = target
    self.kind = .post
    self.floor = parentPost.floor
    self.replyingToName = Self.preferredName(
      parentPost.authorName,
      fallback: parentPost.authorUsername
    )
    self.replyingToUserID = nil
  }

  init?(
    thread: BrowseThread,
    parentPostID: Int64,
    comment: BrowseComment
  ) {
    guard
      comment.authorID > 0,
      let target = TextReplyTarget(
        thread: thread,
        parentPostID: parentPostID,
        comment: comment
      )
    else { return nil }
    self.target = target
    self.kind = .subpost
    self.floor = nil
    self.replyingToName = Self.preferredName(
      comment.authorName,
      fallback: comment.authorUsername
    )
    self.replyingToUserID = comment.authorID
  }

  init?(
    thread: BrowseThread,
    parentPost: BrowsePost,
    comment: BrowseComment
  ) {
    let isExactFirstPost = parentPost.id == thread.firstPostID
      && parentPost.floor == 1
    let isExactReplyPost = parentPost.id != thread.firstPostID
      && parentPost.floor > 1
    guard
      parentPost.id > 0,
      parentPost.threadID == thread.id,
      isExactFirstPost || isExactReplyPost,
      parentPost.inlineComments.filter({ $0.id == comment.id }) == [comment]
    else { return nil }
    self.init(
      thread: thread,
      parentPostID: parentPost.id,
      comment: comment
    )
  }

  private static func preferredName(_ value: String, fallback: String) -> String? {
    for candidate in [value, fallback] {
      let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty {
        return String(normalized.prefix(100))
      }
    }
    return nil
  }
}

enum TextReplyContentPolicy {
  static let maximumCharacterCount = TiebaTextReplyContentPolicy.maximumCharacterCount
  static let maximumUTF8ByteCount = TiebaTextReplyContentPolicy.maximumUTF8ByteCount

  static func isValid(_ content: String) -> Bool {
    TiebaTextReplyContentPolicy.isValid(content)
  }
}

struct TextReplySubmission:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let target: TextReplyTarget
  let content: String
  let attachments: [ComposerImageAttachment]
  let imageWatermark: TiebaStaticImageWatermark

  init?(
    id: UUID = UUID(),
    target: TextReplyTarget,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName
  ) {
    guard
      ComposerImageDraftPolicy.isValid(attachments),
      Self.target(target.destination, allows: attachments),
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: content,
        imageCount: attachments.count,
        maximumCharacterCount: TextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TextReplyContentPolicy.maximumUTF8ByteCount
      )
    else { return nil }
    self.id = id
    self.target = target
    self.content = content
    self.attachments = attachments
    self.imageWatermark = ComposerImageDraftPolicy.normalizedWatermark(
      imageWatermark,
      for: attachments
    )
  }

  var description: String { "TextReplySubmission(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.target == rhs.target
      && lhs.content.utf8.elementsEqual(rhs.content.utf8)
      && lhs.attachments == rhs.attachments
      && lhs.imageWatermark == rhs.imageWatermark
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(target)
    hasher.combine(content.utf8.count)
    for byte in content.utf8 {
      hasher.combine(byte)
    }
    hasher.combine(attachments)
    hasher.combine(imageWatermark)
  }

  private static func target(
    _ destination: TextReplyTarget.Destination,
    allows attachments: [ComposerImageAttachment]
  ) -> Bool {
    guard !attachments.isEmpty else { return true }
    if case .thread = destination { return true }
    return false
  }
}

enum TextReplyReceipt: Hashable, Codable, Sendable {
  case post(postID: Int64)
  case subpost(parentPostID: Int64, subpostID: Int64)

  var isValid: Bool {
    switch self {
    case .post(let postID):
      postID > 0
    case .subpost(let parentPostID, let subpostID):
      parentPostID > 0 && subpostID > 0 && parentPostID != subpostID
    }
  }

  func belongs(to target: TextReplyTarget) -> Bool {
    guard isValid else { return false }
    return switch (target.destination, self) {
    case (.thread(let firstPostID), .post(let postID)):
      postID != firstPostID
    case (.post(let expectedParent), .subpost(let parentPostID, _)):
      parentPostID == expectedParent
    case (
      .subpost(let expectedParent, let repliedSubpostID),
      .subpost(let parentPostID, let createdSubpostID)
    ):
      parentPostID == expectedParent && createdSubpostID != repliedSubpostID
    default:
      false
    }
  }
}

enum CreatedTextReply: Hashable, Codable, Sendable {
  case post(postID: Int64, floor: Int)
  case subpost(parentPostID: Int64, subpostID: Int64)

  var receipt: TextReplyReceipt {
    switch self {
    case .post(let postID, _):
      .post(postID: postID)
    case .subpost(let parentPostID, let subpostID):
      .subpost(parentPostID: parentPostID, subpostID: subpostID)
    }
  }

  var isValid: Bool {
    switch self {
    case .post(let postID, let floor):
      postID > 0 && floor > 1
    case .subpost(let parentPostID, let subpostID):
      parentPostID > 0 && subpostID > 0 && parentPostID != subpostID
    }
  }

  func belongs(to target: TextReplyTarget) -> Bool {
    isValid && receipt.belongs(to: target)
  }
}

enum TextReplyOutcome: Hashable, Sendable {
  case confirmed(CreatedTextReply)
  case acceptedAwaitingVisibility(TextReplyReceipt)
}

struct TextReplyVisibilityConfirmation:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let created: CreatedTextReply
  let authorUserID: Int64
  let content: String
  let attachments: [ComposerImageAttachment]
  let imageWatermark: TiebaStaticImageWatermark

  init?(
    created: CreatedTextReply,
    authorUserID: Int64,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName
  ) {
    guard
      created.isValid,
      authorUserID > 0,
      attachments.isEmpty || Self.isDirectTopicReply(created),
      ComposerImageDraftPolicy.isValid(attachments),
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: content,
        imageCount: attachments.count,
        maximumCharacterCount: TextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TextReplyContentPolicy.maximumUTF8ByteCount
      )
    else { return nil }
    self.created = created
    self.authorUserID = authorUserID
    self.content = content
    self.attachments = attachments
    self.imageWatermark = ComposerImageDraftPolicy.normalizedWatermark(
      imageWatermark,
      for: attachments
    )
  }

  var description: String { "TextReplyVisibilityConfirmation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  private static func isDirectTopicReply(_ created: CreatedTextReply) -> Bool {
    if case .post = created { return true }
    return false
  }
}

struct TextReplyResult: Hashable, Sendable {
  let submissionID: UUID
  let userID: Int64
  let target: TextReplyTarget
  let outcome: TextReplyOutcome

  init?(
    submissionID: UUID,
    userID: Int64,
    target: TextReplyTarget,
    outcome: TextReplyOutcome
  ) {
    guard userID > 0 else { return nil }
    switch outcome {
    case .confirmed(let created):
      guard created.belongs(to: target) else { return nil }
    case .acceptedAwaitingVisibility(let receipt):
      guard receipt.belongs(to: target) else { return nil }
    }
    self.submissionID = submissionID
    self.userID = userID
    self.target = target
    self.outcome = outcome
  }
}

enum TextReplySubmissionError: LocalizedError, Sendable, Equatable {
  case signedOut
  case fullCredentialsRequired
  case invalidSubmission
  case submissionInProgress
  case submissionConflict
  case challengeRequired
  case outcomeUnknown
  case accountChanged
  case server(code: Int32)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .signedOut:
      "请先登录贴吧账户后再回复。"
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全发送回复。"
    case .invalidSubmission:
      "回复目标或正文无效，请检查后再试。"
    case .submissionInProgress:
      "这条回复正在发送，请等待当前操作完成。"
    case .submissionConflict:
      "回复请求标识发生冲突，未再次发送。"
    case .challengeRequired:
      "贴吧要求完成安全验证；当前版本不会绕过验证，草稿已保留。"
    case .outcomeUnknown:
      "发送结果未知，请刷新确认，勿立即重试；草稿已保留。"
    case .accountChanged:
      "发送期间账户已改变，结果未在当前页面采用；草稿已保留。"
    case .server(let code):
      "贴吧拒绝了回复（错误码 \(code)）；草稿已保留。"
    case .unavailable:
      "暂时无法发送回复，草稿已保留。"
    }
  }
}

struct TextReplyDraftKey: Hashable, Codable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let firstPostID: Int64
  let destination: TextReplyTarget.Destination

  init?(userID: Int64, target: TextReplyTarget) {
    guard userID > 0 else { return nil }
    self.userID = userID
    self.forumID = target.forumID
    self.threadID = target.threadID
    self.firstPostID = target.firstPostID
    self.destination = target.destination
  }

  var isValid: Bool {
    userID > 0
      && forumID > 0
      && threadID > 0
      && firstPostID > 0
      && TextReplyTarget.isValid(destination, firstPostID: firstPostID)
  }
}

enum TextReplyDraftDisposition: Hashable, Codable, Sendable {
  case editing
  case submissionPending(submissionID: UUID)
  case imagePreparationPending(reference: ComposerImageSubmissionReference)
  case imagePipeline(reference: ComposerImageSubmissionReference)
  case challengeRequired(submissionID: UUID, sessionRevision: UUID)
  case acceptedAwaitingVisibility(submissionID: UUID, receipt: TextReplyReceipt)
  case imageAcceptedAwaitingVisibility(
    reference: ComposerImageSubmissionReference,
    receipt: TextReplyReceipt
  )
  case imageConfirmed(
    reference: ComposerImageSubmissionReference,
    created: CreatedTextReply
  )
  case outcomeUnknown(submissionID: UUID)

  var imageSubmissionReference: ComposerImageSubmissionReference? {
    switch self {
    case .imagePreparationPending(let reference), .imagePipeline(let reference),
      .imageAcceptedAwaitingVisibility(let reference, _), .imageConfirmed(let reference, _):
      reference
    case .editing, .submissionPending, .challengeRequired, .acceptedAwaitingVisibility,
      .outcomeUnknown:
      nil
    }
  }
}

struct TextReplyDraft:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  static let maximumStoredCharacterCount = 20_000
  static let maximumStoredUTF8ByteCount = 64 * 1_024

  let key: TextReplyDraftKey
  let content: String
  let attachments: [ComposerImageAttachment]
  let imageWatermark: TiebaStaticImageWatermark
  let disposition: TextReplyDraftDisposition
  let updatedAt: Date

  init?(
    key: TextReplyDraftKey,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName,
    disposition: TextReplyDraftDisposition = .editing,
    updatedAt: Date = Date()
  ) {
    guard
      key.isValid,
      content.count <= Self.maximumStoredCharacterCount,
      content.utf8.count <= Self.maximumStoredUTF8ByteCount,
      ComposerImageDraftPolicy.isValid(attachments),
      updatedAt.timeIntervalSinceReferenceDate.isFinite,
      !content.isEmpty || !attachments.isEmpty || Self.allowsEmptyContent(disposition),
      Self.target(key.destination, allows: attachments),
      Self.isValid(disposition, for: key.destination),
      Self.isValidContent(content, attachments: attachments, disposition: disposition)
    else { return nil }
    self.key = key
    self.content = content
    self.attachments = attachments
    self.imageWatermark = ComposerImageDraftPolicy.normalizedWatermark(
      imageWatermark,
      for: attachments
    )
    self.disposition = disposition
    self.updatedAt = updatedAt
  }

  var description: String { "TextReplyDraft(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  private static func isValid(
    _ disposition: TextReplyDraftDisposition,
    for destination: TextReplyTarget.Destination
  ) -> Bool {
    switch disposition {
    case .editing, .submissionPending, .imagePreparationPending, .imagePipeline,
      .challengeRequired, .outcomeUnknown:
      true
    case .acceptedAwaitingVisibility(_, let receipt),
      .imageAcceptedAwaitingVisibility(_, let receipt):
      Self.receipt(receipt, belongsTo: destination)
    case .imageConfirmed(_, let created):
      created.isValid && Self.receipt(created.receipt, belongsTo: destination)
    }
  }

  private static func receipt(
    _ receipt: TextReplyReceipt,
    belongsTo destination: TextReplyTarget.Destination
  ) -> Bool {
    switch (destination, receipt) {
    case (.thread(let firstPostID), .post(let postID)):
      postID > 0 && postID != firstPostID
    case (.post(let expectedParent), .subpost(let parentPostID, let subpostID)):
      expectedParent == parentPostID && subpostID > 0 && subpostID != parentPostID
    case (
      .subpost(let expectedParent, let repliedSubpostID),
      .subpost(let parentPostID, let createdSubpostID)
    ):
      expectedParent == parentPostID
        && createdSubpostID > 0
        && createdSubpostID != parentPostID
        && createdSubpostID != repliedSubpostID
    default:
      false
    }
  }

  private static func allowsEmptyContent(_ disposition: TextReplyDraftDisposition) -> Bool {
    if case .challengeRequired = disposition { return true }
    return false
  }

  private static func target(
    _ destination: TextReplyTarget.Destination,
    allows attachments: [ComposerImageAttachment]
  ) -> Bool {
    guard !attachments.isEmpty else { return true }
    if case .thread = destination { return true }
    return false
  }

  private static func isValidContent(
    _ content: String,
    attachments: [ComposerImageAttachment],
    disposition: TextReplyDraftDisposition
  ) -> Bool {
    switch disposition {
    case .editing:
      true
    case .challengeRequired:
      attachments.isEmpty && (content.isEmpty || TextReplyContentPolicy.isValid(content))
    case .submissionPending, .acceptedAwaitingVisibility, .outcomeUnknown:
      attachments.isEmpty && TextReplyContentPolicy.isValid(content)
    case .imagePreparationPending, .imagePipeline, .imageAcceptedAwaitingVisibility,
      .imageConfirmed:
      !attachments.isEmpty && isValidSubmissionContent(content, attachments: attachments)
    }
  }

  private static func isValidSubmissionContent(
    _ content: String,
    attachments: [ComposerImageAttachment]
  ) -> Bool {
    TiebaStaticImageContentPolicy.canCompileWithinLimits(
      userContent: content,
      imageCount: attachments.count,
      maximumCharacterCount: TextReplyContentPolicy.maximumCharacterCount,
      maximumUTF8ByteCount: TextReplyContentPolicy.maximumUTF8ByteCount
    )
  }
}
