# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the minimal attributed protobuf schemas used for interoperability are documented
in `Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Development is in progress. Current builds prioritize anonymous, read-only
browsing. The first authenticated milestone is available for device testing,
but authenticated write operations remain intentionally unsupported.

### Discovery and search

- Anonymous post rankings pair a bounded hot-topic preview with a total list
  and bounded server-defined categories. Preview topics open the existing topic
  detail flow, while category changes and refreshes replace the complete post
  ranking snapshot because the endpoint has no pagination contract.
- Ranked hot-topic discovery includes images and discussion counts. Topic
  details provide related forums and cursor-aware thread pagination.
- Forum, thread, and user search are categorized. Global post search supports
  newest, oldest, and relevance sorting; per-forum search supports
  newest/relevance sorting and topic-only or all-content filters.
- Optional online suggestions for the home search field are disabled by
  default. When explicitly enabled, they use a bounded, credential-free
  request after a short pause; failures silently leave the local history flow
  available.
- Per-forum post-search results preserve their matched topic or reply context.
  Per-forum history supports individual deletion and per-forum clearing; global
  history adds recent/all views, individual deletion, clearing, and explicit
  corruption recovery.
- Credential-free public profiles are available from topic threads, search
  results, moderator lists, posts, nested replies, and user mentions. They
  include public statistics, a bounded liked-forum preview, and paginated public
  threads.

### Forums and threads

- Forum pages provide pagination, pull to refresh, reply-time and creation-time
  sorting, featured classifications, and server-defined channels. Channel sort
  menus are bounded server data with independent cursor pagination and
  screen-lifetime sort memory.
- Public forum information includes statistics, introductions, original
  avatars, rules, and moderator teams grouped by server-provided role names.
- Thread reading supports ascending, descending, and hot order, page jumps,
  only-thread-author filtering, anchored opening, direct forum navigation, and
  an independently validated first-floor topic section. That section remains
  available when an anchor or page number opens in the middle of a thread and
  stays outside reply deduplication, physical-page progress, and the PID cursor.
- Anchored ascending threads can prepend the exact adjacent page while
  preserving reading position and the existing tail cursor. After the loaded
  ascending tail is exhausted, users can explicitly check for newly added
  replies without background polling.
- Each floor can show up to four text-only, server-ranked nested-reply previews.
  Full reply pages add parent-floor context, earlier/later pagination, anchored
  highlighting, and safe copy actions.
- Thread pages provide a transient pure-reading mode and full-floor text copy.
  They also preserve anonymous single- and multiple-choice poll results, author
  forum levels, bounded moderator roles, IP locations, and read-only approval
  scores where the server exposes them. Shared-thread origins retain original
  content, media, and navigation.

### Content, media, and navigation

- Forum, channel, hot-thread ranking, hot-topic, global-search, and
  public-profile lists share one metadata-aware thread card. It distinguishes
  pinned, featured, live, shared, and special-format topics. Ordinary rows can
  show one to three downsampled image previews or a nonplaying video cover
  together with reply, view, approval, share, and relative-time context; pinned
  rows stay compact and do not request preview media.
- Rich content supports images, video links, voice playback, and shared-thread
  origin media. Images open in a same-content gallery with paging and zoom;
  explicit actions can share the original file or save it through add-only
  Photos access.
- Content media can either load automatically or wait for an explicit tap.
  Tap-to-load covers thread previews, post images, video covers, per-forum
  search media, and hot-topic images while leaving avatars, opened gallery
  originals, sharing, and saving on their existing user-initiated paths.
- An optional compact mode replaces media previews in thread lists and
  per-forum search with noninteractive type or image-count summaries. Collapsed
  rows create no preview view or request; post bodies, hot-topic images,
  avatars, galleries, sharing, and saving remain unchanged.
- A default-on dark-appearance option reduces successfully rendered static
  content thumbnails to 40% brightness. It is a visual-only treatment for
  thread images, post bodies, per-forum search, and hot topics; video covers,
  avatars, galleries, placeholders, downloads, and caches remain unchanged.
- Forum and thread pages use the native share sheet with canonical HTTPS links.
  Copied thread links retain browse mode, including only-author state.
- A strict in-app router handles supported rich-content links, explicit
  clipboard pastes, and the app-owned `tieba-plus-plus` scheme while preserving
  valid post anchors and reply context.

### Local data and controls

- Versioned browsing history restores the last visible post for stable orders
  together with active sort and filter options. Hot order deliberately reopens
  at its first page because its ranking changes over time.
- Forums and threads have an independent local favorites archive. Saved threads
  retain reading position and browse mode, while saved forums appear as home
  shortcuts. Favorites and browsing history can be cleared independently.
- The home screen projects up to 100 recently visited forums from browsing
  history. The section starts expanded and can be persistently hidden without
  changing the underlying archive.
- Settings provide system, light, and dark appearance, a global forum-sort
  default with normalized per-forum memory, and a no-history mode backed by the
  same versioned browsing-history archive.
- Local filtering supports case-sensitive literal keywords, exact UID/name
  block and allow lists, placeholder or hidden presentation, and independent
  video-topic blocking. It covers forum/channel, hot-thread, and global
  thread-search lists, floors, nested replies, and shared origins without
  changing raw pagination. Per-forum search and public-profile activity are not
  yet filtered, while public profiles can add a user directly to either user
  list.

### Accounts and current limits

- Login uses an ephemeral Baidu Web flow with an exact host allowlist. Account
  records stay in device-only Keychain storage and support local switching and
  logout.
- The authenticated read-only surface currently exposes the active account's
  paginated followed-forum list. Server-side following, favoriting, liking,
  posting, replying, notifications, and moderation remain future milestones.

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
