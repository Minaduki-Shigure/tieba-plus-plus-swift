import Foundation

public struct TiebaForumSearchResult: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let displayName: String
  public let avatarURL: URL?
  public let postCount: Int
  public let memberCount: Int
  public let introduction: String
  public let slogan: String

  public init(
    id: Int64,
    name: String,
    displayName: String,
    avatarURL: URL?,
    postCount: Int,
    memberCount: Int,
    introduction: String,
    slogan: String
  ) {
    self.id = id
    self.name = name
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.postCount = postCount
    self.memberCount = memberCount
    self.introduction = introduction
    self.slogan = slogan
  }
}

public struct TiebaForumSearchResults: Sendable, Hashable {
  public let exactMatch: TiebaForumSearchResult?
  public let fuzzyMatches: [TiebaForumSearchResult]
  public let isLoggedIn: Bool

  public init(
    exactMatch: TiebaForumSearchResult?,
    fuzzyMatches: [TiebaForumSearchResult],
    isLoggedIn: Bool
  ) {
    self.exactMatch = exactMatch
    self.fuzzyMatches = fuzzyMatches
    self.isLoggedIn = isLoggedIn
  }
}

public struct TiebaUserSearchResult: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let username: String
  public let displayName: String
  public let portrait: String
  public let introduction: String

  public init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    introduction: String
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.introduction = introduction
  }

  public var preferredName: String {
    displayName.isEmpty ? username : displayName
  }
}

public struct TiebaUserSearchResults: Sendable, Hashable {
  public let exactMatch: TiebaUserSearchResult?
  public let fuzzyMatches: [TiebaUserSearchResult]

  public init(
    exactMatch: TiebaUserSearchResult?,
    fuzzyMatches: [TiebaUserSearchResult]
  ) {
    self.exactMatch = exactMatch
    self.fuzzyMatches = fuzzyMatches
  }
}

public struct TiebaSearchImage: Sendable, Hashable {
  public let thumbnailURL: URL?
  public let fullSizeURL: URL?
  public let width: Int
  public let height: Int

  public init(thumbnailURL: URL?, fullSizeURL: URL?, width: Int, height: Int) {
    self.thumbnailURL = thumbnailURL
    self.fullSizeURL = fullSizeURL
    self.width = width
    self.height = height
  }
}

public enum TiebaThreadSearchSort: Int, CaseIterable, Sendable, Hashable {
  case newest = 1
  case relevance = 2
}

public enum TiebaThreadSearchFilter: Int, CaseIterable, Sendable, Hashable {
  case threadsOnly = 1
  case all = 2
}

public enum TiebaThreadSearchTarget: Sendable, Hashable {
  case thread
  case post(Int64)
  case comment(postID: Int64, commentID: Int64)
}

public struct TiebaSearchPostContext: Sendable, Hashable {
  public let threadID: Int64
  public let postID: Int64?
  public let title: String
  public let excerpt: String
  public let authorID: Int64
  public let authorName: String
  public let authorPortraitURL: URL?
  public let replyCount: Int
  public let likeCount: Int
  public let shareCount: Int

  public init(
    threadID: Int64,
    postID: Int64?,
    title: String,
    excerpt: String,
    authorID: Int64,
    authorName: String,
    authorPortraitURL: URL?,
    replyCount: Int = 0,
    likeCount: Int = 0,
    shareCount: Int = 0
  ) {
    self.threadID = threadID
    self.postID = postID
    self.title = title
    self.excerpt = excerpt
    self.authorID = authorID
    self.authorName = authorName
    self.authorPortraitURL = authorPortraitURL
    self.replyCount = replyCount
    self.likeCount = likeCount
    self.shareCount = shareCount
  }
}

public struct TiebaThreadSearchResult: Identifiable, Sendable, Hashable {
  public var id: String {
    switch target {
    case .thread:
      "thread:\(threadID)"
    case .post(let postID):
      "post:\(threadID):\(postID)"
    case .comment(let postID, let commentID):
      "comment:\(threadID):\(postID):\(commentID)"
    }
  }

  public let threadID: Int64
  public let firstPostID: Int64
  public let matchedPostID: Int64
  public let forumID: Int64
  public let forumName: String
  public let title: String
  public let excerpt: String
  public let authorID: Int64
  public let authorName: String
  public let authorPortraitURL: URL?
  public let replyCount: Int
  public let likeCount: Int
  public let shareCount: Int
  public let createdAt: Date?
  public let images: [TiebaSearchImage]
  public let target: TiebaThreadSearchTarget
  public let mainPost: TiebaSearchPostContext?
  public let postInfo: TiebaSearchPostContext?

  public init(
    threadID: Int64,
    firstPostID: Int64,
    matchedPostID: Int64? = nil,
    forumID: Int64,
    forumName: String,
    title: String,
    excerpt: String,
    authorID: Int64,
    authorName: String,
    authorPortraitURL: URL?,
    replyCount: Int,
    likeCount: Int,
    shareCount: Int,
    createdAt: Date?,
    images: [TiebaSearchImage],
    target: TiebaThreadSearchTarget = .thread,
    mainPost: TiebaSearchPostContext? = nil,
    postInfo: TiebaSearchPostContext? = nil
  ) {
    self.threadID = threadID
    self.firstPostID = firstPostID
    self.matchedPostID = matchedPostID ?? firstPostID
    self.forumID = forumID
    self.forumName = forumName
    self.title = title
    self.excerpt = excerpt
    self.authorID = authorID
    self.authorName = authorName
    self.authorPortraitURL = authorPortraitURL
    self.replyCount = replyCount
    self.likeCount = likeCount
    self.shareCount = shareCount
    self.createdAt = createdAt
    self.images = images
    self.target = target
    self.mainPost = mainPost
    self.postInfo = postInfo
  }
}

public struct TiebaThreadSearchPage: Sendable, Hashable {
  public let results: [TiebaThreadSearchResult]
  public let pagination: TiebaPagination
  public let isLoggedIn: Bool

  public init(
    results: [TiebaThreadSearchResult],
    pagination: TiebaPagination,
    isLoggedIn: Bool
  ) {
    self.results = results
    self.pagination = pagination
    self.isLoggedIn = isLoggedIn
  }
}
