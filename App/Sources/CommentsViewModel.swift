import Combine
import Foundation

@MainActor
final class CommentsViewModel: ObservableObject {
  @Published private(set) var comments: [BrowseComment] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false

  let threadID: Int64
  let postID: Int64

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?

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
    loadTask?.cancel()
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    comments = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func loadMoreIfNeeded(current comment: BrowseComment) {
    guard comment.id == comments.last?.id, hasMore, !isLoadingMore, state == .loaded else {
      return
    }
    isLoadingMore = true
    load(page: currentPage + 1, replacing: false)
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
      state = comments.isEmpty ? .idle : .loaded
    }
  }

  private func load(page: Int, replacing: Bool) {
    let service = service
    let threadID = threadID
    let postID = postID
    loadTask = Task {
      do {
        let response = try await service.comments(
          threadID: threadID,
          postID: postID,
          page: page
        )
        try Task.checkCancellation()
        currentPage = response.currentPage
        hasMore = response.hasMore
        comments = replacing ? response.comments : merge(comments, response.comments)
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

  private func merge(_ existing: [BrowseComment], _ newItems: [BrowseComment]) -> [BrowseComment] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
