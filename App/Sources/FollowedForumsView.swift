import Foundation
import SwiftUI

struct FollowedForumsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @State private var surfaceID = UUID()
  @State private var pendingUnfollow: FollowedForumUnfollowPrompt?
  @EnvironmentObject private var viewModel: FollowedForumsViewModel
  @EnvironmentObject private var followedForumCheckInStore: FollowedForumCheckInStore
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
      viewModel.presentedOperationError?.title ?? "无法更新关注的贴吧",
      isPresented: Binding(
        get: {
          viewModel.presentedOperationError != nil
            && viewModel.canPresentOperationError(onFullList: surfaceID)
        },
        set: {
          if !$0, viewModel.canPresentOperationError(onFullList: surfaceID) {
            viewModel.dismissPresentedOperationError()
          }
        }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(viewModel.presentedOperationError?.message ?? "未知错误")
    }
    .confirmationDialog(
      pendingUnfollow.map { "取消关注 \($0.forum.name)吧？" } ?? "取消关注贴吧？",
      isPresented: Binding(
        get: { pendingUnfollow != nil },
        set: { if !$0 { pendingUnfollow = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let prompt = pendingUnfollow {
        Button("取消关注", role: .destructive) {
          pendingUnfollow = nil
          viewModel.unfollow(prompt)
        }
      }
      Button("取消", role: .cancel) { pendingUnfollow = nil }
    } message: {
      Text("这会修改当前贴吧账户的关注列表。")
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
    .onAppear {
      viewModel.fullListSurfaceDidAppear(id: surfaceID)
      if scenePhase == .active {
        followedForumCheckInStore.loadIfNeeded()
      }
    }
    .onDisappear {
      pendingUnfollow = nil
      viewModel.fullListSurfaceDidDisappear(id: surfaceID)
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      pendingUnfollow = nil
    }
    .onChange(of: viewModel.forums) { forums in
      guard let pendingUnfollow else { return }
      let normalizedName = FollowedForumPin.normalizedForumName(pendingUnfollow.forum.name)
      guard forums.contains(where: {
        $0.id == pendingUnfollow.forum.id
          && FollowedForumPin.normalizedForumName($0.name) == normalizedName
      }) else {
        self.pendingUnfollow = nil
        return
      }
    }
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
    .refreshable {
      async let forums: Void = viewModel.refresh()
      async let checkIns: Void = followedForumCheckInStore.refresh()
      _ = await (forums, checkIns)
    }
  }

  private func forumGrid(_ forums: [FollowedForumItem], isPinned: Bool) -> some View {
    LazyVGrid(
      columns: FollowedForumsLayoutPolicy.columns(
        preferred: preferredLayout,
        dynamicTypeSize: dynamicTypeSize,
        horizontalSizeClass: horizontalSizeClass
      ),
      alignment: .leading,
      spacing: FollowedForumsLayoutPolicy.spacing
    ) {
      ForEach(forums) { forum in
        let unfollowState = viewModel.unfollowControlState(for: forum)
        NavigationLink {
          ForumView(
            forumName: forum.name,
            service: browseService,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        } label: {
          FollowedForumCard(
            forum: forum,
            isPinned: isPinned,
            isUnfollowing: unfollowState == .busy,
            isCheckedInToday: followedForumCheckInStore.isCheckedInToday(
              forum,
              forumLease: viewModel.loadedSessionLease
            ),
            layout: cardLayout
          )
        }
        .buttonStyle(.plain)
        .followedForumContextMenu(
          forum: forum,
          isPinned: isPinned,
          unfollowState: unfollowState,
          setPinned: { viewModel.setPinned(forum, isPinned: $0) },
          requestUnfollow: { pendingUnfollow = viewModel.unfollowPrompt(for: forum) }
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

  private var cardLayout: FollowedForumCardLayout {
    FollowedForumsLayoutPolicy.cardLayout(
      preferred: preferredLayout,
      dynamicTypeSize: dynamicTypeSize
    )
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
