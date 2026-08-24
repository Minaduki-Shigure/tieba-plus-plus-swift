import Combine
import Foundation

struct ThreadScrollTargetDescriptor: Equatable, Sendable {
  let order: Int
  let localVisibility: LocalContentVisibility
  let tracksPrependAnchor: Bool
}

enum ThreadInitialFocus: Equatable, Sendable {
  case firstReply
}

@MainActor
final class ThreadViewModel: ObservableObject {
  @Published private(set) var thread: BrowseThread
  @Published private(set) var originThread: BrowseThread?
  @Published private(set) var poll: BrowsePoll?
  @Published private(set) var firstPost: BrowsePost?
  @Published private(set) var posts: [BrowsePost] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isCheckingLatestReplies = false
  @Published private(set) var latestRepliesError: String?
  @Published private(set) var canLoadPrevious = false
  @Published private(set) var isLoadingPrevious = false
  @Published private(set) var loadPreviousError: String?
  @Published private(set) var prependRestorePostID: Int64?
  @Published private(set) var prependRestoreSequence = 0
  @Published private(set) var isRestoringPrependPosition = false
  @Published private(set) var options = ThreadBrowseOptions()
  @Published private(set) var currentPage = 0
  @Published private(set) var totalPages = 0
  @Published private(set) var isJumping = false
  @Published private(set) var jumpError: String?
  @Published private(set) var positionNotice: String?
  @Published private(set) var scrollTargetPostID: Int64?
  @Published private(set) var agreementReadDescriptors: [ContentAgreementReadDescriptor] = []
  @Published private(set) var agreementDescriptorEpoch = 0

  private let service: any BrowseService
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var initialLocation: ThreadPostLocation?
  private var pendingInitialFocus: ThreadInitialFocus?
  private var failedJumpPage: Int?
  private var lowestLoadedPage = 0
  private var previousLoadAnchorPostID: Int64?
  private var nextPagePostID: Int64?
  private var descendingFallbackPage: Int?
  private var agreementTargetsByPostID: [Int64: ContentAgreementTarget] = [:]
  private var postsByID: [Int64: BrowsePost] = [:]
  private(set) var scrollTargetsByPostID: [Int64: ThreadScrollTargetDescriptor] = [:]
  private(set) var resolvedThreadAuthorAvatarURL: URL?
  private(set) var firstDisplayableReplyPostID: Int64?
  private(set) var firstVisibleReplyPostID: Int64?
  private var nextScrollTargetOrder = 0
  private(set) var fullPostIndexRebuildCount = 0
  private(set) var incrementallyIndexedPostCount = 0

  init(
    thread: BrowseThread,
    service: any BrowseService,
    options: ThreadBrowseOptions = ThreadBrowseOptions(),
    initialLocation: ThreadPostLocation? = nil,
    initialFocus: ThreadInitialFocus? = nil
  ) {
    self.thread = thread
    self.originThread = nil
    self.poll = nil
    self.firstPost = nil
    self.service = service
    self.options = options
    self.initialLocation = options.sort == .hot ? nil : initialLocation
    self.pendingInitialFocus = initialFocus
    self.resolvedThreadAuthorAvatarURL = ThreadAuthorAvatarResolver.resolve(
      thread: thread,
      firstPost: nil,
      posts: []
    )
    self.firstDisplayableReplyPostID = nil
    self.firstVisibleReplyPostID = nil
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload(location: initialLocation)
  }

  func waitForCurrentLoad() async {
    await loadTask?.value
  }

  func reload() {
    reload(location: initialLocation)
  }

  func relocateAfterConfirmedReply(postID: Int64) {
    guard postID > 0 else { return }
    prepareForReplyRelocation()
    reload(location: .postID(postID))
  }

  func verifyAndRelocateAcceptedReply(postID: Int64) async -> BrowsePost? {
    guard postID > 0 else { return nil }
    prepareForReplyRelocation()
    reload(location: .postID(postID))
    await loadTask?.value
    guard state == .loaded else { return nil }
    return post(withID: postID)
  }

  func verifyAcceptedSubpost(
    parentPostID: Int64,
    subpostID: Int64
  ) async throws -> BrowseComment? {
    guard
      parentPostID > 0,
      subpostID > 0,
      parentPostID != subpostID
    else { return nil }
    let response = try await service.comments(
      threadID: thread.id,
      postID: parentPostID,
      aroundCommentID: subpostID,
      page: 1
    )
    guard
      response.parentPost.id == parentPostID,
      response.parentPost.threadID == thread.id
    else { return nil }
    if let responseThread = response.thread {
      let forumConflicts = thread.forumID > 0 && responseThread.forumID > 0
        && thread.forumID != responseThread.forumID
      guard responseThread.id == thread.id, !forumConflicts else { return nil }
    }
    let matches = response.comments.filter {
      $0.id == subpostID
        && $0.threadID == thread.id
        && $0.parentPostID == parentPostID
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  private func prepareForReplyRelocation() {
    if options.sort == .hot {
      options.sort = .ascending
    }
    if options.onlyThreadAuthor {
      options.onlyThreadAuthor = false
    }
    initialLocation = nil
  }

  private func reload(location: ThreadPostLocation?) {
    invalidateCurrentLoad()
    currentPage = 0
    totalPages = 0
    hasMore = true
    lowestLoadedPage = 0
    canLoadPrevious = false
    isLoadingMore = false
    isLoadingPrevious = false
    loadMoreError = nil
    isCheckingLatestReplies = false
    latestRepliesError = nil
    loadPreviousError = nil
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    jumpError = nil
    positionNotice = nil
    failedJumpPage = nil
    nextPagePostID = nil
    descendingFallbackPage = nil
    scrollTargetPostID = nil
    replaceAgreementDescriptors(with: [])
    replacePostSnapshot(firstPost: nil, posts: [])
    state = .loading
    load(page: 1, replacing: true, location: location, jumping: false)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func setSort(_ sort: ThreadPostSort) {
    guard options.sort != sort else { return }
    options.sort = sort
    if sort == .hot {
      initialLocation = nil
    }
    reload()
  }

  func setOnlyThreadAuthor(_ onlyThreadAuthor: Bool) {
    guard options.onlyThreadAuthor != onlyThreadAuthor else { return }
    options.onlyThreadAuthor = onlyThreadAuthor
    reload()
  }

  func prepareResume(options: ThreadBrowseOptions, postID: Int64?) {
    guard state == .idle else { return }
    self.options = options
    if options.sort != .hot, let postID, postID > 0 {
      initialLocation = .postID(postID)
    }
  }

  func jump(toPage page: Int) {
    guard !isCheckingLatestReplies else { return }
    guard page > 0, totalPages == 0 || page <= totalPages else {
      failedJumpPage = nil
      jumpError = totalPages > 0 ? "请输入 1 到 \(totalPages) 之间的页码。" : "页码必须大于 0。"
      return
    }
    invalidateCurrentLoad()
    isLoadingMore = false
    isLoadingPrevious = false
    loadMoreError = nil
    latestRepliesError = nil
    loadPreviousError = nil
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    jumpError = nil
    failedJumpPage = nil
    initialLocation = nil
    isJumping = true
    load(page: page, replacing: true, location: .pageNumber, jumping: true)
  }

  func retryJump() {
    guard let page = failedJumpPage, !isJumping else { return }
    jump(toPage: page)
  }

  var canRetryJump: Bool { failedJumpPage != nil }

  func dismissJumpError() {
    jumpError = nil
    failedJumpPage = nil
  }

  func dismissPositionNotice() {
    positionNotice = nil
  }

  func consumeScrollTarget() {
    scrollTargetPostID = nil
  }

  func consumePrependRestoreTarget() {
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    isLoadingPrevious = false
    isCheckingLatestReplies = false
    latestRepliesError = nil
    isJumping = false
    prependRestorePostID = nil
    isRestoringPrependPosition = false
    previousLoadAnchorPostID = nil
    if state == .loading {
      state = firstPost == nil && posts.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current post: BrowsePost) {
    guard post.id == posts.last?.id else { return }
    loadMoreIfNeeded()
  }

  func loadMoreIfNeeded() {
    guard
      hasMore,
      !isLoadingMore,
      !isCheckingLatestReplies,
      !isAdjustingPrependPosition,
      !isJumping,
      loadMoreError == nil,
      state == .loaded
    else {
      return
    }
    let request = nextLoadMoreRequest()
    load(
      page: request.page,
      replacing: false,
      location: request.location,
      jumping: false
    )
  }

  func retryLoadMore() {
    guard
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      !isCheckingLatestReplies,
      !isAdjustingPrependPosition,
      !isJumping,
      state == .loaded
    else { return }
    let request = nextLoadMoreRequest()
    load(
      page: request.page,
      replacing: false,
      location: request.location,
      jumping: false
    )
  }

  var canCheckLatestReplies: Bool {
    options.sort == .ascending
      && !hasMore
      && !posts.isEmpty
      && state == .loaded
      && loadTask == nil
      && !isLoadingMore
      && !isCheckingLatestReplies
      && !isAdjustingPrependPosition
      && !isJumping
      && loadMoreError == nil
  }

  func checkLatestReplies() {
    guard latestRepliesError == nil, canCheckLatestReplies else { return }
    startLatestRepliesCheck()
  }

  func retryLatestReplies() {
    guard latestRepliesError != nil, canCheckLatestReplies else { return }
    startLatestRepliesCheck()
  }

  private func startLatestRepliesCheck() {
    guard let tailPostID = posts.last?.id, tailPostID > 0 else { return }
    let threadID = thread.id
    let service = service
    let options = options
    loadGeneration &+= 1
    let generation = loadGeneration
    latestRepliesError = nil
    isCheckingLatestReplies = true
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isCheckingLatestReplies = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.posts(
          threadID: threadID,
          page: 1,
          pageSize: 15,
          options: options,
          location: .latestReplies(after: tailPostID)
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        guard !response.posts.isEmpty else { return }
        let normalized = try normalizedPostPage(
          response,
          threadID: threadID,
          deduplicatingReplies: true
        )
        try validateRetainedFirstPostIdentity(
          normalized.firstPost,
          responseThread: response.thread,
          replacing: false
        )
        let newReplies = uniqueValidPosts(normalized.replies, threadID: threadID)
        guard !newReplies.isEmpty else { return }

        let requiresFullRebuild = replaceThreadIfNeeded(response.thread)
        appendPostsToEnd(newReplies, requiresFullRebuild: requiresFullRebuild)
        upsertAgreementDescriptor(
          response.agreementReadDescriptor,
          pruningAll: requiresFullRebuild
        )
        currentPage = response.currentPage
        totalPages = response.totalPages
        hasMore = response.hasMore
        nextPagePostID = response.nextPagePostID
        descendingFallbackPage = nil
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        latestRepliesError = error.localizedDescription
      }
    }
  }

  func loadPrevious(anchorPostID: Int64? = nil) {
    guard
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isAdjustingPrependPosition,
      !isLoadingMore,
      !isCheckingLatestReplies,
      !isJumping,
      loadPreviousError == nil,
      state == .loaded,
      options.sort == .ascending
    else { return }
    previousLoadAnchorPostID = anchorPostID.flatMap { candidate in
      post(withID: candidate).flatMap { post in
        post.localVisibility == .hidden ? nil : post.id
      }
    }
    load(
      page: lowestLoadedPage - 1,
      replacing: false,
      location: .pageNumber,
      jumping: false,
      prepending: true
    )
  }

  func retryLoadPrevious() {
    guard
      loadPreviousError != nil,
      canLoadPrevious,
      lowestLoadedPage > 1,
      !isAdjustingPrependPosition,
      !isLoadingMore,
      !isCheckingLatestReplies,
      !isJumping,
      state == .loaded,
      options.sort == .ascending
    else { return }
    load(
      page: lowestLoadedPage - 1,
      replacing: false,
      location: .pageNumber,
      jumping: false,
      prepending: true
    )
  }

  var isAdjustingPrependPosition: Bool {
    isLoadingPrevious || isRestoringPrependPosition
  }

  private func load(
    page: Int,
    replacing: Bool,
    location: ThreadPostLocation?,
    jumping: Bool,
    prepending: Bool = false
  ) {
    let threadID = thread.id
    let service = service
    let options = options
    loadGeneration &+= 1
    let generation = loadGeneration
    if prepending {
      loadPreviousError = nil
      isLoadingPrevious = true
    } else if !replacing {
      loadMoreError = nil
      isLoadingMore = true
    }
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          isLoadingPrevious = false
          isJumping = false
          loadTask = nil
        }
      }
      do {
        var response = try await service.posts(
          threadID: threadID,
          page: page,
          pageSize: 30,
          options: options,
          location: location
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        var normalized = try normalizedPostPage(response, threadID: threadID)
        try validateRetainedFirstPostIdentity(
          normalized.firstPost,
          responseThread: response.thread,
          replacing: replacing
        )

        var resolvedScrollTarget: Int64?
        var didResolveInitialReplyFocus = false
        var effectiveLocation = location
        var didFallBackFromMissingPosition = false
        var didHideRequestedPosition = false
        if case .postID(let postID) = location {
          if let target = post(
            withID: postID,
            firstPost: normalized.firstPost,
            replies: normalized.replies
          ) {
            if target.localVisibility == .hidden {
              didHideRequestedPosition = true
            } else {
              resolvedScrollTarget = postID
            }
          } else {
            didFallBackFromMissingPosition = true
            let locationResponse = response
            do {
              response = try await service.posts(
                threadID: threadID,
                page: 1,
                pageSize: 30,
                options: options,
                location: nil
              )
              effectiveLocation = nil
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              response = locationResponse
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            normalized = try normalizedPostPage(response, threadID: threadID)
            try validateRetainedFirstPostIdentity(
              normalized.firstPost,
              responseThread: response.thread,
              replacing: replacing
            )
            resolvedScrollTarget = firstVisiblePost(
              firstPost: normalized.firstPost,
              replies: normalized.replies
            )?.id
          }
        } else if replacing && jumping {
          resolvedScrollTarget = normalized.replies.first(where: {
            $0.localVisibility != .hidden
          })?.id ?? normalized.firstPost.flatMap {
            $0.localVisibility == .hidden ? nil : $0.id
          }
        } else if replacing, pendingInitialFocus == .firstReply {
          didResolveInitialReplyFocus = true
          resolvedScrollTarget = normalized.replies.first(where: {
            $0.localVisibility != .hidden
          })?.id
        }

        if prepending {
          guard
            options.sort == .ascending,
            response.currentPage == page,
            page == lowestLoadedPage - 1
          else {
            throw BrowseError.unavailable("贴吧返回的上一页页码异常，未合并该响应。")
          }
          let newItems = uniqueValidPosts(normalized.replies, threadID: threadID)
          guard !newItems.isEmpty else {
            canLoadPrevious = false
            previousLoadAnchorPostID = nil
            state = .loaded
            return
          }
          let restorePostID = previousLoadAnchorPostID
          isRestoringPrependPosition = true
          let threadRequiresFullRebuild = replaceThreadIfNeeded(response.thread)
          if let responseOriginThread = response.originThread {
            replaceOriginThreadIfNeeded(responseOriginThread)
          }
          if let responsePoll = response.poll {
            replacePollIfNeeded(responsePoll)
          }
          replacePostSnapshot(
            firstPost: normalized.firstPost ?? firstPost,
            posts: newItems + posts
          )
          upsertAgreementDescriptor(
            response.agreementReadDescriptor,
            pruningAll: threadRequiresFullRebuild
          )
          lowestLoadedPage = response.currentPage
          totalPages = max(totalPages, response.totalPages)
          canLoadPrevious = response.hasPrevious && lowestLoadedPage > 1
          prependRestorePostID = restorePostID
          prependRestoreSequence &+= 1
          state = .loaded
          return
        }

        let previousPage = currentPage
        let requestedCursor: Int64?
        if case .pageCursor(let cursor) = effectiveLocation {
          requestedCursor = cursor
        } else {
          requestedCursor = nil
        }
        let appendedPosts = replacing
          ? []
          : uniqueValidPosts(normalized.replies, threadID: threadID)
        if replacing, jumping, effectiveLocation == .pageNumber, response.currentPage != page {
          throw BrowseError.unavailable("贴吧返回的跳转页码异常，未显示该响应。")
        }
        if !replacing {
          switch effectiveLocation {
          case .pageNumber:
            guard response.currentPage == page else {
              throw BrowseError.unavailable("贴吧返回的下一页页码异常，未合并该响应。")
            }
          case .pageCursor(let cursor):
            let didAdvanceCursorPage: Bool
            if options.sort == .ascending {
              didAdvanceCursorPage = response.currentPage > previousPage
                || (response.currentPage == previousPage && response.nextPagePostID != cursor)
            } else {
              didAdvanceCursorPage = response.currentPage != previousPage
                || response.nextPagePostID != cursor
            }
            guard didAdvanceCursorPage else {
              throw BrowseError.unavailable("贴吧返回的分页游标未前进，未合并该响应。")
            }
          case .postID(_), .latestReplies(after: _), nil:
            break
          }
        }
        let threadRequiresFullRebuild = replaceThreadIfNeeded(response.thread)
        var firstPostChanged = false
        if replacing {
          firstPostChanged = firstPost != normalized.firstPost
        } else if let responseFirstPost = normalized.firstPost {
          firstPostChanged = replaceFirstPostIfNeeded(responseFirstPost)
        }
        if replacing {
          replaceOriginThreadIfNeeded(response.originThread)
        } else if let responseOriginThread = response.originThread {
          replaceOriginThreadIfNeeded(responseOriginThread)
        }
        if replacing {
          replacePollIfNeeded(response.poll)
        } else if let responsePoll = response.poll {
          replacePollIfNeeded(responsePoll)
        }
        currentPage = response.currentPage
        totalPages = response.totalPages
        nextPagePostID = response.nextPagePostID
        updateDescendingFallbackPage(
          requestedPage: page,
          replacing: replacing,
          location: effectiveLocation,
          currentPage: response.currentPage,
          totalPages: response.totalPages
        )
        let addedPosts = !appendedPosts.isEmpty
        let exhaustedFallbackPage =
          !replacing && options.sort == .descending
          && effectiveLocation == .pageNumber && page == 1
        let noDescendingContinuation =
          options.sort == .descending && response.nextPagePostID == nil
          && descendingFallbackPage == nil
        let stalledDescendingPage =
          !replacing && options.sort == .descending && !addedPosts
        let canAdvancePastDuplicateAscendingPage =
          !replacing && options.sort == .ascending && !addedPosts && response.hasMore
          && (response.currentPage > previousPage
            || (response.nextPagePostID != nil && response.nextPagePostID != requestedCursor))
        let stalledAscendingPage =
          !replacing && options.sort == .ascending && !addedPosts
          && !canAdvancePastDuplicateAscendingPage
        let stalledHotPage =
          !replacing && options.sort == .hot && !addedPosts
        hasMore = response.hasMore
          && !exhaustedFallbackPage
          && !noDescendingContinuation
          && !stalledDescendingPage
          && !stalledAscendingPage
          && !stalledHotPage
        if replacing {
          let rebuilt = replacePostSnapshot(
            firstPost: normalized.firstPost,
            posts: normalized.replies
          )
          if threadRequiresFullRebuild, !rebuilt {
            rebuildPostIndexes()
          }
        } else if !appendedPosts.isEmpty {
          appendPostsToEnd(
            appendedPosts,
            requiresFullRebuild: threadRequiresFullRebuild || firstPostChanged
          )
        } else if threadRequiresFullRebuild || firstPostChanged {
          rebuildPostIndexes()
        }
        if replacing {
          replaceAgreementDescriptors(
            with: response.agreementReadDescriptor.map { [$0] } ?? []
          )
        } else {
          upsertAgreementDescriptor(
            response.agreementReadDescriptor,
            pruningAll: threadRequiresFullRebuild
          )
        }
        if replacing {
          lowestLoadedPage = max(response.currentPage, 1)
          canLoadPrevious = options.sort == .ascending
            && response.currentPage > 1
            && response.hasPrevious
          loadPreviousError = nil
          prependRestorePostID = nil
        }
        if replacing, let resolvedScrollTarget {
          scrollTargetPostID = resolvedScrollTarget
        }
        if replacing {
          if didHideRequestedPosition {
            positionNotice = "目标楼层已按本地规则隐藏。"
          } else if didFallBackFromMissingPosition {
            positionNotice = "上次阅读位置已失效或不符合当前筛选，已显示当前可用内容。"
          } else if didResolveInitialReplyFocus, resolvedScrollTarget == nil {
            positionNotice = "暂无可显示的回复。"
          } else {
            positionNotice = nil
          }
          initialLocation = nil
          pendingInitialFocus = nil
        }
        jumpError = nil
        failedJumpPage = nil
        state = .loaded
        if canAdvancePastDuplicateAscendingPage {
          let request = nextLoadMoreRequest()
          load(
            page: request.page,
            replacing: false,
            location: request.location,
            jumping: false
          )
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if prepending {
          loadPreviousError = error.localizedDescription
        } else if jumping {
          failedJumpPage = page
          jumpError = error.localizedDescription
          state = firstPost == nil && posts.isEmpty
            ? .failed(error.localizedDescription)
            : .loaded
        } else if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
    isCheckingLatestReplies = false
  }

  private func nextLoadMoreRequest() -> (page: Int, location: ThreadPostLocation) {
    if options.sort == .descending {
      if let nextPagePostID {
        return (
          page: max(totalPages - currentPage, 0),
          location: .pageCursor(nextPagePostID)
        )
      }
      return (
        page: descendingFallbackPage ?? max(totalPages - 1, 1),
        location: .pageNumber
      )
    }
    if options.sort == .ascending, let nextPagePostID {
      return (
        page: max(currentPage, 1) + 1,
        location: .pageCursor(nextPagePostID)
      )
    }
    return (page: max(currentPage, 1) + 1, location: .pageNumber)
  }

  private func updateDescendingFallbackPage(
    requestedPage: Int,
    replacing: Bool,
    location: ThreadPostLocation?,
    currentPage: Int,
    totalPages: Int
  ) {
    guard options.sort == .descending else {
      descendingFallbackPage = nil
      return
    }
    if replacing {
      switch location {
      case nil:
        descendingFallbackPage = totalPages > 1 ? totalPages - 1 : nil
      case .pageNumber:
        descendingFallbackPage = requestedPage > 1 ? requestedPage - 1 : nil
      case .postID(_), .pageCursor(_), .latestReplies(after: _):
        descendingFallbackPage = currentPage > 1 ? currentPage - 1 : nil
      }
    } else if location == .pageNumber {
      descendingFallbackPage = requestedPage > 1 ? requestedPage - 1 : nil
    } else if let page = descendingFallbackPage {
      descendingFallbackPage = page > 1 ? page - 1 : nil
    }
  }

  private struct AgreementThreadIdentity: Equatable {
    let threadID: Int64
    let firstPostID: Int64
    let forumID: Int64
    let forumName: String

    init(_ thread: BrowseThread) {
      threadID = thread.id
      firstPostID = thread.firstPostID
      forumID = thread.forumID
      forumName = thread.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
    }
  }

  private struct ThreadAvatarIdentity: Equatable {
    let threadID: Int64
    let authorID: Int64
    let authorAvatarURL: URL?
    let localVisibility: LocalContentVisibility

    init(_ thread: BrowseThread) {
      threadID = thread.id
      authorID = thread.authorID
      authorAvatarURL = thread.authorAvatarURL
      localVisibility = thread.localVisibility
    }
  }

  @discardableResult
  private func replaceThreadIfNeeded(_ replacement: BrowseThread) -> Bool {
    let agreementIdentityChanged = AgreementThreadIdentity(thread)
      != AgreementThreadIdentity(replacement)
    let avatarIdentityChanged = ThreadAvatarIdentity(thread)
      != ThreadAvatarIdentity(replacement)
    if thread != replacement {
      thread = replacement
      if avatarIdentityChanged {
        refreshResolvedThreadAuthorAvatarURL()
      }
    }
    return agreementIdentityChanged
  }

  @discardableResult
  private func replaceFirstPostIfNeeded(_ replacement: BrowsePost?) -> Bool {
    guard firstPost != replacement else { return false }
    firstPost = replacement
    refreshResolvedThreadAuthorAvatarURL()
    return true
  }

  private func replaceOriginThreadIfNeeded(_ replacement: BrowseThread?) {
    guard originThread != replacement else { return }
    originThread = replacement
  }

  private func replacePollIfNeeded(_ replacement: BrowsePoll?) {
    guard poll != replacement else { return }
    poll = replacement
  }

  @discardableResult
  private func replacePostSnapshot(
    firstPost replacementFirstPost: BrowsePost?,
    posts replacementPosts: [BrowsePost]
  ) -> Bool {
    let firstPostChanged = firstPost != replacementFirstPost
    let postsChanged = posts != replacementPosts
    guard firstPostChanged || postsChanged else { return false }
    if firstPostChanged {
      firstPost = replacementFirstPost
    }
    if postsChanged {
      posts = replacementPosts
    }
    rebuildPostIndexes()
    return true
  }

  private func appendPostsToEnd(
    _ candidates: [BrowsePost],
    requiresFullRebuild: Bool
  ) {
    var accepted: [BrowsePost] = []
    accepted.reserveCapacity(candidates.count)
    for post in candidates where post.id > 0 && postsByID[post.id] == nil {
      accepted.append(post)
    }
    guard !accepted.isEmpty else {
      if requiresFullRebuild {
        rebuildPostIndexes()
      }
      return
    }

    if requiresFullRebuild {
      posts.append(contentsOf: accepted)
      rebuildPostIndexes()
      return
    }

    for post in accepted {
      if let target = ContentAgreementTarget(thread: thread, post: post) {
        agreementTargetsByPostID[post.id] = target
      }
      postsByID[post.id] = post
      scrollTargetsByPostID[post.id] = ThreadScrollTargetDescriptor(
        order: nextScrollTargetOrder,
        localVisibility: post.localVisibility,
        tracksPrependAnchor: true
      )
      nextScrollTargetOrder += 1
    }
    if firstDisplayableReplyPostID == nil {
      firstDisplayableReplyPostID = accepted.first(where: {
        $0.localVisibility != .hidden
      })?.id
    }
    if firstVisibleReplyPostID == nil {
      firstVisibleReplyPostID = accepted.first(where: {
        $0.localVisibility == .visible
      })?.id
    }
    if resolvedThreadAuthorAvatarURL == nil {
      resolvedThreadAuthorAvatarURL = ThreadAuthorAvatarResolver.resolve(
        thread: thread,
        firstPost: firstPost,
        posts: accepted
      )
    }
    incrementallyIndexedPostCount += accepted.count
    posts.append(contentsOf: accepted)
  }

  func post(withID postID: Int64) -> BrowsePost? {
    postsByID[postID]
  }

  func agreementTarget(forPostID postID: Int64) -> ContentAgreementTarget? {
    agreementTargetsByPostID[postID]
  }

  private func replaceAgreementDescriptors(
    with descriptors: [ContentAgreementReadDescriptor]
  ) {
    let retainedTargets = Set(agreementTargetsByPostID.values)
    var normalized: [ContentAgreementReadDescriptor] = []
    normalized.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      guard
        let retainedDescriptor = ContentAgreementReadDescriptor(
          request: descriptor.request,
          expectedTargets: descriptor.expectedTargets.intersection(retainedTargets)
        )
      else { continue }
      if let index = normalized.firstIndex(where: { $0.request == retainedDescriptor.request }) {
        normalized[index] = retainedDescriptor
      } else {
        normalized.append(retainedDescriptor)
      }
    }
    guard normalized != agreementReadDescriptors else { return }
    agreementReadDescriptors = normalized
    agreementDescriptorEpoch &+= 1
  }

  private func upsertAgreementDescriptor(
    _ descriptor: ContentAgreementReadDescriptor?,
    pruningAll: Bool = false
  ) {
    if pruningAll {
      var descriptors = agreementReadDescriptors
      if let descriptor {
        if let index = descriptors.firstIndex(where: { $0.request == descriptor.request }) {
          descriptors[index] = descriptor
        } else {
          descriptors.append(descriptor)
        }
      }
      replaceAgreementDescriptors(with: descriptors)
      return
    }

    guard let descriptor else { return }
    var descriptors = agreementReadDescriptors
    guard let retainedDescriptor = retainedAgreementDescriptor(descriptor) else {
      guard let index = descriptors.firstIndex(where: { $0.request == descriptor.request }) else {
        return
      }
      descriptors.remove(at: index)
      agreementReadDescriptors = descriptors
      agreementDescriptorEpoch &+= 1
      return
    }
    if let index = descriptors.firstIndex(where: { $0.request == retainedDescriptor.request }) {
      descriptors[index] = retainedDescriptor
    } else {
      descriptors.append(retainedDescriptor)
    }
    guard descriptors != agreementReadDescriptors else { return }
    agreementReadDescriptors = descriptors
    agreementDescriptorEpoch &+= 1
  }

  private func retainedAgreementDescriptor(
    _ descriptor: ContentAgreementReadDescriptor
  ) -> ContentAgreementReadDescriptor? {
    let retainedTargets = Set(descriptor.expectedTargets.filter { target in
      agreementTargetsByPostID[target.objectID] == target
    })
    return ContentAgreementReadDescriptor(
      request: descriptor.request,
      expectedTargets: retainedTargets
    )
  }

  private func rebuildPostIndexes() {
    fullPostIndexRebuildCount += 1
    var agreementTargets: [Int64: ContentAgreementTarget] = [:]
    var lookup: [Int64: BrowsePost] = [:]
    var scrollTargets: [Int64: ThreadScrollTargetDescriptor] = [:]
    let capacity = posts.count + (firstPost == nil ? 0 : 1)
    agreementTargets.reserveCapacity(capacity)
    lookup.reserveCapacity(capacity)
    scrollTargets.reserveCapacity(capacity)

    var order = 0
    var firstDisplayableReplyPostID: Int64?
    var firstVisibleReplyPostID: Int64?
    if let firstPost, firstPost.id > 0 {
      if let target = ContentAgreementTarget(thread: thread, post: firstPost) {
        agreementTargets[firstPost.id] = target
      }
      lookup[firstPost.id] = firstPost
      scrollTargets[firstPost.id] = ThreadScrollTargetDescriptor(
        order: order,
        localVisibility: firstPost.localVisibility,
        tracksPrependAnchor: false
      )
      order += 1
    }
    for post in posts where post.id > 0 && lookup[post.id] == nil {
      if let target = ContentAgreementTarget(thread: thread, post: post) {
        agreementTargets[post.id] = target
      }
      lookup[post.id] = post
      scrollTargets[post.id] = ThreadScrollTargetDescriptor(
        order: order,
        localVisibility: post.localVisibility,
        tracksPrependAnchor: true
      )
      if firstDisplayableReplyPostID == nil, post.localVisibility != .hidden {
        firstDisplayableReplyPostID = post.id
      }
      if firstVisibleReplyPostID == nil, post.localVisibility == .visible {
        firstVisibleReplyPostID = post.id
      }
      order += 1
    }
    agreementTargetsByPostID = agreementTargets
    postsByID = lookup
    scrollTargetsByPostID = scrollTargets
    self.firstDisplayableReplyPostID = firstDisplayableReplyPostID
    self.firstVisibleReplyPostID = firstVisibleReplyPostID
    nextScrollTargetOrder = order
    refreshResolvedThreadAuthorAvatarURL()
  }

  private func refreshResolvedThreadAuthorAvatarURL() {
    resolvedThreadAuthorAvatarURL = ThreadAuthorAvatarResolver.resolve(
      thread: thread,
      firstPost: firstPost,
      posts: posts
    )
  }

  private struct NormalizedPostPage {
    let firstPost: BrowsePost?
    let replies: [BrowsePost]
  }

  private func normalizedPostPage(
    _ page: PostPageData,
    threadID: Int64,
    deduplicatingReplies: Bool = false
  ) throws -> NormalizedPostPage {
    guard page.thread.id == threadID else {
      throw BrowseError.unavailable("贴吧返回的主题归属异常，未显示该响应。")
    }

    let expectedFirstPostID = page.thread.firstPostID
    let explicitFirstPost = page.firstPost
    if let explicitFirstPost {
      try validateFirstPost(
        explicitFirstPost,
        threadID: threadID,
        expectedFirstPostID: expectedFirstPostID
      )
    }

    let shouldExtractLegacyFirstPost = explicitFirstPost == nil && expectedFirstPostID > 0
    let firstPostCandidates = page.posts.filter { post in
      if let explicitFirstPost {
        return post.floor == 1 || post.id == explicitFirstPost.id
      }
      return shouldExtractLegacyFirstPost
        && (post.floor == 1 || post.id == expectedFirstPostID)
    }
    for candidate in firstPostCandidates {
      try validateFirstPost(
        candidate,
        threadID: threadID,
        expectedFirstPostID: expectedFirstPostID
      )
    }

    guard firstPostCandidates.count <= 1 else {
      throw BrowseError.unavailable("贴吧返回了相互冲突的主题首楼，未显示该响应。")
    }
    if
      let explicitFirstPost,
      let candidate = firstPostCandidates.first,
      candidate.id != explicitFirstPost.id
    {
      throw BrowseError.unavailable("贴吧返回了相互冲突的主题首楼，未显示该响应。")
    }

    let resolvedFirstPost = explicitFirstPost
      ?? (shouldExtractLegacyFirstPost ? firstPostCandidates.first : nil)
    let replies: [BrowsePost]
    if let resolvedFirstPost {
      replies = page.posts.filter { $0.id != resolvedFirstPost.id && $0.floor != 1 }
    } else {
      replies = page.posts
    }

    guard replies.allSatisfy({ $0.id > 0 && $0.threadID == threadID }) else {
      throw BrowseError.unavailable("贴吧返回的楼层标识或归属异常，未显示该响应。")
    }
    var seen = Set<Int64>()
    if deduplicatingReplies {
      return NormalizedPostPage(
        firstPost: resolvedFirstPost,
        replies: replies.filter { seen.insert($0.id).inserted }
      )
    }
    guard replies.allSatisfy({ seen.insert($0.id).inserted }) else {
      throw BrowseError.unavailable("贴吧返回的楼层标识或归属异常，未显示该响应。")
    }
    return NormalizedPostPage(firstPost: resolvedFirstPost, replies: replies)
  }

  private func validateFirstPost(
    _ post: BrowsePost,
    threadID: Int64,
    expectedFirstPostID: Int64
  ) throws {
    guard
      post.id > 0,
      post.threadID == threadID,
      post.floor == 1,
      expectedFirstPostID <= 0 || post.id == expectedFirstPostID
    else {
      throw BrowseError.unavailable("贴吧返回的主题首楼标识或归属异常，未显示该响应。")
    }
  }

  private func post(
    withID postID: Int64,
    firstPost: BrowsePost?,
    replies: [BrowsePost]
  ) -> BrowsePost? {
    if firstPost?.id == postID { return firstPost }
    return replies.first(where: { $0.id == postID })
  }

  private func firstVisiblePost(
    firstPost: BrowsePost?,
    replies: [BrowsePost]
  ) -> BrowsePost? {
    if let reply = replies.first(where: { $0.localVisibility != .hidden }) {
      return reply
    }
    guard let firstPost, firstPost.localVisibility != .hidden else { return nil }
    return firstPost
  }

  private func validateRetainedFirstPostIdentity(
    _ responseFirstPost: BrowsePost?,
    responseThread: BrowseThread,
    replacing: Bool
  ) throws {
    guard !replacing, let firstPost else { return }
    let metadataConflicts = responseThread.firstPostID > 0
      && responseThread.firstPostID != firstPost.id
    let payloadConflicts = responseFirstPost.map { $0.id != firstPost.id } ?? false
    guard !metadataConflicts, !payloadConflicts else {
      throw BrowseError.unavailable("贴吧返回的主题首楼标识发生冲突，未合并该响应。")
    }
  }

  private func uniqueValidPosts(_ newItems: [BrowsePost], threadID: Int64) -> [BrowsePost] {
    var seen = Set<Int64>()
    return newItems.filter {
      $0.id > 0
        && $0.threadID == threadID
        && postsByID[$0.id] == nil
        && seen.insert($0.id).inserted
    }
  }
}
