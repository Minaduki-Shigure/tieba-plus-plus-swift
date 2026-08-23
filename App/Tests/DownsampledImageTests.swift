import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class DownsampledImageTests: XCTestCase {
  func testImageIODownsamplesToRequestedPixelBound() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
    let source = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    let fileURL = temporaryURL(extension: "jpg")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try XCTUnwrap(source.jpegData(compressionQuality: 0.9)).write(to: fileURL)

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 120)

    let image = try XCTUnwrap(asset.image.cgImage)
    XCTAssertLessThanOrEqual(max(image.width, image.height), 120)
    XCTAssertEqual(image.width * 3, image.height * 4)
  }

  func testImageIOPreservesNarrowLongStaticImageWithinDecodedPixelBudget() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: 128, height: 4_000),
      format: format
    )
    let source = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 128, height: 4_000))
    }
    let fileURL = temporaryURL(extension: "jpg")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try XCTUnwrap(source.jpegData(compressionQuality: 0.9)).write(to: fileURL)

    let asset = try ImageDownsampler.image(
      at: fileURL,
      maxPixelSize: ImageDownsampler.maximumStaticPixelDimension
    )
    let image = try XCTUnwrap(asset.image.cgImage)

    XCTAssertEqual(image.width, 128)
    XCTAssertEqual(image.height, 4_000)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(ImageDownsampler.decodedByteCost(of: asset.image)),
      ImageDownsampler.maximumStaticDecodedByteCost
    )
  }

  func testStaticPixelLimitPreservesLongImageButBoundsSquareImageMemory() {
    XCTAssertEqual(
      ImageDownsampler.staticPixelLimit(
        requestedPixelSize: ImageDownsampler.maximumStaticPixelDimension,
        sourceWidth: 412,
        sourceHeight: 12_800
      ),
      12_800
    )
    XCTAssertEqual(
      ImageDownsampler.staticPixelLimit(
        requestedPixelSize: ImageDownsampler.maximumStaticPixelDimension,
        sourceWidth: 20_000,
        sourceHeight: 20_000
      ),
      4_096
    )
    XCTAssertEqual(
      ImageDownsampler.staticPixelLimit(
        requestedPixelSize: ImageDownsampler.maximumStaticPixelDimension,
        sourceWidth: 0,
        sourceHeight: 0
      ),
      ImageDownsampler.standardMaximumPixelDimension
    )
  }

  func testImageIODownsamplerRejectsInvalidInput() throws {
    let fileURL = temporaryURL(extension: "bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data("not an image".utf8).write(to: fileURL)

    XCTAssertThrowsError(try ImageDownsampler.image(at: fileURL, maxPixelSize: 200))
  }

  func testImageIODownsamplerBuildsLazyBoundedAnimatedGIFAsset() async throws {
    let fileURL = temporaryURL(extension: "bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let data = try gifData(
      frameDurations: [0.2, 0.3],
      size: CGSize(width: 800, height: 600),
      loopCount: 0
    )
    try data.write(to: fileURL)
    RemoteImageAnimationFrameCache.shared.removeAllObjects()

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 120)
    let animation = try XCTUnwrap(asset.animation)

    XCTAssertEqual(animation.format, .gif)
    XCTAssertEqual(animation.frameCount, 2)
    XCTAssertEqual(animation.frameDurations.count, 2)
    XCTAssertEqual(animation.frameDurations[0], 0.2, accuracy: 0.02)
    XCTAssertEqual(animation.frameDurations[1], 0.3, accuracy: 0.02)
    XCTAssertEqual(animation.totalPlaythroughs, 0)
    XCTAssertTrue(asset.image === animation.poster)
    let poster = try XCTUnwrap(asset.image.cgImage)
    XCTAssertLessThanOrEqual(max(poster.width, poster.height), 120)
    let posterCost = try XCTUnwrap(ImageDownsampler.decodedByteCost(of: asset.image))
    XCTAssertEqual(animation.decodedByteCost, posterCost + data.count)
    XCTAssertEqual(asset.decodedByteCost, animation.decodedByteCost)

    let secondFrameBox = try await animation.decodedFrame(at: 1)
    let secondFrame = secondFrameBox.image
    let secondCGImage = try XCTUnwrap(secondFrame.cgImage)
    XCTAssertLessThanOrEqual(max(secondCGImage.width, secondCGImage.height), 120)
    let key = RemoteImageAnimationFrameCacheKey(sequenceID: animation.id, frameIndex: 1)
    let (cachedFrame, _) =
      RemoteImageAnimationFrameCache.shared.cachedFrameAndGeneration(for: key)
    XCTAssertTrue(cachedFrame?.image === secondFrame)
    XCTAssertEqual(
      cachedFrame?.decodedByteCost,
      secondCGImage.bytesPerRow * secondCGImage.height
    )
  }

  func testSingleFrameGIFFallsBackToStaticPoster() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try gifData(
      frameDurations: [0.2],
      size: CGSize(width: 320, height: 180),
      loopCount: 0
    ).write(to: fileURL)

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 96)

    XCTAssertNil(asset.animation)
    let poster = try XCTUnwrap(asset.image.cgImage)
    XCTAssertLessThanOrEqual(max(poster.width, poster.height), 96)
    XCTAssertEqual(asset.decodedByteCost, poster.bytesPerRow * poster.height)
  }

  func testGIFOverFrameLimitFallsBackToStaticPoster() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let frameCount = ImageDownsampler.maximumAnimationFrameCount + 1
    try gifData(
      frameDurations: [TimeInterval](repeating: 0.1, count: frameCount),
      size: CGSize(width: 2, height: 2),
      loopCount: 0
    ).write(to: fileURL)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(fileURL as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), frameCount)

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 96)

    XCTAssertNil(asset.animation)
    XCTAssertNotNil(asset.image.cgImage)
  }

  func testAnimationBelowMinimumBudgetFallsBackToStaticPoster() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try gifData(
      frameDurations: [0.1, 0.1],
      size: CGSize(width: 320, height: 180),
      loopCount: 0
    ).write(to: fileURL)

    let asset = try ImageDownsampler.image(
      at: fileURL,
      maxPixelSize: 320,
      animationDecodedByteBudget: 4 * 63 * 63
    )

    XCTAssertNil(asset.animation)
    let poster = try XCTUnwrap(asset.image.cgImage)
    XCTAssertLessThanOrEqual(max(poster.width, poster.height), 320)
  }

  func testAnimatedGIFWithoutLoopMetadataDefaultsToOnePlaythrough() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try gifData(
      frameDurations: [0.1, 0.1],
      size: CGSize(width: 32, height: 24),
      loopCount: nil
    ).write(to: fileURL)

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 64)

    XCTAssertEqual(try XCTUnwrap(asset.animation).totalPlaythroughs, 1)
  }

  func testAnimationFormatClassificationRequiresRealTypeAndBoundedFrameCount() {
    XCTAssertEqual(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: UTType.gif.identifier,
        frameCount: 2,
        hasHEICSSequenceMetadata: false
      ),
      .gif
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: "org.webmproject.webp",
        frameCount: 2,
        hasHEICSSequenceMetadata: false
      ),
      .webP
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: "public.heics",
        frameCount: 2,
        hasHEICSSequenceMetadata: false
      ),
      .heics
    )
    XCTAssertNil(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: "public.heif",
        frameCount: 2,
        hasHEICSSequenceMetadata: false
      )
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: "public.heif",
        frameCount: 2,
        hasHEICSSequenceMetadata: true
      ),
      .heics
    )
    XCTAssertNil(
      RemoteImageAnimationPolicy.format(
        sourceTypeIdentifier: UTType.jpeg.identifier,
        frameCount: 2,
        hasHEICSSequenceMetadata: true
      )
    )
    for type in [UTType.gif.identifier, "org.webmproject.webp", "public.heics"] {
      XCTAssertNil(
        RemoteImageAnimationPolicy.format(
          sourceTypeIdentifier: type,
          frameCount: 1,
          hasHEICSSequenceMetadata: true
        )
      )
      XCTAssertNil(
        RemoteImageAnimationPolicy.format(
          sourceTypeIdentifier: type,
          frameCount: ImageDownsampler.maximumAnimationFrameCount + 1,
          hasHEICSSequenceMetadata: true
        )
      )
    }
  }

  func testAnimationDurationNormalizationRejectsInvalidAndTooFastFrames() {
    let invalidDurations: [TimeInterval?] = [
      nil,
      -.infinity,
      .infinity,
      .nan,
      -1,
      0,
      0.019,
    ]
    for duration in invalidDurations {
      XCTAssertEqual(
        RemoteImageAnimationPolicy.normalizedFrameDuration(duration),
        0.1
      )
    }
    XCTAssertEqual(RemoteImageAnimationPolicy.normalizedFrameDuration(0.02), 0.02)
    XCTAssertEqual(RemoteImageAnimationPolicy.normalizedFrameDuration(0.25), 0.25)
  }

  func testAnimationLoopMetadataNormalizesPerFormat() {
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .gif, imageIOLoopCount: nil),
      1
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .gif, imageIOLoopCount: 0),
      0
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .gif, imageIOLoopCount: 3),
      3
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .webP, imageIOLoopCount: nil),
      1
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .webP, imageIOLoopCount: 4),
      4
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .heics, imageIOLoopCount: nil),
      0
    )
    XCTAssertEqual(
      RemoteImageAnimationPolicy.totalPlaythroughs(format: .heics, imageIOLoopCount: 2),
      2
    )
  }

  func testAnimationPixelLimitUsesFrameCountAndDecodedBudget() {
    XCTAssertEqual(
      ImageDownsampler.animationPixelLimit(requestedPixelSize: 4_096, frameCount: 500),
      2_048
    )
    XCTAssertEqual(
      ImageDownsampler.animationPixelLimit(requestedPixelSize: 120, frameCount: 2),
      120
    )
    XCTAssertNil(
      ImageDownsampler.animationPixelLimit(requestedPixelSize: 4_096, frameCount: 1)
    )
    XCTAssertNil(
      ImageDownsampler.animationPixelLimit(requestedPixelSize: 4_096, frameCount: 501)
    )
    XCTAssertNil(
      ImageDownsampler.animationPixelLimit(
        requestedPixelSize: 4_096,
        frameCount: 2,
        decodedByteBudget: 4 * 63 * 63
      )
    )
  }

  func testDecodedByteCostRejectsInvalidAndOverflowingDimensions() {
    XCTAssertEqual(ImageDownsampler.decodedByteCost(bytesPerRow: 48, height: 7), 336)
    XCTAssertNil(ImageDownsampler.decodedByteCost(bytesPerRow: 0, height: 7))
    XCTAssertNil(ImageDownsampler.decodedByteCost(bytesPerRow: 48, height: 0))
    XCTAssertNil(
      ImageDownsampler.decodedByteCost(bytesPerRow: Int.max, height: Int.max)
    )
  }

  func testRetainedCostAdditionClampsOnOverflow() {
    XCTAssertEqual(ImageDownsampler.addingClamped(10, 20), 30)
    XCTAssertEqual(ImageDownsampler.addingClamped(Int.max, 1), Int.max)
    XCTAssertEqual(ImageDownsampler.addingClamped(-1, 1), Int.max)
  }

  func testAnimatedAssetRetainsOptionalSourceOwner() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let data = try gifData(
      frameDurations: [0.1, 0.1],
      size: CGSize(width: 32, height: 24),
      loopCount: 0
    )
    try data.write(to: fileURL)
    var owner: AnimationSourceOwnerProbe? = AnimationSourceOwnerProbe()
    weak var weakOwner = owner
    var asset: DownsampledImageAsset? = try ImageDownsampler.image(
      at: fileURL,
      maxPixelSize: 64,
      sourceOwner: owner,
      sourceByteCount: Int64(data.count)
    )

    owner = nil
    XCTAssertNotNil(weakOwner)
    XCTAssertNotNil(asset?.animation)

    asset = nil
    XCTAssertNil(weakOwner)
  }

  func testStaticAssetDoesNotRetainOptionalSourceOwner() throws {
    let fileURL = temporaryURL(extension: "gif")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let data = try gifData(
      frameDurations: [0.1],
      size: CGSize(width: 32, height: 24),
      loopCount: nil
    )
    try data.write(to: fileURL)
    var owner: AnimationSourceOwnerProbe? = AnimationSourceOwnerProbe()
    weak var weakOwner = owner
    let asset = try ImageDownsampler.image(
      at: fileURL,
      maxPixelSize: 64,
      sourceOwner: owner,
      sourceByteCount: Int64(data.count)
    )

    owner = nil
    XCTAssertNil(asset.animation)
    XCTAssertNil(weakOwner)
  }

  func testRepositoryRejectsCleartextURLBeforeNetworking() async throws {
    let repository = DownsampledImageRepository()
    let url = try XCTUnwrap(URL(string: "http://example.com/image.jpg"))

    do {
      _ = try await repository.image(at: url, maxPixelSize: 200)
      XCTFail("Expected cleartext URL rejection")
    } catch DownsampledImageError.invalidResponse {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func temporaryURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(pathExtension)
  }

  private func gifData(
    frameDurations: [TimeInterval],
    size: CGSize,
    loopCount: Int?
  ) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data,
        UTType.gif.identifier as CFString,
        frameDurations.count,
        nil
      )
    )
    if let loopCount {
      CGImageDestinationSetProperties(
        destination,
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: loopCount
          ]
        ] as CFDictionary
      )
    }
    let renderer = UIGraphicsImageRenderer(size: size)
    let frameImages = [UIColor.systemBlue, UIColor.systemRed].map { color in
      renderer.image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
      }
    }
    for (index, duration) in frameDurations.enumerated() {
      CGImageDestinationAddImage(
        destination,
        try XCTUnwrap(frameImages[index % frameImages.count].cgImage),
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: duration,
            kCGImagePropertyGIFUnclampedDelayTime: duration,
          ]
        ] as CFDictionary
      )
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private final class AnimationSourceOwnerProbe {}
