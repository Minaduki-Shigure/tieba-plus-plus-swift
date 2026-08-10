import Combine
import SwiftUI

struct SearchView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let onSearchSubmitted: @MainActor (String) -> Void

  @StateObject private var viewModel: SearchViewModel
  @State private var query: String

  init(
    query: String,
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    searchService: any SearchService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    onSearchSubmitted: @escaping @MainActor (String) -> Void
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.onSearchSubmitted = onSearchSubmitted
    _query = State(initialValue: query)
    _viewModel = StateObject(wrappedValue: SearchViewModel(query: query, service: searchService))
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker(
        "搜索范围",
        selection: Binding(
          get: { viewModel.selectedScope },
          set: { viewModel.selectScope($0) }
        )
      ) {
        ForEach(SearchScope.allCases) { scope in
          Text(scope.title).tag(scope)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Divider()
      if viewModel.selectedScope == .threads {
        threadSortPicker
        Divider()
      }
      selectedResults
    }
    .navigationTitle(viewModel.submittedQuery.isEmpty ? "搜索" : viewModel.submittedQuery)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "搜索贴吧、帖子和用户")
    .onSubmit(of: .search, submitSearch)
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in viewModel.reloadThreadsAfterContentFilterChange() }
    }
    .alert(
      "刷新失败",
      isPresented: Binding(
        get: { viewModel.refreshError != nil },
        set: { if !$0 { viewModel.clearRefreshError() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.clearRefreshError() }
    } message: {
      Text(viewModel.refreshError ?? "无法刷新搜索结果。")
    }
  }

  private func submitSearch() {
    let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    viewModel.submit(query)
    guard !submittedQuery.isEmpty else { return }
    onSearchSubmitted(submittedQuery)
  }

  private var threadSortPicker: some View {
    Picker(
      "帖子排序",
      selection: Binding(
        get: { viewModel.threadSort },
        set: { viewModel.setThreadSort($0) }
      )
    ) {
      ForEach(GlobalThreadSearchSort.allCases) { sort in
        Text(sort.title).tag(sort)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: .infinity, minHeight: 32)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .accessibilityIdentifier("global-thread-search-sort-picker")
  }

  @ViewBuilder
  private var selectedResults: some View {
    if !viewModel.hasResults {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.retry)
      case .loaded:
        emptyResults
      }
    } else {
      switch viewModel.selectedScope {
      case .forums:
        forumResults
      case .threads:
        threadResults
      case .users:
        userResults
      }
    }
  }

  private var forumResults: some View {
    List {
      if let exactForum = viewModel.exactForum {
        Section("精确匹配") {
          forumLink(exactForum)
        }
      }

      if !viewModel.relatedForums.isEmpty {
        Section(viewModel.exactForum == nil ? "贴吧" : "相关贴吧") {
          ForEach(viewModel.relatedForums) { forum in
            forumLink(forum)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }

  private var threadResults: some View {
    List {
      Section("帖子") {
        ForEach(viewModel.displayableThreads) { thread in
          LocallyFilteredContent(
            visibility: thread.localVisibility,
            placeholder: "已屏蔽此搜索结果"
          ) {
            NavigationLink {
              ThreadView(
                thread: thread,
                service: browseService,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              SearchThreadRow(thread: thread)
            }
          }
          .frame(minHeight: 44)
          .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
        }

        if !viewModel.threads.isEmpty && !viewModel.hasDisplayableThreads {
          Label("暂无可显示的帖子", systemImage: "eye.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        }

        if let lastThread = viewModel.threads.last {
          Color.clear
            .frame(height: 1)
            .id(
              "search-thread-pagination-\(lastThread.id)-\(viewModel.threads.count)-\(viewModel.threadPaginationEpoch)"
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear { viewModel.loadMoreIfNeeded(current: lastThread) }
        }

        if viewModel.isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .frame(minHeight: 44)
          .listRowSeparator(.hidden)
        } else if let message = viewModel.loadMoreError {
          LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
            .frame(minHeight: 44)
            .listRowSeparator(.hidden)
        }
      }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }

  private var userResults: some View {
    List {
      if let exactUser = viewModel.exactUser {
        Section("推荐") {
          userLink(exactUser)
        }
      }

      if !viewModel.relatedUsers.isEmpty {
        Section(viewModel.exactUser == nil ? "用户" : "相关用户") {
          ForEach(viewModel.relatedUsers) { user in
            userLink(user)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }

  private var emptyResults: some View {
    List {}
      .listStyle(.insetGrouped)
      .overlay {
        EmptyStateView(title: emptyTitle, systemImage: emptySystemImage)
      }
      .refreshable { await viewModel.refresh() }
  }

  private func forumLink(_ forum: ForumSearchItem) -> some View {
    NavigationLink {
      ForumView(
        forumName: forum.name,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    } label: {
      ForumSearchRow(forum: forum)
    }
  }

  private func userLink(_ user: UserSearchItem) -> some View {
    NavigationLink {
      UserProfileView(
        userID: user.id,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    } label: {
      UserSearchRow(user: user)
    }
  }

  private var emptyTitle: String {
    switch viewModel.selectedScope {
    case .forums:
      "没有找到贴吧"
    case .threads:
      "没有找到帖子"
    case .users:
      "没有找到用户"
    }
  }

  private var emptySystemImage: String {
    switch viewModel.selectedScope {
    case .forums:
      "text.bubble"
    case .threads:
      "text.page"
    case .users:
      "person.crop.circle"
    }
  }
}

private struct ForumSearchRow: View {
  let forum: ForumSearchItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      DownsampledRemoteImage(url: forum.avatarURL, maxPixelSize: 256) { phase in
        switch phase {
        case .success(let asset, _):
          RemoteImageAssetView(asset: asset, contentMode: .fill)
        default:
          Image(systemName: "text.bubble.fill")
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemFill))
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(forum.displayName)
          .font(.headline)
        if !forum.summary.isEmpty {
          Text(forum.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 12) {
          Label(forum.memberCount.formatted(), systemImage: "person.2")
          Label(forum.postCount.formatted(), systemImage: "text.bubble")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct SearchThreadRow: View {
  let thread: BrowseThread

  var body: some View {
    ThreadSummaryRow(thread: thread, showsForum: true)
  }
}

private struct UserSearchRow: View {
  let user: UserSearchItem
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  private var displayedName: String {
    UserNameFormatter.displayName(
      preferredName: user.displayName,
      username: user.username,
      showsBoth: showsBothNames
    )
  }

  private var legacyUsername: String? {
    guard !showsBothNames else { return nil }
    let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty, username != displayedName else { return nil }
    return username
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: user.portraitURL, name: displayedName, size: 48)
      VStack(alignment: .leading, spacing: 4) {
        Text(displayedName)
          .font(.headline)
          .lineLimit(showsBothNames ? 3 : 2)
          .minimumScaleFactor(0.75)
          .accessibilityLabel(displayedName)
        if let legacyUsername {
          Text(legacyUsername)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if !user.introduction.isEmpty {
          Text(user.introduction)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 3)
  }
}
