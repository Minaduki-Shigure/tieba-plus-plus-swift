import Foundation

extension Notification.Name {
  static let localFavoritesDidChange = Notification.Name(
    "TiebaPlusPlus.localFavoritesDidChange"
  )
}

enum LocalFavoriteKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case thread
  case forum

  var id: Self { self }

  var title: String {
    switch self {
    case .thread:
      "帖子"
    case .forum:
      "贴吧"
    }
  }
}

enum LocalFavoriteTarget: Hashable, Sendable {
  case forum(ForumHistorySnapshot)
  case thread(ThreadHistorySnapshot)

  var kind: LocalFavoriteKind {
    switch self {
    case .forum:
      .forum
    case .thread:
      .thread
    }
  }

  var storageKey: String {
    switch self {
    case .forum(let forum):
      return "forum:\(Self.normalizedForumName(forum.name))"
    case .thread(let thread):
      return "thread:\(thread.threadID)"
    }
  }

  private static func normalizedForumName(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
  }
}

extension LocalFavoriteTarget: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case forum
    case thread
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(LocalFavoriteKind.self, forKey: .kind) {
    case .forum:
      self = .forum(try container.decode(ForumHistorySnapshot.self, forKey: .forum))
    case .thread:
      self = .thread(try container.decode(ThreadHistorySnapshot.self, forKey: .thread))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .forum(let forum):
      try container.encode(forum, forKey: .forum)
    case .thread(let thread):
      try container.encode(thread, forKey: .thread)
    }
  }
}

struct LocalFavoriteEntry: Codable, Hashable, Identifiable, Sendable {
  let target: LocalFavoriteTarget
  let savedAt: Date
  let updatedAt: Date

  var id: String { target.storageKey }
  var kind: LocalFavoriteKind { target.kind }
}

enum LocalFavoritesStoreError: LocalizedError, Equatable, Sendable {
  case invalidTarget
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidTarget:
      "收藏内容缺少有效的贴吧名或帖子编号。"
    case .archiveTooLarge:
      "本地收藏文件超过安全大小限制。"
    case .corruptedArchive:
      "本地收藏文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "本地收藏来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取本地收藏。"
    case .writeFailed:
      "无法保存本地收藏。"
    }
  }
}

protocol LocalFavoritesRepository: Sendable {
  func entries(kind: LocalFavoriteKind?) async throws -> [LocalFavoriteEntry]
  func contains(id: String) async throws -> Bool
  func save(_ target: LocalFavoriteTarget, at date: Date) async throws
  func updateThreadProgress(
    threadID: Int64,
    postID: Int64,
    floor: Int,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws
  func updateThreadOptions(
    threadID: Int64,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws
  func delete(id: String) async throws
  func deleteAll(kind: LocalFavoriteKind?) async throws
}

extension LocalFavoritesRepository {
  func entries() async throws -> [LocalFavoriteEntry] {
    try await entries(kind: nil)
  }

  func save(_ target: LocalFavoriteTarget) async throws {
    try await save(target, at: Date())
  }

  func updateThreadProgress(
    threadID: Int64,
    postID: Int64,
    floor: Int,
    options: ThreadBrowseOptions
  ) async throws {
    try await updateThreadProgress(
      threadID: threadID,
      postID: postID,
      floor: floor,
      options: options,
      at: Date()
    )
  }

  func updateThreadOptions(
    threadID: Int64,
    options: ThreadBrowseOptions
  ) async throws {
    try await updateThreadOptions(
      threadID: threadID,
      options: options,
      at: Date()
    )
  }

  func deleteAll() async throws {
    try await deleteAll(kind: nil)
  }
}

actor FileLocalFavoritesStore: LocalFavoritesRepository {
  static let schemaVersion = 1
  static let defaultMaximumEntriesPerKind = 200
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024

  private struct Archive: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var entries: [LocalFavoriteEntry]

    static var empty: Self {
      Archive(schemaVersion: FileLocalFavoritesStore.schemaVersion, entries: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumEntriesPerKind: Int
  private let maximumArchiveBytes: Int
  private var cachedArchive: Archive?

  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumEntriesPerKind: Int = defaultMaximumEntriesPerKind,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumEntriesPerKind = max(maximumEntriesPerKind, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileLocalFavoritesStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileLocalFavoritesStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("local-favorites.json", isDirectory: false)
    )
  }

  func entries(kind: LocalFavoriteKind?) async throws -> [LocalFavoriteEntry] {
    let archive = try loadArchive()
    return archive.entries
      .filter { kind == nil || $0.kind == kind }
      .sorted(by: Self.wasSavedMoreRecently)
  }

  func contains(id: String) async throws -> Bool {
    try loadArchive().entries.contains { $0.id == id }
  }

  func save(_ target: LocalFavoriteTarget, at date: Date) async throws {
    try Self.validate(target)
    var candidate = try loadArchive()
    if let index = candidate.entries.firstIndex(where: { $0.id == target.storageKey }) {
      let current = candidate.entries[index]
      guard date >= current.updatedAt else { return }
      candidate.entries[index] = LocalFavoriteEntry(
        target: target,
        savedAt: current.savedAt,
        updatedAt: date
      )
    } else {
      candidate.entries.append(
        LocalFavoriteEntry(target: target, savedAt: date, updatedAt: date)
      )
    }
    candidate.entries = normalized(candidate.entries)
    try commit(candidate)
    notifyChange()
  }

  func updateThreadProgress(
    threadID: Int64,
    postID: Int64,
    floor: Int,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws {
    var candidate = try loadArchive()
    guard
      threadID > 0,
      postID > 0,
      floor >= 0,
      let index = candidate.entries.firstIndex(where: { $0.id == "thread:\(threadID)" }),
      case .thread(let thread) = candidate.entries[index].target,
      date >= candidate.entries[index].updatedAt
    else { return }

    let updatedThread = ThreadHistorySnapshot(
      threadID: thread.threadID,
      forumID: thread.forumID,
      forumName: thread.forumName,
      title: thread.title,
      excerpt: thread.excerpt,
      authorName: thread.authorName,
      authorUsername: thread.authorUsername,
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      createdAt: thread.createdAt,
      lastReplyAt: thread.lastReplyAt,
      authorAvatarURL: thread.authorAvatarURL,
      browseOptions: options,
      lastPostID: options.sort == .hot ? nil : postID,
      lastFloor: options.sort == .hot ? nil : floor
    )
    let current = candidate.entries[index]
    candidate.entries[index] = LocalFavoriteEntry(
      target: .thread(updatedThread),
      savedAt: current.savedAt,
      updatedAt: date
    )
    try commit(candidate)
  }

  func updateThreadOptions(
    threadID: Int64,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws {
    var candidate = try loadArchive()
    guard
      threadID > 0,
      let index = candidate.entries.firstIndex(where: { $0.id == "thread:\(threadID)" }),
      case .thread(let thread) = candidate.entries[index].target,
      date >= candidate.entries[index].updatedAt
    else { return }

    let updatedThread = ThreadHistorySnapshot(
      threadID: thread.threadID,
      forumID: thread.forumID,
      forumName: thread.forumName,
      title: thread.title,
      excerpt: thread.excerpt,
      authorName: thread.authorName,
      authorUsername: thread.authorUsername,
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      createdAt: thread.createdAt,
      lastReplyAt: thread.lastReplyAt,
      authorAvatarURL: thread.authorAvatarURL,
      browseOptions: options,
      lastPostID: options.sort == .hot ? nil : thread.lastPostID,
      lastFloor: options.sort == .hot ? nil : thread.lastFloor
    )
    let current = candidate.entries[index]
    candidate.entries[index] = LocalFavoriteEntry(
      target: .thread(updatedThread),
      savedAt: current.savedAt,
      updatedAt: date
    )
    try commit(candidate)
  }

  func delete(id: String) async throws {
    var candidate = try loadArchive()
    let oldCount = candidate.entries.count
    candidate.entries.removeAll { $0.id == id }
    guard candidate.entries.count != oldCount else { return }
    try commit(candidate)
    notifyChange()
  }

  func deleteAll(kind: LocalFavoriteKind?) async throws {
    var candidate = try loadArchive()
    let oldCount = candidate.entries.count
    if let kind {
      candidate.entries.removeAll { $0.kind == kind }
    } else {
      candidate.entries.removeAll()
    }
    guard candidate.entries.count != oldCount else { return }
    try commit(candidate)
    notifyChange()
  }

  private func loadArchive() throws -> Archive {
    if let cachedArchive { return cachedArchive }
    var archive = try fileManager.fileExists(atPath: fileURL.path)
      ? decodedArchiveFromDisk()
      : Archive.empty
    archive.entries = normalized(archive.entries)
    cachedArchive = archive
    return archive
  }

  private func decodedArchiveFromDisk() throws -> Archive {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw LocalFavoritesStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw LocalFavoritesStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw LocalFavoritesStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw LocalFavoritesStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    do {
      let archive = try decoder.decode(Archive.self, from: data)
      try archive.entries.forEach { try Self.validate($0.target) }
      return archive
    } catch let error as LocalFavoritesStoreError {
      if error == .invalidTarget { throw LocalFavoritesStoreError.corruptedArchive }
      throw error
    } catch {
      throw LocalFavoritesStoreError.corruptedArchive
    }
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw LocalFavoritesStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw LocalFavoritesStoreError.archiveTooLarge
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
      throw LocalFavoritesStoreError.writeFailed
    }
    cachedArchive = candidate
  }

  private func normalized(_ entries: [LocalFavoriteEntry]) -> [LocalFavoriteEntry] {
    var newestByID: [String: LocalFavoriteEntry] = [:]
    for entry in entries.sorted(by: Self.wasUpdatedMoreRecently)
    where newestByID[entry.id] == nil {
      newestByID[entry.id] = entry
    }
    return LocalFavoriteKind.allCases
      .flatMap { kind in
        newestByID.values
          .filter { $0.kind == kind }
          .sorted(by: Self.wasSavedMoreRecently)
          .prefix(maximumEntriesPerKind)
      }
      .sorted(by: Self.wasSavedMoreRecently)
  }

  private func notifyChange() {
    NotificationCenter.default.post(name: .localFavoritesDidChange, object: nil)
  }

  private static func validate(_ target: LocalFavoriteTarget) throws {
    switch target {
    case .forum(let forum):
      guard !forum.name.isEmpty else { throw LocalFavoritesStoreError.invalidTarget }
    case .thread(let thread):
      guard thread.threadID > 0 else { throw LocalFavoritesStoreError.invalidTarget }
    }
  }

  private static func wasSavedMoreRecently(
    _ lhs: LocalFavoriteEntry,
    _ rhs: LocalFavoriteEntry
  ) -> Bool {
    if lhs.savedAt != rhs.savedAt { return lhs.savedAt > rhs.savedAt }
    return lhs.id < rhs.id
  }

  private static func wasUpdatedMoreRecently(
    _ lhs: LocalFavoriteEntry,
    _ rhs: LocalFavoriteEntry
  ) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return wasSavedMoreRecently(lhs, rhs)
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
