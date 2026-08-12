import SwiftUI

struct FollowedForumsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @State private var surfaceID = UUID()
  @EnvironmentObject private var viewModel: FollowedForumsViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage(AppPreferenceKey.followedForumsLayout)
  private var followedForumsLayout = FollowedForumsLayoutMode.defaultValue.rawValue

  init(
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
  }

  var body: some View {
    Group {
      if viewModel.forums.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          EmptyStateView(title: "暂无关注贴吧", systemImage: "star")
        }
      } else {
        forumList
      }
    }
    .navigationTitle("关注的贴吧")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !dynamicTypeSize.isAccessibilitySize {
        Button(action: toggleLayout) {
          Image(systemName: preferredLayout == .adaptive ? "list.bullet" : "rectangle.grid.2x2")
        }
        .accessibilityLabel(preferredLayout == .adaptive ? "切换为单列" : "切换为自适应布局")
        .help(preferredLayout == .adaptive ? "切换为单列" : "切换为自适应布局")
        .accessibilityIdentifier("followed-forums-layout-toggle")
      }
    }
    .onAppear { viewModel.fullListSurfaceDidAppear(id: surfaceID) }
    .onDisappear { viewModel.fullListSurfaceDidDisappear(id: surfaceID) }
  }

  private var forumList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        LazyVGrid(
          columns: FollowedForumsLayoutPolicy.columns(
            preferred: preferredLayout,
            dynamicTypeSize: dynamicTypeSize
          ),
          alignment: .leading,
          spacing: FollowedForumsLayoutPolicy.spacing
        ) {
          ForEach(viewModel.forums) { forum in
            NavigationLink {
              ForumView(
                forumName: forum.name,
                service: browseService,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              FollowedForumCard(forum: forum)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if viewModel.isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .padding(.vertical, 12)
        } else if let message = viewModel.loadMoreError {
          LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        } else if viewModel.canLoadNextPage {
          Button(action: viewModel.loadNextPage) {
            Label("加载更多", systemImage: "arrow.down.circle")
          }
          .buttonStyle(.bordered)
          .padding(.bottom, 16)
          .accessibilityIdentifier("followed-forums-load-more")
        }
      }
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .refreshable { await viewModel.refresh() }
  }

  private var preferredLayout: FollowedForumsLayoutMode {
    FollowedForumsLayoutMode.resolved(followedForumsLayout)
  }

  private func toggleLayout() {
    followedForumsLayout = preferredLayout.toggled.rawValue
  }
}
