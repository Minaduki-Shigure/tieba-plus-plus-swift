import Foundation
import XCTest
@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeRepositoryTests: XCTestCase {
  // Storage checksums and boundaries are independent of image decoding. The
  // processor tests exercise real JPEGs; these distinct payloads isolate storage.
  private let firstJPEG = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
  private let secondJPEG = Data([0xFF, 0xD8, 4, 5, 6, 0xFF, 0xD9])

  func testSaveReloadAndResetUseIndependentDurableVersions() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let first = try await save(repository, jpeg: firstJPEG)
    let second = try await save(repository, jpeg: secondJPEG)
    XCTAssertNotEqual(first.record.id, second.record.id)
    let reloaded = try await WallpaperThemeRepository(directory: directory).load()
    XCTAssertEqual(reloaded?.record, second.record)
    XCTAssertEqual(reloaded?.sourceJPEG, secondJPEG)
    XCTAssertEqual(reloaded?.renderedJPEG, secondJPEG)
    try await repository.reset()
    let disabled = try await WallpaperThemeRepository(directory: directory).load()
    XCTAssertNil(disabled)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".jpg") })
    // The recovery manifest is also disabled, so damage cannot resurrect a reset wallpaper.
    try Data("broken".utf8).write(to: directory.appendingPathComponent("current.json"))
    let afterDamage = try await repository.load()
    XCTAssertNil(afterDamage)
  }

  func testCorruptCurrentImageFallsBackToPriorVersionAndCanBeReplaced() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let first = try await save(repository, jpeg: firstJPEG)
    let second = try await save(repository, jpeg: secondJPEG)
    try firstJPEG.write(to: imageURL(second.record.id, suffix: "source", directory: directory))
    let recovered = try await repository.load()
    XCTAssertEqual(recovered?.record, first.record)
    let replacement = try await save(repository, jpeg: secondJPEG)
    let loaded = try await repository.load()
    XCTAssertEqual(loaded?.record, replacement.record)
  }

  func testOversizedOrCorruptManifestFallsBackWithoutReadingUnboundedData() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let first = try await save(repository, jpeg: firstJPEG)
    _ = try await save(repository, jpeg: secondJPEG)
    try Data(repeating: 65, count: 16 * 1_024 + 1).write(to: directory.appendingPathComponent("current.json"))
    let recovered = try await repository.load()
    XCTAssertEqual(recovered?.record, first.record)
    try Data("broken".utf8).write(to: directory.appendingPathComponent("previous.json"))
    do {
      _ = try await repository.load()
      XCTFail("Both corrupt manifests must be reported")
    } catch { XCTAssertEqual(error as? WallpaperThemeError, .corruptedStorage) }
    try await repository.reset()
    let reset = try await repository.load()
    XCTAssertNil(reset)
    _ = try await save(repository, jpeg: firstJPEG)
  }

  func testFailedSaveAtEveryPublicationBoundaryPreservesEnabledVersion() async throws {
    for point in [WallpaperThemeRepository.WriteCheckpoint.sourceWritten, .renderedWritten, .beforeManifest, .afterManifestRename] {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let initial = WallpaperThemeRepository(directory: directory)
      let old = try await save(initial, jpeg: firstJPEG)
      let failing = WallpaperThemeRepository(directory: directory) { encountered in
        if encountered == point { throw WallpaperThemeError.storageFailed }
      }
      do {
        _ = try await save(failing, jpeg: secondJPEG)
        XCTFail("Injected failure must be reported at \(point)")
      } catch { XCTAssertEqual(error as? WallpaperThemeError, .storageFailed) }
      let loaded = try await WallpaperThemeRepository(directory: directory).load()
      XCTAssertEqual(loaded?.record, old.record)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") }.count, 2)
    }
  }

  func testResetFailurePreservesRecoveredVersionEvenWhenCurrentWasAlreadyCorrupt() async throws {
    for afterRename in [false, true] {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let repository = WallpaperThemeRepository(directory: directory)
      let old = try await save(repository, jpeg: firstJPEG)
      _ = try await save(repository, jpeg: secondJPEG)
      try Data("broken".utf8).write(to: directory.appendingPathComponent("current.json"))
      let failing = WallpaperThemeRepository(directory: directory) { point in
        switch point {
        case .beforeManifest where !afterRename, .afterManifestRename where afterRename:
          throw WallpaperThemeError.storageFailed
        default: break
        }
      }
      do {
        try await failing.reset()
        XCTFail("Failed reset must preserve the recovered wallpaper")
      } catch { XCTAssertEqual(error as? WallpaperThemeError, .storageFailed) }
      let loaded = try await repository.load()
      XCTAssertEqual(loaded?.record, old.record)
    }
  }

  func testCancellationBeforeSaveDoesNotCreateStorage() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let jpeg = firstJPEG
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await repository.save(sourceJPEG: jpeg, renderedJPEG: jpeg, settings: .defaultValue, crop: .initial, aspectRatio: 0.5)
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled save must throw")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testCancellationImmediatelyBeforePublicationRetainsOldVersion() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let old = try await save(repository, jpeg: firstJPEG)
    let cancelling = WallpaperThemeRepository(directory: directory) { point in
      if case .beforeManifest = point { withUnsafeCurrentTask { $0?.cancel() } }
    }
    let jpeg = secondJPEG
    let task = Task {
      try await cancelling.save(sourceJPEG: jpeg, renderedJPEG: jpeg, settings: .defaultValue, crop: .initial, aspectRatio: 0.5)
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled save must throw")
    } catch { XCTAssertTrue(error is CancellationError) }
    let loaded = try await repository.load()
    XCTAssertEqual(loaded?.record, old.record)
  }

  func testCancellationAfterManifestRenameReturnsTheCommittedVersion() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory) { point in
      if case .afterManifestRename = point { withUnsafeCurrentTask { $0?.cancel() } }
    }
    let jpeg = firstJPEG
    let task = Task {
      try await repository.save(sourceJPEG: jpeg, renderedJPEG: jpeg, settings: .defaultValue, crop: .initial, aspectRatio: 0.5)
    }
    let committed = try await task.value
    let loaded = try await WallpaperThemeRepository(directory: directory).load()
    XCTAssertEqual(loaded?.record, committed.record)
  }

  func testSymlinkDirectoryAndImageDoNotEscapeStorageBoundary() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    do {
      _ = try await save(WallpaperThemeRepository(directory: link), jpeg: firstJPEG)
      XCTFail("Symlink storage root must be rejected")
    } catch { XCTAssertEqual(error as? WallpaperThemeError, .unsafeStorage) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)

    let directory = root.appendingPathComponent("wallpaper", isDirectory: true)
    let repository = WallpaperThemeRepository(directory: directory)
    let old = try await save(repository, jpeg: firstJPEG)
    let new = try await save(repository, jpeg: secondJPEG)
    let sentinel = external.appendingPathComponent("sentinel.jpg")
    try secondJPEG.write(to: sentinel)
    let image = imageURL(new.record.id, suffix: "source", directory: directory)
    try FileManager.default.removeItem(at: image)
    try FileManager.default.createSymbolicLink(at: image, withDestinationURL: sentinel)
    let recovered = try await repository.load()
    XCTAssertEqual(recovered?.record, old.record)
    try await repository.reset()
    XCTAssertEqual(try Data(contentsOf: sentinel), secondJPEG)
  }

  func testInvalidSaveCannotReplaceCurrentAndCleanupRetainsOnlyTwoVersions() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    _ = try await save(repository, jpeg: firstJPEG)
    _ = try await save(repository, jpeg: secondJPEG)
    let old = try await save(repository, jpeg: firstJPEG)
    let unrelated = directory.appendingPathComponent("unrelated.jpg")
    try Data([7]).write(to: unrelated)
    var invalid = WallpaperThemeSettings.defaultValue
    invalid.imageOpacity = .infinity
    do {
      _ = try await repository.save(sourceJPEG: firstJPEG, renderedJPEG: firstJPEG, settings: invalid, crop: .initial, aspectRatio: 0.5)
      XCTFail("Invalid setting must be rejected")
    } catch { XCTAssertEqual(error as? WallpaperThemeError, .invalidSettings) }
    do {
      _ = try await save(repository, jpeg: Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1))
      XCTFail("Oversized data must be rejected")
    } catch { XCTAssertEqual(error as? WallpaperThemeError, .imageTooLarge) }
    let loaded = try await repository.load()
    XCTAssertEqual(loaded?.record, old.record)
    XCTAssertEqual(try Data(contentsOf: unrelated), Data([7]))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix("-source.jpg") || $0.hasSuffix("-rendered.jpg") }.count, 4)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperThemeTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func save(_ repository: WallpaperThemeRepository, jpeg: Data) async throws -> WallpaperThemeDocument {
    try await repository.save(sourceJPEG: jpeg, renderedJPEG: jpeg, settings: .defaultValue, crop: .initial, aspectRatio: 0.5)
  }

  private func imageURL(_ id: UUID, suffix: String, directory: URL) -> URL {
    directory.appendingPathComponent("\(id.uuidString.lowercased())-\(suffix).jpg")
  }
}
