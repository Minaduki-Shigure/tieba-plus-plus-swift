import Combine
import Foundation

@MainActor
final class SearchSuggestionViewModel: ObservableObject {
  @Published private(set) var suggestions: [String] = []

  private let service: any SearchSuggestionService
  private let debounceNanoseconds: UInt64
  private let sleeper: @Sendable (UInt64) async throws -> Void
  private var isEnabled = false
  private var currentQuery: String?
  private var isDebouncePending = false
  private var generation = 0
  private var task: Task<Void, Never>?

  init(
    service: any SearchSuggestionService,
    debounceNanoseconds: UInt64 = 500_000_000,
    sleeper: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.service = service
    self.debounceNanoseconds = debounceNanoseconds
    self.sleeper = sleeper
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if !enabled {
      cancelAndClear()
    }
  }

  func inputChanged(_ rawQuery: String) {
    guard isEnabled else {
      cancelAndClear()
      return
    }

    let query = Self.validatedQuery(rawQuery)
    if query == currentQuery, !isDebouncePending { return }

    let requestGeneration = invalidateRequest()
    currentQuery = query
    suggestions = []
    guard let query else { return }

    let service = service
    let debounceNanoseconds = debounceNanoseconds
    let sleeper = sleeper
    isDebouncePending = debounceNanoseconds > 0
    task = Task { [weak self] in
      do {
        if debounceNanoseconds > 0 {
          try await sleeper(debounceNanoseconds)
        }
        try Task.checkCancellation()
        guard let self, self.isCurrent(requestGeneration, query: query) else { return }
        self.isDebouncePending = false
        let response = try await service.searchSuggestions(query: query)
        try Task.checkCancellation()
        guard self.isCurrent(requestGeneration, query: query) else { return }
        self.suggestions = Self.filtered(response)
        self.finishRequest(requestGeneration)
      } catch is CancellationError {
        self?.finishRequest(requestGeneration)
        return
      } catch {
        guard let self, self.isCurrent(requestGeneration, query: query) else { return }
        self.suggestions = []
        self.finishRequest(requestGeneration)
      }
    }
  }

  func cancelAndClear() {
    _ = invalidateRequest()
    currentQuery = nil
    suggestions = []
  }

  private func invalidateRequest() -> Int {
    task?.cancel()
    task = nil
    isDebouncePending = false
    generation &+= 1
    return generation
  }

  private func isCurrent(_ requestGeneration: Int, query: String) -> Bool {
    isEnabled
      && generation == requestGeneration
      && currentQuery == query
      && !Task.isCancelled
  }

  private func finishRequest(_ requestGeneration: Int) {
    guard generation == requestGeneration else { return }
    task = nil
    isDebouncePending = false
  }

  private static func validatedQuery(_ rawValue: String) -> String? {
    validated(rawValue, minimumCharacterCount: 2)
  }

  private static func validatedSuggestion(_ rawValue: String) -> String? {
    validated(rawValue, minimumCharacterCount: 1)
  }

  private static func validated(_ rawValue: String, minimumCharacterCount: Int) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      (minimumCharacterCount...100).contains(value.count),
      value.utf8.count <= 400,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }

  private static func filtered(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for rawValue in values {
      guard
        let value = validatedSuggestion(rawValue),
        seen.insert(value).inserted
      else { continue }
      result.append(value)
      if result.count == 8 { break }
    }
    return result
  }
}
