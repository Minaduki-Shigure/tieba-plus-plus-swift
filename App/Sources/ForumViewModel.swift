import Combine
import Foundation

@MainActor
final class ForumViewModel: ObservableObject {
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false

  let forumName: String

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?

  init(forumName: String, service: any BrowseService) {
    self.forumName = forumName
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    loadTask?.cancel()
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    threads = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    isLoadingMore = false
    if state == .loading {
      state = threads.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard thread.id == threads.last?.id, hasMore, !isLoadingMore, state == .loaded else {
      return
    }
    isLoadingMore = true
    load(page: currentPage + 1, replacing: false)
  }

  private func load(page: Int, replacing: Bool) {
    let forumName = forumName
    let service = service
    loadTask = Task {
      do {
        let response = try await service.threads(
          forumName: forumName,
          page: page,
          pageSize: 30
        )
        try Task.checkCancellation()
        currentPage = response.currentPage
        hasMore = response.hasMore
        threads = replacing ? response.threads : merge(threads, response.threads)
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        if replacing {
          state = .failed(error.localizedDescription)
        }
      }
      isLoadingMore = false
    }
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
