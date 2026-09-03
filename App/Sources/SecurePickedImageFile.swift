import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct SecurePickedImageFile: Transferable, Sendable {
  static let maximumSourceByteCount: Int64 = 32 * 1_024 * 1_024
  private static let copyBufferByteCount = 64 * 1_024

  let fileURL: URL
  let temporaryDirectoryURL: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(
      importedContentType: .image,
      shouldAttemptToOpenInPlace: false
    ) { receivedFile in
      try Self.makeTemporaryCopy(of: receivedFile.file)
    }
  }

  static func makeTemporaryCopy(
    of sourceURL: URL,
    fileManager: FileManager = .default,
    temporaryRootURL: URL? = nil,
    maximumSourceByteCount: Int64 = SecurePickedImageFile.maximumSourceByteCount
  ) throws -> Self {
    guard maximumSourceByteCount > 0 else {
      throw SecurePickedImageFileError.invalidSource
    }
    let sourceAttributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
    guard
      sourceAttributes[.type] as? FileAttributeType == .typeRegular,
      let sourceByteCount = (sourceAttributes[.size] as? NSNumber)?.int64Value,
      sourceByteCount >= 0
    else {
      throw SecurePickedImageFileError.invalidSource
    }
    guard sourceByteCount <= maximumSourceByteCount else {
      throw SecurePickedImageFileError.sourceTooLarge(
        maximumByteCount: maximumSourceByteCount
      )
    }

    let rootURL = temporaryRootURL ?? fileManager.temporaryDirectory
    _ = ComposerImageTemporaryDirectoryCleaner(rootURL: rootURL).cleanup()
    let temporaryDirectoryURL = rootURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.directoryPrefix
        + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    let fileURL = temporaryDirectoryURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.selectedImageFilename,
      isDirectory: false
    )
    do {
      #if os(iOS)
        try fileManager.createDirectory(
          at: temporaryDirectoryURL,
          withIntermediateDirectories: false,
          attributes: [.protectionKey: FileProtectionType.complete]
        )
      #else
        try fileManager.createDirectory(
          at: temporaryDirectoryURL,
          withIntermediateDirectories: false
        )
      #endif
      #if os(iOS)
        let createdFile = fileManager.createFile(
          atPath: fileURL.path,
          contents: nil,
          attributes: [.protectionKey: FileProtectionType.complete]
        )
      #else
        let createdFile = fileManager.createFile(atPath: fileURL.path, contents: nil)
      #endif
      guard createdFile else { throw SecurePickedImageFileError.invalidSource }
      try copyBounded(
        from: sourceURL,
        to: fileURL,
        maximumByteCount: maximumSourceByteCount
      )
      return Self(
        fileURL: fileURL,
        temporaryDirectoryURL: temporaryDirectoryURL
      )
    } catch {
      try? fileManager.removeItem(at: temporaryDirectoryURL)
      throw error
    }
  }

  func removeTemporaryCopy() {
    try? FileManager.default.removeItem(at: temporaryDirectoryURL)
  }

  private static func copyBounded(
    from sourceURL: URL,
    to destinationURL: URL,
    maximumByteCount: Int64
  ) throws {
    let source = try FileHandle(forReadingFrom: sourceURL)
    defer { try? source.close() }
    let destination = try FileHandle(forWritingTo: destinationURL)
    defer { try? destination.close() }

    var copiedByteCount: Int64 = 0
    while let chunk = try source.read(upToCount: copyBufferByteCount), !chunk.isEmpty {
      let chunkByteCount = Int64(chunk.count)
      guard
        copiedByteCount <= maximumByteCount,
        chunkByteCount <= maximumByteCount - copiedByteCount
      else {
        throw SecurePickedImageFileError.sourceTooLarge(
          maximumByteCount: maximumByteCount
        )
      }
      try destination.write(contentsOf: chunk)
      copiedByteCount += chunkByteCount
    }
    try destination.synchronize()
  }
}

enum SecurePickedImageFileError: LocalizedError, Sendable {
  case invalidSource
  case sourceTooLarge(maximumByteCount: Int64)

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      "无法安全读取所选图片。"
    case .sourceTooLarge(let maximumByteCount):
      "所选图片文件不能超过 \(maximumByteCount / 1_024 / 1_024) MiB。"
    }
  }
}
