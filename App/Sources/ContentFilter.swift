import Foundation

extension Notification.Name {
  static let contentFilterDidChange = Notification.Name(
    "TiebaPlusPlus.contentFilterDidChange"
  )
}

enum ContentFilterList: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case block
  case allow

  var id: Self { self }

  var title: String {
    switch self {
    case .block:
      "屏蔽列表"
    case .allow:
      "白名单"
    }
  }
}

enum ContentFilterRuleKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case keyword
  case user

  var id: Self { self }

  var title: String {
    switch self {
    case .keyword:
      "关键词"
    case .user:
      "用户"
    }
  }
}

enum ContentFilterKeywordMatchMode: String, Codable, Hashable, Sendable {
  case literal
}

enum ContentFilterDisplayMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case placeholder
  case hidden

  var id: Self { self }

  var title: String {
    switch self {
    case .placeholder:
      "显示提示"
    case .hidden:
      "完全隐藏"
    }
  }
}

struct ContentFilterRule: Codable, Hashable, Identifiable, Sendable {
  let id: UUID
  let list: ContentFilterList
  let kind: ContentFilterRuleKind
  let keyword: String
  let keywordMatchMode: ContentFilterKeywordMatchMode
  let userID: Int64?
  let username: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    list: ContentFilterList,
    kind: ContentFilterRuleKind,
    keyword: String = "",
    keywordMatchMode: ContentFilterKeywordMatchMode = .literal,
    userID: Int64? = nil,
    username: String = "",
    createdAt: Date = Date()
  ) {
    self.id = id
    self.list = list
    self.kind = kind
    self.keyword = keyword
    self.keywordMatchMode = keywordMatchMode
    self.userID = userID
    self.username = username
    self.createdAt = createdAt
  }

  static func keyword(
    _ keyword: String,
    list: ContentFilterList,
    id: UUID = UUID(),
    createdAt: Date = Date()
  ) -> Self {
    ContentFilterRule(
      id: id,
      list: list,
      kind: .keyword,
      keyword: keyword,
      keywordMatchMode: .literal,
      createdAt: createdAt
    )
  }

  static func user(
    id userID: Int64?,
    name username: String,
    list: ContentFilterList,
    ruleID: UUID = UUID(),
    createdAt: Date = Date()
  ) -> Self {
    ContentFilterRule(
      id: ruleID,
      list: list,
      kind: .user,
      userID: userID,
      username: username,
      createdAt: createdAt
    )
  }

  var displayValue: String {
    switch kind {
    case .keyword:
      return keyword
    case .user:
      if let userID, !username.isEmpty {
        return "\(username) · \(userID)"
      }
      if let userID { return String(userID) }
      return username
    }
  }

  fileprivate var identityKey: String {
    switch kind {
    case .keyword:
      "\(list.rawValue):keyword:\(keywordMatchMode.rawValue):\(keyword)"
    case .user:
      "\(list.rawValue):user:\(userID.map { String($0) } ?? ""):\(username)"
    }
  }
}

struct ContentFilterSnapshot: Codable, Hashable, Sendable {
  let displayMode: ContentFilterDisplayMode
  let blockVideos: Bool
  let rules: [ContentFilterRule]

  static let empty = ContentFilterSnapshot(
    displayMode: .placeholder,
    blockVideos: false,
    rules: []
  )

  func rules(in list: ContentFilterList) -> [ContentFilterRule] {
    rules.filter { $0.list == list }
  }

  var allowsWholeThreadPictureGallery: Bool {
    !blockVideos && rules.isEmpty
  }
}

enum ContentFilterStoreError: LocalizedError, Equatable, Sendable {
  case invalidRule
  case duplicateRule
  case tooManyRules
  case archiveTooLarge
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case readFailed
  case writeFailed
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidRule:
      "规则内容无效。"
    case .duplicateRule:
      "相同规则已存在。"
    case .tooManyRules:
      "本地规则数量已达到上限。"
    case .archiveTooLarge:
      "本地屏蔽规则文件超过安全大小限制。"
    case .corruptedArchive:
      "本地屏蔽规则文件已损坏，未对其进行覆盖。"
    case .unsupportedSchemaVersion(let version):
      "本地屏蔽规则来自不受支持的数据版本（\(version)）。"
    case .readFailed:
      "无法读取本地屏蔽规则。"
    case .writeFailed:
      "无法保存本地屏蔽规则。"
    case .unavailable:
      "当前环境无法修改本地屏蔽规则。"
    }
  }
}

protocol ContentFilterRepository: Sendable {
  func snapshot() async throws -> ContentFilterSnapshot
  @discardableResult
  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule
  func delete(id: UUID) async throws
  func deleteAll(in list: ContentFilterList) async throws
  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws
  func setBlockVideos(_ blockVideos: Bool) async throws
  func reset() async throws
}

struct EmptyContentFilterRepository: ContentFilterRepository {
  func snapshot() async throws -> ContentFilterSnapshot { .empty }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func reset() async throws {
    throw ContentFilterStoreError.unavailable
  }
}

actor FileContentFilterStore: ContentFilterRepository {
  static let schemaVersion = 1
  static let defaultMaximumRules = 500
  static let defaultMaximumArchiveBytes = 512 * 1_024

  private struct Archive: Codable, Hashable, Sendable {
    let schemaVersion: Int
    var displayMode: ContentFilterDisplayMode
    var blockVideos: Bool
    var rules: [ContentFilterRule]

    static var empty: Self {
      Archive(
        schemaVersion: FileContentFilterStore.schemaVersion,
        displayMode: .placeholder,
        blockVideos: false,
        rules: []
      )
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumRules: Int
  private let maximumArchiveBytes: Int
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumRules: Int = defaultMaximumRules,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumRules = max(maximumRules, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileContentFilterStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileContentFilterStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("content-filters.json", isDirectory: false)
    )
  }

  func snapshot() async throws -> ContentFilterSnapshot {
    let archive = try loadArchive()
    return ContentFilterSnapshot(
      displayMode: archive.displayMode,
      blockVideos: archive.blockVideos,
      rules: archive.rules
    )
  }

  @discardableResult
  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    let rule = try Self.normalizedRule(rule)
    var candidate = try loadArchive()
    guard candidate.rules.count < maximumRules else {
      throw ContentFilterStoreError.tooManyRules
    }
    guard !candidate.rules.contains(where: { $0.identityKey == rule.identityKey }) else {
      throw ContentFilterStoreError.duplicateRule
    }
    candidate.rules.append(rule)
    candidate.rules = normalizedRules(candidate.rules)
    try commit(candidate)
    notifyChange()
    return rule
  }

  func delete(id: UUID) async throws {
    var candidate = try loadArchive()
    let previousCount = candidate.rules.count
    candidate.rules.removeAll { $0.id == id }
    guard candidate.rules.count != previousCount else { return }
    try commit(candidate)
    notifyChange()
  }

  func deleteAll(in list: ContentFilterList) async throws {
    var candidate = try loadArchive()
    let previousCount = candidate.rules.count
    candidate.rules.removeAll { $0.list == list }
    guard candidate.rules.count != previousCount else { return }
    try commit(candidate)
    notifyChange()
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    var candidate = try loadArchive()
    guard candidate.displayMode != mode else { return }
    candidate.displayMode = mode
    try commit(candidate)
    notifyChange()
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    var candidate = try loadArchive()
    guard candidate.blockVideos != blockVideos else { return }
    candidate.blockVideos = blockVideos
    try commit(candidate)
    notifyChange()
  }

  func reset() async throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw ContentFilterStoreError.writeFailed
    }
    notifyChange()
  }

  private func loadArchive() throws -> Archive {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
    var archive = try decodedArchiveFromDisk()
    archive.rules = normalizedRules(archive.rules)
    return archive
  }

  private func decodedArchiveFromDisk() throws -> Archive {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw ContentFilterStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw ContentFilterStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw ContentFilterStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw ContentFilterStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    do {
      let archive = try decoder.decode(Archive.self, from: data)
      guard archive.rules.count <= maximumRules else {
        throw ContentFilterStoreError.corruptedArchive
      }
      _ = try archive.rules.map(Self.normalizedRule)
      return archive
    } catch let error as ContentFilterStoreError {
      if error == .invalidRule { throw ContentFilterStoreError.corruptedArchive }
      throw error
    } catch {
      throw ContentFilterStoreError.corruptedArchive
    }
  }

  private func commit(_ candidate: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(candidate)
    } catch {
      throw ContentFilterStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw ContentFilterStoreError.archiveTooLarge
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
      throw ContentFilterStoreError.writeFailed
    }
  }

  private func normalizedRules(_ rules: [ContentFilterRule]) -> [ContentFilterRule] {
    var newestByIdentity: [String: ContentFilterRule] = [:]
    for rule in rules.compactMap({ try? Self.normalizedRule($0) }) {
      if let current = newestByIdentity[rule.identityKey], current.createdAt >= rule.createdAt {
        continue
      }
      newestByIdentity[rule.identityKey] = rule
    }
    return newestByIdentity.values.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  private static func normalizedRule(_ rule: ContentFilterRule) throws -> ContentFilterRule {
    let keyword = normalizedText(rule.keyword)
    let username = normalizedText(rule.username)
    guard rule.createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ContentFilterStoreError.invalidRule
    }

    switch rule.kind {
    case .keyword:
      guard (1...128).contains(keyword.count) else {
        throw ContentFilterStoreError.invalidRule
      }
      return ContentFilterRule(
        id: rule.id,
        list: rule.list,
        kind: .keyword,
        keyword: keyword,
        keywordMatchMode: .literal,
        createdAt: rule.createdAt
      )
    case .user:
      if let userID = rule.userID, userID <= 0 {
        throw ContentFilterStoreError.invalidRule
      }
      guard username.count <= 100, rule.userID != nil || !username.isEmpty else {
        throw ContentFilterStoreError.invalidRule
      }
      return ContentFilterRule(
        id: rule.id,
        list: rule.list,
        kind: .user,
        userID: rule.userID,
        username: username,
        createdAt: rule.createdAt
      )
    }
  }

  private static func normalizedText(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private func notifyChange() {
    NotificationCenter.default.post(name: .contentFilterDidChange, object: nil)
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

extension ContentFilterSnapshot {
  func visibility(
    for thread: BrowseThread,
    hasKnownVideo: Bool = false
  ) -> LocalContentVisibility {
    let containsVideo = hasKnownVideo || thread.contents.contains(where: Self.isVideo)
    return visibility(
      isBlocked: (blockVideos && containsVideo)
        || blocksKeyword(thread.title)
        || blocksKeyword(thread.excerpt)
        || blocksUser(
          id: thread.authorID,
          preferredName: thread.authorName,
          username: thread.authorUsername
        )
    )
  }

  func visibility(for post: BrowsePost) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(Self.plainText(post.contents))
        || blocksUser(
          id: post.authorID,
          preferredName: post.authorName,
          username: post.authorUsername
        )
    )
  }

  func visibility(for comment: BrowseComment) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(Self.plainText(comment.contents))
        || blocksUser(
          id: comment.authorID,
          preferredName: comment.authorName,
          username: comment.authorUsername
        )
    )
  }

  func visibility(for parentPost: CommentParentPostContext) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(Self.plainText(parentPost.contents))
        || blocksUser(
          id: parentPost.authorID,
          preferredName: parentPost.authorName,
          username: parentPost.authorUsername
        )
    )
  }

  func visibility(for reply: BrowseUserReply) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(reply.threadTitle)
        || blocksKeyword(reply.excerpt)
        || blocksUser(
          id: reply.authorID,
          preferredName: reply.authorName,
          username: reply.authorUsername
        )
    )
  }

  func visibility(
    for result: ForumPostSearchItem,
    hasKnownVideo: Bool = false
  ) -> LocalContentVisibility {
    let containsVideo = hasKnownVideo || result.matchedContents.contains(where: Self.isVideo)
    return visibility(
      isBlocked: (blockVideos && containsVideo)
        || blocksKeyword(result.matchedTitle)
        || blocksKeyword(result.matchedExcerpt)
        || blocksKeyword(Self.plainText(result.matchedContents))
        || blocksUser(
          id: result.matchedAuthorID,
          preferredName: result.matchedAuthorName,
          username: result.matchedAuthorUsername
        )
    )
  }

  func visibility(for summary: ForumPostSearchSummary) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(summary.title)
        || blocksKeyword(summary.excerpt)
        || blocksUser(
          id: summary.authorID,
          preferredName: summary.authorName,
          username: summary.authorUsername
        )
    )
  }

  func applying(
    to thread: BrowseThread,
    hasKnownVideo: Bool = false
  ) -> BrowseThread {
    thread.withLocalVisibility(
      visibility(for: thread, hasKnownVideo: hasKnownVideo)
    )
  }

  func applying(to post: BrowsePost) -> BrowsePost {
    post.withLocalPresentation(
      visibility: visibility(for: post),
      inlineComments: post.inlineComments.map { applying(to: $0) }
    )
  }

  func applying(to comment: BrowseComment) -> BrowseComment {
    comment.withLocalVisibility(visibility(for: comment))
  }

  func applying(to parentPost: CommentParentPostContext) -> CommentParentPostContext {
    parentPost.withLocalVisibility(visibility(for: parentPost))
  }

  func applying(to reply: BrowseUserReply) -> BrowseUserReply {
    reply.withLocalVisibility(visibility(for: reply))
  }

  func applying(
    to result: ForumPostSearchItem,
    hasKnownVideo: Bool = false
  ) -> ForumPostSearchItem {
    result.withLocalPresentation(
      visibility: visibility(for: result, hasKnownVideo: hasKnownVideo),
      thread: applying(to: result.thread),
      context: result.context.map {
        $0.withLocalVisibility(visibility(for: $0))
      }
    )
  }

  private func visibility(isBlocked: Bool) -> LocalContentVisibility {
    guard isBlocked else { return .visible }
    switch displayMode {
    case .placeholder:
      return .placeholder
    case .hidden:
      return .hidden
    }
  }

  private func blocksKeyword(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let keywordRules = rules.filter { $0.kind == .keyword }
    if keywordRules.contains(where: { $0.list == .allow && text.contains($0.keyword) }) {
      return false
    }
    return keywordRules.contains { $0.list == .block && text.contains($0.keyword) }
  }

  private func blocksUser(
    id: Int64,
    preferredName: String,
    username: String
  ) -> Bool {
    let userRules = rules.filter { $0.kind == .user }
    if userRules.contains(where: {
      $0.list == .allow && Self.matchesUser($0, id, preferredName, username)
    }) {
      return false
    }
    return userRules.contains {
      $0.list == .block && Self.matchesUser($0, id, preferredName, username)
    }
  }

  private static func matchesUser(
    _ rule: ContentFilterRule,
    _ userID: Int64,
    _ preferredName: String,
    _ username: String
  ) -> Bool {
    let matchesID = rule.userID.map { userID > 0 && $0 == userID } ?? false
    let matchesName = !rule.username.isEmpty
      && (rule.username == preferredName || rule.username == username)
    return matchesID || matchesName
  }

  private static func plainText(_ contents: [BrowseContent]) -> String {
    contents.map { content in
      switch content {
      case .text(let text):
        text
      case .mention(let name, _):
        "@\(name)"
      case .link(let label, _):
        label
      case .emoticon(let name, _):
        name
      case .unsupported(let label):
        label
      case .image, .video, .voice:
        ""
      }
    }.joined()
  }

  private static func isVideo(_ content: BrowseContent) -> Bool {
    guard case .video = content else { return false }
    return true
  }
}
