import Combine
import SwiftUI
import UIKit

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appAccentColor) private var appAccentColor
  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @StateObject private var viewModel: CommentsViewModel
  @State private var linkedTarget: TiebaLinkTarget?
  @State private var highlightedComment: CommentHighlightToken?
  @State private var agreementScopeID = UUID()
  @State private var pendingAgreementChange: PendingContentAgreementChange?
  @State private var agreementErrorMessage: String?
  @State private var hasRecordedDirectVisit = false
  @State private var replyComposerContext: TextReplyComposerContext?
  @State private var pendingConfirmedThreadRoute: TiebaThreadRoute?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  private let showsDismissButton: Bool
  private let recordsOwningThreadVisit: Bool

  init(
    threadID: Int64,
    postID: Int64,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    showsDismissButton: Bool = true
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = false
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
    showsDismissButton: Bool = true
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = false
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
    showsDismissButton: Bool = true
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.showsDismissButton = showsDismissButton
    self.recordsOwningThreadVisit = true
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
                  agreementTarget: viewModel.parentAgreementTarget,
                  service: service,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository,
                  openMentionedUser: openMentionedUser,
                  openTiebaLink: openTiebaLink,
                  requestAgreementChange: requestAgreementChange,
                  retryAgreement: retryAgreement,
                  requestReply: parentReplyContext.map { context in
                    { replyComposerContext = context }
                  }
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

              if !viewModel.comments.contains(where: { $0.localVisibility != .hidden }) {
                EmptyStateView(title: "暂无可显示的楼中楼回复", systemImage: "bubble.left")
                  .frame(maxWidth: .infinity)
                  .listRowSeparator(.hidden)
              }

              ForEach(viewModel.comments) { comment in
                LocallyFilteredContent(
                  visibility: comment.localVisibility,
                  placeholder: "已屏蔽此条回复"
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

                      if let context = replyContext(for: comment) {
                        Button {
                          replyComposerContext = context
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
                      onTiebaLink: openTiebaLink
                    )
                  }
                  .padding(.vertical, 4)
                  .contextMenu {
                    if let copyText = BrowseContentCopyText.text(comment.contents) {
                      Button {
                        UIPasteboard.general.string = copyText
                      } label: {
                        Label("复制此条回复", systemImage: "doc.on.doc")
                      }
                    }
                    if let context = replyContext(for: comment) {
                      Button {
                        replyComposerContext = context
                      } label: {
                        Label("回复此条", systemImage: "arrowshape.turn.up.left")
                      }
                    }
                  }
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
    .toolbar {
      if showsDismissButton {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
    .task { viewModel.loadIfNeeded() }
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
      pendingAgreementChange = nil
      contentAgreementStore?.removeScope(agreementScopeID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      pendingAgreementChange = nil
      agreementErrorMessage = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in viewModel.reload() }
    }
    .onChange(of: replyComposerContext) { context in
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

  @ViewBuilder
  private var commentsBottomInset: some View {
    VStack(spacing: 0) {
      if let message = viewModel.positionNotice {
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

      if let context = parentReplyContext {
        Divider()
        Button {
          replyComposerContext = context
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

  private func verifyReplyVisibility(_ receipt: TextReplyReceipt) async throws
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
        let content = TextReplyVisibilityProof.exactPlainText(from: post.contents)
      else { return nil }
      return TextReplyVisibilityConfirmation(
        created: .post(postID: post.id, floor: post.floor),
        authorUserID: post.authorID,
        content: content
      )
    case .subpost(let parentPostID, let subpostID):
      let expectedNestedReplyUserID: Int64?
      if
        let context = replyComposerContext,
        case .subpost(let expectedParentPostID, let targetSubpostID) =
          context.target.destination
      {
        guard
          expectedParentPostID == parentPostID,
          let targetComment = viewModel.comments.first(where: { $0.id == targetSubpostID }),
          targetComment.parentPostID == parentPostID,
          targetComment.authorID > 0
        else { return nil }
        expectedNestedReplyUserID = targetComment.authorID
      } else {
        expectedNestedReplyUserID = nil
      }
      guard
        parentPostID == viewModel.parentPost?.id,
        let comment = await viewModel.verifyAndRelocateAcceptedReply(commentID: subpostID),
        comment.id == subpostID,
        comment.threadID == viewModel.threadID,
        comment.parentPostID == parentPostID
      else { return nil }
      let content: String?
      if let expectedNestedReplyUserID {
        content = TextReplyVisibilityProof.exactNestedReplyBody(
          from: comment,
          expectedReplyToUserID: expectedNestedReplyUserID
        )
      } else {
        content = TextReplyVisibilityProof.exactPlainText(from: comment.contents)
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

private struct CommentHighlightToken: Equatable {
  let commentID: Int64
  let generation = UUID()
}
