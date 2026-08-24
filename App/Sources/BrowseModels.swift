import Foundation

struct BrowseForumClassification: Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
}

struct BrowseForumChannelSortOption: Identifiable, Hashable, Sendable {
  let id: Int32
  let title: String

  var sort: ForumChannelSort { ForumChannelSort(rawValue: id) }
}

struct BrowseForumChannel: Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let isDefault: Bool
  let sortOptions: [BrowseForumChannelSortOption]

  init(
    id: Int,
    name: String,
    isDefault: Bool,
    sortOptions: [BrowseForumChannelSortOption] = []
  ) {
    self.id = id
    self.name = name
    self.isDefault = isDefault
    self.sortOptions = sortOptions
  }
}

struct BrowseForum: Identifiable, Hashable, Sendable {
  let id: Int64
  let name: String
  let category: String
  let subcategory: String
  let memberCount: Int
  let threadCount: Int
  let postCount: Int
  let avatarURL: URL?
  let slogan: String
  let hasModerators: Bool
  let hasRules: Bool
  let featuredClassifications: [BrowseForumClassification]

  static func placeholder(name: String) -> BrowseForum {
    BrowseForum(
      id: 0,
      name: name,
      category: "",
      subcategory: "",
      memberCount: 0,
      threadCount: 0,
      postCount: 0,
      avatarURL: nil,
      slogan: "",
      hasModerators: false,
      hasRules: false,
      featuredClassifications: []
    )
  }
}

struct BrowseThreadIdentity: Hashable, Sendable {
  let threadID: Int64
  let forumID: Int64
  let forumName: String
}

struct BrowseForumOverview: Hashable, Sendable {
  let forum: BrowseForum
  let introduction: String
  let originalAvatarURL: URL?
}

struct BrowseForumModerator: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let level: Int
  let roleName: String

  var preferredName: String {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? username : name
  }
}

struct BrowseForumModeratorRole: Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let moderators: [BrowseForumModerator]
}

struct BrowseForumRule: Identifiable, Hashable, Sendable {
  let id: Int
  let title: String
  let contents: [BrowseContent]
}

struct BrowseForumRules: Hashable, Sendable {
  let title: String
  let preface: String
  let rules: [BrowseForumRule]
  let publishTime: String
  let author: BrowseForumModerator?
}

struct ThreadPageData: Sendable {
  let forum: BrowseForum
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
  let channels: [BrowseForumChannel]

  init(
    forum: BrowseForum,
    threads: [BrowseThread],
    currentPage: Int,
    hasMore: Bool,
    channels: [BrowseForumChannel] = []
  ) {
    self.forum = forum
    self.threads = threads
    self.currentPage = currentPage
    self.hasMore = hasMore
    self.channels = channels
  }

  init(
    forumName: String,
    threads: [BrowseThread],
    currentPage: Int,
    hasMore: Bool,
    channels: [BrowseForumChannel] = []
  ) {
    self.init(
      forum: .placeholder(name: forumName),
      threads: threads,
      currentPage: currentPage,
      hasMore: hasMore,
      channels: channels
    )
  }
}

struct ForumChannelPageData: Sendable {
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
  let nextPageCursor: Int64?
}

struct BrowsePollOption: Identifiable, Hashable, Sendable {
  let id: Int32
  let text: String
  let voteCount: Int64
  let imageURL: URL?

  init(id: Int32, text: String, voteCount: Int64, imageURL: URL? = nil) {
    self.id = id
    self.text = text
    self.voteCount = voteCount
    self.imageURL = imageURL
  }
}

struct BrowsePoll: Hashable, Sendable {
  let title: String
  let isMultipleChoice: Bool
  let participantCount: Int64
  let totalVoteCount: Int64
  let options: [BrowsePollOption]
  let isPolled: Bool
  let selectedOptionIDs: Set<Int32>
  let tips: String
  let endTimestamp: Int64
  let status: Int32

  init(
    title: String,
    isMultipleChoice: Bool,
    participantCount: Int64,
    totalVoteCount: Int64,
    options: [BrowsePollOption],
    isPolled: Bool = false,
    selectedOptionIDs: Set<Int32> = [],
    tips: String = "",
    endTimestamp: Int64 = 0,
    status: Int32 = 0
  ) {
    self.title = title
    self.isMultipleChoice = isMultipleChoice
    self.participantCount = participantCount
    self.totalVoteCount = totalVoteCount
    self.options = options
    self.isPolled = isPolled
    self.selectedOptionIDs = selectedOptionIDs
    self.tips = tips
    self.endTimestamp = endTimestamp
    self.status = status
  }

  func isClosed(at date: Date) -> Bool {
    status != 0 || (endTimestamp > 0 && endTimestamp <= Int64(date.timeIntervalSince1970))
  }

  func canVote(at date: Date) -> Bool {
    !isPolled && !isClosed(at: date) && !options.isEmpty
  }

  func isSelected(_ optionID: Int32) -> Bool {
    selectedOptionIDs.contains(optionID)
  }

  func progress(for option: BrowsePollOption) -> Double {
    let declaredTotal = Double(max(totalVoteCount, 0))
    let fallbackTotal = options.reduce(0.0) { partialResult, candidate in
      partialResult + Double(max(candidate.voteCount, 0))
    }
    let denominator = declaredTotal > 0 ? declaredTotal : fallbackTotal
    guard denominator > 0, denominator.isFinite else { return 0 }

    let ratio = Double(max(option.voteCount, 0)) / denominator
    guard ratio.isFinite else { return 0 }
    return min(max(ratio, 0), 1)
  }

  func percentage(for option: BrowsePollOption) -> Int {
    Int((progress(for: option) * 100).rounded(.down))
  }
}

struct ContentAgreementPostPageRequest: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let page: Int
  let pageSize: Int
  let options: ThreadBrowseOptions
  let location: ThreadPostLocation?
  let includesSubposts: Bool
  let subpostsSortedByAgree: Bool
  let subpostPageSize: Int

  init?(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?,
    includesSubposts: Bool = true,
    subpostsSortedByAgree: Bool = true,
    subpostPageSize: Int = 4
  ) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let pageIsValid: Bool
    if case .pageCursor = location {
      pageIsValid = page >= 0
    } else {
      pageIsValid = page > 0
    }
    guard
      forumID > 0,
      !forumName.isEmpty,
      threadID > 0,
      pageIsValid,
      pageSize > 0,
      pageSize <= 100,
      subpostPageSize > 0,
      subpostPageSize <= 20
    else { return nil }
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.page = page
    self.pageSize = pageSize
    self.options = options
    self.location = location
    self.includesSubposts = includesSubposts
    self.subpostsSortedByAgree = subpostsSortedByAgree
    self.subpostPageSize = subpostPageSize
  }
}

struct ContentAgreementSubpostPageRequest: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let parentPostID: Int64
  let aroundSubpostID: Int64?
  let page: Int

  init?(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64?,
    page: Int
  ) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      forumID > 0,
      !forumName.isEmpty,
      threadID > 0,
      parentPostID > 0,
      page > 0,
      aroundSubpostID.map({ $0 > 0 && $0 != parentPostID }) ?? true
    else { return nil }
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.aroundSubpostID = aroundSubpostID
    self.page = page
  }
}

enum ContentAgreementReadRequest: Hashable, Sendable {
  case postPage(ContentAgreementPostPageRequest)
  case subpostPage(ContentAgreementSubpostPageRequest)

  var forumID: Int64 {
    switch self {
    case .postPage(let request): request.forumID
    case .subpostPage(let request): request.forumID
    }
  }

  var forumName: String {
    switch self {
    case .postPage(let request): request.forumName
    case .subpostPage(let request): request.forumName
    }
  }

  var threadID: Int64 {
    switch self {
    case .postPage(let request): request.threadID
    case .subpostPage(let request): request.threadID
    }
  }
}

struct ContentAgreementReadDescriptor: Hashable, Sendable {
  let request: ContentAgreementReadRequest
  let expectedTargets: Set<ContentAgreementTarget>

  init?(request: ContentAgreementReadRequest, expectedTargets: Set<ContentAgreementTarget>) {
    guard !expectedTargets.isEmpty else { return nil }
    guard expectedTargets.allSatisfy({ target in
      guard
        target.forumID == request.forumID,
        target.forumName == request.forumName,
        target.threadID == request.threadID
      else { return false }
      switch request {
      case .postPage:
        return true
      case .subpostPage(let page):
        switch target.kind {
        case .topic, .post:
          return target.parentPostID == nil && target.objectID == page.parentPostID
        case .subpost:
          return target.parentPostID == page.parentPostID
        }
      }
    }) else { return nil }
    self.request = request
    self.expectedTargets = expectedTargets
  }
}

struct PostPageData: Sendable {
  let thread: BrowseThread
  let originThread: BrowseThread?
  let poll: BrowsePoll?
  let firstPost: BrowsePost?
  let posts: [BrowsePost]
  let currentPage: Int
  let hasMore: Bool
  let hasPrevious: Bool
  let totalPages: Int
  let totalCount: Int
  let nextPagePostID: Int64?
  let agreementReadDescriptor: ContentAgreementReadDescriptor?

  init(
    thread: BrowseThread,
    posts: [BrowsePost],
    currentPage: Int,
    hasMore: Bool,
    hasPrevious: Bool = false,
    totalPages: Int = 0,
    totalCount: Int = 0,
    nextPagePostID: Int64? = nil,
    originThread: BrowseThread? = nil,
    poll: BrowsePoll? = nil,
    firstPost: BrowsePost? = nil,
    agreementReadDescriptor: ContentAgreementReadDescriptor? = nil
  ) {
    self.thread = thread
    self.originThread = originThread
    self.poll = poll
    self.firstPost = firstPost
    self.posts = posts
    self.currentPage = currentPage
    self.hasMore = hasMore
    self.hasPrevious = hasPrevious
    self.totalPages = totalPages
    self.totalCount = totalCount
    self.nextPagePostID = nextPagePostID
    self.agreementReadDescriptor = agreementReadDescriptor
  }
}

struct CommentPageData: Sendable {
  let parentPost: CommentParentPostContext
  let comments: [BrowseComment]
  let thread: BrowseThread?
  let currentPage: Int
  let hasMore: Bool
  let hasPrevious: Bool
  let totalPages: Int
  let totalCount: Int
  let agreementReadDescriptor: ContentAgreementReadDescriptor?

  init(
    parentPost: CommentParentPostContext,
    comments: [BrowseComment],
    currentPage: Int,
    hasMore: Bool,
    hasPrevious: Bool = false,
    totalPages: Int = 0,
    totalCount: Int = 0,
    thread: BrowseThread? = nil,
    agreementReadDescriptor: ContentAgreementReadDescriptor? = nil
  ) {
    self.parentPost = parentPost
    self.comments = comments
    self.currentPage = currentPage
    self.hasMore = hasMore
    self.hasPrevious = hasPrevious
    self.totalPages = totalPages
    self.totalCount = totalCount
    self.thread = thread
    self.agreementReadDescriptor = agreementReadDescriptor
  }

  var parentPostID: Int64 { parentPost.id }
}

enum BrowseGender: Sendable, Hashable {
  case unknown
  case male
  case female
}

struct BrowseProfileForum: Identifiable, Sendable, Hashable {
  let id: Int64
  let name: String
}

struct BrowseUserProfile: Identifiable, Sendable, Hashable {
  let id: Int64
  let tiebaUID: Int64?
  let username: String
  let displayName: String
  let portraitURL: URL?
  let largePortraitURL: URL?
  let growthLevel: Int
  let gender: BrowseGender
  let ipLocation: String
  let badges: [String]
  let biography: String
  let tiebaAge: String
  let threadCount: Int
  let postCount: Int
  let followerCount: Int
  let followingCount: Int
  let followedForumCount: Int
  let likedForums: [BrowseProfileForum]
  let totalAgreeCount: Int64
  let isModerator: Bool
  let isVIP: Bool
  let isVerifiedCreator: Bool
  let isBlocked: Bool

  var preferredName: String {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? username : name
  }
}

enum UserRelationKind: String, CaseIterable, Identifiable, Hashable, Sendable {
  case following
  case followers

  var id: Self { self }

  var title: String {
    switch self {
    case .following:
      "关注"
    case .followers:
      "粉丝"
    }
  }
}

enum BrowseRelatedUserConcernState: Hashable, Sendable {
  case notFollowing
  case following
  case mutual
  case unknown(Int64)

  init(rawValue: Int64) {
    self =
      switch rawValue {
      case 0: .notFollowing
      case 1: .following
      case 2: .mutual
      default: .unknown(rawValue)
      }
  }

  var rawValue: Int64 {
    switch self {
    case .notFollowing: 0
    case .following: 1
    case .mutual: 2
    case .unknown(let rawValue): rawValue
    }
  }
}

struct BrowseRelatedUser: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let introduction: String
  let concernState: BrowseRelatedUserConcernState?
  let localVisibility: LocalContentVisibility

  init(
    id: Int64,
    username: String,
    displayName: String,
    portraitURL: URL?,
    introduction: String,
    concernState: BrowseRelatedUserConcernState? = nil,
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portraitURL = portraitURL
    self.introduction = introduction
    self.concernState = concernState
    self.localVisibility = localVisibility
  }

  var preferredName: String {
    let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !displayName.isEmpty { return displayName }
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return username.isEmpty ? String(id) : username
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    BrowseRelatedUser(
      id: id,
      username: username,
      displayName: displayName,
      portraitURL: portraitURL,
      introduction: introduction,
      concernState: concernState,
      localVisibility: visibility
    )
  }
}

struct UserRelationPageData: Hashable, Sendable {
  let users: [BrowseRelatedUser]
  let currentPage: Int
  let totalCount: Int
  let hasMore: Bool
  let notice: String
  let visibilitySwitch: Int?
}

struct UserThreadPageData: Sendable {
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
  let isHidden: Bool
}

struct BrowseUserReplyID: Hashable, Sendable {
  let threadID: Int64
  let postID: Int64
}

enum BrowseUserReplyTarget: Hashable, Sendable {
  case post
  case comment
  case unsupported(rawType: UInt64)
}

enum UserReplyNavigationTarget: Hashable, Sendable {
  case thread(TiebaThreadRoute)
  case comment(threadID: Int64, commentID: Int64)
}

struct BrowseUserReply: Identifiable, Hashable, Sendable {
  let id: BrowseUserReplyID
  let forumID: Int64
  let forumName: String
  let threadTitle: String
  let excerpt: String
  let createdAt: Date?
  let authorID: Int64
  let authorName: String
  let authorUsername: String
  let target: BrowseUserReplyTarget
  let localVisibility: LocalContentVisibility

  init(
    threadID: Int64,
    postID: Int64,
    forumID: Int64,
    forumName: String,
    threadTitle: String,
    excerpt: String,
    createdAt: Date?,
    authorID: Int64,
    authorName: String,
    authorUsername: String,
    target: BrowseUserReplyTarget,
    localVisibility: LocalContentVisibility = .visible
  ) {
    id = BrowseUserReplyID(threadID: threadID, postID: postID)
    self.forumID = forumID
    self.forumName = forumName
    self.threadTitle = threadTitle
    self.excerpt = excerpt
    self.createdAt = createdAt
    self.authorID = authorID
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.target = target
    self.localVisibility = localVisibility
  }

  var threadID: Int64 { id.threadID }
  var postID: Int64 { id.postID }

  var navigationTarget: UserReplyNavigationTarget? {
    switch target {
    case .post:
      return .thread(TiebaThreadRoute(threadID: threadID, postID: postID))
    case .comment:
      return .comment(threadID: threadID, commentID: postID)
    case .unsupported:
      return nil
    }
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    BrowseUserReply(
      threadID: threadID,
      postID: postID,
      forumID: forumID,
      forumName: forumName,
      threadTitle: threadTitle,
      excerpt: excerpt,
      createdAt: createdAt,
      authorID: authorID,
      authorName: authorName,
      authorUsername: authorUsername,
      target: target,
      localVisibility: visibility
    )
  }
}

struct UserReplyPageData: Sendable {
  let replies: [BrowseUserReply]
  let currentPage: Int
  let hasMore: Bool
  let isHidden: Bool
}

struct ForumSearchItem: Identifiable, Hashable, Sendable {
  let id: Int64
  let name: String
  let displayName: String
  let avatarURL: URL?
  let postCount: Int
  let memberCount: Int
  let summary: String
}

struct ForumSearchData: Sendable {
  let exactMatch: ForumSearchItem?
  let related: [ForumSearchItem]
}

struct UserSearchItem: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let introduction: String

  var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

struct UserSearchData: Sendable {
  let exactMatch: UserSearchItem?
  let related: [UserSearchItem]
}

struct ThreadSearchPageData: Sendable {
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
}

enum GlobalThreadSearchSort: String, CaseIterable, Hashable, Identifiable, Sendable {
  case newest
  case oldest
  case relevance

  var id: Self { self }

  var title: String {
    switch self {
    case .newest:
      "最新"
    case .oldest:
      "最早"
    case .relevance:
      "相关"
    }
  }
}

enum ForumPostSearchSort: String, CaseIterable, Hashable, Identifiable, Sendable {
  case newest
  case relevance

  var id: Self { self }

  var title: String {
    switch self {
    case .newest:
      "最新"
    case .relevance:
      "相关"
    }
  }
}

enum ForumPostSearchFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
  case all
  case threadsOnly

  var id: Self { self }

  var title: String {
    switch self {
    case .all:
      "全部"
    case .threadsOnly:
      "主题帖"
    }
  }
}

enum ForumPostSearchTarget: Hashable, Sendable {
  case thread
  case post(Int64)
  case comment(postID: Int64, commentID: Int64)

  var title: String {
    switch self {
    case .thread:
      "主题帖"
    case .post:
      "回复"
    case .comment:
      "楼中楼"
    }
  }

  fileprivate var storageKey: String {
    switch self {
    case .thread:
      "thread"
    case .post(let postID):
      "post:\(postID)"
    case .comment(let postID, let commentID):
      "comment:\(postID):\(commentID)"
    }
  }
}

enum ForumPostSearchContextTarget: Hashable, Sendable {
  case mainPost(threadID: Int64)
  case parentPost(threadID: Int64, postID: Int64)

  var title: String {
    switch self {
    case .mainPost:
      "相关原帖"
    case .parentPost:
      "所属楼层"
    }
  }

  fileprivate var storageKey: String {
    switch self {
    case .mainPost(let threadID):
      "main:\(threadID)"
    case .parentPost(let threadID, let postID):
      "parent:\(threadID):\(postID)"
    }
  }
}

struct ForumPostSearchSummary: Hashable, Sendable {
  let postID: Int64
  let title: String
  let excerpt: String
  let authorID: Int64
  let authorName: String
  let authorUsername: String
  let localVisibility: LocalContentVisibility

  init(
    postID: Int64,
    title: String,
    excerpt: String,
    authorID: Int64,
    authorName: String,
    authorUsername: String = "",
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.postID = postID
    self.title = title
    self.excerpt = excerpt
    self.authorID = authorID
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.localVisibility = localVisibility
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    ForumPostSearchSummary(
      postID: postID,
      title: title,
      excerpt: excerpt,
      authorID: authorID,
      authorName: authorName,
      authorUsername: authorUsername,
      localVisibility: visibility
    )
  }
}

struct ForumPostSearchContext: Identifiable, Hashable, Sendable {
  var id: String { target.storageKey }

  let target: ForumPostSearchContextTarget
  let summary: ForumPostSearchSummary

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    ForumPostSearchContext(
      target: target,
      summary: summary.withLocalVisibility(visibility)
    )
  }
}

struct ForumPostSearchItem: Identifiable, Hashable, Sendable {
  var id: String { "\(thread.id):\(target.storageKey)" }

  let thread: BrowseThread
  let target: ForumPostSearchTarget
  let matchedTitle: String
  let matchedExcerpt: String
  let matchedAuthorID: Int64
  let matchedAuthorName: String
  let matchedAuthorUsername: String
  let matchedAuthorPortraitURL: URL?
  let matchedAt: Date?
  let replyCount: Int
  let likeCount: Int
  let shareCount: Int
  let matchedContents: [BrowseContent]
  let contexts: [ForumPostSearchContext]
  let localVisibility: LocalContentVisibility

  init(
    thread: BrowseThread,
    target: ForumPostSearchTarget,
    matchedTitle: String,
    matchedExcerpt: String,
    matchedAuthorID: Int64,
    matchedAuthorName: String,
    matchedAuthorPortraitURL: URL?,
    matchedAt: Date?,
    replyCount: Int,
    likeCount: Int,
    shareCount: Int,
    matchedContents: [BrowseContent],
    contexts: [ForumPostSearchContext] = [],
    matchedAuthorUsername: String = "",
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.thread = thread
    self.target = target
    self.matchedTitle = matchedTitle
    self.matchedExcerpt = matchedExcerpt
    self.matchedAuthorID = matchedAuthorID
    self.matchedAuthorName = matchedAuthorName
    self.matchedAuthorUsername = matchedAuthorUsername
    self.matchedAuthorPortraitURL = matchedAuthorPortraitURL
    self.matchedAt = matchedAt
    self.replyCount = replyCount
    self.likeCount = likeCount
    self.shareCount = shareCount
    self.matchedContents = matchedContents
    self.contexts = contexts
    self.localVisibility = localVisibility
  }

  func withLocalPresentation(
    visibility: LocalContentVisibility,
    thread: BrowseThread,
    contexts: [ForumPostSearchContext]
  ) -> Self {
    ForumPostSearchItem(
      thread: thread,
      target: target,
      matchedTitle: matchedTitle,
      matchedExcerpt: matchedExcerpt,
      matchedAuthorID: matchedAuthorID,
      matchedAuthorName: matchedAuthorName,
      matchedAuthorPortraitURL: matchedAuthorPortraitURL,
      matchedAt: matchedAt,
      replyCount: replyCount,
      likeCount: likeCount,
      shareCount: shareCount,
      matchedContents: matchedContents,
      contexts: contexts,
      matchedAuthorUsername: matchedAuthorUsername,
      localVisibility: visibility
    )
  }
}

struct ForumPostSearchPageData: Sendable {
  let results: [ForumPostSearchItem]
  let currentPage: Int
  let hasMore: Bool
}

struct HotTopicItem: Identifiable, Hashable, Sendable {
  let id: Int64
  let name: String
  let summary: String
  let imageURL: URL?
  let discussionCount: Int64
  let rank: Int
  let tag: Int
}

struct HotTopicPageData: Sendable {
  let topic: HotTopicItem
  let relatedForums: [ForumSearchItem]
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
  let nextPageCursor: Int64?
}

struct HotThreadCategory: Identifiable, Hashable, Sendable {
  var id: String { code }

  let serverID: Int32
  let code: String
  let title: String

  static let all = HotThreadCategory(serverID: 1, code: "all", title: "总榜")
}

struct HotThreadRankItem: Identifiable, Hashable, Sendable {
  var id: Int64 { thread.id }

  let rank: Int
  let hotScore: Int
  let thread: BrowseThread
}

struct HotThreadFeedData: Hashable, Sendable {
  let topics: [HotTopicItem]
  let categories: [HotThreadCategory]
  let items: [HotThreadRankItem]
}

struct PersonalizedFeedbackReason: Identifiable, Hashable, Sendable {
  let id: UInt32
  let title: String
  let extra: String
}

struct PersonalizedFeedItem: Identifiable, Hashable, Sendable {
  var id: Int64 { thread.id }

  let thread: BrowseThread
  let feedbackReasons: [PersonalizedFeedbackReason]
}

struct PersonalizedFeedPageData: Hashable, Sendable {
  let items: [PersonalizedFeedItem]
  let currentPage: Int
  let hasMore: Bool
}

enum BrowseThreadKind: Hashable, Sendable {
  case article
  case album
  case externalShare
  case voice
  case cloudDrive
  case story
  case video
  case live
  case help
  case vote
  case lottery
  case unknown(Int32)
}

enum LocalContentVisibility: String, Codable, Hashable, Sendable {
  case visible
  case placeholder
  case hidden
}

struct BrowseThread: Identifiable, Hashable, Sendable {
  let id: Int64
  let firstPostID: Int64
  let contentPostID: Int64
  let forumID: Int64
  let forumName: String
  let title: String
  let excerpt: String
  let authorName: String
  let authorUsername: String
  let authorAvatarURL: URL?
  let authorID: Int64
  let replyCount: Int
  let viewCount: Int
  let shareCount: Int
  let agreeCount: Int
  let disagreeCount: Int
  let createdAt: Date?
  let lastReplyAt: Date?
  let contents: [BrowseContent]
  let kind: BrowseThreadKind
  let tabID: Int
  let isPinned: Bool
  let isFeatured: Bool
  let isShared: Bool
  let isServerHidden: Bool
  let isLive: Bool
  let localVisibility: LocalContentVisibility

  init(
    id: Int64,
    forumID: Int64,
    forumName: String,
    title: String,
    excerpt: String,
    authorName: String,
    replyCount: Int,
    viewCount: Int,
    createdAt: Date?,
    lastReplyAt: Date?,
    contents: [BrowseContent],
    authorID: Int64 = 0,
    authorUsername: String = "",
    authorAvatarURL: URL? = nil,
    firstPostID: Int64 = 0,
    contentPostID: Int64? = nil,
    shareCount: Int = 0,
    agreeCount: Int = 0,
    disagreeCount: Int = 0,
    kind: BrowseThreadKind = .article,
    tabID: Int = 0,
    isPinned: Bool = false,
    isFeatured: Bool = false,
    isShared: Bool = false,
    isServerHidden: Bool = false,
    isLive: Bool = false,
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.id = id
    self.firstPostID = firstPostID
    if let contentPostID {
      self.contentPostID = max(contentPostID, 0)
    } else {
      self.contentPostID = 0
    }
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.excerpt = excerpt
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.authorAvatarURL = SecureTiebaURL.media(authorAvatarURL)
    self.authorID = authorID
    self.replyCount = replyCount
    self.viewCount = viewCount
    self.shareCount = shareCount
    self.agreeCount = agreeCount
    self.disagreeCount = disagreeCount
    self.createdAt = createdAt
    self.lastReplyAt = lastReplyAt
    self.contents = contents
    self.kind = kind
    self.tabID = tabID
    self.isPinned = isPinned
    self.isFeatured = isFeatured
    self.isShared = isShared
    self.isServerHidden = isServerHidden
    self.isLive = isLive
    self.localVisibility = localVisibility
  }

  var agreeScore: Int {
    let (score, overflow) = agreeCount.subtractingReportingOverflow(disagreeCount)
    guard !overflow else { return agreeCount >= 0 ? Int.max : 0 }
    return max(score, 0)
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    BrowseThread(
      id: id,
      forumID: forumID,
      forumName: forumName,
      title: title,
      excerpt: excerpt,
      authorName: authorName,
      replyCount: replyCount,
      viewCount: viewCount,
      createdAt: createdAt,
      lastReplyAt: lastReplyAt,
      contents: contents,
      authorID: authorID,
      authorUsername: authorUsername,
      authorAvatarURL: authorAvatarURL,
      firstPostID: firstPostID,
      contentPostID: contentPostID,
      shareCount: shareCount,
      agreeCount: agreeCount,
      disagreeCount: disagreeCount,
      kind: kind,
      tabID: tabID,
      isPinned: isPinned,
      isFeatured: isFeatured,
      isShared: isShared,
      isServerHidden: isServerHidden,
      isLive: isLive,
      localVisibility: visibility
    )
  }
}

struct BrowsePost: Identifiable, Hashable, Sendable {
  let id: Int64
  let threadID: Int64
  let floor: Int
  let authorID: Int64
  let authorName: String
  let authorUsername: String
  let authorPortraitURL: URL?
  let authorLevel: Int
  let authorIPLocation: String
  let moderatorRole: BrowseModeratorRole?
  let createdAt: Date?
  let nestedReplyCount: Int
  let agreeScore: Int
  let isThreadAuthor: Bool
  let contents: [BrowseContent]
  let inlineComments: [BrowseComment]
  let localVisibility: LocalContentVisibility

  init(
    id: Int64,
    threadID: Int64,
    floor: Int,
    authorID: Int64,
    authorName: String,
    authorPortraitURL: URL?,
    createdAt: Date?,
    nestedReplyCount: Int,
    isThreadAuthor: Bool,
    contents: [BrowseContent],
    authorUsername: String = "",
    authorLevel: Int = 0,
    authorIPLocation: String = "",
    moderatorRole: BrowseModeratorRole? = nil,
    agreeScore: Int = 0,
    inlineComments: [BrowseComment] = [],
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.id = id
    self.threadID = threadID
    self.floor = floor
    self.authorID = authorID
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.authorPortraitURL = authorPortraitURL
    self.authorLevel = authorLevel
    self.authorIPLocation = authorIPLocation
    self.moderatorRole = moderatorRole
    self.createdAt = createdAt
    self.nestedReplyCount = nestedReplyCount
    self.agreeScore = agreeScore
    self.isThreadAuthor = isThreadAuthor
    self.contents = contents
    self.inlineComments = inlineComments
    self.localVisibility = localVisibility
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    withLocalPresentation(visibility: visibility, inlineComments: inlineComments)
  }

  func withLocalPresentation(
    visibility: LocalContentVisibility,
    inlineComments: [BrowseComment]
  ) -> Self {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: authorID,
      authorName: authorName,
      authorPortraitURL: authorPortraitURL,
      createdAt: createdAt,
      nestedReplyCount: nestedReplyCount,
      isThreadAuthor: isThreadAuthor,
      contents: contents,
      authorUsername: authorUsername,
      authorLevel: authorLevel,
      authorIPLocation: authorIPLocation,
      moderatorRole: moderatorRole,
      agreeScore: agreeScore,
      inlineComments: inlineComments,
      localVisibility: visibility
    )
  }
}

enum BrowseModeratorRole: Hashable, Sendable {
  case manager
  case assistant
  case moderator

  var title: String {
    switch self {
    case .manager:
      "吧主"
    case .assistant:
      "小吧主"
    case .moderator:
      "吧务"
    }
  }
}

struct CommentParentPostContext: Identifiable, Hashable, Sendable {
  let id: Int64
  let threadID: Int64
  let floor: Int
  let authorID: Int64
  let authorName: String
  let authorUsername: String
  let authorPortraitURL: URL?
  let authorLevel: Int
  let authorIPLocation: String
  let moderatorRole: BrowseModeratorRole?
  let createdAt: Date?
  let agreeScore: Int
  let isThreadAuthor: Bool
  let contents: [BrowseContent]
  let localVisibility: LocalContentVisibility

  init(
    id: Int64,
    threadID: Int64,
    floor: Int,
    authorID: Int64,
    authorName: String,
    authorPortraitURL: URL?,
    createdAt: Date?,
    isThreadAuthor: Bool,
    contents: [BrowseContent],
    authorUsername: String = "",
    authorLevel: Int = 0,
    authorIPLocation: String = "",
    moderatorRole: BrowseModeratorRole? = nil,
    agreeScore: Int = 0,
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.id = id
    self.threadID = threadID
    self.floor = floor
    self.authorID = authorID
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.authorPortraitURL = authorPortraitURL
    self.authorLevel = authorLevel
    self.authorIPLocation = authorIPLocation
    self.moderatorRole = moderatorRole
    self.createdAt = createdAt
    self.agreeScore = agreeScore
    self.isThreadAuthor = isThreadAuthor
    self.contents = contents
    self.localVisibility = localVisibility
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    CommentParentPostContext(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: authorID,
      authorName: authorName,
      authorPortraitURL: authorPortraitURL,
      createdAt: createdAt,
      isThreadAuthor: isThreadAuthor,
      contents: contents,
      authorUsername: authorUsername,
      authorLevel: authorLevel,
      authorIPLocation: authorIPLocation,
      moderatorRole: moderatorRole,
      agreeScore: agreeScore,
      localVisibility: visibility
    )
  }
}

struct BrowseComment: Identifiable, Hashable, Sendable {
  let id: Int64
  let threadID: Int64
  let parentPostID: Int64
  let authorID: Int64
  let authorName: String
  let authorUsername: String
  let authorPortraitURL: URL?
  let authorLevel: Int
  let authorIPLocation: String
  let moderatorRole: BrowseModeratorRole?
  let createdAt: Date?
  let agreeScore: Int
  let isThreadAuthor: Bool
  let replyToUserID: Int64?
  let replyToUserName: String
  let contents: [BrowseContent]
  let localVisibility: LocalContentVisibility

  init(
    id: Int64,
    authorID: Int64,
    authorName: String,
    authorPortraitURL: URL?,
    createdAt: Date?,
    contents: [BrowseContent],
    authorUsername: String = "",
    authorLevel: Int = 0,
    authorIPLocation: String = "",
    moderatorRole: BrowseModeratorRole? = nil,
    agreeScore: Int = 0,
    isThreadAuthor: Bool = false,
    replyToUserID: Int64? = nil,
    replyToUserName: String = "",
    localVisibility: LocalContentVisibility = .visible,
    threadID: Int64 = 0,
    parentPostID: Int64 = 0
  ) {
    self.id = id
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.authorID = authorID
    self.authorName = authorName
    self.authorUsername = authorUsername
    self.authorPortraitURL = authorPortraitURL
    self.authorLevel = authorLevel
    self.authorIPLocation = authorIPLocation
    self.moderatorRole = moderatorRole
    self.createdAt = createdAt
    self.agreeScore = agreeScore
    self.isThreadAuthor = isThreadAuthor
    self.replyToUserID = replyToUserID
    self.replyToUserName = replyToUserName
    self.contents = contents
    self.localVisibility = localVisibility
  }

  func withLocalVisibility(_ visibility: LocalContentVisibility) -> Self {
    BrowseComment(
      id: id,
      authorID: authorID,
      authorName: authorName,
      authorPortraitURL: authorPortraitURL,
      createdAt: createdAt,
      contents: contents,
      authorUsername: authorUsername,
      authorLevel: authorLevel,
      authorIPLocation: authorIPLocation,
      moderatorRole: moderatorRole,
      agreeScore: agreeScore,
      isThreadAuthor: isThreadAuthor,
      replyToUserID: replyToUserID,
      replyToUserName: replyToUserName,
      localVisibility: visibility,
      threadID: threadID,
      parentPostID: parentPostID
    )
  }
}

extension ContentAgreementTarget {
  init?(thread: BrowseThread, post: BrowsePost) {
    guard post.id > 0, post.threadID == thread.id else { return nil }
    let kind: ContentAgreementKind
    if
      thread.firstPostID > 0,
      post.id == thread.firstPostID,
      post.floor == 1
    {
      kind = .topic
    } else {
      guard post.floor > 1, post.id != thread.firstPostID else { return nil }
      kind = .post
    }
    self.init(
      kind: kind,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      objectID: post.id
    )
  }

  init?(thread: BrowseThread, parentPost: CommentParentPostContext) {
    guard parentPost.id > 0, parentPost.threadID == thread.id else { return nil }
    let kind: ContentAgreementKind
    if
      thread.firstPostID > 0,
      parentPost.id == thread.firstPostID,
      parentPost.floor == 1
    {
      kind = .topic
    } else {
      guard parentPost.floor > 1, parentPost.id != thread.firstPostID else { return nil }
      kind = .post
    }
    self.init(
      kind: kind,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      objectID: parentPost.id
    )
  }

  init?(thread: BrowseThread, parentPostID: Int64, comment: BrowseComment) {
    guard
      parentPostID > 0,
      comment.threadID == thread.id,
      comment.parentPostID == parentPostID
    else { return nil }
    self.init(
      kind: .subpost,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      parentPostID: parentPostID,
      objectID: comment.id
    )
  }
}

struct BrowseVideoContent: Hashable, Sendable {
  let url: URL?
  let cover: URL?
  let pageURL: URL?
  let width: Int
  let height: Int

  init(
    url: URL?,
    cover: URL?,
    width: Int,
    height: Int,
    pageURL: URL? = nil
  ) {
    self.url = url
    self.cover = cover
    self.pageURL = pageURL
    self.width = width
    self.height = height
  }
}

enum BrowseContent: Hashable, Sendable {
  case text(String)
  case mention(name: String, userID: Int64)
  case link(label: String, url: URL)
  case image(
    thumbnail: URL,
    fullSize: URL?,
    original: URL?,
    dynamic: URL? = nil,
    width: Int,
    height: Int
  )
  case video(BrowseVideoContent)
  case voice(url: URL, duration: Int)
  case emoticon(name: String, url: URL?)
  case unsupported(label: String)

  static func video(
    url: URL?,
    cover: URL?,
    width: Int,
    height: Int,
    pageURL: URL? = nil
  ) -> Self {
    .video(
      BrowseVideoContent(
        url: url,
        cover: cover,
        width: width,
        height: height,
        pageURL: pageURL
      )
    )
  }
}

enum BrowseContentImageSourceResolver {
  static func previewURL(
    thumbnail: URL,
    fullSize: URL?,
    dynamic: URL? = nil,
    quality: ContentImagePreviewQuality
  ) -> URL {
    switch quality {
    case .standard:
      thumbnail
    case .highDefinition:
      fullSize ?? dynamic ?? thumbnail
    }
  }

  static func galleryURL(
    thumbnail: URL,
    fullSize: URL?,
    original: URL?,
    dynamic: URL? = nil
  ) -> URL {
    original ?? dynamic ?? fullSize ?? thumbnail
  }
}
