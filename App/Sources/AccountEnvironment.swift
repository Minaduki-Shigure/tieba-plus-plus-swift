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

extension Notification.Name {
  static let accountSessionDidChange = Notification.Name(
    "TiebaPlusPlus.accountSessionDidChange"
  )
  static let forumMembershipDidChange = Notification.Name(
    "TiebaPlusPlus.forumMembershipDidChange"
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
}

private enum AccountNotificationKey {
  static let kind = "kind"
  static let accountID = "accountID"
  static let forumID = "forumID"
  static let isFollowed = "isFollowed"
}
