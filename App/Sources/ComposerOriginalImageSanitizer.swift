import Foundation
import zlib

// A metadata-only container rewrite. Apple QA1895 documents the distinction
// between copying image data and decoding/re-encoding it. Here an explicit
// container allowlist additionally covers opaque APP segments and PNG chunks
// that are not necessarily exposed by ImageIO's metadata dictionaries.
// JPEG scans/tables and PNG IDAT bytes are copied, never regenerated.
enum ComposerOriginalImageSanitizer {
  // ImageIO may expand iCCP while inspecting properties, before full decode.
  // Bound that expansion before constructing any CGImageSource for original PNG.
  static func preflight(_ data: Data) throws -> Data {
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return data }
    let bytes = [UInt8](data)
    var result = Data(bytes.prefix(8))
    var index = 8
    var foundProfile = false
    var foundCICP = false
    var sawPaletteOrImage = false
    while index < bytes.count {
      try Task.checkCancellation()
      guard index <= bytes.count - 12 else { throw invalid }
      let length = Int(read32(bytes, index))
      guard length <= bytes.count - index - 12 else { throw invalid }
      let end = index + length + 12
      guard crc32(bytes[(index + 4)..<(end - 4)]) == read32(bytes, end - 4) else { throw invalid }
      let name = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
      if ["acTL", "fcTL", "fdAT"].contains(name) {
        throw ComposerImageProcessingError.animatedImage
      }
      if ["mDCV", "cLLI", "mDCv", "cLLi"].contains(name) {
        throw ComposerImageProcessingError.unsupportedOriginal
      }
      if name == "PLTE" || name == "IDAT" { sawPaletteOrImage = true }
      if name == "cICP" {
        guard !foundCICP, !sawPaletteOrImage else { throw invalid }
        foundCICP = true
        try validateSDRCICP(bytes[(index + 8)..<(index + 8 + length)])
      }
      if name == "iCCP" {
        guard !foundProfile else { throw invalid }
        foundProfile = true
        _ = try expandedColorProfile(bytes[(index + 8)..<(index + 8 + length)])
      }
      if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "eXIf", "cICP"]
        .contains(
          name)
      {
        result.append(contentsOf: bytes[index..<end])
      } else if bytes[index + 4] & 0x20 == 0 {
        throw ComposerImageProcessingError.unsupportedOriginal
      }
      // In particular, do not let ImageIO expand discarded zTXt/iTXt text.
      index = end
    }
    return result
  }

  private static func validateSDRCICP(_ payload: ArraySlice<UInt8>) throws {
    // PNG Third Edition §11.3.2.6: cICP is the highest-precedence color chunk,
    // including SDR Display P3 (example 4), not an HDR-only marker. Preserve
    // these exact full-range RGB/sRGB-transfer tuples; reject PQ, HLG, unknown
    // primaries, non-RGB matrices and narrow-range signals without converting.
    guard payload.elementsEqual([1, 13, 0, 1]) || payload.elementsEqual([12, 13, 0, 1]) else {
      throw ComposerImageProcessingError.unsupportedOriginal
    }
  }

  private static func expandedColorProfile(_ payload: ArraySlice<UInt8>) throws -> Data {
    let bytes = Array(payload)
    guard let nameEnd = bytes.firstIndex(of: 0), (1...79).contains(nameEnd),
      nameEnd + 2 < bytes.count, bytes[nameEnd + 1] == 0
    else { throw invalid }
    var compressed = Array(bytes[(nameEnd + 2)...])
    let maximumProfileByteCount = 256 * 1_024
    var expanded = [UInt8](repeating: 0, count: maximumProfileByteCount + 1)
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw invalid
    }
    defer { inflateEnd(&stream) }
    let status = compressed.withUnsafeMutableBufferPointer { input in
      expanded.withUnsafeMutableBufferPointer { output in
        stream.next_in = input.baseAddress
        stream.avail_in = uInt(input.count)
        stream.next_out = output.baseAddress
        stream.avail_out = uInt(output.count)
        return inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, stream.avail_in == 0,
      stream.total_out >= 128, stream.total_out <= maximumProfileByteCount,
      Int(read32(expanded, 0)) == Int(stream.total_out),
      expanded[36..<40].elementsEqual(Array("acsp".utf8))
    else { throw ComposerImageProcessingError.unsupportedOriginal }
    return Data(expanded.prefix(Int(stream.total_out)))
  }

  static func sanitize(
    _ data: Data,
    encoding: ComposerImageAttachmentEncoding,
    orientation: Int,
    canonicalColorProfile: (Data) throws -> Data
  ) throws -> Data {
    guard (1...8).contains(orientation) else {
      throw ComposerImageProcessingError.unsupportedOriginal
    }
    switch encoding {
    case .jpeg:
      return try jpeg(data, orientation: orientation, colorProfile: canonicalColorProfile)
    case .png:
      return try png(data, orientation: orientation, colorProfile: canonicalColorProfile)
    case .gif:
      // GIF has a separate container and per-frame verification path.
      throw ComposerImageProcessingError.unsupportedGIF
    }
  }

  private static func jpeg(
    _ data: Data,
    orientation: Int,
    colorProfile: (Data) throws -> Data
  ) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.starts(with: [0xFF, 0xD8]) else { throw invalid }
    var body = Data()
    var index = 2
    var sawFrame = false
    var sawScan = false
    var sawEnd = false
    var profileSegments: [Int: Data] = [:]
    var profileSegmentCount: Int?
    var profileByteCount = 0
    while index < bytes.count {
      try Task.checkCancellation()
      let start = index
      guard bytes[index] == 0xFF else { throw invalid }
      while index < bytes.count, bytes[index] == 0xFF { index += 1 }
      guard index < bytes.count else { throw invalid }
      let marker = bytes[index]
      index += 1
      if marker == 0xD9 {
        guard index == bytes.count, sawFrame, sawScan else { throw invalid }
        body.append(contentsOf: [0xFF, 0xD9])
        sawEnd = true
        break
      }
      guard index + 1 < bytes.count else { throw invalid }
      let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      guard length >= 2, index <= bytes.count - length else { throw invalid }
      let end = index + length
      let payload = bytes[(index + 2)..<end]
      var retain = false
      switch marker {
      case 0xC0, 0xC1, 0xC2:
        let values = Array(payload)
        guard !sawFrame, values.count >= 6, values[0] == 8,
          values[5] == 1 || values[5] == 3,
          values.count == 6 + Int(values[5]) * 3
        else { throw ComposerImageProcessingError.unsupportedOriginal }
        sawFrame = true
        retain = true
      case 0xC4, 0xDB, 0xDD:
        retain = true
      case 0xDA:
        guard sawFrame else { throw invalid }
        sawScan = true
        retain = true
      case 0xE0:
        if payload.starts(with: Array("JFIF\0".utf8)) {
          // No original density, version text or embedded JFIF thumbnail.
          body.append(
            jpegSegment(
              0xE0,
              payload: Data([
                0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
              ])))
        }
      case 0xE2:
        // Includes MPF (multi-picture / gain-map) and all unknown APP2 payloads.
        guard payload.starts(with: Array("ICC_PROFILE\0".utf8)), payload.count > 14 else {
          throw ComposerImageProcessingError.unsupportedOriginal
        }
        let sequence = Int(bytes[index + 14])
        let count = Int(bytes[index + 15])
        guard sequence > 0, count > 0, sequence <= count,
          profileSegmentCount == nil || profileSegmentCount == count,
          profileSegments[sequence] == nil
        else { throw invalid }
        profileSegmentCount = count
        profileSegments[sequence] = Data(payload.dropFirst(14))
        profileByteCount += payload.count - 14
        guard profileByteCount <= 256 * 1_024 else {
          throw ComposerImageProcessingError.unsupportedOriginal
        }
      case 0xEE:
        // Adobe color transform flags affect JPEG interpretation; the fixed
        // 12-byte binary header has no variable/private text or thumbnail.
        guard payload.count == 12, payload.starts(with: Array("Adobe".utf8)),
          bytes[end - 1] <= 1
        else { throw ComposerImageProcessingError.unsupportedOriginal }
        retain = true
      case 0xEB:
        // JUMBF may describe HDR/alternate representations, not just metadata.
        throw ComposerImageProcessingError.unsupportedOriginal
      case 0xE1, 0xE3...0xEA, 0xEC...0xED, 0xEF, 0xFE:
        let text = String(decoding: payload, as: UTF8.self).lowercased()
        guard !text.contains("gainmap"), !text.contains("hdrgm") else {
          throw ComposerImageProcessingError.unsupportedOriginal
        }
        // EXIF/XMP/IPTC/Photoshop/comments and opaque application data removed.
        break
      default:
        throw ComposerImageProcessingError.unsupportedOriginal
      }
      if retain { body.append(contentsOf: bytes[start..<end]) }
      index = end
      if marker == 0xDA {
        let scanStart = index
        while index < bytes.count {
          if bytes[index] != 0xFF {
            index += 1
            continue
          }
          let nextMarker = index
          while index < bytes.count, bytes[index] == 0xFF { index += 1 }
          guard index < bytes.count else { throw invalid }
          if bytes[index] == 0 || (0xD0...0xD7).contains(bytes[index]) {
            index += 1
          } else {
            index = nextMarker
            break
          }
        }
        body.append(contentsOf: bytes[scanStart..<index])
      }
    }
    guard sawEnd else { throw invalid }
    var result = Data([0xFF, 0xD8])
    if orientation != 1 {
      result.append(
        jpegSegment(0xE1, payload: Data("Exif\0\0".utf8) + orientationTIFF(orientation)))
    }
    if let count = profileSegmentCount {
      guard profileSegments.count == count else { throw invalid }
      var originalProfile = Data()
      for sequence in 1...count {
        guard let segment = profileSegments[sequence] else { throw invalid }
        originalProfile.append(segment)
      }
      let profile = try colorProfile(originalProfile)
      guard !profile.isEmpty, profile.count <= 65_519 else {
        throw ComposerImageProcessingError.unsupportedOriginal
      }
      result.append(
        jpegSegment(
          0xE2, payload: Data("ICC_PROFILE\0".utf8) + Data([1, 1]) + profile
        ))
    }
    result.append(body)
    return result
  }

  private static func png(
    _ data: Data,
    orientation: Int,
    colorProfile: (Data) throws -> Data
  ) throws -> Data {
    let bytes = [UInt8](data)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.starts(with: signature) else { throw invalid }
    var chunks: [(name: String, raw: Data)] = []
    var index = 8
    var sawHeader = false
    var sawImage = false
    var endedImage = false
    var sawEnd = false
    var uniqueChunks = Set<String>()
    var originalProfile: Data?
    while index < bytes.count {
      try Task.checkCancellation()
      guard index <= bytes.count - 12 else { throw invalid }
      let length = Int(read32(bytes, index))
      guard length <= bytes.count - index - 12 else { throw invalid }
      let end = index + 12 + length
      let typeBytes = bytes[(index + 4)..<(index + 8)]
      guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
        crc32(bytes[(index + 4)..<(end - 4)]) == read32(bytes, end - 4)
      else { throw invalid }
      let name = String(decoding: typeBytes, as: UTF8.self)
      guard sawHeader || name == "IHDR" else { throw invalid }
      if sawImage, name != "IDAT" { endedImage = true }
      switch name {
      case "IHDR":
        guard !sawHeader, length == 13,
          [1, 2, 4, 8].contains(bytes[index + 16]),
          [0, 2, 3, 4, 6].contains(bytes[index + 17])
        else { throw ComposerImageProcessingError.unsupportedOriginal }
        sawHeader = true
      case "IDAT":
        guard !endedImage else { throw invalid }
        sawImage = true
      case "IEND":
        guard sawImage, length == 0, end == bytes.count else { throw invalid }
        sawEnd = true
      case "acTL", "fcTL", "fdAT":
        throw ComposerImageProcessingError.animatedImage
      case "mDCV", "cLLI", "mDCv", "cLLi":
        throw ComposerImageProcessingError.unsupportedOriginal
      case "cICP":
        guard !sawImage, !uniqueChunks.contains("PLTE"), uniqueChunks.insert(name).inserted else {
          throw invalid
        }
        try validateSDRCICP(bytes[(index + 8)..<(end - 4)])
      case "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP":
        guard !sawImage, uniqueChunks.insert(name).inserted else { throw invalid }
        if name == "gAMA", length != 4 { throw invalid }
        if name == "cHRM", length != 32 { throw invalid }
        if name == "sRGB", length != 1 { throw invalid }
        if name == "iCCP" {
          originalProfile = try expandedColorProfile(bytes[(index + 8)..<(end - 4)])
        }
      default:
        // Reject unrecognized critical chunks; strip all private/ancillary
        // text, timestamps, eXIf, XMP, physical resolution and preview data.
        guard bytes[index + 4] & 0x20 != 0 else {
          throw ComposerImageProcessingError.unsupportedOriginal
        }
      }
      if ["IHDR", "IDAT", "IEND", "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "cICP"].contains(name) {
        chunks.append((name, Data(bytes[index..<end])))
      }
      index = end
    }
    guard sawEnd else { throw invalid }
    let profile = try originalProfile.map(colorProfile)
    var result = Data(signature)
    for chunk in chunks {
      if profile != nil, ["gAMA", "cHRM", "sRGB"].contains(chunk.name) { continue }
      result.append(chunk.raw)
      if chunk.name == "IHDR" {
        if orientation != 1 {
          result.append(pngChunk("eXIf", payload: orientationTIFF(orientation)))
        }
        if let profile {
          result.append(
            pngChunk("iCCP", payload: Data("Color\0\0".utf8) + (try zlibStored(profile))))
        }
      }
    }
    return result
  }

  // A single SHORT Orientation tag, no next IFD or offsets to original metadata.
  private static func orientationTIFF(_ orientation: Int) -> Data {
    Data([
      0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0,
      0x12, 1, 3, 0, 1, 0, 0, 0, UInt8(orientation), 0, 0, 0,
      0, 0, 0, 0,
    ])
  }

  private static func jpegSegment(_ marker: UInt8, payload: Data) -> Data {
    let count = payload.count + 2
    return Data([0xFF, marker, UInt8(count >> 8), UInt8(count & 255)]) + payload
  }

  private static func pngChunk(_ name: String, payload: Data) -> Data {
    let body = Data(name.utf8) + payload
    return bigEndian32(UInt32(payload.count)) + body + bigEndian32(crc32(body))
  }

  // Canonical system profiles are small. A stored DEFLATE block avoids another
  // image codec/dependency and contains no arbitrary original profile text.
  private static func zlibStored(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= 65_535 else {
      throw ComposerImageProcessingError.unsupportedOriginal
    }
    let count = UInt16(data.count)
    let inverse = ~count
    var result = Data([
      0x78, 1, 1, UInt8(count & 255), UInt8(count >> 8),
      UInt8(inverse & 255), UInt8(inverse >> 8),
    ])
    result.append(data)
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65_521
      b = (b + a) % 65_521
    }
    result.append(bigEndian32((b << 16) | a))
    return result
  }

  private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
  }

  private static func bigEndian32(_ value: UInt32) -> Data {
    Data([
      UInt8(value >> 24), UInt8((value >> 16) & 255),
      UInt8((value >> 8) & 255), UInt8(value & 255),
    ])
  }

  private static let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xEDB8_8320 }
    return value
  }

  private static func crc32<Bytes: Sequence>(_ bytes: Bytes) -> UInt32
  where Bytes.Element == UInt8 {
    var crc = UInt32.max
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
    return crc ^ UInt32.max
  }

  private static var invalid: ComposerImageProcessingError { .invalidSource }
}
