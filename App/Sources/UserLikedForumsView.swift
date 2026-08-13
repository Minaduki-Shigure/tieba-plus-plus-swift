import Combine
import Foundation
import SwiftUI

struct UserLikedForumsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: UserLikedForumsViewModel

  init(
    targetUserID: Int64,
    accountAccess: AccountAccess,
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
    _viewModel = StateObject(
      wrappedValue: UserLikedForumsViewModel(
        targetUserID: targetUserID,
        service: accountAccess.service,
        vault: accountAccess.vault
      )
    )
  }

  var body: some View {
    Group {
      if viewModel.forums.isEmpty {
        emptyContent
      } else {
        forumList
      }
    }
    .navigationTitle("喜欢的吧")
    .navigationBarTitleDisplayMode(.inline)
    .task { viewModel.loadIfNeeded() }
    .onDisappear { viewModel.cancel() }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      viewModel.accountSessionDidChange()
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch viewModel.state {
    case .idle, .loading:
      ProgressView()
    case .failed(let message):
      if viewModel.isSignedOut {
        signedOutView
      } else {
        ErrorStateView(message: message, retry: viewModel.reload)
      }
    case .loaded:
      List {
        EmptyStateView(title: "暂无可浏览的喜欢贴吧", systemImage: "star")
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .refreshable { await viewModel.refresh() }
    }
  }

  private var signedOutView: some View {
    VStack(spacing: 14) {
      Image(systemName: "person.crop.circle.badge.exclamationmark")
        .font(.largeTitle)
      Text("请先登录账户")
        .font(.headline)
      Text("登录后可查看该用户完整的喜欢贴吧列表。")
        .font(.callout)
        .multilineTextAlignment(.center)
      Button(action: viewModel.reload) {
        Label("重新检查", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
    .foregroundStyle(.secondary)
    .padding(24)
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
          UserLikedForumRow(forum: forum)
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

private struct UserLikedForumRow: View {
  let forum: FollowedForumItem

  private var slogan: String {
    forum.slogan.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      AvatarView(
        url: ForumAvatarDisplayPolicy.displayURL(forum.avatarURL),
        name: forum.name,
        size: 44,
        urlPolicy: .forumAvatar
      )
      VStack(alignment: .leading, spacing: 4) {
        Text("\(forum.name)吧")
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
        if !slogan.isEmpty {
          Text(slogan)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}
