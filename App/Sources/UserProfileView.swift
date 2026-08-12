import Combine
import SwiftUI
import UIKit

struct UserProfilePortraitPresentation: Identifiable, Equatable, Sendable {
  let sourceURL: URL

  var id: URL { sourceURL }

  init?(
    largePortraitURL: URL?,
    fallbackPortraitURL: URL?
  ) {
    guard let sourceURL = largePortraitURL ?? fallbackPortraitURL else { return nil }
    self.sourceURL = sourceURL
  }

  init?(profile: BrowseUserProfile) {
    self.init(
      largePortraitURL: profile.largePortraitURL,
      fallbackPortraitURL: profile.portraitURL
    )
  }
}

struct UserLikedForumsPreviewPresentation: Equatable, Sendable {
  let reportedCount: Int
  let totalCount: Int
  let previewCount: Int
  let offersFullList: Bool

  init(
    reportedCount: Int,
    previewCount: Int,
    offersFullList: Bool
  ) {
    self.reportedCount = max(reportedCount, 0)
    self.previewCount = max(previewCount, 0)
    totalCount = max(self.reportedCount, self.previewCount)
    self.offersFullList = offersFullList
  }

  var showsSection: Bool {
    totalCount > 0 || offersFullList
  }

  var title: String {
    hasReliableReportedCount ? "喜欢的吧 \(reportedCount.formatted())" : "喜欢的吧"
  }

  var footer: String {
    if totalCount == 0 {
      return "公开资料未提供喜欢贴吧计数或可浏览预览；可通过完整列表继续读取。"
    }
    guard hasReliableReportedCount else {
      return "公开资料提供了 \(previewCount.formatted()) 个预览，但未提供可靠的完整数量。"
    }
    if previewCount == 0 {
      return "公开资料计数为 \(reportedCount.formatted()) 个吧，但未提供可浏览的预览。"
    }
    return "公开资料提供了 \(previewCount.formatted()) 个预览；资料计数为 \(reportedCount.formatted()) 个吧。"
  }

  private var hasReliableReportedCount: Bool {
    reportedCount > 0 && reportedCount >= previewCount
  }
}

private enum UserProfileActivity: String, CaseIterable, Hashable, Identifiable, Sendable {
  case threads
  case replies

  var id: Self { self }

  var title: String {
    switch self {
    case .threads: "主题"
    case .replies: "回复"
    }
  }
}

struct UserProfileView: View {
  @Environment(\.accountAccess) private var accountAccess
  @Environment(\.contentFilterRepository) private var contentFilterRepository
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let showsUserFilterActions: Bool

  @StateObject private var viewModel: UserProfileViewModel
  @StateObject private var repliesViewModel: UserRepliesViewModel
  @State private var selectedActivity: UserProfileActivity = .threads
  @State private var contentFilterMessage: String?
  @State private var portraitPresentation: UserProfilePortraitPresentation?
  @State private var relationKind: UserRelationKind?

  init(
    userID: Int64,
    showsUserFilterActions: Bool = true,
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
    self.showsUserFilterActions = showsUserFilterActions
    _viewModel = StateObject(
      wrappedValue: UserProfileViewModel(userID: userID, service: service)
    )
    _repliesViewModel = StateObject(
      wrappedValue: UserRepliesViewModel(userID: userID, service: service)
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
      if showsUserFilterActions, let profile = viewModel.profile, profile.id > 0 {
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
    .fullScreenCover(item: $portraitPresentation) { presentation in
      ImageViewer(url: presentation.sourceURL)
    }
    .navigationDestination(isPresented: relationsPresented) {
      if let relationKind {
        UserRelationsView(
          userID: viewModel.userID,
          initialKind: relationKind,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      }
    }
    .task { viewModel.loadIfNeeded() }
    .task(id: selectedActivity) {
      if selectedActivity == .replies {
        repliesViewModel.loadIfNeeded()
      }
    }
    .onDisappear {
      viewModel.cancel()
      repliesViewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in
        viewModel.reloadThreadsAfterContentFilterChange()
        repliesViewModel.reloadAfterContentFilterChange()
      }
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
        UserProfileHeader(
          profile: profile,
          accountAccess: accountAccess,
          onOpenPortrait: {
            portraitPresentation = UserProfilePortraitPresentation(profile: profile)
          },
          onOpenFollowing: { relationKind = .following },
          onOpenFollowers: { relationKind = .followers }
        )
          .listRowSeparator(.hidden)

        likedForumPreview(profile)
      }

      Section {
        Picker("公开动态", selection: $selectedActivity) {
          ForEach(UserProfileActivity.allCases) { activity in
            Text(activity.title).tag(activity)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("公开动态")
      }
      .listRowSeparator(.hidden)

      if selectedActivity == .threads {
        publicThreadsSection
      } else {
        publicRepliesSection
      }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .listStyle(.plain)
    .refreshable { await refresh() }
  }

  private var publicThreadsSection: some View {
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

  private var publicRepliesSection: some View {
    Section {
      switch repliesViewModel.state {
      case .idle, .loading:
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      case .failed(let message):
        ErrorStateView(message: message, retry: repliesViewModel.reload)
          .listRowSeparator(.hidden)
      case .loaded:
        if repliesViewModel.isActivityHidden {
          Label("该用户未公开回复", systemImage: "eye.slash")
            .foregroundStyle(.secondary)
        } else if repliesViewModel.replies.isEmpty {
          Label("暂无公开回复", systemImage: "text.bubble")
            .foregroundStyle(.secondary)
        } else if !repliesViewModel.hasDisplayableReplies {
          Label("暂无可显示的公开回复", systemImage: "eye.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        } else {
          ForEach(repliesViewModel.displayableReplies) { reply in
            LocallyFilteredContent(
              visibility: reply.localVisibility,
              placeholder: "已屏蔽此公开回复"
            ) {
              if let target = reply.navigationTarget {
                NavigationLink {
                  userReplyDestination(for: target)
                } label: {
                  UserActivityReplyRow(reply: reply)
                }
              } else {
                UserActivityReplyRow(reply: reply)
              }
            }
            .frame(minHeight: 44)
          }
        }

        if !repliesViewModel.isActivityHidden, let lastReply = repliesViewModel.replies.last {
          Color.clear
            .frame(height: 1)
            .id(
              "user-profile-reply-pagination-\(lastReply.id.threadID)-\(lastReply.id.postID)-\(repliesViewModel.replies.count)-\(repliesViewModel.paginationEpoch)"
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear { repliesViewModel.loadMoreIfNeeded(current: lastReply) }
        }

        if repliesViewModel.isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowSeparator(.hidden)
        } else if let message = repliesViewModel.loadMoreError {
          LoadMoreErrorView(message: message, retry: repliesViewModel.retryLoadMore)
            .listRowSeparator(.hidden)
        }
      }
    } header: {
      if let profile = viewModel.profile {
        Text("公开回复 \(profile.postCount.formatted())")
      } else {
        Text("公开回复")
      }
    }
  }

  @ViewBuilder
  private func userReplyDestination(for target: UserReplyNavigationTarget) -> some View {
    switch target {
    case .thread(let route):
      ThreadView(
        thread: route.placeholderThread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
    case .comment(let threadID, let commentID):
      CommentsView(
        threadID: threadID,
        resolvingCommentID: commentID,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        showsDismissButton: false
      )
    }
  }

  private func refresh() async {
    await viewModel.refresh()
    if selectedActivity == .replies {
      await repliesViewModel.refresh()
    }
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

  private var relationsPresented: Binding<Bool> {
    Binding(
      get: { relationKind != nil },
      set: { isPresented in
        if !isPresented {
          relationKind = nil
        }
      }
    )
  }

  @ViewBuilder
  private func likedForumPreview(_ profile: BrowseUserProfile) -> some View {
    let presentation = UserLikedForumsPreviewPresentation(
      reportedCount: profile.followedForumCount,
      previewCount: profile.likedForums.count,
      offersFullList: accountAccess != nil
    )
    if presentation.showsSection {
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

        if let accountAccess {
          NavigationLink {
            UserLikedForumsView(
              targetUserID: profile.id,
              accountAccess: accountAccess,
              browseService: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          } label: {
            Label("查看完整列表", systemImage: "list.bullet")
          }
        }
      } header: {
        Text(presentation.title)
      } footer: {
        Text(presentation.footer)
      }
    }
  }
}

private struct UserProfileHeader: View {
  let profile: BrowseUserProfile
  let accountAccess: AccountAccess?
  let onOpenPortrait: () -> Void
  let onOpenFollowing: () -> Void
  let onOpenFollowers: () -> Void
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
        profileAvatar
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
        Spacer(minLength: 8)
        if let accountAccess {
          UserRelationshipControl(
            targetUserID: profile.id,
            targetName: profile.preferredName,
            access: accountAccess
          )
        }
      }

      HStack(spacing: 0) {
        statButton(
          title: "关注",
          value: Int64(profile.followingCount),
          action: onOpenFollowing
        )
        Divider().frame(height: 30)
        statButton(
          title: "粉丝",
          value: Int64(profile.followerCount),
          action: onOpenFollowers
        )
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

  @ViewBuilder
  private var profileAvatar: some View {
    if profile.largePortraitURL != nil || profile.portraitURL != nil {
      Button(action: onOpenPortrait) {
        AvatarView(url: profile.portraitURL, name: displayedName, size: 82)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("查看\(displayedName)的头像")
      .help("查看头像")
    } else {
      AvatarView(url: nil, name: displayedName, size: 82)
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

  private func statButton(
    title: String,
    value: Int64,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      stat(title: title, value: value)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title) \(max(value, 0).formatted())")
    .help("查看\(title)列表")
  }
}

private struct UserRelationshipControl: View {
  @StateObject private var viewModel: UserRelationshipViewModel
  @State private var pendingFollowedState: Bool?
  private let targetName: String

  init(targetUserID: Int64, targetName: String, access: AccountAccess) {
    self.targetName = targetName
    _viewModel = StateObject(
      wrappedValue: UserRelationshipViewModel(
        targetUserID: targetUserID,
        access: access
      )
    )
  }

  var body: some View {
    control
      .task { await viewModel.loadIfNeeded() }
      .onDisappear {
        pendingFollowedState = nil
        viewModel.cancel()
      }
      .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
        pendingFollowedState = nil
        Task { @MainActor in await viewModel.accountSessionDidChange() }
      }
      .confirmationDialog(
        pendingFollowedState == true ? "关注这名用户？" : "取消关注这名用户？",
        isPresented: Binding(
          get: { pendingFollowedState != nil },
          set: { if !$0 { pendingFollowedState = nil } }
        ),
        titleVisibility: .visible
      ) {
        if pendingFollowedState == true {
          Button("关注") { confirmFollowedState(true) }
        } else if pendingFollowedState == false {
          Button("取消关注", role: .destructive) { confirmFollowedState(false) }
        }
        Button("取消", role: .cancel) { pendingFollowedState = nil }
      } message: {
        Text("这会修改当前贴吧账户对“\(targetName)”的关注状态。")
      }
      .alert(
        "无法更新用户关注",
        isPresented: Binding(
          get: { viewModel.errorMessage != nil },
          set: { if !$0 { viewModel.dismissError() } }
        )
      ) {
        Button("好", role: .cancel) { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage ?? "无法完成用户关注操作。")
      }
  }

  @ViewBuilder
  private var control: some View {
    switch viewModel.state {
    case .idle, .hidden, .signedOut:
      EmptyView()
    case .loading, .mutating:
      ProgressView()
        .controlSize(.small)
        .frame(width: 44, height: 44)
        .accessibilityLabel("正在更新用户关注")
    case .ready(let isFollowed):
      if isFollowed {
        Button {
          pendingFollowedState = false
        } label: {
          Label("已关注", systemImage: "person.crop.circle.badge.checkmark")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("取消关注用户")
      } else {
        Button {
          pendingFollowedState = true
        } label: {
          Label("关注", systemImage: "person.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("关注用户")
      }
    case .failed:
      Button {
        Task { @MainActor in await viewModel.reload() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("重试读取用户关注状态")
      .help("重试读取用户关注状态")
    }
  }

  private func confirmFollowedState(_ isFollowed: Bool) {
    pendingFollowedState = nil
    Task { @MainActor in await viewModel.setFollowed(isFollowed) }
  }
}

private struct UserActivityThreadRow: View {
  let thread: BrowseThread

  var body: some View {
    ThreadSummaryRow(thread: thread, showsForum: true, showsAuthor: false)
  }
}

private struct UserActivityReplyRow: View {
  let reply: BrowseUserReply

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if !reply.forumName.isEmpty {
          Text("\(reply.forumName)吧")
            .font(.caption)
            .foregroundStyle(.tint)
            .lineLimit(1)
        }
        Text(targetLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if let createdAt = reply.createdAt {
          Text(createdAt, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Text(reply.excerpt.isEmpty ? "（非文字回复）" : reply.excerpt)
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(4)

      if !reply.threadTitle.isEmpty {
        Text(reply.threadTitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private var targetLabel: String {
    switch reply.target {
    case .post:
      "楼层"
    case .comment:
      "楼中楼"
    case .unsupported:
      "暂不支持定位"
    }
  }
}
