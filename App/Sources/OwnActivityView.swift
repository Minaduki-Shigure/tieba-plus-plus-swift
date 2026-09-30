import SwiftUI

struct OwnActivityView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @State private var selectedKind: OwnActivityKind = .threads

  var body: some View {
    VStack(spacing: 0) {
      Picker("我的活动", selection: $selectedKind) {
        ForEach(OwnActivityKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)
      .accessibilityIdentifier("own-activity-kind")

      OwnActivityListView(
        kind: selectedKind,
        browseService: browseService,
        accountService: accountService,
        vault: vault,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
      .id(selectedKind)
    }
    .navigationTitle("我的发帖与回复")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct OwnActivityListView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel: OwnActivityViewModel
  @State private var isVisible = false
  @State private var threadRequest: ThreadSummaryNavigationRequest?
  @State private var replyTarget: UserReplyNavigationTarget?

  init(
    kind: OwnActivityKind,
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: OwnActivityViewModel(kind: kind, service: accountService, vault: vault)
    )
  }

  var body: some View {
    List {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 80)
          .listRowSeparator(.hidden)
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.reload)
          .listRowSeparator(.hidden)
      case .loaded:
        activityRows
      }
    }
    .listStyle(.plain)
    .appScrollableSurface()
    .refreshable { await viewModel.refresh() }
    .onAppear {
      isVisible = true
      viewModel.loadIfNeeded()
    }
    .onDisappear {
      isVisible = false
      viewModel.cancel()
    }
    .onChange(of: scenePhase) { phase in
      if phase == .active, isVisible {
        viewModel.loadIfNeeded()
      } else if phase == .background {
        viewModel.cancel()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      threadRequest = nil
      replyTarget = nil
      viewModel.accountSessionDidChange(loadImmediately: isVisible && scenePhase == .active)
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      viewModel.cancel()
      if isVisible && scenePhase == .active { viewModel.loadIfNeeded() }
    }
    .navigationDestination(isPresented: threadPresented) {
      if let request = threadRequest {
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
    .navigationDestination(isPresented: replyPresented) {
      if let target = replyTarget { replyDestination(target) }
    }
  }

  @ViewBuilder
  private var activityRows: some View {
    if viewModel.isSignedOut {
      EmptyStateView(title: "请先登录账户", systemImage: "person.crop.circle.badge.exclamationmark")
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    } else if viewModel.isHidden {
      EmptyStateView(title: "贴吧暂未提供这些活动记录", systemImage: "eye.slash")
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    } else {
      if viewModel.kind == .threads {
        ForEach(viewModel.threads.filter { $0.localVisibility != .hidden }) { thread in
          LocallyFilteredContent(
            visibility: thread.localVisibility, placeholder: "已屏蔽此主题"
          ) {
            ThreadSummaryRow(
              thread: thread,
              showsForum: true,
              showsAuthor: false,
              onNavigate: { threadRequest = $0 }
            )
          }
          .frame(minHeight: 44)
        }
      } else {
        ForEach(viewModel.replies.filter { $0.localVisibility != .hidden }) { reply in
          LocallyFilteredContent(
            visibility: reply.localVisibility, placeholder: "已屏蔽此回复"
          ) {
            UserActivityReplyRow(reply: reply) { replyTarget = $0 }
          }
          .frame(minHeight: 44)
        }
      }

      if !hasVisibleActivity {
        EmptyStateView(
          title: hasActivity ? "暂无可显示的活动记录" : "暂无活动记录",
          systemImage: "text.bubble"
        )
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
      }

      if viewModel.isLoadingMore {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 44)
          .listRowSeparator(.hidden)
      } else if let message = viewModel.loadMoreError {
        LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
          .listRowSeparator(.hidden)
      } else if viewModel.hasMore {
        Button("加载更多", action: viewModel.loadMore)
          .frame(maxWidth: .infinity, minHeight: 44)
          .accessibilityIdentifier("own-activity-load-more")
      }
    }
  }

  private var hasActivity: Bool {
    viewModel.kind == .threads ? !viewModel.threads.isEmpty : !viewModel.replies.isEmpty
  }

  private var hasVisibleActivity: Bool {
    viewModel.kind == .threads
      ? viewModel.threads.contains { $0.localVisibility != .hidden }
      : viewModel.replies.contains { $0.localVisibility != .hidden }
  }

  private var threadPresented: Binding<Bool> {
    Binding(
      get: { threadRequest != nil },
      set: { if !$0 { threadRequest = nil } }
    )
  }

  private var replyPresented: Binding<Bool> {
    Binding(
      get: { replyTarget != nil },
      set: { if !$0 { replyTarget = nil } }
    )
  }

  @ViewBuilder
  private func replyDestination(_ target: UserReplyNavigationTarget) -> some View {
    switch target {
    case .thread(let route):
      ThreadView(
        thread: route.placeholderThread,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
    case .comment(let threadID, let commentID):
      CommentsView(
        threadID: threadID,
        resolvingCommentID: commentID,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        presentationContext: .navigation
      )
    }
  }
}
