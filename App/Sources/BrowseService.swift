import Foundation

enum ForumThreadSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case replyTime
  case creationTime

  var id: Self { self }

  var title: String {
    switch self {
    case .replyTime:
      "回复"
    case .creationTime:
      "发帖"
    }
  }
}

struct ForumChannelSort: RawRepresentable, Hashable, Sendable {
  let rawValue: Int32

  init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  static let unspecified = ForumChannelSort(rawValue: -1)
  static let replyTime = ForumChannelSort(rawValue: 0)
  static let creationTime = ForumChannelSort(rawValue: 1)
}

struct ForumBrowseOptions: Codable, Equatable, Sendable {
  var sort: ForumThreadSort
  var featuredOnly: Bool
  var featuredClassificationID: Int?

  init(
    sort: ForumThreadSort = .replyTime,
    featuredOnly: Bool = false,
    featuredClassificationID: Int? = nil
  ) {
    self.sort = sort
    self.featuredOnly = featuredOnly
    self.featuredClassificationID = featuredClassificationID
  }
}

enum ThreadPostSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case ascending
  case descending
  case hot

  var id: Self { self }

  var title: String {
    switch self {
    case .ascending:
      "正序"
    case .descending:
      "倒序"
    case .hot:
      "热门"
    }
  }
}

struct ThreadBrowseOptions: Codable, Hashable, Sendable {
  var sort: ThreadPostSort
  var onlyThreadAuthor: Bool

  init(sort: ThreadPostSort = .ascending, onlyThreadAuthor: Bool = false) {
    self.sort = sort
    self.onlyThreadAuthor = onlyThreadAuthor
  }
}

enum ThreadPostLocation: Hashable, Sendable {
  case postID(Int64)
  case pageNumber
  case pageCursor(Int64)
  case latestReplies(after: Int64)
}

protocol BrowseService: Sendable {
  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData
  func forumChannelThreads(
    forumID: Int64,
    forumName: String,
    channel: BrowseForumChannel,
    page: Int,
    pageSize: Int,
    sort: ForumChannelSort,
    lastThreadID: Int64?
  ) async throws -> ForumChannelPageData
  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData
  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData
  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData
  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData
}

extension BrowseService {
  func forumChannelThreads(
    forumID: Int64,
    forumName: String,
    channel: BrowseForumChannel,
    page: Int,
    pageSize: Int,
    sort: ForumChannelSort,
    lastThreadID: Int64?
  ) async throws -> ForumChannelPageData {
    throw BrowseError.unavailable("当前浏览服务不支持贴吧频道。")
  }
}

protocol SearchService: Sendable {
  func searchForums(query: String) async throws -> ForumSearchData
  func searchUsers(query: String) async throws -> UserSearchData
  func searchThreads(
    query: String,
    page: Int,
    pageSize: Int,
    sort: GlobalThreadSearchSort
  ) async throws
    -> ThreadSearchPageData
}

protocol SearchSuggestionService: Sendable {
  func searchSuggestions(query: String) async throws -> [String]
}

protocol ForumPostSearchService: Sendable {
  func searchForumPosts(
    query: String,
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) async throws -> ForumPostSearchPageData
}

protocol HotTopicService: Sendable {
  func hotTopics() async throws -> [HotTopicItem]
  func hotTopic(
    id: Int64,
    name: String,
    page: Int,
    pageSize: Int,
    lastID: Int64?
  ) async throws -> HotTopicPageData
}

protocol HotThreadService: Sendable {
  func hotThreads(categoryCode: String) async throws -> HotThreadFeedData
}

protocol UserProfileService: Sendable {
  func userProfile(userID: Int64) async throws -> BrowseUserProfile
  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserReplyPageData
  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
}

protocol ForumInformationService: Sendable {
  func forumOverview(forumID: Int64) async throws -> BrowseForumOverview
  func forumModeratorRoles(forumID: Int64) async throws -> [BrowseForumModeratorRole]
  func forumRules(forumID: Int64) async throws -> BrowseForumRules
}

enum BrowseError: LocalizedError, Sendable {
  case invalidForumName
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidForumName:
      "吧名不能为空"
    case .unavailable(let message):
      message
    }
  }
}
