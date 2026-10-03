import Combine
import Foundation

/// Pull-to-refresh and a repeated Home tab selection share the whole refresh,
/// including local history reads. Invalidating this waiter does not cancel the
/// account stores' independently owned requests, which other pages may share.
@MainActor
final class HomeRefreshCoordinator: ObservableObject {
  @Published private(set) var isRefreshing = false
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0

  func refresh(operation: @escaping @MainActor () async -> Void) async {
    guard !Task.isCancelled else { return }
    if let task {
      await task.value
      return
    }
    generation &+= 1
    let requestGeneration = generation
    isRefreshing = true
    let shared = Task {
      defer {
        if generation == requestGeneration {
          task = nil
          isRefreshing = false
        }
      }
      guard !Task.isCancelled else { return }
      await operation()
    }
    task = shared
    await shared.value
  }

  func invalidate() {
    generation &+= 1
    task?.cancel()
    task = nil
    isRefreshing = false
  }
}
