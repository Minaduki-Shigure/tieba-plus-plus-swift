import Foundation

public enum TiebaTextReplyContentPolicy {
  public static let maximumCharacterCount = 10_000
  public static let maximumUTF8ByteCount = 32 * 1_024

  public static func isValid(_ value: String) -> Bool {
    guard
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.count <= maximumCharacterCount,
      value.utf8.count <= maximumUTF8ByteCount,
      !value.contains("#(")
    else { return false }

    return !value.unicodeScalars.contains { scalar in
      CharacterSet.controlCharacters.contains(scalar)
        && scalar.value != 0x0A
        && scalar.value != 0x0D
        && scalar.value != 0x09
    }
  }
}

public enum TiebaTextReplyTarget: Sendable, Hashable {
  case thread(firstPostID: Int64)
  case post(postID: Int64)
  case subpost(parentPostID: Int64, subpostID: Int64)
}

public struct TiebaTextReplySubmission:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let submissionID: UUID
  public let forumID: Int64
  public let forumName: String
  public let threadID: Int64
  public let target: TiebaTextReplyTarget
  public let content: String

  public init(
    submissionID: UUID,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaTextReplyTarget,
    content: String
  ) {
    self.submissionID = submissionID
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.target = target
    self.content = content
  }

  public var description: String { "TiebaTextReplySubmission(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "submissionID": submissionID,
        "forumID": forumID,
        "threadID": threadID,
        "target": target,
        "contentUTF8ByteCount": content.utf8.count,
      ],
      displayStyle: .struct
    )
  }
}

public enum TiebaTextReplyReceipt: Sendable, Hashable {
  case post(postID: Int64)
  case subpost(parentPostID: Int64, subpostID: Int64)
}

public enum TiebaCreatedReply: Sendable, Hashable {
  case post(postID: Int64, floor: Int)
  case subpost(parentPostID: Int64, subpostID: Int64)
}

public enum TiebaTextReplyOutcome: Sendable, Hashable {
  case confirmed(TiebaCreatedReply)
  case acceptedAwaitingVisibility(TiebaTextReplyReceipt)
}

public struct TiebaTextReplyResult: Sendable, Hashable {
  public let submissionID: UUID
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let target: TiebaTextReplyTarget
  public let outcome: TiebaTextReplyOutcome

  public init(
    submissionID: UUID,
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaTextReplyTarget,
    outcome: TiebaTextReplyOutcome
  ) {
    self.submissionID = submissionID
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.target = target
    self.outcome = outcome
  }
}
