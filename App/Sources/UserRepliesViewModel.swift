import Combine
import Foundation

@MainActor
final class UserRepliesViewModel: ObservableObject {
  @Published private(set) var replies: [BrowseUserReply] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var isActivityHidden = false
  @Published private(set) var paginationEpoch = 0

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

  var displayableReplies: [BrowseUserReply] {
    replies.filter { $0.localVisibility != .hidden }
  }

  var hasDisplayableReplies: Bool {
    !displayableReplies.isEmpty
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    replies = []
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

  func reloadAfterContentFilterChange() {
    guard state != .idle else { return }
    reload()
  }

  func loadMoreIfNeeded(current reply: BrowseUserReply) {
    guard
      reply.id == replies.last?.id,
      !isActivityHidden,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadReplies(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard
      !isActivityHidden,
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      state == .loaded
    else { return }
    loadReplies(page: currentPage + 1)
  }

  func cancel() {
    let shouldRearmPagination = !replies.isEmpty && isLoadingMore
    invalidateCurrentLoad()
    isLoadingMore = false
    if shouldRearmPagination {
      paginationEpoch &+= 1
    }
    if state == .loading {
      state = replies.isEmpty ? .idle : .loaded
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
        let response = try await service.userReplies(userID: userID, page: 1, pageSize: 20)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        replies = unique(response.replies)
        currentPage = response.currentPage
        hasMore = response.hasMore
        isActivityHidden = response.isHidden
        state = .loaded
        paginationEpoch &+= 1
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func loadReplies(page: Int) {
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
        let response = try await service.userReplies(
          userID: userID,
          page: page,
          pageSize: 20
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        let merged = merge(replies, response.replies)
        let addedItems = merged.count > replies.count
        replies = merged
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

  private func unique(_ items: [BrowseUserReply]) -> [BrowseUserReply] {
    merge([], items)
  }

  private func merge(
    _ existing: [BrowseUserReply],
    _ newItems: [BrowseUserReply]
  ) -> [BrowseUserReply] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
