import Foundation

struct ForumSearchHistoryEntry: Codable, Hashable, Identifiable, Sendable {
  let forumName: String
  let query: String
  let searchedAt: Date

  var id: String {
    let forumKey = Self.normalizedIdentityComponent(forumName)
    let queryKey = Self.normalizedIdentityComponent(query)
    return "forum:\(forumKey.utf8.count):\(forumKey)|query:\(queryKey)"
  }

  init(forumName: String, query: String, searchedAt: Date) {
    self.forumName = Self.trimmed(forumName)
    self.query = Self.trimmed(query)
    self.searchedAt = searchedAt
  }

  private enum CodingKeys: String, CodingKey {
    case forumName
    case query
    case searchedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      forumName: try container.decode(String.self, forKey: .forumName),
      query: try container.decode(String.self, forKey: .query),
      searchedAt: try container.decode(Date.self, forKey: .searchedAt)
    )
  }

  static func normalizedIdentityComponent(_ value: String) -> String {
    trimmed(value)
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum ForumSearchHistoryStoreError: LocalizedError, Equatable, Sendable {
  case invalidEntry
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidEntry:
      "搜索记录缺少有效的贴吧名或搜索词。"
    case .archiveTooLarge:
      "吧内搜索历史文件超过安全大小限制。"
    case .corruptedArchive:
      "吧内搜索历史文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "吧内搜索历史来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取吧内搜索历史。"
    case .writeFailed:
      "无法保存吧内搜索历史。"
    }
  }
}

protocol ForumSearchHistoryRepository: Sendable {
  func entries(forumName: String) async throws -> [ForumSearchHistoryEntry]
  func record(query: String, forumName: String, at date: Date) async throws
  func delete(id: String) async throws
  func deleteAll(forumName: String) async throws
  func reset() async throws
}

extension ForumSearchHistoryRepository {
  func record(query: String, forumName: String) async throws {
    try await record(query: query, forumName: forumName, at: Date())
  }
}

actor FileForumSearchHistoryStore: ForumSearchHistoryRepository {
  static let schemaVersion = 1
  static let defaultMaximumEntriesPerForum = 20
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var entries: [ForumSearchHistoryEntry]

    static var empty: Self {
      Archive(schemaVersion: FileForumSearchHistoryStore.schemaVersion, entries: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumEntriesPerForum: Int
  private let maximumArchiveBytes: Int

  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumEntriesPerForum: Int = defaultMaximumEntriesPerForum,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumEntriesPerForum = max(maximumEntriesPerForum, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileForumSearchHistoryStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileForumSearchHistoryStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("forum-search-history.json", isDirectory: false)
    )
  }

  func entries(forumName: String) async throws -> [ForumSearchHistoryEntry] {
    let forumKey = try Self.validatedForumKey(forumName)
    return try loadArchive().entries
      .filter { Self.normalizedForumKey($0) == forumKey }
      .sorted(by: Self.isMoreRecent)
  }

  func record(query: String, forumName: String, at date: Date) async throws {
    let entry = ForumSearchHistoryEntry(
      forumName: forumName,
      query: query,
      searchedAt: date
    )
    try Self.validate(entry)

    var candidate = try loadArchive()
    if let existing = candidate.entries.first(where: { $0.id == entry.id }),
      existing.searchedAt > entry.searchedAt
    {
      return
    }
    candidate.entries.removeAll { $0.id == entry.id }
    candidate.entries.append(entry)
    candidate.entries = normalized(candidate.entries)
    try commit(candidate)
  }

  func delete(id: String) async throws {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ForumSearchHistoryStoreError.invalidEntry
    }
    var candidate = try loadArchive()
    let previousCount = candidate.entries.count
    candidate.entries.removeAll { $0.id == id }
    guard candidate.entries.count != previousCount else { return }
    try commit(candidate)
  }

  func deleteAll(forumName: String) async throws {
    let forumKey = try Self.validatedForumKey(forumName)
    var candidate = try loadArchive()
    let previousCount = candidate.entries.count
    candidate.entries.removeAll { Self.normalizedForumKey($0) == forumKey }
    guard candidate.entries.count != previousCount else { return }
    try commit(candidate)
  }

  func reset() async throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw ForumSearchHistoryStoreError.writeFailed
    }
  }

  private func loadArchive() throws -> Archive {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
    var archive = try decodedArchiveFromDisk()
    archive.entries = normalized(archive.entries)
    return archive
  }

  private func decodedArchiveFromDisk() throws -> Archive {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw ForumSearchHistoryStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw ForumSearchHistoryStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw ForumSearchHistoryStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw ForumSearchHistoryStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    do {
      let archive = try decoder.decode(Archive.self, from: data)
      try archive.entries.forEach { try Self.validate($0) }
      return archive
    } catch let error as ForumSearchHistoryStoreError {
      if error == .invalidEntry {
        throw ForumSearchHistoryStoreError.corruptedArchive
      }
      throw error
    } catch {
      throw ForumSearchHistoryStoreError.corruptedArchive
    }
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw ForumSearchHistoryStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw ForumSearchHistoryStoreError.archiveTooLarge
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableFileURL = fileURL
      try? mutableFileURL.setResourceValues(values)
    } catch {
      throw ForumSearchHistoryStoreError.writeFailed
    }
  }

  private func normalized(
    _ entries: [ForumSearchHistoryEntry]
  ) -> [ForumSearchHistoryEntry] {
    var newestByID: [String: ForumSearchHistoryEntry] = [:]
    for entry in entries {
      if let existing = newestByID[entry.id],
        !Self.isMoreRecent(entry, existing) {
        continue
      }
      newestByID[entry.id] = entry
    }

    let grouped = Dictionary(grouping: newestByID.values) {
      Self.normalizedForumKey($0)
    }
    return grouped.values
      .flatMap { entries in
        entries
          .sorted(by: Self.isMoreRecent)
          .prefix(maximumEntriesPerForum)
      }
      .sorted(by: Self.isMoreRecent)
  }

  private static func validate(_ entry: ForumSearchHistoryEntry) throws {
    let forumKey = normalizedForumKey(entry)
    let queryKey = ForumSearchHistoryEntry.normalizedIdentityComponent(entry.query)
    guard
      !forumKey.isEmpty,
      forumKey.count <= 100,
      !queryKey.isEmpty,
      queryKey.count <= 100
    else {
      throw ForumSearchHistoryStoreError.invalidEntry
    }
  }

  private static func validatedForumKey(_ forumName: String) throws -> String {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    guard !key.isEmpty, key.count <= 100 else {
      throw ForumSearchHistoryStoreError.invalidEntry
    }
    return key
  }

  private static func normalizedForumKey(_ entry: ForumSearchHistoryEntry) -> String {
    ForumSearchHistoryEntry.normalizedIdentityComponent(entry.forumName)
  }

  private static func isMoreRecent(
    _ lhs: ForumSearchHistoryEntry,
    _ rhs: ForumSearchHistoryEntry
  ) -> Bool {
    if lhs.searchedAt != rhs.searchedAt { return lhs.searchedAt > rhs.searchedAt }
    return lhs.id < rhs.id
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
