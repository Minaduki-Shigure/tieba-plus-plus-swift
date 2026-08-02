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
  public let isModerator: Bool
  public let isVIP: Bool
  public let isVerifiedCreator: Bool

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
    isVerifiedCreator: Bool
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
    self.isModerator = isModerator
    self.isVIP = isVIP
    self.isVerifiedCreator = isVerifiedCreator
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaUserProfile: Sendable, Hashable {
  public let user: TiebaUser
  public let tiebaUID: Int64?
  public let biography: String
  public let tiebaAge: String
  public let threadCount: Int
  public let postCount: Int
  public let followerCount: Int
  public let followingCount: Int
  public let followedForumCount: Int
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
    totalAgreeCount: Int64,
    isBlocked: Bool
  ) {
    self.user = user
    self.tiebaUID = tiebaUID
    self.biography = biography
    self.tiebaAge = tiebaAge
    self.threadCount = threadCount
    self.postCount = postCount
    self.followerCount = followerCount
    self.followingCount = followingCount
    self.followedForumCount = followedForumCount
    self.totalAgreeCount = totalAgreeCount
    self.isBlocked = isBlocked
  }
}

public struct TiebaImage: Sendable, Hashable {
  public let thumbnailURL: URL?
  public let fullSizeURL: URL?
  public let originalURL: URL?
  public let width: Int
  public let height: Int
  public let originalByteCount: Int

  public init(
    thumbnailURL: URL?,
    fullSizeURL: URL?,
    originalURL: URL?,
    width: Int,
    height: Int,
    originalByteCount: Int
  ) {
    self.thumbnailURL = thumbnailURL
    self.fullSizeURL = fullSizeURL
    self.originalURL = originalURL
    self.width = width
    self.height = height
    self.originalByteCount = originalByteCount
  }
}

public struct TiebaVideo: Sendable, Hashable {
  public let streamURL: URL?
  public let coverURL: URL?
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
    viewCount: Int
  ) {
    self.streamURL = streamURL
    self.coverURL = coverURL
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

public enum TiebaPostSort: Int32, Sendable, Hashable {
  case ascending = 0
  case descending = 1
  case hot = 2
}

public enum TiebaPostLocation: Sendable, Hashable {
  case postID(Int64)
  case pageNumber
  case pageCursor(Int64)
}

public struct TiebaForumClassification: Identifiable, Sendable, Hashable {
  public let id: Int
  public let name: String

  public init(id: Int, name: String) {
    self.id = id
    self.name = name
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

public struct TiebaComment: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let threadID: Int64
  public let parentPostID: Int64
  public let floor: Int
  public let author: TiebaUser?
  public let replyToUserID: Int64?
  public let content: TiebaContent
  public let agreeCount: Int
  public let disagreeCount: Int
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
    isThreadAuthor: Bool
  ) {
    self.id = id
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.floor = floor
    self.author = author
    self.replyToUserID = replyToUserID
    self.content = content
    self.agreeCount = agreeCount
    self.disagreeCount = disagreeCount
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
    isAIMeme: Bool
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
    self.createdAt = createdAt
    self.isThreadAuthor = isThreadAuthor
    self.isAIMeme = isAIMeme
  }
}

public struct TiebaThreadPage: Sendable, Hashable {
  public let forum: TiebaForum
  public let threads: [TiebaThread]
  public let pagination: TiebaPagination
  public let tabs: [String: Int]

  public init(
    forum: TiebaForum,
    threads: [TiebaThread],
    pagination: TiebaPagination,
    tabs: [String: Int]
  ) {
    self.forum = forum
    self.threads = threads
    self.pagination = pagination
    self.tabs = tabs
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

public struct TiebaPostPage: Sendable, Hashable {
  public let forum: TiebaForum
  public let thread: TiebaThread
  public let posts: [TiebaPost]
  public let pagination: TiebaPagination

  public init(
    forum: TiebaForum,
    thread: TiebaThread,
    posts: [TiebaPost],
    pagination: TiebaPagination
  ) {
    self.forum = forum
    self.thread = thread
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
