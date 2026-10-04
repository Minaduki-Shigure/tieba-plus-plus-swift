import Combine
import Foundation

@MainActor
final class GlobalSearchHistoryViewModel: ObservableObject {
  @Published private(set) var entries: [GlobalSearchHistoryEntry] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let repository: any GlobalSearchHistoryRepository
  private let operations = SearchHistoryOperationQueue()
  private var initialLoadTask: Task<Void, Never>?
  private var hasLoaded = false
  private var lastRecordTimestamp: Date?

  init(repository: any GlobalSearchHistoryRepository) {
    self.repository = repository
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    if let initialLoadTask {
      await initialLoadTask.value
      return
    }

    let task = operations.enqueue { [self] in
      defer { initialLoadTask = nil }
      // A previously queued record or reset may have already loaded the owner.
      guard !hasLoaded else { return }
      await self.reload()
    }
    initialLoadTask = task
    await task.value
  }

  func record(_ rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let queryKey = GlobalSearchHistoryEntry.normalizedIdentityComponent(query)
    guard !queryKey.isEmpty, queryKey.count <= 100 else { return }

    let repository = repository
    let timestamp = nextRecordTimestamp()
    operations.enqueue { [self] in
      do {
        try await repository.record(query: query, at: timestamp)
        await reload()
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func delete(id: String) async {
    await operations.enqueue { [self] in
      do {
        try await repository.delete(id: id)
        entries.removeAll { $0.id == id }
        errorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }.value
  }

  func deleteAll() async {
    await operations.enqueue { [self] in
      do {
        try await repository.deleteAll()
        entries = []
        errorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }.value
  }

  func retry() async {
    await operations.enqueue { [self] in await reload() }.value
  }

  func reset() async {
    await operations.enqueue { [self] in
      do {
        try await repository.reset()
        entries = []
        hasLoaded = true
        errorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }.value
  }

  private func reload() async {
    isLoading = true
    defer { isLoading = false }
    do {
      entries = try await repository.entries()
      hasLoaded = true
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func nextRecordTimestamp() -> Date {
    let now = Date()
    let timestamp: Date
    if let lastRecordTimestamp,
      now.timeIntervalSince(lastRecordTimestamp) < 0.001
    {
      timestamp = lastRecordTimestamp.addingTimeInterval(0.001)
    } else {
      timestamp = now
    }
    lastRecordTimestamp = timestamp
    return timestamp
  }
}
