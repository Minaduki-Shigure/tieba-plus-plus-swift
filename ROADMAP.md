# TiebaLite parity roadmap

Tieba++ is an independent Swift application implementation. TiebaLite is used as
a product reference for expected workflows; the only adapted source material is
the minimal attributed protobuf schema documented in TiebaProto's `NOTICE.md`.

## Available

- Anonymous forum and thread search
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

## Next milestones

1. Account login backed by Keychain and an explicit security review
2. Authenticated follow, favorite, like, post, and reply workflows
3. Notifications, moderation tools, and broader settings parity

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
isolation, and real-device validation. Anonymous browsing must continue to work
without creating or storing an account session.
