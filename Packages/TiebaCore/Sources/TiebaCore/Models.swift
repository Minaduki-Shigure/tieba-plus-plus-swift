import Foundation

public struct TiebaPagination: Sendable, Hashable {
  public let pageSize: Int
  public let currentPage: Int
  public let totalPages: Int
  public let totalCount: Int
  public let hasMore: Bool
  public let hasPrevious: Bool

  public init(
    pageSize: Int,
    currentPage: Int,
    totalPages: Int,
    totalCount: Int,
    hasMore: Bool,
    hasPrevious: Bool
  ) {
    self.pageSize = pageSize
    self.currentPage = currentPage
    self.totalPages = totalPages
    self.totalCount = totalCount
    self.hasMore = hasMore
    self.hasPrevious = hasPrevious
  }

  public var nextPage: Int? {
    hasMore ? max(currentPage, 1) + 1 : nil
  }

  public var previousPage: Int? {
    hasPrevious && currentPage > 1 ? currentPage - 1 : nil
  }
}

public enum TiebaGender: Int32, Sendable, Hashable {
  case unknown = 0
  case male = 1
  case female = 2
}

public enum TiebaModeratorRole: Sendable, Hashable {
  case manager
  case assistant
  case moderator
}

public struct TiebaUser: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let level: Int
  public let growthLevel: Int
  public let gender: TiebaGender
  public let ipLocation: String
  public let badges: [String]
  public let moderatorRole: TiebaModeratorRole?
  public let isVIP: Bool
  public let isVerifiedCreator: Bool

  public var isModerator: Bool { moderatorRole != nil }

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    level: Int,
    growthLevel: Int,
    gender: TiebaGender,
    ipLocation: String,
    badges: [String],
    isModerator: Bool,
    isVIP: Bool,
    isVerifiedCreator: Bool,
    moderatorRole: TiebaModeratorRole? = nil
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.level = level
    self.growthLevel = growthLevel
    self.gender = gender
    self.ipLocation = ipLocation
    self.badges = badges
    self.moderatorRole = isModerator ? (moderatorRole ?? .moderator) : nil
    self.isVIP = isVIP
    self.isVerifiedCreator = isVerifiedCreator
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaUserProfile: Sendable, Hashable {
  public let user: TiebaUser
  public let portraitSource: String
  public let tiebaUID: Int64?
  public let biography: String
  public let tiebaAge: String
  public let threadCount: Int
  public let postCount: Int
  public let followerCount: Int
  public let followingCount: Int
  public let followedForumCount: Int
  public let likedForums: [TiebaProfileForum]
  public let totalAgreeCount: Int64
  public let isBlocked: Bool

  public init(
    user: TiebaUser,
    tiebaUID: Int64?,
    biography: String,
    tiebaAge: String,
    threadCount: Int,
    postCount: Int,
    followerCount: Int,
    followingCount: Int,
    followedForumCount: Int,
    likedForums: [TiebaProfileForum] = [],
    totalAgreeCount: Int64,
    isBlocked: Bool,
    portraitSource: String? = nil
  ) {
    self.user = user
    self.portraitSource = portraitSource ?? user.portrait
    self.tiebaUID = tiebaUID
    self.biography = biography
    self.tiebaAge = tiebaAge
    self.threadCount = threadCount
    self.postCount = postCount
    self.followerCount = followerCount
    self.followingCount = followingCount
    self.followedForumCount = followedForumCount
    self.likedForums = likedForums
    self.totalAgreeCount = totalAgreeCount
    self.isBlocked = isBlocked
  }
}

public struct TiebaProfileForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String

  public init(id: Int64, name: String) {
    self.id = id
    self.name = name
  }
}

public struct TiebaImage: Sendable, Hashable {
  public let thumbnailURL: URL?
  public let fullSizeURL: URL?
  public let originalURL: URL?
  public let dynamicURL: URL?
  public let width: Int
  public let height: Int
  public let originalByteCount: Int
  public let postID: Int64?

  public init(
    thumbnailURL: URL?,
    fullSizeURL: URL?,
    originalURL: URL?,
    width: Int,
    height: Int,
    originalByteCount: Int,
    dynamicURL: URL? = nil,
    postID: Int64? = nil
  ) {
    self.thumbnailURL = thumbnailURL
    self.fullSizeURL = fullSizeURL
    self.originalURL = originalURL
    self.dynamicURL = dynamicURL
    self.width = width
    self.height = height
    self.originalByteCount = originalByteCount
    self.postID = postID.flatMap { $0 > 0 ? $0 : nil }
  }
}

public struct TiebaVideo: Sendable, Hashable {
  public let streamURL: URL?
  public let coverURL: URL?
  public let pageURL: URL?
  public let duration: TimeInterval
  public let width: Int
  public let height: Int
  public let viewCount: Int

  public init(
    streamURL: URL?,
    coverURL: URL?,
    duration: TimeInterval,
    width: Int,
    height: Int,
    viewCount: Int,
    pageURL: URL? = nil
  ) {
    self.streamURL = streamURL
    self.coverURL = coverURL
    self.pageURL = pageURL
    self.duration = duration
    self.width = width
    self.height = height
    self.viewCount = viewCount
  }
}

public struct TiebaVoice: Sendable, Hashable {
  public let md5: String
  public let duration: TimeInterval

  public init(md5: String, duration: TimeInterval) {
    self.md5 = md5
    self.duration = duration
  }
}

public struct TiebaMention: Sendable, Hashable {
  public let text: String
  public let userID: Int64

  public init(text: String, userID: Int64) {
    self.text = text
    self.userID = userID
  }
}

public struct TiebaLink: Sendable, Hashable {
  public let text: String
  public let title: String
  public let url: URL?

  public init(text: String, title: String, url: URL?) {
    self.text = text
    self.title = title
    self.url = url
  }
}

public enum TiebaContentFragment: Sendable, Hashable {
  case text(String)
  case emoji(identifier: String, description: String)
  case image(TiebaImage)
  case mention(TiebaMention)
  case link(TiebaLink)
  case video(TiebaVideo)
  case voice(TiebaVoice)
  case tiebaPlus(description: String, url: URL?)
  case unknown(type: UInt32, text: String)

  public var plainText: String {
    switch self {
    case .text(let text):
      text
    case .emoji(_, let description):
      description
    case .mention(let mention):
      mention.text
    case .link(let link):
      link.title.isEmpty ? link.text : link.title
    case .tiebaPlus(let description, _):
      description
    case .unknown(_, let text):
      text
    case .image, .video, .voice:
      ""
    }
  }
}

public struct TiebaContent: Sendable, Hashable {
  public let fragments: [TiebaContentFragment]

  public init(fragments: [TiebaContentFragment]) {
    self.fragments = fragments
  }

  public var plainText: String {
    fragments.map(\.plainText).joined()
  }

  public var images: [TiebaImage] {
    fragments.compactMap {
      guard case .image(let image) = $0 else { return nil }
      return image
    }
  }
}

public enum TiebaThreadKind: Sendable, Hashable {
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

  public init(rawValue: Int32) {
    self =
      switch rawValue {
      case 0: .article
      case 1: .album
      case 6: .externalShare
      case 11: .voice
      case 14: .cloudDrive
      case 31: .story
      case 40: .video
      case 50: .live
      case 71: .help
      case 75: .vote
      case 76: .lottery
      default: .unknown(rawValue)
      }
  }
}

public enum TiebaThreadSort: Int32, Sendable, Hashable {
  case replyTime = 6
  case creationTime = 1
  case hot = 3
  case followedUsers = 2
}

public struct TiebaForumChannelSort: RawRepresentable, Sendable, Hashable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  public static let unspecified = TiebaForumChannelSort(rawValue: -1)
  public static let replyTime = TiebaForumChannelSort(rawValue: 0)
  public static let creationTime = TiebaForumChannelSort(rawValue: 1)
}

public enum TiebaPostSort: Int32, Sendable, Hashable {
  case ascending = 0
  case descending = 1
  case hot = 2
}

public enum TiebaPostLocation: Sendable, Hashable {
  case postID(Int64)
  case pageNumber
  case pageCursor(Int64)
  case latestReplies(after: Int64)
}

public struct TiebaForumClassification: Identifiable, Sendable, Hashable {
  public let id: Int
  public let name: String

  public init(id: Int, name: String) {
    self.id = id
    self.name = name
  }
}

public struct TiebaForumChannelSortOption: Identifiable, Sendable, Hashable {
  public let id: Int32
  public let title: String

  public init(id: Int32, title: String) {
    self.id = id
    self.title = title
  }
}

public struct TiebaForumChannel: Identifiable, Sendable, Hashable {
  public let id: Int
  public let name: String
  public let isDefault: Bool
  public let sortOptions: [TiebaForumChannelSortOption]

  public init(
    id: Int,
    name: String,
    isDefault: Bool = false,
    sortOptions: [TiebaForumChannelSortOption] = []
  ) {
    self.id = id
    self.name = name
    self.isDefault = isDefault
    self.sortOptions = sortOptions
  }
}

public struct TiebaForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let category: String
  public let subcategory: String
  public let memberCount: Int
  public let threadCount: Int
  public let postCount: Int
  public let hasModerators: Bool
  public let hasRules: Bool
  public let avatar: String
  public let slogan: String
  public let featuredClassifications: [TiebaForumClassification]

  public init(
    id: Int64,
    name: String,
    category: String,
    subcategory: String,
    memberCount: Int,
    threadCount: Int,
    postCount: Int,
    hasModerators: Bool,
    hasRules: Bool,
    avatar: String = "",
    slogan: String = "",
    featuredClassifications: [TiebaForumClassification] = []
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.subcategory = subcategory
    self.memberCount = memberCount
    self.threadCount = threadCount
    self.postCount = postCount
    self.hasModerators = hasModerators
    self.hasRules = hasRules
    self.avatar = avatar
    self.slogan = slogan
    self.featuredClassifications = featuredClassifications
  }
}

public struct TiebaForumOverview: Sendable, Hashable {
  public let forum: TiebaForum
  public let introduction: String
  public let originalAvatar: String

  public init(
    forum: TiebaForum,
    introduction: String,
    originalAvatar: String
  ) {
    self.forum = forum
    self.introduction = introduction
    self.originalAvatar = originalAvatar
  }
}

public struct TiebaForumModerator: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let level: Int
  public let roleName: String

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    level: Int,
    roleName: String
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.level = level
    self.roleName = roleName
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaForumModeratorRole: Sendable, Hashable {
  public let name: String
  public let moderators: [TiebaForumModerator]

  public init(name: String, moderators: [TiebaForumModerator]) {
    self.name = name
    self.moderators = moderators
  }
}

public struct TiebaForumRule: Sendable, Hashable {
  public let title: String
  public let content: TiebaContent
  public let status: Int

  public init(title: String, content: TiebaContent, status: Int) {
    self.title = title
    self.content = content
    self.status = status
  }
}

public struct TiebaForumRules: Sendable, Hashable {
  public let forum: TiebaForum
  public let title: String
  public let preface: String
  public let rules: [TiebaForumRule]
  public let publishTime: String
  public let author: TiebaForumModerator?

  public init(
    forum: TiebaForum,
    title: String,
    preface: String,
    rules: [TiebaForumRule],
    publishTime: String,
    author: TiebaForumModerator?
  ) {
    self.forum = forum
    self.title = title
    self.preface = preface
    self.rules = rules
    self.publishTime = publishTime
    self.author = author
  }
}

public struct TiebaThreadIdentity: Sendable, Hashable {
  public let threadID: Int64
  public let forumID: Int64
  public let forumName: String

  public init(threadID: Int64, forumID: Int64, forumName: String) {
    self.threadID = threadID
    self.forumID = forumID
    self.forumName = forumName
  }
}

public struct TiebaThread: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let firstPostID: Int64
  public let forumID: Int64
  public let forumName: String
  public let title: String
  public let content: TiebaContent
  public let author: TiebaUser?
  public let kind: TiebaThreadKind
  public let tabID: Int
  public let viewCount: Int
  public let replyCount: Int
  public let shareCount: Int
  public let agreeCount: Int
  public let disagreeCount: Int
  public let createdAt: Date?
  public let lastReplyAt: Date?
  public let isPinned: Bool
  public let isFeatured: Bool
  public let isShared: Bool
  public let isHidden: Bool
  public let isLive: Bool
  public let pagePostIDs: [Int64]

  public init(
    id: Int64,
    firstPostID: Int64,
    forumID: Int64,
    forumName: String,
    title: String,
    content: TiebaContent,
    author: TiebaUser?,
    kind: TiebaThreadKind,
    tabID: Int,
    viewCount: Int,
    replyCount: Int,
    shareCount: Int,
    agreeCount: Int,
    disagreeCount: Int,
    createdAt: Date?,
    lastReplyAt: Date?,
    isPinned: Bool,
    isFeatured: Bool,
    isShared: Bool,
    isHidden: Bool,
    isLive: Bool,
    pagePostIDs: [Int64] = []
  ) {
    self.id = id
    self.firstPostID = firstPostID
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.content = content
    self.author = author
    self.kind = kind
    self.tabID = tabID
    self.viewCount = viewCount
    self.replyCount = replyCount
    self.shareCount = shareCount
    self.agreeCount = agreeCount
    self.disagreeCount = disagreeCount
    self.createdAt = createdAt
    self.lastReplyAt = lastReplyAt
    self.isPinned = isPinned
    self.isFeatured = isFeatured
    self.isShared = isShared
    self.isHidden = isHidden
    self.isLive = isLive
    self.pagePostIDs = pagePostIDs
  }
}

public struct TiebaOriginThread: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let firstPostID: Int64
  public let forumID: Int64
  public let forumName: String
  public let title: String
  public let content: TiebaContent
  public let poll: TiebaPoll?

  public init(
    id: Int64,
    firstPostID: Int64,
    forumID: Int64,
    forumName: String,
    title: String,
    content: TiebaContent,
    poll: TiebaPoll? = nil
  ) {
    self.id = id
    self.firstPostID = firstPostID
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.content = content
    self.poll = poll
  }
}

public struct TiebaPollOption: Sendable, Hashable {
  public let id: Int32
  public let text: String
  public let voteCount: Int64
  public let image: String

  public init(id: Int32 = 0, text: String, voteCount: Int64, image: String = "") {
    self.id = id
    self.text = text
    self.voteCount = voteCount
    self.image = image
  }
}

public struct TiebaPoll: Sendable, Hashable {
  public let type: Int32
  public let title: String
  public let isMultipleChoice: Bool
  public let isPolled: Bool
  public let selectedOptionIDs: Set<Int32>
  public let tips: String
  public let endTimestamp: Int64
  public let status: Int32
  public let lastTimestamp: Int64
  public let participantCount: Int64
  public let totalVoteCount: Int64
  public let options: [TiebaPollOption]

  public init(
    type: Int32 = 0,
    title: String,
    isMultipleChoice: Bool,
    isPolled: Bool = false,
    selectedOptionIDs: Set<Int32> = [],
    tips: String = "",
    endTimestamp: Int64 = 0,
    status: Int32 = 0,
    lastTimestamp: Int64 = 0,
    participantCount: Int64,
    totalVoteCount: Int64,
    options: [TiebaPollOption]
  ) {
    self.type = type
    self.title = title
    self.isMultipleChoice = isMultipleChoice
    self.isPolled = isPolled
    self.selectedOptionIDs = selectedOptionIDs
    self.tips = tips
    self.endTimestamp = endTimestamp
    self.status = status
    self.lastTimestamp = lastTimestamp
    self.participantCount = participantCount
    self.totalVoteCount = totalVoteCount
    self.options = options
  }

  public func isClosed(at date: Date = Date()) -> Bool {
    status != 0 || (endTimestamp > 0 && endTimestamp <= Int64(date.timeIntervalSince1970))
  }
}

public struct TiebaComment: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let threadID: Int64
  public let parentPostID: Int64
  public let floor: Int
  public let author: TiebaUser?
  public let replyToUserID: Int64?
  public let replyToUserName: String
  public let content: TiebaContent
  public let agreeCount: Int
  public let disagreeCount: Int
  public let agreeScore: Int
  public let createdAt: Date?
  public let isThreadAuthor: Bool

  public init(
    id: Int64,
    threadID: Int64,
    parentPostID: Int64,
    floor: Int,
    author: TiebaUser?,
    replyToUserID: Int64?,
    content: TiebaContent,
    agreeCount: Int,
    disagreeCount: Int,
    createdAt: Date?,
    isThreadAuthor: Bool,
    agreeScore: Int? = nil,
    replyToUserName: String = ""
  ) {
    self.id = id
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.floor = floor
    self.author = author
    self.replyToUserID = replyToUserID
    self.replyToUserName = replyToUserName
    self.content = content
    self.agreeCount = agreeCount
    self.disagreeCount = disagreeCount
    self.agreeScore = agreeScore ?? inferredAgreeScore(agreeCount, disagreeCount)
    self.createdAt = createdAt
    self.isThreadAuthor = isThreadAuthor
  }
}

public struct TiebaPost: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let threadID: Int64
  public let floor: Int
  public let author: TiebaUser?
  public let content: TiebaContent
  public let signature: String
  public let comments: [TiebaComment]
  public let commentCount: Int
  public let agreeCount: Int
  public let disagreeCount: Int
  public let agreeScore: Int
  public let createdAt: Date?
  public let isThreadAuthor: Bool
  public let isAIMeme: Bool

  public init(
    id: Int64,
    threadID: Int64,
    floor: Int,
    author: TiebaUser?,
    content: TiebaContent,
    signature: String,
    comments: [TiebaComment],
    commentCount: Int,
    agreeCount: Int,
    disagreeCount: Int,
    createdAt: Date?,
    isThreadAuthor: Bool,
    isAIMeme: Bool,
    agreeScore: Int? = nil
  ) {
    self.id = id
    self.threadID = threadID
    self.floor = floor
    self.author = author
    self.content = content
    self.signature = signature
    self.comments = comments
    self.commentCount = commentCount
    self.agreeCount = agreeCount
    self.disagreeCount = disagreeCount
    self.agreeScore = agreeScore ?? inferredAgreeScore(agreeCount, disagreeCount)
    self.createdAt = createdAt
    self.isThreadAuthor = isThreadAuthor
    self.isAIMeme = isAIMeme
  }
}

private func inferredAgreeScore(_ agreeCount: Int, _ disagreeCount: Int) -> Int {
  let (score, overflow) = agreeCount.subtractingReportingOverflow(disagreeCount)
  guard overflow else { return score }
  return agreeCount >= 0 ? Int.max : Int.min
}

public struct TiebaThreadPage: Sendable, Hashable {
  public let forum: TiebaForum
  public let threads: [TiebaThread]
  public let pagination: TiebaPagination
  public let tabs: [String: Int]
  public let channels: [TiebaForumChannel]

  public init(
    forum: TiebaForum,
    threads: [TiebaThread],
    pagination: TiebaPagination,
    tabs: [String: Int],
    channels: [TiebaForumChannel] = []
  ) {
    self.forum = forum
    self.threads = threads
    self.pagination = pagination
    self.tabs = tabs
    self.channels = channels
  }
}

public struct TiebaForumChannelPage: Sendable, Hashable {
  public let channel: TiebaForumChannel
  public let threads: [TiebaThread]
  public let pagination: TiebaPagination
  public let nextPageCursor: Int64?

  public init(
    channel: TiebaForumChannel,
    threads: [TiebaThread],
    pagination: TiebaPagination,
    nextPageCursor: Int64?
  ) {
    self.channel = channel
    self.threads = threads
    self.pagination = pagination
    self.nextPageCursor = nextPageCursor
  }
}

public struct TiebaUserThreadPage: Sendable, Hashable {
  public let userID: Int64
  public let threads: [TiebaThread]
  public let pagination: TiebaPagination
  public let isHidden: Bool

  public init(
    userID: Int64,
    threads: [TiebaThread],
    pagination: TiebaPagination,
    isHidden: Bool
  ) {
    self.userID = userID
    self.threads = threads
    self.pagination = pagination
    self.isHidden = isHidden
  }
}

public enum TiebaUserReplyTarget: Sendable, Hashable {
  case post
  case comment
  case unsupported(rawType: UInt64)
}

public struct TiebaUserReply: Sendable, Hashable {
  public let threadID: Int64
  public let forumID: Int64
  public let forumName: String
  public let threadTitle: String
  public let postID: Int64
  public let createdAt: Date?
  public let content: TiebaContent
  public let author: TiebaUser?
  public let target: TiebaUserReplyTarget

  public init(
    threadID: Int64,
    forumID: Int64,
    forumName: String,
    threadTitle: String,
    postID: Int64,
    createdAt: Date?,
    content: TiebaContent,
    author: TiebaUser?,
    target: TiebaUserReplyTarget
  ) {
    self.threadID = threadID
    self.forumID = forumID
    self.forumName = forumName
    self.threadTitle = threadTitle
    self.postID = postID
    self.createdAt = createdAt
    self.content = content
    self.author = author
    self.target = target
  }
}

public struct TiebaUserReplyPage: Sendable, Hashable {
  public let userID: Int64
  public let replies: [TiebaUserReply]
  public let pagination: TiebaPagination
  public let isHidden: Bool

  public init(
    userID: Int64,
    replies: [TiebaUserReply],
    pagination: TiebaPagination,
    isHidden: Bool
  ) {
    self.userID = userID
    self.replies = replies
    self.pagination = pagination
    self.isHidden = isHidden
  }
}

public struct TiebaPostPage: Sendable, Hashable {
  public let forum: TiebaForum
  public let thread: TiebaThread
  public let originThread: TiebaOriginThread?
  public let poll: TiebaPoll?
  public let firstPost: TiebaPost?
  public let posts: [TiebaPost]
  public let pagination: TiebaPagination

  public init(
    forum: TiebaForum,
    thread: TiebaThread,
    posts: [TiebaPost],
    pagination: TiebaPagination,
    originThread: TiebaOriginThread? = nil,
    poll: TiebaPoll? = nil,
    firstPost: TiebaPost? = nil
  ) {
    self.forum = forum
    self.thread = thread
    self.originThread = originThread
    self.poll = poll
    self.firstPost = firstPost
    self.posts = posts
    self.pagination = pagination
  }
}

public struct TiebaCommentPage: Sendable, Hashable {
  public let forum: TiebaForum
  public let thread: TiebaThread
  public let parentPost: TiebaPost
  public let comments: [TiebaComment]
  public let pagination: TiebaPagination

  public init(
    forum: TiebaForum,
    thread: TiebaThread,
    parentPost: TiebaPost,
    comments: [TiebaComment],
    pagination: TiebaPagination
  ) {
    self.forum = forum
    self.thread = thread
    self.parentPost = parentPost
    self.comments = comments
    self.pagination = pagination
  }
}
