# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the minimal attributed protobuf schemas used for interoperability are documented
in `Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Tieba++ is an alpha-stage, native SwiftUI client. Anonymous browsing is the
current stable focus; account writes remain experimental and require device
validation. The table below describes the current `main` source; main-only
features do not reach the public app source until a tagged IPA passes release
checks.

| Area | Current state |
| --- | --- |
| Anonymous browsing | Available across personalized discovery, rankings, search, forums, threads, replies, profiles, and media |
| Local features | Available for history, favorites, filtering, appearance, and media preferences |
| Accounts | Current `main` supports bound Web login, switching, logout, followed forums, a default-off followed-forum recommendation filter, a foreground concern feed and ReplyMe/AtMe inbox, Tieba cloud favorites, per-forum state, and experimental content approval |
| Server-side writes | Guarded forum follow/unfollow, check-in, content approval, thread-detail cloud-favorite changes, and plain-text topic/floor/nested replies are in device validation; other writes stay disabled |
| TiebaLite parity | Anonymous reading and media: about 90–95%; full product scope: about 67–71% |
| Distribution | The public SideStore/LiveContainer source currently serves `v0.59.0-alpha.1` (build 62); later `main` features require a tagged release |

### Release and validation

- **Current alpha:** `v0.59.0-alpha.1` adds a foreground, account-bound inbox for
  replies and mentions. It uses an HTTPS Protobuf ReplyMe request and a minimal
  signed HTTPS AtMe form, paginates in memory, and discards responses when the
  active account lease changes.
- **Current main source:** Explore now opens on a credential-free personalized
  thread feed beside the existing hot ranking. A logged-in account additionally
  receives an on-demand concern channel; it makes no request until selected,
  keeps the server snapshot timestamp in memory per exact account session, and
  rejects stale pages after logout, account switching, or credential rotation.
  Both feeds preserve local filtering and media preferences. Public profiles
  also expose separate reply history plus read-only following and follower lists;
  the account page links the active UID to that same credential-free public view.
  A logged-in home page also shows at most six forums from the current account's
  followed-forum list and links to the complete paginated list. Both surfaces
  share one app-scoped, memory-only snapshot that is discarded when the account
  session or a forum relationship changes. A default-off setting can reuse a
  verified-complete snapshot to show personalized recommendations only from the
  active account's followed forums. This filtering is local: the anonymous
  recommendation request receives no account, credential, lease, or forum ID.
  Multi-image galleries can switch between horizontal and vertical one-image
  paging while retaining a stable selected occurrence and bounded zoom state. A
  logged-in thread can also read its account-bound Tieba cloud-favorite state and,
  after explicit confirmation, add it at the last visible floor, update the saved
  floor, or remove it. Every mutation is followed by a read-only reconciliation;
  an uncertain write is never retried. Logged-in thread and full nested-reply
  pages also expose experimental, draft-backed plain-text composers for replying
  to the topic, an ordinary floor, or a specific nested reply. The write is sent
  at most once, a valid server PID is read back by exact identity, and challenge,
  accepted-but-not-yet-visible, and unknown outcomes remain distinct.
  These main-only changes will not enter the public app source until a tagged
  IPA passes the release checks.
- **Compatibility:** The deployment target is iOS 16. Builds use Xcode 16.4 and
  XcodeGen 2.45.4 or newer.
- **Automated checks:** GitHub Actions runs package tests and an unsigned
  simulator build, validates the app source, and verifies its public IPA hash.
  Authenticated flows never use real credentials in CI. Login binding, cloud
  favorite reads and mutations, followed-forum recommendation filtering,
  concern-feed, inbox, and plain-text reply contracts are covered by fixtures,
  while successful private reads and forum follow/unfollow, check-in,
  cloud-favorite changes, topic/post/subpost content approval, and real reply
  creation remain physical-device validation features in this alpha.
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

- **Discovery:** On current `main`, a pageable anonymous personalized feed, an
  explicitly selected account-bound concern feed, post rankings, hot-topic
  previews, category snapshots, topic details, related forums, and cursor-aware
  topic pagination are available. The personalized feed has a default-off
  setting that locally retains only threads whose stable forum ID occurs in the
  active account's complete followed-forum index. The personalized and concern
  feeds are not in the public `v0.59.0-alpha.1` IPA. Recommendation dislike
  feedback remains disabled.
- **Search:** Forum, thread, and user search are separated by category. Global
  and per-forum post search provide the supported sort and content filters,
  local history, and optional credential-free suggestions.
- **Forum browsing:** Forum and channel lists support pagination, refresh,
  reply-time or creation-time sorting, server-defined classifications, and
  bounded channel menus with independent cursors.
- **Public information:** Forum introductions, statistics, rules, moderator
  teams, and credential-free user profiles are available. Profiles include
  independently paginated public topics, replies, following, and followers;
  public liked-forum data is presented only as a bounded preview. Relationship
  lists are read-only public endpoint snapshots, not proof of the active
  account's relationship with any listed user.

### Threads and media

- **Thread reading:** Ascending, descending, and hot order, only-author mode,
  page jumps, anchored opening, earlier-page loading, first-floor context, and
  explicit latest-reply checks are implemented with cursor validation.
- **Replies and metadata:** Floors, nested replies, parent context, polls,
  shared-thread origins, author levels, moderator roles, IP locations, and
  approval scores are preserved where returned by the server. A logged-in
  account can explicitly approve or cancel approval on the canonical topic,
  ordinary floors, and individual replies on the full nested-reply page. Inline
  nested-reply previews remain read only.
- **Images:** Responsive image groups open in a zoomable gallery with horizontal
  or vertical one-image paging. Switching direction retains the current image
  and its bounded in-memory zoom state while the occurrence ID remains stable.
  Ordinary unfiltered threads can expand the gallery across floors; originals
  can be explicitly shared or saved through add-only Photos access.
- **Playback:** Voice and native AVKit video share one application-wide playback
  coordinator. Starting new media pauses the prior item, inactive scenes pause
  playback, and playback never resumes implicitly. Voice files can be explicitly
  downloaded, validated, and passed to the system share sheet; Picture in Picture
  is off.
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
  without modifying network pagination. A separate default-off recommendation
  filter matches the active account's followed forums by stable forum ID.
- **Appearance:** System, light, and dark themes, a bounded accent palette,
  Dynamic Type-relative text sizing, compact previews, and optional combined
  nickname/username presentation are persistent local controls.
- **Media policy:** Automatic, data-saving, or tap-to-load behavior and standard
  or high-definition preview selection apply to content media. The decoded-image
  cache is memory-only and can be explicitly evicted.

### Accounts and boundaries

- **Login and storage:** Login uses a nonpersistent, HTTPS-only Baidu Web view
  with an exact host allowlist. A new login captures BDUSS and STOKEN from one
  Cookie-store snapshot, requires independent app and Web probes to return the
  same UID, and stores the same-snapshot pair in the device-only Keychain.
  Whether both probes reject a wrong STOKEN still requires disposable-account
  negative testing; STOKEN-dependent writes remain validation-build features.
  Existing v1/v2
  records migrate without STOKEN and retain their current BDUSS features; they
  must be logged in again before an STOKEN-dependent feature is available.
- **Forum account state:** On current `main`, the logged-in home page projects at
  most six entries from the active account's followed-forum list and can open the
  complete paginated list. A selected, default-off recommendation filter is a
  third consumer of the same app-scoped, memory-only state. It publishes an
  allowlist only after the server explicitly ends pagination; partial, stalled,
  invalid, over-limit, signed-out, and failed results remain unavailable. Each
  page checks the exact `userID + sessionRevision` lease before and after its
  request; account or forum-membership changes clear the snapshot. New list
  requests begin only while the home page, complete list, or selected filtered
  recommendation page is active. These surfaces perform no automatic write,
  retain nothing across accounts or app restarts, and currently provide no
  pinning, unfollow, or batch check-in controls. A loaded forum
  separately reads account-specific follow and check-in state and retains its
  explicitly confirmed single-forum actions. Successful private-list retrieval
  still requires physical-device validation and is not asserted by CI fixtures.
- **Current-account public profile:** The account page can open the active UID in
  the same credential-free public profile used elsewhere, including public
  topics, replies, following, and followers. This is a navigation shortcut, not
  private account history, and it adds no authenticated profile request.
- **Content approval state:** The canonical first floor, ordinary floors, and
  parent and child rows on a full nested-reply page independently read the active
  account's approval state and expose confirmed approve/cancel actions. Anonymous
  content and inline nested-reply previews remain separate read-only snapshots.
- **Private inbox:** The account page opens foreground-only ReplyMe and AtMe
  lists with refresh and bounded page-number pagination. Ordinary notifications
  can reopen the exact post. A nested-reply notification sends only its child ID
  to the public floor resolver, validates the returned thread, parent, and child,
  and opens the exact reply without trusting the ambiguous legacy `quote_pid`
  field. No background polling, badge clearing, or explicit mark-read request is
  implemented.
- **Concern feed:** Logged-in Explore adds a foreground-only concern channel.
  Page-style preloading cannot start it: the request begins only after the user
  selects the channel. Refresh replaces the snapshot; load-more preserves the
  same opaque server timestamp and cursor, and all retained state is bound to
  `userID + sessionRevision` in memory. The request uses a separate process-local
  random UUID and no hardware-derived identifier. Successful retrieval and the
  exact minimum signed-field set still require physical-device validation.
- **Tieba cloud favorites:** The account page has a separate, read-only cloud
  favorites list with refresh, offset pagination, saved-post navigation, deleted
  thread state, and account-lease isolation. A logged-in thread separately reads
  its exact cloud state and offers explicitly confirmed add, saved-floor update,
  and removal controls. These operations never upload, merge, or delete the
  independent local favorites archive. Successful authenticated reads and writes
  over the minimal HTTPS contracts still require disposable-account device
  validation.
- **Plain-text replies:** Current `main` can reply to a topic, an ordinary floor,
  or a specific nested reply, including one under the canonical first floor,
  from native, draft-backed composers. Replying to the first-floor parent itself
  remains a topic reply rather than an ordinary-floor reply. Targets are rebuilt
  only from validated page models and rebound by an authenticated PB
  Page/Floor read before the single write. Drafts are isolated by account and
  exact target and protected on disk. A non-resendable pending marker must be
  persisted before the network write; challenge, accepted-but-not-visible, and
  unknown outcomes remain blocked so reopening a composer cannot silently resend
  them. A challenge remains blocked for the same `sessionRevision`; only an
  explicit new login can start a fresh attempt. The request deliberately omits
  Android device fingerprints and therefore remains a disposable-account
  validation feature.
- **Credential boundary:** Anonymous and authenticated requests use isolated,
  ephemeral clients. The vault stores only the same-snapshot BDUSS/STOKEN pair
  accepted by the UID-consistency probes and its actual BDUSS Cookie name;
  neither value enters summaries, client-owned logs, App-visible errors, or
  mirrors. The 26-character `tbs` value is validated, made available to at most
  the immediately following write, and never returned to the app model or
  persisted. Content approval's mandatory `cuid` is a random
  client-lifetime Galaxy2 identifier (`32HEX|V` plus an 8-character Helios
  checksum); it is not hardware-derived or persisted. Personalized discovery
  separately uses one nonsecret random UUID stored in local preferences. The
  authenticated concern feed uses a different random UUID that lasts only for
  the current process. Neither value is derived from hardware, IDFV, an account,
  or a credential, and the two feeds never share an identifier.
- **Write safety:** Each write is bound to the expected account UID and forum.
  Follow and check-in operations for the same forum cannot overlap, identical
  concurrent forum operations are coalesced, and both Core and the account
  service coalesce the same account, complete content target, and requested
  approval or cloud-favorite state. A conflicting call waits for the active
  write to settle before requesting read-only reconciliation; it is never queued
  as a second write. The
  App starts and applies reconciliation only while the initiating account lease
  remains readable and current; a later account change discards its result. No
  uncertain failure retries a write. Reply submissions additionally serialize
  per account, share only an identical submission UUID, and permit cancellation
  to stop the owner only before write dispatch. Once dispatched, the owner
  finishes receipt parsing and exact-ID readback even if its view disappears.
  Already-completed check-in and matching content state are idempotent. All
  supported writes require explicit user confirmation. Automatic and batch
  check-in are not implemented.
- **Unsupported operations:** Direct deletion from the cloud-favorites list,
  bulk cloud/local synchronization, disagreement and other reaction types,
  new-thread creation, rich-media replies, notification replies, background
  notification polling, and moderation remain unavailable until their request
  contracts and recovery paths have been validated on a disposable account.
- **Detailed parity:** See [`ROADMAP.md`](ROADMAP.md) for the complete TiebaLite
  comparison, auditable weighting, protocol constraints, and next milestones.
  The current `main` audit totals 67–71 of 100 weighted points; its anonymous
  reading and media subtotal is about 90–95%. The largest remaining gaps are
  new-thread and rich-media creation, background unread handling, broader
  settings, remaining cloud-favorite list actions, and moderation.

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
The account vault persists the same-snapshot BDUSS/STOKEN pair accepted by the
UID-consistency probes for new logins. It does not persist the short-lived
anti-CSRF value made available to at most one confirmed account write.

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
