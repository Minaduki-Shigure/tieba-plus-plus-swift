import Combine
import Foundation

@MainActor
final class ThreadViewModel: ObservableObject {
  @Published private(set) var thread: BrowseThread
  @Published private(set) var posts: [BrowsePost] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var options = ThreadBrowseOptions()

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(
    thread: BrowseThread,
    service: any BrowseService,
    options: ThreadBrowseOptions = ThreadBrowseOptions()
  ) {
    self.thread = thread
    self.service = service
    self.options = options
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
    posts = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func setSort(_ sort: ThreadPostSort) {
    guard options.sort != sort else { return }
    options.sort = sort
    reload()
  }

  func setOnlyThreadAuthor(_ onlyThreadAuthor: Bool) {
    guard options.onlyThreadAuthor != onlyThreadAuthor else { return }
    options.onlyThreadAuthor = onlyThreadAuthor
    reload()
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    if state == .loading {
      state = posts.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current post: BrowsePost) {
    guard
      post.id == posts.last?.id,
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
    let threadID = thread.id
    let service = service
    let options = options
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
        let response = try await service.posts(
          threadID: threadID,
          page: page,
          pageSize: 30,
          options: options
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        thread = response.thread
        currentPage = response.currentPage
        hasMore = response.hasMore
        posts = replacing ? response.posts : merge(posts, response.posts)
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

  private func merge(_ existing: [BrowsePost], _ newItems: [BrowsePost]) -> [BrowsePost] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
