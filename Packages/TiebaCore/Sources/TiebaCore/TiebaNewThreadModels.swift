import Foundation

public enum TiebaNewThreadContentPolicy {
  public static let maximumTitleCharacterCount = 31
  public static let maximumTitleUTF8ByteCount = 124
  public static let maximumContentCharacterCount = TiebaTextReplyContentPolicy.maximumCharacterCount
  public static let maximumContentUTF8ByteCount = TiebaTextReplyContentPolicy.maximumUTF8ByteCount

  public static func isValidTitle(_ value: String) -> Bool {
    value.count <= maximumTitleCharacterCount
      && value.utf8.count <= maximumTitleUTF8ByteCount
      && !value.contains("#(")
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  public static func isValidContent(_ value: String) -> Bool {
    TiebaTextReplyContentPolicy.isValid(value)
  }

  public static func isValid(title: String, content: String) -> Bool {
    isValidTitle(title) && isValidContent(content)
  }
}

public struct TiebaNewThreadSubmission:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let submissionID: UUID
  public let forumID: Int64
  public let forumName: String
  public let title: String
  public let content: String
  public let imageProofs: [TiebaStaticImageContentProof]

  public init(
    submissionID: UUID,
    forumID: Int64,
    forumName: String,
    title: String,
    content: String,
    imageProofs: [TiebaStaticImageContentProof] = []
  ) {
    self.submissionID = submissionID
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.content = content
    self.imageProofs = imageProofs
  }

  public var description: String { "TiebaNewThreadSubmission(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "submissionID": submissionID,
        "forumID": forumID,
        "titleCharacterCount": title.count,
        "titleUTF8ByteCount": title.utf8.count,
        "contentCharacterCount": content.count,
        "contentUTF8ByteCount": content.utf8.count,
      ],
      displayStyle: .struct
    )
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.submissionID == rhs.submissionID
      && lhs.forumID == rhs.forumID
      && lhs.forumName == rhs.forumName
      && lhs.title == rhs.title
      && lhs.content.utf8.elementsEqual(rhs.content.utf8)
      && lhs.imageProofs == rhs.imageProofs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(submissionID)
    hasher.combine(forumID)
    hasher.combine(forumName)
    hasher.combine(title)
    hasher.combine(content.utf8.count)
    for byte in content.utf8 {
      hasher.combine(byte)
    }
    hasher.combine(imageProofs)
  }
}

public struct TiebaNewThreadReceipt: Sendable, Hashable, Codable {
  public let threadID: Int64
  public let firstPostID: Int64

  public init(threadID: Int64, firstPostID: Int64) {
    self.threadID = threadID
    self.firstPostID = firstPostID
  }

  var isValid: Bool {
    threadID > 0 && firstPostID > 0
  }
}

public enum TiebaNewThreadOutcome: Sendable, Hashable {
  case confirmed(TiebaNewThreadReceipt)
  case acceptedAwaitingVisibility(TiebaNewThreadReceipt)
}

public struct TiebaNewThreadResult: Sendable, Hashable {
  public let submissionID: UUID
  public let userID: Int64
  public let forumID: Int64
  public let forumName: String
  public let outcome: TiebaNewThreadOutcome

  public init(
    submissionID: UUID,
    userID: Int64,
    forumID: Int64,
    forumName: String,
    outcome: TiebaNewThreadOutcome
  ) {
    self.submissionID = submissionID
    self.userID = userID
    self.forumID = forumID
    self.forumName = forumName
    self.outcome = outcome
  }
}
