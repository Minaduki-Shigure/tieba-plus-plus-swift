import Combine
import SwiftUI
import UIKit

struct ThreadView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ThreadViewModel
  @State private var commentsRoute: CommentsRoute?
  @State private var showsPageJump = false
  @State private var pageInput = ""
  @State private var visiblePost: BrowsePost?
  @State private var leadingVisiblePostID: Int64?
  @State private var linkedTarget: TiebaLinkTarget?
  @State private var restoredHistorySnapshot: ThreadHistorySnapshot?
  @State private var hasRecordedHistoryVisit = false
  @State private var isPureReadingMode = false
  @State private var pictureGalleryRoute: ThreadImageGalleryRoute?
  @State private var pictureGalleryPolicyTask: Task<Void, Never>?
  @State private var agreementScopeID = UUID()
  @State private var pendingAgreementChange: PendingContentAgreementChange?
  @State private var agreementErrorMessage: String?
  @State private var cloudFavoriteScopeID = UUID()
  @State private var pendingCloudFavoriteAction: ThreadCloudFavoritePendingAction?
  @State private var cloudFavoriteErrorMessage: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.contentFilterRepository) private var contentFilterRepository
  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @Environment(\.threadCloudFavoriteStore) private var threadCloudFavoriteStore
  private let historySnapshot: ThreadHistorySnapshot?
  private let linkRoute: TiebaThreadRoute?

  init(
    thread: BrowseThread,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    historySnapshot: ThreadHistorySnapshot? = nil,
    linkRoute: TiebaThreadRoute? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.historySnapshot = historySnapshot
    self.linkRoute = linkRoute
    _viewModel = StateObject(
      wrappedValue: ThreadViewModel(
        thread: thread,
        service: service,
        options: linkRoute?.options ?? ThreadBrowseOptions(),
        initialLocation: linkRoute.flatMap { route in
          route.postID.map { ThreadPostLocation.postID($0) }
        }
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
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      if !isPureReadingMode {
        optionsBar
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let message = viewModel.jumpError {
        if viewModel.canRetryJump {
          LoadMoreErrorView(message: message, retry: viewModel.retryJump)
            .padding(.horizontal, 12)
            .background(.regularMaterial)
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
          .background(.regularMaterial)
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
        .background(.regularMaterial)
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        navigationPrincipal
      }

      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          togglePureReadingMode()
        } label: {
          Image(systemName: isPureReadingMode ? "book.closed.fill" : "book.closed")
        }
        .accessibilityLabel(isPureReadingMode ? "退出纯净阅读" : "纯净阅读")
        .help(isPureReadingMode ? "退出纯净阅读" : "纯净阅读")

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
    .task(id: viewModel.state) {
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
      cancelPictureGallery()
      visiblePost = nil
      leadingVisiblePostID = nil
      persistBrowseOptions(options)
    }
    .onDisappear {
      if let visiblePost, !viewModel.isRestoringPrependPosition {
        let options = viewModel.options
        Task { await persistProgress(visiblePost, options: options) }
      } else {
        persistBrowseOptions(viewModel.options)
      }
      cancelPictureGallery()
      pendingAgreementChange = nil
      pendingCloudFavoriteAction = nil
      contentAgreementStore?.removeScope(agreementScopeID)
      threadCloudFavoriteStore?.deactivate(cloudFavoriteScopeID)
      viewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      pendingAgreementChange = nil
      agreementErrorMessage = nil
      pendingCloudFavoriteAction = nil
      cloudFavoriteErrorMessage = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      cancelPictureGallery()
      Task { @MainActor in
        visiblePost = nil
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
    .sheet(item: $commentsRoute) { route in
      NavigationStack {
        switch route {
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

  private func openMentionedUser(_ userID: Int64) {
    guard userID > 0 else { return }
    linkedTarget = .user(userID)
  }

  private func openTiebaLink(_ target: TiebaLinkTarget) {
    linkedTarget = target
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
                    agreementTarget: viewModel.agreementTarget(forPostID: firstPost.id),
                    agreementFallbackScore: viewModel.thread.agreeScore,
                    originThread: viewModel.originThread,
                    poll: viewModel.poll,
                    service: service,
                    historyRepository: historyRepository,
                    favoritesRepository: favoritesRepository,
                    searchHistoryRepository: searchHistoryRepository,
                    threadTitle: viewModel.thread.title,
                    isPureReadingMode: isPureReadingMode,
                    openImage: { contentOffset in
                      openPictureGallery(post: firstPost, contentOffset: contentOffset)
                    },
                    openMentionedUser: openMentionedUser,
                    openTiebaLink: openTiebaLink,
                    requestAgreementChange: requestAgreementChange,
                    retryAgreement: retryAgreement,
                    openComments: { commentID in
                      commentsRoute = CommentsRoute(
                        threadID: firstPost.threadID,
                        postID: firstPost.id,
                        commentID: commentID
                      )
                    }
                  )
                  Divider()
                    .padding(.leading, isPureReadingMode ? 0 : 52)
                }
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: PostFramePreferenceKey.self,
                      value: [firstPost.id: geometry.frame(in: .named("thread-scroll"))]
                    )
                  }
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
                    agreementTarget: viewModel.agreementTarget(forPostID: post.id),
                    agreementFallbackScore: post.agreeScore,
                    originThread: nil,
                    poll: nil,
                    service: service,
                    historyRepository: historyRepository,
                    favoritesRepository: favoritesRepository,
                    searchHistoryRepository: searchHistoryRepository,
                    threadTitle: viewModel.thread.title,
                    isPureReadingMode: isPureReadingMode,
                    openImage: { contentOffset in
                      openPictureGallery(post: post, contentOffset: contentOffset)
                    },
                    openMentionedUser: openMentionedUser,
                    openTiebaLink: openTiebaLink,
                    requestAgreementChange: requestAgreementChange,
                    retryAgreement: retryAgreement,
                    openComments: { commentID in
                      commentsRoute = CommentsRoute(
                        threadID: post.threadID,
                        postID: post.id,
                        commentID: commentID
                      )
                    }
                  )
                  Divider()
                    .padding(.leading, isPureReadingMode ? 0 : 52)
                }
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: PostFramePreferenceKey.self,
                      value: [post.id: geometry.frame(in: .named("thread-scroll"))]
                    )
                  }
                }
              }
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: PrependAnchorFramePreferenceKey.self,
                    value: [post.id: geometry.frame(in: .named("thread-scroll"))]
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
        }
        .coordinateSpace(name: "thread-scroll")
        .onPreferenceChange(PostFramePreferenceKey.self) { frames in
          let lastVisibleID =
            frames
            .filter { _, frame in
              frame.maxY > 0 && frame.minY < viewport.size.height
            }
            .max { lhs, rhs in lhs.value.minY < rhs.value.minY }?
            .key
          visiblePost = lastVisibleID.flatMap { postID in
            viewModel.post(withID: postID)
          }
        }
        .onPreferenceChange(PrependAnchorFramePreferenceKey.self) { frames in
          leadingVisiblePostID =
            frames
            .filter { _, frame in
              frame.height > 0 && frame.maxY > 0 && frame.minY < viewport.size.height
            }
            .min { lhs, rhs in lhs.value.minY < rhs.value.minY }?
            .key
        }
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

  private func openPictureGallery(post: BrowsePost, contentOffset: Int) {
    guard
      effectiveVisibility(for: post) == .visible,
      let presentation = ImageGalleryPresentation(
        contents: post.contents,
        selectedContentOffset: contentOffset
      )
    else { return }

    let remoteService = service as? any ThreadPictureGalleryService
    let galleryService: any ThreadPictureGalleryService
    if let remoteService {
      galleryService = remoteService
    } else {
      galleryService = UnavailableThreadPictureGalleryService()
    }

    let localOccurrences = presentation.items.enumerated().map { pair in
      let (imageIndex, item) = pair
      return ThreadPictureOccurrence(
        localURL: item.url,
        pictureID: remoteService?.pictureIdentifier(for: item.url) ?? "",
        postID: post.id,
        contentOffset: item.contentOffset,
        width: item.width,
        height: item.height,
        imageOrdinal: imageIndex + 1
      )
    }
    let selectedID = ThreadPictureOccurrenceID.local(
      postID: post.id,
      contentOffset: contentOffset
    )
    let galleryViewModel = ThreadImageGalleryViewModel(
      context: ThreadPictureGalleryContext(
        forumID: viewModel.thread.forumID,
        forumName: viewModel.thread.forumName,
        threadID: viewModel.thread.id,
        onlyThreadAuthor: viewModel.options.onlyThreadAuthor
      ),
      localOccurrences: localOccurrences,
      selectedID: selectedID,
      isRemoteLoadingEnabled: false,
      service: galleryService
    )
    let route = ThreadImageGalleryRoute(viewModel: galleryViewModel)
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
      let leadingVisiblePostID,
      let leadingPost = viewModel.posts.first(where: { $0.id == leadingVisiblePostID }),
      effectiveVisibility(for: leadingPost) != .hidden
    {
      return leadingVisiblePostID
    }
    return viewModel.posts.first(where: { effectiveVisibility(for: $0) != .hidden })?.id
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
       let position = ThreadCloudFavoritePosition(post: visiblePost, threadID: threadID)
    {
      return position
    }
    if let firstPost = viewModel.firstPost,
       let position = ThreadCloudFavoritePosition(post: firstPost, threadID: threadID)
    {
      return position
    }
    return viewModel.posts.lazy.compactMap {
      ThreadCloudFavoritePosition(post: $0, threadID: threadID)
    }.first
  }

  private var threadAuthorAvatarURL: URL? {
    ThreadAuthorAvatarResolver.resolve(
      thread: viewModel.thread,
      firstPost: viewModel.firstPost,
      posts: viewModel.posts
    )
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

  private func togglePureReadingMode() {
    if !isPureReadingMode {
      pendingAgreementChange = nil
      agreementErrorMessage = nil
      contentAgreementStore?.removeScope(agreementScopeID)
    }
    withAnimation { isPureReadingMode.toggle() }
  }

  private func requestAgreementChange(
    _ target: ContentAgreementTarget,
    targetAgreed: Bool
  ) {
    guard !isPureReadingMode else { return }
    pendingCloudFavoriteAction = nil
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
    pendingAgreementChange = nil
    pendingCloudFavoriteAction = action
  }

  private func confirmCloudFavoriteAction(_ action: ThreadCloudFavoritePendingAction) {
    pendingCloudFavoriteAction = nil
    guard let threadCloudFavoriteStore else { return }
    Task { @MainActor in
      do {
        try await threadCloudFavoriteStore.setMarkedPostID(
          action.requestedMarkedPostID,
          for: action.target
        )
      } catch is CancellationError {
        return
      } catch {
        cloudFavoriteErrorMessage = error.localizedDescription
      }
    }
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

private struct PostFramePreferenceKey: PreferenceKey {
  static let defaultValue: [Int64: CGRect] = [:]

  static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
  }
}

private struct PrependAnchorFramePreferenceKey: PreferenceKey {
  static let defaultValue: [Int64: CGRect] = [:]

  static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
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

private struct PostView: View {
  let post: BrowsePost
  let agreementTarget: ContentAgreementTarget?
  let agreementFallbackScore: Int
  let originThread: BrowseThread?
  let poll: BrowsePoll?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let threadTitle: String
  let isPureReadingMode: Bool
  let openImage: (Int) -> Void
  let openMentionedUser: (Int64) -> Void
  let openTiebaLink: (TiebaLinkTarget) -> Void
  let requestAgreementChange: (ContentAgreementTarget, Bool) -> Void
  let retryAgreement: (ContentAgreementTarget) -> Void
  let openComments: (Int64?) -> Void

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  @Environment(\.contentAgreementStore) private var contentAgreementStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if isPureReadingMode {
        pureReadingContext
      } else {
        authorRow
      }

      BrowseContentView(
        contents: post.contents,
        onImageOpen: openImage,
        onUserMention: openMentionedUser,
        onTiebaLink: openTiebaLink
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
        PollResultsCard(poll: poll)
      }

      if let presentation = InlineCommentPreviewPresentation(
        post: post,
        isPureReadingMode: isPureReadingMode
      ) {
        InlineCommentPreviewCard(
          presentation: presentation,
          openComments: openComments
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contextMenu {
      if let copyText = PostCopyText.text(threadTitle: threadTitle, post: post) {
        Button {
          UIPasteboard.general.string = copyText
        } label: {
          Label("复制本楼内容", systemImage: "doc.on.doc")
        }
      }
    }
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
    }
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

private struct PollResultsCard: View {
  let poll: BrowsePoll

  @Environment(\.appAccentColor) private var appAccentColor

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label("投票结果", systemImage: "chart.bar.fill")
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

      VStack(alignment: .leading, spacing: 12) {
        ForEach(poll.options) { option in
          pollOption(option)
        }
      }

      Text("\(compactCount(poll.participantCount)) 人参与")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel("\(max(poll.participantCount, 0).formatted()) 人参与")
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

  private var pollTitle: String {
    let title = poll.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "投票" : title
  }

  private func pollOption(_ option: BrowsePollOption) -> some View {
    let percentage = poll.percentage(for: option)
    let voteCount = max(option.voteCount, 0)
    let text = option.text.isEmpty ? "选项 \(option.id + 1)" : option.text

    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(text)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("\(compactCount(voteCount)) 票 · \(percentage)%")
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
            .fill(appAccentColor.color.opacity(0.65))
            .frame(width: geometry.size.width * CGFloat(poll.progress(for: option)))
        }
      }
      .frame(height: 5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(text)，\(voteCount.formatted()) 票，\(percentage)%")
  }

  private func compactCount(_ value: Int64) -> String {
    max(value, 0).formatted(.number.notation(.compactName))
  }
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
          onTiebaLink: openTiebaLink
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
