import CryptoKit
import Darwin
import Foundation

enum ComposerImageAttachmentStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidAttachment
  case unsafeStorageDirectory
  case attachmentAlreadyExists
  case storageUnavailable
  case storedFileMissing
  case storedFileTampered

  var errorDescription: String? {
    switch self {
    case .invalidAttachment:
      "图片附件记录无效。"
    case .unsafeStorageDirectory:
      "图片附件存储目录不安全。"
    case .attachmentAlreadyExists:
      "图片附件标识已存在，未覆盖原文件。"
    case .storageUnavailable:
      "无法安全保存图片附件。"
    case .storedFileMissing:
      "图片附件文件已丢失。"
    case .storedFileTampered:
      "图片附件文件未通过完整性检查。"
    }
  }
}

actor ComposerImageAttachmentStore {
  private let directoryURL: URL
  private let trustedRootURL: URL
  private let relativeDirectoryComponents: [String]
  private let isBoundToTrustedRoot: Bool
  private let processor: ComposerImageAttachmentProcessor
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforePublication: (@Sendable () async -> Void)?
  private let processingDidStart: @Sendable () -> Void
  private let processingDidFinish: @Sendable () -> Void
  private let processingLimiter = ComposerImageProcessingLimiter()
  private var activeAttachmentIDs = Set<UUID>()
  private var activeStagedFilenames = Set<String>()

  init(
    directoryURL: URL,
    trustedRootURL: URL,
    processor: ComposerImageAttachmentProcessor = .init(),
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforePublication: (@Sendable () async -> Void)? = nil,
    processingDidStart: @escaping @Sendable () -> Void = {},
    processingDidFinish: @escaping @Sendable () -> Void = {}
  ) {
    let candidate = directoryURL.standardizedFileURL
    let lexicalRoot = trustedRootURL.standardizedFileURL
    let components = Self.relativePathComponents(from: lexicalRoot, to: candidate)
    let canonicalRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
    self.trustedRootURL = canonicalRoot
    self.relativeDirectoryComponents = components ?? []
    self.isBoundToTrustedRoot = components != nil
    self.directoryURL =
      (components ?? []).reduce(canonicalRoot) { partialURL, component in
        partialURL.appendingPathComponent(component, isDirectory: true)
      }.standardizedFileURL
    self.processor = processor
    self.prepareStagedFile = prepareStagedFile ?? { _ in }
    self.beforePublication = beforePublication
    self.processingDidStart = processingDidStart
    self.processingDidFinish = processingDidFinish
  }

  static func live(fileManager: FileManager = .default) -> ComposerImageAttachmentStore {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      let unavailableRoot = URL(fileURLWithPath: "/dev/null", isDirectory: true)
      return ComposerImageAttachmentStore(
        directoryURL: unavailableRoot.appendingPathComponent("unavailable"),
        trustedRootURL: unavailableRoot
      )
    }
    return ComposerImageAttachmentStore(
      directoryURL:
        applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("composer-image-attachments-v1", isDirectory: true),
      trustedRootURL: applicationSupport
    )
  }

  func importImage(
    at temporaryFileURL: URL,
    quality: ComposerImageAttachmentQuality,
    id: UUID = UUID()
  ) async throws -> ComposerImageAttachment {
    try reserve(id)
    defer { activeAttachmentIDs.remove(id) }
    try await processingLimiter.acquire()
    do {
      try Task.checkCancellation()
      let processed = try await runProcessingOperation { [processor] in
        try processor.process(temporaryFileURL: temporaryFileURL, quality: quality)
      }
      let attachment = try await persist(processed, id: id)
      await processingLimiter.release()
      return attachment
    } catch {
      await processingLimiter.release()
      throw error
    }
  }

  func importImage(
    data: Data,
    quality: ComposerImageAttachmentQuality,
    id: UUID = UUID()
  ) async throws -> ComposerImageAttachment {
    try reserve(id)
    defer { activeAttachmentIDs.remove(id) }
    try await processingLimiter.acquire()
    do {
      try Task.checkCancellation()
      let processed = try await runProcessingOperation { [processor] in
        try processor.process(data: data, quality: quality)
      }
      let attachment = try await persist(processed, id: id)
      await processingLimiter.release()
      return attachment
    } catch {
      await processingLimiter.release()
      throw error
    }
  }

  func validatedData(for attachment: ComposerImageAttachment) async throws -> Data {
    try await processingLimiter.acquire()
    do {
      try Task.checkCancellation()
      let data = try validatedDataWithoutProcessingPermit(for: attachment)
      await processingLimiter.release()
      return data
    } catch {
      await processingLimiter.release()
      throw error
    }
  }

  #if DEBUG
    func processingWaiterCountForTesting() async -> Int {
      await processingLimiter.waiterCount()
    }
  #endif

  private func validatedDataWithoutProcessingPermit(
    for attachment: ComposerImageAttachment
  ) throws -> Data {
    guard Self.isValid(attachment) else {
      throw ComposerImageAttachmentStoreError.invalidAttachment
    }
    try ensureStorageDirectory()
    let fileURL = try resolvedFileURL(for: attachment)
    guard Self.itemExists(at: fileURL) else {
      throw ComposerImageAttachmentStoreError.storedFileMissing
    }
    let data: Data
    do {
      data = try ComposerSecureRegularFileReader.read(
        from: fileURL,
        expectedByteCount: attachment.byteCount,
        maximumByteCount: attachment.quality.maximumByteCount,
        checksCancellation: true
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageAttachmentStoreError.storedFileTampered
    }
    guard Self.sha256(of: data) == attachment.sha256 else {
      throw ComposerImageAttachmentStoreError.storedFileTampered
    }
    try Task.checkCancellation()
    do {
      try processor.validateStoredData(data, matching: attachment)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageAttachmentStoreError.storedFileTampered
    }
    try Task.checkCancellation()
    return data
  }

  func remove(_ attachment: ComposerImageAttachment) throws {
    guard Self.isValid(attachment) else {
      throw ComposerImageAttachmentStoreError.invalidAttachment
    }
    try ensureStorageDirectory()
    let fileURL = try resolvedFileURL(for: attachment)
    guard Self.itemExists(at: fileURL) else { return }
    if Self.isSymbolicLink(at: fileURL) {
      do {
        // Removing the link itself cannot delete its target outside this directory.
        try FileManager.default.removeItem(at: fileURL)
        return
      } catch {
        throw ComposerImageAttachmentStoreError.storageUnavailable
      }
    }
    guard
      let values = try? fileURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .isDirectoryKey,
      ])
    else {
      throw ComposerImageAttachmentStoreError.storageUnavailable
    }
    guard values.isDirectory != true else {
      throw ComposerImageAttachmentStoreError.storedFileTampered
    }
    guard values.isRegularFile == true else {
      throw ComposerImageAttachmentStoreError.storedFileTampered
    }
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      throw ComposerImageAttachmentStoreError.storageUnavailable
    }
  }

  private func reserve(_ id: UUID) throws {
    guard activeAttachmentIDs.insert(id).inserted else {
      throw ComposerImageAttachmentStoreError.attachmentAlreadyExists
    }
  }

  private func runProcessingOperation(
    _ operation: @escaping @Sendable () throws -> ComposerProcessedImage
  ) async throws -> ComposerProcessedImage {
    let processingDidStart = processingDidStart
    let processingDidFinish = processingDidFinish
    let task = Task.detached(priority: .userInitiated) {
      var didStart = false
      do {
        try Task.checkCancellation()
        processingDidStart()
        didStart = true
        let result = try operation()
        processingDidFinish()
        didStart = false
        return result
      } catch {
        if didStart {
          processingDidFinish()
        }
        throw error
      }
    }
    do {
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      task.cancel()
      throw error
    }
  }

  private func persist(
    _ processed: ComposerProcessedImage,
    id: UUID
  ) async throws -> ComposerImageAttachment {
    try Task.checkCancellation()
    try ensureStorageDirectory()
    let sha256 = Self.sha256(of: processed.data)
    guard
      let attachment = ComposerImageAttachment(
        id: id,
        sha256: sha256,
        byteCount: Int64(processed.data.count),
        pixelWidth: processed.pixelWidth,
        pixelHeight: processed.pixelHeight,
        encoding: processed.encoding,
        quality: processed.quality
      )
    else { throw ComposerImageAttachmentStoreError.invalidAttachment }

    let destinationURL = try resolvedFileURL(for: attachment)
    guard !Self.itemExists(at: destinationURL) else {
      throw ComposerImageAttachmentStoreError.attachmentAlreadyExists
    }
    let stagedURL = directoryURL.appendingPathComponent(
      ".staged-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    let stagedFilename = stagedURL.lastPathComponent
    activeStagedFilenames.insert(stagedFilename)
    defer { activeStagedFilenames.remove(stagedFilename) }
    var didPublish = false
    do {
      try processed.data.write(
        to: stagedURL,
        options: [.atomic, .completeFileProtection]
      )
      try Self.applyStorageAttributes(to: stagedURL)
      try prepareStagedFile(stagedURL)
      guard
        let stagedData = try? ComposerSecureRegularFileReader.read(
          from: stagedURL,
          expectedByteCount: attachment.byteCount,
          maximumByteCount: attachment.quality.maximumByteCount,
          checksCancellation: false
        ),
        Self.sha256(of: stagedData) == attachment.sha256
      else { throw ComposerImageAttachmentStoreError.storageUnavailable }
      try processor.validateStoredData(stagedData, matching: attachment)

      if let beforePublication {
        await beforePublication()
      }
      try Task.checkCancellation()
      guard !Self.itemExists(at: destinationURL) else {
        throw ComposerImageAttachmentStoreError.attachmentAlreadyExists
      }
      try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
      didPublish = true

      guard
        let publishedData = try? ComposerSecureRegularFileReader.read(
          from: destinationURL,
          expectedByteCount: attachment.byteCount,
          maximumByteCount: attachment.quality.maximumByteCount,
          checksCancellation: false
        ),
        Self.sha256(of: publishedData) == attachment.sha256
      else { throw ComposerImageAttachmentStoreError.storageUnavailable }
      try processor.validateStoredData(publishedData, matching: attachment)
      try Task.checkCancellation()
      return attachment
    } catch {
      try? FileManager.default.removeItem(at: stagedURL)
      if didPublish {
        try? FileManager.default.removeItem(at: destinationURL)
      }
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      if let processingError = error as? ComposerImageProcessingError {
        throw processingError
      }
      if let storeError = error as? ComposerImageAttachmentStoreError {
        throw storeError
      }
      throw ComposerImageAttachmentStoreError.storageUnavailable
    }
  }

  private func ensureStorageDirectory() throws {
    guard
      isBoundToTrustedRoot,
      directoryURL.isFileURL,
      trustedRootURL.isFileURL,
      !relativeDirectoryComponents.isEmpty
    else {
      throw ComposerImageAttachmentStoreError.unsafeStorageDirectory
    }
    let fileManager = FileManager.default
    do {
      if !Self.itemExists(at: trustedRootURL) {
        try fileManager.createDirectory(
          at: trustedRootURL,
          withIntermediateDirectories: true
        )
      }
      guard
        !Self.isSymbolicLink(at: trustedRootURL),
        let trustedRootValues = try? trustedRootURL.resourceValues(forKeys: [
          .isDirectoryKey,
          .isSymbolicLinkKey,
        ]),
        trustedRootValues.isDirectory == true,
        trustedRootValues.isSymbolicLink != true
      else { throw ComposerImageAttachmentStoreError.unsafeStorageDirectory }
      // The canonical app-private root and per-component lstat checks reject
      // redirected ancestors. A hostile process in the same app sandbox could
      // still race these checks; eliminating that residual TOCTOU needs a full
      // openat/renameat directory-descriptor storage implementation.
      try validateDirectoryChain()
      if !Self.itemExists(at: directoryURL) {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      }
      guard
        !Self.isSymbolicLink(at: directoryURL),
        let values = try? directoryURL.resourceValues(forKeys: [
          .isDirectoryKey,
          .isSymbolicLinkKey,
        ]),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        directoryURL.resolvingSymlinksInPath().standardizedFileURL == directoryURL
      else { throw ComposerImageAttachmentStoreError.unsafeStorageDirectory }
      try validateDirectoryChain()
      try Self.applyStorageAttributes(to: directoryURL)
      try cleanupOldStagedFiles(fileManager: fileManager)
    } catch let error as ComposerImageAttachmentStoreError {
      throw error
    } catch {
      throw ComposerImageAttachmentStoreError.storageUnavailable
    }
  }

  private func validateDirectoryChain() throws {
    var currentURL = trustedRootURL
    for component in relativeDirectoryComponents {
      currentURL.appendPathComponent(component, isDirectory: true)
      var status = stat()
      let result = currentURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.lstat(path, &status)
      }
      if result != 0, errno == ENOENT {
        return
      }
      guard
        result == 0,
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      else { throw ComposerImageAttachmentStoreError.unsafeStorageDirectory }
    }
  }

  private func cleanupOldStagedFiles(fileManager: FileManager) throws {
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let children = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    var removalCount = 0
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard removalCount < 32 else { break }
      let filename = child.lastPathComponent
      guard
        filename.hasPrefix(".staged-"),
        !activeStagedFilenames.contains(filename),
        let status = Self.symbolicLinkStatus(at: child),
        Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)) < cutoff
      else { continue }
      let kind = status.st_mode & mode_t(S_IFMT)
      guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { continue }
      try fileManager.removeItem(at: child)
      removalCount += 1
    }
  }

  private func resolvedFileURL(for attachment: ComposerImageAttachment) throws -> URL {
    guard
      Self.isValid(attachment),
      ComposerImageAttachment.isValidRelativePrivateFilename(
        attachment.relativePrivateFilename
      )
    else { throw ComposerImageAttachmentStoreError.invalidAttachment }
    let candidate = directoryURL.appendingPathComponent(
      attachment.relativePrivateFilename,
      isDirectory: false
    ).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directoryURL else {
      throw ComposerImageAttachmentStoreError.invalidAttachment
    }
    return candidate
  }

  private static func isValid(_ attachment: ComposerImageAttachment) -> Bool {
    guard
      let validated = ComposerImageAttachment(
        id: attachment.id,
        relativePrivateFilename: attachment.relativePrivateFilename,
        sha256: attachment.sha256,
        byteCount: attachment.byteCount,
        pixelWidth: attachment.pixelWidth,
        pixelHeight: attachment.pixelHeight,
        encoding: attachment.encoding,
        quality: attachment.quality
      )
    else { return false }
    return validated == attachment
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

  private static func relativePathComponents(from root: URL, to child: URL) -> [String]? {
    guard root.isFileURL, child.isFileURL else { return nil }
    let rootComponents = root.standardizedFileURL.pathComponents
    let childComponents = child.standardizedFileURL.pathComponents
    guard
      childComponents.count > rootComponents.count,
      Array(childComponents.prefix(rootComponents.count)) == rootComponents
    else { return nil }
    let relativeComponents = Array(childComponents.dropFirst(rootComponents.count))
    guard
      relativeComponents.allSatisfy({ component in
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
      })
    else { return nil }
    return relativeComponents
  }

  private static func itemExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(at: url)
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    guard let status = symbolicLinkStatus(at: url) else { return false }
    return (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
  }

  private static func symbolicLinkStatus(at url: URL) -> stat? {
    guard url.isFileURL else { return nil }
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    return result == 0 ? status : nil
  }

  private static func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private actor ComposerImageProcessingLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var permitIsAvailable = true
  private var waiters: [Waiter] = []

  func acquire() async throws {
    try Task.checkCancellation()
    if permitIsAvailable {
      permitIsAvailable = false
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(Waiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }

    do {
      try Task.checkCancellation()
    } catch {
      // Grant and cancellation can cross while their actor messages are in
      // flight. If the grant won, forward its permit before reporting cancel.
      release()
      throw error
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      permitIsAvailable = true
      return
    }
    let waiter = waiters.removeFirst()
    waiter.continuation.resume()
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  #if DEBUG
    func waiterCount() -> Int {
      waiters.count
    }
  #endif
}
