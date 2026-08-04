import Foundation

public struct TiebaBDUSSCredential:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let bduss: String

  public init(bduss: String) {
    self.bduss = bduss
  }

  public var description: String { "TiebaBDUSSCredential(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

public struct TiebaAuthenticatedAccount:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let userID: Int64
  public let username: String
  public let portrait: String

  public init(userID: Int64, username: String, portrait: String) {
    self.userID = userID
    self.username = username
    self.portrait = portrait
  }

  public var description: String {
    "TiebaAuthenticatedAccount(userID: \(userID), username: \(username))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["userID": userID, "username": username], displayStyle: .struct)
  }
}

public struct TiebaFollowedForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let level: Int
  public let experience: Int

  public init(id: Int64, name: String, level: Int, experience: Int) {
    self.id = id
    self.name = name
    self.level = level
    self.experience = experience
  }
}

public struct TiebaFollowedForumPage: Sendable, Hashable {
  public let forums: [TiebaFollowedForum]
  public let pagination: TiebaPagination

  public init(forums: [TiebaFollowedForum], pagination: TiebaPagination) {
    self.forums = forums
    self.pagination = pagination
  }
}

public struct TiebaForumMembership: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let forumName: String
  public let isFollowed: Bool

  public init(userID: Int64, forumID: Int64, forumName: String, isFollowed: Bool) {
    self.userID = userID
    self.forumID = forumID
    self.forumName = forumName
    self.isFollowed = isFollowed
  }
}

public struct TiebaForumCheckIn: Sendable, Hashable {
  public let isCheckedIn: Bool
  public let consecutiveDays: Int
  public let rank: Int

  public init(isCheckedIn: Bool, consecutiveDays: Int, rank: Int) {
    self.isCheckedIn = isCheckedIn
    self.consecutiveDays = consecutiveDays
    self.rank = rank
  }
}

public struct TiebaForumAccountState: Sendable, Hashable {
  public let membership: TiebaForumMembership
  public let checkIn: TiebaForumCheckIn?

  public init(membership: TiebaForumMembership, checkIn: TiebaForumCheckIn?) {
    self.membership = membership
    self.checkIn = checkIn
  }
}

public struct TiebaThreadAgreement: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let firstPostID: Int64
  public let isAgreed: Bool
  public let agreeScore: Int

  public init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool,
    agreeScore: Int
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.firstPostID = firstPostID
    self.isAgreed = isAgreed
    self.agreeScore = agreeScore
  }
}

public enum TiebaAgreementTarget: Sendable, Hashable {
  case thread(firstPostID: Int64)
  case post(postID: Int64)
  case subpost(parentPostID: Int64, subpostID: Int64)
}

public struct TiebaAgreementState: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let target: TiebaAgreementTarget
  public let isAgreed: Bool
  public let agreeScore: Int

  public init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool,
    agreeScore: Int
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.target = target
    self.isAgreed = isAgreed
    self.agreeScore = agreeScore
  }
}

public struct TiebaAgreementPage: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let agreements: [TiebaAgreementState]
  public let pagination: TiebaPagination

  public init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    agreements: [TiebaAgreementState],
    pagination: TiebaPagination
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.agreements = agreements
    self.pagination = pagination
  }
}
