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

  init(
    threadID: Int64,
    aroundCommentID commentID: Int64,
    service: any BrowseService & UserProfileService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(
        threadID: threadID,
        aroundCommentID: commentID,
        service: service
      )
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
              HStack(alignment: .top, spacing: 10) {
                if comment.authorID > 0 {
                  NavigationLink {
                    UserProfileView(
                      userID: comment.authorID,
                      service: service,
                      historyRepository: historyRepository,
                      favoritesRepository: favoritesRepository
                    )
                  } label: {
                    commentAuthorIdentity(comment)
                  }
                  .buttonStyle(.plain)
                } else {
                  commentAuthorIdentity(comment)
                }

                ReadOnlyAgreeLabel(score: comment.agreeScore)
                  .padding(.top, 2)
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

  private func commentAuthorIdentity(_ comment: BrowseComment) -> some View {
    HStack(alignment: .top, spacing: 10) {
      AvatarView(
        url: comment.authorPortraitURL,
        name: comment.authorName,
        size: 32
      )
      VStack(alignment: .leading, spacing: 2) {
        PostAuthorNameLine(
          name: comment.authorName,
          level: comment.authorLevel,
          isThreadAuthor: comment.isThreadAuthor
        )
        PostContextLine(
          date: comment.createdAt,
          ipLocation: comment.authorIPLocation
        )
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
