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
- Public user profiles opened from post and nested-reply authors
- Paginated public threads on user profiles
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
