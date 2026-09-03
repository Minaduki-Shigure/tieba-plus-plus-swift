import ImageIO
import TiebaCore
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ProfileAvatarImageProcessorTests: XCTestCase {
  private let processor = ProfileAvatarImageProcessor()

  func testPrepareNormalizesToBoundedMetadataFreeJPEG() async throws {
    let sourceData = try imageData(
      width: 2_400,
      height: 1_200,
      properties: [
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitudeRef: "N",
          kCGImagePropertyGPSLatitude: 31.2304,
          kCGImagePropertyGPSLongitudeRef: "E",
          kCGImagePropertyGPSLongitude: 121.4737,
        ],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private"],
      ]
    )
    let sourceProperties = try imageProperties(sourceData)
    XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
    XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary])
    XCTAssertNotNil(sourceProperties[kCGImagePropertyTIFFDictionary])

    let source = try await processor.prepare(data: sourceData)

    XCTAssertEqual(source.pixelWidth, 2_400)
    XCTAssertEqual(source.pixelHeight, 1_200)
    XCTAssertEqual(imageType(source.data), UTType.jpeg.identifier)
    let properties = try imageProperties(source.data)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    XCTAssertNil(properties[kCGImagePropertyExifDictionary])
    XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
    XCTAssertFalse(source.description.contains("private"))
  }

  func testMakeUploadProducesFixedSquareValidatedJPEG() async throws {
    let source = try await processor.prepare(data: try splitColorImageData())

    let upload = try await processor.makeUpload(source: source, state: .initial)

    XCTAssertEqual(upload.pixelSize, 960)
    XCTAssertLessThanOrEqual(
      Int64(upload.jpegData.count),
      ComposerImageAttachmentQuality.standard.maximumByteCount
    )
    XCTAssertLessThanOrEqual(
      upload.jpegData.count,
      AccountProfileAvatarUpload.maximumByteCount
    )
    XCTAssertEqual(imageType(upload.jpegData), UTType.jpeg.identifier)
    let properties = try imageProperties(upload.jpegData)
    XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 960)
    XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 960)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    XCTAssertNil(properties[kCGImagePropertyExifDictionary])
    let coreUpload = TiebaSelfProfileAvatarUpload(
      uploadID: upload.uploadID,
      jpegData: upload.jpegData,
      squarePixelSize: upload.pixelSize
    )
    XCTAssertTrue(TiebaSelfProfileAvatarUploadPolicy.isValid(coreUpload))
  }

  func testCropStateSelectsDifferentSourceRegions() async throws {
    let source = try await processor.prepare(data: try splitColorImageData())
    let leftState = ProfileAvatarCropState(
      normalizedCenter: CGPoint(x: 0.25, y: 0.5),
      zoom: 1
    )
    let rightState = ProfileAvatarCropState(
      normalizedCenter: CGPoint(x: 0.75, y: 0.5),
      zoom: 1
    )

    let left = try await processor.makeUpload(source: source, state: leftState)
    let right = try await processor.makeUpload(source: source, state: rightState)
    let leftPixel = try centerPixel(left.jpegData)
    let rightPixel = try centerPixel(right.jpegData)

    XCTAssertGreaterThan(leftPixel.red, 200)
    XCTAssertLessThan(leftPixel.blue, 60)
    XCTAssertGreaterThan(rightPixel.blue, 200)
    XCTAssertLessThan(rightPixel.red, 60)
  }

  func testMakeUploadRejectsTamperedPreparedSource() async throws {
    let source = try XCTUnwrap(
      ProfileAvatarCropSource(
        data: Data("not-a-jpeg".utf8),
        pixelWidth: 20,
        pixelHeight: 20
      )
    )

    await XCTAssertThrowsErrorAsync {
      try await self.processor.makeUpload(source: source, state: .initial)
    }
  }

  func testMakeUploadRejectsNonFiniteCropState() async throws {
    let source = try await processor.prepare(data: try splitColorImageData())
    let state = ProfileAvatarCropState(
      normalizedCenter: CGPoint(x: .nan, y: 0.5),
      zoom: 1
    )

    await XCTAssertThrowsErrorAsync {
      try await self.processor.makeUpload(source: source, state: state)
    } verify: { error in
      XCTAssertEqual(error as? ProfileAvatarImageProcessingError, .invalidCrop)
    }
  }

  func testDetachedProcessingObservesCallerCancellation() async {
    let started = DispatchSemaphore(value: 0)
    let caller = Task.detached {
      try await ProfileAvatarImageProcessor.runCancellableDetachedOperation {
        started.signal()
        let deadline = Date().addingTimeInterval(2)
        while !Task.isCancelled, Date() < deadline {
          Thread.sleep(forTimeInterval: 0.001)
        }
        try Task.checkCancellation()
        return true
      }
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    caller.cancel()

    do {
      _ = try await caller.value
      XCTFail("Expected cancellation to reach the detached image operation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testValueDescriptionsAndMirrorsNeverExposeImageBytes() throws {
    let marker = Data("private-avatar-byte-marker".utf8)
    var jpegMarker = Data([0xFF, 0xD8])
    jpegMarker.append(marker)
    jpegMarker.append(contentsOf: [0xFF, 0xD9])
    let source = try XCTUnwrap(
      ProfileAvatarCropSource(data: marker, pixelWidth: 1, pixelHeight: 1)
    )
    let upload = try XCTUnwrap(
      AccountProfileAvatarUpload(jpegData: jpegMarker, pixelSize: 960)
    )

    for value in [source.description, source.debugDescription, String(reflecting: source)] {
      XCTAssertFalse(value.contains("private-avatar-byte-marker"))
    }
    for value in [upload.description, upload.debugDescription, String(reflecting: upload)] {
      XCTAssertFalse(value.contains("private-avatar-byte-marker"))
    }
    XCTAssertFalse(source.customMirror.children.contains { $0.label == "data" })
    XCTAssertFalse(upload.customMirror.children.contains { $0.label == "jpegData" })
  }

  private func splitColorImageData() throws -> Data {
    let width = 800
    let height = 400
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { context in
      UIColor.systemRed.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width / 2), height: CGFloat(height))
      )
      UIColor.systemBlue.setFill()
      context.fill(
        CGRect(
          x: CGFloat(width / 2),
          y: 0,
          width: CGFloat(width / 2),
          height: CGFloat(height)
        )
      )
    }
    return try XCTUnwrap(image.pngData())
  }

  private func imageData(
    width: Int,
    height: Int,
    properties: [CFString: Any]
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
      UIColor.systemGreen.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width / 2), height: CGFloat(height))
      )
    }
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func imageType(_ data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
  }

  private func imageProperties(_ data: Data) throws -> [CFString: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
  }

  private func centerPixel(_ data: Data) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let sample = try XCTUnwrap(
      image.cropping(
        to: CGRect(
          x: CGFloat(image.width / 2),
          y: CGFloat(image.height / 2),
          width: 1,
          height: 1
        )
      )
    )
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
      context.interpolationQuality = .none
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (pixel[0], pixel[1], pixel[2])
  }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  verify: (any Error) -> Void = { _ in }
) async {
  do {
    try await expression()
    XCTFail("Expected an error")
  } catch {
    verify(error)
  }
}
