import Foundation

enum TiebaGalaxy2CUID {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
  private static let prefixLength = 32
  private static let checksumLength = 8
  private static let sectionMask: UInt64 = (1 << 40) - 1

  static func generate() -> String {
    let prefix = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return make(prefix: prefix)!
  }

  static func make(prefix: String) -> String? {
    let bytes = Array(prefix.utf8)
    guard bytes.count == prefixLength, bytes.allSatisfy(isUppercaseHex) else {
      return nil
    }
    return prefix + "|V" + base32(heliosHash(bytes))
  }

  static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard
      bytes.count == prefixLength + 2 + checksumLength,
      bytes[prefixLength] == 0x7C,
      bytes[prefixLength + 1] == 0x56
    else {
      return false
    }

    let prefixBytes = Array(bytes[..<prefixLength])
    guard prefixBytes.allSatisfy(isUppercaseHex) else {
      return false
    }
    let expectedChecksum = base32(heliosHash(prefixBytes)).utf8
    return bytes.suffix(checksumLength).elementsEqual(expectedChecksum)
  }

  private static func isUppercaseHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46)
  }

  // Adapted from TiebaLite's Helios checksum pipeline for Galaxy2 CUID validation.
  private static func heliosHash(_ source: [UInt8]) -> [UInt8] {
    var section = sectionMask
    var buffer = [UInt8](repeating: 0xFF, count: 5)

    update(&section, hash: crc32(source + buffer), start: 8, xor: false)
    appendSection(section, to: &buffer)

    update(&section, hash: xxHash32(source + buffer), start: 0, xor: true)
    appendSection(section, to: &buffer)

    update(&section, hash: xxHash32(source + buffer), start: 1, xor: true)
    appendSection(section, to: &buffer)

    update(&section, hash: crc32(source + buffer), start: 7, xor: true)
    return sectionBytes(section)
  }

  private static func update(
    _ section: inout UInt64,
    hash: UInt32,
    start: UInt64,
    xor: Bool
  ) {
    let mask = UInt64(UInt32.max) << start
    let current = (section & mask) >> start
    let updated = xor ? current ^ UInt64(hash) : current & UInt64(hash)
    section = (section & ~mask) | ((updated << start) & mask)
    section &= sectionMask
  }

  private static func appendSection(_ section: UInt64, to buffer: inout [UInt8]) {
    buffer.append(contentsOf: sectionBytes(section))
  }

  private static func sectionBytes(_ section: UInt64) -> [UInt8] {
    (0..<5).map { UInt8(truncatingIfNeeded: section >> UInt64($0 * 8)) }
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc = UInt32.max
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB8_8320)
      }
    }
    return crc ^ UInt32.max
  }

  private static func xxHash32(_ bytes: [UInt8]) -> UInt32 {
    let prime1: UInt32 = 0x9E37_79B1
    let prime2: UInt32 = 0x85EB_CA77
    let prime3: UInt32 = 0xC2B2_AE3D
    let prime4: UInt32 = 0x27D4_EB2F
    let prime5: UInt32 = 0x1656_67B1
    var offset = 0
    var hash: UInt32

    if bytes.count > 16 {
      var value1 = prime1 &+ prime2
      var value2 = prime2
      var value3: UInt32 = 0
      var value4 = UInt32.zero &- prime1
      while offset <= bytes.count - 16 {
        value1 = xxHashRound(value1, lane: littleEndianUInt32(bytes, at: offset))
        value2 = xxHashRound(value2, lane: littleEndianUInt32(bytes, at: offset + 4))
        value3 = xxHashRound(value3, lane: littleEndianUInt32(bytes, at: offset + 8))
        value4 = xxHashRound(value4, lane: littleEndianUInt32(bytes, at: offset + 12))
        offset += 16
      }
      hash = value1.rotatedLeft(by: 1)
        &+ value2.rotatedLeft(by: 7)
        &+ value3.rotatedLeft(by: 12)
        &+ value4.rotatedLeft(by: 18)
    } else {
      hash = prime5
    }

    hash &+= UInt32(truncatingIfNeeded: bytes.count)
    while offset <= bytes.count - 4 {
      hash = (hash &+ littleEndianUInt32(bytes, at: offset) &* prime3)
        .rotatedLeft(by: 17) &* prime4
      offset += 4
    }
    while offset < bytes.count {
      hash = (hash &+ UInt32(bytes[offset]) &* prime5).rotatedLeft(by: 11) &* prime1
      offset += 1
    }

    hash = (hash ^ (hash >> 15)) &* prime2
    hash = (hash ^ (hash >> 13)) &* prime3
    return hash ^ (hash >> 16)
  }

  private static func xxHashRound(_ value: UInt32, lane: UInt32) -> UInt32 {
    (value &+ lane &* 0x85EB_CA77).rotatedLeft(by: 13) &* 0x9E37_79B1
  }

  private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }

  private static func base32(_ bytes: [UInt8]) -> String {
    var result = [UInt8]()
    result.reserveCapacity((bytes.count * 8 + 4) / 5)
    var accumulator: UInt64 = 0
    var bitCount = 0
    for byte in bytes {
      accumulator = (accumulator << 8) | UInt64(byte)
      bitCount += 8
      while bitCount >= 5 {
        bitCount -= 5
        result.append(alphabet[Int((accumulator >> UInt64(bitCount)) & 0x1F)])
      }
    }
    if bitCount > 0 {
      result.append(alphabet[Int((accumulator << UInt64(5 - bitCount)) & 0x1F)])
    }
    return String(decoding: result, as: UTF8.self)
  }
}

private extension UInt32 {
  func rotatedLeft(by count: UInt32) -> UInt32 {
    (self << count) | (self >> (32 - count))
  }
}
