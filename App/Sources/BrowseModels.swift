import Foundation

struct ThreadPageData: Sendable {
  let forumName: String
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
}

struct PostPageData: Sendable {
  let thread: BrowseThread
  let posts: [BrowsePost]
  let currentPage: Int
  let hasMore: Bool
}

struct CommentPageData: Sendable {
  let comments: [BrowseComment]
  let currentPage: Int
  let hasMore: Bool
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

struct ThreadSearchPageData: Sendable {
  let threads: [BrowseThread]
  let currentPage: Int
  let hasMore: Bool
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
