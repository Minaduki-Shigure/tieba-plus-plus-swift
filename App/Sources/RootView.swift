import Combine
import Foundation
import SwiftUI
import UIKit

struct HomeExploreEntryLabel: View {
  var body: some View {
    HStack(spacing: 0) {
      Label("发现", systemImage: "sparkles")
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

struct RootView: View {
  let service:
    any BrowseService & SearchService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
      & SearchSuggestionService & TiebaLinkPreviewService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let accountVault: any AccountVault
  let accountSessionLookup: any AccountSessionLookup
  let accountService: any AccountService
  let personalizedFeedbackService: any PersonalizedFeedbackService
  let contentFilterRepository: any ContentFilterRepository
  let showsExploreTab: Bool

  @State private var query = ""
  @State private var navigation: RootMainNavigationState
  @State private var showsAllSearchHistory = false
  @State private var showsRecentForums = true
  @State private var showsQuickAccountLogin = false
  @State private var searchHistoryAction: GlobalSearchHistoryAction?
  @State private var linkErrorMessage: String?
  @State private var pendingFollowedForumUnfollow: FollowedForumUnfollowPrompt?
  @State private var accountSurfaceIsVisible = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentObject private var mediaPlaybackCoordinator: MediaPlaybackCoordinator
  @EnvironmentObject private var followedForumsViewModel: FollowedForumsViewModel
  @EnvironmentObject private var followedForumCheckInStore: FollowedForumCheckInStore
  @EnvironmentObject private var sceneDelegate: TiebaSceneDelegate
  @EnvironmentObject private var externalWebPresentation: ExternalWebPresentationModel
  @Environment(\.threadCloudFavoriteStore) private var threadCloudFavoriteStore
  @Environment(\.contentReportCoordinator) private var contentReportCoordinator
  @AppStorage(AppPreferenceKey.homeShowsRecentForums)
  private var homeShowsRecentForums = true
  @AppStorage(AppPreferenceKey.homeShowsDiscovery)
  private var homeShowsDiscovery = AppPreferenceDefaults.homeShowsDiscovery
  @AppStorage(AppPreferenceKey.followedForumsLayout)
  private var followedForumsLayout = FollowedForumsLayoutMode.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.searchSuggestionsEnabled)
  private var searchSuggestionsEnabled = false
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenOnlyAuthor)
  private var favoriteThreadsOpenOnlyAuthor =
    AppPreferenceDefaults.favoriteThreadsOpenOnlyAuthor
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenDescending)
  private var favoriteThreadsOpenDescending =
    AppPreferenceDefaults.favoriteThreadsOpenDescending
  @StateObject private var favoritesViewModel: LocalFavoritesViewModel
  @StateObject private var globalSearchHistoryViewModel: GlobalSearchHistoryViewModel
  @StateObject private var recentForumsViewModel: BrowsingHistoryViewModel
  @StateObject private var searchSuggestionViewModel: SearchSuggestionViewModel
  @StateObject private var accountViewModel: AccountViewModel
  @StateObject private var unreadSummaryViewModel: InboxUnreadSummaryViewModel
  @StateObject private var linkPreviewViewModel: TiebaLinkPreviewViewModel
  @StateObject private var threadSummaryImageGalleryCoordinator:
    ThreadSummaryImageGalleryCoordinator

  init(
    service: any BrowseService & SearchService & ForumPostSearchService & HotTopicService
      & HotThreadService & PersonalizedFeedService & UserProfileService & ForumInformationService
      & SearchSuggestionService & TiebaLinkPreviewService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    globalSearchHistoryRepository: any GlobalSearchHistoryRepository,
    accountVault: any AccountVault,
    accountSessionLookup: any AccountSessionLookup,
    accountService: any AccountService,
    personalizedFeedbackService: any PersonalizedFeedbackService,
    contentFilterRepository: any ContentFilterRepository,
    startDestination: AppStartDestination,
    showsExploreTab: Bool
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.accountVault = accountVault
    self.accountSessionLookup = accountSessionLookup
    self.accountService = accountService
    self.personalizedFeedbackService = personalizedFeedbackService
    self.contentFilterRepository = contentFilterRepository
    self.showsExploreTab = showsExploreTab
    _navigation = State(
      initialValue: RootStartupNavigation.initialState(
        startDestination: startDestination,
        showsExploreTab: showsExploreTab
      )
    )
    _favoritesViewModel = StateObject(
      wrappedValue: LocalFavoritesViewModel(repository: favoritesRepository)
    )
    _globalSearchHistoryViewModel = StateObject(
      wrappedValue: GlobalSearchHistoryViewModel(repository: globalSearchHistoryRepository)
    )
    _recentForumsViewModel = StateObject(
      wrappedValue: BrowsingHistoryViewModel(repository: historyRepository)
    )
    _searchSuggestionViewModel = StateObject(
      wrappedValue: SearchSuggestionViewModel(service: service)
    )
    _accountViewModel = StateObject(wrappedValue: AccountViewModel(vault: accountVault))
    _unreadSummaryViewModel = StateObject(
      wrappedValue: InboxUnreadSummaryViewModel(service: accountService, vault: accountVault)
    )
    _linkPreviewViewModel = StateObject(
      wrappedValue: TiebaLinkPreviewViewModel(service: service)
    )
    _threadSummaryImageGalleryCoordinator = StateObject(
      wrappedValue: ThreadSummaryImageGalleryCoordinator(
        remoteService: service as? any ThreadPictureGalleryService,
        contentFilterRepository: contentFilterRepository
      )
    )
  }

  var body: some View {
    TabView(selection: rootTabSelection) {
      NavigationStack(path: rootPathBinding(for: .home)) {
        List {
        if homeShowsDiscovery {
          Section("\u{53d1}\u{73b0}") {
            if RootMainTabVisibilityPolicy.showsHomeExploreEntry(
              homeShowsDiscovery: homeShowsDiscovery,
              showsExploreTab: showsExploreTab
            ) {
              Button {
                selectExplore(.personalized)
              } label: {
                HomeExploreEntryLabel()
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("home-explore-entry")
            }

            NavigationLink(value: RootDestination.hotTopics) {
              Label("\u{70ed}\u{95e8}\u{8bdd}\u{9898}", systemImage: "flame.fill")
            }

            HStack(spacing: 12) {
              Label("打开贴吧链接", systemImage: "link")
              Spacer(minLength: 8)
              PasteButton(payloadType: String.self, onPaste: openPastedLinks)
                .accessibilityLabel("粘贴并预览贴吧链接")
                .help("粘贴并预览贴吧链接")
            }
          }
          .appListRowSurface(.card)
        }

        Section {
          HStack(spacing: 10) {
            TextField("输入吧名或关键词", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.search)
              .onSubmit(search)
            Button(action: search) {
              Image(systemName: "magnifyingglass.circle.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("搜索贴吧、帖子和用户")
            .help("搜索贴吧、帖子和用户")
            Button(action: openForum) {
              Image(systemName: "arrow.right.circle.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("直接打开贴吧")
            .help("直接打开贴吧")
          }
        }
        .appListRowSurface(.card)

        searchSuggestionSection
          .appListRowSurface(.card)

        searchHistorySection
          .appListRowSurface(.card)

        if let errorMessage = globalSearchHistoryViewModel.errorMessage {
          Section("搜索记录错误") {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            Button {
              Task { await globalSearchHistoryViewModel.retry() }
            } label: {
              Label("重试", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
              searchHistoryAction = .reset
            } label: {
              Label("重置搜索记录", systemImage: "trash")
            }
          }
          .appListRowSurface(.card)
        }

        followedForumsSection

        recentForumsSection
          .appListRowSurface(.card)

        if !favoritesViewModel.favoriteForumEntries.isEmpty {
          Section("收藏的贴吧") {
            ForEach(Array(favoritesViewModel.favoriteForumEntries.prefix(6))) { entry in
              if case .forum(let forum) = entry.target {
                Button {
                  append(.forum(forum.name), to: .home)
                } label: {
                  HStack(spacing: 12) {
                    AvatarView(url: forum.avatarURL, name: forum.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(forum.displayName)
                        .foregroundStyle(.primary)
                      if forum.name != forum.displayName {
                        Text(forum.name)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                    Spacer(minLength: 0)
                    if entry.isPinned {
                      LocalFavoritePinIndicator()
                    }
                    Image(systemName: "chevron.right")
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.tertiary)
                      .accessibilityHidden(true)
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .forumFavoriteContextMenu(
                  entry: entry,
                  setPinned: { favoritesViewModel.setForumPinned(entry, isPinned: $0) },
                  delete: { favoritesViewModel.delete(entry) }
                )
              }
            }
          }
          .appListRowSurface(.card)
        }

      }
      .listStyle(.insetGrouped)
      .appScrollableSurface(.canvas)
      .refreshable { await refreshHome() }
      .navigationTitle("贴吧++")
      .toolbar {
        if RootAccountActionPolicy.showsBatchCheckIn(
          for: accountViewModel.activeAccount,
          state: accountViewModel.state
        ) {
          ToolbarItem(placement: .navigationBarLeading) {
            Button {
              append(.batchCheckIn, to: .home)
            } label: {
              Image(systemName: "checkmark.seal")
            }
            .accessibilityLabel("一键签到")
            .accessibilityHint("打开前台一键签到页面")
            .help("一键签到")
          }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Menu {
            accountQuickSwitchMenu
          } label: {
            accountToolbarLabel
          } primaryAction: {
            selectRoot(.account)
          }
          .disabled(accountViewModel.isMutating)
          .accessibilityLabel(accountToolbarAccessibilityLabel)
          .accessibilityHint("轻点管理账户，长按查看消息或快速切换")
          .help("账户")
          .alert(
            "账户切换失败",
            isPresented: Binding(
              get: { accountViewModel.errorMessage != nil },
              set: { if !$0 { accountViewModel.clearError() } }
            )
          ) {
            Button("好", role: .cancel) { accountViewModel.clearError() }
          } message: {
            Text(accountViewModel.errorMessage ?? "无法切换账户。")
          }

          Button {
            append(.settings, to: .home)
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("设置")
          .help("设置")

          Button {
            append(.favorites, to: .home)
          } label: {
            Image(systemName: "bookmark")
          }
          .accessibilityLabel("本地收藏")
          .help("本地收藏")

          Button {
            append(.history, to: .home)
          } label: {
            Image(systemName: "clock.arrow.circlepath")
          }
          .accessibilityLabel("浏览记录")
          .help("浏览记录")
        }
      }
      .navigationDestination(for: RootDestination.self) { destination in
        rootDestination(destination, in: .home)
      }
      .alert(
        "无法更新本地收藏",
        isPresented: Binding(
          get: { favoritesViewModel.operationError != nil },
          set: { if !$0 { favoritesViewModel.dismissOperationError() } }
        )
      ) {
        Button("好", action: favoritesViewModel.dismissOperationError)
      } message: {
        Text(favoritesViewModel.operationError ?? "未知错误")
      }
      .alert(
        followedForumsViewModel.presentedOperationError?.title ?? "无法更新关注的贴吧",
        isPresented: Binding(
          get: {
            followedForumsViewModel.presentedOperationError != nil
              && !followedForumsViewModel.hasActiveFullListSurface
          },
          set: {
            if !$0, !followedForumsViewModel.hasActiveFullListSurface {
              followedForumsViewModel.dismissPresentedOperationError()
            }
          }
        )
      ) {
        Button("好", role: .cancel) {}
      } message: {
        Text(followedForumsViewModel.presentedOperationError?.message ?? "未知错误")
      }
      }
      .tag(RootMainTab.home)
      .tabItem {
        Label(RootMainTab.home.title, systemImage: RootMainTab.home.systemImage)
      }

      if showsExploreTab {
        NavigationStack(path: rootPathBinding(for: .explore)) {
          ExploreView(
            initialSection: navigation.exploreSection,
            isActive: rootTabIsActive(.explore),
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository,
            accountService: accountService,
            feedbackService: personalizedFeedbackService,
            accountVault: accountVault,
            accountSessionLookup: accountSessionLookup
          )
          .id(navigation.exploreActivationID)
          .navigationDestination(for: RootDestination.self) { destination in
            rootDestination(destination, in: .explore)
          }
        }
        .tag(RootMainTab.explore)
        .tabItem {
          Label(RootMainTab.explore.title, systemImage: RootMainTab.explore.systemImage)
        }
      }

      NavigationStack(path: rootPathBinding(for: .notifications)) {
        NotificationsView(
          browseService: service,
          accountService: accountService,
          vault: accountVault,
          contentFilterRepository: contentFilterRepository,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository,
          initialKind: navigation.inboxKind,
          isActive: rootTabIsActive(.notifications)
        )
        .id(navigation.inboxActivationID)
        .navigationDestination(for: RootDestination.self) { destination in
          rootDestination(destination, in: .notifications)
        }
      }
      .tag(RootMainTab.notifications)
      .tabItem {
        Label(
          RootMainTab.notifications.title,
          systemImage: RootMainTab.notifications.systemImage
        )
      }
      .badge(homeUnreadBadgePresentation?.count ?? 0)

      NavigationStack(path: rootPathBinding(for: .account)) {
        AccountView(
          browseService: service,
          accountService: accountService,
          vault: accountVault,
          unreadSummaryViewModel: unreadSummaryViewModel,
          onVisibilityChanged: accountSurfaceVisibilityDidChange,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository,
          isActive: rootTabIsActive(.account),
          pageTitle: "我的"
        )
        .navigationDestination(for: RootDestination.self) { destination in
          rootDestination(destination, in: .account)
        }
      }
      .tag(RootMainTab.account)
      .tabItem {
        Label(RootMainTab.account.title, systemImage: RootMainTab.account.systemImage)
      }
    }
    .appNavigationSurface()
    .threadSummaryImageGallery(threadSummaryImageGalleryCoordinator)
    .sheet(isPresented: $showsQuickAccountLogin) {
      NavigationStack {
        LoginView(service: accountService, vault: accountVault) {
          Task { await accountViewModel.loadIfNeeded() }
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { linkPreviewViewModel.preview != nil },
        set: { if !$0 { linkPreviewViewModel.dismiss() } }
      )
    ) {
      TiebaLinkPreviewSheet(
        viewModel: linkPreviewViewModel,
        onClose: { linkPreviewViewModel.dismiss(expectedID: $0) },
        onOpen: openLinkPreview
      )
    }
    .onAppear {
      favoritesViewModel.reload()
      recentForumsViewModel.reload()
      if RootFollowedForumsActivationPolicy.isActive(navigation: navigation) {
        followedForumsViewModel.loadIfNeeded()
        if scenePhase == .active {
          followedForumCheckInStore.loadIfNeeded()
        }
      }
      searchSuggestionViewModel.setEnabled(searchSuggestionsEnabled)
      mediaPlaybackCoordinator.setSceneActive(scenePhase == .active)
      linkPreviewViewModel.sceneActivityDidChange(isActive: scenePhase == .active)
      unreadSummaryViewModel.sceneActivityDidChange(
        isActive: RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: scenePhase == .active,
          navigation: navigation,
          accountSurfaceIsVisible: accountSurfaceIsVisible
        )
      )
    }
    .task { await globalSearchHistoryViewModel.loadIfNeeded() }
    .task { await accountViewModel.loadIfNeeded() }
    .onChange(of: query) { searchSuggestionViewModel.inputChanged($0) }
    .onChange(of: searchSuggestionsEnabled) {
      searchSuggestionViewModel.setEnabled($0)
    }
    .onChange(of: showsExploreTab) {
      navigation = RootMainTabVisibilityPolicy.reconciled(
        navigation,
        showsExploreTab: $0
      )
    }
    .onChange(of: scenePhase) {
      mediaPlaybackCoordinator.setSceneActive($0 == .active)
      linkPreviewViewModel.sceneActivityDidChange(isActive: $0 == .active)
      followedForumCheckInStore.sceneActivityDidChange(
        isActive: $0 == .active,
        shouldLoad: RootFollowedForumsActivationPolicy.isActive(navigation: navigation)
          || followedForumsViewModel.hasActiveFullListSurface
      )
      unreadSummaryViewModel.sceneActivityDidChange(
        isActive: RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: $0 == .active,
          navigation: navigation,
          accountSurfaceIsVisible: accountSurfaceIsVisible
        )
      )
      if $0 != .active {
        searchSuggestionViewModel.cancelAndClear()
      }
    }
    .onChange(of: navigation.primarySurface) { _ in
      mediaPlaybackCoordinator.activeSurfaceDidChange()
    }
    .onChange(of: navigation) { navigation in
      pendingFollowedForumUnfollow = nil
      searchSuggestionViewModel.cancelAndClear()
      recentForumsViewModel.reload()
      if RootFollowedForumsActivationPolicy.isActive(navigation: navigation) {
        followedForumsViewModel.loadIfNeeded()
        if scenePhase == .active {
          followedForumCheckInStore.loadIfNeeded()
        }
      }
      unreadSummaryViewModel.sceneActivityDidChange(
        isActive: RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: scenePhase == .active,
          navigation: navigation,
          accountSurfaceIsVisible: accountSurfaceIsVisible
        )
      )
    }
    .onDisappear {
      searchSuggestionViewModel.cancelAndClear()
      linkPreviewViewModel.sceneActivityDidChange(isActive: false)
    }
    .onReceive(NotificationCenter.default.publisher(for: .localFavoritesDidChange)) { _ in
      Task { @MainActor in favoritesViewModel.reload() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumBrowsingHistoryDidChange)) { _ in
      Task { @MainActor in recentForumsViewModel.reload() }
    }
    .onReceive(sceneDelegate.$pendingQuickAction.compactMap { $0 }) {
      invocation in
      openHomeScreenQuickAction(invocation)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) {
      _ in
      followedForumCheckInStore.significantTimeDidChange(
        shouldLoad: scenePhase == .active
          && (RootFollowedForumsActivationPolicy.isActive(navigation: navigation)
            || followedForumsViewModel.hasActiveFullListSurface)
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      pendingFollowedForumUnfollow = nil
      accountViewModel.invalidateForAccountSessionChange()
      Task { @MainActor in await accountViewModel.loadIfNeeded() }
      unreadSummaryViewModel.accountSessionDidChange(
        loadImmediately: RootUnreadSummaryActivationPolicy.isActive(
          sceneIsActive: scenePhase == .active,
          navigation: navigation,
          accountSurfaceIsVisible: accountSurfaceIsVisible
        )
      )
      let loadsImmediately = RootFollowedForumsActivationPolicy.isActive(
        navigation: navigation
      )
        || followedForumsViewModel.hasActiveFullListSurface
        || followedForumsViewModel.hasActiveCompleteIndexSurface
      followedForumsViewModel.accountSessionDidChange(loadImmediately: loadsImmediately)
      followedForumCheckInStore.accountSessionDidChange(
        loadImmediately: scenePhase == .active
          && (RootFollowedForumsActivationPolicy.isActive(navigation: navigation)
            || followedForumsViewModel.hasActiveFullListSurface)
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumMembershipDidChange)) {
      notification in
      guard let change = ForumMembershipChange(notification) else { return }
      let loadsImmediately = RootFollowedForumsActivationPolicy.isActive(
        navigation: navigation
      )
        || followedForumsViewModel.hasActiveFullListSurface
        || followedForumsViewModel.hasActiveCompleteIndexSurface
      followedForumsViewModel.forumMembershipDidChange(
        change,
        loadImmediately: loadsImmediately
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumCheckInDidChange)) {
      notification in
      guard let change = ForumCheckInChange(notification) else { return }
      followedForumCheckInStore.forumCheckInDidChange(change)
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumCheckInCatalogDidChange)) {
      notification in
      guard let change = ForumCheckInCatalogChange(notification) else { return }
      followedForumCheckInStore.forumCheckInCatalogDidChange(
        change,
        loadImmediately: scenePhase == .active
          && (RootFollowedForumsActivationPolicy.isActive(navigation: navigation)
            || followedForumsViewModel.hasActiveFullListSurface)
      )
    }
    .onChange(of: followedForumsViewModel.forums) { forums in
      guard let pendingFollowedForumUnfollow else { return }
      let normalizedName = FollowedForumPin.normalizedForumName(
        pendingFollowedForumUnfollow.forum.name
      )
      guard forums.contains(where: {
        $0.id == pendingFollowedForumUnfollow.forum.id
          && FollowedForumPin.normalizedForumName($0.name) == normalizedName
      }) else {
        self.pendingFollowedForumUnfollow = nil
        return
      }
    }
    .onOpenURL(perform: openTiebaURL)
    .alert(
      "无法打开贴吧链接",
      isPresented: Binding(
        get: { linkErrorMessage != nil },
        set: { if !$0 { linkErrorMessage = nil } }
      )
    ) {
      Button("好") { linkErrorMessage = nil }
    } message: {
      Text(linkErrorMessage ?? "链接格式不受支持。")
    }
    .confirmationDialog(
      searchHistoryActionTitle,
      isPresented: Binding(
        get: { searchHistoryAction != nil },
        set: { if !$0 { searchHistoryAction = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(searchHistoryActionButtonTitle, role: .destructive) {
        let action = searchHistoryAction
        searchHistoryAction = nil
        Task {
          switch action {
          case .clear:
            await globalSearchHistoryViewModel.deleteAll()
          case .reset:
            await globalSearchHistoryViewModel.reset()
          case nil:
            break
          }
        }
      }
      Button("取消", role: .cancel) { searchHistoryAction = nil }
    } message: {
      Text(searchHistoryActionMessage)
    }
  }

  private func rootPathBinding(for tab: RootMainTab) -> Binding<[RootDestination]> {
    Binding(
      get: { navigation.path(for: tab) },
      set: { navigation.setPath($0, for: tab) }
    )
  }

  private var rootTabSelection: Binding<RootMainTab> {
    Binding(
      get: {
        RootMainTabVisibilityPolicy.resolvedSelection(
          navigation.selectedTab,
          showsExploreTab: showsExploreTab
        )
      },
      set: {
        navigation.selectedTab = RootMainTabVisibilityPolicy.resolvedSelection(
          $0,
          showsExploreTab: showsExploreTab
        )
      }
    )
  }

  private var effectiveNavigation: RootMainNavigationState {
    RootMainTabVisibilityPolicy.reconciled(
      navigation,
      showsExploreTab: showsExploreTab
    )
  }

  private func rootTabIsActive(_ tab: RootMainTab) -> Bool {
    RootMainTabActivationPolicy.isActive(
      sceneIsActive: scenePhase == .active,
      navigation: effectiveNavigation,
      tab: tab
    )
  }

  private func rootTabOwnsForeground(_ tab: RootMainTab) -> Bool {
    RootMainTabActivationPolicy.isForeground(
      sceneIsActive: scenePhase == .active,
      navigation: effectiveNavigation,
      tab: tab
    )
  }

  private func append(_ destination: RootDestination, to tab: RootMainTab) {
    navigation.append(destination, to: tab)
  }

  private func selectRoot(_ tab: RootMainTab) {
    navigation.selectRoot(tab)
  }

  private func selectExplore(_ section: ExploreSection) {
    navigation.activateExplore(section)
  }

  private func selectInbox(_ kind: InboxKind) {
    navigation.activateInbox(kind)
  }

  @ViewBuilder
  private func rootDestination(
    _ destination: RootDestination,
    in tab: RootMainTab
  ) -> some View {
    switch destination {
    case .forum(let forumName):
      ForumView(
        forumName: forumName,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .search(let query):
      SearchView(
        query: query,
        browseService: service,
        searchService: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        globalSearchHistoryViewModel: globalSearchHistoryViewModel,
        onSearchSubmitted: { globalSearchHistoryViewModel.record($0) }
      )
    case .hotTopics:
      HotTopicListView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .explore(let section):
      ExploreView(
        initialSection: section,
        isActive: rootTabOwnsForeground(tab),
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        accountService: accountService,
        feedbackService: personalizedFeedbackService,
        accountVault: accountVault,
        accountSessionLookup: accountSessionLookup
      )
    case .history:
      HistoryView(repository: historyRepository) { target in
        switch target {
        case .forum(let forum):
          append(.forum(forum.name), to: tab)
        case .thread(let thread):
          append(.thread(thread), to: tab)
        }
      }
    case .favorites:
      LocalFavoritesView(repository: favoritesRepository) { target in
        let overrides = FavoriteThreadOpenOverrides(
          onlyThreadAuthor: favoriteThreadsOpenOnlyAuthor,
          descending: favoriteThreadsOpenDescending
        )
        append(
          RootFavoriteNavigation.destination(for: target, overrides: overrides),
          to: tab
        )
      }
    case .followedForums:
      FollowedForumsView(
        browseService: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .batchCheckIn:
      ForumBatchCheckInView(
        access: AccountAccess(vault: accountVault, service: accountService)
      )
    case .notifications(let initialKind):
      NotificationsView(
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        contentFilterRepository: contentFilterRepository,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        initialKind: initialKind,
        isActive: rootTabOwnsForeground(tab)
      )
    case .cloudFavorites:
      CloudFavoritesView(
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        cloudFavoriteStore: threadCloudFavoriteStore,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .homeScreenQuickAction(let invocation):
      homeScreenQuickActionDestination(
        invocation,
        isActive: rootTabOwnsForeground(tab)
      )
    case .account:
      AccountView(
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        unreadSummaryViewModel: unreadSummaryViewModel,
        onVisibilityChanged: accountSurfaceVisibilityDidChange,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        isActive: rootTabOwnsForeground(tab)
      )
    case .settings:
      AppSettingsView(historyRepository: historyRepository)
    case .about:
      AppAboutView()
    case .thread(let thread):
      ThreadView(
        thread: thread.browseThread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        historySnapshot: thread
      )
    case .linkedThread(let route):
      ThreadView(
        thread: route.placeholderThread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
    case .user(let userID):
      UserProfileView(
        userID: userID,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    }
  }

  @ViewBuilder
  private var accountQuickSwitchMenu: some View {
    if accountViewModel.activeAccount != nil {
      Section("消息") {
        ForEach(InboxKind.allCases) { kind in
          Button {
            selectInbox(kind)
          } label: {
            Label(
              inboxQuickActionTitle(for: kind),
              systemImage: kind == .replies ? "arrowshape.turn.up.left" : "at"
            )
          }
        }
      }
    }

    if case .loaded = accountViewModel.state, !accountViewModel.accounts.isEmpty {
      Section("切换账户") {
        ForEach(accountViewModel.accounts) { account in
          Button {
            Task { await accountViewModel.switchAccount(to: account.id) }
          } label: {
            Label(
              account.preferredName,
              systemImage: account.isActive ? "checkmark.circle.fill" : "person.crop.circle"
            )
          }
          .disabled(!accountViewModel.canSwitch(to: account.id))
          .accessibilityLabel(
            account.isActive
              ? "\(account.preferredName)，当前账户"
              : "切换到\(account.preferredName)"
          )
        }
      }
    } else if case .loading = accountViewModel.state {
      Button {} label: {
        Label("正在读取账户", systemImage: "hourglass")
      }
      .disabled(true)
    } else if case .failed = accountViewModel.state {
      Button {
        Task { await accountViewModel.reload() }
      } label: {
        Label("重新载入账户", systemImage: "arrow.clockwise")
      }
    }

    Section {
      Button {
        showsQuickAccountLogin = true
      } label: {
        Label("添加账户", systemImage: "person.badge.plus")
      }
      .disabled(accountViewModel.hasLoadFailure)

      Button {
        selectRoot(.account)
      } label: {
        Label("账户管理", systemImage: "person.crop.circle")
      }
    }
  }

  @ViewBuilder
  private var accountToolbarLabel: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if accountViewModel.isMutating {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(
            systemName: accountViewModel.activeAccount == nil
              ? "person.crop.circle"
              : "person.crop.circle.fill"
          )
        }
      }
      .frame(width: 28, height: 28)

      if !accountViewModel.isMutating,
        let badgeText = homeUnreadBadgePresentation?.badgeText
      {
        Text(badgeText)
          .font(.system(size: 9, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .padding(.horizontal, 4)
          .frame(minWidth: 16, minHeight: 16)
          .background(Color.red, in: Capsule())
          .offset(x: 6, y: -5)
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }

  private var homeUnreadSummary: InboxUnreadSummary? {
    guard
      let activeUserID = accountViewModel.activeAccount?.id,
      let summary = unreadSummaryViewModel.summary,
      summary.userID == activeUserID
    else { return nil }
    return summary
  }

  private var homeUnreadBadgePresentation: InboxUnreadBadgePresentation? {
    homeUnreadSummary.map { InboxUnreadBadgePresentation(summary: $0) }
  }

  private var accountToolbarAccessibilityLabel: String {
    guard !accountViewModel.isMutating else { return "正在切换账户" }
    guard let presentation = homeUnreadBadgePresentation else { return "账户" }
    let refreshFailed: Bool
    if case .failed = unreadSummaryViewModel.state {
      refreshFailed = true
    } else {
      refreshFailed = false
    }
    return "账户，\(presentation.accessibilityValue(refreshFailed: refreshFailed))"
  }

  private func inboxQuickActionTitle(for kind: InboxKind) -> String {
    guard let summary = homeUnreadSummary else { return kind.title }
    let count = kind == .replies ? summary.replyCount : summary.mentionCount
    guard count > 0 else { return kind.title }
    return "\(kind.title)（\(count > 99 ? "99+" : String(count))）"
  }

  private func accountSurfaceVisibilityDidChange(_ isVisible: Bool) {
    accountSurfaceIsVisible = isVisible
    unreadSummaryViewModel.sceneActivityDidChange(
      isActive: RootUnreadSummaryActivationPolicy.isActive(
        sceneIsActive: scenePhase == .active,
        navigation: navigation,
        accountSurfaceIsVisible: isVisible
      )
    )
  }

  @MainActor
  private func refreshHome() async {
    favoritesViewModel.reload()
    recentForumsViewModel.reload()
    async let forums: Void = followedForumsViewModel.refresh()
    async let checkIns: Void = followedForumCheckInStore.refresh()
    _ = await (forums, checkIns)
  }

  @ViewBuilder
  private var followedForumsSection: some View {
    let forums = followedForumsViewModel.homeForums
    if !forums.isEmpty {
      Section {
        LazyVGrid(
          columns: FollowedForumsLayoutPolicy.columns(
            preferred: preferredFollowedForumsLayout,
            dynamicTypeSize: dynamicTypeSize
          ),
          alignment: .leading,
          spacing: FollowedForumsLayoutPolicy.spacing
        ) {
          ForEach(forums) { forum in
            let isPinned = followedForumsViewModel.isPinned(forum)
            let unfollowState = followedForumsViewModel.unfollowControlState(for: forum)
            Button {
              append(.forum(forum.name), to: .home)
            } label: {
              FollowedForumCard(
                forum: forum,
                isPinned: isPinned,
                isUnfollowing: unfollowState == .busy,
                isCheckedInToday: followedForumCheckInStore.isCheckedInToday(
                  forum,
                  forumLease: followedForumsViewModel.loadedSessionLease
                )
              )
            }
            .buttonStyle(.plain)
            .followedForumContextMenu(
              forum: forum,
              isPinned: isPinned,
              unfollowState: unfollowState,
              setPinned: { followedForumsViewModel.setPinned(forum, isPinned: $0) },
              requestUnfollow: {
                pendingFollowedForumUnfollow = followedForumsViewModel.unfollowPrompt(
                  for: forum
                )
              }
            )
          }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .confirmationDialog(
          pendingFollowedForumUnfollow.map { "取消关注 \($0.forum.name)吧？" }
            ?? "取消关注贴吧？",
          isPresented: Binding(
            get: { pendingFollowedForumUnfollow != nil },
            set: { if !$0 { pendingFollowedForumUnfollow = nil } }
          ),
          titleVisibility: .visible
        ) {
          if let prompt = pendingFollowedForumUnfollow {
            Button("取消关注", role: .destructive) {
              pendingFollowedForumUnfollow = nil
              followedForumsViewModel.unfollow(prompt)
            }
          }
          Button("取消", role: .cancel) { pendingFollowedForumUnfollow = nil }
        } message: {
          Text("这会修改当前贴吧账户的关注列表。")
        }

        NavigationLink(value: RootDestination.followedForums) {
          Label("查看全部", systemImage: "list.bullet")
        }
        .appListRowSurface(.card)
      } header: {
        HStack(spacing: 8) {
          Text("关注的贴吧")
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          if let action = followedForumsLayoutToggleAction {
            FollowedForumsLayoutToggleButton(
              action: action,
              accessibilityIdentifier: "home-followed-forums-layout-toggle",
              onToggle: { applyFollowedForumsLayoutToggle(action) }
            )
          }
        }
        .textCase(nil)
      }
    } else if case .failed(let message) = followedForumsViewModel.state,
      !followedForumsViewModel.isSignedOut
    {
      Section("关注的贴吧") {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Button {
          followedForumsViewModel.reload()
        } label: {
          Label("重试", systemImage: "arrow.clockwise")
        }
      }
      .appListRowSurface(.card)
    }
  }

  private var preferredFollowedForumsLayout: FollowedForumsLayoutMode {
    FollowedForumsLayoutMode.resolved(followedForumsLayout)
  }

  private var followedForumsLayoutToggleAction: FollowedForumsLayoutToggleAction? {
    FollowedForumsLayoutPolicy.toggleAction(
      preferred: preferredFollowedForumsLayout,
      dynamicTypeSize: dynamicTypeSize
    )
  }

  private func applyFollowedForumsLayoutToggle(
    _ action: FollowedForumsLayoutToggleAction
  ) {
    guard let target = FollowedForumsLayoutPolicy.validatedToggleTarget(
      for: action,
      preferred: preferredFollowedForumsLayout,
      dynamicTypeSize: dynamicTypeSize
    ) else { return }
    followedForumsLayout = target.rawValue
  }

  @ViewBuilder
  private var searchSuggestionSection: some View {
    if searchSuggestionsEnabled, !searchSuggestionViewModel.suggestions.isEmpty {
      Section("搜索建议") {
        ForEach(Array(searchSuggestionViewModel.suggestions.enumerated()), id: \.offset) {
          _, suggestion in
          Button {
            search(for: suggestion)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(suggestion)
                .foregroundStyle(.primary)
                .lineLimit(2)
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("搜索建议：\(suggestion)")
        }
      }
    }
  }

  @ViewBuilder
  private var searchHistorySection: some View {
    if globalSearchHistoryViewModel.isLoading,
      globalSearchHistoryViewModel.entries.isEmpty
    {
      Section("最近搜索") {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      }
    } else if !globalSearchHistoryViewModel.entries.isEmpty {
      Section {
        ForEach(visibleSearchHistoryEntries) { entry in
          Button {
            search(for: entry.query)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "clock")
                .foregroundStyle(.secondary)
              Text(entry.query)
                .foregroundStyle(.primary)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(entry.searchedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .onDelete(perform: deleteSearchHistory)

        if globalSearchHistoryViewModel.entries.count > 6 {
          Button {
            showsAllSearchHistory.toggle()
          } label: {
            Label(
              showsAllSearchHistory ? "收起" : "显示全部",
              systemImage: showsAllSearchHistory ? "chevron.up" : "chevron.down"
            )
          }
        }
      } header: {
        HStack {
          Text("最近搜索")
          Spacer()
          Button {
            searchHistoryAction = .clear
          } label: {
            Image(systemName: "trash")
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("清空搜索记录")
          .help("清空搜索记录")
        }
      }
    }
  }

  private var visibleSearchHistoryEntries: [GlobalSearchHistoryEntry] {
    if showsAllSearchHistory {
      return globalSearchHistoryViewModel.entries
    }
    return Array(globalSearchHistoryViewModel.entries.prefix(6))
  }

  @ViewBuilder
  private var recentForumsSection: some View {
    let entries = Array(recentForumsViewModel.forumEntries.prefix(100))
    if homeShowsRecentForums, !entries.isEmpty {
      Section {
        if showsRecentForums {
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
              ForEach(entries) { entry in
                if case .forum(let forum) = entry.target {
                  Button {
                    append(.forum(forum.name), to: .home)
                  } label: {
                    HStack(spacing: 7) {
                      AvatarView(url: forum.avatarURL, name: forum.displayName, size: 28)
                      Text(forum.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("打开\(forum.displayName)吧")
                }
              }
            }
            .padding(.vertical, 2)
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 0))
        }
      } header: {
        Button {
          withAnimation { showsRecentForums.toggle() }
        } label: {
          HStack {
            Text("最近访问的贴吧")
            Spacer()
            Image(systemName: showsRecentForums ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsRecentForums ? "收起最近访问的贴吧" : "展开最近访问的贴吧")
      }
    }
  }

  private func deleteSearchHistory(at offsets: IndexSet) {
    let visibleEntries = visibleSearchHistoryEntries
    let ids = offsets.compactMap { index in
      visibleEntries.indices.contains(index)
        ? visibleEntries[index].id
        : nil
    }
    Task {
      for id in ids {
        await globalSearchHistoryViewModel.delete(id: id)
      }
    }
  }

  private var searchHistoryActionTitle: String {
    switch searchHistoryAction {
    case .clear:
      "清空全部搜索记录？"
    case .reset:
      "重置全部搜索记录？"
    case nil:
      "管理搜索记录"
    }
  }

  private var searchHistoryActionButtonTitle: String {
    switch searchHistoryAction {
    case .clear:
      "清空"
    case .reset:
      "重置"
    case nil:
      "确认"
    }
  }

  private var searchHistoryActionMessage: String {
    switch searchHistoryAction {
    case .clear:
      "只会删除保存在本机的全局搜索词。"
    case .reset:
      "这会删除保存在本机的全局搜索历史文件，用于恢复损坏或版本不兼容的数据。"
    case nil:
      ""
    }
  }

  private func openForum() {
    openForum(named: query)
  }

  private func search() {
    search(for: query)
  }

  private func search(for rawQuery: String) {
    let searchQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !searchQuery.isEmpty else { return }
    searchSuggestionViewModel.cancelAndClear()
    globalSearchHistoryViewModel.record(searchQuery)
    query = ""
    append(.search(searchQuery), to: .home)
  }

  private func openForum(named rawName: String) {
    let forumName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else { return }
    searchSuggestionViewModel.cancelAndClear()
    query = ""
    append(.forum(forumName), to: .home)
  }

  private func openPastedLinks(_ values: [String]) {
    guard let target = PastedTiebaLinkPolicy.target(from: values) else {
      linkPreviewViewModel.dismiss()
      linkErrorMessage = "请确保剪贴板中只有一个受支持的贴吧链接。"
      return
    }
    linkErrorMessage = nil
    linkPreviewViewModel.present(target: target)
  }

  private func openTiebaURL(_ url: URL) {
    linkPreviewViewModel.dismiss()
    guard
      let routedNavigation = RootStartupNavigation.appending(
        url: url,
        to: effectiveNavigation
      )
    else {
      linkErrorMessage = "该链接不是受支持的贴吧内容或应用链接。"
      return
    }
    navigation = routedNavigation
  }

  private func openHomeScreenQuickAction(_ invocation: HomeScreenQuickActionInvocation) {
    guard sceneDelegate.consume(invocation) else { return }
    dismissRootPresentationsForHomeScreenQuickAction()
    navigation = RootStartupNavigation.applyingQuickAction(
      invocation: invocation,
      to: navigation
    )
  }

  private func dismissRootPresentationsForHomeScreenQuickAction() {
    showsQuickAccountLogin = false
    searchHistoryAction = nil
    linkErrorMessage = nil
    linkPreviewViewModel.dismiss()
    pendingFollowedForumUnfollow = nil
    accountViewModel.clearError()
    favoritesViewModel.dismissOperationError()
    followedForumsViewModel.dismissPresentedOperationError()
    threadSummaryImageGalleryCoordinator.dismiss()
    contentReportCoordinator?.cancelPendingRequest()
    contentReportCoordinator?.dismissReportPage()
    contentReportCoordinator?.dismissError()
    if let page = externalWebPresentation.page {
      externalWebPresentation.dismiss(id: page.id)
    }
  }

  @ViewBuilder
  private func homeScreenQuickActionDestination(
    _ invocation: HomeScreenQuickActionInvocation,
    isActive: Bool
  ) -> some View {
    switch invocation.action {
    case .batchCheckIn:
      ForumBatchCheckInView(
        access: AccountAccess(vault: accountVault, service: accountService)
      )
    case .cloudFavorites:
      CloudFavoritesView(
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        cloudFavoriteStore: threadCloudFavoriteStore,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .search:
      SearchView(
        query: "",
        browseService: service,
        searchService: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        globalSearchHistoryViewModel: globalSearchHistoryViewModel,
        onSearchSubmitted: { globalSearchHistoryViewModel.record($0) }
      )
    case .notificationReplies:
      NotificationsView(
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        contentFilterRepository: contentFilterRepository,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        initialKind: .replies,
        isActive: isActive
      )
    }
  }

  private func openTiebaTarget(_ target: TiebaLinkTarget) {
    navigation = RootStartupNavigation.appending(
      target: target,
      to: effectiveNavigation
    )
  }

  private func openLinkPreview(_ previewID: UUID) {
    guard
      let target = linkPreviewViewModel.consumeTargetForOpening(expectedID: previewID)
    else { return }
    openTiebaTarget(target)
  }

}

private enum GlobalSearchHistoryAction {
  case clear
  case reset
}

enum RootDestination: Hashable {
  case forum(String)
  case search(String)
  case hotTopics
  case explore(ExploreSection)
  case history
  case favorites
  case followedForums
  case batchCheckIn
  case notifications(InboxKind)
  case cloudFavorites
  case homeScreenQuickAction(HomeScreenQuickActionInvocation)
  case account
  case settings
  case about
  case thread(ThreadHistorySnapshot)
  case linkedThread(TiebaThreadRoute)
  case user(Int64)
}

enum RootAccountActionPolicy {
  static func showsBatchCheckIn(
    for account: AccountSummary?,
    state: LoadState
  ) -> Bool {
    guard state == .loaded, let account else { return false }
    return account.isActive && account.hasFullCredentials
  }
}

enum RootFollowedForumsActivationPolicy {
  static func isActive(navigation: RootMainNavigationState) -> Bool {
    navigation.selectedTab == .home && navigation.path(for: .home).isEmpty
  }
}

enum RootMainTabActivationPolicy {
  static func isForeground(
    sceneIsActive: Bool,
    navigation: RootMainNavigationState,
    tab: RootMainTab
  ) -> Bool {
    sceneIsActive && navigation.selectedTab == tab
  }

  static func isActive(
    sceneIsActive: Bool,
    navigation: RootMainNavigationState,
    tab: RootMainTab
  ) -> Bool {
    isForeground(sceneIsActive: sceneIsActive, navigation: navigation, tab: tab)
      && navigation.path(for: tab).isEmpty
  }
}

enum RootUnreadSummaryActivationPolicy {
  static func isActive(
    sceneIsActive: Bool,
    navigation: RootMainNavigationState,
    accountSurfaceIsVisible: Bool
  ) -> Bool {
    guard sceneIsActive else { return false }
    switch navigation.selectedTab {
    case .home:
      return navigation.path(for: .home).isEmpty
    case .account:
      return accountSurfaceIsVisible && navigation.path(for: .account).isEmpty
    case .explore, .notifications:
      return false
    }
  }
}

enum RootStartupNavigation {
  static func initialState(
    startDestination: AppStartDestination,
    showsExploreTab: Bool = AppPreferenceDefaults.showsExploreTab
  ) -> RootMainNavigationState {
    if !showsExploreTab {
      switch startDestination {
      case .discovery:
        return RootMainNavigationState(
          selectedTab: .home,
          homePath: [.explore(.personalized)]
        )
      case .hotThreads:
        return RootMainNavigationState(
          selectedTab: .home,
          homePath: [.explore(.hot)]
        )
      case .hotTopics:
        return RootMainNavigationState(selectedTab: .home, homePath: [.hotTopics])
      case .home, .notifications, .favorites, .history:
        break
      }
    }

    return switch startDestination {
    case .home:
      RootMainNavigationState(selectedTab: .home)
    case .discovery:
      RootMainNavigationState(selectedTab: .explore, exploreSection: .personalized)
    case .hotThreads:
      RootMainNavigationState(selectedTab: .explore, exploreSection: .hot)
    case .hotTopics:
      RootMainNavigationState(selectedTab: .explore, explorePath: [.hotTopics])
    case .notifications:
      RootMainNavigationState(selectedTab: .notifications, inboxKind: .replies)
    case .favorites:
      RootMainNavigationState(selectedTab: .home, homePath: [.favorites])
    case .history:
      RootMainNavigationState(selectedTab: .home, homePath: [.history])
    }
  }

  static func appending(
    target: TiebaLinkTarget,
    to navigation: RootMainNavigationState
  ) -> RootMainNavigationState {
    var result = navigation
    let tab = result.selectedTab
    switch target {
    case .forum(let forumName):
      result.append(.forum(forumName), to: tab)
    case .thread(let route):
      result.append(.linkedThread(route), to: tab)
    case .user(let userID):
      result.append(.user(userID), to: tab)
    }
    return result
  }

  static func appending(
    url: URL,
    to navigation: RootMainNavigationState
  ) -> RootMainNavigationState? {
    if let target = TiebaLink.target(from: url) {
      return appending(target: target, to: navigation)
    }
    if let appRoute = TiebaAppLink.route(from: url) {
      return appending(appRoute: appRoute, to: navigation)
    }
    return nil
  }

  static func appending(
    appRoute: TiebaAppRoute,
    to navigation: RootMainNavigationState
  ) -> RootMainNavigationState {
    var result = navigation
    if case .notifications(let kind) = appRoute {
      result.activateInbox(kind)
      return result
    }

    result.selectedTab = .home
    result.append(destination(for: appRoute), to: .home)
    return result
  }

  static func applyingQuickAction(
    invocation: HomeScreenQuickActionInvocation,
    to navigation: RootMainNavigationState
  ) -> RootMainNavigationState {
    if invocation.action == .notificationReplies {
      var result = navigation
      result.activateInbox(.replies)
      return result
    }

    let route = invocation.appRoute
    // A check-in page owns foreground work that its disappearance intentionally
    // stops. Every other launch replaces the old navigation subtree with a
    // unique landing page so child routes, selections, and modals cannot hide it.
    if
      invocation.action == .batchCheckIn,
      navigation.selectedTab == .home,
      let current = navigation.path(for: .home).last,
      represents(route, destination: current)
    {
      return navigation
    }

    var result = navigation
    result.selectedTab = .home
    result.setPath([.homeScreenQuickAction(invocation)], for: .home)
    return result
  }

  private static func destination(for appRoute: TiebaAppRoute) -> RootDestination {
    switch appRoute {
    case .search:
      .search("")
    case .history:
      .history
    case .cloudFavorites:
      .cloudFavorites
    case .batchCheckIn:
      .batchCheckIn
    case .notifications(let kind):
      .notifications(kind)
    }
  }

  private static func represents(
    _ appRoute: TiebaAppRoute,
    destination: RootDestination
  ) -> Bool {
    if case .homeScreenQuickAction(let invocation) = destination {
      return invocation.appRoute == appRoute
    }
    return destination == self.destination(for: appRoute)
  }
}

enum RootFavoriteNavigation {
  static func destination(
    for target: LocalFavoriteTarget,
    overrides: FavoriteThreadOpenOverrides
  ) -> RootDestination {
    switch target {
    case .forum(let forum):
      .forum(forum.name)
    case .thread(let thread):
      .thread(overrides.applying(to: thread))
    }
  }
}
