import SwiftUI

struct NotificationsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: NotificationsViewModel
  @State private var replyRoute: InboxReplyIntent?
  @State private var replyNotice: String?

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
    _viewModel = StateObject(
      wrappedValue: NotificationsViewModel(service: accountService, vault: vault)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker(
        "消息类型",
        selection: Binding(
          get: { viewModel.selectedKind },
          set: { viewModel.select($0) }
        )
      ) {
        ForEach(InboxKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      content
    }
    .navigationTitle("消息")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let replyNotice {
        replyNoticeBanner(replyNotice)
      }
    }
    .navigationDestination(isPresented: replyRoutePresented) {
      if let replyRoute {
        notificationReplyDestination(for: replyRoute)
      }
    }
    .task { viewModel.loadIfNeeded() }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      viewModel.accountSessionDidChange()
    }
    .onDisappear(perform: viewModel.cancel)
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.messages.isEmpty {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.reload)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        EmptyStateView(
          title: viewModel.selectedKind == .replies ? "暂无回复消息" : "暂无提及消息",
          systemImage: viewModel.selectedKind == .replies ? "bubble.left" : "at"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      messageList
    }
  }

  private var messageList: some View {
    List {
      ForEach(viewModel.messages) { message in
        HStack(alignment: .center, spacing: 8) {
          NavigationLink {
            notificationDestination(for: message)
          } label: {
            NotificationMessageRow(message: message)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          Button {
            prepareReply(to: message)
          } label: {
            Image(systemName: "arrowshape.turn.up.left")
              .foregroundStyle(.tint)
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("回复 \(message.sender.preferredName)")
          .help("回复此消息")
        }
        .onAppear { viewModel.loadMoreIfNeeded(current: message) }
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

  @ViewBuilder
  private func notificationDestination(for message: InboxMessage) -> some View {
    switch message.navigationTarget {
    case .thread(let route):
      ThreadView(
        thread: route.placeholderThread,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
    case .comment(let threadID, let commentID):
      CommentsView(
        threadID: threadID,
        resolvingCommentID: commentID,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        showsDismissButton: false
      )
    }
  }

  @ViewBuilder
  private func notificationReplyDestination(for intent: InboxReplyIntent) -> some View {
    switch intent.target {
    case .post(let postID):
      let route = TiebaThreadRoute(threadID: intent.threadID, postID: postID)
      ThreadView(
        thread: route.placeholderThread,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route,
        replyIntent: intent
      )
      .id(intent)
    case .subpost(let commentID):
      CommentsView(
        threadID: intent.threadID,
        resolvingCommentID: commentID,
        service: browseService,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        showsDismissButton: false,
        replyIntent: intent
      )
      .id(intent)
    }
  }

  private var replyRoutePresented: Binding<Bool> {
    Binding(
      get: { replyRoute != nil },
      set: { isPresented in
        if !isPresented { replyRoute = nil }
      }
    )
  }

  private func prepareReply(to message: InboxMessage) {
    replyNotice = nil
    guard let intent = viewModel.replyIntent(for: message) else {
      replyNotice = "消息所属账户或回复目标已变化，请刷新后重试。"
      return
    }
    replyRoute = intent
  }

  private func replyNoticeBanner(_ message: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button {
        replyNotice = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial)
  }
}

private struct NotificationMessageRow: View {
  let message: InboxMessage

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(
        url: message.sender.portraitURL,
        name: message.sender.preferredName,
        size: 42
      )

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(message.sender.preferredName)
            .font(.headline)
            .lineLimit(1)
          if message.isUnread {
            Circle()
              .fill(.tint)
              .frame(width: 7, height: 7)
              .accessibilityLabel("未读")
          }
          Spacer(minLength: 0)
          if let createdAt = message.createdAt {
            Text(createdAt, style: .relative)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !message.content.isEmpty {
          Text(message.content)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(4)
        }

        if !message.quotedContent.isEmpty {
          Text(message.quotedContent)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
              Rectangle()
                .fill(.quaternary)
                .frame(width: 2)
            }
        }

        HStack(spacing: 8) {
          if !message.title.isEmpty {
            Text(message.title)
              .lineLimit(1)
          } else if !message.forumName.isEmpty {
            Text("\(message.forumName)吧")
              .lineLimit(1)
          }
          if message.isFloorReply {
            Label("楼中楼", systemImage: "bubble.left.and.bubble.right")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.vertical, 3)
    }
  }
}
