import SwiftUI

struct HotTopicDetailView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & UserProfileService
      & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: HotTopicDetailViewModel

  init(
    topic: HotTopicItem,
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
    _viewModel = StateObject(
      wrappedValue: HotTopicDetailViewModel(topic: topic, service: service)
    )
  }

  var body: some View {
    Group {
      if viewModel.hasLoadedDetails {
        detailList
      } else {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.retry)
        case .loaded:
          detailList
        }
      }
    }
    .navigationTitle(viewModel.topic.name)
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
      Text(viewModel.refreshError ?? "\u{65e0}\u{6cd5}\u{5237}\u{65b0}\u{8bdd}\u{9898}\u{5185}\u{5bb9}\u{3002}")
    }
  }

  private var detailList: some View {
    List {
      HotTopicHeader(topic: viewModel.topic)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)

      if !viewModel.relatedForums.isEmpty {
        Section("\u{76f8}\u{5173}\u{8d34}\u{5427}") {
          ForEach(viewModel.relatedForums) { forum in
            NavigationLink {
              ForumView(
                forumName: forum.name,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              HotTopicForumRow(forum: forum)
            }
          }
        }
      }

      Section("\u{76f8}\u{5173}\u{5e16}\u{5b50}") {
        if viewModel.threads.isEmpty {
          Label("\u{6682}\u{65e0}\u{76f8}\u{5173}\u{5e16}\u{5b50}", systemImage: "text.bubble")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.threads) { thread in
            NavigationLink {
              ThreadView(
                thread: thread,
                service: service,
                historyRepository: historyRepository,
                favoritesRepository: favoritesRepository,
                searchHistoryRepository: searchHistoryRepository
              )
            } label: {
              HotTopicThreadRow(thread: thread)
            }
            .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
          }
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
}

private struct HotTopicHeader: View {
  let topic: HotTopicItem

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HotTopicRemoteImage(url: topic.imageURL, maxPixelSize: 1_600)
        .aspectRatio(2.39, contentMode: .fit)
      VStack(alignment: .leading, spacing: 8) {
        Text("#\(topic.name)#")
          .font(.title3.weight(.bold))
          .fixedSize(horizontal: false, vertical: true)
        if !topic.summary.isEmpty {
          Text(topic.summary)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 14) {
          if topic.rank > 0 {
            Label("\u{6392}\u{540d} \(topic.rank)", systemImage: "chart.bar.fill")
          }
          Label(
            "\(topic.discussionCount.formatted()) \u{8ba8}\u{8bba}",
            systemImage: "bubble.left.and.bubble.right"
          )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
    }
  }
}

private struct HotTopicForumRow: View {
  let forum: ForumSearchItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: forum.avatarURL, name: forum.displayName, size: 44)
      VStack(alignment: .leading, spacing: 4) {
        Text("\(forum.displayName)\u{5427}")
          .font(.headline)
        if !forum.summary.isEmpty {
          Text(forum.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 12) {
          Label(forum.memberCount.formatted(), systemImage: "person.2")
          Label(forum.postCount.formatted(), systemImage: "text.bubble")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct HotTopicThreadRow: View {
  let thread: BrowseThread

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(thread.title.isEmpty ? thread.excerpt : thread.title)
        .font(.headline)
        .lineLimit(2)
      if !thread.excerpt.isEmpty, thread.excerpt != thread.title {
        Text(thread.excerpt)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      HStack(spacing: 12) {
        if !thread.forumName.isEmpty {
          Label("\(thread.forumName)\u{5427}", systemImage: "text.bubble")
        }
        if !thread.authorName.isEmpty {
          Label(thread.authorName, systemImage: "person")
        }
        Label(thread.replyCount.formatted(), systemImage: "arrowshape.turn.up.left")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .padding(.vertical, 3)
  }
}
