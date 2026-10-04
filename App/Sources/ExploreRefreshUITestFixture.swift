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
        if ProcessInfo.processInfo.arguments.contains("--forum-sections-ui-testing") {
          arguments[AppPreferenceKey.forumPrimaryAction] = ForumPrimaryAction.scrollToTop.rawValue
        }
        if ProcessInfo.processInfo.arguments.contains("--home-refresh-ui-testing") {
          arguments[AppPreferenceKey.followedForumsLayout] =
            FollowedForumsLayoutMode.singleColumn.rawValue
        }
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
        ExploreRefreshUITestRoot(dependencies: dependencies)
      }
    }
  }

  @MainActor
  private struct ExploreRefreshUITestRoot: View {
    @ObservedObject var dependencies: ExploreRefreshUITestDependencies
    @State private var selectedWidth: Int = 390
    @State private var showsExplore = true
    @State private var largeText = false

    var body: some View {
      if dependencies.testsAdaptiveNavigation {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            adaptiveControls
            // Keep one RootView at this exact structural position. The controls
            // alter its real layout proposal, never its mode, traits or identity.
            root
              .environment(\.dynamicTypeSize, largeText ? .accessibility1 : .large)
              .frame(
                width: selectedWidth == 0
                  ? geometry.size.width
                  : min(CGFloat(selectedWidth), geometry.size.width)
              )
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      } else {
        root.overlay(alignment: .topLeading) { probes.allowsHitTesting(false) }
      }
    }

    private var root: some View {
      Group {
        if dependencies.forumProbe != nil {
          NavigationStack {
            NavigationLink("进入离线贴吧") {
              ForumView(
                forumName: "离线分区", service: dependencies.service,
                historyRepository: dependencies.repositories,
                favoritesRepository: dependencies.repositories,
                searchHistoryRepository: dependencies.repositories)
            }
            .navigationTitle("离线测试入口")
          }
        } else {
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
            startDestination: dependencies.homeProbe == nil ? .discovery : .home,
            showsExploreTab: showsExplore
          )
        }
      }
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
    }

    private var probes: some View {
      VStack(alignment: .leading, spacing: 1) {
        ExploreRefreshUITestProbeView(probe: dependencies.probe)
        if let homeProbe = dependencies.homeProbe {
          HomeRefreshUITestProbeView(probe: homeProbe)
        }
        if let forumProbe = dependencies.forumProbe {
          ForumSectionsUITestProbeView(probe: forumProbe)
        }
      }
    }

    private var adaptiveControls: some View {
      VStack(alignment: .leading, spacing: 2) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach([390, 599, 600, 839, 840, 1024, 0], id: \.self) { width in
              Button(width == 0 ? "可用宽度" : "\(width)") { selectedWidth = width }
                .accessibilityIdentifier("adaptive-width-\(width)")
            }
            Button(showsExplore ? "隐藏发现" : "显示发现") { showsExplore.toggle() }
              .accessibilityIdentifier("adaptive-toggle-explore")
            Button(largeText ? "标准字体" : "大字体") { largeText.toggle() }
              .accessibilityIdentifier("adaptive-toggle-text")
          }
          .buttonStyle(.bordered)
        }
        ExploreRefreshRequestCountsUITestView(probe: dependencies.probe)
      }
      .dynamicTypeSize(.medium)
      .padding(.horizontal, 8)
      .frame(height: 60)
      .background(.bar)
    }
  }

  @MainActor
  private final class ExploreRefreshUITestDependencies: ObservableObject {
    let probe = ExploreRefreshUITestProbe()
    let homeProbe: HomeRefreshUITestProbe?
    let testsAdaptiveNavigation: Bool
    let forumProbe: ForumSectionsUITestProbe?
    let vault: ExploreRefreshUITestVault
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
      let arguments = ProcessInfo.processInfo.arguments
      let testsHome = arguments.contains("--home-refresh-ui-testing")
      testsAdaptiveNavigation = arguments.contains("--adaptive-root-ui-testing")
      homeProbe = testsHome ? HomeRefreshUITestProbe() : nil
      forumProbe =
        arguments.contains("--forum-sections-ui-testing") ? ForumSectionsUITestProbe() : nil
      vault = ExploreRefreshUITestVault(
        isSignedOut: testsHome && arguments.contains("--home-refresh-signed-out"))
      let service = ExploreRefreshUITestService(
        probe: probe, homeProbe: homeProbe, forumProbe: forumProbe,
        unreadReplyCount: testsAdaptiveNavigation ? 7 : 0)
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
      VStack(alignment: .leading, spacing: 1) {
        ExploreRefreshRequestCountsUITestView(probe: probe)
        if let diagnostics = ExploreRefreshLifecycleDiagnostics.active {
          ExploreRefreshLifecycleProbeView(diagnostics: diagnostics)
        }
      }
    }
  }

  private struct ExploreRefreshRequestCountsUITestView: View {
    @ObservedObject var probe: ExploreRefreshUITestProbe

    var body: some View {
      Text(probe.summary)
        .font(.system(size: 9, design: .monospaced))
        .accessibilityIdentifier("explore-refresh-request-counts")
    }
  }

  /// Kept separate so the original Explore fixture's observable contract and
  /// request counts remain unchanged when its tests briefly visit Home.
  @MainActor
  private final class HomeRefreshUITestProbe: ObservableObject {
    @Published private var counts: [String: Int] = [:]

    func record(_ key: String) -> Int {
      counts[key, default: 0] += 1
      return counts[key, default: 0]
    }

    var summary: String {
      ["page1", "page2", "catalog", "unexpected"]
        .map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
    }
  }

  private struct HomeRefreshUITestProbeView: View {
    @ObservedObject var probe: HomeRefreshUITestProbe

    var body: some View {
      Text(probe.summary)
        .font(.system(size: 9, design: .monospaced))
        .accessibilityIdentifier("home-refresh-request-counts")
    }
  }

  @MainActor
  private final class ForumSectionsUITestProbe: ObservableObject {
    @Published private var counts: [String: Int] = [:]

    func record(_ key: String) { counts[key, default: 0] += 1 }

    var summary: String {
      ["latest", "featured", "channel71", "channel72", "account", "unexpected"]
        .map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
    }
  }

  private struct ForumSectionsUITestProbeView: View {
    @ObservedObject var probe: ForumSectionsUITestProbe

    var body: some View {
      Text(probe.summary)
        .font(.system(size: 8, design: .monospaced))
        .accessibilityIdentifier("forum-section-request-counts")
    }
  }

  private struct ExploreRefreshLifecycleProbeView: View {
    @ObservedObject var diagnostics: ExploreRefreshLifecycleDiagnostics

    var body: some View {
      Text(diagnostics.summary)
        .font(.system(size: 7, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 390, alignment: .leading)
        .accessibilityIdentifier("explore-refresh-lifecycle")
    }
  }

  /// Synchronous, fixture-only observations. No tasks, notifications or feed
  /// state are changed; release builds compile out both this type and its calls.
  @MainActor
  final class ExploreRefreshLifecycleDiagnostics: ObservableObject {
    static let active: ExploreRefreshLifecycleDiagnostics? =
      ProcessInfo.processInfo.arguments.contains("--explore-refresh-ui-testing")
      ? ExploreRefreshLifecycleDiagnostics() : nil

    @Published private(set) var summary = "lifecycle awaiting events"
    private var sequence = 0
    private var appearances = 0
    private var disappearances = 0
    private var starts = 0
    private var cancellations = 0
    private var root = "root=?"
    private var explore = "explore=?"
    private var personal = "personal=?"
    private var model = "model=?"

    func recordRoot(phase: String, tab: RootMainTab) {
      sequence += 1
      root = "root#\(sequence) phase=\(phase) tab=\(tab.rawValue)"
      publish()
    }

    func recordExplore(selection: ExploreSection, sections: [ExploreSection], ready: Bool) {
      sequence += 1
      explore =
        "explore#\(sequence) selected=\(selection.rawValue) ready=\(ready) "
        + "pages=\(sections.map(\.rawValue).joined(separator: ","))"
      publish()
    }

    func recordPersonal(event: String, active: Bool, visible: Bool) {
      sequence += 1
      if event == "appear" { appearances += 1 }
      if event == "disappear" { disappearances += 1 }
      personal =
        "personal#\(sequence) \(event) appear=\(appearances) disappear=\(disappearances) "
        + "active=\(active) visible=\(visible) load=\(active && visible)"
      publish()
    }

    func recordModel(event: String, state: LoadState, generation: Int) {
      sequence += 1
      if event == "start" { starts += 1 }
      if event == "cancel" { cancellations += 1 }
      let stateName: String
      switch state {
      case .idle: stateName = "idle"
      case .loading: stateName = "loading"
      case .loaded: stateName = "loaded"
      case .failed: stateName = "failed"
      }
      model =
        "model#\(sequence) \(event) state=\(stateName) generation=\(generation) "
        + "starts=\(starts) cancels=\(cancellations)"
      publish()
    }

    private func publish() {
      summary = [root, explore, personal, model].joined(separator: "\n")
    }
  }

  /// All credentials are inert generated values retained only by this actor.
  /// The mock service below is the sole consumer; no authenticated client exists.
  private actor ExploreRefreshUITestVault: AccountVault, AccountSessionLookup {
    private let isSignedOut: Bool
    private let account = StoredAccountSession(
      id: 7, username: "offline-fixture", displayName: "离线测试账号", portrait: "",
      bduss: String(repeating: "b", count: 192), stoken: String(repeating: "s", count: 64),
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
    )

    init(isSignedOut: Bool = false) { self.isSignedOut = isSignedOut }

    func accountSummaries() -> [AccountSummary] {
      guard !isSignedOut else { return [] }
      return [
        AccountSummary(
          id: account.id, username: account.username, displayName: account.displayName,
          portraitURL: nil, isActive: true, hasFullCredentials: true, updatedAt: account.updatedAt)
      ]
    }
    func activeSession() -> StoredAccountSession? { isSignedOut ? nil : account }
    func session(userID: Int64) -> StoredAccountSession? {
      !isSignedOut && userID == account.id ? account : nil
    }
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
    private let homeProbe: HomeRefreshUITestProbe?
    private let unreadReplyCount: Int
    private let forumProbe: ForumSectionsUITestProbe?
    private var homeGeneration = 0
    private var threadsByID: [Int64: BrowseThread] = [:]

    init(
      probe: ExploreRefreshUITestProbe, homeProbe: HomeRefreshUITestProbe?,
      forumProbe: ForumSectionsUITestProbe?, unreadReplyCount: Int
    ) {
      self.probe = probe
      self.homeProbe = homeProbe
      self.unreadReplyCount = unreadReplyCount
      self.forumProbe = forumProbe
    }

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

    func followedForums(session: StoredAccountSession, page: Int, pageSize: Int) async throws
      -> FollowedForumPageData
    {
      guard let homeProbe else {
        return FollowedForumPageData(forums: [], currentPage: page, hasMore: false)
      }
      guard session.id == 7, (1...2).contains(page), pageSize > 0 else {
        _ = await homeProbe.record("unexpected")
        throw Self.unsupported
      }
      if page == 1 { homeGeneration += 1 }
      let generation = homeGeneration
      _ = await homeProbe.record("page\(page)")
      let forum = FollowedForumItem(
        id: Int64(200 + page), name: page == 1 ? "离线首页甲" : "离线首页乙",
        level: page + 1, experience: generation * 100 + page,
        slogan: "首页第\(generation)轮·第\(page)页")
      return FollowedForumPageData(forums: [forum], currentPage: page, hasMore: page == 1)
    }

    func inboxUnreadSummary(session: StoredAccountSession) -> InboxUnreadSummary {
      InboxUnreadSummary(
        userID: session.id, replyCount: unreadReplyCount, mentionCount: 0, fanCount: 0)
    }

    func checkInCatalog(session: StoredAccountSession) async throws -> ForumCheckInCatalogData {
      guard let homeProbe else {
        return ForumCheckInCatalogData(userID: session.id, targets: [], officialBatchPolicy: nil)
      }
      guard session.id == 7 else {
        _ = await homeProbe.record("unexpected")
        throw Self.unsupported
      }
      let count = await homeProbe.record("catalog")
      let status: ForumCheckInCatalogStatus = count > 1 ? .checkedIn : .pending
      let targets: [ForumCheckInCatalogTarget] = [
        ForumCheckInCatalogTarget(
          forumID: 201, forumName: "离线首页甲", level: 2,
          status: status, isForbidden: false),
        ForumCheckInCatalogTarget(
          forumID: 202, forumName: "离线首页乙", level: 3,
          status: status, isForbidden: false),
      ]
      return ForumCheckInCatalogData(userID: session.id, targets: targets, officialBatchPolicy: nil)
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

    func threads(forumName: String, page: Int, pageSize: Int, options: ForumBrowseOptions)
      async throws
      -> ThreadPageData
    {
      guard let forumProbe else { throw Self.unsupported }
      guard forumName == "离线分区", (1...2).contains(page), pageSize == 30,
        options.featuredClassificationID == nil
      else {
        await forumProbe.record("unexpected")
        throw Self.unsupported
      }
      await forumProbe.record(options.featuredOnly ? "featured" : "latest")
      return ThreadPageData(
        forum: fixtureForum,
        threads: forumThreads(section: options.featuredOnly ? 2 : 1, page: page),
        currentPage: page, hasMore: page == 1,
        channels: [71, 72].map {
          BrowseForumChannel(id: $0, name: $0 == 71 ? "讨论" : "图集", isDefault: false)
        })
    }

    func forumChannelThreads(
      forumID: Int64, forumName: String, channel: BrowseForumChannel,
      page: Int, pageSize: Int, sort: ForumChannelSort, lastThreadID: Int64?
    ) async throws -> ForumChannelPageData {
      guard let forumProbe else { throw Self.unsupported }
      guard forumID == 100, forumName == "离线分区", [71, 72].contains(channel.id),
        (1...2).contains(page), pageSize == 30, sort == .unspecified,
        page == 1 ? lastThreadID == nil : lastThreadID == Int64(channel.id * 10_000 + 30)
      else {
        await forumProbe.record("unexpected")
        throw Self.unsupported
      }
      let rows = forumThreads(section: channel.id, page: page)
      await forumProbe.record("channel\(channel.id)")
      return ForumChannelPageData(
        threads: rows, currentPage: page, hasMore: page == 1, nextPageCursor: rows.last?.id)
    }

    private var fixtureForum: BrowseForum {
      BrowseForum(
        id: 100, name: "离线分区", category: "", subcategory: "", memberCount: 100,
        threadCount: 120, postCount: 120, avatarURL: nil, slogan: "离线分区测试",
        hasModerators: false, hasRules: false, featuredClassifications: [])
    }

    private func forumThreads(section: Int, page: Int) -> [BrowseThread] {
      let title = [1: "最新", 2: "精华", 71: "讨论", 72: "图集"][section]!
      return (1...30).map { index in
        let number = (page - 1) * 30 + index
        let id = Int64(section * 10_000 + number)
        let thread = BrowseThread(
          id: id, forumID: 100, forumName: "离线分区", title: "\(title)·帖子\(number)",
          excerpt: "保留此条目的阅读位置，切换频道后可继续阅读。",
          authorName: "离线作者", replyCount: 3, viewCount: 20, createdAt: nil,
          lastReplyAt: nil, contents: [], authorID: 8, firstPostID: id + 1_000_000)
        threadsByID[id] = thread
        return thread
      }
    }
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
    {
      guard forumProbe != nil, forumID == 100 else { throw Self.unsupported }
      return ForumMembershipData(
        userID: session.id, forumID: forumID, forumName: forumName, isFollowed: true)
    }
    func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String)
      async throws
      -> ForumAccountStateData
    {
      guard let forumProbe else { throw Self.unsupported }
      guard session.id == 7, forumID == 100, forumName == "离线分区" else {
        await forumProbe.record("unexpected")
        throw Self.unsupported
      }
      await forumProbe.record("account")
      return ForumAccountStateData(
        membership: try forumMembership(session: session, forumID: forumID, forumName: forumName),
        checkIn: ForumCheckInData(isCheckedIn: true, consecutiveDays: 3, rank: 0))
    }
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
