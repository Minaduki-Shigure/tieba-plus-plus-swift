import Combine
import Foundation

@MainActor
final class UserRelationsViewModel: ObservableObject {
  @Published private(set) var users: [BrowseRelatedUser] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var totalCount = 0
  @Published private(set) var notice = ""
  @Published private(set) var visibilitySwitch: Int?
  @Published private(set) var paginationEpoch = 0

  let userID: Int64
  let kind: UserRelationKind

  private let service: any UserProfileService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(userID: Int64, kind: UserRelationKind, service: any UserProfileService) {
    self.userID = userID
    self.kind = kind
    self.service = service
  }

  var displayableUsers: [BrowseRelatedUser] {
    users.filter { $0.localVisibility != .hidden }
  }

  var hasDisplayableUsers: Bool {
    !displayableUsers.isEmpty
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    users = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    totalCount = 0
    notice = ""
    visibilitySwitch = nil
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

  func loadMoreIfNeeded(current user: BrowseRelatedUser) {
    guard
      user.id == users.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadUsers(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      state == .loaded
    else { return }
    loadUsers(page: currentPage + 1)
  }

  func cancel() {
    let shouldRearmPagination = !users.isEmpty && isLoadingMore
    invalidateCurrentLoad()
    isLoadingMore = false
    if shouldRearmPagination {
      paginationEpoch &+= 1
    }
    if state == .loading {
      state = users.isEmpty ? .idle : .loaded
    }
  }

  private func loadInitialPage() {
    let service = service
    let userID = userID
    let kind = kind
    loadGeneration &+= 1
    let generation = loadGeneration
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          loadTask = nil
        }
      }
      do {
        let response = try await service.userRelations(userID: userID, kind: kind, page: 1)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        users = unique(response.users)
        currentPage = response.currentPage
        hasMore = response.hasMore && !response.users.isEmpty
        totalCount = response.totalCount
        notice = response.notice
        visibilitySwitch = response.visibilitySwitch
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

  private func loadUsers(page: Int) {
    let service = service
    let userID = userID
    let kind = kind
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
        let response = try await service.userRelations(userID: userID, kind: kind, page: page)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        let merged = merge(users, response.users)
        let addedItems = merged.count > users.count
        users = merged
        currentPage = response.currentPage
        hasMore = response.hasMore && !response.users.isEmpty && addedItems
        totalCount = response.totalCount
        if !response.notice.isEmpty {
          notice = response.notice
        }
        if let responseSwitch = response.visibilitySwitch {
          visibilitySwitch = responseSwitch
        }
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

  private func unique(_ items: [BrowseRelatedUser]) -> [BrowseRelatedUser] {
    merge([], items)
  }

  private func merge(
    _ existing: [BrowseRelatedUser],
    _ newItems: [BrowseRelatedUser]
  ) -> [BrowseRelatedUser] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
