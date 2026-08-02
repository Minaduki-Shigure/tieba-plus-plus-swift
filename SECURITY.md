# Security Policy

Do not include BDUSS, STOKEN, complete cookies, device identifiers, or private
user content in issues, fixtures, logs, screenshots, or crash reports.

The networking layer must use HTTPS with URLSession's default certificate and
hostname verification. Any endpoint that requires disabled verification or a
global cleartext exception must remain unsupported.

API traffic is restricted to the exact HTTPS hosts `tiebac.baidu.com` and
`tieba.baidu.com`. Redirects between those hosts are rejected even though both
are individually allowed.

Anonymous public-profile requests must use the protocol's guest target fields.
They must not place the target user in the current-account field, attach account
credentials, or attempt to bypass profile privacy settings.

Public forum introductions, rules, and moderator-team requests must remain
credential-free. They may include only the forum identifier and anonymous
client metadata; no future account Cookie, BDUSS, or STOKEN may be attached to
these read-only calls.

Browsing history and local favorites are separate versioned JSON archives in
Application Support. Both use atomic writes, enforce bounded archive sizes,
refuse to overwrite malformed or future-version data, and are excluded from
device backups. They must never contain account credentials or private server
responses.

Remote media uses an ephemeral, credential-free session, rejects cleartext
requests or redirect destinations, and is decoded through ImageIO with a
bounded pixel size and memory cache. Original image dimensions are never
decoded directly into the browsing UI.

Report security issues privately to the repository owner rather than opening a
public issue.
