# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The project is
implemented from public protocol research and does not include code or assets
from TiebaLite.

## Status

Development is in progress. Anonymous mode supports forum and thread search,
forum, post, and nested-reply browsing, remote media, forum metadata and
featured classifications, post sorting, page jumps, and an only-thread-author
filter. Local browsing history records the last visible post ID for stable post
orders and restores it with the active sort/filter options; the changing hot
ranking reopens at its first page. Recording can be disabled or cleared in the
app. Account credentials and write operations are intentionally excluded until
the anonymous protocol path is stable on real devices.

See [`ROADMAP.md`](ROADMAP.md) for the current TiebaLite parity matrix and the
next implementation milestones.

## Architecture

- `App`: SwiftUI application shell and feature views.
- `Packages/TiebaCore`: domain models, SwiftProtobuf schemas, request building,
  HTTPS transport, and protocol tests.
- `project.yml`: reproducible XcodeGen project definition.
- `.github/workflows`: core tests, simulator builds, and unsigned SideStore IPA.

The minimum deployment target is iOS 16. Account secrets will be stored only in
Keychain with device-only accessibility. API traffic uses normal URLSession
certificate validation; global App Transport Security exceptions are forbidden.

## Build

Install Xcode 16.4 or newer and XcodeGen 2.45.4, then run:

```sh
xcodegen generate
xcodebuild \
  -project TiebaPlusPlus.xcodeproj \
  -scheme TiebaPlusPlus \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the protocol package tests with:

```sh
swift test --package-path Packages/TiebaCore
```

## Distribution

The initial distribution target is SideStore-compatible self-signing. The
`Build unsigned IPA` workflow creates an unsigned IPA that must be signed by the
installer. App Store distribution is not currently a project goal.

## License

GPL-3.0-only. See `LICENSE`.
