import Combine
import SwiftUI

struct PersonalizedFeedView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: PersonalizedFeedViewModel

  init(
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(wrappedValue: PersonalizedFeedViewModel(service: service))
  }

  var body: some View {
    Group {
      if viewModel.state == .loaded {
        feedList
      } else {
        initialState
      }
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      viewModel.reloadForContentFilterChange()
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
      Text(viewModel.refreshError ?? "无法刷新推荐内容。")
    }
  }

  @ViewBuilder
  private var initialState: some View {
    switch viewModel.state {
    case .idle, .loading:
      ProgressView()
    case .failed(let message):
      ErrorStateView(message: message, retry: viewModel.retry)
    case .loaded:
      EmptyStateView(title: "暂无推荐内容", systemImage: "sparkles")
    }
  }

  private var feedList: some View {
    List {
      if viewModel.items.isEmpty {
        EmptyStateView(title: "暂无推荐内容", systemImage: "sparkles")
          .frame(maxWidth: .infinity, minHeight: 240)
          .listRowSeparator(.hidden)
      } else {
        ForEach(viewModel.items) { item in
          LocallyFilteredContent(
            visibility: item.thread.localVisibility,
            placeholder: "已屏蔽此推荐帖子"
          ) {
            NavigationLink {
              ThreadView(
                thread: item.thread,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              ThreadSummaryRow(thread: item.thread, showsForum: true)
            }
          }
        }
      }

      if viewModel.isLoadingMore {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      } else if let loadMoreError = viewModel.loadMoreError {
        LoadMoreErrorView(message: loadMoreError, retry: viewModel.retryLoadMore)
          .listRowSeparator(.hidden)
      } else if viewModel.hasMore, !viewModel.items.isEmpty {
        Color.clear
          .frame(height: 1)
          .listRowSeparator(.hidden)
          .accessibilityHidden(true)
          .onAppear(perform: viewModel.loadMore)
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }
}
