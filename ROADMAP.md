# TiebaLite parity roadmap

Tieba++ is an independent Swift implementation. TiebaLite is used as a product
reference for expected workflows; its source code and assets are not copied.

## Available

- Anonymous forum and thread search
- Forum thread list with pagination and pull to refresh
- Reply-time and creation-time forum sorting
- Featured-thread filtering
- Post list with ascending, descending, and hot sorting
- Only-thread-author filtering
- Nested replies, images, video links, and voice playback
- HTTPS-only, credential-free anonymous requests

## Next milestones

1. Forum header, statistics, rules, and featured classifications
2. Floor jump, scroll position restoration, and browsing history
3. User profile and public user activity
4. Local favorites and followed-forum shortcuts
5. Account login backed by Keychain and an explicit security review
6. Authenticated follow, favorite, like, post, and reply workflows
7. Notifications, moderation tools, and broader settings parity

Each authenticated milestone remains gated on protocol tests, credential
isolation, and real-device validation. Anonymous browsing must continue to work
without creating or storing an account session.
