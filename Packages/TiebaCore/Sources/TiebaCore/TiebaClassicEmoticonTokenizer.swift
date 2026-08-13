import Foundation
import TiebaProto

enum TiebaClassicEmoticonContentToken: Sendable, Equatable {
  case text(String)
  case emoticon(String)

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.text(let lhs), .text(let rhs)), (.emoticon(let lhs), .emoticon(let rhs)):
      return lhs.utf8.elementsEqual(rhs.utf8)
    default:
      return false
    }
  }
}

public enum TiebaClassicEmoticonTokenizer {
  private static let readbackTextTypes: Set<UInt32> = [0, 9, 18, 27, 40]

  /// Returns byte-exact, type-tagged tokens suitable for cross-layer visibility proofs.
  public static func submissionProofTokens(in value: String) -> [[UInt8]]? {
    submissionTokens(in: value)?.map { token in
      switch token {
      case .text(let text):
        [UInt8(0)] + Array(text.utf8)
      case .emoticon(let name):
        [UInt8(1)] + Array(name.utf8)
      }
    }
  }

  static func submissionTokens(
    in value: String
  ) -> [TiebaClassicEmoticonContentToken]? {
    var tokens = [TiebaClassicEmoticonContentToken]()
    var cursor = value.startIndex

    while let marker = value.range(of: "#(", range: cursor..<value.endIndex) {
      appendText(String(value[cursor..<marker.lowerBound]), to: &tokens)
      let nameStart = marker.upperBound
      guard let closingParenthesis = value[nameStart...].firstIndex(of: ")") else {
        return nil
      }
      let rawName = String(value[nameStart..<closingParenthesis])
      guard
        !rawName.isEmpty,
        !rawName.contains(","),
        !rawName.contains("#("),
        !rawName.unicodeScalars.contains(where: {
          CharacterSet.whitespacesAndNewlines.contains($0)
        }),
        let canonicalName = TiebaClassicEmoticonCatalog.canonicalName(exactly: rawName)
      else {
        return nil
      }
      tokens.append(.emoticon(canonicalName))
      cursor = value.index(after: closingParenthesis)
    }
    appendText(String(value[cursor...]), to: &tokens)
    return tokens
  }

  static func readbackTokens(
    in fragments: [PbContent],
    maximumUTF8ByteCount: Int,
    allowsMentions: Bool = false
  ) -> [TiebaClassicEmoticonContentToken]? {
    var tokens = [TiebaClassicEmoticonContentToken]()
    var reconstructedByteCount = 0

    for fragment in fragments {
      if readbackTextTypes.contains(fragment.type) {
        guard appendReadbackText(
          fragment.text,
          to: &tokens,
          byteCount: &reconstructedByteCount,
          maximumUTF8ByteCount: maximumUTF8ByteCount
        ) else { return nil }
      } else if fragment.type == 1 {
        let value = fragment.text.isEmpty ? fragment.link : fragment.text
        guard appendReadbackText(
          value,
          to: &tokens,
          byteCount: &reconstructedByteCount,
          maximumUTF8ByteCount: maximumUTF8ByteCount
        ) else { return nil }
      } else if fragment.type == 2 || fragment.type == 11 {
        guard
          let name = TiebaClassicEmoticonCatalog.canonicalName(exactly: fragment.c),
          let wireToken = TiebaClassicEmoticonCatalog.token(for: name)
        else { return nil }
        reconstructedByteCount += wireToken.utf8.count
        guard reconstructedByteCount <= maximumUTF8ByteCount else { return nil }
        tokens.append(.emoticon(name))
      } else if fragment.type == 4, allowsMentions {
        guard appendReadbackText(
          fragment.text,
          to: &tokens,
          byteCount: &reconstructedByteCount,
          maximumUTF8ByteCount: maximumUTF8ByteCount
        ) else { return nil }
      } else {
        return nil
      }
    }
    return tokens
  }

  static func droppingNestedReplySeparator(
    from tokens: [TiebaClassicEmoticonContentToken]
  ) -> [TiebaClassicEmoticonContentToken]? {
    guard case .text(let text)? = tokens.first else { return nil }
    let bytes = Array(text.utf8)
    let prefixes = [Array(" :".utf8), Array(":".utf8)]
    guard let prefix = prefixes.first(where: { bytes.starts(with: $0) }) else {
      return nil
    }

    var result = Array(tokens.dropFirst())
    let remainder = bytes.dropFirst(prefix.count)
    if !remainder.isEmpty {
      result.insert(.text(String(decoding: remainder, as: UTF8.self)), at: 0)
    }
    return result
  }

  private static func appendReadbackText(
    _ value: String,
    to tokens: inout [TiebaClassicEmoticonContentToken],
    byteCount: inout Int,
    maximumUTF8ByteCount: Int
  ) -> Bool {
    byteCount += value.utf8.count
    guard byteCount <= maximumUTF8ByteCount else { return false }
    appendText(value, to: &tokens)
    return true
  }

  private static func appendText(
    _ value: String,
    to tokens: inout [TiebaClassicEmoticonContentToken]
  ) {
    guard !value.isEmpty else { return }
    if case .text(let previous)? = tokens.last {
      tokens[tokens.count - 1] = .text(previous + value)
    } else {
      tokens.append(.text(value))
    }
  }
}
