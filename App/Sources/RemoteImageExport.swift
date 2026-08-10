import Combine
import Foundation
import ImageIO
@preconcurrency import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum RemoteImageExportError: Error, Equatable, LocalizedError {
  case invalidImage
  case invalidDimensions
  case imagePixelCountTooLarge
  case imageFrameCountTooLarge
  case unsupportedImageType
  case photoLibraryAccessDenied
  case photoLibrarySaveFailed

  var errorDescription: String? {
    switch self {
    case .invalidImage:
      "下载内容不是可读取的图片。"
    case .invalidDimensions:
      "图片尺寸无效。"
    case .imagePixelCountTooLarge:
      "图片像素过大，无法安全导出。"
    case .imageFrameCountTooLarge:
      "图片帧数过多，无法安全导出。"
    case .unsupportedImageType:
      "无法识别图片格式。"
    case .photoLibraryAccessDenied:
      "未获得向照片图库添加图片的权限。"
    case .photoLibrarySaveFailed:
      "无法将图片保存到照片图库。"
    }
  }
}

struct RemoteImageValidationResult: Equatable, Sendable {
  let contentTypeIdentifier: String
  let filenameExtension: String
  let pixelWidth: Int
  let pixelHeight: Int
}

enum RemoteImageValidationPolicy {
  static let maximumPixelCount = 100_000_000
  static let maximumPixelDimension = 32_768
  static let maximumFrameCount = 500
  static let maximumTotalPixelCount = 500_000_000

  static func acceptsDimensions(
    width: Int,
    height: Int,
    maximumPixelCount: Int = maximumPixelCount,
    maximumPixelDimension: Int = maximumPixelDimension
  ) -> Bool {
    guard
      width > 0,
      height > 0,
      maximumPixelCount > 0,
      maximumPixelDimension > 0,
      width <= maximumPixelDimension,
      height <= maximumPixelDimension
    else { return false }
    return width <= maximumPixelCount / height
  }

  static func acceptsFrameCount(
    _ frameCount: Int,
    maximumFrameCount: Int = maximumFrameCount
  ) -> Bool {
    frameCount > 0 && maximumFrameCount > 0 && frameCount <= maximumFrameCount
  }

  static func totalPixelCountByAddingFrame(
    width: Int,
    height: Int,
    to currentPixelCount: Int,
    maximumTotalPixelCount: Int = maximumTotalPixelCount
  ) -> Int? {
    guard
      currentPixelCount >= 0,
      maximumTotalPixelCount > 0,
      acceptsDimensions(width: width, height: height)
    else { return nil }
    let framePixelCount = width * height
    guard currentPixelCount <= maximumTotalPixelCount - framePixelCount else {
      return nil
    }
    return currentPixelCount + framePixelCount
  }

  static func filenameExtension(
    for contentType: UTType,
    suggestedFilename: String?
  ) -> String? {
    guard contentType.conforms(to: .image) else { return nil }
    let suggestedExtension = suggestedFilename
      .flatMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }
      .flatMap(safeFilenameExtension)

    if contentType.conforms(to: .gif) {
      return "gif"
    }
    if contentType.conforms(to: .png) {
      return "png"
    }
    if contentType.conforms(to: .jpeg) {
      if suggestedExtension == "jpeg" || suggestedExtension == "jpg" {
        return suggestedExtension
      }
      return "jpg"
    }
    if
      let suggestedExtension,
      let suggestedType = UTType(filenameExtension: suggestedExtension),
      suggestedType == contentType
        || suggestedType.conforms(to: contentType)
        || contentType.conforms(to: suggestedType)
    {
      return suggestedExtension
    }
    return contentType.preferredFilenameExtension.flatMap(safeFilenameExtension)
  }

  private static func safeFilenameExtension(_ value: String) -> String? {
    guard
      !value.isEmpty,
      value.count <= 12,
      value.unicodeScalars.allSatisfy({
        $0.value < 128 && CharacterSet.alphanumerics.contains($0)
      })
    else { return nil }
    return value.lowercased()
  }
}

enum RemoteImageFileValidator {
  static func validate(
    fileURL: URL,
    suggestedFilename: String?
  ) throws -> RemoteImageValidationResult {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
      CGImageSourceGetCount(source) > 0,
      let sourceTypeIdentifier = CGImageSourceGetType(source) as String?,
      let contentType = UTType(sourceTypeIdentifier),
      contentType.conforms(to: .image)
    else { throw RemoteImageExportError.invalidImage }
    let frameCount = CGImageSourceGetCount(source)
    guard RemoteImageValidationPolicy.acceptsFrameCount(frameCount) else {
      throw RemoteImageExportError.imageFrameCountTooLarge
    }
    guard
      let filenameExtension = RemoteImageValidationPolicy.filenameExtension(
        for: contentType,
        suggestedFilename: suggestedFilename
      )
    else { throw RemoteImageExportError.unsupportedImageType }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 32,
    ]
    var firstFrameSize: (width: Int, height: Int)?
    var totalPixelCount = 0
    for frameIndex in 0..<frameCount {
      guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil)
          as? [CFString: Any],
        let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        widthNumber.int64Value <= Int64(Int.max),
        heightNumber.int64Value <= Int64(Int.max)
      else { throw RemoteImageExportError.invalidDimensions }

      let width = Int(widthNumber.int64Value)
      let height = Int(heightNumber.int64Value)
      guard width > 0, height > 0 else {
        throw RemoteImageExportError.invalidDimensions
      }
      guard RemoteImageValidationPolicy.acceptsDimensions(width: width, height: height),
        let updatedTotal = RemoteImageValidationPolicy.totalPixelCountByAddingFrame(
          width: width,
          height: height,
          to: totalPixelCount
        )
      else { throw RemoteImageExportError.imagePixelCountTooLarge }
      totalPixelCount = updatedTotal
      if firstFrameSize == nil {
        firstFrameSize = (width, height)
      }
      guard
        CGImageSourceCreateThumbnailAtIndex(
          source,
          frameIndex,
          thumbnailOptions as CFDictionary
        ) != nil
      else { throw RemoteImageExportError.invalidImage }
    }
    guard let firstFrameSize else {
      throw RemoteImageExportError.invalidImage
    }

    return RemoteImageValidationResult(
      contentTypeIdentifier: contentType.identifier,
      filenameExtension: filenameExtension,
      pixelWidth: firstFrameSize.width,
      pixelHeight: firstFrameSize.height
    )
  }
}

enum RemoteImagePhotoAccessLevel: Equatable, Sendable {
  case addOnly
}

enum RemoteImagePhotoAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case restricted
  case denied
  case authorized
  case limited

  var permitsAddition: Bool {
    self == .authorized || self == .limited
  }
}

protocol RemoteImagePhotoLibrary: Sendable {
  func authorizationStatus(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  func requestAuthorization(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  func createImageAsset(from fileURL: URL) async throws
}

struct PhotoKitRemoteImageLibrary: RemoteImagePhotoLibrary {
  func authorizationStatus(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  {
    switch accessLevel {
    case .addOnly:
      Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }
  }

  func requestAuthorization(for accessLevel: RemoteImagePhotoAccessLevel) async
    -> RemoteImagePhotoAuthorizationStatus
  {
    switch accessLevel {
    case .addOnly:
      return await withCheckedContinuation { continuation in
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          continuation.resume(returning: Self.map(status))
        }
      }
    }
  }

  func createImageAsset(from fileURL: URL) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      PHPhotoLibrary.shared().performChanges {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileURL.lastPathComponent
        options.uniformTypeIdentifier = UTType(filenameExtension: fileURL.pathExtension)?.identifier
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(
          with: .photo,
          fileURL: fileURL,
          options: options
        )
      } completionHandler: { succeeded, error in
        if succeeded {
          continuation.resume()
        } else {
          continuation.resume(
            throwing: error ?? RemoteImageExportError.photoLibrarySaveFailed
          )
        }
      }
    }
  }

  private static func map(
    _ status: PHAuthorizationStatus
  ) -> RemoteImagePhotoAuthorizationStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorized:
      .authorized
    case .limited:
      .limited
    @unknown default:
      .denied
    }
  }
}

final class RemoteImageShareItem: Identifiable, @unchecked Sendable {
  let id = UUID()
  let fileURL: URL
  let contentTypeIdentifier: String
  let pixelWidth: Int
  let pixelHeight: Int

  private let lease: RemoteImageFileLease

  init(
    fileURL: URL,
    validation: RemoteImageValidationResult,
    lease: RemoteImageFileLease
  ) {
    self.fileURL = fileURL
    contentTypeIdentifier = validation.contentTypeIdentifier
    pixelWidth = validation.pixelWidth
    pixelHeight = validation.pixelHeight
    self.lease = lease
  }

  func holdLeaseThroughCompletion() {
    withExtendedLifetime(lease) {}
  }
}

protocol RemoteImageExporting: Sendable {
  func prepareForSharing(from sourceURL: URL) async throws -> RemoteImageShareItem
  func saveToPhotos(from sourceURL: URL) async throws
}

struct RemoteImageExporter: RemoteImageExporting, Sendable {
  static let shared = RemoteImageExporter(
    persistentCache: RemoteImageDiskCache.shared
  )

  private let downloader: any RemoteImageDownloading
  private let persistentCache: (any RemoteImagePersistentCacheProviding)?
  private let photoLibrary: any RemoteImagePhotoLibrary

  init(
    downloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport.shared,
    persistentCache: (any RemoteImagePersistentCacheProviding)? = nil,
    photoLibrary: any RemoteImagePhotoLibrary = PhotoKitRemoteImageLibrary()
  ) {
    self.downloader = downloader
    self.persistentCache = persistentCache
    self.photoLibrary = photoLibrary
  }

  func prepareForSharing(from sourceURL: URL) async throws -> RemoteImageShareItem {
    let (lease, prepared) = try await preparedDownload(from: sourceURL)
    return RemoteImageShareItem(
      fileURL: prepared.fileURL,
      validation: prepared.validation,
      lease: lease
    )
  }

  func saveToPhotos(from sourceURL: URL) async throws {
    var authorization = await photoLibrary.authorizationStatus(for: .addOnly)
    if authorization == .notDetermined {
      authorization = await photoLibrary.requestAuthorization(for: .addOnly)
    }
    guard authorization.permitsAddition else {
      throw RemoteImageExportError.photoLibraryAccessDenied
    }
    try Task.checkCancellation()

    let (lease, prepared) = try await preparedDownload(from: sourceURL)
    defer { withExtendedLifetime(lease) {} }
    try Task.checkCancellation()
    try await photoLibrary.createImageAsset(from: prepared.fileURL)
  }

  private func preparedDownload(
    from sourceURL: URL
  ) async throws -> (
    lease: RemoteImageFileLease,
    prepared: (fileURL: URL, validation: RemoteImageValidationResult)
  ) {
    let generationToken = await persistentCache?.currentGenerationToken()
    try Task.checkCancellation()

    if let persistentCache {
      let cachedLease: RemoteImageFileLease?
      do {
        cachedLease = try await persistentCache.cachedDownload(
          from: sourceURL,
          kind: .original
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        cachedLease = nil
      }
      if let cachedLease {
        do {
          let prepared = try Self.prepareFile(from: cachedLease)
          try Task.checkCancellation()
          return (cachedLease, prepared)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // A corrupt cache entry must not prevent an explicitly requested export.
        }
      }
    }

    let lease = try await downloader.download(from: sourceURL, kind: .original)
    try Task.checkCancellation()
    let prepared = try Self.prepareFile(from: lease)
    try Task.checkCancellation()

    if let persistentCache, let generationToken {
      do {
        try await persistentCache.storeValidated(
          lease,
          requestedURL: sourceURL,
          kind: .original,
          generationToken: generationToken
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Sharing and PhotoKit saves remain available if optional caching fails.
      }
    }
    try Task.checkCancellation()
    return (lease, prepared)
  }

  private static func prepareFile(
    from lease: RemoteImageFileLease
  ) throws -> (fileURL: URL, validation: RemoteImageValidationResult) {
    let validation = try RemoteImageFileValidator.validate(
      fileURL: lease.fileURL,
      suggestedFilename: lease.suggestedFilename
    )
    let currentExtension = lease.fileURL.pathExtension.lowercased()
    guard currentExtension != validation.filenameExtension else {
      return (lease.fileURL, validation)
    }

    let parentDirectory = lease.fileURL.deletingLastPathComponent()
    let baseName = safeBaseName(from: lease.suggestedFilename)
    var destination = parentDirectory
      .appendingPathComponent(baseName, isDirectory: false)
      .appendingPathExtension(validation.filenameExtension)
    if FileManager.default.fileExists(atPath: destination.path) {
      destination = parentDirectory
        .appendingPathComponent("\(baseName)-\(UUID().uuidString)", isDirectory: false)
        .appendingPathExtension(validation.filenameExtension)
    }
    try FileManager.default.copyItem(at: lease.fileURL, to: destination)
    return (destination, validation)
  }

  private static func safeBaseName(from suggestedFilename: String?) -> String {
    guard let suggestedFilename else { return "remote-image" }
    let lastComponent = URL(fileURLWithPath: suggestedFilename).lastPathComponent
    let baseName = URL(fileURLWithPath: lastComponent)
      .deletingPathExtension()
      .lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseName.isEmpty, baseName != ".", baseName != ".." else {
      return "remote-image"
    }
    let allowedCharacters = CharacterSet.alphanumerics
      .union(.whitespaces)
      .union(CharacterSet(charactersIn: "-_"))
    let sanitized = baseName.unicodeScalars.map { scalar in
      allowedCharacters.contains(scalar) ? String(scalar) : "-"
    }.joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard sanitized.unicodeScalars.contains(where: {
      CharacterSet.alphanumerics.contains($0)
    })
    else { return "remote-image" }
    return String(sanitized.prefix(80))
  }
}

@MainActor
final class RemoteImageExportViewModel: ObservableObject {
  enum State: Equatable {
    case idle
    case preparingForSharing
    case readyToShare
    case savingToPhotos
    case shared
    case savedToPhotos
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published var shareItem: RemoteImageShareItem?

  private let exporter: any RemoteImageExporting

  init(exporter: any RemoteImageExporting = RemoteImageExporter.shared) {
    self.exporter = exporter
  }

  var isBusy: Bool {
    state == .preparingForSharing || state == .savingToPhotos
  }

  var errorMessage: String? {
    guard case .failed(let message) = state else { return nil }
    return message
  }

  func prepareForSharing(from sourceURL: URL) async {
    guard !isBusy, shareItem == nil else { return }
    state = .preparingForSharing
    do {
      let item = try await exporter.prepareForSharing(from: sourceURL)
      try Task.checkCancellation()
      shareItem = item
      state = .readyToShare
    } catch is CancellationError {
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func saveToPhotos(from sourceURL: URL) async {
    guard !isBusy, shareItem == nil else { return }
    state = .savingToPhotos
    do {
      try await exporter.saveToPhotos(from: sourceURL)
      try Task.checkCancellation()
      state = .savedToPhotos
    } catch is CancellationError {
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func finishSharing(completed: Bool, errorMessage: String?) {
    guard state == .readyToShare else { return }
    shareItem?.holdLeaseThroughCompletion()
    shareItem = nil
    if let errorMessage, !errorMessage.isEmpty {
      state = .failed(errorMessage)
    } else {
      state = completed ? .shared : .idle
    }
  }

  func resetTransientState() {
    switch state {
    case .shared, .savedToPhotos, .failed:
      state = .idle
    case .idle, .preparingForSharing, .readyToShare, .savingToPhotos:
      break
    }
  }
}

struct RemoteImageActivitySheet: UIViewControllerRepresentable {
  let item: RemoteImageShareItem
  let onCompletion: @MainActor @Sendable (Bool, String?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(item: item, onCompletion: onCompletion)
  }

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [item.fileURL],
      applicationActivities: nil
    )
    let coordinator = context.coordinator
    controller.completionWithItemsHandler = { _, completed, _, error in
      let errorMessage = error?.localizedDescription
      Task { @MainActor in
        coordinator.finish(completed: completed, errorMessage: errorMessage)
      }
    }
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIActivityViewController,
    context: Context
  ) {}

  @MainActor
  final class Coordinator {
    private var item: RemoteImageShareItem?
    private let onCompletion: @MainActor @Sendable (Bool, String?) -> Void
    private var didFinish = false

    init(
      item: RemoteImageShareItem,
      onCompletion: @escaping @MainActor @Sendable (Bool, String?) -> Void
    ) {
      self.item = item
      self.onCompletion = onCompletion
    }

    func finish(completed: Bool, errorMessage: String?) {
      guard !didFinish else { return }
      didFinish = true
      let heldItem = item
      onCompletion(completed, errorMessage)
      heldItem?.holdLeaseThroughCompletion()
      item = nil
    }
  }
}
