import SwiftUI

enum NotificationsToolbarRoute {
  static var searchDestination: RootDestination { .search("") }
}

struct NotificationsView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let accountService: any AccountService
  let vault: any AccountVault
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let isActive: Bool

  @Environment(\.hidesReplyEntryPoints) private var hidesReplyEntryPoints
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel: NotificationsActivityViewModel
  @State private var browseRoute: NotificationBrowseRoute?
  @State private var replyRouteState = NotificationsReplyRouteState()
  @State private var replyNotice: String?
  @State private var isPresented = false

  init(
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    contentFilterRepository: any ContentFilterRepository,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    initialKind: InboxKind = .replies,
    isActive: Bool = true
  ) {
    self.browseService = browseService
    self.accountService = accountService
    self.vault = vault
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.isActive = isActive
    _viewModel = StateObject(
      wrappedValue: NotificationsActivityViewModel(
        service: accountService,
        vault: vault,
        contentFilterRepository: contentFilterRepository,
        selectedKind: initialKind,
        onValidatedFirstPage: { revision in
          InboxNotificationRuntime.shared.reconcileInbox(sessionRevision: revision)
        }
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker(
        "消息类型",
        selection: selectedKind
      ) {
        ForEach(InboxKind.allCases) { kind in
          Text(kind.title).tag(kind)
            .accessibilityIdentifier("inbox-kind-\(kind.rawValue)")
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      ForumSectionPager(sections: InboxKind.allCases, selection: selectedKind) { kind in
        NotificationsPageView(
          model: viewModel.model(for: kind),
          onRefresh: { await viewModel.refresh(kind: kind) }
        ) { presentation in
          interactiveMessageRow(presentation, kind: kind)
        }
      }
    }
    .navigationTitle("消息")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        NavigationLink(value: NotificationsToolbarRoute.searchDestination) {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索")
        .help("搜索")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let replyNotice {
        replyNoticeBanner(replyNotice)
      }
    }
    .navigationDestination(isPresented: replyRoutePresented) {
      if let replyRoute = replyRouteState.intent {
        notificationReplyDestination(for: replyRoute)
      }
    }
    .navigationDestination(isPresented: browseRoutePresented) {
      if let browseRoute {
        switch browseRoute {
        case .message(let message): notificationDestination(for: message)
        case .sender(let route): notificationSenderDestination(for: route)
        }
      }
    }
    .onAppear {
      isPresented = true
      synchronizeActivation()
    }
    .onChange(of: isActive) { _ in synchronizeActivation() }
    .onChange(of: scenePhase) { _ in synchronizeActivation() }
    .onChange(of: hidesReplyEntryPoints) { hidden in
      if hidden { invalidatePendingReplyRouteForHiddenPreference() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      invalidatePendingReplyRouteForAccountChange()
      if !acceptsAutomaticRequests { viewModel.deactivate() }
      viewModel.accountSessionDidChange()
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      invalidatePendingReplyRouteForContentFilterChange()
      viewModel.contentFilterDidChange()
    }
    .onDisappear {
      isPresented = false
      invalidatePendingReplyRouteForInactiveTab()
      viewModel.deactivate()
    }
  }

  private var acceptsAutomaticRequests: Bool {
    isPresented && isActive && scenePhase == .active
  }

  private var selectedKind: Binding<InboxKind> {
    Binding(
      get: { viewModel.selectedKind },
      set: { kind in
        guard acceptsAutomaticRequests else { return }
        invalidatePendingReplyRouteForInactiveTab()
        viewModel.select(kind)
      })
  }

  private func synchronizeActivation() {
    if acceptsAutomaticRequests {
      viewModel.activate()
    } else {
      invalidatePendingReplyRouteForInactiveTab()
      viewModel.deactivate()
    }
  }

  private func invalidatePendingReplyRouteForInactiveTab() {
    guard replyRouteState.cancelPending() else { return }
    replyNotice = nil
  }

  private func interactiveMessageRow(
    _ presentation: InboxMessagePresentation, kind: InboxKind
  ) -> some View {
    let message = presentation.message
    let senderRoute = NotificationSenderProfileRoute(presentation: presentation)

    return HStack(alignment: .center, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        notificationSenderAvatar(message: message, route: senderRoute)

        VStack(alignment: .leading, spacing: 5) {
          notificationMessageHeader(message: message, route: senderRoute)

          Button {
            guard acceptsAutomaticRequests, viewModel.isActive(kind) else { return }
            browseRoute = .message(message)
          } label: {
            NotificationMessageBody(message: message)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.primary)
        }
        .padding(.vertical, 3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if replyEntriesVisible {
        Button {
          guard replyEntriesVisible else { return }
          prepareReply(to: message, kind: kind)
        } label: {
          Image(systemName: "arrowshape.turn.up.left")
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("回复 \(message.sender.preferredName)")
        .help("回复此消息")
      }
    }
  }

  @ViewBuilder
  private func notificationSenderAvatar(
    message: InboxMessage,
    route: NotificationSenderProfileRoute?
  ) -> some View {
    if let route {
      Button {
        guard acceptsAutomaticRequests else { return }
        browseRoute = .sender(route)
      } label: {
        NotificationMessageAvatar(message: message)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("查看 \(message.sender.preferredName) 的主页")
    } else {
      NotificationMessageAvatar(message: message)
        .frame(width: 44, height: 44)
    }
  }

  @ViewBuilder
  private func notificationSenderName(
    message: InboxMessage,
    route: NotificationSenderProfileRoute?
  ) -> some View {
    if let route {
      Button {
        guard acceptsAutomaticRequests else { return }
        browseRoute = .sender(route)
      } label: {
        NotificationMessageSenderName(message: message)
          .frame(minWidth: 44, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("查看 \(message.sender.preferredName) 的主页")
    } else {
      NotificationMessageSenderName(message: message)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
    }
  }

  @ViewBuilder
  private func notificationMessageHeader(
    message: InboxMessage,
    route: NotificationSenderProfileRoute?
  ) -> some View {
    if let createdAt = message.createdAt {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 6) {
          notificationSenderName(message: message, route: route)
          notificationUnreadIndicator(message: message)
          Spacer(minLength: 0)
          NotificationMessageTimestamp(createdAt: createdAt)
        }
        .fixedSize(horizontal: true, vertical: false)

        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 6) {
            notificationSenderName(message: message, route: route)
            notificationUnreadIndicator(message: message)
          }
          NotificationMessageTimestamp(createdAt: createdAt)
        }
      }
    } else {
      HStack(alignment: .center, spacing: 6) {
        notificationSenderName(message: message, route: route)
        notificationUnreadIndicator(message: message)
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder
  private func notificationUnreadIndicator(message: InboxMessage) -> some View {
    if message.isUnread {
      Circle()
        .fill(.tint)
        .frame(width: 7, height: 7)
        .accessibilityLabel("未读")
    }
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
        presentationContext: .navigation
      )
    }
  }

  private func notificationSenderDestination(
    for route: NotificationSenderProfileRoute
  ) -> some View {
    UserProfileView(
      userID: route.userID,
      service: browseService,
      historyRepository: historyRepository,
      favoritesRepository: favoritesRepository,
      searchHistoryRepository: searchHistoryRepository
    )
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
        replyIntent: intent,
        onInboxReplyComposerPresented: markReplyRouteEstablished
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
        presentationContext: .navigation,
        replyIntent: intent,
        onInboxReplyComposerPresented: markReplyRouteEstablished
      )
      .id(intent)
    }
  }

  private var replyRoutePresented: Binding<Bool> {
    Binding(
      get: { replyRouteState.isPresented },
      set: { isPresented in
        if !isPresented { replyRouteState.dismiss() }
      }
    )
  }

  private var browseRoutePresented: Binding<Bool> {
    Binding(
      get: { browseRoute != nil },
      set: { if !$0 { browseRoute = nil } })
  }

  private var replyEntriesVisible: Bool {
    ReplyEntryVisibilityPolicy(
      preferenceHidden: hidesReplyEntryPoints,
      pureReading: false,
      contextAvailable: true
    ).showsReplyEntry
  }

  private func prepareReply(to message: InboxMessage, kind: InboxKind) {
    let model = viewModel.model(for: kind)
    guard acceptsAutomaticRequests, viewModel.isActive(kind), replyEntriesVisible,
      !model.isResolvingSession, !model.isResolvingContentFilter
    else { return }
    replyNotice = nil
    guard
      let intent = InboxReplyIntentAdmissionPolicy.admittedIntent(
        model.replyIntent(for: message),
        hidesReplyEntryPoints: hidesReplyEntryPoints
      )
    else {
      replyNotice = "消息所属账户或回复目标已变化，请刷新后重试。"
      return
    }
    replyRouteState.present(intent)
  }

  private func invalidatePendingReplyRouteForHiddenPreference() {
    guard replyRouteState.cancelPending() else { return }
    replyNotice = "已在设置中隐藏回复入口，未打开回复编辑器。"
  }

  private func invalidatePendingReplyRouteForAccountChange() {
    guard replyRouteState.cancelPending() else { return }
    replyNotice = "账户已变化，未打开回复编辑器。"
  }

  private func invalidatePendingReplyRouteForContentFilterChange() {
    guard replyRouteState.cancelPending() else { return }
    replyNotice = "本地屏蔽规则已变化，未打开回复编辑器。"
  }

  private func markReplyRouteEstablished(_ intent: InboxReplyIntent) {
    replyRouteState.markEstablished(intent)
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
    .appRegularMaterialSurface()
  }
}

/// Multiple destination-style NavigationLinks in one native List row can push
/// both the sender and the body destination. Explicit buttons select exactly
/// one parent-owned route and keep those hit regions independent.
private enum NotificationBrowseRoute {
  case message(InboxMessage)
  case sender(NotificationSenderProfileRoute)
}

struct NotificationSenderProfileRoute: Hashable, Sendable {
  let userID: Int64

  init?(presentation: InboxMessagePresentation) {
    guard presentation.visibility == .visible, presentation.message.sender.id > 0 else {
      return nil
    }
    userID = presentation.message.sender.id
  }
}

struct NotificationsReplyRouteState: Equatable {
  private(set) var intent: InboxReplyIntent?
  private(set) var isEstablished = false

  var isPresented: Bool { intent != nil }

  mutating func present(_ intent: InboxReplyIntent) {
    self.intent = intent
    isEstablished = false
  }

  mutating func markEstablished(_ intent: InboxReplyIntent) {
    guard self.intent == intent else { return }
    isEstablished = true
  }

  @discardableResult
  mutating func cancelPending() -> Bool {
    guard intent != nil, !isEstablished else { return false }
    dismiss()
    return true
  }

  mutating func dismiss() {
    intent = nil
    isEstablished = false
  }
}

private struct NotificationMessageAvatar: View {
  let message: InboxMessage

  var body: some View {
    AvatarView(
      url: message.sender.portraitURL,
      name: message.sender.preferredName,
      size: 42
    )
  }
}

private struct NotificationMessageSenderName: View {
  let message: InboxMessage

  var body: some View {
    Text(message.sender.preferredName)
      .font(.headline)
      .foregroundStyle(.primary)
      .lineLimit(2)
  }
}

private struct NotificationMessageTimestamp: View {
  let createdAt: Date

  var body: some View {
    Text(createdAt, style: .relative)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct NotificationMessageBody: View {
  let message: InboxMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
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
  }
}
