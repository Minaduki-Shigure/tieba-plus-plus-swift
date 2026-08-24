#if PERFORMANCE_HARNESS
  import Foundation
  import QuartzCore
  import SwiftUI

  struct ThreadScrollFrameMetrics: Codable, Equatable, Sendable {
    let frameCount: Int
    let expectedFrameDurationMS: Double
    let p50MS: Double
    let p95MS: Double
    let p99MS: Double
    let maximumMS: Double
    let overBudgetCount: Int
    let overTwoFramesCount: Int
  }

  @MainActor
  final class ThreadScrollFrameRecorder: NSObject {
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var intervalsMS: [Double] = []
    private var expectedFrameDurationMS = 1_000.0 / 60.0

    func start() {
      guard displayLink == nil else { return }
      intervalsMS.removeAll(keepingCapacity: true)
      previousTimestamp = nil
      let displayLink = CADisplayLink(target: self, selector: #selector(recordFrame(_:)))
      if displayLink.duration.isFinite, displayLink.duration > 0 {
        expectedFrameDurationMS = displayLink.duration * 1_000
      }
      displayLink.add(to: .main, forMode: .common)
      self.displayLink = displayLink
    }

    func stop() -> ThreadScrollFrameMetrics {
      displayLink?.invalidate()
      displayLink = nil
      previousTimestamp = nil
      let sorted = intervalsMS.sorted()
      return ThreadScrollFrameMetrics(
        frameCount: sorted.count,
        expectedFrameDurationMS: expectedFrameDurationMS,
        p50MS: percentile(0.50, in: sorted),
        p95MS: percentile(0.95, in: sorted),
        p99MS: percentile(0.99, in: sorted),
        maximumMS: sorted.last ?? 0,
        overBudgetCount: sorted.lazy.filter { $0 > expectedFrameDurationMS * 1.5 }.count,
        overTwoFramesCount: sorted.lazy.filter { $0 > expectedFrameDurationMS * 2.5 }.count
      )
    }

    @objc private func recordFrame(_ displayLink: CADisplayLink) {
      defer { previousTimestamp = displayLink.timestamp }
      guard let previousTimestamp else { return }
      let intervalMS = (displayLink.timestamp - previousTimestamp) * 1_000
      guard intervalMS.isFinite, intervalMS > 0 else { return }
      intervalsMS.append(intervalMS)
    }

    private func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
      guard !sorted.isEmpty else { return 0 }
      let rank = max(Int(ceil(Double(sorted.count) * percentile)) - 1, 0)
      return sorted[min(rank, sorted.count - 1)]
    }
  }

  enum ThreadScrollPerformanceExperiment: String, Sendable {
    case control
    case omitInlineMinimumScale = "omit-inline-minimum-scale"
    case omitLongTextFixedSize = "omit-long-text-fixed-size"
    case skipEmptyImageGalleryCover = "skip-empty-image-gallery-cover"
    case lazyCommentsContainer = "lazy-comments-container"

    static let requested: Self = {
      guard
        let value = ProcessInfo.processInfo.environment["TIEBA_PERFORMANCE_EXPERIMENT"]
      else { return .control }
      guard let experiment = Self(rawValue: value) else {
        preconditionFailure("Unsupported thread scroll performance experiment: \(value)")
      }
      return experiment
    }()
  }

  enum ThreadScrollPerformanceScenario: String, CaseIterable, Sendable {
    case baseline
    case longPlainText = "long-plain-text"
    case inlineReplies = "inline-replies"
    case manyFloors = "many-floors"
    case nestedComments = "nested-comments"
    case mixedNestedComments = "mixed-nested-comments"

    static let requested: Self? = {
      guard
        let value = ProcessInfo.processInfo.environment["TIEBA_PERFORMANCE_SCENARIO"]
      else { return nil }
      return Self(rawValue: value)
    }()

    static let requestedProfileID: String? = {
      guard
        let value = ProcessInfo.processInfo.environment["TIEBA_PERFORMANCE_PROFILE_ID"],
        !value.isEmpty
      else { return nil }
      let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
      guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
      return value
    }()

    static let appliesInlinePreviewMinimumScaleFactor =
      requested == .inlineReplies
      && ThreadScrollPerformanceExperiment.requested != .omitInlineMinimumScale

    static let appliesLongTextFixedSize =
      requested == .longPlainText
      && ThreadScrollPerformanceExperiment.requested != .omitLongTextFixedSize

    static var installsLegacyEmptyImageGalleryCovers: Bool {
      guard requested?.isCommentsScenario == true else { return false }
      return ThreadScrollPerformanceExperiment.requested == .control
    }

    static var usesLegacyCommentsList: Bool {
      guard requested?.isCommentsScenario == true else { return false }
      return ThreadScrollPerformanceExperiment.requested != .lazyCommentsContainer
    }

    var isCommentsScenario: Bool {
      self == .nestedComments || self == .mixedNestedComments
    }

    static var isSelfDrivenProfileRequested: Bool {
      ProcessInfo.processInfo.environment["TIEBA_PERFORMANCE_AUTOSCROLL"] == "1"
    }

    @MainActor
    static func waitForSelfDrivenProfileStart() async throws -> Bool {
      guard isSelfDrivenProfileRequested, let markerURL = profileMarkerURL(phase: "go") else {
        return false
      }
      for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: markerURL.path) { return true }
        try await Task.sleep(for: .milliseconds(100))
      }
      return false
    }

    @discardableResult
    @MainActor
    static func writeSelfDrivenProfileMarker(phase: String) -> Bool {
      guard let markerURL = profileMarkerURL(phase: phase) else { return false }
      do {
        try phase.write(to: markerURL, atomically: true, encoding: .utf8)
        return true
      } catch {
        return false
      }
    }

    @discardableResult
    @MainActor
    static func writeFrameMetrics(_ metrics: ThreadScrollFrameMetrics) -> Bool {
      guard let metricsURL = profileMarkerURL(phase: "frames.json") else { return false }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: metricsURL, options: .atomic)
        return true
      } catch {
        return false
      }
    }

    @MainActor
    private static func profileMarkerURL(phase: String) -> URL? {
      guard let scenario = requested else { return nil }
      let markerID = requestedProfileID ?? scenario.rawValue
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("tieba-scroll-profile-\(markerID)-\(phase)")
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

  extension View {
    @ViewBuilder
    func threadScrollProfileMinimumScaleFactor(_ factor: CGFloat, isEnabled: Bool) -> some View {
      if isEnabled {
        minimumScaleFactor(factor)
      } else {
        self
      }
    }

    @ViewBuilder
    func threadScrollProfileFixedSize(
      horizontal: Bool,
      vertical: Bool,
      isEnabled: Bool
    ) -> some View {
      if isEnabled {
        fixedSize(horizontal: horizontal, vertical: vertical)
      } else {
        self
      }
    }
  }

  @MainActor
  struct ThreadScrollPerformanceRootView: View {
    let scenario: ThreadScrollPerformanceScenario

    var body: some View {
      NavigationStack {
        if scenario.isCommentsScenario {
          CommentsView(
            threadID: ThreadScrollPerformanceFixture.threadID,
            postID: ThreadScrollPerformanceFixture.commentsParentPostID,
            service: ThreadScrollPerformanceService(scenario: scenario),
            historyRepository: ThreadScrollPerformanceHistoryRepository(),
            favoritesRepository: ThreadScrollPerformanceFavoritesRepository(),
            searchHistoryRepository: ThreadScrollPerformanceSearchHistoryRepository(),
            showsDismissButton: false
          )
        } else {
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
      guard
        scenario.isCommentsScenario,
        threadID == ThreadScrollPerformanceFixture.threadID,
        postID == ThreadScrollPerformanceFixture.commentsParentPostID,
        page == 1
      else { throw ThreadScrollPerformanceError.unexpectedRequest("comments") }
      return ThreadScrollPerformanceFixture.commentsPage(for: scenario)
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
    static let commentsParentPostID: Int64 = 9_101_002

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
        inlineComments = (1...4).map { reply in
          comment(postID: postID, floor: floor, reply: reply)
        }
      case .nestedComments, .mixedNestedComments:
        contents = [.text(text(floor: floor, targetLength: 120, paragraphCount: 1))]
        inlineComments = []
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
        id: postID * 100 + Int64(reply),
        authorID: 20_000 + Int64(floor * 100 + reply),
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

    static func commentsPage(for scenario: ThreadScrollPerformanceScenario) -> CommentPageData {
      let count = scenario == .mixedNestedComments ? 600 : 240
      let comments = (1...count).map { index in
        detailComment(index: index, scenario: scenario)
      }
      let thread = scenario.thread
      let parentPost = CommentParentPostContext(
        id: commentsParentPostID,
        threadID: threadID,
        floor: 2,
        authorID: 9_200,
        authorName: "楼中楼性能测试父楼",
        authorPortraitURL: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        isThreadAuthor: false,
        contents: [.text(text(floor: 2, targetLength: 180, paragraphCount: 1))],
        authorLevel: 12,
        authorIPLocation: "测试环境",
        agreeScore: 42
      )
      var agreementTargets = Set(comments.compactMap { comment in
        ContentAgreementTarget(
          thread: thread,
          parentPostID: parentPost.id,
          comment: comment
        )
      })
      if let parentAgreementTarget = ContentAgreementTarget(
        thread: thread,
        parentPost: parentPost
      ) {
        agreementTargets.insert(parentAgreementTarget)
      }
      let agreementRequest = ContentAgreementSubpostPageRequest(
        forumID: thread.forumID,
        forumName: thread.forumName,
        threadID: thread.id,
        parentPostID: parentPost.id,
        aroundSubpostID: nil,
        page: 1
      )!
      return CommentPageData(
        parentPost: parentPost,
        comments: comments,
        currentPage: 1,
        hasMore: false,
        totalPages: 1,
        totalCount: count,
        thread: thread,
        agreementReadDescriptor: ContentAgreementReadDescriptor(
          request: .subpostPage(agreementRequest),
          expectedTargets: agreementTargets
        )
      )
    }

    private static func detailComment(
      index: Int,
      scenario: ThreadScrollPerformanceScenario
    ) -> BrowseComment {
      let visibility: LocalContentVisibility
      if scenario == .mixedNestedComments, index.isMultiple(of: 11) {
        visibility = .hidden
      } else if scenario == .mixedNestedComments, index.isMultiple(of: 5) {
        visibility = .placeholder
      } else {
        visibility = .visible
      }
      return BrowseComment(
        id: commentsParentPostID * 1_000 + Int64(index),
        authorID: 30_000 + Int64(index),
        authorName: "楼中楼测试用户 \(index) 的较长昵称",
        authorPortraitURL: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
        contents: detailCommentContents(index: index),
        authorLevel: (index % 18) + 1,
        authorIPLocation: "测试环境",
        agreeScore: index % 97,
        isThreadAuthor: index.isMultiple(of: 23),
        localVisibility: visibility,
        threadID: threadID,
        parentPostID: commentsParentPostID
      )
    }

    private static func detailCommentContents(index: Int) -> [BrowseContent] {
      if index.isMultiple(of: 13) {
        return [.text(text(floor: index, targetLength: 520, paragraphCount: 2))]
      }
      if index.isMultiple(of: 5) {
        return [
          .text("回复 "),
          .mention(name: "被回复用户 \(index - 1)", userID: 40_000 + Int64(index)),
          .text("：\(text(floor: index, targetLength: 96, paragraphCount: 1))"),
          .emoticon(name: "微笑", url: nil),
        ]
      }
      if index.isMultiple(of: 7) {
        return [
          .text(text(floor: index, targetLength: 72, paragraphCount: 1)),
          .link(
            label: "查看相关主题",
            url: URL(string: "https://tieba.baidu.com/p/\(threadID)")!
          ),
        ]
      }
      let targetLength = 42 + (index % 4) * 48
      return [.text(text(floor: index, targetLength: targetLength, paragraphCount: 1))]
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
