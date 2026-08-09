import SwiftUI

struct FollowedForumsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @State private var surfaceID = UUID()
  @EnvironmentObject private var viewModel: FollowedForumsViewModel

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
    .onAppear { viewModel.fullListSurfaceDidAppear(id: surfaceID) }
    .onDisappear { viewModel.fullListSurfaceDidDisappear(id: surfaceID) }
  }

  private var forumList: some View {
    List {
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
          VStack(alignment: .leading, spacing: 5) {
            Text("\(forum.name)吧")
              .font(.headline)
            HStack(spacing: 12) {
              if forum.level > 0 {
                Label("等级 \(forum.level)", systemImage: "chart.line.uptrend.xyaxis")
              }
              if forum.experience > 0 {
                Label(forum.experience.formatted(), systemImage: "sparkles")
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 3)
        }
        .onAppear { viewModel.loadMoreIfNeeded(current: forum) }
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
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }
}
