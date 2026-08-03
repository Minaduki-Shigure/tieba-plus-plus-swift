import SwiftUI

struct HotThreadListView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotThreadService & UserProfileService
      & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: HotThreadListViewModel

  init(
    service: any BrowseService & ForumPostSearchService & HotThreadService & UserProfileService
      & ForumInformationService,
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
