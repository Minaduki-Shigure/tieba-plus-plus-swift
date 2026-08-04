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

protocol AccountService: Sendable {
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount
  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData
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
}

extension AccountService {
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
}
