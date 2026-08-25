import Foundation

struct FollowedForumPinKey: Hashable, Sendable {
  let accountID: Int64
  let forumID: Int64
}

struct FollowedForumPin: Codable, Equatable, Sendable {
  static let maximumForumNameCharacterCount = 255
  static let maximumForumNameUTF8ByteCount = 1_024

  let accountID: Int64
  let forumID: Int64
  let forumName: String
  let pinnedAt: Date

  private enum CodingKeys: String, CodingKey {
    case accountID
    case forumID
    case forumName
    case pinnedAt
  }

  var key: FollowedForumPinKey {
    FollowedForumPinKey(accountID: accountID, forumID: forumID)
  }

  init?(
    accountID: Int64,
    forumID: Int64,
    forumName: String,
    pinnedAt: Date
  ) {
    guard
      accountID > 0,
      forumID > 0,
      let forumName = Self.normalizedForumName(forumName),
      pinnedAt.timeIntervalSinceReferenceDate.isFinite
    else { return nil }
    self.accountID = accountID
    self.forumID = forumID
    self.forumName = forumName
    self.pinnedAt = pinnedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let accountID = try container.decode(Int64.self, forKey: .accountID)
    let forumID = try container.decode(Int64.self, forKey: .forumID)
    let forumName = try container.decode(String.self, forKey: .forumName)
    let pinnedAt = try container.decode(Date.self, forKey: .pinnedAt)
    guard
      let pin = Self(
        accountID: accountID,
        forumID: forumID,
        forumName: forumName,
        pinnedAt: pinnedAt
      )
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .forumName,
        in: container,
        debugDescription: "Invalid followed-forum pin"
      )
    }
    self = pin
  }

  static func normalizedForumName(_ forumName: String) -> String? {
    let trimmed = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed.count <= maximumForumNameCharacterCount,
      trimmed.utf8.count <= maximumForumNameUTF8ByteCount,
      !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }

    let normalized = trimmed
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
    guard
      !normalized.isEmpty,
      normalized.count <= maximumForumNameCharacterCount,
      normalized.utf8.count <= maximumForumNameUTF8ByteCount,
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return normalized
  }
}

enum FollowedForumPinsStoreError: LocalizedError, Equatable, Sendable {
  case invalidAccount
  case invalidForum
  case tooManyPins
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidAccount:
      "置顶贴吧缺少有效的账户标识。"
    case .invalidForum:
      "置顶贴吧缺少有效的贴吧标识或吧名。"
    case .tooManyPins:
      "该账户的置顶贴吧数量已达到安全上限。"
    case .archiveTooLarge:
      "置顶贴吧文件超过安全大小限制。"
    case .corruptedArchive:
      "置顶贴吧文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "置顶贴吧来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取置顶贴吧。"
    case .writeFailed:
      "无法保存置顶贴吧。"
    }
  }
}

protocol FollowedForumPinsRepository: Sendable {
  func pins(accountID: Int64) async throws -> [FollowedForumPin]
  func setPin(
    accountID: Int64,
    forumID: Int64,
    forumName: String,
    pinnedAt: Date
  ) async throws
  func removePin(accountID: Int64, forumID: Int64) async throws
}

extension FollowedForumPinsRepository {
  func setPin(
    accountID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws {
    try await setPin(
      accountID: accountID,
      forumID: forumID,
      forumName: forumName,
      pinnedAt: Date()
    )
  }
}

actor FileFollowedForumPinsStore: FollowedForumPinsRepository {
  static let schemaVersion = 1
  static let defaultMaximumPinsPerAccount = 200
  static let defaultMaximumTotalPins = 2_000
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024

  private struct Archive: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var pins: [FollowedForumPin]

    static var empty: Self {
      Archive(schemaVersion: FileFollowedForumPinsStore.schemaVersion, pins: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumPinsPerAccount: Int
  private let maximumTotalPins: Int
  private let maximumArchiveBytes: Int
  private var cachedArchive: Archive?

  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumPinsPerAccount: Int = defaultMaximumPinsPerAccount,
    maximumTotalPins: Int = defaultMaximumTotalPins,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumPinsPerAccount = max(maximumPinsPerAccount, 1)
    self.maximumTotalPins = max(maximumTotalPins, self.maximumPinsPerAccount)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileFollowedForumPinsStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileFollowedForumPinsStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("followed-forum-pins.json", isDirectory: false)
    )
  }

  func pins(accountID: Int64) async throws -> [FollowedForumPin] {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    return try loadArchive().pins
      .filter { $0.accountID == accountID }
      .sorted(by: Self.appearsEarlier)
  }

  func setPin(
    accountID: Int64,
    forumID: Int64,
    forumName: String,
    pinnedAt: Date
  ) async throws {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    guard
      let pin = FollowedForumPin(
        accountID: accountID,
        forumID: forumID,
        forumName: forumName,
        pinnedAt: pinnedAt
      )
    else { throw FollowedForumPinsStoreError.invalidForum }

    var candidate = try loadArchive()
    let existingIndex = candidate.pins.firstIndex { $0.key == pin.key }
    if let existingIndex {
      candidate.pins[existingIndex] = pin
    } else {
      let accountPinCount = candidate.pins.lazy.filter { $0.accountID == accountID }.count
      guard
        accountPinCount < maximumPinsPerAccount,
        candidate.pins.count < maximumTotalPins
      else { throw FollowedForumPinsStoreError.tooManyPins }
      candidate.pins.append(pin)
    }
    candidate.pins.sort(by: Self.appearsEarlier)
    try commit(candidate)
  }

  func removePin(accountID: Int64, forumID: Int64) async throws {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    guard forumID > 0 else { throw FollowedForumPinsStoreError.invalidForum }
    var candidate = try loadArchive()
    let oldCount = candidate.pins.count
    candidate.pins.removeAll {
      $0.accountID == accountID && $0.forumID == forumID
    }
    guard candidate.pins.count != oldCount else { return }
    try commit(candidate)
  }

  private func loadArchive() throws -> Archive {
    if let cachedArchive { return cachedArchive }
    var archive = try fileManager.fileExists(atPath: fileURL.path)
      ? decodedArchiveFromDisk()
      : Archive.empty
    archive.pins = try normalized(archive.pins)
    cachedArchive = archive
    return archive
  }

  private func decodedArchiveFromDisk() throws -> Archive {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw FollowedForumPinsStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw FollowedForumPinsStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw FollowedForumPinsStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw FollowedForumPinsStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }
    do {
      return try decoder.decode(Archive.self, from: data)
    } catch {
      throw FollowedForumPinsStoreError.corruptedArchive
    }
  }

  private func normalized(_ pins: [FollowedForumPin]) throws -> [FollowedForumPin] {
    var newestByKey: [FollowedForumPinKey: FollowedForumPin] = [:]
    for pin in pins.sorted(by: Self.appearsEarlier)
    where newestByKey[pin.key] == nil {
      newestByKey[pin.key] = pin
    }
    let normalizedPins = newestByKey.values.sorted(by: Self.appearsEarlier)
    guard normalizedPins.count <= maximumTotalPins else {
      throw FollowedForumPinsStoreError.corruptedArchive
    }
    let accountCounts = Dictionary(grouping: normalizedPins, by: \.accountID).mapValues(\.count)
    guard accountCounts.values.allSatisfy({ $0 <= maximumPinsPerAccount }) else {
      throw FollowedForumPinsStoreError.corruptedArchive
    }
    return normalizedPins
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw FollowedForumPinsStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw FollowedForumPinsStoreError.archiveTooLarge
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    let stagedURL = directoryURL.appendingPathComponent(
      ".followed-forum-pins-\(UUID().uuidString).staged",
      isDirectory: false
    )
    var didAttemptCommit = false
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try data.write(to: stagedURL, options: .atomic)
      try Self.applyStorageAttributes(to: stagedURL)
      if fileManager.fileExists(atPath: fileURL.path) {
        didAttemptCommit = true
        _ = try fileManager.replaceItemAt(
          fileURL,
          withItemAt: stagedURL,
          backupItemName: nil,
          options: [.usingNewMetadataOnly]
        )
      } else {
        didAttemptCommit = true
        try fileManager.moveItem(at: stagedURL, to: fileURL)
      }
    } catch {
      try? fileManager.removeItem(at: stagedURL)
      guard didAttemptCommit, targetArchiveMatches(data) else {
        throw FollowedForumPinsStoreError.writeFailed
      }
    }
    cachedArchive = candidate
  }

  private func targetArchiveMatches(_ expected: Data) -> Bool {
    guard
      let actual = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
      actual.count <= maximumArchiveBytes
    else { return false }
    return actual == expected
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

  private static func appearsEarlier(
    _ lhs: FollowedForumPin,
    _ rhs: FollowedForumPin
  ) -> Bool {
    if lhs.pinnedAt != rhs.pinnedAt { return lhs.pinnedAt > rhs.pinnedAt }
    if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
    if lhs.forumID != rhs.forumID { return lhs.forumID < rhs.forumID }
    return lhs.forumName < rhs.forumName
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

actor TransientFollowedForumPinsStore: FollowedForumPinsRepository {
  private var storedPins: [FollowedForumPin] = []

  func pins(accountID: Int64) async throws -> [FollowedForumPin] {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    return storedPins
      .filter { $0.accountID == accountID }
      .sorted {
        if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
        return $0.forumID < $1.forumID
      }
  }

  func setPin(
    accountID: Int64,
    forumID: Int64,
    forumName: String,
    pinnedAt: Date
  ) async throws {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    guard
      let pin = FollowedForumPin(
        accountID: accountID,
        forumID: forumID,
        forumName: forumName,
        pinnedAt: pinnedAt
      )
    else { throw FollowedForumPinsStoreError.invalidForum }
    storedPins.removeAll { $0.key == pin.key }
    storedPins.append(pin)
  }

  func removePin(accountID: Int64, forumID: Int64) async throws {
    guard accountID > 0 else { throw FollowedForumPinsStoreError.invalidAccount }
    guard forumID > 0 else { throw FollowedForumPinsStoreError.invalidForum }
    storedPins.removeAll { $0.accountID == accountID && $0.forumID == forumID }
  }
}

struct FollowedForumsProjection: Equatable, Sendable {
  let pinned: [FollowedForumItem]
  let unpinned: [FollowedForumItem]

  var all: [FollowedForumItem] { pinned + unpinned }
}

enum FollowedForumPinProjection {
  static func make(
    forums: [FollowedForumItem],
    pins: [FollowedForumPin],
    accountID: Int64
  ) -> FollowedForumsProjection {
    guard accountID > 0 else {
      return FollowedForumsProjection(
        pinned: [],
        unpinned: uniqueForumsPreservingOrder(forums)
      )
    }

    var newestPinByForumID: [Int64: FollowedForumPin] = [:]
    for pin in pins where pin.accountID == accountID {
      if let existing = newestPinByForumID[pin.forumID] {
        if existing.pinnedAt > pin.pinnedAt { continue }
        if existing.pinnedAt == pin.pinnedAt, existing.forumName <= pin.forumName {
          continue
        }
      }
      newestPinByForumID[pin.forumID] = pin
    }

    var seenForumIDs = Set<Int64>()
    var pinnedRows = [(forum: FollowedForumItem, pin: FollowedForumPin, index: Int)]()
    var unpinned = [FollowedForumItem]()
    for (index, forum) in forums.enumerated() where seenForumIDs.insert(forum.id).inserted {
      if
        let pin = newestPinByForumID[forum.id],
        FollowedForumPin.normalizedForumName(forum.name) == pin.forumName
      {
        pinnedRows.append((forum, pin, index))
      } else {
        unpinned.append(forum)
      }
    }
    pinnedRows.sort {
      if $0.pin.pinnedAt != $1.pin.pinnedAt {
        return $0.pin.pinnedAt > $1.pin.pinnedAt
      }
      if $0.index != $1.index { return $0.index < $1.index }
      return $0.forum.id < $1.forum.id
    }
    return FollowedForumsProjection(
      pinned: pinnedRows.map { $0.forum },
      unpinned: unpinned
    )
  }

  private static func uniqueForumsPreservingOrder(
    _ forums: [FollowedForumItem]
  ) -> [FollowedForumItem] {
    var seen = Set<Int64>()
    return forums.filter { seen.insert($0.id).inserted }
  }
}
