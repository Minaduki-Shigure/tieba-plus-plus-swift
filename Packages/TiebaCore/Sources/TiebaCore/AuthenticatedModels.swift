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

public enum TiebaNotificationKind: Sendable, Hashable {
  case replies
  case mentions
}

public struct TiebaNotificationSender: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let isFriend: Bool
  public let isFan: Bool

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    isFriend: Bool,
    isFan: Bool
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.isFriend = isFriend
    self.isFan = isFan
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaNotificationItem: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let sender: TiebaNotificationSender
  public let quotedUser: TiebaNotificationSender?
  public let threadID: Int64
  public let postID: Int64
  public let quotedPostID: Int64?
  public let title: String
  public let content: String
  public let quotedContent: String
  public let forumName: String
  public let timestamp: Int64
  public let isFloorReply: Bool
  public let isFirstPost: Bool
  public let isUnread: Bool
  public let threadType: Int

  public init(
    sender: TiebaNotificationSender,
    quotedUser: TiebaNotificationSender?,
    threadID: Int64,
    postID: Int64,
    quotedPostID: Int64?,
    title: String,
    content: String,
    quotedContent: String,
    forumName: String,
    timestamp: Int64,
    isFloorReply: Bool,
    isFirstPost: Bool,
    isUnread: Bool,
    threadType: Int
  ) {
    self.id = postID
    self.sender = sender
    self.quotedUser = quotedUser
    self.threadID = threadID
    self.postID = postID
    self.quotedPostID = quotedPostID
    self.title = title
    self.content = content
    self.quotedContent = quotedContent
    self.forumName = forumName
    self.timestamp = timestamp
    self.isFloorReply = isFloorReply
    self.isFirstPost = isFirstPost
    self.isUnread = isUnread
    self.threadType = threadType
  }
}

public struct TiebaNotificationPage: Sendable, Hashable {
  public let userID: Int64
  public let kind: TiebaNotificationKind
  public let items: [TiebaNotificationItem]
  public let pagination: TiebaPagination

  public init(
    userID: Int64,
    kind: TiebaNotificationKind,
    items: [TiebaNotificationItem],
    pagination: TiebaPagination
  ) {
    self.userID = userID
    self.kind = kind
    self.items = items
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
