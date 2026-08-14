import Combine
import SwiftUI

struct PersonalizedFeedView: View {
  let isActive: Bool
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: PersonalizedFeedViewModel
  @State private var completeIndexSurfaceID = UUID()
  @State private var showsLogin = false
  @EnvironmentObject private var followedForumsViewModel: FollowedForumsViewModel
  @AppStorage(AppPreferenceKey.personalizedFollowedForumsOnly)
  private var followedForumsOnly = AppPreferenceDefaults.personalizedFollowedForumsOnly

  init(
    isActive: Bool,
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.isActive = isActive
    self.service = service
    self.accountService = accountService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(wrappedValue: PersonalizedFeedViewModel(service: service))
  }

  var body: some View {
    Group {
      if followedForumsOnly {
        followedForumsOnlyContent
      } else {
        feedContent
      }
    }
    .onAppear(perform: synchronizeActivation)
    .onChange(of: isActive) { _ in synchronizeActivation() }
    .onChange(of: followedForumsOnly) { _ in synchronizeActivation() }
    .onChange(of: followedForumsViewModel.indexState) { _ in synchronizeScope() }
    .onDisappear {
      followedForumsViewModel.completeIndexSurfaceDidDisappear(id: completeIndexSurfaceID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      if isActive { viewModel.reloadForContentFilterChange() }
    }
    .sheet(isPresented: $showsLogin) {
      NavigationStack {
        LoginView(service: accountService, vault: vault) {}
      }
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
  private var followedForumsOnlyContent: some View {
    switch followedForumsViewModel.indexState {
    case .idle, .loading, .partial:
      ProgressView()
    case .signedOut:
      accountState
    case .failed(let message):
      ErrorStateView(message: message, retry: followedForumsViewModel.retryCompleteIndex)
    case .ready(let snapshot):
      if snapshot.forumIDs.isEmpty {
        EmptyStateView(title: "当前账户暂无关注贴吧", systemImage: "star")
      } else {
        feedContent
      }
    }
  }

  @ViewBuilder
  private var feedContent: some View {
    if viewModel.state == .loaded {
      feedList
    } else {
      initialState
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
      EmptyStateView(title: emptyTitle, systemImage: "sparkles")
    }
  }

  private var accountState: some View {
    VStack(spacing: 12) {
      EmptyStateView(
        title: "请先登录账户",
        systemImage: "person.crop.circle.badge.exclamationmark"
      )
      Button { showsLogin = true } label: {
        Label("登录账户", systemImage: "person.badge.key")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var emptyTitle: String {
    followedForumsOnly ? "暂无来自已关注贴吧的推荐" : "暂无推荐内容"
  }

  private var feedList: some View {
    List {
      if viewModel.items.isEmpty {
        EmptyStateView(title: emptyTitle, systemImage: "sparkles")
          .frame(maxWidth: .infinity, minHeight: 240)
          .listRowSeparator(.hidden)
        if viewModel.hasMore, viewModel.loadMoreError == nil {
          Button {
            guard isActive else { return }
            viewModel.loadMore()
          } label: {
            Label("继续加载", systemImage: "arrow.down.circle")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderless)
          .disabled(viewModel.isLoadingMore || viewModel.loadMoreError != nil)
          .listRowSeparator(.hidden)
        }
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
          .onAppear {
            guard isActive else { return }
            viewModel.loadMoreIfNeeded(currentItemID: item.id)
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
          .onAppear {
            guard isActive else { return }
            viewModel.loadMore()
          }
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private func synchronizeActivation() {
    if isActive, followedForumsOnly {
      followedForumsViewModel.completeIndexSurfaceDidAppear(id: completeIndexSurfaceID)
    } else {
      followedForumsViewModel.completeIndexSurfaceDidDisappear(id: completeIndexSurfaceID)
    }
    synchronizeScope()
    if !isActive { viewModel.cancel() }
  }

  private func synchronizeScope() {
    let scope: PersonalizedFeedScope
    if !followedForumsOnly {
      scope = .all
    } else if case .ready(let snapshot) = followedForumsViewModel.indexState {
      scope = .followedForums(snapshot)
    } else {
      scope = .waitingForFollowedForumIndex
    }
    viewModel.setScope(scope, loadIfNeeded: isActive)
  }
}
