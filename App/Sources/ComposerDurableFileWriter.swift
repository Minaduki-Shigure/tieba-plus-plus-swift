import Darwin
import Foundation

enum ComposerDraftDurabilityCheckpoint: Sendable, Equatable {
  case stagedFile
  case parentDirectory
}

enum ComposerDurableFileWriterError: Error, Sendable, Equatable {
  case writeFailed
}

struct ComposerDurableFileWriter: Sendable {
  private let targetURL: URL
  private let maximumByteCount: Int
  private let stagedFilenamePrefix: String
  private let prepareStorageDirectory: @Sendable (URL) throws -> Void
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync: @Sendable (ComposerDraftDurabilityCheckpoint) throws -> Void

  init(
    targetURL: URL,
    maximumByteCount: Int,
    stagedFilenamePrefix: String,
    prepareStorageDirectory: @escaping @Sendable (URL) throws -> Void,
    prepareStagedFile: @escaping @Sendable (URL) throws -> Void,
    beforeDurabilitySync: @escaping @Sendable (ComposerDraftDurabilityCheckpoint) throws
      -> Void = { _ in }
  ) {
    self.targetURL = targetURL.standardizedFileURL
    self.maximumByteCount = maximumByteCount
    self.stagedFilenamePrefix = stagedFilenamePrefix
    self.prepareStorageDirectory = prepareStorageDirectory
    self.prepareStagedFile = prepareStagedFile
    self.beforeDurabilitySync = beforeDurabilitySync
  }

  func persist(_ data: Data) throws {
    guard
      targetURL.isFileURL,
      !data.isEmpty,
      data.count <= maximumByteCount,
      Self.isValidFilename(targetURL.lastPathComponent),
      Self.isValidStagedFilenamePrefix(stagedFilenamePrefix)
    else { throw ComposerDurableFileWriterError.writeFailed }

    let directoryURL = targetURL.deletingLastPathComponent()
    let stagedFilename =
      "\(stagedFilenamePrefix)\(UUID().uuidString.lowercased()).staged"
    let stagedURL = directoryURL.appendingPathComponent(stagedFilename, isDirectory: false)
    let targetFilename = targetURL.lastPathComponent
    var directoryDescriptor: Int32 = -1
    var stagedDescriptor: Int32 = -1
    var didPublish = false

    do {
      let expectedDirectoryStatus = try ensureStorageDirectory(directoryURL)
      directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard directoryDescriptor >= 0 else {
        throw ComposerDurableFileWriterError.writeFailed
      }

      var openedDirectoryStatus = stat()
      guard
        Darwin.fstat(directoryDescriptor, &openedDirectoryStatus) == 0,
        Self.fileType(of: openedDirectoryStatus) == mode_t(S_IFDIR),
        openedDirectoryStatus.st_dev == expectedDirectoryStatus.st_dev,
        openedDirectoryStatus.st_ino == expectedDirectoryStatus.st_ino
      else { throw ComposerDurableFileWriterError.writeFailed }

      stagedDescriptor = stagedFilename.withCString { filename in
        Darwin.openat(
          directoryDescriptor,
          filename,
          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
          mode_t(S_IRUSR | S_IWUSR)
        )
      }
      guard stagedDescriptor >= 0 else {
        throw ComposerDurableFileWriterError.writeFailed
      }

      try Self.writeAll(data, to: stagedDescriptor)
      try prepareStagedFile(stagedURL)
      try verifyStagedFile(
        at: stagedURL,
        descriptor: stagedDescriptor,
        expectedData: data
      )
      try runDurabilityHook(.stagedFile)
      try Self.synchronizeRegularFile(descriptor: stagedDescriptor)
      guard Darwin.close(stagedDescriptor) == 0 else {
        stagedDescriptor = -1
        throw ComposerDurableFileWriterError.writeFailed
      }
      stagedDescriptor = -1

      let renameResult = stagedFilename.withCString { source in
        targetFilename.withCString { destination in
          Darwin.renameat(directoryDescriptor, source, directoryDescriptor, destination)
        }
      }
      guard renameResult == 0 else {
        throw ComposerDurableFileWriterError.writeFailed
      }
      didPublish = true

      try runDurabilityHook(.parentDirectory)
      try Self.synchronizeWithFSync(descriptor: directoryDescriptor)
      try verifyTargetFile(expectedData: data)
    } catch {
      if stagedDescriptor >= 0 {
        _ = Darwin.close(stagedDescriptor)
        stagedDescriptor = -1
      }
      if !didPublish, directoryDescriptor >= 0 {
        _ = stagedFilename.withCString { filename in
          Darwin.unlinkat(directoryDescriptor, filename, 0)
        }
      }
      if directoryDescriptor >= 0 {
        _ = Darwin.close(directoryDescriptor)
        directoryDescriptor = -1
      }
      throw ComposerDurableFileWriterError.writeFailed
    }

    if directoryDescriptor >= 0 {
      _ = Darwin.close(directoryDescriptor)
    }
  }

  private func ensureStorageDirectory(_ directoryURL: URL) throws -> stat {
    guard directoryURL.isFileURL else {
      throw ComposerDurableFileWriterError.writeFailed
    }
    do {
      if let status = try Self.storageItemStatus(at: directoryURL) {
        guard Self.fileType(of: status) == mode_t(S_IFDIR) else {
          throw ComposerDurableFileWriterError.writeFailed
        }
      } else {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      }
      guard
        let status = try Self.storageItemStatus(at: directoryURL),
        Self.fileType(of: status) == mode_t(S_IFDIR)
      else { throw ComposerDurableFileWriterError.writeFailed }
      try prepareStorageDirectory(directoryURL)
      guard
        let preparedStatus = try Self.storageItemStatus(at: directoryURL),
        Self.fileType(of: preparedStatus) == mode_t(S_IFDIR),
        preparedStatus.st_dev == status.st_dev,
        preparedStatus.st_ino == status.st_ino
      else { throw ComposerDurableFileWriterError.writeFailed }
      return preparedStatus
    } catch {
      throw ComposerDurableFileWriterError.writeFailed
    }
  }

  private func verifyStagedFile(
    at stagedURL: URL,
    descriptor: Int32,
    expectedData: Data
  ) throws {
    var descriptorStatus = stat()
    guard
      Darwin.fstat(descriptor, &descriptorStatus) == 0,
      Self.fileType(of: descriptorStatus) == mode_t(S_IFREG),
      descriptorStatus.st_size == off_t(expectedData.count),
      let pathStatus = try Self.storageItemStatus(at: stagedURL),
      Self.fileType(of: pathStatus) == mode_t(S_IFREG),
      pathStatus.st_dev == descriptorStatus.st_dev,
      pathStatus.st_ino == descriptorStatus.st_ino,
      pathStatus.st_size == off_t(expectedData.count),
      try ComposerSecureRegularFileReader.read(
        from: stagedURL,
        expectedByteCount: Int64(expectedData.count),
        maximumByteCount: Int64(maximumByteCount),
        checksCancellation: false
      ) == expectedData
    else { throw ComposerDurableFileWriterError.writeFailed }
  }

  private func verifyTargetFile(expectedData: Data) throws {
    guard
      let status = try Self.storageItemStatus(at: targetURL),
      Self.fileType(of: status) == mode_t(S_IFREG),
      status.st_size == off_t(expectedData.count),
      try ComposerSecureRegularFileReader.read(
        from: targetURL,
        expectedByteCount: Int64(expectedData.count),
        maximumByteCount: Int64(maximumByteCount),
        checksCancellation: false
      ) == expectedData
    else { throw ComposerDurableFileWriterError.writeFailed }
  }

  private func runDurabilityHook(_ checkpoint: ComposerDraftDurabilityCheckpoint) throws {
    do {
      try beforeDurabilitySync(checkpoint)
    } catch {
      throw ComposerDurableFileWriterError.writeFailed
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw ComposerDurableFileWriterError.writeFailed
      }
      var writtenByteCount = 0
      while writtenByteCount < buffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: writtenByteCount),
          buffer.count - writtenByteCount
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw ComposerDurableFileWriterError.writeFailed }
        writtenByteCount += result
      }
    }
  }

  private static func synchronizeRegularFile(descriptor: Int32) throws {
    while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
      if errno == EINTR { continue }
      let fullSyncError = errno
      guard
        fullSyncError == EINVAL || fullSyncError == ENOTSUP || fullSyncError == ENOTTY
      else { throw ComposerDurableFileWriterError.writeFailed }
      try synchronizeWithFSync(descriptor: descriptor)
      return
    }
  }

  private static func synchronizeWithFSync(descriptor: Int32) throws {
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw ComposerDurableFileWriterError.writeFailed
    }
  }

  private static func storageItemStatus(at url: URL) throws -> stat? {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    if result == 0 { return status }
    if errno == ENOENT { return nil }
    throw ComposerDurableFileWriterError.writeFailed
  }

  private static func fileType(of status: stat) -> mode_t {
    status.st_mode & mode_t(S_IFMT)
  }

  private static func isValidFilename(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.utf8.contains(0)
      && !value.contains("/")
  }

  private static func isValidStagedFilenamePrefix(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && !value.utf8.contains(0)
      && !value.contains("/")
  }
}
