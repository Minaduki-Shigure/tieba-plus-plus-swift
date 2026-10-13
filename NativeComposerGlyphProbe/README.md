# Source-preserving composer glyph experiment

This isolated UIKit app and hosted XCTest target do not compile or modify the
Tieba++ product. The branch-only `composer-glyph-probe.yml` runs on Xcode 16.4 / an
iOS 18.5 simulator. No account, credential, network image, or release is used.

The experiment follows Apple's
[Display text with a custom layout](https://developer.apple.com/documentation/uikit/display-text-with-a-custom-layout):
retain source characters and character indexes, replace a token's first glyph
property with `.controlCharacter`, use the `.whitespace` control action with a
fixed box, mark remaining token glyphs `.null`, and draw a colored placeholder
without changing text storage. This does not implement a source/display text
projection or production selection policy.

Six tests measure width/caret positions, mixed scripts and wrapping, line-edge
layout, native copy, native insertion/deletion/undo/redo, and marked-text commit.
PNG/JSON attachments and raw XCTest logs record the observations, including
whether native backspace removes a whole token or only part of it. A partial
deletion is not described as atomic-token support. Failed assertions are evidence
that the proposed architecture needs correction; signing or compilation alone
does not prove feasibility. Real Chinese keyboard interactions, VoiceOver,
production draft lifecycle, and iOS 16 compatibility remain separate checks.

Initial experiment status: prepared; native results pending. Only the two fixed
tokens `#(滑稽)` and `#(哈哈)` are recognized. The scanner invalidates glyphs after
source changes and shows source glyphs while a token overlaps marked text.
