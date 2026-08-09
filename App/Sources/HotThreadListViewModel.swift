import Combine
import Foundation

@MainActor
final class HotThreadListViewModel: ObservableObject {
  @Published private(set) var categories: [HotThreadCategory] = [.all]
  @Published private(set) var selectedCategory: HotThreadCategory = .all
  @Published private(set) var topics: [HotTopicItem] = []
  @Published private(set) var items: [HotThreadRankItem] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var hasLoadedInitialSnapshot = false
  @Published private(set) var refreshError: String?

  private static let maximumServerCategories = 20
  private static let maximumTopics = 20
  private static let maximumItems = 100
  private static let maximumCategoryCodeCharacters = 64
  private static let maximumCategoryTitleCharacters = 40

  private let service: any HotThreadService
  private var loadTask: Task<Void, Never>?
  private var activeRequestKind: RequestKind?
  private var generation = 0

  init(service: any HotThreadService) {
    self.service = service
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    startRequest(kind: .replacement)
  }

  func retry() {
    startRequest(kind: .replacement)
  }

  func reloadForContentFilterChange() {
    guard hasLoadedInitialSnapshot else { return }
    startRequest(kind: .replacement)
  }

  func selectCategory(_ category: HotThreadCategory) {
    guard let advertised = categories.first(where: { $0.code == category.code }) else { return }
    guard advertised.code != selectedCategory.code else { return }
    selectedCategory = advertised
    startRequest(kind: .replacement)
  }

  func refresh() async {
    guard hasLoadedInitialSnapshot, state == .loaded else { return }
    startRequest(kind: .refresh)
    await loadTask?.value
  }

  func clearRefreshError() {
    refreshError = nil
  }

  func cancel() {
    let canPreserveSnapshot =
      activeRequestKind == .refresh
      && hasLoadedInitialSnapshot
      && (!topics.isEmpty || !items.isEmpty)
    invalidateCurrentLoad()
    if state == .loading {
      state = canPreserveSnapshot ? .loaded : .idle
    }
  }

  private func startRequest(kind: RequestKind) {
    invalidateCurrentLoad()
    activeRequestKind = kind
    if kind == .replacement {
      items = []
    }
    refreshError = nil
    state = .loading

    let requestedCategoryCode = selectedCategory.code
    let requestGeneration = generation
    let service = service
    loadTask = Task {
      defer { finishRequest(generation: requestGeneration) }
      do {
        let response = try await service.hotThreads(categoryCode: requestedCategoryCode)
        try Task.checkCancellation()
        guard
          generation == requestGeneration,
          selectedCategory.code == requestedCategoryCode
        else { return }

        if requestedCategoryCode == HotThreadCategory.all.code {
          topics = uniqueTopics(response.topics)
          categories = normalizedCategories(response.categories)
          selectedCategory = .all
        }
        items = uniqueItems(response.items)
        hasLoadedInitialSnapshot = true
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        if kind == .refresh {
          refreshError = error.localizedDescription
          state = .loaded
        } else {
          state = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func normalizedCategories(
    _ serverCategories: [HotThreadCategory]
  ) -> [HotThreadCategory] {
    var seen = Set([HotThreadCategory.all.code])
    var result: [HotThreadCategory] = [.all]
    result.reserveCapacity(min(serverCategories.count + 1, Self.maximumServerCategories + 1))

    for category in serverCategories {
      guard result.count <= Self.maximumServerCategories else { break }
      let code = category.code
      let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !trimmedCode.isEmpty,
        code == trimmedCode,
        code.count <= Self.maximumCategoryCodeCharacters,
        !code.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        }),
        seen.insert(code).inserted
      else { continue }

      let title = category.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { continue }
      result.append(
        HotThreadCategory(
          serverID: category.serverID,
          code: code,
          title: String(title.prefix(Self.maximumCategoryTitleCharacters))
        )
      )
    }
    return result
  }

  private func uniqueItems(_ responseItems: [HotThreadRankItem]) -> [HotThreadRankItem] {
    var seen = Set<Int64>()
    var result: [HotThreadRankItem] = []
    result.reserveCapacity(min(responseItems.count, Self.maximumItems))
    for item in responseItems {
      guard result.count < Self.maximumItems else { break }
      guard item.thread.id > 0, seen.insert(item.thread.id).inserted else { continue }
      result.append(item)
    }
    return result
  }

  private func uniqueTopics(_ responseTopics: [HotTopicItem]) -> [HotTopicItem] {
    var seen = Set<Int64>()
    var result: [HotTopicItem] = []
    result.reserveCapacity(min(responseTopics.count, Self.maximumTopics))
    for topic in responseTopics {
      guard result.count < Self.maximumTopics else { break }
      guard topic.id > 0, seen.insert(topic.id).inserted else { continue }
      result.append(topic)
    }
    return result
  }

  private func finishRequest(generation requestGeneration: Int) {
    guard generation == requestGeneration else { return }
    loadTask = nil
    activeRequestKind = nil
  }

  private func invalidateCurrentLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    activeRequestKind = nil
  }
}

private enum RequestKind: Equatable, Sendable {
  case replacement
  case refresh
}
