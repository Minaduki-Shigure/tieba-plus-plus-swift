import Foundation

public enum TiebaUserRelationKind: Sendable, Hashable {
  case following
  case followers
}

public enum TiebaRelatedUserConcernState: Sendable, Hashable {
  case notFollowing
  case following
  case mutual
  case unknown(Int64)

  public init(rawValue: Int64) {
    self =
      switch rawValue {
      case 0: .notFollowing
      case 1: .following
      case 2: .mutual
      default: .unknown(rawValue)
      }
  }

  public var rawValue: Int64 {
    switch self {
    case .notFollowing: 0
    case .following: 1
    case .mutual: 2
    case .unknown(let rawValue): rawValue
    }
  }
}

public struct TiebaRelatedUser: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let introduction: String
  public let concernState: TiebaRelatedUserConcernState?

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    introduction: String,
    concernState: TiebaRelatedUserConcernState? = nil
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.introduction = introduction
    self.concernState = concernState
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
