import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

final class ComposerWebPImageAttachmentTests: XCTestCase {
  private typealias Fixture = ComposerWebPTestFixture

  func testStaticLossyLosslessAndAlphaReencodeAsJPEGInBothQualityModes() throws {
    let processor = ComposerImageAttachmentProcessor()
    for source in [Fixture.lossy, Fixture.lossless, Fixture.alphaLossless, Fixture.alphaLossy] {
      for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
        let result = try processor.process(data: source, quality: quality)
        XCTAssertEqual(result.encoding, .jpeg)
        XCTAssertEqual(result.quality, quality)
        XCTAssertEqual(result.pixelWidth, 8)
        XCTAssertEqual(result.pixelHeight, 6)
        XCTAssertNotEqual(result.data, source)
        let imageSource = try sourceFor(result.data)
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.jpeg.identifier)
        try processor.validateStoredData(result.data, matching: attachment(result))
      }
    }
  }

  func testOriginalStaticWebPPreservesLossyLosslessAndAlphaCodecPayloads() throws {
    let processor = ComposerImageAttachmentProcessor()
    for source in [Fixture.lossy, Fixture.lossless, Fixture.alphaLossless, Fixture.alphaLossy] {
      let result = try processor.process(data: source, quality: .original)
      XCTAssertEqual(result.encoding, .webp)
      XCTAssertEqual(result.quality, .original)
      XCTAssertEqual(result.data, source)
      XCTAssertEqual(result.pixelWidth, 8)
      XCTAssertEqual(result.pixelHeight, 6)
      try processor.validateStoredData(result.data, matching: attachment(result))
    }
  }

  func testOriginalAlphaRemainsTransparentAndJPEGCompositesAgainstWhite() throws {
    let processor = ComposerImageAttachmentProcessor()
    for data in [Fixture.alphaLossless, Fixture.alphaLossy] {
      let original = try processor.process(data: data, quality: .original)
      let originalPixels = try pixels(original.data)
      let alphas = stride(from: 3, to: originalPixels.count, by: 4).map { originalPixels[$0] }
      XCTAssertEqual(alphas.min(), 0)
      XCTAssertGreaterThan(try XCTUnwrap(alphas.max()), 120)
      XCTAssertLessThan(try XCTUnwrap(alphas.max()), 140)

      let jpeg = try processor.process(data: data, quality: .standard)
      let jpegPixels = try pixels(jpeg.data)
      XCTAssertTrue(stride(from: 3, to: jpegPixels.count, by: 4).allSatisfy { jpegPixels[$0] == 255 })
      // The right half of the source is transparent. JPEG must use the same
      // white compositing policy as PNG inputs, rather than an unreadable black area.
      let rightPixel = (7 * 4)
      XCTAssertGreaterThan(jpegPixels[rightPixel], 220)
      XCTAssertGreaterThan(jpegPixels[rightPixel + 1], 220)
      XCTAssertGreaterThan(jpegPixels[rightPixel + 2], 220)
    }
  }

  func testOriginalAnimationRetainsPartialFrameTimingLoopBlendAndDisposal() throws {
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    let input = Fixture.animated()
    let result = try processor.process(data: input, quality: .original)
    XCTAssertEqual(result.data, input, "Animation and compressed frame bytes must remain exact")
    XCTAssertEqual(result.encoding, .webp)
    XCTAssertEqual(counter.indices, [0, 1])
    let inspection = try ComposerWebPSanitizer.sanitize(result.data) { $0 }
    XCTAssertEqual(inspection.frameCount, 2)
    XCTAssertEqual(inspection.frameDurationsMilliseconds, [70, 130])
    XCTAssertEqual(inspection.loopCount, 3)
    XCTAssertTrue(inspection.isAnimated)
    let decoded = try sourceFor(result.data)
    XCTAssertEqual(CGImageSourceGetCount(decoded), 2)
    let secondPixels = try pixels(result.data, index: 1)
    XCTAssertTrue(stride(from: 0, to: secondPixels.count, by: 4).contains {
      secondPixels[$0] < 30 && secondPixels[$0 + 1] > 200
    }, "The partial green second frame must remain present")
    try processor.validateStoredData(result.data, matching: attachment(result))
    XCTAssertEqual(counter.indices, [0, 1, 0, 1])
  }

  func testAnimationIncludingOneFrameRequiresOriginalWithoutDecoderWork() throws {
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    for frameCount in [1, 2] {
      for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
        XCTAssertThrowsError(
          try processor.process(data: Fixture.animated(frameCount: frameCount), quality: quality)
        ) {
          XCTAssertEqual($0 as? ComposerImageProcessingError, .webPRequiresOriginal)
        }
      }
      let original = try processor.process(data: Fixture.animated(frameCount: frameCount), quality: .original)
      XCTAssertEqual(original.data, Fixture.animated(frameCount: frameCount))
    }
    XCTAssertEqual(counter.indices, [0, 0, 1])
  }

  func testOriginalRemovesPrivateMetadataButPreservesOrientationAndDisplayChunks() throws {
    let processor = ComposerImageAttachmentProcessor()
    for clean in [Fixture.lossless, Fixture.animated()] {
      let dirty = Fixture.withMetadata(clean, orientation: 6)
      let result = try processor.process(data: dirty, quality: .original)
      XCTAssertNil(result.data.range(of: Data("private".utf8)))
      let inspection = try ComposerWebPSanitizer.sanitize(result.data) { $0 }
      XCTAssertEqual(inspection.orientation, 6)
      XCTAssertEqual(displayChunks(result.data), displayChunks(dirty))
      XCTAssertEqual(result.data, inspection.data, "Stored representation must be canonical")
      let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(try sourceFor(result.data), 0, nil) as? [CFString: Any])
      XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
      try processor.validateStoredData(result.data, matching: attachment(result))
    }
  }

  func testJPEGConversionAppliesWebPOrientationAndRemovesMetadata() throws {
    for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
      let result = try ComposerImageAttachmentProcessor().process(
        data: Fixture.withMetadata(Fixture.lossless, orientation: 6), quality: quality)
      XCTAssertEqual(result.pixelWidth, 6)
      XCTAssertEqual(result.pixelHeight, 8)
      XCTAssertNil(result.data.range(of: Data("private".utf8)))
      let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(try sourceFor(result.data), 0, nil) as? [CFString: Any])
      XCTAssertNil(properties[kCGImagePropertyExifDictionary])
      XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
      XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
    }
  }

  func testOriginalAcceptsOnlyCanonicalKnownColorProfilesWithoutChangingCodecBytes() throws {
    for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
      let space = try XCTUnwrap(CGColorSpace(name: name))
      let profile = try XCTUnwrap(space.copyICCData()) as Data
      let input = Fixture.withMetadata(Fixture.lossless, orientation: 1, icc: profile)
      let processor = ComposerImageAttachmentProcessor()
      let result = try processor.process(data: input, quality: .original)
      XCTAssertEqual(displayChunks(result.data), displayChunks(input))
      let actualProfile = try XCTUnwrap(Fixture.chunks(result.data).first { $0.type == "ICCP" })
      XCTAssertEqual(actualProfile.payload, profile)
      let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try sourceFor(result.data), 0, nil))
      let decodedColorSpace = try XCTUnwrap(decoded.colorSpace)
      let decodedProfile = try XCTUnwrap(decodedColorSpace.copyICCData())
      // Compare ICC-based representations, as the production canonicalization
      // does. A named color space need not CFEqual its ICC-based counterpart.
      let expectedICC = try XCTUnwrap(CGColorSpace(iccData: profile as CFData))
      let decodedICC = try XCTUnwrap(CGColorSpace(iccData: decodedProfile))
      XCTAssertTrue(CFEqual(decodedICC, expectedICC), "ImageIO must honor the embedded sRGB/P3 profile")
      try processor.validateStoredData(result.data, matching: attachment(result))
    }
    let unsupportedSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
    let unsupportedProfile = try XCTUnwrap(unsupportedSpace.copyICCData()) as Data
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    XCTAssertThrowsError(try processor.process(
      data: Fixture.withMetadata(Fixture.lossless, icc: unsupportedProfile), quality: .original)
    ) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .unsupportedOriginal)
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testStoredWebPRejectsReintroducedMetadataEvenWithRecomputedDigest() throws {
    let processor = ComposerImageAttachmentProcessor()
    for clean in [Fixture.lossless, Fixture.animated()] {
      let dirty = Fixture.withMetadata(clean)
      XCTAssertThrowsError(try processor.validateStoredData(dirty, matching: attachment(
        data: dirty, width: 8, height: 6, encoding: .webp))) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .metadataWasNotRemoved)
      }
      let result = try processor.process(data: dirty, quality: .original)
      try processor.validateStoredData(result.data, matching: attachment(result))
    }
  }

  func testStoredWebPRejectsEncodingCanvasAndContainerSubstitution() throws {
    let processor = ComposerImageAttachmentProcessor()
    let data = Fixture.lossless
    XCTAssertThrowsError(try processor.validateStoredData(data, matching: attachment(
      data: data, width: 8, height: 6, encoding: .jpeg))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .invalidSource)
    }
    XCTAssertThrowsError(try processor.validateStoredData(data, matching: attachment(
      data: data, width: 9, height: 6, encoding: .webp))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .invalidDimensions)
    }
    let disguised = Data("not-a-webp".utf8)
    XCTAssertThrowsError(try processor.validateStoredData(disguised, matching: attachment(
      data: disguised, width: 8, height: 6, encoding: .webp))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .invalidSource)
    }
  }

  func testBrokenLastFrameCannotPassImportOrStoredValidation() throws {
    var chunks = Fixture.chunks(Fixture.animated())
    let index = try XCTUnwrap(chunks.lastIndex { $0.type == "ANMF" })
    // Keep the VP8L size/signature valid, but remove the compressed image data.
    let frameHeader = Data(chunks[index].payload.prefix(16))
    let codecHeader = Data(chunks[index].payload.dropFirst(24).prefix(5))
    chunks[index].payload = frameHeader + Fixture.Chunk("VP8L", codecHeader + Data([0])).encoded
    let broken = Fixture.container(chunks)
    XCTAssertEqual(try ComposerWebPSanitizer.sanitize(broken) { $0 }.frameCount, 2)
    let processor = ComposerImageAttachmentProcessor()
    XCTAssertThrowsError(try processor.process(data: broken, quality: .original)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
    XCTAssertThrowsError(try processor.validateStoredData(broken, matching: attachment(
      data: broken, width: 8, height: 6, encoding: .webp))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
  }

  func testBrokenMiddleFrameCannotBeHiddenByHealthySurroundingFrames() throws {
    var chunks = Fixture.chunks(Fixture.animated(frameCount: 3))
    let frameIndices = chunks.indices.filter { chunks[$0].type == "ANMF" }
    XCTAssertEqual(frameIndices.count, 3)
    let index = frameIndices[1]
    let frameHeader = Data(chunks[index].payload.prefix(16))
    let codecHeader = Data(chunks[index].payload.dropFirst(24).prefix(5))
    // This is the same truncated codec used by the original failing last-frame
    // regression. A later healthy frame must not mask the intervening damage.
    chunks[index].payload = frameHeader + Fixture.Chunk("VP8L", codecHeader + Data([0])).encoded
    let broken = Fixture.container(chunks)
    let inspection = try ComposerWebPSanitizer.sanitize(broken) { $0 }
    XCTAssertEqual(inspection.frameCount, 3)
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    XCTAssertThrowsError(try processor.process(data: broken, quality: .original)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
    XCTAssertFalse(counter.indices.contains(2), "Stop before validating later frames after damage")
    XCTAssertThrowsError(try processor.validateStoredData(broken, matching: attachment(
      data: broken, width: 8, height: 6, encoding: .webp))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
  }

  func testBrokenStandaloneBitstreamFailsOriginalImportAndStoredValidation() throws {
    let original = try XCTUnwrap(Fixture.chunks(Fixture.lossless).first)
    let broken = Fixture.container([
      Fixture.Chunk("VP8L", Data(original.payload.prefix(5)) + Data([0]))
    ])
    let inspection = try ComposerWebPSanitizer.sanitize(broken) { $0 }
    XCTAssertFalse(inspection.isAnimated)
    XCTAssertEqual(inspection.frameCount, 1)
    let processor = ComposerImageAttachmentProcessor()
    XCTAssertThrowsError(try processor.process(data: broken, quality: .original)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
    XCTAssertThrowsError(try processor.validateStoredData(broken, matching: attachment(
      data: broken, width: 8, height: 6, encoding: .webp))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
  }

  func testStaticQualityConversionCannotTurnBrokenColorOrAlphaIntoBlankJPEG() throws {
    let codec = try XCTUnwrap(Fixture.chunks(Fixture.lossless).first)
    let brokenColor = Fixture.container([
      Fixture.Chunk("VP8L", Data(codec.payload.prefix(5)) + Data([0]))
    ])
    var alphaChunks = Fixture.chunks(Fixture.alphaLossy)
    let alphaIndex = try XCTUnwrap(alphaChunks.firstIndex { $0.type == "ALPH" })
    alphaChunks[alphaIndex].payload = Data([1, 0])
    let brokenAlpha = Fixture.container(alphaChunks)
    let processor = ComposerImageAttachmentProcessor()
    for source in [brokenColor, brokenAlpha] {
      XCTAssertEqual(try ComposerWebPSanitizer.sanitize(source) { $0 }.frameCount, 1)
      for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
        XCTAssertThrowsError(try processor.process(data: source, quality: quality)) {
          XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
        }
      }
    }
  }

  func testBareWebPCodecDataCannotBypassContainerValidation() throws {
    let codec = try XCTUnwrap(Fixture.chunks(Fixture.lossless).first)
    let processor = ComposerImageAttachmentProcessor()
    for source in [codec.payload, codec.encoded] {
      for quality in ComposerImageAttachmentQuality.allCases {
        XCTAssertThrowsError(try processor.process(data: source, quality: quality))
      }
    }
  }

  func testStrictBitstreamDecodeChecksBudgetAndDeclaredFrameDimensions() throws {
    let inspection = try ComposerWebPSanitizer.sanitize(Fixture.lossless) { $0 }
    let frame = try inspection.standaloneFrame(at: 0)
    try ComposerWebPBitstreamValidator.validate(frame, maximumDecodedBytes: 8 * 6 * 4)
    XCTAssertThrowsError(try ComposerWebPBitstreamValidator.validate(
      frame, maximumDecodedBytes: 8 * 6 * 4 - 1)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodedImageTooLarge)
    }
    let mismatch = ComposerWebPSanitizer.FrameImage(data: frame.data, width: 7, height: 6)
    XCTAssertThrowsError(try ComposerWebPBitstreamValidator.validate(
      mismatch, maximumDecodedBytes: 8 * 6 * 4)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
    }
    let overflow = ComposerWebPSanitizer.FrameImage(data: frame.data, width: Int.max, height: 6)
    XCTAssertThrowsError(try ComposerWebPBitstreamValidator.validate(
      overflow, maximumDecodedBytes: Int.max)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .decodedImageTooLarge)
    }
  }

  func testCorruptCompressedAlphaFailsStaticAndAnimatedImportAndStoredValidation() throws {
    var imageChunks = Fixture.chunks(Fixture.alphaLossy)
    let alphaIndex = try XCTUnwrap(imageChunks.firstIndex { $0.type == "ALPH" })
    // Compressed-alpha method 1 with a truncated lossless stream: libwebp's
    // header inspection accepts it, but its actual RGBA decode fails. Keep the
    // healthy VP8 color bitstream, so silently discarding alpha cannot pass.
    imageChunks[alphaIndex].payload = Data([1, 0])
    let brokenStatic = Fixture.container(imageChunks)

    var animation = Fixture.chunks(Fixture.animated())
    animation[0].payload[0] |= 0x10
    let frameIndex = try XCTUnwrap(animation.lastIndex { $0.type == "ANMF" })
    var frame = Data([0, 0, 0, 0, 0, 0, 7, 0, 0, 5, 0, 0, 130, 0, 0, 0])
    for chunk in imageChunks where chunk.type != "VP8X" { frame.append(chunk.encoded) }
    animation[frameIndex].payload = frame
    let brokenAnimation = Fixture.container(animation)

    let processor = ComposerImageAttachmentProcessor()
    for (data, frameCount) in [(brokenStatic, 1), (brokenAnimation, 2)] {
      let inspected = try ComposerWebPSanitizer.sanitize(data) { $0 }
      XCTAssertEqual(inspected.frameCount, frameCount)
      XCTAssertThrowsError(try processor.process(data: data, quality: .original)) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
      }
      XCTAssertThrowsError(try processor.validateStoredData(data, matching: attachment(
        data: data, width: 8, height: 6, encoding: .webp))) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .decodeFailed)
      }
    }
  }

  func testIndependentAnimationFrameValidationPreservesAlphaAndColorProfile() throws {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    let profile = try XCTUnwrap(space.copyICCData()) as Data
    for alpha in [Fixture.alphaLossy, Fixture.alphaLossless] {
      var chunks = Fixture.chunks(Fixture.animated())
      chunks[0].payload[0] |= 0x10
      let frameIndex = try XCTUnwrap(chunks.lastIndex { $0.type == "ANMF" })
      // A full 8x6 transparent second frame blends with the red first frame.
      var frame = Data([0, 0, 0, 0, 0, 0, 7, 0, 0, 5, 0, 0, 130, 0, 0, 0])
      for chunk in Fixture.chunks(alpha) where chunk.type != "VP8X" {
        frame.append(chunk.encoded)
      }
      chunks[frameIndex].payload = frame
      let input = Fixture.withMetadata(Fixture.container(chunks), orientation: 1, icc: profile)
      let counter = WebPDecodeCounter()
      let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
      let result = try processor.process(data: input, quality: .original)
      XCTAssertEqual(displayChunks(result.data), displayChunks(input))
      XCTAssertEqual(counter.indices, [0, 1])
      let inspection = try ComposerWebPSanitizer.sanitize(result.data) { $0 }
      let standalone = try inspection.standaloneFrame(at: 1)
      XCTAssertEqual(standalone.width, 8)
      XCTAssertEqual(standalone.height, 6)
      let independentPixels = try pixels(standalone.data)
      XCTAssertTrue(stride(from: 3, to: independentPixels.count, by: 4).contains {
        independentPixels[$0] == 0
      })
      let standaloneProfile = try XCTUnwrap(Fixture.chunks(standalone.data).first { $0.type == "ICCP" })
      XCTAssertEqual(standaloneProfile.payload, profile)
      try processor.validateStoredData(result.data, matching: attachment(result))
    }
  }

  func testAnimationResourceLimitsRejectBeforeFullFrameDecode() throws {
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    var tooWide = Fixture.chunks(Fixture.animated())
    tooWide[0].payload.replaceSubrange(4..<7, with: Fixture.littleEndian(4_096, bytes: 3))
    var tooLong = Fixture.chunks(Fixture.animated())
    let frame = try XCTUnwrap(tooLong.lastIndex { $0.type == "ANMF" })
    tooLong[frame].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(120_001, bytes: 3))
    for data in [Fixture.container(tooWide), Fixture.container(tooLong), Fixture.animated(frameCount: 501)] {
      XCTAssertThrowsError(try processor.process(data: data, quality: .original)) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .webPResourceLimit)
      }
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testCallerByteLimitRejectsOriginalBeforeDecoderWithoutRecompression() throws {
    let data = Fixture.animated()
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: counter.record)
    XCTAssertThrowsError(try processor.process(
      data: data, quality: .original, maximumByteCount: Int64(data.count - 1))) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .encodedImageTooLarge)
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testCancellationBetweenWebPFramesStopsDecodingAndPublication() async throws {
    let counter = WebPDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedWebPFrameDecode: { index in
      counter.record(index)
      if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let input = Fixture.animated(frameCount: 3)
    let task = Task.detached { try processor.process(data: input, quality: .original) }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation before decoding the second frame")
    } catch is CancellationError {}
    XCTAssertEqual(counter.indices, [0, 1])
  }

  private func attachment(_ result: ComposerProcessedImage) throws -> ComposerImageAttachment {
    try attachment(
      data: result.data, width: result.pixelWidth, height: result.pixelHeight,
      encoding: result.encoding, quality: result.quality)
  }

  private func attachment(
    data: Data, width: Int, height: Int, encoding: ComposerImageAttachmentEncoding,
    quality: ComposerImageAttachmentQuality = .original
  ) throws -> ComposerImageAttachment {
    try XCTUnwrap(ComposerImageAttachment(
      id: UUID(), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(data.count), pixelWidth: width, pixelHeight: height,
      encoding: encoding, quality: quality))
  }

  private func sourceFor(_ data: Data) throws -> CGImageSource {
    try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
  }

  private func displayChunks(_ data: Data) -> [Fixture.Chunk] {
    Fixture.chunks(data).filter { ["VP8 ", "VP8L", "ALPH", "ANIM", "ANMF"].contains($0.type) }
  }

  private func pixels(_ data: Data, index: Int = 0) throws -> [UInt8] {
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try sourceFor(data), index, nil))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(CGContext(
        data: storage.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    return bytes
  }
}

private final class WebPDecodeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []

  var indices: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  func record(_ index: Int) {
    lock.lock()
    values.append(index)
    lock.unlock()
  }
}
