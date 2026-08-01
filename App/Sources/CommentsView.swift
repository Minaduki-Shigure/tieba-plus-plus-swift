import SwiftUI

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: CommentsViewModel

  init(threadID: Int64, postID: Int64, service: any BrowseService) {
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(threadID: threadID, postID: postID, service: service)
    )
  }

  var body: some View {
    Group {
      switch viewModel.state {
      case .idle, .loading:
        ProgressView()
      case .failed(let message):
        ErrorStateView(message: message, retry: viewModel.reload)
      case .loaded:
        List {
          ForEach(viewModel.comments) { comment in
            HStack(alignment: .top, spacing: 10) {
              AvatarView(url: comment.authorPortraitURL, name: comment.authorName, size: 32)
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(comment.authorName)
                    .font(.subheadline.weight(.semibold))
                  Spacer()
                  if let date = comment.createdAt {
                    Text(date, style: .relative)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                BrowseContentView(contents: comment.contents)
              }
            }
            .padding(.vertical, 4)
            .onAppear {
              viewModel.loadMoreIfNeeded(current: comment)
            }
          }
          if viewModel.isLoadingMore {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowSeparator(.hidden)
          }
        }
        .listStyle(.plain)
        .overlay {
          if viewModel.comments.isEmpty {
            EmptyStateView(title: "暂无楼中楼回复", systemImage: "bubble.left")
          }
        }
        .refreshable { await viewModel.refresh() }
      }
    }
    .navigationTitle("楼中楼")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("完成") { dismiss() }
      }
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
  }
}
