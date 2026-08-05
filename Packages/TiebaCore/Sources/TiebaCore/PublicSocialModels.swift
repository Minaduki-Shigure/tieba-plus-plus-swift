import Foundation

public enum TiebaUserRelationKind: Sendable, Hashable {
  case following
  case followers
}

public struct TiebaRelatedUser: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let introduction: String

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    introduction: String
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.introduction = introduction
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaUserRelationPage: Sendable, Hashable {
  public let requestedUserID: Int64
  public let kind: TiebaUserRelationKind
  public let users: [TiebaRelatedUser]
  public let pagination: TiebaPagination
  public let notice: String
  public let visibilitySwitch: Int?

  public init(
    requestedUserID: Int64,
    kind: TiebaUserRelationKind,
    users: [TiebaRelatedUser],
    pagination: TiebaPagination,
    notice: String,
    visibilitySwitch: Int?
  ) {
    self.requestedUserID = requestedUserID
    self.kind = kind
    self.users = users
    self.pagination = pagination
    self.notice = notice
    self.visibilitySwitch = visibilitySwitch
  }
}

enum TiebaPublicSocialPolicy {
  static let maximumResponseBodyBytes = 1 * 1_024 * 1_024
  static let followingPageSize = 20
  static let maximumResponseUserCount = 100
  static let maximumNameBytes = 512
  static let maximumPortraitBytes = 2_048
  static let maximumIntroductionBytes = 8_192
  static let maximumNoticeBytes = 8_192
}
