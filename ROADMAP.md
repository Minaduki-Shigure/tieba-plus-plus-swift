# TiebaLite parity roadmap

Tieba++ is an independent Swift application implementation. TiebaLite is used as
a product reference for expected workflows. Adapted interoperability material is
limited to the attributed protobuf schemas and fixed classic-emoticon wire-name
catalog documented in TiebaProto's `NOTICE.md`.
This audit was last compared with TiebaLite `4.0-dev` at commit
[`268f388c`](https://github.com/zzc10086/TiebaLite/tree/268f388c7824ae2c8f6ed549827a943ec8a7f352).

## Progress audit

The estimate below measures end-user workflow scope in the current `main`
source, not line count or endpoint count. Full credit requires an end-to-end
implementation with automated contract coverage; a substantial workflow that
still needs disposable-account or physical-device validation receives partial
credit. Ranges reflect remaining edge-case uncertainty. The public app source
currently serves `v0.64.0-alpha.2` (build 77), whose app-code snapshot includes
the current image, media, navigation, Home/account, settings, cloud-favorite,
durable owner-deletion, legacy-link, guarded official-wrapper, level-progress,
and bounded regular-expression filtering workflows.
Paired profiles continue to support the nested-reply lazy-scroll container.
The published level-progress and bounded regular-expression filtering additions
improve existing credited areas without changing the current
80–82% weighted estimate; experimental account writes retain their documented
physical-device and disposable-account gates.
Current-main personalized-discovery startup routing and public-profile identity
label preservation likewise improve existing local-settings and public-reading
areas without adding a data source or weighted point.

| Capability area | Weight | Credited points | Current basis |
| --- | ---: | ---: | --- |
| Anonymous discovery, search, and forums | 20 | 18–19 | Core browsing, ranking, recommendations, categories, and search are implemented; a few niche discovery paths remain. Account-bound dislike feedback is credited under server writes, not anonymous reading |
| Thread, reply, and public-profile reading | 20 | 18–19 | Main reading, pagination, nested replies, shared text selection/copying, navigation, profiles, and public relationship lists are implemented; uncommon content cards and edge routes remain |
| Media rendering, playback, and export | 15 | 14 | Images, bounded GIF/WebP/HEIC-sequence playback, galleries, video, voice, sharing, saving, media policy, and a bounded persistent image cache are implemented; cache lifecycle remains a physical-device validation gate |
| Local data, settings, and customization | 10 | 7 | History, favorites, public-content and inbox filtering, appearance, text size, media preferences, hierarchical settings navigation, account-isolated followed-forum pinning and layout, separate local/cloud favorite opening habits, a configurable forum primary action, confirmation-frozen foreground check-in execution settings, a TiebaLite-compatible default image-watermark choice, reply-entry visibility, a default-on composer risk notice with an experimental reply-only system handoff attempt pending physical validation, local version/source information, and a TiebaLite-aligned inbox startup destination are implemented; wider customization remains |
| Account, session, and private read flows | 15 | 9 | Login, Home-toolbar quick switching, a self-profile summary, an authenticated current-account following list with a guarded mutual filter, followed and target-user liked forums with optional validated level-up progress, target-bound user relationship state, cloud favorites, inbox, foreground unread summary, and concern are implemented; several private reads still need real-account validation or broader activity coverage |
| Server writes, creation, and social actions | 15 | 14 | Forum/user follow and unfollow, server-side user interaction restrictions, single-forum and explicitly confirmed foreground batch check-in, account-bound poll voting, approval, verified list/thread-detail cloud-favorite mutations, server-reason-bound personalized recommendation dislike feedback, three text/classic-emoticon reply targets, equivalent new-topic creation, bounded static-image new-topic/direct-topic-reply creation, owner-only topic/ordinary-floor deletion, direct inline-preview reply entry, and credential-free official reporting entry points have guarded implementations; real batch-check-in behavior, creation, deletion, poll and interaction-restriction success, broader uploaded media, unresolvable cloud rows, native reporting, and other reactions remain unavailable or unvalidated |
| Background unread, moderation, and administration | 5 | 0 | Background polling, unread reconciliation, moderation, and administration are not implemented |
| **Total** | **100** | **80–82** | Current full-product estimate; roughly 18–20% remains |

This is a source-workflow coverage estimate, not a release-readiness or
physical-device-validation percentage. Current `main` receives partial credit
for the end-to-end static-image composer workflow and one additional server-write
point for the bounded recommendation-feedback workflow, bringing that row to 14.
The latter adds no anonymous data source, so the anonymous subtotal is unchanged.
The public `v0.64.0-alpha.2` app-code snapshot is at 80–82%; all experimental
account paths retain the validation gates documented below.

The first three rows form the anonymous reading-and-media subtotal: 50–52 of 55
points, or roughly 91–95%. Concern and the foreground unread summary raise the
private-read area but receive only partial credit until their minimum request
fields, empty/expired envelopes, cursor replay where applicable, and possible
seen-state effects are validated on a disposable account.
The complete self/other liked-forum list remains inside the existing private-read
credit until its pagination, privacy-empty, expired-session, and account-switch
behavior has also been validated on physical devices.
User relationship reads are required by the guarded follow workflow, so their
incremental credit is counted in the server-write row rather than duplicated in
the private-read row. The target-bound interaction-permission read is likewise
credited with its guarded server-write workflow rather than duplicated. The
inbox startup destination improves parity inside the
existing local-settings credit but is too small to add a full weighted point.
The followed-forum layout choice, including direct switches on both existing
surfaces at non-accessibility sizes, likewise improves the completeness of the
existing local-settings credit but does not add a full weighted point because it
only reflows those surfaces without adding a data source or workflow.
The account-isolated followed-forum pin archive, in contrast, completes
TiebaLite's local pinned-forum management workflow and presents it consistently
in the iOS home projection and complete list.
It adds one local-settings point because persistence, exact loaded-row projection,
context actions, account switching, unfollow cleanup, and failure recovery are
covered together without adding an authenticated request.
The composer-entry risk notice and experimental reply-only official-client
choice implement one narrow TiebaLite habit and harden an existing creation
flow, but add no App write target or weighted workflow point. The handoff remains
outside credited compatibility until its iOS device matrix passes.
The default image-watermark preference likewise closes a narrow composer habit
gap inside the existing local-settings credit. It adds no upload, write target,
or weighted point.
The hierarchical settings root groups the existing controls into six stable,
iOS-native destinations without changing their storage keys, defaults, account
boundaries, or local loading behavior. It improves discoverability inside the
existing local-settings credit and adds no data source, preference, or weighted
workflow point.
The first owner-deletion phase closes the loaded-topic and ordinary-floor paths
without claiming moderator authority. A public row can only make the control a
candidate: the authenticated Core probe must independently bind the active UID,
forum, thread, exact post, author, floor kind, and fresh `tbs` before a single
write. Definite acknowledgement, definite rejection, and outcome-unknown remain
separate. A bounded, authenticated write-ahead journal records dispatch before
the request and retains accepted or unknown terminal outcomes across process and
account-session lifetimes without automatic eviction; unreadable, future, unsafe,
or full storage fails closed. Restored accepted content is projected before the
thread starts history or network loading, while unknown targets cannot be
automatically resent. This remains inside the existing server-write point until
disposable-account testing validates the minimum field set. Nested-reply deletion
remains unimplemented because the compared TiebaLite source contains
contradictory concrete parameters for that irreversible request. An endpoint-
specific authoritative absence proof also remains before this workflow can
leave disposable-account validation.
The explicitly confirmed followed-list unfollow action closes a TiebaLite workflow
gap while reusing the already credited forum-membership endpoint and shared list
snapshot. It therefore adds no weighted point by itself.
Cloud favorites now consume independent only-thread-author and descending-order
opening preferences while retaining the server-provided marked-post anchor. This
closes another narrow TiebaLite habit gap without adding a request or weighted
point, and leaves the established local-favorite defaults unchanged.
The local About destination closes another narrow settings gap but adds no data
source or workflow, so it also remains inside the existing settings credit.
The shared selectable-text panel closes one narrow TiebaLite interaction gap
across existing visible post and reply surfaces, but adds no data source or
readable content, so it remains inside the existing reading credit rather than
adding a weighted point.
Direct list-image gallery entry likewise closes a narrow TiebaLite interaction
gap inside the existing media credit. It reuses the established viewer and
anonymous picture-page endpoint, adds no new content source, and therefore does
not add a weighted point. A single Root-level presenter keeps gallery state out
of scrolling rows; uncertain image ownership and active filtering fail closed
to the already filtered card.
Explicit list-card video playback closes the corresponding narrow TiebaLite
interaction gap inside the existing media credit. It reuses the one established
lazy AVKit player, stream policy, landing-page router, and playback coordinator;
it adds no endpoint, media source, or weighted point. Compact-media mode remains
passive, and an expanded card allocates no player before an explicit Play tap.
Explicit voice export to a user-selected Files destination closes TiebaLite's
narrow independent-save interaction gap inside the existing media credit. It
reuses the hardened voice download, byte/format/media validation, canonical
extension, and temporary lease used by sharing. One exact request binds its UUID,
source URL, and share-or-Files target; cancellation, replacement, duplicate or
mismatched completion, and late non-cooperative preparation cannot publish a
different presentation. The document picker copies rather than moves the source
and adds no background queue, fixed download directory, persistent cache, new
endpoint, or weighted point.
Reply-count navigation on shared thread cards closes another narrow TiebaLite
reading interaction gap. It reuses the canonical thread route and initial-page
response, adding no endpoint, data source, or weighted point. Its canonical link
route derives identity from the card's validated positive thread ID and pairs it
with a typed first-reply intent. After existing response validation and local
filtering, the first locally displayable reply becomes the initial scroll target,
otherwise the thread opens normally.
Independent forum and author controls on shared ordinary thread cards close the
corresponding narrow TiebaLite context-navigation gap. The context line is a
sibling of the whole-card topic button rather than a nested control. A forum or
author route is emitted only for visible content, an enabled displayed label,
and a strict round-trippable app URL built from a normalized forum name or
positive public UID; invalid, filtered, disabled, and pinned cases retain their
prior passive or compact presentation. The controls reuse existing Root routes,
add no request, per-row model, or thread/nested-reply scroll work, and therefore
remain inside the existing reading credit without adding a weighted point.
Independent per-forum search navigation likewise closes a narrow TiebaLite
reading gap inside the existing search credit. A matched result, its exact
parent-floor context, and its owning-topic context are separate controls; the
two context identities survive local filtering independently. Explicit topic
and floor routes bypass unrelated reading history, while a nested-reply match
uses the existing comment-ID resolver instead of trusting a displayed parent
PID. This reuses existing anonymous endpoints and adds no weighted point.
The app-owned search, history, cloud-favorite, foreground check-in-page, and inbox
routes close another narrow TiebaLite navigation gap. They expose only already
credited destinations, add no endpoint or account choice, and keep app-only
routes outside public rich content and clipboard parsing, so they add no weighted
point.
The explicit-paste preview closes a related narrow TiebaLite navigation habit
without copying its automatic clipboard inspection. The existing system
`PasteButton` remains the only read gate; a local card appears before one
credential-free, minimum-page forum or thread request enriches display text.
The immutable parsed target, including only-author and post-anchor context,
cannot be replaced by response metadata. Cancellation plus request generations
discard stale responses, and locally filtered, server-hidden, mismatched, or
failed responses remain generic but openable. This adds no content source or
weighted point.
The ordered iOS Home Screen quick actions expose the existing foreground batch-
check-in page, Tieba cloud favorites, search, and replies inbox through the iOS
16-and-later scene lifecycle. They add no endpoint, data source, background
behavior, or weighted point.
Public-reply cards now match TiebaLite's independent destination controls: the
reply body retains its exact floor or nested-reply target, while the displayed
topic title opens the origin thread without carrying that reply anchor. Unknown
reply types still expose no guessed exact target, but may open a separately
validated positive thread ID. This reuses existing anonymous readers and adds no
request, data source, or weighted point.
Standalone complete nested-reply pages now expose TiebaLite's owning-thread
action after the parent floor has been validated. It opens the exact parent PID;
the sheet already presented over a thread omits the redundant action. Route
derivation performs no request and reuses the existing anonymous thread reader
only after an explicit tap, so this closes a narrow navigation gap without a new
endpoint, data source, or weighted point.
The configurable forum primary action likewise completes a narrow local habit
setting by rearranging existing controls, so it remains inside the existing
local-settings credit rather than adding a weighted point.
The opaque custom accent closes another narrow customization gap without adding
a data source or workflow, so it likewise adds no weighted point.
The foreground inbox projection closes another filtering-surface gap without
adding a data source or workflow, so it also remains inside the existing local-
settings and private-read credit rather than adding a weighted point.
The floor-level cloud-favorite marker and context action close a TiebaLite
reading-workflow gap by exposing the existing confirmed thread-detail mutation
at an exact retained floor. They add no endpoint or write target, so they remain
inside the existing server-write credit rather than adding a weighted point.
The cloud-favorite saved-position-to-latest handoff closes the corresponding
private-reading gap. A consistent, nondeleted row still opens its marked PID
first, then offers one explicit jump to the distinct positive maximum PID and
its positive floor. The jump preserves an ascending or descending sort and the
selected only-author option; hot order exposes no exact-position action. A
transport or request failure retains the current page and retries the same PID;
a returned missing or locally hidden target instead produces a dismissible notice
without a futile retry. Invalid, unchanged, or incomplete update metadata exposes
no action. This reuses the existing anonymous post reader, adds no account write
or background request,
and remains inside the existing private-read credit without adding a weighted
point.
The followed-forum avatar and slogan presentation similarly preserves optional
metadata that the existing authenticated response and Core decoder already
carried. It adds neither a data source nor a workflow, so it adds no weighted point.
Complete followed-forum level progress now retains the optional level name and
upgrade target from the existing list response, and the loaded-forum surface
reads the same four-field tuple from its existing account-state response. Invalid
or incomplete metadata falls back to the earlier level/experience text or no
progress without failing membership or check-in. A confirmed check-in may issue
one read-only account-state refresh to update the score, but never another write.
This closes a TiebaLite presentation gap inside the existing private-read credit
and adds no endpoint, persistence, background behavior, or weighted point.
The separate fan-reminder entry consumes the existing optional `fans` field and
opens the already credited public follower list. It adds no endpoint, background
work, persistence, or weighted point.
The home-level one-click check-in entry likewise exposes the existing guarded
foreground flow where TiebaLite places a daily action. It appears only for an
active account with complete credentials, and opening it performs catalog reads
only; the existing confirmation remains the write boundary. It adds no endpoint,
write target, background behavior, or weighted point.
The one-click execution settings close another narrow TiebaLite habit gap inside
that same foreground workflow. They add no endpoint, write target, automatic or
background behavior, or weighted point; the confirmation freezes the selected
batch, failure, and pacing policy for one explicit run.
The Home account control now preserves its ordinary account-management tap while
adding a native long-press menu for exact saved-account switching and direct
account addition. It consumes only the existing nonsecret account summaries and
Keychain-vault mutation, adds no endpoint or private read, and therefore remains
inside the existing account-session credit rather than adding a weighted point.
The official-report handoff closes the end-user reporting-entry gap for visible
topics, floors, and nested replies and therefore adds one weighted point. It does
not claim native reporting parity: the credential-free preflight only resolves a
strictly bound HTTPS form URL, `SFSafariViewController` receives no App Keychain
credentials, cannot bind Safari's Baidu identity to the active App account, and
cannot infer whether the user submitted or cancelled the form.
The fixed classic-emoticon catalog and inline-preview reply entry together close
one bounded TiebaLite creation-workflow gap and therefore add one weighted point.
They reuse the existing three write targets and add no endpoint: only exact,
compiled `#(name)` tokens are accepted. Voice, arbitrary markers, and remotely
supplied sending choices remain unsupported; image support is limited to the
current-main workflow described next.
The current-main static-image composer closes another bounded part of that gap
for new topics and direct topic replies and receives one partial weighted point.
It includes the picker, nine-image drafts, ordered upload proof, immutable final
confirmation, explicit no-resend recovery, terminal metadata cleanup,
enqueue-only attachment tombstones, and strict ordered readback, but remains
below full credit until its minimum HTTPS contract and server-visible result pass
disposable-account and physical-device validation.
The current-main personalized recommendation-feedback flow closes one bounded
reaction workflow and adds one server-write point. It includes explicit
server-reason selection, exact reason/opaque-extra/target/time binding, a signed
single write, session-lease isolation, concurrent equivalent-request sharing,
conflict rejection, and no retry after an unknown outcome. It receives no
anonymous-reading credit and remains below release readiness until the live
minimum contract, acknowledgement behavior, and downstream recommendation effect
pass disposable-account and physical-device validation.

## Available

This section describes the current `main` source. A newly implemented item is
not installable from the public app source until its tagged build passes CI and
the source metadata is updated to that tested IPA.

- Anonymous hot-thread ranking with an embedded hot-topic preview,
  server-defined categories, and snapshot refresh
- Personalized thread feed as the default Explore channel, with a persistent
  choice between the default anonymous CUID and any saved account, pull refresh,
  integer pagination, duplicate and stalled-page termination, local filtering,
  one app-scoped random recommendation UUID, and a default-off persona-bound
  followed-forum filter
- Account-persona personalized recommendation dislike feedback for rows carrying
  valid server-provided reasons, with exact reason, opaque-extra, thread, forum,
  click-time, account-session, and recommendation-CUID binding; one signed HTTPS
  write; equivalent-request sharing; conflict rejection; and no retry after an
  unknown outcome
- Foreground account-bound concern feed shown only for a saved account, with
  explicit-selection activation, opaque cursor pagination, per-session in-memory
  timestamps, local filtering, and UID-plus-session-revision isolation
- Home account control with ordinary account-management opening plus a native
  long-press menu for exact saved-account switching and direct account addition
- Ranked anonymous hot-topic discovery with images and discussion counts
- Hot-topic details with related forums and cursor-aware thread pagination
- Categorized anonymous forum, thread, and user search
- Default-off anonymous online suggestions for the home search field
- Local home-entry customization with a next-launch home, personalized discovery,
  ranking, topic, inbox, favorite, or history destination plus an optional home
  discovery section
- Persistent adaptive-grid or single-column followed-forum layout shared by the
  six-item home projection and complete list, with an explicit switch on each
  surface at non-accessibility sizes, accessibility-size fallback, and explicit
  full-list pagination independent from card appearance
- Account-isolated local followed-forum pins shared by the home projection and
  complete list, with pin, unpin, and copy-name context actions; only exact loaded
  rows are reordered, so stale pins neither fabricate cards nor load another page
- Global post search with newest, oldest, and relevance sorting
- Local keyword, user, and video filtering for global and per-forum search results
- Local filtering for paginated public-profile activity
- Versioned local global-search history with recent/all, delete, and clear controls
- Anonymous per-forum post search with newest/relevance sorting
- Topic-only and topic-plus-reply search filters with separate matched-reply,
  exact-parent-floor, and owning-topic navigation
- Versioned, per-forum local search history with delete and clear controls
- Forum thread list with pagination and pull to refresh
- Persistent forum primary-action selection between publishing, refreshing,
  returning to the top, or hiding the shortcut, while retaining publishing,
  refresh, return-to-top, and sharing in the native More menu when applicable
- Reply-time and creation-time forum sorting
- Global default sorting with normalized per-forum sort memory
- Server-defined forum channels with bounded server-provided sorting menus and cursor pagination
- Shared rich thread cards across forum, channel, concern, personalized, hot,
  hot-topic, global-search, and public-profile surfaces
- Compact pinned rows, bounded author avatars, topic-state badges, image previews,
  explicit non-autoplay video playback on expanded thread cards, and a separate
  reply-counter entry to the first locally displayable reply
- Forum header, statistics, rules state, and featured classifications
- Public forum introductions with original avatars and server statistics
- Full forum-rule documents with publisher and rich section content
- Moderator teams grouped by the server's public role names
- Post list with ascending, descending, and hot sorting
- Only-thread-author filtering
- Protocol-correct descending pagination with PID cursors
- Page-number jump and last-visible-post restoration
- Adjacent earlier-page loading for anchored ascending threads with leading-floor restoration
- Independently preserved first-floor topic context on anchored and middle-page windows
- Explicit incremental latest-reply checks after ascending pagination is exhausted
- Direct owning-forum navigation from the thread navigation bar
- Versioned local browsing history with delete, clear, and recording controls
- Settings-level no-history mode using the existing browsing-history archive
- Six-category settings navigation that preserves every existing preference,
  local-history state, cache operation, and About destination
- Native system, light, and dark appearance selection
- Persistent selection among five preset accents and one opaque custom sRGB
  accent, with adaptive light, dark, and high-contrast variants
- Persistent six-position app text-size adjustment relative to iOS Dynamic Type
- Transient pure-reading and explicit only-author immersive-reading modes, plus
  one shared text-selection panel for visible topic and ordinary floors, inline
  nested-reply previews, and full-page parent and child rows, with partial system
  selection and explicit whole-text copying
- Default-off local hiding of topic, floor, nested-reply, and inbox quick-reply
  entry points without removing reply content, drafts, or an open composer
- Default-on, locally configurable entry-risk notice for editable reply and
  new-topic composers, separate from final submission confirmation, with a
  reply-only credential-free official-client handoff pending physical validation
- Home-screen recent-forum history, expanded by default and independently hideable
- Canonical forum/thread sharing and browse-mode-aware thread-link copying
- Strict internal routing for supported Tieba HTTPS, exact legacy
  `wapp.baidu.com`/`tiebac.baidu.com` and `/mo/q/m` forum/thread links, pasted
  official-scheme links, content links, and navigation-only app links matching
  TiebaLite's search, history, account-favorite, and two inbox entry points
- Default-system external HTTPS opening with an optional in-app Safari view
- Local About page with bundle version/build information and an explicit fixed
  source-repository action using the selected external-Web policy
- Nested replies, images, video links, and voice playback
- Explicit video landing-page fallback when a `PbContent` video has no accepted
  native stream, using native Tieba routing and the selected browser policy
- Application-scoped voice/video arbitration with one active playback lease,
  inactive-scene pausing, and no implicit resume
- Single lazy video player with native AVKit inline/full-screen controls and
  Picture in Picture disabled
- Single-session voice playback with loading/failure state, elapsed progress,
  seeking, and audio-interruption handling
- Explicit voice-file sharing and user-selected Files export through one
  credential-free bounded downloader, byte-level format checks, AVFoundation
  validation, and temporary-file leases
- Responsive one-to-three-column masonry for consecutive post-body image runs
- Persistent automatic, data-saving, or tap-to-load policy for content media
- Persistent standard or high-definition quality selection for supported image previews
- Independent server dynamic-image URL preservation plus ImageIO-confirmed
  multi-frame GIF, WebP, and HEIC/HEIF-sequence playback in previews and the
  gallery, with single-frame fallback, a 500-frame metadata limit, a 16 MiB
  per-frame bound and a shared frame cache capped at 64 MiB and 1,000 entries,
  viewport/scroll-tracking/background/Reduce Motion pausing, and one active gallery page
- Explicit eviction of the process-local decoded-image memory cache
- Optional compact media summaries for thread lists and per-forum search, with no collapsed preview request
- Default-on dark-appearance dimming for successfully rendered static content thumbnails
- Same-content multi-image gallery with horizontal or vertical one-image paging,
  stable selection, retained bounded zoom state with explicit one-to-one
  local-to-remote occurrence migration, bounded download progress, original-file
  sharing, and Photos saving
- Anonymous whole-thread image traversal with stable occurrences, global
  positions, and bidirectional lazy metadata loading
- Server-ranked inline nested-reply previews with anchored opening and the shared
  selectable-text panel
- Full nested-reply pages with parent-floor context and bidirectional anchored pagination
- Shared-thread origin cards with original content, media, and navigation
- Anonymous single- and multiple-choice poll result cards
- Account-bound authoritative poll state and explicitly confirmed single- or
  multiple-choice voting with real option IDs, one minimum-field HTTPS write at
  most, mandatory readback, and exact account-lease isolation; real-account
  behavior remains a disposable-account validation gate
- Read-only scores, author forum levels, bounded moderator roles, verified-creator
  field labels, and IP locations
- Lossless nested-reply context and public-profile links for user mentions
- Public user profiles opened from post and nested-reply authors
- Explicit profile-avatar viewing, sharing, and Photos saving
- Bounded public liked-forum previews plus an independent login-gated, paginated
  complete list for the current or another user, with direct forum navigation
- Paginated public threads on user profiles
- Lazily paginated public replies on user profiles, with exact ordinary-floor
  navigation and child-only nested-reply resolution
- Read-only public following and follower lists with profile navigation, local
  filtering, refresh, and endpoint-aware pagination
- Authenticated current-account following pages with inline management and a
  TiebaLite-style all/mutual filter, exact `has_concerned=2` classification,
  session-revision isolation, raw-cursor pagination, and a five-page bounded
  search for later visible mutual rows; incomplete metadata hides the filter instead of
  guessing
- Default-off combined public nickname and username presentation
- Local case-sensitive literal-keyword, bounded non-backtracking regular-expression,
  and exact UID/name user block/allow lists
- Placeholder or fully hidden presentation for locally blocked content
- Local video-topic blocking and user-profile block/allow shortcuts
- Lazy, account-bound server interaction restrictions on another user's profile,
  with separate follow, interaction, and private-message bits, explicit save
  confirmation, one changed-state write at most, mandatory readback, and
  account-lease isolation; real-server behavior remains a disposable-account
  validation gate
- Independent local forum and thread favorites
- Local pinned-forum ordering and explicit forum-favorite context actions
- Saved-thread reading-position and browse-mode restoration
- Default-off only-author and descending overrides for locally saved threads
- Home-screen shortcuts for locally saved forums
- HTTPS-only anonymous requests with no account credentials or hardware-derived identifiers
- Ephemeral, HTTPS-only Baidu Web login with an exact host allowlist
- Same-snapshot BDUSS/STOKEN capture, independent same-UID session binding,
  device-only Keychain v3 storage, account switching, and local logout
- Account-bound, memory-only self-profile summary with current avatar, display
  name, biography, following, follower, and reply counts, plus an explicit link to
  the existing credential-free public profile and its public topic, reply,
  following, and follower views
- App-scoped, memory-only followed-forum state shared by a six-item logged-in
  home projection, the active account's complete paginated list, and a selected
  default-off followed-forum recommendation filter, with a local layout setting
  that performs no explicit refresh or account mutation. Home and complete-list
  cards preserve the existing response's optional avatar and slogan, and show
  bounded level-name/current/upgrade progress when that complete tuple is valid,
  with the earlier level/experience text as a local fallback. A separate account-
  isolated
  local archive pins exact already-loaded rows across both list surfaces without
  adding a private request
- Separate Tieba cloud favorites with offset pagination, saved-post navigation,
  a dismissible saved-position-to-latest-update handoff for consistent metadata,
  deleted-thread state, account-lease isolation, and confirmed list deletion only
  after raw thread/forum rebinding, plus confirmed thread-detail add, saved-floor
  update, and removal with read-only reconciliation. Exact visible floors expose
  the same snapshot-bound actions from their context menu, and the confirmed
  marker is shown only on its exact PID
- Foreground ReplyMe and AtMe inbox with account-lease isolation, refresh,
  bounded pagination, safe thread navigation, explicit reply actions bound to
  the active account lease, and a local content/sender filter projection that
  preserves the raw message pages; a visible sender avatar or name opens that
  sender's credential-free public profile only for a strict positive UID
- Foreground, memory-only reply, mention, and optional fan-reminder summary shared
  by the Home account control and account page, with direct ReplyMe/AtMe Home-menu
  routes, separate message and fan badges, an existing public follower-list
  destination, exact account-lease isolation, five-minute eligible-surface freshness,
  no local clearing, a privacy-minimized signed HTTPS form, and no background polling
- Exact nested-notification positioning through the public child-only resolver,
  with parent locking, bidirectional pagination, history continuity, and an
  owning-thread fallback when the target is unavailable; a reply action opens the
  existing composer only after the exact ordinary post or child is relocated,
  while legacy `quote_pid` never becomes a write target
- Authoritative per-forum account membership state with explicit follow and
  unfollow confirmation
- Authoritative per-forum check-in state and explicitly confirmed single-forum
  check-in, with already-signed idempotence
- Foreground-only one-click check-in from the home toolbar or account page, with
  an explicit confirmation snapshot, a fresh official eligibility refresh, and
  a batch dispatch limited to their intersection. Official rejections and dropped
  targets never fall back to individual writes; an uncertain batch outcome is
  reconciled only through authoritative per-forum reads and is never retried.
  The confirmation also freezes whether official batch is enabled, whether an
  authoritative single-forum failure stops later targets, and whether individual
  requests use a random 3.5-to-under-8-second or fixed 2-second interval. Unknown
  outcomes, cancellation, and account changes always stop. Background and
  automatic check-in are not implemented
- Account-bound approval and cancellation on the canonical topic, ordinary
  floors, and both parent and child items in a full nested-reply page, with
  explicit confirmation and lease-guarded read-only recovery
- Experimental native text/classic-emoticon composers for replying to the topic, an
  ordinary floor, or a specific nested reply including one under the canonical
  first floor, with exact target rebinding, account-level write serialization,
  persistent per-target drafts, strict challenge/accepted/unknown states, and
  structured exact-PID readback without write retry; visible inline nested-reply
  previews expose the same exact-target composer without another network request
- Current-main static-image selection for direct topic replies, with up to nine
  ordered metadata-stripped attachments, quality and watermark choices,
  account-scoped durable drafts and upload proof, explicit resume-only recovery,
  immutable confirmation, and strict ordered image readback. Ordinary-floor and
  nested-reply image entry remain unsupported
- Experimental native text/classic-emoticon new-topic creation from a loaded forum, with an
  optional bounded title, fresh account/forum/TBS preflight, one signed HTTPS
  write, persistent per-account-and-forum drafts, strict
  challenge/accepted/unknown states, and exact TID/PID readback without retry
- Current-main static-image selection for new topics with the same bounded picker,
  durable upload, confirmation, recovery, terminal metadata cleanup, enqueue-only
  attachment tombstones, and exact visibility rules
- Page-shaped authenticated approval overlays that mirror the anonymous post
  and nested-reply requests, batch the currently retained targets, and refresh
  a full nested-reply page even when its target set is unchanged
- Short-lived `tbs` availability for at most the immediately following write,
  without Keychain persistence or exposure to application models
- Isolated anonymous and authenticated networking clients
- Login-gated official report-form handoff for exact visible topic, floor, and
  nested-reply IDs, using a minimum-field credential-free HTTPS preflight,
  canonical HTTPS route rebuilding, SafariServices handoff, and no App
  credential injection, browser-account identity claim, or submission-state inference

## In progress

Current `main` now connects the security-sensitive static-image foundation to
the new-topic and direct-topic-reply composers. The App normalizes a selected
single-frame JPEG, PNG, HEIC, or HEIF into a bounded, metadata-stripped JPEG;
stores up to nine ordered attachments under private random filenames with file
protection, backup exclusion, and digest validation; and persists account-scoped
draft and upload state. Core validates the complete session, serializes
same-account uploads, sends sequential 512,000-byte chunks, owns typed image-marker
compilation, and never retries an uncertain dispatched chunk. The final write is
bound to an immutable target, content, attachment order, processing choice,
watermark, session, and submission ID. Restart recovery performs no network work
until an explicit resume, while locked outcomes remain read-only.
The shared settings menu now stores TiebaLite's stable `0`/`1`/`2` watermark
values, defaults to forum name, and fails back to that default for unknown
values. A composer without an image draft adopts the current preference, while
a restored draft with images retains the watermark already bound to those
attachments. Discarding a draft or explicitly starting another topic returns to
the current default; changing the preference never mutates a live image draft or
starts network work.

Attachment removal and terminal submission cleanup write a durable bounded
tombstone but do not physically delete the private composer JPEG in current
`main`. The reference audit spans all new-topic drafts, reply drafts, and upload
ledger records, but its snapshot is not atomic with in-flight UI and store
mutations; treating it as deletion authorization could therefore remove a live
cross-key attachment. The fail-closed policy retains every file. At 128 records,
the journal rotates the oldest audit entry without deleting its file, and a
journal write failure never keeps a terminal draft or completed ledger record
sendable. Physical reclamation requires a future shared exclusive reference
reservation. Picker transfer copies are separate: strictly named
`tieba-composer-image-<uuid>` directories expire after 24 hours and a no-follow,
nonrecursive pass inspects at most 256 entries and removes at most 32 directories.

Automated model, durability, pipeline, UI-policy, and strict visibility-proof
coverage is present. The remaining gate is disposable-account and physical-device
validation of the upload response, watermark values, marker acceptance, server
readback, picker lifecycle, and cleanup on iOS 16 and iOS 18.7.2. Ordinary-floor
and nested-reply image entry remain outside the current TiebaLite-aligned scope.

Current `main` also exposes personalized recommendation dislike feedback when a
row carries a bounded valid server reason. Automated coverage verifies reason
and target binding, full-session admission, exact signed request fields,
credential sanitization, equivalent-request sharing, conflict rejection,
success/known-rejection/unknown classification, no automatic retry, pre-dispatch
caller cancellation, and stale UI suppression after an account-session change.
It does not use a real account in CI. A session change is not claimed to retract
a write that may already have been dispatched. The remaining gate is
disposable-account and physical-device
validation of the endpoint's minimum fields, reason encoding, acknowledgement,
and effect on later recommendations.

## Next milestones

1. Real-device validation of multi-frame GIF, WebP, and HEIC/HEIF sequences in
   post bodies, list previews, and the zoom gallery on iOS 16 and iOS 18.7.2,
   including single-frame containers, Reduce Motion, backgrounding, rapid and
   cancelled paging, memory pressure, save/share byte preservation, and static
   fallback at the frame and decoded-memory limits. Also validate expanded
   thread-card video Play, pause, scrubbing, native full-screen entry/exit,
   landing-page fallback, offscreen cleanup, and compact-mode switching inside
   every whole-row navigation surface; none of those media actions may open the
   thread destination, and scrolling covers alone must leave the player unallocated
2. Real-device validation of the persistent image cache on iOS 16 and iOS 18.7.2,
   including cold-relaunch hits, preview/original size boundaries, TTL and LRU
   eviction, clearing against in-flight downloads, storage pressure, and logical
   usage while independent share or Photos-export leases remain alive
3. Real-device validation of the complete liked-forum list for the current and
   another public user, including page-one/page-two termination, privacy-empty
   results, expired credentials, same-UID credential rotation, account switching,
   and confirmation that reading performs no follow, check-in, or other write.
   Compare `level_name` and `levelup_score` availability for current-account and
   target-user rows, including incomplete tuples and scores at or above the target
4. Real-device validation of full-session binding and the minimal HTTPS cloud
   favorites list, including valid, random, cross-account, and expired STOKEN
   cases and whether reading the list has any server-side side effect
5. Real-device validation of canonical-topic, ordinary-floor, and full
   nested-reply approval/cancellation, single-forum and foreground batch
   check-in, forum follow, and user follow/unfollow in both directions, plus all
   three server-side user interaction restrictions. For batch check-in, cover
   partially eligible confirmation snapshots, newly eligible and removed
   targets, official per-forum rejection, malformed or lost acknowledgements,
   read-only reconciliation without retry or single-write fallback,
   official-batch-disabled sequential execution, both pacing modes, definitive-
   failure continue/stop behavior, cancellation, and a second explicit run. Also
   cover mutual-follow value `2`,
   the per-forum level tuple before and after a confirmed check-in, ensuring its
   one read-only refresh never resends the write. Also cover the permission
   field-deletion matrix and `0`/`1` meaning, idempotence, rate
   limits, expired credentials, server errors, uncertain failures, mandatory
   read-only reconciliation, cross-operation exclusion, account switching, and
   same-UID credential rotation
6. Disposable-account validation of authenticated poll reads and command
   `309006` writes, including single- and multiple-choice polls, real option-ID
   binding, open/closed and already-voted states, malformed or stale options,
   known server rejection, post-dispatch transport loss, mandatory readback,
   identical-selection sharing, conflicting-selection read-only recovery,
   cancellation, account switching, and same-UID credential rotation
7. Real-device validation of the minimal HTTPS ReplyMe, AtMe, and `/c/s/msg`
   summary requests, including the summary field-deletion matrix, reply, mention,
   and optional fan-reminder count parity, whether `fans` denotes a pending
   reminder count, and whether either summary or list retrieval changes server
   unread state,
   plus ordinary post and child-reply action relocation, unavailable targets,
   and account switching before composer presentation
8. Real-device validation of the minimal authenticated self-profile request,
   including successful V12 field deletion, absent `is_login`, empty biography,
   expired and cross-account credentials, response UID binding, account switching,
   and same-UID credential rotation
9. Real-device validation of the account-bound concern request, including the
   signed-field deletion matrix, empty-account and expired-session envelopes,
   cursor replay, and whether list retrieval changes recommendation state
10. Real-device validation of explicit cloud-favorite list/detail removal, add,
   and saved-floor updates, including unresolvable deleted rows, STOKEN rejection,
   idempotence, uncertain-write readback, concurrency, session rotation, and
   account switching
11. Disposable-account validation of all three text/classic-emoticon reply targets,
   including minimum-field deletion, missing/random/expired/cross-account
   STOKEN and TBS, challenge and permission failures, post-dispatch loss,
   exact-PID visibility, all 50 fixed catalog tokens, type-2/type-11 readback,
   inline-preview entry, account rotation, and duplicate-send prevention
12. Disposable-account validation of text/classic-emoticon new-topic creation and
   the current-main static-image workflow for new topics and direct topic replies:
   validate the minimum HTTPS upload contract, standard/high-definition processing,
   all watermark choices, ordered one-to-nine-image marker acceptance, final
   creation readback, cancellation, restart recovery, cleanup, account switching,
   and same-UID credential rotation on physical devices.
   Other rich media, broader settings parity, remaining account activity, and
   moderation tools follow that bounded workflow
13. Real-device validation of the official report-form handoff, including
   browser login state, report reasons, captcha/SMS challenges, cancellation,
   account rotation during preflight, and unsupported image/private-message
   evidence. A future native reporter requires separate minimum-field captures
   for `/mo/q/tbs`, `/mg/o/complaint/wise/querytpl`, and
   `/mg/o/complaint/wise/submit`; Keychain credentials must not be injected into
   a remotely updated general-purpose WebView.
14. Disposable-account and physical-device validation of personalized
   recommendation dislike feedback, including the signed-field deletion matrix,
   missing, random, expired, and cross-account STOKEN cases, single- and
   multiple-reason opaque-extra encoding, explicit success, known rejection,
   malformed acknowledgement, post-dispatch transport loss, equivalent and
   conflicting concurrency, cancellation before and after dispatch, account
   switching, same-UID credential rotation, and whether submission changes later
   recommendation pages. Confirm that unknown outcomes never trigger a retry and
   that a stale account lease cannot publish a completion.
15. Real-device validation of the experimental official-client reply handoff
   with the current iOS official client installed and absent, covering topic,
   floor, and nested targets, a different official-client account, return-to-App
   draft retention, unsupported or hijacked custom-scheme handlers, and both
   SideStore and LiveContainer. Record whether each route reaches a reply editor,
   its intended floor, or only the App home page. Compare the observed full
   TiebaLite template with a minimal TID/PID field set before retaining opaque
   Chrome, push, referrer, and sample-attribution constants.

The foreground inbox deliberately does not copy TiebaLite's cleartext JSON
transport or its Android hardware parameters. ReplyMe uses the current HTTPS
Protobuf command `303007`; AtMe uses a signed HTTPS form containing only BDUSS,
the fixed client version, page number, and signature. Both are isolated in the
authenticated client, reject redirects, enforce response limits, and remain
entirely in memory. A `userID + sessionRevision` lease is checked before and
after every page request so an account switch cannot display a previous
account's private response.

The inbox's local filter projection inspects only `message.content` and the
sender's exact UID, nickname, and username. Message titles, quoted content,
forum labels, routing metadata, and other fields do not participate. A
placeholder discloses no message-specific content and constructs neither a
navigation destination nor a reply action; a hidden result constructs no row.
The ordered raw message array, current page, and has-more decision remain
authoritative. A rule change rereads the local archive and reprojects only the
already loaded messages in memory, without requesting those pages again. It also
pauses automatic load-more until the user explicitly continues, preventing a
rule edit from silently starting another private request. If the archive reread
fails, the inbox retains the last successfully accepted snapshot; before any
successful read it uses an empty snapshot. This behavior is fail-open local
presentation, not a confidentiality or access-control boundary.

Notification pagination is strictly one-based and a returned page must match the
requested page. Positive thread, post, and sender IDs and zero-or-one flags are
validated before an item is exposed. Ordinary notifications can reopen a stable
post ID. Nested replies do not trust the legacy `quote_pid` value because public
clients document it as ambiguously representing either a parent floor or a
child reply. Instead, the app sends `pid=0`, the notification post ID as `spid`,
and `pn=1` to the public floor resolver, then requires the exact thread and child
in the response before accepting the server-resolved parent. That parent remains
locked for earlier and later pages. A successful direct visit records the owning
parent as local reading progress; a missing target retains an explicit owning-
thread fallback. An explicit reply action creates only an intent bound to the
current `userID + sessionRevision` and the stable thread, post, and sender IDs.
It never derives a write target from `quote_pid`, title, body, quoted content, or
forum display text. The destination rechecks the account lease and requires the
authoritative loaded post or child, including its author and resolved parent, to
match before opening the existing composer. A missing or mismatched target,
cancellation, or session change opens no composer and sends no write; normal
fallback navigation remains available. Once presented, the existing draft,
explicit confirmation, authenticated target rebinding, and non-retry outcome
rules apply unchanged. A separate `/c/s/msg` request reads bounded `replyme`,
`atme`, and optional `fans` counts into one root-owned foreground snapshot. Reply
plus mention drives the Home-toolbar and account-page message badges; the Home
account menu can route directly to either existing inbox. The optional fan count
drives a separate public-follower-list entry. Its form contains only BDUSS,
client version, `bookmark`, and signature; it sends no Cookie, STOKEN, UID
header, or device identifier. The response does not prove a UID, so Core labels
it with the requested UID and the App checks the exact
`userID + sessionRevision` lease before and after the request. An inactive scene
or navigation away from Home/account cancels an in-flight summary request; an
eligible foreground surface reuses an accepted snapshot for five minutes before
refreshing it. The inbox does not poll in the background, clear either badge
locally, or send a mark-read request. Whether
summary or list retrieval has an implicit server-side read effect remains a
physical-device validation item. The unread summary continues to use the raw
server counts and is not changed by local inbox filtering. The App keeps a
missing `fans` field distinct from zero, stores no follower baseline, and does
not infer new or lost followers from reminder or profile-count changes.

The concern feed uses HTTPS protobuf command `309474` only after the user selects
its Explore channel; page-style TabView preloading and inactive account changes
cannot start it. Its minimal candidate request carries the full session in the
protobuf common data and a signed outer multipart credential set, one expected
UID header, and a separate process-local random UUID. It carries no Cookie or
hardware-derived identifier. A successful refresh binds the returned opaque
page tag and request timestamp to the exact `userID + sessionRevision` lease.
Load-more keeps that timestamp unchanged, honors the raw `has_more` flag, and
stops on an empty, stalled, or duplicate-only page until explicit continuation.
Logout, account switching, same-UID re-login, and app restart discard the
frontier. A zero-error response that asks the user to log in is not accepted as
an ordinary empty page until the existing two-origin session probe confirms the
same UID. Live success, minimum-field elimination, and possible server-side
seen-state changes remain real-device validation items.

New Web logins capture one structurally valid BDUSS or BDUSS_BFESS and one
STOKEN from the same ephemeral Cookie-store snapshot. The app checks the pair
through signed app login and an independent Web identity request and persists it
only when both return the same positive UID. These probes both carry BDUSS, so
wrong-STOKEN negative cases remain a physical-device requirement rather than a
proved server invariant. Keychain v1 and v2
records migrate to v3 without inventing an STOKEN; existing BDUSS-only features
continue to work, while cloud favorites require an explicit re-login. The cloud
list uses an HTTPS-only, signed minimal form and returns no credential to the
application model. A thread-detail overlay separately binds the authenticated
state to the exact UID, forum, thread, and positive saved post. Adding, updating,
or removing that state requires explicit confirmation, at most one write, and a
read-only reconciliation even after an apparently successful response. List
removal additionally requires a raw PB thread/forum identity that survives the
same authenticated preflight; no `fid=null` fallback is used. An
uncertain write is never retried. Both surfaces remain separate from local
favorites, and a `userID + sessionRevision` lease discards late pages and
mutation results after account changes.

Tieba's anonymous post endpoint does not currently honor its nominal numeric
floor-jump fields. The app therefore restores a stable post ID and offers page
jumps instead of presenting an unreliable arbitrary-floor jump as supported.
Hot ranking responses expose physical-page PIDs unrelated to the ranking, so a
hot history entry restores the mode but deliberately reopens its first page.

An ascending thread opened around a stable post can prepend only the exact
adjacent physical page reported by the anonymous endpoint. The app restores the
leading rendered floor, keeps the existing tail page and PID cursor unchanged,
and isolates previous-page loading and retry state from tail pagination. A
wrong-thread, skipped-page, duplicate-only, invalid-ID, or stalled response is
rejected before it can mutate the loaded window. Descending and hot windows do
not expose this control because their physical-page direction and ranking
semantics require separate live validation.

Post responses can carry the first floor independently from the current reply
page. The app accepts that topic context only when it has a positive ID, floor
one, a matching thread owner, and, when declared, the thread's exact first-post
ID. The PB thread object's `post_id` may identify the current anchor and is never
used as a first-post fallback on post pages. A valid first floor is rendered
once above the reply window and owns the outer thread's shared-origin card and
poll. It is filtered like any other floor, is retained when later or earlier
reply pages omit it, and is replaced or
cleared by a new snapshot. It never participates in reply deduplication,
physical-page progression, prepend restoration, or the tail PID cursor. An
absent or invalid first floor is not synthesized from the thread-list excerpt.

After ordinary ascending pagination is exhausted, a user can explicitly check
for replies added after the raw final post ID. The request sends that same
server-issued ID as both the anchor and protobuf `last_pid` field, keeps the
active only-author mode, and never runs as a background poll. New replies retain
server order and are deduplicated by positive post ID before being appended. An
empty or duplicate-only response preserves the complete loaded snapshot; a
nonempty response can resume ordinary cursor pagination when the server reports
more pages. Descending and hot modes do not expose the control because their
ordering does not provide the required chronological tail. The thread navigation
bar also links its normalized public forum name directly to the existing forum
view without issuing a preparatory request.

Consecutive images in floors, nested replies, parent-post context, and shared
origins form bounded image runs; text, unsupported fragments, video, and voice
end the current run. A single SwiftUI `Layout` keeps every image as a direct
child identified by its original content offset while selecting one, two, or
three columns from the actual proposed width at 600- and 840-point boundaries.
The count never exceeds the number of images, a one-column run retains the
existing 560-point maximum width, and Accessibility Dynamic Type forces one
column without changing child identity. Forum-rule documents explicitly remain
single-column. Sanitized 0.5-through-2 aspect ratios feed a deterministic
shortest-column assignment whose ties choose the lower column. Nonfinite
proposals or spacing and invalid dimensions are normalized before frame
calculation.

Media playback uses one main-actor application coordinator rather than allowing
each rendered control to play independently. Voice and video compete for one
opaque lease: a successful new claim pauses the previous participant, while an
invalid URL cannot disturb an unrelated lease. Returning from an inactive scene
does not reacquire a lease or resume anything. Controller leases, owner IDs,
random load-session IDs, and current player-item identities form separate
guards, so late engine, interruption, and UI lifecycle events from an old owner
cannot mutate or stop its successor. Native AVKit play and pause actions pass
through the same arbitration even when they bypass the app's cover control.

Voice content retains one application-scoped player, and every rendered control
owns a fresh item identity. The declared public duration is a bounded initial
fallback; a finite positive AVFoundation duration can replace it after loading,
and both elapsed time and explicit seeks are clamped before presentation.
Loading, playing, paused, and generic failure states remain separate. Completion
returns the same item to zero, while leaving that item, an audio interruption,
or loss of the active output cannot leave an inaccessible player running.

Video content also has one application-scoped player, but the underlying
`AVPlayer` and item remain absent while only a cover is visible. An explicit
start first validates the initial HTTPS URL, acquires the shared lease, and then
creates the player lazily. Repeated URL values in different cells remain
different owners, replacing one inline video with another replaces the only
item, and changing an owner's URL never autoplays the replacement. AVKit keeps
the same player for inline and full-screen playback. Entering, presented,
exiting, and inline transition states are tied to the current owner and session;
owner disappearance or a source change pauses immediately but defers item
destruction until a transition outcome confirms the player is inline. A
cancelled entry can complete only its matching pending cleanup, while a
cancelled exit remains full-screen and keeps cleanup pending. Stale transitions
cannot tear down a newer session, and another video cannot replace a non-inline
item. Post bodies and expanded thread-list cards share this same playback leaf;
list cards preserve the exact video occurrence even when no cover survives, and
compact-media rows never construct that leaf. Removing a playing row or changing
its source invokes the same owner cleanup as a post-body video.

TiebaLite also preserves the `PbContent.type == 5` text field as a video landing
page. Tieba++ keeps that field independently from the media stream. Core trims
only surrounding whitespace, accepts bounded credential-free HTTP(S) or
protocol-relative URLs, and rejects control characters, non-Web schemes, empty
hosts, credentials, and values over 8,192 UTF-8 bytes. The App repeats that
boundary and rejects percent-decoded control characters. A stream passing the
stricter HTTPS playback policy remains primary. Only when no playable stream
exists does the card offer an explicit Web action; native playback failure may
expose a separate explicit fallback but never opens it automatically. Supported
Tieba links remain internal, external HTTPS follows the selected system/Safari
preference, and HTTP remains system-owned.

The shared rich-content and video-page router also implements TiebaLite's
`/mo/q/checkurl` compatibility behavior without relying on the remote redirect
page. Only exact standard-port `tieba.baidu.com` and `wapp.baidu.com` wrappers
with the exact path and one raw lowercase `url` query key are unwrapped. The
credential-free absolute HTTP(S) target is decoded once, bounded, checked for
encoded control characters, and routed again so a wrapped forum or thread still
uses native navigation. Query metadata, total bytes, and recursive depth are
bounded; malformed official wrappers fail closed, while non-official lookalikes
retain ordinary external-link behavior. The known leading `http://https://`
producer defect is repaired once without rewriting the same text inside a valid
path or query. System-browser and unavailable-Safari fallbacks receive the
validated target explicitly rather than reopening the wrapper.

Voice sharing and Files saving are explicit, one-shot exports. They use a
separate ephemeral credential-free HTTPS session that rejects redirects,
non-200 and partial responses,
non-identity content encoding, and files over 16 MiB. Response MIME and filenames
are ignored. Supported bytes must identify MP3, AMR, AMR-WB, or AAC; AMR storage
frames are traversed to exact EOF and the canonical-extension copy must be
playable, audio-only, and duration-bounded under AVFoundation before either
system surface receives it. One exact request owns preparation and presentation;
the share sheet and copy-only Files picker cannot overlap, and stale source,
target, ID, dismissal, or completion events cannot finish its successor. Files
success receives an app acknowledgement, while cancellation is silent. The
temporary lease is deleted after completion, dismissal, cancellation, source
replacement, view disappearance, or failure and never becomes a persistent media
cache. This is not a background download queue or a fixed public media directory.

This milestone intentionally adds no background audio, lock-screen controls,
automatic playback, automatic resume after scene activation, persistent media
cache, or custom media credentials and headers. Picture in Picture and automatic
Picture in Picture startup are disabled.

Rich-content images first open from the already filtered content array that
produced the tap, so the local gallery is available without waiting for metadata.
Source offsets identify local pages and preserve repeated URLs. Ordinary topic
floors may then use the anonymous HTTPS `picpage` contract when the current
content-filter snapshot has no rules and does not block video topics. Strict
picture IDs, post IDs, and global indexes identify remote occurrences; the
selected occurrence remains stable while inclusive cursor windows are
deduplicated and prepended or appended. The first response may contain 30 items,
while continuation windows include their anchor, so no UI logic assumes a fixed
response size. Empty, duplicate-only, malformed, stale-generation, or
inconsistent-total responses stop only the affected direction and retain the
local fallback. Changing thread options or filters cancels and dismisses the
session. Current-main thread-list thumbnails and collapsed image summaries use
one Root-level presenter and retain the exact tapped source offset without
installing a route, task, or cover in every scrolling row. Their already filtered
card opens immediately. Remote expansion uses the typed `index` picture source
only when every represented media item carries the same positive `Media.post_id`,
or a normal search result provides an authoritative matched-post target. Missing,
partial, or conflicting ownership, matched comments, active content filters,
nested replies, origin cards, forum rules, and profile avatars deliberately keep
the same-content gallery. User-profile topic cards follow TiebaLite's shared
feed-card behavior and may expand only when their `Media.post_id` is complete
and unambiguous. Ordinary floor galleries retain the typed `pb` source;
the unused `frs` value is represented but is not presented as an implemented
forum-gallery workflow.

The gallery uses one `UIPageViewController` implementation for horizontal and
vertical one-image paging. Direction is transient to the current presentation;
switching it rebuilds the UIKit pager but keeps the selected stable occurrence.
A bounded process-local LRU store also restores that occurrence's scale and
clamped offset. Within one gallery context, replacing a local placeholder with
exactly one currently accepted remote occurrence sharing its `(pictureID, postID)`
emits an explicit ID migration that carries that state to the new occurrence.
URLs, source offsets, image ordinals, and list positions never infer a migration.
Ambiguous local or remote candidates fail closed when that mapping is first
established: the local fallback remains when reconciliation cannot prove a
replacement, and an otherwise new destination starts at identity rather than
borrowing guessed state. A committed mapping stays bound to that explicit
destination; a later repeated server representation does not reassign it.
Existing destination state wins. Context or local-snapshot replacement, or
disabling remote loading, clears the migration chain and zoom cache; neither is
persisted.
At most the current controller plus two neighbors on either side stay in the
normal cache, reduced to adjacent controllers after a memory warning. Once a
one-finger drag exceeds the system movement threshold, the native pan
recognizer's dominant axis and direction plus the enlarged image's current pan
boundary assign the complete gesture to image panning or the native pager. An
image-owned drag remains owned until lift or cancellation even when it reaches
the boundary; a subsequent outward drag at that boundary pages, while an inward
drag pans back into the image. Two-finger gestures stay with zooming and never
page. The same policy is applied symmetrically to horizontal and vertical
paging. XCTest covers the pixel-scale edge policy and recognizer hierarchy;
continuous touch competition remains a device-validation gate.
Interactive and programmatic transitions coalesce pending migration, list, and
selection updates, then apply them atomically after the active transition
resolves, so whole-thread prepend or append loading cannot replace a newer
requested occurrence. VoiceOver scroll directions map to the active axis and
announce the displayed position. Single-image presentations omit paging
direction, count, and previous/next controls while retaining share, save, zoom,
and close actions.

Each original-image page observes its own waiter on the existing deduplicated
transfer. A stable positive server length produces an integer percentage from
exact received bytes; missing, changing, or inconsistent lengths remain
indeterminate, and ImageIO work is shown as a separate processing stage.
Transfer, waiter, and SwiftUI-attempt identities reject late progress from a
canceled same-URL request without fragmenting the decoded cache. Persistent-cache
hits never report a network-download stage and may finish bounded ImageIO work
before SwiftUI observes the processing state. Sharing and
Photos saving request only the selected original image. They first reuse an
exact-URL persistent entry when one passes the original-size bound and payload
digest, otherwise use the bounded credential-free media transport. The bytes
must still pass full ImageIO type, frame, pixel, and dimension validation before
export or cache publication, and an independent temporary copy is retained only
until the system consumer finishes.

Public profiles use the protocol's guest fields instead of impersonating the
target user as the current account. The public-topic endpoint ignores its
nominal page-size field, so pagination deliberately continues until an empty
page and deduplicates by thread ID. Public reply activity uses the same endpoint
through a separate anonymous request whose endpoint-specific client version is
fixed to `8`; newer global versions currently return an empty, hidden response.
The request sends only the target UID, page size, page number, content flag, and
credential-free common data. Each outer thread group can contain several reply
records, so mapping flattens every inner record and terminates only after an
empty raw page. Ordinary floors navigate with the inner post ID. Nested replies
send only the thread and inner child ID to the existing public parent resolver;
the outer group post ID is never treated as a parent. Unknown post types remain
visible but have no guessed reply navigation; their independently validated
positive origin-thread identity can still open the ordinary topic reader.
TiebaLite presents this history only for
the current account, while the separately researched guest contract exposes the
same public data without credentials or account-only fields.
The account page now reads a minimal authenticated self-profile summary bound to
the exact active-session lease, supplies a direct current-UID route to that same
guest view, and hides self-directed local block/allow shortcuts on that route.
The summary does not expose private activity, and the public destination remains
credential-free. Until successful real-device validation, this incremental
enhancement stays within the existing account/private-read score and adds no
weighted parity credit.

Public following and follower lists are separate anonymous signed-form reads.
Following uses `POST https://tiebac.baidu.com/c/u/follow/followList`; followers
uses `POST https://tiebac.baidu.com/c/u/fans/page`. Before signing, either form
contains exactly `_client_version=22.6.5.1`, one-based `pn`, and the positive
target `uid`; the final form adds only `sign`, the compatibility MD5 over the
sorted fields and fixed Tieba suffix. There is no query or protobuf common block,
and the requests contain no BDUSS, STOKEN, Cookie, Authorization, CUID, IMEI,
screen, network, or other device field. Each response is limited to 1 MiB. Since
neither response echoes the target UID, Core labels the result with the requested
UID and relation kind, and the App validates that request context before
accepting a page.

The two endpoints have different pagination behavior. Following validates the
returned page, nonnegative total, bounded list, and binary `has_more`; an observed
full 20-row page can require one bounded next-page probe even when `has_more=0`,
while an empty page always stops. Followers validates its nested page object,
nonnegative counts, binary flags, and bounded list, then follows the server's
`has_more`; an empty page also stops. Duplicate-only or nonadvancing pages stop
local continuation without replacing prior rows. Local user filtering uses the
raw list tail for pagination, so hiding the displayed tail cannot stall loading.
The returned `follow_list_switch` and `tips_text` are retained only as opaque
metadata: observed visible and unavailable results can share the same switch, so
neither value establishes a privacy state. These public lists likewise do not
establish whether the active account follows, is followed by, or can mutate any
listed user; this public surface deliberately has no relationship write controls.

The exact active account's following page instead uses an authenticated read to
the same path. Its signed form contains BDUSS, `_client_type=2`, fixed
`_client_version=12.41.7.1`, one-based `pn`, and `sign`; it intentionally omits
target UID, STOKEN, Cookie, and device identifiers. The App binds each page to
one `userID + sessionRevision` before and after transport and never mixes it with
anonymous pages. Only known `has_concerned` values enable the local all/mutual
menu, and only exact value 2 is mutual. Missing, malformed, or unknown metadata
keeps the ordinary list and management actions but hides the filter. Empty
filtered results scan no more than five raw pages per user-approved attempt, and
unfollow/refollow changes the action override without rewriting the server's
mutual snapshot. The minimum authenticated field set and live metadata behavior
remain a physical-device validation gate, so this closes a narrow workflow gap
inside the existing private-read credit without adding a weighted point.

An independently authenticated relationship probe now powers an explicit
follow/unfollow control on another user's profile. It sends the active account
as `uid`, the profile target as `friend_uid`, `is_guest=1`, and only the existing
minimal V12 BDUSS/STOKEN common fields to the fixed HTTPS profile endpoint. The
response is accepted only when the target UID matches, `has_concerned` is `0`,
`1`, or mutual-follow `2`, the portrait token is bounded, and `anti_stat.tbs`
has the expected lowercase hexadecimal format. The portrait and `tbs` remain
inside Core and are never exposed to SwiftUI, logs, persistence, or reflection.

A changed-state action requires explicit confirmation, performs that fresh
probe, sends at most one signed HTTPS follow or unfollow form, then performs
exactly one authenticated profile readback. The acknowledgement has no target
identity and is never treated as relationship truth; the readback's actual state
is returned even when it did not reach the requested value. Identical concurrent
operations share one complete flight. A conflicting state or rotated credential
waits for that flight and performs a read only, while another target may progress
independently. Caller cancellation removes only its waiter and never turns an
already-dispatched write into an implicit retry. The App additionally binds
presentation to `userID + sessionRevision`, hides the control when signed out or
viewing the active account, and rejects late results after logout, account
switching, or same-UID reauthentication. Minimum-field server compatibility,
rate limits, expired-session behavior, and both directions remain disposable-
account validation gates, so this workflow receives only partial parity credit.

The profile action menu separately exposes Tieba's server-side interaction
restrictions for a distinct target. It does not reuse or modify the app's local
user block/allow rules. Opening the editor first performs the same authenticated
profile probe to bind the active UID, target UID, and complete session, then sends
a signed HTTPS form to `/c/u/user/getUserBlackInfo`. The permission response does
not echo either UID, so the returned `userID` and `targetUserID` remain caller-
bound context rather than server assertions. All three `perm_list` members are
required exact integer bits: `follow`, `interact`, and `chat`; the unrelated,
unverified `is_black_white` field is ignored.

Saving requires an explicit confirmation and a fresh profile/TBS preflight. The
compact JSON sent to `/c/c/user/setUserBlack` uses `0` for allowed and `1` for
blocked and contains only those three named members. A dispatched write is never
retried and is followed by exactly one raw permission readback whether its
acknowledgement succeeds, fails, or cannot be decoded. Only the exact requested
readback is success; any missing or different state becomes outcome-unknown and
the App locks further saves until an explicit reload. Equivalent operations share
one flight. Conflicting permissions or rotated credentials wait and then only
read, while different targets can proceed independently. Follow and interaction-
permission writes for the same account and target also exclude each other, with
the later operation settling through its own read. The App loads this editor only
when opened and binds every result to the initiating `userID + sessionRevision`.
Minimum-field acceptance, bit semantics, server errors, and both block/unblock
directions remain disposable-account validation gates.

Tieba's followed-forum list rejects anonymous requests. The logged-in home page
projects at most the first six entries from the same app-scoped, memory-only state
used by the current account's complete paginated list. The selected, default-off
recommendation filter builds a separate memory-only index while its page is
active. An account persona resolves that exact saved UID without changing the
App-wide active account; anonymous resolves the active account for local filtering
only. Every page checks the chosen session before and after transport, and the
result is accepted only while the exact `userID + sessionRevision`, persona, and
requested page remain current. Persona changes, account switching, logout,
same-UID credential rotation, or a forum-membership change synchronously removes
the filter snapshot; an inactive filtered surface remains empty until active.
Only an explicit server end publishes the complete forum-ID set. Empty or
duplicate-only continuations, invalid data, service failures, more than 100
pages, or more than 5,000 retained forums fail closed rather than publishing a
partial allowlist. The shared rows, page state, and lease are never persisted or
reused across an app restart or account lease. A separate bounded local pin
archive persists only positive account UID, forum ID, normalized public name, and
pin time. It projects only exact rows already loaded for that account, orders
pinned rows newest first, leaves all other rows in server order, and never requests
another page. Home and complete-list context menus pin, unpin, or explicitly copy
the forum name; stale pins create no row. They also expose a destructive inline
unfollow only after explicit confirmation of an exact loaded row. The app validates
the loaded `userID + sessionRevision` lease, performs one authoritative membership
preflight, sends at most one changed-state write, and performs at most one readback
when the result is uncertain. It never retries the write or deletes only the local
row. An authoritative change invalidates the entire old page cursor and complete
forum-ID index, reloads from page one while an eligible surface is active, and
removes only the matching account's pin. A row whose response contains a complete
positive level, bounded nonempty level name, nonnegative current experience, and
positive upgrade target shows that tuple with a progress value clamped to
`0...1`; malformed or incomplete tuples retain the legacy level/experience text
without failing the page. Inline check-in remains unavailable.
The home toolbar and account page open the same separate foreground one-click
flow, which consumes its own authoritative catalog and explicit confirmation
snapshot. The home entry is shown only for an active account with complete
credentials, and opening either entry performs no check-in write.
Opening a forum continues to use the separate, explicitly confirmed
per-forum membership and check-in workflow. Its same FRS response publishes the
level tuple only for a followed forum. A successful check-in carries the
preflight tuple until one explicit read-only refresh returns a newer value;
transport failure keeps the confirmed check-in and never dispatches another
write. Client-side lease checks prevent a
late page from being published under another local session, but successful
private-list retrieval and server-side account binding still require physical-
device validation.
The profile response may include a small public liked-forum preview. It remains
visible without credentials and is presented as a preview alongside the server's
declared total, never as a full list; an empty preview remains a valid privacy
state. A separate profile action can use the login-required `/c/f/forum/like`
read for either the current or another user. A self request keeps `uid` equal to
the active account and omits guest fields. An other-user request still keeps
`uid` equal to the active account, adds the target as `friend_uid`, and adds only
`is_guest=1`. Its pagination state is independently bound to active-account UID,
`sessionRevision`, target UID, and page, and it never populates or mutates the
global current-account followed-forum index. Duplicate-only or empty continuing
pages, invalid response context, more than 100 pages, and more than 5,000 retained
rows stop safely. The complete list is memory only and read only; successful
self/other retrieval and privacy behavior still require physical-device
validation.

The profile header keeps its existing bounded portrait preview and creates a
large-portrait presentation only after an explicit avatar tap. A bare portrait
token can derive the HTTPS `/sys/portraith/item/` resource; URL-shaped inputs
must use one of the exact legacy or current portrait hosts, one of the three
known portrait paths, and one bounded single-segment token. The raw source is
limited to 4,096 UTF-8 bytes before surrounding whitespace is removed. Its only
accepted query is the observed cache-buster `t=` followed by 1 through 20 ASCII
digits; it is stripped from the canonical result. Credentials, explicit ports,
other or repeated queries, fragments, encoded separators, and unrelated media
hosts cannot seed that derivation. If no strict large source exists, the viewer
uses the already normalized regular portrait; if neither exists, the
placeholder is noninteractive. Viewing, sharing, and Photos saving then reuse
the existing credential-free image viewer and validated original-file exporter.

A default-off local preference combines a returned public nickname and username
as `nickname(username)` across thread cards, floors, nested replies, search,
profiles, forum staff, browsing history, and local favorites. Empty or identical
values collapse to one name, and user search plus profile headers retain their
pre-existing secondary username while the option is off. Both fields come from
the response that already loads each surface; presentation creates no request.
Thread history and favorite schema v1 records store the username as an optional
additive field, so older records remain readable and simply render one name.

Local favorites are deliberately separate from browsing history and from
Tieba's account-backed collection service. Disabling or clearing history does
not remove favorites, and the UI labels them as local rather than implying
cross-device account sync. Hot-ranked threads retain the mode but not an
unstable ranking position.

Two default-off, force-on preferences are evaluated only when a thread is
opened from the local-favorites list. A disabled preference preserves the
snapshot's saved browse mode; an enabled preference can force only-thread-author
or descending mode while preserving thread identity, public metadata, and the
saved post/floor position. History, deep links, search, and ordinary thread-card
navigation do not evaluate the switches directly. The existing thread workflow
persists the effective mode to the favorite and browsing history, so later
history or ordinary openings of the same thread may resume it; deep links still
bypass stored snapshots. Disabling an override does not reconstruct an older
value. The preferences require no favorite-schema migration, account state, or
additional network request.

Saved forums can be pinned locally from an explicit context menu in either the
favorites list or its home-screen projection. Pinned forums appear first, with
the most recently pinned first; the same menu can copy the canonical public
forum name or remove the local favorite. Pinning is presentation metadata, not
a retention lock: the bounded archive still evicts by original save time, so an
old pinned forum can be displaced when the per-kind limit is reached. The
optional `pinnedAt` field remains additive within favorite schema v1, allowing
new builds to read existing archives without migration. Older builds that
support favorite schema v1 ignore the field while reading, but any successful
favorite write from such a build re-encodes schema v1 without pin metadata and
therefore clears all pins.

The home-screen recent-forum row is a projection of the same browsing-history
archive, not a second store. It shows at most the 100 newest forum records while
the archive continues to retain its normal per-kind limit. The row is expanded
for each new app session; whether the section is present is a persistent local
preference. A forum is still recorded only after valid server metadata arrives,
and history remains available without an account.

Home-entry customization is a closed local preference, not a new feed. The
default remains the ordinary home page, with optional starts limited to the
existing personalized discovery, post ranking, hot topics, inbox, local
favorites, and browsing history. The choice is snapshotted once at process
launch, so changing it cannot redirect an active session; unknown stored values
fall back to home. A cold-start forum, thread, or user link is appended above
that initial page and remains the visible destination. The independent discovery
switch defaults on and removes only the home section containing ranking, topic,
and explicit paste-link shortcuts. It does not disable direct personalized-
discovery startup, those other destinations, the strict URL router, or any
network path.

Forum and thread share actions emit canonical `https://tieba.baidu.com` URLs
through the system share sheet. Thread copying additionally carries an exact
`see_lz=0` or `see_lz=1` value so the active author filter can round-trip. URL
construction uses structured components rather than interpolating unescaped
forum names.

The content parser handles in-app rich links, explicit clipboard pastes, and the
forum, thread, and user subset of the registered app-owned `tieba-plus-plus`
scheme. It requires an exact allowlisted Tieba host, standard ports, exact paths,
nonempty bounded forum names, positive 64-bit IDs, and unambiguous supported
state. Legacy `wapp.baidu.com` and `tiebac.baidu.com` `/f`, `/p/<tid>`, and
`/mo/q/m` routes accept exactly one forum (`kw` or `word`) or thread (`kz`)
identity and normalize it to the same native target; mixed, duplicate, empty,
or invalid identities fail closed. Valid `see_lz` and post anchors are preserved
when opening a thread. A separate strict
app-navigation parser accepts only canonical `tieba-plus-plus://search`,
`tieba-plus-plus://history`, `tieba-plus-plus://favorite`,
`tieba-plus-plus://check-in`, and `tieba-plus-plus://notifications/0|1` URLs. As
in TiebaLite, `favorite` opens the active account's server-side favorites rather
than the app's local archive, notification values `0` and `1` select replies and
mentions respectively, and `check-in` opens only the existing foreground page
whose explicit confirmation remains required before any write. These routes
append above the configured startup destination, select no account, carry no
data, and perform no write. The empty search route stays idle, focuses the
search field on iOS 18 or later, and projects the same local recent-search archive
on every supported OS instead of issuing an empty request or showing an input
error. Other destination pages retain their ordinary signed-out or incomplete-
credential state. Rich content and the explicit clipboard control cannot consume
app-only routes, and an unrecognized app-owned URL is rejected instead of being
handed to the system to reopen this app.

On iOS 16 or later, the static Home Screen quick-action order is `一键签到`,
`我的收藏`, `搜索`, then `我的消息`. Those entries resolve only to the existing
foreground batch-check-in page, account cloud favorites, empty search landing,
and replies inbox. The scene bridge handles both a cold launch from connection
options and a warm invocation delivered to the active scene. It resets the old
navigation subtree to one validated, uniquely identified destination, so an
internal Picker, child `NavigationLink`, or child-owned modal cannot swallow a
repeated shortcut; Back returns Home. An already-topmost check-in page is
preserved instead, because reconstructing it would intentionally stop foreground
work. Shared and Root-owned login, gallery, report, alert, and in-app Safari
presentations are dismissed before routing.
Every unknown shortcut type and every shortcut carrying an additional payload is
rejected rather than interpreting user data. A shortcut selects no account:
signed-out and incomplete-session states remain owned by the destination page.

The check-in shortcut is navigation only. Opening the page may read the existing
authoritative forum catalog, but no write is dispatched until the same in-page
snapshot confirmation described below. It does not add background, scheduled,
or automatic check-in. The four shortcuts reuse existing routes and services
and add no endpoint or weighted parity point.
The static menu is expected only when the IPA is installed as its own SideStore
app. A LiveContainer guest is not independently registered with SpringBoard; its
documented Home Screen entry is a LiveContainer Launch App Shortcut. Therefore
the guest manifest menu is not counted as available on that icon, and the custom
scene delegate must be validated separately inside LiveContainer before release.

Cleartext official links are accepted only as route text; the destination is
loaded through the existing HTTPS-only API client. External HTTPS links default
to the user's system browser and can instead use a system-managed in-app Safari
view; external HTTP links remain system actions in both modes. Link credentials
are rejected, and unchanged external URLs retain their input query and fragment
rather than being rebuilt. The Safari view does not reuse the login Web view or
expose its page, Cookie state, or navigation history to the app. The app does not
register Baidu's official scheme, automatically inspect the clipboard, claim
Universal Links without Baidu's AASA authorization, or fabricate a browsing-
history snapshot before the linked thread has loaded successfully.
The Home paste action accepts at most eight text values totaling 64 KiB through
the system `PasteButton`; raw clipboard text is neither retained nor persisted.
After that explicit action, a forum preview requests FRS page one with `rn=1`
and a thread preview requests PB page one with `rn=2` and nested replies
disabled. Those calls carry no account credentials or hardware identifier
fields, touch no history or write service, and the UI deliberately avoids
remote-avatar loading. Only sanitized, bounded display text crosses into the
preview model.
User app links remain local generic cards. A second explicit action consumes the
original immutable target for navigation, while closing, replacement, scene
inactivity, external URL routing, and Home Screen quick actions invalidate the
pending generation so a late response cannot recreate or retarget the sheet.
The About page reads only local display/version/build strings and exposes one
exact, credential-free HTTPS source-repository URL after an explicit tap. That
destination is code-defined rather than constructed from Bundle, account, or
remote data, and follows the same external-Web preference and Safari isolation.

Forum introductions, rule documents, and moderator teams use independent
credential-free protobuf endpoints. Moderator role names are treated as an
open server-defined set instead of being hard-coded to only large and small
moderators. A forum without published rules is a normal empty state rather than
an API failure.

Forum channels are accepted only from FRS tabs marked as general type 15.
Each channel exposes at most 12 valid entries from its server-provided sort
menu, preserving the first occurrence of every nonnegative raw ID and trimming
titles to 40 characters. Unknown nonnegative IDs remain usable instead of being
collapsed into the two currently observed values. A channel defaults to its
first advertised entry; a missing menu sends the protocol's `-1` sentinel.
`GeneralTabList` requests use that channel-specific raw sort value and advance
with both the page number and the final valid thread ID. Missing, duplicate, or
stalled cursors terminate pagination instead of repeatedly loading one page.

Thread-list mapping preserves the public topic kind, first-post ID, server state
flags, author portrait, and available read-only counters through the application
layer. Bare portraits from ordinary topic responses use the existing portrait
derivation, while URL-shaped search portraits pass the same HTTPS media
normalization used by other avatars. Per-forum search binds the card avatar to
the first exact-TID thread context (matching `mainPost`, then matching `postInfo`)
that supplies the card's author name and UID; a matched reply or comment author
remains separate. History and local favorites preserve that normalized URL. If
it is absent after a thread
loads, a floor portrait may fill it only when the topic has a positive author UID
and the post belongs to the exact thread, is marked as the thread author, and
matches that UID; both models must remain locally visible. One card renders this
metadata across forum/channel lists, hot-topic details, global search, and public
user themes without reordering or filtering the server result set. Only an ordinary,
locally visible row whose surface displays its author constructs the 24-point
avatar view. Pinned rows, filtered placeholders, hidden rows, and profile-owned
thread lists deliberately issue no author-avatar request. Ordinary rows load at
most three image thumbnails or one video cover. The expanded video surface is
never autoplaying: a playable fragment remains cover-only, or a local placeholder
when no cover exists, until an explicit Play tap initializes the one shared
player. A fragment with only a safe cover preserves the prior static preview;
a completely unusable fragment cannot hide later valid images. Every requested
image still passes the existing HTTPS URL normalization,
credential-free downloader, redirect policy, transfer-time byte limit, and pixel
downsampling. Automatic 720-pixel previews stop at 16 MiB; higher-resolution
explicit image views retain the 80 MiB ceiling.
A third, opt-in data-saving policy carries TiebaLite's smart no-image workflow
into iOS without changing the existing automatic default. One app-level path
monitor classifies only transient availability, cost, and Low Data Mode state.
An available, non-expensive, non-constrained path can start an automatic
preview with request-level cellular, expensive, and constrained access denied;
all other states read the memory cache and expose the existing exact-request
load control. An explicit tap remains unrestricted and stays authorized across
later path changes. Avatars, galleries, media playback, export, page data, and
all nonmedia requests remain outside this policy.
An independent preview-quality setting retains the separately normalized
standard, high-definition, dynamic, and original candidates already carried by
the anonymous response. Standard remains the default and preserves the prior URL
choice. The opt-in high-definition mode selects that candidate when available,
then the dynamic candidate, and otherwise falls back to the standard candidate.
It applies dynamically to post bodies, thread cards, and per-forum search
without changing whether a
request is automatic, economical, or user initiated. Gallery, sharing, and
saving retain the original-then-dynamic-then-high-definition-then-standard
chain and do not consult the preview preference. Avatars, video covers, and
single-source hot-topic images are also unchanged.

Downloaded bytes, rather than a URL suffix, MIME label, or `dynamic` field,
decide whether an image animates. A real multi-frame GIF, WebP, or HEIC/HEIF
sequence is downsampled frame by frame off the main actor. The decoder accepts
at most 500 frame metadata entries, limits each decoded frame to 16 MiB, and
  shares a generation-aware frame cache capped at 64 MiB and 1,000 entries across
  the app. It keeps only the poster and current frame strongly; unsupported,
  malformed, single-frame, or
over-budget inputs render a normal poster instead of failing the image. Per-frame
timing is preserved with a 100 ms fallback for invalid or pathologically short
delays. Animation does not create a new request identity or bypass the existing
  network policy. Views removed from presentation, inactive scenes, Reduce
  Motion, and inactive gallery neighbors stop playback; only the visible gallery
  page can own its player.
An independent persistent compact mode replaces those thread-list previews and
per-forum search image strips with noninteractive media summaries. Its collapsed
presentation retains only a media type or full image count and never constructs
a remote preview view, so it creates no preview request. It does not alter post
bodies, hot-topic images, avatars, gallery/export paths, playback, page data, or
the separate automatic, data-saving, or tap-to-load policy used when previews
are expanded.
A separate default-on dark-appearance control applies a 0.4 color multiplier
only to successfully rendered content images in thread cards, post
bodies, per-forum search, and hot topics. Video covers, avatars, galleries,
placeholders, and compact summaries remain unchanged. The control is a pure
rendering decision and does not enter URL normalization, fetch policy, reload
identity, transfer deduplication, decoding, or cache keys.

TiebaLite exposes fixed themes, dynamic Android colors, and arbitrary custom
colors. The iOS adaptation keeps appearance and accent independent, preserves
five curated presets, and accepts one opaque custom sRGB base color. That base
is never used directly across every appearance: a bounded, deterministic search
derives separate light, dark, high-contrast-light, and high-contrast-dark values
that retain the existing surface and foreground contrast contract. Preset raw
values and their exact four palettes remain unchanged. Custom editing stays in
one transient draft; only Apply stores the canonical value and selects it, while
Cancel, interactive dismissal, and restoring the opening color write nothing.
Switching to a preset retains the last valid custom base for later editing.

Wallpaper and dynamic color extraction, translucent themes, Android toolbar
backgrounds, and status-bar text controls are not imported. Root SwiftUI tint
covers native controls and tint shape styles, while the matching environment
supplies the concrete color needed by attributed strings, comment highlights,
badges, and progress fills. System Safari, Web login, share sheets, semantic
warning colors, and immersive media controls remain system-managed or explicitly
white.

Tieba++ now clears both memory and persistent image caches. The hardened media
transport remains ephemeral with system URL caching disabled; persistence is an
explicit application layer used only after an HTTPS image response fetched without
account Cookie or Authorization headers has
passed the existing ImageIO validation. Exact request URLs are mapped to SHA-256
directory names. Versioned metadata stores only a random entry identifier,
payload byte count and digest, and creation/access timestamps: no URL, query,
header, MIME type, suggested filename, cookie, credential, or account response is
written. URLs with fragments or more than 8 KiB are never persisted. Finite cache
times are normalized to milliseconds and clamped on clock rollback, then written
back after a hit so future timestamps cannot extend the seven-day lifetime.

The disk layer is capped at 256 MiB and 1,024 entries with a seven-day maximum
lifetime and persisted LRU access times. Every hit rechecks a regular, non-symlink
payload, exact byte count, digest, and the active 16 MiB preview or 80 MiB original
bound, then creates an independent temporary copy so clearing or eviction cannot
invalidate an active animation, share sheet, or Photos save. Staging directories
publish atomically. A generation token and bounded per-key publication sequence reject
pre-clear and out-of-order late stores; publication is selected by each live
repository waiter rather than by the shared transfer task.

Explicit clearing advances both decoded-cache and disk-cache generations without
cancelling active transfers or blanking displayed images. A waiter that started
before the clear can still receive its image but cannot repopulate the old
generation; a waiter that starts afterward may share that same transfer and
publish for the new generation. A repository-level barrier bypasses all memory
and disk reads or publications while the disk actor is clearing, then evicts
decoded state again before the operation returns. Active independent leases are
released when
their animation or system consumer finishes, so the settings value and clear
result describe logical cached entries rather than immediately reclaimed physical
bytes. Later animation frames use a separate process-wide memory cache capped at
64 MiB and 1,000 entries, costed by `bytesPerRow * height`.

The global forum-sort preference applies when a forum has no remembered choice;
changing a forum's picker stores a normalized, bounded per-forum override.
Channel-menu choices are remembered separately only while the current forum
screen is alive, are revalidated when a menu changes, and never overwrite the
global or per-forum topic-sort preference.

The forum primary-action preference preserves TiebaLite's bounded
`post`/`refresh`/`back_to_top`/`hide` values while presenting the selected action
as a native toolbar control rather than an Android-style FAB. It is a nonsecret,
local enum; changing it starts no request and unknown values resolve to publish.
The action rechecks current page capability when pressed. Refresh reuses the
existing generation-guarded transaction, and returning to the stable header
anchor does not reload, mutate pagination, or install a global scroll event.
The More menu retains refresh, return to top, canonical sharing, and, whenever
the loaded forum has a valid creation target, publishing. Choosing hidden
therefore removes only the primary shortcut and never removes the underlying
available actions.

TiebaLite implements text sizing as a fixed app-wide Android font-scale
override. Tieba++ instead stores a relative adjustment from two steps smaller
through three steps larger, with following the system as the default. It shifts
the current iOS Dynamic Type category within the platform's 12 supported
categories and clamps the result at either end, so the system setting remains
the baseline.
The resolved category updates semantic fonts and scale-aware controls throughout
the app's SwiftUI hierarchy immediately; Safari, share sheets, and other system
UI remain system-managed. Unknown stored values normalize to following the system.
Appearance, sort, and text-size adjustment values are nonsecret local enums.
The followed-forum layout setting adapts TiebaLite's `listSingle` choice into an
iOS-native adaptive grid or single column. The home projection and complete list
both resolve, and at non-accessibility Dynamic Type sizes explicitly toggle, the
same stored enum, while accessibility Dynamic Type sizes force one effective
column without overwriting the user's preference. Changing layout
does not explicitly refresh, start image downloads, or mutate the account-bound
followed-forum snapshot. The complete list requests another page only after the
user selects its explicit load-more control; card appearance and layout reflow
never authorize account traffic.
No-history mode updates the recording flag inside the existing versioned
history archive, so it does not create a competing source of truth or delete
favorites. The transient thread reading-mode menu keeps standard, pure, and
immersive reading explicit. Pure reading removes author chrome, filter
placeholders, and nested-reply entry points without changing post data, making a
request, or changing the persisted sort and only-author options. Immersive
reading deliberately composes that same presentation with TiebaLite's
only-thread-author behavior. If the filter is off, an immutable thread/options
confirmation first discloses that the command returns to page one and that the
filter remains enabled after exit; only confirmation clears unresolved opening
anchors and performs one existing anonymous page-one reload while preserving
sort. If only-author is already enabled, entry is local-only, sends no request,
and does not deliberately return to page one. Exiting changes only the transient
presentation. The existing history/favorite option path persists only-author,
but never the reading mode. An external filter disable downgrades a stale
immersive presentation to pure rather than presenting a false state. The independent
hide-reply-entry preference is persistent,
defaults off, and removes the topic, floor, nested-reply, and inbox quick-reply
controls while retaining reply content, ordinary notification navigation,
text selection/copying, agreement controls, drafts, and any composer that is
already open. Changing it is local-only and starts no network request. Copy
actions for a visible topic or ordinary floor, an inline nested-reply preview,
or a parent or child row on the full nested-reply page capture the currently
decoded public-text projection in one transient, immutable panel. System text
selection can copy a substring; Copy All writes that exact snapshot and closes
the panel, while closing alone writes nothing. The projection uses fixed
`[图片]`, `[视频]`, and `[语音]` boundary markers and never synthesizes media URLs,
credentials, account responses, locally filtered content, or replies outside
the selected item. A content-filter change revokes an open selection snapshot
before the affected page reloads.

The independent composer-risk preference is a default-on local Boolean. An
editable reply or new-topic composer restores its draft before presenting the
notice; continuing only unlocks editing, while returning preserves the draft.
For replies only, the third choice reproduces the full undocumented
`com.baidu.tieba` PB compatibility template observed in TiebaLite from the
validated target. Topic replies carry the TID; floor replies carry the TID and
floor PID; nested replies carry only the parent PID and explicitly require the
user to reselect the child in the receiving app. The template also retains
TiebaLite's opaque fixed `obj_source`, `obj_param2`, `wise_sample_id`, `refer`,
and `fr` values; they are not credentials, but their iOS routing and telemetry
meaning is unverified. It bypasses the internal content router by code
definition, reads no account or draft data, starts no App network request, and
has no automatic retry or Web fallback. The composer remains available with its
stored draft for both accepted and rejected system dispatch. A public
custom-scheme handler and its active account cannot be authenticated, so the
system result is never proof of an official app, correct login, reply position,
or submission. New-topic creation deliberately omits this reply-only route
rather than reproducing an invalid `tid=0` behavior. The notice remains advisory
and never authorizes a request. Final send or publish confirmation captures the
exact target and text in an immutable, one-use snapshot; any edit, confirmation
dismissal, account-session change, or page exit invalidates that pending
snapshot.

Local content filtering covers ordinary and channel forum thread lists, global
and per-forum search results, public-profile activity, post floors, nested
replies, shared-thread origin cards, and the foreground inbox. Keyword rules use
case-sensitive literal substring matching or a bounded regular-expression
subset compiled to a Thompson NFA. The latter supports grouping, alternation,
character classes, anchors, bounded and unbounded quantifiers, and the documented
character-class escapes without captures, backreferences, lookaround, inline
code, or a backtracking engine. User rules match an exact positive UID or exact
name. An allow rule takes precedence only within the same matching domain and
inspected field: a user allow rule does not override a blocked keyword, and a
keyword allowed in one field does not override a blocked match in another.
Blocked content can remain as a placeholder or be fully hidden. In per-forum
search, the matched entity and each displayed topic or parent-floor context are
filtered independently. A blocked context can be replaced or omitted without
removing an otherwise visible match; a blocked match suppresses the complete
row so none of its contexts can reveal it. The independent video-topic switch
applies to thread rows; global search and the matched per-forum entity preserve
the server's public video marker even when no usable cover URL survives media
normalization.
Filtering annotates the raw models instead of removing them, so page and cursor
progression still uses every server result even when an entire visible page is
hidden. Inaccessible raw-tail sentinels can therefore advance through hidden
global-search, per-forum-search, and public-profile pages without exposing their
content. The private inbox uses the same raw-state rule but, after a filter
change, replaces automatic continuation with an explicit user action and does
not refetch loaded pages. Regex rules are capped at 32, compile to at most 256
immutable NFA states, and inspect at most the first 8,192 Unicode scalars of one
field. All regex allow and block rules for that field share one prepared scalar
view, one reusable workspace, and a 200,000-work-unit budget that charges both
NFA state visits and character-class member checks. Budget exhaustion fails open
for the entire field; truncation never fabricates an end anchor or
bypasses raw pagination. A successfully decoded archive and its derived indexes
are cached for read-only page requests, avoiding repeated page-by-page
compilation. Every app-owned mutation first re-reads and validates the current
disk bytes, so a stale cache cannot overwrite a malformed, future-version, or
newer valid archive.

Each authenticated milestone remains gated on protocol tests, credential
isolation, and real-device validation. Forum follow/unfollow, check-in, and
content approval bind a fresh FRS response to the current account and forum
before a changed-state write, make its short-lived `tbs` available to at most
that write inside the authenticated client, and never retry an uncertain write.
Content approval uses exact target identities: `thread(firstPostID)` for the
canonical topic, `post(postID)` for an ordinary floor, and
`subpost(parentPostID, subpostID)` for a nested reply. The write endpoint maps
those targets to `obj_type=3`, `obj_type=1`, and `obj_type=2` respectively; all
three use the target object ID as `post_id`, the owning thread ID, and a
nonpersistent random Galaxy2 CUID with the required Helios checksum.

Authenticated PB Page and PB Floor reads overlay account-scoped
`Agree.has_agree` onto the exact anonymous page request instead of issuing one
read per row. A page is accepted only for its expected account, forum, thread,
and complete target identity; nested replies additionally remain bound to their
parent post. Duplicate targets are rejected, unrelated returned targets are
ignored, and an expected target omitted by the response becomes an explicit
read failure rather than inheriting another row's state. These overlays are
reads only: they never turn page loading or refresh into a batch write.

The authenticated core serializes content-approval writes per account even when
they address different targets. Identical in-flight writes for one target share
their result; a conflicting request waits for the active write and performs a
read-only reconciliation instead of queuing another write. A transport outcome
that may have reached the server receives at most one readback and is never
resent. At the application boundary, the account UID plus `sessionRevision`
forms the lease for every read and write, so switching accounts or logging the
same UID in again discards late state from the older session. Check-in
additionally requires authoritative per-forum sign state and rejects an
unfollowed forum. All writes require explicit user confirmation and perform no
write when the server already reports the requested state. Acknowledging or
disabling the composer-entry notice is never this write authorization. Anonymous
browsing must continue to work without creating, reading, or storing an account
session.

Foreground batch check-in uses the official forum catalog and batch endpoint.
The home toolbar and account page open the same flow, and merely entering it
performs catalog reads only; user confirmation remains the write-authorization
boundary. The client
normalizes and binds the ordered official-batch subset shown for confirmation,
then refreshes the official catalog immediately before dispatch and sends only
its intersection with the fresh eligible set. Newly eligible forums are not
silently added; official rejections and confirmed targets that drop out do not
become single-forum writes. If the batch may have reached the server but its
response is missing, malformed, oversized, or incomplete, the exact dispatched
targets enter an outcome-unknown path. The App performs only authoritative
per-forum reads, reports unresolved targets as unconfirmed, and does not retry
the batch or degrade to individual writes. A local policy may skip the official
batch and process every confirmed target individually. It may also continue to a
later target after readback proves that a failed individual request left the
current forum unsigned, but it never retries that target. A malformed or
unconfirmed result, cancellation, or account-lease change always stops.
The policy and its slow random or fixed 2-second pacing mode are frozen into the
same explicit confirmation snapshot. The flow remains foreground-only,
explicitly initiated, memory-only, and subject to real-device validation; it
does not implement TiebaLite's background or automatic sign-in.

Text and fixed-catalog classic-emoticon replies use HTTPS protobuf command `309731` with client version
`12.35.1.0`. Topic replies, ordinary-floor replies, and replies to a specific
nested reply share one endpoint but have distinct `post_from`, parent, quoted,
and subpost fields. A nested reply alone receives the protocol-owned `reply`
marker, built from the freshly read target identity. The composer may insert one
of 50 fixed classic `#(name)` tokens at the current UTF-16 selection. A
fail-closed tokenizer rejects unknown, malformed, nested, image, `reply`, and
all other user-supplied rich-content markers. The minimal request contains BDUSS, STOKEN, fresh TBS,
fixed client metadata, and the required business fields, but no IMEI, Android
ID, OAID, ZID, installation history, screen, location, or advertising identifier.
If a real device proves those omitted fingerprint fields mandatory, the feature
remains gated rather than adopting an Android device-identity chain.

The canonical first post remains reserved as the topic target: replying to that
parent uses `thread(firstPostID)`, and `post(firstPostID)` is invalid. Its child
replies are still independent nested targets and use
`subpost(parentPostID: firstPostID, subpostID: ...)`.

Before a reply write, Core binds the exact account, forum, thread, first floor,
parent, and optional child through authenticated PB Page/Floor responses. One
account has one reply-write tail; an identical submission UUID shares its owner,
while a different payload reusing that UUID is rejected. Cancellation before
dispatch guarantees zero write. After dispatch, the owner continues even if its
caller or view disappears. A valid returned PID is read exactly once: a matching
author, structured text/emoticon body, parent, and marker confirms success; a genuinely absent PID becomes
accepted-awaiting-visibility; any visible mismatch or lost receipt becomes an
unknown outcome. Neither case resends the write.

The App binds each composer to `userID + sessionRevision` and stores its exact
draft by account, forum, thread, first post, and reply target. The bounded atomic
archive contains no credential, TBS, or author metadata and is excluded from
backup with iOS file protection. A non-sendable submission marker must be
persisted before dispatch; a crash or indeterminate failure after that boundary
reopens as unknown rather than editable. Confirmed success clears the draft only
after a terminal receipt is persisted. Accepted, unknown, and challenge states
remain non-sendable across navigation and restart; a challenge for one session
can be unlocked only by an explicit new login. Composer navigation uses the
native stack without a custom back gesture, including cancellation of an
interactive edge swipe.

Text and fixed-catalog classic-emoticon new topics use one signed HTTPS form at `/c/c/thread/add` after a
fresh authenticated FRS read binds the active UID, positive forum ID, canonical
forum name, trusted account display name, and valid TBS. The optional title is
limited to 31 Swift characters and 124 UTF-8 bytes; the body uses the same
10,000-character and 32 KiB wire-text bounds as replies. Titles reject control
characters; bodies preserve line breaks and tabs while rejecting other
unsupported controls. Titles reject all markers; bodies accept only the same
fixed classic-emoticon catalog and reject every other Tieba rich-content marker. The minimal form
follows the observed
TiebaLite contract but deliberately omits Android hardware, advertising,
installation, screen, network, and telemetry identifiers; every redirect is
rejected.

One account has one new-topic write tail. An identical submission UUID shares
its owner, conflicting reuse is rejected, and cancellation before dispatch
performs no write. After dispatch, transport loss, malformed receipts, or
mismatched readback become an unknown outcome and are never resent. A positive
TID/PID receipt is confirmed only when an authenticated first-floor readback
matches the account, forum, thread, author, explicit title when supplied, and
exact structured text/emoticon body. Temporary first-floor absence remains
accepted-awaiting-visibility. The App persists a non-sendable marker before the
write, isolates drafts by account and forum, locks challenge and unknown states,
and allows an untitled topic's server-generated display title only after all
other proof matches. Confirmed creation remains as a bounded local tombstone
across restart until the user explicitly starts another topic in that forum, so
a crash between persistence and navigation cannot reopen the old body as
sendable. Apart from the current-main bounded static-image workflow, voice and
other rich-media topic creation remain unsupported.

Search categories load independently so one endpoint failure does not discard
another category's results. User search uses the credential-free Web endpoint,
accepts the server's object/array result variants and 64-bit user identifiers,
and opens the same anonymous public profile workflow used by author rows.
Online suggestions are a separate, explicitly enabled pre-submission path. The
switch defaults off and enabling it does not send text already in the field;
only a later edit that remains valid for 500 milliseconds can issue a request.
That minimal protobuf request contains the bounded public keyword and fixed
global-search discriminator, but no `CommonReq`, account credential, cookie, or
device identifier. Suggestions are never cached, logged, or added to local
history; only an explicit suggestion tap or ordinary search submission records
the final term. Leaving the home flow, backgrounding the app, or disabling the
setting cancels and clears the current suggestion state, although cancellation
cannot retract a request that has already reached the server.
Global post search defaults to newest and keeps its newest/oldest/relevance
selection across first-page retries, refreshes, and pagination. Its wire values
are intentionally modeled separately from per-forum search because the two Web
endpoints assign different values to the same user-facing sort names.
Global search history is a separate local-only archive capped at 20 entries.
The home screen shows the six most recent terms by default, can expand the full
list, and records searches submitted again from the results screen. It never
shares storage with the per-forum history domain.

Per-forum search uses the same credential-free Web transport but keeps its
TiebaLite-compatible request contract separate from global topic search. Topic,
floor-reply, and nested-reply matches have distinct identities so pagination
does not collapse valid results from the same thread. Floor replies reopen the
thread at the matched post ID; nested replies use the comment-anchor endpoint.
Search history is local-only, versioned, and isolated by normalized forum name.

Hot-topic discovery uses credential-free Web endpoints and treats topic IDs,
thread IDs, and pagination cursors as 64-bit values. Detail refresh preserves
the prior page and cursor on failure; duplicate-only pages terminate pagination
instead of repeatedly requesting the same feed. Login-related fields returned
incidentally by the public detail response are ignored.

The anonymous hot-thread ranking is a separate protobuf endpoint. Its initial
`all` request returns one complete ranking snapshot and an opaque server-defined
category menu; category requests replace that snapshot and have no page, size,
cursor, or load-more fields. Category names stay bound to the exact codes from
the same server records even when a code's spelling appears unrelated to its
title. The app synthesizes only the visible total-list tab, limits selections to
the current advertised menu, and refreshes the selected category without
attaching an account or device identifier. The same initial `all` response also
supplies a bounded hot-topic preview above the post ranking. Only a successful
total-list response may replace that preview; category responses retain it.
Selecting a preview item opens the existing topic detail flow, while displaying
the preview itself performs no additional request.

Post pages expose an origin-thread object for both ordinary and shared topics,
so the app treats it as a share only when `is_share_thread == 1` and the origin
has a positive, distinct thread ID. Pagination may omit the repeated origin
object; a loaded card remains until a replacing first-page response says it is
absent. Opening the origin reuses the normal anonymous thread workflow.

Explore's default personalized channel uses HTTPS protobuf command `309264`.
The minimal request contains client type `2`, endpoint-compatible version
`12.52.1.0`, load type, one-based page, target count `11`, two public mode flags,
and one ordinary UUID in `CommonReq.cuid`. Live field-deletion probes established that
omitting only this UUID returns a successful but empty response, while adding it
returns real recommendations without Cookie, account ID, signature, client ID,
IMEI, OAID, Android ID, IDFV, location, screen, model, or brand data. The app
generates the UUID independently, stores it only in local preferences, and reuses
it across launches so refresh and pagination remain one recommendation session.
It is not hardware- or account-derived. Current `main` also offers an independent
account persona for every saved full session. That path follows TiebaLite's v12
shape by adding the selected session's BDUSS/STOKEN in `CommonReq`, a top-level
`stoken`, and the selected UID in `client_user_token`; Cookie contains only
`ka=open`, and account credentials never enter the URL. The App-wide active
account is not changed. Anonymous remains the default and retains the proven
credential-free contract. The same install UUID is intentionally reused across
personas to match TiebaLite's device-level identity behavior, so this is not an
anti-correlation boundary. Account-mode ranking behavior still needs a
disposable-account physical-device comparison before parity credit increases.

The response has no authoritative
`has_more`; any nonempty raw page permits one continuation, while an empty page
stops. After refresh preserves older rows and resets the server page number,
duplicate-only pages may traverse the highest page reached before that refresh.
Beyond that frontier, one additional duplicate-only page is allowed to advance
past overlap; a second consecutive duplicate-only page stops. When the
default-off followed-forum option is selected, the app first waits for an exact
complete index: an account persona uses that selected session, while anonymous
uses the current active account only for this local filter. It then matches
returned threads locally by stable forum ID; no forum allowlist enters the
recommendation request. Waiting, signed-out, empty, or failed indexes issue no
recommendation request and never fall open. One explicit load action may scan at
most five pages whose mapped threads are all removed by that local followed-forum
filter before presenting an explicit continue action. Independently, it may cross
at most five consecutive nonempty raw pages whose entries all fail UI mapping
before requiring another explicit continuation. Raw page and item progress remain
independent from visible local filtering. Ads, live cards, invalid identities,
and duplicate threads are discarded before UI mapping. Refresh prepends new
unique items, the retained window is bounded, and local filtering never replaces
the raw-page nonempty decision used for continuation.
Recommendation reasons are retained as bounded `(id, title, opaque extra)`
records. Current `main` exposes the explicit selection only for account-persona
rows carrying at least one valid reason; anonymous rows never fall back to the
active account for a server write. The submission preserves server reason order,
binds the exact thread and forum IDs plus the feedback-entry click timestamp, and
sends one signed HTTPS form to `/c/c/excellent/submitDislike` with full BDUSS/STOKEN,
`dislike_from=homepage`, and the same random recommendation CUID used by the
selected feed. Both read and feedback resolve the explicitly selected UID rather
than the App-wide active account. The CUID is independently generated, not
hardware- or account-derived, but its reuse allows Tieba to associate personas.

For one account and thread, equivalent in-flight submissions share one request
and a different payload is rejected instead of queued. Explicit success hides
the row, while a known server rejection retains it. Transport loss or a malformed
acknowledgement becomes outcome unknown, hides the row from the current in-memory
feed, and is never retried. Persona changes and account-session revision changes
cancel caller work before dispatch and suppress stale result publication, but do
not claim to retract a write that may already have been dispatched. Live
minimum-field behavior,
reason encoding, acknowledgement
semantics, and future-feed effects remain disposable-account and physical-device
validation gates.

Anonymous poll cards remain read-only. Current post responses place an ordinary
thread's poll in its mirrored `origin_thread_info`, while that same field belongs
to the original topic when the outer thread is a share. The mapper keeps those
owners distinct, prefers an authoritative direct poll when present, and uses the
ordinary thread's mirror as a compatibility fallback.
Percentages use the server's total option-vote count, with a sanitized option-sum
fallback for missing totals; zero and inconsistent totals cannot produce an
invalid or oversized progress bar. This anonymous model never authorizes a vote
and never receives account credentials.

When a complete account session is active, the App may overlay a separate
authenticated PB read that binds the exact account UID, forum ID, thread ID,
positive unique option IDs, single- or multiple-choice mode, selected IDs, and
open/closed state. A vote is eligible only when this authoritative state is open,
the account has not voted, and every selected real option ID belongs to the poll
with legal cardinality. After explicit confirmation, the complete credential may
send the minimum-field HTTPS PB command `309006` at most once without hardware,
installation, advertising, location, or screen identifiers. An identical
canonical selection for the same resource and credential shares the complete
flight. A conflicting selection or rotated credential waits for that flight and
then performs only an authoritative read. Every dispatched write, regardless of
its acknowledgement outcome, is followed by exactly one authenticated readback;
uncertain failures never retry the vote. The App checks the initiating
`userID + sessionRevision` lease around the operation and discards late state.
Successful real-account voting remains a disposable-account validation gate.

Post and nested-reply headers preserve the public author context already present
in anonymous responses: the author's level in that forum, bounded forum-moderator
role, server-supplied IP location, and `diff_agree_num` as the displayed net
approval score. Moderator roles normalize only recognized manager and assistant
wire values; a flagged but empty or unknown value becomes the generic `吧务`
label. The raw role string and arbitrary badge images never enter the UI. Missing
or malformed values collapse to a quiet empty state instead of creating a
control. These values are public response snapshots. With a validated active
account, the canonical first floor and ordinary floor headers can replace that
snapshot with an authenticated approval control; a full nested-reply page does
the same for its parent floor and each returned child. Signed-out, pure-reading,
and immersive-reading presentations remain read only, and no approval control
exposes moderation actions.

Nested replies preserve every server content fragment, including both direct
leading mentions and the legacy `reply + mention + colon` form. Positive mention
user IDs become strictly internal profile links in thread and nested-reply
content; invalid IDs remain styled text, and ordinary HTTPS links retain their
existing system behavior.

Post pages opt into the same anonymous response's embedded nested replies with
`with_floor=1`, `floor_sort_type=1`, and `floor_rn=4`. The app preserves the
server's agree-ranked order, rejects nonpositive or mismatched identifiers,
deduplicates by first occurrence, and renders at most four text-only previews per
floor. Preview rows do not fetch avatars or media and do not carry active links;
images, video, and voice use fixed textual markers. Each child receives its own
local-filter annotation without changing the parent floor, raw count, or post
pagination. Fully hidden children disappear, but the full-reply entry remains
available whenever the server declares replies. Pure-reading and
immersive-reading modes hide the entire preview surface without triggering
another request. Inline preview children remain read only even for a signed-in
account and are deliberately excluded from the active approval overlay; opening
the full nested-reply page is
required before a child can expose an approval action.

Opening a preview first uses the comment-anchor field so the matching reply can
be centered after load. Once that response resolves the enclosing parent post,
later pages switch to ordinary parent-post pagination; refresh deliberately uses
the comment anchor again. This avoids repeating an `spid` anchor for unrelated
continuation pages while retaining deterministic entry from a preview.

The complete nested-reply page renders its parent floor through a dedicated
context model that cannot retain or recursively display the inline preview list.
Both parent and child content use the same local-filter snapshot and the normal
rich-content, media, internal-link, profile, and copy boundaries. The page
rejects responses whose thread or parent identity differs from the request and
drops nonpositive, cross-context, or duplicate child IDs before they reach the
list. When that validated page is pushed independently, a toolbar action opens
the owning thread at the exact parent floor. The action is absent while loading,
after an initial failure, for filtered ownership context, and in the sheet that
already overlays the owning thread. It uses a `ScrollView` with a `LazyVStack`,
stable native reply identities,
and a pagination sentinel keyed by the raw tail, retained count, and page so a
hidden-only appended page can rearm automatic loading. In two reversed-order,
production-like iOS 18.5 profiles, this container change reduced sampled
main-thread work by 66.0% and 50.9%, and reduced frame-interval p95 by 75.5% and
64.9%. A separately profiled no-image gallery-cover candidate had mixed results
and is retained only in the performance harness, not production. Its
authenticated PB Floor overlay batch-reads the parent and every retained child
after first verifying the parent's topic-or-floor identity through PB Page.
Pull to refresh explicitly invalidates the matching authenticated read cache and
repeats that batch read even when the anonymous response returns the same target
set. A hidden anchor produces an explicit notice instead of an invalid scroll
target.

Anchored requests carry both the enclosing `pid` and target `spid`. Replies can
then paginate toward either earlier or later pages using the locked parent ID;
prepending restores the previously visible reply. A page must advance strictly
in the requested direction before any new IDs or counts are merged, so duplicate,
stalled, invalid, or reversed pages terminate that direction without corrupting
server order. Pull to refresh keeps the prior snapshot on failure and atomically
replaces it on success, including allowing a decreased server reply count.
