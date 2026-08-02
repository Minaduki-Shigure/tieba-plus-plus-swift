import Combine
import Foundation

@MainActor
final class FollowedForumsViewModel: ObservableObject {
  @Published private(set) var forums: [FollowedForumItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?

  private let service: any AccountService
  private let vault: any AccountVault
  private var session: StoredAccountSession?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(service: any AccountService, vault: any AccountVault) {
    self.service = service
    self.vault = vault
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateLoad()
    session = nil
    currentPage = 0
    hasMore = true
    forums = []
    loadMoreError = nil
    state = .loading
    load(page: 1, replacing: true)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func loadMoreIfNeeded(current forum: FollowedForumItem) {
    guard
      forum.id == forums.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard loadMoreError != nil, hasMore, !isLoadingMore else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func cancel() {
    invalidateLoad()
    session = nil
    isLoadingMore = false
    if state == .loading {
      state = forums.isEmpty ? .idle : .loaded
    }
  }

  private func load(page: Int, replacing: Bool) {
    let service = service
    let vault = vault
    let existingSession = session
    generation &+= 1
    let requestGeneration = generation
    if !replacing {
      isLoadingMore = true
      loadMoreError = nil
    }
    loadTask = Task {
      defer {
        if requestGeneration == generation {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let activeSession: StoredAccountSession
        if let existingSession {
          activeSession = existingSession
        } else if let storedSession = try await vault.activeSession() {
          activeSession = storedSession
        } else {
          throw BrowseError.unavailable("请先登录账户。")
        }
        let response = try await service.followedForums(
          session: activeSession,
          page: page,
          pageSize: 50
        )
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        session = activeSession
        currentPage = response.currentPage
        hasMore = response.hasMore
        forums = replacing ? response.forums : merge(forums, response.forums)
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard requestGeneration == generation, !Task.isCancelled else { return }
        if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func invalidateLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func merge(
    _ existing: [FollowedForumItem],
    _ newItems: [FollowedForumItem]
  ) -> [FollowedForumItem] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
