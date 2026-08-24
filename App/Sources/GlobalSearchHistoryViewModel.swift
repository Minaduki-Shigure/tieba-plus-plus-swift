import Combine
import Foundation

@MainActor
final class GlobalSearchHistoryViewModel: ObservableObject {
  @Published private(set) var entries: [GlobalSearchHistoryEntry] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let repository: any GlobalSearchHistoryRepository
  private var initialLoadTask: Task<Void, Never>?
  private var recordTask: Task<Void, Never>?
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

    let task = Task { [weak self] in
      guard let self else { return }
      await self.reload()
    }
    initialLoadTask = task
    await task.value
    initialLoadTask = nil
  }

  func record(_ rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let queryKey = GlobalSearchHistoryEntry.normalizedIdentityComponent(query)
    guard !queryKey.isEmpty, queryKey.count <= 100 else { return }

    let previousTask = recordTask
    let repository = repository
    let timestamp = nextRecordTimestamp()
    recordTask = Task { [weak self] in
      await previousTask?.value
      do {
        try await repository.record(query: query, at: timestamp)
        await self?.reload()
      } catch is CancellationError {
        return
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func delete(id: String) async {
    await recordTask?.value
    do {
      try await repository.delete(id: id)
      entries.removeAll { $0.id == id }
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteAll() async {
    await recordTask?.value
    do {
      try await repository.deleteAll()
      entries = []
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func retry() async {
    await recordTask?.value
    await reload()
  }

  func reset() async {
    await recordTask?.value
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
