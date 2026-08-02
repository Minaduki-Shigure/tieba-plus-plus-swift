import SwiftUI

struct AccountView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: AccountViewModel
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
    .task { await viewModel.loadIfNeeded() }
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

        if viewModel.activeAccount != nil {
          Section {
            NavigationLink {
              FollowedForumsView(
                browseService: browseService,
                accountService: accountService,
                vault: vault,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              Label("我的关注", systemImage: "star")
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
    .refreshable { await viewModel.reload() }
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
