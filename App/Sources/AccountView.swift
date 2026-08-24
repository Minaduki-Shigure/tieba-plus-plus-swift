import SwiftUI

struct AccountView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @Environment(\.threadCloudFavoriteStore) private var threadCloudFavoriteStore
  @Environment(\.contentFilterRepository) private var contentFilterRepository
  @StateObject private var viewModel: AccountViewModel
  @StateObject private var profileSummaryViewModel: ActiveAccountProfileSummaryViewModel
  @StateObject private var unreadSummaryViewModel: InboxUnreadSummaryViewModel
  @State private var showsLogin = false
  @State private var confirmsLogout = false
  @State private var confirmsReset = false

  init(
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.accountService = accountService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(wrappedValue: AccountViewModel(vault: vault))
    _profileSummaryViewModel = StateObject(
      wrappedValue: ActiveAccountProfileSummaryViewModel(service: accountService, vault: vault)
    )
    _unreadSummaryViewModel = StateObject(
      wrappedValue: InboxUnreadSummaryViewModel(service: accountService, vault: vault)
    )
  }

  var body: some View {
    Group {
      if case .failed(let message) = viewModel.state {
        accountFailure(message: message)
      } else if viewModel.accounts.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed:
          EmptyView()
        case .loaded:
          accountList
        }
      } else {
        accountList
      }
    }
    .navigationTitle("账户")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button { showsLogin = true } label: {
          Image(systemName: "person.badge.plus")
        }
        .disabled(viewModel.isMutating || viewModel.hasLoadFailure)
        .accessibilityLabel("添加账户")
        .help("添加账户")
      }
    }
    .task {
      profileSummaryViewModel.loadIfNeeded()
      unreadSummaryViewModel.reload()
      await viewModel.loadIfNeeded()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      profileSummaryViewModel.accountSessionDidChange()
      unreadSummaryViewModel.accountSessionDidChange()
    }
    .onDisappear {
      profileSummaryViewModel.cancel()
      unreadSummaryViewModel.cancel()
    }
    .sheet(isPresented: $showsLogin) {
      NavigationStack {
        LoginView(service: accountService, vault: vault) {
          Task { await viewModel.reload() }
        }
      }
    }
    .confirmationDialog(
      "从本机移除当前账户？",
      isPresented: $confirmsLogout,
      titleVisibility: .visible
    ) {
      Button("从本机移除", role: .destructive) {
        Task { await viewModel.removeActiveAccount() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这只会删除本机保存的登录会话，不会使已签发的百度登录令牌失效。")
    }
    .confirmationDialog(
      "重置本地账户数据？",
      isPresented: $confirmsReset,
      titleVisibility: .visible
    ) {
      Button("重置账户数据", role: .destructive) {
        Task { await viewModel.resetLocalAccounts() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会删除本机保存的全部登录会话，不影响百度账户、浏览记录或本地收藏。")
    }
    .alert(
      "账户操作失败",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.clearError() }
    } message: {
      Text(viewModel.errorMessage ?? "无法完成账户操作。")
    }
  }

  private func accountFailure(message: String) -> some View {
    VStack(spacing: 16) {
      ErrorStateView(message: message) {
        Task { await viewModel.reload() }
      }
      Button(role: .destructive) { confirmsReset = true } label: {
        Label("重置本地账户数据", systemImage: "trash")
      }
      .disabled(viewModel.isMutating)
    }
  }

  private var accountList: some View {
    List {
      if viewModel.accounts.isEmpty {
        Section {
          Button { showsLogin = true } label: {
            Label("添加账户", systemImage: "person.badge.plus")
          }
        }
      } else {
        Section("已保存账户") {
          ForEach(viewModel.accounts) { account in
            Button {
              guard !account.isActive else { return }
              Task { await viewModel.switchAccount(to: account.id) }
            } label: {
              AccountRow(account: account)
            }
            .buttonStyle(.plain)
            .disabled(
              viewModel.isMutating
                || (!account.isActive && !viewModel.canSwitch(to: account.id))
            )
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await viewModel.remove(userID: account.id) }
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        }

        if let activeAccount = viewModel.activeAccount {
          Section("贴吧账户") {
            NavigationLink {
              UserProfileView(
                userID: activeAccount.id,
                showsUserFilterActions: false,
                service: browseService,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              ActiveAccountProfileSummaryRow(
                account: activeAccount,
                profile: activeProfileSummary,
                isLoading: profileSummaryViewModel.state == .loading
              )
            }
            .disabled(viewModel.isMutating)

            if let message = profileSummaryFailureMessage {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if activeAccount.hasFullCredentials {
                  Button {
                    profileSummaryViewModel.reload()
                  } label: {
                    Image(systemName: "arrow.clockwise")
                  }
                  .buttonStyle(.borderless)
                  .disabled(viewModel.isMutating)
                  .accessibilityLabel("重新读取本人资料")
                  .help("重新读取本人资料")
                } else {
                  Button { showsLogin = true } label: {
                    Label("重新登录", systemImage: "key")
                  }
                  .buttonStyle(.borderless)
                  .disabled(viewModel.isMutating)
                }
              }
            }

            NavigationLink {
              FollowedForumsView(
                browseService: browseService,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              Label("关注的贴吧", systemImage: "star")
            }

            if activeAccount.hasFullCredentials {
              NavigationLink {
                ForumBatchCheckInView(
                  access: AccountAccess(vault: vault, service: accountService)
                )
              } label: {
                Label("一键签到", systemImage: "checkmark.seal")
              }
              .disabled(viewModel.isMutating)
              .accessibilityHint("打开前台一键签到页面")
            }

            NavigationLink {
              NotificationsView(
                browseService: browseService,
                accountService: accountService,
                vault: vault,
                contentFilterRepository: contentFilterRepository,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              messageNavigationLabel
            }

            NavigationLink {
              UserRelationsView(
                userID: activeAccount.id,
                initialKind: .followers,
                service: browseService,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              fanReminderNavigationLabel
            }
            .disabled(viewModel.isMutating)
            .accessibilityHint("打开公开粉丝列表")

            if activeAccount.hasFullCredentials {
              NavigationLink {
                CloudFavoritesView(
                  browseService: browseService,
                  accountService: accountService,
                  vault: vault,
                  cloudFavoriteStore: threadCloudFavoriteStore,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository
                )
              } label: {
                Label("贴吧收藏（云端）", systemImage: "bookmark.circle")
              }
            } else {
              Button { showsLogin = true } label: {
                Label("重新登录以启用贴吧收藏", systemImage: "key")
              }
              .disabled(viewModel.isMutating)
            }

            Button(role: .destructive) { confirmsLogout = true } label: {
              Label("从本机移除账户", systemImage: "trash")
            }
            .disabled(viewModel.isMutating)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable {
      await viewModel.reload()
      await profileSummaryViewModel.refresh()
      await unreadSummaryViewModel.refresh()
    }
  }

  private var activeProfileSummary: AccountProfileSummary? {
    guard
      let activeUserID = viewModel.activeAccount?.id,
      let summary = profileSummaryViewModel.summary,
      summary.userID == activeUserID,
      [summary.followingCount, summary.followerCount, summary.postCount]
        .allSatisfy({ (0...Int(Int32.max)).contains($0) })
    else { return nil }
    return summary
  }

  private var profileSummaryFailureMessage: String? {
    if
      let activeUserID = viewModel.activeAccount?.id,
      let summary = profileSummaryViewModel.summary,
      summary.userID != activeUserID
    {
      return viewModel.isMutating ? nil : "账户状态已变化，请重新加载本人资料。"
    }
    if case .failed(let message) = profileSummaryViewModel.state {
      return message
    }
    return nil
  }

  private var unreadBadgePresentation: InboxUnreadBadgePresentation {
    guard
      let activeUserID = viewModel.activeAccount?.id,
      let summary = unreadSummaryViewModel.summary,
      let presentation = InboxUnreadBadgePresentation(
        summary: summary,
        activeUserID: activeUserID
      )
    else { return .empty }
    return presentation
  }

  private var hasUnreadSummaryAccountMismatch: Bool {
    guard
      let activeUserID = viewModel.activeAccount?.id,
      let summary = unreadSummaryViewModel.summary
    else { return false }
    return summary.userID != activeUserID
  }

  private var fanReminderPresentation: FanReminderPresentation? {
    guard
      let activeUserID = viewModel.activeAccount?.id,
      let summary = unreadSummaryViewModel.summary
    else { return nil }
    return FanReminderPresentation(summary: summary, activeUserID: activeUserID)
  }

  private var messageNavigationLabel: some View {
    let presentation = unreadBadgePresentation
    return HStack(spacing: 10) {
      Label("消息", systemImage: "bell")
      Spacer(minLength: 8)
      if let badgeText = presentation.badgeText {
        Text(badgeText)
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.white)
          .lineLimit(1)
          .padding(.horizontal, 7)
          .frame(minWidth: 24, minHeight: 20)
          .background(Color.red, in: Capsule())
          .accessibilityHidden(true)
      }
      if unreadSummaryViewModel.state == .loading
        || (hasUnreadSummaryAccountMismatch && viewModel.isMutating)
      {
        ProgressView()
          .controlSize(.small)
          .frame(minWidth: 24, minHeight: 20)
          .accessibilityHidden(true)
      } else if unreadSummaryViewModel.state.isFailed || hasUnreadSummaryAccountMismatch {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(minWidth: 24, minHeight: 20)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("消息")
    .accessibilityValue(messageAccessibilityValue)
  }

  private var messageAccessibilityValue: String {
    if hasUnreadSummaryAccountMismatch {
      return viewModel.isMutating ? "正在切换账户" : "账户状态已变化，请重新加载"
    }
    if unreadSummaryViewModel.state.isFailed {
      guard unreadSummaryViewModel.summary != nil else {
        return "未读回复和提及暂不可用"
      }
      return unreadBadgePresentation.accessibilityValue(refreshFailed: true)
    }
    switch unreadSummaryViewModel.state {
    case .loading:
      return unreadSummaryViewModel.summary == nil
        ? "正在读取未读回复和提及"
        : "\(unreadBadgePresentation.accessibilityValue)，正在更新"
    case .failed:
      return "未读回复和提及暂不可用"
    case .idle:
      return "未读回复和提及尚未读取"
    case .loaded:
      return unreadBadgePresentation.accessibilityValue
    }
  }

  private var fanReminderNavigationLabel: some View {
    let presentation = fanReminderPresentation
    return HStack(spacing: 10) {
      Label("粉丝提醒", systemImage: "person.2")
      Spacer(minLength: 8)
      if let badgeText = presentation?.badgeText {
        Text(badgeText)
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.white)
          .lineLimit(1)
          .padding(.horizontal, 7)
          .frame(minWidth: 24, minHeight: 20)
          .background(Color.red, in: Capsule())
          .accessibilityHidden(true)
      }
      if unreadSummaryViewModel.state == .loading
        || (hasUnreadSummaryAccountMismatch && viewModel.isMutating)
      {
        ProgressView()
          .controlSize(.small)
          .frame(minWidth: 24, minHeight: 20)
          .accessibilityHidden(true)
      } else if unreadSummaryViewModel.state.isFailed || hasUnreadSummaryAccountMismatch {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(minWidth: 24, minHeight: 20)
          .accessibilityHidden(true)
      } else if
        unreadSummaryViewModel.state == .loaded,
        presentation?.isUnavailable == true
      {
        Image(systemName: "questionmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(minWidth: 24, minHeight: 20)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("粉丝提醒")
    .accessibilityValue(fanReminderAccessibilityValue)
  }

  private var fanReminderAccessibilityValue: String {
    if hasUnreadSummaryAccountMismatch {
      return viewModel.isMutating ? "正在切换账户" : "账户状态已变化，请重新加载"
    }
    if unreadSummaryViewModel.state.isFailed {
      guard let presentation = fanReminderPresentation else {
        return "粉丝提醒暂不可用"
      }
      return presentation.accessibilityValue(refreshFailed: true)
    }
    switch unreadSummaryViewModel.state {
    case .loading:
      guard let presentation = fanReminderPresentation else {
        return "正在读取粉丝提醒"
      }
      return "\(presentation.accessibilityValue)，正在更新"
    case .failed:
      return "粉丝提醒暂不可用"
    case .idle:
      return "粉丝提醒尚未读取"
    case .loaded:
      return fanReminderPresentation?.accessibilityValue ?? "服务端未提供粉丝提醒计数"
    }
  }
}

struct InboxUnreadBadgePresentation: Equatable, Sendable {
  static let empty = InboxUnreadBadgePresentation(replyCount: 0, mentionCount: 0)

  let count: Int

  init(summary: InboxUnreadSummary) {
    self.init(replyCount: summary.replyCount, mentionCount: summary.mentionCount)
  }

  init?(summary: InboxUnreadSummary, activeUserID: Int64) {
    guard summary.userID == activeUserID else { return nil }
    self.init(summary: summary)
  }

  init(replyCount: Int, mentionCount: Int) {
    let replyCount = max(replyCount, 0)
    let mentionCount = max(mentionCount, 0)
    let sum = replyCount.addingReportingOverflow(mentionCount)
    count = sum.overflow ? Int.max : sum.partialValue
  }

  var badgeText: String? {
    guard count > 0 else { return nil }
    return count > 99 ? "99+" : String(count)
  }

  var accessibilityValue: String {
    count == 0 ? "没有未读回复或提及" : "\(count) 条未读回复或提及"
  }

  func accessibilityValue(refreshFailed: Bool) -> String {
    refreshFailed ? "\(accessibilityValue)，当前更新失败" : accessibilityValue
  }
}

struct FanReminderPresentation: Equatable, Sendable {
  let count: Int?

  init(summary: InboxUnreadSummary) {
    count = summary.fanCount.map { max($0, 0) }
  }

  init?(summary: InboxUnreadSummary, activeUserID: Int64) {
    guard summary.userID == activeUserID else { return nil }
    self.init(summary: summary)
  }

  init(count: Int) {
    self.count = max(count, 0)
  }

  var badgeText: String? {
    guard let count, count > 0 else { return nil }
    return count > 99 ? "99+" : String(count)
  }

  var isUnavailable: Bool { count == nil }

  var accessibilityValue: String {
    guard let count else { return "服务端未提供粉丝提醒计数" }
    return count == 0 ? "没有粉丝提醒" : "\(count) 条粉丝提醒"
  }

  func accessibilityValue(refreshFailed: Bool) -> String {
    refreshFailed ? "\(accessibilityValue)，当前更新失败" : accessibilityValue
  }
}

private extension LoadState {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

private struct AccountRow: View {
  let account: AccountSummary

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(url: account.portraitURL, name: account.preferredName, size: 44)
      VStack(alignment: .leading, spacing: 3) {
        Text(account.preferredName)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text("用户 ID \(account.id)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if account.isActive {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .accessibilityLabel("当前账户")
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 2)
  }
}

private struct ActiveAccountProfileSummaryRow: View {
  let account: AccountSummary
  let profile: AccountProfileSummary?
  let isLoading: Bool

  private var name: String { profile?.preferredName ?? account.preferredName }
  private var avatarURL: URL? { profile?.portraitURL ?? account.portraitURL }
  private var biography: String {
    guard let profile else { return "用户 ID \(account.id)" }
    return profile.biography.isEmpty ? "暂未填写简介" : profile.biography
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        AvatarView(url: avatarURL, name: name, size: 56)
        VStack(alignment: .leading, spacing: 5) {
          Text(name)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
          Text(biography)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        }
      }

      if let profile {
        HStack(spacing: 0) {
          ProfileStatistic(title: "关注", value: profile.followingCount)
          ProfileStatistic(title: "粉丝", value: profile.followerCount)
          ProfileStatistic(title: "回贴", value: profile.postCount)
        }
        .frame(minHeight: 38)
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(name)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let profile else {
      return isLoading ? "用户 ID \(account.id)，正在读取本人资料" : "用户 ID \(account.id)"
    }
    let intro = profile.biography.isEmpty ? "暂未填写简介" : profile.biography
    return "\(intro)，关注 \(profile.followingCount)，粉丝 \(profile.followerCount)，回贴 \(profile.postCount)"
  }
}

private struct ProfileStatistic: View {
  let title: String
  let value: Int

  var body: some View {
    VStack(spacing: 2) {
      Text(max(value, 0).formatted(.number.notation(.compactName)))
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }
}
