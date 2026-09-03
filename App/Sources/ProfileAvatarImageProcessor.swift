import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProfileAvatarImageProcessingError: Error, Equatable, LocalizedError, Sendable {
  case invalidPreparedImage
  case invalidCrop
  case renderingFailed

  var errorDescription: String? {
    switch self {
    case .invalidPreparedImage:
      "无法读取已处理的头像图片。"
    case .invalidCrop:
      "头像裁剪区域无效，请重新调整。"
    case .renderingFailed:
      "无法生成裁剪后的头像。"
    }
  }
}

struct ProfileAvatarCropSource:
  Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let id: UUID
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int

  var byteCount: Int { data.count }

  init?(id: UUID = UUID(), data: Data, pixelWidth: Int, pixelHeight: Int) {
    guard
      !data.isEmpty,
      Int64(data.count) <= ComposerImageAttachmentQuality.highQuality.maximumByteCount,
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: pixelWidth,
        height: pixelHeight,
        maximumPixelSize: ComposerImageAttachmentQuality.highQuality.maximumPixelSize
      )
    else { return nil }
    self.id = id
    self.data = data
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  var description: String {
    "ProfileAvatarCropSource(id: \(id), byteCount: \(byteCount), "
      + "pixelSize: \(pixelWidth)x\(pixelHeight), data: redacted)"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "byteCount": byteCount,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
      ],
      displayStyle: .struct
    )
  }
}

struct ProfileAvatarImageProcessor: Sendable {
  static let outputSquarePixelSize = 960

  private let composerProcessor: ComposerImageAttachmentProcessor

  init(composerProcessor: ComposerImageAttachmentProcessor = .init()) {
    self.composerProcessor = composerProcessor
  }

  func prepare(fileURL: URL) async throws -> ProfileAvatarCropSource {
    let composerProcessor = composerProcessor
    return try await Self.runCancellableDetachedOperation {
      let processed = try composerProcessor.process(
        temporaryFileURL: fileURL,
        quality: .highQuality
      )
      try Task.checkCancellation()
      guard
        let source = ProfileAvatarCropSource(
          data: processed.data,
          pixelWidth: processed.pixelWidth,
          pixelHeight: processed.pixelHeight
        )
      else { throw ProfileAvatarImageProcessingError.invalidPreparedImage }
      return source
    }
  }

  func prepare(data: Data) async throws -> ProfileAvatarCropSource {
    let composerProcessor = composerProcessor
    return try await Self.runCancellableDetachedOperation {
      let processed = try composerProcessor.process(data: data, quality: .highQuality)
      try Task.checkCancellation()
      guard
        let source = ProfileAvatarCropSource(
          data: processed.data,
          pixelWidth: processed.pixelWidth,
          pixelHeight: processed.pixelHeight
        )
      else { throw ProfileAvatarImageProcessingError.invalidPreparedImage }
      return source
    }
  }

  func makeUpload(
    source: ProfileAvatarCropSource,
    state: ProfileAvatarCropState
  ) async throws -> AccountProfileAvatarUpload {
    let composerProcessor = composerProcessor
    return try await Self.runCancellableDetachedOperation {
      try Self.makeUpload(
        source: source,
        state: state,
        composerProcessor: composerProcessor
      )
    }
  }

  static func runCancellableDetachedOperation<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try operation()
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      return result
    } catch {
      task.cancel()
      try Task.checkCancellation()
      throw error
    }
  }

  private static func makeUpload(
    source: ProfileAvatarCropSource,
    state: ProfileAvatarCropState,
    composerProcessor: ComposerImageAttachmentProcessor
  ) throws -> AccountProfileAvatarUpload {
    try Task.checkCancellation()
    guard
      let validationAttachment = ComposerImageAttachment(
        id: source.id,
        sha256: sha256(source.data),
        byteCount: Int64(source.data.count),
        pixelWidth: source.pixelWidth,
        pixelHeight: source.pixelHeight,
        quality: .highQuality
      )
    else { throw ProfileAvatarImageProcessingError.invalidPreparedImage }
    try composerProcessor.validateStoredData(source.data, matching: validationAttachment)
    try Task.checkCancellation()

    guard
      let imageSource = CGImageSourceCreateWithData(
        source.data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      ),
      CGImageSourceGetCount(imageSource) == 1,
      let image = CGImageSourceCreateImageAtIndex(
        imageSource,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      ),
      image.width == source.pixelWidth,
      image.height == source.pixelHeight
    else { throw ProfileAvatarImageProcessingError.invalidPreparedImage }
    try Task.checkCancellation()

    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(
        width: CGFloat(source.pixelWidth),
        height: CGFloat(source.pixelHeight)
      ),
      viewportSide: 1
    )
    guard
      let cropRect = geometry.sourceCropRect(for: state),
      cropRect.width == cropRect.height,
      cropRect.width >= 1,
      let cropped = image.cropping(to: cropRect)
    else { throw ProfileAvatarImageProcessingError.invalidCrop }

    let rendered = try renderSquare(cropped, pixelSize: outputSquarePixelSize)
    let intermediate = try pngData(from: rendered)
    try Task.checkCancellation()
    let processed = try composerProcessor.process(
      data: intermediate,
      quality: .standard,
      maximumByteCount: Int64(AccountProfileAvatarUpload.maximumByteCount)
    )
    guard
      processed.encoding == .jpeg,
      processed.pixelWidth == outputSquarePixelSize,
      processed.pixelHeight == outputSquarePixelSize,
      let upload = AccountProfileAvatarUpload(
        jpegData: processed.data,
        pixelSize: outputSquarePixelSize
      )
    else { throw ProfileAvatarImageProcessingError.renderingFailed }
    return upload
  }

  private static func renderSquare(_ image: CGImage, pixelSize: Int) throws -> CGImage {
    guard
      pixelSize > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.noneSkipLast.rawValue
      ),
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: context.bytesPerRow,
        height: pixelSize
      )
    else { throw ProfileAvatarImageProcessingError.renderingFailed }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    guard let rendered = context.makeImage() else {
      throw ProfileAvatarImageProcessingError.renderingFailed
    }
    return rendered
  }

  private static func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else { throw ProfileAvatarImageProcessingError.renderingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ProfileAvatarImageProcessingError.renderingFailed
    }
    return data as Data
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
