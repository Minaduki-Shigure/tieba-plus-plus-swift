import Combine
import Foundation

enum CommentsAnchor: Hashable, Sendable {
  case post(Int64)
  case comment(postID: Int64, commentID: Int64)
  case resolvingComment(Int64)

  var targetCommentID: Int64? {
    switch self {
    case .post:
      nil
    case .comment(_, let commentID), .resolvingComment(let commentID):
      commentID
    }
  }
}

private enum CommentPagePlacement: Equatable {
  case replacing
  case refreshing
  case before
  case after
}

struct CommentsPaginationSentinelID: Hashable, Sendable {
  let tailCommentID: Int64
  let commentCount: Int
  let page: Int
}

@MainActor
final class CommentsViewModel: ObservableObject {
  @Published private(set) var parentPost: CommentParentPostContext?
  @Published private(set) var thread: BrowseThread?
  @Published private(set) var comments: [BrowseComment] = []
  private(set) var displayableComments: [BrowseComment] = []
  private(set) var hasDisplayableComments = false
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
  @Published private(set) var agreementReadDescriptors: [ContentAgreementReadDescriptor] = []
  @Published private(set) var agreementDescriptorEpoch = 0
  @Published private(set) var agreementExplicitRefreshEpoch = 0

  let threadID: Int64
  let anchor: CommentsAnchor

  private let service: any BrowseService
  private var lowestLoadedPage = 0
  private var highestLoadedPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var lockedParentPostID: Int64?
  private var activeAnchor: CommentsAnchor
  private var commentIDs = Set<Int64>()
  private var commentsByID: [Int64: BrowseComment] = [:]
  private var acceptedDeletionTargets: [Int64: OwnedContentDeletionTarget] = [:]
  private var stagedAcceptedDeletionTargets: [Int64: OwnedContentDeletionTarget] = [:]
  private var indexedParentAgreementTarget: ContentAgreementTarget?
  private var agreementTargetsByCommentID: [Int64: ContentAgreementTarget] = [:]
  private var indexedAgreementContext: CommentAgreementIndexContext?
  private(set) var commentIndexFullRebuildCount = 0
  private(set) var commentIndexIncrementalUpdateCount = 0

  init(threadID: Int64, postID: Int64, service: any BrowseService) {
    self.threadID = threadID
    self.anchor = .post(postID)
    self.activeAnchor = .post(postID)
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
    self.activeAnchor = .comment(postID: postID, commentID: commentID)
    self.service = service
    self.lockedParentPostID = postID > 0 ? postID : nil
  }

  init(
    threadID: Int64,
    resolvingCommentID commentID: Int64,
    service: any BrowseService
  ) {
    self.threadID = threadID
    self.anchor = .resolvingComment(commentID)
    self.activeAnchor = .resolvingComment(commentID)
    self.service = service
    self.lockedParentPostID = nil
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func waitForCurrentLoad() async {
    await loadTask?.value
  }

  func reload() {
    reload(anchorOverride: nil)
  }

  func relocateAfterConfirmedReply(commentID: Int64) {
    guard
      commentID > 0,
      let parentPostID = lockedParentPostID,
      parentPostID > 0
    else { return }
    reload(anchorOverride: .comment(postID: parentPostID, commentID: commentID))
  }

  func verifyAndRelocateAcceptedReply(commentID: Int64) async -> BrowseComment? {
    guard
      commentID > 0,
      let parentPostID = lockedParentPostID,
      parentPostID > 0
    else { return nil }
    reload(anchorOverride: .comment(postID: parentPostID, commentID: commentID))
    await loadTask?.value
    guard state == .loaded else { return nil }
    return comments.first(where: { $0.id == commentID && $0.parentPostID == parentPostID })
  }

  private func reload(anchorOverride: CommentsAnchor?) {
    if let anchorOverride {
      activeAnchor = anchorOverride
    }
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
    resetCommentSnapshot()
    replaceAgreementDescriptors(with: [])
    state = .loading
    load(page: 1, placement: .replacing, anchorOverride: anchorOverride)
  }

  func loadMoreIfNeeded(current comment: BrowseComment) {
    guard comment.id == comments.last?.id else { return }
    loadMore()
  }

  var canLoadMore: Bool { hasMore && state == .loaded }

  func loadMore() {
    guard
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

  var parentAgreementTarget: ContentAgreementTarget? {
    indexedParentAgreementTarget
  }

  func agreementTarget(forCommentID commentID: Int64) -> ContentAgreementTarget? {
    agreementTargetsByCommentID[commentID]
  }

  func comment(withID commentID: Int64) -> BrowseComment? {
    commentsByID[commentID]
  }

  /// Only call for an accepted receipt or an authenticated accepted ledger record.
  /// Deferred records are bound to live forum/parent/author identity before projection.
  @discardableResult
  func stageAcceptedContentDeletion(
    _ target: OwnedContentDeletionTarget,
    allowsUnresolvedThreadIdentity: Bool = false
  ) -> Bool {
    guard
      state == .idle || state == .loading,
      target.kind == .subpost,
      target.threadID == threadID,
      let parentID = target.parentPostID,
      parentID > 0,
      lockedParentPostID.map({ $0 == parentID }) ?? true
    else { return false }
    if let existing = acceptedDeletionTargets[target.objectID]
      ?? stagedAcceptedDeletionTargets[target.objectID]
    {
      return existing == target
    }
    stagedAcceptedDeletionTargets[target.objectID] = target
    return true
  }

  @discardableResult
  func applyAcceptedContentDeletion(_ target: OwnedContentDeletionTarget) -> Bool {
    guard
      let thread, let parentPost,
      matchesDeletionContext(target, thread: thread, parentPost: parentPost)
    else { return false }
    if let existing = acceptedDeletionTargets[target.objectID] {
      return existing == target
    }
    if let comment = commentsByID[target.objectID], !matchesDeletionComment(target, comment) {
      return false
    }
    acceptedDeletionTargets[target.objectID] = target
    stagedAcceptedDeletionTargets.removeValue(forKey: target.objectID)
    if commentsByID[target.objectID] != nil {
      let retained = comments.filter { $0.id != target.objectID }
      replaceCommentSnapshot(thread: thread, parentPost: parentPost, comments: retained)
    }
    replaceAgreementDescriptors(
      with: agreementReadDescriptors, retainingOnlyIndexedTargets: true
    )
    if scrollTargetCommentID == target.objectID { scrollTargetCommentID = nil }
    if prependRestoreCommentID == target.objectID { prependRestoreCommentID = nil }
    return true
  }

  var paginationTail: BrowseComment? {
    hasMore ? comments.last : nil
  }

  var paginationSentinelID: CommentsPaginationSentinelID? {
    guard let paginationTail else { return nil }
    return CommentsPaginationSentinelID(
      tailCommentID: paginationTail.id,
      commentCount: comments.count,
      page: highestLoadedPage
    )
  }

  private func load(
    page: Int,
    placement: CommentPagePlacement,
    anchorOverride: CommentsAnchor? = nil
  ) {
    guard loadTask == nil else { return }
    let service = service
    let threadID = threadID
    let anchor = anchorOverride ?? activeAnchor
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
          if placement == .before || placement == .after, let lockedParentPostID {
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
        case .resolvingComment(let commentID):
          if placement == .before || placement == .after, let lockedParentPostID {
            response = try await service.comments(
              threadID: threadID,
              postID: lockedParentPostID,
              page: page
            )
          } else {
            response = try await service.comments(
              threadID: threadID,
              resolvingCommentID: commentID
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
        try validateThreadContext(response.thread, placement: placement)
        let rawPageComments = normalized(response.comments)
        let responseThread =
          (placement == .before || placement == .after)
          ? resolvedPaginationThread(response.thread) : response.thread
        let responseParent =
          (placement == .before || placement == .after)
          ? resolvedPaginationParentPost(response.parentPost) : response.parentPost
        let pageComments = try projectAcceptedDeletions(
          rawPageComments, thread: responseThread, parentPost: responseParent
        )
        let removedAcceptedComments = pageComments.count < rawPageComments.count
        var agreementContextChanged = false
        switch placement {
        case .replacing, .refreshing:
          if self.lockedParentPostID == nil {
            self.lockedParentPostID = response.parentPost.id
          }
          replaceCommentSnapshot(
            thread: response.thread,
            parentPost: response.parentPost,
            comments: pageComments
          )
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
          let newItems = unique(pageComments)
          let changedContext = resolvedPaginatedAgreementContextIfChanged(
            responseThread: response.thread,
            responseParentPost: response.parentPost
          )
          if newItems.isEmpty {
            if let changedContext {
              agreementContextChanged = true
              replacePaginatedSnapshotForContextChange(
                thread: changedContext.thread,
                parentPost: changedContext.parentPost,
                mergedComments: comments,
                commentsChanged: false
              )
            }
            // A stale page containing only accepted deletions is still a real page.
            // Preserve navigation so filtering cannot strand surviving earlier replies.
            if removedAcceptedComments {
              lowestLoadedPage = response.currentPage
              canLoadPrevious = response.hasPrevious && lowestLoadedPage > 1
            } else {
              canLoadPrevious = false
            }
          } else {
            if let changedContext {
              agreementContextChanged = true
              replacePaginatedSnapshotForContextChange(
                thread: changedContext.thread,
                parentPost: changedContext.parentPost,
                mergedComments: newItems + comments,
                commentsChanged: true
              )
            } else {
              indexCommentsIncrementally(newItems)
              displayableComments = newItems.filter { $0.localVisibility != .hidden }
                + displayableComments
              comments = newItems + comments
            }
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
          let newItems = unique(pageComments)
          let changedContext = resolvedPaginatedAgreementContextIfChanged(
            responseThread: response.thread,
            responseParentPost: response.parentPost
          )
          if newItems.isEmpty {
            if let changedContext {
              agreementContextChanged = true
              replacePaginatedSnapshotForContextChange(
                thread: changedContext.thread,
                parentPost: changedContext.parentPost,
                mergedComments: comments,
                commentsChanged: false
              )
            }
            if removedAcceptedComments {
              highestLoadedPage = response.currentPage
              hasMore = response.hasMore
            } else {
              hasMore = false
            }
          } else {
            if let changedContext {
              agreementContextChanged = true
              replacePaginatedSnapshotForContextChange(
                thread: changedContext.thread,
                parentPost: changedContext.parentPost,
                mergedComments: comments + newItems,
                commentsChanged: true
              )
            } else {
              indexCommentsIncrementally(newItems)
              displayableComments.append(
                contentsOf: newItems.filter { $0.localVisibility != .hidden }
              )
              comments.append(contentsOf: newItems)
            }
            highestLoadedPage = response.currentPage
            hasMore = response.hasMore
          }
          totalCount = max(max(totalCount, response.totalCount), comments.count)
        }
        if placement == .replacing {
          replaceAgreementDescriptors(
            with: response.agreementReadDescriptor.map { [$0] } ?? [],
            retainingOnlyIndexedTargets: !acceptedDeletionTargets.isEmpty
          )
        } else if placement == .refreshing {
          replaceAgreementDescriptors(
            with: response.agreementReadDescriptor.map { [$0] } ?? [],
            forceReadIfUnchanged: true,
            retainingOnlyIndexedTargets: !acceptedDeletionTargets.isEmpty
          )
        } else {
          upsertAgreementDescriptor(
            response.agreementReadDescriptor,
            pruningAll: agreementContextChanged || !acceptedDeletionTargets.isEmpty
          )
        }
        if placement == .replacing || placement == .refreshing,
          let commentID = anchor.targetCommentID
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

  private func matchesDeletionContext(
    _ target: OwnedContentDeletionTarget,
    thread: BrowseThread,
    parentPost: CommentParentPostContext
  ) -> Bool {
    target.kind == .subpost && target.threadID == threadID
      && thread.id == threadID && target.forumID == thread.forumID
      && target.forumName == normalizedForumName(thread.forumName)
      && target.parentPostID == parentPost.id && parentPost.threadID == threadID
      && target.floor == parentPost.floor
      && (target.threadOwnerID == nil || target.threadOwnerID == thread.authorID)
  }

  private func matchesDeletionComment(
    _ target: OwnedContentDeletionTarget, _ comment: BrowseComment
  ) -> Bool {
    comment.id == target.objectID && comment.threadID == target.threadID
      && comment.parentPostID == target.parentPostID && comment.authorID == target.authorID
  }

  private func projectAcceptedDeletions(
    _ items: [BrowseComment],
    thread: BrowseThread?,
    parentPost: CommentParentPostContext
  ) throws -> [BrowseComment] {
    // A child-only route cannot know its parent until the first response. Ledger
    // records belonging to other parents must neither filter nor block that page.
    stagedAcceptedDeletionTargets = stagedAcceptedDeletionTargets.filter {
      $0.value.parentPostID == parentPost.id
    }
    guard !acceptedDeletionTargets.isEmpty || !stagedAcceptedDeletionTargets.isEmpty else {
      return items
    }
    guard let thread, thread.forumID > 0, !normalizedForumName(thread.forumName).isEmpty,
      parentPost.floor > 0
    else {
      throw BrowseError.unavailable("贴吧返回的楼中楼身份不足，无法安全恢复已删除回复。")
    }
    // Do not activate a restored record solely because its numeric child ID appears.
    // Every response (including an already in-flight refresh) binds all target identity.
    var completed = Set<Int64>()
    for item in items {
      guard let target = stagedAcceptedDeletionTargets[item.id] else { continue }
      if matchesDeletionContext(target, thread: thread, parentPost: parentPost)
        && matchesDeletionComment(target, item)
      {
        acceptedDeletionTargets[item.id] = target
      }
      completed.insert(item.id)
    }
    for (id, target) in stagedAcceptedDeletionTargets
    where
      !matchesDeletionContext(target, thread: thread, parentPost: parentPost)
    {
      completed.insert(id)
    }
    for id in completed { stagedAcceptedDeletionTargets.removeValue(forKey: id) }
    return items.filter { item in
      guard let target = acceptedDeletionTargets[item.id] else { return true }
      return
        !(matchesDeletionContext(target, thread: thread, parentPost: parentPost)
        && matchesDeletionComment(target, item))
    }
  }

  private func unique(_ newItems: [BrowseComment]) -> [BrowseComment] {
    var newIDs = Set<Int64>()
    newIDs.reserveCapacity(newItems.count)
    return newItems.filter {
      !commentIDs.contains($0.id) && newIDs.insert($0.id).inserted
    }
  }

  private func validateThreadContext(
    _ responseThread: BrowseThread?,
    placement: CommentPagePlacement
  ) throws {
    guard let responseThread else { return }
    guard responseThread.id == threadID else {
      throw BrowseError.unavailable("贴吧返回的楼中楼主题归属异常，未显示该响应。")
    }
    if placement == .before || placement == .after {
      guard let thread else {
        throw BrowseError.unavailable("楼中楼分页缺少已锁定的主题归属，未合并该响应。")
      }
      let forumConflicts = thread.forumID > 0 && responseThread.forumID > 0
        && thread.forumID != responseThread.forumID
      let firstPostConflicts = thread.firstPostID > 0 && responseThread.firstPostID > 0
        && thread.firstPostID != responseThread.firstPostID
      guard !forumConflicts, !firstPostConflicts else {
        throw BrowseError.unavailable("贴吧返回的楼中楼主题上下文发生冲突，未合并该响应。")
      }
    }
  }

  private func replaceAgreementDescriptors(
    with descriptors: [ContentAgreementReadDescriptor],
    forceReadIfUnchanged: Bool = false,
    retainingOnlyIndexedTargets: Bool = false
  ) {
    let indexedTargets: Set<ContentAgreementTarget>? = retainingOnlyIndexedTargets
      ? Set(agreementTargetsByCommentID.values).union(
        indexedParentAgreementTarget.map { [$0] } ?? []
      )
      : nil
    var normalized: [ContentAgreementReadDescriptor] = []
    normalized.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      let retainedDescriptor: ContentAgreementReadDescriptor
      if let indexedTargets {
        guard
          let candidate = ContentAgreementReadDescriptor(
            request: descriptor.request,
            expectedTargets: descriptor.expectedTargets.intersection(indexedTargets)
          )
        else { continue }
        retainedDescriptor = candidate
      } else {
        retainedDescriptor = descriptor
      }
      if let index = normalized.firstIndex(where: { $0.request == retainedDescriptor.request }) {
        normalized[index] = retainedDescriptor
      } else {
        normalized.append(retainedDescriptor)
      }
    }
    guard normalized != agreementReadDescriptors else {
      if forceReadIfUnchanged, !normalized.isEmpty {
        agreementExplicitRefreshEpoch &+= 1
      }
      return
    }
    agreementReadDescriptors = normalized
    agreementDescriptorEpoch &+= 1
  }

  private func upsertAgreementDescriptor(
    _ descriptor: ContentAgreementReadDescriptor?,
    pruningAll: Bool = false
  ) {
    guard descriptor != nil || pruningAll else { return }
    var descriptors = agreementReadDescriptors
    if let descriptor {
      if let index = descriptors.firstIndex(where: { $0.request == descriptor.request }) {
        descriptors[index] = descriptor
      } else {
        descriptors.append(descriptor)
      }
    }
    replaceAgreementDescriptors(
      with: descriptors,
      retainingOnlyIndexedTargets: pruningAll
    )
  }

  private func resetCommentSnapshot() {
    if hasDisplayableComments {
      hasDisplayableComments = false
    }
    commentIDs.removeAll(keepingCapacity: true)
    commentsByID.removeAll(keepingCapacity: true)
    indexedParentAgreementTarget = nil
    agreementTargetsByCommentID.removeAll(keepingCapacity: true)
    indexedAgreementContext = nil
    parentPost = nil
    thread = nil
    comments = []
    displayableComments = []
  }

  private func replaceCommentSnapshot(
    thread: BrowseThread?,
    parentPost: CommentParentPostContext,
    comments: [BrowseComment]
  ) {
    rebuildCommentIndexes(thread: thread, parentPost: parentPost, comments: comments)
    self.thread = thread
    self.parentPost = parentPost
    self.comments = comments
  }

  private func resolvedPaginatedAgreementContextIfChanged(
    responseThread: BrowseThread?,
    responseParentPost: CommentParentPostContext
  ) -> (thread: BrowseThread?, parentPost: CommentParentPostContext)? {
    let resolvedThread = resolvedPaginationThread(responseThread)
    let resolvedParentPost = resolvedPaginationParentPost(responseParentPost)
    guard
      agreementContext(thread: resolvedThread, parentPost: resolvedParentPost)
        != indexedAgreementContext
    else { return nil }
    return (thread: resolvedThread, parentPost: resolvedParentPost)
  }

  private func replacePaginatedSnapshotForContextChange(
    thread: BrowseThread?,
    parentPost: CommentParentPostContext,
    mergedComments: [BrowseComment],
    commentsChanged: Bool
  ) {
    rebuildCommentIndexes(
      thread: thread,
      parentPost: parentPost,
      comments: mergedComments
    )
    self.thread = thread
    self.parentPost = parentPost
    if commentsChanged {
      comments = mergedComments
    }
  }

  private func resolvedPaginationThread(_ responseThread: BrowseThread?) -> BrowseThread? {
    guard let responseThread else { return thread }
    guard let thread else { return responseThread }
    let resolvedForumID = responseThread.forumID > 0
      ? responseThread.forumID
      : thread.forumID
    let resolvedForumName = normalizedForumName(responseThread.forumName).isEmpty
      ? thread.forumName
      : responseThread.forumName
    let resolvedFirstPostID = responseThread.firstPostID > 0
      ? responseThread.firstPostID
      : thread.firstPostID
    guard
      resolvedForumID != responseThread.forumID
        || resolvedForumName != responseThread.forumName
        || resolvedFirstPostID != responseThread.firstPostID
    else { return responseThread }
    return BrowseThread(
      id: responseThread.id,
      forumID: resolvedForumID,
      forumName: resolvedForumName,
      title: responseThread.title,
      excerpt: responseThread.excerpt,
      authorName: responseThread.authorName,
      replyCount: responseThread.replyCount,
      viewCount: responseThread.viewCount,
      createdAt: responseThread.createdAt,
      lastReplyAt: responseThread.lastReplyAt,
      contents: responseThread.contents,
      authorID: responseThread.authorID,
      authorUsername: responseThread.authorUsername,
      authorAvatarURL: responseThread.authorAvatarURL,
      firstPostID: resolvedFirstPostID,
      contentPostID: responseThread.contentPostID,
      shareCount: responseThread.shareCount,
      agreeCount: responseThread.agreeCount,
      disagreeCount: responseThread.disagreeCount,
      kind: responseThread.kind,
      tabID: responseThread.tabID,
      isPinned: responseThread.isPinned,
      isFeatured: responseThread.isFeatured,
      isShared: responseThread.isShared,
      isServerHidden: responseThread.isServerHidden,
      isLive: responseThread.isLive,
      localVisibility: responseThread.localVisibility
    )
  }

  private func resolvedPaginationParentPost(
    _ responseParentPost: CommentParentPostContext
  ) -> CommentParentPostContext {
    guard
      let parentPost,
      parentPost.id == responseParentPost.id,
      parentPost.threadID == responseParentPost.threadID,
      parentPost.floor > 0,
      responseParentPost.floor <= 0
    else { return responseParentPost }
    return parentPost
  }

  private func normalizedForumName(_ forumName: String) -> String {
    forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private func rebuildCommentIndexes(
    thread: BrowseThread?,
    parentPost: CommentParentPostContext,
    comments: [BrowseComment]
  ) {
    commentIndexFullRebuildCount += 1
    indexedAgreementContext = agreementContext(thread: thread, parentPost: parentPost)
    indexedParentAgreementTarget = thread.flatMap { thread in
      ContentAgreementTarget(thread: thread, parentPost: parentPost)
    }
    var ids = Set<Int64>()
    var lookup: [Int64: BrowseComment] = [:]
    var targets: [Int64: ContentAgreementTarget] = [:]
    var displayable: [BrowseComment] = []
    ids.reserveCapacity(comments.count)
    lookup.reserveCapacity(comments.count)
    targets.reserveCapacity(comments.count)
    displayable.reserveCapacity(comments.count)
    var containsDisplayableComment = false
    for comment in comments {
      ids.insert(comment.id)
      lookup[comment.id] = comment
      if comment.localVisibility != .hidden {
        displayable.append(comment)
        containsDisplayableComment = true
      }
      if
        let thread,
        let target = ContentAgreementTarget(
          thread: thread,
          parentPostID: parentPost.id,
          comment: comment
        )
      {
        targets[comment.id] = target
      }
    }
    commentIDs = ids
    commentsByID = lookup
    displayableComments = displayable
    if hasDisplayableComments != containsDisplayableComment {
      hasDisplayableComments = containsDisplayableComment
    }
    agreementTargetsByCommentID = targets
  }

  private func indexCommentsIncrementally(_ newComments: [BrowseComment]) {
    guard !newComments.isEmpty else { return }
    commentIndexIncrementalUpdateCount += 1
    let indexedThread = thread
    let indexedParentPostID = parentPost?.id
    var discoveredDisplayableComment = false
    for comment in newComments {
      commentIDs.insert(comment.id)
      commentsByID[comment.id] = comment
      discoveredDisplayableComment =
        discoveredDisplayableComment
        || comment.localVisibility != .hidden
      if
        let indexedThread,
        let indexedParentPostID,
        let target = ContentAgreementTarget(
          thread: indexedThread,
          parentPostID: indexedParentPostID,
          comment: comment
        )
      {
        agreementTargetsByCommentID[comment.id] = target
      }
    }
    if !hasDisplayableComments, discoveredDisplayableComment {
      hasDisplayableComments = true
    }
  }

  private func agreementContext(
    thread: BrowseThread?,
    parentPost: CommentParentPostContext?
  ) -> CommentAgreementIndexContext? {
    guard let thread, let parentPost else { return nil }
    return CommentAgreementIndexContext(thread: thread, parentPost: parentPost)
  }
}

private struct CommentAgreementIndexContext: Equatable {
  let threadID: Int64
  let forumID: Int64
  let forumName: String
  let firstPostID: Int64
  let parentPostID: Int64
  let parentThreadID: Int64
  let parentFloor: Int

  init(thread: BrowseThread, parentPost: CommentParentPostContext) {
    threadID = thread.id
    forumID = thread.forumID
    forumName = thread.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    firstPostID = thread.firstPostID
    parentPostID = parentPost.id
    parentThreadID = parentPost.threadID
    parentFloor = parentPost.floor
  }
}
