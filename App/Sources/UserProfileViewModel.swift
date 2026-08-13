import Combine
import Foundation

@MainActor
final class UserProfileViewModel: ObservableObject {
  @Published private(set) var profile: BrowseUserProfile?
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var threadState: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isActivityHidden = false
  @Published private(set) var threadPaginationEpoch = 0

  let userID: Int64

  private let service: any UserProfileService
  private var currentPage = 0
  private var hasMore = true
  private var profileTask: Task<Void, Never>?
  private var threadTask: Task<Void, Never>?
  private var profileGeneration = 0
  private var threadGeneration = 0

  init(userID: Int64, service: any UserProfileService) {
    self.userID = userID
    self.service = service
  }

  var displayableThreads: [BrowseThread] {
    threads.filter { $0.localVisibility != .hidden }
  }

  var hasDisplayableThreads: Bool {
    !displayableThreads.isEmpty
  }

  func loadIfNeeded() {
    if state == .idle {
      reload()
    } else if state == .loaded, threadState == .idle {
      reloadThreads()
    }
  }

  func reload() {
    _ = beginFullReload()
  }

  func refresh() async {
    let tasks = beginFullReload()
    await tasks.profile.value
    await tasks.threads.value
  }

  func retryInitialThreads() {
    guard case .failed = threadState else { return }
    reloadThreads()
  }

  func reloadThreadsAfterContentFilterChange() {
    guard state != .idle || threadState != .idle else { return }
    reloadThreads()
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      !isActivityHidden,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      threadState == .loaded
    else { return }
    loadThreads(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard
      !isActivityHidden,
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      threadState == .loaded
    else { return }
    loadThreads(page: currentPage + 1)
  }

  func cancel() {
    let shouldRearmPagination = !threads.isEmpty && isLoadingMore
    cancelProfileLoad()
    cancelThreadLoad()
    isLoadingMore = false
    if shouldRearmPagination {
      threadPaginationEpoch &+= 1
    }
    if state == .loading {
      state = profile == nil ? .idle : .loaded
    }
    if threadState == .loading {
      threadState = .idle
    }
  }

  private func beginFullReload() -> (
    profile: Task<Void, Never>,
    threads: Task<Void, Never>
  ) {
    cancelProfileLoad()
    resetThreads()
    profile = nil
    state = .loading
    threadState = .loading
    let profileTask = loadProfile()
    let threadTask = loadInitialThreads()
    return (profileTask, threadTask)
  }

  private func reloadThreads() {
    resetThreads()
    threadState = .loading
    _ = loadInitialThreads()
  }

  private func resetThreads() {
    cancelThreadLoad()
    threads = []
    currentPage = 0
    hasMore = true
    isActivityHidden = false
    isLoadingMore = false
    loadMoreError = nil
  }

  @discardableResult
  private func loadProfile() -> Task<Void, Never> {
    let service = service
    let userID = userID
    profileGeneration &+= 1
    let generation = profileGeneration
    let task = Task {
      defer {
        if generation == profileGeneration {
          profileTask = nil
        }
      }
      do {
        let loadedProfile = try await service.userProfile(userID: userID)
        try Task.checkCancellation()
        guard generation == profileGeneration else { return }
        profile = loadedProfile
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == profileGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
    profileTask = task
    return task
  }

  @discardableResult
  private func loadInitialThreads() -> Task<Void, Never> {
    let service = service
    let userID = userID
    threadGeneration &+= 1
    let generation = threadGeneration
    let task = Task {
      defer {
        if generation == threadGeneration {
          threadTask = nil
        }
      }
      do {
        let response = try await service.userThreads(userID: userID, page: 1, pageSize: 20)
        try Task.checkCancellation()
        guard generation == threadGeneration else { return }
        threads = unique(response.threads)
        currentPage = response.currentPage
        hasMore = response.hasMore
        isActivityHidden = response.isHidden
        threadState = .loaded
        threadPaginationEpoch &+= 1
      } catch is CancellationError {
        return
      } catch {
        guard generation == threadGeneration, !Task.isCancelled else { return }
        threadState = .failed(error.localizedDescription)
      }
    }
    threadTask = task
    return task
  }

  private func loadThreads(page: Int) {
    let service = service
    let userID = userID
    threadGeneration &+= 1
    let generation = threadGeneration
    loadMoreError = nil
    isLoadingMore = true
    let task = Task {
      defer {
        if generation == threadGeneration {
          isLoadingMore = false
          threadTask = nil
        }
      }
      do {
        let response = try await service.userThreads(
          userID: userID,
          page: page,
          pageSize: 20
        )
        try Task.checkCancellation()
        guard generation == threadGeneration else { return }
        let merged = merge(threads, response.threads)
        let addedItems = merged.count > threads.count
        threads = merged
        currentPage = response.currentPage
        hasMore = response.hasMore && addedItems
        isActivityHidden = response.isHidden
      } catch is CancellationError {
        return
      } catch {
        guard generation == threadGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
    threadTask = task
  }

  private func cancelProfileLoad() {
    profileGeneration &+= 1
    profileTask?.cancel()
    profileTask = nil
  }

  private func cancelThreadLoad() {
    threadGeneration &+= 1
    threadTask?.cancel()
    threadTask = nil
  }

  private func unique(_ items: [BrowseThread]) -> [BrowseThread] {
    merge([], items)
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
