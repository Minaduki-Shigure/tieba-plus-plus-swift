import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ComposerImageProcessingError: Error, Equatable, LocalizedError, Sendable {
  case invalidSource
  case sourceTooLarge
  case unsupportedFormat
  case animatedImage
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
      "仅支持静态 JPEG、PNG 或 HEIC 图片。"
    case .animatedImage:
      "暂不支持动画或多帧图片。"
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
      ComposerImageAttachment.acceptsDimensions(
        width: pixelWidth,
        height: pixelHeight,
        maximumPixelSize: quality.maximumPixelSize
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

  init(
    beforeValidatedJPEGFullDecode: @escaping @Sendable () -> Void = {}
  ) {
    self.beforeValidatedJPEGFullDecode = beforeValidatedJPEGFullDecode
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
    try Task.checkCancellation()
    guard !data.isEmpty else { throw ComposerImageProcessingError.invalidSource }
    guard Int64(data.count) <= ComposerImageProcessingPolicy.maximumSourceByteCount else {
      throw ComposerImageProcessingError.sourceTooLarge
    }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
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
    let encoded = try Self.encodeWithinLimit(controlledImage, quality: quality)
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
    return result
  }

  func validateStoredData(
    _ data: Data,
    matching attachment: ComposerImageAttachment
  ) throws {
    guard
      !data.isEmpty,
      Int64(data.count) == attachment.byteCount,
      Int64(data.count) <= attachment.quality.maximumByteCount,
      attachment.encoding == .jpeg
    else { throw ComposerImageProcessingError.invalidSource }
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
    quality: ComposerImageAttachmentQuality
  ) throws -> EncodedCandidate {
    let compressionQualities: [Double] =
      switch quality {
      case .standard:
        [0.90, 0.82, 0.72, 0.60, 0.48, 0.36]
      case .highQuality:
        [0.95, 0.88, 0.80, 0.70, 0.58, 0.46, 0.34]
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
        if Int64(data.count) <= quality.maximumByteCount {
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
          (Double(quality.maximumByteCount) / Double(smallestEncodedByteCount)).squareRoot()
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
