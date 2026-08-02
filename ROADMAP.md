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
- Server-defined forum channels with independent sorting and cursor pagination
- Forum header, statistics, rules state, and featured classifications
- Public forum introductions with original avatars and server statistics
- Full forum-rule documents with publisher and rich section content
- Moderator teams grouped by the server's public role names
- Post list with ascending, descending, and hot sorting
- Only-thread-author filtering
- Protocol-correct descending pagination with PID cursors
- Page-number jump and last-visible-post restoration
- Versioned local browsing history with delete, clear, and recording controls
- Nested replies, images, video links, and voice playback
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

Forum introductions, rule documents, and moderator teams use independent
credential-free protobuf endpoints. Moderator role names are treated as an
open server-defined set instead of being hard-coded to only large and small
moderators. A forum without published rules is a normal empty state rather than
an API failure.

Forum channels are accepted only from FRS tabs marked as general type 15.
Their `GeneralTabList` requests use a channel-specific sort type and advance
with both the page number and the final valid thread ID. Missing, duplicate, or
stalled cursors terminate pagination instead of repeatedly loading one page.

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
