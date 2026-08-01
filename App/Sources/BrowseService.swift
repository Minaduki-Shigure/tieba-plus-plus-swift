import Foundation

enum ForumThreadSort: String, CaseIterable, Hashable, Identifiable, Sendable {
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

struct ForumBrowseOptions: Equatable, Sendable {
  var sort: ForumThreadSort
  var featuredOnly: Bool

  init(sort: ForumThreadSort = .replyTime, featuredOnly: Bool = false) {
    self.sort = sort
    self.featuredOnly = featuredOnly
  }
}

enum ThreadPostSort: String, CaseIterable, Hashable, Identifiable, Sendable {
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

struct ThreadBrowseOptions: Equatable, Sendable {
  var sort: ThreadPostSort
  var onlyThreadAuthor: Bool

  init(sort: ThreadPostSort = .ascending, onlyThreadAuthor: Bool = false) {
    self.sort = sort
    self.onlyThreadAuthor = onlyThreadAuthor
  }
}

protocol BrowseService: Sendable {
  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData
  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions
  ) async throws -> PostPageData
  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData
}

protocol SearchService: Sendable {
  func searchForums(query: String) async throws -> ForumSearchData
  func searchThreads(query: String, page: Int, pageSize: Int) async throws
    -> ThreadSearchPageData
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
