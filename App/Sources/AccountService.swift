import Foundation

struct ValidatedAccount:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let userID: Int64
  let username: String
  let portrait: String

  var description: String { "ValidatedAccount(userID: \(userID))" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["userID": userID, "username": username], displayStyle: .struct)
  }
}

struct FollowedForumItem: Identifiable, Hashable, Sendable {
  let id: Int64
  let name: String
  let level: Int
  let experience: Int
}

struct FollowedForumPageData: Sendable {
  let forums: [FollowedForumItem]
  let currentPage: Int
  let hasMore: Bool
}

enum InboxKind: String, CaseIterable, Identifiable, Hashable, Sendable {
  case replies
  case mentions

  var id: Self { self }

  var title: String {
    switch self {
    case .replies: "回复我的"
    case .mentions: "提到我的"
    }
  }
}

struct InboxSender: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let isFriend: Bool
  let isFan: Bool

  var preferredName: String {
    for candidate in [displayName, username] {
      let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    return "用户 \(id)"
  }
}

struct InboxMessage: Identifiable, Hashable, Sendable {
  let id: Int64
  let sender: InboxSender
  let quotedUser: InboxSender?
  let threadID: Int64
  let postID: Int64
  let quotedPostID: Int64?
  let title: String
  let content: String
  let quotedContent: String
  let forumName: String
  let createdAt: Date?
  let isFloorReply: Bool
  let isFirstPost: Bool
  let isUnread: Bool
  let threadType: Int

  var threadRoute: TiebaThreadRoute {
    TiebaThreadRoute(
      threadID: threadID,
      postID: isFloorReply ? nil : postID
    )
  }
}

struct InboxPage: Hashable, Sendable {
  let userID: Int64
  let kind: InboxKind
  let messages: [InboxMessage]
  let currentPage: Int
  let hasMore: Bool
}

struct ForumMembershipData: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let forumName: String
  let isFollowed: Bool
}

struct ForumCheckInData: Hashable, Sendable {
  let isCheckedIn: Bool
  let consecutiveDays: Int
  let rank: Int
}

struct ForumAccountStateData: Hashable, Sendable {
  let membership: ForumMembershipData
  let checkIn: ForumCheckInData?
}

struct ThreadAgreementData: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let firstPostID: Int64
  let isAgreed: Bool
  let agreeScore: Int

  init(
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
    self.agreeScore = max(agreeScore, 0)
  }
}

enum ContentAgreementKind: Int32, Hashable, Sendable {
  case post = 1
  case subpost = 2
  case topic = 3
}

struct ContentAgreementTarget: Hashable, Sendable {
  let kind: ContentAgreementKind
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let parentPostID: Int64?
  let objectID: Int64

  init?(
    kind: ContentAgreementKind,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    parentPostID: Int64? = nil,
    objectID: Int64
  ) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard forumID > 0, !forumName.isEmpty, threadID > 0, objectID > 0 else { return nil }
    switch kind {
    case .topic, .post:
      guard parentPostID == nil else { return nil }
    case .subpost:
      guard let parentPostID, parentPostID > 0, parentPostID != objectID else { return nil }
    }
    self.kind = kind
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.objectID = objectID
  }
}

struct ContentAgreementSnapshot: Hashable, Sendable {
  let isAgreed: Bool
  let agreeScore: Int

  init(isAgreed: Bool, agreeScore: Int) {
    self.isAgreed = isAgreed
    self.agreeScore = max(agreeScore, 0)
  }
}

struct ContentAgreementData: Hashable, Sendable {
  let userID: Int64
  let target: ContentAgreementTarget
  let snapshot: ContentAgreementSnapshot

  init(
    userID: Int64,
    target: ContentAgreementTarget,
    isAgreed: Bool,
    agreeScore: Int
  ) {
    self.userID = userID
    self.target = target
    self.snapshot = ContentAgreementSnapshot(isAgreed: isAgreed, agreeScore: agreeScore)
  }
}

struct ContentAgreementPageData: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let agreements: [ContentAgreementData]
}

protocol AccountService: Sendable {
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount
  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData
  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage
  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData
  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData
  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData
  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData
  func threadAgreement(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> ThreadAgreementData
  func setThreadAgreed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> ThreadAgreementData
  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData
  func contentAgreements(
    session: StoredAccountSession,
    descriptor: ContentAgreementReadDescriptor
  ) async throws -> ContentAgreementPageData
  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData
}

extension AccountService {
  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage {
    throw BrowseError.unavailable("当前账户服务不支持读取消息。")
  }

  func threadAgreement(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> ThreadAgreementData {
    throw BrowseError.unavailable("当前账户服务不支持读取主题点赞状态。")
  }

  func setThreadAgreed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> ThreadAgreementData {
    throw BrowseError.unavailable("当前账户服务不支持更新主题点赞状态。")
  }

  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData {
    guard target.kind == .topic else {
      throw BrowseError.unavailable("当前账户服务不支持读取此内容的点赞状态。")
    }
    let agreement = try await threadAgreement(
      session: session,
      forumID: target.forumID,
      forumName: target.forumName,
      threadID: target.threadID,
      firstPostID: target.objectID
    )
    guard
      agreement.userID == session.id,
      agreement.forumID == target.forumID,
      agreement.threadID == target.threadID,
      agreement.firstPostID == target.objectID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的点赞状态，请重新加载后再试。")
    }
    return ContentAgreementData(
      userID: agreement.userID,
      target: target,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  func contentAgreements(
    session: StoredAccountSession,
    descriptor: ContentAgreementReadDescriptor
  ) async throws -> ContentAgreementPageData {
    throw BrowseError.unavailable("当前账户服务不支持批量读取内容点赞状态。")
  }

  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData {
    guard target.kind == .topic else {
      throw BrowseError.unavailable("当前账户服务不支持更新此内容的点赞状态。")
    }
    let agreement = try await setThreadAgreed(
      session: session,
      forumID: target.forumID,
      forumName: target.forumName,
      threadID: target.threadID,
      firstPostID: target.objectID,
      isAgreed: isAgreed
    )
    guard
      agreement.userID == session.id,
      agreement.forumID == target.forumID,
      agreement.threadID == target.threadID,
      agreement.firstPostID == target.objectID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的点赞状态，请重新加载后再试。")
    }
    return ContentAgreementData(
      userID: agreement.userID,
      target: target,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }
}
