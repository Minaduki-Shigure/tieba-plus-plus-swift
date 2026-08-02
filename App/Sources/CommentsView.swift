import Combine
import SwiftUI
import UIKit

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: CommentsViewModel
  @State private var linkedTarget: TiebaLinkTarget?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  init(
    threadID: Int64,
    postID: Int64,
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
    _viewModel = StateObject(
      wrappedValue: CommentsViewModel(threadID: threadID, postID: postID, service: service)
    )
  }

  init(
    threadID: Int64,
    aroundCommentID commentID: Int64,
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
        ScrollViewReader { proxy in
          List {
            ForEach(viewModel.comments) { comment in
              LocallyFilteredContent(
                visibility: comment.localVisibility,
                placeholder: "已屏蔽此条回复"
              ) {
                VStack(alignment: .leading, spacing: 7) {
                  HStack(alignment: .top, spacing: 10) {
                    if comment.authorID > 0 {
                      NavigationLink {
                        UserProfileView(
                          userID: comment.authorID,
                          service: service,
                          historyRepository: historyRepository,
                          favoritesRepository: favoritesRepository,
                          searchHistoryRepository: searchHistoryRepository
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
                  BrowseContentView(
                    contents: comment.contents,
                    onUserMention: openMentionedUser,
                    onTiebaLink: openTiebaLink
                  )
                }
                .padding(.vertical, 4)
                .contextMenu {
                  if let copyText = BrowseContentCopyText.text(comment.contents) {
                    Button {
                      UIPasteboard.general.string = copyText
                    } label: {
                      Label("复制此条回复", systemImage: "doc.on.doc")
                    }
                  }
                }
              }
              .id(comment.id)
              .onAppear {
                viewModel.loadMoreIfNeeded(current: comment)
              }
            }
            if let lastComment = viewModel.comments.last {
              Color.clear
                .frame(height: 1)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
                .onAppear { viewModel.loadMoreIfNeeded(current: lastComment) }
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
          .task(id: viewModel.scrollTargetCommentID) {
            guard let commentID = viewModel.scrollTargetCommentID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(commentID, anchor: .center)
            viewModel.consumeScrollTarget()
          }
          .refreshable { await viewModel.refresh() }
        }
      }
    }
    .navigationTitle(viewModel.totalCount > 0 ? "\(viewModel.totalCount) 条回复" : "楼中楼")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: linkedTargetPresented) {
      if let linkedTarget {
        TiebaLinkDestination(
          target: linkedTarget,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      }
    }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("完成") { dismiss() }
      }
    }
    .task { viewModel.loadIfNeeded() }
    .onDisappear(perform: viewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in viewModel.reload() }
    }
  }

  private var linkedTargetPresented: Binding<Bool> {
    Binding(
      get: { linkedTarget != nil },
      set: { isPresented in
        if !isPresented { linkedTarget = nil }
      }
    )
  }

  private func openMentionedUser(_ userID: Int64) {
    guard userID > 0 else { return }
    linkedTarget = .user(userID)
  }

  private func openTiebaLink(_ target: TiebaLinkTarget) {
    linkedTarget = target
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
