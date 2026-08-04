import Combine
import SwiftUI
import UIKit

struct CommentsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appAccentColor) private var appAccentColor
  @StateObject private var viewModel: CommentsViewModel
  @State private var linkedTarget: TiebaLinkTarget?
  @State private var highlightedComment: CommentHighlightToken?
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
    postID: Int64,
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
        postID: postID,
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
            if let parentPost = viewModel.parentPost,
              parentPost.localVisibility != .hidden
            {
              LocallyFilteredContent(
                visibility: parentPost.localVisibility,
                placeholder: "已屏蔽父楼"
              ) {
                CommentParentPostView(
                  post: parentPost,
                  service: service,
                  historyRepository: historyRepository,
                  favoritesRepository: favoritesRepository,
                  searchHistoryRepository: searchHistoryRepository,
                  openMentionedUser: openMentionedUser,
                  openTiebaLink: openTiebaLink
                )
              }
              .id(CommentsListItemID.parentPost(parentPost.id))
            }

            Section {
              if viewModel.isLoadingPrevious {
                HStack {
                  Spacer()
                  ProgressView()
                  Spacer()
                }
                .listRowSeparator(.hidden)
              } else if let message = viewModel.loadPreviousError {
                LoadMoreErrorView(message: message, retry: viewModel.retryLoadPrevious)
                  .listRowSeparator(.hidden)
              } else if viewModel.canLoadPrevious {
                Button(action: viewModel.loadPrevious) {
                  Label("加载更早回复", systemImage: "arrow.up")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("comments-load-previous")
              }

              if !viewModel.comments.contains(where: { $0.localVisibility != .hidden }) {
                EmptyStateView(title: "暂无可显示的楼中楼回复", systemImage: "bubble.left")
                  .frame(maxWidth: .infinity)
                  .listRowSeparator(.hidden)
              }

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
                .id(CommentsListItemID.comment(comment.id))
                .listRowBackground(
                  highlightedComment?.commentID == comment.id
                    ? appAccentColor.color.opacity(0.12)
                    : Color.clear
                )
                .overlay(alignment: .leading) {
                  if highlightedComment?.commentID == comment.id {
                    appAccentColor.color
                      .frame(width: 3)
                      .accessibilityHidden(true)
                  }
                }
                .animation(
                  reduceMotion ? nil : .easeInOut(duration: 0.2),
                  value: highlightedComment?.commentID
                )
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
            } header: {
              Text("共 \(viewModel.totalCount) 条回复")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            }
          }
          .listStyle(.plain)
          .task(id: viewModel.scrollTargetCommentID) {
            guard let commentID = viewModel.scrollTargetCommentID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(CommentsListItemID.comment(commentID), anchor: .center)
            highlightedComment = CommentHighlightToken(commentID: commentID)
            viewModel.consumeScrollTarget()
          }
          .task(id: viewModel.prependRestoreCommentID) {
            guard let commentID = viewModel.prependRestoreCommentID else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(CommentsListItemID.comment(commentID), anchor: .top)
            viewModel.consumePrependRestoreTarget()
          }
          .task(id: highlightedComment) {
            guard let token = highlightedComment else { return }
            do {
              try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
              return
            }
            guard !Task.isCancelled, highlightedComment == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
              highlightedComment = nil
            }
          }
          .refreshable { await viewModel.refresh() }
        }
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let message = viewModel.positionNotice {
        HStack(spacing: 10) {
          Image(systemName: "location.slash")
            .foregroundStyle(.secondary)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button(action: viewModel.dismissPositionNotice) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
      } else if let message = viewModel.refreshError {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button(action: viewModel.dismissRefreshError) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
      }
    }
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
    PostAuthorIdentityView(
      name: comment.authorName,
      username: comment.authorUsername,
      portraitURL: comment.authorPortraitURL,
      level: comment.authorLevel,
      isThreadAuthor: comment.isThreadAuthor,
      moderatorRole: comment.moderatorRole,
      date: comment.createdAt,
      ipLocation: comment.authorIPLocation,
      avatarSize: 32
    )
  }

  private var navigationTitle: String {
    if let floor = viewModel.parentPost?.floor, floor > 0 {
      return "\(floor) 楼的回复"
    }
    return "楼中楼"
  }
}

private enum CommentsListItemID: Hashable {
  case parentPost(Int64)
  case comment(Int64)
}

private struct CommentHighlightToken: Equatable {
  let commentID: Int64
  let generation = UUID()
}
