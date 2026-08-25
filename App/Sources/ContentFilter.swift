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

enum ContentFilterKeywordMatchMode:
  String, CaseIterable, Codable, Hashable, Identifiable, Sendable
{
  case literal
  case regularExpression = "regular-expression"

  var id: Self { self }

  var title: String {
    switch self {
    case .literal:
      "普通关键词"
    case .regularExpression:
      "正则表达式"
    }
  }
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
  private let compiledRegularExpression: SafeContentFilterRegex?

  private enum CodingKeys: String, CodingKey {
    case id
    case list
    case kind
    case keyword
    case keywordMatchMode
    case userID
    case username
    case createdAt
  }

  private init(
    id: UUID = UUID(),
    list: ContentFilterList,
    kind: ContentFilterRuleKind,
    keyword: String = "",
    keywordMatchMode: ContentFilterKeywordMatchMode = .literal,
    userID: Int64? = nil,
    username: String = "",
    createdAt: Date = Date(),
    compiledRegularExpression: SafeContentFilterRegex? = nil
  ) {
    self.id = id
    self.list = list
    self.kind = kind
    self.keyword = keyword
    self.keywordMatchMode = keywordMatchMode
    self.userID = userID
    self.username = username
    self.createdAt = createdAt
    self.compiledRegularExpression = compiledRegularExpression
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let list = try container.decode(ContentFilterList.self, forKey: .list)
    let kind = try container.decode(ContentFilterRuleKind.self, forKey: .kind)
    let keyword = try container.decode(String.self, forKey: .keyword)
    let keywordMatchMode = try container.decode(
      ContentFilterKeywordMatchMode.self,
      forKey: .keywordMatchMode
    )
    let userID = try container.decodeIfPresent(Int64.self, forKey: .userID)
    let username = try container.decode(String.self, forKey: .username)
    let createdAt = try container.decode(Date.self, forKey: .createdAt)
    let compiledRegularExpression: SafeContentFilterRegex?
    switch (kind, keywordMatchMode) {
    case (.keyword, .regularExpression):
      do {
        compiledRegularExpression = try SafeContentFilterRegex(keyword)
      } catch {
        throw DecodingError.dataCorruptedError(
          forKey: .keyword,
          in: container,
          debugDescription: "The bounded regular expression is invalid."
        )
      }
    case (.keyword, .literal), (.user, .literal):
      compiledRegularExpression = nil
    case (.user, .regularExpression):
      throw DecodingError.dataCorruptedError(
        forKey: .keywordMatchMode,
        in: container,
        debugDescription: "A user rule cannot use keyword matching."
      )
    }
    self.init(
      id: id,
      list: list,
      kind: kind,
      keyword: keyword,
      keywordMatchMode: keywordMatchMode,
      userID: userID,
      username: username,
      createdAt: createdAt,
      compiledRegularExpression: compiledRegularExpression
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(list, forKey: .list)
    try container.encode(kind, forKey: .kind)
    try container.encode(keyword, forKey: .keyword)
    try container.encode(keywordMatchMode, forKey: .keywordMatchMode)
    try container.encodeIfPresent(userID, forKey: .userID)
    try container.encode(username, forKey: .username)
    try container.encode(createdAt, forKey: .createdAt)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.list == rhs.list
      && lhs.kind == rhs.kind
      && lhs.keyword == rhs.keyword
      && lhs.keywordMatchMode == rhs.keywordMatchMode
      && lhs.userID == rhs.userID
      && lhs.username == rhs.username
      && lhs.createdAt == rhs.createdAt
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(list)
    hasher.combine(kind)
    hasher.combine(keyword)
    hasher.combine(keywordMatchMode)
    hasher.combine(userID)
    hasher.combine(username)
    hasher.combine(createdAt)
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

  static func regularExpression(
    _ pattern: String,
    list: ContentFilterList,
    id: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> Self {
    let compiled = try SafeContentFilterRegex(pattern)
    return ContentFilterRule(
      id: id,
      list: list,
      kind: .keyword,
      keyword: pattern,
      keywordMatchMode: .regularExpression,
      createdAt: createdAt,
      compiledRegularExpression: compiled
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

  fileprivate func matchesRegularExpression(
    in input: SafeContentFilterRegex.Input,
    workspace: inout SafeContentFilterRegex.Workspace,
    remainingSteps: inout Int
  ) -> SafeContentFilterRegex.MatchResult {
    compiledRegularExpression?.match(
      in: input,
      workspace: &workspace,
      remainingSteps: &remainingSteps
    ) ?? .budgetExhausted
  }
}

struct ContentFilterSnapshot: Codable, Hashable, Sendable {
  let displayMode: ContentFilterDisplayMode
  let blockVideos: Bool
  let rules: [ContentFilterRule]

  private let literalKeywordAllowRules: [ContentFilterRule]
  private let literalKeywordBlockRules: [ContentFilterRule]
  private let regularExpressionAllowRules: [ContentFilterRule]
  private let regularExpressionBlockRules: [ContentFilterRule]
  private let allowedUserIDs: Set<Int64>
  private let blockedUserIDs: Set<Int64>
  private let allowedUsernames: Set<String>
  private let blockedUsernames: Set<String>

  private enum CodingKeys: String, CodingKey {
    case displayMode
    case blockVideos
    case rules
  }

  init(
    displayMode: ContentFilterDisplayMode,
    blockVideos: Bool,
    rules: [ContentFilterRule]
  ) {
    self.displayMode = displayMode
    self.blockVideos = blockVideos
    self.rules = rules
    self.literalKeywordAllowRules = rules.filter {
      $0.kind == .keyword && $0.list == .allow && $0.keywordMatchMode == .literal
    }
    self.literalKeywordBlockRules = rules.filter {
      $0.kind == .keyword && $0.list == .block && $0.keywordMatchMode == .literal
    }
    self.regularExpressionAllowRules = rules.filter {
      $0.kind == .keyword
        && $0.list == .allow
        && $0.keywordMatchMode == .regularExpression
    }
    self.regularExpressionBlockRules = rules.filter {
      $0.kind == .keyword
        && $0.list == .block
        && $0.keywordMatchMode == .regularExpression
    }

    let allowedUsers = rules.filter { $0.kind == .user && $0.list == .allow }
    let blockedUsers = rules.filter { $0.kind == .user && $0.list == .block }
    self.allowedUserIDs = Set(allowedUsers.compactMap(\.userID))
    self.blockedUserIDs = Set(blockedUsers.compactMap(\.userID))
    self.allowedUsernames = Set(allowedUsers.map(\.username).filter { !$0.isEmpty })
    self.blockedUsernames = Set(blockedUsers.map(\.username).filter { !$0.isEmpty })
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      displayMode: try container.decode(ContentFilterDisplayMode.self, forKey: .displayMode),
      blockVideos: try container.decode(Bool.self, forKey: .blockVideos),
      rules: try container.decode([ContentFilterRule].self, forKey: .rules)
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(displayMode, forKey: .displayMode)
    try container.encode(blockVideos, forKey: .blockVideos)
    try container.encode(rules, forKey: .rules)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.displayMode == rhs.displayMode
      && lhs.blockVideos == rhs.blockVideos
      && lhs.rules == rhs.rules
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(displayMode)
    hasher.combine(blockVideos)
    hasher.combine(rules)
  }

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

enum ContentFilterKeywordPatternError: LocalizedError, Equatable, Sendable {
  case empty
  case tooLong
  case invalidRegularExpression(String)

  var errorDescription: String? {
    switch self {
    case .empty:
      "请输入匹配内容。"
    case .tooLong:
      "匹配内容不能超过 \(SafeContentFilterRegex.maximumPatternCharacters) 个字符。"
    case .invalidRegularExpression(let message):
      message
    }
  }
}

enum ContentFilterKeywordPatternPolicy {
  static func validated(
    _ value: String,
    mode: ContentFilterKeywordMatchMode
  ) throws -> String {
    let normalized = normalized(value, mode: mode)
    guard !normalized.isEmpty else { throw ContentFilterKeywordPatternError.empty }
    guard normalized.count <= SafeContentFilterRegex.maximumPatternCharacters else {
      throw ContentFilterKeywordPatternError.tooLong
    }

    if mode == .regularExpression {
      do {
        _ = try SafeContentFilterRegex(normalized)
      } catch {
        throw ContentFilterKeywordPatternError.invalidRegularExpression(
          (error as? any LocalizedError)?.errorDescription ?? "正则表达式无效。"
        )
      }
    }
    return normalized
  }

  static func validationMessage(
    for value: String,
    mode: ContentFilterKeywordMatchMode
  ) -> String? {
    do {
      _ = try validated(value, mode: mode)
      return nil
    } catch {
      return (error as? any LocalizedError)?.errorDescription ?? "匹配内容无效。"
    }
  }

  private static func normalized(
    _ value: String,
    mode: ContentFilterKeywordMatchMode
  ) -> String {
    let canonical = value.precomposedStringWithCanonicalMapping
    switch mode {
    case .literal:
      return canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    case .regularExpression:
      return canonical
    }
  }
}

enum ContentFilterStoreError: LocalizedError, Equatable, Sendable {
  case invalidRule
  case duplicateRule
  case tooManyRules
  case tooManyRegularExpressions
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
    case .tooManyRegularExpressions:
      "正则表达式规则数量已达到安全上限。"
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
  static let schemaVersion = 2
  static let defaultMaximumRules = 500
  static let defaultMaximumRegularExpressionRules = 32
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

  private struct LegacyArchiveV1: Decodable, Sendable {
    let schemaVersion: Int
    let displayMode: ContentFilterDisplayMode
    let blockVideos: Bool
    let rules: [LegacyRuleV1]
  }

  private struct LegacyRuleV1: Decodable, Sendable {
    let id: UUID
    let list: ContentFilterList
    let kind: ContentFilterRuleKind
    let keyword: String
    let keywordMatchMode: ContentFilterKeywordMatchMode
    let userID: Int64?
    let username: String
    let createdAt: Date

    func migrated() throws -> ContentFilterRule {
      guard keywordMatchMode == .literal else {
        throw ContentFilterStoreError.invalidRule
      }
      switch kind {
      case .keyword:
        return .keyword(keyword, list: list, id: id, createdAt: createdAt)
      case .user:
        return .user(
          id: userID,
          name: username,
          list: list,
          ruleID: id,
          createdAt: createdAt
        )
      }
    }
  }

  private let fileURL: URL
  private let maximumRules: Int
  private let maximumRegularExpressionRules: Int
  private let maximumArchiveBytes: Int
  private var cachedArchive: Archive?
  private var cachedSnapshot: ContentFilterSnapshot?
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumRules: Int = defaultMaximumRules,
    maximumRegularExpressionRules: Int = defaultMaximumRegularExpressionRules,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumRules = max(maximumRules, 1)
    self.maximumRegularExpressionRules = max(maximumRegularExpressionRules, 1)
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
    if let cachedSnapshot { return cachedSnapshot }
    let archive = try loadArchive()
    let snapshot = ContentFilterSnapshot(
      displayMode: archive.displayMode,
      blockVideos: archive.blockVideos,
      rules: archive.rules
    )
    cachedSnapshot = snapshot
    return snapshot
  }

  @discardableResult
  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    let rule = try Self.normalizedRule(rule)
    var candidate = try loadArchiveForMutation()
    guard candidate.rules.count < maximumRules else {
      throw ContentFilterStoreError.tooManyRules
    }
    if rule.kind == .keyword && rule.keywordMatchMode == .regularExpression {
      let regularExpressionCount = candidate.rules.lazy.filter {
        $0.kind == .keyword && $0.keywordMatchMode == .regularExpression
      }.count
      guard regularExpressionCount < maximumRegularExpressionRules else {
        throw ContentFilterStoreError.tooManyRegularExpressions
      }
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
    var candidate = try loadArchiveForMutation()
    let previousCount = candidate.rules.count
    candidate.rules.removeAll { $0.id == id }
    guard candidate.rules.count != previousCount else { return }
    try commit(candidate)
    notifyChange()
  }

  func deleteAll(in list: ContentFilterList) async throws {
    var candidate = try loadArchiveForMutation()
    let previousCount = candidate.rules.count
    candidate.rules.removeAll { $0.list == list }
    guard candidate.rules.count != previousCount else { return }
    try commit(candidate)
    notifyChange()
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    var candidate = try loadArchiveForMutation()
    guard candidate.displayMode != mode else { return }
    candidate.displayMode = mode
    try commit(candidate)
    notifyChange()
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    var candidate = try loadArchiveForMutation()
    guard candidate.blockVideos != blockVideos else { return }
    candidate.blockVideos = blockVideos
    try commit(candidate)
    notifyChange()
  }

  func reset() async throws {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      cachedArchive = .empty
      cachedSnapshot = .empty
      return
    }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw ContentFilterStoreError.writeFailed
    }
    cachedArchive = .empty
    cachedSnapshot = .empty
    notifyChange()
  }

  private func loadArchive() throws -> Archive {
    if let cachedArchive { return cachedArchive }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      let archive = Archive.empty
      cachedArchive = archive
      return archive
    }
    let archive = try decodedArchiveFromDisk()
    cachedArchive = archive
    return archive
  }

  private func loadArchiveForMutation() throws -> Archive {
    cachedArchive = nil
    cachedSnapshot = nil
    guard fileManager.fileExists(atPath: fileURL.path) else {
      let archive = Archive.empty
      cachedArchive = archive
      return archive
    }
    let archive = try decodedArchiveFromDisk()
    cachedArchive = archive
    cachedSnapshot = ContentFilterSnapshot(
      displayMode: archive.displayMode,
      blockVideos: archive.blockVideos,
      rules: archive.rules
    )
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
    do {
      let archive: Archive
      switch header.schemaVersion {
      case 1:
        let legacy = try decoder.decode(LegacyArchiveV1.self, from: data)
        archive = Archive(
          schemaVersion: Self.schemaVersion,
          displayMode: legacy.displayMode,
          blockVideos: legacy.blockVideos,
          rules: try legacy.rules.map { try $0.migrated() }
        )
      case Self.schemaVersion:
        archive = try decoder.decode(Archive.self, from: data)
      default:
        throw ContentFilterStoreError.unsupportedSchemaVersion(header.schemaVersion)
      }
      guard archive.rules.count <= maximumRules else {
        throw ContentFilterStoreError.corruptedArchive
      }
      guard
        archive.rules.lazy.filter({
          $0.kind == .keyword && $0.keywordMatchMode == .regularExpression
        }).count <= maximumRegularExpressionRules
      else {
        throw ContentFilterStoreError.corruptedArchive
      }
      var normalizedArchive = archive
      normalizedArchive.rules = normalizedRules(
        try archive.rules.map(Self.normalizedRule)
      )
      return normalizedArchive
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
    cachedArchive = candidate
    cachedSnapshot = ContentFilterSnapshot(
      displayMode: candidate.displayMode,
      blockVideos: candidate.blockVideos,
      rules: candidate.rules
    )
  }

  private func normalizedRules(_ rules: [ContentFilterRule]) -> [ContentFilterRule] {
    var newestByIdentity: [String: ContentFilterRule] = [:]
    for rule in rules {
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
    let username = normalizedText(rule.username)
    guard rule.createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ContentFilterStoreError.invalidRule
    }

    switch rule.kind {
    case .keyword:
      let pattern: String
      do {
        pattern = try ContentFilterKeywordPatternPolicy.validated(
          rule.keyword,
          mode: rule.keywordMatchMode
        )
      } catch {
        throw ContentFilterStoreError.invalidRule
      }
      switch rule.keywordMatchMode {
      case .literal:
        return .keyword(
          pattern,
          list: rule.list,
          id: rule.id,
          createdAt: rule.createdAt
        )
      case .regularExpression:
        do {
          return try .regularExpression(
            pattern,
            list: rule.list,
            id: rule.id,
            createdAt: rule.createdAt
          )
        } catch {
          throw ContentFilterStoreError.invalidRule
        }
      }
    case .user:
      if let userID = rule.userID, userID <= 0 {
        throw ContentFilterStoreError.invalidRule
      }
      guard username.count <= 100, rule.userID != nil || !username.isEmpty else {
        throw ContentFilterStoreError.invalidRule
      }
      return .user(
        id: rule.userID,
        name: username,
        list: rule.list,
        ruleID: rule.id,
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
  static let regularExpressionStepBudgetPerField = 200_000

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

  func visibility(for message: InboxMessage) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(message.content)
        || blocksUser(
          id: message.sender.id,
          preferredName: message.sender.displayName,
          username: message.sender.username
        )
    )
  }

  func visibility(for user: BrowseRelatedUser) -> LocalContentVisibility {
    visibility(
      isBlocked: blocksKeyword(user.displayName)
        || blocksKeyword(user.username)
        || blocksKeyword(user.introduction)
        || blocksUser(
          id: user.id,
          preferredName: user.preferredName,
          username: user.username
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

  func applying(to user: BrowseRelatedUser) -> BrowseRelatedUser {
    user.withLocalVisibility(visibility(for: user))
  }

  func applying(
    to result: ForumPostSearchItem,
    hasKnownVideo: Bool = false
  ) -> ForumPostSearchItem {
    result.withLocalPresentation(
      visibility: visibility(for: result, hasKnownVideo: hasKnownVideo),
      thread: applying(to: result.thread),
      contexts: result.contexts.map { context in
        context.withLocalVisibility(visibility(for: context.summary))
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
    if literalKeywordAllowRules.contains(where: { text.contains($0.keyword) }) {
      return false
    }

    if regularExpressionAllowRules.isEmpty {
      if literalKeywordBlockRules.contains(where: { text.contains($0.keyword) }) {
        return true
      }
      guard !regularExpressionBlockRules.isEmpty else { return false }

      let input = SafeContentFilterRegex.Input(text)
      var workspace = SafeContentFilterRegex.Workspace()
      var remainingSteps = Self.regularExpressionStepBudgetPerField
      return regularExpressionMatch(
        in: regularExpressionBlockRules,
        input: input,
        workspace: &workspace,
        remainingSteps: &remainingSteps
      ) == .matched
    }

    let input = SafeContentFilterRegex.Input(text)
    var workspace = SafeContentFilterRegex.Workspace()
    var remainingSteps = Self.regularExpressionStepBudgetPerField
    switch regularExpressionMatch(
      in: regularExpressionAllowRules,
      input: input,
      workspace: &workspace,
      remainingSteps: &remainingSteps
    ) {
    case .matched, .budgetExhausted:
      return false
    case .notMatched:
      break
    }

    if literalKeywordBlockRules.contains(where: { text.contains($0.keyword) }) {
      return true
    }
    return regularExpressionMatch(
      in: regularExpressionBlockRules,
      input: input,
      workspace: &workspace,
      remainingSteps: &remainingSteps
    ) == .matched
  }

  private func regularExpressionMatch(
    in rules: [ContentFilterRule],
    input: SafeContentFilterRegex.Input,
    workspace: inout SafeContentFilterRegex.Workspace,
    remainingSteps: inout Int
  ) -> SafeContentFilterRegex.MatchResult {
    for rule in rules {
      switch rule.matchesRegularExpression(
        in: input,
        workspace: &workspace,
        remainingSteps: &remainingSteps
      ) {
      case .matched:
        return .matched
      case .notMatched:
        continue
      case .budgetExhausted:
        return .budgetExhausted
      }
    }
    return .notMatched
  }

  private func blocksUser(
    id: Int64,
    preferredName: String,
    username: String
  ) -> Bool {
    if Self.matchesUser(
      id: id,
      preferredName: preferredName,
      username: username,
      ids: allowedUserIDs,
      names: allowedUsernames
    ) {
      return false
    }
    return Self.matchesUser(
      id: id,
      preferredName: preferredName,
      username: username,
      ids: blockedUserIDs,
      names: blockedUsernames
    )
  }

  private static func matchesUser(
    id userID: Int64,
    preferredName: String,
    username: String,
    ids: Set<Int64>,
    names: Set<String>
  ) -> Bool {
    let matchesID = userID > 0 && ids.contains(userID)
    let matchesName = names.contains(preferredName) || names.contains(username)
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
