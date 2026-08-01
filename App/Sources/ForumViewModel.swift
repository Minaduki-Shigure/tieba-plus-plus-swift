import Combine
import Foundation

@MainActor
final class ForumViewModel: ObservableObject {
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?

  let forumName: String

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(forumName: String, service: any BrowseService) {
    self.forumName = forumName
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    threads = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    if state == .loading {
      state = threads.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else {
      return
    }
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard loadMoreError != nil, hasMore, !isLoadingMore, state == .loaded else { return }
    load(page: currentPage + 1, replacing: false)
  }

  private func load(page: Int, replacing: Bool) {
    let forumName = forumName
    let service = service
    loadGeneration &+= 1
    let generation = loadGeneration
    if !replacing {
      loadMoreError = nil
      isLoadingMore = true
    }
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.threads(
          forumName: forumName,
          page: page,
          pageSize: 30
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        currentPage = response.currentPage
        hasMore = response.hasMore
        threads = replacing ? response.threads : merge(threads, response.threads)
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if replacing {
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
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
