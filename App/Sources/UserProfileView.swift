import Combine
import SwiftUI
import UIKit

struct UserProfileView: View {
  @Environment(\.contentFilterRepository) private var contentFilterRepository
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: UserProfileViewModel
  @State private var contentFilterMessage: String?

  init(
    userID: Int64,
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
    _viewModel = StateObject(
      wrappedValue: UserProfileViewModel(userID: userID, service: service)
    )
  }

  var body: some View {
    Group {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.reload)
      case .loaded:
        profileList
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let profile = viewModel.profile, profile.id > 0 {
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button {
              addUserRule(profile, to: .block)
            } label: {
              Label("加入屏蔽列表", systemImage: "hand.raised")
            }
            Button {
              addUserRule(profile, to: .allow)
            } label: {
              Label("加入白名单", systemImage: "checkmark.shield")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("用户规则")
          .help("用户规则")
        }
      }
    }
    .alert(
      "本地用户规则",
      isPresented: Binding(
        get: { contentFilterMessage != nil },
        set: { if !$0 { contentFilterMessage = nil } }
      )
    ) {
      Button("好") { contentFilterMessage = nil }
    } message: {
      Text(contentFilterMessage ?? "")
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in viewModel.reloadThreadsAfterContentFilterChange() }
    }
  }

  private var navigationTitle: String {
    guard let profile = viewModel.profile else { return "用户主页" }
    return UserNameFormatter.displayName(
      preferredName: profile.displayName,
      username: profile.username,
      showsBoth: showsBothNames
    )
  }

  private var profileList: some View {
    List {
      if let profile = viewModel.profile {
        UserProfileHeader(profile: profile)
          .listRowSeparator(.hidden)

        likedForumPreview(profile)
      }

      Section {
        if viewModel.isActivityHidden {
          Label("该用户未公开主题", systemImage: "eye.slash")
            .foregroundStyle(.secondary)
        } else if viewModel.threads.isEmpty {
          Label("暂无公开主题", systemImage: "text.bubble")
            .foregroundStyle(.secondary)
        } else if !viewModel.hasDisplayableThreads {
          Label("暂无可显示的公开主题", systemImage: "eye.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        } else {
          ForEach(viewModel.displayableThreads) { thread in
            LocallyFilteredContent(
              visibility: thread.localVisibility,
              placeholder: "已屏蔽此公开主题"
            ) {
              NavigationLink {
                ThreadView(
                  thread: thread,
                  service: service,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository
                )
              } label: {
                UserActivityThreadRow(thread: thread)
              }
            }
            .frame(minHeight: 44)
          }
        }

        if !viewModel.isActivityHidden, let lastThread = viewModel.threads.last {
          Color.clear
            .frame(height: 1)
            .id(
              "user-profile-thread-pagination-\(lastThread.id)-\(viewModel.threads.count)-\(viewModel.threadPaginationEpoch)"
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear { viewModel.loadMoreIfNeeded(current: lastThread) }
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
      } header: {
        if let profile = viewModel.profile {
          Text("公开主题 \(profile.threadCount.formatted())")
        } else {
          Text("公开主题")
        }
      }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private func addUserRule(_ profile: BrowseUserProfile, to list: ContentFilterList) {
    let repository = contentFilterRepository
    Task { @MainActor in
      do {
        _ = try await repository.add(
          .user(
            id: profile.id,
            name: profile.preferredName,
            list: list
          )
        )
        contentFilterMessage = list == .block ? "已加入屏蔽列表。" : "已加入白名单。"
      } catch {
        contentFilterMessage = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private func likedForumPreview(_ profile: BrowseUserProfile) -> some View {
    let totalCount = max(profile.followedForumCount, profile.likedForums.count)
    if totalCount > 0 {
      Section {
        if profile.likedForums.isEmpty {
          Label("公开资料未提供贴吧预览", systemImage: "eye.slash")
            .foregroundStyle(.secondary)
        } else {
          ForEach(profile.likedForums) { forum in
            NavigationLink {
              ForumView(
                forumName: forum.name,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              Label("\(forum.name)吧", systemImage: "text.bubble")
                .foregroundStyle(.primary)
            }
          }
        }
      } header: {
        Text("喜欢的吧 \(totalCount.formatted())")
      } footer: {
        if profile.likedForums.isEmpty {
          Text("该用户共喜欢 \(totalCount.formatted()) 个吧，公开资料未提供可浏览的预览。")
        } else {
          Text(
            "公开资料提供了 \(profile.likedForums.count.formatted()) 个预览；该用户共喜欢 \(totalCount.formatted()) 个吧。"
          )
        }
      }
    }
  }
}

private struct UserProfileHeader: View {
  let profile: BrowseUserProfile
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  private var displayedName: String {
    UserNameFormatter.displayName(
      preferredName: profile.displayName,
      username: profile.username,
      showsBoth: showsBothNames
    )
  }

  private var legacyUsername: String? {
    guard !showsBothNames else { return nil }
    let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty, username != displayedName else { return nil }
    return username
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 14) {
        AvatarView(url: profile.portraitURL, name: displayedName, size: 82)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(displayedName)
              .font(.title3.weight(.bold))
              .lineLimit(showsBothNames ? 3 : 2)
              .minimumScaleFactor(0.75)
              .layoutPriority(1)
              .accessibilityLabel(displayedName)
            if profile.isVerifiedCreator {
              Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("创作者认证")
            }
          }
          if let legacyUsername {
            Text(legacyUsername)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          HStack(spacing: 8) {
            if profile.isVIP {
              Label("会员", systemImage: "crown.fill")
            }
            if profile.isModerator {
              Label("吧务", systemImage: "checkmark.shield")
            }
            if profile.isBlocked {
              Label("账号受限", systemImage: "exclamationmark.shield")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 0) {
        stat(title: "关注", value: Int64(profile.followingCount))
        Divider().frame(height: 30)
        stat(title: "粉丝", value: Int64(profile.followerCount))
        Divider().frame(height: 30)
        stat(title: "获赞", value: profile.totalAgreeCount)
      }

      Text(profile.biography.isEmpty ? "这个用户还没有填写简介" : profile.biography)
        .font(.subheadline)
        .foregroundColor(profile.biography.isEmpty ? Color.secondary : Color.primary)
        .fixedSize(horizontal: false, vertical: true)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
        alignment: .leading,
        spacing: 8
      ) {
        profileDetails
      }

      if !profile.badges.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(Array(profile.badges.enumerated()), id: \.offset) { _, badge in
              Label(badge, systemImage: "seal")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var profileDetails: some View {
    if profile.growthLevel > 0 {
      Label("成长等级 \(profile.growthLevel)", systemImage: "chart.line.uptrend.xyaxis")
    }
    if !profile.tiebaAge.isEmpty {
      Label("吧龄 \(profile.tiebaAge) 年", systemImage: "calendar")
    }
    if !profile.ipLocation.isEmpty {
      Label(profile.ipLocation, systemImage: "location")
    }
    switch profile.gender {
    case .male:
      Label("男", systemImage: "person")
    case .female:
      Label("女", systemImage: "person")
    case .unknown:
      EmptyView()
    }
    HStack(spacing: 5) {
      Text("用户 ID \(profile.id)")
      Button {
        UIPasteboard.general.string = String(profile.id)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("复制用户 ID")
      .help("复制用户 ID")
    }
    if let tiebaUID = profile.tiebaUID {
      Text("主页 UID \(tiebaUID)")
    }
  }

  private func stat(title: String, value: Int64) -> some View {
    VStack(spacing: 2) {
      Text(max(value, 0).formatted())
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct UserActivityThreadRow: View {
  let thread: BrowseThread

  var body: some View {
    ThreadSummaryRow(thread: thread, showsForum: true, showsAuthor: false)
  }
}
