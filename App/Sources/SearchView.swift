import SwiftUI

struct SearchView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: SearchViewModel
  @State private var query: String

  init(
    query: String,
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    searchService: any SearchService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
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
    .onSubmit(of: .search) { viewModel.submit(query) }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
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
        ForEach(viewModel.threads) { thread in
          NavigationLink {
            ThreadView(
              thread: thread,
              service: browseService,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository
            )
          } label: {
            SearchThreadRow(thread: thread)
          }
          .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
        }

        if viewModel.isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowSeparator(.hidden)
        } else if let message = viewModel.loadMoreError {
          LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
            .listRowSeparator(.hidden)
        }
      }
    }
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
        favoritesRepository: favoritesRepository
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
        case .success(let image):
          image.resizable().scaledToFill()
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
    VStack(alignment: .leading, spacing: 7) {
      Text(thread.title.isEmpty ? thread.excerpt : thread.title)
        .font(.headline)
        .lineLimit(2)
      if !thread.title.isEmpty, !thread.excerpt.isEmpty {
        Text(thread.excerpt)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      HStack(spacing: 12) {
        Label(thread.forumName, systemImage: "text.bubble")
          .lineLimit(1)
        Label(thread.authorName, systemImage: "person")
          .lineLimit(1)
        Spacer(minLength: 0)
        Label(thread.replyCount.formatted(), systemImage: "bubble.left")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}

private struct UserSearchRow: View {
  let user: UserSearchItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: user.portraitURL, name: user.preferredName, size: 48)
      VStack(alignment: .leading, spacing: 4) {
        Text(user.preferredName)
          .font(.headline)
          .lineLimit(2)
        if !user.username.isEmpty, user.username != user.preferredName {
          Text(user.username)
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
