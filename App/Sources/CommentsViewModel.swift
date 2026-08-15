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

@MainActor
final class CommentsViewModel: ObservableObject {
  @Published private(set) var parentPost: CommentParentPostContext?
  @Published private(set) var thread: BrowseThread?
  @Published private(set) var comments: [BrowseComment] = []
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
  private var indexedParentAgreementTarget: ContentAgreementTarget?
  private var agreementTargetsByCommentID: [Int64: ContentAgreementTarget] = [:]
  private var commentsByID: [Int64: BrowseComment] = [:]
  private var contentRenderPlansByCommentID: [Int64: BrowseContentRenderPlan] = [:]
  private var commentRenderRevisionsByID: [Int64: UInt64] = [:]
  private var indexedParentContentRenderPlan: BrowseContentRenderPlan?
  private var indexedAgreementContext: CommentAgreementIndexContext?
  private(set) var commentIndexFullRebuildCount = 0
  private(set) var commentIndexIncrementalUpdateCount = 0
  private var nextCommentRenderRevision: UInt64 = 0

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

  var parentAgreementTarget: ContentAgreementTarget? {
    indexedParentAgreementTarget
  }

  func agreementTarget(forCommentID commentID: Int64) -> ContentAgreementTarget? {
    agreementTargetsByCommentID[commentID]
  }

  var parentContentRenderPlan: BrowseContentRenderPlan? {
    indexedParentContentRenderPlan
      ?? parentPost.map { BrowseContentRenderPlan(contents: $0.contents) }
  }

  func contentRenderPlan(for comment: BrowseComment) -> BrowseContentRenderPlan {
    contentRenderPlansByCommentID[comment.id]
      ?? BrowseContentRenderPlan(contents: comment.contents)
  }

  func renderRevision(for comment: BrowseComment) -> UInt64 {
    commentRenderRevisionsByID[comment.id] ?? 0
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
        case .resolvingComment(let commentID):
          if (placement == .before || placement == .after), let lockedParentPostID {
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
        let pageComments = normalized(response.comments)
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
            canLoadPrevious = false
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
            hasMore = false
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
              comments.append(contentsOf: newItems)
            }
            highestLoadedPage = response.currentPage
            hasMore = response.hasMore
          }
          totalCount = max(max(totalCount, response.totalCount), comments.count)
        }
        if placement == .replacing {
          replaceAgreementDescriptors(
            with: response.agreementReadDescriptor.map { [$0] } ?? []
          )
        } else if placement == .refreshing {
          replaceAgreementDescriptors(
            with: response.agreementReadDescriptor.map { [$0] } ?? [],
            forceReadIfUnchanged: true
          )
        } else {
          upsertAgreementDescriptor(
            response.agreementReadDescriptor,
            pruningAll: agreementContextChanged
          )
        }
        if (placement == .replacing || placement == .refreshing),
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
    indexedParentAgreementTarget = nil
    agreementTargetsByCommentID.removeAll(keepingCapacity: true)
    commentsByID.removeAll(keepingCapacity: true)
    contentRenderPlansByCommentID.removeAll(keepingCapacity: true)
    commentRenderRevisionsByID.removeAll(keepingCapacity: true)
    indexedParentContentRenderPlan = nil
    indexedAgreementContext = nil
    parentPost = nil
    thread = nil
    comments = []
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
    let previousCommentsByID = commentsByID
    let previousRenderPlansByID = contentRenderPlansByCommentID
    let previousRenderRevisionsByID = commentRenderRevisionsByID
    indexedAgreementContext = agreementContext(thread: thread, parentPost: parentPost)
    indexedParentAgreementTarget = thread.flatMap { thread in
      ContentAgreementTarget(thread: thread, parentPost: parentPost)
    }
    indexedParentContentRenderPlan = BrowseContentRenderPlan(contents: parentPost.contents)
    var ids = Set<Int64>()
    var targets: [Int64: ContentAgreementTarget] = [:]
    var lookup: [Int64: BrowseComment] = [:]
    var renderPlans: [Int64: BrowseContentRenderPlan] = [:]
    var renderRevisions: [Int64: UInt64] = [:]
    ids.reserveCapacity(comments.count)
    targets.reserveCapacity(comments.count)
    lookup.reserveCapacity(comments.count)
    renderPlans.reserveCapacity(comments.count)
    renderRevisions.reserveCapacity(comments.count)
    var containsDisplayableComment = false
    for comment in comments {
      ids.insert(comment.id)
      lookup[comment.id] = comment
      if
        previousCommentsByID[comment.id] == comment,
        let previousPlan = previousRenderPlansByID[comment.id],
        let previousRevision = previousRenderRevisionsByID[comment.id]
      {
        renderPlans[comment.id] = previousPlan
        renderRevisions[comment.id] = previousRevision
      } else {
        renderPlans[comment.id] = BrowseContentRenderPlan(contents: comment.contents)
        renderRevisions[comment.id] = allocateCommentRenderRevision()
      }
      containsDisplayableComment = containsDisplayableComment
        || comment.localVisibility != .hidden
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
    if hasDisplayableComments != containsDisplayableComment {
      hasDisplayableComments = containsDisplayableComment
    }
    agreementTargetsByCommentID = targets
    commentsByID = lookup
    contentRenderPlansByCommentID = renderPlans
    commentRenderRevisionsByID = renderRevisions
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
      contentRenderPlansByCommentID[comment.id] = BrowseContentRenderPlan(
        contents: comment.contents
      )
      commentRenderRevisionsByID[comment.id] = allocateCommentRenderRevision()
      discoveredDisplayableComment = discoveredDisplayableComment
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

  private func allocateCommentRenderRevision() -> UInt64 {
    nextCommentRenderRevision &+= 1
    if nextCommentRenderRevision == 0 {
      nextCommentRenderRevision = 1
    }
    return nextCommentRenderRevision
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
