#if PERFORMANCE_HARNESS
  import Foundation
  import SwiftUI

  enum ThreadScrollPerformanceScenario: String, CaseIterable, Sendable {
    case baseline
    case longPlainText = "long-plain-text"
    case inlineReplies = "inline-replies"
    case manyFloors = "many-floors"

    static var requested: Self? {
      guard
        let value = ProcessInfo.processInfo.environment["TIEBA_PERFORMANCE_SCENARIO"]
      else { return nil }
      return Self(rawValue: value)
    }

    fileprivate var thread: BrowseThread {
      BrowseThread(
        id: ThreadScrollPerformanceFixture.threadID,
        forumID: ThreadScrollPerformanceFixture.forumID,
        forumName: "性能测试",
        title: "离线滚动性能测试",
        excerpt: "",
        authorName: "PERF-READY-\(rawValue)",
        replyCount: ThreadScrollPerformanceFixture.postCount(for: self) - 1,
        viewCount: 1,
        createdAt: nil,
        lastReplyAt: nil,
        contents: [],
        firstPostID: ThreadScrollPerformanceFixture.firstPostID
      )
    }
  }

  @MainActor
  struct ThreadScrollPerformanceRootView: View {
    let scenario: ThreadScrollPerformanceScenario

    var body: some View {
      NavigationStack {
        ThreadView(
          thread: scenario.thread,
          service: ThreadScrollPerformanceService(scenario: scenario),
          historyRepository: ThreadScrollPerformanceHistoryRepository(),
          favoritesRepository: ThreadScrollPerformanceFavoritesRepository(),
          searchHistoryRepository: ThreadScrollPerformanceSearchHistoryRepository()
        )
      }
    }
  }

  private struct ThreadScrollPerformanceService:
    BrowseService, ForumPostSearchService, UserProfileService, ForumInformationService
  {
    let scenario: ThreadScrollPerformanceScenario

    func posts(
      threadID: Int64,
      page: Int,
      pageSize: Int,
      options: ThreadBrowseOptions,
      location: ThreadPostLocation?
    ) async throws -> PostPageData {
      guard
        threadID == ThreadScrollPerformanceFixture.threadID,
        page == 1,
        pageSize == 30,
        options == ThreadBrowseOptions(),
        location == nil
      else {
        throw ThreadScrollPerformanceError.unexpectedRequest("posts")
      }
      return ThreadScrollPerformanceFixture.page(for: scenario)
    }

    func threads(
      forumName: String,
      page: Int,
      pageSize: Int,
      options: ForumBrowseOptions
    ) async throws -> ThreadPageData {
      throw ThreadScrollPerformanceError.unexpectedRequest("threads")
    }

    func comments(threadID: Int64, postID: Int64, page: Int) async throws
      -> CommentPageData
    {
      throw ThreadScrollPerformanceError.unexpectedRequest("comments")
    }

    func comments(
      threadID: Int64,
      postID: Int64,
      aroundCommentID commentID: Int64,
      page: Int
    ) async throws -> CommentPageData {
      throw ThreadScrollPerformanceError.unexpectedRequest("comments-around")
    }

    func comments(
      threadID: Int64,
      resolvingCommentID commentID: Int64
    ) async throws -> CommentPageData {
      throw ThreadScrollPerformanceError.unexpectedRequest("comments-resolve")
    }

    func searchForumPosts(
      query: String,
      forumName: String,
      page: Int,
      pageSize: Int,
      sort: ForumPostSearchSort,
      filter: ForumPostSearchFilter
    ) async throws -> ForumPostSearchPageData {
      throw ThreadScrollPerformanceError.unexpectedRequest("forum-search")
    }

    func userProfile(userID: Int64) async throws -> BrowseUserProfile {
      throw ThreadScrollPerformanceError.unexpectedRequest("user-profile")
    }

    func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
      -> UserThreadPageData
    {
      throw ThreadScrollPerformanceError.unexpectedRequest("user-threads")
    }

    func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
      -> UserReplyPageData
    {
      throw ThreadScrollPerformanceError.unexpectedRequest("user-replies")
    }

    func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
      -> UserRelationPageData
    {
      throw ThreadScrollPerformanceError.unexpectedRequest("user-relations")
    }

    func forumOverview(forumID: Int64) async throws -> BrowseForumOverview {
      throw ThreadScrollPerformanceError.unexpectedRequest("forum-overview")
    }

    func forumModeratorRoles(forumID: Int64) async throws -> [BrowseForumModeratorRole] {
      throw ThreadScrollPerformanceError.unexpectedRequest("forum-moderators")
    }

    func forumRules(forumID: Int64) async throws -> BrowseForumRules {
      throw ThreadScrollPerformanceError.unexpectedRequest("forum-rules")
    }
  }

  private enum ThreadScrollPerformanceFixture {
    static let forumID: Int64 = 9_100
    static let threadID: Int64 = 9_100_001
    static let firstPostID: Int64 = 9_101_001

    static func postCount(for scenario: ThreadScrollPerformanceScenario) -> Int {
      // This models the steady state after four normal pages without timing pagination itself.
      scenario == .manyFloors ? 120 : 30
    }

    static func page(for scenario: ThreadScrollPerformanceScenario) -> PostPageData {
      let count = postCount(for: scenario)
      let allPosts = (1...count).map { post(floor: $0, scenario: scenario) }
      return PostPageData(
        thread: scenario.thread,
        posts: Array(allPosts.dropFirst()),
        currentPage: 1,
        hasMore: false,
        totalPages: 1,
        totalCount: count,
        firstPost: allPosts.first
      )
    }

    private static func post(
      floor: Int,
      scenario: ThreadScrollPerformanceScenario
    ) -> BrowsePost {
      let postID = firstPostID + Int64(floor - 1)
      let contents: [BrowseContent]
      let inlineComments: [BrowseComment]
      switch scenario {
      case .baseline, .manyFloors:
        contents = [.text(text(floor: floor, targetLength: 120, paragraphCount: 1))]
        inlineComments = []
      case .longPlainText:
        contents = [.text(text(floor: floor, targetLength: 900, paragraphCount: 6))]
        inlineComments = []
      case .inlineReplies:
        contents = [.text(text(floor: floor, targetLength: 120, paragraphCount: 1))]
        inlineComments = (1...50).map { reply in
          comment(postID: postID, floor: floor, reply: reply)
        }
      }
      return BrowsePost(
        id: postID,
        threadID: threadID,
        floor: floor,
        authorID: 10_000 + Int64(floor),
        authorName: floor == 1 ? "PERF-READY-\(scenario.rawValue)" : "测试用户 \(floor)",
        authorPortraitURL: nil,
        createdAt: nil,
        nestedReplyCount: inlineComments.count,
        isThreadAuthor: floor == 1,
        contents: contents,
        authorLevel: (floor % 18) + 1,
        authorIPLocation: "测试环境",
        agreeScore: floor % 37,
        inlineComments: inlineComments
      )
    }

    private static func comment(postID: Int64, floor: Int, reply: Int) -> BrowseComment {
      BrowseComment(
        id: postID * 10 + Int64(reply),
        authorID: 20_000 + Int64(floor * 10 + reply),
        authorName: "回复用户 \(reply)",
        authorPortraitURL: nil,
        createdAt: nil,
        contents: [.text(text(floor: floor + reply, targetLength: 80, paragraphCount: 1))],
        authorLevel: reply + 1,
        agreeScore: reply,
        threadID: threadID,
        parentPostID: postID
      )
    }

    private static func text(floor: Int, targetLength: Int, paragraphCount: Int) -> String {
      let fragments = [
        "这是用于滚动性能分析的固定中文段落，内容不会访问网络，也不会随运行时间变化。",
        "当前楼层包含足够的文字来触发实际换行、字形塑形和动态高度计算。",
        "测试会比较普通文字、超长纯文本以及带楼中楼回复的三种独立场景。",
        "每次运行都使用相同的数据顺序，从而让调用栈和性能指标可以进行相对比较。",
      ]
      var result = "第 \(floor) 楼。"
      var index = 0
      while result.count < targetLength {
        if index > 0, index % max(paragraphCount, 1) == 0 {
          result.append("\n")
        }
        result.append(fragments[(floor + index) % fragments.count])
        index += 1
      }
      return String(result.prefix(targetLength))
    }
  }

  private enum ThreadScrollPerformanceError: Error, Sendable {
    case unexpectedRequest(String)
  }

  private struct ThreadScrollPerformanceHistoryRepository: BrowsingHistoryRepository {
    func entries(kind: BrowsingHistoryKind?) async throws -> [BrowsingHistoryEntry] { [] }
    func isRecordingEnabled() async throws -> Bool { false }
    func setRecordingEnabled(_ enabled: Bool) async throws {}
    func record(_ target: BrowsingHistoryTarget, at date: Date) async throws {}
    func updateThreadProgress(
      threadID: Int64,
      postID: Int64,
      floor: Int,
      options: ThreadBrowseOptions,
      at date: Date
    ) async throws {}
    func updateThreadOptions(
      threadID: Int64,
      options: ThreadBrowseOptions,
      at date: Date
    ) async throws {}
    func delete(id: String) async throws {}
    func deleteAll(kind: BrowsingHistoryKind?) async throws {}
  }

  private struct ThreadScrollPerformanceFavoritesRepository: LocalFavoritesRepository {
    func entries(kind: LocalFavoriteKind?) async throws -> [LocalFavoriteEntry] { [] }
    func contains(id: String) async throws -> Bool { false }
    func save(_ target: LocalFavoriteTarget, at date: Date) async throws {}
    func setForumPinned(id: String, isPinned: Bool, at date: Date) async throws {}
    func updateThreadProgress(
      threadID: Int64,
      postID: Int64,
      floor: Int,
      options: ThreadBrowseOptions,
      at date: Date
    ) async throws {}
    func updateThreadOptions(
      threadID: Int64,
      options: ThreadBrowseOptions,
      at date: Date
    ) async throws {}
    func delete(id: String) async throws {}
    func deleteAll(kind: LocalFavoriteKind?) async throws {}
  }

  private struct ThreadScrollPerformanceSearchHistoryRepository:
    ForumSearchHistoryRepository
  {
    func entries(forumName: String) async throws -> [ForumSearchHistoryEntry] { [] }
    func record(query: String, forumName: String, at date: Date) async throws {}
    func delete(id: String) async throws {}
    func deleteAll(forumName: String) async throws {}
    func reset() async throws {}
  }
#endif
