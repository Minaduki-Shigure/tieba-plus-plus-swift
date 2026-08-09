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
  @StateObject private var viewModel: AccountViewModel
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
      unreadSummaryViewModel.loadIfNeeded()
      await viewModel.loadIfNeeded()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      unreadSummaryViewModel.accountSessionDidChange()
    }
    .onDisappear(perform: unreadSummaryViewModel.cancel)
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
            .disabled(viewModel.isMutating)
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
              Label("我的公开主页", systemImage: "person.crop.circle")
            }
            .disabled(viewModel.isMutating)

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

            NavigationLink {
              NotificationsView(
                browseService: browseService,
                accountService: accountService,
                vault: vault,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              messageNavigationLabel
            }

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
      await unreadSummaryViewModel.refresh()
    }
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
