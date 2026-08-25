import CryptoKit
import Darwin
import Foundation

enum OwnedContentDeletionLedgerAuthenticationError: Error, Equatable, Sendable {
  case unavailable
  case invalidKey
}

protocol OwnedContentDeletionLedgerAuthenticating: Sendable {
  func authenticationCode(for canonicalPayload: Data) throws -> Data
  func isValidAuthenticationCode(
    _ authenticationCode: Data,
    for canonicalPayload: Data
  ) throws -> Bool
}

struct OwnedContentDeletionLedgerHMACAuthenticator:
  OwnedContentDeletionLedgerAuthenticating, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  // This authenticates archive bytes; it is not a monotonic rollback anchor.
  private enum KeySource: Sendable {
    case keyStore(any ComposerImageUploadLedgerKeyStoring)
    case fixed(Data)
  }

  private static let domain = Data(
    "TiebaPlusPlus/OwnedContentDeletionLedger/HMAC-SHA256/v1\0".utf8
  )
  private let keySource: KeySource

  init(
    keyStore: any ComposerImageUploadLedgerKeyStoring =
      SystemComposerImageUploadLedgerKeyStore(
        service: "io.github.minaduki.tieba-plus-plus.owned-content-deletion-ledger",
        account: "hmac-sha256-v1"
      )
  ) {
    keySource = .keyStore(keyStore)
  }

  init(testingKey: Data) {
    keySource = .fixed(testingKey)
  }

  var description: String { "OwnedContentDeletionLedgerHMACAuthenticator(redacted)" }
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
    do {
      switch keySource {
      case .keyStore(let keyStore):
        key = try keyStore.existingOrNewKey()
      case .fixed(let fixed):
        key = fixed
      }
    } catch {
      throw OwnedContentDeletionLedgerAuthenticationError.unavailable
    }
    guard key.count == SystemComposerImageUploadLedgerKeyStore.keyByteCount else {
      throw OwnedContentDeletionLedgerAuthenticationError.invalidKey
    }
    return key
  }

  private func verificationKey() throws -> Data {
    let key: Data?
    do {
      switch keySource {
      case .keyStore(let keyStore):
        key = try keyStore.existingKey()
      case .fixed(let fixed):
        key = fixed
      }
    } catch {
      throw OwnedContentDeletionLedgerAuthenticationError.unavailable
    }
    guard
      let key,
      key.count == SystemComposerImageUploadLedgerKeyStore.keyByteCount
    else { throw OwnedContentDeletionLedgerAuthenticationError.invalidKey }
    return key
  }

  private static func domainSeparated(_ canonicalPayload: Data) -> Data {
    var authenticated = domain
    var byteCount = UInt64(canonicalPayload.count).bigEndian
    withUnsafeBytes(of: &byteCount) { authenticated.append(contentsOf: $0) }
    authenticated.append(canonicalPayload)
    return authenticated
  }
}

enum OwnedContentDeletionLedgerRestoredTerminal: Hashable, Sendable {
  case outcomeUnknown
  case accepted
}

enum OwnedContentDeletionLedgerPhase: String, Codable, Hashable, Sendable {
  case dispatchPending
  case outcomeUnknown
  case accepted

  var restoredTerminal: OwnedContentDeletionLedgerRestoredTerminal {
    switch self {
    case .dispatchPending, .outcomeUnknown:
      .outcomeUnknown
    case .accepted:
      .accepted
    }
  }
}

private enum OwnedContentDeletionLedgerStoredKind: String, Codable, Sendable {
  case topic
  case post

  init(_ kind: OwnedContentDeletionKind) {
    switch kind {
    case .topic: self = .topic
    case .post: self = .post
    }
  }

  var value: OwnedContentDeletionKind {
    switch self {
    case .topic: .topic
    case .post: .post
    }
  }
}

struct OwnedContentDeletionLedgerKey: Hashable, Codable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let kind: OwnedContentDeletionKind
  let objectID: Int64

  init?(userID: Int64, target: OwnedContentDeletionTarget) {
    guard userID == target.authorID else { return nil }
    self.init(
      userID: userID,
      forumID: target.forumID,
      threadID: target.threadID,
      kind: target.kind,
      objectID: target.objectID
    )
  }

  private init?(
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    kind: OwnedContentDeletionKind,
    objectID: Int64
  ) {
    guard userID > 0, forumID > 0, threadID > 0, objectID > 0 else { return nil }
    self.userID = userID
    self.forumID = forumID
    self.threadID = threadID
    self.kind = kind
    self.objectID = objectID
  }

  fileprivate var isValid: Bool {
    Self(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      kind: kind,
      objectID: objectID
    ) != nil
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case userID
    case forumID
    case threadID
    case kind
    case objectID
  }

  init(from decoder: any Decoder) throws {
    try requireOwnedContentDeletionLedgerKeys(decoder, CodingKeys.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let value = Self(
        userID: try container.decode(Int64.self, forKey: .userID),
        forumID: try container.decode(Int64.self, forKey: .forumID),
        threadID: try container.decode(Int64.self, forKey: .threadID),
        kind: try container.decode(
          OwnedContentDeletionLedgerStoredKind.self,
          forKey: .kind
        ).value,
        objectID: try container.decode(Int64.self, forKey: .objectID)
      )
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid deletion key.")
      )
    }
    self = value
  }

  func encode(to encoder: any Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        .init(codingPath: encoder.codingPath, debugDescription: "Invalid deletion key.")
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(userID, forKey: .userID)
    try container.encode(forumID, forKey: .forumID)
    try container.encode(threadID, forKey: .threadID)
    try container.encode(OwnedContentDeletionLedgerStoredKind(kind), forKey: .kind)
    try container.encode(objectID, forKey: .objectID)
  }
}

struct OwnedContentDeletionLedgerTargetSnapshot: Hashable, Codable, Sendable {
  let kind: OwnedContentDeletionKind
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let objectID: Int64
  let authorID: Int64
  let floor: Int

  init?(_ target: OwnedContentDeletionTarget) {
    guard
      let validated = OwnedContentDeletionTarget(
        kind: target.kind,
        forumID: target.forumID,
        forumName: target.forumName,
        threadID: target.threadID,
        objectID: target.objectID,
        authorID: target.authorID,
        floor: target.floor
      ),
      validated == target
    else { return nil }
    kind = validated.kind
    forumID = validated.forumID
    forumName = validated.forumName
    threadID = validated.threadID
    objectID = validated.objectID
    authorID = validated.authorID
    floor = validated.floor
  }

  var target: OwnedContentDeletionTarget? {
    OwnedContentDeletionTarget(
      kind: kind,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      objectID: objectID,
      authorID: authorID,
      floor: floor
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case forumID
    case forumName
    case threadID
    case objectID
    case authorID
    case floor
  }

  init(from decoder: any Decoder) throws {
    try requireOwnedContentDeletionLedgerKeys(decoder, CodingKeys.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let target = OwnedContentDeletionTarget(
        kind: try container.decode(
          OwnedContentDeletionLedgerStoredKind.self,
          forKey: .kind
        ).value,
        forumID: try container.decode(Int64.self, forKey: .forumID),
        forumName: try container.decode(String.self, forKey: .forumName),
        threadID: try container.decode(Int64.self, forKey: .threadID),
        objectID: try container.decode(Int64.self, forKey: .objectID),
        authorID: try container.decode(Int64.self, forKey: .authorID),
        floor: try container.decode(Int.self, forKey: .floor)
      ),
      let value = Self(target)
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid deletion target snapshot."
        )
      )
    }
    self = value
  }

  func encode(to encoder: any Encoder) throws {
    guard let target, Self(target) == self else {
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: "Invalid deletion target snapshot."
        )
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(OwnedContentDeletionLedgerStoredKind(kind), forKey: .kind)
    try container.encode(forumID, forKey: .forumID)
    try container.encode(forumName, forKey: .forumName)
    try container.encode(threadID, forKey: .threadID)
    try container.encode(objectID, forKey: .objectID)
    try container.encode(authorID, forKey: .authorID)
    try container.encode(floor, forKey: .floor)
  }
}

struct OwnedContentDeletionLedgerRecord: Hashable, Codable, Sendable {
  private static let maximumExactTimestampMilliseconds = 9_007_199_254_740_991.0

  let key: OwnedContentDeletionLedgerKey
  let targetSnapshot: OwnedContentDeletionLedgerTargetSnapshot
  let operationID: UUID
  let originSessionRevision: UUID
  let phase: OwnedContentDeletionLedgerPhase
  let createdAt: Date
  let updatedAt: Date

  init?(
    userID: Int64,
    target: OwnedContentDeletionTarget,
    operationID: UUID,
    originSessionRevision: UUID,
    phase: OwnedContentDeletionLedgerPhase,
    createdAt: Date,
    updatedAt: Date
  ) {
    guard
      let key = OwnedContentDeletionLedgerKey(userID: userID, target: target),
      let targetSnapshot = OwnedContentDeletionLedgerTargetSnapshot(target),
      let createdAt = Self.normalizedTimestamp(createdAt),
      let updatedAt = Self.normalizedTimestamp(updatedAt),
      updatedAt >= createdAt
    else { return nil }
    self.key = key
    self.targetSnapshot = targetSnapshot
    self.operationID = operationID
    self.originSessionRevision = originSessionRevision
    self.phase = phase
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var restoredTerminal: OwnedContentDeletionLedgerRestoredTerminal {
    phase.restoredTerminal
  }

  func reconstructedTarget() throws -> OwnedContentDeletionTarget {
    guard
      let target = targetSnapshot.target,
      let rebuiltKey = OwnedContentDeletionLedgerKey(userID: key.userID, target: target),
      rebuiltKey == key
    else { throw OwnedContentDeletionLedgerError.invalidRecord }
    return target
  }

  fileprivate var isValid: Bool {
    guard
      key.isValid,
      let target = targetSnapshot.target,
      let rebuilt = Self(
        userID: key.userID,
        target: target,
        operationID: operationID,
        originSessionRevision: originSessionRevision,
        phase: phase,
        createdAt: createdAt,
        updatedAt: updatedAt
      )
    else { return false }
    return rebuilt == self
  }

  fileprivate func replacingPhase(
    _ phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) -> Self? {
    guard
      let target = targetSnapshot.target,
      let normalizedDate = Self.normalizedTimestamp(date)
    else { return nil }
    return Self(
      userID: key.userID,
      target: target,
      operationID: operationID,
      originSessionRevision: originSessionRevision,
      phase: phase,
      createdAt: createdAt,
      updatedAt: max(updatedAt, normalizedDate)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case key
    case targetSnapshot
    case operationID
    case originSessionRevision
    case phase
    case createdAt
    case updatedAt
  }

  init(from decoder: any Decoder) throws {
    try requireOwnedContentDeletionLedgerKeys(decoder, CodingKeys.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let key = try container.decode(OwnedContentDeletionLedgerKey.self, forKey: .key)
    let snapshot = try container.decode(
      OwnedContentDeletionLedgerTargetSnapshot.self,
      forKey: .targetSnapshot
    )
    guard
      let target = snapshot.target,
      let value = Self(
        userID: key.userID,
        target: target,
        operationID: try container.decode(UUID.self, forKey: .operationID),
        originSessionRevision: try container.decode(
          UUID.self,
          forKey: .originSessionRevision
        ),
        phase: try container.decode(OwnedContentDeletionLedgerPhase.self, forKey: .phase),
        createdAt: try Self.timestamp(
          milliseconds: container.decode(Int64.self, forKey: .createdAt),
          codingPath: decoder.codingPath
        ),
        updatedAt: try Self.timestamp(
          milliseconds: container.decode(Int64.self, forKey: .updatedAt),
          codingPath: decoder.codingPath
        )
      ),
      value.key == key,
      value.targetSnapshot == snapshot
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid deletion record.")
      )
    }
    self = value
  }

  func encode(to encoder: any Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        .init(codingPath: encoder.codingPath, debugDescription: "Invalid deletion record.")
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(targetSnapshot, forKey: .targetSnapshot)
    try container.encode(operationID, forKey: .operationID)
    try container.encode(originSessionRevision, forKey: .originSessionRevision)
    try container.encode(phase, forKey: .phase)
    guard
      let createdAtMilliseconds = Self.timestampMilliseconds(createdAt),
      let updatedAtMilliseconds = Self.timestampMilliseconds(updatedAt)
    else {
      throw EncodingError.invalidValue(
        self,
        .init(codingPath: encoder.codingPath, debugDescription: "Invalid record timestamp.")
      )
    }
    try container.encode(createdAtMilliseconds, forKey: .createdAt)
    try container.encode(updatedAtMilliseconds, forKey: .updatedAt)
  }

  private static func normalizedTimestamp(_ date: Date) -> Date? {
    guard let milliseconds = timestampMilliseconds(date) else { return nil }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }

  private static func timestampMilliseconds(_ date: Date) -> Int64? {
    let value = (date.timeIntervalSince1970 * 1_000).rounded()
    guard
      value.isFinite,
      abs(value) <= maximumExactTimestampMilliseconds
    else { return nil }
    return Int64(value)
  }

  private static func timestamp(
    milliseconds: Int64,
    codingPath: [any CodingKey]
  ) throws -> Date {
    guard abs(Double(milliseconds)) <= maximumExactTimestampMilliseconds else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: codingPath, debugDescription: "Invalid record timestamp.")
      )
    }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }
}

enum OwnedContentDeletionLedgerError: LocalizedError, Equatable, Sendable {
  case invalidTarget
  case invalidRecord
  case recordNotFound
  case resourceLocked
  case operationIDConflict
  case operationMismatch
  case invalidTransition
  case corruptedArchive
  case authenticationFailed
  case authenticationUnavailable
  case unsupportedSchemaVersion(Int)
  case archiveTooLarge
  case tooManyRecords
  case unsafeStorage
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidTarget:
      "删除安全记录的目标无效。"
    case .invalidRecord:
      "删除安全记录无效。"
    case .recordNotFound:
      "没有找到删除安全记录。"
    case .resourceLocked:
      "该内容已有不可重复的删除记录。"
    case .operationIDConflict:
      "删除操作标识已被其他内容使用。"
    case .operationMismatch:
      "删除操作与安全记录不匹配。"
    case .invalidTransition:
      "删除安全记录的状态转换无效。"
    case .corruptedArchive:
      "删除安全记录已损坏，未进行覆盖。"
    case .authenticationFailed:
      "删除安全记录未通过完整性认证，未进行覆盖。"
    case .authenticationUnavailable:
      "无法验证删除安全记录，未进行覆盖。"
    case .unsupportedSchemaVersion:
      "删除安全记录来自更新版本，当前版本不会修改它。"
    case .archiveTooLarge:
      "删除安全记录超过安全大小限制。"
    case .tooManyRecords:
      "删除安全记录数量超过安全限制。"
    case .unsafeStorage:
      "删除安全记录的存储位置不安全。"
    case .readFailed:
      "无法读取删除安全记录。"
    case .writeFailed:
      "无法安全保存删除安全记录。"
    }
  }
}

protocol OwnedContentDeletionLedgerRepository: Sendable {
  func records() async throws -> [OwnedContentDeletionLedgerRecord]
  func record(
    for key: OwnedContentDeletionLedgerKey
  ) async throws -> OwnedContentDeletionLedgerRecord?
  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord
  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord
  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws
}

extension OwnedContentDeletionLedgerRepository {
  func allRecords() async throws -> [OwnedContentDeletionLedgerRecord] {
    try await records()
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await prepare(
      target: target,
      accountID: accountID,
      sessionRevision: sessionRevision,
      operationID: operationID,
      at: Date()
    )
  }

  func markOutcomeUnknown(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await transition(
      for: key,
      operationID: operationID,
      to: .outcomeUnknown,
      at: Date()
    )
  }

  func markAccepted(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await transition(for: key, operationID: operationID, to: .accepted, at: Date())
  }

  func markOutcomeUnknown(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await transition(for: key, operationID: operationID, to: .outcomeUnknown, at: date)
  }

  func markAccepted(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await transition(for: key, operationID: operationID, to: .accepted, at: date)
  }

  func removeAfterDefiniteFailure(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws {
    try await removeDispatchPending(for: key, operationID: operationID)
  }
}

actor FileOwnedContentDeletionLedger: OwnedContentDeletionLedgerRepository {
  static let schemaVersion = 1
  static let defaultMaximumRecords = 4_096
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024
  // This inode is never replaced or removed, so every repository instance locks the same object.
  static let lockFilename = ".owned-content-deletion-ledger.lock"
  private static let exclusiveLockRetryCount = 500
  private static let exclusiveLockRetryDelayNanoseconds: UInt64 = 10_000_000

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var records: [OwnedContentDeletionLedgerRecord]

    static var empty: Self {
      Archive(schemaVersion: FileOwnedContentDeletionLedger.schemaVersion, records: [])
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
      case schemaVersion
      case records
    }

    init(schemaVersion: Int, records: [OwnedContentDeletionLedgerRecord]) {
      self.schemaVersion = schemaVersion
      self.records = records
    }

    init(from decoder: any Decoder) throws {
      try requireOwnedContentDeletionLedgerKeys(decoder, CodingKeys.self)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
      records = try container.decode(
        [OwnedContentDeletionLedgerRecord].self,
        forKey: .records
      )
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private struct SignedEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let canonicalPayload: Data
    let authenticationCode: Data

    private enum CodingKeys: String, CodingKey, CaseIterable {
      case schemaVersion
      case canonicalPayload
      case authenticationCode
    }

    init(schemaVersion: Int, canonicalPayload: Data, authenticationCode: Data) {
      self.schemaVersion = schemaVersion
      self.canonicalPayload = canonicalPayload
      self.authenticationCode = authenticationCode
    }

    init(from decoder: any Decoder) throws {
      try requireOwnedContentDeletionLedgerKeys(decoder, CodingKeys.self)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
      canonicalPayload = try container.decode(Data.self, forKey: .canonicalPayload)
      authenticationCode = try container.decode(Data.self, forKey: .authenticationCode)
    }
  }

  private let fileURL: URL
  private let authenticator: any OwnedContentDeletionLedgerAuthenticating
  private let maximumRecords: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync: @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
  private let onExclusiveLockContention: @Sendable () -> Void

  init(
    fileURL: URL,
    authenticator: (any OwnedContentDeletionLedgerAuthenticating)? = nil,
    testingKey: Data? = nil,
    maximumRecords: Int = defaultMaximumRecords,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (
      @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
    )? = nil,
    onExclusiveLockContention: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL.standardizedFileURL
    if let authenticator {
      self.authenticator = authenticator
    } else if let testingKey {
      self.authenticator = OwnedContentDeletionLedgerHMACAuthenticator(testingKey: testingKey)
    } else {
      self.authenticator = OwnedContentDeletionLedgerHMACAuthenticator()
    }
    self.maximumRecords = max(maximumRecords, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.prepareStagedFile = prepareStagedFile ?? { url in
      try FileOwnedContentDeletionLedger.applyStorageAttributes(to: url)
    }
    self.beforeDurabilitySync = beforeDurabilitySync ?? { _ in }
    self.onExclusiveLockContention = onExclusiveLockContention ?? {}
  }

  static func live(fileManager: FileManager = .default) -> FileOwnedContentDeletionLedger {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return FileOwnedContentDeletionLedger(
        fileURL: URL(fileURLWithPath: "/dev/null", isDirectory: true)
          .appendingPathComponent("owned-content-deletion-ledger-unavailable.json")
      )
    }
    return FileOwnedContentDeletionLedger(
      fileURL:
        applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("owned-content-deletion-ledger-v1.json", isDirectory: false)
    )
  }

  func records() async throws -> [OwnedContentDeletionLedgerRecord] {
    try await withExclusiveArchiveLock {
      try loadArchive().records
    }
  }

  func record(
    for key: OwnedContentDeletionLedgerKey
  ) async throws -> OwnedContentDeletionLedgerRecord? {
    guard key.isValid else { throw OwnedContentDeletionLedgerError.invalidTarget }
    return try await withExclusiveArchiveLock {
      try loadArchive().records.first(where: { $0.key == key })
    }
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    try await withExclusiveArchiveLock {
      var archive = try loadArchive()
      let record = try OwnedContentDeletionLedgerModel.beginDispatch(
        records: &archive.records,
        maximumRecords: maximumRecords,
        userID: accountID,
        target: target,
        operationID: operationID,
        sessionRevision: sessionRevision,
        at: date
      )
      try commit(archive)
      return record
    }
  }

  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) async throws -> OwnedContentDeletionLedgerRecord {
    guard phase == .accepted || phase == .outcomeUnknown else {
      throw OwnedContentDeletionLedgerError.invalidTransition
    }
    return try await withExclusiveArchiveLock {
      try applyTransition(key: key, operationID: operationID, phase: phase, at: date)
    }
  }

  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) async throws {
    try await withExclusiveArchiveLock {
      var archive = try loadArchive()
      try OwnedContentDeletionLedgerModel.removeAfterDefiniteFailure(
        records: &archive.records,
        key: key,
        operationID: operationID
      )
      try commit(archive)
    }
  }

  private func withExclusiveArchiveLock<Result>(
    _ operation: () throws -> Result
  ) async throws -> Result {
    let directoryURL = fileURL.deletingLastPathComponent()
    let expectedDirectoryStatus = try ensureStorageDirectory(at: directoryURL)
    var directoryDescriptor: Int32 = -1
    var lockDescriptor: Int32 = -1
    var didAcquireLock = false

    defer {
      if didAcquireLock {
        Self.releaseExclusiveLock(descriptor: lockDescriptor)
      }
      if lockDescriptor >= 0 {
        _ = Darwin.close(lockDescriptor)
      }
      if directoryDescriptor >= 0 {
        _ = Darwin.close(directoryDescriptor)
      }
    }

    directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard directoryDescriptor >= 0 else {
      throw OwnedContentDeletionLedgerError.unsafeStorage
    }
    try Self.verifyDirectoryDescriptor(
      directoryDescriptor,
      expectedStatus: expectedDirectoryStatus
    )

    lockDescriptor = Self.lockFilename.withCString { filename in
      Darwin.openat(
        directoryDescriptor,
        filename,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
        mode_t(S_IRUSR | S_IWUSR)
      )
    }
    guard lockDescriptor >= 0 else {
      throw OwnedContentDeletionLedgerError.unsafeStorage
    }
    try Self.verifyLockFile(
      descriptor: lockDescriptor,
      directoryDescriptor: directoryDescriptor
    )

    try await acquireExclusiveLock(descriptor: lockDescriptor)
    didAcquireLock = true
    try Self.verifyLockFile(
      descriptor: lockDescriptor,
      directoryDescriptor: directoryDescriptor
    )
    try Self.verifyDirectoryPath(
      directoryURL,
      expectedStatus: expectedDirectoryStatus
    )

    let result = try operation()

    try Self.verifyLockFile(
      descriptor: lockDescriptor,
      directoryDescriptor: directoryDescriptor
    )
    try Self.verifyDirectoryPath(
      directoryURL,
      expectedStatus: expectedDirectoryStatus
    )
    return result
  }

  private func ensureStorageDirectory(at directoryURL: URL) throws -> stat {
    guard
      fileURL.isFileURL,
      directoryURL.isFileURL,
      Self.isValidFilename(fileURL.lastPathComponent)
    else { throw OwnedContentDeletionLedgerError.unsafeStorage }

    do {
      if let existing = try Self.storageItemStatus(at: directoryURL) {
        guard Self.fileType(of: existing) == mode_t(S_IFDIR) else {
          throw OwnedContentDeletionLedgerError.unsafeStorage
        }
      } else {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      }
      guard
        let status = try Self.storageItemStatus(at: directoryURL),
        Self.fileType(of: status) == mode_t(S_IFDIR),
        status.st_uid == Darwin.geteuid(),
        status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
      else { throw OwnedContentDeletionLedgerError.unsafeStorage }
      try Self.applyStorageAttributes(to: directoryURL)
      guard
        let prepared = try Self.storageItemStatus(at: directoryURL),
        Self.sameStorageItem(status, prepared),
        Self.fileType(of: prepared) == mode_t(S_IFDIR),
        prepared.st_uid == Darwin.geteuid(),
        prepared.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
      else { throw OwnedContentDeletionLedgerError.unsafeStorage }
      return prepared
    } catch let error as OwnedContentDeletionLedgerError {
      throw error
    } catch {
      throw OwnedContentDeletionLedgerError.unsafeStorage
    }
  }

  private static func verifyDirectoryDescriptor(
    _ descriptor: Int32,
    expectedStatus: stat
  ) throws {
    var opened = stat()
    guard
      Darwin.fstat(descriptor, &opened) == 0,
      fileType(of: opened) == mode_t(S_IFDIR),
      sameStorageItem(opened, expectedStatus),
      opened.st_uid == Darwin.geteuid(),
      opened.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else { throw OwnedContentDeletionLedgerError.unsafeStorage }
  }

  private static func verifyDirectoryPath(
    _ directoryURL: URL,
    expectedStatus: stat
  ) throws {
    guard
      let current = try storageItemStatus(at: directoryURL),
      fileType(of: current) == mode_t(S_IFDIR),
      sameStorageItem(current, expectedStatus)
    else { throw OwnedContentDeletionLedgerError.unsafeStorage }
  }

  private static func verifyLockFile(
    descriptor: Int32,
    directoryDescriptor: Int32
  ) throws {
    var opened = stat()
    var linked = stat()
    let pathResult = lockFilename.withCString { filename in
      Darwin.fstatat(directoryDescriptor, filename, &linked, AT_SYMLINK_NOFOLLOW)
    }
    let expectedPermissions = mode_t(S_IRUSR | S_IWUSR)
    let permissionMask = mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
    guard
      Darwin.fstat(descriptor, &opened) == 0,
      pathResult == 0,
      fileType(of: opened) == mode_t(S_IFREG),
      fileType(of: linked) == mode_t(S_IFREG),
      sameStorageItem(opened, linked),
      opened.st_uid == Darwin.geteuid(),
      opened.st_nlink == 1,
      opened.st_mode & permissionMask == expectedPermissions
    else { throw OwnedContentDeletionLedgerError.unsafeStorage }
  }

  private func acquireExclusiveLock(descriptor: Int32) async throws {
    var remainingRetries = Self.exclusiveLockRetryCount
    var didReportContention = false
    while true {
      try Task.checkCancellation()
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
      let nonblockingError = errno
      guard
        nonblockingError == EINTR
          || nonblockingError == EWOULDBLOCK
          || nonblockingError == EAGAIN
      else {
        throw OwnedContentDeletionLedgerError.unsafeStorage
      }
      if nonblockingError != EINTR, !didReportContention {
        didReportContention = true
        onExclusiveLockContention()
      }
      guard remainingRetries > 0 else {
        throw OwnedContentDeletionLedgerError.unsafeStorage
      }
      remainingRetries -= 1
      try await Task.sleep(nanoseconds: Self.exclusiveLockRetryDelayNanoseconds)
    }
  }

  private static func releaseExclusiveLock(descriptor: Int32) {
    guard descriptor >= 0 else { return }
    var remainingRetries = Self.exclusiveLockRetryCount
    while flock(descriptor, LOCK_UN) != 0 {
      guard errno == EINTR, remainingRetries > 0 else { return }
      remainingRetries -= 1
    }
  }

  private static func sameStorageItem(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func isValidFilename(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.utf8.contains(0)
      && !value.contains("/")
  }

  private func applyTransition(
    key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) throws -> OwnedContentDeletionLedgerRecord {
    var archive = try loadArchive()
    let previous = archive.records.first(where: { $0.key == key })
    let record = try OwnedContentDeletionLedgerModel.transition(
      records: &archive.records,
      key: key,
      operationID: operationID,
      phase: phase,
      at: date
    )
    if record != previous {
      try commit(archive)
    }
    return record
  }

  private func loadArchive() throws -> Archive {
    guard let status = try Self.storageItemStatus(at: fileURL) else { return .empty }
    guard Self.fileType(of: status) == mode_t(S_IFREG) else {
      throw OwnedContentDeletionLedgerError.unsafeStorage
    }
    guard status.st_size > 0 else {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard status.st_size <= off_t(maximumArchiveBytes) else {
      throw OwnedContentDeletionLedgerError.archiveTooLarge
    }

    let data: Data
    do {
      data = try ComposerSecureRegularFileReader.read(
        from: fileURL,
        expectedByteCount: Int64(status.st_size),
        maximumByteCount: Int64(maximumArchiveBytes),
        checksCancellation: false
      )
    } catch ComposerSecureRegularFileReadError.fileTooLarge {
      throw OwnedContentDeletionLedgerError.archiveTooLarge
    } catch {
      throw OwnedContentDeletionLedgerError.readFailed
    }

    let decoder = Self.makeDecoder()
    let envelopeHeader: ArchiveHeader
    do {
      envelopeHeader = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard envelopeHeader.schemaVersion == Self.schemaVersion else {
      throw OwnedContentDeletionLedgerError.unsupportedSchemaVersion(
        envelopeHeader.schemaVersion
      )
    }
    let envelope: SignedEnvelope
    do {
      envelope = try decoder.decode(SignedEnvelope.self, from: data)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard envelope.canonicalPayload.count <= maximumArchiveBytes else {
      throw OwnedContentDeletionLedgerError.archiveTooLarge
    }
    let isAuthenticated: Bool
    do {
      isAuthenticated = try authenticator.isValidAuthenticationCode(
        envelope.authenticationCode,
        for: envelope.canonicalPayload
      )
    } catch {
      throw OwnedContentDeletionLedgerError.authenticationUnavailable
    }
    guard isAuthenticated else {
      throw OwnedContentDeletionLedgerError.authenticationFailed
    }
    let payloadHeader: ArchiveHeader
    do {
      payloadHeader = try decoder.decode(ArchiveHeader.self, from: envelope.canonicalPayload)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard payloadHeader.schemaVersion == Self.schemaVersion else {
      throw OwnedContentDeletionLedgerError.unsupportedSchemaVersion(payloadHeader.schemaVersion)
    }
    let archive: Archive
    do {
      archive = try decoder.decode(Archive.self, from: envelope.canonicalPayload)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    try OwnedContentDeletionLedgerModel.validate(
      archive.records,
      maximumRecords: maximumRecords
    )
    let canonicalData: Data
    do {
      canonicalData = try Self.makeEncoder().encode(archive)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard canonicalData == envelope.canonicalPayload else {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    let canonicalEnvelope: Data
    do {
      canonicalEnvelope = try Self.makeEncoder().encode(envelope)
    } catch {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    guard canonicalEnvelope == data else {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    return archive
  }

  private func commit(_ proposedArchive: Archive) throws {
    var archive = proposedArchive
    archive.records.sort(by: OwnedContentDeletionLedgerModel.isOrderedBefore)
    try OwnedContentDeletionLedgerModel.validate(
      archive.records,
      maximumRecords: maximumRecords
    )
    let canonicalPayload: Data
    do {
      canonicalPayload = try Self.makeEncoder().encode(archive)
    } catch {
      throw OwnedContentDeletionLedgerError.writeFailed
    }
    guard canonicalPayload.count <= maximumArchiveBytes else {
      throw OwnedContentDeletionLedgerError.archiveTooLarge
    }
    let authenticationCode: Data
    do {
      authenticationCode = try authenticator.authenticationCode(for: canonicalPayload)
    } catch {
      throw OwnedContentDeletionLedgerError.authenticationUnavailable
    }
    let envelope = SignedEnvelope(
      schemaVersion: Self.schemaVersion,
      canonicalPayload: canonicalPayload,
      authenticationCode: authenticationCode
    )
    let data: Data
    do {
      data = try Self.makeEncoder().encode(envelope)
    } catch {
      throw OwnedContentDeletionLedgerError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw OwnedContentDeletionLedgerError.archiveTooLarge
    }
    do {
      try ComposerDurableFileWriter(
        targetURL: fileURL,
        maximumByteCount: maximumArchiveBytes,
        stagedFilenamePrefix: ".owned-content-deletion-ledger-",
        prepareStorageDirectory: { url in
          try FileOwnedContentDeletionLedger.applyStorageAttributes(to: url)
        },
        prepareStagedFile: prepareStagedFile,
        beforeDurabilitySync: beforeDurabilitySync
      ).persist(data)
    } catch {
      throw OwnedContentDeletionLedgerError.writeFailed
    }
  }

  private static func applyStorageAttributes(to fileURL: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableFileURL = fileURL
    try mutableFileURL.setResourceValues(values)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    #endif
  }

  private static func storageItemStatus(at url: URL) throws -> stat? {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    if result == 0 { return status }
    if errno == ENOENT { return nil }
    throw OwnedContentDeletionLedgerError.readFailed
  }

  private static func fileType(of status: stat) -> mode_t {
    status.st_mode & mode_t(S_IFMT)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

actor TransientOwnedContentDeletionLedger: OwnedContentDeletionLedgerRepository {
  private let maximumRecords: Int
  private var storedRecords: [OwnedContentDeletionLedgerRecord]

  init(maximumRecords: Int = FileOwnedContentDeletionLedger.defaultMaximumRecords) {
    self.maximumRecords = max(maximumRecords, 1)
    self.storedRecords = []
  }

  init(
    records: [OwnedContentDeletionLedgerRecord],
    maximumRecords: Int = FileOwnedContentDeletionLedger.defaultMaximumRecords
  ) throws {
    let maximumRecords = max(maximumRecords, 1)
    try OwnedContentDeletionLedgerModel.validate(records, maximumRecords: maximumRecords)
    self.maximumRecords = maximumRecords
    self.storedRecords = records.sorted(by: OwnedContentDeletionLedgerModel.isOrderedBefore)
  }

  func records() throws -> [OwnedContentDeletionLedgerRecord] {
    storedRecords
  }

  func record(
    for key: OwnedContentDeletionLedgerKey
  ) throws -> OwnedContentDeletionLedgerRecord? {
    guard key.isValid else { throw OwnedContentDeletionLedgerError.invalidTarget }
    return storedRecords.first(where: { $0.key == key })
  }

  func prepare(
    target: OwnedContentDeletionTarget,
    accountID: Int64,
    sessionRevision: UUID,
    operationID: UUID,
    at date: Date
  ) throws -> OwnedContentDeletionLedgerRecord {
    try OwnedContentDeletionLedgerModel.beginDispatch(
      records: &storedRecords,
      maximumRecords: maximumRecords,
      userID: accountID,
      target: target,
      operationID: operationID,
      sessionRevision: sessionRevision,
      at: date
    )
  }

  func transition(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    to phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) throws -> OwnedContentDeletionLedgerRecord {
    guard phase == .accepted || phase == .outcomeUnknown else {
      throw OwnedContentDeletionLedgerError.invalidTransition
    }
    try OwnedContentDeletionLedgerModel.transition(
      records: &storedRecords,
      key: key,
      operationID: operationID,
      phase: phase,
      at: date
    )
  }

  func removeDispatchPending(
    for key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) throws {
    try OwnedContentDeletionLedgerModel.removeAfterDefiniteFailure(
      records: &storedRecords,
      key: key,
      operationID: operationID
    )
  }
}

private enum OwnedContentDeletionLedgerModel {
  static func beginDispatch(
    records: inout [OwnedContentDeletionLedgerRecord],
    maximumRecords: Int,
    userID: Int64,
    target: OwnedContentDeletionTarget,
    operationID: UUID,
    sessionRevision: UUID,
    at date: Date
  ) throws -> OwnedContentDeletionLedgerRecord {
    guard
      let candidate = OwnedContentDeletionLedgerRecord(
        userID: userID,
        target: target,
        operationID: operationID,
        originSessionRevision: sessionRevision,
        phase: .dispatchPending,
        createdAt: date,
        updatedAt: date
      )
    else { throw OwnedContentDeletionLedgerError.invalidTarget }
    if records.contains(where: { $0.key == candidate.key }) {
      throw OwnedContentDeletionLedgerError.resourceLocked
    }
    guard !records.contains(where: { $0.operationID == operationID }) else {
      throw OwnedContentDeletionLedgerError.operationIDConflict
    }
    guard records.count < maximumRecords else {
      throw OwnedContentDeletionLedgerError.tooManyRecords
    }
    records.append(candidate)
    records.sort(by: isOrderedBefore)
    return candidate
  }

  static func transition(
    records: inout [OwnedContentDeletionLedgerRecord],
    key: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    phase: OwnedContentDeletionLedgerPhase,
    at date: Date
  ) throws -> OwnedContentDeletionLedgerRecord {
    guard key.isValid else { throw OwnedContentDeletionLedgerError.invalidTarget }
    guard let index = records.firstIndex(where: { $0.key == key }) else {
      throw OwnedContentDeletionLedgerError.recordNotFound
    }
    let current = records[index]
    guard current.operationID == operationID else {
      throw OwnedContentDeletionLedgerError.operationMismatch
    }
    if current.phase == phase { return current }
    guard
      current.phase == .dispatchPending,
      phase == .outcomeUnknown || phase == .accepted
    else { throw OwnedContentDeletionLedgerError.invalidTransition }
    guard let updated = current.replacingPhase(phase, at: date) else {
      throw OwnedContentDeletionLedgerError.invalidRecord
    }
    records[index] = updated
    return updated
  }

  static func removeAfterDefiniteFailure(
    records: inout [OwnedContentDeletionLedgerRecord],
    key: OwnedContentDeletionLedgerKey,
    operationID: UUID
  ) throws {
    guard key.isValid else { throw OwnedContentDeletionLedgerError.invalidTarget }
    guard let index = records.firstIndex(where: { $0.key == key }) else {
      throw OwnedContentDeletionLedgerError.recordNotFound
    }
    let current = records[index]
    guard current.operationID == operationID else {
      throw OwnedContentDeletionLedgerError.operationMismatch
    }
    guard current.phase == .dispatchPending else {
      throw OwnedContentDeletionLedgerError.invalidTransition
    }
    records.remove(at: index)
  }

  static func validate(
    _ records: [OwnedContentDeletionLedgerRecord],
    maximumRecords: Int
  ) throws {
    guard records.count <= maximumRecords else {
      throw OwnedContentDeletionLedgerError.tooManyRecords
    }
    guard records.elementsEqual(records.sorted(by: isOrderedBefore)) else {
      throw OwnedContentDeletionLedgerError.corruptedArchive
    }
    var keys = Set<OwnedContentDeletionLedgerKey>()
    var operationIDs = Set<UUID>()
    for record in records {
      guard
        record.isValid,
        keys.insert(record.key).inserted,
        operationIDs.insert(record.operationID).inserted
      else { throw OwnedContentDeletionLedgerError.corruptedArchive }
    }
  }

  static func isOrderedBefore(
    _ lhs: OwnedContentDeletionLedgerRecord,
    _ rhs: OwnedContentDeletionLedgerRecord
  ) -> Bool {
    if lhs.key.userID != rhs.key.userID { return lhs.key.userID < rhs.key.userID }
    if lhs.key.forumID != rhs.key.forumID { return lhs.key.forumID < rhs.key.forumID }
    if lhs.key.threadID != rhs.key.threadID { return lhs.key.threadID < rhs.key.threadID }
    let lhsKind = OwnedContentDeletionLedgerStoredKind(lhs.key.kind).rawValue
    let rhsKind = OwnedContentDeletionLedgerStoredKind(rhs.key.kind).rawValue
    if lhsKind != rhsKind { return lhsKind < rhsKind }
    return lhs.key.objectID < rhs.key.objectID
  }
}

private struct OwnedContentDeletionLedgerAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

private func requireOwnedContentDeletionLedgerKeys<Key: CodingKey & CaseIterable>(
  _ decoder: any Decoder,
  _ keyType: Key.Type
) throws {
  let actual = Set(
    try decoder.container(keyedBy: OwnedContentDeletionLedgerAnyCodingKey.self)
      .allKeys.map(\.stringValue)
  )
  let expected = Set(Key.allCases.map(\.stringValue))
  guard actual == expected else {
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Unexpected archive fields.")
    )
  }
}
