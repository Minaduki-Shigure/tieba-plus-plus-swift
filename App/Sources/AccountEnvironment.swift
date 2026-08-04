import Foundation
import SwiftUI

struct AccountAccess: Sendable {
  let vault: any AccountVault
  let service: any AccountService
}

private struct AccountAccessEnvironmentKey: EnvironmentKey {
  static let defaultValue: AccountAccess? = nil
}

extension EnvironmentValues {
  var accountAccess: AccountAccess? {
    get { self[AccountAccessEnvironmentKey.self] }
    set { self[AccountAccessEnvironmentKey.self] = newValue }
  }
}

enum AccountSessionChangeKind: String, Sendable {
  case login
  case switchAccount
  case removeAccount
  case resetAccounts
}

struct ForumMembershipChange: Equatable, Sendable {
  let accountID: Int64
  let forumID: Int64
  let isFollowed: Bool

  init(accountID: Int64, forumID: Int64, isFollowed: Bool) {
    self.accountID = accountID
    self.forumID = forumID
    self.isFollowed = isFollowed
  }

  init?(_ notification: Notification) {
    guard
      let accountID = notification.userInfo?[AccountNotificationKey.accountID] as? NSNumber,
      let forumID = notification.userInfo?[AccountNotificationKey.forumID] as? NSNumber,
      let isFollowed = notification.userInfo?[AccountNotificationKey.isFollowed] as? NSNumber
    else { return nil }
    self.init(
      accountID: accountID.int64Value,
      forumID: forumID.int64Value,
      isFollowed: isFollowed.boolValue
    )
  }
}

struct ForumCheckInChange: Equatable, Sendable {
  let accountID: Int64
  let sessionRevision: UUID
  let forumID: Int64
  let consecutiveDays: Int
  let rank: Int

  init(
    accountID: Int64,
    sessionRevision: UUID,
    forumID: Int64,
    consecutiveDays: Int,
    rank: Int
  ) {
    self.accountID = accountID
    self.sessionRevision = sessionRevision
    self.forumID = forumID
    self.consecutiveDays = consecutiveDays
    self.rank = rank
  }

  init?(_ notification: Notification) {
    guard
      let accountID = notification.userInfo?[AccountNotificationKey.accountID] as? NSNumber,
      let sessionRevisionValue = notification.userInfo?[AccountNotificationKey.sessionRevision]
        as? String,
      let sessionRevision = UUID(uuidString: sessionRevisionValue),
      let forumID = notification.userInfo?[AccountNotificationKey.forumID] as? NSNumber,
      let consecutiveDays = notification.userInfo?[AccountNotificationKey.consecutiveDays]
        as? NSNumber,
      let rank = notification.userInfo?[AccountNotificationKey.rank] as? NSNumber
    else { return nil }
    self.init(
      accountID: accountID.int64Value,
      sessionRevision: sessionRevision,
      forumID: forumID.int64Value,
      consecutiveDays: consecutiveDays.intValue,
      rank: rank.intValue
    )
  }
}

extension Notification.Name {
  static let accountSessionDidChange = Notification.Name(
    "TiebaPlusPlus.accountSessionDidChange"
  )
  static let forumMembershipDidChange = Notification.Name(
    "TiebaPlusPlus.forumMembershipDidChange"
  )
  static let forumCheckInDidChange = Notification.Name(
    "TiebaPlusPlus.forumCheckInDidChange"
  )
}

@MainActor
enum AccountChangeNotifications {
  static func postSessionChange(
    _ kind: AccountSessionChangeKind,
    accountID: Int64? = nil
  ) {
    var userInfo: [AnyHashable: Any] = [AccountNotificationKey.kind: kind.rawValue]
    if let accountID {
      userInfo[AccountNotificationKey.accountID] = NSNumber(value: accountID)
    }
    NotificationCenter.default.post(
      name: .accountSessionDidChange,
      object: nil,
      userInfo: userInfo
    )
  }

  static func postForumMembershipChange(_ change: ForumMembershipChange) {
    NotificationCenter.default.post(
      name: .forumMembershipDidChange,
      object: nil,
      userInfo: [
        AccountNotificationKey.accountID: NSNumber(value: change.accountID),
        AccountNotificationKey.forumID: NSNumber(value: change.forumID),
        AccountNotificationKey.isFollowed: NSNumber(value: change.isFollowed),
      ]
    )
  }

  static func postForumCheckInChange(_ change: ForumCheckInChange) {
    NotificationCenter.default.post(
      name: .forumCheckInDidChange,
      object: nil,
      userInfo: [
        AccountNotificationKey.accountID: NSNumber(value: change.accountID),
        AccountNotificationKey.sessionRevision: change.sessionRevision.uuidString,
        AccountNotificationKey.forumID: NSNumber(value: change.forumID),
        AccountNotificationKey.consecutiveDays: NSNumber(value: change.consecutiveDays),
        AccountNotificationKey.rank: NSNumber(value: change.rank),
      ]
    )
  }
}

private enum AccountNotificationKey {
  static let kind = "kind"
  static let accountID = "accountID"
  static let sessionRevision = "sessionRevision"
  static let forumID = "forumID"
  static let isFollowed = "isFollowed"
  static let consecutiveDays = "consecutiveDays"
  static let rank = "rank"
}
