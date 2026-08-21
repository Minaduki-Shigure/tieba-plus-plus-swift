import Foundation

enum TextReplyDraftStoreError: LocalizedError, Sendable, Equatable {
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
      "回复草稿无效。"
    case .readFailed:
      "无法读取回复草稿。"
    case .writeFailed:
      "无法保存回复草稿。"
    case .corruptedArchive:
      "回复草稿文件已损坏，未进行覆盖。"
    case .unsupportedSchemaVersion:
      "回复草稿来自更新版本，当前版本不会修改它。"
    case .archiveTooLarge:
      "回复草稿文件超过安全大小限制。"
    case .tooManyDrafts:
      "回复草稿数量超过安全限制。"
    }
  }
}

protocol TextReplyDraftRepository: Sendable {
  func draft(for key: TextReplyDraftKey) async throws -> TextReplyDraft?
  func save(_ draft: TextReplyDraft) async throws
  func delete(for key: TextReplyDraftKey) async throws
  func deleteAll() async throws
}

actor FileTextReplyDraftStore: TextReplyDraftRepository {
  static let schemaVersion = 2
  static let defaultMaximumDrafts = 64
  static let defaultMaximumArchiveBytes = 8 * 1_024 * 1_024
  private static let legacySchemaVersion = 1

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var drafts: [TextReplyDraft]

    static var empty: Self {
      Archive(schemaVersion: FileTextReplyDraftStore.schemaVersion, drafts: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private struct LegacyArchiveV1: Decodable, Sendable {
    let schemaVersion: Int
    let drafts: [LegacyDraftV1]
  }

  private struct LegacyDraftV1: Decodable, Sendable {
    let key: TextReplyDraftKey
    let content: String
    let disposition: TextReplyDraftDisposition
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
      case key
      case content
      case disposition
      case updatedAt
      case attachments
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard !container.contains(.attachments) else {
        throw DecodingError.dataCorruptedError(
          forKey: .attachments,
          in: container,
          debugDescription: "Schema v1 drafts cannot contain image attachments."
        )
      }
      self.key = try container.decode(TextReplyDraftKey.self, forKey: .key)
      self.content = try container.decode(String.self, forKey: .content)
      self.disposition = try container.decode(
        TextReplyDraftDisposition.self,
        forKey: .disposition
      )
      self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func migrated() -> TextReplyDraft? {
      TextReplyDraft(
        key: key,
        content: content,
        attachments: [],
        disposition: disposition,
        updatedAt: updatedAt
      )
    }
  }

  private let fileURL: URL
  private let maximumDrafts: Int
  private let maximumArchiveBytes: Int
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumDrafts: Int = defaultMaximumDrafts,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes
  ) {
    self.fileURL = fileURL
    self.maximumDrafts = max(maximumDrafts, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
  }

  static func live(fileManager: FileManager = .default) -> FileTextReplyDraftStore {
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return FileTextReplyDraftStore(
      fileURL: applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("text-reply-drafts.json", isDirectory: false)
    )
  }

  func draft(for key: TextReplyDraftKey) throws -> TextReplyDraft? {
    try loadArchive().drafts.first(where: { $0.key == key })
  }

  func save(_ draft: TextReplyDraft) throws {
    try Self.validate(draft)
    var archive = try loadArchive()
    archive.drafts.removeAll { $0.key == draft.key }
    archive.drafts.append(draft)
    archive.drafts.sort(by: Self.isMoreRecent)
    if archive.drafts.count > maximumDrafts {
      archive.drafts = Array(archive.drafts.prefix(maximumDrafts))
      guard archive.drafts.contains(where: { $0.key == draft.key }) else {
        throw TextReplyDraftStoreError.tooManyDrafts
      }
    }
    try commit(archive)
  }

  func delete(for key: TextReplyDraftKey) throws {
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
      throw TextReplyDraftStoreError.writeFailed
    }
  }

  private func loadArchive() throws -> Archive {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw TextReplyDraftStoreError.readFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw TextReplyDraftStoreError.archiveTooLarge
    }

    let decoder = Self.makeDecoder()
    let header: ArchiveHeader
    do {
      header = try decoder.decode(ArchiveHeader.self, from: data)
    } catch {
      throw TextReplyDraftStoreError.corruptedArchive
    }
    let archive: Archive
    switch header.schemaVersion {
    case Self.schemaVersion:
      do {
        archive = try decoder.decode(Archive.self, from: data)
        guard archive.schemaVersion == Self.schemaVersion else {
          throw TextReplyDraftStoreError.corruptedArchive
        }
      } catch let error as TextReplyDraftStoreError {
        throw error
      } catch {
        throw TextReplyDraftStoreError.corruptedArchive
      }
    case Self.legacySchemaVersion:
      do {
        let legacy = try decoder.decode(LegacyArchiveV1.self, from: data)
        guard legacy.schemaVersion == Self.legacySchemaVersion else {
          throw TextReplyDraftStoreError.corruptedArchive
        }
        var migratedDrafts: [TextReplyDraft] = []
        migratedDrafts.reserveCapacity(legacy.drafts.count)
        for legacyDraft in legacy.drafts {
          guard let migrated = legacyDraft.migrated() else {
            throw TextReplyDraftStoreError.corruptedArchive
          }
          migratedDrafts.append(migrated)
        }
        archive = Archive(schemaVersion: Self.schemaVersion, drafts: migratedDrafts)
      } catch let error as TextReplyDraftStoreError {
        throw error
      } catch {
        throw TextReplyDraftStoreError.corruptedArchive
      }
    default:
      throw TextReplyDraftStoreError.unsupportedSchemaVersion(header.schemaVersion)
    }
    guard archive.drafts.count <= maximumDrafts else {
      throw TextReplyDraftStoreError.tooManyDrafts
    }
    do {
      try archive.drafts.forEach(Self.validate)
    } catch {
      throw TextReplyDraftStoreError.corruptedArchive
    }
    guard Set(archive.drafts.map(\.key)).count == archive.drafts.count else {
      throw TextReplyDraftStoreError.corruptedArchive
    }
    return archive
  }

  private func commit(_ archive: Archive) throws {
    let data: Data
    do {
      data = try Self.makeEncoder().encode(archive)
    } catch {
      throw TextReplyDraftStoreError.writeFailed
    }
    guard data.count <= maximumArchiveBytes else {
      throw TextReplyDraftStoreError.archiveTooLarge
    }
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
      try applyStorageAttributes()
    } catch let error as TextReplyDraftStoreError {
      throw error
    } catch {
      throw TextReplyDraftStoreError.writeFailed
    }
  }

  private func applyStorageAttributes() throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableFileURL = fileURL
    try mutableFileURL.setResourceValues(values)
#if os(iOS)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: fileURL.path
    )
#endif
  }

  private static func validate(_ draft: TextReplyDraft) throws {
    guard
      draft.key.isValid,
      draft.content.count <= TextReplyDraft.maximumStoredCharacterCount,
      draft.content.utf8.count <= TextReplyDraft.maximumStoredUTF8ByteCount,
      ComposerImageDraftPolicy.isValid(draft.attachments),
      draft.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      TextReplyDraft(
        key: draft.key,
        content: draft.content,
        attachments: draft.attachments,
        disposition: draft.disposition,
        updatedAt: draft.updatedAt
      ) != nil
    else {
      throw TextReplyDraftStoreError.invalidDraft
    }
  }

  private static func isMoreRecent(_ lhs: TextReplyDraft, _ rhs: TextReplyDraft) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    if lhs.key.userID != rhs.key.userID { return lhs.key.userID < rhs.key.userID }
    if lhs.key.threadID != rhs.key.threadID { return lhs.key.threadID < rhs.key.threadID }
    return String(describing: lhs.key.destination) < String(describing: rhs.key.destination)
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
