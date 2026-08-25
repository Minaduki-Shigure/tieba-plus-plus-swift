import Combine
import SwiftUI

struct ThreadView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ThreadViewModel
  @State private var sheetRoute: ThreadSheetRoute?
  @State private var showsPageJump = false
  @State private var pageInput = ""
  @State private var scrollPosition = ThreadScrollPosition.empty
  @State private var scrollPositionCoalescer = ThreadScrollPositionCoalescer()
  @State private var linkedTarget: TiebaLinkTarget?
  @State private var restoredHistorySnapshot: ThreadHistorySnapshot?
  @State private var hasRecordedHistoryVisit = false
  @State private var readingMode = ThreadReadingMode.standard
  @State private var pendingImmersiveReadingConfirmation:
    ThreadImmersiveReadingConfirmation?
  @State private var pictureGalleryRoute: ThreadImageGalleryRoute?
  @State private var pictureGalleryPolicyTask: Task<Void, Never>?
  @State private var agreementScopeID = UUID()
  @State private var reportScopeID = UUID()
  @State private var pendingAgreementChange: PendingContentAgreementChange?
  @State private var agreementErrorMessage: String?
  @State private var cloudFavoriteScopeID = UUID()
  @State private var pendingCloudFavoriteAction: ThreadCloudFavoritePendingAction?
  @State private var cloudFavoriteErrorMessage: String?
  @State private var pendingOwnedContentDeletion: PendingOwnedContentDeletion?
  @State private var ownedContentDeletionInProgress: OwnedContentDeletionTarget?
  @State private var ownedContentDeletionUnknownTarget: OwnedContentDeletionTarget?
  @State private var ownedContentDeletionErrorMessage: String?
  @State private var replyComposerContext: TextReplyComposerContext?
  @State private var pendingInboxReplyIntent: InboxReplyIntent?
  @State private var isResolvingInboxReplyIntent = false
  @State private var inboxReplyIntentGeneration = 0
  @State private var inboxReplyNotice: String?
  @State private var inboxReplyComposerIntent: InboxReplyIntent?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss
  @Environment(\.hidesReplyEntryPoints) private var hidesReplyEntryPoints
  @Environment(\.accountAccess) private var accountAccess
  @Environment(\.contentFilterRepository) private var contentFilterRepository
  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @Environment(\.threadCloudFavoriteStore) private var threadCloudFavoriteStore
  @Environment(\.ownedContentDeletionStore) private var ownedContentDeletionStore
  @Environment(\.contentReportCoordinator) private var contentReportCoordinator
  private let historySnapshot: ThreadHistorySnapshot?
  private let linkRoute: TiebaThreadRoute?
  private let onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)?

  init(
    thread: BrowseThread,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    historySnapshot: ThreadHistorySnapshot? = nil,
    linkRoute: TiebaThreadRoute? = nil,
    initialBrowseOptions: ThreadBrowseOptions? = nil,
    initialFocus: ThreadInitialFocus? = nil,
    replyIntent: InboxReplyIntent? = nil,
    onInboxReplyComposerPresented: ((InboxReplyIntent) -> Void)? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.historySnapshot = historySnapshot
    self.linkRoute = linkRoute
    self.onInboxReplyComposerPresented = onInboxReplyComposerPresented
    _pendingInboxReplyIntent = State(initialValue: replyIntent)
    _viewModel = StateObject(
      wrappedValue: ThreadViewModel(
        thread: thread,
        service: service,
        options: initialBrowseOptions ?? linkRoute?.options ?? ThreadBrowseOptions(),
        initialLocation: linkRoute.flatMap { route in
          route.postID.map { ThreadPostLocation.postID($0) }
        },
        initialFocus: initialFocus
      )
    )
  }

  var body: some View {
    Group {
      if viewModel.firstPost == nil && viewModel.posts.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          postList
        }
      } else {
        postList
      }
    }
    .navigationTitle(threadNavigationTitle)
    .environment(\.contentReportScopeID, reportScopeID)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        if !isPureReadingMode {
          optionsBar
        }
        if let ownedContentDeletionInProgress {
          ownedContentDeletionProgress(ownedContentDeletionInProgress)
        } else if let ownedContentDeletionUnknownTarget {
          ownedContentDeletionUnknown(ownedContentDeletionUnknownTarget)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      threadBottomInset
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        navigationPrincipal
      }

      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Menu {
          ForEach(ThreadReadingMode.allCases) { mode in
            Button {
              selectReadingMode(mode)
            } label: {
              Label(
                mode.title,
                systemImage: readingMode == mode ? "checkmark" : mode.systemImage
              )
            }
            .accessibilityLabel(
              readingMode == mode ? "\(mode.title)，当前" : mode.title
            )
          }
        } label: {
          Image(systemName: readingMode.systemImage)
        }
        .accessibilityLabel("阅读模式，当前为 \(readingMode.title)")
        .accessibilityIdentifier("thread-reading-mode-menu")
        .help("阅读模式：\(readingMode.title)")

        if
          let shareURL = TiebaLink.canonicalURL(
            for: .thread(TiebaThreadRoute(threadID: viewModel.thread.id))
          ),
          let copyURL = TiebaLink.threadCopyURL(
            threadID: viewModel.thread.id,
            onlyThreadAuthor: viewModel.options.onlyThreadAuthor
          )
        {
          TiebaShareMenu(
            url: shareURL,
            copyURL: copyURL,
            title: viewModel.thread.title.isEmpty
              ? "帖子 \(viewModel.thread.id)"
              : viewModel.thread.title
          )
        }

        LocalFavoriteButton(target: favoriteTarget, repository: favoritesRepository)

        ThreadCloudFavoriteControlSlot(
          store: threadCloudFavoriteStore,
          target: threadCloudFavoriteTarget,
          currentPosition: currentCloudFavoritePosition,
          requestAction: requestCloudFavoriteAction,
          retry: retryCloudFavorite
        )

        Button {
          pageInput = viewModel.currentPage > 0 ? String(viewModel.currentPage) : ""
          showsPageJump = true
        } label: {
          Image(systemName: "number.square")
        }
        .disabled(
          viewModel.totalPages <= 1
            || viewModel.isJumping
            || viewModel.isCheckingLatestReplies
        )
        .accessibilityLabel("跳转页码")
        .help("跳转页码")

        if !isPureReadingMode {
          ThreadTopicActionsMenu(
            reportTarget: topicReportTarget,
            deletionStore: ownedContentDeletionStore,
            deletionTarget: topicDeletionTarget,
            requestDeletion: requestOwnedContentDeletion
          )
        }
      }
    }
    .alert("跳转页码", isPresented: $showsPageJump) {
      TextField("页码", text: $pageInput)
        .keyboardType(.numberPad)
      Button("跳转") {
        viewModel.jump(toPage: Int(pageInput) ?? 0)
      }
      Button("取消", role: .cancel) {}
    } message: {
      if viewModel.totalPages > 0 {
        Text("当前第 \(max(viewModel.currentPage, 1)) 页，共 \(viewModel.totalPages) 页")
      }
    }
    .confirmationDialog(
      "进入沉浸阅读？",
      isPresented: immersiveReadingConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      if let pendingImmersiveReadingConfirmation {
        Button("进入并回到第一页") {
          confirmImmersiveReading(pendingImmersiveReadingConfirmation)
        }
      }
      Button("取消", role: .cancel) {
        pendingImmersiveReadingConfirmation = nil
      }
    } message: {
      Text(
        "将回到第 1 页并只加载楼主内容。退出沉浸阅读后仍会保持“只看楼主”，可在帖子顶部关闭。"
      )
    }
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
    .confirmationDialog(
      pendingCloudFavoriteAction?.title ?? "更新贴吧云收藏？",
      isPresented: cloudFavoriteConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      if let pendingCloudFavoriteAction {
        if pendingCloudFavoriteAction.isDestructive {
          Button(pendingCloudFavoriteAction.actionTitle, role: .destructive) {
            confirmCloudFavoriteAction(pendingCloudFavoriteAction)
          }
        } else {
          Button(pendingCloudFavoriteAction.actionTitle) {
            confirmCloudFavoriteAction(pendingCloudFavoriteAction)
          }
        }
      }
      Button("取消", role: .cancel) { pendingCloudFavoriteAction = nil }
    } message: {
      Text(pendingCloudFavoriteAction?.message ?? "")
    }
    .confirmationDialog(
      pendingOwnedContentDeletion?.confirmationTitle ?? "删除本人内容？",
      isPresented: ownedContentDeletionConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      if let pendingOwnedContentDeletion {
        Button(pendingOwnedContentDeletion.actionTitle, role: .destructive) {
          confirmOwnedContentDeletion(pendingOwnedContentDeletion)
        }
      }
      Button("取消", role: .cancel) { pendingOwnedContentDeletion = nil }
    } message: {
      Text(pendingOwnedContentDeletion?.confirmationMessage ?? "")
    }
    .alert("无法更新点赞状态", isPresented: agreementErrorIsPresented) {
      Button("好", role: .cancel) { agreementErrorMessage = nil }
    } message: {
      Text(agreementErrorMessage ?? "无法完成点赞操作。")
    }
    .alert("无法更新贴吧云收藏", isPresented: cloudFavoriteErrorIsPresented) {
      Button("重新读取") {
        cloudFavoriteErrorMessage = nil
        if let target = threadCloudFavoriteTarget {
          retryCloudFavorite(target)
        }
      }
      Button("好", role: .cancel) { cloudFavoriteErrorMessage = nil }
    } message: {
      Text(cloudFavoriteErrorMessage ?? "无法完成云收藏操作。")
    }
    .alert("无法删除内容", isPresented: ownedContentDeletionErrorIsPresented) {
      Button("好", role: .cancel) { ownedContentDeletionErrorMessage = nil }
    } message: {
      Text(ownedContentDeletionErrorMessage ?? "无法完成删除操作。")
    }
    .fullScreenCover(
      item: $pictureGalleryRoute,
      onDismiss: cancelPictureGallery
    ) { route in
      ThreadImageGalleryView(viewModel: route.viewModel)
    }
    .task {
      let snapshot: ThreadHistorySnapshot?
      if linkRoute == nil {
        snapshot = await resumeSnapshot()
      } else {
        snapshot = nil
      }
      guard !Task.isCancelled else { return }
      restoredHistorySnapshot = snapshot
      if let snapshot {
        viewModel.prepareResume(
          options: snapshot.browseOptions,
          postID: snapshot.lastPostID
        )
      }
      viewModel.loadIfNeeded()
    }
    .task(
      id: ContentAgreementRegistrationTaskID(
        descriptorEpoch: viewModel.agreementDescriptorEpoch,
        isEnabled: !isPureReadingMode
      )
    ) {
      guard let contentAgreementStore else { return }
      guard !isPureReadingMode else {
        contentAgreementStore.removeScope(agreementScopeID)
        return
      }
      await contentAgreementStore.replaceDescriptors(
        viewModel.agreementReadDescriptors,
        for: agreementScopeID
      )
    }
    .task(id: threadCloudFavoriteTarget) {
      guard let threadCloudFavoriteStore, let target = threadCloudFavoriteTarget else {
        threadCloudFavoriteStore?.deactivate(cloudFavoriteScopeID)
        return
      }
      await threadCloudFavoriteStore.activate(target, for: cloudFavoriteScopeID)
    }
    .task(
      id: InboxReplyIntentResolutionTaskID(
        loadState: viewModel.state,
        hidesReplyEntryPoints: hidesReplyEntryPoints
      )
    ) {
      await consumeInboxReplyIntentIfReady()
    }
    .task(id: viewModel.state) {
      if viewModel.state == .loaded, let ownedContentDeletionStore {
        ownedContentDeletionUnknownTarget = ownedContentDeletionStore.outcomeUnknownTarget(
          threadID: viewModel.thread.id
        )
      }
      guard
        !hasRecordedHistoryVisit,
        !Task.isCancelled,
        viewModel.state == .loaded,
        !viewModel.thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      hasRecordedHistoryVisit = true
      let requestedPostID = restoredHistorySnapshot?.lastPostID ?? linkRoute?.postID
      let resolvedPost = requestedPostID.flatMap { postID in
        viewModel.post(withID: postID).flatMap {
          $0.localVisibility == .hidden ? nil : $0
        }
      }
      try? await historyRepository.record(
        .thread(
          ThreadHistorySnapshot(
            thread: viewModel.thread,
            resolvedAuthorAvatarURL: threadAuthorAvatarURL,
            browseOptions: viewModel.options,
            lastPostID: resolvedPost?.id,
            lastFloor: resolvedPost?.floor
          )
        )
      )
    }
    .task(
      id: ThreadProgressTaskID(
        postID: visiblePost?.id,
        isRestoringPrependPosition: viewModel.isRestoringPrependPosition
      )
    ) {
      guard let visiblePost, !viewModel.isRestoringPrependPosition else { return }
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard !Task.isCancelled, !viewModel.isRestoringPrependPosition else { return }
      await persistProgress(visiblePost, options: viewModel.options)
    }
    .onChange(of: viewModel.options) { options in
      pendingImmersiveReadingConfirmation = nil
      let normalizedMode = ThreadReadingModePolicy.normalized(
        readingMode,
        options: options
      )
      if normalizedMode != readingMode {
        setReadingMode(normalizedMode)
      }
      cancelPictureGallery()
      scrollPositionCoalescer.reset()
      scrollPosition = .empty
      persistBrowseOptions(options)
    }
    .onDisappear {
      scrollPositionCoalescer.cancelPendingPublication()
      if let latestVisiblePost, !viewModel.isRestoringPrependPosition {
        let options = viewModel.options
        Task { await persistProgress(latestVisiblePost, options: options) }
      } else {
        persistBrowseOptions(viewModel.options)
      }
      cancelPictureGallery()
      contentReportCoordinator?.invalidate(scopeID: reportScopeID)
      pendingAgreementChange = nil
      pendingImmersiveReadingConfirmation = nil
      pendingCloudFavoriteAction = nil
      pendingOwnedContentDeletion = nil
      ownedContentDeletionErrorMessage = nil
      clearSelectableTextRoute()
      contentAgreementStore?.removeScope(agreementScopeID)
      threadCloudFavoriteStore?.deactivate(cloudFavoriteScopeID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      invalidateInboxReplyIntentForAccountChange()
      pendingAgreementChange = nil
      agreementErrorMessage = nil
      pendingCloudFavoriteAction = nil
      cloudFavoriteErrorMessage = nil
      pendingOwnedContentDeletion = nil
      ownedContentDeletionErrorMessage = nil
    }
    .onChange(of: replyComposerContext) { context in
      if context == nil {
        inboxReplyComposerIntent = nil
      }
    }
    .onChange(of: hidesReplyEntryPoints) { isHidden in
      if isHidden {
        invalidatePendingInboxReplyIntentForHiddenPreference()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      cancelPictureGallery()
      contentReportCoordinator?.invalidate(scopeID: reportScopeID)
      pendingCloudFavoriteAction = nil
      clearSelectableTextRoute()
      scrollPositionCoalescer.reset()
      Task { @MainActor in
        scrollPosition = .empty
        viewModel.reload()
      }
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
    .sheet(item: $sheetRoute) { route in
      switch route {
      case .comments(let commentsRoute):
        NavigationStack {
          switch commentsRoute {
          case .post(let threadID, let postID):
            CommentsView(
              threadID: threadID,
              postID: postID,
              service: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          case .comment(let threadID, let postID, let commentID):
            CommentsView(
              threadID: threadID,
              postID: postID,
              aroundCommentID: commentID,
              service: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      case .selectableText(let presentation):
        SelectableTextSheet(
          presentation: presentation,
          onCommand: performSelectableTextCommand
        )
      }
    }
  }

  private var linkedTargetPresented: Binding<Bool> {
    Binding(
      get: { linkedTarget != nil },
      set: { isPresented in
        if !isPresented { linkedTarget = nil }
      }
    )
  }

  private var replyComposerPresented: Binding<Bool> {
    Binding(
      get: { replyComposerContext != nil },
      set: { isPresented in
        if !isPresented { replyComposerContext = nil }
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

  private func presentComments(threadID: Int64, postID: Int64, commentID: Int64?) {
    guard let route = CommentsRoute(
      threadID: threadID,
      postID: postID,
      commentID: commentID
    ) else { return }
    sheetRoute = .comments(route)
  }

  private func presentSelectableText(_ text: String) {
    guard let presentation = SelectableTextPresentation(text: text) else { return }
    sheetRoute = .selectableText(presentation)
  }

  private func clearSelectableTextRoute() {
    guard case .selectableText = sheetRoute else { return }
    sheetRoute = nil
  }

  private func performSelectableTextCommand(
    _ command: SelectableTextSheetCommand,
    expected: SelectableTextPresentation
  ) {
    guard case .selectableText(let current)? = sheetRoute else { return }
    var pending: SelectableTextPresentation? = current
    let text = SelectableTextSheetCommandPolicy.consume(
      command,
      expected: expected,
      pending: &pending
    )
    guard pending == nil else { return }
    sheetRoute = nil
    if let text {
      SelectableTextPasteboard.write(text)
    }
  }

  @ViewBuilder
  private var threadBottomInset: some View {
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
      } else if let message = viewModel.jumpError {
        if viewModel.canRetryJump {
          LoadMoreErrorView(message: message, retry: viewModel.retryJump)
            .padding(.horizontal, 12)
        } else {
          HStack(spacing: 10) {
            Text(message)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: viewModel.dismissJumpError) {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
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
      }

      if replyEntriesVisible, let context = topicReplyContext {
        Divider()
        Button {
          guard replyEntriesVisible else { return }
          replyComposerContext = context
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "bubble.left")
            Text("回复主题")
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
        .accessibilityIdentifier("thread-reply-topic")
      }
    }
    .background(.regularMaterial)
  }

  private var topicReplyContext: TextReplyComposerContext? {
    guard let firstPost = viewModel.firstPost else { return nil }
    return TextReplyComposerContext(thread: viewModel.thread, firstPost: firstPost)
  }

  private func ownedContentDeletionProgress(
    _ target: OwnedContentDeletionTarget
  ) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(target.kind == .topic ? "正在删除主题" : "正在删除第 \(target.floor) 楼")
        .font(.footnote)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 40)
    .background(.regularMaterial)
    .accessibilityIdentifier("owned-content-deletion-progress")
  }

  private func ownedContentDeletionUnknown(
    _ target: OwnedContentDeletionTarget
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(
        target.kind == .topic
          ? "主题删除结果未确认，请在官方客户端核对，勿立即重试"
          : "第 \(target.floor) 楼删除结果未确认，请在官方客户端核对，勿立即重试"
      )
      .font(.footnote)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 40)
    .background(.regularMaterial)
    .accessibilityIdentifier("owned-content-deletion-unknown")
  }

  private var topicReportTarget: ContentReportTarget? {
    guard let firstPost = viewModel.firstPost else { return nil }
    return ContentReportTarget(thread: viewModel.thread, post: firstPost)
  }

  private var topicDeletionTarget: OwnedContentDeletionTarget? {
    guard let firstPost = viewModel.firstPost else { return nil }
    return OwnedContentDeletionTarget(thread: viewModel.thread, post: firstPost)
  }

  private var replyEntriesVisible: Bool {
    ReplyEntryVisibilityPolicy(
      preferenceHidden: hidesReplyEntryPoints,
      pureReading: isPureReadingMode,
      contextAvailable: true
    ).showsReplyEntry
  }

  private func requestReply(to post: BrowsePost) {
    guard replyEntriesVisible else { return }
    if
      let firstPost = viewModel.firstPost,
      firstPost.id == post.id,
      let context = TextReplyComposerContext(thread: viewModel.thread, firstPost: firstPost)
    {
      replyComposerContext = context
    } else {
      replyComposerContext = TextReplyComposerContext(thread: viewModel.thread, post: post)
    }
  }

  private func requestReply(
    toCommentID commentID: Int64,
    inParentPostID parentPostID: Int64
  ) {
    guard
      let parentPost = viewModel.post(withID: parentPostID),
      let comment = parentPost.inlineComments.first(where: { $0.id == commentID }),
      let presentation = InlineCommentReplyPresentation(
        thread: viewModel.thread,
        parentPost: parentPost,
        comment: comment,
        replyEntriesVisible: replyEntriesVisible
      )
    else { return }
    replyComposerContext = presentation.context
  }

  private func consumeInboxReplyIntentIfReady() async {
    let pendingIntent = pendingInboxReplyIntent
    guard
      let intent = InboxReplyIntentAdmissionPolicy.admittedIntent(
        pendingIntent,
        hidesReplyEntryPoints: hidesReplyEntryPoints
      )
    else {
      if pendingInboxReplyIntent != nil {
        pendingInboxReplyIntent = nil
        inboxReplyNotice = "已在设置中隐藏回复入口，未打开回复编辑器。"
      }
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
      intent.threadID == viewModel.thread.id,
      case .post(let postID) = intent.target,
      let post = viewModel.post(withID: postID),
      post.id == postID,
      post.threadID == intent.threadID,
      viewModel.thread.localVisibility == .visible,
      post.localVisibility == .visible
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
          thread: viewModel.thread,
          post: post
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
    let hadPendingIntent = pendingInboxReplyIntent != nil || isResolvingInboxReplyIntent
    inboxReplyIntentGeneration &+= 1
    pendingInboxReplyIntent = nil
    isResolvingInboxReplyIntent = false
    if hadPendingIntent {
      inboxReplyNotice = "已在设置中隐藏回复入口，未打开回复编辑器。"
    }
  }

  private func verifyReplyVisibility(
    _ submission: TextReplySubmission,
    receipt: TextReplyReceipt,
    imageUploads: [ComposerImageUploadResult]
  ) async throws
    -> TextReplyVisibilityConfirmation?
  {
    guard
      let context = replyComposerContext,
      context.target == submission.target,
      receipt.belongs(to: submission.target)
    else { throw TextReplySubmissionError.invalidSubmission }
    switch receipt {
    case .post(let postID):
      guard
        let post = await viewModel.verifyAndRelocateAcceptedReply(postID: postID),
        post.id == postID,
        post.threadID == viewModel.thread.id,
        post.id != viewModel.thread.firstPostID,
        post.floor > 1
      else { return nil }
      let content: String
      if submission.attachments.isEmpty {
        guard
          imageUploads.isEmpty,
          let exactContent = TextReplyVisibilityProof.exactPlainText(
            from: post.contents,
            matching: submission.content
          )
        else { return nil }
        content = exactContent
      } else {
        guard
          ReplyComposerImagePolicy.allowsAttachments(for: submission.target),
          TextReplyImageVisibilityProof.exactDirectTopicReply(
            from: post.contents,
            matching: submission.content,
            uploads: imageUploads
          )
        else { return nil }
        content = submission.content
      }
      return TextReplyVisibilityConfirmation(
        created: .post(postID: post.id, floor: post.floor),
        authorUserID: post.authorID,
        content: content,
        attachments: submission.attachments,
        imageWatermark: submission.imageWatermark
      )
    case .subpost(let parentPostID, let subpostID):
      guard
        submission.attachments.isEmpty,
        imageUploads.isEmpty,
        let comment = try await viewModel.verifyAcceptedSubpost(
          parentPostID: parentPostID,
          subpostID: subpostID
        ),
        comment.id == subpostID,
        comment.threadID == viewModel.thread.id,
        comment.parentPostID == parentPostID
      else { return nil }
      let content: String?
      switch context.target.destination {
      case .subpost(let expectedParentPostID, _):
        guard expectedParentPostID == parentPostID else { return nil }
        guard let expectedReplyToUserID = context.replyingToUserID else { return nil }
        content = TextReplyVisibilityProof.exactNestedReplyBody(
          from: comment,
          expectedReplyToUserID: expectedReplyToUserID,
          matching: submission.content
        )
      case .post(let expectedParentPostID):
        guard expectedParentPostID == parentPostID else { return nil }
        content = TextReplyVisibilityProof.exactPlainText(
          from: comment.contents,
          matching: submission.content
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
      if viewModel.scrollTargetPostID != postID {
        viewModel.relocateAfterConfirmedReply(postID: postID)
      }
    case .subpost(let parentPostID, let subpostID):
      presentComments(
        threadID: viewModel.thread.id,
        postID: parentPostID,
        commentID: subpostID
      )
    }
  }

  private var optionsBar: some View {
    VStack(spacing: 0) {
      Group {
        if AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize) {
          VStack(alignment: .leading, spacing: 8) {
            threadSortPicker
            threadAuthorToggle
          }
        } else {
          HStack(spacing: 12) {
            threadSortPicker
            threadAuthorToggle
              .fixedSize()
          }
        }
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Divider()
    }
  }

  private var threadSortPicker: some View {
    Picker(
      "楼层排序",
      selection: Binding(
        get: { viewModel.options.sort },
        set: { sort in viewModel.setSort(sort) }
      )
    ) {
      ForEach(ThreadPostSort.allCases) { sort in
        Text(sort.title).tag(sort)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: .infinity, minHeight: 32)
    .accessibilityIdentifier("thread-sort-picker")
  }

  private var threadAuthorToggle: some View {
    Toggle(
      "只看楼主",
      isOn: Binding(
        get: { viewModel.options.onlyThreadAuthor },
        set: { onlyThreadAuthor in viewModel.setOnlyThreadAuthor(onlyThreadAuthor) }
      )
    )
    .toggleStyle(.switch)
    .controlSize(.small)
    .accessibilityIdentifier("thread-author-toggle")
  }

  private var postList: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            if let firstPost = viewModel.firstPost {
              LocallyFilteredContent(
                visibility: effectiveVisibility(for: firstPost),
                placeholder: "已屏蔽主题首楼"
              ) {
                VStack(spacing: 0) {
                  PostView(
                    post: firstPost,
                    forumID: viewModel.thread.forumID,
                    agreementTarget: viewModel.agreementTarget(forPostID: firstPost.id),
                    agreementFallbackScore: viewModel.thread.agreeScore,
                    originThread: viewModel.originThread,
                    poll: viewModel.poll,
                    service: service,
                    historyRepository: historyRepository,
                    favoritesRepository: favoritesRepository,
                    searchHistoryRepository: searchHistoryRepository,
                    selectableThreadTitle: selectableThreadTitle(for: firstPost),
                    isPureReadingMode: isPureReadingMode,
                    openImage: { contentOffset in
                      openPictureGallery(post: firstPost, contentOffset: contentOffset)
                    },
                    openMentionedUser: openMentionedUser,
                    openTiebaLink: openTiebaLink,
                    requestAgreementChange: requestAgreementChange,
                    retryAgreement: retryAgreement,
                    cloudFavoriteTarget: threadCloudFavoriteTarget,
                    requestCloudFavoriteAction: requestFloorCloudFavoriteAction,
                    requestReply: replyEntriesVisible ? {
                      requestReply(to: firstPost)
                    } : nil,
                    requestInlineCommentReply: replyEntriesVisible
                      ? { comment in
                        requestReply(
                          toCommentID: comment.id,
                          inParentPostID: firstPost.id
                        )
                      }
                      : nil,
                    requestReplyIsAvailable: replyEntriesVisible,
                    requestInlineCommentReplyIsAvailable: replyEntriesVisible,
                    reportThread: viewModel.thread,
                    reportTarget: isPureReadingMode
                      ? nil
                      : ContentReportTarget(thread: viewModel.thread, post: firstPost),
                    deletionTarget: nil,
                    requestDeletion: requestOwnedContentDeletion,
                    openComments: { commentID in
                      presentComments(
                        threadID: firstPost.threadID,
                        postID: firstPost.id,
                        commentID: commentID
                      )
                    },
                    selectText: presentSelectableText
                  )
                  .equatable()
                  Divider()
                    .padding(.leading, isPureReadingMode ? 0 : 52)
                }
              }
              .background {
                if #available(iOS 18.0, *) {
                  EmptyView()
                } else {
                  ThreadPostVisibilityReader(
                    postID: firstPost.id,
                    viewportHeight: viewport.size.height,
                    tracksReadingProgress: effectiveVisibility(for: firstPost) == .visible,
                    tracksPrependAnchor: false
                  )
                }
              }
              .id(firstPost.id)
            }

            if viewModel.isLoadingPrevious {
              ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else if let message = viewModel.loadPreviousError {
              LoadMoreErrorView(message: message, retry: viewModel.retryLoadPrevious)
                .disabled(
                  viewModel.isLoadingMore
                    || viewModel.isJumping
                    || viewModel.isCheckingLatestReplies
                )
            } else if viewModel.canLoadPrevious, !viewModel.isJumping {
              Button {
                viewModel.loadPrevious(anchorPostID: prependAnchorPostID)
              } label: {
                Label("加载更早楼层", systemImage: "arrow.up")
                  .font(.subheadline)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.tint)
              .disabled(
                viewModel.isLoadingMore
                  || viewModel.isAdjustingPrependPosition
                  || viewModel.isCheckingLatestReplies
              )
              .accessibilityIdentifier("thread-load-previous")
            }

            ForEach(viewModel.posts) { post in
              LocallyFilteredContent(
                visibility: effectiveVisibility(for: post),
                placeholder: post.floor > 0 ? "已屏蔽第 \(post.floor) 楼" : "已屏蔽此楼层"
              ) {
                VStack(spacing: 0) {
                  PostView(
                    post: post,
                    forumID: viewModel.thread.forumID,
                    agreementTarget: viewModel.agreementTarget(forPostID: post.id),
                    agreementFallbackScore: post.agreeScore,
                    originThread: nil,
                    poll: nil,
                    service: service,
                    historyRepository: historyRepository,
                    favoritesRepository: favoritesRepository,
                    searchHistoryRepository: searchHistoryRepository,
                    selectableThreadTitle: selectableThreadTitle(for: post),
                    isPureReadingMode: isPureReadingMode,
                    openImage: { contentOffset in
                      openPictureGallery(post: post, contentOffset: contentOffset)
                    },
                    openMentionedUser: openMentionedUser,
                    openTiebaLink: openTiebaLink,
                    requestAgreementChange: requestAgreementChange,
                    retryAgreement: retryAgreement,
                    cloudFavoriteTarget: threadCloudFavoriteTarget,
                    requestCloudFavoriteAction: requestFloorCloudFavoriteAction,
                    requestReply: replyEntriesVisible ? {
                      requestReply(to: post)
                    } : nil,
                    requestInlineCommentReply: replyEntriesVisible
                      ? { comment in
                        requestReply(
                          toCommentID: comment.id,
                          inParentPostID: post.id
                        )
                      }
                      : nil,
                    requestReplyIsAvailable: replyEntriesVisible,
                    requestInlineCommentReplyIsAvailable: replyEntriesVisible,
                    reportThread: viewModel.thread,
                    reportTarget: isPureReadingMode
                      ? nil
                      : ContentReportTarget(thread: viewModel.thread, post: post),
                    deletionTarget: isPureReadingMode
                      ? nil
                      : OwnedContentDeletionTarget(thread: viewModel.thread, post: post),
                    requestDeletion: requestOwnedContentDeletion,
                    openComments: { commentID in
                      presentComments(
                        threadID: post.threadID,
                        postID: post.id,
                        commentID: commentID
                      )
                    },
                    selectText: presentSelectableText
                  )
                  .equatable()
                  Divider()
                    .padding(.leading, isPureReadingMode ? 0 : 52)
                }
              }
              .background {
                if #available(iOS 18.0, *) {
                  EmptyView()
                } else {
                  ThreadPostVisibilityReader(
                    postID: post.id,
                    viewportHeight: viewport.size.height,
                    tracksReadingProgress: effectiveVisibility(for: post) == .visible,
                    tracksPrependAnchor: true
                  )
                }
              }
              .id(post.id)
              .onAppear {
                viewModel.loadMoreIfNeeded(current: post)
              }
            }
            if viewModel.firstPost == nil && viewModel.posts.isEmpty && viewModel.state == .loaded {
              EmptyStateView(title: "暂无楼层", systemImage: "bubble.left.and.bubble.right")
                .padding(.vertical, 24)
            }
            Color.clear
              .frame(height: 1)
              .accessibilityHidden(true)
              .onAppear { viewModel.loadMoreIfNeeded() }
            if viewModel.isLoadingMore || viewModel.isJumping {
              ProgressView()
                .padding(20)
            } else if let message = viewModel.loadMoreError {
              LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
            } else if viewModel.isCheckingLatestReplies {
              ProgressView()
                .padding(20)
                .accessibilityLabel("正在检查新回复")
            } else if let message = viewModel.latestRepliesError {
              LoadMoreErrorView(message: message, retry: viewModel.retryLatestReplies)
            } else if viewModel.canCheckLatestReplies {
              Button(action: viewModel.checkLatestReplies) {
                Label("检查新回复", systemImage: "arrow.clockwise")
                  .font(.subheadline)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 12)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.tint)
              .accessibilityIdentifier("thread-check-latest-replies")
            }
          }
          .modifier(ThreadScrollTargetLayoutModifier())
        }
        .coordinateSpace(name: "thread-scroll")
        .onPreferenceChange(ThreadScrollPositionPreferenceKey.self) { position in
          if #available(iOS 18.0, *) { return }
          updateScrollPosition(position)
        }
        .modifier(
          ThreadNativeScrollVisibilityModifier(
            onChange: { visiblePostIDs in
              updateScrollPosition(visiblePostIDs: visiblePostIDs)
            }
          )
        )
        #if PERFORMANCE_HARNESS
          .task {
            await runPerformanceAutoscroll(proxy: proxy)
          }
        #endif
        .task(id: viewModel.scrollTargetPostID) {
          guard let postID = viewModel.scrollTargetPostID else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          proxy.scrollTo(postID, anchor: .top)
          viewModel.consumeScrollTarget()
        }
        .task(id: viewModel.prependRestoreSequence) {
          guard viewModel.isRestoringPrependPosition else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          if let postID = viewModel.prependRestorePostID {
            proxy.scrollTo(postID, anchor: .top)
          }
          viewModel.consumePrependRestoreTarget()
        }
        .refreshable { await viewModel.refresh() }
      }
    }
  }

  @ViewBuilder
  private var navigationPrincipal: some View {
    if let forumName = forumNavigationName {
      NavigationLink {
        ForumView(
          forumName: forumName,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        Label("\(forumName)吧", systemImage: "text.bubble")
          .font(.headline)
          .lineLimit(1)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("进入\(forumName)吧")
    } else {
      Text(threadNavigationTitle)
        .font(.headline)
        .lineLimit(1)
    }
  }

  private var forumNavigationName: String? {
    let name = viewModel.thread.forumName.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return name.isEmpty ? nil : name
  }

  private var threadNavigationTitle: String {
    viewModel.thread.title.isEmpty ? viewModel.thread.forumName : viewModel.thread.title
  }

  private func resumeSnapshot() async -> ThreadHistorySnapshot? {
    if let historySnapshot {
      return historySnapshot
    }
    guard
      let entry = try? await historyRepository.entries(kind: .thread)
        .first(where: { $0.id == "thread:\(viewModel.thread.id)" }),
      case .thread(let snapshot) = entry.target
    else {
      return nil
    }
    return snapshot
  }

  private func persistBrowseOptions(_ options: ThreadBrowseOptions) {
    let repository = historyRepository
    let favoritesRepository = favoritesRepository
    let threadID = viewModel.thread.id
    let updatedAt = Date()
    Task {
      try? await repository.updateThreadOptions(
        threadID: threadID,
        options: options,
        at: updatedAt
      )
      try? await favoritesRepository.updateThreadOptions(
        threadID: threadID,
        options: options,
        at: updatedAt
      )
    }
  }

  private func persistProgress(
    _ post: BrowsePost,
    options: ThreadBrowseOptions
  ) async {
    let updatedAt = Date()
    try? await historyRepository.updateThreadProgress(
      threadID: viewModel.thread.id,
      postID: post.id,
      floor: post.floor,
      options: options,
      at: updatedAt
    )
    try? await favoritesRepository.updateThreadProgress(
      threadID: viewModel.thread.id,
      postID: post.id,
      floor: post.floor,
      options: options,
      at: updatedAt
    )
  }

  private func effectiveVisibility(for post: BrowsePost) -> LocalContentVisibility {
    guard isPureReadingMode, post.localVisibility != .visible else {
      return post.localVisibility
    }
    return .hidden
  }

  private func updateScrollPosition(visiblePostIDs: [Int64]) {
    updateScrollPosition(
      ThreadScrollPositionResolver.position(
        visiblePostIDs: visiblePostIDs,
        targetsByPostID: viewModel.scrollTargetsByPostID,
        hidesLocallyFilteredContent: isPureReadingMode
      )
    )
  }

  private func updateScrollPosition(_ position: ThreadScrollPosition) {
    scrollPositionCoalescer.submit(position) { position in
      guard position != scrollPosition else { return }
      scrollPosition = position
    }
  }

  #if PERFORMANCE_HARNESS
    @MainActor
    private func runPerformanceAutoscroll(proxy: ScrollViewProxy) async {
      guard ThreadScrollPerformanceScenario.isSelfDrivenProfileRequested else { return }

      do {
        var targetIDs: [Int64] = []
        for _ in 0..<50 {
          targetIDs = ([viewModel.firstPost].compactMap { $0 } + viewModel.posts).map(\.id)
          if targetIDs.count > 1 { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        let initialTargetIndex = ThreadScrollPerformanceScenario.requested == .manyFloors
          ? min(60, max(targetIDs.count - 21, 0))
          : 0
        if initialTargetIndex > 0 {
          proxy.scrollTo(targetIDs[initialTargetIndex], anchor: .top)
          try await Task.sleep(for: .seconds(1))
        }
        let forwardTargets = Array(
          targetIDs.dropFirst(initialTargetIndex + 1).prefix(20)
        )
        guard !forwardTargets.isEmpty else { return }

        guard ThreadScrollPerformanceScenario.writeSelfDrivenProfileMarker(phase: "ready") else {
          assertionFailure("Could not mark the performance fixture as ready")
          return
        }
        guard try await ThreadScrollPerformanceScenario.waitForSelfDrivenProfileStart() else {
          return
        }
        guard ThreadScrollPerformanceScenario.writeSelfDrivenProfileMarker(phase: "started") else {
          assertionFailure("Could not mark the performance autoscroll as started")
          return
        }
        let backwardTargets = Array(forwardTargets.dropLast().reversed())
        for targetID in forwardTargets + backwardTargets + forwardTargets {
          try Task.checkCancellation()
          withAnimation(.linear(duration: 0.22)) {
            proxy.scrollTo(targetID, anchor: .top)
          }
          try await Task.sleep(for: .milliseconds(260))
        }
        guard ThreadScrollPerformanceScenario.writeSelfDrivenProfileMarker(phase: "completed") else {
          assertionFailure("Could not mark the performance autoscroll as completed")
          return
        }
      } catch is CancellationError {
        return
      } catch {
        assertionFailure("Unexpected performance autoscroll failure: \(error)")
      }
    }
  #endif

  private func selectableThreadTitle(for post: BrowsePost) -> String? {
    let thread = viewModel.thread
    guard
      thread.localVisibility == .visible,
      post.localVisibility == .visible,
      post.threadID == thread.id,
      post.id == thread.firstPostID,
      post.floor == 1
    else { return nil }
    return thread.title
  }

  private func openPictureGallery(post: BrowsePost, contentOffset: Int) {
    let remoteService = service as? any ThreadPictureGalleryService
    guard
      effectiveVisibility(for: post) == .visible,
      let route = ThreadImageGalleryRouteFactory.make(
        context: ThreadPictureGalleryContext(
          forumID: viewModel.thread.forumID,
          forumName: viewModel.thread.forumName,
          threadID: viewModel.thread.id,
          onlyThreadAuthor: viewModel.options.onlyThreadAuthor
        ),
        postID: post.id,
        contents: post.contents,
        selectedContentOffset: contentOffset,
        remoteService: remoteService
      )
    else { return }
    let galleryViewModel = route.viewModel
    pictureGalleryRoute = route

    guard remoteService != nil, self.viewModel.thread.kind == .article else { return }
    let repository = contentFilterRepository
    pictureGalleryPolicyTask = Task { @MainActor in
      do {
        let snapshot = try await repository.snapshot()
        try Task.checkCancellation()
        guard pictureGalleryRoute?.id == route.id else { return }
        galleryViewModel.setRemoteLoadingEnabled(snapshot.allowsWholeThreadPictureGallery)
      } catch {
        // Reading the local policy is fail-closed; the same-floor gallery stays available.
      }
    }
  }

  private func cancelPictureGallery() {
    pictureGalleryPolicyTask?.cancel()
    pictureGalleryPolicyTask = nil
    pictureGalleryRoute?.viewModel.cancel()
    pictureGalleryRoute = nil
  }

  private var prependAnchorPostID: Int64? {
    if
      let leadingVisiblePostID = scrollPositionCoalescer.latestPosition.prependAnchorPostID,
      let leadingPost = viewModel.post(withID: leadingVisiblePostID),
      effectiveVisibility(for: leadingPost) != .hidden
    {
      return leadingVisiblePostID
    }
    return isPureReadingMode
      ? viewModel.firstVisibleReplyPostID
      : viewModel.firstDisplayableReplyPostID
  }

  private var favoriteTarget: LocalFavoriteTarget {
    let progress = viewModel.options.sort == .hot ? nil : visiblePost
    return .thread(
      ThreadHistorySnapshot(
        thread: viewModel.thread,
        resolvedAuthorAvatarURL: threadAuthorAvatarURL,
        browseOptions: viewModel.options,
        lastPostID: progress?.id,
        lastFloor: progress?.floor
      )
    )
  }

  private var visiblePost: BrowsePost? {
    guard let postID = scrollPosition.readingProgressPostID else { return nil }
    return viewModel.post(withID: postID)
  }

  private var latestVisiblePost: BrowsePost? {
    guard let postID = scrollPositionCoalescer.latestPosition.readingProgressPostID else {
      return visiblePost
    }
    return viewModel.post(withID: postID)
  }

  private var threadCloudFavoriteTarget: ThreadCloudFavoriteTarget? {
    ThreadCloudFavoriteTarget(
      forumID: viewModel.thread.forumID,
      forumName: viewModel.thread.forumName,
      threadID: viewModel.thread.id
    )
  }

  private var currentCloudFavoritePosition: ThreadCloudFavoritePosition? {
    let threadID = viewModel.thread.id
    if let visiblePost,
       effectiveVisibility(for: visiblePost) == .visible,
       let position = ThreadCloudFavoritePosition(post: visiblePost, threadID: threadID)
    {
      return position
    }
    if let firstPost = viewModel.firstPost,
       effectiveVisibility(for: firstPost) == .visible,
       let position = ThreadCloudFavoritePosition(post: firstPost, threadID: threadID)
    {
      return position
    }
    guard
      let firstVisibleReplyPostID = viewModel.firstVisibleReplyPostID,
      let firstVisibleReply = viewModel.post(withID: firstVisibleReplyPostID),
      effectiveVisibility(for: firstVisibleReply) == .visible
    else { return nil }
    return ThreadCloudFavoritePosition(post: firstVisibleReply, threadID: threadID)
  }

  private var threadAuthorAvatarURL: URL? {
    viewModel.resolvedThreadAuthorAvatarURL
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

  private var cloudFavoriteConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingCloudFavoriteAction != nil },
      set: { isPresented in
        if !isPresented { pendingCloudFavoriteAction = nil }
      }
    )
  }

  private var cloudFavoriteErrorIsPresented: Binding<Bool> {
    Binding(
      get: { cloudFavoriteErrorMessage != nil },
      set: { isPresented in
        if !isPresented { cloudFavoriteErrorMessage = nil }
      }
    )
  }

  private var ownedContentDeletionConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingOwnedContentDeletion != nil },
      set: { isPresented in
        if !isPresented { pendingOwnedContentDeletion = nil }
      }
    )
  }

  private var ownedContentDeletionErrorIsPresented: Binding<Bool> {
    Binding(
      get: { ownedContentDeletionErrorMessage != nil },
      set: { isPresented in
        if !isPresented { ownedContentDeletionErrorMessage = nil }
      }
    )
  }

  private var immersiveReadingConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingImmersiveReadingConfirmation != nil },
      set: { isPresented in
        if !isPresented { pendingImmersiveReadingConfirmation = nil }
      }
    )
  }

  private var isPureReadingMode: Bool { readingMode.usesPurePresentation }

  private func selectReadingMode(_ requestedMode: ThreadReadingMode) {
    switch ThreadReadingModePolicy.selection(
      for: requestedMode,
      threadID: viewModel.thread.id,
      options: viewModel.options
    ) {
    case .apply(let mode):
      pendingImmersiveReadingConfirmation = nil
      setReadingMode(mode)
    case .confirmImmersive(let confirmation):
      pendingImmersiveReadingConfirmation = confirmation
    case .ignore:
      pendingImmersiveReadingConfirmation = nil
    }
  }

  private func confirmImmersiveReading(
    _ confirmation: ThreadImmersiveReadingConfirmation
  ) {
    guard
      confirmation.matches(
        threadID: viewModel.thread.id,
        options: viewModel.options
      )
    else {
      pendingImmersiveReadingConfirmation = nil
      return
    }
    pendingImmersiveReadingConfirmation = nil
    setReadingMode(.immersive)
    viewModel.enableOnlyThreadAuthorFromFirstPage()
  }

  private func setReadingMode(_ mode: ThreadReadingMode) {
    guard readingMode != mode else { return }
    let wasPureReading = isPureReadingMode
    let willUsePurePresentation = mode.usesPurePresentation
    pendingCloudFavoriteAction = nil
    if !wasPureReading && willUsePurePresentation {
      pendingAgreementChange = nil
      agreementErrorMessage = nil
      contentAgreementStore?.removeScope(agreementScopeID)
    }
    if wasPureReading != willUsePurePresentation {
      scrollPositionCoalescer.reset()
      scrollPosition = .empty
    }
    withAnimation { readingMode = mode }
  }

  private func requestAgreementChange(
    _ target: ContentAgreementTarget,
    targetAgreed: Bool
  ) {
    guard !isPureReadingMode else { return }
    pendingCloudFavoriteAction = nil
    pendingOwnedContentDeletion = nil
    pendingAgreementChange = PendingContentAgreementChange(
      target: target,
      targetAgreed: targetAgreed
    )
  }

  private func confirmAgreementChange(_ change: PendingContentAgreementChange) {
    pendingAgreementChange = nil
    guard !isPureReadingMode, let contentAgreementStore else { return }
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
    guard !isPureReadingMode, let contentAgreementStore else { return }
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

  private func requestCloudFavoriteAction(_ action: ThreadCloudFavoritePendingAction) {
    guard cloudFavoriteActionIsCurrent(action) else { return }
    pendingAgreementChange = nil
    pendingOwnedContentDeletion = nil
    pendingCloudFavoriteAction = action
  }

  private func requestOwnedContentDeletion(_ pending: PendingOwnedContentDeletion) {
    guard !isPureReadingMode else { return }
    guard ownedContentDeletionInProgress == nil else {
      ownedContentDeletionErrorMessage = "当前已有删除操作正在进行，请等待结果。"
      return
    }
    pendingAgreementChange = nil
    pendingCloudFavoriteAction = nil
    pendingOwnedContentDeletion = pending
  }

  private func confirmOwnedContentDeletion(_ pending: PendingOwnedContentDeletion) {
    pendingOwnedContentDeletion = nil
    guard let ownedContentDeletionStore else {
      ownedContentDeletionErrorMessage = "当前账户服务不支持删除内容。"
      return
    }
    ownedContentDeletionInProgress = pending.target
    Task { @MainActor in
      defer {
        if ownedContentDeletionInProgress == pending.target {
          ownedContentDeletionInProgress = nil
        }
      }
      do {
        let receipt = try await ownedContentDeletionStore.delete(pending)
        guard receipt.target == pending.target else {
          ownedContentDeletionErrorMessage = "贴吧返回的删除目标不一致，请重新加载核对。"
          return
        }
        switch receipt.target.kind {
        case .topic:
          ownedContentDeletionUnknownTarget = nil
          replyComposerContext = nil
          sheetRoute = nil
          dismiss()
        case .post:
          if ownedContentDeletionUnknownTarget == receipt.target {
            ownedContentDeletionUnknownTarget = nil
          }
          if commentsSheetTargets(receipt.target) {
            sheetRoute = nil
          }
          guard viewModel.applyAcceptedContentDeletion(receipt.target) else {
            ownedContentDeletionErrorMessage = "贴吧已受理删除，但当前页面已变化，请重新加载核对。"
            return
          }
        }
      } catch {
        if let deletionError = error as? OwnedContentDeletionError,
          deletionError == .outcomeUnknown
        {
          ownedContentDeletionUnknownTarget = pending.target
        }
        ownedContentDeletionErrorMessage = error.localizedDescription
      }
    }
  }

  private func commentsSheetTargets(_ target: OwnedContentDeletionTarget) -> Bool {
    guard let sheetRoute, case .comments(let route) = sheetRoute else { return false }
    switch route {
    case .post(let threadID, let postID), .comment(let threadID, let postID, _):
      return threadID == target.threadID && postID == target.objectID
    }
  }

  private func requestFloorCloudFavoriteAction(_ action: ThreadCloudFavoritePendingAction) {
    guard !isPureReadingMode else { return }
    requestCloudFavoriteAction(action)
  }

  private func confirmCloudFavoriteAction(_ action: ThreadCloudFavoritePendingAction) {
    pendingCloudFavoriteAction = nil
    guard let threadCloudFavoriteStore, cloudFavoriteActionIsCurrent(action) else {
      cloudFavoriteErrorMessage = "云端收藏状态或目标已变化，请重新读取并确认后再试。"
      return
    }
    Task { @MainActor in
      do {
        try await threadCloudFavoriteStore.setMarkedPostID(
          action.requestedMarkedPostID,
          for: action.target,
          replacing: action.previousSnapshot
        )
      } catch is CancellationError {
        return
      } catch {
        cloudFavoriteErrorMessage = error.localizedDescription
      }
    }
  }

  private func cloudFavoriteActionIsCurrent(
    _ action: ThreadCloudFavoritePendingAction
  ) -> Bool {
    guard
      let threadCloudFavoriteStore,
      let target = threadCloudFavoriteTarget,
      action.target == target
    else { return false }
    let retainedPost = action.requestedMarkedPostID.flatMap(viewModel.post(withID:))
      .flatMap { effectiveVisibility(for: $0) == .visible ? $0 : nil }
    return ThreadCloudFavoriteActionAdmissionPolicy.admits(
      action,
      target: target,
      state: threadCloudFavoriteStore.entry(for: target).state,
      retainedPost: retainedPost
    )
  }

  private func retryCloudFavorite(_ target: ThreadCloudFavoriteTarget) {
    guard let threadCloudFavoriteStore else { return }
    Task { @MainActor in
      do {
        _ = try await threadCloudFavoriteStore.reload(target)
      } catch is CancellationError {
        return
      } catch {
        cloudFavoriteErrorMessage = error.localizedDescription
      }
    }
  }
}

struct ThreadAgreementTarget: Hashable, Sendable {
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let firstPostID: Int64

  init?(thread: BrowseThread, firstPost: BrowsePost) {
    let forumName = thread.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      thread.forumID > 0,
      !forumName.isEmpty,
      thread.id > 0,
      thread.firstPostID > 0,
      firstPost.id == thread.firstPostID,
      firstPost.threadID == thread.id,
      firstPost.floor == 1
    else { return nil }
    forumID = thread.forumID
    self.forumName = forumName
    threadID = thread.id
    firstPostID = firstPost.id
  }
}

struct ThreadAgreementContext {
  let target: ThreadAgreementTarget
  let fallbackAgreeScore: Int

  init?(thread: BrowseThread, firstPost: BrowsePost) {
    guard let target = ThreadAgreementTarget(thread: thread, firstPost: firstPost) else {
      return nil
    }
    self.target = target
    fallbackAgreeScore = thread.agreeScore
  }
}

enum ThreadAuthorAvatarResolver {
  static func resolve(
    thread: BrowseThread,
    firstPost: BrowsePost?,
    posts: [BrowsePost]
  ) -> URL? {
    guard thread.localVisibility == .visible else { return nil }
    if let authorAvatarURL = thread.authorAvatarURL {
      return authorAvatarURL
    }
    guard thread.id > 0, thread.authorID > 0 else { return nil }

    if
      let firstPost,
      firstPost.floor == 1,
      let authorAvatarURL = matchingAvatarURL(for: firstPost, thread: thread)
    {
      return authorAvatarURL
    }
    for post in posts {
      if let authorAvatarURL = matchingAvatarURL(for: post, thread: thread) {
        return authorAvatarURL
      }
    }
    return nil
  }

  private static func matchingAvatarURL(for post: BrowsePost, thread: BrowseThread) -> URL? {
    guard
      post.threadID == thread.id,
      post.authorID == thread.authorID,
      post.isThreadAuthor,
      post.localVisibility == .visible
    else { return nil }
    return SecureTiebaURL.media(post.authorPortraitURL)
  }
}

struct ThreadScrollPosition: Equatable, Sendable {
  static let empty = ThreadScrollPosition(
    readingProgressPostID: nil,
    prependAnchorPostID: nil
  )

  let readingProgressPostID: Int64?
  let prependAnchorPostID: Int64?
}

@MainActor
final class ThreadScrollPositionCoalescer {
  static let defaultDelayNanoseconds: UInt64 = 180_000_000

  private(set) var latestPosition = ThreadScrollPosition.empty
  private(set) var publicationCount = 0
  private let delayNanoseconds: UInt64
  private var pendingPublication: Task<Void, Never>?
  private var publishedPosition = ThreadScrollPosition.empty

  init(delayNanoseconds: UInt64 = defaultDelayNanoseconds) {
    self.delayNanoseconds = delayNanoseconds
  }

  func submit(
    _ position: ThreadScrollPosition,
    publish: @escaping @MainActor (ThreadScrollPosition) -> Void
  ) {
    let positionChanged = position != latestPosition
    latestPosition = position
    guard positionChanged || (pendingPublication == nil && position != publishedPosition) else {
      return
    }
    pendingPublication?.cancel()
    pendingPublication = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      pendingPublication = nil
      publicationCount += 1
      publishedPosition = latestPosition
      publish(publishedPosition)
    }
  }

  func cancelPendingPublication() {
    pendingPublication?.cancel()
    pendingPublication = nil
  }

  func reset() {
    cancelPendingPublication()
    latestPosition = .empty
    publishedPosition = .empty
  }
}

enum ThreadScrollPositionResolver {
  static func position(
    visiblePostIDs: [Int64],
    targetsByPostID: [Int64: ThreadScrollTargetDescriptor],
    hidesLocallyFilteredContent: Bool
  ) -> ThreadScrollPosition {
    var readingProgressPostID: Int64?
    var prependAnchorPostID: Int64?
    let visiblePostIDs = Set(visiblePostIDs.filter { $0 > 0 })
    let orderedTargets = visiblePostIDs.compactMap { postID in
      targetsByPostID[postID].map { (postID, $0) }
    }.sorted { lhs, rhs in
      lhs.1.order < rhs.1.order
    }

    for (postID, target) in orderedTargets {
      let visibility = hidesLocallyFilteredContent && target.localVisibility != .visible
        ? LocalContentVisibility.hidden
        : target.localVisibility
      if visibility == .visible {
        readingProgressPostID = postID
      }
      if
        prependAnchorPostID == nil,
        target.tracksPrependAnchor,
        visibility != .hidden
      {
        prependAnchorPostID = postID
      }
    }
    return ThreadScrollPosition(
      readingProgressPostID: readingProgressPostID,
      prependAnchorPostID: prependAnchorPostID
    )
  }
}

enum ThreadPostVisibilityPolicy {
  static func position(
    postID: Int64,
    frame: CGRect,
    viewportHeight: CGFloat,
    tracksReadingProgress: Bool,
    tracksPrependAnchor: Bool
  ) -> ThreadScrollPosition {
    guard
      postID > 0,
      viewportHeight.isFinite,
      viewportHeight > 0,
      frame.minY.isFinite,
      frame.maxY.isFinite,
      frame.height.isFinite,
      frame.height > 0,
      frame.maxY > 0,
      frame.minY < viewportHeight
    else { return .empty }

    return ThreadScrollPosition(
      readingProgressPostID: tracksReadingProgress ? postID : nil,
      prependAnchorPostID: tracksPrependAnchor ? postID : nil
    )
  }
}

struct ThreadScrollPositionPreferenceKey: PreferenceKey {
  static let defaultValue = ThreadScrollPosition.empty

  static func reduce(
    value: inout ThreadScrollPosition,
    nextValue: () -> ThreadScrollPosition
  ) {
    let next = nextValue()
    value = ThreadScrollPosition(
      readingProgressPostID: next.readingProgressPostID ?? value.readingProgressPostID,
      prependAnchorPostID: value.prependAnchorPostID ?? next.prependAnchorPostID
    )
  }
}

private struct ThreadPostVisibilityReader: View {
  let postID: Int64
  let viewportHeight: CGFloat
  let tracksReadingProgress: Bool
  let tracksPrependAnchor: Bool

  var body: some View {
    GeometryReader { geometry in
      Color.clear.preference(
        key: ThreadScrollPositionPreferenceKey.self,
        value: ThreadPostVisibilityPolicy.position(
          postID: postID,
          frame: geometry.frame(in: .named("thread-scroll")),
          viewportHeight: viewportHeight,
          tracksReadingProgress: tracksReadingProgress,
          tracksPrependAnchor: tracksPrependAnchor
        )
      )
    }
  }
}

private struct ThreadScrollTargetLayoutModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.scrollTargetLayout()
    } else {
      content
    }
  }
}

private struct ThreadNativeScrollVisibilityModifier: ViewModifier {
  let onChange: ([Int64]) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content
        .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0) {
          onChange($0)
        }
    } else {
      content
    }
  }
}

private struct ThreadProgressTaskID: Hashable {
  let postID: Int64?
  let isRestoringPrependPosition: Bool
}

private struct ContentAgreementRegistrationTaskID: Hashable {
  let descriptorEpoch: Int
  let isEnabled: Bool
}

struct PendingContentAgreementChange: Equatable {
  let target: ContentAgreementTarget
  let targetAgreed: Bool

  var confirmationTitle: String {
    targetAgreed
      ? "点赞这个\(target.kind.localizedObjectName)？"
      : "取消点赞这个\(target.kind.localizedObjectName)？"
  }

  var actionTitle: String {
    targetAgreed ? "点赞" : "取消点赞"
  }

  var confirmationMessage: String {
    "这会使用当前贴吧账户更新\(target.kind.localizedObjectName)的点赞状态。"
  }
}

extension ContentAgreementKind {
  var localizedObjectName: String {
    switch self {
    case .topic:
      "主题"
    case .post:
      "楼层"
    case .subpost:
      "楼中楼回复"
    }
  }
}

enum ContentAgreementControlPresentation: Equatable {
  case readOnly(score: Int)
  case loading(score: Int)
  case ready(ContentAgreementSnapshot)
  case mutating(ContentAgreementSnapshot)
  case retry(score: Int)

  init(state: ContentAgreementEntryState, fallbackAgreeScore: Int) {
    let fallbackAgreeScore = max(fallbackAgreeScore, 0)
    switch state {
    case .unknown, .signedOut:
      self = .readOnly(score: fallbackAgreeScore)
    case .loading(let previous):
      self = .loading(score: previous?.agreeScore ?? fallbackAgreeScore)
    case .ready(let snapshot):
      self = .ready(snapshot)
    case .mutating(let previous, _):
      self = .mutating(previous)
    case .failed(let previous):
      self = .retry(score: previous?.agreeScore ?? fallbackAgreeScore)
    }
  }
}

private struct PostView: View, Equatable {
  let post: BrowsePost
  let forumID: Int64
  let agreementTarget: ContentAgreementTarget?
  let agreementFallbackScore: Int
  let originThread: BrowseThread?
  let poll: BrowsePoll?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let selectableThreadTitle: String?
  let isPureReadingMode: Bool
  let openImage: (Int) -> Void
  let openMentionedUser: (Int64) -> Void
  let openTiebaLink: (TiebaLinkTarget) -> Void
  let requestAgreementChange: (ContentAgreementTarget, Bool) -> Void
  let retryAgreement: (ContentAgreementTarget) -> Void
  let cloudFavoriteTarget: ThreadCloudFavoriteTarget?
  let requestCloudFavoriteAction: (ThreadCloudFavoritePendingAction) -> Void
  let requestReply: (() -> Void)?
  let requestInlineCommentReply: ((BrowseComment) -> Void)?
  let requestReplyIsAvailable: Bool
  let requestInlineCommentReplyIsAvailable: Bool
  let reportThread: BrowseThread
  let reportTarget: ContentReportTarget?
  let deletionTarget: OwnedContentDeletionTarget?
  let requestDeletion: (PendingOwnedContentDeletion) -> Void
  let openComments: (Int64?) -> Void
  let selectText: (String) -> Void

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  @Environment(\.accountAccess) private var accountAccess
  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @Environment(\.threadCloudFavoriteStore) private var threadCloudFavoriteStore
  @Environment(\.ownedContentDeletionStore) private var ownedContentDeletionStore

  nonisolated static func == (lhs: PostView, rhs: PostView) -> Bool {
    lhs.post == rhs.post
      && lhs.forumID == rhs.forumID
      && lhs.agreementTarget == rhs.agreementTarget
      && lhs.agreementFallbackScore == rhs.agreementFallbackScore
      && lhs.originThread == rhs.originThread
      && lhs.poll == rhs.poll
      && lhs.selectableThreadTitle == rhs.selectableThreadTitle
      && lhs.isPureReadingMode == rhs.isPureReadingMode
      && lhs.cloudFavoriteTarget == rhs.cloudFavoriteTarget
      && lhs.reportThread.id == rhs.reportThread.id
      && lhs.reportThread.forumID == rhs.reportThread.forumID
      && lhs.reportThread.forumName == rhs.reportThread.forumName
      && lhs.reportThread.firstPostID == rhs.reportThread.firstPostID
      && lhs.reportThread.localVisibility == rhs.reportThread.localVisibility
      && lhs.reportTarget == rhs.reportTarget
      && lhs.deletionTarget == rhs.deletionTarget
      && lhs.requestReplyIsAvailable == rhs.requestReplyIsAvailable
      && lhs.requestInlineCommentReplyIsAvailable
        == rhs.requestInlineCommentReplyIsAvailable
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if isPureReadingMode {
        HStack(alignment: .top, spacing: 8) {
          pureReadingContext
          cloudFavoriteFloorMarker
        }
      } else {
        authorRow
      }

      BrowseContentView(
        contents: post.contents,
        onImageOpen: openImage,
        onUserMention: openMentionedUser,
        onTiebaLink: openTiebaLink,
        allowsDirectTextSelection: false,
        tracksAnimationVisibility: true,
        maximumPreviewPixelSize: 1_320
      )

      if let originThread {
        LocallyFilteredContent(
          visibility: isPureReadingMode && originThread.localVisibility != .visible
            ? .hidden
            : originThread.localVisibility,
          placeholder: "已屏蔽转发的原帖"
        ) {
          OriginThreadCard(
            thread: originThread,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository,
            openMentionedUser: openMentionedUser,
            openTiebaLink: openTiebaLink
          )
        }
      }

      if let poll {
        if let accountAccess {
          PollVoteControl(
            anonymousPoll: poll,
            forumID: forumID,
            threadID: post.threadID,
            access: accountAccess,
            isReadOnly: isPureReadingMode
          )
        } else {
          PollResultsCard(poll: poll)
        }
      }

      if let presentation = InlineCommentPreviewPresentation(
        post: post,
        isPureReadingMode: isPureReadingMode
      ) {
        InlineCommentPreviewCard(
          presentation: presentation,
          openComments: openComments,
          replyPresentation: { comment in
            InlineCommentReplyPresentation(
              thread: reportThread,
              parentPost: post,
              comment: comment,
              replyEntriesVisible: requestInlineCommentReply != nil
            )
          },
          requestReply: { comment in
            if let requestInlineCommentReply {
              requestInlineCommentReply(comment)
            }
          },
          reportTarget: { comment in
            guard !isPureReadingMode else { return nil }
            return ContentReportTarget(
              thread: reportThread,
              parentPostID: post.id,
              comment: comment
            )
          },
          selectText: selectText
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contextMenu {
      if let copyText = PostCopyText.text(threadTitle: selectableThreadTitle, post: post) {
        Button {
          selectText(copyText)
        } label: {
          Label("选择文字", systemImage: "text.cursor")
        }
      }
      if let requestReply {
        Button(action: requestReply) {
          Label(
            post.floor == 1 ? "回复主题" : "回复本楼",
            systemImage: "arrowshape.turn.up.left"
          )
        }
      }
      if !isPureReadingMode {
        ContentReportMenuItem(
          target: reportTarget,
          title: reportActionTitle,
          accessibilityIdentifier: "thread-report-post-\(post.id)"
        )
      }
      ThreadCloudFavoriteFloorMenuSlot(
        store: threadCloudFavoriteStore,
        target: cloudFavoriteTarget,
        post: post,
        isPureReadingMode: isPureReadingMode,
        requestAction: requestCloudFavoriteAction
      )
      if !isPureReadingMode {
        OwnedContentDeletionMenuSlot(
          store: ownedContentDeletionStore,
          target: deletionTarget,
          requestDeletion: requestDeletion
        )
      }
    }
  }

  private var reportActionTitle: String {
    guard reportTarget?.kind == .post, post.floor > 1 else {
      return reportTarget?.actionTitle ?? "举报本楼"
    }
    return "举报第 \(post.floor) 楼"
  }

  private var authorRow: some View {
    HStack(alignment: .top, spacing: 10) {
      if post.authorID > 0 {
        NavigationLink {
          UserProfileView(
            userID: post.authorID,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        } label: {
          authorIdentity
        }
        .buttonStyle(.plain)
      } else {
        authorIdentity
      }

      ContentAgreementControlSlot(
        store: contentAgreementStore,
        target: agreementTarget,
        fallbackAgreeScore: agreementFallbackScore,
        requestChange: requestAgreementChange,
        retry: retryAgreement
      )

      cloudFavoriteFloorMarker

      if let requestReply {
        Button(action: requestReply) {
          Image(systemName: "arrowshape.turn.up.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(post.floor == 1 ? "回复主题" : "回复第 \(post.floor) 楼")
        .help(post.floor == 1 ? "回复主题" : "回复本楼")
      }
    }
  }

  private var cloudFavoriteFloorMarker: some View {
    ThreadCloudFavoriteFloorMarkerSlot(
      store: threadCloudFavoriteStore,
      target: cloudFavoriteTarget,
      post: post,
      isPureReadingMode: isPureReadingMode
    )
    .frame(width: 24, height: 24)
  }

  private var pureReadingContext: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(displayedAuthorName)
          .lineLimit(showsBothNames ? 2 : 1)
          .minimumScaleFactor(0.75)
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityLabel(displayedAuthorName)
        pureReadingAuthorBadge
        Spacer(minLength: 0)
        pureReadingPostMetadata
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(displayedAuthorName)
          .lineLimit(showsBothNames ? 3 : 1)
          .minimumScaleFactor(0.75)
          .accessibilityLabel(displayedAuthorName)
        pureReadingAuthorBadge
        VStack(alignment: .leading, spacing: 4) {
          pureReadingPostMetadata
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var pureReadingAuthorBadge: some View {
    if post.isThreadAuthor {
      Label("楼主", systemImage: "person.fill.checkmark")
        .foregroundStyle(.tint)
        .fixedSize()
    }
  }

  @ViewBuilder
  private var pureReadingPostMetadata: some View {
    if post.floor > 0 {
      Text("\(post.floor) 楼")
        .fixedSize()
    }
    if let createdAt = post.createdAt {
      Text(createdAt, style: .relative)
        .fixedSize()
    }
  }

  private var authorIdentity: some View {
    PostAuthorIdentityView(
      name: post.authorName,
      username: post.authorUsername,
      portraitURL: post.authorPortraitURL,
      level: post.authorLevel,
      isThreadAuthor: post.isThreadAuthor,
      moderatorRole: post.moderatorRole,
      floor: post.floor,
      date: post.createdAt,
      ipLocation: post.authorIPLocation,
      showsDisclosureIndicator: post.authorID > 0
    )
  }

  private var displayedAuthorName: String {
    UserNameFormatter.displayName(
      preferredName: post.authorName,
      username: post.authorUsername,
      showsBoth: showsBothNames
    )
  }
}

private enum ThreadSheetRoute: Identifiable, Equatable, Sendable {
  case comments(CommentsRoute)
  case selectableText(SelectableTextPresentation)

  var id: String {
    switch self {
    case .comments(let route):
      "comments:\(route.id)"
    case .selectableText(let presentation):
      "selectable-text:\(presentation.id.uuidString)"
    }
  }
}

struct ContentAgreementControlSlot: View {
  let store: ContentAgreementStore?
  let target: ContentAgreementTarget?
  let fallbackAgreeScore: Int
  let requestChange: (ContentAgreementTarget, Bool) -> Void
  let retry: (ContentAgreementTarget) -> Void

  @ViewBuilder
  var body: some View {
    if let store, let target {
      ContentAgreementControl(
        entry: store.entry(for: target),
        fallbackAgreeScore: fallbackAgreeScore,
        requestChange: requestChange,
        retry: retry
      )
    } else {
      ContentAgreementFixedLabel(
        score: fallbackAgreeScore,
        icon: .thumbsUp
      )
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("净赞数 \(max(fallbackAgreeScore, 0).formatted())")
    }
  }
}

private struct ContentAgreementControl: View {
  @ObservedObject private var entry: ContentAgreementEntry
  let fallbackAgreeScore: Int
  let requestChange: (ContentAgreementTarget, Bool) -> Void
  let retry: (ContentAgreementTarget) -> Void

  init(
    entry: ContentAgreementEntry,
    fallbackAgreeScore: Int,
    requestChange: @escaping (ContentAgreementTarget, Bool) -> Void,
    retry: @escaping (ContentAgreementTarget) -> Void
  ) {
    _entry = ObservedObject(wrappedValue: entry)
    self.fallbackAgreeScore = fallbackAgreeScore
    self.requestChange = requestChange
    self.retry = retry
  }

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .readOnly(let score):
      ContentAgreementFixedLabel(score: score, icon: .thumbsUp)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("净赞数 \(score.formatted())")
    case .loading(let score):
      ContentAgreementFixedLabel(score: score, icon: .progress)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在读取\(entry.target.kind.localizedObjectName)点赞状态")
    case .ready(let snapshot):
      Button {
        requestChange(entry.target, !snapshot.isAgreed)
      } label: {
        ContentAgreementFixedLabel(
          score: snapshot.agreeScore,
          icon: snapshot.isAgreed ? .thumbsUpFilled : .thumbsUp
        )
      }
      .buttonStyle(.plain)
      .foregroundStyle(snapshot.isAgreed ? Color.accentColor : Color.secondary)
      .accessibilityLabel(
        snapshot.isAgreed
          ? "取消点赞\(entry.target.kind.localizedObjectName)"
          : "点赞\(entry.target.kind.localizedObjectName)"
      )
      .accessibilityValue("净赞数 \(snapshot.agreeScore.formatted())")
      .help(
        snapshot.isAgreed
          ? "取消点赞\(entry.target.kind.localizedObjectName)"
          : "点赞\(entry.target.kind.localizedObjectName)"
      )
      .accessibilityIdentifier(
        "content-agreement-\(entry.target.kind.rawValue)-\(entry.target.objectID)"
      )
    case .mutating(let previous):
      ContentAgreementFixedLabel(score: previous.agreeScore, icon: .progress)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在更新\(entry.target.kind.localizedObjectName)点赞")
    case .retry(let score):
      Button { retry(entry.target) } label: {
        ContentAgreementFixedLabel(score: score, icon: .retry)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("重试读取\(entry.target.kind.localizedObjectName)点赞状态")
      .help("重试读取\(entry.target.kind.localizedObjectName)点赞状态")
      .accessibilityIdentifier(
        "content-agreement-retry-\(entry.target.kind.rawValue)-\(entry.target.objectID)"
      )
    }
  }

  private var presentation: ContentAgreementControlPresentation {
    ContentAgreementControlPresentation(
      state: entry.state,
      fallbackAgreeScore: fallbackAgreeScore
    )
  }
}

private enum ContentAgreementFixedLabelIcon {
  case thumbsUp
  case thumbsUpFilled
  case progress
  case retry
}

private struct ContentAgreementFixedLabel: View {
  let score: Int
  let icon: ContentAgreementFixedLabelIcon

  var body: some View {
    HStack(spacing: 5) {
      switch icon {
      case .thumbsUp:
        Image(systemName: "hand.thumbsup")
      case .thumbsUpFilled:
        Image(systemName: "hand.thumbsup.fill")
      case .progress:
        ProgressView()
          .controlSize(.small)
      case .retry:
        Image(systemName: "arrow.clockwise")
      }
      Text(max(score, 0).formatted(.number.notation(.compactName)))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .font(.caption)
    .frame(width: 72, height: 44)
    .contentShape(Rectangle())
  }
}

private struct PollVoteControl: View {
  @StateObject private var viewModel: PollVoteViewModel
  @State private var showsConfirmation = false

  let anonymousPoll: BrowsePoll
  let isReadOnly: Bool

  @Environment(\.appAccentColor) private var appAccentColor

  init(
    anonymousPoll: BrowsePoll,
    forumID: Int64,
    threadID: Int64,
    access: AccountAccess,
    isReadOnly: Bool
  ) {
    self.anonymousPoll = anonymousPoll
    self.isReadOnly = isReadOnly
    _viewModel = StateObject(
      wrappedValue: PollVoteViewModel(
        anonymousPoll: anonymousPoll,
        forumID: forumID,
        threadID: threadID,
        access: access
      )
    )
  }

  var body: some View {
    alertContent
  }

  private var pollContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if presentsSelection {
        selectionCard
      } else {
        PollResultsCard(
          poll: displayedPoll,
          status: resultStatus,
          retry: resultReloadAction
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var lifecycleContent: some View {
    pollContent
    .task(id: isReadOnly) {
      guard !isReadOnly else { return }
      await viewModel.loadIfNeeded()
    }
    .onChange(of: anonymousPoll) { poll in
      viewModel.replaceAnonymousSnapshot(poll)
    }
    .onChange(of: isReadOnly) { readOnly in
      if readOnly {
        showsConfirmation = false
        viewModel.presentationDidDisappear()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      showsConfirmation = false
      let token = viewModel.invalidateForAccountSessionChange()
      guard !isReadOnly else { return }
      Task { @MainActor in
        await viewModel.reloadAfterAccountSessionChange(ifCurrent: token)
      }
    }
    .onDisappear {
      showsConfirmation = false
      viewModel.presentationDidDisappear()
    }
  }

  private var confirmationContent: some View {
    lifecycleContent
    .confirmationDialog(
      "提交投票？",
      isPresented: $showsConfirmation,
      titleVisibility: .visible
    ) {
      Button("确认投票") {
        showsConfirmation = false
        viewModel.beginSubmitSelection()
      }
      Button("取消", role: .cancel) { showsConfirmation = false }
    } message: {
      Text(confirmationMessage)
    }
  }

  private var alertContent: some View {
    confirmationContent
    .alert("无法完成投票", isPresented: errorIsPresented) {
      if resultCanReload {
        Button("重新读取") {
          viewModel.dismissError()
          reload()
        }
      }
      Button("好", role: .cancel) { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage ?? "无法确认投票状态。")
    }
  }

  private var presentsSelection: Bool {
    guard !isReadOnly else { return false }
    switch viewModel.state {
    case .ready:
      return viewModel.isSelectionEnabled
    case .submitting:
      return true
    case .idle, .signedOut, .loading, .failed, .outcomeUnknown:
      return false
    }
  }

  private var displayedPoll: BrowsePoll {
    isReadOnly ? anonymousPoll : viewModel.displayedPoll
  }

  private var selectionCard: some View {
    let poll = displayedPoll
    let isSubmitting: Bool
    if case .submitting = viewModel.state {
      isSubmitting = true
    } else {
      isSubmitting = false
    }

    return VStack(alignment: .leading, spacing: 12) {
      PollCardHeader(poll: poll, showsResultsLabel: false)

      if !poll.tips.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(poll.tips)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(poll.options) { option in
          selectionRow(option, poll: poll, isSubmitting: isSubmitting)
        }
      }

      HStack(spacing: 10) {
        Text("\(compactPollCount(poll.participantCount)) 人参与")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel("\(max(poll.participantCount, 0).formatted()) 人参与")

        Spacer(minLength: 8)

        Button {
          showsConfirmation = true
        } label: {
          if isSubmitting {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("提交中")
            }
          } else {
            Label("投票", systemImage: "paperplane.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!viewModel.canSubmit || isSubmitting || isReadOnly)
        .accessibilityIdentifier("poll-submit")
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }

  private func selectionRow(
    _ option: BrowsePollOption,
    poll: BrowsePoll,
    isSubmitting: Bool
  ) -> some View {
    let isSelected = viewModel.selectedOptionIDs.contains(option.id)
    let symbol: String
    if poll.isMultipleChoice {
      symbol = isSelected ? "checkmark.square.fill" : "square"
    } else {
      symbol = isSelected ? "checkmark.circle.fill" : "circle"
    }

    return Button {
      viewModel.toggleSelection(optionID: option.id)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(isSelected ? appAccentColor.color : Color.secondary)
          .frame(width: 24, height: 24)

        PollOptionThumbnail(url: option.imageURL)

        Text(pollOptionTitle(option))
          .font(.subheadline)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        isSelected ? appAccentColor.color.opacity(0.08) : Color(uiColor: .systemBackground)
      )
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(
            isSelected
              ? appAccentColor.color.opacity(0.7)
              : Color(uiColor: .separator).opacity(0.35),
            lineWidth: 0.75
          )
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isSubmitting || isReadOnly || !viewModel.isSelectionEnabled)
    .accessibilityLabel(pollOptionTitle(option))
    .accessibilityValue(isSelected ? "已选择" : "未选择")
    .accessibilityIdentifier("poll-option-\(option.id)")
  }

  private var resultStatus: PollResultStatus? {
    guard !isReadOnly else { return .readOnly }
    let poll = displayedPoll
    switch viewModel.state {
    case .idle:
      return nil
    case .signedOut:
      return .signedOut
    case .loading:
      return .loading
    case .ready:
      if poll.isClosed(at: Date()) { return .closed }
      if poll.isPolled { return .participated }
      return isReadOnly ? .readOnly : nil
    case .submitting:
      return .submitting
    case .failed:
      return .failed
    case .outcomeUnknown:
      return .outcomeUnknown
    }
  }

  private var resultCanReload: Bool {
    guard !isReadOnly else { return false }
    switch viewModel.state {
    case .failed, .outcomeUnknown:
      return true
    case .idle, .signedOut, .loading, .ready, .submitting:
      return false
    }
  }

  private var resultReloadAction: (() -> Void)? {
    guard resultCanReload else { return nil }
    return { reload() }
  }

  private var confirmationMessage: String {
    let selectedTitles = displayedPoll.options.compactMap { option in
      viewModel.selectedOptionIDs.contains(option.id)
        ? String(pollOptionTitle(option).prefix(40))
        : nil
    }
    let visibleTitles = selectedTitles.prefix(3)
    var summary = visibleTitles.joined(separator: "、")
    if selectedTitles.count > visibleTitles.count {
      summary += "等 \(selectedTitles.count) 项"
    }
    guard !summary.isEmpty else { return "投票提交后不可撤销。" }
    return "将选择“\(summary)”。投票提交后不可撤销。"
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { !isReadOnly && viewModel.errorMessage != nil },
      set: { isPresented in
        if !isPresented { viewModel.dismissError() }
      }
    )
  }

  private func reload() {
    guard !isReadOnly else { return }
    showsConfirmation = false
    Task { @MainActor in await viewModel.reload() }
  }
}

private enum PollResultStatus {
  case signedOut
  case loading
  case readOnly
  case participated
  case closed
  case submitting
  case failed
  case outcomeUnknown

  var title: String {
    switch self {
    case .signedOut: "未登录"
    case .loading: "正在读取"
    case .readOnly: "只读"
    case .participated: "已参与"
    case .closed: "已截止"
    case .submitting: "提交中"
    case .failed: "读取失败"
    case .outcomeUnknown: "结果待确认"
    }
  }

  var systemImage: String {
    switch self {
    case .signedOut: "person.crop.circle.badge.questionmark"
    case .loading, .submitting: "hourglass"
    case .readOnly: "eye"
    case .participated: "checkmark.circle.fill"
    case .closed: "clock.badge.xmark"
    case .failed: "exclamationmark.triangle"
    case .outcomeUnknown: "questionmark.circle"
    }
  }
}

private struct PollCardHeader: View {
  let poll: BrowsePoll
  let showsResultsLabel: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(
          showsResultsLabel ? "投票结果" : "投票",
          systemImage: showsResultsLabel ? "chart.bar.fill" : "checkmark.circle"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        Spacer(minLength: 8)
        Label(
          poll.isMultipleChoice ? "多选" : "单选",
          systemImage: poll.isMultipleChoice ? "checklist" : "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
      }

      Text(pollTitle)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var pollTitle: String {
    let title = poll.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "投票" : title
  }
}

private struct PollOptionThumbnail: View {
  let url: URL?

  var body: some View {
    if let url {
      ContentRemoteImage(
        url: url,
        maxPixelSize: 384,
        loadAccessibilityLabel: "加载投票选项图片"
      ) { phase in
        switch phase {
        case .success(let asset, _):
          RemoteImageAssetView(asset: asset, contentMode: .fill)
        case .empty:
          ZStack {
            Color(uiColor: .tertiarySystemFill)
            ProgressView().controlSize(.mini)
          }
        case .loadRequired:
          pollOptionImagePlaceholder(systemImage: "arrow.down.circle")
        case .failure:
          pollOptionImagePlaceholder(systemImage: "photo.badge.exclamationmark")
        }
      }
      .frame(width: 48, height: 48)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .accessibilityHidden(true)
    }
  }

  private func pollOptionImagePlaceholder(systemImage: String) -> some View {
    ZStack {
      Color(uiColor: .tertiarySystemFill)
      Image(systemName: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct PollResultsCard: View {
  let poll: BrowsePoll
  let status: PollResultStatus?
  let retry: (() -> Void)?

  @Environment(\.appAccentColor) private var appAccentColor

  init(
    poll: BrowsePoll,
    status: PollResultStatus? = nil,
    retry: (() -> Void)? = nil
  ) {
    self.poll = poll
    self.status = status
    self.retry = retry
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      PollCardHeader(poll: poll, showsResultsLabel: true)

      if !poll.tips.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(poll.tips)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 12) {
        ForEach(poll.options) { option in
          pollOption(option)
        }
      }

      HStack(spacing: 10) {
        Text("\(compactPollCount(poll.participantCount)) 人参与")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel("\(max(poll.participantCount, 0).formatted()) 人参与")

        Spacer(minLength: 8)

        if let status {
          Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
        }

        if let retry {
          Button(action: retry) {
            Image(systemName: "arrow.clockwise")
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
          .accessibilityLabel("重新读取投票状态")
          .help("重新读取投票状态")
          .accessibilityIdentifier("poll-reload")
        }
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }

  private func pollOption(_ option: BrowsePollOption) -> some View {
    let percentage = poll.percentage(for: option)
    let voteCount = max(option.voteCount, 0)
    let text = pollOptionTitle(option)
    let isSelected = poll.isSelected(option.id)

    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        PollOptionThumbnail(url: option.imageURL)

        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
              .font(.subheadline)
              .fontWeight(isSelected ? .semibold : .regular)
              .foregroundStyle(isSelected ? appAccentColor.color : Color.primary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(compactPollCount(voteCount)) 票 · \(percentage)%")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .fixedSize()
          }

          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color(uiColor: .tertiarySystemFill))
              Capsule()
                .fill(appAccentColor.color.opacity(isSelected ? 0.85 : 0.65))
                .frame(width: geometry.size.width * CGFloat(poll.progress(for: option)))
            }
          }
          .frame(height: 5)
        }

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(appAccentColor.color)
            .accessibilityHidden(true)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(text)，\(voteCount.formatted()) 票，\(percentage)%\(isSelected ? "，已选择" : "")"
    )
  }
}

private func pollOptionTitle(_ option: BrowsePollOption) -> String {
  let title = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !title.isEmpty else { return "未命名选项" }
  return title.count > 200 ? "\(title.prefix(200))..." : title
}

private func compactPollCount(_ value: Int64) -> String {
  max(value, 0).formatted(.number.notation(.compactName))
}

private struct OriginThreadCard: View {
  let thread: BrowseThread
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let openMentionedUser: (Int64) -> Void
  let openTiebaLink: (TiebaLinkTarget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NavigationLink {
        ThreadView(
          thread: thread,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "arrowshape.turn.up.right.fill")
            .foregroundStyle(.tint)
            .frame(width: 20, height: 20)
          VStack(alignment: .leading, spacing: 3) {
            Text("转发的原帖")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(thread.title.isEmpty ? "查看原帖" : thread.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(3)
            if !thread.forumName.isEmpty {
              Text("\(thread.forumName)吧")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 3)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        thread.title.isEmpty ? "打开原帖" : "打开原帖，\(thread.title)"
      )

      if !thread.contents.isEmpty {
        Divider()
        BrowseContentView(
          contents: thread.contents,
          onUserMention: openMentionedUser,
          onTiebaLink: openTiebaLink,
          allowsDirectTextSelection: false,
          tracksAnimationVisibility: true,
          maximumPreviewPixelSize: 1_320
        )
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
    }
  }
}
