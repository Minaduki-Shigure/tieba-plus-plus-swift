import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class RemoteImageExportTests: XCTestCase {
  func testDimensionPolicyRejectsInvalidOverflowingAndExcessiveDimensions() {
    XCTAssertFalse(RemoteImageValidationPolicy.acceptsDimensions(width: 0, height: 1))
    XCTAssertFalse(RemoteImageValidationPolicy.acceptsDimensions(width: 1, height: 0))
    XCTAssertTrue(
      RemoteImageValidationPolicy.acceptsDimensions(width: 10_000, height: 10_000)
    )
    XCTAssertFalse(
      RemoteImageValidationPolicy.acceptsDimensions(width: 10_001, height: 10_000)
    )
    XCTAssertFalse(
      RemoteImageValidationPolicy.acceptsDimensions(width: 32_769, height: 1)
    )
    XCTAssertFalse(
      RemoteImageValidationPolicy.acceptsDimensions(width: Int.max, height: Int.max)
    )
    XCTAssertTrue(RemoteImageValidationPolicy.acceptsFrameCount(1))
    XCTAssertTrue(RemoteImageValidationPolicy.acceptsFrameCount(500))
    XCTAssertFalse(RemoteImageValidationPolicy.acceptsFrameCount(0))
    XCTAssertFalse(RemoteImageValidationPolicy.acceptsFrameCount(501))
    XCTAssertEqual(
      RemoteImageValidationPolicy.totalPixelCountByAddingFrame(
        width: 10_000,
        height: 10_000,
        to: 0
      ),
      100_000_000
    )
    XCTAssertNil(
      RemoteImageValidationPolicy.totalPixelCountByAddingFrame(
        width: 10_000,
        height: 10_000,
        to: 100_000_000,
        maximumTotalPixelCount: 150_000_000
      )
    )
  }

  func testFilenamePolicyPreservesGIFPNGAndJPEGExtensions() {
    XCTAssertEqual(
      RemoteImageValidationPolicy.filenameExtension(
        for: .gif,
        suggestedFilename: "animation.JPG"
      ),
      "gif"
    )
    XCTAssertEqual(
      RemoteImageValidationPolicy.filenameExtension(
        for: .png,
        suggestedFilename: "image.bin"
      ),
      "png"
    )
    XCTAssertEqual(
      RemoteImageValidationPolicy.filenameExtension(
        for: .jpeg,
        suggestedFilename: "photo.jpeg"
      ),
      "jpeg"
    )
    XCTAssertEqual(
      RemoteImageValidationPolicy.filenameExtension(
        for: .jpeg,
        suggestedFilename: "photo.jpg"
      ),
      "jpg"
    )
    XCTAssertEqual(
      RemoteImageValidationPolicy.filenameExtension(
        for: .jpeg,
        suggestedFilename: "photo.png"
      ),
      "jpg"
    )
    XCTAssertNil(
      RemoteImageValidationPolicy.filenameExtension(
        for: .plainText,
        suggestedFilename: "not-an-image.txt"
      )
    )
  }

  func testValidatorSniffsActualImageInsteadOfTrustingFilename() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("payload.jpg")
    try pngData(width: 12, height: 7).write(to: fileURL)

    let validation = try RemoteImageFileValidator.validate(
      fileURL: fileURL,
      suggestedFilename: "misleading.jpeg"
    )

    XCTAssertEqual(validation.contentTypeIdentifier, UTType.png.identifier)
    XCTAssertEqual(validation.filenameExtension, "png")
    XCTAssertEqual(validation.pixelWidth, 12)
    XCTAssertEqual(validation.pixelHeight, 7)
  }

  func testValidatorRejectsNonImageData() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("payload.png")
    try Data("not an image".utf8).write(to: fileURL)

    XCTAssertThrowsError(
      try RemoteImageFileValidator.validate(
        fileURL: fileURL,
        suggestedFilename: "payload.png"
      )
    ) { error in
      XCTAssertEqual(error as? RemoteImageExportError, .invalidImage)
    }
  }

  func testValidatorChecksEveryFrameOfAnimatedGIF() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("animated.bin")
    try animatedGIFData(frameSizes: [
      CGSize(width: 12, height: 7),
      CGSize(width: 8, height: 5),
    ]).write(to: fileURL)

    let validation = try RemoteImageFileValidator.validate(
      fileURL: fileURL,
      suggestedFilename: "animated.jpg"
    )

    XCTAssertEqual(validation.contentTypeIdentifier, UTType.gif.identifier)
    XCTAssertEqual(validation.filenameExtension, "gif")
    XCTAssertEqual(validation.pixelWidth, 12)
    XCTAssertEqual(validation.pixelHeight, 7)
  }

  func testPrepareForSharingDownloadsOriginalAndKeepsLeaseUntilCompletion() async throws {
    let recorder = ExportEventRecorder()
    let downloader = RemoteImageDownloaderSpy(
      data: pngData(width: 10, height: 6),
      suggestedFilename: "../../thread\nphoto.jpg",
      recorder: recorder
    )
    let exporter = RemoteImageExporter(
      downloader: downloader,
      photoLibrary: RemoteImagePhotoLibrarySpy(
        authorization: .denied,
        requestedAuthorization: .denied,
        recorder: recorder
      )
    )
    var item: RemoteImageShareItem? = try await exporter.prepareForSharing(
      from: sourceURL
    )
    let exportedURL = try XCTUnwrap(item?.fileURL)

    XCTAssertEqual(exportedURL.pathExtension, "png")
    XCTAssertEqual(exportedURL.lastPathComponent, "thread-photo.png")
    XCTAssertEqual(item?.contentTypeIdentifier, UTType.png.identifier)
    XCTAssertEqual(item?.pixelWidth, 10)
    XCTAssertEqual(item?.pixelHeight, 6)
    XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
    let events = await recorder.snapshot()
    XCTAssertEqual(events, [.downloadOriginal])

    item = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportedURL.path))
  }

  func testDeniedPhotoPermissionPerformsNoDownload() async throws {
    let recorder = ExportEventRecorder()
    let downloader = RemoteImageDownloaderSpy(
      data: pngData(width: 2, height: 2),
      suggestedFilename: "photo.png",
      recorder: recorder
    )
    let photoLibrary = RemoteImagePhotoLibrarySpy(
      authorization: .denied,
      requestedAuthorization: .authorized,
      recorder: recorder
    )
    let exporter = RemoteImageExporter(
      downloader: downloader,
      photoLibrary: photoLibrary
    )

    do {
      try await exporter.saveToPhotos(from: sourceURL)
      XCTFail("Expected denied authorization")
    } catch {
      XCTAssertEqual(error as? RemoteImageExportError, .photoLibraryAccessDenied)
    }

    let downloadCount = await downloader.downloadCount()
    let events = await recorder.snapshot()
    XCTAssertEqual(downloadCount, 0)
    XCTAssertEqual(events, [.authorizationStatusAddOnly])
  }

  func testDeniedPhotoPermissionAfterRequestPerformsNoDownload() async throws {
    let recorder = ExportEventRecorder()
    let downloader = RemoteImageDownloaderSpy(
      data: pngData(width: 2, height: 2),
      suggestedFilename: "photo.png",
      recorder: recorder
    )
    let photoLibrary = RemoteImagePhotoLibrarySpy(
      authorization: .notDetermined,
      requestedAuthorization: .denied,
      recorder: recorder
    )
    let exporter = RemoteImageExporter(
      downloader: downloader,
      photoLibrary: photoLibrary
    )

    do {
      try await exporter.saveToPhotos(from: sourceURL)
      XCTFail("Expected denied authorization")
    } catch {
      XCTAssertEqual(error as? RemoteImageExportError, .photoLibraryAccessDenied)
    }

    let downloadCount = await downloader.downloadCount()
    let events = await recorder.snapshot()
    XCTAssertEqual(downloadCount, 0)
    XCTAssertEqual(
      events,
      [.authorizationStatusAddOnly, .requestAuthorizationAddOnly]
    )
  }

  func testPhotoSaveUsesAddOnlyBeforeDownloadAndHoldsLeaseThroughCompletion() async throws {
    let recorder = ExportEventRecorder()
    let gate = ExportAsyncGate()
    let downloader = RemoteImageDownloaderSpy(
      data: pngData(width: 20, height: 8),
      suggestedFilename: "saved-image.PNG",
      recorder: recorder
    )
    let photoLibrary = RemoteImagePhotoLibrarySpy(
      authorization: .notDetermined,
      requestedAuthorization: .authorized,
      recorder: recorder,
      saveGate: gate
    )
    let exporter = RemoteImageExporter(
      downloader: downloader,
      photoLibrary: photoLibrary
    )

    let saveTask = Task {
      try await exporter.saveToPhotos(from: sourceURL)
    }
    guard await gate.waitUntilEntered() else {
      await gate.open()
      _ = try? await saveTask.value
      XCTFail("Timed out before the photo-library save was reached")
      return
    }
    let optionalSavedURL = await photoLibrary.lastSavedURL()
    let events = await recorder.snapshot()
    guard let savedURL = optionalSavedURL else {
      await gate.open()
      _ = try? await saveTask.value
      XCTFail("Photo-library save was not reached")
      return
    }
    XCTAssertEqual(savedURL.pathExtension, "png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
    XCTAssertEqual(
      events,
      [
        .authorizationStatusAddOnly,
        .requestAuthorizationAddOnly,
        .downloadOriginal,
        .createImageAsset,
      ]
    )

    await gate.open()
    try await saveTask.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
  }

  func testExportViewModelTracksShareCompletionAndReleasesLease() async throws {
    let prepared = try makeOneShotShareExporter()
    let viewModel = RemoteImageExportViewModel(exporter: prepared.exporter)

    await viewModel.prepareForSharing(from: sourceURL)

    XCTAssertEqual(viewModel.state, .readyToShare)
    XCTAssertNotNil(viewModel.shareItem)
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))

    viewModel.finishSharing(completed: false, errorMessage: nil)

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.shareItem)
    XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))
  }

  func testExportViewModelReportsSaveSuccessAndFailure() async {
    let successfulExporter = RemoteImageExportingSpy()
    let successfulViewModel = RemoteImageExportViewModel(exporter: successfulExporter)

    await successfulViewModel.saveToPhotos(from: sourceURL)

    XCTAssertEqual(successfulViewModel.state, .savedToPhotos)
    let saveCallCount = await successfulExporter.saveCallCount()
    XCTAssertEqual(saveCallCount, 1)
    successfulViewModel.resetTransientState()
    XCTAssertEqual(successfulViewModel.state, .idle)

    let failedExporter = RemoteImageExportingSpy(
      saveError: ExportTestError(message: "photo write failed")
    )
    let failedViewModel = RemoteImageExportViewModel(exporter: failedExporter)

    await failedViewModel.saveToPhotos(from: sourceURL)

    XCTAssertEqual(failedViewModel.state, .failed("photo write failed"))
    XCTAssertEqual(failedViewModel.errorMessage, "photo write failed")
  }

  private var sourceURL: URL {
    URL(string: "https://example.com/original-image")!
  }

  private func pngData(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    )
    return renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
    }.pngData()!
  }

  private func animatedGIFData(frameSizes: [CGSize]) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.gif.identifier as CFString,
        frameSizes.count,
        nil
      )
    )
    for size in frameSizes {
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      format.opaque = true
      let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(origin: .zero, size: size))
      }
      CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), nil)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteImageExportTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeOneShotShareExporter() throws
    -> (exporter: RemoteImageExportingSpy, fileURL: URL)
  {
    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("prepared.png")
    try pngData(width: 3, height: 2).write(to: fileURL)
    let lease = RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: sourceURL,
      mimeType: "image/png",
      suggestedFilename: "prepared.png",
      byteCount: Int64((try? Data(contentsOf: fileURL).count) ?? 0)
    )
    let validation = RemoteImageValidationResult(
      contentTypeIdentifier: UTType.png.identifier,
      filenameExtension: "png",
      pixelWidth: 3,
      pixelHeight: 2
    )
    return (
      RemoteImageExportingSpy(
        shareItem: RemoteImageShareItem(
          fileURL: fileURL,
          validation: validation,
          lease: lease
        )
      ),
      fileURL
    )
  }
}

private enum ExportEvent: Equatable, Sendable {
  case authorizationStatusAddOnly
  case requestAuthorizationAddOnly
  case downloadOriginal
  case createImageAsset
}

private actor ExportEventRecorder {
  private var events: [ExportEvent] = []

  func append(_ event: ExportEvent) {
    events.append(event)
  }

  func snapshot() -> [ExportEvent] {
    events
  }
}

private actor RemoteImageDownloaderSpy: RemoteImageDownloading {
  private let data: Data
  private let suggestedFilename: String?
  private let recorder: ExportEventRecorder
  private var downloads = 0

  init(
    data: Data,
    suggestedFilename: String?,
    recorder: ExportEventRecorder
  ) {
    self.data = data
    self.suggestedFilename = suggestedFilename
    self.recorder = recorder
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease
  {
    guard networkAccess == .unrestricted else {
      throw ExportTestError(message: "expected unrestricted network access")
    }
    downloads += 1
    switch kind {
    case .original:
      await recorder.append(.downloadOriginal)
    case .preview:
      throw ExportTestError(message: "expected original download")
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteImageDownloaderSpy", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("download")
    try data.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      mimeType: "application/octet-stream",
      suggestedFilename: suggestedFilename,
      byteCount: Int64(data.count)
    )
  }

  func downloadCount() -> Int {
    downloads
  }
}

private actor RemoteImagePhotoLibrarySpy: RemoteImagePhotoLibrary {
  private let authorization: RemoteImagePhotoAuthorizationStatus
  private let requestedAuthorization: RemoteImagePhotoAuthorizationStatus
  private let recorder: ExportEventRecorder
  private let saveGate: ExportAsyncGate?
  private var savedURL: URL?

  init(
    authorization: RemoteImagePhotoAuthorizationStatus,
    requestedAuthorization: RemoteImagePhotoAuthorizationStatus,
    recorder: ExportEventRecorder,
    saveGate: ExportAsyncGate? = nil
  ) {
    self.authorization = authorization
    self.requestedAuthorization = requestedAuthorization
    self.recorder = recorder
    self.saveGate = saveGate
  }

  func authorizationStatus(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  {
    switch accessLevel {
    case .addOnly:
      await recorder.append(.authorizationStatusAddOnly)
    }
    return authorization
  }

  func requestAuthorization(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  {
    switch accessLevel {
    case .addOnly:
      await recorder.append(.requestAuthorizationAddOnly)
    }
    return requestedAuthorization
  }

  func createImageAsset(from fileURL: URL) async throws {
    savedURL = fileURL
    await recorder.append(.createImageAsset)
    if let saveGate {
      await saveGate.wait()
    }
  }

  func lastSavedURL() -> URL? {
    savedURL
  }
}

private actor ExportAsyncGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        waiter = continuation
      }
    }
  }

  func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while waiter == nil, !isOpen, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return waiter != nil || isOpen
  }

  func open() {
    isOpen = true
    waiter?.resume()
    waiter = nil
  }
}

private struct ExportTestError: LocalizedError, Equatable, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor RemoteImageExportingSpy: RemoteImageExporting {
  private var shareItem: RemoteImageShareItem?
  private let saveError: ExportTestError?
  private var saveCalls = 0

  init(
    shareItem: RemoteImageShareItem? = nil,
    saveError: ExportTestError? = nil
  ) {
    self.shareItem = shareItem
    self.saveError = saveError
  }

  func prepareForSharing(from sourceURL: URL) async throws -> RemoteImageShareItem {
    guard let shareItem else {
      throw ExportTestError(message: "missing share item")
    }
    self.shareItem = nil
    return shareItem
  }

  func saveToPhotos(from sourceURL: URL) async throws {
    saveCalls += 1
    if let saveError {
      throw saveError
    }
  }

  func saveCallCount() -> Int {
    saveCalls
  }
}
