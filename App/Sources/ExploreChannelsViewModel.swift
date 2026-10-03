import Combine
import Foundation

@MainActor
final class ExploreChannelsViewModel: ObservableObject {
  @Published private(set) var visibleSections = ExploreSection.available(hasActiveAccount: false)
  @Published private(set) var hasResolvedInitialSession = false

  private let vault: any AccountVault
  private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(vault: any AccountVault) {
    self.vault = vault
  }

  func reload() {
    generation &+= 1
    loadTask?.cancel()
    let requestGeneration = generation
    let vault = vault
    loadTask = Task {
      defer {
        if requestGeneration == generation { loadTask = nil }
      }
      let hasActiveAccount: Bool
      do {
        hasActiveAccount = try await vault.activeSession() != nil
      } catch is CancellationError {
        return
      } catch {
        hasActiveAccount = false
      }
      guard requestGeneration == generation, !Task.isCancelled else { return }
      visibleSections = ExploreSection.available(hasActiveAccount: hasActiveAccount)
      hasResolvedInitialSession = true
    }
  }

  func cancel() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }
}
