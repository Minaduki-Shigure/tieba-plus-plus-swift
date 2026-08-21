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
  static let schemaVersion = 3
  static let defaultMaximumDrafts = 64
  static let defaultMaximumArchiveBytes = 8 * 1_024 * 1_024
  private static let legacySchemaVersion = 1
  private static let attachmentSchemaVersion = 2

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

  private struct LegacyArchiveV1: Decodable, Sendable {
    let schemaVersion: Int
    let drafts: [LegacyDraftV1]
  }

  private struct LegacyArchiveV2: Decodable, Sendable {
    let schemaVersion: Int
    let drafts: [LegacyDraftV2]
  }

  private struct LegacyDraftV2: Decodable, Sendable {
    let key: NewThreadDraftKey
    let title: String?
    let content: String
    let attachments: [ComposerImageAttachment]
    let disposition: NewThreadDraftDisposition
    let updatedAt: Date

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let disposition = try container.decode(
        NewThreadDraftDisposition.self,
        forKey: .disposition
      )
      guard
        disposition.imageSubmissionReference == nil,
        !container.contains(.imageWatermark)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .disposition,
          in: container,
          debugDescription: "Schema v2 drafts cannot contain v3 image submission fields."
        )
      }
      self.key = try container.decode(NewThreadDraftKey.self, forKey: .key)
      self.title = try container.decodeIfPresent(String.self, forKey: .title)
      self.content = try container.decode(String.self, forKey: .content)
      self.attachments = try container.decode(
        [ComposerImageAttachment].self,
        forKey: .attachments
      )
      self.disposition = disposition
      self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func migrated() -> NewThreadDraft? {
      NewThreadDraft(
        key: key,
        title: title,
        content: content,
        attachments: attachments,
        imageWatermark: .forumName,
        disposition: disposition,
        updatedAt: updatedAt
      )
    }

    private enum CodingKeys: CodingKey {
      case key
      case title
      case content
      case attachments
      case imageWatermark
      case disposition
      case updatedAt
    }
  }

  private struct LegacyDraftV1: Decodable, Sendable {
    let key: NewThreadDraftKey
    let title: String?
    let content: String
    let disposition: NewThreadDraftDisposition
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
      case key
      case title
      case content
      case disposition
      case updatedAt
      case attachments
      case imageWatermark
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard
        !container.contains(.attachments),
        !container.contains(.imageWatermark)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .attachments,
          in: container,
          debugDescription: "Schema v1 drafts cannot contain image fields."
        )
      }
      self.key = try container.decode(NewThreadDraftKey.self, forKey: .key)
      self.title = try container.decodeIfPresent(String.self, forKey: .title)
      self.content = try container.decode(String.self, forKey: .content)
      self.disposition = try container.decode(
        NewThreadDraftDisposition.self,
        forKey: .disposition
      )
      self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func migrated() -> NewThreadDraft? {
      NewThreadDraft(
        key: key,
        title: title,
        content: content,
        attachments: [],
        imageWatermark: .forumName,
        disposition: disposition,
        updatedAt: updatedAt
      )
    }
  }

  private let fileURL: URL
  private let maximumDrafts: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync: @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    maximumDrafts: Int = defaultMaximumDrafts,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (
      @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void
    )? = nil
  ) {
    self.fileURL = fileURL.standardizedFileURL
    self.maximumDrafts = max(maximumDrafts, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.prepareStagedFile =
      prepareStagedFile ?? { url in
        try FileNewThreadDraftStore.applyStorageAttributes(to: url)
      }
    self.beforeDurabilitySync = beforeDurabilitySync ?? { _ in }
  }

  static func live(fileManager: FileManager = .default) -> FileNewThreadDraftStore {
    let applicationSupport =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory
    return FileNewThreadDraftStore(
      fileURL:
        applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("new-thread-drafts.json", isDirectory: false)
    )
  }

  func draft(for key: NewThreadDraftKey) throws -> NewThreadDraft? {
    try loadArchive().drafts.first(where: { $0.key == key })
  }

  func deletionProtectedAttachmentIDs() throws -> Set<UUID> {
    Set(
      try loadArchive().drafts.lazy
        .filter { ComposerImageAttachmentReferencePolicy.retainsFiles($0.disposition) }
        .flatMap { $0.attachments.map(\.id) }
    )
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
    let archive: Archive
    switch header.schemaVersion {
    case Self.schemaVersion:
      do {
        archive = try decoder.decode(Archive.self, from: data)
        guard archive.schemaVersion == Self.schemaVersion else {
          throw NewThreadDraftStoreError.corruptedArchive
        }
      } catch let error as NewThreadDraftStoreError {
        throw error
      } catch {
        throw NewThreadDraftStoreError.corruptedArchive
      }
    case Self.legacySchemaVersion:
      do {
        let legacy = try decoder.decode(LegacyArchiveV1.self, from: data)
        guard legacy.schemaVersion == Self.legacySchemaVersion else {
          throw NewThreadDraftStoreError.corruptedArchive
        }
        var migratedDrafts: [NewThreadDraft] = []
        migratedDrafts.reserveCapacity(legacy.drafts.count)
        for legacyDraft in legacy.drafts {
          guard let migrated = legacyDraft.migrated() else {
            throw NewThreadDraftStoreError.corruptedArchive
          }
          migratedDrafts.append(migrated)
        }
        archive = Archive(schemaVersion: Self.schemaVersion, drafts: migratedDrafts)
      } catch let error as NewThreadDraftStoreError {
        throw error
      } catch {
        throw NewThreadDraftStoreError.corruptedArchive
      }
    case Self.attachmentSchemaVersion:
      do {
        let legacy = try decoder.decode(LegacyArchiveV2.self, from: data)
        guard legacy.schemaVersion == Self.attachmentSchemaVersion else {
          throw NewThreadDraftStoreError.corruptedArchive
        }
        var migratedDrafts: [NewThreadDraft] = []
        migratedDrafts.reserveCapacity(legacy.drafts.count)
        for legacyDraft in legacy.drafts {
          guard let migrated = legacyDraft.migrated() else {
            throw NewThreadDraftStoreError.corruptedArchive
          }
          migratedDrafts.append(migrated)
        }
        archive = Archive(schemaVersion: Self.schemaVersion, drafts: migratedDrafts)
      } catch let error as NewThreadDraftStoreError {
        throw error
      } catch {
        throw NewThreadDraftStoreError.corruptedArchive
      }
    default:
      throw NewThreadDraftStoreError.unsupportedSchemaVersion(header.schemaVersion)
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
    do {
      try ComposerDurableFileWriter(
        targetURL: fileURL,
        maximumByteCount: maximumArchiveBytes,
        stagedFilenamePrefix: ".new-thread-drafts-",
        prepareStorageDirectory: { url in
          try FileNewThreadDraftStore.applyStorageAttributes(to: url)
        },
        prepareStagedFile: prepareStagedFile,
        beforeDurabilitySync: beforeDurabilitySync
      ).persist(data)
    } catch {
      throw NewThreadDraftStoreError.writeFailed
    }
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
      ComposerImageDraftPolicy.isValid(draft.attachments),
      draft.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      let validated = NewThreadDraft(
        key: draft.key,
        title: draft.title,
        content: draft.content,
        attachments: draft.attachments,
        imageWatermark: draft.imageWatermark,
        disposition: draft.disposition,
        updatedAt: draft.updatedAt
      ),
      validated == draft
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
