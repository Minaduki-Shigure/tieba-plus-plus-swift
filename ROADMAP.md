# TiebaLite parity roadmap

Tieba++ is an independent Swift implementation. TiebaLite is used as a product
reference for expected workflows; its source code and assets are not copied.

## Available

- Anonymous forum and thread search
- Forum thread list with pagination and pull to refresh
- Reply-time and creation-time forum sorting
- Forum header, statistics, rules state, and featured classifications
- Post list with ascending, descending, and hot sorting
- Only-thread-author filtering
- Protocol-correct descending pagination with PID cursors
- Page-number jump and last-visible-post restoration
- Versioned local browsing history with delete, clear, and recording controls
- Nested replies, images, video links, and voice playback
- HTTPS-only, credential-free anonymous requests

## Next milestones

1. Public user profiles and public user activity
2. Local favorites and followed-forum shortcuts
3. Richer forum rules and moderator details
4. Account login backed by Keychain and an explicit security review
5. Authenticated follow, favorite, like, post, and reply workflows
6. Notifications, moderation tools, and broader settings parity

Tieba's anonymous post endpoint does not currently honor its nominal numeric
floor-jump fields. The app therefore restores a stable post ID and offers page
jumps instead of presenting an unreliable arbitrary-floor jump as supported.
Hot ranking responses expose physical-page PIDs unrelated to the ranking, so a
hot history entry restores the mode but deliberately reopens its first page.

Each authenticated milestone remains gated on protocol tests, credential
isolation, and real-device validation. Anonymous browsing must continue to work
without creating or storing an account session.
