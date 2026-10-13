import UIKit

// Isolated feasibility probe, not a production editor. Source text and character
// indexes are preserved; only the generated glyph properties/layout/drawing change.
// https://developer.apple.com/documentation/uikit/display-text-with-a-custom-layout
final class SourceGlyphLayout: NSLayoutManager, NSLayoutManagerDelegate {
  private(set) var tokenRanges: [NSRange] = []
  private(set) var generationCalls = 0
  private(set) var controlBoxCalls = 0
  var tokenWidth: CGFloat = 24
  var markedSourceRange: NSRange?
  var suspendsReplacement = false

  override init() {
    super.init()
    delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("The probe constructs its TextKit stack programmatically.")
  }

  func refreshSourceRanges() {
    scanSourceRanges()
    guard let textStorage else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
    invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
    invalidateDisplay(forCharacterRange: fullRange)
  }

  private func scanSourceRanges() {
    guard let textStorage else { return }
    let source = textStorage.string as NSString
    var ranges: [NSRange] = []
    for token in ["#(滑稽)", "#(哈哈)"] {
      var remaining = NSRange(location: 0, length: source.length)
      while remaining.length > 0 {
        let found = source.range(of: token, options: [], range: remaining)
        guard found.location != NSNotFound else { break }
        ranges.append(found)
        let next = NSMaxRange(found)
        remaining = NSRange(location: next, length: source.length - next)
      }
    }
    tokenRanges = ranges.sorted { $0.location < $1.location }
  }

  override func processEditing(
    for textStorage: NSTextStorage,
    edited editMask: NSTextStorage.EditActions,
    range newCharRange: NSRange,
    changeInLength delta: Int,
    invalidatedRange invalidatedCharRange: NSRange
  ) {
    // Invalidating layout from NSTextStorageDelegate.didProcessEditing made
    // UIKit regenerate insertion-point glyphs while the storage was editing.
    // Update the source plan here, then let TextKit invalidate it as part of its
    // normal edit notification, keeping the real edit range and delta intact.
    scanSourceRanges()
    super.processEditing(
      for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
      invalidatedRange: NSRange(location: 0, length: textStorage.length))
  }

  private func replacementRange(at characterIndex: Int) -> NSRange? {
    guard !suspendsReplacement else { return nil }
    return tokenRanges.first { range in
      guard NSLocationInRange(characterIndex, range) else { return false }
      guard let markedSourceRange else { return true }
      return NSIntersectionRange(range, markedSourceRange).length == 0
    }
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes charIndexes: UnsafePointer<Int>,
    font aFont: UIFont,
    forGlyphRange glyphRange: NSRange
  ) -> Int {
    generationCalls += 1
    var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
    var changed = false
    for index in properties.indices {
      guard let range = replacementRange(at: charIndexes[index]) else { continue }
      properties[index] = charIndexes[index] == range.location ? .controlCharacter : .null
      changed = true
    }
    guard changed else { return 0 }
    properties.withUnsafeBufferPointer { pointer in
      layoutManager.setGlyphs(
        glyphs, properties: pointer.baseAddress!, characterIndexes: charIndexes,
        font: aFont, forGlyphRange: glyphRange)
    }
    return glyphRange.length
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    if replacementRange(at: charIndex)?.location == charIndex { return .whitespace }
    return action
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    boundingBoxForControlGlyphAt glyphIndex: Int,
    for textContainer: NSTextContainer,
    proposedLineFragment proposedRect: CGRect,
    glyphPosition: CGPoint,
    characterIndex charIndex: Int
  ) -> CGRect {
    guard replacementRange(at: charIndex)?.location == charIndex else {
      return CGRect(origin: glyphPosition, size: CGSize(width: 0, height: proposedRect.height))
    }
    controlBoxCalls += 1
    return CGRect(
      origin: glyphPosition, size: CGSize(width: tokenWidth, height: proposedRect.height))
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    for (index, range) in tokenRanges.enumerated() {
      guard replacementRange(at: range.location) != nil else { continue }
      let glyphIndex = glyphIndexForCharacter(at: range.location)
      guard NSLocationInRange(glyphIndex, glyphsToShow) else { continue }
      let line = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
      let glyph = location(forGlyphAt: glyphIndex)
      let rect = CGRect(
        x: origin.x + line.minX + glyph.x,
        y: origin.y + line.minY + (line.height - tokenWidth) / 2,
        width: tokenWidth, height: tokenWidth)
      (index.isMultiple(of: 2) ? UIColor.systemYellow : UIColor.systemCyan).setFill()
      UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 4).fill()
      UIColor.black.setFill()
      for fraction in [0.3, 0.65] {
        UIBezierPath(
          ovalIn: CGRect(
            x: rect.minX + tokenWidth * fraction, y: rect.minY + tokenWidth * 0.3,
            width: 3, height: 3)
        ).fill()
      }
    }
  }
}

final class SourceGlyphTextView: UITextView {
  var sourceLayout: SourceGlyphLayout { layoutManager as! SourceGlyphLayout }

  init(frame: CGRect, source: String, fontSize: CGFloat = 24) {
    let storage = NSTextStorage()
    let layout = SourceGlyphLayout()
    layout.tokenWidth = fontSize
    let container = NSTextContainer(
      size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    super.init(frame: frame, textContainer: container)
    font = .systemFont(ofSize: fontSize)
    textColor = .label
    backgroundColor = .systemBackground
    textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    autocorrectionType = .no
    spellCheckingType = .no
    smartQuotesType = .no
    smartDashesType = .no
    text = source
    layout.refreshSourceRanges()
  }

  required init?(coder: NSCoder) {
    fatalError("The probe constructs its TextKit stack programmatically.")
  }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    sourceLayout.suspendsReplacement = true
    sourceLayout.refreshSourceRanges()
    super.setMarkedText(markedText, selectedRange: selectedRange)
    synchronizeMarkedRange()
  }

  override func unmarkText() {
    super.unmarkText()
    synchronizeMarkedRange()
  }

  private func synchronizeMarkedRange() {
    sourceLayout.markedSourceRange = markedTextRange.map {
      NSRange(
        location: offset(from: beginningOfDocument, to: $0.start),
        length: offset(from: $0.start, to: $0.end))
    }
    sourceLayout.suspendsReplacement = false
    sourceLayout.refreshSourceRanges()
  }
}
