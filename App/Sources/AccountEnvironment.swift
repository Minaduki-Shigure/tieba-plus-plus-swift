import Foundation
import SwiftUI

struct AccountAccess: Sendable {
  let vault: any AccountVault
  let service: any AccountService
  let forumMembershipMutator: any ForumMembershipMutating

  init(
    vault: any AccountVault,
    service: any AccountService,
    forumMembershipMutator: (any ForumMembershipMutating)? = nil
  ) {
    self.vault = vault
    self.service = service
    self.forumMembershipMutator = forumMembershipMutator
      ?? ForumMembershipMutationCoordinator(vault: vault, service: service)
  }
}

private struct AccountAccessEnvironmentKey: EnvironmentKey {
  static let defaultValue: AccountAccess? = nil
}

private struct ContentAgreementStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: ContentAgreementStore? = nil
}

private struct ThreadCloudFavoriteStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: ThreadCloudFavoriteStore? = nil
}

private struct OwnedContentDeletionStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: OwnedContentDeletionStore? = nil
}

private struct TextReplySubmissionStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: TextReplySubmissionStore? = nil
}

private struct NewThreadSubmissionStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: NewThreadSubmissionStore? = nil
}

private struct ComposerImageAttachmentStoreEnvironmentKey: EnvironmentKey {
  static let defaultValue: ComposerImageAttachmentStore? = nil
}

extension EnvironmentValues {
  var accountAccess: AccountAccess? {
    get { self[AccountAccessEnvironmentKey.self] }
    set { self[AccountAccessEnvironmentKey.self] = newValue }
  }

  var contentAgreementStore: ContentAgreementStore? {
    get { self[ContentAgreementStoreEnvironmentKey.self] }
    set { self[ContentAgreementStoreEnvironmentKey.self] = newValue }
  }

  var threadCloudFavoriteStore: ThreadCloudFavoriteStore? {
    get { self[ThreadCloudFavoriteStoreEnvironmentKey.self] }
    set { self[ThreadCloudFavoriteStoreEnvironmentKey.self] = newValue }
  }

  var ownedContentDeletionStore: OwnedContentDeletionStore? {
    get { self[OwnedContentDeletionStoreEnvironmentKey.self] }
    set { self[OwnedContentDeletionStoreEnvironmentKey.self] = newValue }
  }

  var textReplySubmissionStore: TextReplySubmissionStore? {
    get { self[TextReplySubmissionStoreEnvironmentKey.self] }
    set { self[TextReplySubmissionStoreEnvironmentKey.self] = newValue }
  }

  var newThreadSubmissionStore: NewThreadSubmissionStore? {
    get { self[NewThreadSubmissionStoreEnvironmentKey.self] }
    set { self[NewThreadSubmissionStoreEnvironmentKey.self] = newValue }
  }

  var composerImageAttachmentStore: ComposerImageAttachmentStore? {
    get { self[ComposerImageAttachmentStoreEnvironmentKey.self] }
    set { self[ComposerImageAttachmentStoreEnvironmentKey.self] = newValue }
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
  let sessionRevision: UUID?
  let forumID: Int64
  let isFollowed: Bool

  init(
    accountID: Int64,
    sessionRevision: UUID? = nil,
    forumID: Int64,
    isFollowed: Bool
  ) {
    self.accountID = accountID
    self.sessionRevision = sessionRevision
    self.forumID = forumID
    self.isFollowed = isFollowed
  }

  init?(_ notification: Notification) {
    guard
      let accountID = notification.userInfo?[AccountNotificationKey.accountID] as? NSNumber,
      let forumID = notification.userInfo?[AccountNotificationKey.forumID] as? NSNumber,
      let isFollowed = notification.userInfo?[AccountNotificationKey.isFollowed] as? NSNumber
    else { return nil }
    let sessionRevision: UUID?
    if let value = notification.userInfo?[AccountNotificationKey.sessionRevision] {
      guard let rawValue = value as? String, let revision = UUID(uuidString: rawValue) else {
        return nil
      }
      sessionRevision = revision
    } else {
      sessionRevision = nil
    }
    self.init(
      accountID: accountID.int64Value,
      sessionRevision: sessionRevision,
      forumID: forumID.int64Value,
      isFollowed: isFollowed.boolValue
    )
  }
}

struct UserRelationshipChange: Equatable, Sendable {
  let accountID: Int64
  let sessionRevision: UUID
  let targetUserID: Int64
  let isFollowed: Bool

  init(
    accountID: Int64,
    sessionRevision: UUID,
    targetUserID: Int64,
    isFollowed: Bool
  ) {
    self.accountID = accountID
    self.sessionRevision = sessionRevision
    self.targetUserID = targetUserID
    self.isFollowed = isFollowed
  }

  init?(_ notification: Notification) {
    guard
      let accountID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.accountID]
      ),
      let sessionRevisionValue = notification.userInfo?[AccountNotificationKey.sessionRevision]
        as? String,
      let sessionRevision = UUID(uuidString: sessionRevisionValue),
      let targetUserID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.targetUserID]
      ),
      let isFollowed = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.isFollowed]
      ),
      accountID > 0,
      targetUserID > 0,
      accountID != targetUserID,
      isFollowed == 0 || isFollowed == 1
    else { return nil }
    self.init(
      accountID: accountID,
      sessionRevision: sessionRevision,
      targetUserID: targetUserID,
      isFollowed: isFollowed == 1
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

struct ThreadAgreementChange: Equatable, Sendable {
  let accountID: Int64
  let sessionRevision: UUID
  let forumID: Int64
  let threadID: Int64
  let firstPostID: Int64
  let isAgreed: Bool
  let agreeScore: Int

  init(
    accountID: Int64,
    sessionRevision: UUID,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool,
    agreeScore: Int
  ) {
    self.accountID = accountID
    self.sessionRevision = sessionRevision
    self.forumID = forumID
    self.threadID = threadID
    self.firstPostID = firstPostID
    self.isAgreed = isAgreed
    self.agreeScore = max(agreeScore, 0)
  }

  init?(_ notification: Notification) {
    guard
      let accountID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.accountID]
      ),
      let sessionRevisionValue = notification.userInfo?[AccountNotificationKey.sessionRevision]
        as? String,
      let sessionRevision = UUID(uuidString: sessionRevisionValue),
      let forumID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.forumID]
      ),
      let threadID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.threadID]
      ),
      let firstPostID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.firstPostID]
      ),
      let isAgreed = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.isAgreed]
      ),
      let agreeScoreValue = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.agreeScore]
      ),
      let agreeScore = Int(exactly: agreeScoreValue),
      accountID > 0,
      forumID > 0,
      threadID > 0,
      firstPostID > 0,
      isAgreed == 0 || isAgreed == 1
    else { return nil }
    self.init(
      accountID: accountID,
      sessionRevision: sessionRevision,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: isAgreed == 1,
      agreeScore: agreeScore
    )
  }
}

struct ThreadCloudFavoriteChange: Equatable, Sendable {
  let accountID: Int64
  let sessionRevision: UUID
  let target: ThreadCloudFavoriteTarget
  let snapshot: ThreadCloudFavoriteSnapshot

  init(
    accountID: Int64,
    sessionRevision: UUID,
    target: ThreadCloudFavoriteTarget,
    snapshot: ThreadCloudFavoriteSnapshot
  ) {
    self.accountID = accountID
    self.sessionRevision = sessionRevision
    self.target = target
    self.snapshot = snapshot
  }

  init?(_ notification: Notification) {
    guard
      let accountID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.accountID]
      ),
      let sessionRevisionValue = notification.userInfo?[AccountNotificationKey.sessionRevision]
        as? String,
      let sessionRevision = UUID(uuidString: sessionRevisionValue),
      let forumID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.forumID]
      ),
      let forumName = notification.userInfo?[AccountNotificationKey.forumName] as? String,
      let threadID = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.threadID]
      ),
      let isFavorited = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.isFavorited]
      ),
      accountID > 0,
      isFavorited == 0 || isFavorited == 1,
      let target = ThreadCloudFavoriteTarget(
        forumID: forumID,
        forumName: forumName,
        threadID: threadID
      )
    else { return nil }

    let markedPostID: Int64?
    if isFavorited == 1 {
      guard let value = accountNotificationInt64(
        notification.userInfo?[AccountNotificationKey.markedPostID]
      ) else { return nil }
      markedPostID = value
    } else {
      guard notification.userInfo?[AccountNotificationKey.markedPostID] == nil else {
        return nil
      }
      markedPostID = nil
    }
    guard let snapshot = ThreadCloudFavoriteSnapshot(markedPostID: markedPostID) else {
      return nil
    }
    self.init(
      accountID: accountID,
      sessionRevision: sessionRevision,
      target: target,
      snapshot: snapshot
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
  static let userRelationshipDidChange = Notification.Name(
    "TiebaPlusPlus.userRelationshipDidChange"
  )
  static let forumCheckInDidChange = Notification.Name(
    "TiebaPlusPlus.forumCheckInDidChange"
  )
  static let threadAgreementDidChange = Notification.Name(
    "TiebaPlusPlus.threadAgreementDidChange"
  )
  static let threadCloudFavoriteDidChange = Notification.Name(
    "TiebaPlusPlus.threadCloudFavoriteDidChange"
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
    var userInfo: [AnyHashable: Any] = [
      AccountNotificationKey.accountID: NSNumber(value: change.accountID),
      AccountNotificationKey.forumID: NSNumber(value: change.forumID),
      AccountNotificationKey.isFollowed: NSNumber(value: change.isFollowed),
    ]
    if let sessionRevision = change.sessionRevision {
      userInfo[AccountNotificationKey.sessionRevision] = sessionRevision.uuidString
    }
    NotificationCenter.default.post(
      name: .forumMembershipDidChange,
      object: nil,
      userInfo: userInfo
    )
  }

  static func postUserRelationshipChange(_ change: UserRelationshipChange) {
    NotificationCenter.default.post(
      name: .userRelationshipDidChange,
      object: nil,
      userInfo: [
        AccountNotificationKey.accountID: NSNumber(value: change.accountID),
        AccountNotificationKey.sessionRevision: change.sessionRevision.uuidString,
        AccountNotificationKey.targetUserID: NSNumber(value: change.targetUserID),
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

  static func postThreadAgreementChange(_ change: ThreadAgreementChange) {
    NotificationCenter.default.post(
      name: .threadAgreementDidChange,
      object: nil,
      userInfo: [
        AccountNotificationKey.accountID: NSNumber(value: change.accountID),
        AccountNotificationKey.sessionRevision: change.sessionRevision.uuidString,
        AccountNotificationKey.forumID: NSNumber(value: change.forumID),
        AccountNotificationKey.threadID: NSNumber(value: change.threadID),
        AccountNotificationKey.firstPostID: NSNumber(value: change.firstPostID),
        AccountNotificationKey.isAgreed: NSNumber(value: change.isAgreed),
        AccountNotificationKey.agreeScore: NSNumber(value: change.agreeScore),
      ]
    )
  }

  static func postThreadCloudFavoriteChange(_ change: ThreadCloudFavoriteChange) {
    var userInfo: [AnyHashable: Any] = [
      AccountNotificationKey.accountID: NSNumber(value: change.accountID),
      AccountNotificationKey.sessionRevision: change.sessionRevision.uuidString,
      AccountNotificationKey.forumID: NSNumber(value: change.target.forumID),
      AccountNotificationKey.forumName: change.target.forumName,
      AccountNotificationKey.threadID: NSNumber(value: change.target.threadID),
      AccountNotificationKey.isFavorited: NSNumber(value: change.snapshot.isFavorited),
    ]
    if let markedPostID = change.snapshot.markedPostID {
      userInfo[AccountNotificationKey.markedPostID] = NSNumber(value: markedPostID)
    }
    NotificationCenter.default.post(
      name: .threadCloudFavoriteDidChange,
      object: nil,
      userInfo: userInfo
    )
  }
}

private enum AccountNotificationKey {
  static let kind = "kind"
  static let accountID = "accountID"
  static let sessionRevision = "sessionRevision"
  static let forumID = "forumID"
  static let forumName = "forumName"
  static let targetUserID = "targetUserID"
  static let isFollowed = "isFollowed"
  static let consecutiveDays = "consecutiveDays"
  static let rank = "rank"
  static let threadID = "threadID"
  static let firstPostID = "firstPostID"
  static let isAgreed = "isAgreed"
  static let agreeScore = "agreeScore"
  static let isFavorited = "isFavorited"
  static let markedPostID = "markedPostID"
}

private func accountNotificationInt64(_ value: Any?) -> Int64? {
  guard let number = value as? NSNumber else { return nil }
  return Int64(number.stringValue)
}
