# Security Policy

Do not include BDUSS, STOKEN, complete cookies, device identifiers, or private
user content in issues, fixtures, logs, screenshots, or crash reports.

The networking layer must use HTTPS with URLSession's default certificate and
hostname verification. Any endpoint that requires disabled verification or a
global cleartext exception must remain unsupported.

API traffic is restricted to the exact HTTPS hosts `tiebac.baidu.com` and
`tieba.baidu.com`. Redirects between those hosts are rejected even though both
are individually allowed.

The login view is the only embedded browser. It uses
`WKWebsiteDataStore.nonPersistent()`, accepts main-frame navigation only on an
exact first-party host allowlist over HTTPS on the standard port, and captures
only a structurally valid `BDUSS` Secure cookie after the expected Tieba
account-page callback. The store is erased when the view is dismantled.
The app must never inject JavaScript to read passwords, persist the full cookie
jar, override a TLS challenge, or enable Web Inspector for this view.
Camera, microphone, device-motion, and orientation permission requests from the
login page are denied by the WebKit UI delegate.

Account sessions are a bounded, versioned archive stored as a generic-password
Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, data
protection Keychain enabled, and synchronization disabled. Only nonsecret
account summaries may leave the vault. Malformed or future-version archives
must not be overwritten. The stored BDUSS must remain redacted from
descriptions, debug mirrors, errors, analytics, and logs.
Local logout deletes the selected Keychain session; it cannot promise to revoke
an already issued Baidu server token. Users who suspect token exposure must use
Baidu's account-security controls to invalidate sessions. A user-confirmed
local reset may delete an unreadable account archive without touching browsing
history, favorites, or the remote Baidu account.

Anonymous and authenticated networking are separate clients backed by
independent ephemeral URL sessions. Anonymous request factories have no account
parameter and must remain credential-free. Authenticated request factories send
only the fields required by the selected endpoint in the HTTPS request body,
disable cookies and URL credentials, reject all redirects, and never retain
credentials as client state. MD5 is used only for compatibility with the
unofficial request-signature protocol, not for password storage or
verification.

STOKEN is neither extracted nor persisted in this read-only milestone. A future
feature that requires it must add a login flow that verifies BDUSS and STOKEN
belong to the same returned account before storing or using the pair.

Anonymous public-profile requests must use the protocol's guest target fields.
They must not place the target user in the current-account field, attach account
credentials, or attempt to bypass profile privacy settings.

Forum, global thread, per-forum post, and user search must use the anonymous
request factory even when an account is active. Search requests may contain
only the submitted public keyword, public forum name, and endpoint-specific
pagination, sorting, or content-filter fields; they must never attach Cookie,
Authorization, BDUSS, STOKEN, a Referer containing device metadata, or a device
identifier.
Global thread sorting and per-forum post sorting must remain separate protocol
types: their user-facing modes overlap, but their wire values do not. Tests must
assert the exact endpoint-specific value without broadening the allowed fields.

Hot-topic list and detail requests follow the same anonymous boundary. They may
send only the public topic identifier/name and pagination fields documented by
the endpoint. The detail response can include `tbs`, `user`, and generated
client metadata; these fields must not be persisted, promoted into an account
session, or forwarded into later requests. Topic media must pass the same
HTTPS URL normalization policy as all other remote media.

Public forum introductions, rules, and moderator-team requests must remain
credential-free. They may include only the forum identifier and anonymous
client metadata; no future account Cookie, BDUSS, or STOKEN may be attached to
these read-only calls.

Shared-thread origin cards are decoded only from the existing anonymous post
response. They must require the explicit share flag and a positive origin TID
different from the outer thread, and all origin links and media must pass the
same HTTPS normalization used by ordinary post content. Opening an origin uses
the normal credential-free thread request and must not forward response metadata.

Browsing history, local favorites, global search history, and per-forum search
history are separate versioned JSON archives in Application Support. They use
atomic writes, enforce bounded archive sizes, refuse to overwrite malformed or
future-version data, and are excluded from device backups. They must never
contain account credentials or private server responses. Global search history
stores only the trimmed public query and its local submission time.
An unreadable search-history archive may be deleted only through the explicit,
user-confirmed recovery action for that archive; ordinary reads and writes must
preserve it and must not delete the other search-history domain.

Remote media uses an ephemeral, credential-free session, rejects cleartext
requests or redirect destinations, and is decoded through ImageIO with a
bounded pixel size and memory cache. Original image dimensions are never
decoded directly into the browsing UI.

Automated tests use synthetic fixed-length placeholders only. Real `BDUSS`,
`STOKEN`, `tbs`, cookies, passwords, or private account responses must never be
placed in GitHub Actions secrets or exercised by CI. Authenticated releases need
manual device validation with a disposable test account before write features
can be enabled.

Report security issues privately to the repository owner rather than opening a
public issue.
