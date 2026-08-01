import Combine
import Foundation

@MainActor
final class CommentsViewModel: ObservableObject {
  @Published private(set) var comments: [BrowseComment] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?

  let threadID: Int64
  let postID: Int64

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(threadID: Int64, postID: Int64, service: any BrowseService) {
    self.threadID = threadID
    self.postID = postID
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
    comments = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func loadMoreIfNeeded(current comment: BrowseComment) {
    guard
      comment.id == comments.last?.id,
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

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    if state == .loading {
      state = comments.isEmpty ? .idle : .loaded
    }
  }

  private func load(page: Int, replacing: Bool) {
    let service = service
    let threadID = threadID
    let postID = postID
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
        let response = try await service.comments(
          threadID: threadID,
          postID: postID,
          page: page
        )
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        currentPage = response.currentPage
        hasMore = response.hasMore
        comments = replacing ? response.comments : merge(comments, response.comments)
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

  private func merge(_ existing: [BrowseComment], _ newItems: [BrowseComment]) -> [BrowseComment] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
