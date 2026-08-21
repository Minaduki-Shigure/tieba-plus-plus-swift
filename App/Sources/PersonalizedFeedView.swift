import Combine
import SwiftUI

struct PersonalizedFeedView: View {
  let isActive: Bool
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let feedbackService: any PersonalizedFeedbackService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: PersonalizedFeedViewModel
  @State private var completeIndexSurfaceID = UUID()
  @State private var showsLogin = false
  @State private var feedbackPrompt: PersonalizedFeedbackPrompt?
  @EnvironmentObject private var followedForumsViewModel: FollowedForumsViewModel
  @AppStorage(AppPreferenceKey.personalizedFollowedForumsOnly)
  private var followedForumsOnly = AppPreferenceDefaults.personalizedFollowedForumsOnly

  init(
    isActive: Bool,
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    accountService: any AccountService,
    feedbackService: any PersonalizedFeedbackService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.isActive = isActive
    self.service = service
    self.accountService = accountService
    self.feedbackService = feedbackService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: PersonalizedFeedViewModel(
        service: service,
        feedbackService: feedbackService,
        vault: vault
      )
    )
  }

  var body: some View {
    Group {
      if followedForumsOnly {
        followedForumsOnlyContent
      } else {
        feedContent
      }
    }
    .onAppear(perform: synchronizeActivation)
    .onChange(of: isActive) { _ in synchronizeActivation() }
    .onChange(of: followedForumsOnly) { _ in synchronizeActivation() }
    .onChange(of: followedForumsViewModel.indexState) { _ in synchronizeScope() }
    .onDisappear {
      followedForumsViewModel.completeIndexSurfaceDidDisappear(id: completeIndexSurfaceID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      if isActive { viewModel.reloadForContentFilterChange() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      feedbackPrompt = nil
      viewModel.accountSessionDidChange(
        reloadIfActive: isActive && !followedForumsOnly
      )
    }
    .sheet(isPresented: $showsLogin) {
      NavigationStack {
        LoginView(service: accountService, vault: vault) {}
      }
    }
    .sheet(item: $feedbackPrompt) { prompt in
      PersonalizedFeedbackSelectionView(prompt: prompt) { reasonIDs in
        viewModel.submitFeedback(
          threadID: prompt.id,
          selectedReasonIDs: reasonIDs,
          clickTimeMilliseconds: prompt.clickTimeMilliseconds
        )
      }
    }
    .alert(
      "刷新失败",
      isPresented: Binding(
        get: { viewModel.refreshError != nil },
        set: { if !$0 { viewModel.clearRefreshError() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.clearRefreshError() }
    } message: {
      Text(viewModel.refreshError ?? "无法刷新推荐内容。")
    }
  }

  @ViewBuilder
  private var followedForumsOnlyContent: some View {
    switch followedForumsViewModel.indexState {
    case .idle, .loading, .partial:
      ProgressView()
    case .signedOut:
      accountState
    case .failed(let message):
      ErrorStateView(message: message, retry: followedForumsViewModel.retryCompleteIndex)
    case .ready(let snapshot):
      if snapshot.forumIDs.isEmpty {
        EmptyStateView(title: "当前账户暂无关注贴吧", systemImage: "star")
      } else {
        feedContent
      }
    }
  }

  @ViewBuilder
  private var feedContent: some View {
    if viewModel.state == .loaded {
      feedList
    } else {
      initialState
    }
  }

  @ViewBuilder
  private var initialState: some View {
    switch viewModel.state {
    case .idle, .loading:
      ProgressView()
    case .failed(let message):
      ErrorStateView(message: message, retry: viewModel.retry)
    case .loaded:
      EmptyStateView(title: emptyTitle, systemImage: "sparkles")
    }
  }

  private var accountState: some View {
    VStack(spacing: 12) {
      EmptyStateView(
        title: "请先登录账户",
        systemImage: "person.crop.circle.badge.exclamationmark"
      )
      Button {
        showsLogin = true
      } label: {
        Label("登录账户", systemImage: "person.badge.key")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var emptyTitle: String {
    followedForumsOnly ? "暂无来自已关注贴吧的推荐" : "暂无推荐内容"
  }

  private var feedList: some View {
    List {
      if viewModel.items.isEmpty {
        EmptyStateView(title: emptyTitle, systemImage: "sparkles")
          .frame(maxWidth: .infinity, minHeight: 240)
          .listRowSeparator(.hidden)
        if viewModel.hasMore, viewModel.loadMoreError == nil {
          Button {
            guard isActive else { return }
            viewModel.loadMore()
          } label: {
            Label("继续加载", systemImage: "arrow.down.circle")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderless)
          .disabled(viewModel.isLoadingMore || viewModel.loadMoreError != nil)
          .listRowSeparator(.hidden)
        }
      } else {
        ForEach(viewModel.items) { item in
          LocallyFilteredContent(
            visibility: item.thread.localVisibility,
            placeholder: "已屏蔽此推荐帖子"
          ) {
            HStack(spacing: 8) {
              NavigationLink {
                ThreadView(
                  thread: item.thread,
                  service: service,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository
                )
              } label: {
                ThreadSummaryRow(thread: item.thread, showsForum: true)
              }

              if !item.feedbackReasons.isEmpty {
                feedbackButton(for: item)
              }
            }
          }
          .onAppear {
            guard isActive else { return }
            viewModel.loadMoreIfNeeded(currentItemID: item.id)
          }
        }
      }

      if viewModel.isLoadingMore {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      } else if let loadMoreError = viewModel.loadMoreError {
        LoadMoreErrorView(message: loadMoreError, retry: viewModel.retryLoadMore)
          .listRowSeparator(.hidden)
      } else if viewModel.hasMore, !viewModel.items.isEmpty {
        Color.clear
          .frame(height: 1)
          .listRowSeparator(.hidden)
          .accessibilityHidden(true)
          .onAppear {
            guard isActive else { return }
            viewModel.loadMore()
          }
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
    .alert(
      viewModel.feedbackFailure?.title ?? "反馈提交失败",
      isPresented: Binding(
        get: { viewModel.feedbackFailure != nil },
        set: { if !$0 { viewModel.clearFeedbackFailure() } }
      )
    ) {
      if viewModel.feedbackFailure?.offersLogin == true {
        Button("登录") {
          viewModel.clearFeedbackFailure()
          showsLogin = true
        }
      }
      Button("好", role: .cancel) { viewModel.clearFeedbackFailure() }
    } message: {
      Text(viewModel.feedbackFailure?.message ?? "推荐反馈提交失败，请稍后重试。")
    }
  }

  private func feedbackButton(for item: PersonalizedFeedItem) -> some View {
    let isSubmitting = viewModel.feedbackSubmittingThreadIDs.contains(item.id)
    return Button {
      guard !isSubmitting else { return }
      feedbackPrompt = PersonalizedFeedbackPrompt(item: item)
    } label: {
      Group {
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "hand.thumbsdown")
        }
      }
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isSubmitting)
    .accessibilityLabel(isSubmitting ? "正在提交推荐反馈" : "减少此类推荐")
    .help("减少此类推荐")
  }

  private func synchronizeActivation() {
    if isActive, followedForumsOnly {
      followedForumsViewModel.completeIndexSurfaceDidAppear(id: completeIndexSurfaceID)
    } else {
      followedForumsViewModel.completeIndexSurfaceDidDisappear(id: completeIndexSurfaceID)
    }
    synchronizeScope()
    if !isActive { viewModel.cancel() }
  }

  private func synchronizeScope() {
    let scope: PersonalizedFeedScope
    if !followedForumsOnly {
      scope = .all
    } else if case .ready(let snapshot) = followedForumsViewModel.indexState {
      scope = .followedForums(snapshot)
    } else {
      scope = .waitingForFollowedForumIndex
    }
    viewModel.setScope(scope, loadIfNeeded: isActive)
  }
}

struct PersonalizedFeedbackPrompt: Identifiable, Hashable {
  let id: Int64
  let threadTitle: String
  let reasons: [PersonalizedFeedbackReason]
  let clickTimeMilliseconds: Int64

  init?(item: PersonalizedFeedItem, now: Date = Date()) {
    let milliseconds = now.timeIntervalSince1970 * 1_000
    guard
      item.id > 0,
      item.thread.forumID > 0,
      milliseconds.isFinite,
      milliseconds > 0,
      milliseconds < Double(Int64.max)
    else { return nil }

    var seen = Set<UInt32>()
    let reasons = item.feedbackReasons.filter {
      $0.id > 0 && seen.insert($0.id).inserted
    }.prefix(PersonalizedFeedbackSubmission.maximumReasonCount)
    guard !reasons.isEmpty else { return nil }

    id = item.id
    let title = item.thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
    threadTitle = title.isEmpty ? "帖子 \(item.id)" : title
    self.reasons = Array(reasons)
    clickTimeMilliseconds = Int64(milliseconds.rounded(.down))
  }
}

private struct PersonalizedFeedbackSelectionView: View {
  let prompt: PersonalizedFeedbackPrompt
  let submit: (Set<UInt32>) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedReasonIDs = Set<UInt32>()

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(prompt.threadTitle)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("原因") {
          ForEach(prompt.reasons) { reason in
            Button {
              toggle(reason.id)
            } label: {
              HStack(spacing: 12) {
                Text(reason.title.isEmpty ? "减少相似内容" : reason.title)
                  .foregroundStyle(.primary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Image(
                  systemName: selectedReasonIDs.contains(reason.id)
                    ? "checkmark.circle.fill"
                    : "circle"
                )
                .foregroundStyle(
                  selectedReasonIDs.contains(reason.id) ? Color.accentColor : .secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(selectedReasonIDs.contains(reason.id) ? "已选择" : "未选择")
          }
        }
      }
      .navigationTitle("减少此类推荐")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("提交") {
            let selection = selectedReasonIDs
            dismiss()
            submit(selection)
          }
          .disabled(selectedReasonIDs.isEmpty)
        }
      }
    }
  }

  private func toggle(_ reasonID: UInt32) {
    if selectedReasonIDs.contains(reasonID) {
      selectedReasonIDs.remove(reasonID)
    } else {
      selectedReasonIDs.insert(reasonID)
    }
  }
}
