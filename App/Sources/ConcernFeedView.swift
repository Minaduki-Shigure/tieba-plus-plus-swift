import SwiftUI

struct ConcernFeedView: View {
  let isActive: Bool
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ConcernFeedViewModel
  @State private var showsLogin = false
  @State private var threadNavigationRequest: ThreadSummaryNavigationRequest?

  init(
    isActive: Bool,
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.isActive = isActive
    self.browseService = browseService
    self.accountService = accountService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: ConcernFeedViewModel(service: accountService, vault: vault)
    )
  }

  var body: some View {
    Group {
      switch viewModel.state {
      case .idle, .resolvingSession, .loading:
        ProgressView()
      case .signedOut:
        accountState(
          title: "请先登录账户",
          systemImage: "person.crop.circle.badge.exclamationmark"
        )
      case .needsRelogin:
        accountState(
          title: "请重新登录后读取关注动态",
          systemImage: "person.crop.circle.badge.exclamationmark"
        )
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.retry)
      case .loaded:
        feedList
      }
    }
    .onAppear { viewModel.setActive(isActive) }
    .onChange(of: isActive) { viewModel.setActive($0) }
    .onDisappear(perform: viewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      viewModel.accountSessionDidChange()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      viewModel.contentFilterDidChange()
    }
    .navigationDestination(isPresented: threadNavigationPresented) {
      if let request = threadNavigationRequest {
        threadDestination(request)
      } else {
        EmptyView()
      }
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
      Text(viewModel.refreshError ?? "无法刷新关注动态。")
    }
  }

  private func accountState(title: String, systemImage: String) -> some View {
    VStack(spacing: 12) {
      EmptyStateView(title: title, systemImage: systemImage)
      Button { showsLogin = true } label: {
        Label("登录账户", systemImage: "person.badge.key")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var feedList: some View {
    List {
      Group {
        if viewModel.threads.isEmpty {
          EmptyStateView(title: "暂无关注动态", systemImage: "person.2")
            .frame(maxWidth: .infinity, minHeight: 240)
            .listRowSeparator(.hidden)
        } else {
          ForEach(viewModel.threads) { thread in
            LocallyFilteredContent(
              visibility: thread.localVisibility,
              placeholder: "已屏蔽此关注帖子"
            ) {
              ThreadSummaryRow(
                thread: thread,
                showsForum: true,
                onNavigate: { threadNavigationRequest = $0 }
              )
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
        } else if viewModel.hasMore, !viewModel.threads.isEmpty {
          Color.clear
            .frame(height: 1)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear(perform: viewModel.loadMore)
        }
      }
      .appListRowSurface(.content)
    }
    .listStyle(.plain)
    .appScrollableSurface(.canvas)
    .refreshable { await viewModel.refresh() }
  }

  private var threadNavigationPresented: Binding<Bool> {
    Binding(
      get: { threadNavigationRequest != nil },
      set: { isPresented in
        if !isPresented { threadNavigationRequest = nil }
      }
    )
  }

  private func threadDestination(_ request: ThreadSummaryNavigationRequest) -> some View {
    ThreadView(
      thread: request.thread,
      service: browseService,
      historyRepository: historyRepository,
      favoritesRepository: favoritesRepository,
      searchHistoryRepository: searchHistoryRepository,
      linkRoute: request.linkRoute,
      initialFocus: request.initialFocus
    )
    .id(request.destinationID)
  }
}
