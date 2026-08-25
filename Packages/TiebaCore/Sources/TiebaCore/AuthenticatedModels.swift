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

public enum TiebaBDUSSCookieName: String, Codable, Sendable, Hashable {
  case bduss = "BDUSS"
  case bdussBFESS = "BDUSS_BFESS"
}

public struct TiebaSessionCredential:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let bduss: String
  public let stoken: String
  public let bdussCookieName: TiebaBDUSSCookieName

  public init(
    bduss: String,
    stoken: String,
    bdussCookieName: TiebaBDUSSCookieName
  ) {
    self.bduss = bduss
    self.stoken = stoken
    self.bdussCookieName = bdussCookieName
  }

  public var bdussCredential: TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: bduss)
  }

  public var description: String { "TiebaSessionCredential(redacted)" }
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

public struct TiebaSelfProfileSummary: Sendable, Hashable {
  public let userID: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let biography: String
  public let followingCount: Int
  public let followerCount: Int
  public let postCount: Int

  public init(
    userID: Int64,
    username: String,
    displayName: String,
    portrait: String,
    biography: String,
    followingCount: Int,
    followerCount: Int,
    postCount: Int
  ) {
    self.userID = userID
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.biography = biography
    self.followingCount = followingCount
    self.followerCount = followerCount
    self.postCount = postCount
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaUserRelationship: Sendable, Hashable {
  public let userID: Int64
  public let targetUserID: Int64
  public let isFollowed: Bool

  public init(userID: Int64, targetUserID: Int64, isFollowed: Bool) {
    self.userID = userID
    self.targetUserID = targetUserID
    self.isFollowed = isFollowed
  }
}

public struct TiebaUserInteractionPermissions: Sendable, Hashable {
  public let blocksFollow: Bool
  public let blocksInteraction: Bool
  public let blocksChat: Bool

  public init(blocksFollow: Bool, blocksInteraction: Bool, blocksChat: Bool) {
    self.blocksFollow = blocksFollow
    self.blocksInteraction = blocksInteraction
    self.blocksChat = blocksChat
  }
}

public struct TiebaUserInteractionPermissionState: Sendable, Hashable {
  public let userID: Int64
  public let targetUserID: Int64
  public let permissions: TiebaUserInteractionPermissions

  public init(
    userID: Int64,
    targetUserID: Int64,
    permissions: TiebaUserInteractionPermissions
  ) {
    self.userID = userID
    self.targetUserID = targetUserID
    self.permissions = permissions
  }
}

public struct TiebaPollState: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let poll: TiebaPoll

  public init(userID: Int64, forumID: Int64, threadID: Int64, poll: TiebaPoll) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.poll = poll
  }
}

public struct TiebaConcernPage: Sendable, Hashable {
  public let requestedUserID: Int64
  public let threads: [TiebaThread]
  public let nextPageTag: String?
  public let hasMore: Bool
  public let requestUnix: UInt64

  public init(
    requestedUserID: Int64,
    threads: [TiebaThread],
    nextPageTag: String?,
    hasMore: Bool,
    requestUnix: UInt64
  ) {
    self.requestedUserID = requestedUserID
    self.threads = threads
    self.nextPageTag = nextPageTag
    self.hasMore = hasMore
    self.requestUnix = requestUnix
  }
}

public struct TiebaForumLevelProgress: Sendable, Hashable {
  public static let levelNameMaximumCharacters = 64
  public static let levelNameMaximumUTF8Bytes = 256

  public let level: Int
  public let levelName: String
  public let currentExperience: Int
  public let targetExperience: Int

  public init?(
    level: Int,
    levelName: String,
    currentExperience: Int,
    targetExperience: Int
  ) {
    let normalizedLevelName = levelName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      level > 0,
      !normalizedLevelName.isEmpty,
      normalizedLevelName.count <= Self.levelNameMaximumCharacters,
      normalizedLevelName.utf8.count <= Self.levelNameMaximumUTF8Bytes,
      !normalizedLevelName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      currentExperience >= 0,
      targetExperience > 0
    else { return nil }

    self.level = level
    self.levelName = normalizedLevelName
    self.currentExperience = currentExperience
    self.targetExperience = targetExperience
  }
}

public struct TiebaFollowedForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let level: Int
  public let experience: Int
  public let avatar: String
  public let slogan: String
  public let levelProgress: TiebaForumLevelProgress?

  public init(
    id: Int64,
    name: String,
    level: Int,
    experience: Int,
    avatar: String = "",
    slogan: String = "",
    levelProgress: TiebaForumLevelProgress? = nil
  ) {
    self.id = id
    self.name = name
    self.level = level
    self.experience = experience
    self.avatar = avatar
    self.slogan = slogan
    self.levelProgress = levelProgress
  }
}

public struct TiebaFollowedForumPage: Sendable, Hashable {
  public let accountUserID: Int64
  public let targetUserID: Int64
  public let forums: [TiebaFollowedForum]
  public let pagination: TiebaPagination

  public init(
    accountUserID: Int64,
    targetUserID: Int64,
    forums: [TiebaFollowedForum],
    pagination: TiebaPagination
  ) {
    self.accountUserID = accountUserID
    self.targetUserID = targetUserID
    self.forums = forums
    self.pagination = pagination
  }
}

public struct TiebaCloudFavoriteAuthor: Sendable, Hashable {
  public let userID: Int64?
  public let username: String
  public let displayName: String
  public let portrait: String

  public init(
    userID: Int64?,
    username: String,
    displayName: String,
    portrait: String
  ) {
    self.userID = userID
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaCloudFavorite: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let title: String
  public let forumName: String
  public let author: TiebaCloudFavoriteAuthor
  public let isDeleted: Bool
  public let lastTimestamp: Int64
  public let threadType: Int
  public let status: Int
  public let maximumPostID: Int64
  public let minimumPostID: Int64
  public let markedPostID: Int64
  public let markStatus: Int
  public let postNumber: Int
  public let postNumberMessage: String
  public let updateCount: Int

  public init(
    id: Int64,
    title: String,
    forumName: String,
    author: TiebaCloudFavoriteAuthor,
    isDeleted: Bool,
    lastTimestamp: Int64,
    threadType: Int,
    status: Int,
    maximumPostID: Int64,
    minimumPostID: Int64,
    markedPostID: Int64,
    markStatus: Int,
    postNumber: Int,
    postNumberMessage: String,
    updateCount: Int
  ) {
    self.id = id
    self.title = title
    self.forumName = forumName
    self.author = author
    self.isDeleted = isDeleted
    self.lastTimestamp = lastTimestamp
    self.threadType = threadType
    self.status = status
    self.maximumPostID = maximumPostID
    self.minimumPostID = minimumPostID
    self.markedPostID = markedPostID
    self.markStatus = markStatus
    self.postNumber = postNumber
    self.postNumberMessage = postNumberMessage
    self.updateCount = updateCount
  }
}

public struct TiebaCloudFavoritePage: Sendable, Hashable {
  public let requestedUserID: Int64
  public let favorites: [TiebaCloudFavorite]
  public let offset: Int
  public let pageSize: Int
  public let hasMore: Bool

  public init(
    requestedUserID: Int64,
    favorites: [TiebaCloudFavorite],
    offset: Int,
    pageSize: Int,
    hasMore: Bool
  ) {
    self.requestedUserID = requestedUserID
    self.favorites = favorites
    self.offset = offset
    self.pageSize = pageSize
    self.hasMore = hasMore
  }

  public var nextOffset: Int { offset + pageSize }
}

public struct TiebaThreadCloudFavoriteState: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let markedPostID: Int64?

  public init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.markedPostID = markedPostID
  }

  public var isFavorited: Bool { markedPostID != nil }
}

public enum TiebaNotificationKind: Sendable, Hashable {
  case replies
  case mentions
}

public struct TiebaInboxUnreadSummary: Sendable, Hashable {
  public let userID: Int64
  public let replyCount: Int
  public let mentionCount: Int
  public let fanCount: Int?

  public init(
    userID: Int64,
    replyCount: Int,
    mentionCount: Int,
    fanCount: Int? = nil
  ) {
    self.userID = userID
    self.replyCount = replyCount
    self.mentionCount = mentionCount
    self.fanCount = fanCount
  }

  public var totalCount: Int {
    let replyCount = max(replyCount, 0)
    let mentionCount = max(mentionCount, 0)
    let sum = replyCount.addingReportingOverflow(mentionCount)
    return sum.overflow ? Int.max : sum.partialValue
  }
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
  public let levelProgress: TiebaForumLevelProgress?

  public init(
    membership: TiebaForumMembership,
    checkIn: TiebaForumCheckIn?,
    levelProgress: TiebaForumLevelProgress? = nil
  ) {
    self.membership = membership
    self.checkIn = checkIn
    self.levelProgress = levelProgress
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

public enum TiebaOwnedContentDeletionTarget: Sendable, Hashable {
  case thread(firstPostID: Int64)
  case post(postID: Int64)
}

public struct TiebaOwnedContentDeletionReceipt: Sendable, Hashable {
  public let userID: Int64
  public let forumID: Int64
  public let threadID: Int64
  public let target: TiebaOwnedContentDeletionTarget

  public init(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaOwnedContentDeletionTarget
  ) {
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.target = target
  }
}
