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
    .alert(
      "无法读取或更新置顶贴吧",
      isPresented: Binding(
        get: { viewModel.pinOperationError != nil },
        set: { if !$0 { viewModel.dismissPinOperationError() } }
      )
    ) {
      Button("好", action: viewModel.dismissPinOperationError)
    } message: {
      Text(viewModel.pinOperationError ?? "未知错误")
    }
    .navigationTitle("关注的贴吧")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let action = layoutToggleAction {
        ToolbarItem(placement: .navigationBarTrailing) {
          FollowedForumsLayoutToggleButton(
            action: action,
            accessibilityIdentifier: "followed-forums-layout-toggle",
            onToggle: { applyLayoutToggle(action) }
          )
        }
      }
    }
    .onAppear { viewModel.fullListSurfaceDidAppear(id: surfaceID) }
    .onDisappear { viewModel.fullListSurfaceDidDisappear(id: surfaceID) }
  }

  private var forumList: some View {
    let projection = viewModel.forumProjection
    return ScrollView {
      LazyVStack(spacing: 0) {
        if !projection.pinned.isEmpty {
          groupHeader("置顶", systemImage: "pin.fill")
          forumGrid(projection.pinned, isPinned: true)
        }

        if !projection.unpinned.isEmpty {
          if !projection.pinned.isEmpty {
            groupHeader("其他关注", systemImage: "star")
          }
          forumGrid(projection.unpinned, isPinned: false)
        }

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

  private func forumGrid(_ forums: [FollowedForumItem], isPinned: Bool) -> some View {
    LazyVGrid(
      columns: FollowedForumsLayoutPolicy.columns(
        preferred: preferredLayout,
        dynamicTypeSize: dynamicTypeSize
      ),
      alignment: .leading,
      spacing: FollowedForumsLayoutPolicy.spacing
    ) {
      ForEach(forums) { forum in
        NavigationLink {
          ForumView(
            forumName: forum.name,
            service: browseService,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        } label: {
          FollowedForumCard(forum: forum, isPinned: isPinned)
        }
        .buttonStyle(.plain)
        .followedForumContextMenu(
          forum: forum,
          isPinned: isPinned,
          setPinned: { viewModel.setPinned(forum, isPinned: $0) }
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func groupHeader(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(.horizontal, 16)
      .accessibilityAddTraits(.isHeader)
  }

  private var preferredLayout: FollowedForumsLayoutMode {
    FollowedForumsLayoutMode.resolved(followedForumsLayout)
  }

  private var layoutToggleAction: FollowedForumsLayoutToggleAction? {
    FollowedForumsLayoutPolicy.toggleAction(
      preferred: preferredLayout,
      dynamicTypeSize: dynamicTypeSize
    )
  }

  private func applyLayoutToggle(_ action: FollowedForumsLayoutToggleAction) {
    guard let target = FollowedForumsLayoutPolicy.validatedToggleTarget(
      for: action,
      preferred: preferredLayout,
      dynamicTypeSize: dynamicTypeSize
    ) else { return }
    followedForumsLayout = target.rawValue
  }
}

struct FollowedForumsLayoutToggleButton: View {
  let action: FollowedForumsLayoutToggleAction
  let accessibilityIdentifier: String
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      Image(systemName: action.systemImage)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("关注贴吧布局")
    .accessibilityValue(action.accessibilityValue)
    .accessibilityHint(action.actionTitle)
    .help(action.actionTitle)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}
