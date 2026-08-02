import Combine
import Foundation

enum ForumInformationTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case overview
  case rules
  case moderators

  var id: Self { self }

  var title: String {
    switch self {
    case .overview:
      "简介"
    case .rules:
      "吧规"
    case .moderators:
      "吧务"
    }
  }
}

enum ForumInformationResource<Value> {
  case idle
  case loading
  case loaded(Value)
  case failed(String)
}

@MainActor
final class ForumInformationViewModel: ObservableObject {
  @Published private(set) var overview: ForumInformationResource<BrowseForumOverview> = .idle
  @Published private(set) var rules: ForumInformationResource<BrowseForumRules> = .idle
  @Published private(set) var moderatorRoles:
    ForumInformationResource<[BrowseForumModeratorRole]> = .idle

  private let forumID: Int64
  private let service: any ForumInformationService
  private var generations: [ForumInformationTab: Int] = [:]

  init(forumID: Int64, service: any ForumInformationService) {
    self.forumID = forumID
    self.service = service
  }

  func load(_ tab: ForumInformationTab) async {
    guard forumID > 0, shouldLoad(tab) else { return }
    let generation = nextGeneration(for: tab)
    setLoading(tab)

    do {
      switch tab {
      case .overview:
        let value = try await service.forumOverview(forumID: forumID)
        try Task.checkCancellation()
        guard isCurrent(generation, for: tab) else { return }
        overview = .loaded(value)
      case .rules:
        let value = try await service.forumRules(forumID: forumID)
        try Task.checkCancellation()
        guard isCurrent(generation, for: tab) else { return }
        rules = .loaded(value)
      case .moderators:
        let value = try await service.forumModeratorRoles(forumID: forumID)
        try Task.checkCancellation()
        guard isCurrent(generation, for: tab) else { return }
        moderatorRoles = .loaded(value)
      }
    } catch is CancellationError {
      guard isCurrent(generation, for: tab) else { return }
      setIdle(tab)
    } catch {
      guard isCurrent(generation, for: tab), !Task.isCancelled else { return }
      setFailure(error.localizedDescription, for: tab)
    }
  }

  func reload(_ tab: ForumInformationTab) async {
    generations[tab] = (generations[tab] ?? 0) &+ 1
    setIdle(tab)
    await load(tab)
  }

  private func shouldLoad(_ tab: ForumInformationTab) -> Bool {
    switch tab {
    case .overview:
      if case .idle = overview { return true }
      if case .failed = overview { return true }
    case .rules:
      if case .idle = rules { return true }
      if case .failed = rules { return true }
    case .moderators:
      if case .idle = moderatorRoles { return true }
      if case .failed = moderatorRoles { return true }
    }
    return false
  }

  private func nextGeneration(for tab: ForumInformationTab) -> Int {
    let generation = (generations[tab] ?? 0) &+ 1
    generations[tab] = generation
    return generation
  }

  private func isCurrent(_ generation: Int, for tab: ForumInformationTab) -> Bool {
    generations[tab] == generation
  }

  private func setLoading(_ tab: ForumInformationTab) {
    switch tab {
    case .overview:
      overview = .loading
    case .rules:
      rules = .loading
    case .moderators:
      moderatorRoles = .loading
    }
  }

  private func setIdle(_ tab: ForumInformationTab) {
    switch tab {
    case .overview:
      overview = .idle
    case .rules:
      rules = .idle
    case .moderators:
      moderatorRoles = .idle
    }
  }

  private func setFailure(_ message: String, for tab: ForumInformationTab) {
    switch tab {
    case .overview:
      overview = .failed(message)
    case .rules:
      rules = .failed(message)
    case .moderators:
      moderatorRoles = .failed(message)
    }
  }
}
