import Combine
import Foundation

@MainActor
final class AccountViewModel: ObservableObject {
  @Published private(set) var accounts: [AccountSummary] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isMutating = false
  @Published var errorMessage: String?

  private let vault: any AccountVault
  private var generation = 0

  init(vault: any AccountVault) {
    self.vault = vault
  }

  var activeAccount: AccountSummary? {
    accounts.first(where: { $0.isActive })
  }

  var hasLoadFailure: Bool {
    if case .failed = state { return true }
    return false
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
      state = .loaded
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      state = accounts.isEmpty ? .idle : .loaded
    } catch {
      guard requestGeneration == generation else { return }
      state = .failed(error.localizedDescription)
    }
  }

  func switchAccount(to userID: Int64) async {
    await mutate {
      try await vault.switchActive(to: userID)
    }
  }

  func remove(userID: Int64) async {
    await mutate {
      try await vault.remove(userID: userID)
    }
  }

  func removeActiveAccount() async {
    guard let activeAccount else { return }
    await remove(userID: activeAccount.id)
  }

  func resetLocalAccounts() async {
    await mutate {
      try await vault.removeAll()
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func mutate(_ operation: () async throws -> Void) async {
    guard !isMutating else { return }
    generation &+= 1
    let requestGeneration = generation
    isMutating = true
    defer { isMutating = false }
    do {
      try await operation()
      let summaries = try await vault.accountSummaries()
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      accounts = summaries
      state = .loaded
    } catch is CancellationError {
      return
    } catch {
      guard requestGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
final class LoginViewModel: ObservableObject {
  @Published private(set) var isValidating = false
  @Published var errorMessage: String?

  private let service: any AccountService
  private let vault: any AccountVault

  init(service: any AccountService, vault: any AccountVault) {
    self.service = service
    self.vault = vault
  }

  func complete(credentials: AccountCredentials) async -> Bool {
    guard !isValidating else { return false }
    isValidating = true
    defer { isValidating = false }
    do {
      let account = try await service.validate(credential: credentials)
      try Task.checkCancellation()
      let now = Date()
      try await vault.upsert(
        StoredAccountSession(
          id: account.userID,
          username: account.username,
          displayName: account.username,
          portrait: account.portrait,
          bduss: credentials.bduss,
          createdAt: now,
          updatedAt: now
        )
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func reportBlockedNavigation(host: String) {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    errorMessage = host.isEmpty ? "已阻止不安全的登录跳转。" : "已阻止前往 \(host) 的登录跳转。"
  }

  func clearError() {
    errorMessage = nil
  }
}
