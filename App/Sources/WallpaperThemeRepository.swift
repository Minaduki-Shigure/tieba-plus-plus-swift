import CryptoKit
import Foundation
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Immutable image versions are published through one small atomic manifest.
/// The previous manifest remains a recovery point if a file is damaged later.
actor WallpaperThemeRepository {
  enum WriteCheckpoint: Equatable, Sendable {
    case sourceWritten
    case renderedWritten
    case beforeManifest
    case afterManifestRename
  }

  private struct ImageMetadata: Codable {
    let record: WallpaperThemeRecord
    let sourceByteCount: Int
    let renderedByteCount: Int
    let sourceDigest: String
    let renderedDigest: String
  }

  private struct Manifest: Codable {
    var schemaVersion = 1
    let image: ImageMetadata?
    static let disabled = Self(image: nil)
  }

  private let directory: URL
  private let checkpoint: @Sendable (WriteCheckpoint) throws -> Void
  private static let maximumImageBytes = 8 * 1_024 * 1_024
  private static let maximumManifestBytes = 16 * 1_024
  private static let currentName = "current.json"
  private static let previousName = "previous.json"

  init(
    directory: URL,
    checkpoint: @escaping @Sendable (WriteCheckpoint) throws -> Void = { _ in }
  ) {
    self.directory = directory.standardizedFileURL
    self.checkpoint = checkpoint
  }

  nonisolated static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("WallpaperTheme", isDirectory: true)
  }

  func load() throws -> WallpaperThemeDocument? {
    try Task.checkCancellation()
    guard let descriptor = try openDirectory(create: false) else { return nil }
    defer { close(descriptor) }
    return try recoverableManifest(in: descriptor)?.document
  }

  func save(
    sourceJPEG: Data, renderedJPEG: Data, settings: WallpaperThemeSettings,
    crop: WallpaperCropState, aspectRatio: Double
  ) throws -> WallpaperThemeDocument {
    try Task.checkCancellation()
    let record = WallpaperThemeRecord(
      id: UUID(), settings: settings, crop: crop, aspectRatio: aspectRatio)
    guard record.isValid else { throw WallpaperThemeError.invalidSettings }
    try Self.validateJPEG(sourceJPEG)
    try Self.validateJPEG(renderedJPEG)
    guard let descriptor = try openDirectory(create: true) else {
      throw WallpaperThemeError.storageFailed
    }
    defer { close(descriptor) }
    let previous = try recoverableManifest(in: descriptor)
    let previousBytes = try previous?.bytes ?? Self.encode(.disabled)
    let image = ImageMetadata(
      record: record, sourceByteCount: sourceJPEG.count, renderedByteCount: renderedJPEG.count,
      sourceDigest: Self.digest(sourceJPEG), renderedDigest: Self.digest(renderedJPEG))
    let bytes = try Self.encode(Manifest(image: image))
    let sourceName = Self.sourceName(record.id), renderedName = Self.renderedName(record.id)
    var committed = false
    do {
      try writeNew(sourceJPEG, named: sourceName, in: descriptor)
      try checkpoint(.sourceWritten)
      try writeNew(renderedJPEG, named: renderedName, in: descriptor)
      try checkpoint(.renderedWritten)
      try replaceManifest(previousBytes, named: Self.previousName, in: descriptor)
      try checkpoint(.beforeManifest)
      try Task.checkCancellation()
      do {
        try replaceManifest(bytes, named: Self.currentName, in: descriptor, reportsPublication: true)
        committed = true
      } catch {
        // Cancellation and late durability failures must preserve the old enabled
        // version. Rollback is cancellation-independent and never deletes its images.
        do {
          try replaceManifest(
            previousBytes, named: Self.currentName, in: descriptor, checksCancellation: false)
        } catch {
          // Keep both immutable versions and previous.json if storage stays broken.
          // This is the only case in which the active manifest may be uncertain.
          committed = true
        }
        throw error
      }
    } catch {
      if !committed {
        Self.remove(sourceName, from: descriptor)
        Self.remove(renderedName, from: descriptor)
      }
      throw error
    }
    cleanupVersions(keeping: [record.id, previous?.document?.record.id].compactMap { $0 }, in: descriptor)
    return .init(record: record, sourceJPEG: sourceJPEG, renderedJPEG: renderedJPEG)
  }

  func reset() throws {
    try Task.checkCancellation()
    guard let descriptor = try openDirectory(create: false) else { return }
    defer { close(descriptor) }
    // Reset is also the recovery path for a corrupt manifest. Never read through
    // a symlink or require a damaged image to decode before disabling the theme.
    let previous = try? recoverableManifest(in: descriptor)
    let disabled = try Self.encode(.disabled)
    do {
      try replaceManifest(disabled, named: Self.previousName, in: descriptor)
      try checkpoint(.beforeManifest)
      try Task.checkCancellation()
      try replaceManifest(disabled, named: Self.currentName, in: descriptor, reportsPublication: true)
    } catch {
      if let old = previous?.bytes {
        try? replaceManifest(old, named: Self.currentName, in: descriptor, checksCancellation: false)
        try? replaceManifest(old, named: Self.previousName, in: descriptor, checksCancellation: false)
      }
      throw error
    }
    cleanupVersions(keeping: [], in: descriptor)
  }

  private func recoverableManifest(in directoryFD: Int32) throws
    -> (bytes: Data, document: WallpaperThemeDocument?)?
  {
    var failure: Error?
    for name in [Self.currentName, Self.previousName] {
      do {
        guard let bytes = try Self.read(name, maximumBytes: Self.maximumManifestBytes, in: directoryFD)
        else { continue }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.schemaVersion == 1 else { throw WallpaperThemeError.corruptedStorage }
        guard let metadata = manifest.image else { return (bytes, nil) }
        guard metadata.record.isValid,
          (1...Self.maximumImageBytes).contains(metadata.sourceByteCount),
          (1...Self.maximumImageBytes).contains(metadata.renderedByteCount),
          metadata.sourceDigest.count == 64, metadata.renderedDigest.count == 64,
          let source = try Self.read(
            Self.sourceName(metadata.record.id), maximumBytes: metadata.sourceByteCount, in: directoryFD),
          let rendered = try Self.read(
            Self.renderedName(metadata.record.id), maximumBytes: metadata.renderedByteCount, in: directoryFD),
          source.count == metadata.sourceByteCount, rendered.count == metadata.renderedByteCount,
          Self.digest(source) == metadata.sourceDigest, Self.digest(rendered) == metadata.renderedDigest
        else { throw WallpaperThemeError.corruptedStorage }
        try Self.validateJPEG(source)
        try Self.validateJPEG(rendered)
        return (bytes, .init(record: metadata.record, sourceJPEG: source, renderedJPEG: rendered))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failure = error
      }
    }
    if failure != nil { throw WallpaperThemeError.corruptedStorage }
    return nil
  }

  private func openDirectory(create: Bool) throws -> Int32? {
    guard directory.isFileURL, directory.path != "/", directory.query == nil,
      !directory.path.utf8.contains(0)
    else { throw WallpaperThemeError.unsafeStorage }
    var status = stat()
    let found = directory.path.withCString { lstat($0, &status) }
    if found != 0 {
      guard errno == ENOENT else { throw WallpaperThemeError.unsafeStorage }
      if !create { return nil }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: 0o700)])
      } catch { throw WallpaperThemeError.storageFailed }
      guard directory.path.withCString({ lstat($0, &status) }) == 0 else {
        throw WallpaperThemeError.unsafeStorage
      }
    }
    guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), status.st_uid == geteuid() else {
      throw WallpaperThemeError.unsafeStorage
    }
    let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw WallpaperThemeError.unsafeStorage }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
      close(descriptor)
      throw WallpaperThemeError.unsafeStorage
    }
    #if os(iOS)
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
      } catch {
        close(descriptor)
        throw WallpaperThemeError.storageFailed
      }
    #endif
    return descriptor
  }

  private static func read(_ name: String, maximumBytes: Int, in directoryFD: Int32) throws -> Data? {
    try Task.checkCancellation()
    let fd = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw WallpaperThemeError.unsafeStorage
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0,
      (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      status.st_uid == geteuid(), status.st_nlink == 1,
      status.st_size > 0, status.st_size <= maximumBytes
    else { throw WallpaperThemeError.corruptedStorage }
    let count = Int(status.st_size)
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { throw WallpaperThemeError.corruptedStorage }
      var position = 0
      while position < count {
        try Task.checkCancellation()
        #if canImport(Darwin)
          let amount = Darwin.read(fd, base.advanced(by: position), count - position)
        #else
          let amount = Glibc.read(fd, base.advanced(by: position), count - position)
        #endif
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw WallpaperThemeError.corruptedStorage }
        position += amount
      }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, after.st_size == status.st_size,
      after.st_ino == status.st_ino, after.st_nlink == 1
    else { throw WallpaperThemeError.corruptedStorage }
    return data
  }

  private func writeNew(
    _ data: Data, named name: String, in directoryFD: Int32, checksCancellation: Bool = true
  ) throws {
    if checksCancellation { try Task.checkCancellation() }
    let fd = name.withCString {
      openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard fd >= 0 else { throw WallpaperThemeError.storageFailed }
    var complete = false
    defer {
      close(fd)
      if !complete { Self.remove(name, from: directoryFD) }
    }
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { throw WallpaperThemeError.storageFailed }
      var position = 0
      while position < buffer.count {
        if checksCancellation { try Task.checkCancellation() }
        let amount = write(fd, base.advanced(by: position), min(65_536, buffer.count - position))
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw WallpaperThemeError.storageFailed }
        position += amount
      }
    }
    try Self.sync(fd)
    complete = true
  }

  private func replaceManifest(
    _ data: Data, named name: String, in directoryFD: Int32,
    reportsPublication: Bool = false, checksCancellation: Bool = true
  ) throws {
    let stagedName = ".manifest-\(UUID().uuidString.lowercased()).staged"
    defer { Self.remove(stagedName, from: directoryFD) }
    try writeNew(data, named: stagedName, in: directoryFD, checksCancellation: checksCancellation)
    if checksCancellation { try Task.checkCancellation() }
    let renamed = stagedName.withCString { staged in
      name.withCString { target in renameat(directoryFD, staged, directoryFD, target) }
    }
    guard renamed == 0 else { throw WallpaperThemeError.storageFailed }
    if reportsPublication { try checkpoint(.afterManifestRename) }
    try Self.sync(directoryFD)
  }

  private func cleanupVersions(keeping ids: [UUID], in directoryFD: Int32) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let retained = Set(ids.map { $0.uuidString.lowercased() })
    for name in names {
      guard name.hasSuffix("-source.jpg") || name.hasSuffix("-rendered.jpg"),
        name.count <= 49, name.count >= 47,
        let id = UUID(uuidString: String(name.prefix(36))),
        !retained.contains(id.uuidString.lowercased())
      else { continue }
      Self.remove(name, from: directoryFD)
    }
  }

  private static func sync(_ fd: Int32) throws {
    for _ in 0..<8 {
      if fsync(fd) == 0 { return }
      if errno != EINTR { break }
    }
    throw WallpaperThemeError.storageFailed
  }

  private static func remove(_ name: String, from directoryFD: Int32) {
    _ = name.withCString { unlinkat(directoryFD, $0, 0) }
  }

  private static func sourceName(_ id: UUID) -> String { "\(id.uuidString.lowercased())-source.jpg" }
  private static func renderedName(_ id: UUID) -> String { "\(id.uuidString.lowercased())-rendered.jpg" }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func encode(_ manifest: Manifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    guard data.count <= maximumManifestBytes else { throw WallpaperThemeError.invalidSettings }
    return data
  }

  private static func validateJPEG(_ data: Data) throws {
    guard data.count <= maximumImageBytes else { throw WallpaperThemeError.imageTooLarge }
    guard data.count >= 4, data.starts(with: [0xFF, 0xD8]), data.suffix(2).elementsEqual([0xFF, 0xD9]) else {
      throw WallpaperThemeError.invalidImage
    }
  }
}
