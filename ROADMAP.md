# TiebaLite parity roadmap

Tieba++ is an independent Swift application implementation. TiebaLite is used as
a product reference for expected workflows; the only adapted source material is
the minimal attributed protobuf schema documented in TiebaProto's `NOTICE.md`.

## Available

- Anonymous hot-thread ranking with an embedded hot-topic preview,
  server-defined categories, and snapshot refresh
- Ranked anonymous hot-topic discovery with images and discussion counts
- Hot-topic details with related forums and cursor-aware thread pagination
- Categorized anonymous forum, thread, and user search
- Default-off anonymous online suggestions for the home search field
- Local home-entry customization with a next-launch destination and optional discovery section
- Global post search with newest, oldest, and relevance sorting
- Local keyword, user, and video filtering for global and per-forum search results
- Local filtering for paginated public-profile activity
- Versioned local global-search history with recent/all, delete, and clear controls
- Anonymous per-forum post search with newest/relevance sorting
- Topic-only and topic-plus-reply search filters with target-aware navigation
- Versioned, per-forum local search history with delete and clear controls
- Forum thread list with pagination and pull to refresh
- Reply-time and creation-time forum sorting
- Global default sorting with normalized per-forum sort memory
- Server-defined forum channels with bounded server-provided sorting menus and cursor pagination
- Shared rich thread cards across forum, channel, hot-topic, global-search, and public profiles
- Compact pinned rows, topic-state badges, bounded image previews, and video covers
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
- Native system, light, and dark appearance selection
- Transient pure-reading mode and full textual floor copying
- Home-screen recent-forum history, expanded by default and independently hideable
- Canonical forum/thread sharing and browse-mode-aware thread-link copying
- Strict internal routing for supported Tieba HTTPS, pasted official-scheme, and app links
- Nested replies, images, video links, and voice playback
- Persistent automatic or tap-to-load policy for content images and video covers
- Optional compact media summaries for thread lists and per-forum search, with no collapsed preview request
- Default-on dark-appearance dimming for successfully rendered static content thumbnails
- Same-content multi-image gallery with paging, zoom, original-file sharing, and Photos saving
- Server-ranked inline nested-reply previews with anchored opening and safe text copying
- Full nested-reply pages with parent-floor context and bidirectional anchored pagination
- Shared-thread origin cards with original content, media, and navigation
- Anonymous single- and multiple-choice poll result cards
- Read-only scores, author forum levels, bounded moderator roles, and IP locations
- Lossless nested-reply context and public-profile links for user mentions
- Public user profiles opened from post and nested-reply authors
- Limited public liked-forum previews with direct forum navigation
- Paginated public threads on user profiles
- Default-off combined public nickname and username presentation
- Local case-sensitive literal-keyword and exact UID/name user block/allow lists
- Placeholder or fully hidden presentation for locally blocked content
- Local video-topic blocking and user-profile block/allow shortcuts
- Independent local forum and thread favorites
- Local pinned-forum ordering and explicit forum-favorite context actions
- Saved-thread reading-position and browse-mode restoration
- Default-off only-author and descending overrides for locally saved threads
- Home-screen shortcuts for locally saved forums
- HTTPS-only, credential-free anonymous requests
- Ephemeral, HTTPS-only Baidu Web login with an exact host allowlist
- Device-only Keychain account storage, account switching, and local logout
- Paginated followed-forum list for the active account
- Isolated anonymous and authenticated networking clients

## Next milestones

1. Real-device validation of login, account switching, and followed forums
2. Authenticated follow, favorite, and like workflows
3. Post and reply workflows behind explicit confirmation and anti-CSRF tests
4. Notifications, moderation tools, and broader settings parity

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

Rich-content images open as one gallery scoped to the already filtered content
array that produced the tapped image. Source offsets, rather than URLs, identify
pages, so repeated images remain distinct and the selected duplicate opens at
the correct position. Paging, the visible counter, and per-page zoom never fetch
or aggregate another floor. Sharing and Photos saving explicitly download only
the selected original image through the bounded credential-free media transport,
validate its real ImageIO type and dimensions, and retain the temporary file only
until the system consumer finishes. Whole-thread `picpage` traversal remains a
separate milestone because the current domain model does not yet preserve its
picture IDs or bidirectional cursor contract.

Public profiles use the protocol's guest fields instead of impersonating the
target user as the current account. The public-theme endpoint ignores its
nominal page-size field, so pagination deliberately continues until an empty
page and deduplicates by thread ID. Tieba's followed-forum list rejects
anonymous requests, and TiebaLite only presents reply history for the current
account; neither is exposed as a misleading anonymous profile tab.
The profile response may include a small public liked-forum preview. It is
presented as a preview alongside the server's declared total, never as a full
list, and an empty preview remains a valid privacy state. The authenticated
full-list endpoint is not called from a public profile.

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
existing post ranking, hot topics, local favorites, and browsing history. The
choice is snapshotted once at process launch, so changing it cannot redirect an
active session; unknown stored values fall back to home. A cold-start forum,
thread, or user link is appended above that initial page and remains the visible
destination. The independent discovery switch defaults on and removes only the
home section containing ranking, topic, and explicit paste-link shortcuts. It
does not disable those destinations, the strict URL router, or any network path.

Forum and thread share actions emit canonical `https://tieba.baidu.com` URLs
through the system share sheet. Thread copying additionally carries an exact
`see_lz=0` or `see_lz=1` value so the active author filter can round-trip. URL
construction uses structured components rather than interpolating unescaped
forum names.

One parser handles in-app rich links, explicit clipboard pastes, and the
registered app-owned `tieba-plus-plus` scheme. It requires the exact Tieba host,
standard ports, exact paths, nonempty bounded forum names, positive 64-bit IDs,
and unambiguous supported state. Valid `see_lz` and post anchors are preserved
when opening a thread. Cleartext official links are accepted only as route text;
the destination is loaded through the existing HTTPS-only API client. Unknown
HTTPS links remain system actions instead of being swallowed. The app does not
register Baidu's official scheme, automatically inspect the clipboard, claim
Universal Links without Baidu's AASA authorization, or fabricate a browsing-
history snapshot before the linked thread has loaded successfully.

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
flags, and available read-only counters through the application layer. One card
renders this metadata across forum/channel lists, hot-topic details, global
search, and public user themes without reordering or filtering the server result
set. Pinned rows deliberately omit excerpts and media. Ordinary rows load at
most three image thumbnails or one video cover; a cover is never an autoplaying
player. Every preview still passes the existing HTTPS URL normalization,
credential-free downloader, redirect policy, transfer-time byte limit, and pixel
downsampling. Automatic 720-pixel previews stop at 16 MiB; higher-resolution
explicit image views retain the 80 MiB ceiling.
An independent persistent compact mode replaces those thread-list previews and
per-forum search image strips with noninteractive media summaries. Its collapsed
presentation retains only a media type or full image count and never constructs
a remote preview view, so it creates no preview request. It does not alter post
bodies, hot-topic images, avatars, gallery/export paths, playback, page data, or
the separate automatic versus tap-to-load policy used when previews are expanded.
A separate default-on dark-appearance control applies a 0.4 color multiplier
only to successfully rendered static content images in thread cards, post
bodies, per-forum search, and hot topics. Video covers, avatars, galleries,
placeholders, and compact summaries remain unchanged. The control is a pure
rendering decision and does not enter URL normalization, fetch policy, reload
identity, transfer deduplication, decoding, or cache keys.

The global forum-sort preference applies when a forum has no remembered choice;
changing a forum's picker stores a normalized, bounded per-forum override.
Channel-menu choices are remembered separately only while the current forum
screen is alive, are revalidated when a menu changes, and never overwrite the
global or per-forum topic-sort preference.
Appearance and sort values are nonsecret local enums. No-history mode updates
the recording flag inside the existing versioned history archive, so it does not
create a competing source of truth or delete favorites. Pure-reading mode is
transient and removes author chrome, filter placeholders, and nested-reply entry
points without changing post data or the persisted sort. Full-floor copy uses
the currently decoded public textual fragments plus fixed `[图片]`, `[视频]`, and
`[语音]` boundary markers; media URLs and nested replies are not synthesized
into the copied text.

Local content filtering covers ordinary and channel forum thread lists, global
and per-forum search results, public-profile activity, post floors, nested
replies, and shared-thread origin cards. Keyword rules use case-sensitive
literal substring matching; user rules match an exact positive UID or exact
name. An allow rule takes precedence only within the same matching domain and
inspected field: a user allow rule does not override a blocked keyword, and a
keyword allowed in one field does not override a blocked match in another.
Blocked content can remain as a placeholder or be fully hidden. In per-forum
search, the matched entity and its displayed topic or parent-floor context are
filtered independently. A blocked context can be replaced or omitted without
removing an otherwise visible match; a blocked match suppresses the complete
row so its nested context cannot reveal it. The independent video-topic switch
applies to thread rows; global search and the matched per-forum entity preserve
the server's public video marker even when no usable cover URL survives media
normalization.
Filtering annotates the raw models instead of removing them, so page and cursor
progression still uses every server result even when an entire visible page is
hidden. Inaccessible raw-tail sentinels can therefore advance through hidden
global-search, per-forum-search, and public-profile pages without exposing their
content. Regular-expression rules are intentionally unsupported until a
bounded or non-backtracking implementation is available.

Each authenticated milestone remains gated on protocol tests, credential
isolation, and real-device validation. The initial authenticated feature is
read-only: it validates identity and fetches followed forums. Anonymous
browsing must continue to work without creating, reading, or storing an account
session.

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

Anonymous poll cards are read-only. Current post responses place an ordinary
thread's poll in its mirrored `origin_thread_info`, while that same field belongs
to the original topic when the outer thread is a share. The mapper keeps those
owners distinct, prefers an authoritative direct poll when present, and uses the
ordinary thread's mirror as a compatibility fallback.
Percentages use the server's total option-vote count, with a sanitized option-sum
fallback for missing totals; zero and inconsistent totals cannot produce an
invalid or oversized progress bar. Poll submission remains unsupported.

Post and nested-reply headers preserve the public author context already present
in anonymous responses: the author's level in that forum, bounded forum-moderator
role, server-supplied IP location, and `diff_agree_num` as the displayed net
approval score. Moderator roles normalize only recognized manager and assistant
wire values; a flagged but empty or unknown value becomes the generic `吧务`
label. The raw role string and arbitrary badge images never enter the UI. Missing
or malformed values collapse to a quiet empty state instead of creating a
control. These values are response snapshots only; anonymous cards do not submit
likes or expose moderation actions.

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
available whenever the server declares replies. Pure-reading mode hides the
entire preview surface without triggering another request.

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
list. A hidden anchor produces an explicit notice instead of an invalid scroll
target.

Anchored requests carry both the enclosing `pid` and target `spid`. Replies can
then paginate toward either earlier or later pages using the locked parent ID;
prepending restores the previously visible reply. A page must advance strictly
in the requested direction before any new IDs or counts are merged, so duplicate,
stalled, invalid, or reversed pages terminate that direction without corrupting
server order. Pull to refresh keeps the prior snapshot on failure and atomically
replaces it on success, including allowing a decreased server reply count.
