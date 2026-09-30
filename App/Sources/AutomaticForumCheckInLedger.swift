import CryptoKit
import Darwin
import Foundation

struct AutomaticForumCheckInLedgerHMACAuthenticator:
  ComposerImageUploadLedgerAuthenticating, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private enum KeySource: Sendable {
    case store(any ComposerImageUploadLedgerKeyStoring)
    case fixed(Data)
  }
  private static let domain = Data(
    "TiebaPlusPlus/AutomaticForumCheckInLedger/HMAC-SHA256/v1\0".utf8)
  private let source: KeySource

  init(
    keyStore: any ComposerImageUploadLedgerKeyStoring = SystemComposerImageUploadLedgerKeyStore(
      service: "io.github.minaduki.tieba-plus-plus.automatic-forum-check-in-ledger",
      account: "hmac-sha256-v1"
    )
  ) { source = .store(keyStore) }

  init(testingKey: Data) { source = .fixed(testingKey) }

  var description: String { "AutomaticForumCheckInLedgerHMACAuthenticator(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  func authenticationCode(for canonicalPayload: Data) throws -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: Self.separated(canonicalPayload), using: SymmetricKey(data: try key(creating: true))
      ))
  }

  func isValidAuthenticationCode(_ code: Data, for canonicalPayload: Data) throws -> Bool {
    guard code.count == 32 else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      code, authenticating: Self.separated(canonicalPayload),
      using: SymmetricKey(data: try key(creating: false))
    )
  }

  private func key(creating: Bool) throws -> Data {
    let value: Data?
    switch source {
    case .fixed(let data): value = data
    case .store(let store):
      value = try creating ? store.existingOrNewKey() : store.existingKey()
    }
    guard let value, value.count == 32 else {
      throw AutomaticForumCheckInLedgerError.authenticationUnavailable
    }
    return value
  }

  private static func separated(_ payload: Data) -> Data {
    var data = domain
    var count = UInt64(payload.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
  }
}

// Authentication detects byte changes, not rollback to an older authentic file.
// Keeping a stable, never-unlinked lock inode makes read/modify/durable-write
// transactions safe across actors and app processes sharing this container.
actor FileAutomaticForumCheckInLedger: AutomaticForumCheckInLedgerRepository {
  static let schemaVersion = 1
  static let defaultMaximumEntries = 32_768
  static let defaultMaximumArchiveBytes = 8 * 1_024 * 1_024
  static let lockFilename = ".automatic-forum-check-in-ledger.lock"

  private struct Header: Decodable { let schemaVersion: Int }
  private struct Envelope: Codable {
    let schemaVersion: Int
    let canonicalPayload: Data
    let authenticationCode: Data
  }

  private let fileURL: URL
  private let authenticator: any ComposerImageUploadLedgerAuthenticating
  private let maximumEntries: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync: @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
  private let onExclusiveLockContention: @Sendable () -> Void

  init(
    fileURL: URL,
    authenticator: (any ComposerImageUploadLedgerAuthenticating)? = nil,
    testingKey: Data? = nil,
    maximumEntries: Int = defaultMaximumEntries,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (@Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void)? = nil,
    onExclusiveLockContention: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL.standardizedFileURL
    if let authenticator {
      self.authenticator = authenticator
    } else if let testingKey {
      self.authenticator = AutomaticForumCheckInLedgerHMACAuthenticator(testingKey: testingKey)
    } else {
      self.authenticator = AutomaticForumCheckInLedgerHMACAuthenticator()
    }
    self.maximumEntries = max(maximumEntries, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.prepareStagedFile = prepareStagedFile ?? { try Self.applyStorageAttributes(to: $0) }
    self.beforeDurabilitySync = beforeDurabilitySync ?? { _ in }
    self.onExclusiveLockContention = onExclusiveLockContention ?? {}
  }

  static func live(fileManager: FileManager = .default) -> FileAutomaticForumCheckInLedger {
    guard
      let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return Self(fileURL: URL(fileURLWithPath: "/dev/null/automatic-check-in-unavailable.json"))
    }
    return Self(
      fileURL: support.appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("automatic-forum-check-in-ledger-v1.json"))
  }

  func load(userID: Int64, day: String) async throws -> AutomaticForumCheckInDayRecord? {
    try await withExclusiveLock {
      try AutomaticForumCheckInLedgerModel.load(loadArchive(), userID: userID, day: day)
    }
  }

  func claimTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await mutate {
      try AutomaticForumCheckInLedgerModel.claim(
        &$0, userID: userID, day: day, runID: runID, targets: targets, at: date
      )
    }
  }

  func settleResults(
    userID: Int64, day: String, runID: UUID, results: [AutomaticForumCheckInTargetResult],
    at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await mutate {
      try AutomaticForumCheckInLedgerModel.settle(
        &$0, userID: userID, day: day, runID: runID, results: results, at: date
      )
    }
  }

  func releaseUndispatchedTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await mutate {
      try AutomaticForumCheckInLedgerModel.releaseUndispatched(
        &$0, userID: userID, day: day, runID: runID, targets: targets, at: date
      )
    }
  }

  func confirmReadBack(
    userID: Int64, day: String, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await mutate {
      try AutomaticForumCheckInLedgerModel.confirmReadBack(
        &$0, userID: userID, day: day, targets: targets, at: date
      )
    }
  }

  func finishDay(
    userID: Int64, day: String, runID: UUID, state: AutomaticForumCheckInDayState,
    pausedReason: String? = nil, at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await mutate {
      try AutomaticForumCheckInLedgerModel.finishDay(
        &$0, userID: userID, day: day, runID: runID, state: state, pausedReason: pausedReason,
        at: date
      )
    }
  }

  private func mutate(
    _ operation: (inout AutomaticForumCheckInLedgerArchive) throws -> AutomaticForumCheckInDayRecord
  ) async throws -> AutomaticForumCheckInDayRecord {
    try await withExclusiveLock {
      var archive = try loadArchive()
      let result = try operation(&archive)
      try commit(archive)
      return result
    }
  }

  private func loadArchive() throws -> AutomaticForumCheckInLedgerArchive {
    guard let status = try Self.status(at: fileURL) else { return .empty }
    guard Self.fileType(status) == mode_t(S_IFREG) else {
      throw AutomaticForumCheckInLedgerError.unsafeStorage
    }
    guard status.st_size > 0 else { throw AutomaticForumCheckInLedgerError.corruptedArchive }
    guard status.st_size <= maximumArchiveBytes else {
      throw AutomaticForumCheckInLedgerError.capacityExceeded
    }
    let data: Data
    do {
      data = try ComposerSecureRegularFileReader.read(
        from: fileURL, expectedByteCount: Int64(status.st_size),
        maximumByteCount: Int64(maximumArchiveBytes), checksCancellation: false
      )
    } catch { throw AutomaticForumCheckInLedgerError.readFailed }
    let decoder = JSONDecoder()
    let envelope: Envelope
    do {
      let header = try decoder.decode(Header.self, from: data)
      guard header.schemaVersion == Self.schemaVersion else {
        throw AutomaticForumCheckInLedgerError.unsupportedSchemaVersion(header.schemaVersion)
      }
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch let error as AutomaticForumCheckInLedgerError { throw error } catch {
      throw AutomaticForumCheckInLedgerError.corruptedArchive
    }
    guard envelope.canonicalPayload.count <= maximumArchiveBytes else {
      throw AutomaticForumCheckInLedgerError.capacityExceeded
    }
    let authenticated: Bool
    do {
      authenticated = try authenticator.isValidAuthenticationCode(
        envelope.authenticationCode, for: envelope.canonicalPayload
      )
    } catch { throw AutomaticForumCheckInLedgerError.authenticationUnavailable }
    guard authenticated else { throw AutomaticForumCheckInLedgerError.authenticationFailed }
    let archive: AutomaticForumCheckInLedgerArchive
    do {
      archive = try decoder.decode(
        AutomaticForumCheckInLedgerArchive.self, from: envelope.canonicalPayload)
    } catch { throw AutomaticForumCheckInLedgerError.corruptedArchive }
    try AutomaticForumCheckInLedgerModel.validate(archive, maximumEntries: maximumEntries)
    var canonical = archive
    AutomaticForumCheckInLedgerModel.sort(&canonical)
    // Exact re-encoding rejects extra/null/duplicate JSON fields and noncanonical numbers,
    // including in the authenticated payload. Unknown records never become an empty ledger.
    guard try Self.encoder().encode(canonical) == envelope.canonicalPayload,
      try Self.encoder().encode(envelope) == data
    else { throw AutomaticForumCheckInLedgerError.corruptedArchive }
    return archive
  }

  private func commit(_ proposed: AutomaticForumCheckInLedgerArchive) throws {
    var archive = proposed
    AutomaticForumCheckInLedgerModel.sort(&archive)
    try AutomaticForumCheckInLedgerModel.validate(archive, maximumEntries: maximumEntries)
    let payload = try Self.encoder().encode(archive)
    guard payload.count <= maximumArchiveBytes else {
      throw AutomaticForumCheckInLedgerError.capacityExceeded
    }
    let code: Data
    do { code = try authenticator.authenticationCode(for: payload) } catch {
      throw AutomaticForumCheckInLedgerError.authenticationUnavailable
    }
    let data = try Self.encoder().encode(
      Envelope(
        schemaVersion: Self.schemaVersion, canonicalPayload: payload, authenticationCode: code
      ))
    guard data.count <= maximumArchiveBytes else {
      throw AutomaticForumCheckInLedgerError.capacityExceeded
    }
    do {
      try ComposerDurableFileWriter(
        targetURL: fileURL, maximumByteCount: maximumArchiveBytes,
        stagedFilenamePrefix: ".automatic-forum-check-in-ledger-",
        prepareStorageDirectory: { try Self.applyStorageAttributes(to: $0) },
        prepareStagedFile: prepareStagedFile, beforeDurabilitySync: beforeDurabilitySync
      ).persist(data)
    } catch { throw AutomaticForumCheckInLedgerError.writeFailed }
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
    else { throw AutomaticForumCheckInLedgerError.unsafeStorage }
    lockDescriptor = Self.lockFilename.withCString {
      Darwin.openat(
        directoryDescriptor, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
        mode_t(S_IRUSR | S_IWUSR))
    }
    guard lockDescriptor >= 0 else { throw AutomaticForumCheckInLedgerError.unsafeStorage }
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    var reportedContention = false
    for retry in 0...500 {
      try Task.checkCancellation()
      if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 {
        locked = true
        break
      }
      guard errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN, retry < 500 else {
        throw AutomaticForumCheckInLedgerError.unsafeStorage
      }
      if !reportedContention {
        onExclusiveLockContention()
        reportedContention = true
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard locked else { throw AutomaticForumCheckInLedgerError.unsafeStorage }
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    try Self.verifyDirectory(directory, expected: expected)
    let result = try operation()
    try Self.verifyLock(lockDescriptor, directoryDescriptor: directoryDescriptor)
    try Self.verifyDirectory(directory, expected: expected)
    return result
  }

  private func ensureStorageDirectory(_ url: URL) throws -> stat {
    guard fileURL.isFileURL, url.isFileURL,
      !fileURL.lastPathComponent.isEmpty, ![".", ".."].contains(fileURL.lastPathComponent),
      !fileURL.lastPathComponent.utf8.contains(0)
    else { throw AutomaticForumCheckInLedgerError.unsafeStorage }
    do {
      if let existing = try Self.status(at: url) {
        guard Self.isOwnedDirectory(existing) else {
          throw AutomaticForumCheckInLedgerError.unsafeStorage
        }
      } else {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      guard let before = try Self.status(at: url), Self.isOwnedDirectory(before) else {
        throw AutomaticForumCheckInLedgerError.unsafeStorage
      }
      try Self.applyStorageAttributes(to: url)
      try Self.verifyDirectory(url, expected: before)
      return before
    } catch { throw AutomaticForumCheckInLedgerError.unsafeStorage }
  }

  private static func verifyDirectory(_ url: URL, expected: stat) throws {
    guard let current = try status(at: url), sameItem(current, expected), isOwnedDirectory(current)
    else {
      throw AutomaticForumCheckInLedgerError.unsafeStorage
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
    else { throw AutomaticForumCheckInLedgerError.unsafeStorage }
  }

  private static func releaseLock(_ descriptor: Int32) {
    for _ in 0...500 {
      if flock(descriptor, LOCK_UN) == 0 || errno != EINTR { return }
    }
  }

  private static func status(at url: URL) throws -> stat? {
    var result = stat()
    let code = url.withUnsafeFileSystemRepresentation {
      guard let path = $0 else { return Int32(-1) }
      return Darwin.lstat(path, &result)
    }
    if code == 0 { return result }
    if errno == ENOENT { return nil }
    throw AutomaticForumCheckInLedgerError.readFailed
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
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
      )
    #endif
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
