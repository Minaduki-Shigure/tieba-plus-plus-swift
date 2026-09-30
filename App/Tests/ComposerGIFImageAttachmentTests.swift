import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

final class ComposerGIFImageAttachmentTests: XCTestCase {
  func testImageIOEncodedAnimationRetainsFramesTimingLoopAndValidatedBytes() throws {
    let source = try encodedGIF()
    let counter = GIFDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedGIFFrameDecode: counter.record)
    let result = try processor.process(data: source, quality: .original)
    let inspection = try ComposerGIFSanitizer.sanitize(result.data)
    XCTAssertEqual(result.encoding, .gif)
    XCTAssertEqual(result.quality, .original)
    XCTAssertEqual(result.pixelWidth, 8)
    XCTAssertEqual(result.pixelHeight, 6)
    XCTAssertEqual(inspection.frameCount, 2)
    XCTAssertEqual(inspection.frameDelaysCentiseconds, [7, 13])
    XCTAssertEqual(inspection.loopCount, 0)
    XCTAssertEqual(result.data, try ComposerGIFSanitizer.sanitize(source).data)
    XCTAssertEqual(counter.indices, [0, 1])

    try processor.validateStoredData(result.data, matching: attachment(result))
    XCTAssertEqual(counter.indices, [0, 1, 0, 1])
    let decodedSource = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetType(decodedSource) as String?, UTType.gif.identifier)
    XCTAssertEqual(CGImageSourceGetCount(decodedSource), 2)
  }

  func testPartialFramesTransparencyAndDisposalArePreservedWithoutFlattening() throws {
    for (partial, transparent) in [(true, false), (false, true)] {
      let source = gifFixture(partialSecondFrame: partial, transparentSecondFrame: transparent)
      let processor = ComposerImageAttachmentProcessor()
      let result = try processor.process(data: source, quality: .original)
      XCTAssertEqual(result.data, source, "Display blocks must remain byte-exact")
      XCTAssertEqual(result.pixelWidth, 2)
      XCTAssertEqual(result.pixelHeight, 2)
      try processor.validateStoredData(result.data, matching: attachment(result))
      let decodedSource = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
      let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
      let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 1, nil))
      XCTAssertEqual(Set(try pixels(first)), [0xFF00_00FF])
      XCTAssertTrue(
        try pixels(second).contains(0x00FF_00FF), "The second frame must retain its green pixel")
    }
  }

  func testOneFrameGIFIsSupportedInOriginalMode() throws {
    let data = gifFixture(frameCount: 1)
    let result = try ComposerImageAttachmentProcessor().process(data: data, quality: .original)
    XCTAssertEqual(result.encoding, .gif)
    XCTAssertEqual(result.data, data)
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(result.data).frameCount, 1)
  }

  func testOtherQualitiesRejectGIFBeforeAnyFullFrameDecode() throws {
    let counter = GIFDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedGIFFrameDecode: counter.record)
    for quality in [ComposerImageAttachmentQuality.standard, .highQuality] {
      XCTAssertThrowsError(try processor.process(data: gifFixture(), quality: quality)) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .gifRequiresOriginal)
      }
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testPrivateCommentIsStrippedAndReinjectionCannotPassStoredValidation() throws {
    let processor = ComposerImageAttachmentProcessor()
    let clean = gifFixture()
    let dirty = insertingComment("private-location-and-account", in: clean)
    let result = try processor.process(data: dirty, quality: .original)
    XCTAssertEqual(result.data, clean)
    XCTAssertNil(result.data.range(of: Data("private-location-and-account".utf8)))
    try processor.validateStoredData(result.data, matching: attachment(result))

    // Even a recomputed digest and plausible metadata cannot authorize a raw,
    // unsanitized GIF; the store separately checks its original attachment hash.
    let forged = try attachment(data: dirty, width: 2, height: 2, encoding: .gif)
    XCTAssertThrowsError(try processor.validateStoredData(dirty, matching: forged)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .metadataWasNotRemoved)
    }
  }

  func testStoredGIFRejectsEncodingOrCanvasSubstitution() throws {
    let data = gifFixture()
    let processor = ComposerImageAttachmentProcessor()
    let wrongEncoding = try attachment(data: data, width: 2, height: 2, encoding: .jpeg)
    XCTAssertThrowsError(try processor.validateStoredData(data, matching: wrongEncoding)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .invalidSource)
    }
    let wrongDimensions = try attachment(data: data, width: 3, height: 2, encoding: .gif)
    XCTAssertThrowsError(try processor.validateStoredData(data, matching: wrongDimensions)) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .invalidDimensions)
    }
    let disguised = Data("not-a-gif".utf8)
    XCTAssertThrowsError(
      try processor.validateStoredData(
        disguised, matching: attachment(data: disguised, width: 2, height: 2, encoding: .gif)))
  }

  func testContainerResourceLimitsRejectBeforeImageIOFrameDecoding() throws {
    let counter = GIFDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedGIFFrameDecode: counter.record)
    var tooWide = gifFixture()
    tooWide[6] = 1
    tooWide[7] = 16  // 4097 pixels.
    var tooManyPixels = gifFixture()
    tooManyPixels[6] = 0
    tooManyPixels[7] = 8  // 2048 × 2049.
    tooManyPixels[8] = 1
    tooManyPixels[9] = 8
    var oversized = Data("GIF89a".utf8)
    oversized.append(Data(count: ComposerGIFSanitizer.maximumBytes))
    for source in [
      tooWide, tooManyPixels, oversized, gifFixture(frameCount: 501),
      gifFixture(frameCount: 2, frameDelay: 6_001),
      gifFixture(canvasWidth: 1_000, canvasHeight: 1_000, frameCount: 101),
    ] {
      XCTAssertThrowsError(try processor.process(data: source, quality: .original)) {
        XCTAssertEqual($0 as? ComposerImageProcessingError, .gifResourceLimit)
      }
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testSmallerCallerByteBudgetIsHonoredWithoutReencoding() throws {
    let source = gifFixture()
    let counter = GIFDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedGIFFrameDecode: counter.record)
    XCTAssertThrowsError(
      try processor.process(
        data: source, quality: .original, maximumByteCount: Int64(source.count - 1))
    ) {
      XCTAssertEqual($0 as? ComposerImageProcessingError, .encodedImageTooLarge)
    }
    XCTAssertTrue(counter.indices.isEmpty)
  }

  func testCancellationBetweenFramesStopsValidation() async throws {
    let counter = GIFDecodeCounter()
    let processor = ComposerImageAttachmentProcessor(beforeValidatedGIFFrameDecode: { index in
      counter.record(index)
      if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let source = gifFixture(frameCount: 3)
    let task = Task.detached { try processor.process(data: source, quality: .original) }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation while validating the second frame")
    } catch is CancellationError {}
    XCTAssertEqual(counter.indices, [0, 1])
  }

  private func attachment(_ image: ComposerProcessedImage) throws -> ComposerImageAttachment {
    try attachment(
      data: image.data, width: image.pixelWidth, height: image.pixelHeight, encoding: image.encoding
    )
  }

  private func attachment(
    data: Data, width: Int, height: Int, encoding: ComposerImageAttachmentEncoding
  ) throws -> ComposerImageAttachment {
    try XCTUnwrap(
      ComposerImageAttachment(
        id: UUID(), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        byteCount: Int64(data.count), pixelWidth: width, pixelHeight: height,
        encoding: encoding, quality: .original))
  }

  private func encodedGIF() throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.gif.identifier as CFString, 2, nil))
    CGImageDestinationSetProperties(
      destination,
      [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
      ] as CFDictionary)
    for (color, delay) in [(UInt32(0xFF00_00FF), 0.07), (UInt32(0x00FF_00FF), 0.13)] {
      var bytes = [UInt8]()
      for _ in 0..<(8 * 6) {
        bytes += [UInt8(color >> 24), UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), 255]
      }
      let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
      let image = try XCTUnwrap(
        CGImage(
          width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      CGImageDestinationAddImage(
        destination, image,
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
          ]
        ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func pixels(_ image: CGImage) throws -> [UInt32] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(
        CGContext(
          data: storage.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(
        image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    return stride(from: 0, to: bytes.count, by: 4).map { index in
      UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
        | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }
  }

  private func insertingComment(_ comment: String, in data: Data) -> Data {
    let bytes = [UInt8](comment.utf8)
    precondition(bytes.count <= 255)
    var output = Data(data.dropLast())
    output.append(contentsOf: [0x21, 0xFE, UInt8(bytes.count)] + bytes + [0, 0x3B])
    return output
  }

  private func gifFixture(
    canvasWidth: Int = 2, canvasHeight: Int = 2, frameCount: Int = 2,
    frameDelay: Int = 7, partialSecondFrame: Bool = false, transparentSecondFrame: Bool = false
  ) -> Data {
    func word(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8)] }
    var bytes = Array("GIF89a".utf8)
    bytes.append(contentsOf: word(canvasWidth))
    bytes.append(contentsOf: word(canvasHeight))
    bytes.append(contentsOf: [0x80, 0, 0, 255, 0, 0, 0, 255, 0])
    bytes.append(contentsOf: [0x21, 0xFF, 11])
    bytes.append(contentsOf: "NETSCAPE2.0".utf8)
    bytes.append(contentsOf: [3, 1, 0, 0, 0])
    for index in 0..<frameCount {
      let partial = index == 1 && partialSecondFrame
      let transparent = index == 1 && transparentSecondFrame
      let flags: UInt8 = index == 0 ? 4 : (transparent ? 13 : 8)
      bytes.append(contentsOf: [0x21, 0xF9, 4, flags])
      bytes.append(contentsOf: word(frameDelay))
      bytes.append(contentsOf: [0, 0, 0x2C])
      let frameOrigin = partial ? 1 : 0
      let frameDimension = partial ? 1 : 2
      bytes.append(contentsOf: word(frameOrigin))
      bytes.append(contentsOf: word(frameOrigin))
      bytes.append(contentsOf: word(frameDimension))
      bytes.append(contentsOf: word(frameDimension))
      bytes.append(0)
      let indices =
        partial ? [1] : (transparent ? [0, 1, 1, 0] : [Int](repeating: index % 2, count: 4))
      // Clear before each palette index keeps this tiny fixture's LZW width at 3 bits.
      let codes = indices.flatMap { [4, $0] } + [5]
      var compressed = [UInt8]()
      var accumulator = 0
      var bitCount = 0
      for code in codes {
        accumulator |= code << bitCount
        bitCount += 3
        if bitCount >= 8 {
          compressed.append(UInt8(accumulator & 255))
          accumulator >>= 8
          bitCount -= 8
        }
      }
      if bitCount > 0 { compressed.append(UInt8(accumulator & 255)) }
      bytes.append(contentsOf: [2, UInt8(compressed.count)])
      bytes.append(contentsOf: compressed)
      bytes.append(0)
    }
    bytes.append(0x3B)
    return Data(bytes)
  }
}

private final class GIFDecodeCounter: @unchecked Sendable {
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
