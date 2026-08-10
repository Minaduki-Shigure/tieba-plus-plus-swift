import Foundation

enum NewThreadDraftStoreError: LocalizedError, Sendable, Equatable {
  case invalidDraft
  case readFailed
  case writeFailed
  case corruptedArchive
  case unsupportedSchemaVersion(Int)
  case archiveTooLarge
  case tooManyDrafts

  var errorDescription: String? {
    switch self {
    case .invalidDraft:
      "主题草稿无效。"
    case .readFailed:
      "无法读取主题草稿。"
    case .writeFailed:
      "无法保存主题草稿。"
    case .corruptedArchive:
      "主题草稿文件已损坏，未进行覆盖。"
    case .unsupportedSchemaVersion:
      "主题草稿来自更新版本，当前版本不会修改它。"
    case .archiveTooLarge:
      "主题草稿文件超过安全大小限制。"
    case .tooManyDrafts:
      "主题草稿数量超过安全限制。"
    }
  }
}

protocol NewThreadDraftRepository: Sendable {
  func draft(for key: NewThreadDraftKey) async throws -> NewThreadDraft?
  func save(_ draft: NewThreadDraft) async throws
  func delete(for key: NewThreadDraftKey) async throws
  func deleteAll() async throws
}

actor FileNewThreadDraftStore: NewThreadDraftRepository {
  static let schemaVersion = 1
  static let defaultMaximumDrafts = 64
  static let defaultMaximumArchiveBytes = 8 * 1_024 * 1_024

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var drafts: [NewThreadDraft]

    static var empty: Self {
      Archive(schemaVersion: FileNewThreadDraftStore.schemaVersion, drafts: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let maximumDrafts: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumDrafts: Int = defaultMaximumDrafts,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil
  ) {
    self.fileURL = fileURL
    self.maximumDrafts = max(maximumDrafts, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.prepareStagedFile = prepareStagedFile ?? { url in
      try FileNewThreadDraftStore.applyStorageAttributes(to: url)
    }
  }

  static func live(fileManager: FileManager = .default) -> FileNewThreadDraftStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileNewThreadDraftStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("new-thread-drafts.json", isDirectory: false)
    )
  }

  func draft(for key: NewThreadDraftKey) throws -> NewThreadDraft? {
    try loadArchive().drafts.first(where: { $0.key == key })
  }

  func save(_ draft: NewThreadDraft) throws {
    try Self.validate(draft)
    var archive = try loadArchive()
    archive.drafts.removeAll { $0.key == draft.key }
    archive.drafts.append(draft)
    archive.drafts.sort(by: Self.isMoreRecent)
    if archive.drafts.count > maximumDrafts {
      archive.drafts = Array(archive.drafts.prefix(maximumDrafts))
      guard archive.drafts.contains(where: { $0.key == draft.key }) else {
        throw NewThreadDraftStoreError.tooManyDrafts
      }
    }
    try commit(archive)
  }

  func delete(for key: NewThreadDraftKey) throws {
    var archive = try loadArchive()
    let previousCount = archive.drafts.count
    archive.drafts.removeAll { $0.key == key }
    guard archive.drafts.count != previousCount else { return }
    try commit(archive)
  }

  func deleteAll() throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw NewThreadDraftStoreError.writeFailed
    }
  }

  private func loadArchive() throws -> Archive {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw NewThreadDraftStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw NewThreadDraftStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw NewThreadDraftStoreError.corruptedArchive
    }
    guard header.schemaVersion == Self.schemaVersion else {
      throw NewThreadDraftStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    let archive: Archive
    do {
      archive = try decoder.decode(Archive.self, from: data)
    } catch {
      throw NewThreadDraftStoreError.corruptedArchive
    }
    guard archive.drafts.count <= maximumDrafts else {
      throw NewThreadDraftStoreError.tooManyDrafts
    }
    do {
      try archive.drafts.forEach(Self.validate)
    } catch {
      throw NewThreadDraftStoreError.corruptedArchive
    }
    guard Set(archive.drafts.map(\.key)).count == archive.drafts.count else {
      throw NewThreadDraftStoreError.corruptedArchive
    }
    return archive
  }

  private func commit(_ archive: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(archive)
    } catch {
      throw NewThreadDraftStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw NewThreadDraftStoreError.archiveTooLarge
    }
    let directoryURL = fileURL.deletingLastPathComponent()
    let stagedURL = directoryURL.appendingPathComponent(
      ".new-thread-drafts-\(UUID().uuidString).staged",
      isDirectory: false
    )
    var didAttemptCommit = false
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try data.write(to: stagedURL, options: .atomic)
      try prepareStagedFile(stagedURL)
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
    } catch let error as NewThreadDraftStoreError {
      try? fileManager.removeItem(at: stagedURL)
      if didAttemptCommit, targetArchiveMatches(data) { return }
      throw error
    } catch {
      try? fileManager.removeItem(at: stagedURL)
      if didAttemptCommit, targetArchiveMatches(data) { return }
      throw NewThreadDraftStoreError.writeFailed
    }
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

  private static func validate(_ draft: NewThreadDraft) throws {
    guard
      draft.key.isValid,
      draft.content.count <= NewThreadDraft.maximumStoredContentCharacterCount,
      draft.content.utf8.count <= NewThreadDraft.maximumStoredContentUTF8ByteCount,
      draft.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      NewThreadDraft(
        key: draft.key,
        title: draft.title,
        content: draft.content,
        disposition: draft.disposition,
        updatedAt: draft.updatedAt
      ) != nil
    else {
      throw NewThreadDraftStoreError.invalidDraft
    }
  }

  private static func isMoreRecent(_ lhs: NewThreadDraft, _ rhs: NewThreadDraft) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    if lhs.key.userID != rhs.key.userID { return lhs.key.userID < rhs.key.userID }
    if lhs.key.forumID != rhs.key.forumID { return lhs.key.forumID < rhs.key.forumID }
    return lhs.key.forumName < rhs.key.forumName
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
