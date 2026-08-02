# TiebaLite parity roadmap

Tieba++ is an independent Swift application implementation. TiebaLite is used as
a product reference for expected workflows; the only adapted source material is
the minimal attributed protobuf schema documented in TiebaProto's `NOTICE.md`.

## Available

- Ranked anonymous hot-topic discovery with images and discussion counts
- Hot-topic details with related forums and cursor-aware thread pagination
- Categorized anonymous forum, thread, and user search
- Global post search with newest, oldest, and relevance sorting
- Versioned local global-search history with recent/all, delete, and clear controls
- Anonymous per-forum post search with newest/relevance sorting
- Topic-only and topic-plus-reply search filters with target-aware navigation
- Versioned, per-forum local search history with delete and clear controls
- Forum thread list with pagination and pull to refresh
- Reply-time and creation-time forum sorting
- Global default sorting with normalized per-forum sort memory
- Server-defined forum channels with independent sorting and cursor pagination
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
- Versioned local browsing history with delete, clear, and recording controls
- Settings-level no-history mode using the existing browsing-history archive
- Native system, light, and dark appearance selection
- Transient pure-reading mode and full textual floor copying
- Home-screen recent-forum history, expanded by default and independently hideable
- Canonical forum/thread sharing and browse-mode-aware thread-link copying
- Strict internal routing for supported Tieba HTTPS, pasted official-scheme, and app links
- Nested replies, images, video links, and voice playback
- Server-ranked inline nested-reply previews with anchored opening and safe text copying
- Shared-thread origin cards with original content, media, and navigation
- Anonymous single- and multiple-choice poll result cards
- Read-only post and nested-reply scores, author forum levels, and IP locations
- Lossless nested-reply context and public-profile links for user mentions
- Public user profiles opened from post and nested-reply authors
- Limited public liked-forum previews with direct forum navigation
- Paginated public threads on user profiles
- Local case-sensitive literal-keyword and exact UID/name user block/allow lists
- Placeholder or fully hidden presentation for locally blocked content
- Local video-topic blocking and user-profile block/allow shortcuts
- Independent local forum and thread favorites
- Saved-thread reading-position and browse-mode restoration
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

Local favorites are deliberately separate from browsing history and from
Tieba's account-backed collection service. Disabling or clearing history does
not remove favorites, and the UI labels them as local rather than implying
cross-device account sync. Hot-ranked threads retain the mode but not an
unstable ranking position.

The home-screen recent-forum row is a projection of the same browsing-history
archive, not a second store. It shows at most the 100 newest forum records while
the archive continues to retain its normal per-kind limit. The row is expanded
for each new app session; whether the section is present is a persistent local
preference. A forum is still recorded only after valid server metadata arrives,
and history remains available without an account.

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
Their `GeneralTabList` requests use a channel-specific sort type and advance
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

The global forum-sort preference applies when a forum has no remembered choice;
changing a forum's picker stores a normalized, bounded per-forum override.
Appearance and sort values are nonsecret local enums. No-history mode updates
the recording flag inside the existing versioned history archive, so it does not
create a competing source of truth or delete favorites. Pure-reading mode is
transient and removes author chrome, filter placeholders, and nested-reply entry
points without changing post data or the persisted sort. Full-floor copy uses
the currently decoded public textual fragments plus fixed `[图片]`, `[视频]`, and
`[语音]` boundary markers; media URLs and nested replies are not synthesized
into the copied text.

Local content filtering covers ordinary and channel forum thread lists, post
floors, nested replies, and shared-thread origin cards. Keyword rules use
case-sensitive literal substring matching; user rules match an exact positive
UID or exact name. An allow rule takes precedence only within the same matching
domain and inspected field: a user allow rule does not override a blocked
keyword, and a keyword allowed in one field does not override a blocked match
in another. Blocked content can remain as a placeholder or be fully hidden.
The independent video-topic switch applies to thread rows. Filtering annotates
the raw models instead of removing them, so page and cursor progression still
uses every server result even when an entire visible page is hidden. Search
results and public-profile activity are intentionally outside this milestone's
filter scope. Regular-expression rules are intentionally unsupported until a
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
in anonymous responses: the author's level in that forum, the server-supplied IP
location, and `diff_agree_num` as the displayed net approval score. Missing or
malformed values collapse to a quiet empty state instead of creating a control.
These values are response snapshots only; anonymous cards do not submit likes.

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
