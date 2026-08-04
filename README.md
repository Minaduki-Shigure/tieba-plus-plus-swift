# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the minimal attributed protobuf schemas used for interoperability are documented
in `Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Current builds remain focused on anonymous, read-only browsing. The first
authenticated milestone is available for device testing, but authenticated
write operations remain intentionally unsupported. Capabilities are grouped
by the workflow in which they appear; each bold label identifies the
corresponding surface or control.

### Discovery and search

- **Post rankings:** Anonymous post rankings pair a bounded hot-topic preview
  with a total list and bounded server-defined categories. Preview topics open
  the existing topic detail flow, while category changes and refreshes replace
  the complete post ranking snapshot because the endpoint has no pagination
  contract.
- **Hot topics:** Ranked hot-topic discovery includes images and discussion
  counts. Topic details provide related forums and cursor-aware thread
  pagination.
- **Search:** Forum, thread, and user search are categorized. Global post
  search supports newest, oldest, and relevance sorting; per-forum search
  supports newest/relevance sorting and topic-only or all-content filters.
- **Suggestions:** Optional online suggestions for the home search field are
  disabled by default. When explicitly enabled, they use a bounded,
  credential-free request after a short pause; failures silently leave the
  local history flow available.
- **Home entry:** Home-entry customization can hide the discovery section and
  choose a next-launch destination from the home page, post ranking, hot
  topics, local favorites, or browsing history. Defaults preserve the existing
  home page and discovery section, while an incoming supported Tieba link
  remains the topmost destination.
- **Search context and history:** Per-forum post-search results preserve their
  matched topic or reply context. Per-forum history supports individual
  deletion and per-forum clearing; global history adds recent/all views,
  individual deletion, clearing, and explicit corruption recovery.
- **Public profiles:** Credential-free public profiles are available from
  topic threads, search results, moderator lists, posts, nested replies, and
  user mentions. They include public statistics, a bounded liked-forum preview,
  and paginated public threads. An explicit avatar tap opens the best available
  portrait source in the existing image viewer, where it can be shared or
  saved; a derived larger portrait is not requested before that tap.

### Forums and threads

- **Forum lists:** Forum pages provide pagination, pull to refresh, reply-time
  and creation-time sorting, featured classifications, and server-defined
  channels. Channel sort menus are bounded server data with independent cursor
  pagination and screen-lifetime sort memory.
- **Forum actions:** Forum toolbars provide explicit refresh and return-to-top
  actions without replacing native pull-to-refresh or iOS status-bar tap-to-top
  behavior. Sharing stays available from the same bounded toolbar menu.
- **Forum information:** Public forum information includes statistics,
  introductions, original avatars, rules, and moderator teams grouped by
  server-provided role names.
- **Thread navigation:** Thread reading supports ascending, descending, and
  hot order, page jumps, only-thread-author filtering, anchored opening, direct
  forum navigation, and an independently validated first-floor topic section.
  That section remains available when an anchor or page number opens in the
  middle of a thread and stays outside reply deduplication, physical-page
  progress, and the PID cursor.
- **Anchored reading:** Anchored ascending threads can prepend the exact
  adjacent page while preserving reading position and the existing tail cursor.
  After the loaded ascending tail is exhausted, users can explicitly check for
  newly added replies without background polling.
- **Replies:** Each floor can show up to four text-only, server-ranked
  nested-reply previews. Full reply pages add parent-floor context,
  earlier/later pagination, anchored highlighting, and safe copy actions.
- **Reading tools and metadata:** Thread pages provide a transient pure-reading
  mode and full-floor text copy. They also preserve anonymous single- and
  multiple-choice poll results, author forum levels, bounded moderator roles,
  IP locations, and read-only approval scores where the server exposes them.
  Shared-thread origins retain original content, media, and navigation.

### Content, media, and navigation

- **Thread cards:** Forum, channel, hot-thread ranking, hot-topic,
  global-search, and public-profile lists share one metadata-aware thread card.
  It distinguishes pinned, featured, live, shared, and special-format topics.
  Ordinary visible rows can show a bounded, downsampled author avatar together
  with one to three image previews or a nonplaying video cover, plus reply,
  view, approval, share, and relative-time context. Pinned rows stay compact
  and request neither author avatars nor preview media.
- **Rich-content layout:** Rich content supports images, video links, voice
  playback, and shared-thread origin media. Consecutive images in post-like
  content use a one-to-three-column masonry layout based on their actual
  container width; Accessibility Dynamic Type and forum-rule documents remain
  single-column.
- **Audio and video playback:** Voice and video share one application-scoped
  playback arbiter, so starting either pauses the previous voice or video and
  never resumes it implicitly. Voice retains loading and failure states,
  elapsed and resolved duration, and an accessible seek slider. A single video
  player is created lazily only after an explicit valid playback request and
  uses native AVKit inline and full-screen controls; merely rendering a cover
  creates no player. Native play and pause controls participate in the same
  arbitration. Playback pauses when the app becomes inactive, an interruption
  begins, or the active output disappears, and returning active does not resume
  it automatically. Picture in Picture is disabled.
- **Image gallery:** Images open immediately in a same-floor gallery with paging
  and zoom. In an ordinary unfiltered thread, the gallery can expand
  anonymously across floors, preserve repeated occurrences, lazily load in both
  directions, and show the server's global image position; other contexts and
  filtered threads remain scoped to their already visible content.
  Original-image loading shows an exact transfer percentage when the server
  supplies a reliable length; unknown or inconsistent lengths remain
  indeterminate. Explicit actions can share the selected original file or save
  it through add-only Photos access.
- **Media loading:** Content media can load automatically, conserve data, or
  wait for every explicit tap. Data-saving mode loads automatically only on an
  available network that iOS does not mark expensive or constrained; otherwise
  it reads the memory cache first and offers a load control. These modes cover
  thread previews, post images, video covers, per-forum search media, and
  hot-topic images. Avatars remain outside this policy on their existing
  automatic path; opened gallery originals, sharing, and saving remain
  user-initiated. A separate preview-quality setting keeps the existing standard
  source by default or selects a returned high-definition source for post bodies,
  thread cards, and per-forum search.
  It does not make original images load automatically or change when networking
  is allowed.
- **Compact previews:** An optional compact mode replaces media previews in
  thread lists and per-forum search with noninteractive type or image-count
  summaries. Collapsed rows create no preview view or request; post bodies,
  hot-topic images, avatars, galleries, sharing, and saving remain unchanged.
- **Dark appearance:** A default-on dark-appearance option reduces successfully
  rendered static content thumbnails to 40% brightness. It is a visual-only
  treatment for thread images, post bodies, per-forum search, and hot topics;
  video covers, avatars, galleries, placeholders, downloads, and caches remain
  unchanged.
- **Sharing:** Forum and thread pages use the native share sheet with canonical
  HTTPS links. Copied thread links retain browse mode, including only-author
  state.
- **Link routing:** A strict in-app router handles supported rich-content
  links, explicit clipboard pastes, and the app-owned `tieba-plus-plus` scheme
  while preserving valid post anchors and reply context.
- **External links:** External HTTPS links use the system default browser unless
  the user selects an in-app Safari view. Supported Tieba links remain native
  routes, while HTTP links stay with the system browser in either mode.

### Local data and controls

- **History:** Versioned browsing history restores the last visible post for stable orders
  together with active sort and filter options. Hot order deliberately reopens
  at its first page because its ranking changes over time.
- **Favorites:** Forums and threads have an independent local favorites archive. Saved threads
  retain reading position and browse mode. Two default-off controls are evaluated
  when a thread is opened from local favorites and can force only-author or
  descending mode. That effective mode participates in the existing favorite
  and history persistence, so later openings can resume it. Saved forums appear
  as home shortcuts and can be pinned above other favorites. An explicit context
  menu can pin or unpin a forum, copy its canonical name, or remove it locally.
  Favorites and browsing history can be cleared independently.
- **Recent forums:** The home screen projects up to 100 recently visited forums from browsing
  history. The section starts expanded and can be persistently hidden without
  changing the underlying archive.
- **General settings:** Settings provide system, light, and dark appearance, a
  controlled five-color accent palette with light, dark, and increased-contrast
  variants, a global forum-sort default with normalized per-forum memory, and a
  no-history mode backed by the same versioned browsing-history archive.
- **Image cache:** Settings can explicitly evict the process-local decoded-image cache without
  cancelling active transfers or removing currently displayed images. The app
  has no persistent image cache, so this action does not claim disk-space
  recovery and later image views may download again.
- **Text size:** A persistent six-position app text-size adjustment moves the SwiftUI
  interface from two steps smaller through three steps larger relative to the
  current iOS Dynamic Type category. Following the system is the default;
  semantic fonts and scale-aware controls update immediately, while Safari,
  share sheets, and other system UI retain their system-managed text size.
- **Author names:** A default-off author-name option can combine each returned public nickname
  and username as `nickname(username)` across live content, search, profiles,
  forum staff, browsing history, and local favorites. It uses existing response
  fields and does not add a network request.
- **Filtering:** Local filtering supports case-sensitive literal keywords, exact UID/name
  block and allow lists, placeholder or hidden presentation, and independent
  video-topic blocking. It covers forum/channel, hot-thread, global and
  per-forum search lists, public-profile activity, floors, nested replies, and
  shared origins without changing raw pagination. Per-forum search filters the
  matched result and its displayed context independently, while public profiles
  can add a user directly to either user list.

### Accounts and current limits

- **Account storage:** Login uses an ephemeral Baidu Web flow with an exact host allowlist. Account
  records stay in device-only Keychain storage and support local switching and
  logout.
- **Authenticated scope:** The authenticated read-only surface currently
  exposes the active account's paginated followed-forum list. Server-side
  following, favoriting, liking, posting, replying, notifications, and
  moderation remain future milestones.

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
