import Combine
import Foundation

@MainActor
final class HotTopicListViewModel: ObservableObject {
  @Published private(set) var topics: [HotTopicItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var refreshError: String?

  private let service: any HotTopicService
  private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(service: any HotTopicService) {
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    restart(preservingResults: false)
  }

  func retry() {
    restart(preservingResults: false)
  }

  func refresh() async {
    restart(preservingResults: !topics.isEmpty)
    await loadTask?.value
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func cancel() {
    invalidateLoad()
    if state == .loading {
      state = topics.isEmpty ? .idle : .loaded
    }
  }

  private func restart(preservingResults: Bool) {
    invalidateLoad()
    if !preservingResults {
      topics = []
    }
    refreshError = nil
    state = .loading
    generation &+= 1
    let requestGeneration = generation
    let service = service
    loadTask = Task {
      defer {
        if generation == requestGeneration {
          loadTask = nil
        }
      }
      do {
        let response = try await service.hotTopics()
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        topics = unique(response)
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        if preservingResults && !topics.isEmpty {
          refreshError = error.localizedDescription
          state = .loaded
        } else {
          state = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func invalidateLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func unique(_ items: [HotTopicItem]) -> [HotTopicItem] {
    var seen = Set<Int64>()
    return items.filter { seen.insert($0.id).inserted }
  }
}
