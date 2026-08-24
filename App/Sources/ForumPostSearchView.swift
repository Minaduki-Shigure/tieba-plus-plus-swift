import Combine
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

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var viewModel: ForumPostSearchViewModel
  @State private var query = ""
  @State private var historyAction: ForumSearchHistoryAction?
  @State private var selectedDestination: ForumPostSearchDestination?

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
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in viewModel.reloadAfterContentFilterChange() }
    }
    .navigationDestination(isPresented: selectedDestinationIsPresented) {
      if let selectedDestination {
        destination(for: selectedDestination)
      } else {
        EmptyView()
      }
    }
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

  private var selectedDestinationIsPresented: Binding<Bool> {
    Binding(
      get: { selectedDestination != nil },
      set: { if !$0 { selectedDestination = nil } }
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
    Group {
      if AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize) {
        VStack(spacing: 8) {
          forumPostSearchSortPicker
          forumPostSearchFilterPicker
        }
      } else {
        HStack(spacing: 12) {
          forumPostSearchSortPicker
          forumPostSearchFilterPicker
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
  }

  private var forumPostSearchSortPicker: some View {
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
  }

  private var forumPostSearchFilterPicker: some View {
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
        ForEach(viewModel.displayableResults) { result in
          LocallyFilteredContent(
            visibility: result.localVisibility,
            placeholder: "已屏蔽此搜索结果"
          ) {
            HStack(alignment: .top, spacing: 10) {
              authorAvatar(for: result)

              VStack(alignment: .leading, spacing: 9) {
                primaryNavigation(for: result)

                ForumPostSearchMediaStrip(
                  contents: result.matchedContents,
                  destination: ForumPostSearchNavigationPolicy.primaryDestination(for: result),
                  onOpen: { selectedDestination = $0 }
                )

                ForEach(result.contexts) { context in
                  contextNavigation(for: result, context: context)
                }

                ForumPostSearchMetrics(result: result)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 4)
            }
          }
          .frame(minHeight: 44)
        }

        if !viewModel.results.isEmpty && !viewModel.hasDisplayableResults {
          Label("暂无可显示的搜索结果", systemImage: "eye.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        }

        if let rawTail = viewModel.results.last {
          Color.clear
            .frame(height: 1)
            .id(
              "forum-post-search-pagination-\(rawTail.id)-"
                + "\(viewModel.results.count)-\(viewModel.resultPaginationEpoch)"
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .onAppear { viewModel.loadMoreIfNeeded(current: rawTail) }
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
    .environment(\.defaultMinListRowHeight, 1)
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
    if let destination = ForumPostSearchNavigationPolicy.authorDestination(for: result) {
      Button {
        selectedDestination = destination
      } label: {
        AvatarView(
          url: result.matchedAuthorPortraitURL,
          name: displayedAuthorName(for: result),
          size: 36
        )
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("查看\(displayedAuthorName(for: result))的资料")
    } else {
      AvatarView(
        url: result.matchedAuthorPortraitURL,
        name: displayedAuthorName(for: result),
        size: 36
      )
      .frame(width: 44, height: 44)
    }
  }

  @ViewBuilder
  private func primaryNavigation(for result: ForumPostSearchItem) -> some View {
    if let destination = ForumPostSearchNavigationPolicy.primaryDestination(for: result) {
      Button {
        selectedDestination = destination
      } label: {
        HStack(spacing: 8) {
          ForumPostSearchResultRow(result: result)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("打开搜索命中内容")
    } else {
      ForumPostSearchResultRow(result: result)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
  }

  @ViewBuilder
  private func contextNavigation(
    for result: ForumPostSearchItem,
    context: ForumPostSearchContext
  ) -> some View {
    LocallyFilteredContent(
      visibility: context.summary.localVisibility,
      placeholder: "已屏蔽\(context.target.title)"
    ) {
      if
        let destination = ForumPostSearchNavigationPolicy.contextDestination(
          for: result,
          context: context
        )
      {
        Button {
          selectedDestination = destination
        } label: {
          HStack(spacing: 8) {
            ForumPostSearchContextRow(context: context)
              .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开\(context.target.title)")
      } else {
        ForumPostSearchContextRow(context: context)
      }
    }
  }

  private func displayedAuthorName(for result: ForumPostSearchItem) -> String {
    UserNameFormatter.displayName(
      preferredName: result.matchedAuthorName,
      username: result.matchedAuthorUsername,
      showsBoth: showsBothNames
    )
  }

  @ViewBuilder
  private func destination(for destination: ForumPostSearchDestination) -> some View {
    switch destination {
    case .thread(let thread, let route):
      ThreadView(
        thread: thread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
      .id("forum-search-thread:\(route.threadID):\(route.postID ?? 0)")
    case .resolvingComment(let threadID, let commentID):
      CommentsView(
        threadID: threadID,
        resolvingCommentID: commentID,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        presentationContext: .navigation
      )
      .id("forum-search-comment:\(threadID):\(commentID)")
    case .user(let userID):
      UserProfileView(
        userID: userID,
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

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 9) {
        VStack(alignment: .leading, spacing: 2) {
          Text(displayedAuthorName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(showsBothNames ? 3 : 1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel(displayedAuthorName)
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
    }
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

  private var displayedAuthorName: String {
    UserNameFormatter.displayName(
      preferredName: result.matchedAuthorName,
      username: result.matchedAuthorUsername,
      showsBoth: showsBothNames
    )
  }

}

private struct ForumPostSearchContextRow: View {
  let context: ForumPostSearchContext

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(context.target.title, systemImage: contextSystemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      let title = context.summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let excerpt = context.summary.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
      }
      if !excerpt.isEmpty, excerpt != title {
        Text(excerpt)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .padding(8)
    .background(Color(uiColor: .secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var contextSystemImage: String {
    switch context.target {
    case .mainPost:
      "text.page"
    case .parentPost:
      "quote.opening"
    }
  }
}

private struct ForumPostSearchMetrics: View {
  let result: ForumPostSearchItem

  var body: some View {
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
}

enum ForumPostSearchMediaPresentation: Equatable, Sendable {
  case expanded(imageURLs: [URL], totalCount: Int)
  case collapsed(ThreadListMediaSummary)
  case none

  static func resolve(
    contents: [BrowseContent],
    hidesMedia: Bool,
    quality: ContentImagePreviewQuality = .standard
  ) -> Self {
    var imageURLs: [URL] = []
    var totalCount = 0
    for content in contents {
      guard case .image(let thumbnail, let fullSize, _, let dynamic, _, _) = content else {
        continue
      }
      totalCount += 1
      if !hidesMedia, imageURLs.count < 3 {
        imageURLs.append(
          BrowseContentImageSourceResolver.previewURL(
            thumbnail: thumbnail,
            fullSize: fullSize,
            dynamic: dynamic,
            quality: quality
          )
        )
      }
    }
    guard totalCount > 0 else { return .none }
    if hidesMedia {
      return .collapsed(.images(count: totalCount))
    }
    return .expanded(imageURLs: imageURLs, totalCount: totalCount)
  }
}

private struct ForumPostSearchMediaStrip: View {
  private static let previewMaxPixelSize = 512

  let contents: [BrowseContent]
  let destination: ForumPostSearchDestination?
  let onOpen: (ForumPostSearchDestination) -> Void

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior
  @Environment(\.contentImagePreviewQuality) private var contentImagePreviewQuality
  @Environment(\.hidesThreadListMedia) private var hidesThreadListMedia

  @ViewBuilder
  var body: some View {
    switch ForumPostSearchMediaPresentation.resolve(
      contents: contents,
      hidesMedia: hidesThreadListMedia,
      quality: contentImagePreviewQuality
    ) {
    case .expanded(let imageURLs, let totalCount):
      expandedAccessibility(totalCount: totalCount) {
        expandedImages(imageURLs, totalCount: totalCount)
      }
    case .collapsed(let summary):
      if let destination {
        Button {
          onOpen(destination)
        } label: {
          CompactListMediaView(summary: summary, permitsHitTesting: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("打开搜索命中内容，\(summary.accessibilityLabel)")
      } else {
        CompactListMediaView(summary: summary)
      }
    case .none:
      EmptyView()
    }
  }

  private func expandedImages(
    _ imageURLs: [URL],
    totalCount: Int
  ) -> some View {
    HStack(spacing: 6) {
      ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, imageURL in
        ContentRemoteImage(
          url: imageURL,
          maxPixelSize: Self.previewMaxPixelSize,
          loadAccessibilityLabel: "加载搜索结果图片 \(index + 1)"
        ) { phase in
          switch phase {
          case .success(let asset, _):
            mediaNavigationButton(
              accessibilityLabel:
                "打开搜索命中内容，图片预览 \(index + 1)，"
                + "共 \(max(totalCount, 0).formatted()) 张"
            ) {
              RemoteImageAssetView(asset: asset, contentMode: .fill)
                .contentThumbnailDimming()
            }
          case .empty:
            mediaNavigationButton(accessibilityLabel: "打开搜索命中内容") {
              ZStack {
                Color(uiColor: .secondarySystemFill)
                ProgressView()
              }
            }
          case .loadRequired:
            if presentsManualImageAction(for: imageURL) {
              mediaActionPlaceholder(systemImage: "arrow.down.circle")
            } else {
              mediaNavigationButton(accessibilityLabel: "打开搜索命中内容") {
                mediaActionPlaceholder(systemImage: "arrow.down.circle")
              }
            }
          case .failure:
            if presentsManualImageAction(for: imageURL) {
              mediaActionPlaceholder(systemImage: failureSystemImage(for: imageURL))
            } else {
              mediaNavigationButton(accessibilityLabel: "打开搜索命中内容") {
                mediaActionPlaceholder(systemImage: failureSystemImage(for: imageURL))
              }
            }
          }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
    .frame(height: 88)
  }

  @ViewBuilder
  private func expandedAccessibility<Content: View>(
    totalCount: Int,
    @ViewBuilder content: () -> Content
  ) -> some View {
    switch contentMediaLoadBehavior {
    case .automatic, .economicalNetworkOnly:
      if destination == nil {
        content()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(max(totalCount, 0).formatted()) 张图片预览")
      } else {
        content()
      }
    case .userInitiated:
      content()
    }
  }

  private func mediaActionPlaceholder(systemImage: String) -> some View {
    Image(systemName: systemImage)
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .secondarySystemFill))
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func mediaNavigationButton<Content: View>(
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if let destination {
      Button {
        onOpen(destination)
      } label: {
        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(accessibilityLabel)
    } else {
      content()
    }
  }

  private func presentsManualImageAction(for imageURL: URL) -> Bool {
    ContentRemoteImageLoadDecision.permitsManualAction(
      behavior: contentMediaLoadBehavior,
      request: ContentRemoteImageRequestIdentity(
        url: imageURL,
        maxPixelSize: Self.previewMaxPixelSize
      )
    )
  }

  private func failureSystemImage(for imageURL: URL) -> String {
    contentMediaLoadBehavior == .userInitiated && RemoteImageURLPolicy.allows(imageURL)
      ? "arrow.clockwise.circle"
      : "photo.badge.exclamationmark"
  }
}
