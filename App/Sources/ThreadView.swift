import SwiftUI

struct ThreadView: View {
  let service: any BrowseService

  @StateObject private var viewModel: ThreadViewModel
  @State private var commentsPost: BrowsePost?

  init(thread: BrowseThread, service: any BrowseService) {
    self.service = service
    _viewModel = StateObject(wrappedValue: ThreadViewModel(thread: thread, service: service))
  }

  var body: some View {
    Group {
      if viewModel.posts.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          EmptyStateView(title: "暂无楼层", systemImage: "bubble.left.and.bubble.right")
        }
      } else {
        postList
      }
    }
    .navigationTitle(
      viewModel.thread.title.isEmpty ? viewModel.thread.forumName : viewModel.thread.title
    )
    .navigationBarTitleDisplayMode(.inline)
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .sheet(item: $commentsPost) { post in
      NavigationStack {
        CommentsView(
          threadID: post.threadID,
          postID: post.id,
          service: service
        )
      }
      .presentationDetents([.medium, .large])
    }
  }

  private var postList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(viewModel.posts) { post in
          PostView(post: post) {
            commentsPost = post
          }
          .onAppear {
            viewModel.loadMoreIfNeeded(current: post)
          }
          Divider()
            .padding(.leading, 52)
        }
        if viewModel.isLoadingMore {
          ProgressView()
            .padding(20)
        } else if let message = viewModel.loadMoreError {
          LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
        }
      }
    }
    .refreshable { await viewModel.refresh() }
  }
}

private struct PostView: View {
  let post: BrowsePost
  let openComments: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        AvatarView(url: post.authorPortraitURL, name: post.authorName)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(post.authorName)
              .font(.subheadline.weight(.semibold))
            if post.isThreadAuthor {
              Text("楼主")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
            }
          }
          HStack(spacing: 6) {
            Text("\(post.floor) 楼")
            if let date = post.createdAt {
              Text(date, style: .relative)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      BrowseContentView(contents: post.contents)

      if post.nestedReplyCount > 0 {
        Button(action: openComments) {
          Label("\(post.nestedReplyCount)", systemImage: "bubble.left")
            .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }
}
