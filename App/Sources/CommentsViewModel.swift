import Combine
import Foundation

enum CommentsAnchor: Hashable, Sendable {
  case post(Int64)
  case comment(postID: Int64, commentID: Int64)
}

private enum CommentPagePlacement: Equatable {
  case replacing
  case refreshing
  case before
  case after
}

@MainActor
final class CommentsViewModel: ObservableObject {
  @Published private(set) var parentPost: CommentParentPostContext?
  @Published private(set) var comments: [BrowseComment] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var isLoadingPrevious = false
  @Published private(set) var isRefreshing = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var loadPreviousError: String?
  @Published private(set) var refreshError: String?
  @Published private(set) var scrollTargetCommentID: Int64?
  @Published private(set) var prependRestoreCommentID: Int64?
  @Published private(set) var positionNotice: String?
  @Published private(set) var totalCount = 0
  @Published private(set) var canLoadPrevious = false

  let threadID: Int64
  let anchor: CommentsAnchor

  private let service: any BrowseService
  private var lowestLoadedPage = 0
  private var highestLoadedPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var lockedParentPostID: Int64?

  init(threadID: Int64, postID: Int64, service: any BrowseService) {
    self.threadID = threadID
    self.anchor = .post(postID)
    self.service = service
    self.lockedParentPostID = postID > 0 ? postID : nil
  }

  init(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    service: any BrowseService
  ) {
    self.threadID = threadID
    self.anchor = .comment(postID: postID, commentID: commentID)
    self.service = service
    self.lockedParentPostID = postID > 0 ? postID : nil
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    lowestLoadedPage = 0
    highestLoadedPage = 0
    hasMore = true
    canLoadPrevious = false
    isLoadingMore = false
    isLoadingPrevious = false
    isRefreshing = false
    loadMoreError = nil
    loadPreviousError = nil
    refreshError = nil
    scrollTargetCommentID = nil
    prependRestoreCommentID = nil
    positionNotice = nil
    totalCount = 0
    parentPost = nil
    comments = []
    state = .loading
    load(page: 1, placement: .replacing)
  }

  func loadMoreIfNeeded(current comment: BrowseComment) {
    guard
      comment.id == comments.last?.id,
      hasMore,
      !isLoadingMore,
      !isLoadingPrevious,
      !isRefreshing,
      loadMoreError == nil,
      state == .loaded
    else {
      return
    }
    load(page: highestLoadedPage + 1, placement: .after)
  }

  func loadPrevious() {
    guard
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isLoadingPrevious,
      !isLoadingMore,
      !isRefreshing,
      loadPreviousError == nil,
      state == .loaded
    else { return }
    load(page: lowestLoadedPage - 1, placement: .before)
  }

  func retryLoadMore() {
    guard
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      !isLoadingPrevious,
      !isRefreshing,
      state == .loaded
    else { return }
    load(page: highestLoadedPage + 1, placement: .after)
  }

  func retryLoadPrevious() {
    guard
      loadPreviousError != nil,
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isLoadingPrevious,
      !isLoadingMore,
      !isRefreshing,
      state == .loaded
    else { return }
    load(page: lowestLoadedPage - 1, placement: .before)
  }

  func refresh() async {
    guard state == .loaded, !isLoadingMore, !isLoadingPrevious, !isRefreshing else { return }
    invalidateCurrentLoad()
    loadMoreError = nil
    loadPreviousError = nil
    refreshError = nil
    scrollTargetCommentID = nil
    prependRestoreCommentID = nil
    positionNotice = nil
    load(page: 1, placement: .refreshing)
    await loadTask?.value
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    isLoadingPrevious = false
    isRefreshing = false
    if state == .loading {
      state = comments.isEmpty ? .idle : .loaded
    }
  }

  func consumeScrollTarget() {
    scrollTargetCommentID = nil
  }

  func consumePrependRestoreTarget() {
    prependRestoreCommentID = nil
  }

  func dismissPositionNotice() {
    positionNotice = nil
  }

  func dismissRefreshError() {
    refreshError = nil
  }

  private func load(page: Int, placement: CommentPagePlacement) {
    guard loadTask == nil else { return }
    let service = service
    let threadID = threadID
    let anchor = anchor
    let lockedParentPostID = lockedParentPostID
    loadGeneration &+= 1
    let generation = loadGeneration
    switch placement {
    case .replacing:
      break
    case .refreshing:
      isRefreshing = true
    case .before:
      loadPreviousError = nil
      isLoadingPrevious = true
    case .after:
      loadMoreError = nil
      isLoadingMore = true
    }
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          isLoadingPrevious = false
          isRefreshing = false
          loadTask = nil
        }
      }
      do {
        let response: CommentPageData
        switch anchor {
        case .post(let postID):
          response = try await service.comments(
            threadID: threadID,
            postID: postID,
            page: page
          )
        case .comment(let postID, let commentID):
          if (placement == .before || placement == .after), let lockedParentPostID {
            response = try await service.comments(
              threadID: threadID,
              postID: lockedParentPostID,
              page: page
            )
          } else {
            response = try await service.comments(
              threadID: threadID,
              postID: postID,
              aroundCommentID: commentID,
              page: page
            )
          }
        }
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        guard
          response.parentPost.id > 0,
          response.parentPost.threadID == threadID,
          lockedParentPostID.map({ $0 == response.parentPost.id }) ?? true
        else {
          throw BrowseError.unavailable("贴吧返回的楼中楼归属异常，未显示该响应。")
        }
        let pageComments = normalized(response.comments)
        switch placement {
        case .replacing, .refreshing:
          if self.lockedParentPostID == nil {
            self.lockedParentPostID = response.parentPost.id
          }
          parentPost = response.parentPost
          comments = pageComments
          totalCount = max(response.totalCount, comments.count)
          let resolvedPage = max(response.currentPage, 1)
          lowestLoadedPage = resolvedPage
          highestLoadedPage = resolvedPage
          canLoadPrevious = response.hasPrevious && resolvedPage > 1
          hasMore = response.hasMore
        case .before:
          guard parentPost?.id == response.parentPost.id else {
            throw BrowseError.unavailable("贴吧返回的楼中楼归属异常，未合并该页。")
          }
          guard response.currentPage > 0, response.currentPage < lowestLoadedPage else {
            canLoadPrevious = false
            return
          }
          let firstVisibleID = comments.first(where: {
            $0.localVisibility != .hidden
          })?.id
          let newItems = unique(pageComments, excluding: comments)
          if newItems.isEmpty {
            canLoadPrevious = false
          } else {
            comments = newItems + comments
            lowestLoadedPage = response.currentPage
            canLoadPrevious = response.hasPrevious && lowestLoadedPage > 1
            prependRestoreCommentID = firstVisibleID
          }
          totalCount = max(max(totalCount, response.totalCount), comments.count)
        case .after:
          guard parentPost?.id == response.parentPost.id else {
            throw BrowseError.unavailable("贴吧返回的楼中楼归属异常，未合并该页。")
          }
          guard response.currentPage > highestLoadedPage else {
            hasMore = false
            return
          }
          let newItems = unique(pageComments, excluding: comments)
          if newItems.isEmpty {
            hasMore = false
          } else {
            comments.append(contentsOf: newItems)
            highestLoadedPage = response.currentPage
            hasMore = response.hasMore
          }
          totalCount = max(max(totalCount, response.totalCount), comments.count)
        }
        if (placement == .replacing || placement == .refreshing),
          case .comment(_, let commentID) = anchor
        {
          if let target = comments.first(where: { $0.id == commentID }) {
            if target.localVisibility == .hidden {
              positionNotice = "目标回复已按本地规则隐藏。"
            } else {
              scrollTargetCommentID = commentID
            }
          } else {
            positionNotice = "未能在返回页面中定位目标回复。"
          }
        }
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        switch placement {
        case .replacing:
          state = .failed(error.localizedDescription)
        case .refreshing:
          refreshError = error.localizedDescription
        case .before:
          loadPreviousError = error.localizedDescription
        case .after:
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func normalized(_ items: [BrowseComment]) -> [BrowseComment] {
    var seen = Set<Int64>()
    return items.filter { $0.id > 0 && seen.insert($0.id).inserted }
  }

  private func unique(
    _ newItems: [BrowseComment],
    excluding existing: [BrowseComment]
  ) -> [BrowseComment] {
    var seen = Set(existing.map(\.id))
    return newItems.filter { seen.insert($0.id).inserted }
  }
}
