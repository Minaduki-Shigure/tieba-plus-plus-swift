import Foundation

public struct TiebaPersonalizedFeedbackSubmission: Sendable, Hashable {
  public let threadID: Int64
  public let forumID: Int64
  public let reasonIDs: [UInt32]
  public let reasonExtras: [String]
  public let clickTimeMilliseconds: Int64

  public init(
    threadID: Int64,
    forumID: Int64,
    reasonIDs: [UInt32],
    reasonExtras: [String],
    clickTimeMilliseconds: Int64
  ) {
    self.threadID = threadID
    self.forumID = forumID
    self.reasonIDs = reasonIDs
    self.reasonExtras = reasonExtras
    self.clickTimeMilliseconds = clickTimeMilliseconds
  }
}
