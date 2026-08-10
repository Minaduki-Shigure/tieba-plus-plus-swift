import CryptoKit
import Foundation

struct RemoteImageDiskCacheUsage: Equatable, Sendable {
  let entryCount: Int
  let byteCount: Int64
}

struct RemoteImageDiskCacheClearResult: Equatable, Sendable {
  let removedEntryCount: Int
  let removedByteCount: Int64
  let removedAllEntries: Bool
}

struct RemoteImageDiskCacheGenerationToken: Equatable, Sendable {
  fileprivate let cacheIdentifier: UUID
  fileprivate let generation: UInt64
  fileprivate let requestSequence: UInt64
}

struct RemoteImageDiskCacheLimits: Equatable, Sendable {
  static let standard = RemoteImageDiskCacheLimits(
    maximumByteCount: 256 * 1_024 * 1_024,
    maximumEntryCount: 1_024,
    entryLifetime: 7 * 24 * 60 * 60
  )

  let maximumByteCount: Int64
  let maximumEntryCount: Int
  let entryLifetime: TimeInterval

  init(
    maximumByteCount: Int64,
    maximumEntryCount: Int,
    entryLifetime: TimeInterval
  ) {
    self.maximumByteCount = min(max(0, maximumByteCount), 256 * 1_024 * 1_024)
    self.maximumEntryCount = min(max(0, maximumEntryCount), 1_024)
    self.entryLifetime = entryLifetime.isFinite ? max(0, entryLifetime) : 0
  }
}

struct RemoteImageDiskCacheTimestamps: Equatable, Sendable {
  let storedAt: Date
  let lastAccess: Date
}

enum RemoteImageDiskCacheTimestampPolicy {
  static func normalizedDate(_ value: Date) -> Date? {
    let seconds = value.timeIntervalSince1970
    guard seconds.isFinite else { return nil }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite else { return nil }
    return Date(
      timeIntervalSince1970: milliseconds.rounded(.down) / 1_000
    )
  }

  static func timestamps(
    storedAt: Date,
    lastAccess: Date,
    currentDate: Date,
    entryLifetime: TimeInterval
  ) -> RemoteImageDiskCacheTimestamps? {
    guard
      entryLifetime.isFinite,
      entryLifetime > 0,
      let normalizedCurrentDate = normalizedDate(currentDate),
      let normalizedStoredAt = normalizedDate(storedAt),
      let normalizedLastAccess = normalizedDate(lastAccess)
    else { return nil }

    let clampedLastAccess = min(normalizedLastAccess, normalizedCurrentDate)
    let clampedStoredAt = min(normalizedStoredAt, clampedLastAccess)
    guard
      normalizedCurrentDate.timeIntervalSince(clampedStoredAt) < entryLifetime
    else { return nil }
    return RemoteImageDiskCacheTimestamps(
      storedAt: clampedStoredAt,
      lastAccess: clampedLastAccess
    )
  }
}

enum RemoteImageDiskCacheError: Error, Equatable {
  case invalidURL
  case invalidFile
  case responseTooLarge
  case staleGeneration
  case cannotPersist
}

protocol RemoteImagePersistentCacheProviding: Sendable {
  func cachedDownload(
    from url: URL,
    kind: RemoteImageDownloadKind
  ) async throws -> RemoteImageFileLease?

  func currentGenerationToken() async -> RemoteImageDiskCacheGenerationToken

  func storeValidated(
    _ lease: RemoteImageFileLease,
    requestedURL: URL,
    kind: RemoteImageDownloadKind,
    generationToken: RemoteImageDiskCacheGenerationToken
  ) async throws

  func usage() async -> RemoteImageDiskCacheUsage
  func clear() async -> RemoteImageDiskCacheClearResult
}

actor RemoteImageDiskCache: RemoteImagePersistentCacheProviding {
  static let shared = RemoteImageDiskCache()

  private static let formatVersion = 1
  private static let maximumMetadataByteCount: Int64 = 64 * 1_024
  private static let requestSequenceWindowSize: UInt64 = 2_048
  private static let absoluteMaximumPayloadByteCount =
    RemoteImageDownloadPolicy.originalMaximumResponseBytes

  private let directoryURL: URL
  private let leaseDirectoryURL: URL
  private let limits: RemoteImageDiskCacheLimits
  private let now: @Sendable () -> Date
  private let beforeStorePublication: (@Sendable () async -> Void)?
  private let cacheIdentifier = UUID()

  private var generation: UInt64 = 0
  private var nextRequestSequence: UInt64 = 0
  private var latestPublishedSequenceByKey = [String: UInt64]()
  private var consumedRequestSequences = Set<UInt64>()
  private var activeStagingDirectoryNames = Set<String>()
  private var isDisabledAfterClearFailure = false

  init(
    directoryURL: URL = RemoteImageDiskCache.defaultDirectoryURL,
    leaseDirectoryURL: URL = RemoteImageDiskCache.defaultLeaseDirectoryURL,
    limits: RemoteImageDiskCacheLimits = .standard,
    now: @escaping @Sendable () -> Date = { Date() },
    beforeStorePublication: (@Sendable () async -> Void)? = nil
  ) {
    self.directoryURL = directoryURL.standardizedFileURL
    self.leaseDirectoryURL = leaseDirectoryURL.standardizedFileURL
    self.limits = limits
    self.now = now
    self.beforeStorePublication = beforeStorePublication
  }

  func currentGenerationToken() async -> RemoteImageDiskCacheGenerationToken {
    if nextRequestSequence == UInt64.max {
      generation &+= 1
      nextRequestSequence = 0
      latestPublishedSequenceByKey.removeAll()
      consumedRequestSequences.removeAll()
    }
    let token = RemoteImageDiskCacheGenerationToken(
      cacheIdentifier: cacheIdentifier,
      generation: generation,
      requestSequence: nextRequestSequence
    )
    nextRequestSequence &+= 1
    pruneRequestSequenceWindow()
    return token
  }

  func cachedDownload(
    from url: URL,
    kind: RemoteImageDownloadKind
  ) async throws -> RemoteImageFileLease? {
    try Task.checkCancellation()
    guard Self.allowsCacheURL(url), ensureCacheDirectory() else { return nil }
    guard let currentDate = validCurrentDate() else { return nil }

    let key = Self.cacheKey(for: url)
    let entryDirectoryURL = directoryURL.appendingPathComponent(key, isDirectory: true)
    guard var record = validatedRecord(
      at: entryDirectoryURL,
      key: key,
      now: currentDate,
      maximumByteCount: maximumByteCount(for: kind)
    ) else {
      removeEntryFailClosed(at: entryDirectoryURL)
      return nil
    }
    try Task.checkCancellation()

    record.metadata.lastAccess = currentDate
    guard writeMetadata(record.metadata, to: record.metadataURL) else {
      removeEntryFailClosed(at: entryDirectoryURL)
      return nil
    }

    do {
      return try makeLease(
        payloadURL: record.payloadURL,
        requestedURL: url,
        byteCount: record.metadata.byteCount,
        payloadSHA256: record.metadata.payloadSHA256
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      removeEntryIfIdentifierMatches(record.metadata.entryIdentifier, at: entryDirectoryURL)
      return nil
    }
  }

  func storeValidated(
    _ lease: RemoteImageFileLease,
    requestedURL: URL,
    kind: RemoteImageDownloadKind,
    generationToken: RemoteImageDiskCacheGenerationToken
  ) async throws {
    try Task.checkCancellation()
    guard
      Self.allowsCacheURL(requestedURL),
      Self.allowsCacheURL(lease.sourceURL)
    else { throw RemoteImageDiskCacheError.invalidURL }
    guard tokenCanPublish(generationToken) else {
      throw RemoteImageDiskCacheError.staleGeneration
    }
    guard ensureCacheDirectory(), let currentDate = validCurrentDate() else {
      throw RemoteImageDiskCacheError.cannotPersist
    }

    let allowedByteCount = maximumByteCount(for: kind)
    guard lease.byteCount > 0 else { throw RemoteImageDiskCacheError.invalidFile }
    guard lease.byteCount <= allowedByteCount else {
      throw RemoteImageDiskCacheError.responseTooLarge
    }
    guard measuredRegularFileSize(at: lease.fileURL) == lease.byteCount else {
      throw RemoteImageDiskCacheError.invalidFile
    }

    let key = Self.cacheKey(for: requestedURL)
    let entryIdentifier = UUID()
    let metadata = EntryMetadata(
      version: Self.formatVersion,
      entryIdentifier: entryIdentifier,
      byteCount: lease.byteCount,
      payloadSHA256: "",
      storedAt: currentDate,
      lastAccess: currentDate
    )
    let stagingDirectoryName = ".staging-\(UUID().uuidString)"
    let stagingDirectoryURL = directoryURL.appendingPathComponent(
      stagingDirectoryName,
      isDirectory: true
    )
    activeStagingDirectoryNames.insert(stagingDirectoryName)

    let preparation = Task.detached(priority: .utility) {
      try Self.prepareStagingEntry(
        sourceURL: lease.fileURL,
        expectedByteCount: lease.byteCount,
        metadata: metadata,
        stagingDirectoryURL: stagingDirectoryURL
      )
    }

    do {
      try await withTaskCancellationHandler {
        try await preparation.value
      } onCancel: {
        preparation.cancel()
      }
      if let beforeStorePublication {
        await beforeStorePublication()
      }
      try Task.checkCancellation()
      guard tokenCanPublish(generationToken) else {
        throw RemoteImageDiskCacheError.staleGeneration
      }
      guard
        latestPublishedSequenceByKey[key]
          .map({ $0 <= generationToken.requestSequence }) ?? true
      else { throw RemoteImageDiskCacheError.staleGeneration }
      guard
        measuredRegularFileSize(
          at: stagingDirectoryURL.appendingPathComponent("payload", isDirectory: false)
        ) == lease.byteCount
      else { throw RemoteImageDiskCacheError.invalidFile }

      let destinationURL = directoryURL.appendingPathComponent(key, isDirectory: true)
      try publishStagingEntry(
        at: stagingDirectoryURL,
        replacing: destinationURL
      )
      latestPublishedSequenceByKey[key] = generationToken.requestSequence
      consumedRequestSequences.insert(generationToken.requestSequence)
      activeStagingDirectoryNames.remove(stagingDirectoryName)

      if Task.isCancelled || !tokenIsCurrent(generationToken) {
        removeEntryIfIdentifierMatches(entryIdentifier, at: destinationURL)
        if latestPublishedSequenceByKey[key] == generationToken.requestSequence {
          latestPublishedSequenceByKey.removeValue(forKey: key)
        }
        if Task.isCancelled {
          throw CancellationError()
        }
        throw RemoteImageDiskCacheError.staleGeneration
      }

      let trimDate = validCurrentDate() ?? currentDate
      _ = trimIfNeeded(now: trimDate)
    } catch {
      preparation.cancel()
      activeStagingDirectoryNames.remove(stagingDirectoryName)
      try? FileManager.default.removeItem(at: stagingDirectoryURL)
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      if let cacheError = error as? RemoteImageDiskCacheError {
        throw cacheError
      }
      throw RemoteImageDiskCacheError.cannotPersist
    }
  }

  func usage() async -> RemoteImageDiskCacheUsage {
    guard ensureCacheDirectory(), let currentDate = validCurrentDate() else {
      return RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0)
    }
    let records = trimIfNeeded(now: currentDate)
    guard !isDisabledAfterClearFailure else {
      return RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0)
    }
    return RemoteImageDiskCacheUsage(
      entryCount: records.count,
      byteCount: Self.totalByteCount(of: records)
    )
  }

  func clear() async -> RemoteImageDiskCacheClearResult {
    generation &+= 1
    latestPublishedSequenceByKey.removeAll()
    consumedRequestSequences.removeAll()
    let measured = rawUsageForClear()
    let fileManager = FileManager.default
    var removedAllEntries = true

    if directoryURL.isFileURL, fileManager.fileExists(atPath: directoryURL.path) {
      do {
        try fileManager.removeItem(at: directoryURL)
      } catch {
        removedAllEntries = false
      }
    }

    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      guard isUnlinkedDirectory(at: directoryURL) else {
        removedAllEntries = false
        isDisabledAfterClearFailure = true
        return RemoteImageDiskCacheClearResult(
          removedEntryCount: measured.entryCount,
          removedByteCount: measured.byteCount,
          removedAllEntries: false
        )
      }
    } catch {
      removedAllEntries = false
    }

    isDisabledAfterClearFailure = !removedAllEntries
    return RemoteImageDiskCacheClearResult(
      removedEntryCount: measured.entryCount,
      removedByteCount: measured.byteCount,
      removedAllEntries: removedAllEntries
    )
  }

  static var defaultDirectoryURL: URL {
    let baseURL = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return baseURL.appendingPathComponent(
      "TiebaPlusPlusRemoteImages-v1",
      isDirectory: true
    )
  }

  static var defaultLeaseDirectoryURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "TiebaPlusPlusRemoteImageLeases-v1",
      isDirectory: true
    )
  }

  static func cacheKey(for url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func allowsCacheURL(_ url: URL) -> Bool {
    guard RemoteImageURLPolicy.allows(url), url.fragment == nil else { return false }
    return url.absoluteString.utf8.count <= 8_192
  }

  private func maximumByteCount(for kind: RemoteImageDownloadKind) -> Int64 {
    min(
      Self.absoluteMaximumPayloadByteCount,
      RemoteImageDownloadLimits.standard.maximumResponseBytes(for: kind)
    )
  }

  private func tokenIsCurrent(_ token: RemoteImageDiskCacheGenerationToken) -> Bool {
    token.cacheIdentifier == cacheIdentifier && token.generation == generation
  }

  private func tokenCanPublish(_ token: RemoteImageDiskCacheGenerationToken) -> Bool {
    tokenIsCurrent(token)
      && token.requestSequence >= oldestAcceptedRequestSequence
      && token.requestSequence < nextRequestSequence
      && !consumedRequestSequences.contains(token.requestSequence)
  }

  private var oldestAcceptedRequestSequence: UInt64 {
    nextRequestSequence > Self.requestSequenceWindowSize
      ? nextRequestSequence - Self.requestSequenceWindowSize
      : 0
  }

  private func pruneRequestSequenceWindow() {
    let floor = oldestAcceptedRequestSequence
    latestPublishedSequenceByKey = latestPublishedSequenceByKey.filter {
      $0.value >= floor
    }
    consumedRequestSequences = Set(consumedRequestSequences.filter { $0 >= floor })
  }

  private func validCurrentDate() -> Date? {
    RemoteImageDiskCacheTimestampPolicy.normalizedDate(now())
  }

  private func ensureCacheDirectory() -> Bool {
    guard directoryURL.isFileURL, !isDisabledAfterClearFailure else { return false }
    let fileManager = FileManager.default
    do {
      if !fileManager.fileExists(atPath: directoryURL.path) {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      }
      guard isUnlinkedDirectory(at: directoryURL) else { return false }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableDirectoryURL = directoryURL
      try mutableDirectoryURL.setResourceValues(values)
#if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directoryURL.path
      )
#endif
      return true
    } catch {
      return false
    }
  }

  private func ensureLeaseDirectory() -> Bool {
    guard leaseDirectoryURL.isFileURL else { return false }
    let fileManager = FileManager.default
    do {
      if !fileManager.fileExists(atPath: leaseDirectoryURL.path) {
        try fileManager.createDirectory(
          at: leaseDirectoryURL,
          withIntermediateDirectories: true
        )
      }
      guard isUnlinkedDirectory(at: leaseDirectoryURL) else { return false }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableLeaseDirectoryURL = leaseDirectoryURL
      try mutableLeaseDirectoryURL.setResourceValues(values)
      return true
    } catch {
      return false
    }
  }

  private func isUnlinkedDirectory(at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ]) else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private func measuredRegularFileSize(at url: URL) -> Int64? {
    guard url.isFileURL else { return nil }
    guard let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
    ]) else { return nil }
    guard
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let fileSize = values.fileSize,
      fileSize >= 0
    else { return nil }
    return Int64(fileSize)
  }

  private func validatedRecord(
    at entryDirectoryURL: URL,
    key: String,
    now currentDate: Date,
    maximumByteCount: Int64 = RemoteImageDiskCache.absoluteMaximumPayloadByteCount,
    verifiesDigest: Bool = true
  ) -> EntryRecord? {
    guard Self.isCacheKey(key), isUnlinkedDirectory(at: entryDirectoryURL) else {
      return nil
    }
    let metadataURL = entryDirectoryURL.appendingPathComponent(
      "metadata.json",
      isDirectory: false
    )
    let payloadURL = entryDirectoryURL.appendingPathComponent("payload", isDirectory: false)
    guard
      let metadataSize = measuredRegularFileSize(at: metadataURL),
      metadataSize > 0,
      metadataSize <= Self.maximumMetadataByteCount,
      let metadataData = Self.boundedRegularFileData(
        at: metadataURL,
        expectedByteCount: metadataSize,
        maximumByteCount: Self.maximumMetadataByteCount
      ),
      Int64(metadataData.count) == metadataSize,
      var metadata = Self.decodeMetadata(metadataData),
      metadata.version == Self.formatVersion,
      metadata.byteCount > 0,
      metadata.byteCount <= maximumByteCount,
      metadata.byteCount <= Self.absoluteMaximumPayloadByteCount,
      Self.isCacheKey(metadata.payloadSHA256),
      let timestamps = RemoteImageDiskCacheTimestampPolicy.timestamps(
        storedAt: metadata.storedAt,
        lastAccess: metadata.lastAccess,
        currentDate: currentDate,
        entryLifetime: limits.entryLifetime
      )
    else { return nil }

    metadata.lastAccess = timestamps.lastAccess
    metadata.storedAt = timestamps.storedAt

    guard
      measuredRegularFileSize(at: payloadURL) == metadata.byteCount,
      !verifiesDigest
        || Self.fileSHA256(
          at: payloadURL,
          expectedByteCount: metadata.byteCount
        ) == metadata.payloadSHA256
    else { return nil }

    return EntryRecord(
      key: key,
      directoryURL: entryDirectoryURL,
      metadataURL: metadataURL,
      payloadURL: payloadURL,
      metadata: metadata
    )
  }

  private func writeMetadata(_ metadata: EntryMetadata, to url: URL) -> Bool {
    guard let data = Self.encodeMetadata(metadata) else { return false }
    do {
      try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
      return measuredRegularFileSize(at: url) == Int64(data.count)
    } catch {
      return false
    }
  }

  private func trimIfNeeded(now currentDate: Date) -> [EntryRecord] {
    guard ensureCacheDirectory() else { return [] }
    let fileManager = FileManager.default
    guard let children = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants],
      errorHandler: { _, _ in true }
    ) else { return [] }

    var records = [EntryRecord]()
    var totalBytes: Int64 = 0
    for case let child as URL in children {
      let name = child.lastPathComponent
      if activeStagingDirectoryNames.contains(name) {
        continue
      }
      guard Self.isCacheKey(name) else {
        try? fileManager.removeItem(at: child)
        continue
      }
      guard let record = validatedRecord(
        at: child,
        key: name,
        now: currentDate,
        verifiesDigest: false
      ) else {
        removeEntryFailClosed(at: child)
        continue
      }
      records.append(record)
      let addition = totalBytes.addingReportingOverflow(record.metadata.byteCount)
      totalBytes = addition.overflow ? Int64.max : addition.partialValue
      records.sort {
        if $0.metadata.lastAccess != $1.metadata.lastAccess {
          return $0.metadata.lastAccess < $1.metadata.lastAccess
        }
        if $0.metadata.storedAt != $1.metadata.storedAt {
          return $0.metadata.storedAt < $1.metadata.storedAt
        }
        return $0.key < $1.key
      }
      while
        records.count > limits.maximumEntryCount
          || totalBytes > limits.maximumByteCount,
        let oldest = records.first
      {
        records.removeFirst()
        removeEntryFailClosed(at: oldest.directoryURL)
        totalBytes = max(0, totalBytes - oldest.metadata.byteCount)
      }
    }
    return records
  }

  private func makeLease(
    payloadURL: URL,
    requestedURL: URL,
    byteCount: Int64,
    payloadSHA256: String
  ) throws -> RemoteImageFileLease {
    try Task.checkCancellation()
    guard ensureLeaseDirectory() else {
      throw RemoteImageDiskCacheError.cannotPersist
    }
    let leaseDirectoryURL = leaseDirectoryURL.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let leaseFileURL = leaseDirectoryURL.appendingPathComponent("download", isDirectory: false)
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: leaseDirectoryURL,
        withIntermediateDirectories: false
      )
      try fileManager.copyItem(at: payloadURL, to: leaseFileURL)
      guard
        measuredRegularFileSize(at: leaseFileURL) == byteCount,
        Self.fileSHA256(at: leaseFileURL, expectedByteCount: byteCount) == payloadSHA256
      else {
        throw RemoteImageDiskCacheError.invalidFile
      }
#if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: leaseFileURL.path
      )
#endif
      try Task.checkCancellation()
    } catch {
      try? fileManager.removeItem(at: leaseDirectoryURL)
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      if let cacheError = error as? RemoteImageDiskCacheError {
        throw cacheError
      }
      throw RemoteImageDiskCacheError.cannotPersist
    }

    return RemoteImageFileLease(
      fileURL: leaseFileURL,
      cleanupDirectoryURL: leaseDirectoryURL,
      sourceURL: requestedURL,
      mimeType: nil,
      suggestedFilename: nil,
      byteCount: byteCount
    )
  }

  private func publishStagingEntry(at stagingURL: URL, replacing destinationURL: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      let backupName = ".backup-\(UUID().uuidString)"
      let backupURL = directoryURL.appendingPathComponent(backupName, isDirectory: true)
      defer { try? fileManager.removeItem(at: backupURL) }
      do {
        _ = try fileManager.replaceItemAt(
          destinationURL,
          withItemAt: stagingURL,
          backupItemName: backupName,
          options: []
        )
      } catch {
        throw RemoteImageDiskCacheError.cannotPersist
      }
    } else {
      do {
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
      } catch {
        throw RemoteImageDiskCacheError.cannotPersist
      }
    }
  }

  private func removeEntryIfIdentifierMatches(_ identifier: UUID, at directoryURL: URL) {
    let metadataURL = directoryURL.appendingPathComponent("metadata.json", isDirectory: false)
    guard
      let metadataSize = measuredRegularFileSize(at: metadataURL),
      metadataSize > 0,
      metadataSize <= Self.maximumMetadataByteCount,
      let data = Self.boundedRegularFileData(
        at: metadataURL,
        expectedByteCount: metadataSize,
        maximumByteCount: Self.maximumMetadataByteCount
      ),
      Self.decodeMetadata(data)?.entryIdentifier == identifier
    else { return }
    removeEntryFailClosed(at: directoryURL)
  }

  private func removeEntryFailClosed(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func rawUsageForClear() -> RemoteImageDiskCacheUsage {
    guard directoryURL.isFileURL else {
      return RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0)
    }
    guard let children = FileManager.default.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants],
      errorHandler: { _, _ in true }
    ) else {
      return RemoteImageDiskCacheUsage(entryCount: 0, byteCount: 0)
    }

    var count = 0
    var bytes: Int64 = 0
    for case let child as URL in children where Self.isCacheKey(child.lastPathComponent) {
      count += 1
      let payloadURL = child.appendingPathComponent("payload", isDirectory: false)
      if let size = measuredRegularFileSize(at: payloadURL) {
        let addition = bytes.addingReportingOverflow(size)
        bytes = addition.overflow ? Int64.max : addition.partialValue
      }
    }
    return RemoteImageDiskCacheUsage(entryCount: count, byteCount: bytes)
  }

  private static func prepareStagingEntry(
    sourceURL: URL,
    expectedByteCount: Int64,
    metadata: EntryMetadata,
    stagingDirectoryURL: URL
  ) throws {
    try Task.checkCancellation()
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: stagingDirectoryURL,
        withIntermediateDirectories: false
      )
      let payloadURL = stagingDirectoryURL.appendingPathComponent("payload", isDirectory: false)
      try fileManager.copyItem(at: sourceURL, to: payloadURL)
#if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: payloadURL.path
      )
#endif
      try Task.checkCancellation()

      guard let values = try? payloadURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
      ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        values.fileSize.map { Int64($0) } == expectedByteCount
      else { throw RemoteImageDiskCacheError.invalidFile }

      guard let payloadSHA256 = fileSHA256(
        at: payloadURL,
        expectedByteCount: expectedByteCount
      ) else {
        throw RemoteImageDiskCacheError.invalidFile
      }
      try Task.checkCancellation()
      var finalizedMetadata = metadata
      finalizedMetadata.payloadSHA256 = payloadSHA256
      guard let metadataData = encodeMetadata(finalizedMetadata) else {
        throw RemoteImageDiskCacheError.cannotPersist
      }
      try metadataData.write(
        to: stagingDirectoryURL.appendingPathComponent("metadata.json", isDirectory: false),
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      try Task.checkCancellation()
    } catch {
      try? fileManager.removeItem(at: stagingDirectoryURL)
      throw error
    }
  }

  private static func encodeMetadata(_ metadata: EntryMetadata) -> Data? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try? encoder.encode(metadata)
  }

  private static func decodeMetadata(_ data: Data) -> EntryMetadata? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(EntryMetadata.self, from: data)
  }

  private static func isCacheKey(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
    }
  }

  private static func fileSHA256(
    at url: URL,
    expectedByteCount: Int64
  ) -> String? {
    guard
      url.isFileURL,
      expectedByteCount >= 0,
      expectedByteCount <= absoluteMaximumPayloadByteCount,
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return nil
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    var remaining = expectedByteCount
    do {
      while remaining > 0 {
        let requestedCount = Int(min(remaining, 1_024 * 1_024))
        guard
          let chunk = try handle.read(upToCount: requestedCount),
          !chunk.isEmpty
        else { return nil }
        hasher.update(data: chunk)
        remaining -= Int64(chunk.count)
      }
      if let trailingByte = try handle.read(upToCount: 1), !trailingByte.isEmpty {
        return nil
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func boundedRegularFileData(
    at url: URL,
    expectedByteCount: Int64,
    maximumByteCount: Int64
  ) -> Data? {
    guard
      url.isFileURL,
      expectedByteCount > 0,
      expectedByteCount <= maximumByteCount,
      expectedByteCount <= Int64(Int.max),
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    var data = Data()
    var remaining = expectedByteCount
    do {
      while remaining > 0 {
        let requestedCount = Int(min(remaining, 64 * 1_024))
        guard
          let chunk = try handle.read(upToCount: requestedCount),
          !chunk.isEmpty
        else { return nil }
        data.append(chunk)
        remaining -= Int64(chunk.count)
      }
      if let trailingByte = try handle.read(upToCount: 1), !trailingByte.isEmpty {
        return nil
      }
      return data
    } catch {
      return nil
    }
  }

  private static func totalByteCount(of records: [EntryRecord]) -> Int64 {
    records.reduce(into: Int64(0)) { total, record in
      let addition = total.addingReportingOverflow(record.metadata.byteCount)
      total = addition.overflow ? Int64.max : addition.partialValue
    }
  }
}

struct PersistentRemoteImageDownloader: RemoteImageDownloading,
  RemoteImagePersistentCacheProviding, Sendable
{
  static let shared = PersistentRemoteImageDownloader()

  private let cache: any RemoteImagePersistentCacheProviding
  private let networkDownloader: any RemoteImageDownloading

  init(
    cache: any RemoteImagePersistentCacheProviding = RemoteImageDiskCache.shared,
    networkDownloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared
  ) {
    self.cache = cache
    self.networkDownloader = networkDownloader
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    try await download(
      from: url,
      kind: kind,
      networkAccess: networkAccess,
      onProgress: { _ in }
    )
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) async throws -> RemoteImageFileLease {
    do {
      if let cached = try await cache.cachedDownload(from: url, kind: kind) {
        onProgress(
          RemoteImageDownloadProgress(
            receivedByteCount: cached.byteCount,
            expectedByteCount: cached.byteCount
          )
        )
        return cached
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A cache failure is a miss. Network validation remains authoritative.
    }

    try Task.checkCancellation()
    return try await networkDownloader.download(
      from: url,
      kind: kind,
      networkAccess: networkAccess,
      onProgress: onProgress
    )
  }

  func cachedDownload(
    from url: URL,
    kind: RemoteImageDownloadKind
  ) async throws -> RemoteImageFileLease? {
    try await cache.cachedDownload(from: url, kind: kind)
  }

  func currentGenerationToken() async -> RemoteImageDiskCacheGenerationToken {
    await cache.currentGenerationToken()
  }

  func storeValidated(
    _ lease: RemoteImageFileLease,
    requestedURL: URL,
    kind: RemoteImageDownloadKind,
    generationToken: RemoteImageDiskCacheGenerationToken
  ) async throws {
    try await cache.storeValidated(
      lease,
      requestedURL: requestedURL,
      kind: kind,
      generationToken: generationToken
    )
  }

  func usage() async -> RemoteImageDiskCacheUsage {
    await cache.usage()
  }

  func clear() async -> RemoteImageDiskCacheClearResult {
    await cache.clear()
  }
}

private struct EntryMetadata: Codable, Sendable {
  let version: Int
  let entryIdentifier: UUID
  let byteCount: Int64
  var payloadSHA256: String
  var storedAt: Date
  var lastAccess: Date
}

private struct EntryRecord: Sendable {
  let key: String
  let directoryURL: URL
  let metadataURL: URL
  let payloadURL: URL
  var metadata: EntryMetadata
}
