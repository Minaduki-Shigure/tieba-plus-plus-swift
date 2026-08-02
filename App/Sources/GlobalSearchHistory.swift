import Foundation

struct GlobalSearchHistoryEntry: Codable, Hashable, Identifiable, Sendable {
  let query: String
  let searchedAt: Date

  var id: String {
    "query:\(Self.normalizedIdentityComponent(query))"
  }

  init(query: String, searchedAt: Date) {
    self.query = Self.trimmed(query)
    self.searchedAt = searchedAt
  }

  private enum CodingKeys: String, CodingKey {
    case query
    case searchedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
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

enum GlobalSearchHistoryStoreError: LocalizedError, Equatable, Sendable {
  case invalidEntry
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidEntry:
      "搜索记录缺少有效的搜索词。"
    case .archiveTooLarge:
      "全局搜索历史文件超过安全大小限制。"
    case .corruptedArchive:
      "全局搜索历史文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "全局搜索历史来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取全局搜索历史。"
    case .writeFailed:
      "无法保存全局搜索历史。"
    }
  }
}

protocol GlobalSearchHistoryRepository: Sendable {
  func entries() async throws -> [GlobalSearchHistoryEntry]
  func record(query: String, at date: Date) async throws
  func delete(id: String) async throws
  func deleteAll() async throws
  func reset() async throws
}

extension GlobalSearchHistoryRepository {
  func record(query: String) async throws {
    try await record(query: query, at: Date())
  }
}

actor FileGlobalSearchHistoryStore: GlobalSearchHistoryRepository {
  static let schemaVersion = 1
  static let defaultMaximumEntries = 20
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var entries: [GlobalSearchHistoryEntry]

    static var empty: Self {
      Archive(schemaVersion: FileGlobalSearchHistoryStore.schemaVersion, entries: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumEntries: Int
  private let maximumArchiveBytes: Int

  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumEntries: Int = defaultMaximumEntries,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumEntries = max(maximumEntries, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileGlobalSearchHistoryStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileGlobalSearchHistoryStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("global-search-history.json", isDirectory: false)
    )
  }

  func entries() async throws -> [GlobalSearchHistoryEntry] {
    try loadArchive().entries.sorted(by: Self.isMoreRecent)
  }

  func record(query: String, at date: Date) async throws {
    let entry = GlobalSearchHistoryEntry(query: query, searchedAt: date)
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
      throw GlobalSearchHistoryStoreError.invalidEntry
    }
    var candidate = try loadArchive()
    let previousCount = candidate.entries.count
    candidate.entries.removeAll { $0.id == id }
    guard candidate.entries.count != previousCount else { return }
    try commit(candidate)
  }

  func deleteAll() async throws {
    var candidate = try loadArchive()
    guard !candidate.entries.isEmpty else { return }
    candidate.entries = []
    try commit(candidate)
  }

  func reset() async throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw GlobalSearchHistoryStoreError.writeFailed
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
      throw GlobalSearchHistoryStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw GlobalSearchHistoryStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw GlobalSearchHistoryStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw GlobalSearchHistoryStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    do {
      let archive = try decoder.decode(Archive.self, from: data)
      try archive.entries.forEach { try Self.validate($0) }
      return archive
    } catch let error as GlobalSearchHistoryStoreError {
      if error == .invalidEntry {
        throw GlobalSearchHistoryStoreError.corruptedArchive
      }
      throw error
    } catch {
      throw GlobalSearchHistoryStoreError.corruptedArchive
    }
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw GlobalSearchHistoryStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw GlobalSearchHistoryStoreError.archiveTooLarge
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
      throw GlobalSearchHistoryStoreError.writeFailed
    }
  }

  private func normalized(
    _ entries: [GlobalSearchHistoryEntry]
  ) -> [GlobalSearchHistoryEntry] {
    var newestByID: [String: GlobalSearchHistoryEntry] = [:]
    for entry in entries {
      if let existing = newestByID[entry.id],
        !Self.isMoreRecent(entry, existing)
      {
        continue
      }
      newestByID[entry.id] = entry
    }
    return Array(newestByID.values)
      .sorted(by: Self.isMoreRecent)
      .prefix(maximumEntries)
      .map { $0 }
  }

  private static func validate(_ entry: GlobalSearchHistoryEntry) throws {
    let queryKey = GlobalSearchHistoryEntry.normalizedIdentityComponent(entry.query)
    guard !queryKey.isEmpty, queryKey.count <= 100 else {
      throw GlobalSearchHistoryStoreError.invalidEntry
    }
  }

  private static func isMoreRecent(
    _ lhs: GlobalSearchHistoryEntry,
    _ rhs: GlobalSearchHistoryEntry
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
