import Foundation
import TiebaCore

struct NewThreadTarget:
  Identifiable, Hashable, Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let forumID: Int64
  let forumName: String

  var id: String { "forum:\(forumID):\(forumName)" }

  var description: String { "NewThreadTarget(forumID: \(forumID), forumName: redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["forumID": forumID], displayStyle: .struct)
  }

  init?(forumID: Int64, forumName: String) {
    let forumName = Self.normalizedForumName(forumName)
    guard forumID > 0, Self.isValidForumName(forumName) else { return nil }
    self.forumID = forumID
    self.forumName = forumName
  }

  var isValid: Bool {
    forumID > 0
      && forumName == Self.normalizedForumName(forumName)
      && Self.isValidForumName(forumName)
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

enum NewThreadTitlePolicy {
  static let maximumCharacterCount = 31
  static let maximumUTF8ByteCount = 4 * maximumCharacterCount

  static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    return normalized.isEmpty ? nil : normalized
  }

  static func isValid(_ value: String?) -> Bool {
    guard let value = normalized(value) else { return true }
    guard
      value.count <= maximumCharacterCount,
      value.utf8.count <= maximumUTF8ByteCount,
      !value.contains("#(")
    else { return false }
    return !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

enum NewThreadContentPolicy {
  static let maximumCharacterCount = TiebaTextReplyContentPolicy.maximumCharacterCount
  static let maximumUTF8ByteCount = TiebaTextReplyContentPolicy.maximumUTF8ByteCount

  static func isValid(_ content: String) -> Bool {
    TiebaTextReplyContentPolicy.isValid(content)
  }
}

struct NewThreadSubmission:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let target: NewThreadTarget
  let title: String?
  let content: String

  init?(
    id: UUID = UUID(),
    target: NewThreadTarget,
    title: String?,
    content: String
  ) {
    let title = NewThreadTitlePolicy.normalized(title)
    guard
      target.isValid,
      NewThreadTitlePolicy.isValid(title),
      NewThreadContentPolicy.isValid(content)
    else { return nil }
    self.id = id
    self.target = target
    self.title = title
    self.content = content
  }

  var description: String { "NewThreadSubmission(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["id": id, "target": target],
      displayStyle: .struct
    )
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.target == rhs.target
      && lhs.title == rhs.title
      && lhs.content.utf8.elementsEqual(rhs.content.utf8)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(target)
    hasher.combine(title)
    hasher.combine(content.utf8.count)
    for byte in content.utf8 {
      hasher.combine(byte)
    }
  }

}

struct NewThreadReceipt: Hashable, Codable, Sendable {
  let threadID: Int64
  let firstPostID: Int64

  init?(threadID: Int64, firstPostID: Int64) {
    guard threadID > 0, firstPostID > 0 else { return nil }
    self.threadID = threadID
    self.firstPostID = firstPostID
  }

  var isValid: Bool { threadID > 0 && firstPostID > 0 }
}

enum NewThreadOutcome: Hashable, Sendable {
  case confirmed(NewThreadReceipt)
  case acceptedAwaitingVisibility(NewThreadReceipt)
}

struct NewThreadResult: Hashable, Sendable {
  let submissionID: UUID
  let userID: Int64
  let target: NewThreadTarget
  let outcome: NewThreadOutcome

  init?(
    submissionID: UUID,
    userID: Int64,
    target: NewThreadTarget,
    outcome: NewThreadOutcome
  ) {
    let receipt: NewThreadReceipt = switch outcome {
    case .confirmed(let receipt), .acceptedAwaitingVisibility(let receipt):
      receipt
    }
    guard userID > 0, target.isValid, receipt.isValid else { return nil }
    self.submissionID = submissionID
    self.userID = userID
    self.target = target
    self.outcome = outcome
  }
}

struct NewThreadVisibilityConfirmation:
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let receipt: NewThreadReceipt
  let target: NewThreadTarget
  let authorUserID: Int64
  let title: String?
  let content: String

  init?(
    receipt: NewThreadReceipt,
    target: NewThreadTarget,
    authorUserID: Int64,
    title: String?,
    content: String
  ) {
    let title = Self.normalizedVisibleTitle(title)
    guard
      receipt.isValid,
      target.isValid,
      authorUserID > 0,
      Self.isValidVisibleTitle(title),
      NewThreadContentPolicy.isValid(content)
    else { return nil }
    self.receipt = receipt
    self.target = target
    self.authorUserID = authorUserID
    self.title = title
    self.content = content
  }

  var description: String { "NewThreadVisibilityConfirmation(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["receipt": receipt, "target": target, "authorUserID": authorUserID],
      displayStyle: .struct
    )
  }

  private static func normalizedVisibleTitle(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    return normalized.isEmpty ? nil : normalized
  }

  private static func isValidVisibleTitle(_ value: String?) -> Bool {
    guard let value else { return true }
    return value.count <= 100
      && value.utf8.count <= 1_024
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

enum NewThreadSubmissionError: LocalizedError, Sendable, Equatable {
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
      "请先登录贴吧账户后再发布主题。"
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全发布主题。"
    case .invalidSubmission:
      "贴吧、标题或正文无效，请检查后再试。"
    case .submissionInProgress:
      "这个主题正在发布，请等待当前操作完成。"
    case .submissionConflict:
      "发布请求标识发生冲突，未再次发送。"
    case .challengeRequired:
      "贴吧要求完成安全验证；当前版本不会绕过验证，草稿已锁定并保留。"
    case .outcomeUnknown:
      "发布结果未知，请刷新确认，勿立即重试；草稿已锁定并保留。"
    case .accountChanged:
      "发布期间账户已改变，结果未在当前页面采用；原账户草稿已保留。"
    case .server(let code):
      "贴吧拒绝了发布请求（错误码 \(code)）；草稿已保留。"
    case .unavailable:
      "暂时无法发布主题，草稿已保留。"
    }
  }
}

struct NewThreadDraftKey: Hashable, Codable, Sendable {
  let userID: Int64
  let forumID: Int64
  let forumName: String

  init?(userID: Int64, target: NewThreadTarget) {
    guard userID > 0, target.isValid else { return nil }
    self.userID = userID
    self.forumID = target.forumID
    self.forumName = target.forumName
  }

  var isValid: Bool {
    guard let target = NewThreadTarget(forumID: forumID, forumName: forumName) else {
      return false
    }
    return userID > 0 && target.forumName == forumName
  }
}

enum NewThreadDraftDisposition: Hashable, Codable, Sendable {
  case editing
  case submissionPending(submissionID: UUID)
  case challengeRequired(submissionID: UUID, sessionRevision: UUID)
  case acceptedAwaitingVisibility(submissionID: UUID, receipt: NewThreadReceipt)
  case confirmed(submissionID: UUID, receipt: NewThreadReceipt)
  case outcomeUnknown(submissionID: UUID)
}

struct NewThreadDraft:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  static let maximumStoredContentCharacterCount = 20_000
  static let maximumStoredContentUTF8ByteCount = 64 * 1_024

  let key: NewThreadDraftKey
  let title: String?
  let content: String
  let disposition: NewThreadDraftDisposition
  let updatedAt: Date

  init?(
    key: NewThreadDraftKey,
    title: String?,
    content: String,
    disposition: NewThreadDraftDisposition = .editing,
    updatedAt: Date = Date()
  ) {
    let title = NewThreadTitlePolicy.normalized(title)
    guard
      key.isValid,
      NewThreadTitlePolicy.isValid(title),
      content.count <= Self.maximumStoredContentCharacterCount,
      content.utf8.count <= Self.maximumStoredContentUTF8ByteCount,
      updatedAt.timeIntervalSinceReferenceDate.isFinite,
      title != nil || !content.isEmpty || Self.allowsEmptyDraft(disposition),
      Self.isValid(disposition, content: content)
    else { return nil }
    self.key = key
    self.title = title
    self.content = content
    self.disposition = disposition
    self.updatedAt = updatedAt
  }

  var description: String { "NewThreadDraft(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["key": key, "disposition": disposition, "updatedAt": updatedAt],
      displayStyle: .struct
    )
  }

  private static func isValid(
    _ disposition: NewThreadDraftDisposition,
    content: String
  ) -> Bool {
    switch disposition {
    case .editing:
      true
    case .challengeRequired:
      content.isEmpty || NewThreadContentPolicy.isValid(content)
    case .submissionPending, .outcomeUnknown:
      NewThreadContentPolicy.isValid(content)
    case .acceptedAwaitingVisibility(_, let receipt), .confirmed(_, let receipt):
      receipt.isValid && NewThreadContentPolicy.isValid(content)
    }
  }

  private static func allowsEmptyDraft(_ disposition: NewThreadDraftDisposition) -> Bool {
    if case .challengeRequired = disposition { return true }
    return false
  }
}
