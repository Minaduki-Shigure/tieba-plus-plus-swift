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

  private let service: any AccountService
  private let vault: any AccountVault
  private let pinRepository: any FollowedForumPinsRepository
  private var loadedLease: FollowedForumsSessionLease?
  private var requestLease: FollowedForumsSessionLease?
  private var pinAccountID: Int64?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var epoch = 0
  private var fullListSurfaceIDs = Set<UUID>()
  private var completeIndexSurfaceIDs = Set<UUID>()
  private var pinMutationTask: Task<Void, Never>?

  init(
    service: any AccountService,
    vault: any AccountVault,
    pinRepository: any FollowedForumPinsRepository = TransientFollowedForumPinsStore()
  ) {
    self.service = service
    self.vault = vault
    self.pinRepository = pinRepository
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  var hasActiveFullListSurface: Bool {
    !fullListSurfaceIDs.isEmpty
  }

  var hasActiveCompleteIndexSurface: Bool {
    !completeIndexSurfaceIDs.isEmpty
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
    fullListSurfaceIDs.insert(id)
    loadIfNeeded()
  }

  func fullListSurfaceDidDisappear(id: UUID) {
    fullListSurfaceIDs.remove(id)
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
      let lease = loadedLease,
      lease.userID > 0,
      pinAccountID == lease.userID,
      forums.contains(where: {
        $0.id == forum.id
          && FollowedForumPin.normalizedForumName($0.name)
            == FollowedForumPin.normalizedForumName(forum.name)
      })
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
    pinAccountID = nil
    forums = []
    followedForumPins = []
    pinOperationError = nil
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

struct FollowedForumsSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }
}

enum FollowedForumsHomeProjection {
  static let maximumForumCount = 6

  static func visibleForums(from forums: [FollowedForumItem]) -> [FollowedForumItem] {
    Array(forums.prefix(maximumForumCount))
  }
}
