import SwiftUI

struct ThreadView: View {
  let service: any BrowseService & UserProfileService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository

  @StateObject private var viewModel: ThreadViewModel
  @State private var commentsPost: BrowsePost?
  @State private var showsPageJump = false
  @State private var pageInput = ""
  @State private var visiblePost: BrowsePost?
  private let historySnapshot: ThreadHistorySnapshot?

  init(
    thread: BrowseThread,
    service: any BrowseService & UserProfileService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    historySnapshot: ThreadHistorySnapshot? = nil
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.historySnapshot = historySnapshot
    _viewModel = StateObject(wrappedValue: ThreadViewModel(thread: thread, service: service))
  }

  var body: some View {
    Group {
      if viewModel.posts.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          EmptyStateView(title: "暂无楼层", systemImage: "bubble.left.and.bubble.right")
        }
      } else {
        postList
      }
    }
    .navigationTitle(
      viewModel.thread.title.isEmpty ? viewModel.thread.forumName : viewModel.thread.title
    )
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      optionsBar
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
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        LocalFavoriteButton(target: favoriteTarget, repository: favoritesRepository)

        Button {
          pageInput = viewModel.currentPage > 0 ? String(viewModel.currentPage) : ""
          showsPageJump = true
        } label: {
          Image(systemName: "number.square")
        }
        .disabled(viewModel.totalPages <= 1 || viewModel.isJumping)
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
    .task {
      let snapshot = await resumeSnapshot()
      guard !Task.isCancelled else { return }
      if let snapshot {
        viewModel.prepareResume(
          options: snapshot.browseOptions,
          postID: snapshot.lastPostID
        )
      }
      viewModel.loadIfNeeded()
      try? await historyRepository.record(
        .thread(
          ThreadHistorySnapshot(
            thread: viewModel.thread,
            browseOptions: viewModel.options,
            lastPostID: snapshot?.lastPostID,
            lastFloor: snapshot?.lastFloor
          )
        )
      )
    }
    .task(id: visiblePost?.id) {
      guard let visiblePost else { return }
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard !Task.isCancelled else { return }
      await persistProgress(visiblePost, options: viewModel.options)
    }
    .onChange(of: viewModel.options) { options in
      visiblePost = nil
      persistBrowseOptions(options)
    }
    .onDisappear {
      if let visiblePost {
        let options = viewModel.options
        Task { await persistProgress(visiblePost, options: options) }
      } else {
        persistBrowseOptions(viewModel.options)
      }
      viewModel.cancel()
    }
    .sheet(item: $commentsPost) { post in
      NavigationStack {
        CommentsView(
          threadID: post.threadID,
          postID: post.id,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository
        )
      }
      .presentationDetents([.medium, .large])
    }
  }

  private var optionsBar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
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

        Toggle(
          "只看楼主",
          isOn: Binding(
            get: { viewModel.options.onlyThreadAuthor },
            set: { onlyThreadAuthor in viewModel.setOnlyThreadAuthor(onlyThreadAuthor) }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("thread-author-toggle")
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Divider()
    }
  }

  private var postList: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(viewModel.posts) { post in
              PostView(
                post: post,
                originThread: post.floor == 1 ? viewModel.originThread : nil,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                openComments: { commentsPost = post }
              )
              .id(post.id)
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: PostFramePreferenceKey.self,
                    value: [post.id: geometry.frame(in: .named("thread-scroll"))]
                  )
                }
              }
              .onAppear {
                viewModel.loadMoreIfNeeded(current: post)
              }
              Divider()
                .padding(.leading, 52)
            }
            if viewModel.isLoadingMore || viewModel.isJumping {
              ProgressView()
                .padding(20)
            } else if let message = viewModel.loadMoreError {
              LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
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
            viewModel.posts.first(where: { $0.id == postID })
          }
        }
        .task(id: viewModel.scrollTargetPostID) {
          guard let postID = viewModel.scrollTargetPostID else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          proxy.scrollTo(postID, anchor: .top)
          viewModel.consumeScrollTarget()
        }
        .refreshable { await viewModel.refresh() }
      }
    }
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

  private var favoriteTarget: LocalFavoriteTarget {
    let progress = viewModel.options.sort == .hot ? nil : visiblePost
    let authorAvatarURL = viewModel.posts.first(where: { $0.isThreadAuthor })?.authorPortraitURL
    return .thread(
      ThreadHistorySnapshot(
        thread: viewModel.thread,
        authorAvatarURL: authorAvatarURL,
        browseOptions: viewModel.options,
        lastPostID: progress?.id,
        lastFloor: progress?.floor
      )
    )
  }
}

private struct PostFramePreferenceKey: PreferenceKey {
  static let defaultValue: [Int64: CGRect] = [:]

  static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
  }
}

private struct PostView: View {
  let post: BrowsePost
  let originThread: BrowseThread?
  let service: any BrowseService & UserProfileService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let openComments: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if post.authorID > 0 {
        NavigationLink {
          UserProfileView(
            userID: post.authorID,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
          )
        } label: {
          authorHeader
        }
        .buttonStyle(.plain)
      } else {
        authorHeader
      }

      BrowseContentView(contents: post.contents)

      if let originThread {
        OriginThreadCard(
          thread: originThread,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository
        )
      }

      if post.nestedReplyCount > 0 {
        Button(action: openComments) {
          Label("\(post.nestedReplyCount)", systemImage: "bubble.left")
            .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  private var authorHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      AvatarView(url: post.authorPortraitURL, name: post.authorName)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          Text(post.authorName)
            .font(.subheadline.weight(.semibold))
          if post.isThreadAuthor {
            Text("楼主")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.tint)
          }
        }
        HStack(spacing: 6) {
          Text("\(post.floor) 楼")
          if let date = post.createdAt {
            Text(date, style: .relative)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .opacity(post.authorID > 0 ? 1 : 0)
    }
    .contentShape(Rectangle())
  }
}

private struct OriginThreadCard: View {
  let thread: BrowseThread
  let service: any BrowseService & UserProfileService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NavigationLink {
        ThreadView(
          thread: thread,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository
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
        BrowseContentView(contents: thread.contents)
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
