import Combine
import Foundation

enum PersonalizedFeedScope: Equatable, Sendable {
  case all
  case waitingForFollowedForumIndex
  case followedForums(FollowedForumIndexSnapshot)

  var isReady: Bool {
    self != .waitingForFollowedForumIndex
  }

  var isFollowedForumsOnly: Bool {
    if case .followedForums = self { return true }
    return false
  }

  var hasNoAllowedForums: Bool {
    if case .followedForums(let snapshot) = self {
      return snapshot.forumIDs.isEmpty
    }
    return false
  }

  func filter(_ items: [PersonalizedFeedItem]) -> [PersonalizedFeedItem] {
    switch self {
    case .all:
      items
    case .waitingForFollowedForumIndex:
      []
    case .followedForums(let snapshot):
      items.filter { snapshot.forumIDs.contains($0.thread.forumID) }
    }
  }
}

@MainActor
final class PersonalizedFeedViewModel: ObservableObject {
  static let maximumRetainedItems = 300
  static let maximumConsecutiveDuplicatePages = 2
  static let maximumAutomaticMappedEmptyPages = 5
  static let maximumAutomaticFilteredPages = 5
  static let maximumFilteredPagesPerScanEpoch = 50
  static let maximumRawItemIDsPerScanEpoch = 1_000
  static let mappedEmptyScanPausedMessage = "连续多页没有可显示的推荐，可以继续加载。"
  static let filteredScanPausedMessage = "连续多页没有来自已关注贴吧的内容，可以继续查找。"

  @Published private(set) var items: [PersonalizedFeedItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isRefreshing = false
  @Published private(set) var isLoadingMore = false
  @Published private(set) var hasMore = true
  @Published private(set) var refreshError: String?
  @Published private(set) var loadMoreError: String?
  @Published private(set) var scope: PersonalizedFeedScope = .all
  @Published private(set) var persona: PersonalizedRecommendationPersona = .anonymous
  @Published private(set) var feedbackSubmittingThreadIDs = Set<Int64>()
  @Published private(set) var feedbackFailure: PersonalizedFeedbackFailure?

  private let service: any PersonalizedFeedService
  private let feedbackService: (any PersonalizedFeedbackService)?
  private let accountSessionLookup: (any AccountSessionLookup)?
  private let accountVault: (any AccountVault)?
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var currentPage = 0
  private var refreshOverlapFrontier = 0
  private var consecutiveDuplicatePages = 0
  private var activeRequestKind: PersonalizedFeedRequestKind?
  private var scannedRawItemIDs = Set<Int64>()
  private var scannedPageCount = 0
  private var filteredScanIsPaused = false
  private var failedLoadMorePage: Int?
  private var feedbackGeneration = 0
  private var feedbackOperations = [Int64: UUID]()
  private var feedbackTasks = [Int64: Task<Void, Never>]()
  private var feedbackHiddenThreadIDs = Set<Int64>()
  private var loadedAccountLease: PersonalizedFeedbackSessionLease?
  private var needsContentFilterReloadAfterActivation = false

  init(
    service: any PersonalizedFeedService,
    feedbackService: (any PersonalizedFeedbackService)? = nil,
    accountSessionLookup: (any AccountSessionLookup)? = nil,
    accountVault: (any AccountVault)? = nil
  ) {
    self.service = service
    self.feedbackService = feedbackService
    self.accountSessionLookup = accountSessionLookup
    self.accountVault = accountVault
  }

  var usesAccountPersona: Bool { persona.accountUserID != nil }

  func setPersona(_ persona: PersonalizedRecommendationPersona, loadIfNeeded: Bool) {
    guard self.persona != persona else {
      if loadIfNeeded { self.loadIfNeeded() }
      return
    }
    invalidateFeedbackOperations()
    invalidateCurrentRequest()
    self.persona = persona
    resetSnapshot()
    guard loadIfNeeded, scope.isReady, !scope.hasNoAllowedForums else { return }
    self.loadIfNeeded()
  }

  func setScope(_ scope: PersonalizedFeedScope, loadIfNeeded: Bool) {
    guard self.scope != scope else {
      if loadIfNeeded { self.loadIfNeeded() }
      return
    }
    invalidateCurrentRequest()
    self.scope = scope
    resetSnapshot()
    if scope.hasNoAllowedForums {
      state = .loaded
      hasMore = false
    } else if loadIfNeeded {
      self.loadIfNeeded()
    }
  }

  func loadIfNeeded() {
    guard state == .idle, scope.isReady else { return }
    if scope.hasNoAllowedForums {
      state = .loaded
      hasMore = false
      return
    }
    startRequest(.replacement)
  }

  func retry() {
    guard scope.isReady else { return }
    if scope.hasNoAllowedForums {
      resetSnapshot()
      state = .loaded
      hasMore = false
      return
    }
    startRequest(.replacement)
  }

  func refresh() async {
    guard state == .loaded, !isLoadingMore, scope.isReady, !scope.hasNoAllowedForums else {
      return
    }
    startRequest(.refresh)
    await loadTask?.value
  }

  func reloadForContentFilterChange() {
    guard state == .loaded, scope.isReady, !scope.hasNoAllowedForums else { return }
    startRequest(.replacement)
  }

  func contentFilterDidChange(reloadIfActive: Bool) {
    guard reloadIfActive else {
      needsContentFilterReloadAfterActivation = true
      return
    }
    needsContentFilterReloadAfterActivation = false
    reloadForContentFilterChange()
  }

  func reloadDeferredContentFilterIfNeeded() {
    guard needsContentFilterReloadAfterActivation else { return }
    needsContentFilterReloadAfterActivation = false
    reloadForContentFilterChange()
  }

  func loadMore() {
    guard
      state == .loaded,
      !isRefreshing,
      !isLoadingMore,
      loadMoreError == nil,
      hasMore,
      currentPage < Int(Int32.max),
      scope.isReady,
      !scope.hasNoAllowedForums
    else { return }
    if scope.isFollowedForumsOnly, filteredScanEpochIsExhausted {
      pauseFilteredScan()
      return
    }
    startRequest(.loadMore(page: currentPage + 1))
  }

  func loadMoreIfNeeded(currentItemID: Int64) {
    guard
      let index = items.firstIndex(where: { $0.id == currentItemID }),
      index >= max(items.count - 3, 0)
    else { return }
    loadMore()
  }

  func retryLoadMore() {
    guard loadMoreError != nil else { return }
    if filteredScanIsPaused {
      resetFilteredScanEpoch()
    }
    if let failedLoadMorePage {
      loadMoreError = nil
      startRequest(.loadMore(page: failedLoadMorePage))
      return
    }
    loadMoreError = nil
    loadMore()
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func clearFeedbackFailure() {
    feedbackFailure = nil
  }

  func submitFeedback(
    threadID: Int64,
    selectedReasonIDs: Set<UInt32>,
    clickTimeMilliseconds: Int64
  ) {
    guard feedbackOperations[threadID] == nil else { return }
    guard
      let item = items.first(where: { $0.id == threadID }),
      let submission = PersonalizedFeedbackSubmission(
        item: item,
        selectedReasonIDs: selectedReasonIDs,
        clickTimeMilliseconds: clickTimeMilliseconds
      )
    else {
      feedbackFailure = .invalidSelection
      return
    }
    guard let feedbackService, let accountSessionLookup else {
      feedbackFailure = .unavailable("当前版本无法提交推荐反馈。")
      return
    }
    guard let selectedUserID = persona.accountUserID else {
      feedbackFailure = .accountPersonaRequired
      return
    }
    guard let feedLease = loadedAccountLease, feedLease.userID == selectedUserID else {
      feedbackFailure = .unavailable("推荐内容对应的账户会话已变化，请刷新后再提交反馈。")
      return
    }

    feedbackFailure = nil
    let operationID = UUID()
    let requestGeneration = feedbackGeneration
    feedbackOperations[threadID] = operationID
    feedbackSubmittingThreadIDs.insert(threadID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performFeedbackSubmission(
        submission,
        operationID: operationID,
        requestGeneration: requestGeneration,
        service: feedbackService,
        lookup: accountSessionLookup,
        selectedUserID: selectedUserID,
        feedLease: feedLease
      )
    }
    feedbackTasks[threadID] = task
  }

  func accountSessionDidChange(reloadIfActive: Bool) {
    invalidateFeedbackOperations()

    invalidateCurrentRequest()
    resetSnapshot()

    guard reloadIfActive, scope.isReady, !scope.hasNoAllowedForums else { return }
    loadIfNeeded()
  }

  func cancel() {
    let kind = activeRequestKind
    invalidateCurrentRequest()
    if state == .loading {
      state = kind == .replacement && items.isEmpty ? .idle : .loaded
    }
  }

  private func performFeedbackSubmission(
    _ submission: PersonalizedFeedbackSubmission,
    operationID: UUID,
    requestGeneration: Int,
    service: any PersonalizedFeedbackService,
    lookup: any AccountSessionLookup,
    selectedUserID: Int64,
    feedLease: PersonalizedFeedbackSessionLease
  ) async {
    defer {
      finishFeedbackOperation(
        threadID: submission.threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
    }

    let session: StoredAccountSession
    do {
      guard let selectedSession = try await lookup.session(userID: selectedUserID) else {
        publishFeedbackFailure(
          .loginRequired,
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
        return
      }
      guard
        feedbackOperationIsCurrent(
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
      else { return }
      guard feedLease.matches(selectedSession) else {
        publishFeedbackFailure(
          .unavailable("推荐内容对应的账户会话已变化，请刷新后再提交反馈。"),
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
        return
      }
      guard selectedSession.credentials != nil else {
        publishFeedbackFailure(
          .fullCredentialsRequired,
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
        return
      }
      session = selectedSession
    } catch is CancellationError {
      return
    } catch {
      publishFeedbackFailure(
        .unavailable("无法读取当前账户，请稍后重试。"),
        threadID: submission.threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
      return
    }

    let lease = PersonalizedFeedbackSessionLease(session)
    do {
      try await service.submitPersonalizedFeedback(
        session: session,
        submission: submission
      )
      guard await feedbackLeaseIsCurrent(lease, lookup: lookup) else { return }
      guard
        feedbackOperationIsCurrent(
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
      else { return }
      hideFeedbackThread(submission.threadID)
    } catch is CancellationError {
      return
    } catch let error as PersonalizedFeedbackSubmissionError where error == .outcomeUnknown {
      guard await feedbackLeaseIsCurrent(lease, lookup: lookup) else { return }
      guard
        feedbackOperationIsCurrent(
          threadID: submission.threadID,
          operationID: operationID,
          requestGeneration: requestGeneration
        )
      else { return }
      hideFeedbackThread(submission.threadID)
      feedbackFailure = .outcomeUnknown
    } catch let error as PersonalizedFeedbackSubmissionError
      where error == .fullCredentialsRequired
    {
      guard await feedbackLeaseIsCurrent(lease, lookup: lookup) else { return }
      publishFeedbackFailure(
        .fullCredentialsRequired,
        threadID: submission.threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
    } catch {
      guard await feedbackLeaseIsCurrent(lease, lookup: lookup) else { return }
      publishFeedbackFailure(
        .unavailable(error.localizedDescription),
        threadID: submission.threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
    }
  }

  private func feedbackLeaseIsCurrent(
    _ lease: PersonalizedFeedbackSessionLease,
    lookup: any AccountSessionLookup
  ) async -> Bool {
    do {
      return lease.matches(try await lookup.session(userID: lease.userID))
    } catch {
      return false
    }
  }

  private func invalidateFeedbackOperations() {
    feedbackGeneration &+= 1
    feedbackOperations.removeAll()
    // Core stops pre-dispatch work but lets a possibly dispatched one-shot write finish.
    for task in feedbackTasks.values { task.cancel() }
    feedbackTasks.removeAll()
    feedbackSubmittingThreadIDs.removeAll()
    feedbackHiddenThreadIDs.removeAll()
    feedbackFailure = nil
  }

  private func hideFeedbackThread(_ threadID: Int64) {
    feedbackHiddenThreadIDs.insert(threadID)
    items.removeAll { $0.id == threadID }
  }

  private func publishFeedbackFailure(
    _ failure: PersonalizedFeedbackFailure,
    threadID: Int64,
    operationID: UUID,
    requestGeneration: Int
  ) {
    guard
      feedbackOperationIsCurrent(
        threadID: threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
    else { return }
    feedbackFailure = failure
  }

  private func finishFeedbackOperation(
    threadID: Int64,
    operationID: UUID,
    requestGeneration: Int
  ) {
    guard
      feedbackOperationIsCurrent(
        threadID: threadID,
        operationID: operationID,
        requestGeneration: requestGeneration
      )
    else { return }
    feedbackOperations.removeValue(forKey: threadID)
    feedbackTasks.removeValue(forKey: threadID)
    feedbackSubmittingThreadIDs.remove(threadID)
  }

  private func feedbackOperationIsCurrent(
    threadID: Int64,
    operationID: UUID,
    requestGeneration: Int
  ) -> Bool {
    feedbackGeneration == requestGeneration && feedbackOperations[threadID] == operationID
  }

  private var filteredScanEpochIsExhausted: Bool {
    scannedPageCount >= Self.maximumFilteredPagesPerScanEpoch
      || scannedRawItemIDs.count >= Self.maximumRawItemIDsPerScanEpoch
  }

  private func startRequest(_ kind: PersonalizedFeedRequestKind) {
    guard scope.isReady, !scope.hasNoAllowedForums else { return }
    invalidateCurrentRequest()
    activeRequestKind = kind
    refreshError = nil
    loadMoreError = nil
    filteredScanIsPaused = false
    failedLoadMorePage = nil

    let requestedPage: Int
    switch kind {
    case .replacement:
      requestedPage = 1
      state = .loading
      items = []
      loadedAccountLease = nil
      currentPage = 0
      refreshOverlapFrontier = 0
      consecutiveDuplicatePages = 0
      hasMore = true
      resetFilteredScanEpoch()
    case .refresh:
      requestedPage = 1
      isRefreshing = true
      resetFilteredScanEpoch()
    case .loadMore(let page):
      requestedPage = page
      isLoadingMore = true
    }

    let requestGeneration = generation
    let requestScope = scope
    let requestPersona = persona
    let service = service
    let accountSessionLookup = accountSessionLookup
    let accountVault = accountVault
    loadTask = Task {
      var page = requestedPage
      defer { finishRequest(generation: requestGeneration, kind: kind) }
      do {
        let requestIdentity = try await Self.requestIdentity(
          for: requestPersona,
          lookup: accountSessionLookup
        )
        let scopeIsCurrent = await Self.requestScopeIsCurrent(
          requestScope,
          persona: requestPersona,
          identity: requestIdentity,
          vault: accountVault
        )
        try Task.checkCancellation()
        guard generation == requestGeneration, persona == requestPersona else { return }
        guard scopeIsCurrent else {
          throw BrowseError.unavailable("关注贴吧筛选对应的账户已变化，请重新加载。")
        }
        guard Self.snapshotLeaseIsCompatible(
          kind: kind,
          loadedLease: loadedAccountLease,
          identity: requestIdentity
        ) else {
          throw BrowseError.unavailable("推荐内容对应的账户会话已变化，请重新加载。")
        }
        var pagesScannedForAction = 0
        while true {
          let response: PersonalizedFeedPageData
          switch requestIdentity {
          case .anonymous:
            response = try await service.personalizedThreads(page: page)
          case .account(let session, _):
            response = try await service.personalizedThreads(page: page, session: session)
          }
          try Task.checkCancellation()
          let identityIsCurrent = await Self.requestIdentityIsCurrent(
            requestIdentity,
            lookup: accountSessionLookup
          )
          let scopeIsCurrent = await Self.requestScopeIsCurrent(
            requestScope,
            persona: requestPersona,
            identity: requestIdentity,
            vault: accountVault
          )
          try Task.checkCancellation()
          guard
            generation == requestGeneration,
            persona == requestPersona,
            identityIsCurrent,
            scopeIsCurrent
          else {
            throw BrowseError.unavailable("推荐个性对应的账户已变化，请重新加载。")
          }
          guard response.currentPage == page else {
            throw BrowseError.unavailable("推荐流返回了错误的页码。")
          }

          let rawItems = unique(response.items)
          let madeRawProgress = recordRawProgress(rawItems)
          scannedPageCount &+= 1
          pagesScannedForAction &+= 1
          let eligibleItems = feedbackVisible(requestScope.filter(rawItems))
          let termination: PersonalizedFeedBatchTermination

          if !response.hasMore {
            termination = rawItems.isEmpty ? .rawEmpty : .serverEnd
          } else if !madeRawProgress {
            if rawItems.isEmpty,
               pagesScannedForAction < Self.maximumAutomaticMappedEmptyPages,
               page < Int(Int32.max)
            {
              page += 1
              continue
            }
            if rawItems.isEmpty {
              termination = page < Int(Int32.max) ? .mappedEmptyScanPaused : .serverEnd
            } else {
              termination = .duplicateOnly
            }
          } else if !requestScope.isFollowedForumsOnly, eligibleItems.isEmpty {
            if pagesScannedForAction < Self.maximumAutomaticMappedEmptyPages,
              page < Int(Int32.max)
            {
              page += 1
              continue
            }
            termination = page < Int(Int32.max) ? .mappedEmptyScanPaused : .serverEnd
          } else if !requestScope.isFollowedForumsOnly || !eligibleItems.isEmpty {
            termination = .pageReady
          } else if pagesScannedForAction >= Self.maximumAutomaticFilteredPages
            || filteredScanEpochIsExhausted
          {
            termination = .filteredScanPaused
          } else if page >= Int(Int32.max) {
            termination = .serverEnd
          } else {
            page += 1
            continue
          }

          apply(
            PersonalizedFeedBatch(
              items: eligibleItems,
              currentPage: page,
              serverHasMore: response.hasMore,
              termination: termination
            ),
            kind: kind,
            identity: requestIdentity
          )
          return
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        apply(error: error, kind: kind, failedPage: page)
      }
    }
  }

  private func apply(
    _ batch: PersonalizedFeedBatch,
    kind: PersonalizedFeedRequestKind,
    identity: PersonalizedFeedRequestIdentity
  ) {
    let responseItems = feedbackVisible(unique(batch.items))
    switch kind {
    case .replacement:
      loadedAccountLease = identity.accountLease
      items = Array(responseItems.prefix(Self.maximumRetainedItems))
      currentPage = batch.currentPage
      refreshOverlapFrontier = 0
      consecutiveDuplicatePages = 0
      hasMore = canContinue(after: batch, hasVisibleItems: !responseItems.isEmpty)
      state = .loaded
      if batch.termination == .filteredScanPaused {
        pauseFilteredScan()
      } else if batch.termination == .mappedEmptyScanPaused {
        pauseMappedEmptyScan()
      }
    case .refresh:
      if !responseItems.isEmpty {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        items = merged(responseItems, followedBy: items)
        currentPage = batch.currentPage
        consecutiveDuplicatePages = 0
        hasMore = canContinue(after: batch, hasVisibleItems: true)
      } else if batch.termination == .filteredScanPaused {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
        pauseFilteredScan()
      } else if batch.termination == .mappedEmptyScanPaused {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
        pauseMappedEmptyScan()
      } else if batch.termination == .duplicateOnly, batch.serverHasMore {
        refreshOverlapFrontier = max(refreshOverlapFrontier, currentPage)
        currentPage = batch.currentPage
        hasMore = true
      }
    case .loadMore:
      let knownIDs = Set(items.map(\.id))
      let additions = responseItems.filter { !knownIDs.contains($0.id) }
      currentPage = batch.currentPage
      switch batch.termination {
      case .rawEmpty:
        hasMore = false
      case .serverEnd:
        if !additions.isEmpty {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
        }
        consecutiveDuplicatePages = additions.isEmpty ? consecutiveDuplicatePages : 0
        hasMore = false
      case .filteredScanPaused:
        hasMore = items.count < Self.maximumRetainedItems
        pauseFilteredScan()
      case .mappedEmptyScanPaused:
        hasMore = items.count < Self.maximumRetainedItems
        pauseMappedEmptyScan()
      case .duplicateOnly:
        if additions.isEmpty {
          applyDuplicatePage(batch: batch)
        } else {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
          consecutiveDuplicatePages = 0
          hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
        }
      case .pageReady:
        if additions.isEmpty {
          applyDuplicatePage(batch: batch)
        } else {
          items = Array((items + additions).prefix(Self.maximumRetainedItems))
          consecutiveDuplicatePages = 0
          hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
        }
      }
    }
  }

  private func applyDuplicatePage(batch: PersonalizedFeedBatch) {
    if batch.currentPage <= refreshOverlapFrontier {
      consecutiveDuplicatePages = 0
      hasMore = batch.serverHasMore && items.count < Self.maximumRetainedItems
    } else {
      consecutiveDuplicatePages += 1
      hasMore = batch.serverHasMore
        && consecutiveDuplicatePages < Self.maximumConsecutiveDuplicatePages
        && items.count < Self.maximumRetainedItems
    }
  }

  private func canContinue(
    after batch: PersonalizedFeedBatch,
    hasVisibleItems: Bool
  ) -> Bool {
    guard items.count < Self.maximumRetainedItems else { return false }
    switch batch.termination {
    case .serverEnd, .rawEmpty:
      return false
    case .filteredScanPaused, .mappedEmptyScanPaused:
      return true
    case .duplicateOnly:
      return batch.serverHasMore
    case .pageReady:
      return batch.serverHasMore && (scope.isFollowedForumsOnly || hasVisibleItems)
    }
  }

  private func apply(
    error: Error,
    kind: PersonalizedFeedRequestKind,
    failedPage: Int
  ) {
    switch kind {
    case .replacement:
      state = .failed(error.localizedDescription)
    case .refresh:
      refreshError = error.localizedDescription
    case .loadMore:
      failedLoadMorePage = failedPage
      loadMoreError = error.localizedDescription
    }
  }

  private func pauseFilteredScan() {
    filteredScanIsPaused = true
    loadMoreError = Self.filteredScanPausedMessage
  }

  private func pauseMappedEmptyScan() {
    loadMoreError = Self.mappedEmptyScanPausedMessage
  }

  private func resetSnapshot() {
    items = []
    state = .idle
    isRefreshing = false
    isLoadingMore = false
    hasMore = true
    refreshError = nil
    loadMoreError = nil
    currentPage = 0
    refreshOverlapFrontier = 0
    consecutiveDuplicatePages = 0
    filteredScanIsPaused = false
    failedLoadMorePage = nil
    loadedAccountLease = nil
    resetFilteredScanEpoch()
  }

  private func resetFilteredScanEpoch() {
    scannedRawItemIDs = Set(items.map(\.id))
    scannedPageCount = 0
    filteredScanIsPaused = false
  }

  private func recordRawProgress(_ source: [PersonalizedFeedItem]) -> Bool {
    var madeProgress = false
    for item in source where item.id > 0 {
      if scannedRawItemIDs.insert(item.id).inserted {
        madeProgress = true
      }
    }
    return madeProgress
  }

  private func unique(_ source: [PersonalizedFeedItem]) -> [PersonalizedFeedItem] {
    var seen = Set<Int64>()
    return source.filter { $0.id > 0 && seen.insert($0.id).inserted }
  }

  private func feedbackVisible(
    _ source: [PersonalizedFeedItem]
  ) -> [PersonalizedFeedItem] {
    source.filter { !feedbackHiddenThreadIDs.contains($0.id) }
  }

  private func merged(
    _ first: [PersonalizedFeedItem],
    followedBy second: [PersonalizedFeedItem]
  ) -> [PersonalizedFeedItem] {
    var seen = Set<Int64>()
    return Array(
      (first + second)
        .filter {
          $0.id > 0
            && !feedbackHiddenThreadIDs.contains($0.id)
            && seen.insert($0.id).inserted
        }
        .prefix(Self.maximumRetainedItems)
    )
  }

  private func finishRequest(
    generation requestGeneration: Int,
    kind: PersonalizedFeedRequestKind
  ) {
    guard generation == requestGeneration else { return }
    loadTask = nil
    activeRequestKind = nil
    switch kind {
    case .replacement:
      break
    case .refresh:
      isRefreshing = false
    case .loadMore:
      isLoadingMore = false
    }
  }

  private func invalidateCurrentRequest() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    activeRequestKind = nil
    isRefreshing = false
    isLoadingMore = false
  }

  private nonisolated static func requestIdentity(
    for persona: PersonalizedRecommendationPersona,
    lookup: (any AccountSessionLookup)?
  ) async throws -> PersonalizedFeedRequestIdentity {
    switch persona {
    case .anonymous:
      return .anonymous
    case .account(let userID):
      guard let lookup else {
        throw BrowseError.unavailable("当前版本无法读取所选推荐账号。")
      }
      guard let session = try await lookup.session(userID: userID) else {
        throw BrowseError.unavailable("所选推荐账号已不存在，请重新选择。")
      }
      guard session.credentials != nil else {
        throw BrowseError.unavailable("所选账号需要重新登录，才能用于个性推荐。")
      }
      return .account(session: session, lease: PersonalizedFeedbackSessionLease(session))
    }
  }

  private nonisolated static func requestIdentityIsCurrent(
    _ identity: PersonalizedFeedRequestIdentity,
    lookup: (any AccountSessionLookup)?
  ) async -> Bool {
    switch identity {
    case .anonymous:
      return true
    case .account(_, let lease):
      guard let lookup else { return false }
      do {
        return lease.matches(try await lookup.session(userID: lease.userID))
      } catch {
        return false
      }
    }
  }

  private nonisolated static func requestScopeIsCurrent(
    _ scope: PersonalizedFeedScope,
    persona: PersonalizedRecommendationPersona,
    identity: PersonalizedFeedRequestIdentity,
    vault: (any AccountVault)?
  ) async -> Bool {
    guard case .followedForums(let snapshot) = scope else {
      return scope != .waitingForFollowedForumIndex
    }
    switch persona {
    case .anonymous:
      guard let vault else { return false }
      do {
        guard let session = try await vault.activeSession() else { return false }
        return snapshot.lease.matches(session)
      } catch {
        return false
      }
    case .account:
      guard case .account(_, let lease) = identity else { return false }
      return snapshot.lease.userID == lease.userID
        && snapshot.lease.sessionRevision == lease.sessionRevision
    }
  }

  private nonisolated static func snapshotLeaseIsCompatible(
    kind: PersonalizedFeedRequestKind,
    loadedLease: PersonalizedFeedbackSessionLease?,
    identity: PersonalizedFeedRequestIdentity
  ) -> Bool {
    if kind == .replacement { return true }
    return loadedLease == identity.accountLease
  }
}

private enum PersonalizedFeedRequestKind: Equatable, Sendable {
  case replacement
  case refresh
  case loadMore(page: Int)
}

private enum PersonalizedFeedBatchTermination: Equatable, Sendable {
  case pageReady
  case serverEnd
  case rawEmpty
  case duplicateOnly
  case filteredScanPaused
  case mappedEmptyScanPaused
}

private struct PersonalizedFeedBatch: Sendable {
  let items: [PersonalizedFeedItem]
  let currentPage: Int
  let serverHasMore: Bool
  let termination: PersonalizedFeedBatchTermination
}

private enum PersonalizedFeedRequestIdentity: Sendable {
  case anonymous
  case account(session: StoredAccountSession, lease: PersonalizedFeedbackSessionLease)

  var accountLease: PersonalizedFeedbackSessionLease? {
    guard case .account(_, let lease) = self else { return nil }
    return lease
  }
}
