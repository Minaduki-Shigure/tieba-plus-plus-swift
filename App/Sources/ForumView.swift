import SwiftUI

struct ForumView: View {
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ForumViewModel

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
    _viewModel = StateObject(wrappedValue: ForumViewModel(forumName: forumName, service: service))
  }

  var body: some View {
    Group {
      if viewModel.threads.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          EmptyStateView(title: "暂无帖子", systemImage: "text.bubble")
        }
      } else {
        threadList
      }
    }
    .navigationTitle(viewModel.forumName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        NavigationLink {
          ForumPostSearchView(
            forumName: viewModel.forumName,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("吧内搜索")
        .help("吧内搜索")

        LocalFavoriteButton(
          target: .forum(ForumHistorySnapshot(forum: viewModel.forum)),
          repository: favoritesRepository
        )
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      optionsBar
    }
    .task { viewModel.loadIfNeeded() }
    .task(id: viewModel.forum.id) {
      guard viewModel.forum.id > 0 else { return }
      try? await historyRepository.record(
        .forum(ForumHistorySnapshot(forum: viewModel.forum))
      )
    }
    .onDisappear(perform: viewModel.cancel)
  }

  private var optionsBar: some View {
    VStack(spacing: 0) {
      if !viewModel.channels.isEmpty {
        HStack(spacing: 10) {
          Label("频道", systemImage: "rectangle.3.group")
          Spacer(minLength: 0)
          Picker(
            "频道",
            selection: Binding(
              get: { viewModel.selectedChannelID },
              set: { channelID in viewModel.setChannelID(channelID) }
            )
          ) {
            Text("全部主题").tag(Int?.none)
            ForEach(viewModel.channels) { channel in
              Text(channel.name).tag(Optional(channel.id))
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("forum-channel-picker")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(.regularMaterial)
      }

      HStack(spacing: 12) {
        Picker(
          "主题排序",
          selection: Binding(
            get: { viewModel.options.sort },
            set: { sort in viewModel.setSort(sort) }
          )
        ) {
          ForEach(ForumThreadSort.allCases) { sort in
            Text(sort.title).tag(sort)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity, minHeight: 32)
        .accessibilityIdentifier("forum-sort-picker")

        if viewModel.selectedChannelID == nil {
          Toggle(
            "精华",
            isOn: Binding(
              get: { viewModel.options.featuredOnly },
              set: { featuredOnly in viewModel.setFeaturedOnly(featuredOnly) }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .fixedSize()
          .accessibilityIdentifier("forum-featured-toggle")
        }
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      if viewModel.selectedChannelID == nil,
        viewModel.options.featuredOnly,
        !viewModel.forum.featuredClassifications.isEmpty
      {
        HStack(spacing: 10) {
          Label("精华分类", systemImage: "line.3.horizontal.decrease.circle")
          Spacer(minLength: 0)
          Picker(
            "精华分类",
            selection: Binding(
              get: { viewModel.options.featuredClassificationID },
              set: { classificationID in
                viewModel.setFeaturedClassificationID(classificationID)
              }
            )
          ) {
            Text("全部").tag(Int?.none)
            ForEach(viewModel.forum.featuredClassifications) { classification in
              Text(classification.name).tag(Optional(classification.id))
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("forum-featured-classification-picker")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
      }

      Divider()
    }
  }

  private var threadList: some View {
    List {
      NavigationLink {
        ForumInformationView(
          forum: viewModel.forum,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        ForumHeaderView(forum: viewModel.forum)
      }
      .disabled(viewModel.forum.id <= 0)
      .listRowSeparator(.hidden)

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
          ThreadRow(thread: thread)
        }
        .onAppear {
          viewModel.loadMoreIfNeeded(current: thread)
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
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }
}

private struct ForumHeaderView: View {
  let forum: BrowseForum

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      DownsampledRemoteImage(url: forum.avatarURL, maxPixelSize: 256) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        default:
          Image(systemName: "text.bubble.fill")
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemFill))
        }
      }
      .frame(width: 58, height: 58)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 7) {
        Text("\(forum.name)吧")
          .font(.headline)
          .lineLimit(1)

        if !forum.slogan.isEmpty {
          Text(forum.slogan)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 12) {
            Label(forum.memberCount.formatted(), systemImage: "person.2")
            Label(forum.threadCount.formatted(), systemImage: "text.bubble")
          }

          if forum.hasRules || forum.hasModerators {
            HStack(spacing: 12) {
              if forum.hasRules {
                Label("吧规", systemImage: "doc.text")
              }
              if forum.hasModerators {
                Label("吧务", systemImage: "checkmark.shield")
              }
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        let category = [forum.category, forum.subcategory]
          .filter { !$0.isEmpty }
          .joined(separator: " · ")
        if !category.isEmpty {
          Text(category)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
  }
}

private struct ThreadRow: View {
  let thread: BrowseThread

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(thread.title.isEmpty ? thread.excerpt : thread.title)
        .font(.headline)
        .lineLimit(2)
      if !thread.title.isEmpty, !thread.excerpt.isEmpty {
        Text(thread.excerpt)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      HStack(spacing: 12) {
        Label(thread.authorName, systemImage: "person")
          .lineLimit(1)
        Spacer(minLength: 0)
        Label(thread.replyCount.formatted(), systemImage: "bubble.left")
        Label(thread.viewCount.formatted(), systemImage: "eye")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}
