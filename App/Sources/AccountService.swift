import Foundation
import TiebaCore

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
  let avatarURL: URL?
  let slogan: String

  init(
    id: Int64,
    name: String,
    level: Int,
    experience: Int,
    avatarURL: URL? = nil,
    slogan: String = ""
  ) {
    self.id = id
    self.name = name
    self.level = level
    self.experience = experience
    self.avatarURL = avatarURL
    self.slogan = slogan
  }
}

struct FollowedForumPageData: Sendable {
  let forums: [FollowedForumItem]
  let currentPage: Int
  let hasMore: Bool
}

struct UserLikedForumPageData: Hashable, Sendable {
  let accountUserID: Int64
  let targetUserID: Int64
  let forums: [FollowedForumItem]
  let currentPage: Int
  let hasMore: Bool
}

struct AccountProfileSummary: Hashable, Sendable {
  let userID: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let biography: String
  let followingCount: Int
  let followerCount: Int
  let postCount: Int

  var preferredName: String {
    for candidate in [displayName, username] {
      let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    return "用户 \(userID)"
  }
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

enum InboxNavigationTarget: Hashable, Sendable {
  case thread(TiebaThreadRoute)
  case comment(threadID: Int64, commentID: Int64)
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

  var navigationTarget: InboxNavigationTarget {
    if isFloorReply {
      // quote_pid may name a parent or another reply; resolve postID as spid instead.
      return .comment(threadID: threadID, commentID: postID)
    }
    return .thread(TiebaThreadRoute(threadID: threadID, postID: postID))
  }
}

struct InboxPage: Hashable, Sendable {
  let userID: Int64
  let kind: InboxKind
  let messages: [InboxMessage]
  let currentPage: Int
  let hasMore: Bool
}

struct InboxUnreadSummary: Hashable, Sendable {
  let userID: Int64
  let replyCount: Int
  let mentionCount: Int
  let fanCount: Int?

  var totalCount: Int {
    let replyCount = max(replyCount, 0)
    let mentionCount = max(mentionCount, 0)
    let sum = replyCount.addingReportingOverflow(mentionCount)
    return sum.overflow ? Int.max : sum.partialValue
  }
}

struct CloudFavoriteThread: Identifiable, Hashable, Sendable {
  let id: Int64
  let title: String
  let forumName: String
  let authorName: String
  let markPostID: Int64?
  let latestPostID: Int64?
  let latestFloor: Int?
  let hasUpdates: Bool
  let isDeleted: Bool
  let updatedAt: Date?

  var threadRoute: TiebaThreadRoute {
    TiebaThreadRoute(threadID: id, postID: markPostID)
  }

  func navigation(
    applying overrides: FavoriteThreadOpenOverrides
  ) -> CloudFavoriteThreadNavigation {
    CloudFavoriteThreadNavigation(
      route: threadRoute,
      options: overrides.applying(to: threadRoute.options)
    )
  }
}

struct CloudFavoriteThreadNavigation: Hashable, Sendable {
  let route: TiebaThreadRoute
  let options: ThreadBrowseOptions
}

struct CloudFavoritePage: Hashable, Sendable {
  let userID: Int64
  let items: [CloudFavoriteThread]
  let nextOffset: Int?
  let hasMore: Bool
}

struct ThreadCloudFavoriteTarget: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
  let threadID: Int64

  init?(forumID: Int64, forumName: String, threadID: Int64) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      forumID > 0,
      threadID > 0,
      !forumName.isEmpty,
      forumName.count <= 100,
      !forumName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
  }
}

struct ThreadCloudFavoriteSnapshot: Hashable, Sendable {
  let markedPostID: Int64?

  var isFavorited: Bool { markedPostID != nil }

  init?(markedPostID: Int64?) {
    guard markedPostID.map({ $0 > 0 }) ?? true else { return nil }
    self.markedPostID = markedPostID
  }
}

struct ThreadCloudFavoriteData: Hashable, Sendable {
  let userID: Int64
  let target: ThreadCloudFavoriteTarget
  let snapshot: ThreadCloudFavoriteSnapshot
}

struct ConcernFeedPageData: Hashable, Sendable {
  let userID: Int64
  let threads: [BrowseThread]
  let nextPageTag: String?
  let hasMore: Bool
  let requestUnix: UInt64
}

struct UserRelationshipData: Hashable, Sendable {
  let userID: Int64
  let targetUserID: Int64
  let isFollowed: Bool
}

struct UserInteractionPermissions: Hashable, Sendable {
  var blocksFollow: Bool
  var blocksInteraction: Bool
  var blocksChat: Bool

  static let unrestricted = UserInteractionPermissions(
    blocksFollow: false,
    blocksInteraction: false,
    blocksChat: false
  )
}

struct UserInteractionPermissionData: Hashable, Sendable {
  let userID: Int64
  let targetUserID: Int64
  let permissions: UserInteractionPermissions
}

enum UserInteractionPermissionError: LocalizedError, Equatable, Sendable {
  case fullCredentialsRequired
  case outcomeUnknown
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全读取或更新互动权限。"
    case .outcomeUnknown:
      "贴吧尚未确认互动权限是否保存成功。请重新加载权威状态后再决定是否重试。"
    case .unavailable(let message):
      message
    }
  }
}

struct PollVoteData: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let poll: BrowsePoll
}

enum PollVoteError: LocalizedError, Equatable, Sendable {
  case invalidSelection
  case fullCredentialsRequired
  case outcomeUnknown
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidSelection:
      "请选择有效的投票选项。"
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全参与投票。"
    case .outcomeUnknown:
      "贴吧尚未确认投票结果。请重新加载权威状态后再决定是否重试。"
    case .unavailable(let message):
      message
    }
  }
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

enum ForumCheckInCatalogStatus: Hashable, Sendable {
  case unknown
  case pending
  case checkedIn
}

struct ForumCheckInCatalogTarget: Hashable, Identifiable, Sendable {
  let forumID: Int64
  let forumName: String
  let level: Int
  let status: ForumCheckInCatalogStatus
  let isForbidden: Bool

  var id: Int64 { forumID }
}

struct ForumOfficialBatchCheckInPolicy: Hashable, Sendable {
  let minimumLevel: Int
  let maximumForumCount: Int
}

struct ForumCheckInCatalogData: Hashable, Sendable {
  let userID: Int64
  let targets: [ForumCheckInCatalogTarget]
  let officialBatchPolicy: ForumOfficialBatchCheckInPolicy?
}

struct ForumBatchCheckInTarget: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
}

enum ForumBatchCheckInError: LocalizedError, Equatable, Sendable {
  case authorizationChanged
  case outcomeUnknown(dispatchedTargets: [ForumBatchCheckInTarget])

  var errorDescription: String? {
    switch self {
    case .authorizationChanged:
      "可签到贴吧已发生变化，本次没有发送官方批量签到。请重新读取状态并再次确认。"
    case .outcomeUnknown:
      "官方批量签到已经发送，但贴吧未返回可验证的最终结果。应用不会自动重试。"
    }
  }
}

enum ForumBatchCheckInOutcome: Hashable, Sendable {
  case confirmedSigned
  case rejected(message: String)
}

struct ForumBatchCheckInResult: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
  let outcome: ForumBatchCheckInOutcome
}

struct ForumBatchCheckInData: Hashable, Sendable {
  let userID: Int64
  let results: [ForumBatchCheckInResult]
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

enum OwnedContentDeletionKind: Hashable, Sendable {
  case topic
  case post
}

struct OwnedContentDeletionTarget: Hashable, Sendable {
  let kind: OwnedContentDeletionKind
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let objectID: Int64
  let authorID: Int64
  let floor: Int

  init?(
    kind: OwnedContentDeletionKind,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    objectID: Int64,
    authorID: Int64,
    floor: Int
  ) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      forumID > 0,
      !forumName.isEmpty,
      forumName.count <= 100,
      !forumName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      threadID > 0,
      objectID > 0,
      authorID > 0
    else { return nil }
    switch kind {
    case .topic:
      guard floor == 1 else { return nil }
    case .post:
      guard floor > 1 else { return nil }
    }
    self.kind = kind
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.objectID = objectID
    self.authorID = authorID
    self.floor = floor
  }

  init?(thread: BrowseThread, post: BrowsePost) {
    guard
      thread.id > 0,
      post.threadID == thread.id,
      post.localVisibility == .visible,
      thread.localVisibility == .visible
    else { return nil }
    if post.floor == 1 {
      guard
        thread.firstPostID == post.id,
        thread.authorID > 0,
        thread.authorID == post.authorID
      else { return nil }
      self.init(
        kind: .topic,
        forumID: thread.forumID,
        forumName: thread.forumName,
        threadID: thread.id,
        objectID: post.id,
        authorID: post.authorID,
        floor: post.floor
      )
    } else {
      guard post.floor > 1, post.id != thread.firstPostID else { return nil }
      self.init(
        kind: .post,
        forumID: thread.forumID,
        forumName: thread.forumName,
        threadID: thread.id,
        objectID: post.id,
        authorID: post.authorID,
        floor: post.floor
      )
    }
  }
}

struct OwnedContentDeletionReceipt: Hashable, Sendable {
  let accountID: Int64
  let sessionRevision: UUID
  let target: OwnedContentDeletionTarget
}

enum OwnedContentDeletionError: LocalizedError, Equatable, Sendable {
  case definitelyNotAccepted(String)
  case rejected(code: Int32)
  case unavailable(String)
  case outcomeUnknown

  var errorDescription: String? {
    switch self {
    case .definitelyNotAccepted(let message):
      message
    case .rejected(let code):
      "贴吧拒绝了删除请求（错误码 \(code)），请重新加载后再试。"
    case .unavailable(let message):
      message
    case .outcomeUnknown:
      "删除请求可能已经发出，但贴吧未能确认结果。请在官方客户端核对，勿立即重试。"
    }
  }
}

struct ComposerImageUploadResult:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let sessionRevision: UUID
  let attachment: ComposerImageAttachment
  let watermark: TiebaStaticImageWatermark
  let receipt: TiebaStaticImageUploadReceipt
  let proof: TiebaStaticImageContentProof

  var description: String { "ComposerImageUploadResult(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

struct ComposerPreparedImageUpload:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let sessionUserID: Int64
  let sessionRevision: UUID
  let credential: AccountCredentials
  let submissionID: UUID
  let forumID: Int64
  let forumName: String
  let attachment: ComposerImageAttachment
  let validatedBytes: Data
  let watermark: TiebaStaticImageWatermark
  let coreUpload: TiebaStaticImageUpload
  let expectedChunkCount: Int

  var description: String { "ComposerPreparedImageUpload(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

enum ComposerImageUploadPreparationError:
  LocalizedError, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case fullCredentialsRequired
  case invalidUpload
  case unavailable

  var errorDescription: String? {
    switch self {
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全准备图片上传。"
    case .invalidUpload:
      "图片、贴吧或上传选项与当前提交不匹配，未开始上传。"
    case .unavailable:
      "当前账户服务无法准备图片上传。"
    }
  }

  var description: String {
    switch self {
    case .fullCredentialsRequired:
      "ComposerImageUploadPreparationError.fullCredentialsRequired"
    case .invalidUpload:
      "ComposerImageUploadPreparationError.invalidUpload(redacted)"
    case .unavailable:
      "ComposerImageUploadPreparationError.unavailable(redacted)"
    }
  }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

enum ComposerImageUploadError:
  LocalizedError, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case preparedUploadRejected
  case invalidReceipt
  case uploadConflict
  case outcomeUnknown(attachment: ComposerImageAttachment, dispatchedChunk: Int)
  case server(code: Int32)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .preparedUploadRejected:
      "已准备的图片上传请求未被上传客户端接受；附件已保留。"
    case .invalidReceipt:
      "贴吧返回的图片上传回执无法验证；附件已保留。"
    case .uploadConflict:
      "图片上传请求标识发生冲突，未再次上传。"
    case .outcomeUnknown:
      "图片分片已经发出，但贴吧未返回可验证的结果；请保留附件并从恢复记录继续。"
    case .server(let code):
      "贴吧拒绝了图片上传（错误码 \(code)）；附件已保留。"
    case .unavailable:
      "暂时无法上传图片，附件已保留。"
    }
  }

  var description: String {
    switch self {
    case .preparedUploadRejected:
      "ComposerImageUploadError.preparedUploadRejected(redacted)"
    case .invalidReceipt:
      "ComposerImageUploadError.invalidReceipt(redacted)"
    case .uploadConflict:
      "ComposerImageUploadError.uploadConflict(redacted)"
    case .outcomeUnknown:
      "ComposerImageUploadError.outcomeUnknown(redacted)"
    case .server:
      "ComposerImageUploadError.server(redacted)"
    case .unavailable:
      "ComposerImageUploadError.unavailable(redacted)"
    }
  }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }
}

protocol AccountService: Sendable {
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount
  func selfProfile(
    session: StoredAccountSession
  ) async throws -> AccountProfileSummary
  func ownFollowing(
    session: StoredAccountSession,
    page: Int
  ) async throws -> UserRelationPageData
  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData
  func likedForums(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> UserLikedForumPageData
  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage
  func inboxUnreadSummary(
    session: StoredAccountSession
  ) async throws -> InboxUnreadSummary
  func cloudFavorites(
    session: StoredAccountSession,
    offset: Int,
    pageSize: Int
  ) async throws -> CloudFavoritePage
  func threadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteData
  func setThreadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteData
  nonisolated func prepareStaticImageUpload(
    session: StoredAccountSession,
    submissionID: UUID,
    forumID: Int64,
    forumName: String,
    attachment: ComposerImageAttachment,
    validatedBytes: Data,
    watermark: TiebaStaticImageWatermark
  ) async throws -> ComposerPreparedImageUpload
  func dispatchStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload
  ) async throws -> ComposerImageUploadResult
  nonisolated func recoverStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload,
    authenticatedReceipt: TiebaStaticImageUploadReceipt
  ) async throws -> ComposerImageUploadResult
  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission
  ) async throws -> TextReplyResult
  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> TextReplyResult
  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission
  ) async throws -> NewThreadResult
  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadResult
  func verifyNewThreadVisibility(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    receipt: NewThreadReceipt
  ) async throws -> NewThreadVisibilityConfirmation?
  func verifyNewThreadVisibility(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    receipt: NewThreadReceipt,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadVisibilityConfirmation?
  func concernFeed(
    session: StoredAccountSession,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> ConcernFeedPageData
  func userRelationship(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserRelationshipData
  func setUserFollowed(
    session: StoredAccountSession,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> UserRelationshipData
  func userInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserInteractionPermissionData
  func setUserInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64,
    permissions: UserInteractionPermissions
  ) async throws -> UserInteractionPermissionData
  func pollState(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64
  ) async throws -> PollVoteData
  func submitPollVote(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: Set<Int32>
  ) async throws -> PollVoteData
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
  func checkInCatalog(
    session: StoredAccountSession
  ) async throws -> ForumCheckInCatalogData
  func batchCheckIn(
    session: StoredAccountSession,
    authorizedTargets: [ForumBatchCheckInTarget]
  ) async throws -> ForumBatchCheckInData
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
  func deleteOwnedContent(
    session: StoredAccountSession,
    target: OwnedContentDeletionTarget
  ) async throws -> OwnedContentDeletionReceipt
}

extension AccountService {
  func deleteOwnedContent(
    session: StoredAccountSession,
    target: OwnedContentDeletionTarget
  ) async throws -> OwnedContentDeletionReceipt {
    throw OwnedContentDeletionError.definitelyNotAccepted(
      "当前账户服务不支持删除内容。"
    )
  }

  nonisolated func prepareStaticImageUpload(
    session: StoredAccountSession,
    submissionID: UUID,
    forumID: Int64,
    forumName: String,
    attachment: ComposerImageAttachment,
    validatedBytes: Data,
    watermark: TiebaStaticImageWatermark
  ) async throws -> ComposerPreparedImageUpload {
    throw ComposerImageUploadPreparationError.unavailable
  }

  func dispatchStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload
  ) async throws -> ComposerImageUploadResult {
    throw ComposerImageUploadError.unavailable
  }

  nonisolated func recoverStaticImageUpload(
    _ prepared: ComposerPreparedImageUpload,
    authenticatedReceipt: TiebaStaticImageUploadReceipt
  ) async throws -> ComposerImageUploadResult {
    throw ComposerImageUploadError.unavailable
  }

  func checkInCatalog(
    session: StoredAccountSession
  ) async throws -> ForumCheckInCatalogData {
    throw BrowseError.unavailable("当前账户服务不支持读取一键签到列表。")
  }

  func batchCheckIn(
    session: StoredAccountSession,
    authorizedTargets: [ForumBatchCheckInTarget]
  ) async throws -> ForumBatchCheckInData {
    throw BrowseError.unavailable("当前账户服务不支持官方一键签到。")
  }

  func selfProfile(
    session: StoredAccountSession
  ) async throws -> AccountProfileSummary {
    throw BrowseError.unavailable("当前账户服务不支持读取本人资料。")
  }

  func ownFollowing(
    session: StoredAccountSession,
    page: Int
  ) async throws -> UserRelationPageData {
    throw BrowseError.unavailable("当前账户服务不支持读取本人关注列表。")
  }

  func likedForums(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> UserLikedForumPageData {
    throw BrowseError.unavailable("当前账户服务不支持读取用户喜欢的贴吧。")
  }

  func concernFeed(
    session: StoredAccountSession,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> ConcernFeedPageData {
    throw BrowseError.unavailable("当前账户服务不支持读取关注动态。")
  }

  func userRelationship(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserRelationshipData {
    throw BrowseError.unavailable("当前账户服务不支持读取用户关注状态。")
  }

  func setUserFollowed(
    session: StoredAccountSession,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> UserRelationshipData {
    throw BrowseError.unavailable("当前账户服务不支持更新用户关注状态。")
  }

  func userInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserInteractionPermissionData {
    throw UserInteractionPermissionError.unavailable("当前账户服务不支持读取用户互动权限。")
  }

  func setUserInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64,
    permissions: UserInteractionPermissions
  ) async throws -> UserInteractionPermissionData {
    throw UserInteractionPermissionError.unavailable("当前账户服务不支持更新用户互动权限。")
  }

  func pollState(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64
  ) async throws -> PollVoteData {
    throw PollVoteError.unavailable("当前账户服务不支持读取投票状态。")
  }

  func submitPollVote(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: Set<Int32>
  ) async throws -> PollVoteData {
    throw PollVoteError.unavailable("当前账户服务不支持提交投票。")
  }

  func cloudFavorites(
    session: StoredAccountSession,
    offset: Int,
    pageSize: Int
  ) async throws -> CloudFavoritePage {
    throw BrowseError.unavailable("当前账户服务不支持读取贴吧收藏。")
  }

  func threadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteData {
    throw BrowseError.unavailable("当前账户服务不支持读取主题收藏状态。")
  }

  func setThreadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteData {
    throw BrowseError.unavailable("当前账户服务不支持更新主题收藏。")
  }

  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission
  ) async throws -> TextReplyResult {
    try await submitTextReply(session: session, submission: submission, imageUploads: [])
  }

  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> TextReplyResult {
    throw TextReplySubmissionError.unavailable
  }

  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission
  ) async throws -> NewThreadResult {
    try await submitNewThread(session: session, submission: submission, imageUploads: [])
  }

  func submitNewThread(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadResult {
    throw NewThreadSubmissionError.unavailable
  }

  func verifyNewThreadVisibility(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    receipt: NewThreadReceipt
  ) async throws -> NewThreadVisibilityConfirmation? {
    try await verifyNewThreadVisibility(
      session: session,
      submission: submission,
      receipt: receipt,
      imageUploads: []
    )
  }

  func verifyNewThreadVisibility(
    session: StoredAccountSession,
    submission: NewThreadSubmission,
    receipt: NewThreadReceipt,
    imageUploads: [ComposerImageUploadResult]
  ) async throws -> NewThreadVisibilityConfirmation? {
    throw NewThreadSubmissionError.unavailable
  }

  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage {
    throw BrowseError.unavailable("当前账户服务不支持读取消息。")
  }

  func inboxUnreadSummary(
    session: StoredAccountSession
  ) async throws -> InboxUnreadSummary {
    throw BrowseError.unavailable("当前账户服务不支持读取未读消息摘要。")
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
