import Foundation

enum ComposerWebPSanitizerError: Error, LocalizedError, Equatable {
  case invalidWebP
  case unsupportedWebP
  case resourceLimit

  var errorDescription: String? {
    switch self {
    case .invalidWebP: "WebP 图片的数据不完整或格式无效。"
    case .unsupportedWebP: "这张 WebP 使用了暂不支持的图像格式。"
    case .resourceLimit: "这张 WebP 超出了图片大小、帧数或动画长度限制。"
    }
  }
}

/// Bounded container inspection before ImageIO, without decoding or recompressing pixels.
/// Reconstruction chunks follow https://developers.google.com/speed/webp/docs/riff_container.
/// Callers must additionally decode every frame: a valid container is not proof of a valid
/// VP8, VP8L or compressed alpha bitstream.
enum ComposerWebPSanitizer {
  static let maximumBytes = 32 * 1_024 * 1_024
  static let maximumColorProfileBytes = 256 * 1_024
  static let maximumStaticDimension = 16_384
  static let maximumStaticPixels = 12_582_912
  static let maximumAnimatedDimension = 4_096
  static let maximumAnimatedPixels = 4_194_304
  static let maximumFrames = 500
  static let maximumTotalFramePixels = 100_000_000
  static let maximumDurationMilliseconds = 120_000

  struct Inspection: Sendable, Equatable {
    let data: Data
    let width: Int
    let height: Int
    let frameCount: Int
    let isAnimated: Bool
    /// Encoded ANMF delays, unmodified, including zero. Empty for a still image.
    let frameDurationsMilliseconds: [Int]
    /// nil for a still image; zero denotes infinite animation looping.
    let loopCount: Int?
    /// TIFF Orientation, defaulting to 1 when no EXIF orientation is present.
    let orientation: Int
  }

  static func sanitize(
    _ data: Data,
    canonicalColorProfile: (Data) throws -> Data
  ) throws -> Inspection {
    try Task.checkCancellation()
    guard data.count <= maximumBytes else { throw ComposerWebPSanitizerError.resourceLimit }
    var parser = Parser(bytes: Array(data))
    return try parser.inspect(canonicalColorProfile: canonicalColorProfile)
  }

  private struct Chunk {
    let name: String
    let payload: Range<Int>
    let whole: Range<Int>
  }

  private struct Bitmap {
    let width: Int
    let height: Int
    let isLossless: Bool
  }

  private struct Parser {
    let bytes: [UInt8]
    var chunkCount = 0
    var flags: UInt8?
    var width = 0
    var height = 0
    var profile: Data?
    var sawEXIF = false
    var sawXMP = false
    var orientation = 1
    var animationControl: Data?
    var loopCount: Int?
    var durations = [Int]()
    var duration = 0
    var imageBody = Data()
    var stillBitmap: Bitmap?
    var stillAlpha: Chunk?
    var sawAlpha = false
    var sawLossless = false

    var isAnimated: Bool { flags.map { $0 & 0x02 != 0 } ?? false }

    mutating func inspect(canonicalColorProfile: (Data) throws -> Data) throws -> Inspection {
      guard bytes.count >= 20, bytes[0..<4].elementsEqual("RIFF".utf8),
        bytes[8..<12].elementsEqual("WEBP".utf8),
        uint32(4) == bytes.count - 8, bytes.count % 2 == 0
      else { throw ComposerWebPSanitizerError.invalidWebP }

      var cursor = 12
      while cursor < bytes.count {
        let chunk = try nextChunk(cursor: &cursor, end: bytes.count)
        switch chunk.name {
        case "VP8X":
          guard chunk.whole.lowerBound == 12, flags == nil, chunk.payload.count == 10 else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          let p = chunk.payload.lowerBound
          guard bytes[p] & 0xC1 == 0, bytes[(p + 1)..<(p + 4)].allSatisfy({ $0 == 0 }) else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          flags = bytes[p]
          width = uint24(p + 4) + 1
          height = uint24(p + 7) + 1
          try validateCanvas()
        case "ICCP":
          guard flags != nil, profile == nil, animationControl == nil,
            stillAlpha == nil, stillBitmap == nil, durations.isEmpty
          else { throw ComposerWebPSanitizerError.invalidWebP }
          guard chunk.payload.count <= maximumColorProfileBytes else {
            throw ComposerWebPSanitizerError.resourceLimit
          }
          let source = Data(bytes[chunk.payload])
          try validateProfile(source)
          let canonical = try canonicalColorProfile(source)
          try Task.checkCancellation()
          try validateProfile(canonical)
          profile = canonical
        case "ANIM":
          guard isAnimated, animationControl == nil, chunk.payload.count == 6,
            stillBitmap == nil, stillAlpha == nil, durations.isEmpty
          else { throw ComposerWebPSanitizerError.invalidWebP }
          animationControl = Data(bytes[chunk.whole])
          loopCount = uint16(chunk.payload.lowerBound + 4)
        case "ANMF":
          guard isAnimated, animationControl != nil else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          try appendFrame(chunk)
        case "ALPH":
          guard flags != nil, !isAnimated, stillAlpha == nil, stillBitmap == nil else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          stillAlpha = chunk
          sawAlpha = true
        case "VP8 ", "VP8L":
          guard !isAnimated, stillBitmap == nil else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          let bitmap = try inspectBitmap(chunk)
          if flags == nil {
            width = bitmap.width
            height = bitmap.height
            try validateCanvas()
          }
          guard bitmap.width == width, bitmap.height == height else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          if let alpha = stillAlpha {
            guard !bitmap.isLossless else { throw ComposerWebPSanitizerError.invalidWebP }
            try validateAlpha(alpha, width: width, height: height)
            imageBody.append(contentsOf: bytes[alpha.whole])
          }
          stillBitmap = bitmap
          sawLossless = bitmap.isLossless
          imageBody.append(contentsOf: bytes[chunk.whole])
        case "EXIF":
          guard flags != nil, !sawEXIF else { throw ComposerWebPSanitizerError.invalidWebP }
          sawEXIF = true
          orientation = try exifOrientation(chunk.payload)
        case "XMP ":
          guard flags != nil, !sawXMP else { throw ComposerWebPSanitizerError.invalidWebP }
          sawXMP = true
        default:
          // The WebP specification permits opaque, non-rendering chunks. Do not forward
          // private data, including unknown chunks inside animation frames, to ImageIO.
          break
        }
      }

      if isAnimated {
        guard animationControl != nil, !durations.isEmpty else {
          throw ComposerWebPSanitizerError.invalidWebP
        }
      } else {
        guard stillBitmap != nil else { throw ComposerWebPSanitizerError.invalidWebP }
      }
      if let flags {
        guard (flags & 0x20 != 0) == (profile != nil),
          (flags & 0x08 != 0) == sawEXIF, (flags & 0x04 != 0) == sawXMP,
          !sawAlpha || flags & 0x10 != 0,
          flags & 0x10 == 0 || sawAlpha || sawLossless
        else { throw ComposerWebPSanitizerError.invalidWebP }
        // VP8L's alpha_is_used field is only a hint, per its bitstream specification.
        // Never infer the decoded transparency or reject a VP8L from that hint.
      }

      var body = Data()
      if let flags {
        var header = Data([flags & ~0x04, 0, 0, 0])  // XMP is removed; safe EXIF remains.
        header.append(contentsOf: littleEndian(width - 1, count: 3))
        header.append(contentsOf: littleEndian(height - 1, count: 3))
        body.append(makeChunk("VP8X", header))
      }
      if let profile { body.append(makeChunk("ICCP", profile)) }
      if let animationControl { body.append(animationControl) }
      body.append(imageBody)
      if sawEXIF { body.append(makeChunk("EXIF", minimalEXIF(orientation: orientation))) }
      var output = Data("RIFF".utf8)
      output.append(contentsOf: littleEndian(body.count + 4, count: 4))
      output.append(contentsOf: "WEBP".utf8)
      output.append(body)
      return Inspection(
        data: output, width: width, height: height,
        frameCount: isAnimated ? durations.count : 1, isAnimated: isAnimated,
        frameDurationsMilliseconds: durations, loopCount: loopCount, orientation: orientation
      )
    }

    mutating func nextChunk(cursor: inout Int, end: Int) throws -> Chunk {
      try Task.checkCancellation()
      guard cursor <= end, end - cursor >= 8 else {
        throw ComposerWebPSanitizerError.invalidWebP
      }
      chunkCount += 1
      // Includes metadata and frame subchunks, so tiny opaque chunks cannot cause
      // millions of allocations. Normal 500-frame files need roughly 1,500 chunks.
      guard chunkCount <= 16_384 else { throw ComposerWebPSanitizerError.resourceLimit }
      let length = uint32(cursor + 4)
      let start = cursor
      let payloadStart = cursor + 8
      guard length <= end - payloadStart else { throw ComposerWebPSanitizerError.invalidWebP }
      let payloadEnd = payloadStart + length
      let padding = length % 2
      guard padding <= end - payloadEnd else { throw ComposerWebPSanitizerError.invalidWebP }
      if padding == 1, bytes[payloadEnd] != 0 { throw ComposerWebPSanitizerError.invalidWebP }
      cursor = payloadEnd + padding
      return Chunk(
        name: String(decoding: bytes[start..<(start + 4)], as: UTF8.self),
        payload: payloadStart..<payloadEnd, whole: start..<cursor
      )
    }

    mutating func appendFrame(_ chunk: Chunk) throws {
      guard chunk.payload.count >= 16 else { throw ComposerWebPSanitizerError.invalidWebP }
      let p = chunk.payload.lowerBound
      let left = uint24(p) * 2
      let top = uint24(p + 3) * 2
      let frameWidth = uint24(p + 6) + 1
      let frameHeight = uint24(p + 9) + 1
      let delay = uint24(p + 12)
      // Match the GIF processing budget's minimum 20 ms per frame. Keep the
      // original delay bytes: zero/very short delay playback is decoder-defined.
      let budgetedDelay = max(delay, 20)
      guard bytes[p + 15] & 0xFC == 0, left < width, top < height,
        frameWidth <= width - left, frameHeight <= height - top
      else { throw ComposerWebPSanitizerError.invalidWebP }
      guard durations.count < maximumFrames,
        durations.count + 1 <= maximumTotalFramePixels / (width * height),
        budgetedDelay <= maximumDurationMilliseconds - duration
      else { throw ComposerWebPSanitizerError.resourceLimit }

      var cursor = p + 16
      var alpha: Chunk?
      var bitmap: Bitmap?
      var frame = Data(bytes[p..<(p + 16)])  // Keep rectangle, duration, blend and disposal verbatim.
      while cursor < chunk.payload.upperBound {
        let child = try nextChunk(cursor: &cursor, end: chunk.payload.upperBound)
        switch child.name {
        case "ALPH":
          guard alpha == nil, bitmap == nil else { throw ComposerWebPSanitizerError.invalidWebP }
          alpha = child
        case "VP8 ", "VP8L":
          guard bitmap == nil else { throw ComposerWebPSanitizerError.invalidWebP }
          let decodedHeader = try inspectBitmap(child)
          guard decodedHeader.width == frameWidth, decodedHeader.height == frameHeight else {
            throw ComposerWebPSanitizerError.invalidWebP
          }
          if let alpha {
            guard !decodedHeader.isLossless else { throw ComposerWebPSanitizerError.invalidWebP }
            try validateAlpha(alpha, width: frameWidth, height: frameHeight)
            frame.append(contentsOf: bytes[alpha.whole])
            sawAlpha = true
          }
          sawLossless = sawLossless || decodedHeader.isLossless
          bitmap = decodedHeader
          frame.append(contentsOf: bytes[child.whole])
        case "VP8X", "ANIM", "ANMF", "ICCP", "EXIF", "XMP ":
          // These are known top-level chunks, not permitted frame subchunks.
          throw ComposerWebPSanitizerError.invalidWebP
        default:
          break
        }
      }
      guard bitmap != nil else { throw ComposerWebPSanitizerError.invalidWebP }
      durations.append(delay)
      duration += budgetedDelay
      imageBody.append(makeChunk("ANMF", frame))
    }

    func inspectBitmap(_ chunk: Chunk) throws -> Bitmap {
      let p = chunk.payload.lowerBound
      if chunk.name == "VP8L" {
        guard chunk.payload.count > 5, bytes[p] == 0x2F else {
          throw ComposerWebPSanitizerError.invalidWebP
        }
        let packed = uint32(p + 1)
        guard packed >> 29 == 0 else { throw ComposerWebPSanitizerError.unsupportedWebP }
        return Bitmap(
          width: (packed & 0x3FFF) + 1, height: ((packed >> 14) & 0x3FFF) + 1,
          isLossless: true
        )
      }
      guard chunk.payload.count > 10, bytes[(p + 3)..<(p + 6)].elementsEqual([0x9D, 1, 0x2A]) else {
        throw ComposerWebPSanitizerError.invalidWebP
      }
      let tag = uint24(p)
      guard tag & 1 == 0, tag & 0x10 != 0, (tag >> 5) > 0,
        (tag >> 5) <= chunk.payload.count - 10
      else { throw ComposerWebPSanitizerError.invalidWebP }
      guard (tag >> 1) & 7 <= 3, uint16(p + 6) & 0xC000 == 0,
        uint16(p + 8) & 0xC000 == 0
      else { throw ComposerWebPSanitizerError.unsupportedWebP }
      let w = uint16(p + 6) & 0x3FFF
      let h = uint16(p + 8) & 0x3FFF
      guard w > 0, h > 0 else { throw ComposerWebPSanitizerError.invalidWebP }
      return Bitmap(width: w, height: h, isLossless: false)
    }

    func validateAlpha(_ chunk: Chunk, width: Int, height: Int) throws {
      guard chunk.payload.count > 1 else { throw ComposerWebPSanitizerError.invalidWebP }
      let header = bytes[chunk.payload.lowerBound]
      guard header & 0xC0 == 0 else { throw ComposerWebPSanitizerError.invalidWebP }
      guard (header & 3) <= 1, (header >> 4) & 3 <= 1 else {
        throw ComposerWebPSanitizerError.unsupportedWebP
      }
      if header & 3 == 0, chunk.payload.count - 1 != width * height {
        throw ComposerWebPSanitizerError.invalidWebP
      }
    }

    func validateCanvas() throws {
      let dimensionLimit = isAnimated ? maximumAnimatedDimension : maximumStaticDimension
      let pixelLimit = isAnimated ? maximumAnimatedPixels : maximumStaticPixels
      guard width > 0, height > 0, width <= dimensionLimit, height <= dimensionLimit,
        width <= pixelLimit / height
      else { throw ComposerWebPSanitizerError.resourceLimit }
    }

    func validateProfile(_ profile: Data) throws {
      guard profile.count <= maximumColorProfileBytes else {
        throw ComposerWebPSanitizerError.resourceLimit
      }
      let p = [UInt8](profile)
      guard p.count >= 128, p[36..<40].elementsEqual("acsp".utf8),
        (Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])) == p.count
      else { throw ComposerWebPSanitizerError.unsupportedWebP }
    }

    func exifOrientation(_ payload: Range<Int>) throws -> Int {
      var base = payload.lowerBound
      if bytes[payload].starts(with: "Exif\0\0".utf8) { base += 6 }
      guard payload.upperBound - base >= 8 else { throw ComposerWebPSanitizerError.invalidWebP }
      let little: Bool
      if bytes[base] == 0x49, bytes[base + 1] == 0x49 {
        little = true
      } else if bytes[base] == 0x4D, bytes[base + 1] == 0x4D {
        little = false
      } else {
        throw ComposerWebPSanitizerError.invalidWebP
      }
      func read(_ offset: Int, _ count: Int) -> Int {
        var value = 0
        for i in 0..<count {
          let shift = little ? i * 8 : (count - i - 1) * 8
          value |= Int(bytes[base + offset + i]) << shift
        }
        return value
      }
      let length = payload.upperBound - base
      guard read(2, 2) == 42 else { throw ComposerWebPSanitizerError.invalidWebP }
      let directory = read(4, 4)
      guard directory >= 8, directory <= length - 2 else {
        throw ComposerWebPSanitizerError.invalidWebP
      }
      let count = read(directory, 2)
      guard count <= 4_096 else { throw ComposerWebPSanitizerError.resourceLimit }
      guard length - directory - 2 >= 4, count <= (length - directory - 6) / 12 else {
        throw ComposerWebPSanitizerError.invalidWebP
      }
      var result: Int?
      for index in 0..<count {
        try Task.checkCancellation()
        let entry = directory + 2 + index * 12
        guard read(entry, 2) == 0x0112 else { continue }
        guard result == nil, read(entry + 2, 2) == 3, read(entry + 4, 4) == 1 else {
          throw ComposerWebPSanitizerError.invalidWebP
        }
        let orientation = read(entry + 8, 2)
        guard (1...8).contains(orientation) else { throw ComposerWebPSanitizerError.invalidWebP }
        result = orientation
      }
      // Only IFD0 controls orientation. GPS, thumbnails, camera and linked Exif
      // directories are never followed and are removed from the output entirely.
      return result ?? 1
    }

    func uint16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
    func uint24(_ p: Int) -> Int { uint16(p) | Int(bytes[p + 2]) << 16 }
    func uint32(_ p: Int) -> Int { uint24(p) | Int(bytes[p + 3]) << 24 }
  }

  private static func littleEndian(_ value: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  private static func makeChunk(_ name: String, _ payload: Data) -> Data {
    var result = Data(name.utf8)
    result.append(contentsOf: littleEndian(payload.count, count: 4))
    result.append(payload)
    if payload.count % 2 != 0 { result.append(0) }
    return result
  }

  private static func minimalEXIF(orientation: Int) -> Data {
    // Some WebP readers require the Exif signature even though others accept
    // bare TIFF. Normalize to the broadly understood prefixed representation.
    Data("Exif\0\0".utf8)
      + Data([
        0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0,
        UInt8(orientation), 0, 0, 0, 0, 0, 0, 0,
      ])
  }
}
