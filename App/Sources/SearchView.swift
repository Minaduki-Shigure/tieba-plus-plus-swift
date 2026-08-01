import SwiftUI

struct SearchView: View {
  let browseService: any BrowseService

  @StateObject private var viewModel: SearchViewModel
  @State private var query: String

  init(
    query: String,
    browseService: any BrowseService,
    searchService: any SearchService
  ) {
    self.browseService = browseService
    _query = State(initialValue: query)
    _viewModel = StateObject(wrappedValue: SearchViewModel(query: query, service: searchService))
  }

  var body: some View {
    Group {
      if !viewModel.hasResults {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message) { viewModel.submit(query) }
        case .loaded:
          EmptyStateView(title: "没有找到结果", systemImage: "magnifyingglass")
        }
      } else {
        resultsList
      }
    }
    .navigationTitle(viewModel.submittedQuery)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "搜索贴吧和帖子")
    .onSubmit(of: .search) { viewModel.submit(query) }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
  }

  private var resultsList: some View {
    List {
      if let exactForum = viewModel.exactForum {
        Section("贴吧") {
          forumLink(exactForum, exact: true)
        }
      }

      if !viewModel.relatedForums.isEmpty {
        Section(viewModel.exactForum == nil ? "贴吧" : "相关贴吧") {
          ForEach(viewModel.relatedForums) { forum in
            forumLink(forum, exact: false)
          }
        }
      }

      if !viewModel.threads.isEmpty {
        Section("帖子") {
          ForEach(viewModel.threads) { thread in
            NavigationLink {
              ThreadView(thread: thread, service: browseService)
            } label: {
              SearchThreadRow(thread: thread)
            }
            .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
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
    }
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }

  private func forumLink(_ forum: ForumSearchItem, exact: Bool) -> some View {
    NavigationLink {
      ForumView(forumName: forum.name, service: browseService)
    } label: {
      ForumSearchRow(forum: forum, exact: exact)
    }
  }
}

private struct ForumSearchRow: View {
  let forum: ForumSearchItem
  let exact: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
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
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(forum.displayName)
            .font(.headline)
          if exact {
            Text("精确匹配")
              .font(.caption2)
              .foregroundStyle(.tint)
          }
        }
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

private struct SearchThreadRow: View {
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
        Label(thread.forumName, systemImage: "text.bubble")
          .lineLimit(1)
        Label(thread.authorName, systemImage: "person")
          .lineLimit(1)
        Spacer(minLength: 0)
        Label(thread.replyCount.formatted(), systemImage: "bubble.left")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}
