import UIKit

/// TextKit renders catalog tokens as one face while NSTextStorage, UIKit input,
/// the pasteboard, drafts and submission continue to use the original text.
/// Missing images stay literal; no attachment character enters the document.
final class ComposerEmoticonLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
  private(set) var plan = ComposerEmoticonSpans(source: "")
  private(set) var images: [URL: UIImage] = [:]
  var markedSourceRange: NSRange?
  var suspendsReplacement = false
  var sourceDidChange: (() -> Void)?

  override init() {
    super.init()
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  func refreshSource() {
    scanSource()
    invalidateRendering()
  }

  private func scanSource() {
    guard let textStorage else { return }
    plan = ComposerEmoticonSpans(
      source: textStorage.string,
      excluding: markedSourceRange,
      availableURLs: suspendsReplacement ? [] : Set(images.keys))
  }

  func setImages(_ images: [URL: UIImage]) {
    self.images = images
    refreshSource()
  }

  private func invalidateRendering() {
    let range = NSRange(location: 0, length: textStorage?.length ?? 0)
    invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
    invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    invalidateDisplay(forCharacterRange: range)
  }

  override func processEditing(
    for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions,
    range newCharRange: NSRange, changeInLength delta: Int,
    invalidatedRange invalidatedCharRange: NSRange
  ) {
    // Manual invalidation during a storage edit can cause UIKit to regenerate
    // its insertion-point glyphs before endEditing, which raises an exception.
    // Keep the real edit/delta and let TextKit perform its normal invalidation.
    // Regenerate the whole plan because changing ')' can expose an entire token.
    scanSource()
    super.processEditing(
      for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
      invalidatedRange: NSRange(location: 0, length: textStorage.length))
    if editMask.contains(.editedCharacters) { sourceDidChange?() }
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes charIndexes: UnsafePointer<Int>, font aFont: UIFont,
    forGlyphRange glyphRange: NSRange
  ) -> Int {
    var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
    var changed = false
    for index in properties.indices {
      guard let span = plan.span(containingUTF16Offset: charIndexes[index]) else { continue }
      properties[index] = charIndexes[index] == span.range.location ? .controlCharacter : .null
      changed = true
    }
    guard changed else { return 0 }
    properties.withUnsafeBufferPointer { buffer in
      guard let address = buffer.baseAddress else { return }
      // Preserve the original continuous character indexes, including the null
      // glyphs. Querying neighboring glyphs here could recurse into generation.
      layoutManager.setGlyphs(
        glyphs, properties: address, characterIndexes: charIndexes,
        font: aFont, forGlyphRange: glyphRange)
    }
    return glyphRange.length
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    plan.span(containingUTF16Offset: charIndex)?.range.location == charIndex ? .whitespace : action
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
    for textContainer: NSTextContainer, proposedLineFragment proposedRect: CGRect,
    glyphPosition: CGPoint, characterIndex charIndex: Int
  ) -> CGRect {
    let side =
      plan.span(containingUTF16Offset: charIndex)?.range.location == charIndex
      ? faceSide(at: charIndex) : 0
    return CGRect(origin: glyphPosition, size: CGSize(width: side, height: proposedRect.height))
  }

  private func faceSide(at index: Int) -> CGFloat {
    let font = textStorage?.attribute(.font, at: index, effectiveRange: nil) as? UIFont
    return (font ?? .preferredFont(forTextStyle: .body)).lineHeight
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    guard glyphsToShow.length > 0 else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    for span in plan.spans {
      if span.range.location >= NSMaxRange(characters) { break }
      guard NSIntersectionRange(span.range, characters).length > 0,
        let image = images[span.thumbnailURL]
      else { continue }
      let glyphIndex = glyphIndexForCharacter(at: span.range.location)
      guard NSLocationInRange(glyphIndex, glyphsToShow) else { continue }
      let line = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
      let point = location(forGlyphAt: glyphIndex)
      let side = min(faceSide(at: span.range.location), line.height)
      let scale = side / max(image.size.width, image.size.height, 1)
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      image.draw(
        in: CGRect(
          x: origin.x + line.minX + point.x + (faceSide(at: span.range.location) - size.width) / 2,
          y: origin.y + line.minY + (line.height - size.height) / 2,
          width: size.width, height: size.height))
    }
  }
}

final class ComposerEmoticonTextView: UITextView {
  let emoticonLayout: ComposerEmoticonLayoutManager
  private var imageTask: Task<Void, Never>?
  private var sourceUpdateTask: Task<Void, Never>?
  private var imageRequest: InlineEmoticonImageRequest?
  private var imageAttempt: UUID?
  private var fetchPolicy: DownsampledImageFetchPolicy = .cacheOnly(.preview)
  private let imageLoader: DefaultInlineEmoticonImageLoader

  init(imageLoader: DefaultInlineEmoticonImageLoader = .init()) {
    self.imageLoader = imageLoader
    let storage = NSTextStorage()
    let layout = ComposerEmoticonLayoutManager()
    emoticonLayout = layout
    let container = NSTextContainer(size: .zero)
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    super.init(frame: .zero, textContainer: container)
    // NSTextStorage is owned exclusively by this UIKit view on the main thread.
    layout.sourceDidChange = { [weak self] in
      MainActor.assumeIsolated { self?.scheduleSourceUpdate() }
    }
  }

  required init?(coder: NSCoder) { nil }

  func updateEmoticonImages(fetchPolicy: DownsampledImageFetchPolicy) {
    self.fetchPolicy = fetchPolicy
    updateImageRequest()
    scheduleSourceUpdate()
  }

  private func scheduleSourceUpdate() {
    guard sourceUpdateTask == nil else { return }
    // Never load cached images or alter selection from processEditing itself.
    // Read the current document when this coalesced main-actor task executes.
    sourceUpdateTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self else { return }
      self.sourceUpdateTask = nil
      self.updateImageRequest()
      self.normalizeSelection()
    }
  }

  private func updateImageRequest() {
    let sourcePlan = ComposerEmoticonSpans(source: textStorage.string)
    let request = InlineEmoticonImageRequest(
      urls: sourcePlan.spans.map(\.thumbnailURL), fetchPolicy: fetchPolicy)
    guard request != imageRequest else { return }
    imageRequest = request
    imageTask?.cancel()
    let attempt = UUID()
    imageAttempt = attempt
    // Keep already decoded catalog faces for this editor's lifetime so deleting
    // and undoing a token does not briefly unfold it after global cache eviction.
    // The compiled catalog bounds this palette; requests still use current text.
    var available = emoticonLayout.images
    for (url, asset) in imageLoader.cachedImages(for: request) { available[url] = asset.image }
    emoticonLayout.setImages(available)
    let missing = InlineEmoticonImageRequest(
      urls: request.urls.filter { available[$0] == nil }, fetchPolicy: request.fetchPolicy)
    guard !missing.urls.isEmpty else { return }
    let loader = imageLoader
    imageTask = Task { @MainActor [weak self] in
      let assets = await InlineEmoticonImageLoader.load(missing, using: loader)
      guard !Task.isCancelled, let self, self.imageAttempt == attempt else { return }
      var images = self.emoticonLayout.images
      for (url, asset) in assets { images[url] = asset.image }
      self.emoticonLayout.setImages(images)
      self.normalizeSelection()
    }
  }

  func stopLoadingImages() {
    sourceUpdateTask?.cancel()
    sourceUpdateTask = nil
    imageTask?.cancel()
    imageTask = nil
    imageAttempt = nil
    imageRequest = nil
  }

  /// Display updates do not assign text/attributedText and therefore cannot add
  /// an undo operation or replace an active input method's document.
  func normalizeSelection(movingFrom previous: NSRange? = nil) {
    guard markedTextRange == nil, !emoticonLayout.suspendsReplacement,
      let range = emoticonLayout.plan.selection(selectedRange, movingFrom: previous),
      selectedRange != range
    else { return }
    selectedRange = range
  }

  override func deleteBackward() {
    if markedTextRange == nil, !emoticonLayout.suspendsReplacement {
      var range = selectedRange
      if range.length == 0, range.location > 0,
        emoticonLayout.plan.span(containingUTF16Offset: range.location - 1) != nil
      {
        range = NSRange(location: range.location - 1, length: 1)
      }
      if let expanded = emoticonLayout.plan.selection(range), expanded != selectedRange {
        selectedRange = expanded
      }
    }
    super.deleteBackward()
    synchronizeMarkedRange()
  }

  override func insertText(_ text: String) {
    super.insertText(text)
    synchronizeMarkedRange()
    normalizeSelection()
  }

  override func replace(_ range: UITextRange, withText text: String) {
    super.replace(range, withText: text)
    synchronizeMarkedRange()
  }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    emoticonLayout.suspendsReplacement = true
    emoticonLayout.refreshSource()
    super.setMarkedText(markedText, selectedRange: selectedRange)
    synchronizeMarkedRange()
  }

  override func unmarkText() {
    super.unmarkText()
    synchronizeMarkedRange()
  }

  private func synchronizeMarkedRange() {
    let range = markedTextRange.map {
      NSRange(
        location: offset(from: beginningOfDocument, to: $0.start),
        length: offset(from: $0.start, to: $0.end))
    }
    guard range != emoticonLayout.markedSourceRange || emoticonLayout.suspendsReplacement else {
      return
    }
    emoticonLayout.markedSourceRange = range
    emoticonLayout.suspendsReplacement = false
    emoticonLayout.refreshSource()
  }
}
