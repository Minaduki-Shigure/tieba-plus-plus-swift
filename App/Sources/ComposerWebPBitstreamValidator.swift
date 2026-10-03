import Darwin
import Foundation
import libwebp

/// Validates pixels with libwebp's explicit decode result. ImageIO may return a
/// complete CGImage and zero-filled pixels for an invalid WebP bitstream, so its
/// object/status checks alone cannot establish that all color and alpha decoded.
enum ComposerWebPBitstreamValidator {
  static func validate(
    _ frame: ComposerWebPSanitizer.FrameImage, maximumDecodedBytes: Int
  ) throws {
    try Task.checkCancellation()
    guard !frame.data.isEmpty, frame.width > 0, frame.height > 0 else {
      throw ComposerImageProcessingError.invalidSource
    }
    // The C decoder takes an int stride. Check both arithmetic and the caller's
    // byte budget before asking it to inspect dimensions or allocate any pixels.
    guard maximumDecodedBytes > 0, frame.width <= Int(Int32.max) / 4 else {
      throw ComposerImageProcessingError.decodedImageTooLarge
    }
    let stride = frame.width * 4
    guard stride <= maximumDecodedBytes / frame.height else {
      throw ComposerImageProcessingError.decodedImageTooLarge
    }
    let byteCount = stride * frame.height

    try frame.data.withUnsafeBytes { storage in
      guard let input = storage.bindMemory(to: UInt8.self).baseAddress else {
        throw ComposerImageProcessingError.invalidSource
      }
      var features = WebPBitstreamFeatures()
      guard WebPGetFeatures(input, storage.count, &features) == VP8_STATUS_OK,
        Int(features.width) == frame.width, Int(features.height) == frame.height,
        features.has_animation == 0, features.format == 1 || features.format == 2
      else { throw ComposerImageProcessingError.decodeFailed }
      try Task.checkCancellation()

      guard let allocation = malloc(byteCount) else {
        throw ComposerImageProcessingError.decodedImageTooLarge
      }
      defer { free(allocation) }
      let pixels = allocation.assumingMemoryBound(to: UInt8.self)
      // RGBA is deliberate: RGB-only decode could skip a malformed alpha plane.
      // The official Into API returns NULL on a decode error or insufficient
      // output storage; no fallback/partial bitmap is accepted as success.
      guard WebPDecodeRGBAInto(
        input, storage.count, pixels, byteCount, Int32(stride)
      ) != nil else { throw ComposerImageProcessingError.decodeFailed }
      try Task.checkCancellation()
    }
  }
}
