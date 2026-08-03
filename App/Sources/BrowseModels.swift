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
  let id: Int
  let text: String
  let voteCount: Int64
}

struct BrowsePoll: Hashable, Sendable {
  let title: String
  let isMultipleChoice: Bool
  let participantCount: Int64
  let totalVoteCount: Int64
  let options: [BrowsePollOption]

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
    firstPost: BrowsePost? = nil
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
  }
}

struct CommentPageData: Sendable {
  let parentPost: CommentParentPostContext
  let comments: [BrowseComment]
  let currentPage: Int
  let hasMore: Bool
  let hasPrevious: Bool
  let totalPages: Int
  let totalCount: Int

  init(
    parentPost: CommentParentPostContext,
    comments: [BrowseComment],
    currentPage: Int,
    hasMore: Bool,
    hasPrevious: Bool = false,
    totalPages: Int = 0,
    totalCount: Int = 0
  ) {
    self.parentPost = parentPost
    self.comments = comments
    self.currentPage = currentPage
    self.hasMore = hasMore
    self.hasPrevious = hasPrevious
    self.totalPages = totalPages
    self.totalCount = totalCount
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

struct UserThreadPageData: Sendable {
  let threads: [BrowseThread]
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

struct ForumPostSearchSummary: Hashable, Sendable {
  let postID: Int64
  let title: String
  let excerpt: String
  let authorID: Int64
  let authorName: String
}

struct ForumPostSearchItem: Identifiable, Hashable, Sendable {
  var id: String { "\(thread.id):\(target.storageKey)" }

  let thread: BrowseThread
  let target: ForumPostSearchTarget
  let matchedTitle: String
  let matchedExcerpt: String
  let matchedAuthorID: Int64
  let matchedAuthorName: String
  let matchedAuthorPortraitURL: URL?
  let matchedAt: Date?
  let replyCount: Int
  let likeCount: Int
  let shareCount: Int
  let matchedContents: [BrowseContent]
  let context: ForumPostSearchSummary?
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
  let forumID: Int64
  let forumName: String
  let title: String
  let excerpt: String
  let authorName: String
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
    firstPostID: Int64 = 0,
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
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.excerpt = excerpt
    self.authorName = authorName
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
      firstPostID: firstPostID,
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
  let authorID: Int64
  let authorName: String
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
    authorLevel: Int = 0,
    authorIPLocation: String = "",
    moderatorRole: BrowseModeratorRole? = nil,
    agreeScore: Int = 0,
    isThreadAuthor: Bool = false,
    replyToUserID: Int64? = nil,
    replyToUserName: String = "",
    localVisibility: LocalContentVisibility = .visible
  ) {
    self.id = id
    self.authorID = authorID
    self.authorName = authorName
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
      authorLevel: authorLevel,
      authorIPLocation: authorIPLocation,
      moderatorRole: moderatorRole,
      agreeScore: agreeScore,
      isThreadAuthor: isThreadAuthor,
      replyToUserID: replyToUserID,
      replyToUserName: replyToUserName,
      localVisibility: visibility
    )
  }
}

enum BrowseContent: Hashable, Sendable {
  case text(String)
  case mention(name: String, userID: Int64)
  case link(label: String, url: URL)
  case image(thumbnail: URL, original: URL?, width: Int, height: Int)
  case video(url: URL?, cover: URL?, width: Int, height: Int)
  case voice(url: URL, duration: Int)
  case emoticon(name: String, url: URL?)
  case unsupported(label: String)
}
