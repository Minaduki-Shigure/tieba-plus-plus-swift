import Foundation
import Security

enum AccountVaultError: LocalizedError, Sendable, Equatable {
  case invalidArchive
  case futureArchive
  case archiveTooLarge
  case tooManyAccounts
  case accountNotFound
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidArchive:
      "账户数据已损坏，未进行覆盖。"
    case .futureArchive:
      "账户数据来自更新版本，当前版本不会修改它。"
    case .archiveTooLarge:
      "账户数据超过安全大小限制。"
    case .tooManyAccounts:
      "最多可以保存 8 个账户。"
    case .accountNotFound:
      "没有找到该账户。"
    case .keychain:
      "无法访问系统钥匙串。"
    }
  }
}

protocol AccountVaultBackend: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
  func delete() throws
}

struct SystemKeychainAccountVaultBackend: AccountVaultBackend, @unchecked Sendable {
  private let service: String
  private let account: String

  init(
    service: String = "io.github.minaduki.tieba-plus-plus.account-vault",
    account: String = "accounts"
  ) {
    self.service = service
    self.account = account
  }

  func read() throws -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw AccountVaultError.invalidArchive
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw AccountVaultError.keychain(status)
    }
  }

  func write(_ data: Data) throws {
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var attributes = baseQuery
      attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      attributes[kSecAttrLabel as String] = "Tieba++ accounts"
      let addStatus = SecItemAdd(attributes as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw AccountVaultError.keychain(addStatus)
      }
    default:
      throw AccountVaultError.keychain(updateStatus)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AccountVaultError.keychain(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}

actor KeychainAccountVault: AccountVault {
  static let maximumArchiveBytes = 64 * 1_024
  static let maximumAccounts = 8

  private let backend: any AccountVaultBackend
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(backend: any AccountVaultBackend = SystemKeychainAccountVaultBackend()) {
    self.backend = backend
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  func accountSummaries() throws -> [AccountSummary] {
    let archive = try loadArchive()
    return archive.accounts
      .sorted { $0.updatedAt > $1.updatedAt }
      .map { session in
        AccountSummary(
          id: session.id,
          username: session.username,
          displayName: session.displayName,
          portraitURL: SecureTiebaURL.portrait(session.portrait),
          isActive: session.id == archive.activeUserID,
          updatedAt: session.updatedAt
        )
      }
  }

  func activeSession() throws -> StoredAccountSession? {
    let archive = try loadArchive()
    guard let activeUserID = archive.activeUserID else { return nil }
    return archive.accounts.first { $0.id == activeUserID }
  }

  func upsert(_ session: StoredAccountSession) throws {
    try Task.checkCancellation()
    try validate(session)
    var archive = try loadArchive()
    if let index = archive.accounts.firstIndex(where: { $0.id == session.id }) {
      let current = archive.accounts[index]
      let mergedSession = StoredAccountSession(
        id: session.id,
        username: session.username,
        displayName: session.displayName,
        portrait: session.portrait,
        bduss: session.bduss,
        createdAt: current.createdAt,
        updatedAt: max(current.updatedAt, session.updatedAt)
      )
      try validate(mergedSession)
      archive.accounts[index] = mergedSession
    } else {
      guard archive.accounts.count < Self.maximumAccounts else {
        throw AccountVaultError.tooManyAccounts
      }
      archive.accounts.append(session)
    }
    archive.activeUserID = session.id
    try save(archive)
  }

  func switchActive(to userID: Int64) throws {
    var archive = try loadArchive()
    guard archive.accounts.contains(where: { $0.id == userID }) else {
      throw AccountVaultError.accountNotFound
    }
    archive.activeUserID = userID
    try save(archive)
  }

  func remove(userID: Int64) throws {
    var archive = try loadArchive()
    let previousCount = archive.accounts.count
    archive.accounts.removeAll { $0.id == userID }
    guard archive.accounts.count != previousCount else {
      throw AccountVaultError.accountNotFound
    }
    if archive.activeUserID == userID {
      archive.activeUserID = archive.accounts.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }
    if archive.accounts.isEmpty {
      try backend.delete()
    } else {
      try save(archive)
    }
  }

  func removeAll() throws {
    try backend.delete()
  }

  private func loadArchive() throws -> AccountVaultArchive {
    guard let data = try backend.read() else { return AccountVaultArchive() }
    guard data.count <= Self.maximumArchiveBytes else {
      throw AccountVaultError.archiveTooLarge
    }
    let archive: AccountVaultArchive
    do {
      archive = try decoder.decode(AccountVaultArchive.self, from: data)
    } catch {
      throw AccountVaultError.invalidArchive
    }
    guard archive.version == AccountVaultArchive.currentVersion else {
      throw AccountVaultError.futureArchive
    }
    guard archive.accounts.count <= Self.maximumAccounts else {
      throw AccountVaultError.tooManyAccounts
    }
    var seen = Set<Int64>()
    guard archive.accounts.allSatisfy({ session in
      seen.insert(session.id).inserted && isValid(session)
    }) else {
      throw AccountVaultError.invalidArchive
    }
    if let activeUserID = archive.activeUserID,
      !archive.accounts.contains(where: { $0.id == activeUserID })
    {
      throw AccountVaultError.invalidArchive
    }
    return archive
  }

  private func save(_ archive: AccountVaultArchive) throws {
    let data: Data
    do {
      data = try encoder.encode(archive)
    } catch {
      throw AccountVaultError.invalidArchive
    }
    guard data.count <= Self.maximumArchiveBytes else {
      throw AccountVaultError.archiveTooLarge
    }
    try backend.write(data)
  }

  private func validate(_ session: StoredAccountSession) throws {
    guard isValid(session) else { throw AccountVaultError.invalidArchive }
  }

  private func isValid(_ session: StoredAccountSession) -> Bool {
    session.id > 0
      && !session.username.contains(where: { $0.isNewline })
      && !session.displayName.contains(where: { $0.isNewline })
      && session.bduss.count == 192
      && session.bduss.allSatisfy { $0.isASCII && !$0.isWhitespace }
      && session.createdAt <= session.updatedAt
  }
}

private struct AccountVaultArchive: Codable {
  static let currentVersion = 1

  var version = currentVersion
  var activeUserID: Int64?
  var accounts: [StoredAccountSession] = []
}
