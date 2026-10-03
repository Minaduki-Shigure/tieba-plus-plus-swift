#if DEBUG
  import Combine
  import Foundation
  import SwiftUI

  /// Dispatch before initializing the production App, which owns Keychain, disk
  /// repositories and background account runtimes. Release has no fixture entry.
  @main
  @MainActor
  enum TiebaPlusPlusDebugEntryPoint {
    static func main() {
      if ProcessInfo.processInfo.arguments.contains("--explore-refresh-ui-testing") {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppPreferenceKey.personalizedRecommendationPersona] = "anonymous"
        arguments[AppPreferenceKey.personalizedFollowedForumsOnly] = false
        arguments[AppPreferenceKey.homeShowsDiscovery] = true
        arguments[AppPreferenceKey.homeShowsRecentForums] = false
        arguments[AppPreferenceKey.searchSuggestionsEnabled] = false
        arguments[InboxNotificationRuntime.enabledKey] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        ExploreRefreshUITestApp.main()
      } else {
        TiebaPlusPlusApp.main()
      }
    }
  }

  @MainActor
  private struct ExploreRefreshUITestApp: App {
    @StateObject private var dependencies = ExploreRefreshUITestDependencies()

    var body: some Scene {
      WindowGroup {
        RootView(
          service: dependencies.service,
          historyRepository: dependencies.repositories,
          favoritesRepository: dependencies.repositories,
          searchHistoryRepository: dependencies.repositories,
          globalSearchHistoryRepository: dependencies.repositories,
          accountVault: dependencies.vault,
          accountSessionLookup: dependencies.vault,
          accountService: dependencies.service,
          personalizedFeedbackService: dependencies.service,
          contentFilterRepository: dependencies.contentFilters,
          startDestination: .discovery,
          showsExploreTab: true
        )
        .environment(\.accountAccess, dependencies.accountAccess)
        .environment(\.contentFilterRepository, dependencies.contentFilters)
        .environment(\.contentMediaLoadPolicy, .tapToLoad)
        .environment(\.contentMediaLoadBehavior, .userInitiated)
        .environment(\.hidesReplyEntryPoints, true)
        .environmentObject(dependencies.mediaPlayback)
        .environmentObject(dependencies.voicePlayback)
        .environmentObject(dependencies.videoPlayback)
        .environmentObject(dependencies.followedForums)
        .environmentObject(dependencies.checkIns)
        .environmentObject(dependencies.externalWeb)
        .environmentObject(dependencies.sceneDelegate)
        .overlay(alignment: .topLeading) {
          ExploreRefreshUITestProbeView(probe: dependencies.probe)
            .allowsHitTesting(false)
        }
      }
    }
  }

  @MainActor
  private final class ExploreRefreshUITestDependencies: ObservableObject {
    let probe = ExploreRefreshUITestProbe()
    let vault = ExploreRefreshUITestVault()
    let repositories = ExploreRefreshUITestRepositories()
    let contentFilters = EmptyContentFilterRepository()
    let mediaPlayback = MediaPlaybackCoordinator()
    let externalWeb = ExternalWebPresentationModel()
    // Only the observable quick-action dependency, not a UIApplication/scene
    // delegate. No production runtime registration or lifecycle callbacks run.
    let sceneDelegate = TiebaSceneDelegate()
    let service: ExploreRefreshUITestService
    let accountAccess: AccountAccess
    let voicePlayback: VoicePlaybackController
    let videoPlayback: VideoPlaybackController
    let followedForums: FollowedForumsViewModel
    let checkIns: FollowedForumCheckInStore

    init() {
      let service = ExploreRefreshUITestService(probe: probe)
      self.service = service
      accountAccess = AccountAccess(vault: vault, service: service)
      voicePlayback = VoicePlaybackController(coordinator: mediaPlayback)
      videoPlayback = VideoPlaybackController(coordinator: mediaPlayback)
      followedForums = FollowedForumsViewModel(service: service, vault: vault)
      checkIns = FollowedForumCheckInStore(
        vault: vault, catalogLoader: { try await service.checkInCatalog(session: $0) })
    }
  }

  @MainActor
  private final class ExploreRefreshUITestProbe: ObservableObject {
    @Published private var counts: [String: Int] = [:]

    func record(_ key: String) -> Int {
      counts[key, default: 0] += 1
      return counts[key, default: 0]
    }

    var summary: String {
      ["concern", "personalized", "hot", "posts"]
        .map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
    }
  }

  private struct ExploreRefreshUITestProbeView: View {
    @ObservedObject var probe: ExploreRefreshUITestProbe

    var body: some View {
      Text(probe.summary)
        .font(.system(size: 9, design: .monospaced))
        .accessibilityIdentifier("explore-refresh-request-counts")
    }
  }

  /// All credentials are inert generated values retained only by this actor.
  /// The mock service below is the sole consumer; no authenticated client exists.
  private actor ExploreRefreshUITestVault: AccountVault, AccountSessionLookup {
    private let account = StoredAccountSession(
      id: 7, username: "offline-fixture", displayName: "离线测试账号", portrait: "",
      bduss: String(repeating: "b", count: 192), stoken: String(repeating: "s", count: 64),
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
    )

    func accountSummaries() -> [AccountSummary] {
      [
        AccountSummary(
          id: account.id, username: account.username, displayName: account.displayName,
          portraitURL: nil, isActive: true, hasFullCredentials: true, updatedAt: account.updatedAt)
      ]
    }
    func activeSession() -> StoredAccountSession? { account }
    func session(userID: Int64) -> StoredAccountSession? { userID == account.id ? account : nil }
    func upsert(_ session: StoredAccountSession) throws {
      throw ExploreRefreshUITestService.unsupported
    }
    func switchActive(to userID: Int64) throws { throw ExploreRefreshUITestService.unsupported }
    func remove(userID: Int64) throws { throw ExploreRefreshUITestService.unsupported }
    func removeAll() throws { throw ExploreRefreshUITestService.unsupported }
  }

  /// Empty local storage keeps the real navigation and view models independent
  /// of a simulator's previous app data. No file-backed store is constructed.
  private actor ExploreRefreshUITestRepositories: BrowsingHistoryRepository,
    LocalFavoritesRepository, ForumSearchHistoryRepository, GlobalSearchHistoryRepository
  {
    func entries(kind: BrowsingHistoryKind?) -> [BrowsingHistoryEntry] { [] }
    func entries(kind: LocalFavoriteKind?) -> [LocalFavoriteEntry] { [] }
    func entries(forumName: String) -> [ForumSearchHistoryEntry] { [] }
    func entries() -> [GlobalSearchHistoryEntry] { [] }
    func isRecordingEnabled() -> Bool { false }
    func setRecordingEnabled(_ enabled: Bool) {}
    func record(_ target: BrowsingHistoryTarget, at date: Date) {}
    func record(query: String, forumName: String, at date: Date) {}
    func record(query: String, at date: Date) {}
    func contains(id: String) -> Bool { false }
    func save(_ target: LocalFavoriteTarget, at date: Date) {}
    func setForumPinned(id: String, isPinned: Bool, at date: Date) {}
    func updateThreadProgress(
      threadID: Int64, postID: Int64, floor: Int, options: ThreadBrowseOptions, at date: Date
    ) {}
    func updateThreadOptions(threadID: Int64, options: ThreadBrowseOptions, at date: Date) {}
    func delete(id: String) {}
    func deleteAll(kind: BrowsingHistoryKind?) {}
    func deleteAll(kind: LocalFavoriteKind?) {}
    func deleteAll(forumName: String) {}
    func deleteAll() {}
    func reset() {}
  }

  /// Full RootView protocol surface, deliberately without a network transport.
  /// Unsupported operations fail locally, including every account write.
  private actor ExploreRefreshUITestService: BrowseService, SearchService,
    ForumPostSearchService, HotTopicService, HotThreadService, PersonalizedFeedService,
    UserProfileService, ForumInformationService, SearchSuggestionService,
    TiebaLinkPreviewService, AccountService, PersonalizedFeedbackService
  {
    static var unsupported: BrowseError { .unavailable("离线界面测试不提供此操作。") }
    private let probe: ExploreRefreshUITestProbe
    private var threadsByID: [Int64: BrowseThread] = [:]

    init(probe: ExploreRefreshUITestProbe) { self.probe = probe }

    private func thread(channel: String, title: String, id: Int64) async -> BrowseThread {
      let count = await probe.record(channel)
      let thread = BrowseThread(
        id: id, forumID: 100, forumName: "离线测试", title: "\(title)·第\(count)次",
        excerpt: "点击此条目进入真实帖子页面", authorName: "离线作者", replyCount: 0,
        viewCount: count, createdAt: nil, lastReplyAt: nil, contents: [],
        authorID: 8, firstPostID: id + 1_000
      )
      threadsByID[id] = thread
      return thread
    }

    func personalizedThreads(page: Int) async -> PersonalizedFeedPageData {
      let thread = await thread(channel: "personalized", title: "推荐", id: 101)
      return PersonalizedFeedPageData(
        items: [PersonalizedFeedItem(thread: thread, feedbackReasons: [])],
        currentPage: page, hasMore: false)
    }

    func personalizedThreads(page: Int, session: StoredAccountSession) async
      -> PersonalizedFeedPageData
    {
      await personalizedThreads(page: page)
    }

    func concernFeed(session: StoredAccountSession, pageTag: String?, lastRequestUnix: UInt64) async
      -> ConcernFeedPageData
    {
      let thread = await thread(channel: "concern", title: "关注", id: 102)
      return ConcernFeedPageData(
        userID: session.id, threads: [thread], nextPageTag: nil, hasMore: false,
        requestUnix: max(lastRequestUnix, 1))
    }

    func hotThreads(categoryCode: String) async -> HotThreadFeedData {
      let thread = await thread(channel: "hot", title: "热门", id: 103)
      return HotThreadFeedData(
        topics: [], categories: [.all],
        items: [HotThreadRankItem(rank: 1, hotScore: 100, thread: thread)])
    }

    func posts(
      threadID: Int64, page: Int, pageSize: Int, options: ThreadBrowseOptions,
      location: ThreadPostLocation?
    ) async throws -> PostPageData {
      guard let thread = threadsByID[threadID] else { throw Self.unsupported }
      _ = await probe.record("posts")
      let post = BrowsePost(
        id: thread.firstPostID, threadID: threadID, floor: 1, authorID: thread.authorID,
        authorName: thread.authorName, authorPortraitURL: nil, createdAt: nil,
        nestedReplyCount: 0, isThreadAuthor: true, contents: [.text("离线帖子正文")])
      return PostPageData(
        thread: thread, posts: [], currentPage: 1, hasMore: false,
        totalPages: 1, totalCount: 1, firstPost: post)
    }

    func followedForums(session: StoredAccountSession, page: Int, pageSize: Int)
      -> FollowedForumPageData
    { FollowedForumPageData(forums: [], currentPage: page, hasMore: false) }

    func inboxUnreadSummary(session: StoredAccountSession) -> InboxUnreadSummary {
      InboxUnreadSummary(userID: session.id, replyCount: 0, mentionCount: 0, fanCount: 0)
    }

    func checkInCatalog(session: StoredAccountSession) -> ForumCheckInCatalogData {
      ForumCheckInCatalogData(userID: session.id, targets: [], officialBatchPolicy: nil)
    }

    func searchForums(query: String) -> ForumSearchData {
      ForumSearchData(exactMatch: nil, related: [])
    }
    func searchUsers(query: String) -> UserSearchData {
      UserSearchData(exactMatch: nil, related: [])
    }
    func searchThreads(query: String, page: Int, pageSize: Int, sort: GlobalThreadSearchSort)
      -> ThreadSearchPageData
    { ThreadSearchPageData(threads: [], currentPage: page, hasMore: false) }
    func searchSuggestions(query: String) -> [String] { [] }
    func preview(for target: TiebaLinkTarget) -> TiebaLinkPreviewMetadata? { nil }

    func threads(forumName: String, page: Int, pageSize: Int, options: ForumBrowseOptions) throws
      -> ThreadPageData
    { throw Self.unsupported }
    func comments(threadID: Int64, postID: Int64, page: Int) throws -> CommentPageData {
      throw Self.unsupported
    }
    func comments(threadID: Int64, postID: Int64, aroundCommentID: Int64, page: Int) throws
      -> CommentPageData
    { throw Self.unsupported }
    func comments(threadID: Int64, resolvingCommentID: Int64) throws -> CommentPageData {
      throw Self.unsupported
    }
    func searchForumPosts(
      query: String, forumName: String, page: Int, pageSize: Int, sort: ForumPostSearchSort,
      filter: ForumPostSearchFilter
    ) throws -> ForumPostSearchPageData { throw Self.unsupported }
    func hotTopics() throws -> [HotTopicItem] { throw Self.unsupported }
    func hotTopic(id: Int64, name: String, page: Int, pageSize: Int, lastID: Int64?) throws
      -> HotTopicPageData
    { throw Self.unsupported }
    func userProfile(userID: Int64) throws -> BrowseUserProfile { throw Self.unsupported }
    func userThreads(userID: Int64, page: Int, pageSize: Int) throws -> UserThreadPageData {
      throw Self.unsupported
    }
    func userReplies(userID: Int64, page: Int, pageSize: Int) throws -> UserReplyPageData {
      throw Self.unsupported
    }
    func userRelations(userID: Int64, kind: UserRelationKind, page: Int) throws
      -> UserRelationPageData
    { throw Self.unsupported }
    func forumOverview(forumID: Int64) throws -> BrowseForumOverview { throw Self.unsupported }
    func forumModeratorRoles(forumID: Int64) throws -> [BrowseForumModeratorRole] {
      throw Self.unsupported
    }
    func forumRules(forumID: Int64) throws -> BrowseForumRules { throw Self.unsupported }
    func validate(credential: AccountCredentials) throws -> ValidatedAccount {
      throw Self.unsupported
    }
    func forumMembership(session: StoredAccountSession, forumID: Int64, forumName: String) throws
      -> ForumMembershipData
    { throw Self.unsupported }
    func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String) throws
      -> ForumAccountStateData
    { throw Self.unsupported }
    func setForumFollowed(
      session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
    ) throws -> ForumMembershipData { throw Self.unsupported }
    func checkInToForum(session: StoredAccountSession, forumID: Int64, forumName: String) throws
      -> ForumAccountStateData
    { throw Self.unsupported }
    func submitPersonalizedFeedback(
      session: StoredAccountSession, submission: PersonalizedFeedbackSubmission
    ) throws { throw Self.unsupported }
  }
#endif
