import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import WebPDecodeProbe

final class WebPDecoderProbeTests: XCTestCase {
  func testReadAndForceDecodeVariants() throws {
    typealias F = ComposerWebPTestFixture
    let bitmap = try XCTUnwrap(F.chunks(F.lossless).first)
    let brokenLossless = F.container([F.Chunk("VP8L", Data(bitmap.payload.prefix(5)) + Data([0]))])
    var alpha = F.chunks(F.alphaLossy)
    alpha[1].payload = Data([1, 0])
    let brokenAlpha = F.container(alpha)
    let samples: [(String, Data)] = [
      ("valid-lossy", F.lossy), ("valid-lossless", F.lossless),
      ("valid-alpha", F.alphaLossy), ("broken-lossless", brokenLossless),
      ("broken-alpha", brokenAlpha),
    ]
    for (name, data) in samples {
      for cacheAtSource in [false, true] {
        for mode in ["immediate", "explicit-cache", "thumbnail"] {
          try autoreleasepool {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(
              data as CFData, [kCGImageSourceShouldCache: cacheAtSource] as CFDictionary))
            var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if mode != "immediate" { options[kCGImageSourceShouldCache] = true }
            let image: CGImage?
            if mode == "thumbnail" {
              options[kCGImageSourceCreateThumbnailFromImageAlways] = true
              options[kCGImageSourceThumbnailMaxPixelSize] = 8
              image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            } else {
              image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
            }
            let initialStatus = CGImageSourceGetStatusAtIndex(source, 0).rawValue
            let pixels = image?.dataProvider?.data
            let byteCount = pixels.map { CFDataGetLength($0) } ?? -1
            let expectedCount = image.map { $0.bytesPerRow * $0.height } ?? -1
            let finalStatus = CGImageSourceGetStatusAtIndex(source, 0).rawValue
            print("WEBP_PROBE name=\(name) sourceCache=\(cacheAtSource) mode=\(mode) image=\(image != nil) initialStatus=\(initialStatus) pixelBytes=\(byteCount) expectedBytes=\(expectedCount) finalStatus=\(finalStatus)")
            if let pixels {
              let bytes = pixels as Data
              print("WEBP_PIXELS \(name) \(mode) prefix=\(bytes.prefix(12).map { String(format: "%02x", $0) }.joined())")
            }
            CGImageSourceRemoveCacheAtIndex(source, 0)
          }
        }
      }
    }
  }
}
