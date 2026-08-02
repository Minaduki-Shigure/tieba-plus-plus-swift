# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the minimal attributed protobuf schemas used for interoperability are documented
in `Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Development is in progress. Anonymous mode supports a ranked hot-topic feed
with paginated topic details, categorized forum, thread, and user search,
global post search with newest, oldest, and relevance sorting,
per-forum post search with newest/relevance and topic/all-content filters,
forum, post, and nested-reply browsing with server-ranked inline previews,
parent-floor context, bidirectional pagination, and anchored opening, remote media, forum metadata and
featured classifications, server-defined forum channels with independent
sorting and cursor pagination, complete public forum introductions, forum rules,
moderator teams, and shared-thread origin cards with original media and
navigation, plus anonymous single- and multiple-choice poll results, post
author forum levels, IP locations, read-only net approval counts, post sorting,
page jumps, an only-thread-author filter, and in-app public-profile navigation
from user mentions without dropping reply context.
Forum, channel, hot-topic, global-search, and public-profile thread lists share
a metadata-aware card that distinguishes pinned, featured, live, shared, and
special-format topics. Ordinary cards can show one to three downsampled image
previews or a nonplaying video cover together with reply, view, approval, share,
and relative-time context; pinned rows stay compact and do not fetch previews.
Topic threads, search results, moderator rows, post authors, and
nested-reply authors open credential-free public user profiles with profile
statistics, a limited public liked-forum preview, and paginated public threads.
The home screen projects up to 100 recently visited forums from the existing
versioned browsing-history archive, shows them expanded by default, and offers
a persistent setting to hide the section. Settings also provide native
system/light/dark appearance, a global default plus remembered per-forum topic
sorting, and a no-history mode backed by the same versioned archive rather than
a second preference. Thread pages provide up to four text-only nested-reply
previews per floor plus full-reply pages with parent-floor context, earlier and
later pagination, anchored target highlighting, and safe copy actions. They also
provide a transient pure-reading mode and full-floor copying. Forum and
thread pages use the native iOS share sheet with canonical HTTPS links; copied
thread links retain the
only-thread-author mode. A single strict router handles supported links in rich
post content, explicit clipboard pastes, and the app-owned
`tieba-plus-plus` URL scheme while preserving valid post anchors.
Local content filtering provides case-sensitive literal-keyword and exact
UID/name user block and allow lists, placeholder or fully hidden presentation,
and an independent switch for video topics. It applies to forum and channel
thread lists, post floors, nested replies, and shared-thread origin cards;
public profiles can add a user directly to either list. Filtering leaves the
raw paginated result set intact and does not currently apply to search results.
Local browsing
history records the last visible post ID for stable post orders and restores it
with the active sort/filter options; the changing hot ranking reopens at its
first page. Forums and threads can also be saved in an independent local
favorites list; saved threads retain their reading position and browsing mode,
while saved forums appear as home-screen shortcuts. History and favorites can
be cleared independently. Per-forum search terms are kept in a separate,
versioned local history and can be deleted individually or cleared for that
forum. Global search terms use their own versioned local history on the home
screen, with recent/all views, individual deletion, clear, and explicit
corruption recovery. The first authenticated milestone adds an ephemeral
Baidu login flow with an exact host allowlist, device-only Keychain storage,
local multi-account switching, and the current account's followed-forum list.
Authenticated write operations
remain intentionally unsupported while this read-only path is validated on real
devices.

See [`ROADMAP.md`](ROADMAP.md) for the current TiebaLite parity matrix and the
next implementation milestones.

## Architecture

- `App`: SwiftUI application shell and feature views.
- `Packages/TiebaCore`: domain models, SwiftProtobuf schemas, request building,
  HTTPS transport, and protocol tests.
- `project.yml`: reproducible XcodeGen project definition.
- `.github/workflows`: core tests, simulator builds, and unsigned SideStore IPA.

The minimum deployment target is iOS 16. Account secrets are stored only in
Keychain with unlocked, device-only accessibility. The login WebView uses a
nonpersistent data store and is destroyed after login. Anonymous and
authenticated API clients are separate, ephemeral transports. API traffic uses
normal URLSession certificate validation; global App Transport Security
exceptions are forbidden. See [`SECURITY.md`](SECURITY.md) before testing an
account build.
The current read-only vault persists BDUSS only; it does not extract or store
STOKEN or the login response's anti-CSRF value.

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
