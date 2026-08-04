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
  private let makeSessionRevision: @Sendable () -> UUID

  init(
    backend: any AccountVaultBackend = SystemKeychainAccountVaultBackend(),
    sessionRevisionGenerator: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.backend = backend
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.makeSessionRevision = sessionRevisionGenerator
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
          hasFullCredentials: session.credentials != nil,
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
        stoken: session.stoken,
        bdussCookieName: session.bdussCookieName,
        createdAt: current.createdAt,
        updatedAt: max(current.updatedAt, session.updatedAt),
        sessionRevision: nextSessionRevision(replacing: current.sessionRevision)
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
    let version: Int
    do {
      version = try decoder.decode(AccountVaultArchiveHeader.self, from: data).version
    } catch {
      throw AccountVaultError.invalidArchive
    }

    if version > AccountVaultArchive.currentVersion {
      throw AccountVaultError.futureArchive
    }

    let archive: AccountVaultArchive
    switch version {
    case AccountVaultArchive.currentVersion:
      do {
        archive = try decoder.decode(AccountVaultArchive.self, from: data)
      } catch {
        throw AccountVaultError.invalidArchive
      }
    case AccountVaultArchiveV2.supportedVersion:
      let legacyArchive: AccountVaultArchiveV2
      do {
        legacyArchive = try decoder.decode(AccountVaultArchiveV2.self, from: data)
      } catch {
        throw AccountVaultError.invalidArchive
      }
      try validate(legacyArchive)
      archive = AccountVaultArchive(
        activeUserID: legacyArchive.activeUserID,
        accounts: legacyArchive.accounts.map { $0.migrated() }
      )
      try validate(archive)
      try save(archive)
      return archive
    case AccountVaultArchiveV1.supportedVersion:
      let legacyArchive: AccountVaultArchiveV1
      do {
        legacyArchive = try decoder.decode(AccountVaultArchiveV1.self, from: data)
      } catch {
        throw AccountVaultError.invalidArchive
      }
      try validate(legacyArchive)
      archive = AccountVaultArchive(
        activeUserID: legacyArchive.activeUserID,
        accounts: legacyArchive.accounts.map {
          $0.migrated(sessionRevision: makeSessionRevision())
        }
      )
      try validate(archive)
      try save(archive)
      return archive
    default:
      throw AccountVaultError.invalidArchive
    }

    try validate(archive)
    return archive
  }

  private func validate(_ archive: AccountVaultArchive) throws {
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
  }

  private func validate(_ archive: AccountVaultArchiveV2) throws {
    try validateLegacyArchive(
      activeUserID: archive.activeUserID,
      accounts: archive.accounts.map {
        ($0.id, $0.username, $0.displayName, $0.bduss, $0.createdAt, $0.updatedAt)
      }
    )
  }

  private func validate(_ archive: AccountVaultArchiveV1) throws {
    try validateLegacyArchive(
      activeUserID: archive.activeUserID,
      accounts: archive.accounts.map {
        ($0.id, $0.username, $0.displayName, $0.bduss, $0.createdAt, $0.updatedAt)
      }
    )
  }

  private func validateLegacyArchive(
    activeUserID: Int64?,
    accounts: [
      (
        id: Int64, username: String, displayName: String, bduss: String,
        createdAt: Date, updatedAt: Date
      )
    ]
  ) throws {
    guard accounts.count <= Self.maximumAccounts else {
      throw AccountVaultError.tooManyAccounts
    }
    var seen = Set<Int64>()
    guard accounts.allSatisfy({ account in
      seen.insert(account.id).inserted
        && account.id > 0
        && !account.username.contains(where: { $0.isNewline })
        && !account.displayName.contains(where: { $0.isNewline })
        && AccountCredentialFormat.isValidBDUSS(account.bduss)
        && account.createdAt <= account.updatedAt
    }) else {
      throw AccountVaultError.invalidArchive
    }
    if let activeUserID, !accounts.contains(where: { $0.id == activeUserID }) {
      throw AccountVaultError.invalidArchive
    }
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

  private func nextSessionRevision(replacing current: UUID) -> UUID {
    let candidate = makeSessionRevision()
    return candidate == current ? UUID() : candidate
  }

  private func isValid(_ session: StoredAccountSession) -> Bool {
    session.id > 0
      && !session.username.contains(where: { $0.isNewline })
      && !session.displayName.contains(where: { $0.isNewline })
      && AccountCredentialFormat.isValidBDUSS(session.bduss)
      && (session.stoken.map { AccountCredentialFormat.isValidSTOKEN($0) } ?? true)
      && (session.stoken != nil || session.bdussCookieName == .bduss)
      && session.createdAt <= session.updatedAt
  }
}

private struct AccountVaultArchive: Codable {
  static let currentVersion = 3

  var version = currentVersion
  var activeUserID: Int64?
  var accounts: [StoredAccountSession] = []

  init(activeUserID: Int64? = nil, accounts: [StoredAccountSession] = []) {
    self.activeUserID = activeUserID
    self.accounts = accounts
  }
}

private struct AccountVaultArchiveHeader: Decodable {
  let version: Int
}

private struct AccountVaultArchiveV2: Decodable {
  static let supportedVersion = 2

  let activeUserID: Int64?
  let accounts: [StoredAccountSessionV2]

  private enum CodingKeys: CodingKey {
    case version
    case activeUserID
    case accounts
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.supportedVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Unexpected account archive version."
      )
    }
    activeUserID = try container.decodeIfPresent(Int64.self, forKey: .activeUserID)
    accounts = try container.decode([StoredAccountSessionV2].self, forKey: .accounts)
  }
}

private struct StoredAccountSessionV2: Decodable {
  let id: Int64
  let username: String
  let displayName: String
  let portrait: String
  let bduss: String
  let createdAt: Date
  let updatedAt: Date
  let sessionRevision: UUID

  func migrated() -> StoredAccountSession {
    StoredAccountSession(
      id: id,
      username: username,
      displayName: displayName,
      portrait: portrait,
      bduss: bduss,
      stoken: nil,
      bdussCookieName: .bduss,
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionRevision: sessionRevision
    )
  }
}

private struct AccountVaultArchiveV1: Decodable {
  static let supportedVersion = 1

  let activeUserID: Int64?
  let accounts: [StoredAccountSessionV1]

  private enum CodingKeys: CodingKey {
    case version
    case activeUserID
    case accounts
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.supportedVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Unexpected account archive version."
      )
    }
    activeUserID = try container.decodeIfPresent(Int64.self, forKey: .activeUserID)
    accounts = try container.decode([StoredAccountSessionV1].self, forKey: .accounts)
  }
}

private struct StoredAccountSessionV1: Decodable {
  let id: Int64
  let username: String
  let displayName: String
  let portrait: String
  let bduss: String
  let createdAt: Date
  let updatedAt: Date

  func migrated(sessionRevision: UUID) -> StoredAccountSession {
    StoredAccountSession(
      id: id,
      username: username,
      displayName: displayName,
      portrait: portrait,
      bduss: bduss,
      stoken: nil,
      bdussCookieName: .bduss,
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionRevision: sessionRevision
    )
  }
}
