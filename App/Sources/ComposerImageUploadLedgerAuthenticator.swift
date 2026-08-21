import CryptoKit
import Foundation
import Security

enum ComposerImageUploadLedgerAuthenticationError: LocalizedError, Sendable, Equatable {
  case unavailable
  case invalidKey

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "无法访问图片上传恢复记录的设备密钥。"
    case .invalidKey:
      "图片上传恢复记录的设备密钥无效。"
    }
  }
}

protocol ComposerImageUploadLedgerAuthenticating: Sendable {
  func authenticationCode(for canonicalPayload: Data) throws -> Data
  func isValidAuthenticationCode(_ authenticationCode: Data, for canonicalPayload: Data) throws
    -> Bool
}

protocol ComposerImageUploadLedgerKeyStoring: Sendable {
  func existingKey() throws -> Data?
  func existingOrNewKey() throws -> Data
}

struct SystemComposerImageUploadLedgerKeyStore:
  ComposerImageUploadLedgerKeyStoring, @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  static let keyByteCount = 32

  private let service: String
  private let account: String

  init(
    service: String = "io.github.minaduki.tieba-plus-plus.image-upload-ledger",
    account: String = "hmac-sha256-v1"
  ) {
    self.service = service
    self.account = account
  }

  var description: String { "SystemComposerImageUploadLedgerKeyStore(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  func existingKey() throws -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard
        let key = result as? Data,
        key.count == Self.keyByteCount
      else { throw ComposerImageUploadLedgerAuthenticationError.invalidKey }
      return key
    case errSecItemNotFound:
      return nil
    default:
      throw ComposerImageUploadLedgerAuthenticationError.unavailable
    }
  }

  func existingOrNewKey() throws -> Data {
    if let key = try existingKey() { return key }

    var candidate = Data(count: Self.keyByteCount)
    let randomStatus: OSStatus = candidate.withUnsafeMutableBytes {
      (buffer: UnsafeMutableRawBufferPointer) in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw ComposerImageUploadLedgerAuthenticationError.unavailable
    }
    var attributes = baseQuery
    attributes[kSecValueData as String] = candidate
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    attributes[kSecAttrLabel as String] = "Tieba++ image upload recovery key"
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    switch addStatus {
    case errSecSuccess:
      return candidate
    case errSecDuplicateItem:
      guard let racedKey = try existingKey() else {
        throw ComposerImageUploadLedgerAuthenticationError.unavailable
      }
      return racedKey
    default:
      throw ComposerImageUploadLedgerAuthenticationError.unavailable
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

struct ComposerImageUploadLedgerHMACAuthenticator:
  ComposerImageUploadLedgerAuthenticating, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  // This authenticates archive bytes; it does not provide a monotonic freshness anchor.
  private enum KeySource: Sendable {
    case keyStore(any ComposerImageUploadLedgerKeyStoring)
    case fixed(Data)
  }

  private static let domain = Data("TiebaPlusPlus/ComposerImageUploadLedger/HMAC-SHA256/v1\0".utf8)
  private let keySource: KeySource

  init(
    keyStore: any ComposerImageUploadLedgerKeyStoring =
      SystemComposerImageUploadLedgerKeyStore()
  ) {
    self.keySource = .keyStore(keyStore)
  }

  init(testingKey: Data) {
    self.keySource = .fixed(testingKey)
  }

  var description: String { "ComposerImageUploadLedgerHMACAuthenticator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  func authenticationCode(for canonicalPayload: Data) throws -> Data {
    let key = try signingKey()
    return Data(
      HMAC<SHA256>.authenticationCode(
        for: Self.domainSeparated(canonicalPayload),
        using: SymmetricKey(data: key)
      )
    )
  }

  func isValidAuthenticationCode(
    _ authenticationCode: Data,
    for canonicalPayload: Data
  ) throws -> Bool {
    guard authenticationCode.count == SystemComposerImageUploadLedgerKeyStore.keyByteCount else {
      return false
    }
    let key = try verificationKey()
    return HMAC<SHA256>.isValidAuthenticationCode(
      authenticationCode,
      authenticating: Self.domainSeparated(canonicalPayload),
      using: SymmetricKey(data: key)
    )
  }

  private func signingKey() throws -> Data {
    let key: Data
    switch keySource {
    case .keyStore(let keyStore):
      key = try keyStore.existingOrNewKey()
    case .fixed(let fixed):
      key = fixed
    }
    guard key.count == SystemComposerImageUploadLedgerKeyStore.keyByteCount else {
      throw ComposerImageUploadLedgerAuthenticationError.invalidKey
    }
    return key
  }

  private func verificationKey() throws -> Data {
    let key: Data?
    switch keySource {
    case .keyStore(let keyStore):
      key = try keyStore.existingKey()
    case .fixed(let fixed):
      key = fixed
    }
    guard
      let key,
      key.count == SystemComposerImageUploadLedgerKeyStore.keyByteCount
    else { throw ComposerImageUploadLedgerAuthenticationError.invalidKey }
    return key
  }

  private static func domainSeparated(_ canonicalPayload: Data) -> Data {
    var authenticated = domain
    var payloadByteCount = UInt64(canonicalPayload.count).bigEndian
    withUnsafeBytes(of: &payloadByteCount) { authenticated.append(contentsOf: $0) }
    authenticated.append(canonicalPayload)
    return authenticated
  }
}
