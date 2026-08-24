import Combine
import Foundation

enum FollowedForumIndexState: Equatable, Sendable {
  case idle
  case loading
  case partial
  case ready(FollowedForumIndexSnapshot)
  case signedOut
  case failed(String)
}

struct FollowedForumIndexSnapshot: Equatable, Sendable {
  let lease: FollowedForumsSessionLease
  let forumIDs: Set<Int64>
}

enum FollowedForumUnfollowControlState: Equatable, Sendable {
  case available
  case busy
  case unavailable
}

struct FollowedForumUnfollowPrompt: Equatable, Sendable {
  let forum: FollowedForumItem
  let lease: AccountSessionLease
}

enum FollowedForumsOperationErrorKind: Equatable, Sendable {
  case pin
  case unfollow
}

struct FollowedForumsOperationError: Equatable, Sendable {
  let kind: FollowedForumsOperationErrorKind
  let title: String
  let message: String
}

@MainActor
final class FollowedForumsViewModel: ObservableObject {
  static let maximumCatalogPageCount = 100
  static let maximumRetainedForums = 5_000

  @Published private(set) var forums: [FollowedForumItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isSignedOut = false
  @Published private(set) var indexState: FollowedForumIndexState = .idle
  @Published private(set) var followedForumPins: [FollowedForumPin] = []
  @Published private(set) var pinOperationError: String?
  @Published private(set) var unfollowingForumID: Int64?
  @Published private(set) var unfollowOperationError: String?
  @Published private var fullListSurfaceOrder: [UUID] = []

  private let service: any AccountService
  private let vault: any AccountVault
  private let pinRepository: any FollowedForumPinsRepository
  private let forumMembershipMutator: any ForumMembershipMutating
  private var loadedLease: FollowedForumsSessionLease?
  private var requestLease: FollowedForumsSessionLease?
  private var loadedForumNamesByID: [Int64: String] = [:]
  private var pinAccountID: Int64?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var epoch = 0
  private var completeIndexSurfaceIDs = Set<UUID>()
  private var pinMutationTask: Task<Void, Never>?
  private var unfollowTask: Task<Void, Never>?
  private var unfollowOperation: UnfollowOperation?

  private struct UnfollowOperation: Equatable, Sendable {
    let id: UUID
    let forumID: Int64
    let normalizedForumName: String
    let lease: AccountSessionLease
  }

  init(
    service: any AccountService,
    vault: any AccountVault,
    pinRepository: any FollowedForumPinsRepository = TransientFollowedForumPinsStore(),
    forumMembershipMutator: (any ForumMembershipMutating)? = nil
  ) {
    self.service = service
    self.vault = vault
    self.pinRepository = pinRepository
    self.forumMembershipMutator = forumMembershipMutator
      ?? ForumMembershipMutationCoordinator(vault: vault, service: service)
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  var hasActiveFullListSurface: Bool {
    !fullListSurfaceOrder.isEmpty
  }

  var hasActiveCompleteIndexSurface: Bool {
    !completeIndexSurfaceIDs.isEmpty
  }

  var presentedOperationError: FollowedForumsOperationError? {
    if let unfollowOperationError {
      return FollowedForumsOperationError(
        kind: .unfollow,
        title: "无法取消关注贴吧",
        message: unfollowOperationError
      )
    }
    if let pinOperationError {
      return FollowedForumsOperationError(
        kind: .pin,
        title: "无法读取或更新置顶贴吧",
        message: pinOperationError
      )
    }
    return nil
  }

  var canLoadNextPage: Bool {
    hasMore
      && !isLoadingMore
      && loadMoreError == nil
      && state == .loaded
  }

  var forumProjection: FollowedForumsProjection {
    FollowedForumPinProjection.make(
      forums: forums,
      pins: followedForumPins,
      accountID: pinAccountID ?? 0
    )
  }

  var homeForums: [FollowedForumItem] {
    FollowedForumsHomeProjection.visibleForums(from: forumProjection.all)
  }

  func isPinned(_ forum: FollowedForumItem) -> Bool {
    guard
      let accountID = pinAccountID,
      let normalizedName = FollowedForumPin.normalizedForumName(forum.name)
    else { return false }
    let newestPin = followedForumPins
      .filter { $0.accountID == accountID && $0.forumID == forum.id }
      .max {
        if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt < $1.pinnedAt }
        return $0.forumName > $1.forumName
      }
    return newestPin?.forumName == normalizedName
  }

  func unfollowControlState(
    for forum: FollowedForumItem
  ) -> FollowedForumUnfollowControlState {
    if isUnfollowing(forum) { return .busy }
    if unfollowTask != nil { return .unavailable }
    return canUnfollow(forum) ? .available : .unavailable
  }

  func unfollowPrompt(for forum: FollowedForumItem) -> FollowedForumUnfollowPrompt? {
    guard canUnfollow(forum), let lease = loadedLease else { return nil }
    return FollowedForumUnfollowPrompt(forum: forum, lease: lease)
  }

  func isUnfollowing(_ forum: FollowedForumItem) -> Bool {
    guard
      let operation = unfollowOperation,
      operation.lease == loadedLease,
      operation.forumID == forum.id,
      operation.normalizedForumName == FollowedForumPin.normalizedForumName(forum.name)
    else { return false }
    return true
  }

  func canPresentOperationError(onFullList id: UUID) -> Bool {
    fullListSurfaceOrder.first == id
  }

  private func removeInactiveAccountPin(_ change: ForumMembershipChange) {
    let pinRepository = pinRepository
    let previousTask = pinMutationTask
    pinMutationTask = Task {
      await previousTask?.value
      try? await pinRepository.removePin(
        accountID: change.accountID,
        forumID: change.forumID
      )
    }
  }

  func fullListSurfaceDidAppear(id: UUID) {
    if !fullListSurfaceOrder.contains(id) {
      fullListSurfaceOrder.append(id)
    }
    loadIfNeeded()
  }

  func fullListSurfaceDidDisappear(id: UUID) {
    fullListSurfaceOrder.removeAll { $0 == id }
  }

  func completeIndexSurfaceDidAppear(id: UUID) {
    completeIndexSurfaceIDs.insert(id)
    ensureCompleteIndexIfNeeded()
  }

  func completeIndexSurfaceDidDisappear(id: UUID) {
    completeIndexSurfaceIDs.remove(id)
  }

  func retryCompleteIndex() {
    guard hasActiveCompleteIndexSurface, !isSignedOut else { return }
    if loadMoreError != nil, hasMore {
      retryLoadMore()
    } else {
      reload()
    }
  }

  func reload() {
    beginNewEpoch(loadImmediately: true)
  }

  func refresh() async {
    reload()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange(loadImmediately: Bool = true) {
    // Clear synchronously so the prior account cannot remain on the home screen.
    beginNewEpoch(loadImmediately: loadImmediately)
  }

  func forumMembershipDidChange(
    _ change: ForumMembershipChange,
    loadImmediately: Bool = true
  ) {
    if let activeLease = loadedLease ?? requestLease,
      activeLease.userID != change.accountID
    {
      if !change.isFollowed {
        removeInactiveAccountPin(change)
      }
      return
    }
    guard !change.isFollowed else {
      beginNewEpoch(loadImmediately: loadImmediately)
      return
    }

    beginNewEpoch(loadImmediately: false)
    let requestEpoch = epoch
    let pinRepository = pinRepository
    let previousTask = pinMutationTask
    pinMutationTask = Task {
      await previousTask?.value
      var cleanupError: String?
      do {
        try await pinRepository.removePin(
          accountID: change.accountID,
          forumID: change.forumID
        )
      } catch {
        cleanupError = error.localizedDescription
      }
      guard requestEpoch == epoch else { return }
      if loadImmediately {
        beginNewEpoch(loadImmediately: true)
      }
      if let cleanupError {
        pinOperationError = cleanupError
      }
    }
  }

  func setPinned(_ forum: FollowedForumItem, isPinned: Bool) {
    guard
      unfollowControlState(for: forum) != .busy,
      let lease = loadedLease,
      lease.userID > 0,
      pinAccountID == lease.userID,
      loadedForumNamesByID[forum.id] == FollowedForumPin.normalizedForumName(forum.name)
    else { return }

    let pinRepository = pinRepository
    let previousTask = pinMutationTask
    pinMutationTask = Task {
      await previousTask?.value
      do {
        if isPinned {
          try await pinRepository.setPin(
            accountID: lease.userID,
            forumID: forum.id,
            forumName: forum.name
          )
        } else {
          try await pinRepository.removePin(
            accountID: lease.userID,
            forumID: forum.id
          )
        }
        let pins = try await pinRepository.pins(accountID: lease.userID)
        guard loadedLease == lease, pinAccountID == lease.userID else { return }
        followedForumPins = pins
        pinOperationError = nil
      } catch {
        guard loadedLease == lease, pinAccountID == lease.userID else { return }
        pinOperationError = error.localizedDescription
      }
    }
  }

  func dismissPinOperationError() {
    pinOperationError = nil
  }

  func dismissUnfollowOperationError() {
    unfollowOperationError = nil
  }

  func dismissPresentedOperationError() {
    switch presentedOperationError?.kind {
    case .unfollow:
      dismissUnfollowOperationError()
    case .pin:
      dismissPinOperationError()
    case nil:
      break
    }
  }

  func unfollow(_ prompt: FollowedForumUnfollowPrompt) {
    let forum = prompt.forum
    guard
      let lease = loadedLease,
      lease == prompt.lease,
      canUnfollow(forum),
      let normalizedForumName = FollowedForumPin.normalizedForumName(forum.name)
    else { return }

    let operation = UnfollowOperation(
      id: UUID(),
      forumID: forum.id,
      normalizedForumName: normalizedForumName,
      lease: lease
    )
    let mutator = forumMembershipMutator
    unfollowOperation = operation
    unfollowingForumID = forum.id
    unfollowOperationError = nil
    unfollowTask = Task { [weak self] in
      let outcome = await mutator.setFollowed(
        ForumMembershipMutationRequest(
          forumID: forum.id,
          forumName: forum.name.trimmingCharacters(in: .whitespacesAndNewlines),
          previouslyFollowed: true,
          targetFollowed: false,
          expectedLease: lease,
          verifiesCurrentState: true
        )
      )
      guard let self, self.unfollowOperation?.id == operation.id else { return }
      self.unfollowTask = nil
      self.unfollowOperation = nil
      self.unfollowingForumID = nil
      self.applyUnfollowOutcome(outcome, operation: operation)
    }
  }

  func loadNextPage() {
    guard hasActiveFullListSurface, canLoadNextPage else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard loadMoreError != nil, !isLoadingMore else { return }
    if hasMore {
      load(page: currentPage + 1, replacing: false)
    } else {
      reload()
    }
  }

  func cancel() {
    invalidateLoad()
    isLoadingMore = false
    if state == .loading {
      state = forums.isEmpty ? .idle : .loaded
    }
    if indexState == .loading {
      indexState = forums.isEmpty ? .idle : .partial
    }
  }

  private func ensureCompleteIndexIfNeeded() {
    guard hasActiveCompleteIndexSurface else { return }
    switch indexState {
    case .idle:
      loadIfNeeded()
    case .partial:
      guard hasMore, !isLoadingMore, loadMoreError == nil else { return }
      load(page: currentPage + 1, replacing: false)
    case .loading, .ready, .signedOut, .failed:
      break
    }
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateLoad()
    currentPage = 0
    hasMore = true
    loadedLease = nil
    requestLease = nil
    loadedForumNamesByID = [:]
    pinAccountID = nil
    forums = []
    followedForumPins = []
    pinOperationError = nil
    unfollowOperationError = nil
    isLoadingMore = false
    loadMoreError = nil
    isSignedOut = false
    state = loadImmediately ? .loading : .idle
    indexState = loadImmediately ? .loading : .idle
    if loadImmediately {
      load(page: 1, replacing: true)
    }
  }

  private func load(page: Int, replacing: Bool) {
    guard (1...Self.maximumCatalogPageCount).contains(page) else { return }
    let service = service
    let vault = vault
    epoch &+= 1
    let requestEpoch = epoch
    if !replacing {
      isLoadingMore = true
      loadMoreError = nil
    }
    indexState = .loading
    loadTask = Task {
      var requestedPage = page
      var requestReplacesSnapshot = replacing
      var isAutomaticIndexContinuation = false
      defer {
        if requestEpoch == epoch {
          isLoadingMore = false
          requestLease = nil
          loadTask = nil
        }
      }
      do {
        while true {
          if isAutomaticIndexContinuation, !hasActiveCompleteIndexSurface {
            indexState = .partial
            return
          }
          guard let sessionBeforeRequest = try await vault.activeSession() else {
            discardResultsFromMissingSession(requestEpoch: requestEpoch)
            return
          }
          try Task.checkCancellation()
          guard requestEpoch == epoch else { return }
          if isAutomaticIndexContinuation, !hasActiveCompleteIndexSurface {
            indexState = .partial
            return
          }
          let lease = FollowedForumsSessionLease(sessionBeforeRequest)
          guard requestReplacesSnapshot || loadedLease == lease else {
            discardResultsFromChangedSession(requestEpoch: requestEpoch)
            return
          }
          requestLease = lease
          var replacementPins: [FollowedForumPin]?
          var replacementPinError: String?
          if requestReplacesSnapshot {
            do {
              replacementPins = try await pinRepository.pins(accountID: lease.userID)
            } catch {
              replacementPins = []
              replacementPinError = error.localizedDescription
            }
            try Task.checkCancellation()
            guard requestEpoch == epoch else { return }
          }
          let response = try await service.followedForums(
            session: sessionBeforeRequest,
            page: requestedPage,
            pageSize: 50
          )
          try Task.checkCancellation()
          let sessionAfterRequest = try await vault.activeSession()
          try Task.checkCancellation()
          guard requestEpoch == epoch else { return }
          guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
            discardResultsFromChangedSession(requestEpoch: requestEpoch)
            return
          }
          if requestReplacesSnapshot {
            pinAccountID = lease.userID
            followedForumPins = replacementPins ?? []
            if let replacementPinError {
              pinOperationError = replacementPinError
            }
          }
          let continues = try apply(
            response,
            lease: lease,
            requestedPage: requestedPage,
            replacing: requestReplacesSnapshot
          )
          guard continues else { return }
          requestReplacesSnapshot = false
          requestedPage = currentPage + 1
          isAutomaticIndexContinuation = true
          isLoadingMore = true
        }
      } catch is CancellationError {
        return
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        let message = error.localizedDescription
        indexState = .failed(message)
        if requestReplacesSnapshot {
          state = .failed(message)
        } else {
          loadMoreError = message
        }
      }
    }
  }

  private func apply(
    _ response: FollowedForumPageData,
    lease: FollowedForumsSessionLease,
    requestedPage: Int,
    replacing: Bool
  ) throws -> Bool {
    try Self.validate(
      response,
      requestedPage: requestedPage,
      replacing: replacing,
      currentPage: currentPage
    )
    let existing = replacing ? [] : forums
    let merged = merge(existing, response.forums)
    let madeProgress = merged.count > existing.count
    currentPage = response.currentPage
    loadedLease = lease
    forums = Array(merged.prefix(Self.maximumRetainedForums))
    loadedForumNamesByID = Dictionary(
      uniqueKeysWithValues: forums.compactMap { forum in
        FollowedForumPin.normalizedForumName(forum.name).map { (forum.id, $0) }
      }
    )
    state = .loaded

    if merged.count > Self.maximumRetainedForums {
      failIncompleteIndex(
        message: "关注贴吧数量超过当前安全读取上限，请稍后重新加载。",
        replacing: replacing
      )
      return false
    }

    guard response.hasMore else {
      hasMore = false
      loadMoreError = nil
      indexState = .ready(
        FollowedForumIndexSnapshot(lease: lease, forumIDs: Set(forums.map(\.id)))
      )
      return false
    }

    if response.forums.isEmpty || !madeProgress {
      failIncompleteIndex(
        message: "关注贴吧分页未取得进展，请重新加载后再试。",
        replacing: replacing
      )
      return false
    }
    if currentPage >= Self.maximumCatalogPageCount
      || merged.count >= Self.maximumRetainedForums
    {
      failIncompleteIndex(
        message: "关注贴吧数量超过当前安全读取上限，请稍后重新加载。",
        replacing: replacing
      )
      return false
    }

    hasMore = true
    let continues = hasActiveCompleteIndexSurface
    indexState = continues ? .loading : .partial
    return continues
  }

  private func failIncompleteIndex(message: String, replacing: Bool) {
    hasMore = false
    indexState = .failed(message)
    if replacing, forums.isEmpty {
      state = .failed(message)
    } else {
      loadMoreError = message
    }
  }

  private func discardResultsFromChangedSession(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    beginNewEpoch(loadImmediately: false)
  }

  private func discardResultsFromMissingSession(requestEpoch: Int) {
    guard requestEpoch == epoch, !Task.isCancelled else { return }
    beginNewEpoch(loadImmediately: false)
    isSignedOut = true
    state = .failed("请先登录账户。")
    indexState = .signedOut
  }

  private func invalidateLoad() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
    requestLease = nil
  }

  private func canUnfollow(_ forum: FollowedForumItem) -> Bool {
    guard
      unfollowTask == nil,
      state == .loaded,
      let lease = loadedLease,
      lease.userID > 0,
      pinAccountID == lease.userID,
      let normalizedForumName = FollowedForumPin.normalizedForumName(forum.name)
    else { return false }
    return loadedForumNamesByID[forum.id] == normalizedForumName
  }

  private func applyUnfollowOutcome(
    _ outcome: ForumMembershipMutationOutcome,
    operation: UnfollowOperation
  ) {
    guard loadedLease == operation.lease else { return }
    switch outcome {
    case .confirmed:
      break
    case .unchanged(_, let message),
      .unavailable(_, let message),
      .rejected(let message):
      unfollowOperationError = message
    case .sessionChanged:
      break
    }
  }

  private func merge(
    _ existing: [FollowedForumItem],
    _ newItems: [FollowedForumItem]
  ) -> [FollowedForumItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }

  private static func validate(
    _ page: FollowedForumPageData,
    requestedPage: Int,
    replacing: Bool,
    currentPage: Int
  ) throws {
    let expectedPage = replacing ? 1 : currentPage + 1
    guard requestedPage == expectedPage, page.currentPage == requestedPage else {
      throw BrowseError.unavailable("贴吧返回了异常的关注贴吧页码，请重新加载后再试。")
    }
    guard page.forums.count <= 100,
      page.forums.allSatisfy({
        $0.id > 0
          && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw BrowseError.unavailable("贴吧返回了异常的关注贴吧数据，请重新加载后再试。")
    }
  }
}

enum FollowedForumsHomeProjection {
  static let maximumForumCount = 6

  static func visibleForums(from forums: [FollowedForumItem]) -> [FollowedForumItem] {
    Array(forums.prefix(maximumForumCount))
  }
}
