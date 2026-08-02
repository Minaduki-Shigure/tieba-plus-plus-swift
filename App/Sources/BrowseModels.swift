import Foundation

struct BrowseForumClassification: Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
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

  init(
    forum: BrowseForum,
    threads: [BrowseThread],
    currentPage: Int,
    hasMore: Bool
  ) {
    self.forum = forum
    self.threads = threads
    self.currentPage = currentPage
    self.hasMore = hasMore
  }

  init(
    forumName: String,
    threads: [BrowseThread],
    currentPage: Int,
    hasMore: Bool
  ) {
    self.init(
      forum: .placeholder(name: forumName),
      threads: threads,
      currentPage: currentPage,
      hasMore: hasMore
    )
  }
}

struct PostPageData: Sendable {
  let thread: BrowseThread
  let originThread: BrowseThread?
  let posts: [BrowsePost]
  let currentPage: Int
  let hasMore: Bool
  let totalPages: Int
  let totalCount: Int
  let nextPagePostID: Int64?

  init(
    thread: BrowseThread,
    posts: [BrowsePost],
    currentPage: Int,
    hasMore: Bool,
    totalPages: Int = 0,
    totalCount: Int = 0,
    nextPagePostID: Int64? = nil,
    originThread: BrowseThread? = nil
  ) {
    self.thread = thread
    self.originThread = originThread
    self.posts = posts
    self.currentPage = currentPage
    self.hasMore = hasMore
    self.totalPages = totalPages
    self.totalCount = totalCount
    self.nextPagePostID = nextPagePostID
  }
}

struct CommentPageData: Sendable {
  let comments: [BrowseComment]
  let currentPage: Int
  let hasMore: Bool
}

enum BrowseGender: Sendable, Hashable {
  case unknown
  case male
  case female
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

struct BrowseThread: Identifiable, Hashable, Sendable {
  let id: Int64
  let forumID: Int64
  let forumName: String
  let title: String
  let excerpt: String
  let authorName: String
  let replyCount: Int
  let viewCount: Int
  let createdAt: Date?
  let lastReplyAt: Date?
  let contents: [BrowseContent]
}

struct BrowsePost: Identifiable, Hashable, Sendable {
  let id: Int64
  let threadID: Int64
  let floor: Int
  let authorID: Int64
  let authorName: String
  let authorPortraitURL: URL?
  let createdAt: Date?
  let nestedReplyCount: Int
  let isThreadAuthor: Bool
  let contents: [BrowseContent]
}

struct BrowseComment: Identifiable, Hashable, Sendable {
  let id: Int64
  let authorID: Int64
  let authorName: String
  let authorPortraitURL: URL?
  let createdAt: Date?
  let contents: [BrowseContent]
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
