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

  init(
    userID: Int64,
    initialKind: UserRelationKind,
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
        service: service
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
    .navigationTitle("关注与粉丝")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await selectedViewModel.refresh() }
    .task(id: selectedKind) { selectedViewModel.loadIfNeeded() }
    .onDisappear {
      followingViewModel.cancel()
      followersViewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in
        followingViewModel.reloadAfterContentFilterChange()
        followersViewModel.reloadAfterContentFilterChange()
      }
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
    if viewModel.users.isEmpty {
      EmptyStateView(title: "暂无可显示", systemImage: "person.2.slash")
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    } else if !viewModel.hasDisplayableUsers {
      Label("暂无可显示的用户", systemImage: "eye.slash")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    } else {
      ForEach(viewModel.displayableUsers) { user in
        LocallyFilteredContent(
          visibility: user.localVisibility,
          placeholder: "已屏蔽此用户"
        ) {
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
        }
        .frame(minHeight: 44)
      }
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
