import Foundation

enum TiebaReportPageDecoder {
  static func page(from body: Data, expectedPostID: Int64) throws -> TiebaReportPage {
    guard expectedPostID > 0, StrictJSONScanner.accepts(body) else {
      throw TiebaClientError.invalidJSON
    }

    let envelope: ReportPageEnvelope
    do {
      envelope = try JSONDecoder().decode(ReportPageEnvelope.self, from: body)
    } catch {
      throw TiebaClientError.invalidJSON
    }

    guard envelope.errorNumber.value == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: envelope.errorNumber.value),
        message: envelope.errorMessage
      )
    }
    guard
      let rawURL = envelope.data?.url,
      let url = TiebaReportPagePolicy.canonicalReportURL(
        from: rawURL,
        expectedPostID: expectedPostID
      )
    else {
      throw TiebaClientError.invalidJSON
    }
    return TiebaReportPage(postID: expectedPostID, url: url)
  }
}

private struct ReportPageEnvelope: Decodable {
  let errorNumber: ReportPageInteger
  let errorMessage: String
  let data: ReportPageData?

  enum CodingKeys: String, CodingKey {
    case errorNumber = "errno"
    case errorMessage = "errmsg"
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    errorNumber = try container.decode(ReportPageInteger.self, forKey: .errorNumber)
    errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
    if errorNumber.value == 0 {
      data = try container.decode(ReportPageData.self, forKey: .data)
    } else {
      data = nil
    }
  }
}

private struct ReportPageData: Decodable {
  let url: String
}

private struct ReportPageInteger: Decodable {
  let value: Int64

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let integer = try? container.decode(Int64.self) {
      value = integer
      return
    }
    if
      let string = try? container.decode(String.self),
      !string.isEmpty,
      string.utf8.count <= 20,
      string.utf8.allSatisfy({ (48...57).contains($0) }),
      string == "0" || !string.hasPrefix("0"),
      let integer = Int64(string)
    {
      value = integer
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Expected an exact nonnegative decimal integer."
    )
  }
}

/// JSONDecoder accepts the last occurrence of a duplicate key. This lexical pass rejects
/// duplicates, including keys whose JSON escape sequences decode to the same string.
private struct StrictJSONScanner {
  private static let maximumNestingDepth = 64

  private let bytes: [UInt8]
  private var index = 0

  private init(_ body: Data) {
    bytes = Array(body)
  }

  static func accepts(_ body: Data) -> Bool {
    var scanner = StrictJSONScanner(body)
    scanner.skipWhitespace()
    guard scanner.parseValue(depth: 0) else { return false }
    scanner.skipWhitespace()
    return scanner.index == scanner.bytes.count
  }

  private mutating func parseValue(depth: Int) -> Bool {
    guard depth <= Self.maximumNestingDepth, index < bytes.count else { return false }
    switch bytes[index] {
    case 0x7B:  // {
      return parseObject(depth: depth)
    case 0x5B:  // [
      return parseArray(depth: depth)
    case 0x22:  // "
      return parseString() != nil
    case 0x74:  // true
      return consumeLiteral([0x74, 0x72, 0x75, 0x65])
    case 0x66:  // false
      return consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
    case 0x6E:  // null
      return consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
    case 0x2D, 0x30...0x39:
      return parseNumber()
    default:
      return false
    }
  }

  private mutating func parseObject(depth: Int) -> Bool {
    index += 1
    skipWhitespace()
    if consume(0x7D) { return true }

    var keys = Set<String>()
    while true {
      guard
        let keyData = parseString(),
        let key = try? JSONDecoder().decode(String.self, from: keyData),
        keys.insert(key).inserted
      else { return false }
      skipWhitespace()
      guard consume(0x3A) else { return false }
      skipWhitespace()
      guard parseValue(depth: depth + 1) else { return false }
      skipWhitespace()
      if consume(0x7D) { return true }
      guard consume(0x2C) else { return false }
      skipWhitespace()
    }
  }

  private mutating func parseArray(depth: Int) -> Bool {
    index += 1
    skipWhitespace()
    if consume(0x5D) { return true }

    while true {
      guard parseValue(depth: depth + 1) else { return false }
      skipWhitespace()
      if consume(0x5D) { return true }
      guard consume(0x2C) else { return false }
      skipWhitespace()
    }
  }

  private mutating func parseString() -> Data? {
    guard index < bytes.count, bytes[index] == 0x22 else { return nil }
    let start = index
    index += 1
    while index < bytes.count {
      switch bytes[index] {
      case 0x22:
        index += 1
        return Data(bytes[start..<index])
      case 0x00...0x1F:
        return nil
      case 0x5C:
        index += 1
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
          index += 1
        case 0x75:
          guard index + 4 < bytes.count else { return nil }
          for offset in 1...4 where !Self.isHexDigit(bytes[index + offset]) {
            return nil
          }
          index += 5
        default:
          return nil
        }
      default:
        index += 1
      }
    }
    return nil
  }

  private mutating func parseNumber() -> Bool {
    if consume(0x2D), index == bytes.count { return false }
    if consume(0x30) {
      if index < bytes.count, (0x30...0x39).contains(bytes[index]) { return false }
    } else {
      guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { return false }
      index += 1
      while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
    }

    if consume(0x2E) {
      guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return false }
      repeat { index += 1 } while index < bytes.count && (0x30...0x39).contains(bytes[index])
    }
    if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
      index += 1
      if index < bytes.count, (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
      guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return false }
      repeat { index += 1 } while index < bytes.count && (0x30...0x39).contains(bytes[index])
    }
    return true
  }

  private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
    guard index + literal.count <= bytes.count else { return false }
    for (offset, byte) in literal.enumerated() where bytes[index + offset] != byte {
      return false
    }
    index += literal.count
    return true
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x09, 0x0A, 0x0D, 0x20:
        index += 1
      default:
        return
      }
    }
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
      || (0x41...0x46).contains(byte)
      || (0x61...0x66).contains(byte)
  }
}
