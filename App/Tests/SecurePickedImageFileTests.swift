import Foundation
import XCTest

@testable import TiebaPlusPlus

final class SecurePickedImageFileTests: XCTestCase {
  func testTemporaryCopyIsOwnedProtectedAndRemovable() throws {
    let fileManager = FileManager.default
    let testRootURL = fileManager.temporaryDirectory.appendingPathComponent(
      "secure-picked-image-tests-" + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    let temporaryRootURL = testRootURL.appendingPathComponent("imports", isDirectory: true)
    let sourceURL = testRootURL.appendingPathComponent("source.jpg", isDirectory: false)
    try fileManager.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
    let sourceData = Data("private-image".utf8)
    try sourceData.write(to: sourceURL)
    defer { try? fileManager.removeItem(at: testRootURL) }

    let imported = try SecurePickedImageFile.makeTemporaryCopy(
      of: sourceURL,
      fileManager: fileManager,
      temporaryRootURL: temporaryRootURL
    )

    XCTAssertEqual(try Data(contentsOf: imported.fileURL), sourceData)
    XCTAssertEqual(imported.temporaryDirectoryURL.deletingLastPathComponent(), temporaryRootURL)
    #if os(iOS)
      let directoryAttributes = try fileManager.attributesOfItem(
        atPath: imported.temporaryDirectoryURL.path
      )
      let fileAttributes = try fileManager.attributesOfItem(atPath: imported.fileURL.path)
      #if targetEnvironment(simulator)
        if let protection = directoryAttributes[.protectionKey] as? FileProtectionType {
          XCTAssertEqual(protection, .complete)
        }
        if let protection = fileAttributes[.protectionKey] as? FileProtectionType {
          XCTAssertEqual(protection, .complete)
        }
      #else
        XCTAssertEqual(directoryAttributes[.protectionKey] as? FileProtectionType, .complete)
        XCTAssertEqual(fileAttributes[.protectionKey] as? FileProtectionType, .complete)
      #endif
    #endif

    imported.removeTemporaryCopy()
    XCTAssertFalse(fileManager.fileExists(atPath: imported.temporaryDirectoryURL.path))
  }

  func testRemoveTemporaryCopyRemovesOwnedDirectory() throws {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.directoryPrefix
        + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    let fileURL = directoryURL.appendingPathComponent(
      ComposerImageTemporaryDirectoryCleaner.selectedImageFilename,
      isDirectory: false
    )
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    try Data("private-image".utf8).write(to: fileURL)
    defer { try? fileManager.removeItem(at: directoryURL) }

    SecurePickedImageFile(
      fileURL: fileURL,
      temporaryDirectoryURL: directoryURL
    ).removeTemporaryCopy()

    XCTAssertFalse(fileManager.fileExists(atPath: directoryURL.path))
  }

  func testFailedTemporaryCopyDoesNotLeaveOwnedDirectory() throws {
    let fileManager = FileManager.default
    let temporaryRootURL = fileManager.temporaryDirectory.appendingPathComponent(
      "secure-picked-image-failure-tests-" + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    try fileManager.createDirectory(at: temporaryRootURL, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: temporaryRootURL) }

    XCTAssertThrowsError(
      try SecurePickedImageFile.makeTemporaryCopy(
        of: temporaryRootURL.appendingPathComponent("missing-source"),
        fileManager: fileManager,
        temporaryRootURL: temporaryRootURL
      )
    )
    XCTAssertTrue(
      try fileManager.contentsOfDirectory(
        at: temporaryRootURL,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
  }

  func testOversizedSourceIsRejectedBeforeCreatingOwnedDirectory() throws {
    let fileManager = FileManager.default
    let testRootURL = fileManager.temporaryDirectory.appendingPathComponent(
      "secure-picked-image-size-tests-" + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    let temporaryRootURL = testRootURL.appendingPathComponent("imports", isDirectory: true)
    let sourceURL = testRootURL.appendingPathComponent("source.jpg", isDirectory: false)
    try fileManager.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
    try Data(repeating: 0x7F, count: 9).write(to: sourceURL)
    defer { try? fileManager.removeItem(at: testRootURL) }

    XCTAssertThrowsError(
      try SecurePickedImageFile.makeTemporaryCopy(
        of: sourceURL,
        fileManager: fileManager,
        temporaryRootURL: temporaryRootURL,
        maximumSourceByteCount: 8
      )
    ) { error in
      guard case SecurePickedImageFileError.sourceTooLarge(let maximum) = error else {
        return XCTFail("Expected a bounded source-size error, got \(error)")
      }
      XCTAssertEqual(maximum, 8)
    }
    XCTAssertTrue(
      try fileManager.contentsOfDirectory(
        at: temporaryRootURL,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
  }
}
