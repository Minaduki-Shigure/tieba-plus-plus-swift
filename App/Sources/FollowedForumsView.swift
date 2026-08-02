import SwiftUI

struct FollowedForumsView: View {
  let browseService: any BrowseService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository

  @StateObject private var viewModel: FollowedForumsViewModel

  init(
    browseService: any BrowseService & UserProfileService & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository
  ) {
    self.browseService = browseService
    self.accountService = accountService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    _viewModel = StateObject(
      wrappedValue: FollowedForumsViewModel(service: accountService, vault: vault)
    )
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
    .navigationTitle("我的关注")
    .navigationBarTitleDisplayMode(.inline)
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
  }

  private var forumList: some View {
    List {
      ForEach(viewModel.forums) { forum in
        NavigationLink {
          ForumView(
            forumName: forum.name,
            service: browseService,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
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
