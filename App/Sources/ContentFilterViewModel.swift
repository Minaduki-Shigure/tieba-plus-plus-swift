import Combine
import Foundation

@MainActor
final class ContentFilterViewModel: ObservableObject {
  @Published private(set) var snapshot = ContentFilterSnapshot.empty
  @Published private(set) var isLoading = false
  @Published private(set) var loadErrorMessage: String?
  @Published private(set) var operationErrorMessage: String?
  @Published var selectedList = ContentFilterList.block

  private let repository: any ContentFilterRepository
  private var hasLoaded = false
  private var requestGeneration = 0

  init(repository: any ContentFilterRepository) {
    self.repository = repository
  }

  var visibleRules: [ContentFilterRule] {
    snapshot.rules(in: selectedList)
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await reload()
  }

  func reload() async {
    let generation = beginRequest()
    isLoading = true
    defer {
      if generation == requestGeneration {
        isLoading = false
      }
    }
    do {
      let snapshot = try await repository.snapshot()
      guard generation == requestGeneration else { return }
      self.snapshot = snapshot
      hasLoaded = true
      loadErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      loadErrorMessage = error.localizedDescription
    }
  }

  func add(_ rule: ContentFilterRule) async throws {
    try await saveRules {
      _ = try await repository.add(rule)
    }
  }

  func add(_ rules: [ContentFilterRule]) async throws {
    try await saveRules {
      _ = try await repository.add(rules)
    }
  }

  private func saveRules(_ write: () async throws -> Void) async throws {
    let generation = beginRequest()
    // The editor waits for the transaction and keeps its draft on failure.
    try await write()
    let snapshot = try await repository.snapshot()
    guard generation == requestGeneration else { return }
    self.snapshot = snapshot
    hasLoaded = true
    loadErrorMessage = nil
    operationErrorMessage = nil
  }

  func delete(id: UUID) async {
    let generation = beginRequest()
    do {
      try await repository.delete(id: id)
      let snapshot = try await repository.snapshot()
      guard generation == requestGeneration else { return }
      self.snapshot = snapshot
      hasLoaded = true
      loadErrorMessage = nil
      operationErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      operationErrorMessage = error.localizedDescription
    }
  }

  func deleteSelectedList() async {
    let generation = beginRequest()
    do {
      try await repository.deleteAll(in: selectedList)
      let snapshot = try await repository.snapshot()
      guard generation == requestGeneration else { return }
      self.snapshot = snapshot
      hasLoaded = true
      loadErrorMessage = nil
      operationErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      operationErrorMessage = error.localizedDescription
    }
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async {
    guard snapshot.displayMode != mode else { return }
    let generation = beginRequest()
    do {
      try await repository.setDisplayMode(mode)
      let snapshot = try await repository.snapshot()
      guard generation == requestGeneration else { return }
      self.snapshot = snapshot
      hasLoaded = true
      loadErrorMessage = nil
      operationErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      operationErrorMessage = error.localizedDescription
    }
  }

  func setBlockVideos(_ blockVideos: Bool) async {
    guard snapshot.blockVideos != blockVideos else { return }
    let generation = beginRequest()
    do {
      try await repository.setBlockVideos(blockVideos)
      let snapshot = try await repository.snapshot()
      guard generation == requestGeneration else { return }
      self.snapshot = snapshot
      hasLoaded = true
      loadErrorMessage = nil
      operationErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      operationErrorMessage = error.localizedDescription
    }
  }

  func reset() async {
    let generation = beginRequest()
    do {
      try await repository.reset()
      guard generation == requestGeneration else { return }
      snapshot = .empty
      hasLoaded = true
      loadErrorMessage = nil
      operationErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == requestGeneration else { return }
      operationErrorMessage = error.localizedDescription
    }
  }

  func dismissOperationError() {
    operationErrorMessage = nil
  }

  @discardableResult
  private func beginRequest() -> Int {
    requestGeneration &+= 1
    isLoading = false
    return requestGeneration
  }
}
