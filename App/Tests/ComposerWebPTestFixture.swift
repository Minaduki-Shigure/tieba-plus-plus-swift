import Foundation

/// Small real libwebp bitstreams generated from solid-color images with ImageMagick.
/// Container helpers change only RIFF framing; the codec payloads are not synthetic.
enum ComposerWebPTestFixture {
  static let lossy = Data(base64Encoded:
    "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoIAAYAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=")!
  static let lossless = Data(base64Encoded:
    "UklGRiAAAABXRUJQVlA4TBQAAAAvB0ABAAcQ/Y/+BwCC8L9tIqL/IQ==")!
  static let alphaLossless = Data(base64Encoded:
    "UklGRiIAAABXRUJQVlA4TBYAAAAvB0ABEA8w/xEDGAyAIBL895qI6H8I")!
  static let alphaLossy = Data(base64Encoded:
    "UklGRnIAAABXRUJQVlA4WAoAAAAQAAAABwAABQAAQUxQSBEAAAABDzCAERECIIgE/70mIvofAgBWUDggOgAAABACAJ0BKggABgABQCYlqAJ0cgCr/9wABcAA/ukiH/m4/eSg5f9se8lBy/+nP+Kdw5//8c/4p3CAAAA=")!
  private static let partialGreen = Data(base64Encoded:
    "UklGRhwAAABXRUJQVlA4TA8AAAAvA0AAAAfQ/4j+ByKi/wEA")!

  struct Chunk: Equatable {
    let type: String
    var payload: Data

    init(_ type: String, _ payload: Data) {
      precondition(type.utf8.count == 4)
      self.type = type
      self.payload = payload
    }

    var encoded: Data {
      var result = Data(type.utf8)
      result.append(littleEndian(payload.count, bytes: 4))
      result.append(payload)
      if !payload.count.isMultiple(of: 2) { result.append(0) }
      return result
    }
  }

  static func animated(frameCount: Int = 2, loopCount: Int = 3) -> Data {
    var result = [
      Chunk("VP8X", Data([0x02, 0, 0, 0, 7, 0, 0, 5, 0, 0])),
      Chunk("ANIM", Data([0, 0, 0, 0]) + littleEndian(loopCount, bytes: 2)),
    ]
    for index in 0..<frameCount {
      let partial = index.isMultiple(of: 2) == false
      var frame = littleEndian(partial ? 1 : 0, bytes: 3)
      frame.append(littleEndian(partial ? 1 : 0, bytes: 3))
      frame.append(littleEndian(partial ? 3 : 7, bytes: 3))
      frame.append(littleEndian(partial ? 1 : 5, bytes: 3))
      frame.append(littleEndian(partial ? 130 : 70, bytes: 3))
      // Full frame replaces the canvas; partial frame blends and disposes to background.
      frame.append(partial ? 1 : 2)
      frame.append((partial ? partialGreen : lossless).dropFirst(12))
      result.append(Chunk("ANMF", frame))
    }
    return container(result)
  }

  static func withMetadata(
    _ data: Data, orientation: Int = 6, icc: Data? = nil
  ) -> Data {
    var result = chunks(data)
    if result.first?.type != "VP8X" {
      let alpha: UInt8 = data == alphaLossless ? 0x10 : 0
      result.insert(Chunk("VP8X", Data([alpha, 0, 0, 0, 7, 0, 0, 5, 0, 0])), at: 0)
    }
    result[0].payload[0] |= 0x0C  // EXIF and XMP.
    if let icc {
      result[0].payload[0] |= 0x20
      result.insert(Chunk("ICCP", icc), at: 1)
    }
    // IFD0 contains orientation and a valid software field carrying private text.
    var exif = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0, 2, 0])
    exif.append(contentsOf: [0x12, 0x01, 3, 0, 1, 0, 0, 0])
    exif.append(littleEndian(orientation, bytes: 2))
    exif.append(contentsOf: [0, 0, 0x31, 0x01, 2, 0, 8, 0, 0, 0, 38, 0, 0, 0])
    exif.append(contentsOf: [0, 0, 0, 0])
    exif.append(Data("private\0".utf8))
    result.append(Chunk("EXIF", exif))
    result.append(Chunk("XMP ", Data("private-location-and-account".utf8)))
    return container(result)
  }

  static func chunks(_ data: Data) -> [Chunk] {
    let bytes = [UInt8](data)
    var result: [Chunk] = []
    var offset = 12
    while offset + 8 <= bytes.count {
      let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << ($1 * 8) }
      precondition(size <= bytes.count - offset - 8)
      result.append(Chunk(
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self),
        Data(bytes[(offset + 8)..<(offset + 8 + size)])))
      offset += 8 + size + size % 2
    }
    precondition(offset == bytes.count)
    return result
  }

  static func container(_ chunks: [Chunk]) -> Data {
    var body = Data("WEBP".utf8)
    for chunk in chunks { body.append(chunk.encoded) }
    return Data("RIFF".utf8) + littleEndian(body.count, bytes: 4) + body
  }

  static func littleEndian(_ value: Int, bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8((value >> ($0 * 8)) & 255) })
  }
}
