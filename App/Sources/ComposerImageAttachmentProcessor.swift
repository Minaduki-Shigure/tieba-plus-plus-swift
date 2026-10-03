import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ComposerImageProcessingError: Error, Equatable, LocalizedError, Sendable {
  case invalidSource
  case sourceTooLarge
  case unsupportedFormat
  case unsupportedOriginal
  case animatedImage
  case gifRequiresOriginal
  case unsupportedGIF
  case gifResourceLimit
  case webPRequiresOriginal
  case unsupportedWebP
  case webPResourceLimit
  case invalidDimensions
  case sourcePixelCountTooLarge
  case decodedImageTooLarge
  case decodeFailed
  case encodeFailed
  case encodedImageTooLarge
  case metadataWasNotRemoved

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      "选择的文件不是可读取的普通图片文件。"
    case .sourceTooLarge:
      "选择的图片文件过大。"
    case .unsupportedFormat:
      "支持静态 JPEG、PNG、HEIC、WebP 图片；GIF 和 WebP 动图请使用原图模式。"
    case .unsupportedOriginal:
      "原图模式支持 JPEG、PNG、GIF、WebP，以及可验证的 sRGB、Display P3 色彩；HDR、特殊格式或自定义色彩请改用标准或高清模式。"
    case .animatedImage:
      "暂不支持此格式的动画或多帧图片；GIF 和 WebP 动图请使用原图模式。"
    case .gifRequiresOriginal:
      "GIF 图片请先选择原图模式，以保留动画。"
    case .unsupportedGIF:
      "这张 GIF 包含暂不支持的图像数据或扩展，无法保证原图效果。"
    case .gifResourceLimit:
      "GIF 超过安全处理限制：最多 10 MB、单边 4096 像素、500 帧和单次播放 120 秒，并受累计像素限制。"
    case .webPRequiresOriginal:
      "WebP 动图请先选择原图模式，以保留动画。"
    case .unsupportedWebP:
      "这张 WebP 包含暂不支持的图像数据、色彩或动画控制，无法保证原图效果。"
    case .webPResourceLimit:
      "WebP 超过图片处理限制；静态图最多单边 16384 像素、约 1258 万像素；动图最多单边 4096 像素、500 帧和单次播放 120 秒，并受累计像素限制。"
    case .invalidDimensions:
      "图片尺寸无效。"
    case .sourcePixelCountTooLarge:
      "图片像素过大，无法安全处理。"
    case .decodedImageTooLarge:
      "图片解码所需内存超过安全限制。"
    case .decodeFailed:
      "无法安全解码这张图片。"
    case .encodeFailed:
      "无法安全转换这张图片。"
    case .encodedImageTooLarge:
      "处理后的图片仍超过上传大小限制。"
    case .metadataWasNotRemoved:
      "无法确认图片隐私元数据已被移除。"
    }
  }
}

enum ComposerImageProcessingPolicy {
  static let maximumSourceByteCount: Int64 = 32 * 1_024 * 1_024
  static let maximumSourcePixelDimension = 16_384
  static let maximumSourceDecodedByteCount = 96 * 1_024 * 1_024
  static let estimatedPredecodeBytesPerPixel = 8
  static let maximumSourcePixelCount =
    maximumSourceDecodedByteCount / estimatedPredecodeBytesPerPixel
  static let maximumDecodedByteCount = 64 * 1_024 * 1_024
  static let maximumDecodedPixelCount =
    maximumDecodedByteCount / estimatedPredecodeBytesPerPixel

  static func acceptsSourceDimensions(width: Int, height: Int) -> Bool {
    guard
      width > 0,
      height > 0,
      width <= maximumSourcePixelDimension,
      height <= maximumSourcePixelDimension,
      width <= maximumSourcePixelCount / height
    else { return false }
    return true
  }

  static func acceptsDecodedLayout(bytesPerRow: Int, height: Int) -> Bool {
    guard bytesPerRow > 0, height > 0, bytesPerRow <= Int.max / height else {
      return false
    }
    return bytesPerRow * height <= maximumDecodedByteCount
  }

  static func acceptsOutputDimensions(
    width: Int,
    height: Int,
    maximumPixelSize: Int
  ) -> Bool {
    guard
      width > 0,
      height > 0,
      width <= maximumPixelSize,
      height <= maximumPixelSize,
      width <= maximumDecodedPixelCount / height
    else { return false }
    return true
  }

  static func thumbnailMaximumPixelSize(
    sourceWidth: Int,
    sourceHeight: Int,
    requestedMaximumPixelSize: Int
  ) -> Int? {
    guard sourceWidth > 0, sourceHeight > 0, requestedMaximumPixelSize > 0 else {
      return nil
    }
    let longestSide = max(sourceWidth, sourceHeight)
    let shortestSide = min(sourceWidth, sourceHeight)
    var lowerBound = 1
    var upperBound = min(longestSide, requestedMaximumPixelSize)
    var acceptedMaximum = 0

    while lowerBound <= upperBound {
      let candidate = lowerBound + (upperBound - lowerBound) / 2
      let (scaledProduct, overflow) = shortestSide.multipliedReportingOverflow(by: candidate)
      guard !overflow else { return nil }
      let scaledShortestSide = max(
        1,
        scaledProduct / longestSide + (scaledProduct % longestSide == 0 ? 0 : 1)
      )
      if candidate <= maximumDecodedPixelCount / scaledShortestSide {
        acceptedMaximum = candidate
        lowerBound = candidate + 1
      } else {
        upperBound = candidate - 1
      }
    }
    return acceptedMaximum > 0 ? acceptedMaximum : nil
  }
}

struct ComposerProcessedImage: Equatable, Sendable {
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int
  let encoding: ComposerImageAttachmentEncoding
  let quality: ComposerImageAttachmentQuality

  init?(
    data: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    encoding: ComposerImageAttachmentEncoding,
    quality: ComposerImageAttachmentQuality
  ) {
    guard
      !data.isEmpty,
      Int64(data.count) <= quality.maximumByteCount,
      encoding == .jpeg || quality == .original,
      encoding != .gif
        || ComposerImageAttachment.acceptsDimensions(
          width: pixelWidth,
          height: pixelHeight,
          maximumPixelSize: ComposerGIFSanitizer.maximumDimension,
          maximumPixelCount: ComposerGIFSanitizer.maximumFramePixels
        ),
      ComposerImageAttachment.acceptsDimensions(
        width: pixelWidth,
        height: pixelHeight,
        maximumPixelSize: quality.maximumPixelSize,
        maximumPixelCount: quality.maximumPixelCount
      )
    else { return nil }
    self.data = data
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.encoding = encoding
    self.quality = quality
  }
}

struct ComposerImageAttachmentProcessor: Sendable {
  private let beforeValidatedJPEGFullDecode: @Sendable () -> Void
  private let beforeValidatedGIFFrameDecode: @Sendable (Int) -> Void
  private let beforeValidatedWebPFrameDecode: @Sendable (Int) -> Void

  init(
    beforeValidatedJPEGFullDecode: @escaping @Sendable () -> Void = {},
    beforeValidatedGIFFrameDecode: @escaping @Sendable (Int) -> Void = { _ in },
    beforeValidatedWebPFrameDecode: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.beforeValidatedJPEGFullDecode = beforeValidatedJPEGFullDecode
    self.beforeValidatedGIFFrameDecode = beforeValidatedGIFFrameDecode
    self.beforeValidatedWebPFrameDecode = beforeValidatedWebPFrameDecode
  }

  func process(
    temporaryFileURL: URL,
    quality: ComposerImageAttachmentQuality
  ) throws -> ComposerProcessedImage {
    let data = try Self.boundedRegularFileData(at: temporaryFileURL)
    return try process(data: data, quality: quality)
  }

  func process(
    data: Data,
    quality: ComposerImageAttachmentQuality
  ) throws -> ComposerProcessedImage {
    try process(
      data: data,
      quality: quality,
      maximumByteCount: quality.maximumByteCount
    )
  }

  func process(
    data: Data,
    quality: ComposerImageAttachmentQuality,
    maximumByteCount: Int64
  ) throws -> ComposerProcessedImage {
    try Task.checkCancellation()
    guard maximumByteCount > 0, maximumByteCount <= quality.maximumByteCount else {
      throw ComposerImageProcessingError.encodedImageTooLarge
    }
    guard !data.isEmpty else { throw ComposerImageProcessingError.invalidSource }
    guard Int64(data.count) <= ComposerImageProcessingPolicy.maximumSourceByteCount else {
      throw ComposerImageProcessingError.sourceTooLarge
    }
    if Self.hasGIFSignature(data) {
      guard quality == .original else {
        throw ComposerImageProcessingError.gifRequiresOriginal
      }
      let inspection = try Self.sanitizedGIF(data)
      guard Int64(inspection.data.count) <= maximumByteCount else {
        throw ComposerImageProcessingError.encodedImageTooLarge
      }
      try validateGIFFrames(inspection)
      guard
        let result = ComposerProcessedImage(
          data: inspection.data,
          pixelWidth: inspection.width,
          pixelHeight: inspection.height,
          encoding: .gif,
          quality: .original
        )
      else { throw ComposerImageProcessingError.invalidDimensions }
      return result
    }
    let inspectionData: Data
    if Self.hasWebPSignature(data) {
      // Validate canvas/frame limits before ImageIO sees any WebP bytes. Quality
      // modes may convert a custom color space, while originals require a
      // recognized canonical profile because their codec payload is preserved.
      let inspection = try Self.sanitizedWebP(data, original: quality == .original)
      guard !inspection.isAnimated || quality == .original else {
        throw ComposerImageProcessingError.webPRequiresOriginal
      }
      if quality == .original {
        guard Int64(inspection.data.count) <= maximumByteCount else {
          throw ComposerImageProcessingError.encodedImageTooLarge
        }
        try validateWebPFrames(inspection)
        guard let result = ComposerProcessedImage(
          data: inspection.data, pixelWidth: inspection.width, pixelHeight: inspection.height,
          encoding: .webp, quality: .original
        ) else { throw ComposerImageProcessingError.invalidDimensions }
        return result
      }
      inspectionData = inspection.data
    } else {
      inspectionData = quality == .original
        ? try ComposerOriginalImageSanitizer.preflight(data) : data
    }
    guard
      let source = CGImageSourceCreateWithData(
        inspectionData as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else {
      throw ComposerImageProcessingError.invalidSource
    }

    let inspection = try Self.inspectSource(source, requiresStrippedMetadata: false)
    guard
      ComposerImageProcessingPolicy.acceptsSourceDimensions(
        width: inspection.width,
        height: inspection.height
      )
    else {
      throw ComposerImageProcessingError.sourcePixelCountTooLarge
    }
    if quality == .original {
      return try processOriginal(
        data: data,
        source: source,
        inspection: inspection,
        maximumByteCount: maximumByteCount
      )
    }
    guard
      let thumbnailMaximumPixelSize =
        ComposerImageProcessingPolicy.thumbnailMaximumPixelSize(
          sourceWidth: inspection.width,
          sourceHeight: inspection.height,
          requestedMaximumPixelSize: quality.maximumPixelSize
        )
    else { throw ComposerImageProcessingError.decodedImageTooLarge }
    try Task.checkCancellation()

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize,
    ]
    guard
      let decoded = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        thumbnailOptions as CFDictionary
      )
    else {
      throw ComposerImageProcessingError.decodeFailed
    }
    guard
      decoded.width > 0,
      decoded.height > 0,
      decoded.width <= quality.maximumPixelSize,
      decoded.height <= quality.maximumPixelSize,
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: decoded.bytesPerRow,
        height: decoded.height
      )
    else {
      throw ComposerImageProcessingError.decodedImageTooLarge
    }
    try Task.checkCancellation()

    let controlledImage = try Self.renderControlledSRGBImage(
      decoded,
      width: decoded.width,
      height: decoded.height
    )
    let encoded = try Self.encodeWithinLimit(
      controlledImage,
      quality: quality,
      maximumByteCount: maximumByteCount
    )
    let encodedInspection = try inspectEncodedJPEG(
      encoded.data,
      expectedWidth: encoded.image.width,
      expectedHeight: encoded.image.height,
      quality: quality
    )
    guard
      let result = ComposerProcessedImage(
        data: encoded.data,
        pixelWidth: encodedInspection.width,
        pixelHeight: encodedInspection.height,
        encoding: .jpeg,
        quality: quality
      )
    else { throw ComposerImageProcessingError.encodedImageTooLarge }
    guard Int64(result.data.count) <= maximumByteCount else {
      throw ComposerImageProcessingError.encodedImageTooLarge
    }
    return result
  }

  func validateStoredData(
    _ data: Data,
    matching attachment: ComposerImageAttachment
  ) throws {
    try Task.checkCancellation()
    guard
      !data.isEmpty,
      Int64(data.count) == attachment.byteCount,
      Int64(data.count) <= attachment.quality.maximumByteCount
    else { throw ComposerImageProcessingError.invalidSource }
    if attachment.encoding == .gif || Self.hasGIFSignature(data) {
      guard attachment.encoding == .gif, attachment.quality == .original else {
        throw ComposerImageProcessingError.invalidSource
      }
      let inspection = try Self.sanitizedGIF(data)
      guard inspection.data == data else {
        throw ComposerImageProcessingError.metadataWasNotRemoved
      }
      guard inspection.width == attachment.pixelWidth,
        inspection.height == attachment.pixelHeight
      else { throw ComposerImageProcessingError.invalidDimensions }
      try validateGIFFrames(inspection)
      return
    }
    if attachment.encoding == .webp || Self.hasWebPSignature(data) {
      guard attachment.encoding == .webp, attachment.quality == .original else {
        throw ComposerImageProcessingError.invalidSource
      }
      let inspection = try Self.sanitizedWebP(data, original: true)
      guard inspection.data == data else {
        throw ComposerImageProcessingError.metadataWasNotRemoved
      }
      guard inspection.width == attachment.pixelWidth,
        inspection.height == attachment.pixelHeight
      else { throw ComposerImageProcessingError.invalidDimensions }
      try validateWebPFrames(inspection)
      return
    }
    if attachment.quality == .original {
      _ = try inspectOriginal(
        data,
        expectedWidth: attachment.pixelWidth,
        expectedHeight: attachment.pixelHeight,
        expectedEncoding: attachment.encoding
      )
      return
    }
    guard attachment.encoding == .jpeg else {
      throw ComposerImageProcessingError.invalidSource
    }
    _ = try inspectEncodedJPEG(
      data,
      expectedWidth: attachment.pixelWidth,
      expectedHeight: attachment.pixelHeight,
      quality: attachment.quality
    )
  }

  private struct SourceInspection {
    let width: Int
    let height: Int
  }

  private struct EncodedCandidate {
    let data: Data
    let image: CGImage
  }

  private static func hasGIFSignature(_ data: Data) -> Bool {
    // Route even unsupported GIF versions through the bounded container parser.
    // ImageIO must never inspect an unvalidated GIF container on this path.
    data.starts(with: [0x47, 0x49, 0x46])
  }

  private static func sanitizedGIF(_ data: Data) throws -> ComposerGIFSanitizer.Inspection {
    do {
      return try ComposerGIFSanitizer.sanitize(data)
    } catch let error as ComposerGIFSanitizerError {
      switch error {
      case .invalidGIF: throw ComposerImageProcessingError.invalidSource
      case .unsupportedGIF: throw ComposerImageProcessingError.unsupportedGIF
      case .resourceLimit: throw ComposerImageProcessingError.gifResourceLimit
      }
    }
  }

  private static func hasWebPSignature(_ data: Data) -> Bool {
    data.starts(with: Data("RIFF".utf8))
      || (data.count >= 12 && data.dropFirst(8).starts(with: Data("WEBP".utf8)))
  }

  private static func sanitizedWebP(
    _ data: Data, original: Bool
  ) throws -> ComposerWebPSanitizer.Inspection {
    do {
      return try ComposerWebPSanitizer.sanitize(data) { profile in
        if original { return try canonicalOriginalColorProfile(profile) }
        return profile
      }
    } catch let error as ComposerWebPSanitizerError {
      switch error {
      case .invalidWebP: throw ComposerImageProcessingError.invalidSource
      case .unsupportedWebP: throw ComposerImageProcessingError.unsupportedWebP
      case .resourceLimit: throw ComposerImageProcessingError.webPResourceLimit
      }
    }
  }

  private func validateWebPFrames(_ inspection: ComposerWebPSanitizer.Inspection) throws {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(
      inspection.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) as String? == UTType.webP.identifier,
      CGImageSourceGetCount(source) == inspection.frameCount,
      CGImageSourceGetStatus(source) == .statusComplete
    else { throw ComposerImageProcessingError.decodeFailed }

    let maximumFrameDecodedBytes = inspection.isAnimated
      ? ComposerWebPSanitizer.maximumAnimatedPixels * 8
      : ComposerImageProcessingPolicy.maximumSourceDecodedByteCount
    for index in 0..<inspection.frameCount {
      try Task.checkCancellation()
      beforeValidatedWebPFrameDecode(index)
      try Task.checkCancellation()
      if inspection.isAnimated {
        // An animation decoder can report a composed canvas as complete even
        // when a frame's bitstream is invalid. Decode the ANMF codec payload as
        // an independent still image first, without animation composition.
        // Construct and release only one frame at a time.
        try autoreleasepool {
          let frame = try inspection.standaloneFrame(at: index)
          try Self.validateStandaloneWebPFrame(
            frame, maximumDecodedBytes: maximumFrameDecodedBytes)
        }
      }
      try Task.checkCancellation()
      // Also validate the original composed representation, preserving its
      // canvas, frame rectangles, timing, blending, disposal and color profile.
      try autoreleasepool {
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        guard let decoded = CGImageSourceCreateImageAtIndex(
          source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
          CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
          decoded.width > 0, decoded.width <= inspection.width,
          decoded.height > 0, decoded.height <= inspection.height,
          inspection.isAnimated
            || (decoded.width == inspection.width && decoded.height == inspection.height),
          decoded.bitsPerComponent > 0, decoded.bitsPerComponent <= 8,
          decoded.bytesPerRow > 0,
          decoded.bytesPerRow <= maximumFrameDecodedBytes / decoded.height,
          Self.hasSupportedOriginalColorModel(decoded.colorSpace)
        else { throw ComposerImageProcessingError.decodeFailed }
      }
    }
    try Task.checkCancellation()
  }

  private static func validateStandaloneWebPFrame(
    _ frame: ComposerWebPSanitizer.FrameImage, maximumDecodedBytes: Int
  ) throws {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(
      frame.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) as String? == UTType.webP.identifier,
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatus(source) == .statusComplete
    else { throw ComposerImageProcessingError.decodeFailed }
    defer { CGImageSourceRemoveCacheAtIndex(source, 0) }
    guard let decoded = CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      decoded.width == frame.width, decoded.height == frame.height,
      decoded.bitsPerComponent > 0, decoded.bitsPerComponent <= 8,
      decoded.bytesPerRow > 0, decoded.height > 0,
      decoded.bytesPerRow <= maximumDecodedBytes / decoded.height,
      hasSupportedOriginalColorModel(decoded.colorSpace)
    else { throw ComposerImageProcessingError.decodeFailed }
    try Task.checkCancellation()
  }

  private func validateGIFFrames(_ inspection: ComposerGIFSanitizer.Inspection) throws {
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithData(
        inspection.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
      ),
      CGImageSourceGetType(source) as String? == UTType.gif.identifier,
      CGImageSourceGetCount(source) == inspection.frameCount,
      CGImageSourceGetStatus(source) == .statusComplete
    else { throw ComposerImageProcessingError.decodeFailed }

    let maximumFrameDecodedBytes = ComposerGIFSanitizer.maximumFramePixels * 8
    for index in 0..<inspection.frameCount {
      try Task.checkCancellation()
      // Release each decoded frame before advancing; retaining the full animation
      // would multiply the canvas allocation by the number of frames.
      try autoreleasepool {
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        beforeValidatedGIFFrameDecode(index)
        try Task.checkCancellation()
        guard
          let decoded = CGImageSourceCreateImageAtIndex(
            source, index,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
          ),
          CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
          decoded.width > 0, decoded.width <= inspection.width,
          decoded.height > 0, decoded.height <= inspection.height,
          decoded.bitsPerComponent > 0, decoded.bitsPerComponent <= 8,
          decoded.bytesPerRow > 0,
          decoded.bytesPerRow <= maximumFrameDecodedBytes / decoded.height,
          Self.hasSupportedOriginalColorModel(decoded.colorSpace)
        else { throw ComposerImageProcessingError.decodeFailed }
      }
    }
    try Task.checkCancellation()
  }

  private func processOriginal(
    data: Data,
    source: CGImageSource,
    inspection: SourceInspection,
    maximumByteCount: Int64
  ) throws -> ComposerProcessedImage {
    let encoding = try Self.originalEncoding(source)
    let sanitized = try Self.sanitizeOriginal(data, source: source, encoding: encoding)
    guard Int64(sanitized.count) <= maximumByteCount else {
      // Unlike the JPEG quality modes, never downscale or recompress this path.
      throw ComposerImageProcessingError.encodedImageTooLarge
    }
    _ = try inspectOriginal(
      sanitized,
      expectedWidth: inspection.width,
      expectedHeight: inspection.height,
      expectedEncoding: encoding
    )
    guard
      let result = ComposerProcessedImage(
        data: sanitized,
        pixelWidth: inspection.width,
        pixelHeight: inspection.height,
        encoding: encoding,
        quality: .original
      )
    else { throw ComposerImageProcessingError.invalidDimensions }
    return result
  }

  private static func originalEncoding(
    _ source: CGImageSource
  ) throws -> ComposerImageAttachmentEncoding {
    switch CGImageSourceGetType(source) as String? {
    case UTType.jpeg.identifier: return .jpeg
    case UTType.png.identifier: return .png
    default: throw ComposerImageProcessingError.unsupportedOriginal
    }
  }

  private static func sanitizeOriginal(
    _ data: Data,
    source: CGImageSource,
    encoding: ComposerImageAttachmentEncoding
  ) throws -> Data {
    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
      as? [CFString: Any] ?? [:]
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw ComposerImageProcessingError.unsupportedOriginal
    }
    // MPF/APNG/HDR container markers are also checked before bytes are copied.
    // ImageIO exposes Apple's auxiliary gain map independently of frame count.
    guard
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
      ) == nil
    else { throw ComposerImageProcessingError.unsupportedOriginal }
    return try ComposerOriginalImageSanitizer.sanitize(
      data,
      encoding: encoding,
      orientation: orientation,
      canonicalColorProfile: canonicalOriginalColorProfile
    )
  }

  static func canonicalOriginalColorProfile(_ originalProfile: Data) throws -> Data {
    // Validate the actual embedded profile, not ImageIO's decoded image space:
    // a decoder may ignore damaged ICC and fall back to sRGB. Named color
    // spaces and ICC-based instances need not compare equal, even when the
    // latter was created from the former's own copyICCData(). Compare matching
    // representations; never use the untrusted profile's display name.
    guard originalProfile.count <= 256 * 1_024,
      let colorSpace = CGColorSpace(iccData: originalProfile as CFData)
    else { throw ComposerImageProcessingError.unsupportedOriginal }
    for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
      guard let canonical = CGColorSpace(name: name),
        let profile = canonical.copyICCData()
      else { continue }
      if originalProfile == profile as Data {
        return profile as Data
      }
      if let reference = CGColorSpace(iccData: profile), CFEqual(colorSpace, reference) {
        return profile as Data
      }
    }
    throw ComposerImageProcessingError.unsupportedOriginal
  }

  private func inspectOriginal(
    _ data: Data,
    expectedWidth: Int,
    expectedHeight: Int,
    expectedEncoding: ComposerImageAttachmentEncoding
  ) throws -> SourceInspection {
    try Task.checkCancellation()
    let inspectionData = try ComposerOriginalImageSanitizer.preflight(data)
    guard inspectionData == data else {
      throw ComposerImageProcessingError.metadataWasNotRemoved
    }
    guard
      Int64(data.count) <= ComposerImageAttachmentQuality.original.maximumByteCount,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else { throw ComposerImageProcessingError.invalidSource }
    let inspection = try Self.inspectSource(source, requiresStrippedMetadata: false)
    guard
      inspection.width == expectedWidth,
      inspection.height == expectedHeight,
      try Self.originalEncoding(source) == expectedEncoding,
      ComposerImageProcessingPolicy.acceptsSourceDimensions(
        width: inspection.width, height: inspection.height
      )
    else { throw ComposerImageProcessingError.invalidDimensions }
    // Canonical re-sanitization is also the stored-file privacy check. It allows
    // only the synthesized orientation and system color profile, not arbitrary
    // EXIF/XMP/private PNG chunks even if the attachment digest was recomputed.
    guard try Self.sanitizeOriginal(data, source: source, encoding: expectedEncoding) == data else {
      throw ComposerImageProcessingError.metadataWasNotRemoved
    }
    beforeValidatedJPEGFullDecode()
    try Task.checkCancellation()
    guard
      let decoded = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      ),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      decoded.width == inspection.width,
      decoded.height == inspection.height,
      decoded.bitsPerComponent <= 8,
      decoded.bytesPerRow > 0,
      decoded.bytesPerRow <= ComposerImageProcessingPolicy.maximumSourceDecodedByteCount
        / inspection.height,
      Self.hasSupportedOriginalColorModel(decoded.colorSpace)
    else { throw ComposerImageProcessingError.decodeFailed }
    try Task.checkCancellation()
    return inspection
  }

  private static func hasSupportedOriginalColorModel(_ colorSpace: CGColorSpace?) -> Bool {
    guard let colorSpace else { return false }
    switch colorSpace.model {
    case .rgb, .monochrome: return true
    case .indexed: return colorSpace.baseColorSpace?.model == .rgb
    default: return false
    }
  }

  private static func inspectSource(
    _ source: CGImageSource,
    requiresStrippedMetadata: Bool
  ) throws -> SourceInspection {
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else { throw ComposerImageProcessingError.invalidSource }
    guard frameCount == 1 else { throw ComposerImageProcessingError.animatedImage }
    guard
      let typeIdentifier = CGImageSourceGetType(source) as String?,
      let contentType = UTType(typeIdentifier),
      isSupportedSourceType(contentType)
    else { throw ComposerImageProcessingError.unsupportedFormat }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      widthNumber.int64Value > 0,
      heightNumber.int64Value > 0,
      widthNumber.int64Value <= Int64(Int.max),
      heightNumber.int64Value <= Int64(Int.max)
    else { throw ComposerImageProcessingError.invalidDimensions }
    if requiresStrippedMetadata {
      let containerProperties =
        CGImageSourceCopyProperties(source, nil)
        as? [CFString: Any] ?? [:]
      guard
        !containsPrivateMetadata(containerProperties),
        !containsPrivateMetadata(properties)
      else { throw ComposerImageProcessingError.metadataWasNotRemoved }
    }
    return SourceInspection(
      width: Int(widthNumber.int64Value),
      height: Int(heightNumber.int64Value)
    )
  }

  private func inspectEncodedJPEG(
    _ data: Data,
    expectedWidth: Int,
    expectedHeight: Int,
    quality: ComposerImageAttachmentQuality
  ) throws -> SourceInspection {
    let markerInspection = try Self.inspectJPEGMarkers(data)
    guard
      markerInspection.width == expectedWidth,
      markerInspection.height == expectedHeight
    else { throw ComposerImageProcessingError.invalidDimensions }
    guard
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: markerInspection.width,
        height: markerInspection.height,
        maximumPixelSize: quality.maximumPixelSize
      )
    else { throw ComposerImageProcessingError.decodedImageTooLarge }

    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else { throw ComposerImageProcessingError.encodeFailed }
    let inspection = try Self.inspectSource(source, requiresStrippedMetadata: true)
    guard
      let typeIdentifier = CGImageSourceGetType(source) as String?,
      let contentType = UTType(typeIdentifier),
      contentType.conforms(to: .jpeg),
      inspection.width == markerInspection.width,
      inspection.height == markerInspection.height
    else { throw ComposerImageProcessingError.invalidDimensions }
    if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
      let tags = CGImageMetadataCopyTags(metadata),
      CFArrayGetCount(tags) > 0
    {
      throw ComposerImageProcessingError.metadataWasNotRemoved
    }

    beforeValidatedJPEGFullDecode()
    try Task.checkCancellation()
    guard
      let decoded = CGImageSourceCreateImageAtIndex(
        source,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      ),
      decoded.width == inspection.width,
      decoded.height == inspection.height,
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: decoded.bytesPerRow,
        height: decoded.height
      ),
      decoded.bitsPerComponent == 8
    else { throw ComposerImageProcessingError.decodeFailed }
    try Task.checkCancellation()
    return inspection
  }

  private static func isSupportedSourceType(_ type: UTType) -> Bool {
    let identifier = type.identifier
    return identifier == UTType.jpeg.identifier
      || identifier == UTType.png.identifier
      || identifier == UTType.heic.identifier
      || identifier == UTType.heif.identifier
      || identifier == UTType.webP.identifier
      || identifier == "public.heif-standard"
  }

  private static func containsPrivateMetadata(_ properties: [CFString: Any]) -> Bool {
    for (key, value) in properties {
      let normalizedKey = (key as String).lowercased()
      let prohibitedKeyFragments = [
        "8bim", "ciff", "comment", "dng", "exif", "gps", "iptc",
        "maker", "photoshop", "raw", "tiff", "xmp",
      ]
      if prohibitedKeyFragments.contains(where: { normalizedKey.contains($0) }) {
        return true
      }
      if let nested = value as? [CFString: Any], containsPrivateMetadata(nested) {
        return true
      }
      if let nested = value as? [String: Any] {
        let bridged = Dictionary(
          uniqueKeysWithValues: nested.map {
            ($0.key as CFString, $0.value)
          })
        if containsPrivateMetadata(bridged) {
          return true
        }
      }
    }
    return false
  }

  private struct JPEGMarkerInspection {
    let width: Int
    let height: Int
  }

  private static func inspectJPEGMarkers(_ data: Data) throws -> JPEGMarkerInspection {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
      throw ComposerImageProcessingError.encodeFailed
    }
    var index = 2
    var dimensions: (width: Int, height: Int)?
    var sawScan = false

    while index < bytes.count {
      guard bytes[index] == 0xFF else {
        throw ComposerImageProcessingError.encodeFailed
      }
      while index < bytes.count, bytes[index] == 0xFF {
        index += 1
      }
      guard index < bytes.count else {
        throw ComposerImageProcessingError.encodeFailed
      }
      let marker = bytes[index]
      index += 1

      if marker == 0xD9 {
        guard index == bytes.count, sawScan, let dimensions else {
          throw ComposerImageProcessingError.encodeFailed
        }
        return JPEGMarkerInspection(width: dimensions.width, height: dimensions.height)
      }
      if marker == 0x00 || marker == 0xD8 || marker == 0x01
        || (0xD0...0xD7).contains(marker)
      {
        throw ComposerImageProcessingError.encodeFailed
      }
      guard index + 1 < bytes.count else {
        throw ComposerImageProcessingError.encodeFailed
      }
      let segmentLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      guard segmentLength >= 2, index <= bytes.count - segmentLength else {
        throw ComposerImageProcessingError.encodeFailed
      }
      let payloadStart = index + 2
      let segmentEnd = index + segmentLength

      switch marker {
      case 0xE0:
        guard isStandardJFIFPayload(bytes[payloadStart..<segmentEnd]) else {
          throw ComposerImageProcessingError.metadataWasNotRemoved
        }
      case 0xE1...0xEF, 0xFE:
        // Fresh output is stricter than the wire format: ICC, XMP, Photoshop,
        // comments, and every other application segment are removed.
        throw ComposerImageProcessingError.metadataWasNotRemoved
      case 0xC0, 0xC1, 0xC2:
        guard
          dimensions == nil,
          segmentEnd - payloadStart >= 6,
          bytes[payloadStart] == 8
        else { throw ComposerImageProcessingError.encodeFailed }
        let height = Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2])
        let width = Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4])
        let componentCount = Int(bytes[payloadStart + 5])
        guard
          width > 0,
          height > 0,
          componentCount == 3,
          segmentEnd - payloadStart == 6 + componentCount * 3
        else { throw ComposerImageProcessingError.invalidDimensions }
        dimensions = (width, height)
      case 0xC4, 0xDB, 0xDD:
        break
      case 0xDA:
        guard dimensions != nil else {
          throw ComposerImageProcessingError.encodeFailed
        }
        sawScan = true
      default:
        throw ComposerImageProcessingError.encodeFailed
      }

      index = segmentEnd
      if marker == 0xDA {
        index = try nextJPEGMarkerOffset(in: bytes, afterScanHeader: index)
      }
    }
    throw ComposerImageProcessingError.encodeFailed
  }

  private static func nextJPEGMarkerOffset(
    in bytes: [UInt8],
    afterScanHeader start: Int
  ) throws -> Int {
    var index = start
    while index < bytes.count {
      guard bytes[index] == 0xFF else {
        index += 1
        continue
      }
      let markerOffset = index
      while index < bytes.count, bytes[index] == 0xFF {
        index += 1
      }
      guard index < bytes.count else {
        throw ComposerImageProcessingError.encodeFailed
      }
      let marker = bytes[index]
      if marker == 0x00 || (0xD0...0xD7).contains(marker) {
        index += 1
        continue
      }
      return markerOffset
    }
    throw ComposerImageProcessingError.encodeFailed
  }

  private static func isStandardJFIFPayload(_ payload: ArraySlice<UInt8>) -> Bool {
    let bytes = Array(payload)
    guard
      bytes.count >= 14,
      Array(bytes[0..<5]) == [0x4A, 0x46, 0x49, 0x46, 0x00],
      bytes[5] == 1
    else { return false }
    let thumbnailByteCount = Int(bytes[12]) * Int(bytes[13]) * 3
    return bytes.count == 14 + thumbnailByteCount
  }

  private static func strippingJPEGMetadata(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var output: [UInt8] = [0xFF, 0xD8]
    output.reserveCapacity(bytes.count)
    var index = 2

    while index < bytes.count {
      let markerOffset = index
      guard bytes[index] == 0xFF else { return nil }
      while index < bytes.count, bytes[index] == 0xFF {
        index += 1
      }
      guard index < bytes.count else { return nil }
      let marker = bytes[index]
      index += 1
      if marker == 0xD9 {
        guard index == bytes.count else { return nil }
        output.append(contentsOf: [0xFF, 0xD9])
        return Data(output)
      }
      guard
        marker != 0x00,
        marker != 0xD8,
        marker != 0x01,
        !(0xD0...0xD7).contains(marker),
        index + 1 < bytes.count
      else { return nil }
      let segmentLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      guard segmentLength >= 2, index <= bytes.count - segmentLength else { return nil }
      let payloadStart = index + 2
      let segmentEnd = index + segmentLength

      let isApplicationSegment = (0xE0...0xEF).contains(marker)
      let retainSegment =
        !isApplicationSegment && marker != 0xFE
        || marker == 0xE0 && isStandardJFIFPayload(bytes[payloadStart..<segmentEnd])
      if retainSegment {
        output.append(contentsOf: bytes[markerOffset..<segmentEnd])
      }
      index = segmentEnd

      if marker == 0xDA {
        guard
          let nextMarker = try? nextJPEGMarkerOffset(
            in: bytes,
            afterScanHeader: index
          )
        else { return nil }
        output.append(contentsOf: bytes[index..<nextMarker])
        index = nextMarker
      }
    }
    return nil
  }

  private static func encodeWithinLimit(
    _ sourceImage: CGImage,
    quality: ComposerImageAttachmentQuality,
    maximumByteCount: Int64
  ) throws -> EncodedCandidate {
    let compressionQualities: [Double] =
      switch quality {
      case .standard:
        [0.90, 0.82, 0.72, 0.60, 0.48, 0.36]
      case .highQuality:
        [0.95, 0.88, 0.80, 0.70, 0.58, 0.46, 0.34]
      case .original:
        []  // The original branch never invokes a lossy encoder.
      }
    var image = sourceImage

    for _ in 0..<4 {
      var smallestEncodedByteCount = Int.max
      for compressionQuality in compressionQualities {
        try Task.checkCancellation()
        guard let data = jpegData(from: image, compressionQuality: compressionQuality) else {
          throw ComposerImageProcessingError.encodeFailed
        }
        smallestEncodedByteCount = min(smallestEncodedByteCount, data.count)
        if Int64(data.count) <= maximumByteCount {
          return EncodedCandidate(data: data, image: image)
        }
      }

      guard smallestEncodedByteCount > 0 else {
        throw ComposerImageProcessingError.encodeFailed
      }
      let targetRatio = min(
        0.85,
        max(
          0.50,
          (Double(maximumByteCount) / Double(smallestEncodedByteCount)).squareRoot()
            * 0.90
        )
      )
      let targetWidth = max(1, Int((Double(image.width) * targetRatio).rounded(.down)))
      let targetHeight = max(1, Int((Double(image.height) * targetRatio).rounded(.down)))
      guard targetWidth < image.width || targetHeight < image.height else { break }
      image = try renderControlledSRGBImage(
        image,
        width: targetWidth,
        height: targetHeight
      )
    }
    throw ComposerImageProcessingError.encodedImageTooLarge
  }

  private static func jpegData(
    from image: CGImage,
    compressionQuality: Double
  ) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else { return nil }
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: compressionQuality
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return strippingJPEGMetadata(data as Data)
  }

  private static func renderControlledSRGBImage(
    _ image: CGImage,
    width: Int,
    height: Int
  ) throws -> CGImage {
    guard
      width > 0,
      height > 0,
      width <= ComposerImageProcessingPolicy.maximumDecodedPixelCount / height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { throw ComposerImageProcessingError.decodedImageTooLarge }
    guard
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: context.bytesPerRow,
        height: height
      )
    else { throw ComposerImageProcessingError.decodedImageTooLarge }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(
      CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )
    guard let resized = context.makeImage() else {
      throw ComposerImageProcessingError.encodeFailed
    }
    guard
      resized.bitsPerComponent == 8,
      resized.alphaInfo == .noneSkipLast
    else { throw ComposerImageProcessingError.encodeFailed }
    return resized
  }

  private static func boundedRegularFileData(at url: URL) throws -> Data {
    do {
      return try ComposerSecureRegularFileReader.read(
        from: url,
        expectedByteCount: nil,
        maximumByteCount: ComposerImageProcessingPolicy.maximumSourceByteCount,
        checksCancellation: true
      )
    } catch ComposerSecureRegularFileReadError.fileTooLarge {
      throw ComposerImageProcessingError.sourceTooLarge
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerImageProcessingError.invalidSource
    }
  }
}

enum ComposerSecureRegularFileReadError: Error, Sendable {
  case invalidFile
  case fileTooLarge
  case sizeMismatch
}

enum ComposerSecureRegularFileReader {
  static func read(
    from url: URL,
    expectedByteCount: Int64?,
    maximumByteCount: Int64,
    checksCancellation: Bool
  ) throws -> Data {
    guard url.isFileURL, maximumByteCount > 0 else {
      throw ComposerSecureRegularFileReadError.invalidFile
    }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(
        path,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
      )
    }
    guard descriptor >= 0 else {
      throw ComposerSecureRegularFileReadError.invalidFile
    }
    defer { _ = Darwin.close(descriptor) }

    var initialStatus = stat()
    guard
      Darwin.fstat(descriptor, &initialStatus) == 0,
      (initialStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      initialStatus.st_size > 0
    else { throw ComposerSecureRegularFileReadError.invalidFile }
    let initialByteCount = Int64(initialStatus.st_size)
    if initialByteCount > maximumByteCount {
      throw ComposerSecureRegularFileReadError.fileTooLarge
    }
    if let expectedByteCount, initialByteCount != expectedByteCount {
      throw ComposerSecureRegularFileReadError.sizeMismatch
    }
    guard initialByteCount <= Int64(Int.max) else {
      throw ComposerSecureRegularFileReadError.fileTooLarge
    }

    var result = Data()
    result.reserveCapacity(Int(initialByteCount))
    var remaining = initialByteCount
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while remaining > 0 {
      if checksCancellation {
        try Task.checkCancellation()
      }
      let requestedCount = min(buffer.count, Int(remaining))
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
      }
      if bytesRead < 0, errno == EINTR {
        continue
      }
      guard bytesRead > 0, Int64(bytesRead) <= remaining else {
        throw ComposerSecureRegularFileReadError.sizeMismatch
      }
      result.append(contentsOf: buffer.prefix(bytesRead))
      remaining -= Int64(bytesRead)
    }

    var trailingByte: UInt8 = 0
    let trailingCount = withUnsafeMutablePointer(to: &trailingByte) {
      Darwin.read(descriptor, $0, 1)
    }
    guard trailingCount == 0 else {
      throw ComposerSecureRegularFileReadError.sizeMismatch
    }

    var finalStatus = stat()
    guard
      Darwin.fstat(descriptor, &finalStatus) == 0,
      (finalStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      finalStatus.st_dev == initialStatus.st_dev,
      finalStatus.st_ino == initialStatus.st_ino,
      finalStatus.st_size == initialStatus.st_size,
      Int64(result.count) == initialByteCount
    else { throw ComposerSecureRegularFileReadError.sizeMismatch }
    return result
  }
}
