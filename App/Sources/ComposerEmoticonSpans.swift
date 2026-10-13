import Foundation
import TiebaCore

/// Display metadata in the original text's UTF-16 coordinate space. The editor
/// never replaces token characters with U+FFFC or serializes a display string.
struct ComposerEmoticonSpans: Sendable {
  struct Span: Equatable, Sendable {
    let range: NSRange
    let token: String
    let name: String
    let thumbnailURL: URL
  }

  let source: String
  let spans: [Span]

  private static let entries = Dictionary(
    uniqueKeysWithValues: TiebaClassicEmoticonCatalog.entries.compactMap { entry in
      entry.thumbnailURL.map { ("#(\(entry.name))", (entry.name, $0)) }
    })
  private static let maximumTokenLength = entries.keys.map { $0.utf16.count }.max() ?? 0

  init(source: String, excluding markedRange: NSRange? = nil, availableURLs: Set<URL>? = nil) {
    self.source = source
    let units = Array(source.utf16)
    var boundaries: Set<Int> = [0]
    var characterOffset = 0
    for character in source {
      characterOffset += String(character).utf16.count
      boundaries.insert(characterOffset)
    }
    if let markedRange,
      markedRange.location < 0 || markedRange.length < 0
        || markedRange.location > units.count
        || markedRange.length > units.count - markedRange.location
    {
      self.spans = []
      return
    }
    var spans: [Span] = []
    var index = 0
    // Bounded lookahead keeps unfinished/malformed drafts linear to scan. An
    // unknown outer marker must not swallow a later complete, recognized token.
    while index + 1 < units.count {
      guard units[index] == 35, units[index + 1] == 40 else {
        index += 1
        continue
      }
      let limit = min(units.count, index + Self.maximumTokenLength)
      var end = index + 2
      while end < limit {
        let unit = units[end]
        if unit == 41 {
          let range = NSRange(location: index, length: end + 1 - index)
          let token = String(decoding: units[index...end], as: UTF16.self)
          if let (name, url) = Self.entries[token],
            token.utf8.elementsEqual("#(\(name))".utf8),
            availableURLs?.contains(url) ?? true,
            boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)),
            markedRange.map({
              NSIntersectionRange($0, range).length == 0
                && !($0.length == 0 && $0.location > range.location
                  && $0.location < NSMaxRange(range))
            }) ?? true
          {
            spans.append(Span(range: range, token: token, name: name, thumbnailURL: url))
            index = end
          }
          break
        }
        if unit == 35 || unit == 40 || unit == 10 || unit == 13 { break }
        end += 1
      }
      index += 1
    }
    self.spans = spans
  }

  /// Returns the containing token, with its end boundary excluded. The sorted
  /// source ranges also support per-glyph lookup without scanning every token.
  func span(containingUTF16Offset offset: Int) -> Span? {
    var lower = 0
    var upper = spans.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let span = spans[middle]
      if offset < span.range.location {
        upper = middle
      } else if offset >= NSMaxRange(span.range) {
        lower = middle + 1
      } else {
        return span
      }
    }
    return nil
  }

  /// The visible face is one selection unit, while storage retains every source
  /// character. Reject invalid Unicode ranges instead of retargeting an edit.
  func selection(_ range: NSRange, movingFrom previous: NSRange? = nil) -> NSRange? {
    guard ComposerTextSelection(range).isValid(for: source) else { return nil }
    if range.length == 0 {
      guard let span = span(containingUTF16Offset: range.location),
        range.location > span.range.location
      else { return range }
      let end = NSMaxRange(span.range)
      let location: Int
      if let previous, previous.length == 0, previous.location != range.location {
        location = previous.location > range.location ? span.range.location : end
      } else {
        location =
          range.location - span.range.location < end - range.location
          ? span.range.location : end
      }
      let result = NSRange(location: location, length: 0)
      return ComposerTextSelection(result).isValid(for: source) ? result : nil
    }
    var start = range.location
    var end = NSMaxRange(range)
    if let span = span(containingUTF16Offset: start) { start = span.range.location }
    if let span = span(containingUTF16Offset: end - 1) { end = NSMaxRange(span.range) }
    let result = NSRange(location: start, length: end - start)
    return ComposerTextSelection(result).isValid(for: source) ? result : nil
  }
}
