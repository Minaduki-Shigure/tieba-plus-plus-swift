import Combine
import Foundation
import SwiftUI

struct UserRelationsView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var followingViewModel: UserRelationsViewModel
  @StateObject private var followersViewModel: UserRelationsViewModel
  @State private var selectedKind: UserRelationKind
  @State private var pendingFollow: UserRelationFollowPrompt?

  init(
    userID: Int64,
    initialKind: UserRelationKind,
    accountAccess: AccountAccess?,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _followingViewModel = StateObject(
      wrappedValue: UserRelationsViewModel(
        userID: userID,
        kind: .following,
        service: service,
        accountAccess: accountAccess
      )
    )
    _followersViewModel = StateObject(
      wrappedValue: UserRelationsViewModel(
        userID: userID,
        kind: .followers,
        service: service
      )
    )
    _selectedKind = State(initialValue: initialKind)
  }

  var body: some View {
    List {
      Section {
        Picker("用户关系", selection: $selectedKind) {
          ForEach(UserRelationKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("用户关系")
      }
      .listRowSeparator(.hidden)

      relationsSection(for: selectedViewModel)
    }
    .environment(\.defaultMinListRowHeight, 1)
    .listStyle(.plain)
    .appScrollableSurface()
    .navigationTitle("关注与粉丝")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await selectedViewModel.refresh() }
    .task(id: selectedKind) {
      selectedViewModel.loadIfNeeded()
    }
    .onDisappear {
      pendingFollow = nil
      followingViewModel.cancel()
      followersViewModel.cancel()
    }
    .onChange(of: selectedKind) { _ in pendingFollow = nil }
    .onChange(of: followingViewModel.users) { users in
      guard let pendingFollow else { return }
      guard users.contains(pendingFollow.user) else {
        self.pendingFollow = nil
        return
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      pendingFollow = nil
      followingViewModel.accountSessionDidChange(reloadIfActive: selectedKind == .following)
    }
    .onReceive(NotificationCenter.default.publisher(for: .userRelationshipDidChange)) {
      notification in
      guard let change = UserRelationshipChange(notification) else { return }
      if followingViewModel.userRelationshipDidChange(change) {
        pendingFollow = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in
        followingViewModel.reloadAfterContentFilterChange()
        followersViewModel.reloadAfterContentFilterChange()
      }
    }
    .confirmationDialog(
      pendingFollow?.targetFollowed == true ? "关注这名用户？" : "取消关注这名用户？",
      isPresented: Binding(
        get: { pendingFollow != nil },
        set: { if !$0 { pendingFollow = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let pendingFollow {
        if pendingFollow.targetFollowed {
          Button("关注") { confirmFollowChange(pendingFollow) }
        } else {
          Button("取消关注", role: .destructive) { confirmFollowChange(pendingFollow) }
        }
      }
      Button("取消", role: .cancel) { pendingFollow = nil }
    } message: {
      Text(
        "这会修改当前贴吧账户对“\(pendingFollow?.user.preferredName ?? "这名用户")”的关注状态。"
      )
    }
    .alert(
      "无法更新用户关注",
      isPresented: Binding(
        get: { followingViewModel.relationshipMutationError != nil },
        set: { if !$0 { followingViewModel.dismissRelationshipMutationError() } }
      )
    ) {
      Button("好", role: .cancel) { followingViewModel.dismissRelationshipMutationError() }
    } message: {
      Text(followingViewModel.relationshipMutationError ?? "无法完成用户关注操作。")
    }
  }

  private var selectedViewModel: UserRelationsViewModel {
    switch selectedKind {
    case .following:
      followingViewModel
    case .followers:
      followersViewModel
    }
  }

  @ViewBuilder
  private func relationsSection(for viewModel: UserRelationsViewModel) -> some View {
    Section {
      if viewModel.canSelectFollowingFilter {
        followingFilterMenu(viewModel)
      }
      switch viewModel.state {
      case .idle, .loading:
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.reload)
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      case .loaded:
        loadedRelations(viewModel)
      }
    } header: {
      HStack {
        Text(viewModel.kind.title)
        Spacer(minLength: 8)
        if viewModel.state == .loaded {
          Text(max(viewModel.totalCount, 0).formatted())
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      let notice = viewModel.notice.trimmingCharacters(in: .whitespacesAndNewlines)
      if !notice.isEmpty {
        Text(notice)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private func loadedRelations(_ viewModel: UserRelationsViewModel) -> some View {
    switch viewModel.emptyPresentation {
    case .none:
      ForEach(viewModel.displayableUsers) { user in
        LocallyFilteredContent(
          visibility: user.localVisibility,
          placeholder: "已屏蔽此用户"
        ) {
          HStack(spacing: 6) {
            NavigationLink {
              UserProfileView(
                userID: user.id,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              UserRelationRow(user: user)
            }
            .buttonStyle(.plain)

            followControl(for: user, viewModel: viewModel)
          }
        }
        .frame(minHeight: 44)
      }
    case .noRelations:
      EmptyStateView(
        title: viewModel.kind == .following ? "暂无关注" : "暂无粉丝",
        systemImage: "person.2.slash"
      )
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    case .locallyFiltered:
      Label("暂无可显示的用户", systemImage: "eye.slash")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    case .searchingMutual:
      Label("正在查找互相关注", systemImage: "person.2")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    case .mutualScanPaused:
      mutualScanContinuationButton(viewModel)
    case .noMutual:
      EmptyStateView(title: "暂无互相关注", systemImage: "person.2.slash")
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    if viewModel.mutualScanIsPaused && viewModel.hasDisplayableUsers {
      mutualScanContinuationButton(viewModel)
    }

    if let rawTail = viewModel.users.last {
      Color.clear
        .frame(height: 1)
        .id(
          "user-relations-\(viewModel.kind.rawValue)-pagination-"
            + "\(rawTail.id)-\(viewModel.users.count)-\(viewModel.paginationEpoch)"
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .accessibilityHidden(true)
        .onAppear { viewModel.loadMoreIfNeeded(current: rawTail) }
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

  private func followingFilterMenu(_ viewModel: UserRelationsViewModel) -> some View {
    Menu {
      ForEach(UserRelationFollowingFilter.allCases) { filter in
        Button {
          viewModel.selectFollowingFilter(filter)
        } label: {
          if viewModel.followingFilter == filter {
            Label(filter.title, systemImage: "checkmark")
          } else {
            Text(filter.title)
          }
        }
      }
    } label: {
      HStack(spacing: 8) {
        Text(viewModel.followingFilter.title)
        Spacer(minLength: 8)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isLoadingMore)
    .listRowSeparator(.hidden)
    .accessibilityLabel("关注列表筛选")
    .accessibilityValue(viewModel.followingFilter.title)
  }

  private func mutualScanContinuationButton(_ viewModel: UserRelationsViewModel) -> some View {
    Button {
      viewModel.continueMutualScan()
    } label: {
      Label("继续查找互相关注", systemImage: "arrow.down.circle")
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
    .buttonStyle(.borderless)
    .listRowSeparator(.hidden)
    .accessibilityHint("继续加载后续关注列表")
  }

  @ViewBuilder
  private func followControl(
    for user: BrowseRelatedUser,
    viewModel: UserRelationsViewModel
  ) -> some View {
    switch viewModel.followControlState(for: user) {
    case .hidden:
      EmptyView()
    case .followed(let isEnabled):
      Button {
        pendingFollow = viewModel.followPrompt(for: user)
      } label: {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(!isEnabled)
      .opacity(isEnabled ? 1 : 0.45)
      .accessibilityLabel("取消关注用户")
      .accessibilityValue(isEnabled ? "已关注" : "已关注，需要刷新后才能更改")
      .help("取消关注用户")
    case .notFollowed(let isEnabled):
      Button {
        pendingFollow = viewModel.followPrompt(for: user)
      } label: {
        Image(systemName: "person.badge.plus")
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(!isEnabled)
      .opacity(isEnabled ? 1 : 0.45)
      .accessibilityLabel("关注用户")
      .accessibilityValue(isEnabled ? "未关注" : "未关注，需要刷新后才能更改")
      .help("关注用户")
    case .mutating(let targetFollowed):
      ProgressView()
        .controlSize(.small)
        .frame(width: 44, height: 44)
        .accessibilityLabel(targetFollowed ? "正在关注用户" : "正在取消关注用户")
    }
  }

  private func confirmFollowChange(_ prompt: UserRelationFollowPrompt) {
    pendingFollow = nil
    followingViewModel.setFollowed(prompt)
  }
}

private struct UserRelationRow: View {
  let user: BrowseRelatedUser
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  private var displayedName: String {
    UserNameFormatter.displayName(
      preferredName: user.displayName,
      username: user.username,
      showsBoth: showsBothNames
    )
  }

  private var legacyUsername: String? {
    guard !showsBothNames else { return nil }
    let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty, username != displayedName else { return nil }
    return username
  }

  private var introduction: String {
    let value = user.introduction.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "暂无简介" : value
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: user.portraitURL, name: displayedName, size: 46)

      VStack(alignment: .leading, spacing: 4) {
        Text(displayedName)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(showsBothNames ? 3 : 2)
          .minimumScaleFactor(0.75)
          .accessibilityLabel(displayedName)

        if let legacyUsername {
          Text(legacyUsername)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Text(introduction)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
