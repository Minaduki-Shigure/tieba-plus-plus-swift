import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerWebPSanitizerTests: XCTestCase {
  private typealias Fixture = ComposerWebPTestFixture
  private typealias Chunk = ComposerWebPTestFixture.Chunk

  func testRealLossyLosslessAndBothAlphaEncodingsRetainEveryCodecByte() throws {
    for source in [Fixture.lossy, Fixture.lossless, Fixture.alphaLossless, Fixture.alphaLossy] {
      let result = try sanitize(source)
      XCTAssertEqual(result.data, source)
      XCTAssertEqual(result.width, 8)
      XCTAssertEqual(result.height, 6)
      XCTAssertEqual(result.frameCount, 1)
      XCTAssertFalse(result.isAnimated)
      XCTAssertEqual(result.frameDurationsMilliseconds, [])
      XCTAssertNil(result.loopCount)
      XCTAssertEqual(result.orientation, 1)
    }
  }

  func testPartialAnimationPreservesTimingLoopBackgroundBlendDisposalAndCodecData() throws {
    for loop in [0, 3, 65_535] {
      var chunks = Fixture.chunks(Fixture.animated(loopCount: loop))
      chunks[1].payload.replaceSubrange(0..<4, with: [12, 34, 56, 78])
      let source = Fixture.container(chunks)
      let result = try sanitize(source)
      XCTAssertEqual(result.data, source)
      XCTAssertTrue(result.isAnimated)
      XCTAssertEqual(result.frameCount, 2)
      XCTAssertEqual(result.frameDurationsMilliseconds, [70, 130])
      XCTAssertEqual(result.loopCount, loop)
      XCTAssertEqual(result.width, 8)
      XCTAssertEqual(result.height, 6)
    }
  }

  func testSingleFrameAnimationAndZeroDurationAreNotReclassifiedOrRetimed() throws {
    var chunks = Fixture.chunks(Fixture.animated(frameCount: 1))
    chunks[2].payload.replaceSubrange(12..<15, with: [0, 0, 0])
    let result = try sanitize(Fixture.container(chunks))
    XCTAssertTrue(result.isAnimated)
    XCTAssertEqual(result.frameCount, 1)
    XCTAssertEqual(result.frameDurationsMilliseconds, [0])
    XCTAssertEqual(result.loopCount, 3)
  }

  func testMetadataBetweenReconstructionChunksAndInsideFramesIsRemoved() throws {
    let source = Fixture.withMetadata(Fixture.alphaLossy)
    var chunks = Fixture.chunks(source)
    let exif = chunks.remove(at: chunks.firstIndex { $0.type == "EXIF" }!)
    let xmp = chunks.remove(at: chunks.firstIndex { $0.type == "XMP " }!)
    chunks.insert(exif, at: 1)
    chunks.insert(xmp, at: 3)  // Metadata between ALPH and VP8 is allowed.
    chunks.insert(Chunk("PRIV", Data("private-field".utf8)), at: 2)
    let result = try sanitize(Fixture.container(chunks))
    XCTAssertEqual(result, try sanitize(source))
    XCTAssertEqual(result.orientation, 6)
    XCTAssertNil(result.data.range(of: Data("private".utf8)))

    var animated = Fixture.chunks(Fixture.animated())
    animated[2].payload.append(Chunk("PRIV", Data("frame-private".utf8)).encoded)
    animated.append(Chunk("JUNK", Data([1, 2, 3])))
    XCTAssertEqual(try sanitize(Fixture.container(animated)).data, Fixture.animated())
    XCTAssertEqual(try sanitize(result.data), result)
  }

  func testBothEXIFByteOrdersAndExifPrefixKeepAllEightOrientationsOnly() throws {
    for orientation in 1...8 {
      for bigEndian in [false, true] {
        for prefix in [false, true] {
          var chunks = Fixture.chunks(Fixture.withMetadata(Fixture.lossless))
          let index = chunks.firstIndex { $0.type == "EXIF" }!
          chunks[index].payload = exif(orientation: orientation, bigEndian: bigEndian)
          if prefix { chunks[index].payload = Data("Exif\0\0".utf8) + chunks[index].payload }
          let result = try sanitize(Fixture.container(chunks))
          XCTAssertEqual(result.orientation, orientation)
          XCTAssertEqual(
            Fixture.chunks(result.data).last?.payload,
            Data("Exif\0\0".utf8) + exif(orientation: orientation))
          XCTAssertEqual(try sanitize(result.data), result)
        }
      }
    }
  }

  func testEXIFWithoutOrientationDefaultsToIdentityAndDoesNotFollowPrivateDirectories() throws {
    var chunks = Fixture.chunks(Fixture.withMetadata(Fixture.lossless))
    let index = chunks.firstIndex { $0.type == "EXIF" }!
    // An empty IFD0 with a pointer to an unrelated thumbnail directory is discarded.
    chunks[index].payload =
      Data([0x49, 0x49, 42, 0, 8, 0, 0, 0, 0, 0, 14, 0, 0, 0])
      + Data("private-thumbnail".utf8)
    let result = try sanitize(Fixture.container(chunks))
    XCTAssertEqual(result.orientation, 1)
    XCTAssertEqual(
      Fixture.chunks(result.data).last?.payload, Data("Exif\0\0".utf8) + exif(orientation: 1))
  }

  func testColorProfileUsesCanonicalizerAndPreservesPixelAndAnimationChunks() throws {
    let inputProfile = profile(marker: 0x55)
    let outputProfile = profile(marker: 0x66)
    let source = Fixture.withMetadata(Fixture.animated(), icc: inputProfile)
    var calls = [Data]()
    let result = try ComposerWebPSanitizer.sanitize(source) { input in
      calls.append(input)
      return outputProfile
    }
    XCTAssertEqual(calls, [inputProfile])
    let chunks = Fixture.chunks(result.data)
    XCTAssertEqual(chunks.first { $0.type == "ICCP" }?.payload, outputProfile)
    XCTAssertEqual(
      chunks.filter { ["ANIM", "ANMF"].contains($0.type) },
      Fixture.chunks(source).filter { ["ANIM", "ANMF"].contains($0.type) })
    XCTAssertEqual(try sanitize(result.data), result)
  }

  func testProfileSizeAndHeaderAreValidatedBeforeCanonicalizerAndOnItsResult() throws {
    let valid = Fixture.withMetadata(Fixture.lossless, icc: profile(marker: 0))
    for malformed in [Data(), Data(repeating: 0, count: 128), profile(marker: 0).dropLast()] {
      var chunks = Fixture.chunks(valid)
      chunks[1].payload = Data(malformed)
      var called = false
      XCTAssertThrowsError(
        try ComposerWebPSanitizer.sanitize(Fixture.container(chunks)) {
          called = true
          return $0
        })
      XCTAssertFalse(called)
    }
    var oversized = Fixture.chunks(valid)
    oversized[1].payload = Data(repeating: 0, count: 256 * 1_024 + 1)
    assertRejected(Fixture.container(oversized), .resourceLimit)
    XCTAssertThrowsError(try ComposerWebPSanitizer.sanitize(valid) { _ in Data() }) {
      XCTAssertEqual($0 as? ComposerWebPSanitizerError, .unsupportedWebP)
    }
    XCTAssertThrowsError(
      try ComposerWebPSanitizer.sanitize(valid) { _ in
        throw CancellationError()
      }
    ) { XCTAssertTrue($0 is CancellationError) }
  }

  func testEveryTruncationAndTrailingDataAreRejectedWithoutReadingOutsideInput() {
    for source in [Fixture.lossy, Fixture.alphaLossy, Fixture.withMetadata(Fixture.animated())] {
      for length in 0..<source.count {
        assertRejected(Data(source.prefix(length)), .invalidWebP)
        if length >= 12 {
          // Update RIFF size too, to exercise chunk/subchunk/EXIF boundaries
          // rather than stopping every truncated input at the outer size field.
          var internallyTruncated = Data(source.prefix(length))
          internallyTruncated.replaceSubrange(
            4..<8, with: Fixture.littleEndian(length - 8, bytes: 4))
          assertRejected(internallyTruncated, .invalidWebP)
        }
      }
      assertRejected(source + Data([0, 0]), .invalidWebP)
    }
    var invalidLength = Fixture.lossless
    invalidLength.replaceSubrange(16..<20, with: [255, 255, 255, 255])
    assertRejected(invalidLength, .invalidWebP)
    var wrongType = Fixture.lossless
    wrongType[8] = 0
    assertRejected(wrongType, .invalidWebP)
  }

  func testNonzeroAndMissingOddChunkPaddingAreRejectedIncludingFrameSubchunks() {
    let chunks = Fixture.chunks(Fixture.lossless) + [Chunk("JUNK", Data([1]))]
    var nonzero = Fixture.container(chunks)
    nonzero[nonzero.count - 1] = 9
    assertRejected(nonzero, .invalidWebP)
    var missing = Data(nonzero.dropLast())
    missing.replaceSubrange(4..<8, with: Fixture.littleEndian(missing.count - 8, bytes: 4))
    assertRejected(missing, .invalidWebP)
    var frames = Fixture.chunks(Fixture.animated())
    var unknown = Chunk("JUNK", Data([1])).encoded
    unknown[unknown.count - 1] = 1
    frames[2].payload.append(unknown)
    assertRejected(Fixture.container(frames), .invalidWebP)
  }

  func testDuplicateOrOutOfOrderReconstructionChunksAreRejected() {
    let still = Fixture.chunks(Fixture.alphaLossy)
    let animation = Fixture.chunks(Fixture.animated())
    let colored = Fixture.chunks(Fixture.withMetadata(Fixture.lossless, icc: profile(marker: 0)))
    for chunks in [
      [still[1], still[0], still[2]],
      [still[0], still[0], still[1], still[2]],
      [still[0], still[1], still[1], still[2]],
      [still[0], still[2], still[1]],
      [still[0], still[1], still[2], still[2]],
      [animation[0], animation[2], animation[1]],
      [animation[0], animation[1], animation[1], animation[2]],
      [animation[0], animation[1], Fixture.chunks(Fixture.lossless)[0]],
      [colored[0], colored[2], colored[1], colored[3], colored[4]],
      [colored[0], colored[1], colored[1], colored[2], colored[3], colored[4]],
      [still[0], still[1], Fixture.chunks(Fixture.lossless)[0]],
    ] { assertRejected(Fixture.container(chunks), .invalidWebP) }
  }

  func testFeatureFlagsMustMatchPresentChunksAndReservedBitsAreRejected() {
    for bit: UInt8 in [0x01, 0x02, 0x04, 0x08, 0x20, 0x40, 0x80] {
      var chunks = Fixture.chunks(Fixture.alphaLossy)
      chunks[0].payload[0] |= bit
      assertRejected(Fixture.container(chunks), .invalidWebP)
    }
    var alpha = Fixture.chunks(Fixture.alphaLossy)
    alpha[0].payload[0] &= ~0x10
    assertRejected(Fixture.container(alpha), .invalidWebP)
    var opaque = Fixture.chunks(Fixture.withMetadata(Fixture.lossy))
    opaque[0].payload[0] |= 0x10
    assertRejected(Fixture.container(opaque), .invalidWebP)
    var reserved = Fixture.chunks(Fixture.alphaLossy)
    reserved[0].payload[2] = 1
    assertRejected(Fixture.container(reserved), .invalidWebP)
    var duplicate = Fixture.chunks(Fixture.withMetadata(Fixture.lossless))
    duplicate.append(duplicate[2])
    assertRejected(Fixture.container(duplicate), .invalidWebP)
  }

  func testLosslessAlphaHintDoesNotOverrideDecodedTransparencyOrContainerFlags() throws {
    var chunks = Fixture.chunks(Fixture.withMetadata(Fixture.alphaLossless))
    chunks[1].payload[4] &= ~0x10  // VP8L alpha_is_used is only a hint.
    XCTAssertNoThrow(try sanitize(Fixture.container(chunks)))
    chunks[0].payload[0] &= ~0x10
    XCTAssertNoThrow(try sanitize(Fixture.container(chunks)))
  }

  func testBitmapHeadersAndCanvasDimensionsMustAgree() {
    var dimension = Fixture.chunks(Fixture.alphaLossy)
    dimension[0].payload[4] = 8
    assertRejected(Fixture.container(dimension), .invalidWebP)
    var lossy = Fixture.chunks(Fixture.lossy)
    lossy[0].payload[3] = 0
    assertRejected(Fixture.container(lossy), .invalidWebP)
    lossy = Fixture.chunks(Fixture.lossy)
    lossy[0].payload[0] |= 1
    assertRejected(Fixture.container(lossy), .invalidWebP)
    lossy = Fixture.chunks(Fixture.lossy)
    lossy[0].payload[7] |= 0x40
    assertRejected(Fixture.container(lossy), .unsupportedWebP)
    var lossless = Fixture.chunks(Fixture.lossless)
    lossless[0].payload[4] |= 0x20
    assertRejected(Fixture.container(lossless), .unsupportedWebP)
  }

  func testFrameRectanglesSubchunkDimensionsAndReservedFlagsMustAgree() {
    for (index, value): (Int, UInt8) in [(0, 4), (3, 3), (6, 8), (9, 6), (15, 4)] {
      var chunks = Fixture.chunks(Fixture.animated())
      chunks[2].payload[index] = value
      assertRejected(Fixture.container(chunks), .invalidWebP)
    }
    var mismatch = Fixture.chunks(Fixture.animated())
    mismatch[2].payload[6] = 6  // Rectangle fits canvas but differs from VP8L header.
    assertRejected(Fixture.container(mismatch), .invalidWebP)
    var nested = Fixture.chunks(Fixture.animated())
    nested[2].payload.append(Chunk("ANIM", Data(repeating: 0, count: 6)).encoded)
    assertRejected(Fixture.container(nested), .invalidWebP)
    var duplicate = Fixture.chunks(Fixture.animated())
    duplicate[2].payload.append(Fixture.lossless.dropFirst(12))
    assertRejected(Fixture.container(duplicate), .invalidWebP)
  }

  func testUncompressedAlphaLengthAndUnsupportedMethodsAreChecked() throws {
    let raw = Data([0]) + Data(repeating: 128, count: 8 * 6)
    var chunks = Fixture.chunks(Fixture.alphaLossy)
    chunks[1].payload = raw
    XCTAssertEqual(try sanitize(Fixture.container(chunks)).data, Fixture.container(chunks))
    chunks[1].payload.removeLast()
    assertRejected(Fixture.container(chunks), .invalidWebP)
    for (header, error): (UInt8, ComposerWebPSanitizerError) in [
      (0x80, .invalidWebP), (0x02, .unsupportedWebP), (0x20, .unsupportedWebP),
    ] {
      chunks[1].payload = raw
      chunks[1].payload[0] = header
      assertRejected(Fixture.container(chunks), error)
    }
  }

  func testStaticAndAnimatedDimensionsAndAggregateDecodeBudgetAreBounded() throws {
    let maxStatic = syntheticLossless(width: 16_384, height: 768)
    XCTAssertEqual(try sanitize(maxStatic).width, 16_384)
    assertRejected(syntheticLossless(width: 16_384, height: 769), .resourceLimit)
    var animated = Fixture.chunks(Fixture.animated())
    animated[0].payload.replaceSubrange(
      4..<10,
      with:
        Fixture.littleEndian(4_096, bytes: 3) + Fixture.littleEndian(5, bytes: 3))
    assertRejected(Fixture.container(animated), .resourceLimit)
    animated = Fixture.chunks(Fixture.animated(frameCount: 24))
    animated[0].payload.replaceSubrange(
      4..<10,
      with:
        Fixture.littleEndian(4_095, bytes: 3) + Fixture.littleEndian(1_023, bytes: 3))
    assertRejected(Fixture.container(animated), .resourceLimit)
    animated.removeLast()
    XCTAssertEqual(try sanitize(Fixture.container(animated)).frameCount, 23)
  }

  func testFrameCountAndTotalDurationLimitsIncludeZeroDelayAndOneLongFrame() throws {
    XCTAssertEqual(try sanitize(Fixture.animated(frameCount: 500)).frameCount, 500)
    assertRejected(Fixture.animated(frameCount: 501), .resourceLimit)
    var frames = Fixture.chunks(Fixture.animated(frameCount: 1))
    frames[2].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(120_000, bytes: 3))
    XCTAssertEqual(try sanitize(Fixture.container(frames)).frameDurationsMilliseconds, [120_000])
    frames[2].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(120_001, bytes: 3))
    assertRejected(Fixture.container(frames), .resourceLimit)
    frames = Fixture.chunks(Fixture.animated())
    frames[2].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(119_900, bytes: 3))
    assertRejected(Fixture.container(frames), .resourceLimit)
    frames[2].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(119_990, bytes: 3))
    frames[3].payload.replaceSubrange(12..<15, with: [0, 0, 0])
    assertRejected(Fixture.container(frames), .resourceLimit)
    frames[2].payload.replaceSubrange(12..<15, with: Fixture.littleEndian(119_980, bytes: 3))
    XCTAssertEqual(
      try sanitize(Fixture.container(frames)).frameDurationsMilliseconds, [119_980, 0])
  }

  func testInputLimitAllowsLargeMetadataToBeRemovedBeforeOriginalOutputLimit() throws {
    let source = Fixture.container(
      Fixture.chunks(Fixture.lossless)
        + [Chunk("PRIV", Data(repeating: 0x55, count: 11 * 1_024 * 1_024))])
    XCTAssertEqual(try sanitize(source).data, Fixture.lossless)
    assertRejected(Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1), .resourceLimit)
  }

  func testMalformedEXIFDoesNotSilentlyLoseOrInventOrientation() {
    var duplicate = exif(orientation: 6)
    duplicate.replaceSubrange(8..<10, with: [2, 0])
    duplicate.insert(contentsOf: duplicate[10..<22], at: 22)
    var invalidOffset = exif(orientation: 6)
    invalidOffset.replaceSubrange(4..<8, with: [255, 255, 255, 255])
    var invalidType = exif(orientation: 6)
    invalidType[12] = 4
    var invalidCount = exif(orientation: 6)
    invalidCount[14] = 2
    var malformed = [
      Data(), duplicate, invalidOffset, invalidType, invalidCount,
      exif(orientation: 0), exif(orientation: 9),
    ]
    malformed.append(Data(exif(orientation: 6).dropLast()))
    for metadata in malformed {
      var chunks = Fixture.chunks(Fixture.withMetadata(Fixture.lossless))
      chunks[2].payload = metadata
      assertRejected(Fixture.container(chunks), .invalidWebP)
    }
  }

  func testStandaloneStaticFramesKeepRealCodecAndAlphaChunksWithoutCopyingMetadata() throws {
    for source in [Fixture.lossy, Fixture.lossless, Fixture.alphaLossless, Fixture.alphaLossy] {
      let inspection = try sanitize(source)
      let frame = try inspection.standaloneFrame(at: 0)
      XCTAssertEqual(frame.data, source)
      XCTAssertEqual(frame.width, 8)
      XCTAssertEqual(frame.height, 6)
      XCTAssertFalse(try sanitize(frame.data).isAnimated)
      XCTAssertThrowsError(try inspection.standaloneFrame(at: -1))
      XCTAssertThrowsError(try inspection.standaloneFrame(at: 1))
    }
  }

  func testStandaloneAnimationFramesUseTheirOwnRectanglesCodecOrderAndCanonicalProfile() throws {
    var source = Fixture.chunks(
      Fixture.withMetadata(Fixture.animated(), orientation: 6, icc: profile(marker: 0x55)))
    // The canonical profile grows, EXIF moves, and a private frame chunk is removed.
    // Frame descriptors must refer into the rebuilt output, never the input offsets.
    let exif = source.remove(at: source.firstIndex { $0.type == "EXIF" }!)
    source.insert(exif, at: 1)
    for index in source.indices where source[index].type == "ANMF" {
      source[index].payload.append(Chunk("PRIV", Data("frame-private".utf8)).encoded)
    }
    var canonicalProfile = profile(marker: 0x66) + Data(repeating: 0, count: 128)
    canonicalProfile[2] = 1
    canonicalProfile[3] = 0
    let inspection = try ComposerWebPSanitizer.sanitize(Fixture.container(source)) { _ in
      canonicalProfile
    }
    let sourceFrames = Fixture.chunks(Fixture.animated()).filter { $0.type == "ANMF" }
    for index in 0..<2 {
      let frame = try inspection.standaloneFrame(at: index)
      XCTAssertEqual(frame.width, index == 0 ? 8 : 4)
      XCTAssertEqual(frame.height, index == 0 ? 6 : 2)
      let chunks = Fixture.chunks(frame.data)
      XCTAssertEqual(chunks.map(\.type), ["VP8X", "ICCP", "VP8L"])
      XCTAssertEqual(chunks[1].payload, canonicalProfile)
      XCTAssertEqual(chunks[2].encoded, Data(sourceFrames[index].payload.dropFirst(16)))
      let still = try sanitize(frame.data)
      XCTAssertEqual(still.width, frame.width)
      XCTAssertEqual(still.height, frame.height)
      XCTAssertEqual(still.orientation, 1)
      XCTAssertFalse(still.isAnimated)
      XCTAssertEqual(still.frameCount, 1)
      XCTAssertEqual(still.frameDurationsMilliseconds, [])
      XCTAssertNil(still.loopCount)
      XCTAssertEqual(try still.standaloneFrame(at: 0).data, frame.data)
    }
    XCTAssertEqual(inspection.orientation, 6)
    XCTAssertThrowsError(try inspection.standaloneFrame(at: 2))
  }

  func testStandaloneAnimatedLossyAlphaPreservesAllCodecChunks() throws {
    let stillChunks = Fixture.chunks(Fixture.alphaLossy)
    var animation = Fixture.chunks(Fixture.animated(frameCount: 1))
    animation[0].payload[0] |= 0x10
    animation[2].payload =
      Data(animation[2].payload.prefix(16))
      + stillChunks[1].encoded + stillChunks[2].encoded
    let inspection = try sanitize(Fixture.container(animation))
    XCTAssertEqual(try inspection.standaloneFrame(at: 0).data, Fixture.alphaLossy)
    XCTAssertEqual(inspection.frameDurationsMilliseconds, [70])
  }

  func testStandaloneBrokenFrameDoesNotReusePreviousValidBitstream() throws {
    var chunks = Fixture.chunks(Fixture.animated())
    let previousCodec = Fixture.chunks(Fixture.lossless)[0]
    let codecHeader = Data(chunks[3].payload.dropFirst(24).prefix(5))
    let brokenCodec = Chunk("VP8L", codecHeader + Data([0]))
    chunks[3].payload = Data(chunks[3].payload.prefix(16)) + brokenCodec.encoded
    let inspection = try sanitize(Fixture.container(chunks))
    XCTAssertEqual(Fixture.chunks(try inspection.standaloneFrame(at: 0).data), [previousCodec])
    XCTAssertEqual(Fixture.chunks(try inspection.standaloneFrame(at: 1).data), [brokenCodec])
    // The container remains valid; native ImageIO tests must reject this isolated
    // broken codec instead of accepting a canvas the animation compositor reports as complete.
    XCTAssertEqual(try inspection.standaloneFrame(at: 1).width, 4)
    XCTAssertEqual(try inspection.standaloneFrame(at: 1).height, 2)
  }

  func testStandaloneFrameChecksCancellationBeforeBuildingOutput() async throws {
    let inspection = try sanitize(Fixture.animated())
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try inspection.standaloneFrame(at: 0)
    }
    do {
      _ = try await task.value
      XCTFail("Expected a cancelled caller to stop before frame construction")
    } catch is CancellationError {}
  }

  private func sanitize(_ data: Data) throws -> ComposerWebPSanitizer.Inspection {
    try ComposerWebPSanitizer.sanitize(data, canonicalColorProfile: { $0 })
  }

  private func assertRejected(
    _ data: Data, _ expected: ComposerWebPSanitizerError,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try sanitize(data), file: file, line: line) {
      XCTAssertEqual($0 as? ComposerWebPSanitizerError, expected, file: file, line: line)
    }
  }

  private func profile(marker: UInt8) -> Data {
    var data = Data(repeating: 0, count: 128)
    data[3] = 128
    data.replaceSubrange(36..<40, with: "acsp".utf8)
    data[100] = marker
    return data
  }

  private func exif(orientation: Int, bigEndian: Bool = false) -> Data {
    if bigEndian {
      return Data([
        0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 1, 0x12, 0, 3, 0, 0, 0, 1,
        0, UInt8(orientation), 0, 0, 0, 0, 0, 0,
      ])
    }
    return Data([
      0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0,
      UInt8(orientation), 0, 0, 0, 0, 0, 0, 0,
    ])
  }

  private func syntheticLossless(width: Int, height: Int) -> Data {
    var chunks = Fixture.chunks(Fixture.lossless)
    let packed = (width - 1) | ((height - 1) << 14)
    chunks[0].payload.replaceSubrange(1..<5, with: Fixture.littleEndian(packed, bytes: 4))
    return Fixture.container(chunks)
  }
}
