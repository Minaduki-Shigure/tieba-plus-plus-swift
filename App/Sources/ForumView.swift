import Combine
import Foundation
import SwiftUI

private enum ForumScrollTarget: Hashable {
  case top
}

private enum ForumNavigationDestination {
  case newThread(NewThreadTarget)
  case createdThread(BrowseThread)
  case thread(ThreadSummaryNavigationRequest)
}

struct ForumView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ForumViewModel
  @State private var navigationDestination: ForumNavigationDestination?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accountAccess) private var accountAccess
  @AppStorage(AppPreferenceKey.forumPrimaryAction)
  private var forumPrimaryAction = ForumPrimaryAction.defaultValue.rawValue

  init(
    forumName: String,
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
      wrappedValue: ForumViewModel(
        forumName: forumName,
        service: service,
        options: ForumBrowseOptions(
          sort: ForumSortPreferences.resolvedSort(for: forumName)
        )
      )
    )
  }

  var body: some View {
    ScrollViewReader { proxy in
      Group {
        if viewModel.threads.isEmpty {
          switch viewModel.state {
          case .idle, .loading:
            ProgressView()
          case .failed(let message):
            ErrorStateView(message: message, retry: viewModel.reload)
          case .loaded:
            EmptyStateView(title: "暂无帖子", systemImage: "text.bubble")
          }
        } else {
          threadList
        }
      }
      .navigationTitle(viewModel.forumName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          NavigationLink {
            ForumPostSearchView(
              forumName: viewModel.forumName,
              service: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          } label: {
            Image(systemName: "magnifyingglass")
          }
          .accessibilityLabel("吧内搜索")
          .help("吧内搜索")

          if let action = primaryActionPolicy.toolbarAction {
            Button {
              performPrimaryAction(action, proxy: proxy)
            } label: {
              Image(systemName: action.systemImage)
            }
            .disabled(!primaryActionPolicy.canPerform(action))
            .accessibilityLabel(action.title)
            .help(action.title)
            .accessibilityIdentifier("forum-primary-action-\(action.rawValue)")
          }

          if let accountAccess, viewModel.forum.id > 0 {
            ForumMembershipToolbarControl(
              forumID: viewModel.forum.id,
              forumName: membershipForumName,
              access: accountAccess
            )
            .id(
              ForumMembershipTarget(
                forumID: viewModel.forum.id,
                forumName: membershipForumName
              )
            )
          }

          LocalFavoriteButton(
            target: .forum(ForumHistorySnapshot(forum: viewModel.forum)),
            repository: favoritesRepository
          )

          forumActionsMenu(proxy: proxy)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        optionsBar
      }
      .task { viewModel.loadIfNeeded() }
      .task(id: viewModel.forum.id) {
        guard viewModel.forum.id > 0 else { return }
        try? await historyRepository.record(
          .forum(ForumHistorySnapshot(forum: viewModel.forum))
        )
      }
      .onDisappear(perform: viewModel.cancel)
      .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
        Task { @MainActor in viewModel.reload() }
      }
      .onChange(of: viewModel.options.sort) { sort in
        ForumSortPreferences.save(sort, for: viewModel.forumName)
      }
      .navigationDestination(isPresented: forumNavigationPresented) {
        switch navigationDestination {
        case .newThread(let target):
          NewThreadComposerView(
            target: target,
            onConfirmed: handleConfirmedNewThread
          )
          .id("new-thread:\(target.id)")
        case .createdThread(let createdThread):
          ThreadView(
            thread: createdThread,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository,
            linkRoute: TiebaThreadRoute(
              threadID: createdThread.id,
              postID: createdThread.firstPostID
            )
          )
          .id("created-thread:\(createdThread.id):\(createdThread.firstPostID)")
        case .thread(let request):
          threadDestination(request)
        case nil:
          EmptyView()
        }
      }
    }
  }

  private var membershipForumName: String {
    let name = viewModel.forum.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? viewModel.forumName : name
  }

  private var newThreadTarget: NewThreadTarget? {
    guard accountAccess != nil, viewModel.forum.id > 0 else { return nil }
    return NewThreadTarget(
      forumID: viewModel.forum.id,
      forumName: membershipForumName
    )
  }

  private var selectedPrimaryAction: ForumPrimaryAction {
    ForumPrimaryAction.resolved(forumPrimaryAction)
  }

  private var primaryActionPolicy: ForumPrimaryActionPolicy {
    ForumPrimaryActionPolicy(
      selected: selectedPrimaryAction,
      hasNewThreadTarget: newThreadTarget != nil,
      isLoading: viewModel.state == .loading,
      hasThreads: !viewModel.threads.isEmpty
    )
  }

  private var forumNavigationPresented: Binding<Bool> {
    Binding(
      get: { navigationDestination != nil },
      set: { isPresented in
        if !isPresented { navigationDestination = nil }
      }
    )
  }

  private func handleConfirmedNewThread(
    _ receipt: NewThreadReceipt,
    title: String?,
    content: String
  ) {
    let fallbackTitle = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let thread = BrowseThread(
      id: receipt.threadID,
      forumID: viewModel.forum.id,
      forumName: membershipForumName,
      title: title ?? String(fallbackTitle.prefix(NewThreadTitlePolicy.maximumCharacterCount)),
      excerpt: String(content.prefix(160)),
      authorName: "",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text(content)],
      firstPostID: receipt.firstPostID
    )
    viewModel.reload()
    navigationDestination = .createdThread(thread)
  }

  private func forumActionsMenu(proxy: ScrollViewProxy) -> some View {
    Menu {
      if let target = newThreadTarget {
        Button {
          openNewThread(target)
        } label: {
          Label("发布主题", systemImage: "square.and.pencil")
        }

        Divider()
      }

      Button {
        refreshForum()
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .disabled(viewModel.state == .loading)

      Button {
        scrollToTop(proxy: proxy)
      } label: {
        Label("回到顶部", systemImage: "arrow.up.to.line")
      }
      .disabled(viewModel.threads.isEmpty)

      if let url = TiebaLink.canonicalURL(for: .forum(viewModel.forumName)) {
        Divider()
        ShareLink(
          item: TiebaLink.shareText(url: url, title: "\(viewModel.forumName)吧"),
          subject: Text("\(viewModel.forumName)吧")
        ) {
          Label("分享链接", systemImage: "square.and.arrow.up")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("更多贴吧操作")
    .help("更多贴吧操作")
  }

  private func performPrimaryAction(
    _ action: ForumPrimaryAction,
    proxy: ScrollViewProxy
  ) {
    guard primaryActionPolicy.canPerform(action) else { return }
    switch action {
    case .newThread:
      guard let target = newThreadTarget else { return }
      openNewThread(target)
    case .refresh:
      refreshForum()
    case .scrollToTop:
      scrollToTop(proxy: proxy)
    case .hidden:
      return
    }
  }

  private func openNewThread(_ target: NewThreadTarget) {
    guard newThreadTarget == target else { return }
    navigationDestination = .newThread(target)
  }

  private func refreshForum() {
    guard viewModel.state != .loading else { return }
    Task { @MainActor in await viewModel.refresh() }
  }

  private func scrollToTop(proxy: ScrollViewProxy) {
    guard !viewModel.threads.isEmpty else { return }
    proxy.scrollTo(ForumScrollTarget.top, anchor: .top)
  }

  private var optionsBar: some View {
    VStack(spacing: 0) {
      if !viewModel.channels.isEmpty {
        HStack(spacing: 10) {
          Label("频道", systemImage: "rectangle.3.group")
          Spacer(minLength: 0)
          Picker(
            "频道",
            selection: Binding(
              get: { viewModel.selectedChannelID },
              set: { channelID in viewModel.setChannelID(channelID) }
            )
          ) {
            Text("全部主题").tag(Int?.none)
            ForEach(viewModel.channels) { channel in
              Text(channel.name).tag(Optional(channel.id))
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("forum-channel-picker")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
      }

      if viewModel.selectedChannelID == nil {
        Group {
          if AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 8) {
              forumSortPicker
              forumFeaturedToggle
            }
          } else {
            HStack(spacing: 12) {
              forumSortPicker
              forumFeaturedToggle
                .fixedSize()
            }
          }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
      } else if viewModel.selectedChannelSortOptions.count > 1 {
        HStack(spacing: 10) {
          Label("频道排序", systemImage: "arrow.up.arrow.down")
          Spacer(minLength: 0)
          Picker(
            "频道排序",
            selection: Binding(
              get: { viewModel.selectedChannelSort },
              set: { sort in viewModel.setChannelSort(sort) }
            )
          ) {
            ForEach(viewModel.selectedChannelSortOptions) { option in
              Text(option.title).tag(option.sort)
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("forum-channel-sort-picker")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
      }

      if viewModel.selectedChannelID == nil,
        viewModel.options.featuredOnly,
        !viewModel.forum.featuredClassifications.isEmpty
      {
        HStack(spacing: 10) {
          Label("精华分类", systemImage: "line.3.horizontal.decrease.circle")
          Spacer(minLength: 0)
          Picker(
            "精华分类",
            selection: Binding(
              get: { viewModel.options.featuredClassificationID },
              set: { classificationID in
                viewModel.setFeaturedClassificationID(classificationID)
              }
            )
          ) {
            Text("全部").tag(Int?.none)
            ForEach(viewModel.forum.featuredClassifications) { classification in
              Text(classification.name).tag(Optional(classification.id))
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("forum-featured-classification-picker")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
      }

      Divider()
    }
  }

  private var forumSortPicker: some View {
    Picker(
      "主题排序",
      selection: Binding(
        get: { viewModel.options.sort },
        set: { sort in viewModel.setSort(sort) }
      )
    ) {
      ForEach(ForumThreadSort.allCases) { sort in
        Text(sort.title).tag(sort)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: .infinity, minHeight: 32)
    .accessibilityIdentifier("forum-sort-picker")
  }

  private var forumFeaturedToggle: some View {
    Toggle(
      "精华",
      isOn: Binding(
        get: { viewModel.options.featuredOnly },
        set: { featuredOnly in viewModel.setFeaturedOnly(featuredOnly) }
      )
    )
    .toggleStyle(.switch)
    .controlSize(.small)
    .accessibilityIdentifier("forum-featured-toggle")
  }

  private var threadList: some View {
    List {
      NavigationLink {
        ForumInformationView(
          forum: viewModel.forum,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        ForumHeaderView(forum: viewModel.forum)
      }
      .disabled(viewModel.forum.id <= 0)
      .id(ForumScrollTarget.top)
      .listRowSeparator(.hidden)

      if let accountAccess, viewModel.forum.id > 0 {
        ForumCheckInRow(
          forumID: viewModel.forum.id,
          forumName: membershipForumName,
          access: accountAccess
        )
        .id(
          ForumCheckInTarget(
            forumID: viewModel.forum.id,
            forumName: membershipForumName
          )
        )
        .listRowSeparator(.hidden)
      }

      ForEach(viewModel.threads) { thread in
        LocallyFilteredContent(
          visibility: thread.localVisibility,
          placeholder: "已屏蔽此主题"
        ) {
          ThreadSummaryRow(
            thread: thread,
            onNavigate: { navigationDestination = .thread($0) }
          )
        }
        .onAppear {
          viewModel.loadMoreIfNeeded(current: thread)
        }
      }

      if let lastThread = viewModel.threads.last {
        Color.clear
          .frame(height: 1)
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
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private func threadDestination(_ request: ThreadSummaryNavigationRequest) -> some View {
    ThreadView(
      thread: request.thread,
      service: service,
      historyRepository: historyRepository,
      favoritesRepository: favoritesRepository,
      searchHistoryRepository: searchHistoryRepository,
      linkRoute: request.linkRoute,
      initialFocus: request.initialFocus
    )
    .id(request.destinationID)
  }
}

private struct ForumMembershipTarget: Hashable {
  let forumID: Int64
  let forumName: String
}

private struct ForumCheckInTarget: Hashable {
  let forumID: Int64
  let forumName: String
}

enum ForumCheckInRowVisibility {
  static func isVisible(for state: ForumCheckInState) -> Bool {
    switch state {
    case .idle, .signedOut:
      false
    case .loading, .requiresFollow, .unavailable, .ready, .signedToday, .checking, .failed:
      true
    }
  }

  static func signedStatus(consecutiveDays: Int, rank: Int) -> String {
    let streak = "今日已签到 · 连续 \(consecutiveDays) 天"
    return rank > 0 ? "\(streak) · 第 \(rank) 名" : streak
  }
}

private struct ForumCheckInRow: View {
  @StateObject private var viewModel: ForumCheckInViewModel
  @State private var isConfirmationPresented = false

  init(forumID: Int64, forumName: String, access: AccountAccess) {
    _viewModel = StateObject(
      wrappedValue: ForumCheckInViewModel(
        forumID: forumID,
        forumName: forumName,
        access: access
      )
    )
  }

  var body: some View {
    rowContent
      .task { await viewModel.loadIfNeeded() }
      .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
        isConfirmationPresented = false
        Task { @MainActor in await viewModel.accountSessionDidChange() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .forumMembershipDidChange)) {
        notification in
        guard let change = ForumMembershipChange(notification) else { return }
        Task { @MainActor in await viewModel.forumMembershipDidChange(change) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .forumCheckInDidChange)) {
        notification in
        guard let change = ForumCheckInChange(notification) else { return }
        Task { @MainActor in await viewModel.forumCheckInDidChange(change) }
      }
      .confirmationDialog(
        "签到 \(viewModel.forumName)吧？",
        isPresented: $isConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button("签到") {
          isConfirmationPresented = false
          Task { @MainActor in await viewModel.checkIn() }
        }
        Button("取消", role: .cancel) { isConfirmationPresented = false }
      } message: {
        Text("这会使用当前贴吧账户完成签到。")
      }
      .alert(
        "无法完成贴吧签到",
        isPresented: Binding(
          get: { viewModel.errorMessage != nil },
          set: { if !$0 { viewModel.dismissError() } }
        )
      ) {
        Button("好", role: .cancel) { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage ?? "无法完成贴吧签到。")
      }
  }

  @ViewBuilder
  private var rowContent: some View {
    if ForumCheckInRowVisibility.isVisible(for: viewModel.state) {
      control
    } else {
      EmptyView()
        .frame(height: 0)
        .listRowInsets(EdgeInsets())
        .environment(\.defaultMinListRowHeight, 0)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var control: some View {
    switch viewModel.state {
    case .idle, .signedOut:
      EmptyView()
    case .loading:
      visibleRow {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在读取签到状态")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    case .requiresFollow:
      visibleRow {
        Label("关注后可签到", systemImage: "person.badge.plus")
          .foregroundStyle(.secondary)
          .allowsHitTesting(false)
      }
    case .unavailable:
      visibleRow {
        Label("当前无法签到", systemImage: "checkmark.seal")
          .foregroundStyle(.secondary)
          .allowsHitTesting(false)
      }
    case .ready:
      visibleRow {
        Button {
          isConfirmationPresented = true
        } label: {
          Label("签到", systemImage: "checkmark.seal")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forum-check-in-button")
      }
    case .signedToday(let consecutiveDays, let rank):
      visibleRow {
        Label(
          ForumCheckInRowVisibility.signedStatus(
            consecutiveDays: consecutiveDays,
            rank: rank
          ),
          systemImage: "checkmark.seal.fill"
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
        .accessibilityIdentifier("forum-check-in-status")
      }
    case .checking:
      visibleRow {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在签到")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    case .failed:
      visibleRow {
        Button {
          Task { @MainActor in await viewModel.reload() }
        } label: {
          Label("重试读取签到状态", systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forum-check-in-retry")
      }
    }
  }

  private func visibleRow<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
  }
}

private struct ForumMembershipToolbarControl: View {
  @StateObject private var viewModel: ForumMembershipViewModel
  @State private var pendingFollowedState: Bool?

  init(forumID: Int64, forumName: String, access: AccountAccess) {
    _viewModel = StateObject(
      wrappedValue: ForumMembershipViewModel(
        forumID: forumID,
        forumName: forumName,
        access: access
      )
    )
  }

  var body: some View {
    control
      .task { await viewModel.loadIfNeeded() }
      .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
        pendingFollowedState = nil
        Task { @MainActor in await viewModel.accountSessionDidChange() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .forumMembershipDidChange)) {
        notification in
        guard let change = ForumMembershipChange(notification) else { return }
        Task { @MainActor in await viewModel.forumMembershipDidChange(change) }
      }
      .confirmationDialog(
        pendingFollowedState == true
          ? "关注 \(viewModel.forumName)吧？"
          : "取消关注 \(viewModel.forumName)吧？",
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
        Text("这会修改当前贴吧账户的关注列表。")
      }
      .alert(
        "无法更新贴吧关注",
        isPresented: Binding(
          get: { viewModel.errorMessage != nil },
          set: { if !$0 { viewModel.dismissError() } }
        )
      ) {
        Button("好", role: .cancel) { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage ?? "无法完成贴吧关注操作。")
      }
  }

  @ViewBuilder
  private var control: some View {
    switch viewModel.state {
    case .idle, .signedOut:
      EmptyView()
    case .loading, .mutating:
      ProgressView()
        .controlSize(.small)
        .frame(width: 24, height: 24)
        .accessibilityLabel("正在更新贴吧关注")
    case .ready(let isFollowed):
      Button {
        pendingFollowedState = !isFollowed
      } label: {
        Image(systemName: isFollowed ? "star.fill" : "star")
          .frame(width: 24, height: 24)
      }
      .accessibilityLabel(isFollowed ? "取消关注贴吧" : "关注贴吧")
      .help(isFollowed ? "取消关注贴吧" : "关注贴吧")
    case .failed:
      Button {
        Task { @MainActor in await viewModel.reload() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 24, height: 24)
      }
      .accessibilityLabel("重试读取贴吧关注状态")
      .help("重试读取贴吧关注状态")
    }
  }

  private func confirmFollowedState(_ isFollowed: Bool) {
    pendingFollowedState = nil
    Task { @MainActor in await viewModel.setFollowed(isFollowed) }
  }
}

private struct ForumHeaderView: View {
  let forum: BrowseForum

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      DownsampledRemoteImage(url: forum.avatarURL, maxPixelSize: 256) { phase in
        switch phase {
        case .success(let asset, _):
          RemoteImageAssetView(asset: asset, contentMode: .fill)
        default:
          Image(systemName: "text.bubble.fill")
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemFill))
        }
      }
      .frame(width: 58, height: 58)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 7) {
        Text("\(forum.name)吧")
          .font(.headline)
          .lineLimit(1)

        if !forum.slogan.isEmpty {
          Text(forum.slogan)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 12) {
            Label(forum.memberCount.formatted(), systemImage: "person.2")
            Label(forum.threadCount.formatted(), systemImage: "text.bubble")
          }

          if forum.hasRules || forum.hasModerators {
            HStack(spacing: 12) {
              if forum.hasRules {
                Label("吧规", systemImage: "doc.text")
              }
              if forum.hasModerators {
                Label("吧务", systemImage: "checkmark.shield")
              }
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        let category = [forum.category, forum.subcategory]
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
        if !category.isEmpty {
          Text(category)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
  }
}
