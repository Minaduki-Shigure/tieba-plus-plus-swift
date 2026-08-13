# Tieba++ for iOS

An independent, native SwiftUI client for browsing Baidu Tieba. The application
code and assets are implemented independently from public protocol research;
the attributed protobuf schemas and fixed classic-emoticon wire-name catalog
used for interoperability are documented in
`Packages/TiebaCore/Sources/TiebaProto/NOTICE.md`.

## Status

Tieba++ is an alpha-stage, native SwiftUI client. Anonymous browsing is the
current stable focus; account writes remain experimental and require device
validation. The table below describes the current `main` source; main-only
features do not reach the public app source until a tagged IPA passes release
checks.

| Area | Current state |
| --- | --- |
| Anonymous browsing | Available across personalized discovery, rankings, search, forums, threads, replies, profiles, and media |
| Local features | Available for history, favorites, filtering, appearance, media preferences, account-isolated followed-forum pinning and layout, a configurable forum primary action, reply-entry visibility, a default-on posting/reply risk notice, a shared selectable-text panel for visible floors and nested replies, and a next-launch destination including the inbox |
| Accounts | Current `main` supports bound Web login, switching, logout, an account-bound self-profile summary, followed forums, login-gated complete liked-forum lists for the current or another user, target-bound user relationship and interaction-restriction reads, a default-off followed-forum recommendation filter, a foreground concern feed and ReplyMe/AtMe inbox with separate message and optional fan-reminder badges plus authoritative reply actions, Tieba cloud favorites, per-forum state, explicitly confirmed foreground one-click check-in, authenticated poll state, and experimental content approval |
| Server-side writes | Guarded forum and user follow/unfollow, user interaction restrictions, single-forum and foreground batch check-in, poll voting, content approval, thread-detail and verified list-level cloud-favorite changes, text plus fixed-catalog classic-emoticon topic/floor/nested replies, and equivalent new-topic creation are in device validation. Visible topics, floors, and nested replies can also open Tieba's official report form through SafariServices without exporting App credentials; other writes stay disabled |
| TiebaLite parity | Current `main` source: about 80% of full product scope (estimated range 78–81%, with 19–22% remaining); anonymous reading and media: about 91–95%. The public `v0.59.0-alpha.1` IPA remains about 57–62% |
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
  their bounded public liked-forum preview now links to an independently paginated,
  login-gated complete list for either the current or another user. That list is
  bound to the active account session and target UID and never enters the global
  current-account followed-forum index. The account page reads a bounded,
  memory-only self-profile summary for the exact authenticated session and links
  it to the existing credential-free public profile. It shows the current avatar,
  display name, biography, following, follower, and reply counts; a refresh checks
  the `userID + sessionRevision` lease before and after transport.
  Another user's profile can now read whether the exact active account follows
  that target and, after explicit confirmation, follow or unfollow them. A fresh
  authenticated profile probe binds the account UID, target UID, portrait,
  relationship value, and short-lived `tbs`; the write is sent at most once and
  its target-less acknowledgement never becomes relationship truth. One
  mandatory authenticated readback supplies the final state, including mutual-
  follow value `2`; cancellation or account rotation cannot publish a late
  result. This minimum-field HTTPS contract remains a disposable-account
  validation gate.
  The same profile menu now keeps local content filtering separate from a lazy,
  account-bound server interaction-permission editor. For another user, it can
  read and explicitly update whether that user may follow, interact with, or
  privately message the active account. The read is first bound by the existing
  authenticated profile probe. A changed state uses a fresh `tbs`, sends one
  minimum-field HTTPS write at most, and always performs one raw permission
  readback; an uncertain result is locked until an explicit reload. Follow and
  interaction-permission writes for the same account and target cannot overlap.
  Real-server field compatibility remains a disposable-account validation gate.
  A logged-in home page also shows at most six forums from the current account's
  followed-forum list and links to the complete paginated list. Both surfaces
  share one app-scoped, memory-only snapshot that is discarded when the account
  session or a forum relationship changes. Their cards preserve the bounded
  server-supplied forum avatar and slogan; unavailable or disallowed images fall
  back locally without another metadata request. An account-isolated local archive
  can pin exact, already loaded forums on both surfaces; pinned rows move to the
  front without loading another page, and the same context menu can unpin or copy
  the public forum name. A default-off setting can reuse
  a verified-complete snapshot to show personalized recommendations only from
  the active account's followed forums. This filtering is local: the anonymous
  recommendation request receives no account, credential, lease, or forum ID.
  The account page now also offers a foreground-only one-click check-in after it
  loads the authoritative forum catalog and the user explicitly confirms the
  displayed target snapshot. Immediately before dispatch, the official batch
  path refreshes the catalog and signs only the intersection of that fresh
  eligible set and the confirmed snapshot; a newly eligible, unconfirmed forum
  is never added. Forums rejected by the batch response or no longer present in
  the dispatch set do not fall back to individual writes. If the batch response
  is lost or cannot be proved complete, the App performs read-only per-forum
  reconciliation for the exact dispatched targets and marks unresolved results
  for review without retrying or sending individual check-ins. There is no
  background or automatic check-in, and real-account behavior remains a
  physical-device validation gate.
  Multi-image galleries can switch between horizontal and vertical one-image
  paging while retaining a stable selected occurrence and bounded zoom state. A
  server-provided dynamic-image candidate now remains separate from static and
  original sources. ImageIO-confirmed multi-frame GIF, WebP, and HEIC/HEIF
  sequences use bounded frame decoding in previews and the gallery; single-frame,
  unsupported, oversized, or malformed sequences remain readable as static
  posters. Only the current gallery page animates, and playback stops while the
  scene or view is inactive or Reduce Motion is enabled.
  Validated HTTPS image bytes fetched without account Cookie or Authorization
  headers now use a bounded persistent cache
  shared by previews, galleries, sharing, and Photos export. Exact request URLs
  are represented only by SHA-256 keys; metadata contains no URL, response header,
  MIME type, filename, cookie, or account data. Settings reports its logical size
  and clears it together with decoded memory and animation-frame caches.
  A logged-in thread can also read its account-bound Tieba cloud-favorite state and,
  after explicit confirmation, add it at the last visible floor, update the saved
  floor, or remove it. A visible floor's context menu can perform the same exact
  add, move, or remove action, and the server-confirmed saved floor carries a
  dedicated marker. Loading, failed, filtered, and pure-reading floor surfaces
  never expose a mutation action. Every mutation is followed by a read-only reconciliation;
  an uncertain write is never retried. The cloud-favorites list can also remove
  one item after a separate destructive confirmation. It first resolves the raw
  anonymous PB thread/forum identity, then requires the existing authenticated
  UID/forum/thread preflight before the single write; an unresolvable deleted
  item sends no write. Logged-in thread and full nested-reply
  pages also expose experimental, draft-backed composers for replying to the
  topic, an ordinary floor, or a specific nested reply. A visible inline
  nested-reply preview can open the same exact-target composer without first
  opening the full reply page. The body supports ordinary text plus a fixed,
  bundled catalog of 50 classic Tieba emoticon tokens selected at the current
  text selection; it does not download or bundle remote emoticon artwork. The write is sent
  at most once, a valid server PID is read back by exact identity, and challenge,
  accepted-but-not-yet-visible, and unknown outcomes remain distinct. Inbox reply
  actions first relocate the exact ordinary post or child reply and recheck the
  active account lease before opening that same composer. The notification's
  legacy `quote_pid` and display payload never become a write target; failed
  relocation or a changed session opens no composer and dispatches no write.
  A loaded forum now also exposes an experimental native composer for a new
  text-and-classic-emoticon topic with an optional title. It binds the active account, exact
  forum ID and canonical forum name through a fresh FRS preflight, persists the
  account-scoped draft before dispatch, sends one signed HTTPS write at most,
  and verifies the returned topic and first-floor IDs by authenticated readback.
  Challenge, accepted-but-not-yet-visible, and unknown outcomes lock and retain
  the draft; an untitled topic may accept a server-generated display title, but
  an explicit title, author, forum, first floor, and body must match exactly.
  Confirmed creation retains a bounded local receipt marker across restart so a
  crash cannot silently reopen the old body for resubmission; the next composer
  requires an explicit “开始新主题” action before clearing that marker.
  Poll result cards remain credential-free and read only. A logged-in thread can
  separately read authoritative poll state from an authenticated PB response,
  including the real option IDs and the account's selected IDs. Only an open,
  unvoted poll with a legal selection exposes the explicitly confirmed vote
  action. The complete account credential sends one minimum-field HTTPS PB write
  for command `309006` at most; hardware and installation identifiers are omitted.
  Identical selections for the same account and thread share one flight, while a
  different selection or credential waits and then performs only a read. Every
  dispatched write is followed by one authoritative authenticated readback, and
  an uncertain outcome is never retried. The App accepts the result only while
  the initiating `userID + sessionRevision` lease remains current. Real-account
  success and failure behavior remains a disposable-account device-validation gate.
  The account page also reads Tieba's reply, mention, and optional fan-reminder
  summary on demand. Reply plus mention remains the message badge; a separate
  fan-reminder entry shows the server count only when that field is present and
  opens the existing credential-free public follower list. This summary is
  memory-only, bound to the exact account lease, refreshed when the account page
  returns, and never cleared locally when either entry opens.
  Visible topic and floor text, inline nested-reply previews, and parent and
  child rows on a full nested-reply page now open one shared transient selection
  panel from their context menus. It reuses the existing public-text projection,
  supports partial system selection and an explicit copy-all action, and presents
  or dismisses without a network request, account read, persistent write, or
  implicit pasteboard write.
  The same visible topic, floor, inline nested-reply, parent-floor, and full
  nested-reply surfaces now expose a login-gated route to Tieba's official
  report form. A credential-free, two-field HTTPS preflight resolves the exact
  post ID; the returned route is accepted only after exact host, path, query,
  and target binding and is rebuilt as HTTPS. The form opens in
  `SFSafariViewController`: the App never injects its Keychain BDUSS/STOKEN,
  cannot observe submission, and cannot prove that the browser's Baidu account
  matches the active App account. The user must verify or complete browser login.
  These main-only changes will not enter the public app source until a tagged
  IPA passes the release checks.
- **Compatibility:** The deployment target is iOS 16. Builds use Xcode 16.4 and
  XcodeGen 2.45.4 or newer.
- **Automated checks:** GitHub Actions runs package tests and the complete iOS
  simulator test target, validates the app source, tests its release-metadata
  updater, and verifies its public IPA hash.
  Authenticated flows never use real credentials in CI. Login binding, cloud
  favorite reads and mutations, including floor-level marker/action admission,
  stale-confirmation rejection and verified list deletion, followed-forum recommendation filtering,
  target-bound liked-forum pagination, the minimal self-profile request and its
  UID/session-lease race handling, target-bound interaction permissions,
  concern-feed, inbox summary, inbox
  navigation and reply-action rebinding, single-forum and foreground batch
  check-in safety contracts, text/classic-emoticon reply contracts, and equivalent
  new-topic and account-bound poll-vote contracts are
  covered by fixtures, while successful real-account self-profile and private
  reads, forum
  follow/unfollow, check-in, cloud-favorite changes, topic/post/subpost content
  approval, poll voting, user follow/unfollow, user interaction restrictions,
  real reply creation, and real new-topic creation remain
  physical-device validation features in the current `main` source.
- **App source:** Add [`sidestore-source.json`](https://raw.githubusercontent.com/Minaduki-Shigure/tieba-plus-plus-swift/main/sidestore-source.json)
  to LiveContainer 3.7.0 or newer, or to SideStore. Its latest IPA is published
  only after the tag's package, anonymous integration, and simulator tests all
  pass. After the release asset is published and reverified, the release workflow
  derives its date, download URL, byte size, and SHA-256 and updates the source
  atomically; version or concurrent-source mismatches fail closed. The source
  currently distributes `v0.59.0-alpha.1`; the newer `main`
  features described above, including foreground one-click check-in, are not in
  that IPA yet.
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
  bounded channel menus with independent cursors. The forum toolbar's primary
  action can be set locally to publish, refresh, return to top, or hidden; the
  complete refresh, return-to-top, share, and available publish actions remain
  reachable from the More menu. A loaded forum offers an
  experimental, account-bound text-and-classic-emoticon new-topic composer with an optional
  title, persistent per-account draft, explicit publish confirmation, and no
  automatic retry; a signed-out composer remains read only and asks for login.
- **Public information:** Forum introductions, statistics, rules, moderator
  teams, and credential-free user profiles are available. Profiles include
  independently paginated public topics, replies, following, and followers.
  Public liked-forum data remains a bounded preview; a separate complete list is
  available only through an active account session and still performs no write.
  Relationship lists are read-only public endpoint snapshots, not proof of the
  active account's relationship with any listed user.

### Threads and media

- **Thread reading:** Ascending, descending, and hot order, only-author mode,
  page jumps, anchored opening, earlier-page loading, first-floor context, and
  explicit latest-reply checks are implemented with cursor validation. For a
  logged-in account with an authoritative cloud-favorite snapshot, a visible
  floor's context menu can save, move, or remove the exact cloud marker after a
  separate confirmation; the exact saved PID is marked in the floor content.
- **Replies and metadata:** Floors, nested replies, parent context, read-only
  anonymous poll results,
  shared-thread origins, author levels, moderator roles, IP locations, and
  approval scores are preserved where returned by the server. A logged-in
  account can separately read authoritative poll state and submit one legal
  selection after explicit confirmation; it can also explicitly approve or
  cancel approval on the canonical topic,
  ordinary floors, and individual replies on the full nested-reply page. Inline
  nested-reply previews remain read only.
- **Images:** Responsive image groups open in a zoomable gallery with horizontal
  or vertical one-image paging. Switching direction retains the current image
  and its bounded in-memory zoom state while the occurrence ID remains stable.
  After a one-finger drag passes the system movement threshold, the gallery
  assigns that complete gesture to either image panning or the native pager from
  the native pan recognizer's dominant axis and direction plus the current pan
  boundary. A drag that starts inside the image remains an image pan even if it
  reaches the boundary; the next outward drag pages, while an inward drag
  continues panning. Two-finger gestures never page, and the rule is symmetric
  in horizontal and vertical paging modes. XCTest covers the ownership policy
  and recognizer hierarchy; continuous touch competition remains a device test
  gate for the next IPA.
  Within the same gallery context, an explicit one-to-one occurrence migration
  also carries scale and clamped offset when whole-thread metadata first replaces
  a local placeholder with the currently unique `(pictureID, postID)` remote
  occurrence; ambiguous initial matches are never guessed. Ordinary unfiltered
  threads can expand the gallery across floors; originals can be explicitly
  shared or saved through add-only Photos access.
  Server dynamic-image URLs are retained as independent fallbacks rather than
  animation flags. The downloaded file must identify as a real multi-frame GIF,
  WebP, or HEIC/HEIF sequence before it animates. Metadata is capped at 500 frames;
  frames downscale to a 16 MiB decoded bound and enter one shared cache capped
  at 64 MiB and 1,000 entries.
  Unsupported or over-limit data falls back to a poster. Animated thumbnails pause
  after their SwiftUI surface leaves presentation or the scene becomes inactive;
  gallery neighbors and Reduce Motion always show the poster.
- **Playback:** Voice and native AVKit video share one application-wide playback
  coordinator. Starting new media pauses the prior item, inactive scenes pause
  playback, and playback never resumes implicitly. Voice files can be explicitly
  downloaded, validated, and passed to the system share sheet; Picture in Picture
  is off. If a server video fragment has no stream accepted by the HTTPS playback
  policy, a bounded credential-free HTTP(S) landing page can be opened only by
  an explicit tap. A valid stream remains primary and playback failure never
  redirects automatically.
- **Links and sharing:** Supported Tieba links stay in the native router with
  post and reply context. External HTTPS links use the selected system or Safari
  presentation, while forum and thread sharing emits canonical HTTPS links.
- **Text selection and copying:** Context-menu copy actions for a visible topic
  or ordinary floor, an inline nested-reply preview, and the parent or child row
  of a full nested-reply page open one shared local panel. Its projected text is
  scrollable and selectable; the user can copy a system-selected range or
  explicitly copy all. Dismissing the panel writes nothing, while short-value
  actions such as copying a link, user ID, or forum name retain their direct
  system behavior.

### Local data and controls

- **History:** Versioned browsing and search history support restoration,
  individual deletion, clearing, no-history mode, and corruption recovery.
  Recent forums are projected from the same browsing archive.
- **Favorites:** Forums and threads use a separate local archive. Saved forums
  can be pinned as home shortcuts; saved threads retain position and browse mode
  and can apply explicit only-author or descending overrides.
- **Filtering:** Local literal-keyword, exact user block/allow, and video-topic
  filters cover list, profile, floor, nested-reply, shared-origin, and foreground
  inbox surfaces without discarding their raw server pagination. A separate
  default-off recommendation filter matches the active account's followed forums
  by stable forum ID.
- **Appearance:** System, light, and dark themes, five tested accent presets,
  one locally stored opaque custom accent, Dynamic Type-relative text sizing,
  compact previews, and optional combined
  nickname/username presentation are persistent local controls. Followed-forum
  cards can use an adaptive grid or a single column; accessibility text sizes
  always use one column so labels can expand without overlap.
- **Followed-forum pins:** The logged-in home projection and complete followed-
  forum list share account-isolated local pin ordering. Only an exact forum ID and
  normalized name already present in the authoritative loaded snapshot can move;
  stale or not-yet-loaded pins create no row and cause no pagination. Context
  menus pin, unpin, or copy the public forum name, and confirmed unfollow cleans
  only the matching account's pin.
- **Reply controls:** A default-off local preference can hide topic, floor,
  nested-reply, and inbox quick-reply entry points without hiding reply content,
  read-only navigation, agreement controls, existing drafts, or an already-open
  composer. A separate default-on local notice pauses an editable reply or
  new-topic composer after its draft is restored and lets the user continue or
  return without deleting that draft. It is advisory only: disabling or
  acknowledging it never replaces the separate confirmation of the exact reply
  or topic snapshot immediately before submission.
- **About:** A local About page reads the installed bundle's display name,
  version, and build number. Its explicit source-code action opens only the fixed
  project repository URL through the selected system-browser or in-app Safari
  policy; the destination is not derived from account or remote data.
- **Media policy:** Automatic, data-saving, or tap-to-load behavior and standard
  or high-definition preview selection apply to content media. Animation uses
  the same URL authorization and transfer limits as static images. Decoded images
  and animation frames remain memory-only. Validated image bytes fetched without
  account Cookie or Authorization headers can also
  enter a 256 MiB, 1,024-entry, seven-day disk cache; preview and original reads
  retain their separate 16 MiB and 80 MiB limits. Tap-to-load and data-saving
  cache checks can reuse exact-URL disk entries without starting or joining a
  network request. The settings screen reports and explicitly clears both layers.

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
  complete paginated list. The home projection and complete list share a
  persistent adaptive-grid or single-column layout preference, with an explicit
  switch on the complete list. Layout changes are local and do not reload the
  account snapshot. A selected, default-off recommendation filter is a
  third consumer of the same app-scoped, memory-only state. It publishes an
  allowlist only after the server explicitly ends pagination; partial, stalled,
  invalid, over-limit, signed-out, and failed results remain unavailable. Each
  page checks the exact `userID + sessionRevision` lease before and after its
  request; account or forum-membership changes clear the snapshot. New list
  requests begin only while the home page, complete list, or selected filtered
  recommendation page is active. The private server snapshot remains memory-only
  and performs no automatic account write. A separate versioned local archive
  retains pins across launches and isolates them by positive account UID; it only
  reorders exact rows already present in that snapshot and never loads another
  page. The lists provide no inline server unfollow or check-in control. A loaded forum separately reads
  account-specific follow and check-in state and retains its explicitly
  confirmed single-forum actions. The account page provides the distinct,
  foreground-only one-click flow described below. Successful private-list
  retrieval still requires physical-device validation and is not asserted by CI
  fixtures.
- **Current-account profile:** The account page reads a bounded, account-lease-
  bound authenticated summary containing identity, biography, relation counts,
  and reply count. Selecting it opens the same credential-free public profile
  used elsewhere for public topics, replies, following, and followers. The
  destination remains a navigation shortcut and does not expose private account
  history.
- **User liked forums:** A public profile keeps its bounded credential-free
  preview and offers a separate complete list for the current or another user
  when account access is available. The request is read only and paginated; each
  page is bound to the active account UID, session revision, target UID, and page
  number before and after transport. Its memory-only state is independent from
  the global current-account followed-forum snapshot, so viewing another user
  cannot affect home shortcuts or recommendation filtering. Successful self and
  other-user retrieval, privacy-empty results, expired credentials, and account
  switching still require physical-device validation.
- **User interaction restrictions:** Another user's profile keeps the existing
  local block/allow actions separate from a server-side editor available only to
  a complete active account session. The editor loads lazily and exposes the
  three Tieba permission bits for following, interaction (reposts, comments,
  reactions, and mentions), and private messages. It binds the target through an
  authenticated profile probe, requires explicit save confirmation, sends one
  changed-state write at most, and accepts only the mandatory permission
  readback. Its state is memory-only and bound to `userID + sessionRevision`;
  account changes synchronously invalidate and close it. Unknown write outcomes
  disable further saves until an explicit authoritative reload. This remains a
  disposable-account validation feature.
- **Content approval state:** The canonical first floor, ordinary floors, and
  parent and child rows on a full nested-reply page independently read the active
  account's approval state and expose confirmed approve/cancel actions. Anonymous
  content and inline nested-reply previews remain separate read-only snapshots.
- **Private inbox:** The account page opens foreground-only ReplyMe and AtMe
  lists with refresh and bounded page-number pagination. Ordinary notifications
  can reopen the exact post. A visible sender avatar or name separately opens
  that sender's credential-free public profile when the notification carries a
  strict positive UID; the message body retains its original post/reply target.
  A nested-reply notification sends only its child ID
  to the public floor resolver, validates the returned thread, parent, and child,
  and opens the exact reply without trusting the ambiguous legacy `quote_pid`
  field. Each supported row also exposes an explicit reply action bound to the
  current `userID + sessionRevision`. It reopens that ordinary post or resolves
  that child, requires the authoritative model to match the notification's stable
  thread, post, and sender IDs, and only then opens the existing composer. The
  message title, body, forum label, and `quote_pid` never participate in the write
  target. A missing or mismatched target, cancellation, or account change leaves
  the fallback navigation available but opens no composer and sends no write. No
  background polling or explicit mark-read request is implemented. The local
  inbox filter checks only `message.content` plus the sender's exact UID,
  nickname, and username; the title, quoted content, forum label, and other
  fields do not participate. A placeholder exposes no message-specific content,
  navigation, or reply action, and a hidden message exposes no row. The original
  ordered messages and page state remain in memory. A rule change reprojects only
  those loaded messages, makes no repeat inbox request, and pauses automatic
  pagination until the user explicitly continues. If the rule archive cannot be
  reread, the inbox retains its last successfully loaded snapshot; before the
  first successful read it uses an empty snapshot. This is a presentation
  preference, not a confidentiality or access-control boundary. The account page
  separately requests an unfiltered foreground unread summary and shows the sum of
  `replyme + atme` beside the message entry. The optional `fans` field remains
  separate: when present, it drives a distinct fan-reminder entry that opens the
  existing credential-free public follower list; when absent, the App does not
  infer zero. Zero counts hide their badges and larger counts are capped visually
  while accessibility retains the exact value. Neither entry clears a count
  locally when opened, and the whole snapshot is discarded on logout, account
  switching, or same-UID credential rotation. No local baseline is used to infer
  new or lost followers.
- **Concern feed:** Logged-in Explore adds a foreground-only concern channel.
  Page-style preloading cannot start it: the request begins only after the user
  selects the channel. Refresh replaces the snapshot; load-more preserves the
  same opaque server timestamp and cursor, and all retained state is bound to
  `userID + sessionRevision` in memory. The request uses a separate process-local
  random UUID and no hardware-derived identifier. Successful retrieval and the
  exact minimum signed-field set still require physical-device validation.
- **Tieba cloud favorites:** The account page has a separate cloud favorites list
  with refresh, offset pagination, saved-post navigation, deleted-thread state,
  account-lease isolation, and explicitly confirmed single-item removal. Before a
  list removal, a raw anonymous PB response must bind the thread to a positive
  forum ID and canonical forum name; the authenticated PB preflight then binds
  the same target to the exact account. A fully deleted item whose target can no
  longer be resolved remains visible and sends no write. A logged-in thread separately reads
  its exact cloud state and offers explicitly confirmed add, saved-floor update,
  and removal controls. These operations never upload, merge, or delete the
  independent local favorites archive. Successful authenticated reads and writes
  over the minimal HTTPS contracts still require disposable-account device
  validation.
- **Text and classic-emoticon replies:** Current `main` can reply to a topic, an ordinary floor,
  or a specific nested reply, including one under the canonical first floor,
  from native, draft-backed composers. A visible inline nested-reply preview has
  a direct exact-target reply action. Bodies may include only ordinary text and
  the fixed 50-name classic-emoticon catalog; all other rich markers remain
  invalid. Replying to the first-floor parent itself
  remains a topic reply rather than an ordinary-floor reply. Targets are rebuilt
  only from validated page models and rebound by an authenticated PB
  Page/Floor read before the single write. Drafts are isolated by account and
  exact target and protected on disk. A non-resendable pending marker must be
  persisted before the network write; challenge, accepted-but-not-visible, and
  unknown outcomes remain blocked so reopening a composer cannot silently resend
  them. The local reply-entry preference prevents new manual or inbox-driven
  composers while hidden, but never deletes those drafts or closes a composer
  that is already open. A challenge remains blocked for the same
  `sessionRevision`; only an explicit new login can start a fresh attempt. The
  request deliberately omits Android device fingerprints and therefore remains
  a disposable-account validation feature.
- **Poll voting:** Anonymous poll cards remain read only and never receive an
  account credential. With a complete active session, a separate authenticated
  PB read binds the account, forum, thread, real option IDs, open/closed state,
  and previous selection. The App enables voting only while that authoritative
  state is open and unvoted and the chosen IDs are legal for its single- or
  multiple-choice mode. After explicit confirmation, command `309006` is sent at
  most once over minimum-field HTTPS and is always followed by one authenticated
  readback. Same-resource identical selections coalesce; conflicting selections
  or credentials wait and then read without writing. The App publishes only to
  the initiating `userID + sessionRevision` lease. Disposable-account validation
  is still required before this can leave validation builds.
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
  uncertain failure retries a write. Reply and new-topic submissions additionally
  bind final confirmation to an immutable target-and-content snapshot; editing,
  dismissing the confirmation, or an account-session change invalidates it before
  dispatch. They serialize per account, share only an identical submission UUID,
  and permit cancellation to stop the owner only before write dispatch. Once
  dispatched, the owner finishes receipt parsing and exact-ID readback even if
  its view disappears.
  Poll voting uses the same no-retry boundary: an identical canonical selection
  for one account and thread may share the active task, while a conflicting
  selection or credential receives only post-flight authoritative state. Every
  poll write, including one whose acknowledgement fails, performs exactly one
  authenticated readback and never dispatches a second vote.
  User interaction-permission changes follow the same rule: equivalent changes
  for one account and target share a flight; a conflicting permission set or
  rotated credential waits and then reads only. A user follow write and a
  permission write for that same account and target are mutually exclusive, so
  the later operation also settles through a read without dispatching a second
  kind of write.
  Already-completed check-in and matching content state are idempotent. The
  foreground one-click flow binds the user's confirmation to an ordered forum
  snapshot, refreshes official eligibility immediately before dispatch, and
  sends only the intersection. Official batch rejections and targets removed by
  that refresh never become individual check-in writes. Once a batch may have
  reached the server, an uncertain response triggers read-only reconciliation
  for the exact dispatched forums; unresolved outcomes remain visibly
  unconfirmed, with no retry or single-write fallback. All supported writes
  require explicit user confirmation; the configurable composer-entry risk
  notice is not that confirmation. Background and automatic check-in are not
  implemented.
- **Unsupported operations:** Guess-based removal of unresolvable cloud-favorite
  rows, bulk cloud/local synchronization, disagreement and other reaction types,
  recommendation feedback, image/voice and arbitrary rich-media topic/reply creation, profile editing, content
  deletion, native or credential-injected reporting, background or automatic check-in, notification mark-read/unread
  reconciliation, background notification polling, and moderation remain
  unavailable until their request contracts and recovery paths have been
  validated on a disposable account.
- **Detailed parity:** See [`ROADMAP.md`](ROADMAP.md) for the complete TiebaLite
  comparison, weighted estimate, protocol constraints, and next milestones.
  The current `main` source audit totals 78–81 of 100 weighted points, leaving
  about 19–22%; its anonymous reading and media subtotal remains about 91–95%.
  This measures implemented end-to-end workflows with partial credit for
  device-validation gates; it is not a claim that every path is release-ready.
  The public `v0.59.0-alpha.1` IPA remains at the earlier 57–62% scope. The
  largest remaining gaps are
  rich-media creation, background unread handling, broader settings, remaining
  account/social actions, unresolvable cloud-favorite rows, and moderation.

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
can be added directly to LiveContainer 3.7.0 or newer, or to SideStore. Each
listed IPA is an unsigned GitHub Release asset that must be signed by the
installer; its byte size and SHA-256 are checked against the source by CI. App
source updates are generated only from the tested tag snapshot and the published
IPA, then revalidated against `main` before an atomic commit. App Store
distribution is not currently a project goal.

```text
https://raw.githubusercontent.com/Minaduki-Shigure/tieba-plus-plus-swift/main/sidestore-source.json
```

## License

GPL-3.0-only. See `LICENSE`.
