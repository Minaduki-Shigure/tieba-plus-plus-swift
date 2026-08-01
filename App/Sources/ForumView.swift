import SwiftUI

struct ForumView: View {
  let service: any BrowseService

  @StateObject private var viewModel: ForumViewModel

  init(forumName: String, service: any BrowseService) {
    self.service = service
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
    .safeAreaInset(edge: .top, spacing: 0) {
      optionsBar
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
  }

  private var optionsBar: some View {
    VStack(spacing: 0) {
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
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Divider()
    }
  }

  private var threadList: some View {
    List {
      ForEach(viewModel.threads) { thread in
        NavigationLink {
          ThreadView(thread: thread, service: service)
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
