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
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
  }

  private var threadList: some View {
    List(viewModel.threads) { thread in
      NavigationLink {
        ThreadView(thread: thread, service: service)
      } label: {
        ThreadRow(thread: thread)
      }
      .onAppear {
        viewModel.loadMoreIfNeeded(current: thread)
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
    .overlay(alignment: .bottom) {
      if viewModel.isLoadingMore {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Circle())
          .padding()
      }
    }
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
