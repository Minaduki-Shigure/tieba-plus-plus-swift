import Combine
import Foundation

@MainActor
final class UserProfileViewModel: ObservableObject {
  @Published private(set) var profile: BrowseUserProfile?
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isActivityHidden = false
  @Published private(set) var threadPaginationEpoch = 0

  let userID: Int64

  private let service: any UserProfileService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

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
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    profile = nil
    threads = []
    currentPage = 0
    hasMore = true
    isActivityHidden = false
    isLoadingMore = false
    loadMoreError = nil
    state = .loading
    loadInitialPage()
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func reloadThreadsAfterContentFilterChange() {
    reload()
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      !isActivityHidden,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadThreads(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard
      !isActivityHidden,
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      state == .loaded
    else { return }
    loadThreads(page: currentPage + 1)
  }

  func cancel() {
    let shouldRearmPagination = !threads.isEmpty && isLoadingMore
    invalidateCurrentLoad()
    isLoadingMore = false
    if shouldRearmPagination {
      threadPaginationEpoch &+= 1
    }
    if state == .loading {
      state = profile == nil ? .idle : .loaded
    }
  }

  private func loadInitialPage() {
    let service = service
    let userID = userID
    loadGeneration &+= 1
    let generation = loadGeneration
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          loadTask = nil
        }
      }
      do {
        async let profileRequest = service.userProfile(userID: userID)
        async let threadsRequest = service.userThreads(userID: userID, page: 1, pageSize: 20)
        let (loadedProfile, response) = try await (profileRequest, threadsRequest)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        profile = loadedProfile
        threads = unique(response.threads)
        currentPage = response.currentPage
        hasMore = response.hasMore
        isActivityHidden = response.isHidden
        state = .loaded
        threadPaginationEpoch &+= 1
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func loadThreads(page: Int) {
    let service = service
    let userID = userID
    loadGeneration &+= 1
    let generation = loadGeneration
    loadMoreError = nil
    isLoadingMore = true
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.userThreads(
          userID: userID,
          page: page,
          pageSize: 20
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        let merged = merge(threads, response.threads)
        let addedItems = merged.count > threads.count
        threads = merged
        currentPage = response.currentPage
        hasMore = response.hasMore && addedItems
        isActivityHidden = response.isHidden
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func unique(_ items: [BrowseThread]) -> [BrowseThread] {
    merge([], items)
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
