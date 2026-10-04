import Foundation

/// One history owner's reads and accepted local writes run in invocation order.
/// A read's publication is part of its operation, so a late snapshot cannot
/// restore a record after a subsequent deletion has already been published.
@MainActor
final class SearchHistoryOperationQueue {
  private var tail: Task<Void, Never>?
  private var generation = 0

  @discardableResult
  func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let previous = tail
    generation &+= 1
    let current = generation
    let task = Task {
      await previous?.value
      await operation()
      if generation == current { tail = nil }
    }
    tail = task
    return task
  }
}
