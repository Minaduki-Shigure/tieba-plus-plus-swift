import CryptoKit
import Darwin
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
import zlib

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

  func testOriginalJPEGKeepsCameraDimensionsAndCompressedScanBytes() throws {
    let source = try imageData(type: .jpeg, width: 4_032, height: 3_024)

    let result = try processor.process(data: source, quality: .original)

    XCTAssertEqual(result.quality, .original)
    XCTAssertEqual(result.encoding, .jpeg)
    XCTAssertEqual(result.pixelWidth, 4_032)
    XCTAssertEqual(result.pixelHeight, 3_024)
    XCTAssertEqual(try jpegScanBytes(source), try jpegScanBytes(result.data))
    try processor.validateStoredData(result.data, matching: attachment(for: result))
  }

  func testOriginalPNGPreservesFormatPixelsAndTransparentAlpha() throws {
    let source = try transparentPNGData(width: 5_000, height: 8)

    let result = try processor.process(data: source, quality: .original)

    XCTAssertEqual(result.encoding, .png)
    XCTAssertEqual(imageType(of: result.data), UTType.png.identifier)
    XCTAssertEqual(result.pixelWidth, 5_000)
    XCTAssertEqual(result.pixelHeight, 8)
    XCTAssertEqual(try pngPayloads("IDAT", in: source), try pngPayloads("IDAT", in: result.data))
    XCTAssertEqual(try averageRGBA(of: result.data).alpha, 0)
    XCTAssertEqual(try renderedPixels(source), try renderedPixels(result.data))
    try processor.validateStoredData(result.data, matching: attachment(for: result))
  }

  func testOriginalRetainsAllEightOrientationsWithoutRotatingEncodedPixels() throws {
    for type in [UTType.jpeg, .png] {
      for orientation in 1...8 {
        let source = try imageData(
          type: type, width: 40, height: 20,
          properties: [kCGImagePropertyOrientation: orientation]
        )
        XCTAssertEqual(
          (try imageProperties(of: source)[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? 1,
          orientation
        )

        let result = try processor.process(data: source, quality: .original)

        XCTAssertEqual(result.pixelWidth, 40)
        XCTAssertEqual(result.pixelHeight, 20)
        XCTAssertEqual(
          (try imageProperties(of: result.data)[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? 1,
          orientation
        )
        XCTAssertEqual(
          try renderedPixels(source, transform: true),
          try renderedPixels(result.data, transform: true))
        try processor.validateStoredData(result.data, matching: attachment(for: result))
      }
    }
  }

  func testOriginalPreservesSRGBAndDisplayP3ColorWithoutCopyingPrivateMetadata() throws {
    for type in [UTType.jpeg, .png] {
      for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
        let source = try colorManagedData(type: type, colorSpace: name)
        let result = try processor.process(data: source, quality: .original)
        let sourceImage = try decodedImage(source)
        let resultImage = try decodedImage(result.data)
        let expectedColorSpace = try XCTUnwrap(CGColorSpace(name: name))

        XCTAssertTrue(CFEqual(try XCTUnwrap(sourceImage.colorSpace), expectedColorSpace))
        XCTAssertTrue(CFEqual(try XCTUnwrap(resultImage.colorSpace), expectedColorSpace))
        XCTAssertEqual(try renderedPixels(source), try renderedPixels(result.data))
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("private-"))
        try assertOnlyDisplayMetadata(result.data)
        try processor.validateStoredData(result.data, matching: attachment(for: result))
      }
    }
  }

  func testOriginalRemovesPrivateEXIFAndPNGTextWhileRetainingOrientation() throws {
    let privateProperties: [CFString: Any] = [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLatitude: 31.2304,
        kCGImagePropertyGPSLongitudeRef: "E", kCGImagePropertyGPSLongitude: 121.4737,
      ],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private-comment"],
      kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["private-keyword"]],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFArtist: "private-artist",
        kCGImagePropertyTIFFMake: "private-camera",
        kCGImagePropertyTIFFDateTime: "2026:01:02 03:04:05",
      ],
    ]
    for type in [UTType.jpeg, .png] {
      var source = try imageData(type: type, width: 40, height: 20, properties: privateProperties)
      if type == .png {
        source = try insertingPNGChunk(
          "tEXt", payload: Data("Comment\0private-location".utf8), in: source)
      } else {
        source = try insertingBeforeJPEGEnd(
          jpegSegment(marker: 0xFE, payload: Array("private-location".utf8)), in: source
        )
      }

      let result = try processor.process(data: source, quality: .original)

      XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("private-"))
      XCTAssertEqual(
        (try imageProperties(of: result.data)[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
        6
      )
      try assertOnlyDisplayMetadata(result.data)
    }
  }

  func testOriginalRejectsCustomColorSpaceInsteadOfSilentlyChangingColor() throws {
    let source = try colorManagedData(type: .jpeg, colorSpace: CGColorSpace.adobeRGB1998)

    XCTAssertThrowsError(try processor.process(data: source, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
    XCTAssertNoThrow(try processor.process(data: source, quality: .standard))
  }

  func testOriginalDoesNotMistakeIgnoredMalformedICCForDefaultSRGB() throws {
    let clean = try processor.process(
      data: imageData(type: .jpeg, width: 16, height: 8), quality: .standard
    )
    let malformedProfile =
      Array("ICC_PROFILE\0".utf8) + [1, 1]
      + [UInt8](repeating: 0, count: 128)
    let source = try insertingBeforeJPEGEnd(
      jpegSegment(marker: 0xE2, payload: malformedProfile), in: clean.data
    )

    XCTAssertThrowsError(try processor.process(data: source, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
  }

  func testOriginalRejectsAnimationAPNGAndAuxiliaryRepresentations() throws {
    XCTAssertThrowsError(
      try processor.process(data: animatedGIFData(width: 12, height: 7), quality: .original)
    ) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .animatedImage)
    }
    let png = try imageData(type: .png, width: 12, height: 7)
    // Even an acTL with a single frame is not an ordinary static PNG.
    let apng = try insertingPNGChunk("acTL", payload: Data([0, 0, 0, 1, 0, 0, 0, 0]), in: png)
    XCTAssertThrowsError(try processor.process(data: apng, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .animatedImage)
    }
    let hdrPNG = try insertingPNGChunk("cICP", payload: Data([9, 16, 0, 1]), in: png)
    XCTAssertThrowsError(try processor.process(data: hdrPNG, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
    let jpeg = try imageData(type: .jpeg, width: 12, height: 7)
    for segment in [
      jpegSegment(marker: 0xE2, payload: Array("MPF\0auxiliary-image".utf8)),
      jpegSegment(marker: 0xE1, payload: Array("http://ns.adobe.com/xap/1.0/\0hdrgm:Version".utf8)),
    ] {
      XCTAssertThrowsError(
        try processor.process(data: insertingBeforeJPEGEnd(segment, in: jpeg), quality: .original)
      )
    }
  }

  func testOriginalRejectsHEICInsteadOfConvertingItToJPEG() throws {
    let destinationTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    guard destinationTypes.contains(UTType.heic.identifier) else {
      throw XCTSkip("No HEIC encoder")
    }
    let source = try imageData(type: .heic, width: 24, height: 16)

    XCTAssertThrowsError(try processor.process(data: source, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
  }

  func testOriginalDoesNotRecompressOrResizeToFitByteBudget() throws {
    for type in [UTType.jpeg, .png] {
      let source = try imageData(type: type, width: 128, height: 96)
      let reference = try processor.process(data: source, quality: .original)

      XCTAssertThrowsError(
        try processor.process(
          data: source, quality: .original, maximumByteCount: Int64(reference.data.count - 1))
      ) { error in
        XCTAssertEqual(error as? ComposerImageProcessingError, .encodedImageTooLarge)
      }
    }
  }

  func testOriginalStoredValidationRejectsMetadataFormatAndDimensionTamperingBeforeDecode() throws {
    let counter = LockedCounter()
    let observingProcessor = ComposerImageAttachmentProcessor { counter.increment() }
    for type in [UTType.jpeg, .png] {
      let clean = try processor.process(
        data: imageData(type: type, width: 16, height: 8), quality: .original)
      var polluted: Data
      if type == .jpeg {
        polluted = try insertingBeforeJPEGEnd(
          jpegSegment(marker: 0xFE, payload: Array("private-comment".utf8)), in: clean.data
        )
      } else {
        polluted = try insertingPNGChunk(
          "tEXt", payload: Data("Comment\0private-comment".utf8), in: clean.data)
      }
      let pollutedResult = try XCTUnwrap(
        ComposerProcessedImage(
          data: polluted, pixelWidth: 16, pixelHeight: 8, encoding: clean.encoding,
          quality: .original
        ))
      XCTAssertThrowsError(
        try observingProcessor.validateStoredData(
          polluted, matching: attachment(for: pollutedResult))
      ) { error in
        XCTAssertEqual(error as? ComposerImageProcessingError, .metadataWasNotRemoved)
      }
      let wrongEncoding = try XCTUnwrap(
        ComposerProcessedImage(
          data: clean.data, pixelWidth: 16, pixelHeight: 8,
          encoding: type == .jpeg ? .png : .jpeg, quality: .original
        ))
      XCTAssertThrowsError(
        try observingProcessor.validateStoredData(
          clean.data, matching: attachment(for: wrongEncoding))
      )
      let wrongDimensions = try XCTUnwrap(
        ComposerProcessedImage(
          data: clean.data, pixelWidth: 8, pixelHeight: 16, encoding: clean.encoding,
          quality: .original
        ))
      XCTAssertThrowsError(
        try observingProcessor.validateStoredData(
          clean.data, matching: attachment(for: wrongDimensions))
      )
    }
    XCTAssertEqual(counter.value, 0)
  }

  func testOriginalRejectsOversizedSourceDimensionsBeforeFullDecode() throws {
    let source = try imageData(type: .jpeg, width: 16, height: 8)
    let counter = LockedCounter()
    let observingProcessor = ComposerImageAttachmentProcessor { counter.increment() }
    for (width, height) in [(UInt16(16_385), UInt16(1)), (UInt16(4_096), UInt16(3_073))] {
      let oversized = try replacingSOFDimensions(in: source, width: width, height: height)
      XCTAssertThrowsError(try observingProcessor.process(data: oversized, quality: .original)) {
        error in
        XCTAssertEqual(error as? ComposerImageProcessingError, .sourcePixelCountTooLarge)
      }
    }
    XCTAssertEqual(counter.value, 0)
  }

  func testOriginalStoredPNGRejectsBadCRCTruncationAndTrailingBytes() throws {
    let clean = try processor.process(
      data: imageData(type: .png, width: 16, height: 8), quality: .original)
    var wrongCRC = clean.data
    wrongCRC[wrongCRC.count - 1] ^= 1
    for damaged in [wrongCRC, Data(clean.data.dropLast()), clean.data + Data([0])] {
      let candidate = try XCTUnwrap(
        ComposerProcessedImage(
          data: damaged, pixelWidth: 16, pixelHeight: 8, encoding: .png, quality: .original
        ))
      XCTAssertThrowsError(
        try processor.validateStoredData(damaged, matching: attachment(for: candidate)))
    }
  }

  func testOriginalAcceptsGrayscaleWithoutICCAndPreservesProgressiveJPEGScans() throws {
    // Small synthetic grayscale and progressive gradients encoded with
    // ImageMagick; no platform encoder assumptions or personal image assets.
    let grayscaleJPEG =
      "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAAGAAgBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAABv/EABsQAAAHAQAAAAAAAAAAAAAAAAABBAYYUpLR/9oACAEBAAA/AGUJWfZLg+D/2Q=="
    let grayscalePNG =
      "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAAAAADbboAnAAAAFUlEQVQI12M0ZoAAFjkYQx63CIwBAByPAOLQNipSAAAAAElFTkSuQmCC"
    let progressiveJPEG =
      "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wgARCAAGAAgDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABUBAQEAAAAAAAAAAAAAAAAAAAYH/9oADAMBAAIQAxAAAAESqi7/xAAWEAADAAAAAAAAAAAAAAAAAAAAAhX/2gAIAQEAAQUCoOf/xAAXEQADAQAAAAAAAAAAAAAAAAAABBdh/9oACAEDAQE/AaM3p//EABcRAAMBAAAAAAAAAAAAAAAAAAAEF2H/2gAIAQIBAT8BlyWH/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFRABAQAAAAAAAAAAAAAAAAAAAHH/2gAIAQEAAT8hu//aAAwDAQACAAMAAAAQ/wD/xAAXEQADAQAAAAAAAAAAAAAAAAAAYZHh/9oACAEDAQE/EF1p/8QAFxEAAwEAAAAAAAAAAAAAAAAAAGGR4f/aAAgBAgEBPxBsYf/EABYQAAMAAAAAAAAAAAAAAAAAAABhkf/aAAgBAQABPxBVn//Z"
    for fixture in [grayscaleJPEG, grayscalePNG, progressiveJPEG] {
      let source = try XCTUnwrap(Data(base64Encoded: fixture))
      let result = try processor.process(data: source, quality: .original)

      XCTAssertEqual(result.pixelWidth, 8)
      XCTAssertEqual(result.pixelHeight, 6)
      XCTAssertEqual(try renderedPixels(source), try renderedPixels(result.data))
      if result.encoding == .jpeg {
        XCTAssertEqual(try jpegScanBytes(source), try jpegScanBytes(result.data))
      }
      try processor.validateStoredData(result.data, matching: attachment(for: result))
    }
  }

  func testOriginalRejects16BitPNGInsteadOfSilentlyReducingBitDepth() throws {
    let source = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGEAAAAACL/lxkAAAAIklEQVQI12M0NmZAAYyBr1EFWOR3oAvsRNOyTgRNhRyaFgAY3AT5IrlIKAAAAABJRU5ErkJggg=="
      ))
    XCTAssertThrowsError(try processor.process(data: source, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
  }

  func testOriginalPreservesIndexedPNGPaletteAndPerEntryTransparency() throws {
    let source = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAMAAABIdo1RAAAABlBMVEUAAAD/AAAb/40iAAAAAXRSTlMAQObYZgAAAA9JREFUCNdjYGRkYGAAEQAAIgAFnBl6mAAAAABJRU5ErkJggg=="
      ))
    let result = try processor.process(data: source, quality: .original)

    for name in ["PLTE", "tRNS", "IDAT"] {
      XCTAssertEqual(try pngPayloads(name, in: result.data), try pngPayloads(name, in: source))
    }
    let pixels = try renderedPixels(result.data)
    XCTAssertEqual(pixels, try renderedPixels(source))
    XCTAssertEqual(pixels[3], 255)
    XCTAssertEqual(pixels[11], 0)
    try processor.validateStoredData(result.data, matching: attachment(for: result))
  }

  func testOriginalBoundsICCInflationAndRemovesCompressedTextBeforeImageIO() throws {
    let source = try imageData(type: .png, width: 16, height: 8)
    var profile = Data(repeating: 0, count: 256 * 1_024 + 1)
    profile.replaceSubrange(0..<4, with: [0, 4, 0, 1])
    profile.replaceSubrange(36..<40, with: Data("acsp".utf8))
    let oversizedICC = try insertingPNGChunk(
      "iCCP", payload: Data("Oversized\0\0".utf8) + compressed(profile), in: source
    )
    XCTAssertThrowsError(try ComposerOriginalImageSanitizer.preflight(oversizedICC)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
    XCTAssertThrowsError(try processor.process(data: oversizedICC, quality: .original)) { error in
      XCTAssertEqual(error as? ComposerImageProcessingError, .unsupportedOriginal)
    }
    let privateText = Data(repeating: 65, count: 2 * 1_024 * 1_024)
    let ztxt = try insertingPNGChunk(
      "zTXt", payload: Data("Comment\0\0".utf8) + compressed(privateText), in: source
    )
    let itxt = try insertingPNGChunk(
      "iTXt",
      payload: Data("XML:com.adobe.xmp\0".utf8) + Data([1, 0, 0, 0]) + compressed(privateText),
      in: ztxt
    )
    XCTAssertEqual(
      try ComposerOriginalImageSanitizer.preflight(itxt),
      try ComposerOriginalImageSanitizer.preflight(source))
    XCTAssertEqual(
      try processor.process(data: itxt, quality: .original),
      try processor.process(data: source, quality: .original)
    )
  }

  private func compressed(_ data: Data) throws -> Data {
    var size = compressBound(uLong(data.count))
    var result = [UInt8](repeating: 0, count: Int(size))
    let status = data.withUnsafeBytes { input in
      result.withUnsafeMutableBufferPointer { output in
        compress2(
          output.baseAddress, &size, input.bindMemory(to: UInt8.self).baseAddress,
          uLong(data.count), Z_BEST_COMPRESSION)
      }
    }
    XCTAssertEqual(status, Z_OK)
    return Data(result.prefix(Int(size)))
  }

  private func attachment(for result: ComposerProcessedImage) throws -> ComposerImageAttachment {
    try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(), sha256: sha256(of: result.data), byteCount: Int64(result.data.count),
        pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight,
        encoding: result.encoding, quality: result.quality
      ))
  }

  private func assertOnlyDisplayMetadata(_ data: Data) throws {
    let properties = try imageProperties(of: data)
    for key in [
      kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary,
      kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary,
    ] {
      XCTAssertNil(properties[key])
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any] {
      XCTAssertTrue(Set(tiff.keys).isSubset(of: [kCGImagePropertyTIFFOrientation as String]))
    }
  }

  private func colorManagedData(type: UTType, colorSpace name: CFString) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: name))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0.25, 0, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, try XCTUnwrap(context.makeImage()),
      [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private-artist"]
      ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func decodedImage(_ data: Data, transform: Bool = false) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    if transform {
      return try XCTUnwrap(
        CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 100,
          ] as CFDictionary))
    }
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private func renderedPixels(_ data: Data, transform: Bool = false) throws -> Data {
    let image = try decodedImage(data, transform: transform)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.draw(
      image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
  }

  private func jpegScanBytes(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    // Fixtures emitted by ImageIO use a single baseline scan. Comparing it
    // detects any recompression independently of the application's sanitizer.
    let start = try XCTUnwrap(
      bytes.indices.dropLast().first(where: {
        bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA
      }))
    return Data(bytes[start..<(bytes.count - 2)])
  }

  private func pngPayloads(_ name: String, in data: Data) throws -> [Data] {
    var values: [Data] = []
    var offset = 8
    while offset + 12 <= data.count {
      let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      guard length <= data.count - offset - 12 else { throw TestFixtureError.missingEndOfImage }
      if String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self) == name {
        values.append(Data(data[(offset + 8)..<(offset + 8 + length)]))
      }
      offset += length + 12
    }
    return values
  }

  private func insertingPNGChunk(_ name: String, payload: Data, in data: Data) throws -> Data {
    guard data.count >= 33 else { throw TestFixtureError.missingEndOfImage }
    let body = Data(name.utf8) + payload
    var crc = UInt32.max
    for byte in body {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320 }
    }
    crc ^= UInt32.max
    func bigEndian(_ value: UInt32) -> Data {
      Data([
        UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255),
        UInt8(value & 255),
      ])
    }
    let chunk = bigEndian(UInt32(payload.count)) + body + bigEndian(crc)
    return Data(data.prefix(33)) + chunk + data.dropFirst(33)
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
