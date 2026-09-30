import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerGIFSanitizerTests: XCTestCase {
  func testPreservesPartialFramesPalettesInterlaceDisposalTransparencyAndLZWBytes() throws {
    let first = control(delay: 7, disposal: 2, transparentIndex: 1) + frame()
    let second =
      control(delay: 11, disposal: 3)
      + frame(left: 2, top: 1, localPalette: true, interlaced: true)
    let source = gif(width: 3, height: 2, blocks: loop(0) + first + second)

    let inspection = try ComposerGIFSanitizer.sanitize(source)

    XCTAssertEqual(inspection.data, source)
    XCTAssertEqual(inspection.width, 3)
    XCTAssertEqual(inspection.height, 2)
    XCTAssertEqual(inspection.frameCount, 2)
    XCTAssertEqual(inspection.frameDelaysCentiseconds, [7, 11])
    XCTAssertEqual(inspection.loopCount, 0)
  }

  func testRemovesCommentsAndOpaqueApplicationMetadataWithoutConsumingPendingControl() throws {
    let privateText = Array("private GPS/location/camera information".utf8)
    let gce = control(delay: 4, disposal: 1, transparentIndex: 0)
    let cleanBlocks = loop(3) + gce + frame() + control(delay: 8) + frame()
    let metadata =
      comment(privateText)
      + application("XMP DataXMP", payload: privateText)
      + application("EXAMPLE1001", payload: [0x2C, 0x21, 0xF9, 0x3B])
    let source = gif(
      blocks: metadata + loop(3) + gce + metadata + frame()
        + control(delay: 8) + frame() + metadata)

    let sanitized = try ComposerGIFSanitizer.sanitize(source)

    XCTAssertEqual(sanitized.data, gif(blocks: cleanBlocks))
    XCTAssertEqual(sanitized.frameDelaysCentiseconds, [4, 8])
    XCTAssertEqual(sanitized.loopCount, 3)
    XCTAssertNil(sanitized.data.range(of: Data(privateText)))
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(sanitized.data), sanitized)
  }

  func testPreservesBothEstablishedLoopIdentifiersAndConsistentDuplicateLoops() throws {
    for identifier in ["NETSCAPE2.0", "ANIMEXTS1.0"] {
      let source = gif(blocks: loop(65_535, identifier: identifier) + frame())
      let result = try ComposerGIFSanitizer.sanitize(source)
      XCTAssertEqual(result.loopCount, 65_535)
      XCTAssertEqual(result.data, source)
    }
    let duplicate = gif(blocks: loop(2) + loop(2, identifier: "ANIMEXTS1.0") + frame())
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(duplicate).data, duplicate)
  }

  func testMissingAndZeroDelaysArePreservedWithoutInventingLoopOrTiming() throws {
    let source = gif(blocks: frame() + control(delay: 0) + frame())
    let result = try ComposerGIFSanitizer.sanitize(source)
    XCTAssertEqual(result.frameDelaysCentiseconds, [0, 0])
    XCTAssertNil(result.loopCount)
    XCTAssertEqual(result.data, source)
  }

  func testGIF87aStaticRemainsUnchangedAndReserved87aFieldsAreRejected() throws {
    let source = gif(version: "87a", blocks: frame())
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(source).data, source)
    var sortedGlobal = Array(source)
    sortedGlobal[10] |= 0x08
    assertRejected(Data(sortedGlobal), .invalidGIF)
    var aspect = Array(source)
    aspect[12] = 1
    assertRejected(Data(aspect), .invalidGIF)
    var sortedLocal = frame(localPalette: true)
    sortedLocal[9] |= 0x20
    assertRejected(gif(version: "87a", blocks: sortedLocal), .invalidGIF)
  }

  func testGIF87aSupportedExtensionsNormalizeOutputVersionAfterValidation() throws {
    for extensions in [
      control(delay: 1), loop(0), comment([1]),
      application("PRIVATE1001", payload: [1]),
    ] {
      let source = gif(version: "87a", blocks: extensions + frame())
      let expected = try ComposerGIFSanitizer.sanitize(gif(blocks: extensions + frame()))
      let result = try ComposerGIFSanitizer.sanitize(source)
      XCTAssertEqual(result, expected)
      XCTAssertEqual(try ComposerGIFSanitizer.sanitize(result.data), result)
    }
  }

  func testNativeImageIOGIF87aAnimationNormalizesOnlyVersionByte() throws {
    // Actual CGImageDestination output, captured on Apple's CI runner. The
    // header says 87a despite the NETSCAPE loop and two 89a control extensions.
    let source = try XCTUnwrap(
      Data(
        base64Encoded:
          "R0lGODdhCAAGAKIAAAAAAP8AAAD/AP///wAAAAAAAAAAAAAAACH/C05FVFNDQVBFMi4w"
          + "AwEAAAAh+QQFBwAEACwAAAAACAAGAAADBxi63P4wrgQAIfkEBQ0ABAAsAAAAAAgABgAA"
          + "Awcoutz+MK4EADs="))
    var expected = source
    expected[4] = UInt8(ascii: "9")

    let result = try ComposerGIFSanitizer.sanitize(source)

    XCTAssertEqual(result.data, expected)  // All palettes, controls and LZW bytes are unchanged.
    XCTAssertEqual(result.width, 8)
    XCTAssertEqual(result.height, 6)
    XCTAssertEqual(result.frameCount, 2)
    XCTAssertEqual(result.frameDelaysCentiseconds, [7, 13])
    XCTAssertEqual(result.loopCount, 0)
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(result.data), result)
  }

  func testGIF87aVersionNormalizationDoesNotRelaxOtherValidation() {
    assertRejected(gif(version: "87a", blocks: [0x21, 0x01] + frame()), .unsupportedGIF)
    assertRejected(gif(version: "87a", blocks: [0x21, 0xFC, 0] + frame()), .unsupportedGIF)
    assertRejected(
      gif(version: "87a", blocks: control(delay: 1) + control(delay: 2) + frame()), .invalidGIF)
    var badControl = control(delay: 1)
    badControl[3] |= 0x80
    assertRejected(gif(version: "87a", blocks: badControl + frame()), .invalidGIF)
    var sortedLocal = frame(localPalette: true)
    sortedLocal[9] |= 0x20
    assertRejected(gif(version: "87a", blocks: control(delay: 1) + sortedLocal), .invalidGIF)
    assertRejected(gif(version: "87a", blocks: control(delay: 12_001) + frame()), .resourceLimit)
    assertRejected(
      gif(version: "87a", blocks: control(delay: 1) + frame()) + Data([0]), .invalidGIF)
  }

  func testLocalPaletteCanReplaceMissingGlobalPaletteButDoesNotLeakToNextFrame() throws {
    let source = gif(globalPalette: false, blocks: frame(localPalette: true))
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(source).data, source)
    assertRejected(gif(globalPalette: false, blocks: frame()), .invalidGIF)
    assertRejected(
      gif(globalPalette: false, blocks: frame(localPalette: true) + frame()), .invalidGIF)
  }

  func testTransparentAndBackgroundIndicesMustBelongToTheirActivePalette() throws {
    assertRejected(gif(blocks: control(delay: 1, transparentIndex: 2) + frame()), .invalidGIF)
    let valid = gif(blocks: control(delay: 1, transparentIndex: 1) + frame(localPalette: true))
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(valid).data, valid)
    var badBackground = Array(gif(blocks: frame()))
    badBackground[11] = 2
    assertRejected(Data(badBackground), .invalidGIF)
  }

  func testPlainTextUnknownExtensionsICCAndUnknownLoopCommandsAreNotSilentlyRemoved() {
    assertRejected(gif(blocks: [0x21, 0x01] + frame()), .unsupportedGIF)
    assertRejected(gif(blocks: [0x21, 0xF0, 0] + frame()), .unsupportedGIF)
    assertRejected(gif(blocks: [0x21, 0xFC, 0] + frame()), .unsupportedGIF)
    assertRejected(
      gif(blocks: application("ICCRGBG1012", payload: [1, 2]) + frame()), .unsupportedGIF)
    assertRejected(
      gif(blocks: application("NETSCAPE3.0", payload: [1, 0, 0]) + frame()), .unsupportedGIF)
    assertRejected(
      gif(blocks: application("ANIMEXTS2.0", payload: [1, 0, 0]) + frame()), .unsupportedGIF)
    assertRejected(
      gif(blocks: application("NETSCAPE2.0", payload: [2, 0, 0]) + frame()), .unsupportedGIF)
    assertRejected(
      gif(blocks: application("NETSCAPE2.0", payload: [1, 0]) + frame()), .unsupportedGIF)
    assertRejected(gif(blocks: frame() + loop(0)), .unsupportedGIF)
    assertRejected(gif(blocks: loop(0) + loop(1) + frame()), .invalidGIF)
  }

  func testGCERejectsDuplicatePendingControlUnsupportedDisposalInputAndReservedBits() {
    assertRejected(
      gif(blocks: control(delay: 1) + comment([1]) + control(delay: 2) + frame()), .invalidGIF)
    assertRejected(gif(blocks: frame() + control(delay: 1)), .invalidGIF)
    for disposal in 4...7 {
      assertRejected(gif(blocks: control(delay: 1, disposal: disposal) + frame()), .unsupportedGIF)
    }
    var input = control(delay: 1)
    input[3] |= 2
    assertRejected(gif(blocks: input + frame()), .unsupportedGIF)
    var reserved = control(delay: 1)
    reserved[3] |= 0x80
    assertRejected(gif(blocks: reserved + frame()), .invalidGIF)
    var badSize = control(delay: 1)
    badSize[2] = 5
    assertRejected(gif(blocks: badSize + frame()), .invalidGIF)
    var badTerminator = control(delay: 1)
    badTerminator[7] = 1
    assertRejected(gif(blocks: badTerminator + frame()), .invalidGIF)
  }

  func testDescriptorBoundsDimensionsAndReservedBitsAreStrict() {
    for badFrame in [
      frame(left: 1), frame(top: 1), frame(width: 2), frame(height: 2),
      frame(width: 0), frame(height: 0),
    ] {
      assertRejected(gif(blocks: badFrame), .invalidGIF)
    }
    for flag: UInt8 in [0x08, 0x10] {
      var badFrame = frame()
      badFrame[9] |= flag
      assertRejected(gif(blocks: badFrame), .invalidGIF)
    }
    assertRejected(gif(width: 0, blocks: frame()), .invalidGIF)
    assertRejected(gif(height: 0, blocks: frame()), .invalidGIF)
  }

  func testTruncationAtEveryByteMissingTrailerTrailingDataAndNoFramesAreRejected() {
    let valid = gif(blocks: loop(0) + control(delay: 3) + frame())
    for length in 0..<valid.count {
      assertRejected(Data(valid.prefix(length)))
    }
    assertRejected(valid + Data([0]), .invalidGIF)
    assertRejected(valid + valid, .invalidGIF)
    assertRejected(gif(blocks: []), .invalidGIF)
    var badVersion = Array(valid)
    badVersion[4] = UInt8(ascii: "8")
    assertRejected(Data(badVersion), .invalidGIF)
  }

  func testLZWBlockFramingIsValidatedButCompressedBytesAreNotReencodedOrDecoded() throws {
    for codeSize: UInt8 in [0, 1, 9, 255] {
      var badFrame = frame()
      badFrame[10] = codeSize
      assertRejected(gif(blocks: badFrame), .invalidGIF)
    }
    var emptyPayload = frame()
    emptyPayload.replaceSubrange(11..., with: [0])
    assertRejected(gif(blocks: emptyPayload), .invalidGIF)
    var malformedSubBlock = frame()
    malformedSubBlock[11] = 255
    assertRejected(gif(blocks: malformedSubBlock), .invalidGIF)

    // Structurally bounded but invalid compressed codes belong to the caller's
    // per-frame ImageIO validation. The sanitizer must not invent an LZW decoder.
    var opaqueFrame = frame()
    opaqueFrame[12] = 255
    opaqueFrame[13] = 255
    let opaque = gif(blocks: opaqueFrame)
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(opaque).data, opaque)
  }

  func testDimensionPixelAndByteLimitsApplyBeforeAnyDecode() throws {
    XCTAssertEqual(
      try ComposerGIFSanitizer.sanitize(gif(width: 4_096, blocks: frame())).width, 4_096)
    assertRejected(gif(width: 4_097, blocks: frame()), .resourceLimit)
    XCTAssertEqual(
      try ComposerGIFSanitizer.sanitize(gif(width: 2_048, height: 2_048, blocks: frame())).width,
      2_048
    )
    assertRejected(gif(width: 2_048, height: 2_049, blocks: frame()), .resourceLimit)
    assertRejected(Data(repeating: 0, count: ComposerGIFSanitizer.maximumBytes + 1), .resourceLimit)
  }

  func testFrameCountAndTotalWorkLimitsCountWholeCanvasForPartialFrames() throws {
    let frame = frame()
    let maximum = gif(blocks: Array(repeating: frame, count: 500).flatMap { $0 })
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(maximum).frameCount, 500)
    assertRejected(gif(blocks: Array(repeating: frame, count: 501).flatMap { $0 }), .resourceLimit)
    let partials = Array(repeating: frame, count: 47).flatMap { $0 }
    XCTAssertEqual(
      try ComposerGIFSanitizer.sanitize(gif(width: 2_048, height: 1_024, blocks: partials))
        .frameCount,
      47
    )
    assertRejected(gif(width: 2_048, height: 1_024, blocks: partials + frame), .resourceLimit)
  }

  func testDurationBudgetUsesAtLeastTwoCentisecondsPerFrameButDoesNotMultiplyLoopCount() throws {
    let atLimit = gif(blocks: loop(0) + control(delay: 11_998) + frame() + frame())
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(atLimit).frameDelaysCentiseconds, [11_998, 0])
    let aboveLimit = gif(blocks: control(delay: 11_999) + frame() + control(delay: 1) + frame())
    assertRejected(aboveLimit, .resourceLimit)
    assertRejected(gif(blocks: control(delay: 12_001) + frame()), .resourceLimit)
    let finiteLoop = gif(blocks: loop(65_535) + control(delay: 12_000) + frame())
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(finiteLoop).loopCount, 65_535)
  }

  func testLargeMultiSubBlockMetadataIsRemovedAndMalformedApplicationHeadersReject() throws {
    let payload = [UInt8](repeating: 0xEE, count: 1_027)
    let source = gif(
      blocks: comment(payload) + application("PRIVATE1001", payload: payload) + frame())
    XCTAssertEqual(try ComposerGIFSanitizer.sanitize(source).data, gif(blocks: frame()))
    var bad = application("PRIVATE1001", payload: [1])
    bad[2] = 10
    assertRejected(gif(blocks: bad + frame()), .invalidGIF)
    bad = application("PRIVATE1001", payload: [1])
    bad[3] = 0
    assertRejected(gif(blocks: bad + frame()), .invalidGIF)
  }

  private func assertRejected(
    _ data: Data, _ expected: ComposerGIFSanitizerError? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try ComposerGIFSanitizer.sanitize(data), file: file, line: line) { error in
      if let expected {
        XCTAssertEqual(error as? ComposerGIFSanitizerError, expected, file: file, line: line)
      } else {
        XCTAssertNotNil(error as? ComposerGIFSanitizerError, file: file, line: line)
      }
    }
  }

  private func gif(
    version: String = "89a", width: Int = 1, height: Int = 1,
    globalPalette: Bool = true, blocks: [UInt8]
  ) -> Data {
    var bytes = Array("GIF\(version)".utf8)
    bytes += le(width)
    bytes += le(height)
    bytes += [globalPalette ? 0x80 : 0, 0, 0]
    if globalPalette { bytes += [0, 0, 0, 255, 255, 255] }
    bytes += blocks
    bytes.append(0x3B)
    return Data(bytes)
  }

  private func frame(
    left: Int = 0, top: Int = 0, width: Int = 1, height: Int = 1,
    localPalette: Bool = false, interlaced: Bool = false
  ) -> [UInt8] {
    let flags: UInt8 = (localPalette ? 0x80 : 0) | (interlaced ? 0x40 : 0)
    var bytes: [UInt8] = [0x2C]
    bytes += le(left)
    bytes += le(top)
    bytes += le(width)
    bytes += le(height)
    bytes.append(flags)
    if localPalette { bytes += [255, 0, 0, 0, 255, 0] }
    bytes += [2, 2, 0x44, 0x01, 0]
    return bytes
  }

  private func control(delay: Int, disposal: Int = 0, transparentIndex: UInt8? = nil) -> [UInt8] {
    let packed = UInt8(disposal << 2) | (transparentIndex == nil ? 0 : 1)
    return [0x21, 0xF9, 4, packed] + le(delay) + [transparentIndex ?? 0, 0]
  }

  private func loop(_ count: Int, identifier: String = "NETSCAPE2.0") -> [UInt8] {
    application(identifier, payload: [1] + le(count))
  }

  private func application(_ identifier: String, payload: [UInt8]) -> [UInt8] {
    [0x21, 0xFF, 11] + Array(identifier.utf8) + subBlocks(payload)
  }

  private func comment(_ payload: [UInt8]) -> [UInt8] {
    [0x21, 0xFE] + subBlocks(payload)
  }

  private func subBlocks(_ payload: [UInt8]) -> [UInt8] {
    var result = [UInt8]()
    for start in stride(from: 0, to: payload.count, by: 255) {
      let block = payload[start..<min(start + 255, payload.count)]
      result.append(UInt8(block.count))
      result.append(contentsOf: block)
    }
    result.append(0)
    return result
  }

  private func le(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
  }
}
