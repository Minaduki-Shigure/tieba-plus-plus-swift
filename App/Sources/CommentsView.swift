import Combine
import SwiftUI

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appAccentColor) private var appAccentColor
  @Environment(\.accountAccess) private var accountAccess
  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @Environment(\.contentReportCoordinator) private var contentReportCoordinator
  @Environment(\.hidesReplyEntryPoints) private var hidesReplyEntryPoints
  @StateObject private var viewModel: CommentsViewModel
  @State private var linkedTarget: TiebaLinkTarget?
  @State private var highlightedComment: CommentHighlightToken?
  @State private var agreementScopeID = UUID()
  @State private var reportScopeID = UUID()
  @State private var pendingAgreementChange: PendingContentAgreementChange?
  @State private var agreementErrorMessage: String?
  @State private var hasRecordedDirectVisit = false
  @State private var replyComposerContext: TextReplyComposerContext?
  @State private var pendingConfirmedThreadRoute: TiebaThreadRoute?
  @State private var pendingInboxReplyIntent: InboxReplyIntent?
  @State private var isResolvingInboxReplyIntent = false
  @State private var inboxReplyIntentGeneration = 0
  @State private var inboxReplyNotice: String?
  @State private var inboxReplyComposerIntent: InboxReplyIntent?
  @State private var selectableTextPresentation: SelectableTextPresentation?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  private let showsDismissButton: Bool
  private let recordsOwningThreadVisit: Bool
  private let onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)?

  init(
    threadID: Int64,
    postID: Int64,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    showsDismissButton: Bool = true,
    replyIntent: InboxReplyIntent? = nil,
    onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = false
    self.onInboxReplyComposerPresented = onInboxReplyComposerPresented
    _pendingInboxReplyIntent = State(initialValue: replyIntent)
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(threadID: threadID, postID: postID, service: service)
    )
  }

  init(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    showsDismissButton: Bool = true,
    replyIntent: InboxReplyIntent? = nil,
    onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = false
    self.onInboxReplyComposerPresented = onInboxReplyComposerPresented
    _pendingInboxReplyIntent = State(initialValue: replyIntent)
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(
        threadID: threadID,
        postID: postID,
        aroundCommentID: commentID,
        service: service
      )
    )
  }

  init(
    threadID: Int64,
    resolvingCommentID commentID: Int64,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    showsDismissButton: Bool = true,
    replyIntent: InboxReplyIntent? = nil,
    onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = true
    self.onInboxReplyComposerPresented = onInboxReplyComposerPresented
    _pendingInboxReplyIntent = State(initialValue: replyIntent)
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(
        threadID: threadID,
        resolvingCommentID: commentID,
        service: service
      )
    )
  }

  var body: some View {
    Group {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
      case .failed(let message):
        VStack(spacing: 16) {
          ErrorStateView(message: message, retry: viewModel.reload)
          if recordsOwningThreadVisit {
            NavigationLink {
              let route = TiebaThreadRoute(threadID: viewModel.threadID, postID: nil)
              ThreadView(
                thread: route.placeholderThread,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository,
                linkRoute: route
              )
            } label: {
              Label("查看原帖", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
          }
        }
      case .loaded:
        ScrollViewReader { proxy in
          List {
            if let parentPost = viewModel.parentPost,
              parentPost.localVisibility != .hidden
            {
              LocallyFilteredContent(
                visibility: parentPost.localVisibility,
                placeholder: "已屏蔽父楼"
              ) {
                CommentParentPostView(
                  post: parentPost,
                  thread: viewModel.thread,
                  agreementTarget: viewModel.parentAgreementTarget,
                  service: service,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository,
                  openMentionedUser: openMentionedUser,
                  openTiebaLink: openTiebaLink,
                  requestAgreementChange: requestAgreementChange,
                  retryAgreement: retryAgreement,
                  requestReply: replyEntriesVisible
                    ? parentReplyContext.map { context in
                      {
                        guard replyEntriesVisible else { return }
                        presentReplyComposer(context)
                      }
                    }
                    : nil,
                  reportTarget: viewModel.thread.flatMap { thread in
                    ContentReportTarget(thread: thread, parentPost: parentPost)
                  },
                  selectText: presentSelectableText
                )
              }
              .id(CommentsListItemID.parentPost(parentPost.id))
            }

            Section {
              if viewModel.isLoadingPrevious {
                HStack {
                  Spacer()
                  ProgressView()
                  Spacer()
                }
                .listRowSeparator(.hidden)
              } else if let message = viewModel.loadPreviousError {
                LoadMoreErrorView(message: message, retry: viewModel.retryLoadPrevious)
                  .listRowSeparator(.hidden)
              } else if viewModel.canLoadPrevious {
                Button(action: viewModel.loadPrevious) {
                  Label("加载更早回复", systemImage: "arrow.up")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("comments-load-previous")
              }

              if !viewModel.hasDisplayableComments {
                EmptyStateView(title: "暂无可显示的楼中楼回复", systemImage: "bubble.left")
                  .frame(maxWidth: .infinity)
                  .listRowSeparator(.hidden)
              }

              ForEach(viewModel.comments) { comment in
                LocallyFilteredContent(
                  visibility: comment.localVisibility,
                  placeholder: "已屏蔽此条回复"
                ) {
                  StableRenderBoundary(
                    key: CommentsRowRenderKey(
                      comment: comment,
                      thread: viewModel.thread,
                      parentPostID: viewModel.parentPost?.id,
                      agreementTarget: viewModel.agreementTarget(forCommentID: comment.id),
                      replyEntriesVisible: replyEntriesVisible
                    )
                  ) {
                    VStack(alignment: .leading, spacing: 7) {
                      HStack(alignment: .top, spacing: 10) {
                        if comment.authorID > 0 {
                          NavigationLink {
                            UserProfileView(
                              userID: comment.authorID,
                              service: service,
                              historyRepository: historyRepository,
                              favoritesRepository: favoritesRepository,
                              searchHistoryRepository: searchHistoryRepository
                            )
                          } label: {
                            commentAuthorIdentity(comment)
                          }
                          .buttonStyle(.plain)
                        } else {
                          commentAuthorIdentity(comment)
                        }

                        ContentAgreementControlSlot(
                          store: contentAgreementStore,
                          target: viewModel.agreementTarget(forCommentID: comment.id),
                          fallbackAgreeScore: comment.agreeScore,
                          requestChange: requestAgreementChange,
                          retry: retryAgreement
                        )

                        if replyEntriesVisible, let context = replyContext(for: comment) {
                          Button {
                            guard replyEntriesVisible else { return }
                            presentReplyComposer(context)
                          } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                          }
                          .buttonStyle(.plain)
                          .accessibilityLabel("回复 \(context.replyingToName ?? "此用户")")
                          .help("回复此条")
                        }
                      }
                      BrowseContentView(
                        contents: comment.contents,
                        onUserMention: openMentionedUser,
                        onTiebaLink: openTiebaLink,
                        allowsDirectTextSelection: false,
                        tracksAnimationVisibility: true,
                        maximumPreviewPixelSize: 1_320
                      )
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                      if let copyText = PostCopyText.text(comment: comment) {
                        Button {
                          presentSelectableText(copyText)
                        } label: {
                          Label("选择文字", systemImage: "text.cursor")
                        }
                      }
                      if replyEntriesVisible, let context = replyContext(for: comment) {
                        Button {
                          guard replyEntriesVisible else { return }
                          presentReplyComposer(context)
                        } label: {
                          Label("回复此条", systemImage: "arrowshape.turn.up.left")
                        }
                      }
                      ContentReportMenuItem(
                        target: reportTarget(for: comment),
                        accessibilityIdentifier: "comments-report-subpost-\(comment.id)"
                      )
                    }
                  }
                  .equatable()
                }
                .id(CommentsListItemID.comment(comment.id))
                .listRowBackground(
                  highlightedComment?.commentID == comment.id
                    ? appAccentColor.color.opacity(0.12)
                    : Color.clear
                )
                .overlay(alignment: .leading) {
                  if highlightedComment?.commentID == comment.id {
                    appAccentColor.color
                      .frame(width: 3)
                      .accessibilityHidden(true)
                  }
                }
                .animation(
                  reduceMotion ? nil : .easeInOut(duration: 0.2),
                  value: highlightedComment?.commentID
                )
                .onAppear {
                  viewModel.loadMoreIfNeeded(current: comment)
                }
              }

              if let lastComment = viewModel.comments.last {
                Color.clear
                  .frame(height: 1)
                  .listRowInsets(EdgeInsets())
                  .listRowSeparator(.hidden)
                  .accessibilityHidden(true)
                  .onAppear { viewModel.loadMoreIfNeeded(current: lastComment) }
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
              Text("共 \(viewModel.totalCount) 条回复")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            }
          }
          .listStyle(.plain)
          .task(id: viewModel.scrollTargetCommentID) {
            guard let commentID = viewModel.scrollTargetCommentID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(CommentsListItemID.comment(commentID), anchor: .center)
            highlightedComment = CommentHighlightToken(commentID: commentID)
            viewModel.consumeScrollTarget()
          }
          .task(id: viewModel.prependRestoreCommentID) {
            guard let commentID = viewModel.prependRestoreCommentID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(CommentsListItemID.comment(commentID), anchor: .top)
            viewModel.consumePrependRestoreTarget()
          }
          .task(id: highlightedComment) {
            guard let token = highlightedComment else { return }
            do {
              try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
              return
            }
            guard !Task.isCancelled, highlightedComment == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
              highlightedComment = nil
            }
          }
          .refreshable {
            let previousAgreementRefreshEpoch = viewModel.agreementExplicitRefreshEpoch
            await viewModel.refresh()
            if
              viewModel.agreementExplicitRefreshEpoch != previousAgreementRefreshEpoch,
              let contentAgreementStore
            {
              await contentAgreementStore.refreshDescriptors(for: agreementScopeID)
            }
          }
        }
      }
    }
    .navigationTitle(navigationTitle)
    .environment(\.contentReportScopeID, reportScopeID)
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(
      pendingAgreementChange?.confirmationTitle ?? "更新点赞状态？",
      isPresented: agreementConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      if let pendingAgreementChange {
        if pendingAgreementChange.targetAgreed {
          Button(pendingAgreementChange.actionTitle) {
            confirmAgreementChange(pendingAgreementChange)
          }
        } else {
          Button(pendingAgreementChange.actionTitle, role: .destructive) {
            confirmAgreementChange(pendingAgreementChange)
          }
        }
      }
      Button("取消", role: .cancel) { pendingAgreementChange = nil }
    } message: {
      Text(pendingAgreementChange?.confirmationMessage ?? "")
    }
    .alert("无法更新点赞状态", isPresented: agreementErrorIsPresented) {
      Button("好", role: .cancel) { agreementErrorMessage = nil }
    } message: {
      Text(agreementErrorMessage ?? "无法完成点赞操作。")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      commentsBottomInset
    }
    .navigationDestination(isPresented: linkedTargetPresented) {
      if let linkedTarget {
        TiebaLinkDestination(
          target: linkedTarget,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      }
    }
    .navigationDestination(isPresented: replyComposerPresented) {
      if let replyComposerContext {
        ReplyComposerView(
          context: replyComposerContext,
          verifyVisibility: verifyReplyVisibility,
          onConfirmed: handleConfirmedReply
        )
      }
    }
    .sheet(item: $selectableTextPresentation) { presentation in
      SelectableTextSheet(
        presentation: presentation,
        onCommand: performSelectableTextCommand
      )
    }
    .toolbar {
      if showsDismissButton {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
    .task { viewModel.loadIfNeeded() }
    .task(
      id: InboxReplyIntentResolutionTaskID(
        loadState: viewModel.state,
        hidesReplyEntryPoints: hidesReplyEntryPoints
      )
    ) {
      await consumeInboxReplyIntentIfReady()
    }
    .task(id: viewModel.state) {
      await recordDirectVisitIfNeeded()
    }
    .task(id: viewModel.agreementDescriptorEpoch) {
      guard let contentAgreementStore else { return }
      await contentAgreementStore.replaceDescriptors(
        viewModel.agreementReadDescriptors,
        for: agreementScopeID
      )
    }
    .onDisappear {
      contentReportCoordinator?.invalidate(scopeID: reportScopeID)
      pendingAgreementChange = nil
      selectableTextPresentation = nil
      contentAgreementStore?.removeScope(agreementScopeID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      invalidateInboxReplyIntentForAccountChange()
      pendingAgreementChange = nil
      agreementErrorMessage = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      selectableTextPresentation = nil
      contentReportCoordinator?.invalidate(scopeID: reportScopeID)
      Task { @MainActor in viewModel.reload() }
    }
    .onChange(of: hidesReplyEntryPoints) { isHidden in
      if isHidden {
        invalidatePendingInboxReplyIntentForHiddenPreference()
      }
    }
    .onChange(of: replyComposerContext) { context in
      if context == nil {
        inboxReplyComposerIntent = nil
      }
      guard context == nil, let route = pendingConfirmedThreadRoute else { return }
      pendingConfirmedThreadRoute = nil
      Task { @MainActor in
        await Task.yield()
        linkedTarget = .thread(route)
      }
    }
  }

  private func recordDirectVisitIfNeeded() async {
    guard
      recordsOwningThreadVisit,
      !hasRecordedDirectVisit,
      !Task.isCancelled,
      viewModel.state == .loaded,
      let thread = viewModel.thread,
      let parentPost = viewModel.parentPost,
      thread.id == viewModel.threadID,
      parentPost.threadID == viewModel.threadID
    else { return }
    hasRecordedDirectVisit = true

    let existingOptions: ThreadBrowseOptions
    if
      let entry = try? await historyRepository.entries(kind: .thread)
        .first(where: { $0.id == "thread:\(thread.id)" }),
      case .thread(let snapshot) = entry.target
    {
      existingOptions = snapshot.browseOptions
    } else {
      existingOptions = ThreadBrowseOptions()
    }
    guard !Task.isCancelled else { return }
    let updatedAt = Date()
    try? await historyRepository.record(
      .thread(
        ThreadHistorySnapshot(
          thread: thread,
          resolvedAuthorAvatarURL: thread.authorAvatarURL,
          browseOptions: existingOptions,
          lastPostID: parentPost.id,
          lastFloor: parentPost.floor
        )
      ),
      at: updatedAt
    )
    try? await favoritesRepository.updateThreadProgress(
      threadID: thread.id,
      postID: parentPost.id,
      floor: parentPost.floor,
      options: existingOptions,
      at: updatedAt
    )
  }

  private var linkedTargetPresented: Binding<Bool> {
    Binding(
      get: { linkedTarget != nil },
      set: { isPresented in
        if !isPresented { linkedTarget = nil }
      }
    )
  }

  private func presentSelectableText(_ text: String) {
    selectableTextPresentation = SelectableTextPresentation(text: text)
  }

  private func performSelectableTextCommand(
    _ command: SelectableTextSheetCommand,
    expected: SelectableTextPresentation
  ) {
    guard let current = selectableTextPresentation else { return }
    var pending: SelectableTextPresentation? = current
    let text = SelectableTextSheetCommandPolicy.consume(
      command,
      expected: expected,
      pending: &pending
    )
    guard pending == nil else { return }
    selectableTextPresentation = nil
    if let text {
      SelectableTextPasteboard.write(text)
    }
  }

  private var replyComposerPresented: Binding<Bool> {
    Binding(
      get: { replyComposerContext != nil },
      set: { isPresented in
        if !isPresented { replyComposerContext = nil }
      }
    )
  }

  private var parentReplyContext: TextReplyComposerContext? {
    guard let thread = viewModel.thread, let parentPost = viewModel.parentPost else {
      return nil
    }
    return TextReplyComposerContext(thread: thread, parentPost: parentPost)
  }

  private var replyEntriesVisible: Bool {
    ReplyEntryVisibilityPolicy(
      preferenceHidden: hidesReplyEntryPoints,
      pureReading: false,
      contextAvailable: true
    ).showsReplyEntry
  }

  private func presentReplyComposer(_ context: TextReplyComposerContext?) {
    guard
      ReplyEntryVisibilityPolicy(
        preferenceHidden: hidesReplyEntryPoints,
        pureReading: false,
        contextAvailable: context != nil
      ).showsReplyEntry,
      let context
    else { return }
    replyComposerContext = context
  }

  private func replyContext(for comment: BrowseComment) -> TextReplyComposerContext? {
    guard
      let thread = viewModel.thread,
      let parentPostID = viewModel.parentPost?.id
    else { return nil }
    return TextReplyComposerContext(
      thread: thread,
      parentPostID: parentPostID,
      comment: comment
    )
  }

  private func reportTarget(for comment: BrowseComment) -> ContentReportTarget? {
    guard
      let thread = viewModel.thread,
      let parentPostID = viewModel.parentPost?.id
    else { return nil }
    return ContentReportTarget(
      thread: thread,
      parentPostID: parentPostID,
      comment: comment
    )
  }

  private func consumeInboxReplyIntentIfReady() async {
    guard pendingInboxReplyIntent != nil else { return }
    guard
      let intent = InboxReplyIntentAdmissionPolicy.admittedIntent(
        pendingInboxReplyIntent,
        hidesReplyEntryPoints: hidesReplyEntryPoints
      )
    else {
      invalidatePendingInboxReplyIntentForHiddenPreference()
      return
    }
    switch viewModel.state {
    case .idle, .loading:
      return
    case .failed:
      pendingInboxReplyIntent = nil
      inboxReplyNotice = "未能读取回复目标，因此没有打开回复编辑器。"
      return
    case .loaded:
      break
    }

    let generation = inboxReplyIntentGeneration
    pendingInboxReplyIntent = nil
    isResolvingInboxReplyIntent = true
    defer {
      if inboxReplyIntentGeneration == generation {
        isResolvingInboxReplyIntent = false
      }
    }

    guard
      intent.threadID == viewModel.threadID,
      case .subpost(let commentID) = intent.target,
      let thread = viewModel.thread,
      let parentPost = viewModel.parentPost,
      thread.id == intent.threadID,
      parentPost.threadID == intent.threadID,
      thread.localVisibility == .visible,
      parentPost.localVisibility == .visible
    else {
      inboxReplyNotice = "未能在公开内容中精确定位这条回复，未打开回复编辑器。"
      return
    }
    let matchingComments = viewModel.comments.filter {
      $0.id == commentID
        && $0.threadID == intent.threadID
        && $0.parentPostID == parentPost.id
    }
    guard
      matchingComments.count == 1,
      let comment = matchingComments.first,
      comment.localVisibility == .visible
    else {
      inboxReplyNotice = "未能在公开内容中精确定位这条回复，未打开回复编辑器。"
      return
    }

    guard let accountAccess else {
      inboxReplyNotice = "未能确认当前登录账户，未打开回复编辑器。"
      return
    }
    do {
      guard
        let session = try await InboxReplyIntentAdmissionPolicy.activeSession(
          for: intent,
          hidesReplyEntryPoints: hidesReplyEntryPoints,
          vault: accountAccess.vault
        )
      else {
        guard inboxReplyIntentGeneration == generation else { return }
        if hidesReplyEntryPoints {
          invalidatePendingInboxReplyIntentForHiddenPreference()
        } else {
          inboxReplyNotice = "当前没有可用的登录账户，未打开回复编辑器。"
        }
        return
      }
      try Task.checkCancellation()
      guard inboxReplyIntentGeneration == generation else { return }
      guard intent.isBound(to: session) else {
        inboxReplyNotice = "当前账户已变化，未打开回复编辑器。"
        return
      }
      guard
        let context = intent.composerContext(
          session: session,
          thread: thread,
          parentPost: parentPost,
          comment: comment
        )
      else {
        inboxReplyNotice = "回复目标校验未通过，未打开回复编辑器。"
        return
      }
      guard replyComposerContext == nil else { return }
      guard replyEntriesVisible else { return }
      inboxReplyComposerIntent = intent
      replyComposerContext = context
      onInboxReplyComposerPresented?(intent)
    } catch is CancellationError {
      return
    } catch {
      guard inboxReplyIntentGeneration == generation else { return }
      inboxReplyNotice = "未能确认当前登录账户，未打开回复编辑器。"
    }
  }

  private func invalidateInboxReplyIntentForAccountChange() {
    let hadInboxReplyFlow =
      pendingInboxReplyIntent != nil
      || isResolvingInboxReplyIntent
      || inboxReplyComposerIntent != nil
    inboxReplyIntentGeneration &+= 1
    pendingInboxReplyIntent = nil
    isResolvingInboxReplyIntent = false
    if inboxReplyComposerIntent != nil {
      inboxReplyComposerIntent = nil
      replyComposerContext = nil
    }
    if hadInboxReplyFlow {
      inboxReplyNotice = "当前账户已变化，已取消从消息发起的回复。"
    }
  }

  private func invalidatePendingInboxReplyIntentForHiddenPreference() {
    let hadInboxReplyFlow =
      pendingInboxReplyIntent != nil
      || isResolvingInboxReplyIntent
    inboxReplyIntentGeneration &+= 1
    pendingInboxReplyIntent = nil
    isResolvingInboxReplyIntent = false
    if hadInboxReplyFlow {
      inboxReplyNotice = "已在设置中隐藏回复入口，未打开回复编辑器。"
    }
  }

  @ViewBuilder
  private var commentsBottomInset: some View {
    VStack(spacing: 0) {
      if let inboxReplyNotice {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Text(inboxReplyNotice)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button {
            self.inboxReplyNotice = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      } else if let message = viewModel.positionNotice {
        HStack(spacing: 10) {
          Image(systemName: "location.slash")
            .foregroundStyle(.secondary)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button(action: viewModel.dismissPositionNotice) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      } else if let message = viewModel.refreshError {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button(action: viewModel.dismissRefreshError) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }

      if replyEntriesVisible, let context = parentReplyContext {
        Divider()
        Button {
          guard replyEntriesVisible else { return }
          presentReplyComposer(context)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "bubble.left")
            Text(context.composerTitle)
              .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 14)
          .frame(minHeight: 46)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("comments-reply-parent")
      }
    }
    .background(.regularMaterial)
  }

  private func verifyReplyVisibility(
    _ receipt: TextReplyReceipt,
    expectedContent: String
  ) async throws
    -> TextReplyVisibilityConfirmation?
  {
    switch receipt {
    case .post(let postID):
      guard let thread = viewModel.thread else { return nil }
      let verifier = ThreadViewModel(thread: thread, service: service)
      guard
        let post = await verifier.verifyAndRelocateAcceptedReply(postID: postID),
        post.id == postID,
        post.threadID == viewModel.threadID,
        post.id != thread.firstPostID,
        post.floor > 1,
        let content = TextReplyVisibilityProof.exactPlainText(
          from: post.contents,
          matching: expectedContent
        )
      else { return nil }
      return TextReplyVisibilityConfirmation(
        created: .post(postID: post.id, floor: post.floor),
        authorUserID: post.authorID,
        content: content
      )
    case .subpost(let parentPostID, let subpostID):
      guard let context = replyComposerContext else { return nil }
      guard
        parentPostID == viewModel.parentPost?.id,
        let comment = await viewModel.verifyAndRelocateAcceptedReply(commentID: subpostID),
        comment.id == subpostID,
        comment.threadID == viewModel.threadID,
        comment.parentPostID == parentPostID
      else { return nil }
      let content: String?
      switch context.target.destination {
      case .subpost(let expectedParentPostID, _):
        guard
          expectedParentPostID == parentPostID,
          let expectedNestedReplyUserID = context.replyingToUserID
        else { return nil }
        content = TextReplyVisibilityProof.exactNestedReplyBody(
          from: comment,
          expectedReplyToUserID: expectedNestedReplyUserID,
          matching: expectedContent
        )
      case .post(let expectedParentPostID):
        guard expectedParentPostID == parentPostID else { return nil }
        content = TextReplyVisibilityProof.exactPlainText(
          from: comment.contents,
          matching: expectedContent
        )
      case .thread:
        return nil
      }
      guard let content else { return nil }
      return TextReplyVisibilityConfirmation(
        created: .subpost(parentPostID: parentPostID, subpostID: subpostID),
        authorUserID: comment.authorID,
        content: content
      )
    }
  }

  private func handleConfirmedReply(_ created: CreatedTextReply) {
    switch created {
    case .post(let postID, _):
      guard postID > 0 else { return }
      pendingConfirmedThreadRoute = TiebaThreadRoute(
        threadID: viewModel.threadID,
        postID: postID
      )
    case .subpost(let parentPostID, let subpostID):
      guard parentPostID == viewModel.parentPost?.id else { return }
      if viewModel.scrollTargetCommentID != subpostID {
        viewModel.relocateAfterConfirmedReply(commentID: subpostID)
      }
    }
  }

  private var agreementConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingAgreementChange != nil },
      set: { isPresented in
        if !isPresented { pendingAgreementChange = nil }
      }
    )
  }

  private var agreementErrorIsPresented: Binding<Bool> {
    Binding(
      get: { agreementErrorMessage != nil },
      set: { isPresented in
        if !isPresented { agreementErrorMessage = nil }
      }
    )
  }

  private func openMentionedUser(_ userID: Int64) {
    guard userID > 0 else { return }
    linkedTarget = .user(userID)
  }

  private func openTiebaLink(_ target: TiebaLinkTarget) {
    linkedTarget = target
  }

  private func requestAgreementChange(
    _ target: ContentAgreementTarget,
    targetAgreed: Bool
  ) {
    pendingAgreementChange = PendingContentAgreementChange(
      target: target,
      targetAgreed: targetAgreed
    )
  }

  private func confirmAgreementChange(_ change: PendingContentAgreementChange) {
    pendingAgreementChange = nil
    guard let contentAgreementStore else { return }
    Task { @MainActor in
      do {
        try await contentAgreementStore.setAgreed(
          change.targetAgreed,
          for: change.target
        )
      } catch is CancellationError {
        return
      } catch {
        agreementErrorMessage = error.localizedDescription
      }
    }
  }

  private func retryAgreement(_ target: ContentAgreementTarget) {
    guard let contentAgreementStore else { return }
    Task { @MainActor in
      do {
        try await contentAgreementStore.reload(target)
      } catch is CancellationError {
        return
      } catch {
        agreementErrorMessage = error.localizedDescription
      }
    }
  }

  private func commentAuthorIdentity(_ comment: BrowseComment) -> some View {
    PostAuthorIdentityView(
      name: comment.authorName,
      username: comment.authorUsername,
      portraitURL: comment.authorPortraitURL,
      level: comment.authorLevel,
      isThreadAuthor: comment.isThreadAuthor,
      moderatorRole: comment.moderatorRole,
      date: comment.createdAt,
      ipLocation: comment.authorIPLocation,
      avatarSize: 32
    )
  }

  private var navigationTitle: String {
    if let floor = viewModel.parentPost?.floor, floor > 0 {
      return "\(floor) 楼的回复"
    }
    return "楼中楼"
  }
}

private enum CommentsListItemID: Hashable {
  case parentPost(Int64)
  case comment(Int64)
}

private struct CommentsRowRenderKey: Equatable, Sendable {
  let comment: BrowseComment
  let thread: BrowseThread?
  let parentPostID: Int64?
  let agreementTarget: ContentAgreementTarget?
  let replyEntriesVisible: Bool
}

private struct CommentHighlightToken: Equatable {
  let commentID: Int64
  let generation = UUID()
}
