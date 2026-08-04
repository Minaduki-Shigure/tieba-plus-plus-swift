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
