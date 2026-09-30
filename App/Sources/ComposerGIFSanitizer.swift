import Foundation

enum ComposerGIFSanitizerError: Error, LocalizedError, Equatable {
  case invalidGIF
  case unsupportedGIF
  case resourceLimit

  var errorDescription: String? {
    switch self {
    case .invalidGIF: "GIF 图片的数据不完整或格式无效。"
    case .unsupportedGIF: "这张 GIF 使用了暂不支持的显示或动画控制方式。"
    case .resourceLimit: "这张 GIF 超出了图片大小、帧数或动画长度限制。"
    }
  }
}

/// Checks the complete GIF container before ImageIO is allowed to inspect or decode it.
/// GIF89a sections 18–26 define the copied screen, palettes, frames and control blocks:
/// https://www.w3.org/Graphics/GIF/spec-gif89a.txt
/// This does not decode LZW: callers must additionally decode and validate every frame.
enum ComposerGIFSanitizer {
  static let maximumBytes = 10 * 1_024 * 1_024
  static let maximumDimension = 4_096
  static let maximumFramePixels = 4_194_304
  static let maximumFrames = 500
  static let maximumTotalFramePixels = 100_000_000
  static let maximumDurationCentiseconds = 12_000

  struct Inspection: Sendable, Equatable {
    let data: Data
    let width: Int
    let height: Int
    let frameCount: Int
    let frameDelaysCentiseconds: [Int]
    /// nil means no loop extension; zero means repeat indefinitely.
    let loopCount: Int?
  }

  static func sanitize(_ data: Data) throws -> Inspection {
    guard data.count <= maximumBytes else { throw ComposerGIFSanitizerError.resourceLimit }
    var parser = Parser(bytes: Array(data))
    return try parser.inspect()
  }

  private struct GraphicControl {
    let delay: Int
    let transparentIndex: Int?
  }

  private struct Parser {
    let bytes: [UInt8]
    var cursor = 0
    var result = Data()
    var width = 0
    var height = 0
    var canvasPixels = 0
    var globalColorCount = 0
    var is89a = false
    var pendingControl: GraphicControl?
    var delays = [Int]()
    var loopCount: Int?
    var duration = 0

    mutating func inspect() throws -> Inspection {
      try Task.checkCancellation()
      try require(13)
      let header = bytes[0..<6]
      guard
        header.elementsEqual(Array("GIF89a".utf8))
          || header.elementsEqual(Array("GIF87a".utf8))
      else { throw ComposerGIFSanitizerError.invalidGIF }
      is89a = bytes[4] == 0x39
      width = uint16(at: 6)
      height = uint16(at: 8)
      guard width > 0, height > 0 else { throw ComposerGIFSanitizerError.invalidGIF }
      guard width <= maximumDimension, height <= maximumDimension,
        width <= maximumFramePixels / height
      else { throw ComposerGIFSanitizerError.resourceLimit }
      canvasPixels = width * height
      let packed = bytes[10]
      if !is89a, packed & 0x08 != 0 || bytes[12] != 0 {
        throw ComposerGIFSanitizerError.invalidGIF
      }
      cursor = 13
      if packed & 0x80 != 0 {
        globalColorCount = 1 << (Int(packed & 7) + 1)
        guard Int(bytes[11]) < globalColorCount else { throw ComposerGIFSanitizerError.invalidGIF }
        try advance(globalColorCount * 3)
      }
      result.append(contentsOf: bytes[0..<cursor])

      while cursor < bytes.count {
        try Task.checkCancellation()
        let start = cursor
        let marker = try byte()
        switch marker {
        case 0x2C:
          try image(start: start)
        case 0x21:
          guard is89a else { throw ComposerGIFSanitizerError.invalidGIF }
          try extensionBlock(start: start)
        case 0x3B:
          guard cursor == bytes.count, !delays.isEmpty, pendingControl == nil else {
            throw ComposerGIFSanitizerError.invalidGIF
          }
          result.append(marker)
          return Inspection(
            data: result, width: width, height: height, frameCount: delays.count,
            frameDelaysCentiseconds: delays, loopCount: loopCount
          )
        default:
          throw ComposerGIFSanitizerError.invalidGIF
        }
      }
      throw ComposerGIFSanitizerError.invalidGIF
    }

    mutating func image(start: Int) throws {
      try require(9)
      let left = uint16(at: cursor)
      let top = uint16(at: cursor + 2)
      let frameWidth = uint16(at: cursor + 4)
      let frameHeight = uint16(at: cursor + 6)
      let packed = bytes[cursor + 8]
      guard frameWidth > 0, frameHeight > 0,
        left <= width - frameWidth, top <= height - frameHeight,
        packed & 0x18 == 0
      else { throw ComposerGIFSanitizerError.invalidGIF }
      if !is89a, packed & 0x20 != 0 { throw ComposerGIFSanitizerError.invalidGIF }
      cursor += 9
      var colorCount = globalColorCount
      if packed & 0x80 != 0 {
        colorCount = 1 << (Int(packed & 7) + 1)
        try advance(colorCount * 3)
      }
      guard colorCount > 0 else { throw ComposerGIFSanitizerError.invalidGIF }
      if let transparentIndex = pendingControl?.transparentIndex, transparentIndex >= colorCount {
        throw ComposerGIFSanitizerError.invalidGIF
      }
      let codeSize = try byte()
      guard (2...8).contains(codeSize) else { throw ComposerGIFSanitizerError.invalidGIF }
      let payloadBytes = try subBlocks()
      guard payloadBytes > 0 else { throw ComposerGIFSanitizerError.invalidGIF }

      // Partial image descriptors still require compositing a complete logical canvas.
      // Bound the work using canvas pixels for every frame, not just changed pixels.
      guard delays.count < maximumFrames,
        delays.count + 1 <= maximumTotalFramePixels / canvasPixels
      else { throw ComposerGIFSanitizerError.resourceLimit }
      let delay = pendingControl?.delay ?? 0
      // Retain the raw timing bytes. For admission only, account at least 2 cs per
      // frame (including missing/zero delays), for one cycle, irrespective of loops.
      let budgetedDelay = max(delay, 2)
      guard budgetedDelay <= maximumDurationCentiseconds - duration else {
        throw ComposerGIFSanitizerError.resourceLimit
      }
      duration += budgetedDelay
      delays.append(delay)
      pendingControl = nil
      result.append(contentsOf: bytes[start..<cursor])
    }

    mutating func extensionBlock(start: Int) throws {
      switch try byte() {
      case 0xF9:
        guard pendingControl == nil, try byte() == 4 else {
          throw ComposerGIFSanitizerError.invalidGIF
        }
        try require(5)
        let packed = bytes[cursor]
        guard packed & 0xE0 == 0, bytes[cursor + 4] == 0 else {
          throw ComposerGIFSanitizerError.invalidGIF
        }
        guard packed & 0x02 == 0, (packed >> 2) & 7 <= 3 else {
          throw ComposerGIFSanitizerError.unsupportedGIF
        }
        pendingControl = GraphicControl(
          delay: uint16(at: cursor + 1),
          transparentIndex: packed & 1 != 0 ? Int(bytes[cursor + 3]) : nil
        )
        cursor += 5
        result.append(contentsOf: bytes[start..<cursor])
      case 0xFE:
        _ = try subBlocks()  // Comments have no graphic/control scope.
      case 0xFF:
        try application(start: start)
      case 0x01:
        // Plain Text is a graphic-rendering block. Removing it changes the picture
        // and consumes a pending GCE, so it cannot be treated as private metadata.
        throw ComposerGIFSanitizerError.unsupportedGIF
      default:
        // Unknown graphic/control extensions may change rendering or GCE scope.
        throw ComposerGIFSanitizerError.unsupportedGIF
      }
    }

    mutating func application(start: Int) throws {
      guard try byte() == 11 else { throw ComposerGIFSanitizerError.invalidGIF }
      try require(11)
      let identifierBytes = bytes[cursor..<(cursor + 11)]
      let applicationID = bytes[cursor..<(cursor + 8)]
      guard applicationID.allSatisfy({ (0x20...0x7E).contains($0) }) else {
        throw ComposerGIFSanitizerError.invalidGIF
      }
      let identifier = String(decoding: identifierBytes, as: UTF8.self)
      cursor += 11
      if identifier == "NETSCAPE2.0" || identifier == "ANIMEXTS1.0" {
        // Accept only the established looping sub-block, before the first frame.
        // Other NETSCAPE commands (e.g. buffering) are not inert metadata.
        guard delays.isEmpty else { throw ComposerGIFSanitizerError.unsupportedGIF }
        try require(5)
        guard bytes[cursor] == 3, bytes[cursor + 1] == 1, bytes[cursor + 4] == 0 else {
          throw ComposerGIFSanitizerError.unsupportedGIF
        }
        let count = uint16(at: cursor + 2)
        guard loopCount == nil || loopCount == count else {
          throw ComposerGIFSanitizerError.invalidGIF
        }
        loopCount = count
        cursor += 5
        result.append(contentsOf: bytes[start..<cursor])
      } else {
        guard !applicationID.elementsEqual(Array("NETSCAPE".utf8)),
          !applicationID.elementsEqual(Array("ANIMEXTS".utf8)),
          !applicationID.elementsEqual(Array("ICCRGBG1".utf8))
        else { throw ComposerGIFSanitizerError.unsupportedGIF }
        // Ordinary opaque application metadata (including XMP) is discarded.
        // ICC is rejected above because deleting a profile can change colors.
        _ = try subBlocks()
      }
    }

    mutating func subBlocks() throws -> Int {
      var payloadBytes = 0
      while true {
        try Task.checkCancellation()
        let size = Int(try byte())
        if size == 0 { return payloadBytes }
        try advance(size)
        payloadBytes += size
      }
    }

    mutating func byte() throws -> UInt8 {
      try require(1)
      let value = bytes[cursor]
      cursor += 1
      return value
    }

    mutating func advance(_ count: Int) throws {
      try require(count)
      cursor += count
    }

    func require(_ count: Int) throws {
      guard count >= 0, cursor <= bytes.count, count <= bytes.count - cursor else {
        throw ComposerGIFSanitizerError.invalidGIF
      }
    }

    func uint16(at index: Int) -> Int {
      Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }
  }
}
