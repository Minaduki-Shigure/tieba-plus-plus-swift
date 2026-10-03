import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TiebaPlusPlus

@MainActor
final class WallpaperThemeImageProcessorTests: XCTestCase {
  func testPrepareDownsamplesBeforeReturningAndStripsImportedMetadata() throws {
    let data = try encodedImage(
      width: 2_800, height: 2_800, type: UTType.jpeg.identifier,
      properties: [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private comment"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private artist"],
      ])
    let imported = try properties(data)
    XCTAssertNotNil(imported[kCGImagePropertyGPSDictionary])
    XCTAssertNotNil(
      (imported[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
    XCTAssertNotNil(
      (imported[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
    let prepared = try WallpaperThemeImageProcessor.prepare(data: data)
    XCTAssertLessThanOrEqual(max(prepared.image.width, prepared.image.height), 2_048)
    XCTAssertLessThanOrEqual(prepared.image.width * prepared.image.height, 4_000_000)
    XCTAssertLessThanOrEqual(prepared.jpegData.count, 8 * 1_024 * 1_024)
    let output = try properties(prepared.jpegData)
    XCTAssertNil(output[kCGImagePropertyGPSDictionary])
    XCTAssertNil(output[kCGImagePropertyTIFFDictionary])
    if let exifValue = output[kCGImagePropertyExifDictionary] {
      let exif = try XCTUnwrap(exifValue as? [CFString: Any])
      XCTAssertNil(exif[kCGImagePropertyExifUserComment])
      // ImageIO can synthesize these image-description fields when encoding a
      // fresh sRGB JPEG. No imported/private EXIF fields may survive.
      let generatedFields: [CFString: Int] = [
        kCGImagePropertyExifColorSpace: 1,
        kCGImagePropertyExifPixelXDimension: prepared.image.width,
        kCGImagePropertyExifPixelYDimension: prepared.image.height,
      ]
      for (key, value) in exif {
        guard let expected = generatedFields[key] else {
          XCTFail("Unexpected output EXIF field: \(key)")
          continue
        }
        XCTAssertEqual((value as? NSNumber)?.intValue, expected, "\(key)")
      }
    }
    XCTAssertTrue((1...6).contains(prepared.palette.count))
    XCTAssertTrue(prepared.palette.allSatisfy { $0 <= 0xFF_FF_FF })
  }

  func testOrientationIsBakedIntoPixelsAndThumbnailBudgetIsRespected() throws {
    let data = try encodedImage(width: 800, height: 400, type: UTType.jpeg.identifier,
      properties: [kCGImagePropertyOrientation: 6])
    let prepared = try WallpaperThemeImageProcessor.prepare(data: data, maximumPixelDimension: 256)
    XCTAssertEqual(prepared.image.width, 128)
    XCTAssertEqual(prepared.image.height, 256)
    let output = try properties(prepared.jpegData)
    XCTAssertTrue(output[kCGImagePropertyOrientation] == nil || (output[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
  }

  func testPNGTransparencyIsFlattenedAgainstWhite() throws {
    let prepared = try WallpaperThemeImageProcessor.prepare(
      data: encodedImage(width: 40, height: 40, transparent: true))
    let pixel = try pixel(prepared.image, x: 20, y: 20)
    XCTAssertGreaterThan(pixel.red, 250)
    XCTAssertGreaterThan(pixel.green, 250)
    XCTAssertGreaterThan(pixel.blue, 250)
    XCTAssertEqual(prepared.image.alphaInfo, .noneSkipLast)
  }

  func testCropSelectsSourceRegionAndPaletteContainsBothDominantColors() throws {
    let source = try WallpaperThemeImageProcessor.prepare(
      data: encodedImage(width: 800, height: 400, splitColor: true))
    let left = try WallpaperThemeImageProcessor.render(
      source: source, crop: .init(centerX: 0.25, centerY: 0.5, zoom: 1), aspectRatio: 1, blurRadius: 0)
    let right = try WallpaperThemeImageProcessor.render(
      source: source, crop: .init(centerX: 0.75, centerY: 0.5, zoom: 1), aspectRatio: 1, blurRadius: 0)
    XCTAssertEqual(left.image.width, 400)
    XCTAssertEqual(left.image.height, 400)
    let red = try pixel(left.image, x: 200, y: 200)
    let blue = try pixel(right.image, x: 200, y: 200)
    XCTAssertGreaterThan(red.red, 230)
    XCTAssertLessThan(red.blue, 25)
    XCTAssertGreaterThan(blue.blue, 230)
    XCTAssertLessThan(blue.red, 25)
    XCTAssertTrue(source.palette.contains { (($0 >> 16) & 255) > 230 && ($0 & 255) < 25 })
    XCTAssertTrue(source.palette.contains { ($0 & 255) > 230 && (($0 >> 16) & 255) < 25 })
  }

  func testBlurHasFiniteExtentAndDoesNotDarkenWhiteEdges() throws {
    let source = try WallpaperThemeImageProcessor.prepare(data: encodedImage(width: 400, height: 400))
    let rendered = try WallpaperThemeImageProcessor.render(
      source: source, crop: .initial, aspectRatio: 0.5, blurRadius: 30)
    XCTAssertEqual(rendered.image.width, 200)
    XCTAssertEqual(rendered.image.height, 400)
    for (x, y) in [(0, 0), (199, 0), (0, 399), (199, 399), (100, 200)] {
      let sample = try pixel(rendered.image, x: x, y: y)
      XCTAssertGreaterThan(sample.red, 245)
      XCTAssertGreaterThan(sample.green, 245)
      XCTAssertGreaterThan(sample.blue, 245)
    }
    let output = try properties(rendered.jpegData)
    XCTAssertEqual((output[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 200)
    XCTAssertEqual((output[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 400)
  }

  func testValidNarrowPNGExceedingDimensionBudgetIsRejected() throws {
    // The real fixture needs only 640 KB of pixel storage, while its width is
    // over the app's declared-dimension limit. No enormous bitmap is allocated.
    let data = try encodedImage(width: 20_000, height: 8)
    XCTAssertLessThan(data.count, 1_024 * 1_024)
    let metadata = try properties(data)
    XCTAssertEqual((metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20_000)
    XCTAssertEqual((metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 8)
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: data)) {
      XCTAssertEqual($0 as? WallpaperThemeError, .imageTooLarge)
    }
  }

  func testMalformedOversizedPNGHeadersAreRejected() throws {
    let original = try encodedImage(width: 8, height: 8)
    for (width, height) in [(20_000, 8), (12_000, 12_000)] {
      let forged = try replacingPNGDimensions(original, width: width, height: height)
      XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: forged)) {
        let failure = $0 as? WallpaperThemeError
        XCTAssertTrue(failure == .invalidImage || failure == .imageTooLarge, "Unexpected error: \($0)")
      }
    }
  }

  func testRejectsEmptyOversizedAnimatedAndUnsupportedData() throws {
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: Data()))
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: Data("not an image".utf8)))
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(
      data: Data(repeating: 0, count: WallpaperThemeImageProcessor.maximumInputBytes + 1))) {
      XCTAssertEqual($0 as? WallpaperThemeError, .imageTooLarge)
    }
    let png = try encodedImage(width: 8, height: 8)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let animation = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(animation, UTType.gif.identifier as CFString, 2, nil))
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: animation as Data)) {
      XCTAssertEqual($0 as? WallpaperThemeError, .invalidImage)
    }
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: png, maximumPixelDimension: 0))
    XCTAssertThrowsError(try WallpaperThemeImageProcessor.prepare(data: png, maximumPixelDimension: 2_049))
  }

  func testRenderRejectsNonFiniteOrOutOfRangeSettings() throws {
    let source = try WallpaperThemeImageProcessor.prepare(data: encodedImage(width: 40, height: 40))
    for crop in [WallpaperCropState(centerX: .nan, centerY: 0.5, zoom: 1), .init(centerX: 0.5, centerY: 0.5, zoom: 5)] {
      XCTAssertThrowsError(try WallpaperThemeImageProcessor.render(source: source, crop: crop, aspectRatio: 1, blurRadius: 0))
    }
    for aspect in [Double.nan, .infinity, 0, 100] {
      XCTAssertThrowsError(try WallpaperThemeImageProcessor.render(source: source, crop: .initial, aspectRatio: aspect, blurRadius: 0))
    }
    for blur in [Double.nan, .infinity, -1, 31] {
      XCTAssertThrowsError(try WallpaperThemeImageProcessor.render(source: source, crop: .initial, aspectRatio: 1, blurRadius: blur))
    }
  }

  func testAlreadyCancelledWorkerDoesNotDecode() async {
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try WallpaperThemeImageProcessor.prepare(data: Data("not an image".utf8))
    }
    do {
      _ = try await task.value
      XCTFail("Cancellation must precede decoding")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testProcessingPermitSerializesOverlappingBitmapPipelines() {
    let probe = WallpaperProcessingConcurrencyProbe()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      do {
        try WallpaperThemeImageProcessor.withExclusiveProcessing {
          probe.enter()
          defer { probe.leave() }
          Thread.sleep(forTimeInterval: 0.005)
        }
      } catch { XCTFail("Unexpected permit failure: \(error)") }
    }
    XCTAssertEqual(probe.maximumConcurrent, 1)
    XCTAssertEqual(probe.completed, 8)
  }

  private func encodedImage(
    width: Int, height: Int, type: String = UTType.png.identifier,
    properties: [CFString: Any] = [:], transparent: Bool = false, splitColor: Bool = false
  ) throws -> Data {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    if !transparent {
      context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if splitColor {
      context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
      context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
      context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    }
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func properties(_ data: Data) throws -> [CFString: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
    let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4, space: colorSpace,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return (bytes[0], bytes[1], bytes[2])
  }

  private func replacingPNGDimensions(_ data: Data, width: Int, height: Int) throws -> Data {
    var result = data
    XCTAssertEqual(Array(result.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    guard result.count >= 33 else { throw WallpaperThemeError.invalidImage }
    for (offset, value) in [(16, width), (20, height)] {
      for index in 0..<4 { result[offset + index] = UInt8((value >> (24 - index * 8)) & 255) }
    }
    // Correct the IHDR CRC without resizing the pixel payload. ImageIO may
    // reject this malformed container before the app can inspect its dimensions.
    var crc: UInt32 = 0xFF_FF_FF_FF
    for byte in result[12..<29] {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xED_B8_83_20 : 0) }
    }
    crc ^= 0xFF_FF_FF_FF
    for index in 0..<4 { result[29 + index] = UInt8((crc >> (24 - index * 8)) & 255) }
    return result
  }
}

private final class WallpaperProcessingConcurrencyProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var peak = 0
  private var finished = 0
  var maximumConcurrent: Int { lock.withLock { peak } }
  var completed: Int { lock.withLock { finished } }

  func enter() {
    lock.withLock {
      active += 1
      peak = max(peak, active)
    }
  }

  func leave() {
    lock.withLock {
      active -= 1
      finished += 1
    }
  }
}
