# Composer inline classic emoticons

Status on 2026-10-13: implementation candidate; native validation is in progress.
This document does not claim release or physical-device completion.

## Behavior and source fidelity

TiebaLite `9701bfb6` renders classic faces inside its shared topic/reply editor
while retaining their text markers. Tieba++ already supports the same catalog
in selection, drafts, submission and reading. This candidate adds the missing
editable-body presentation to the two existing production composers.

`ComposerEmoticonTextView` uses one TextKit 1 text storage and layout manager.
Recognized `#(name)` text remains in `NSTextStorage`; a loaded face replaces only
the displayed glyphs. The first source glyph occupies one font line-height of
horizontal space and the remaining token glyphs are null. It does not replace
the document with attachment characters or maintain a second compressed text
coordinate system. UIKit editing, source selections, copying, drafts and sending
therefore continue to use the same original UTF-16 indexes and token bytes.

The approach uses Apple's public
[glyph-substitution example](https://developer.apple.com/documentation/uikit/display-text-with-a-custom-layout).
Continuous source indexes are retained in the generation callback, which never
queries neighboring glyphs that might recursively trigger generation.

## Input and document ownership

- Only exact compiled-catalog names with images are folded. Unknown names,
  unavailable images and token boundaries joined to a combining character remain
  literal text. Network behavior reuses the existing media-loading preference
  and the catalog-only, bounded thumbnail loader.
- Token recognition never changes text. Image completion invalidates rendering,
  not the document or its undo history. Loaded catalog images remain in the
  editor's bounded palette through delete/undo.
- IME marked ranges remain literal. Selection normalization and whole-face
  backward deletion are suspended while the input method owns marked text.
- Picker insertion uses `UITextView.insertText`, including selected-text
  replacement, after checking the exact current source, selection, editable
  state and document identity. The existing content-admission check remains in
  each composer. No response or account endpoint changes.
- External draft restoration, clearing and account changes create a new document
  identity and clear native undo history even if the new text is identical.
  Pending picker commands cannot edit the previous document after invalidation.

## Validation boundary

The isolated branch `ci/composer-glyph-probe-1013` measures source-preserving
glyph generation, width, wrapping, copying, native undo and marked-text behavior
with a minimal UIKit app. This experiment alone cannot prove that the production
picker, SwiftUI bindings, draft stores or lifecycle are wired correctly.

The production candidate adds source-boundary tests, mounted UIKit layout and
editing tests, and coordinator/controller tests. Separate UI workflows must
exercise the actual production composers and picker, including persisted draft
restoration. Native results, screenshots and any failures must be recorded before
this candidate is counted as verified or released. Physical-device checks remain
necessary for the Chinese keyboard's composition and candidate selection,
selection handles, accessibility, hardware keyboards and LiveContainer.

The isolated experiment initially passed the single-face metrics and mixed-script
wrapping checks but failed during marked text with `attempted glyph generation
while textStorage is editing`. Its stack traced manual layout invalidation from
`NSTextStorageDelegate.didProcessEditing` into UIKit's insertion-point layout.
The candidate now updates its source plan in `NSLayoutManager.processEditing`
and passes the real edit range/delta to TextKit with a full invalidated range.
Image loading and selection normalization are coalesced onto a later main-actor
task. This correction is undergoing native rerun with the original assertions;
the failure has not been waived or counted as a passing interaction.
