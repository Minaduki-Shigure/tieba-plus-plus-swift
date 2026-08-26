import Foundation
import SwiftUI

enum SearchKeywordHighlightPolicy {
  static let maximumQueryCharacterCount = 100
  static let maximumTokenCount = 16
  static let maximumMatchCount = 64
  static let maximumScannedTextCharacterCount = 4_096

  private static let comparisonOptions: String.CompareOptions = [
    .caseInsensitive,
    .diacriticInsensitive,
    .widthInsensitive,
  ]
  private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

  static func tokens(from query: String) -> [String] {
    guard
      !query.isEmpty,
      query.index(
        query.startIndex,
        offsetBy: maximumQueryCharacterCount + 1,
        limitedBy: query.endIndex
      ) == nil
    else { return [] }

    var seen: Set<String> = []
    var result: [String] = []
    result.reserveCapacity(maximumTokenCount)

    for substring in query.split(whereSeparator: { $0.isWhitespace }) {
      let token = String(substring)
      let key = token.folding(
        options: comparisonOptions,
        locale: comparisonLocale
      )
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      result.append(token)
      if result.count == maximumTokenCount { break }
    }
    return result
  }

  static func ranges(
    in text: String,
    query: String
  ) -> [Range<String.Index>] {
    guard !text.isEmpty else { return [] }
    let tokens = tokens(from: query)
    guard !tokens.isEmpty else { return [] }

    let searchableEnd = text.index(
      text.startIndex,
      offsetBy: maximumScannedTextCharacterCount,
      limitedBy: text.endIndex
    ) ?? text.endIndex
    let searchableRange = text.startIndex..<searchableEnd
    var matches: [Range<String.Index>] = []
    matches.reserveCapacity(maximumMatchCount)

    for token in tokens {
      var cursor = searchableRange.lowerBound
      var tokenMatchCount = 0
      while
        cursor < searchableRange.upperBound,
        tokenMatchCount < maximumMatchCount,
        let match = text.range(
          of: token,
          options: comparisonOptions,
          range: cursor..<searchableRange.upperBound,
          locale: comparisonLocale
        )
      {
        matches.append(match)
        tokenMatchCount += 1
        cursor = match.upperBound
      }
    }

    matches.sort { lhs, rhs in
      if lhs.lowerBound == rhs.lowerBound {
        return lhs.upperBound > rhs.upperBound
      }
      return lhs.lowerBound < rhs.lowerBound
    }

    var merged: [Range<String.Index>] = []
    merged.reserveCapacity(min(matches.count, maximumMatchCount))
    for match in matches {
      guard let last = merged.last else {
        merged.append(match)
        continue
      }
      if match.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, match.upperBound)
      } else if merged.count < maximumMatchCount {
        merged.append(match)
      } else {
        break
      }
    }
    return merged
  }

  static func attributedText(
    _ text: String,
    query: String,
    highlightColor: Color
  ) -> AttributedString {
    let ranges = ranges(in: text, query: query)
    guard !ranges.isEmpty else { return AttributedString(text) }

    var result = AttributedString()
    var cursor = text.startIndex
    for range in ranges {
      if cursor < range.lowerBound {
        result.append(AttributedString(String(text[cursor..<range.lowerBound])))
      }
      var highlighted = AttributedString(String(text[range]))
      highlighted.foregroundColor = highlightColor
      result.append(highlighted)
      cursor = range.upperBound
    }
    if cursor < text.endIndex {
      result.append(AttributedString(String(text[cursor...])))
    }
    return result
  }
}

struct SearchHighlightedText: View {
  let text: String
  let query: String

  @Environment(\.appAccentColor) private var appAccentColor

  init(_ text: String, query: String) {
    self.text = text
    self.query = query
  }

  @ViewBuilder
  var body: some View {
    if query.isEmpty {
      Text(text)
    } else {
      Text(
        SearchKeywordHighlightPolicy.attributedText(
          text,
          query: query,
          highlightColor: appAccentColor.color
        )
      )
    }
  }
}
