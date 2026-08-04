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
  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData
}
