import Combine
import Foundation

@MainActor
final class ThreadViewModel: ObservableObject {
  @Published private(set) var thread: BrowseThread
  @Published private(set) var posts: [BrowsePost] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?

  init(thread: BrowseThread, service: any BrowseService) {
    self.thread = thread
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
    posts = []
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
      state = posts.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current post: BrowsePost) {
    guard post.id == posts.last?.id, hasMore, !isLoadingMore, state == .loaded else {
      return
    }
    isLoadingMore = true
    load(page: currentPage + 1, replacing: false)
  }

  private func load(page: Int, replacing: Bool) {
    let threadID = thread.id
    let service = service
    loadTask = Task {
      do {
        let response = try await service.posts(threadID: threadID, page: page, pageSize: 30)
        try Task.checkCancellation()
        thread = response.thread
        currentPage = response.currentPage
        hasMore = response.hasMore
        posts = replacing ? response.posts : merge(posts, response.posts)
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

  private func merge(_ existing: [BrowsePost], _ newItems: [BrowsePost]) -> [BrowsePost] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
