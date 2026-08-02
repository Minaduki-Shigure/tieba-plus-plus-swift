import SwiftUI

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: CommentsViewModel
  let service: any BrowseService & UserProfileService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository

  init(
    threadID: Int64,
    postID: Int64,
    service: any BrowseService & UserProfileService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
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
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                if comment.authorID > 0 {
                  NavigationLink {
                    UserProfileView(
                      userID: comment.authorID,
                      service: service,
                      historyRepository: historyRepository,
                      favoritesRepository: favoritesRepository
                    )
                  } label: {
                    HStack(spacing: 10) {
                      AvatarView(
                        url: comment.authorPortraitURL,
                        name: comment.authorName,
                        size: 32
                      )
                      Text(comment.authorName)
                        .font(.subheadline.weight(.semibold))
                    }
                  }
                  .buttonStyle(.plain)
                } else {
                  HStack(spacing: 10) {
                    AvatarView(
                      url: comment.authorPortraitURL,
                      name: comment.authorName,
                      size: 32
                    )
                    Text(comment.authorName)
                      .font(.subheadline.weight(.semibold))
                  }
                }
                Spacer()
                if let date = comment.createdAt {
                  Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              BrowseContentView(contents: comment.contents)
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
          } else if let message = viewModel.loadMoreError {
            LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
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
