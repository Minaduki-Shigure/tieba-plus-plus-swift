# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the minimal attributed protobuf schemas used for interoperability are documented
in `Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Tieba++ is an alpha-stage, native SwiftUI client. Anonymous browsing is the
current stable focus; account writes remain experimental and require device
validation. The table below separates what is usable today from what remains
experimental or unsupported.

| Area | Current state |
| --- | --- |
| Anonymous browsing | Available across discovery, search, forums, threads, replies, profiles, and media |
| Local features | Available for history, favorites, filtering, appearance, and media preferences |
| Accounts | Web login, switching, logout, followed forums, and experimental per-forum follow and check-in state |
| Server-side writes | Confirmed forum follow/unfollow and explicit single-forum check-in are in device validation; other writes stay disabled |
| TiebaLite parity | Anonymous reading and media: about 85–95%; full product scope: about 52–57% |
| Distribution | Public SideStore/LiveContainer source backed by tested unsigned GitHub Release IPAs |

### Release and validation

- **Next unreleased validation build:** The source planned for
  `v0.56.0-alpha.1` adds authoritative per-forum check-in state and an explicit
  single-forum check-in action alongside confirmed follow/unfollow. Until that
  tag passes CI and is published, the app source continues to serve the prior
  tested alpha.
- **Compatibility:** The deployment target is iOS 16. Builds use Xcode 16.4 and
  XcodeGen 2.45.4 or newer.
- **Automated checks:** GitHub Actions runs package tests and an unsigned
  simulator build, validates the app source, and verifies its public IPA hash.
  Authenticated flows never use real credentials in CI. Forum follow/unfollow
  and check-in therefore remain physical-device validation features in this
  alpha.
- **App source:** Add [`sidestore-source.json`](https://raw.githubusercontent.com/Minaduki-Shigure/tieba-plus-plus-swift/main/sidestore-source.json)
  to LiveContainer or SideStore. Its latest IPA is published only after the tag's
  package, anonymous integration, and simulator tests all pass.
- **Login hotfix:** `v0.54.0-alpha.1` can reach Tieba's account page without
  completing because its callback and Cookie matching are too strict.
  `v0.54.1-alpha.1` made that failure explicit and confirmed that iOS 18.7.2
  can expose no eligible Secure candidate. `v0.54.2-alpha.1` adds a constrained
  non-Secure metadata fallback only inside the isolated HTTPS login callback;
  the selected credential still requires online account validation. The flow has
  since completed successfully in physical-device testing on iOS 18.7.2.

### Discovery and forums

- **Discovery:** Anonymous post rankings, hot-topic previews, category snapshots,
  topic details, related forums, and cursor-aware topic pagination are available.
- **Search:** Forum, thread, and user search are separated by category. Global
  and per-forum post search provide the supported sort and content filters,
  local history, and optional credential-free suggestions.
- **Forum browsing:** Forum and channel lists support pagination, refresh,
  reply-time or creation-time sorting, server-defined classifications, and
  bounded channel menus with independent cursors.
- **Public information:** Forum introductions, statistics, rules, moderator
  teams, and credential-free user profiles are available. Public liked-forum
  data is presented only as a bounded preview.

### Threads and media

- **Thread reading:** Ascending, descending, and hot order, only-author mode,
  page jumps, anchored opening, earlier-page loading, first-floor context, and
  explicit latest-reply checks are implemented with cursor validation.
- **Replies and metadata:** Floors, nested replies, parent context, polls,
  shared-thread origins, author levels, moderator roles, IP locations, and
  read-only approval scores are preserved where returned by the server.
- **Images:** Responsive image groups open in a pageable, zoomable gallery.
  Ordinary unfiltered threads can expand the gallery across floors; originals
  can be explicitly shared or saved through add-only Photos access.
- **Playback:** Voice and native AVKit video share one application-wide playback
  coordinator. Starting new media pauses the prior item, inactive scenes pause
  playback, and playback never resumes implicitly. Picture in Picture is off.
- **Links and sharing:** Supported Tieba links stay in the native router with
  post and reply context. External HTTPS links use the selected system or Safari
  presentation, while forum and thread sharing emits canonical HTTPS links.

### Local data and controls

- **History:** Versioned browsing and search history support restoration,
  individual deletion, clearing, no-history mode, and corruption recovery.
  Recent forums are projected from the same browsing archive.
- **Favorites:** Forums and threads use a separate local archive. Saved forums
  can be pinned as home shortcuts; saved threads retain position and browse mode
  and can apply explicit only-author or descending overrides.
- **Filtering:** Local literal-keyword, exact user block/allow, and video-topic
  filters cover list, profile, floor, nested-reply, and shared-origin surfaces
  without modifying network pagination.
- **Appearance:** System, light, and dark themes, a bounded accent palette,
  Dynamic Type-relative text sizing, compact previews, and optional combined
  nickname/username presentation are persistent local controls.
- **Media policy:** Automatic, data-saving, or tap-to-load behavior and standard
  or high-definition preview selection apply to content media. The decoded-image
  cache is memory-only and can be explicitly evicted.

### Accounts and boundaries

- **Login and storage:** Login uses a nonpersistent, HTTPS-only Baidu Web view
  with an exact host allowlist. Validated account records are stored in the
  device-only Keychain and can be switched or removed locally.
- **Forum account state:** The active account can load its paginated
  followed-forum list. A loaded forum independently reads authoritative
  account-specific follow and check-in state, exposes confirmed follow/unfollow,
  and offers an explicit single-forum check-in action when eligible.
- **Credential boundary:** Anonymous and authenticated requests use isolated,
  ephemeral clients. BDUSS is the only credential stored by the vault. STOKEN is
  not extracted, and the 26-character `tbs` value is validated, made available
  to at most the immediately following write, and never returned to the app
  model or persisted.
- **Write safety:** Each write is bound to the expected account UID and forum.
  Follow and check-in operations for the same forum cannot overlap, identical
  concurrent operations are coalesced, and a conflicting call waits for the
  active write to settle before requesting a read-only reconciliation. It is
  never queued as a second write. The App starts and applies reconciliation only
  while the initiating account lease remains readable and current; a later
  account change discards its result. No uncertain failure retries a write.
  Already-completed check-in is idempotent, and following, unfollowing, and
  check-in all require explicit user confirmation. Automatic and batch check-in
  are not implemented.
- **Unsupported operations:** Server-side thread favorites remain blocked on
  safely acquiring and binding the required STOKEN. Thread approval (like) is
  the next account-write candidate; posts, replies, notifications, and
  moderation remain unavailable until their request contracts and recovery
  paths have been validated on a disposable account.
- **Detailed parity:** See [`ROADMAP.md`](ROADMAP.md) for the complete TiebaLite
  comparison, protocol constraints, and next milestones. The current weighted
  end-to-end audit estimates 85–95% coverage of anonymous reading and media, or
  52–57% of the full TiebaLite product scope once the remaining account writes,
  creation, notifications, and moderation are included.

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
The account vault persists BDUSS only. It does not extract or store STOKEN or
the short-lived anti-CSRF value made available to at most one confirmed forum
write.

## Build

Install Xcode 16.4 or newer and XcodeGen 2.45.4 or newer, then run:

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

The distribution target is SideStore-compatible self-signing. The public
[`sidestore-source.json`](https://raw.githubusercontent.com/Minaduki-Shigure/tieba-plus-plus-swift/main/sidestore-source.json)
can be added directly to LiveContainer or SideStore. Each listed IPA is an
unsigned GitHub Release asset that must be signed by the installer; its byte size
and SHA-256 are checked against the source by CI. App Store distribution is not
currently a project goal.

## License

GPL-3.0-only. See `LICENSE`.
