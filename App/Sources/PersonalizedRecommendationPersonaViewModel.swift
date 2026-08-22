import Combine
import Foundation

@MainActor
final class PersonalizedRecommendationPersonaViewModel: ObservableObject {
  @Published private(set) var accounts: [AccountSummary] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var selection: PersonalizedRecommendationPersona

  private let vault: any AccountVault
  private let defaults: UserDefaults
  private var generation = 0

  init(
    vault: any AccountVault,
    defaults: UserDefaults = .standard
  ) {
    self.vault = vault
    self.defaults = defaults
    selection = PersonalizedRecommendationPersona.current(defaults: defaults)
  }

  var selectedAccount: AccountSummary? {
    guard let userID = selection.accountUserID else { return nil }
    return accounts.first { $0.id == userID }
  }

  var title: String {
    switch selection {
    case .anonymous:
      "匿名推荐"
    case .account(let userID):
      selectedAccount?.preferredName ?? "用户 \(userID)"
    }
  }

  func loadIfNeeded() async {
    guard state == .idle else { return }
    await reload()
  }

  func reload() async {
    generation &+= 1
    let requestGeneration = generation
    state = .loading
    do {
      let summaries = try await vault.accountSummaries()
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      accounts = summaries
      if let selectedUserID = selection.accountUserID,
        !summaries.contains(where: { $0.id == selectedUserID })
      {
        setSelection(.anonymous)
      }
      state = .loaded
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      state = accounts.isEmpty ? .idle : .loaded
    } catch {
      guard requestGeneration == generation else { return }
      state = .failed(error.localizedDescription)
    }
  }

  func select(_ persona: PersonalizedRecommendationPersona) {
    switch persona {
    case .anonymous:
      break
    case .account(let userID):
      guard userID > 0, accounts.contains(where: { $0.id == userID }) else { return }
    }
    setSelection(persona)
  }

  private func setSelection(_ persona: PersonalizedRecommendationPersona) {
    guard selection != persona else { return }
    selection = persona
    persona.persist(defaults: defaults)
  }
}

@MainActor
final class PersonalizedFollowedForumIndexViewModel: ObservableObject {
  static let maximumPageCount = 100
  static let maximumForumCount = 5_000

  @Published private(set) var state: FollowedForumIndexState = .idle

  private let service: any AccountService
  private let vault: any AccountVault
  private let lookup: any AccountSessionLookup
  private var persona: PersonalizedRecommendationPersona = .anonymous
  private var generation = 0
  private var loadTask: Task<Void, Never>?

  init(
    service: any AccountService,
    vault: any AccountVault,
    lookup: any AccountSessionLookup
  ) {
    self.service = service
    self.vault = vault
    self.lookup = lookup
  }

  func setPersona(_ persona: PersonalizedRecommendationPersona, loadIfNeeded: Bool) {
    if self.persona != persona {
      self.persona = persona
      reset()
    }
    if loadIfNeeded, state == .idle {
      load()
    }
  }

  func retry() {
    load()
  }

  func accountDataDidChange(loadIfNeeded: Bool) {
    reset()
    if loadIfNeeded { load() }
  }

  func cancel() {
    invalidate()
    if state == .loading { state = .idle }
  }

  private func load() {
    invalidate()
    state = .loading
    let requestGeneration = generation
    let requestPersona = persona
    let service = service
    let vault = vault
    let lookup = lookup
    loadTask = Task {
      defer {
        if generation == requestGeneration { loadTask = nil }
      }
      do {
        guard
          let session = try await Self.session(
            for: requestPersona,
            vault: vault,
            lookup: lookup
          )
        else {
          guard generation == requestGeneration else { return }
          state = .signedOut
          return
        }
        try Task.checkCancellation()
        guard generation == requestGeneration, persona == requestPersona else { return }
        let lease = FollowedForumsSessionLease(session)
        var page = 1
        var forums = [FollowedForumItem]()
        var seen = Set<Int64>()

        while true {
          let response = try await service.followedForums(
            session: session,
            page: page,
            pageSize: 50
          )
          try Task.checkCancellation()
          guard generation == requestGeneration, persona == requestPersona else { return }
          guard
            let currentSession = try await Self.session(
              for: requestPersona,
              vault: vault,
              lookup: lookup
            ),
            generation == requestGeneration,
            persona == requestPersona,
            lease.matches(currentSession)
          else {
            throw BrowseError.unavailable("推荐个性对应的账户已变化，请重新加载。")
          }
          guard
            response.currentPage == page,
            response.forums.count <= 100,
            response.forums.allSatisfy({
              $0.id > 0
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
          else {
            throw BrowseError.unavailable("贴吧返回了异常的关注贴吧数据，请重新加载后再试。")
          }

          let additions = response.forums.filter { seen.insert($0.id).inserted }
          forums.append(contentsOf: additions)
          guard forums.count <= Self.maximumForumCount else {
            throw BrowseError.unavailable("关注贴吧数量超过当前安全读取上限，请稍后重新加载。")
          }
          guard response.hasMore else {
            state = .ready(
              FollowedForumIndexSnapshot(lease: lease, forumIDs: Set(forums.map(\.id)))
            )
            return
          }
          guard !response.forums.isEmpty, !additions.isEmpty, page < Self.maximumPageCount else {
            throw BrowseError.unavailable("关注贴吧分页未取得进展，请重新加载后再试。")
          }
          page += 1
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func reset() {
    invalidate()
    state = .idle
  }

  private func invalidate() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private nonisolated static func session(
    for persona: PersonalizedRecommendationPersona,
    vault: any AccountVault,
    lookup: any AccountSessionLookup
  ) async throws -> StoredAccountSession? {
    switch persona {
    case .anonymous:
      try await vault.activeSession()
    case .account(let userID):
      try await lookup.session(userID: userID)
    }
  }
}
