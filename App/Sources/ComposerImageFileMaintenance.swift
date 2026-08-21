import Darwin
import Foundation

protocol ComposerImageAttachmentDeletionScheduling: Sendable {
  func scheduleDeletion(of attachments: [ComposerImageAttachment]) async throws
}

struct ComposerImageAttachmentDeletionMaintenanceReport: Equatable, Sendable {
  let auditedTombstoneCount: Int
  let retainedReferenceCount: Int
  let remainingTombstoneCount: Int
}

enum ComposerImageAttachmentDeletionCoordinatorError: Error, Equatable, Sendable {
  case invalidAttachment
  case tombstoneUnavailable
  case referenceAuditUnavailable
}

enum ComposerImageAttachmentReferencePolicy {
  static func retainsFiles(_ disposition: NewThreadDraftDisposition) -> Bool {
    switch disposition {
    case .confirmed, .imageConfirmed:
      false
    case .editing, .submissionPending, .imagePreparationPending, .imagePipeline,
      .challengeRequired, .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility,
      .outcomeUnknown:
      true
    }
  }

  static func retainsFiles(_ disposition: TextReplyDraftDisposition) -> Bool {
    switch disposition {
    case .imageConfirmed:
      false
    case .editing, .submissionPending, .imagePreparationPending, .imagePipeline,
      .challengeRequired, .acceptedAwaitingVisibility, .imageAcceptedAwaitingVisibility,
      .outcomeUnknown:
      true
    }
  }
}

actor ComposerImageAttachmentDeletionCoordinator:
  ComposerImageAttachmentDeletionScheduling
{
  typealias ReferenceProvider = @Sendable () async throws -> Set<UUID>

  static let maximumTombstoneCount = 128

  private let journal: ComposerImageAttachmentDeletionJournal
  private let referenceProvider: ReferenceProvider

  init(
    journalFileURL: URL,
    referenceProvider: @escaping ReferenceProvider
  ) {
    self.journal = ComposerImageAttachmentDeletionJournal(
      fileURL: journalFileURL,
      maximumRecordCount: Self.maximumTombstoneCount
    )
    self.referenceProvider = referenceProvider
  }

  static func live(
    newThreadDrafts: FileNewThreadDraftStore,
    replyDrafts: FileTextReplyDraftStore,
    ledger: ComposerImageUploadLedger,
    fileManager: FileManager = .default
  ) -> ComposerImageAttachmentDeletionCoordinator {
    let applicationSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return ComposerImageAttachmentDeletionCoordinator(
      journalFileURL:
        applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent(
          "composer-image-deletion-tombstones-v1.json",
          isDirectory: false
        )
    ) {
      async let newThreadIDs = newThreadDrafts.deletionProtectedAttachmentIDs()
      async let replyIDs = replyDrafts.deletionProtectedAttachmentIDs()
      async let records = ledger.load()
      let (loadedNewThreadIDs, loadedReplyIDs, loadedRecords) = try await (
        newThreadIDs,
        replyIDs,
        records
      )
      let ledgerIDs = Set(
        loadedRecords.flatMap { record in
          record.attachments.map(\.id)
        }
      )
      return loadedNewThreadIDs.union(loadedReplyIDs).union(ledgerIDs)
    }
  }

  func scheduleDeletion(of attachments: [ComposerImageAttachment]) throws {
    guard !attachments.isEmpty else { return }
    guard
      Set(attachments.map(\.id)).count == attachments.count,
      attachments.allSatisfy(Self.isValid)
    else { throw ComposerImageAttachmentDeletionCoordinatorError.invalidAttachment }
    do {
      try journal.enqueue(attachments)
    } catch {
      throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
    }
  }

  func performMaintenance() async throws
    -> ComposerImageAttachmentDeletionMaintenanceReport
  {
    let tombstones: [ComposerImageAttachment]
    do {
      tombstones = try journal.load()
    } catch {
      throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
    }
    guard !tombstones.isEmpty else {
      return ComposerImageAttachmentDeletionMaintenanceReport(
        auditedTombstoneCount: 0,
        retainedReferenceCount: 0,
        remainingTombstoneCount: 0
      )
    }

    let referencedIDs: Set<UUID>
    do {
      referencedIDs = try await referenceProvider()
    } catch {
      throw ComposerImageAttachmentDeletionCoordinatorError.referenceAuditUnavailable
    }

    // This audit is intentionally not deletion authorization. Draft and ledger
    // actors can mutate after this snapshot, and composers can still own an
    // attachment that has not reached durable metadata. Until all of those
    // owners share an exclusive reference reservation, every tombstone remains
    // on disk rather than risking deletion of a live attachment.
    return ComposerImageAttachmentDeletionMaintenanceReport(
      auditedTombstoneCount: tombstones.count,
      retainedReferenceCount: tombstones.lazy.filter { referencedIDs.contains($0.id) }.count,
      remainingTombstoneCount: tombstones.count
    )
  }

  func pendingDeletionCount() throws -> Int {
    do {
      return try journal.load().count
    } catch {
      throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
    }
  }

  func pendingDeletionIDs() throws -> [UUID] {
    do {
      return try journal.load().map(\.id)
    } catch {
      throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
    }
  }

  fileprivate static func isValid(_ attachment: ComposerImageAttachment) -> Bool {
    ComposerImageAttachment(
      id: attachment.id,
      relativePrivateFilename: attachment.relativePrivateFilename,
      sha256: attachment.sha256,
      byteCount: attachment.byteCount,
      pixelWidth: attachment.pixelWidth,
      pixelHeight: attachment.pixelHeight,
      encoding: attachment.encoding,
      quality: attachment.quality
    ) == attachment
  }
}

private struct ComposerImageAttachmentDeletionJournal: Sendable {
  private struct Envelope: Codable, Sendable {
    let schemaVersion: Int
    var attachments: [ComposerImageAttachment]
  }

  private static let schemaVersion = 1
  private static let maximumArchiveByteCount = 256 * 1_024

  private let fileURL: URL
  private let maximumRecordCount: Int

  init(fileURL: URL, maximumRecordCount: Int) {
    self.fileURL = fileURL.standardizedFileURL
    self.maximumRecordCount = max(maximumRecordCount, 1)
  }

  func load() throws -> [ComposerImageAttachment] {
    guard let status = try Self.itemStatus(at: fileURL) else { return [] }
    guard
      Self.fileType(of: status) == mode_t(S_IFREG),
      status.st_size > 0,
      status.st_size <= off_t(Self.maximumArchiveByteCount)
    else { throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable }
    let data = try ComposerSecureRegularFileReader.read(
      from: fileURL,
      expectedByteCount: Int64(status.st_size),
      maximumByteCount: Int64(Self.maximumArchiveByteCount),
      checksCancellation: false
    )
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    let canonical = try Self.encode(envelope)
    guard
      canonical == data,
      envelope.schemaVersion == Self.schemaVersion,
      envelope.attachments.count <= maximumRecordCount,
      Set(envelope.attachments.map(\.id)).count == envelope.attachments.count,
      envelope.attachments.allSatisfy(ComposerImageAttachmentDeletionCoordinator.isValid)
    else { throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable }
    return envelope.attachments
  }

  func enqueue(_ attachments: [ComposerImageAttachment]) throws {
    var records = try load()
    for attachment in attachments {
      if let existing = records.first(where: { $0.id == attachment.id }) {
        guard existing == attachment else {
          throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
        }
      } else {
        records.append(attachment)
      }
    }
    if records.count > maximumRecordCount {
      // Attachment files are never removed by this journal. Rotating the oldest
      // audit-only tombstones therefore trades bounded diagnostic history for a
      // harmless retained file and cannot authorize a deletion.
      records.removeFirst(records.count - maximumRecordCount)
    }
    try persist(records)
  }

  private func persist(_ attachments: [ComposerImageAttachment]) throws {
    let data = try Self.encode(
      Envelope(schemaVersion: Self.schemaVersion, attachments: attachments)
    )
    let writer = ComposerDurableFileWriter(
      targetURL: fileURL,
      maximumByteCount: Self.maximumArchiveByteCount,
      stagedFilenamePrefix: ".composer-image-deletion-tombstones-",
      prepareStorageDirectory: Self.applyStorageAttributes,
      prepareStagedFile: Self.applyStorageAttributes
    )
    try writer.persist(data)
  }

  private static func encode(_ envelope: Envelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(envelope)
  }

  private static func applyStorageAttributes(to url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
      )
    #endif
  }

  private static func itemStatus(at url: URL) throws -> stat? {
    guard url.isFileURL else {
      throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
    }
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    if result == 0 { return status }
    if errno == ENOENT { return nil }
    throw ComposerImageAttachmentDeletionCoordinatorError.tombstoneUnavailable
  }

  private static func fileType(of status: stat) -> mode_t {
    status.st_mode & mode_t(S_IFMT)
  }
}

struct ComposerImageTemporaryDirectoryCleanupReport: Equatable, Sendable {
  let inspectedEntryCount: Int
  let expiredCandidateCount: Int
  let removedDirectoryCount: Int
}

struct ComposerImageTemporaryDirectoryCleaner: Sendable {
  static let directoryPrefix = "tieba-composer-image-"
  static let selectedImageFilename = "selected-image"
  static let expirationInterval: TimeInterval = 24 * 60 * 60
  static let maximumEntryInspectionCount = 256
  static let maximumRemovalCount = 32

  let rootURL: URL

  init(rootURL: URL = FileManager.default.temporaryDirectory) {
    self.rootURL = rootURL.standardizedFileURL
  }

  func cleanup(now: Date = Date()) -> ComposerImageTemporaryDirectoryCleanupReport {
    guard rootURL.isFileURL else {
      return .init(inspectedEntryCount: 0, expiredCandidateCount: 0, removedDirectoryCount: 0)
    }
    let rootDescriptor = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootDescriptor >= 0 else {
      return .init(inspectedEntryCount: 0, expiredCandidateCount: 0, removedDirectoryCount: 0)
    }
    defer { _ = Darwin.close(rootDescriptor) }

    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
        errorHandler: { _, _ in false }
      )
    else {
      return .init(inspectedEntryCount: 0, expiredCandidateCount: 0, removedDirectoryCount: 0)
    }

    var inspectedCount = 0
    var candidateCount = 0
    var removedCount = 0
    while inspectedCount < Self.maximumEntryInspectionCount,
      removedCount < Self.maximumRemovalCount,
      let child = enumerator.nextObject() as? URL
    {
      inspectedCount += 1
      let filename = child.lastPathComponent
      guard Self.isTemporaryDirectoryFilename(filename) else { continue }
      let directoryDescriptor = filename.withCString { name in
        Darwin.openat(
          rootDescriptor,
          name,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
      }
      guard directoryDescriptor >= 0 else { continue }
      var status = stat()
      let statusResult = Darwin.fstat(directoryDescriptor, &status)
      guard statusResult == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
        _ = Darwin.close(directoryDescriptor)
        continue
      }
      let modifiedAt = Date(
        timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
      )
      guard modifiedAt < now.addingTimeInterval(-Self.expirationInterval) else {
        _ = Darwin.close(directoryDescriptor)
        continue
      }
      candidateCount += 1
      let removed = Self.removeBoundedTemporaryDirectory(
        named: filename,
        from: rootDescriptor,
        directoryDescriptor: directoryDescriptor
      )
      _ = Darwin.close(directoryDescriptor)
      if removed { removedCount += 1 }
    }
    return ComposerImageTemporaryDirectoryCleanupReport(
      inspectedEntryCount: inspectedCount,
      expiredCandidateCount: candidateCount,
      removedDirectoryCount: removedCount
    )
  }

  private static func isTemporaryDirectoryFilename(_ value: String) -> Bool {
    guard value.hasPrefix(directoryPrefix) else { return false }
    let suffix = String(value.dropFirst(directoryPrefix.count))
    guard let id = UUID(uuidString: suffix) else { return false }
    return suffix == id.uuidString.lowercased()
  }

  private static func removeBoundedTemporaryDirectory(
    named directoryName: String,
    from rootDescriptor: Int32,
    directoryDescriptor: Int32
  ) -> Bool {
    var childStatus = stat()
    let childStatusResult = selectedImageFilename.withCString { filename in
      Darwin.fstatat(directoryDescriptor, filename, &childStatus, AT_SYMLINK_NOFOLLOW)
    }
    if childStatusResult == 0 {
      let kind = childStatus.st_mode & mode_t(S_IFMT)
      guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { return false }
      let unlinkResult = selectedImageFilename.withCString { filename in
        Darwin.unlinkat(directoryDescriptor, filename, 0)
      }
      guard unlinkResult == 0 || errno == ENOENT else { return false }
    } else if errno != ENOENT {
      return false
    }
    let removeResult = directoryName.withCString { name in
      Darwin.unlinkat(rootDescriptor, name, AT_REMOVEDIR)
    }
    return removeResult == 0 || errno == ENOENT
  }
}
