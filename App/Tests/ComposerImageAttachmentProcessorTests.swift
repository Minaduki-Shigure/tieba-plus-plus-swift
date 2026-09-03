import CryptoKit
import Darwin
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerImageAttachmentProcessorTests: XCTestCase {
  private let processor = ComposerImageAttachmentProcessor()

  func testStandardAlwaysReencodesAndConstrainsLongestEdge() throws {
    let source = try imageData(type: .png, width: 2_400, height: 1_200)

    let result = try processor.process(data: source, quality: .standard)

    XCTAssertEqual(result.encoding, .jpeg)
    XCTAssertEqual(result.quality, .standard)
    XCTAssertEqual(result.pixelWidth, 1_080)
    XCTAssertEqual(result.pixelHeight, 540)
    XCTAssertLessThanOrEqual(
      Int64(result.data.count),
      ComposerImageAttachmentQuality.standard.maximumByteCount
    )
    XCTAssertEqual(imageType(of: result.data), UTType.jpeg.identifier)
    XCTAssertNotEqual(result.data, source)
  }

  func testHighQualityPreservesReasonablePixelDimensionsButStillReencodes() throws {
    let source = try imageData(type: .jpeg, width: 1_200, height: 600)

    let result = try processor.process(data: source, quality: .highQuality)

    XCTAssertEqual(result.pixelWidth, 1_200)
    XCTAssertEqual(result.pixelHeight, 600)
    XCTAssertEqual(result.encoding, .jpeg)
    XCTAssertLessThanOrEqual(
      Int64(result.data.count),
      ComposerImageAttachmentQuality.highQuality.maximumByteCount
    )
    XCTAssertNotEqual(result.data, source)
  }

  func testHighQualityConstrainsUnreasonablePixelDimensions() throws {
    let source = try imageData(type: .png, width: 5_000, height: 1_000)

    let result = try processor.process(data: source, quality: .highQuality)

    XCTAssertEqual(result.pixelWidth, 4_096)
    XCTAssertGreaterThanOrEqual(result.pixelHeight, 818)
    XCTAssertLessThanOrEqual(result.pixelHeight, 820)
  }

  func testCustomMaximumByteCountIsEnforced() throws {
    let source = try imageData(type: .png, width: 1_080, height: 1_080)
    let maximumByteCount: Int64 = 256 * 1_024

    let result = try processor.process(
      data: source,
      quality: .standard,
      maximumByteCount: maximumByteCount
    )

    XCTAssertLessThanOrEqual(Int64(result.data.count), maximumByteCount)
    XCTAssertEqual(result.encoding, .jpeg)
  }

  func testCustomMaximumByteCountCannotWeakenQualityPolicy() throws {
    let source = try imageData(type: .png, width: 32, height: 32)

    XCTAssertThrowsError(
      try processor.process(
        data: source,
        quality: .standard,
        maximumByteCount: ComposerImageAttachmentQuality.standard.maximumByteCount + 1
      )
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .encodedImageTooLarge)
    }
  }

  func testProcessingAppliesOrientationAndDoesNotRetainOrientationMetadata() throws {
    let source = try imageData(
      type: .jpeg,
      width: 40,
      height: 20,
      properties: [kCGImagePropertyOrientation: 6]
    )

    let result = try processor.process(data: source, quality: .standard)
    let properties = try imageProperties(of: result.data)

    XCTAssertEqual(result.pixelWidth, 20)
    XCTAssertEqual(result.pixelHeight, 40)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    XCTAssertNil(properties[kCGImagePropertyExifDictionary])
    XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
  }

  func testProcessingRemovesGPSExifIPTCAndTIFFMetadata() throws {
    let source = try imageData(
      type: .jpeg,
      width: 32,
      height: 24,
      properties: [
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitudeRef: "N",
          kCGImagePropertyGPSLatitude: 31.2304,
          kCGImagePropertyGPSLongitudeRef: "E",
          kCGImagePropertyGPSLongitude: 121.4737,
        ],
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifUserComment: "private-comment"
        ],
        kCGImagePropertyIPTCDictionary: [
          kCGImagePropertyIPTCKeywords: ["private-keyword"]
        ],
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFArtist: "private-artist"
        ],
      ]
    )
    let sourceProperties = try imageProperties(of: source)
    XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
    XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary])
    XCTAssertNotNil(sourceProperties[kCGImagePropertyTIFFDictionary])

    let result = try processor.process(data: source, quality: .standard)
    let properties = try imageProperties(of: result.data)

    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    XCTAssertNil(properties[kCGImagePropertyExifDictionary])
    XCTAssertNil(properties[kCGImagePropertyExifAuxDictionary])
    XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
    XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
  }

  func testTransparentPNGPixelsAreCompositedOntoWhiteBeforeJPEGEncoding() throws {
    let source = try transparentPNGData(width: 24, height: 24)

    let result = try processor.process(data: source, quality: .standard)
    let rgba = try averageRGBA(of: result.data)

    XCTAssertGreaterThan(rgba.red, 245)
    XCTAssertGreaterThan(rgba.green, 245)
    XCTAssertGreaterThan(rgba.blue, 245)
    XCTAssertEqual(rgba.alpha, 255)
  }

  func testForgedHugeSOFDimensionsAreRejectedBeforeFullDecode() throws {
    let valid = try processor.process(
      data: imageData(type: .png, width: 16, height: 8),
      quality: .standard
    )
    let counter = LockedCounter()
    let observingProcessor = ComposerImageAttachmentProcessor {
      counter.increment()
    }
    let validAttachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(),
        sha256: sha256(of: valid.data),
        byteCount: Int64(valid.data.count),
        pixelWidth: valid.pixelWidth,
        pixelHeight: valid.pixelHeight,
        quality: .standard
      )
    )
    try observingProcessor.validateStoredData(valid.data, matching: validAttachment)
    XCTAssertEqual(counter.value, 1)
    counter.reset()

    let forged = try replacingSOFDimensions(
      in: valid.data,
      width: UInt16.max,
      height: UInt16.max
    )
    let forgedAttachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(),
        sha256: sha256(of: forged),
        byteCount: Int64(forged.count),
        pixelWidth: valid.pixelWidth,
        pixelHeight: valid.pixelHeight,
        quality: .standard
      )
    )

    XCTAssertThrowsError(
      try observingProcessor.validateStoredData(forged, matching: forgedAttachment)
    )
    XCTAssertEqual(counter.value, 0)
  }

  func testStoredJPEGRejectsAllApplicationAndCommentMetadataBeforeDecode() throws {
    let valid = try processor.process(
      data: imageData(type: .png, width: 16, height: 8),
      quality: .standard
    )
    let counter = LockedCounter()
    let observingProcessor = ComposerImageAttachmentProcessor {
      counter.increment()
    }
    let privateSegments: [[UInt8]] = [
      jpegSegment(marker: 0xE1, payload: Array("http://ns.adobe.com/xap/1.0/\0private".utf8)),
      jpegSegment(marker: 0xED, payload: Array("Photoshop 3.0\0private".utf8)),
      jpegSegment(marker: 0xE2, payload: Array("ICC_PROFILE\0private".utf8)),
      jpegSegment(marker: 0xFE, payload: Array("private-comment".utf8)),
    ]

    for privateSegment in privateSegments {
      let tampered = try insertingBeforeJPEGEnd(privateSegment, in: valid.data)
      let attachment = try XCTUnwrap(
        ComposerImageAttachment(
          id: UUID(),
          sha256: sha256(of: tampered),
          byteCount: Int64(tampered.count),
          pixelWidth: valid.pixelWidth,
          pixelHeight: valid.pixelHeight,
          quality: .standard
        )
      )

      XCTAssertThrowsError(
        try observingProcessor.validateStoredData(tampered, matching: attachment)
      ) { error in
        XCTAssertEqual(error as? ComposerImageProcessingError, .metadataWasNotRemoved)
      }
      XCTAssertEqual(counter.value, 0)
    }
  }

  func testAcceptsStaticPNGAndJPEGAndRejectsUnknownOrDamagedData() throws {
    for type in [UTType.png, UTType.jpeg] {
      XCTAssertNoThrow(
        try processor.process(
          data: imageData(type: type, width: 12, height: 7),
          quality: .standard
        )
      )
    }

    XCTAssertThrowsError(
      try processor.process(data: Data("not-an-image".utf8), quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .invalidSource)
    }

    let truncated = try imageData(type: .jpeg, width: 12, height: 7).prefix(24)
    XCTAssertThrowsError(
      try processor.process(data: Data(truncated), quality: .standard)
    )
  }

  func testAcceptsStaticHEICWhenImageIOSupportsEncodingIt() throws {
    let destinationTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    guard destinationTypes.contains(UTType.heic.identifier) else {
      throw XCTSkip("This simulator does not provide a HEIC encoder.")
    }
    let source = try imageData(type: .heic, width: 24, height: 16)

    let result = try processor.process(data: source, quality: .standard)

    XCTAssertEqual(result.pixelWidth, 24)
    XCTAssertEqual(result.pixelHeight, 16)
    XCTAssertEqual(imageType(of: result.data), UTType.jpeg.identifier)
  }

  func testRejectsAnimatedImages() throws {
    let animated = try animatedGIFData(width: 12, height: 7)

    XCTAssertThrowsError(
      try processor.process(data: animated, quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .animatedImage)
    }
  }

  func testRejectsStaticImageFormatsOutsideTheAllowlist() throws {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.gif.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(
      destination,
      try cgImage(width: 12, height: 7, color: .systemBlue),
      nil
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    XCTAssertThrowsError(
      try processor.process(data: data as Data, quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedFormat)
    }
  }

  func testRejectsCompressedInputBeyondTheBoundBeforeDecoding() {
    let oversized = Data(
      count: Int(ComposerImageProcessingPolicy.maximumSourceByteCount) + 1
    )

    XCTAssertThrowsError(
      try processor.process(data: oversized, quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .sourceTooLarge)
    }
  }

  func testFileInputRejectsSymlinksAndDoesNotTrustFilenameExtension() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("private-location-and-asset-id.gif")
    try imageData(type: .png, width: 18, height: 9).write(to: sourceURL)
    let symlinkURL = root.appendingPathComponent("linked.jpg")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)

    let processed = try processor.process(
      temporaryFileURL: sourceURL,
      quality: .standard
    )
    XCTAssertEqual(processed.pixelWidth, 18)
    XCTAssertEqual(processed.pixelHeight, 9)
    XCTAssertThrowsError(
      try processor.process(temporaryFileURL: symlinkURL, quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .invalidSource)
    }
  }

  func testFileInputRejectsFIFOsWithoutBlocking() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fifoURL = root.appendingPathComponent("untrusted-image-pipe")
    let result = fifoURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
    }
    XCTAssertEqual(result, 0)

    XCTAssertThrowsError(
      try processor.process(temporaryFileURL: fifoURL, quality: .standard)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .invalidSource)
    }
  }

  func testPoliciesRejectOverflowAndExcessivePixelOrMemoryLayouts() {
    XCTAssertTrue(
      ComposerImageProcessingPolicy.acceptsSourceDimensions(width: 3_072, height: 4_096)
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsSourceDimensions(width: 3_073, height: 4_096)
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsSourceDimensions(width: 16_385, height: 1)
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsSourceDimensions(
        width: Int.max,
        height: Int.max
      )
    )
    XCTAssertTrue(
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: 4_096 * 4,
        height: 4_096
      )
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: 4_096 * 4 + 1,
        height: 4_096
      )
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsDecodedLayout(
        bytesPerRow: Int.max,
        height: Int.max
      )
    )
    XCTAssertTrue(
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: 4_096,
        height: 2_048,
        maximumPixelSize: 4_096
      )
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: 4_096,
        height: 2_049,
        maximumPixelSize: 4_096
      )
    )
    XCTAssertEqual(
      ComposerImageProcessingPolicy.thumbnailMaximumPixelSize(
        sourceWidth: 4_096,
        sourceHeight: 2_048,
        requestedMaximumPixelSize: 4_096
      ),
      4_096
    )
    XCTAssertNil(
      ComposerImageProcessingPolicy.thumbnailMaximumPixelSize(
        sourceWidth: Int.max,
        sourceHeight: Int.max,
        requestedMaximumPixelSize: Int.max
      )
    )
  }

  func testHighQualityCameraImageUsesMemorySafeThumbnailDimensions() {
    XCTAssertTrue(
      ComposerImageProcessingPolicy.acceptsSourceDimensions(
        width: 4_032,
        height: 3_024
      )
    )
    let maximumSide = ComposerImageProcessingPolicy.thumbnailMaximumPixelSize(
      sourceWidth: 4_032,
      sourceHeight: 3_024,
      requestedMaximumPixelSize: ComposerImageAttachmentQuality.highQuality.maximumPixelSize
    )

    XCTAssertEqual(maximumSide, 3_344)
    XCTAssertTrue(
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: 3_344,
        height: 2_508,
        maximumPixelSize: ComposerImageAttachmentQuality.highQuality.maximumPixelSize
      )
    )
    XCTAssertFalse(
      ComposerImageProcessingPolicy.acceptsOutputDimensions(
        width: 3_345,
        height: 2_509,
        maximumPixelSize: ComposerImageAttachmentQuality.highQuality.maximumPixelSize
      )
    )
    XCTAssertEqual(
      ComposerImageProcessingPolicy.thumbnailMaximumPixelSize(
        sourceWidth: 4_032,
        sourceHeight: 3_024,
        requestedMaximumPixelSize: ComposerImageAttachmentQuality.standard.maximumPixelSize
      ),
      1_080
    )
  }

  private func imageData(
    type: UTType,
    width: Int,
    height: Int,
    properties: [CFString: Any] = [:]
  ) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { context in
      UIColor.white.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
      UIColor.systemBlue.setFill()
      context.fill(
        CGRect(
          x: 0,
          y: 0,
          width: CGFloat(max(1, width / 2)),
          height: CGFloat(height)
        )
      )
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        type.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func transparentPNGData(width: Int, height: Int) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { _ in }
    return try XCTUnwrap(image.pngData())
  }

  private func averageRGBA(of data: Data) throws -> (
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    alpha: UInt8
  ) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress,
          width: 1,
          height: 1,
          bitsPerComponent: 8,
          bytesPerRow: 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (pixel[0], pixel[1], pixel[2], pixel[3])
  }

  private func replacingSOFDimensions(
    in data: Data,
    width: UInt16,
    height: UInt16
  ) throws -> Data {
    var bytes = [UInt8](data)
    var index = 2
    while index + 8 < bytes.count {
      guard bytes[index] == 0xFF else { break }
      while index < bytes.count, bytes[index] == 0xFF {
        index += 1
      }
      guard index < bytes.count else { break }
      let marker = bytes[index]
      index += 1
      guard marker != 0xD9, marker != 0xDA, index + 1 < bytes.count else { break }
      let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      guard length >= 2, index <= bytes.count - length else { break }
      if [UInt8(0xC0), 0xC1, 0xC2].contains(marker) {
        bytes[index + 3] = UInt8(height >> 8)
        bytes[index + 4] = UInt8(height & 0xFF)
        bytes[index + 5] = UInt8(width >> 8)
        bytes[index + 6] = UInt8(width & 0xFF)
        return Data(bytes)
      }
      index += length
    }
    throw TestFixtureError.missingSOF
  }

  private func jpegSegment(marker: UInt8, payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    precondition(length <= Int(UInt16.max))
    return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
  }

  private func insertingBeforeJPEGEnd(_ segment: [UInt8], in data: Data) throws -> Data {
    var bytes = [UInt8](data)
    guard bytes.suffix(2) == [0xFF, 0xD9] else {
      throw TestFixtureError.missingEndOfImage
    }
    bytes.insert(contentsOf: segment, at: bytes.count - 2)
    return Data(bytes)
  }

  private func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func animatedGIFData(width: Int, height: Int) throws -> Data {
    let first = try cgImage(width: width, height: height, color: .systemBlue)
    let second = try cgImage(width: width, height: height, color: .systemRed)
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.gif.identifier as CFString,
        2,
        nil
      )
    )
    CGImageDestinationAddImage(destination, first, nil)
    CGImageDestinationAddImage(destination, second, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func cgImage(width: Int, height: Int, color: UIColor) throws -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { context in
      color.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
    }
    return try XCTUnwrap(image.cgImage)
  }

  private func imageType(of data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
  }

  private func imageProperties(of data: Data) throws -> [CFString: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerImageAttachmentProcessorTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private enum TestFixtureError: Error {
  case missingSOF
  case missingEndOfImage
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }

  func reset() {
    lock.withLock { count = 0 }
  }
}
