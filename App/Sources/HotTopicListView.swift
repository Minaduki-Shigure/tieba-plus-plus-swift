import SwiftUI

struct HotTopicListView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & UserProfileService
      & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: HotTopicListViewModel

  init(
    service: any BrowseService & ForumPostSearchService & HotTopicService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(wrappedValue: HotTopicListViewModel(service: service))
  }

  var body: some View {
    Group {
      if viewModel.topics.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.retry)
        case .loaded:
          emptyList
        }
      } else {
        topicList
      }
    }
    .navigationTitle("\u{70ed}\u{95e8}\u{8bdd}\u{9898}")
    .navigationBarTitleDisplayMode(.inline)
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .alert(
      "\u{5237}\u{65b0}\u{5931}\u{8d25}",
      isPresented: Binding(
        get: { viewModel.refreshError != nil },
        set: { if !$0 { viewModel.clearRefreshError() } }
      )
    ) {
      Button("\u{597d}", role: .cancel) { viewModel.clearRefreshError() }
    } message: {
      Text(viewModel.refreshError ?? "\u{65e0}\u{6cd5}\u{5237}\u{65b0}\u{70ed}\u{95e8}\u{8bdd}\u{9898}\u{3002}")
    }
  }

  private var topicList: some View {
    List {
      ForEach(viewModel.topics) { topic in
        NavigationLink {
          HotTopicDetailView(
            topic: topic,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        } label: {
          HotTopicRow(topic: topic, featured: topic.rank > 0 && topic.rank <= 3)
        }
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }

  private var emptyList: some View {
    List {}
      .listStyle(.plain)
      .overlay {
        EmptyStateView(
          title: "\u{6682}\u{65e0}\u{70ed}\u{95e8}\u{8bdd}\u{9898}",
          systemImage: "flame"
        )
        .allowsHitTesting(false)
      }
      .refreshable { await viewModel.refresh() }
  }
}

private struct HotTopicRow: View {
  let topic: HotTopicItem
  let featured: Bool

  var body: some View {
    if featured {
      VStack(alignment: .leading, spacing: 9) {
        HotTopicRemoteImage(url: topic.imageURL, maxPixelSize: 1_200)
          .aspectRatio(2.39, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(alignment: .topLeading) {
            rankBadge.allowsHitTesting(false)
          }
        topicBody(summaryLines: 3)
      }
      .padding(.vertical, 6)
    } else {
      HStack(alignment: .top, spacing: 12) {
        HotTopicRemoteImage(url: topic.imageURL, maxPixelSize: 320)
          .frame(width: 76, height: 76)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(alignment: .topLeading) {
            rankBadge.allowsHitTesting(false)
          }
        topicBody(summaryLines: 2)
      }
      .padding(.vertical, 4)
    }
  }

  private func topicBody(summaryLines: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        Text(topic.name)
          .font(.headline)
          .lineLimit(2)
        tagBadge
      }
      if !topic.summary.isEmpty {
        Text(topic.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(summaryLines)
      }
      Label(
        "\(topic.discussionCount.formatted()) \u{8ba8}\u{8bba}",
        systemImage: "bubble.left.and.bubble.right"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var rankBadge: some View {
    Text("\(topic.rank)")
      .font(.caption2.weight(.bold))
      .foregroundStyle(topic.rank == 3 ? Color.black : Color.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(rankColor)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .padding(6)
      .accessibilityLabel("\u{6392}\u{540d} \(topic.rank)")
  }

  @ViewBuilder
  private var tagBadge: some View {
    switch topic.tag {
    case 1:
      Text("\u{65b0}")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityLabel("\u{65b0}\u{8bdd}\u{9898}")
    case 2:
      Text("\u{70ed}")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.red)
        .accessibilityLabel("\u{70ed}\u{95e8}\u{8bdd}\u{9898}")
    default:
      EmptyView()
    }
  }

  private var rankColor: Color {
    switch topic.rank {
    case 1:
      .red
    case 2:
      .orange
    case 3:
      .yellow
    default:
      .secondary
    }
  }
}

struct HotTopicRemoteImage: View {
  let url: URL?
  let maxPixelSize: Int

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  var body: some View {
    ContentRemoteImage(
      url: url,
      maxPixelSize: maxPixelSize,
      loadAccessibilityLabel: "加载话题图片"
    ) { phase in
      switch phase {
      case .success(let asset, _):
        RemoteImageAssetView(asset: asset, contentMode: .fill)
          .contentThumbnailDimming()
          .accessibilityHidden(true)
      case .empty:
        ZStack {
          Color(uiColor: .secondarySystemFill)
          ProgressView()
        }
        .accessibilityHidden(true)
      case .loadRequired:
        imageActionPlaceholder(systemImage: "arrow.down.circle")
      case .failure:
        imageActionPlaceholder(systemImage: failureSystemImage)
      }
    }
    .buttonStyle(.borderless)
    .clipped()
  }

  private func imageActionPlaceholder(systemImage: String) -> some View {
    Image(systemName: systemImage)
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .secondarySystemFill))
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }

  private var failureSystemImage: String {
    contentMediaLoadBehavior == .userInitiated
      && url.map(RemoteImageURLPolicy.allows) == true
      ? "arrow.clockwise.circle"
      : "photo.badge.exclamationmark"
  }
}
