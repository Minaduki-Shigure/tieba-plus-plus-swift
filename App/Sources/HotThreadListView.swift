import SwiftUI

struct HotThreadListView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: HotThreadListViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(wrappedValue: HotThreadListViewModel(service: service))
  }

  var body: some View {
    Group {
      if viewModel.hasLoadedInitialSnapshot {
        rankingList
      } else {
        initialState
      }
    }
    .navigationTitle("帖子热榜")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      if viewModel.hasLoadedInitialSnapshot {
        categoryTabs
      }
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .alert(
      "刷新失败",
      isPresented: Binding(
        get: { viewModel.refreshError != nil },
        set: { if !$0 { viewModel.clearRefreshError() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.clearRefreshError() }
    } message: {
      Text(viewModel.refreshError ?? "无法刷新帖子热榜。")
    }
  }

  @ViewBuilder
  private var initialState: some View {
    switch viewModel.state {
    case .idle, .loading:
      ProgressView()
    case .failed(let message):
      ErrorStateView(message: message, retry: viewModel.retry)
    case .loaded:
      EmptyStateView(title: "暂无热门帖子", systemImage: "chart.bar")
    }
  }

  private var rankingList: some View {
    List {
      if !viewModel.topics.isEmpty {
        hotTopicRanking
          .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
      }

      if viewModel.items.isEmpty {
        emptyContentRow
      } else {
        ForEach(viewModel.items) { item in
          LocallyFilteredContent(
            visibility: item.thread.localVisibility,
            placeholder: "已屏蔽此热门帖子"
          ) {
            NavigationLink {
              ThreadView(
                thread: item.thread,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              HotThreadRankRow(item: item)
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private var hotTopicRanking: some View {
    VStack(alignment: .leading, spacing: 10) {
      hotTopicHeader

      LazyVGrid(columns: hotTopicColumns, alignment: .leading, spacing: 8) {
        ForEach(Array(viewModel.topics.enumerated()), id: \.element.id) { entry in
          NavigationLink {
            HotTopicDetailView(
              topic: entry.element,
              service: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          } label: {
            HotThreadTopicRankRow(topic: entry.element, position: entry.offset + 1)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            hotTopicAccessibilityLabel(topic: entry.element, position: entry.offset + 1)
          )
          .accessibilityIdentifier("hot-thread-topic-\(entry.element.id)")
        }
      }
    }
  }

  @ViewBuilder
  private var hotTopicHeader: some View {
    if AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize) {
      VStack(alignment: .leading, spacing: 0) {
        hotTopicTitle
        allHotTopicsLink
      }
    } else {
      HStack(spacing: 12) {
        hotTopicTitle
        Spacer(minLength: 8)
        allHotTopicsLink
      }
    }
  }

  private var hotTopicTitle: some View {
    Label("热门话题", systemImage: "flame.fill")
      .font(.headline)
      .accessibilityAddTraits(.isHeader)
  }

  private var allHotTopicsLink: some View {
    NavigationLink {
      HotTopicListView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    } label: {
      HStack(spacing: 3) {
        Text("全部")
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
      }
      .font(.subheadline.weight(.semibold))
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("查看全部热门话题")
    .accessibilityIdentifier("hot-thread-all-topics")
  }

  private var hotTopicColumns: [GridItem] {
    let column = GridItem(.flexible(), spacing: 16, alignment: .leading)
    let count = AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize) ? 1 : 2
    return Array(repeating: column, count: count)
  }

  private func hotTopicAccessibilityLabel(topic: HotTopicItem, position: Int) -> String {
    let base = "第 \(position) 名，\(topic.name)"
    switch topic.tag {
    case 1:
      return "\(base)，新话题"
    case 2:
      return "\(base)，热门话题"
    default:
      return base
    }
  }

  @ViewBuilder
  private var emptyContentRow: some View {
    switch viewModel.state {
    case .idle, .loading:
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
      .frame(minHeight: 180)
      .listRowSeparator(.hidden)
    case .failed(let message):
      ErrorStateView(message: message, retry: viewModel.retry)
        .frame(maxWidth: .infinity, minHeight: 240)
        .listRowSeparator(.hidden)
    case .loaded:
      EmptyStateView(title: "暂无热门帖子", systemImage: "chart.bar")
        .frame(maxWidth: .infinity, minHeight: 240)
        .listRowSeparator(.hidden)
    }
  }

  private var categoryTabs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 20) {
        ForEach(viewModel.categories) { category in
          let isSelected = category.code == viewModel.selectedCategory.code
          Button {
            viewModel.selectCategory(category)
          } label: {
            VStack(spacing: 7) {
              Text(category.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
              Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(height: 2)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier("hot-thread-tab-\(category.code)")
        }
      }
      .padding(.horizontal, 16)
    }
    .background(.regularMaterial)
    .overlay(alignment: .bottom) { Divider() }
  }
}

private struct HotThreadTopicRankRow: View {
  let topic: HotTopicItem
  let position: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text("\(position)")
        .font(.caption.weight(.bold))
        .foregroundStyle(position <= 3 ? Color.red : Color.secondary)
        .frame(minWidth: 16, alignment: .trailing)
      Text(topic.name)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(2)
      topicTag
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var topicTag: some View {
    switch topic.tag {
    case 1:
      Text("新")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .fixedSize()
        .accessibilityHidden(true)
    case 2:
      Text("热")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.red)
        .fixedSize()
        .accessibilityHidden(true)
    default:
      EmptyView()
    }
  }
}

private struct HotThreadRankRow: View {
  let item: HotThreadRankItem

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("#\(item.rank)")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tint)
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 8)
        Label(
          "热度 \(item.hotScore.formatted(.number.notation(.compactName)))",
          systemImage: "flame.fill"
        )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
      ThreadSummaryRow(thread: item.thread, showsForum: true)
    }
  }
}
