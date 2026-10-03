import CryptoKit
import Darwin
import Foundation

struct CloudFavoriteMutationLedgerKey: Hashable, Codable, Sendable {
  let userID: Int64
  let threadID: Int64

  init?(userID: Int64, threadID: Int64) {
    guard userID > 0, threadID > 0 else { return nil }
    self.userID = userID
    self.threadID = threadID
  }

  fileprivate var isValid: Bool { userID > 0 && threadID > 0 }
}

enum CloudFavoriteMutationLedgerPhase: String, Codable, Sendable {
  case dispatchPending
  case outcomeUnknown
  case acceptedAwaitingVerification
  case observedAbsent

  var restoredPhase: Self { self == .dispatchPending ? .outcomeUnknown : self }
  var blocksWrites: Bool { self != .observedAbsent }
}

struct CloudFavoriteMutationLedgerRecord: Codable, Equatable, Sendable {
  let key: CloudFavoriteMutationLedgerKey
  let operationID: UUID
  let originSessionRevision: UUID
  fileprivate(set) var phase: CloudFavoriteMutationLedgerPhase
  // Read-back absence never manufactures an ACK. Retain this evidence after verification.
  fileprivate(set) var receiptAcknowledged: Bool
  private let createdAtMilliseconds: Int64
  private var updatedAtMilliseconds: Int64

  var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1_000) }
  var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMilliseconds) / 1_000) }
  var restoredPhase: CloudFavoriteMutationLedgerPhase { phase.restoredPhase }
  var blocksWrites: Bool { phase.blocksWrites }

  fileprivate init(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) throws {
    guard key.isValid else { throw CloudFavoriteMutationLedgerError.invalidKey }
    let timestamp = try Self.timestamp(now)
    self.key = key
    self.operationID = operationID
    originSessionRevision = sessionRevision
    phase = .dispatchPending
    receiptAcknowledged = false
    createdAtMilliseconds = timestamp
    updatedAtMilliseconds = timestamp
  }

  fileprivate var isValid: Bool {
    guard key.isValid, createdAtMilliseconds >= 0,
      updatedAtMilliseconds >= createdAtMilliseconds,
      updatedAtMilliseconds <= Self.maximumTimestampMilliseconds
    else { return false }
    switch phase {
    case .dispatchPending, .outcomeUnknown: return !receiptAcknowledged
    case .acceptedAwaitingVerification: return receiptAcknowledged
    case .observedAbsent: return true
    }
  }

  fileprivate mutating func transition(to next: CloudFavoriteMutationLedgerPhase, now: Date) throws
  {
    let timestamp = try Self.timestamp(now)
    guard next != .dispatchPending else { throw CloudFavoriteMutationLedgerError.invalidTransition }
    if next == phase { return }
    switch (phase, next) {
    case (.dispatchPending, .outcomeUnknown),
      (.dispatchPending, .acceptedAwaitingVerification),
      (.dispatchPending, .observedAbsent),
      (.outcomeUnknown, .acceptedAwaitingVerification),
      (.outcomeUnknown, .observedAbsent),
      (.acceptedAwaitingVerification, .observedAbsent):
      phase = next
      receiptAcknowledged = receiptAcknowledged || next == .acceptedAwaitingVerification
      updatedAtMilliseconds = max(updatedAtMilliseconds, timestamp)
    default:
      throw CloudFavoriteMutationLedgerError.invalidTransition
    }
  }

  private static let maximumTimestampMilliseconds: Int64 = 8_640_000_000_000_000
  private static func timestamp(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 * 1_000).rounded()
    guard value.isFinite, value >= 0, value <= Double(maximumTimestampMilliseconds) else {
      throw CloudFavoriteMutationLedgerError.invalidRecord
    }
    return Int64(value)
  }
}

enum CloudFavoriteMutationLedgerError: LocalizedError, Equatable, Sendable {
  case invalidKey
  case invalidRecord
  case missingRecord
  case resourceLocked
  case operationMismatch
  case invalidTransition
  case corruptedArchive
  case unsupportedSchema
  case authenticationUnavailable
  case capacityExceeded
  case unsafeStorage
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidKey, .invalidRecord: "云收藏操作记录无效。"
    case .missingRecord: "没有找到云收藏操作记录。"
    case .resourceLocked: "这条云收藏的操作结果尚未核验，请先检查收藏状态。"
    case .operationMismatch: "云收藏操作与保存的记录不匹配。"
    case .invalidTransition: "云收藏操作记录的状态转换无效。"
    case .corruptedArchive: "云收藏操作记录未通过完整性检查，未进行覆盖。"
    case .unsupportedSchema: "云收藏操作记录来自更新版本，当前版本不会修改它。"
    case .authenticationUnavailable: "无法验证云收藏操作记录的设备密钥。"
    case .capacityExceeded: "云收藏操作记录超过安全存储限制。"
    case .unsafeStorage: "云收藏操作记录的存储位置不安全。"
    case .readFailed: "无法读取云收藏操作记录。"
    case .writeFailed: "无法安全保存云收藏操作记录。"
    }
  }
}

protocol CloudFavoriteMutationLedgerRepository: Sendable {
  func records() async throws -> [CloudFavoriteMutationLedgerRecord]
  func record(for key: CloudFavoriteMutationLedgerKey) async throws
    -> CloudFavoriteMutationLedgerRecord?
  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord
  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord
  // Only the originating operation with proof of non-dispatch or definite rejection may call this.
  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    async throws
}

extension CloudFavoriteMutationLedgerRepository {
  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, phase: CloudFavoriteMutationLedgerPhase
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try await transition(key: key, operationID: operationID, phase: phase, now: Date())
  }
}

private struct CloudFavoriteMutationLedgerArchive: Codable {
  var schemaVersion = FileCloudFavoriteMutationLedger.schemaVersion
  var records: [CloudFavoriteMutationLedgerRecord] = []

  mutating func sort() {
    records.sort {
      ($0.key.userID, $0.key.threadID) < ($1.key.userID, $1.key.threadID)
    }
  }

  func validate(maximumRecords: Int) throws {
    guard schemaVersion == FileCloudFavoriteMutationLedger.schemaVersion else {
      throw CloudFavoriteMutationLedgerError.unsupportedSchema
    }
    guard records.count <= maximumRecords else {
      throw CloudFavoriteMutationLedgerError.capacityExceeded
    }
    guard records.allSatisfy(\.isValid), Set(records.map(\.key)).count == records.count,
      Set(records.map(\.operationID)).count == records.count
    else { throw CloudFavoriteMutationLedgerError.corruptedArchive }
  }

  mutating func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date,
    maximumRecords: Int
  ) throws -> CloudFavoriteMutationLedgerRecord {
    let candidate = try CloudFavoriteMutationLedgerRecord(
      key: key, operationID: operationID, sessionRevision: sessionRevision, now: now)
    let previous = records.firstIndex { $0.key == key }
    if let previous, records[previous].blocksWrites {
      throw CloudFavoriteMutationLedgerError.resourceLocked
    }
    guard !records.contains(where: { $0.operationID == operationID }) else {
      throw CloudFavoriteMutationLedgerError.operationMismatch
    }
    if let previous {
      records[previous] = candidate
    } else {
      guard records.count < maximumRecords else {
        throw CloudFavoriteMutationLedgerError.capacityExceeded
      }
      records.append(candidate)
    }
    sort()
    return candidate
  }

  mutating func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) throws -> CloudFavoriteMutationLedgerRecord {
    let index = try index(key: key, operationID: operationID)
    try records[index].transition(to: phase, now: now)
    return records[index]
  }

  mutating func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    throws
  {
    // A previous removal may have reached rename before directory fsync failed.
    // Repeating it is safe only when absent or still the exact pending operation.
    guard records.contains(where: { $0.key == key }) else { return }
    let index = try index(key: key, operationID: operationID)
    guard records[index].phase == .dispatchPending else {
      throw CloudFavoriteMutationLedgerError.invalidTransition
    }
    records.remove(at: index)
  }

  private func index(key: CloudFavoriteMutationLedgerKey, operationID: UUID) throws -> Int {
    guard key.isValid else { throw CloudFavoriteMutationLedgerError.invalidKey }
    guard let index = records.firstIndex(where: { $0.key == key }) else {
      throw CloudFavoriteMutationLedgerError.missingRecord
    }
    guard records[index].operationID == operationID else {
      throw CloudFavoriteMutationLedgerError.operationMismatch
    }
    return index
  }
}

struct CloudFavoriteMutationLedgerHMACAuthenticator:
  ComposerImageUploadLedgerAuthenticating, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  private enum KeySource: Sendable {
    case store(any ComposerImageUploadLedgerKeyStoring)
    case fixed(Data)
  }
  private static let domain = Data(
    "TiebaPlusPlus/CloudFavoriteMutationLedger/HMAC-SHA256/v1\0".utf8)
  private let source: KeySource

  init(
    keyStore: any ComposerImageUploadLedgerKeyStoring = SystemComposerImageUploadLedgerKeyStore(
      service: "io.github.minaduki.tieba-plus-plus.cloud-favorite-mutation-ledger",
      account: "hmac-sha256-v1"
    )
  ) { source = .store(keyStore) }

  init(testingKey: Data) { source = .fixed(testingKey) }
  var description: String { "CloudFavoriteMutationLedgerHMACAuthenticator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  func authenticationCode(for canonicalPayload: Data) throws -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: Self.separated(canonicalPayload), using: SymmetricKey(data: try key(creating: true))))
  }

  func isValidAuthenticationCode(_ code: Data, for canonicalPayload: Data) throws -> Bool {
    guard code.count == 32 else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      code, authenticating: Self.separated(canonicalPayload),
      using: SymmetricKey(data: try key(creating: false)))
  }

  private func key(creating: Bool) throws -> Data {
    let value: Data?
    switch source {
    case .fixed(let data): value = data
    case .store(let store): value = try creating ? store.existingOrNewKey() : store.existingKey()
    }
    guard let value, value.count == 32 else {
      throw CloudFavoriteMutationLedgerError.authenticationUnavailable
    }
    return value
  }

  private static func separated(_ payload: Data) -> Data {
    var result = domain
    var count = UInt64(payload.count).bigEndian
    withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
  }
}

// The HMAC detects changed bytes; it does not detect rollback to an older authentic archive.
// A stable, never-unlinked flock inode serializes whole transactions across instances/processes.
actor FileCloudFavoriteMutationLedger: CloudFavoriteMutationLedgerRepository {
  static let schemaVersion = 1
  static let defaultMaximumRecords = 4_096
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024
  static let lockFilename = ".cloud-favorite-mutation-ledger.lock"

  private struct Header: Decodable { let schemaVersion: Int }
  private struct Envelope: Codable {
    let schemaVersion: Int
    let canonicalPayload: Data
    let authenticationCode: Data
  }

  private let fileURL: URL
  private let authenticator: any ComposerImageUploadLedgerAuthenticating
  private let maximumRecords: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync: @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
  private let onExclusiveLockContention: @Sendable () -> Void

  init(
    fileURL: URL, authenticator: (any ComposerImageUploadLedgerAuthenticating)? = nil,
    testingKey: Data? = nil, maximumRecords: Int = defaultMaximumRecords,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (@Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void)? = nil,
    onExclusiveLockContention: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL.standardizedFileURL
    if let authenticator {
      self.authenticator = authenticator
    } else if let testingKey {
      self.authenticator = CloudFavoriteMutationLedgerHMACAuthenticator(testingKey: testingKey)
    } else {
      self.authenticator = CloudFavoriteMutationLedgerHMACAuthenticator()
    }
    self.maximumRecords = max(1, maximumRecords)
    self.maximumArchiveBytes = max(1_024, maximumArchiveBytes)
    self.prepareStagedFile = prepareStagedFile ?? { try Self.applyStorageAttributes(to: $0) }
    self.beforeDurabilitySync = beforeDurabilitySync ?? { _ in }
    self.onExclusiveLockContention = onExclusiveLockContention ?? {}
  }

  static func live(fileManager: FileManager = .default) -> FileCloudFavoriteMutationLedger {
    guard
      let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return Self(
        fileURL: URL(fileURLWithPath: "/dev/null/cloud-favorite-mutation-ledger-unavailable.json"))
    }
    return Self(
      fileURL: support.appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("cloud-favorite-mutation-ledger-v1.json"))
  }

  func record(for key: CloudFavoriteMutationLedgerKey) async throws
    -> CloudFavoriteMutationLedgerRecord?
  {
    guard key.isValid else { throw CloudFavoriteMutationLedgerError.invalidKey }
    return try await withExclusiveLock { try loadArchive().records.first { $0.key == key } }
  }

  func records() async throws -> [CloudFavoriteMutationLedgerRecord] {
    try await withExclusiveLock { try loadArchive().records }
  }

  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try await withExclusiveLock {
      var archive = try loadArchive()
      let record = try archive.prepare(
        key: key, operationID: operationID,
        sessionRevision: sessionRevision, now: now, maximumRecords: maximumRecords)
      try commit(archive)
      return record
    }
  }

  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) async throws -> CloudFavoriteMutationLedgerRecord {
    try await withExclusiveLock {
      var archive = try loadArchive()
      let record = try archive.transition(
        key: key, operationID: operationID, phase: phase, now: now)
      // Re-sync even an identical result: a previous commit could have renamed
      // the file successfully but failed its final durability sync.
      try commit(archive)
      return record
    }
  }

  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID)
    async throws
  {
    try await withExclusiveLock {
      var archive = try loadArchive()
      try archive.removeAfterDefiniteFailure(key: key, operationID: operationID)
      try commit(archive)
    }
  }

  private func loadArchive() throws -> CloudFavoriteMutationLedgerArchive {
    guard let status = try Self.status(at: fileURL) else { return .init() }
    guard Self.fileType(status) == mode_t(S_IFREG), status.st_uid == Darwin.geteuid(),
      status.st_nlink == 1
    else {
      throw CloudFavoriteMutationLedgerError.unsafeStorage
    }
    guard status.st_size > 0 else { throw CloudFavoriteMutationLedgerError.corruptedArchive }
    guard status.st_size <= maximumArchiveBytes else {
      throw CloudFavoriteMutationLedgerError.capacityExceeded
    }
    let data: Data
    do {
      data = try ComposerSecureRegularFileReader.read(
        from: fileURL, expectedByteCount: Int64(status.st_size),
        maximumByteCount: Int64(maximumArchiveBytes), checksCancellation: false)
    } catch { throw CloudFavoriteMutationLedgerError.readFailed }
    let decoder = JSONDecoder()
    let envelope: Envelope
    do {
      guard try decoder.decode(Header.self, from: data).schemaVersion == Self.schemaVersion else {
        throw CloudFavoriteMutationLedgerError.unsupportedSchema
      }
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch let error as CloudFavoriteMutationLedgerError { throw error } catch {
      throw CloudFavoriteMutationLedgerError.corruptedArchive
    }
    guard envelope.canonicalPayload.count <= maximumArchiveBytes else {
      throw CloudFavoriteMutationLedgerError.capacityExceeded
    }
    let authenticated: Bool
    do {
      authenticated = try authenticator.isValidAuthenticationCode(
        envelope.authenticationCode, for: envelope.canonicalPayload)
    } catch { throw CloudFavoriteMutationLedgerError.authenticationUnavailable }
    guard authenticated else { throw CloudFavoriteMutationLedgerError.corruptedArchive }
    let archive: CloudFavoriteMutationLedgerArchive
    do {
      archive = try decoder.decode(
        CloudFavoriteMutationLedgerArchive.self, from: envelope.canonicalPayload)
    } catch { throw CloudFavoriteMutationLedgerError.corruptedArchive }
    try archive.validate(maximumRecords: maximumRecords)
    var canonical = archive
    canonical.sort()
    // Reject extra, duplicate, null or noncanonical fields even in an authenticated archive.
    guard try Self.encoder().encode(canonical) == envelope.canonicalPayload,
      try Self.encoder().encode(envelope) == data
    else { throw CloudFavoriteMutationLedgerError.corruptedArchive }
    return archive
  }

  private func commit(_ archive: CloudFavoriteMutationLedgerArchive) throws {
    try archive.validate(maximumRecords: maximumRecords)
    let payload = try Self.encoder().encode(archive)
    guard payload.count <= maximumArchiveBytes else {
      throw CloudFavoriteMutationLedgerError.capacityExceeded
    }
    let code: Data
    do { code = try authenticator.authenticationCode(for: payload) } catch {
      throw CloudFavoriteMutationLedgerError.authenticationUnavailable
    }
    let data = try Self.encoder().encode(
      Envelope(
        schemaVersion: Self.schemaVersion, canonicalPayload: payload, authenticationCode: code))
    guard data.count <= maximumArchiveBytes else {
      throw CloudFavoriteMutationLedgerError.capacityExceeded
    }
    do {
      try ComposerDurableFileWriter(
        targetURL: fileURL, maximumByteCount: maximumArchiveBytes,
        stagedFilenamePrefix: ".cloud-favorite-mutation-ledger-",
        prepareStorageDirectory: { try Self.applyStorageAttributes(to: $0) },
        prepareStagedFile: prepareStagedFile, beforeDurabilitySync: beforeDurabilitySync
      ).persist(data)
    } catch { throw CloudFavoriteMutationLedgerError.writeFailed }
  }

  private func withExclusiveLock<Result>(_ operation: () throws -> Result) async throws -> Result {
    let directory = fileURL.deletingLastPathComponent()
    let expected = try ensureStorageDirectory(directory)
    var directoryDescriptor: Int32 = -1
    var lockDescriptor: Int32 = -1
    var locked = false
    defer {
      if locked { Self.releaseLock(lockDescriptor) }
      if lockDescriptor >= 0 { _ = Darwin.close(lockDescriptor) }
      if directoryDescriptor >= 0 { _ = Darwin.close(directoryDescriptor) }
    }
    directoryDescriptor = directory.withUnsafeFileSystemRepresentation {
      guard let path = $0 else { return -1 }
      return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    var opened = stat()
    guard directoryDescriptor >= 0, Darwin.fstat(directoryDescriptor, &opened) == 0,
      Self.sameItem(opened, expected), Self.isOwnedDirectory(opened)
    else { throw CloudFavoriteMutationLedgerError.unsafeStorage }
    lockDescriptor = Self.lockFilename.withCString {
      Darwin.openat(
        directoryDescriptor, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
        mode_t(S_IRUSR | S_IWUSR))
    }
    guard lockDescriptor >= 0 else { throw CloudFavoriteMutationLedgerError.unsafeStorage }
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    var reportedContention = false
    for retry in 0...500 {
      try Task.checkCancellation()
      if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 {
        locked = true
        break
      }
      guard errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN, retry < 500 else {
        throw CloudFavoriteMutationLedgerError.unsafeStorage
      }
      if !reportedContention {
        onExclusiveLockContention()
        reportedContention = true
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard locked else { throw CloudFavoriteMutationLedgerError.unsafeStorage }
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    try Self.verifyDirectory(directory, expected: expected)
    let result = try operation()
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    try Self.verifyDirectory(directory, expected: expected)
    return result
  }

  private func ensureStorageDirectory(_ url: URL) throws -> stat {
    guard fileURL.isFileURL, url.isFileURL, !fileURL.lastPathComponent.isEmpty,
      ![".", "..", Self.lockFilename].contains(fileURL.lastPathComponent),
      !fileURL.lastPathComponent.utf8.contains(0)
    else { throw CloudFavoriteMutationLedgerError.unsafeStorage }
    do {
      if let existing = try Self.status(at: url) {
        guard Self.isOwnedDirectory(existing) else {
          throw CloudFavoriteMutationLedgerError.unsafeStorage
        }
      } else {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      guard let before = try Self.status(at: url), Self.isOwnedDirectory(before) else {
        throw CloudFavoriteMutationLedgerError.unsafeStorage
      }
      try Self.applyStorageAttributes(to: url)
      try Self.verifyDirectory(url, expected: before)
      return before
    } catch { throw CloudFavoriteMutationLedgerError.unsafeStorage }
  }

  private static func verifyDirectory(_ url: URL, expected: stat) throws {
    guard let current = try status(at: url), sameItem(current, expected), isOwnedDirectory(current)
    else {
      throw CloudFavoriteMutationLedgerError.unsafeStorage
    }
  }

  private static func verifyLock(_ descriptor: Int32, directoryDescriptor: Int32) throws {
    var opened = stat()
    var linked = stat()
    let result = lockFilename.withCString {
      Darwin.fstatat(directoryDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
    }
    guard Darwin.fstat(descriptor, &opened) == 0, result == 0,
      fileType(opened) == mode_t(S_IFREG), fileType(linked) == mode_t(S_IFREG),
      sameItem(opened, linked),
      opened.st_uid == Darwin.geteuid(), opened.st_nlink == 1,
      opened.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO) == mode_t(S_IRUSR | S_IWUSR)
    else { throw CloudFavoriteMutationLedgerError.unsafeStorage }
  }

  private static func releaseLock(_ descriptor: Int32) {
    for _ in 0...500 { if flock(descriptor, LOCK_UN) == 0 || errno != EINTR { return } }
  }

  private static func status(at url: URL) throws -> stat? {
    var result = stat()
    let code = url.withUnsafeFileSystemRepresentation {
      guard let path = $0 else { return Int32(-1) }
      return Darwin.lstat(path, &result)
    }
    if code == 0 { return result }
    if errno == ENOENT { return nil }
    throw CloudFavoriteMutationLedgerError.readFailed
  }

  private static func isOwnedDirectory(_ value: stat) -> Bool {
    fileType(value) == mode_t(S_IFDIR) && value.st_uid == Darwin.geteuid()
      && value.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
  }
  private static func fileType(_ value: stat) -> mode_t { value.st_mode & mode_t(S_IFMT) }
  private static func sameItem(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
  private static func applyStorageAttributes(to url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
  }
  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

actor TransientCloudFavoriteMutationLedger: CloudFavoriteMutationLedgerRepository {
  private var archive = CloudFavoriteMutationLedgerArchive()
  private let maximumRecords: Int

  init(maximumRecords: Int = FileCloudFavoriteMutationLedger.defaultMaximumRecords) {
    self.maximumRecords = max(1, maximumRecords)
  }

  func record(for key: CloudFavoriteMutationLedgerKey) throws -> CloudFavoriteMutationLedgerRecord?
  {
    guard key.isValid else { throw CloudFavoriteMutationLedgerError.invalidKey }
    return archive.records.first { $0.key == key }
  }

  func records() -> [CloudFavoriteMutationLedgerRecord] { archive.records }

  func prepare(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID, sessionRevision: UUID, now: Date
  ) throws -> CloudFavoriteMutationLedgerRecord {
    try archive.prepare(
      key: key, operationID: operationID, sessionRevision: sessionRevision,
      now: now, maximumRecords: maximumRecords)
  }

  func transition(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID,
    phase: CloudFavoriteMutationLedgerPhase, now: Date
  ) throws -> CloudFavoriteMutationLedgerRecord {
    try archive.transition(key: key, operationID: operationID, phase: phase, now: now)
  }

  func removeAfterDefiniteFailure(key: CloudFavoriteMutationLedgerKey, operationID: UUID) throws {
    try archive.removeAfterDefiniteFailure(key: key, operationID: operationID)
  }
}
