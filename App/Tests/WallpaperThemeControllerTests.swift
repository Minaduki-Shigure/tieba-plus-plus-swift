import Foundation
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeControllerTests: XCTestCase {
  func testConcurrentLoadWaitsForTheSamePersistedImage() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WallpaperThemeRepository(directory: directory)
    let pair = try images()
    let saved = try await repository.save(
      sourceJPEG: pair.0.jpegData, renderedJPEG: pair.1.jpegData,
      settings: .defaultValue, crop: .initial, aspectRatio: 0.5)
    let controller = WallpaperThemeController(repository: repository)
    async let first: Void = controller.load()
    async let second: Void = controller.load()
    _ = await (first, second)
    XCTAssertEqual(controller.document?.record.id, saved.record.id)
    XCTAssertEqual(controller.snapshot?.id, saved.record.id)
    XCTAssertFalse(controller.isLoading)
  }

  func testFailedSaveKeepsPublishedAndPersistedOldThemeThenResetRestoresDefaults() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failure = WallpaperControllerFailureSwitch()
    let repository = WallpaperThemeRepository(directory: directory) { checkpoint in
      if case .afterManifestRename = checkpoint, failure.isEnabled {
        throw WallpaperThemeError.storageFailed
      }
    }
    let controller = WallpaperThemeController(repository: repository)
    let pair = try images()
    try await controller.save(
      source: pair.0, rendered: pair.1, settings: .defaultValue,
      crop: .initial, aspectRatio: 0.5)
    let oldID = try XCTUnwrap(controller.snapshot?.id)
    failure.setEnabled(true)
    var changed = WallpaperThemeSettings.defaultValue
    changed.appearance = .dark
    changed.accentRGB = 0xFF0000
    do {
      try await controller.save(
        source: pair.0, rendered: pair.1, settings: changed,
        crop: .initial, aspectRatio: 0.5)
      XCTFail("Expected the publication failure")
    } catch {}
    XCTAssertEqual(controller.snapshot?.id, oldID)
    XCTAssertEqual(controller.document?.record.settings, .defaultValue)
    let persisted = try await repository.load()
    XCTAssertEqual(persisted?.record.id, oldID)
    failure.setEnabled(false)
    try await controller.reset()
    XCTAssertNil(controller.snapshot)
    XCTAssertNil(controller.document)
    let fresh = WallpaperThemeController(repository: repository)
    await fresh.load()
    XCTAssertNil(fresh.snapshot)
    XCTAssertNil(fresh.errorMessage)
  }

  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-controller-\(UUID())")
  }

  private func images() throws -> (WallpaperThemeSource, WallpaperThemeRenderedImage) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).image {
      UIColor.blue.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
    }
    let source = try WallpaperThemeImageProcessor.prepare(
      data: XCTUnwrap(image.jpegData(compressionQuality: 0.9)))
    let rendered = try WallpaperThemeImageProcessor.render(
      source: source, crop: .initial, aspectRatio: 0.5, blurRadius: 1)
    return (source, rendered)
  }
}

private final class WallpaperControllerFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false
  var isEnabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }
  func setEnabled(_ value: Bool) {
    lock.lock()
    enabled = value
    lock.unlock()
  }
}
