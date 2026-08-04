import Foundation

extension Notification.Name {
  static let forumBrowsingHistoryDidChange = Notification.Name(
    "TiebaPlusPlus.forumBrowsingHistoryDidChange"
  )
}

enum BrowsingHistoryKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
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

struct ForumHistorySnapshot: Codable, Hashable, Sendable {
  let forumID: Int64
  let name: String
  let displayName: String
  let avatarURL: URL?

  init(
    forumID: Int64 = 0,
    name: String,
    displayName: String? = nil,
    avatarURL: URL? = nil
  ) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.forumID = forumID
    self.name = normalizedName
    if let normalizedDisplayName, !normalizedDisplayName.isEmpty {
      self.displayName = normalizedDisplayName
    } else {
      self.displayName = normalizedName
    }
    self.avatarURL = SecureTiebaURL.media(avatarURL)
  }

  init(forum: ForumSearchItem) {
    self.init(
      forumID: forum.id,
      name: forum.name,
      displayName: forum.displayName,
      avatarURL: forum.avatarURL
    )
  }

  init(forum: BrowseForum) {
    self.init(
      forumID: forum.id,
      name: forum.name,
      displayName: forum.name,
      avatarURL: forum.avatarURL
    )
  }

  private enum CodingKeys: String, CodingKey {
    case forumID
    case name
    case displayName
    case avatarURL
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      forumID: try container.decodeIfPresent(Int64.self, forKey: .forumID) ?? 0,
      name: try container.decode(String.self, forKey: .name),
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      avatarURL: try container.decodeIfPresent(URL.self, forKey: .avatarURL)
    )
  }
}

struct ThreadHistorySnapshot: Codable, Hashable, Sendable {
  let threadID: Int64
  let forumID: Int64
  let forumName: String
  let title: String
  let excerpt: String
  let authorName: String
  let authorUsername: String
  let replyCount: Int
  let viewCount: Int
  let createdAt: Date?
  let lastReplyAt: Date?
  let authorAvatarURL: URL?
  let browseOptions: ThreadBrowseOptions
  let lastPostID: Int64?
  let lastFloor: Int?

  init(
    threadID: Int64,
    forumID: Int64 = 0,
    forumName: String = "",
    title: String,
    excerpt: String = "",
    authorName: String = "",
    authorUsername: String = "",
    replyCount: Int = 0,
    viewCount: Int = 0,
    createdAt: Date? = nil,
    lastReplyAt: Date? = nil,
    authorAvatarURL: URL? = nil,
    browseOptions: ThreadBrowseOptions = ThreadBrowseOptions(),
    lastPostID: Int64? = nil,
    lastFloor: Int? = nil
  ) {
    self.threadID = threadID
    self.forumID = forumID
    self.forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
    self.authorName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.authorUsername = authorUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    self.replyCount = max(replyCount, 0)
    self.viewCount = max(viewCount, 0)
    self.createdAt = createdAt
    self.lastReplyAt = lastReplyAt
    self.authorAvatarURL = SecureTiebaURL.media(authorAvatarURL)
    self.browseOptions = browseOptions
    self.lastPostID = lastPostID.flatMap { $0 > 0 ? $0 : nil }
    self.lastFloor = lastFloor.flatMap { $0 > 0 ? $0 : nil }
  }

  init(
    thread: BrowseThread,
    browseOptions: ThreadBrowseOptions = ThreadBrowseOptions(),
    lastPostID: Int64? = nil,
    lastFloor: Int? = nil
  ) {
    self.init(
      thread: thread,
      resolvedAuthorAvatarURL: thread.localVisibility == .visible ? thread.authorAvatarURL : nil,
      browseOptions: browseOptions,
      lastPostID: lastPostID,
      lastFloor: lastFloor
    )
  }

  init(
    thread: BrowseThread,
    resolvedAuthorAvatarURL: URL?,
    browseOptions: ThreadBrowseOptions = ThreadBrowseOptions(),
    lastPostID: Int64? = nil,
    lastFloor: Int? = nil
  ) {
    self.init(
      threadID: thread.id,
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
      authorAvatarURL: resolvedAuthorAvatarURL,
      browseOptions: browseOptions,
      lastPostID: lastPostID,
      lastFloor: lastFloor
    )
  }

  var browseThread: BrowseThread {
    BrowseThread(
      id: threadID,
      forumID: forumID,
      forumName: forumName,
      title: title,
      excerpt: excerpt,
      authorName: authorName,
      replyCount: replyCount,
      viewCount: viewCount,
      createdAt: createdAt,
      lastReplyAt: lastReplyAt,
      contents: excerpt.isEmpty ? [] : [.text(excerpt)],
      authorUsername: authorUsername,
      authorAvatarURL: authorAvatarURL
    )
  }

  var resumeLocation: ThreadPostLocation? {
    guard let lastPostID else { return nil }
    return .postID(lastPostID)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(threadID)
    hasher.combine(forumID)
    hasher.combine(forumName)
    hasher.combine(title)
    hasher.combine(excerpt)
    hasher.combine(authorName)
    hasher.combine(authorUsername)
    hasher.combine(replyCount)
    hasher.combine(viewCount)
    hasher.combine(createdAt)
    hasher.combine(lastReplyAt)
    hasher.combine(authorAvatarURL)
    hasher.combine(browseOptions.sort)
    hasher.combine(browseOptions.onlyThreadAuthor)
    hasher.combine(lastPostID)
    hasher.combine(lastFloor)
  }

  private enum CodingKeys: String, CodingKey {
    case threadID
    case forumID
    case forumName
    case title
    case excerpt
    case authorName
    case authorUsername
    case replyCount
    case viewCount
    case createdAt
    case lastReplyAt
    case authorAvatarURL
    case browseOptions
    case lastPostID
    case lastFloor
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      threadID: try container.decode(Int64.self, forKey: .threadID),
      forumID: try container.decodeIfPresent(Int64.self, forKey: .forumID) ?? 0,
      forumName: try container.decodeIfPresent(String.self, forKey: .forumName) ?? "",
      title: try container.decode(String.self, forKey: .title),
      excerpt: try container.decodeIfPresent(String.self, forKey: .excerpt) ?? "",
      authorName: try container.decodeIfPresent(String.self, forKey: .authorName) ?? "",
      authorUsername: try container.decodeIfPresent(String.self, forKey: .authorUsername) ?? "",
      replyCount: try container.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0,
      viewCount: try container.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0,
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
      lastReplyAt: try container.decodeIfPresent(Date.self, forKey: .lastReplyAt),
      authorAvatarURL: try container.decodeIfPresent(URL.self, forKey: .authorAvatarURL),
      browseOptions: try container.decodeIfPresent(ThreadBrowseOptions.self, forKey: .browseOptions)
        ?? ThreadBrowseOptions(),
      lastPostID: try container.decodeIfPresent(Int64.self, forKey: .lastPostID),
      lastFloor: try container.decodeIfPresent(Int.self, forKey: .lastFloor)
    )
  }
}

enum BrowsingHistoryTarget: Hashable, Sendable {
  case forum(ForumHistorySnapshot)
  case thread(ThreadHistorySnapshot)

  var kind: BrowsingHistoryKind {
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
      "forum:\(Self.normalizedForumName(forum.name))"
    case .thread(let thread):
      "thread:\(thread.threadID)"
    }
  }

  private static func normalizedForumName(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
  }
}

extension BrowsingHistoryTarget: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case forum
    case thread
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(BrowsingHistoryKind.self, forKey: .kind) {
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

struct BrowsingHistoryEntry: Codable, Hashable, Identifiable, Sendable {
  let target: BrowsingHistoryTarget
  let lastVisitedAt: Date
  let visitCount: Int

  var id: String { target.storageKey }
  var kind: BrowsingHistoryKind { target.kind }
}

enum BrowsingHistoryStoreError: LocalizedError, Equatable, Sendable {
  case invalidTarget
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidTarget:
      "浏览记录缺少有效的贴吧名或帖子编号。"
    case .archiveTooLarge:
      "浏览记录文件超过安全大小限制。"
    case .corruptedArchive:
      "浏览记录文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "浏览记录来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取浏览记录。"
    case .writeFailed:
      "无法保存浏览记录。"
    }
  }
}

protocol BrowsingHistoryRepository: Sendable {
  func entries(kind: BrowsingHistoryKind?) async throws -> [BrowsingHistoryEntry]
  func isRecordingEnabled() async throws -> Bool
  func setRecordingEnabled(_ enabled: Bool) async throws
  func record(_ target: BrowsingHistoryTarget, at date: Date) async throws
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
  func deleteAll(kind: BrowsingHistoryKind?) async throws
}

extension BrowsingHistoryRepository {
  func entries() async throws -> [BrowsingHistoryEntry] {
    try await entries(kind: nil)
  }

  func record(_ target: BrowsingHistoryTarget) async throws {
    try await record(target, at: Date())
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
    try await updateThreadOptions(threadID: threadID, options: options, at: Date())
  }

  func deleteAll() async throws {
    try await deleteAll(kind: nil)
  }
}

actor FileBrowsingHistoryStore: BrowsingHistoryRepository {
  enum LegacyDefaultsScope: Sendable {
    case none
    case standard
    case suite(String)
  }

  static let schemaVersion = 1
  static let defaultMaximumEntriesPerKind = 200
  static let defaultMaximumArchiveBytes = 4 * 1_024 * 1_024
  static let legacyRecentForumsKey = "recentForums"

  private struct Archive: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var recordingEnabled: Bool
    var entries: [BrowsingHistoryEntry]

    static var empty: Self {
      Archive(schemaVersion: FileBrowsingHistoryStore.schemaVersion, recordingEnabled: true, entries: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumEntriesPerKind: Int
  private let maximumArchiveBytes: Int
  private let legacyDefaultsScope: LegacyDefaultsScope
  private var cachedArchive: Archive?

  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumEntriesPerKind: Int = defaultMaximumEntriesPerKind,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    legacyDefaults: LegacyDefaultsScope = .none
  ) {
    self.fileURL = fileURL
    self.maximumEntriesPerKind = max(maximumEntriesPerKind, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.legacyDefaultsScope = legacyDefaults
  }

  static func live(fileManager: FileManager = .default) -> FileBrowsingHistoryStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileBrowsingHistoryStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("browsing-history.json", isDirectory: false),
      legacyDefaults: .standard
    )
  }

  func entries(kind: BrowsingHistoryKind?) async throws -> [BrowsingHistoryEntry] {
    let archive = try loadArchive()
    return archive.entries
      .filter { kind == nil || $0.kind == kind }
      .sorted(by: Self.isMoreRecent)
  }

  func isRecordingEnabled() async throws -> Bool {
    try loadArchive().recordingEnabled
  }

  func setRecordingEnabled(_ enabled: Bool) async throws {
    var candidate = try loadArchive()
    guard candidate.recordingEnabled != enabled else { return }
    candidate.recordingEnabled = enabled
    try commit(candidate)
  }

  func record(_ target: BrowsingHistoryTarget, at date: Date) async throws {
    var candidate = try loadArchive()
    guard candidate.recordingEnabled else { return }
    try Self.validate(target)

    if let index = candidate.entries.firstIndex(where: { $0.id == target.storageKey }) {
      let current = candidate.entries[index]
      candidate.entries[index] = BrowsingHistoryEntry(
        target: target,
        lastVisitedAt: date,
        visitCount: current.visitCount == Int.max ? Int.max : current.visitCount + 1
      )
    } else {
      candidate.entries.append(
        BrowsingHistoryEntry(target: target, lastVisitedAt: date, visitCount: 1)
      )
    }
    candidate.entries = normalized(candidate.entries)
    try commit(candidate)
    if target.kind == .forum {
      notifyForumChange()
    }
  }

  func record(forum: ForumHistorySnapshot, at date: Date = Date()) async throws {
    try await record(.forum(forum), at: date)
  }

  func record(
    thread: BrowseThread,
    options: ThreadBrowseOptions = ThreadBrowseOptions(),
    lastPostID: Int64? = nil,
    lastFloor: Int? = nil,
    at date: Date = Date()
  ) async throws {
    try await record(
      .thread(
        ThreadHistorySnapshot(
          thread: thread,
          browseOptions: options,
          lastPostID: lastPostID,
          lastFloor: lastFloor
        )
      ),
      at: date
    )
  }

  func record(
    thread: BrowseThread,
    resolvedAuthorAvatarURL: URL?,
    options: ThreadBrowseOptions = ThreadBrowseOptions(),
    lastPostID: Int64? = nil,
    lastFloor: Int? = nil,
    at date: Date = Date()
  ) async throws {
    try await record(
      .thread(
        ThreadHistorySnapshot(
          thread: thread,
          resolvedAuthorAvatarURL: resolvedAuthorAvatarURL,
          browseOptions: options,
          lastPostID: lastPostID,
          lastFloor: lastFloor
        )
      ),
      at: date
    )
  }

  func updateThreadProgress(
    threadID: Int64,
    postID: Int64,
    floor: Int,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws {
    var candidate = try loadArchive()
    guard candidate.recordingEnabled else { return }
    guard
      threadID > 0,
      postID > 0,
      floor >= 0,
      let index = candidate.entries.firstIndex(where: { $0.id == "thread:\(threadID)" }),
      case .thread(let thread) = candidate.entries[index].target
    else { return }
    guard date >= candidate.entries[index].lastVisitedAt else { return }

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
    candidate.entries[index] = BrowsingHistoryEntry(
      target: .thread(updatedThread),
      lastVisitedAt: date,
      visitCount: candidate.entries[index].visitCount
    )
    candidate.entries = normalized(candidate.entries)
    try commit(candidate)
  }

  func updateThreadOptions(
    threadID: Int64,
    options: ThreadBrowseOptions,
    at date: Date
  ) async throws {
    var candidate = try loadArchive()
    guard candidate.recordingEnabled else { return }
    guard
      threadID > 0,
      let index = candidate.entries.firstIndex(where: { $0.id == "thread:\(threadID)" }),
      case .thread(let thread) = candidate.entries[index].target,
      date >= candidate.entries[index].lastVisitedAt
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
    candidate.entries[index] = BrowsingHistoryEntry(
      target: .thread(updatedThread),
      lastVisitedAt: date,
      visitCount: candidate.entries[index].visitCount
    )
    candidate.entries = normalized(candidate.entries)
    try commit(candidate)
  }

  func delete(id: String) async throws {
    var candidate = try loadArchive()
    let removedForum = candidate.entries.contains { $0.id == id && $0.kind == .forum }
    let oldCount = candidate.entries.count
    candidate.entries.removeAll { $0.id == id }
    guard candidate.entries.count != oldCount else { return }
    try commit(candidate)
    if removedForum {
      notifyForumChange()
    }
  }

  func deleteAll(kind: BrowsingHistoryKind?) async throws {
    if kind == nil || kind == .forum {
      legacyDefaults()?.removeObject(forKey: Self.legacyRecentForumsKey)
    }
    var candidate = try loadArchive()
    let oldCount = candidate.entries.count
    if let kind {
      candidate.entries.removeAll { $0.kind == kind }
    } else {
      candidate.entries.removeAll()
    }
    guard candidate.entries.count != oldCount else { return }
    try commit(candidate)
    if kind == nil || kind == .forum {
      notifyForumChange()
    }
  }

  private func loadArchive() throws -> Archive {
    if let cachedArchive {
      return cachedArchive
    }
    var archive = try fileManager.fileExists(atPath: fileURL.path)
      ? decodedArchiveFromDisk()
      : Archive.empty
    archive.entries = normalized(archive.entries)
    archive = try migrateLegacyForumsIfNeeded(into: archive)
    cachedArchive = archive
    return archive
  }

  private func decodedArchiveFromDisk() throws -> Archive {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw BrowsingHistoryStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw BrowsingHistoryStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw BrowsingHistoryStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw BrowsingHistoryStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    do {
      let decoded = try decoder.decode(Archive.self, from: data)
      try decoded.entries.forEach { entry in
        try Self.validate(entry.target)
        guard entry.visitCount > 0 else { throw BrowsingHistoryStoreError.corruptedArchive }
      }
      return decoded
    } catch let error as BrowsingHistoryStoreError {
      if error == .invalidTarget {
        throw BrowsingHistoryStoreError.corruptedArchive
      }
      throw error
    } catch {
      throw BrowsingHistoryStoreError.corruptedArchive
    }
  }

  private func migrateLegacyForumsIfNeeded(into archive: Archive) throws -> Archive {
    guard
      let legacyDefaults = legacyDefaults(),
      let storedForums = legacyDefaults.string(forKey: Self.legacyRecentForumsKey)
    else { return archive }

    let names = storedForums
      .split(separator: "\n")
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard archive.recordingEnabled, !names.isEmpty else {
      legacyDefaults.removeObject(forKey: Self.legacyRecentForumsKey)
      return archive
    }

    var candidate = archive
    let migratedAt = Date()
    for (index, name) in names.enumerated() {
      let target = BrowsingHistoryTarget.forum(ForumHistorySnapshot(name: name))
      guard !candidate.entries.contains(where: { $0.id == target.storageKey }) else { continue }
      candidate.entries.append(
        BrowsingHistoryEntry(
          target: target,
          lastVisitedAt: migratedAt.addingTimeInterval(-Double(index) / 1_000),
          visitCount: 1
        )
      )
    }
    candidate.entries = normalized(candidate.entries)
    if candidate != archive {
      try commit(candidate)
    }
    legacyDefaults.removeObject(forKey: Self.legacyRecentForumsKey)
    return candidate
  }

  private func legacyDefaults() -> UserDefaults? {
    switch legacyDefaultsScope {
    case .none:
      return nil
    case .standard:
      return .standard
    case .suite(let name):
      return UserDefaults(suiteName: name)
    }
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw BrowsingHistoryStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw BrowsingHistoryStoreError.archiveTooLarge
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
      throw BrowsingHistoryStoreError.writeFailed
    }
    cachedArchive = candidate
  }

  private func notifyForumChange() {
    NotificationCenter.default.post(name: .forumBrowsingHistoryDidChange, object: nil)
  }

  private func normalized(_ entries: [BrowsingHistoryEntry]) -> [BrowsingHistoryEntry] {
    var newestByID: [String: BrowsingHistoryEntry] = [:]
    for entry in entries.sorted(by: Self.isMoreRecent) where newestByID[entry.id] == nil {
      newestByID[entry.id] = entry
    }

    return BrowsingHistoryKind.allCases
      .flatMap { kind in
        newestByID.values
          .filter { $0.kind == kind }
          .sorted(by: Self.isMoreRecent)
          .prefix(maximumEntriesPerKind)
      }
      .sorted(by: Self.isMoreRecent)
  }

  private static func validate(_ target: BrowsingHistoryTarget) throws {
    switch target {
    case .forum(let forum):
      guard !forum.name.isEmpty else { throw BrowsingHistoryStoreError.invalidTarget }
    case .thread(let thread):
      guard thread.threadID > 0 else { throw BrowsingHistoryStoreError.invalidTarget }
    }
  }

  private static func isMoreRecent(_ lhs: BrowsingHistoryEntry, _ rhs: BrowsingHistoryEntry) -> Bool {
    if lhs.lastVisitedAt != rhs.lastVisitedAt {
      return lhs.lastVisitedAt > rhs.lastVisitedAt
    }
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
