import Foundation

protocol BrowseService: Sendable {
  func threads(forumName: String, page: Int, pageSize: Int) async throws -> ThreadPageData
  func posts(threadID: Int64, page: Int, pageSize: Int) async throws -> PostPageData
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
