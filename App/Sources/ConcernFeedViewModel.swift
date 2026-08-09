import Combine
import Foundation

enum ConcernFeedState: Equatable {
  case idle
  case resolvingSession
  case signedOut
  case needsRelogin
  case loading
  case loaded
  case failed(String)
}

@MainActor
final class ConcernFeedViewModel: ObservableObject {
  static let maximumRetainedThreads = 300

  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: ConcernFeedState = .idle
  @Published private(set) var isRefreshing = false
  @Published private(set) var isLoadingMore = false
  @Published private(set) var refreshError: String?
  @Published private(set) var loadMoreError: String?
  @Published private(set) var hasMore = false

  private let service: any AccountService
  private let vault: any AccountVault
  private var isActive = false
  private var needsReloadAfterActivation = true
  private var loadedLease: ConcernFeedSessionLease?
  private var requestUnix: UInt64?
  private var nextPageTag: String?
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var activeRequestKind: ConcernFeedRequestKind?

  init(service: any AccountService, vault: any AccountVault) {
    self.service = service
    self.vault = vault
  }

  func setActive(_ active: Bool) {
    guard active != isActive else {
      if active, needsReloadAfterActivation, loadTask == nil {
        startRequest(.replacement)
      }
      return
    }
    isActive = active
    if active {
      if needsReloadAfterActivation || state == .idle {
        startRequest(.replacement)
      }
    } else {
      let requestKind = activeRequestKind
      invalidateCurrentRequest()
      if requestKind != nil {
        needsReloadAfterActivation = threads.isEmpty
      }
      if state == .resolvingSession || state == .loading {
        state = threads.isEmpty ? .idle : .loaded
      }
    }
  }

  func retry() {
    guard isActive else {
      needsReloadAfterActivation = true
      return
    }
    startRequest(.replacement)
  }

  func refresh() async {
    guard isActive else { return }
    if state == .loaded, loadedLease != nil, requestUnix != nil {
      startRequest(.refresh)
    } else {
      startRequest(.replacement)
    }
    await loadTask?.value
  }

  func loadMore() {
    guard
      isActive,
      state == .loaded,
      !isRefreshing,
      !isLoadingMore,
      loadMoreError == nil,
      hasMore,
      let nextPageTag
    else { return }
    startRequest(.loadMore(pageTag: nextPageTag))
  }

  func retryLoadMore() {
    guard loadMoreError != nil else { return }
    loadMoreError = nil
    loadMore()
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func accountSessionDidChange() {
    resetForExternalChange()
  }

  func contentFilterDidChange() {
    resetForExternalChange()
  }

  func cancel() {
    setActive(false)
  }

  private func resetForExternalChange() {
    invalidateCurrentRequest()
    clearSnapshot()
    needsReloadAfterActivation = true
    state = .idle
    if isActive {
      startRequest(.replacement)
    }
  }

  private func startRequest(_ kind: ConcernFeedRequestKind) {
    guard isActive else {
      needsReloadAfterActivation = true
      return
    }
    invalidateCurrentRequest()
    activeRequestKind = kind
    refreshError = nil
    loadMoreError = nil

    switch kind {
    case .replacement:
      clearSnapshot()
      state = .resolvingSession
    case .refresh:
      isRefreshing = true
    case .loadMore:
      isLoadingMore = true
    }

    let requestGeneration = generation
    let service = service
    let vault = vault
    loadTask = Task {
      defer { finishRequest(generation: requestGeneration, kind: kind) }
      do {
        guard let sessionBeforeRequest = try await vault.activeSession() else {
          guard generation == requestGeneration else { return }
          clearSnapshot()
          state = .signedOut
          needsReloadAfterActivation = false
          return
        }
        guard sessionBeforeRequest.credentials != nil else {
          guard generation == requestGeneration else { return }
          clearSnapshot()
          state = .needsRelogin
          needsReloadAfterActivation = false
          return
        }
        let lease = ConcernFeedSessionLease(sessionBeforeRequest)
        let requestTimestamp: UInt64
        let pageTag: String?
        switch kind {
        case .replacement:
          requestTimestamp = 0
          pageTag = nil
        case .refresh:
          guard loadedLease == lease, let requestUnix else {
            discardResultsFromChangedSession(generation: requestGeneration)
            return
          }
          requestTimestamp = requestUnix
          pageTag = nil
        case .loadMore(let requestedPageTag):
          guard
            loadedLease == lease,
            nextPageTag == requestedPageTag,
            let requestUnix,
            requestUnix > 0
          else {
            discardResultsFromChangedSession(generation: requestGeneration)
            return
          }
          requestTimestamp = requestUnix
          pageTag = requestedPageTag
        }

        if kind == .replacement, generation == requestGeneration {
          state = .loading
        }
        try Task.checkCancellation()
        let response = try await service.concernFeed(
          session: sessionBeforeRequest,
          pageTag: pageTag,
          lastRequestUnix: requestTimestamp
        )
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(generation: requestGeneration)
          return
        }
        try Self.validate(response, lease: lease, requestedPageTag: pageTag)
        apply(response, lease: lease, kind: kind)
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        apply(error: error, kind: kind)
      }
    }
  }

  private func apply(
    _ response: ConcernFeedPageData,
    lease: ConcernFeedSessionLease,
    kind: ConcernFeedRequestKind
  ) {
    let responseThreads = Self.unique(response.threads)
    switch kind {
    case .replacement, .refresh:
      threads = Array(responseThreads.prefix(Self.maximumRetainedThreads))
      loadedLease = lease
      requestUnix = response.requestUnix
      nextPageTag = response.hasMore ? response.nextPageTag : nil
      hasMore = response.hasMore && threads.count < Self.maximumRetainedThreads
      if hasMore, responseThreads.isEmpty {
        loadMoreError = "本页没有可显示的关注动态，可以继续加载。"
      }
      needsReloadAfterActivation = false
      state = .loaded
    case .loadMore:
      let previousCount = threads.count
      threads = Self.merge(threads, responseThreads)
      nextPageTag = response.hasMore ? response.nextPageTag : nil
      hasMore = response.hasMore && threads.count < Self.maximumRetainedThreads
      if hasMore, threads.count == previousCount {
        loadMoreError = "关注动态列表已发生变化，可以继续加载。"
      }
      state = .loaded
    }
  }

  private func apply(error: Error, kind: ConcernFeedRequestKind) {
    switch kind {
    case .replacement:
      state = .failed(error.localizedDescription)
    case .refresh:
      refreshError = error.localizedDescription
    case .loadMore:
      loadMoreError = error.localizedDescription
    }
  }

  private func finishRequest(
    generation requestGeneration: Int,
    kind: ConcernFeedRequestKind
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

  private func discardResultsFromChangedSession(generation requestGeneration: Int) {
    guard generation == requestGeneration else { return }
    invalidateCurrentRequest()
    clearSnapshot()
    needsReloadAfterActivation = true
    state = .idle
  }

  private func clearSnapshot() {
    threads = []
    loadedLease = nil
    requestUnix = nil
    nextPageTag = nil
    hasMore = false
    refreshError = nil
    loadMoreError = nil
    isRefreshing = false
    isLoadingMore = false
  }

  private func invalidateCurrentRequest() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    activeRequestKind = nil
    isRefreshing = false
    isLoadingMore = false
  }

  private static func validate(
    _ response: ConcernFeedPageData,
    lease: ConcernFeedSessionLease,
    requestedPageTag: String?
  ) throws {
    guard response.userID == lease.userID, response.requestUnix > 0 else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户动态，请重新加载后再试。")
    }
    guard response.threads.count <= 100, response.threads.allSatisfy(Self.isValid) else {
      throw BrowseError.unavailable("贴吧返回了异常的关注动态，请重新加载后再试。")
    }
    if response.hasMore {
      guard
        let nextPageTag = response.nextPageTag,
        isValidPageTag(nextPageTag),
        nextPageTag != requestedPageTag
      else {
        throw BrowseError.unavailable("贴吧返回了异常的关注分页位置，请重新加载后再试。")
      }
    } else if response.nextPageTag != nil {
      throw BrowseError.unavailable("贴吧返回了矛盾的关注分页状态，请重新加载后再试。")
    }
  }

  private static func isValid(_ thread: BrowseThread) -> Bool {
    thread.id > 0 && thread.forumID > 0
      && !thread.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !thread.isLive
  }

  private static func isValidPageTag(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 4_096 else { return false }
    return !value.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    }
  }

  private static func unique(_ source: [BrowseThread]) -> [BrowseThread] {
    var seen = Set<Int64>()
    return source.filter { $0.id > 0 && seen.insert($0.id).inserted }
  }

  private static func merge(
    _ existing: [BrowseThread],
    _ newThreads: [BrowseThread]
  ) -> [BrowseThread] {
    var result = existing
    var indexes = Dictionary(uniqueKeysWithValues: existing.indices.map { (existing[$0].id, $0) })
    for thread in newThreads {
      if let index = indexes[thread.id] {
        result[index] = thread
      } else if result.count < Self.maximumRetainedThreads {
        indexes[thread.id] = result.endIndex
        result.append(thread)
      }
    }
    return result
  }
}

private enum ConcernFeedRequestKind: Equatable, Sendable {
  case replacement
  case refresh
  case loadMore(pageTag: String)
}

private struct ConcernFeedSessionLease: Equatable, Sendable {
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
