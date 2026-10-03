import CoreGraphics
import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeEditorTests: XCTestCase {
  func testAdjustmentsRemainDraftUntilExplicitSave() async throws {
    let source = try makeSource(1)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 390, height: 844))
    model.importImage { Data([1]) }
    await model.waitForImport()
    await model.waitForPreview()
    var settings = model.settings
    settings.imageOpacity = 0.4
    settings.appearance = .dark
    settings.accentRGB = 0xAA_33_11
    model.updateSettings(settings)

    XCTAssertTrue(model.canSave)
    var committed: WallpaperThemeEditorSnapshot?
    let saved = await model.save { committed = $0 }
    XCTAssertTrue(saved)
    let snapshot = try XCTUnwrap(committed)
    XCTAssertEqual(snapshot.settings, settings)
    XCTAssertEqual(snapshot.source.jpegData, Data([1]))
    XCTAssertEqual(snapshot.aspectRatio, 390.0 / 844.0, accuracy: 0.000_001)
  }

  func testReplacementRejectsOldImportEvenWhenItIgnoresCancellation() async throws {
    let first = try makeSource(1)
    let second = try makeSource(2)
    let oldImport = WallpaperEditorTestGate<WallpaperThemeSource>()
    let model = WallpaperThemeEditorModel(
      processing: .init(
        prepare: { data in
          if data == Data([1]) { return await oldImport.wait() }
          return second
        },
        render: { source, _, _, _ in
          .init(image: source.image, jpegData: source.jpegData)
        }
      ),
      previewDelayNanoseconds: 0
    )
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([1]) }
    let oldTask = model.importTask
    await oldImport.waitUntilEntered()
    model.importImage { Data([2]) }
    await model.waitForImport()
    await model.waitForPreview()
    await oldImport.resolve(first)
    await oldTask?.value

    XCTAssertEqual(model.source?.jpegData, Data([2]))
    XCTAssertEqual(model.rendered?.jpegData, Data([2]))
    XCTAssertFalse(model.isImporting)
    XCTAssertTrue(model.canSave)
  }

  func testDiscardDoesNotAcceptLateImportOrEnableSave() async throws {
    let source = try makeSource(1)
    let gate = WallpaperEditorTestGate<WallpaperThemeSource>()
    let model = WallpaperThemeEditorModel(
      processing: .init(
        prepare: { _ in await gate.wait() },
        render: { source, _, _, _ in .init(image: source.image, jpegData: source.jpegData) }
      ),
      previewDelayNanoseconds: 0
    )
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([1]) }
    let oldTask = model.importTask
    await gate.waitUntilEntered()
    model.discard()
    await gate.resolve(source)
    await oldTask?.value

    XCTAssertNil(model.source)
    XCTAssertNil(model.rendered)
    XCTAssertFalse(model.isImporting)
    XCTAssertFalse(model.canSave)
    var didWrite = false
    let saved = await model.save { _ in didWrite = true }
    XCTAssertFalse(saved)
    XCTAssertFalse(didWrite)
  }

  func testLatePreviewCannotReplaceNewBlurResult() async throws {
    let source = try makeSource(1)
    let gate = WallpaperEditorTestGate<WallpaperThemeRenderedImage>()
    let initialBlur = WallpaperThemeSettings.defaultValue.blurRadius
    let newBlur = initialBlur == 7 ? 8.0 : 7.0
    let model = WallpaperThemeEditorModel(
      processing: .init(
        prepare: { _ in source },
        render: { source, _, _, blur in
          if blur == initialBlur { return await gate.wait() }
          return .init(image: source.image, jpegData: Data([2]))
        }
      ),
      previewDelayNanoseconds: 0
    )
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([1]) }
    await model.waitForImport()
    await gate.waitUntilEntered()
    let oldTask = model.previewTask
    var settings = model.settings
    settings.blurRadius = newBlur
    model.updateSettings(settings)
    await model.waitForPreview()
    await gate.resolve(.init(image: source.image, jpegData: Data([1])))
    await oldTask?.value

    XCTAssertEqual(model.rendered?.jpegData, Data([2]))
    XCTAssertEqual(model.settings.blurRadius, newBlur)
    XCTAssertTrue(model.canSave)
  }

  func testResumePreservesDraftAfterTemporarySystemPresentation() async throws {
    let source = try makeSource(8)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([8]) }
    await model.waitForImport()
    await model.waitForPreview()
    var settings = model.settings
    settings.imageOpacity = 0.49
    model.updateSettings(settings)
    var crop = model.crop
    crop.zoom = 2
    model.updateCrop(crop)
    await model.waitForPreview()
    let expectedCrop = model.crop
    model.discard()
    XCTAssertFalse(model.canSave)
    model.resume()
    await model.waitForPreview()

    XCTAssertEqual(model.source?.jpegData, Data([8]))
    XCTAssertEqual(model.settings, settings)
    XCTAssertEqual(model.crop, expectedCrop)
    XCTAssertTrue(model.canSave)
  }

  func testResumeStillRejectsImportFromPreviousPresentation() async throws {
    let first = try makeSource(1)
    let second = try makeSource(2)
    let gate = WallpaperEditorTestGate<WallpaperThemeSource>()
    let model = WallpaperThemeEditorModel(
      processing: .init(
        prepare: { data in
          if data == Data([1]) { return await gate.wait() }
          return second
        },
        render: { source, _, _, _ in .init(image: source.image, jpegData: source.jpegData) }
      ),
      previewDelayNanoseconds: 0
    )
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([1]) }
    let oldTask = model.importTask
    await gate.waitUntilEntered()
    model.discard()
    model.resume()
    model.importImage { Data([2]) }
    await model.waitForImport()
    await model.waitForPreview()
    await gate.resolve(first)
    await oldTask?.value

    XCTAssertEqual(model.source?.jpegData, Data([2]))
    XCTAssertEqual(model.rendered?.jpegData, Data([2]))
    XCTAssertTrue(model.canSave)
  }

  func testSaveFailurePreservesDraftAndAllowsExplicitRetry() async throws {
    let source = try makeSource(3)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 390, height: 844))
    model.importImage { Data([3]) }
    await model.waitForImport()
    await model.waitForPreview()
    var settings = model.settings
    settings.imageOpacity = 0.37
    settings.appearance = .dark
    model.updateSettings(settings)
    var crop = model.crop
    crop.zoom = 2
    model.updateCrop(crop)
    await model.waitForPreview()
    let expectedCrop = model.crop

    let failed = await model.save { _ in throw WallpaperEditorTestError.failed }
    XCTAssertFalse(failed)
    XCTAssertEqual(model.settings, settings)
    XCTAssertEqual(model.crop, expectedCrop)
    XCTAssertEqual(model.source?.jpegData, Data([3]))
    XCTAssertNotNil(model.errorMessage)
    XCTAssertTrue(model.canSave)
    var writeCount = 0
    let retried = await model.save { snapshot in
      writeCount += 1
      XCTAssertEqual(snapshot.settings, settings)
      XCTAssertEqual(snapshot.crop, expectedCrop)
    }
    XCTAssertTrue(retried)
    XCTAssertEqual(writeCount, 1)
    XCTAssertNil(model.errorMessage)
  }

  func testFailedReplacementRetainsPreviousDraft() async throws {
    let source = try makeSource(4)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([4]) }
    await model.waitForImport()
    await model.waitForPreview()
    var settings = model.settings
    settings.imageOpacity = 0.31
    model.updateSettings(settings)
    model.importImage { throw WallpaperEditorTestError.failed }
    await model.waitForImport()
    await model.waitForPreview()

    XCTAssertEqual(model.source?.jpegData, Data([4]))
    XCTAssertEqual(model.settings.imageOpacity, 0.31)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertTrue(model.canSave)
  }

  func testWindowResizeReclampsCropAndInvalidatesOldPreview() async throws {
    let source = try makeSource(5)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([5]) }
    await model.waitForImport()
    await model.waitForPreview()
    var crop = model.crop
    crop.centerX = 0
    crop.centerY = 1
    crop.zoom = 2
    model.updateCrop(crop)
    await model.waitForPreview()
    let newSize = CGSize(width: 800, height: 400)
    model.updateViewportSize(newSize)
    XCTAssertFalse(model.canSave)
    await model.waitForPreview()
    XCTAssertTrue(model.canSave)
    XCTAssertEqual(model.aspectRatio, 2)
    XCTAssertEqual(
      model.crop,
      WallpaperCropGeometry(
        sourcePixelSize: CGSize(width: source.image.width, height: source.image.height),
        viewportSize: newSize
      ).clamped(model.crop)
    )
  }

  func testOpacityAndAccentDoNotRegenerateImage() async throws {
    let source = try makeSource(6)
    let counter = WallpaperEditorTestCounter()
    let model = WallpaperThemeEditorModel(
      processing: .init(
        prepare: { _ in source },
        render: { source, _, _, _ in
          await counter.increment()
          return .init(image: source.image, jpegData: source.jpegData)
        }
      ),
      previewDelayNanoseconds: 0
    )
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([6]) }
    await model.waitForImport()
    await model.waitForPreview()
    var settings = model.settings
    settings.imageOpacity = 0.62
    settings.appearance = .dark
    settings.accentRGB = 0x12_34_56
    model.updateSettings(settings)
    let count = await counter.value
    XCTAssertEqual(count, 1)
    XCTAssertTrue(model.canSave)
  }

  func testSavedDocumentRestoresSettingsAndCropForCurrentWindow() async throws {
    let source = try makeSource(9)
    let storedSourceJPEG = Data([10])
    let model = makeModel(source: source)
    let settings = WallpaperThemeSettings(
      appearance: .dark, imageOpacity: 0.63, blurRadius: 8, accentRGB: 0x22_88_AA
    )
    let crop = WallpaperCropState(centerX: 0.45, centerY: 0.55, zoom: 2)
    let record = WallpaperThemeRecord(
      id: UUID(), settings: settings, crop: crop, aspectRatio: 0.5
    )
    model.updateViewportSize(CGSize(width: 800, height: 400))
    model.restore(
      document: WallpaperThemeDocument(
        record: record, sourceJPEG: storedSourceJPEG, renderedJPEG: Data([0])
      )
    )
    await model.waitForImport()
    await model.waitForPreview()

    XCTAssertEqual(model.settings, settings)
    XCTAssertEqual(model.aspectRatio, 2)
    XCTAssertEqual(
      model.crop,
      WallpaperCropGeometry(
        sourcePixelSize: CGSize(width: source.image.width, height: source.image.height),
        viewportSize: CGSize(width: 800, height: 400)
      ).clamped(crop)
    )
    XCTAssertEqual(model.source?.jpegData, storedSourceJPEG)
    XCTAssertEqual(model.rendered?.jpegData, storedSourceJPEG)
    XCTAssertTrue(model.canSave)
  }

  func testResetFailureRetainsDraftAndInstalledStateUntilRetry() async throws {
    let source = try makeSource(7)
    let model = makeModel(source: source)
    model.updateViewportSize(CGSize(width: 400, height: 800))
    model.importImage { Data([7]) }
    await model.waitForImport()
    await model.waitForPreview()
    let failed = await model.reset { throw WallpaperEditorTestError.failed }
    XCTAssertFalse(failed)
    XCTAssertTrue(model.canSave)
    XCTAssertEqual(model.source?.jpegData, Data([7]))
    XCTAssertNotNil(model.errorMessage)
    var resetCount = 0
    let succeeded = await model.reset { resetCount += 1 }
    XCTAssertTrue(succeeded)
    XCTAssertEqual(resetCount, 1)
    XCTAssertFalse(model.canSave)
  }

  private func makeModel(source: WallpaperThemeSource) -> WallpaperThemeEditorModel {
    WallpaperThemeEditorModel(
      processing: .init(
        prepare: { _ in source },
        render: { source, _, _, _ in .init(image: source.image, jpegData: source.jpegData) }
      ),
      previewDelayNanoseconds: 0
    )
  }

  private func makeSource(_ byte: UInt8) throws -> WallpaperThemeSource {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.setFillColor(CGColor(gray: CGFloat(byte) / 10, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
    return WallpaperThemeSource(
      image: try XCTUnwrap(context.makeImage()), jpegData: Data([byte]), palette: [0x33_66_99]
    )
  }
}

private enum WallpaperEditorTestError: Error { case failed }

private actor WallpaperEditorTestCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Intentionally ignores cancellation to exercise request-identity validation.
private actor WallpaperEditorTestGate<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Never>?
  private var entered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered = true
      entryWaiters.forEach { $0.resume() }
      entryWaiters.removeAll()
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func resolve(_ value: Value) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}
