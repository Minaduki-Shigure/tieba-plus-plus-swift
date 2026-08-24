import Combine
import Foundation
import SwiftUI

struct RootView: View {
  let service:
    any BrowseService & SearchService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
      & SearchSuggestionService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let accountVault: any AccountVault
  let accountSessionLookup: any AccountSessionLookup
  let accountService: any AccountService
  let personalizedFeedbackService: any PersonalizedFeedbackService
  let contentFilterRepository: any ContentFilterRepository

  @State private var query = ""
  @State private var path: [RootDestination]
  @State private var showsAllSearchHistory = false
  @State private var showsRecentForums = true
  @State private var searchHistoryAction: GlobalSearchHistoryAction?
  @State private var linkErrorMessage: String?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentObject private var mediaPlaybackCoordinator: MediaPlaybackCoordinator
  @EnvironmentObject private var followedForumsViewModel: FollowedForumsViewModel
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
  @StateObject private var threadSummaryImageGalleryCoordinator:
    ThreadSummaryImageGalleryCoordinator

  init(
    service: any BrowseService & SearchService & ForumPostSearchService & HotTopicService
      & HotThreadService & PersonalizedFeedService & UserProfileService & ForumInformationService
      & SearchSuggestionService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    globalSearchHistoryRepository: any GlobalSearchHistoryRepository,
    accountVault: any AccountVault,
    accountSessionLookup: any AccountSessionLookup,
    accountService: any AccountService,
    personalizedFeedbackService: any PersonalizedFeedbackService,
    contentFilterRepository: any ContentFilterRepository,
    startDestination: AppStartDestination
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
    _path = State(
      initialValue: RootStartupNavigation.initialPath(startDestination: startDestination)
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
    _threadSummaryImageGalleryCoordinator = StateObject(
      wrappedValue: ThreadSummaryImageGalleryCoordinator(
        remoteService: service as? any ThreadPictureGalleryService,
        contentFilterRepository: contentFilterRepository
      )
    )
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if homeShowsDiscovery {
          Section("\u{53d1}\u{73b0}") {
            NavigationLink(value: RootDestination.explore(.personalized)) {
              Label("发现", systemImage: "sparkles")
            }

            NavigationLink(value: RootDestination.hotTopics) {
              Label("\u{70ed}\u{95e8}\u{8bdd}\u{9898}", systemImage: "flame.fill")
            }

            HStack(spacing: 12) {
              Label("打开贴吧链接", systemImage: "link")
              Spacer(minLength: 8)
              PasteButton(payloadType: String.self, onPaste: openPastedLinks)
                .accessibilityLabel("粘贴并打开贴吧链接")
                .help("粘贴并打开贴吧链接")
            }
          }
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

        searchSuggestionSection

        searchHistorySection

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
        }

        followedForumsSection

        recentForumsSection

        if !favoritesViewModel.favoriteForumEntries.isEmpty {
          Section("收藏的贴吧") {
            ForEach(Array(favoritesViewModel.favoriteForumEntries.prefix(6))) { entry in
              if case .forum(let forum) = entry.target {
                Button {
                  path.append(.forum(forum.name))
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
        }

      }
      .listStyle(.insetGrouped)
      .navigationTitle("贴吧++")
      .toolbar {
        if RootAccountActionPolicy.showsBatchCheckIn(
          for: accountViewModel.activeAccount,
          state: accountViewModel.state
        ) {
          ToolbarItem(placement: .navigationBarLeading) {
            Button {
              path.append(.batchCheckIn)
            } label: {
              Image(systemName: "checkmark.seal")
            }
            .accessibilityLabel("一键签到")
            .accessibilityHint("打开前台一键签到页面")
            .help("一键签到")
          }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Button {
            path.append(.account)
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .accessibilityLabel("账户")
          .help("账户")

          Button {
            path.append(.settings)
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("设置")
          .help("设置")

          Button {
            path.append(.favorites)
          } label: {
            Image(systemName: "bookmark")
          }
          .accessibilityLabel("本地收藏")
          .help("本地收藏")

          Button {
            path.append(.history)
          } label: {
            Image(systemName: "clock.arrow.circlepath")
          }
          .accessibilityLabel("浏览记录")
          .help("浏览记录")
        }
      }
      .navigationDestination(for: RootDestination.self) { destination in
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
              path.append(.forum(forum.name))
            case .thread(let thread):
              path.append(.thread(thread))
            }
          }
        case .favorites:
          LocalFavoritesView(repository: favoritesRepository) { target in
            let overrides = FavoriteThreadOpenOverrides(
              onlyThreadAuthor: favoriteThreadsOpenOnlyAuthor,
              descending: favoriteThreadsOpenDescending
            )
            path.append(
              RootFavoriteNavigation.destination(for: target, overrides: overrides)
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
        case .notifications:
          NotificationsView(
            browseService: service,
            accountService: accountService,
            vault: accountVault,
            contentFilterRepository: contentFilterRepository,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        case .account:
          AccountView(
            browseService: service,
            accountService: accountService,
            vault: accountVault,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        case .settings:
          AppSettingsView(historyRepository: historyRepository)
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
        "无法读取或更新置顶贴吧",
        isPresented: Binding(
          get: {
            followedForumsViewModel.pinOperationError != nil
              && !followedForumsViewModel.hasActiveFullListSurface
          },
          set: { if !$0 { followedForumsViewModel.dismissPinOperationError() } }
        )
      ) {
        Button("好", action: followedForumsViewModel.dismissPinOperationError)
      } message: {
        Text(followedForumsViewModel.pinOperationError ?? "未知错误")
      }
    }
    .threadSummaryImageGallery(threadSummaryImageGalleryCoordinator)
    .onAppear {
      favoritesViewModel.reload()
      recentForumsViewModel.reload()
      if RootFollowedForumsActivationPolicy.isActive(path: path) {
        followedForumsViewModel.loadIfNeeded()
      }
      searchSuggestionViewModel.setEnabled(searchSuggestionsEnabled)
      mediaPlaybackCoordinator.setSceneActive(scenePhase == .active)
    }
    .task { await globalSearchHistoryViewModel.loadIfNeeded() }
    .task { await accountViewModel.loadIfNeeded() }
    .onChange(of: query) { searchSuggestionViewModel.inputChanged($0) }
    .onChange(of: searchSuggestionsEnabled) {
      searchSuggestionViewModel.setEnabled($0)
    }
    .onChange(of: scenePhase) {
      mediaPlaybackCoordinator.setSceneActive($0 == .active)
      if $0 != .active {
        searchSuggestionViewModel.cancelAndClear()
      }
    }
    .onChange(of: path) { path in
      searchSuggestionViewModel.cancelAndClear()
      recentForumsViewModel.reload()
      if RootFollowedForumsActivationPolicy.isActive(path: path) {
        followedForumsViewModel.loadIfNeeded()
      }
    }
    .onDisappear { searchSuggestionViewModel.cancelAndClear() }
    .onReceive(NotificationCenter.default.publisher(for: .localFavoritesDidChange)) { _ in
      Task { @MainActor in favoritesViewModel.reload() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumBrowsingHistoryDidChange)) { _ in
      Task { @MainActor in recentForumsViewModel.reload() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      accountViewModel.invalidateForAccountSessionChange()
      Task { @MainActor in await accountViewModel.loadIfNeeded() }
      let loadsImmediately = RootFollowedForumsActivationPolicy.isActive(path: path)
        || followedForumsViewModel.hasActiveFullListSurface
        || followedForumsViewModel.hasActiveCompleteIndexSurface
      followedForumsViewModel.accountSessionDidChange(loadImmediately: loadsImmediately)
    }
    .onReceive(NotificationCenter.default.publisher(for: .forumMembershipDidChange)) {
      notification in
      guard let change = ForumMembershipChange(notification) else { return }
      let loadsImmediately = RootFollowedForumsActivationPolicy.isActive(path: path)
        || followedForumsViewModel.hasActiveFullListSurface
        || followedForumsViewModel.hasActiveCompleteIndexSurface
      followedForumsViewModel.forumMembershipDidChange(
        change,
        loadImmediately: loadsImmediately
      )
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

  @ViewBuilder
  private var followedForumsSection: some View {
    let forums = followedForumsViewModel.homeForums
    if !forums.isEmpty {
      Section("关注的贴吧") {
        LazyVGrid(
          columns: FollowedForumsLayoutPolicy.columns(
            preferred: FollowedForumsLayoutMode.resolved(followedForumsLayout),
            dynamicTypeSize: dynamicTypeSize
          ),
          alignment: .leading,
          spacing: FollowedForumsLayoutPolicy.spacing
        ) {
          ForEach(forums) { forum in
            let isPinned = followedForumsViewModel.isPinned(forum)
            Button {
              path.append(.forum(forum.name))
            } label: {
              FollowedForumCard(forum: forum, isPinned: isPinned)
            }
            .buttonStyle(.plain)
            .followedForumContextMenu(
              forum: forum,
              isPinned: isPinned,
              setPinned: { followedForumsViewModel.setPinned(forum, isPinned: $0) }
            )
          }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        NavigationLink(value: RootDestination.followedForums) {
          Label("查看全部", systemImage: "list.bullet")
        }
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
    }
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
                    path.append(.forum(forum.name))
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
    path.append(.search(searchQuery))
  }

  private func openForum(named rawName: String) {
    let forumName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else { return }
    searchSuggestionViewModel.cancelAndClear()
    query = ""
    path.append(.forum(forumName))
  }

  private func openPastedLinks(_ values: [String]) {
    let targets = Set(values.compactMap { TiebaLink.target(fromPastedText: $0) })
    guard targets.count == 1, let target = targets.first else {
      linkErrorMessage = "请确保剪贴板中只有一个受支持的贴吧链接。"
      return
    }
    openTiebaTarget(target)
  }

  private func openTiebaURL(_ url: URL) {
    guard let target = TiebaLink.target(from: url) else {
      linkErrorMessage = "该链接不是受支持的贴吧、帖子或用户链接。"
      return
    }
    openTiebaTarget(target)
  }

  private func openTiebaTarget(_ target: TiebaLinkTarget) {
    path = RootStartupNavigation.appending(target: target, to: path)
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
  case notifications
  case account
  case settings
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
  static func isActive(path: [RootDestination]) -> Bool {
    path.isEmpty
  }
}

enum RootStartupNavigation {
  static func initialPath(startDestination: AppStartDestination) -> [RootDestination] {
    switch startDestination {
    case .home:
      []
    case .hotThreads:
      [.explore(.hot)]
    case .hotTopics:
      [.hotTopics]
    case .notifications:
      [.notifications]
    case .favorites:
      [.favorites]
    case .history:
      [.history]
    }
  }

  static func appending(
    target: TiebaLinkTarget,
    to path: [RootDestination]
  ) -> [RootDestination] {
    var result = path
    switch target {
    case .forum(let forumName):
      result.append(.forum(forumName))
    case .thread(let route):
      result.append(.linkedThread(route))
    case .user(let userID):
      result.append(.user(userID))
    }
    return result
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
