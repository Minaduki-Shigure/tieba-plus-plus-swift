import SwiftUI

private enum ForumSearchHistoryAction {
  case clearForum
  case resetAll
}

struct ForumPostSearchView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ForumPostSearchViewModel
  @State private var query = ""
  @State private var historyAction: ForumSearchHistoryAction?

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
      wrappedValue: ForumPostSearchViewModel(
        forumName: forumName,
        service: service,
        historyRepository: searchHistoryRepository
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      if !viewModel.isShowingHistory {
        optionsBar
        Divider()
      }
      content
    }
    .navigationTitle("\(viewModel.forumName)吧内搜索")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "在\(viewModel.forumName)吧内搜索")
    .onSubmit(of: .search) { viewModel.submit(query) }
    .onChange(of: query) { newValue in
      if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        viewModel.clearSearch()
      }
    }
    .toolbar {
      if viewModel.isShowingHistory, viewModel.historyError != nil {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(role: .destructive) { historyAction = .resetAll } label: {
            Image(systemName: "trash.slash")
          }
          .accessibilityLabel("重置全部吧内搜索记录")
          .help("重置全部吧内搜索记录")
        }
      } else if viewModel.isShowingHistory, !viewModel.history.isEmpty {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(role: .destructive) { historyAction = .clearForum } label: {
            Image(systemName: "trash")
          }
          .accessibilityLabel("清空本吧搜索记录")
          .help("清空本吧搜索记录")
        }
      }
    }
    .task { await viewModel.loadHistoryIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .alert("刷新失败", isPresented: refreshErrorIsPresented) {
      Button("好", role: .cancel) { viewModel.clearRefreshError() }
    } message: {
      Text(viewModel.refreshError ?? "无法刷新搜索结果。")
    }
    .confirmationDialog(
      historyActionTitle,
      isPresented: historyActionIsPresented,
      titleVisibility: .visible
    ) {
      switch historyAction {
      case .clearForum:
        Button("清空本吧搜索记录", role: .destructive) {
          Task { await viewModel.deleteAllHistory() }
        }
      case .resetAll:
        Button("重置全部吧内搜索记录", role: .destructive) {
          Task { await viewModel.resetHistory() }
        }
      case nil:
        EmptyView()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(historyActionMessage)
    }
  }

  private var refreshErrorIsPresented: Binding<Bool> {
    Binding(
      get: { viewModel.refreshError != nil },
      set: { isPresented in
        guard !isPresented else { return }
        viewModel.clearRefreshError()
      }
    )
  }

  private var historyActionIsPresented: Binding<Bool> {
    Binding(
      get: { historyAction != nil },
      set: { if !$0 { historyAction = nil } }
    )
  }

  private var historyActionTitle: String {
    switch historyAction {
    case .clearForum:
      "清空\(viewModel.forumName)吧的搜索记录？"
    case .resetAll:
      "重置全部吧内搜索记录？"
    case nil:
      "管理搜索记录"
    }
  }

  private var historyActionMessage: String {
    switch historyAction {
    case .clearForum:
      "只会删除这个贴吧保存在本机的搜索词。"
    case .resetAll:
      "这会删除所有贴吧保存在本机的搜索词，用于恢复损坏或版本不兼容的历史文件。"
    case nil:
      ""
    }
  }

  private var optionsBar: some View {
    HStack(spacing: 12) {
      Picker(
        "排序",
        selection: Binding(
          get: { viewModel.sort },
          set: { viewModel.setSort($0) }
        )
      ) {
        ForEach(ForumPostSearchSort.allCases) { sort in
          Text(sort.title).tag(sort)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: .infinity, minHeight: 32)
      .accessibilityIdentifier("forum-post-search-sort-picker")

      Picker(
        "范围",
        selection: Binding(
          get: { viewModel.filter },
          set: { viewModel.setFilter($0) }
        )
      ) {
        ForEach(ForumPostSearchFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: .infinity, minHeight: 32)
      .accessibilityIdentifier("forum-post-search-filter-picker")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isShowingHistory {
      historyList
    } else if viewModel.results.isEmpty {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.retry)
      case .loaded:
        emptyResults
      }
    } else {
      resultList
    }
  }

  private var historyList: some View {
    List {
      if let historyError = viewModel.historyError {
        Section("搜索记录无法读取") {
          Label(historyError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button {
            Task { await viewModel.retryHistory() }
          } label: {
            Label("重新读取", systemImage: "arrow.clockwise")
          }
        }
      }

      if !viewModel.history.isEmpty {
        Section("最近搜索") {
          ForEach(viewModel.history) { entry in
            Button {
              query = entry.query
              viewModel.submit(entry.query)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "clock")
                  .foregroundStyle(.secondary)
                  .accessibilityHidden(true)
                Text(entry.query)
                  .foregroundStyle(.primary)
                  .lineLimit(2)
                Spacer(minLength: 8)
                Text(entry.searchedAt, style: .relative)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await viewModel.deleteHistory(id: entry.id) }
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .overlay {
      if viewModel.history.isEmpty, viewModel.historyError == nil {
        if viewModel.isHistoryLoading {
          ProgressView()
        } else {
          EmptyStateView(title: "暂无搜索记录", systemImage: "clock")
        }
      }
    }
  }

  private var resultList: some View {
    List {
      Section("搜索结果") {
        ForEach(viewModel.results) { result in
          HStack(alignment: .top, spacing: 10) {
            authorAvatar(for: result)

            NavigationLink {
              destination(for: result)
            } label: {
              HStack(spacing: 8) {
                ForumPostSearchResultRow(result: result)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
                  .accessibilityHidden(true)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          .onAppear { viewModel.loadMoreIfNeeded(current: result) }
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
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private var emptyResults: some View {
    List {}
      .listStyle(.plain)
      .overlay {
        EmptyStateView(title: "没有找到相关内容", systemImage: "text.magnifyingglass")
      }
      .refreshable { await viewModel.refresh() }
  }

  @ViewBuilder
  private func authorAvatar(for result: ForumPostSearchItem) -> some View {
    if result.matchedAuthorID > 0 {
      NavigationLink {
        UserProfileView(
          userID: result.matchedAuthorID,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        AvatarView(
          url: result.matchedAuthorPortraitURL,
          name: result.matchedAuthorName,
          size: 36
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("查看\(result.matchedAuthorName)的资料")
    } else {
      AvatarView(
        url: result.matchedAuthorPortraitURL,
        name: result.matchedAuthorName,
        size: 36
      )
    }
  }

  @ViewBuilder
  private func destination(for result: ForumPostSearchItem) -> some View {
    switch result.target {
    case .thread:
      ThreadView(
        thread: result.thread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .post(let postID):
      ThreadView(
        thread: result.thread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        historySnapshot: ThreadHistorySnapshot(
          thread: result.thread,
          lastPostID: postID
        )
      )
    case .comment(_, let commentID):
      CommentsView(
        threadID: result.thread.id,
        aroundCommentID: commentID,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    }
  }
}

private struct ForumPostSearchResultRow: View {
  let result: ForumPostSearchItem

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 9) {
        VStack(alignment: .leading, spacing: 2) {
          Text(result.matchedAuthorName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          if let matchedAt = result.matchedAt {
            Text(matchedAt, style: .relative)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Label(result.target.title, systemImage: targetSystemImage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      let title = result.matchedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty {
        Text(title)
          .font(.headline)
          .lineLimit(3)
      }

      let excerpt = result.matchedExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
      if !excerpt.isEmpty, excerpt != title {
        Text(excerpt)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }

      ForumPostSearchMediaStrip(contents: result.matchedContents)

      if let context = result.context, result.target != .thread {
        VStack(alignment: .leading, spacing: 4) {
          Label(contextLabel, systemImage: "quote.opening")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          let contextTitle = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
          let contextExcerpt = context.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
          if !contextTitle.isEmpty {
            Text(contextTitle)
              .font(.subheadline.weight(.semibold))
              .lineLimit(2)
          }
          if !contextExcerpt.isEmpty, contextExcerpt != contextTitle {
            Text(contextExcerpt)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      HStack(spacing: 14) {
        if result.replyCount > 0 {
          Label(result.replyCount.formatted(), systemImage: "bubble.left")
        }
        if result.likeCount > 0 {
          Label(result.likeCount.formatted(), systemImage: "hand.thumbsup")
        }
        if result.shareCount > 0 {
          Label(result.shareCount.formatted(), systemImage: "arrowshape.turn.up.right")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var targetSystemImage: String {
    switch result.target {
    case .thread:
      "text.page"
    case .post:
      "arrowshape.turn.up.left"
    case .comment:
      "bubble.left.and.bubble.right"
    }
  }

  private var contextLabel: String {
    switch result.target {
    case .comment:
      "所属楼层"
    case .post:
      "相关原帖"
    case .thread:
      "帖子"
    }
  }
}

private struct ForumPostSearchMediaStrip: View {
  let contents: [BrowseContent]

  private var imageURLs: [URL] {
    contents.compactMap { content in
      guard case .image(let thumbnail, _, _, _) = content else { return nil }
      return thumbnail
    }
  }

  @ViewBuilder
  var body: some View {
    if !imageURLs.isEmpty {
      HStack(spacing: 6) {
        ForEach(Array(imageURLs.prefix(3).enumerated()), id: \.offset) { _, imageURL in
          DownsampledRemoteImage(url: imageURL, maxPixelSize: 512) { phase in
            switch phase {
            case .success(let renderedImage):
              renderedImage.resizable().scaledToFill()
            case .empty, .failure:
              Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemFill))
            }
          }
          .frame(maxWidth: .infinity)
          .frame(height: 88)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }
      .frame(height: 88)
    }
  }
}
