# Security Policy

Do not include BDUSS, STOKEN, complete cookies, device identifiers, or private
user content in issues, fixtures, logs, screenshots, or crash reports.

The networking layer must use HTTPS with URLSession's default certificate and
hostname verification. Any endpoint that requires disabled verification or a
global cleartext exception must remain unsupported.

General API traffic is restricted to the exact HTTPS hosts
`tiebac.baidu.com` and `tieba.baidu.com`. The whole-thread picture-page request
has a separate exact allowlist entry for `c.tieba.baidu.com`. Redirects must
remain on the request's original HTTPS host; redirects between individually
allowed hosts are rejected.

The login view contains the only app-controlled `WKWebView`. It uses
`WKWebsiteDataStore.nonPersistent()`, accepts main-frame navigation only on an
exact first-party host allowlist over HTTPS on the standard port, and captures
only a structurally valid `BDUSS_BFESS` or `BDUSS` cookie and a structurally
valid `STOKEN` from the same Cookie-store snapshot after an expected Tieba
`/index/tbwise/` account-page callback. BDUSS candidates must belong exactly to
`baidu.com`; STOKEN must belong exactly to `tieba.baidu.com`. Both require root
paths, unexpired metadata, 192- or 64-byte values respectively, and RFC 6265
cookie-octets. Secure candidates always precede
non-Secure candidates. A non-Secure metadata fallback is permitted only when no
eligible Secure candidate exists, the current callback is still on the exact
HTTPS Tieba host and account path, and the WebKit data store is confirmed to be
nonpersistent. The selected pair must still pass the isolated, redirect-free
signed `/c/s/login` validation and an independent HTTPS Web identity probe; the
two responses must return the same positive UID before Keychain storage. The
Web probe sends only the actual captured BDUSS Cookie name and STOKEN, rejects
all redirects, and is limited to 256 KiB. Cookie-store propagation is
retried a bounded number of times, and exhaustion is reported instead of
leaving the login flow pending. The store is erased when the view is dismantled.
The app must never inject JavaScript to read passwords, persist the full cookie
jar, override a TLS challenge, or enable Web Inspector for this view.
Camera, microphone, device-motion, and orientation permission requests from the
login page are denied by the WebKit UI delegate.
No App Transport Security or WebKit exception may allow cleartext content in
this flow; adding one would invalidate the non-Secure fallback boundary.

Account sessions are a bounded, versioned archive stored as a generic-password
Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, data
protection Keychain enabled, and synchronization disabled. Only nonsecret
account summaries may leave the vault. Malformed or future-version archives
must not be overwritten. Stored BDUSS and STOKEN values must never be
interpolated by client-owned descriptions, debug mirrors, App-visible errors,
analytics, or logs. Direct Core callers must treat server-provided error text as
untrusted and must not log it because a server can echo request data.
Archive v2 adds one random, nonsecret session-revision UUID to each account.
Archive v3 adds optional STOKEN and the actual BDUSS Cookie name. A valid v1
archive is fully decoded and validated before those revisions are generated;
v2 preserves its existing revision. Both migrate atomically with `stoken = nil`
and the legacy BDUSS Cookie name, while invalid legacy data remains untouched.
The revision stays stable across ordinary reads and account switches,
but every validated upsert of an existing UID rotates it even when the device
clock repeats or moves backwards. Account write results, recovery reads, and
check-in notifications must match both UID and revision before changing current
session state. The revision may be persisted in the Keychain archive and carried
in an in-process notification, but must never substitute for or derive from a
credential.
Local logout deletes the selected Keychain session; it cannot promise to revoke
an already issued Baidu server token. Users who suspect token exposure must use
Baidu's account-security controls to invalidate sessions. A user-confirmed
local reset may delete an unreadable account archive without touching browsing
history, favorites, or the remote Baidu account.

Anonymous and authenticated networking are separate clients backed by
independent ephemeral URL sessions. Anonymous request factories have no account
parameter and must remain credential-free. Authenticated request factories send
only the fields required by the selected endpoint in the HTTPS request body,
disable persistent cookie handling and URL credentials, reject all redirects,
and never persist credentials or retain them beyond the active authenticated
operation. Forum follow/unfollow and check-in writes may carry the fixed,
noncredential header `Cookie: ka=open`; they must not attach a stored cookie jar.
Authenticated account, followed-forum, forum-state probe, and write responses
have endpoint-specific transfer limits before decoding. MD5 is used only for
compatibility with the unofficial request signature protocol, not for password
storage or verification.

The current, not-yet-tagged `main` implementation of the home followed-forum
projection and complete followed-forum list shares one application-scoped,
memory-only state. The home projection exposes at most six rows. The complete
list and a selected, default-off followed-forum recommendation filter may advance
pagination. A new page request may start only while the home page, complete list,
or selected filtered recommendation page is active. Before each request, the App
reads the active Keychain session and binds the operation to its exact
`userID + sessionRevision`; after transport it reads the session again and
rejects the page unless that same lease and the requested page are still current.
Logout, account switching, same-UID credential rotation, and a matching forum-
membership change invalidate the state epoch, clear all rows and cursors, and
prevent an older response from repopulating them. A complete index is published
only when the server explicitly reports the final page. Empty or duplicate-only
continuations, invalid page data, transport failure, more than 100 pages, or more
than 5,000 retained forums keep the index unavailable. No row, page cursor,
complete forum-ID set, or lease is stored across accounts or app launches.

These surfaces are read only: displaying or paginating them must not pin,
unfollow, check in, or issue any other write automatically, and they currently
offer no pinning, unfollow, or batch check-in control. The endpoint response does
not itself establish the active account's identity, so the two-sided lease check
is protection against stale local publication, not proof that the server honored
the requested UID. Successful private-list retrieval and server-side account
binding remain physical-device validation questions; CI may cover only synthetic
request, pagination, and lease behavior.

The personalized Explore feed is the sole anonymous request that carries a
stable app-generated identifier. At first launch the app generates an ordinary
random UUID, stores it in local `UserDefaults`, and sends it only as
`CommonReq.cuid` to the HTTPS `309264` personalized endpoint. This value is
nonsecret and must never be derived from IDFV, hardware, an account, a login
cookie, IMEI, OAID, Android ID, network address, model, screen dimensions, or
location. The request must not add Cookie, Authorization, BDUSS, STOKEN,
`client_user_token`, an outer signature, or a CUID header. The UUID remains
stable so refresh and later pages share one recommendation session; malformed
stored values are replaced locally. Responses are limited to 4 MiB. Raw full
pages may continue, but an empty page stops immediately. A refresh may traverse
duplicate-only pages up to the page frontier already reached by that client;
beyond it, at most one additional duplicate-only page may advance before a
second stops the request chain. The default-off followed-forum filter never adds
its account lease, credentials, or forum-ID set to this anonymous request. It
waits for a verified-complete index and filters returned threads locally by
stable forum ID. A waiting, signed-out, empty, partial, invalid, or failed index
issues no recommendation request and cannot fall back to the unfiltered scope.
Changing scope cancels the old request and synchronously clears its rows. To
bound sparse-match traffic, each explicit action automatically scans at most five
filtered pages before requiring another user action; raw page and thread-ID
progress are tracked independently of locally visible rows. Recommendation
feedback is a separate server write and remains disabled.

The account-bound concern feed requires a complete same-snapshot BDUSS/STOKEN
session and uses protobuf command `309474` at the fixed HTTPS `tiebac.baidu.com`
origin. Its candidate compatibility contract places client type/version, a
separate process-local random UUID, network type, BDUSS, and STOKEN in
`CommonReq`; the outer multipart body contains only BDUSS, the fixed client
version, STOKEN, their signature, and the protobuf file. The expected validated
UID appears only in `client_user_token`. Cookie, Authorization, client ID, IMEI,
OAID, Android ID, IDFV, model, brand, screen, location, installation time, and
randomized telemetry fields are forbidden. The concern UUID must never reuse
the persistent anonymous-personalization UUID or derive from an account,
credential, or device. Responses are limited to 4 MiB and all redirects are
rejected.

Concern loading is foreground and explicit-selection only. Constructing or
preloading its TabView page, starting the app on Personalized, or changing an
account while the channel is inactive must issue no concern request. A refresh
uses an empty page tag and the current lease's prior server timestamp or zero;
load-more uses the exact opaque returned page tag and the same refresh timestamp.
Both values remain memory-only and are scoped to `userID + sessionRevision`.
Every request reads that lease before and after transport. Logout, switching
UIDs, same-UID credential rotation, filter changes, or app restart invalidates
rows, cursor, and timestamp; a late response cannot repopulate them. A returned
`has_more` must be zero or one, and a continuing cursor must be bounded,
control-free, nonempty, and different from the requested cursor. Only valid,
non-advertising, non-live `recommend_type = 1` threads are exposed, while local
filtering never alters raw cursor progression.

The endpoint can return HTTP/protobuf success with no threads and a prompt to
log in. That combined envelope must trigger the existing signed-app plus Web
same-UID session probe before it can be treated as a legitimate empty snapshot;
an authentication failure becomes a re-login requirement. Real-device testing
must still determine the absolute minimum inner/outer credential fields,
unsigned behavior, empty-account prompt type, expired and cross-account STOKEN
behavior, cursor replay semantics, and whether reading changes recommendation or
seen state. CI uses synthetic credentials and never calls this private endpoint.

Read-only cloud favorites require a complete v3 session. They use one signed
HTTPS POST to `https://tiebac.baidu.com/c/f/post/threadstore` containing exactly
`BDUSS`, `_client_version`, `offset`, `rn`, `stoken`, `user_id`, and `sign`, the
expected UID in `client_user_token`, and only `ka=open` in the Cookie header. No
`tbs`, CUID, hardware identifier, or credential Cookie is allowed. Responses are
limited to 2 MiB. Core carries the request's expected UID as request context; it
is not a UID assertion from the response, which has no identity field. The App
checks `userID + sessionRevision` before and after every page request. Cloud
favorites remain in memory and separate from local favorites. The list offers
only explicitly confirmed single-item removal; bulk synchronization stays
disabled.

A list-removal intent captures the complete retained row and its exact
`userID + sessionRevision` lease. Before any authenticated request, an anonymous
PB Page response must contain the requested thread ID, a positive forum ID, a
forum name without control characters, and a thread `fid` that is zero or exactly
that forum ID. A nonempty list forum name must match after trim and NFC
normalization. This produces only a candidate target: the authenticated PB state
read below must still bind the same UID, forum ID, and thread ID before writing.
If a deleted item can no longer provide this identity, the App sends no write; it
does not use TiebaLite's `fid=null` path, a cached login `tbs`, a fuzzy forum
search, or a guessed identifier.

A thread-detail cloud-favorite overlay is a separate full-session workflow. Its
authenticated PB Page read must bind the response's logged-in user, forum, and
thread to the exact expected UID, forum ID, and thread ID. It accepts only
`collect_status = 0` with an empty or zero marker, or `collect_status = 1` with
one positive decimal `collect_mark_pid`; every other combination fails closed.
The same response must contain a valid 26-character `anti.tbs`, which stays
inside Core and is never included in an App model, notification, log, mirror, or
persistent store. Responses are limited to 4 MiB.

Adding or updating a cloud favorite may send one signed HTTPS form to
`https://tiebac.baidu.com/c/c/post/addstore`. Before `sign`, the form contains
exactly `BDUSS`, `_client_version=12.41.7.1`, `data`, and `stoken`; `data` is a
structured JSON array containing one object with the exact decimal thread and
post IDs plus `status=1`. Removing one may instead send one signed form to
`https://tiebac.baidu.com/c/c/post/rmstore` containing exactly `BDUSS`, the same
fixed `_client_version`, `fid`, `stoken`, the fresh `tbs`, `tid`, `user_id`, and
`sign`. Both requests use `client_user_token=<expected UID>`, only `ka=open` in
the Cookie header, the matching fixed-version user agent, HTTPS, no redirects,
and a 64 KiB response limit. They must not add a credential Cookie, CUID, IMEI,
Android ID, IDFV, model, screen, location, or another device or telemetry field.

Every mutation, including one initiated from the list, starts with the strict
state read and returns without writing if the requested marker is already
present. Otherwise it sends at most one write
and always performs a read-only state reconciliation, including after a nominal
success. An uncertain transport or response failure may trigger exactly one
read-only reconciliation and must never retry the write; only the exact requested
marker confirms success. A dispatched write without that proof becomes the typed
cloud-favorite outcome-unknown error rather than an ordinary retryable network
failure. Identical operations may share one flight. A conflicting
operation waits for the active flight and then only rereads, requiring a new
explicit confirmation before any later write. The App additionally binds every
entry and operation to `userID + sessionRevision`, rejects late results after an
account change, keeps only a bounded memory cache, and requires separate explicit
confirmation for add, saved-position update, and destructive removal. Confirmed
list removal invalidates offset pagination and rebuilds from offset zero. A
matching change received while a list page is in flight invalidates that response
so a stale pre-change snapshot cannot resurrect the removed row.

Private ReplyMe and AtMe lists are foreground-only authenticated reads. ReplyMe
must use `https://tiebac.baidu.com/c/u/feed/replyme?cmd=303007` with a Protobuf
body whose common data contains only BDUSS and the fixed client version plus the
one-based page number. AtMe must use a signed HTTPS form at
`https://tiebac.baidu.com/c/u/feed/atme` containing exactly `BDUSS`,
`_client_version`, `pn`, and `sign`. Neither request may carry STOKEN, `tbs`, a
credential cookie, CUID, IMEI, Android ID, model, screen dimensions, randomized
telemetry, or another hardware-derived identifier. Both use the isolated
ephemeral authenticated client, reject redirects, bypass URL caching, and apply
an endpoint-specific response limit before decoding.

Inbox responses must have a zero server error code, the exact requested page,
bounded pagination flags, and positive thread, post, and sender IDs before they
are exposed. The Core result is labelled with the expected UID, while the App
checks the same `userID + sessionRevision` lease before and after every request;
an account change invalidates all retained pages and discards late results. No
private message is persisted. A nested notification's `quote_pid` is treated as
untrusted routing metadata because it is not a stable parent-floor identifier;
the App must not construct a child route from it. Exact child navigation uses a
separate credential-free PB Floor request with `pid=0`, the positive message
`post_id` as `spid`, and `pn=1`. The response must contain the exact requested
thread and child plus one positive server-resolved parent. That parent is locked
before any adjacent page is accepted. A deleted or missing child fails closed and
offers only ordinary owning-thread navigation.

The foreground unread summary uses a separate signed HTTPS `/c/s/msg` form that
contains only BDUSS, `_client_version=8.2.2`, `bookmark=1`, and `sign`. It sends
no Cookie, STOKEN, client UID header, CUID, hardware identifier, model, screen
metadata, or telemetry. The response is capped at 64 KiB and must contain a zero
error code plus bounded nonnegative integer `replyme` and `atme` values;
`fans` is optional, is validated when present, and is not included in the badge.
Because the envelope does not independently identify the account, its UID is
request context rather than server proof. The App checks the same
`userID + sessionRevision` lease before and after the request and synchronously clears the
snapshot on logout, switching, or same-UID credential rotation. The inbox
performs no background polling, explicit mark-read request, or local badge
clearing. An implicit server-side unread change caused by summary or list
retrieval remains a documented real-device validation question.

Before any forum write, the fresh FRS probe must bind the response user ID,
forum ID, normalized forum name, `is_like`, and `anti.tbs` to the requested
account and forum. The check-in state read and check-in write paths additionally
validate a present sign user against the exact expected UID, a zero-or-one sign
state, and nonnegative consecutive-day and rank values. Malformed optional sign
metadata must not disable otherwise valid membership reads or follow/unfollow.
The `tbs` value must be exactly 26 lowercase hexadecimal bytes, remain inside
the authenticated client, and be made available to at most the immediately
following confirmed write. It must not enter an application model, Keychain
archive, log, error, mirror, or retry queue.

Single-forum check-in must reject an unfollowed forum or a probe without usable
sign state. If the FRS probe already reports `is_sign_in = 1`, the operation is
idempotent and must return that state without sending a write. Otherwise it may
send exactly one HTTPS POST to `https://tiebac.baidu.com/c/c/forum/sign`. Its
signed form body contains exactly six fields: `BDUSS`, `_client_version`, `fid`,
`kw`, `tbs`, and `sign`. `_client_version` is fixed to `11.10.8.6`; the request
uses the expected UID in `client_user_token`, the static `Cookie: ka=open`, and
the matching fixed-version user agent. It must not add STOKEN, a stored cookie,
or any device identifier. The write response is limited to 64 KiB and is
accepted only when the error code is zero, the returned sign user ID matches the
expected account, `is_sign_in` is exactly one, and the returned consecutive-day
and rank values are nonnegative integers.

Approval state for a topic, ordinary post, or nested reply must come from an
authenticated protobuf response, never from the anonymous default value of
`Agree.has_agree`. Topic and post reads use PB Page; nested-reply reads use PB
Floor only after an authenticated PB Page probe has uniquely validated the
parent. PB Page must bind a logged-in response user to the exact expected UID,
forum ID, and thread ID, resolve one canonical first-post ID, normalize its two
allowed response representations, and reject invalid, cross-thread, conflicting,
or duplicate ordinary-post and child identities. PB
Floor inherits that validated UID and must bind the same forum and thread, the
exact positive parent-post ID and its topic-or-post classification, and every
positive child ID to that parent. An anchored read must contain the requested
child exactly once. The App may accept only the exact intersection declared by
the anonymous page's read descriptor; extra targets cannot create state or a
control, while a missing or duplicate expected target fails closed.

Before a requested change, the authenticated client reads the exact target and
returns without writing if it already has the requested state. Otherwise it must
acquire a fresh FRS context that binds the same credential to the exact expected
UID, forum ID, normalized forum name, and `tbs`, then make at most one HTTPS POST
to `https://tiebac.baidu.com/c/c/agree/opAgree`. The signed form contains exactly
`BDUSS`, `_client_version`, `agree_type=2`, `cuid`, `obj_type`, `op_type`,
`post_id`, `tbs`, `thread_id`, and `sign`; it must not add STOKEN or a credential
Cookie. `obj_type` is `3` for the canonical topic first post, `1` for an ordinary
post, and `2` for a nested reply. `post_id` is respectively that validated first-
post, post, or child ID; the nested reply's parent remains bound by the preceding
PB Page and PB Floor reads. `op_type=0` approves and `op_type=1` cancels approval.
The mandatory `cuid` is generated once per authenticated client as a random
uppercase Galaxy2 identifier (`32HEX|V` plus an 8-character Helios checksum),
reused only for that client lifetime, never derived from hardware or IDFV, and
never persisted. A write response is limited to 64 KiB and succeeds only when
its error code is zero; its optional score is not a substitute for that code.

An uncertain transport or response failure after the write must trigger exactly
one read-only target readback operation. That operation must repeat the same
account, forum, thread, parent, and child binding and can confirm success only
when the returned state equals the requested state. It must never retry, replay,
or redirect the write; an unconfirmed readback preserves the original failure.

The authenticated Core client single-flights an identical approval operation for
one exact target and credential. All approval writes for the same UID, including
writes to different topics, posts, or nested replies, are serialized behind one
account-level tail. A conflicting same-target operation waits for the active
write, performs read-only reconciliation, and issues no second write. The App
account-service identity additionally includes `sessionRevision` and credential
state: an identical operation may share one task, while a rotated session or an
opposite operation waits and then fails for an explicit reread instead of being
coalesced with the old account lease. Registered batch reads are single-flighted
by exact UID-plus-`sessionRevision` lease and PB request while visible scopes
share only their expected-target union. Scope changes, a write in progress, or
an account switch must invalidate or epoch-guard stale batch results so they
cannot overwrite a mutation or the new account's state.

Follow, unfollow, check-in, topic, post, or nested-reply approval or
cancellation, and each supported plain-text topic, floor, or nested-reply
submission all require explicit user confirmation. Automatic, scheduled, and
batch check-in are deliberately unsupported. `disagree` or downvote, new-topic
creation, rich-media replying, editing, deletion, reporting, and every other
authenticated content write remain unsupported and must not be inferred from
the approval or plain-text reply endpoints.

STOKEN is available only through a validated complete session and only to an
endpoint whose contract explicitly requires it. The current unfollow, check-in,
and content-approval requests deliberately omit STOKEN and must fail visibly
rather than fall back to a second write endpoint or add hardware-derived device
metadata. Thread-detail cloud-favorite changes are the first experimental
STOKEN-dependent writes and remain validation-build only. Before they are
eligible for a public release, disposable-account tests must prove the behavior
of valid, random, cross-account, and expired STOKEN pairs; a read-only identity
or favorites response is not sufficient evidence for safe write behavior.

Anonymous public-profile requests must use the protocol's guest target fields.
They must not place the target user in the current-account field, attach account
credentials, or attempt to bypass profile privacy settings.
Liked forums embedded in that public response are a bounded preview only. The
app must not call the login-required full-list endpoint, infer hidden entries,
or describe an empty or partial preview as the user's complete forum list.

Public following and follower lists are independent credential-free form reads.
Following must use `POST https://tiebac.baidu.com/c/u/follow/followList`, and
followers must use `POST https://tiebac.baidu.com/c/u/fans/page`. Before signing,
either body contains exactly `_client_version=22.6.5.1`, a positive target `uid`,
and a one-based `pn`; the final body adds only `sign`, the protocol-compatibility
MD5 over those sorted fields and the fixed suffix. There is no query or protobuf
common request. Neither endpoint may receive BDUSS, STOKEN, Cookie,
Authorization, CUID, IMEI, Android ID, model, screen, network, or another device
or account field. Responses are limited to 1 MiB before decoding.

Neither relation response echoes the target UID. Core must carry the requested
UID and relation kind as request context, and the App must reject any page whose
context does not match the active public-profile navigation. Following pages must
validate the exact returned page, a nonnegative total, binary `has_more`, and a
bounded raw list. Because an observed full 20-row page can report `has_more=0`
while another page exists, one bounded continuation probe is allowed for a full
page; an empty page stops unconditionally. Follower pages must validate the exact
nested current page, nonnegative pagination values, binary flags, and a bounded
list, then obey the server's `has_more`; an empty page also stops. Duplicate-only
or stalled pages must stop local continuation, and local filtering must never
replace the raw server tail used to trigger pagination.

`follow_list_switch`, `tips_text`, and their follower equivalents are untrusted,
opaque presentation metadata, not privacy assertions. Visible and unavailable
samples may return the same switch value, so the App must not synthesize an
`isHidden` state or claim that a list is public or private from either field. A
returned public-list row is also not authoritative active-account relationship
state: it must not create follow, unfollow, mutual-follow, or other account write
controls. Empty network results and lists emptied by local filtering remain
distinct UI states without changing those request or privacy boundaries.

Public reply activity is a separate credential-free request to the public
UserPost endpoint. Its common data uses only client type 2 and the
endpoint-specific client version `8`; the body otherwise contains only the
positive target UID, bounded page size, one-based page number, and
`need_content=1`. `is_thread` and `is_view_card` remain at their Protobuf zero
defaults. The request must not include BDUSS, STOKEN, Cookie, Authorization,
screen dimensions, CUID, or another device identifier. Responses are limited to
4 MiB, mapping is capped at 100 outer groups and 100 inner records per group,
and the server's `hide_post` privacy state is preserved.

The response groups activity by owning thread, but each inner content record is
an independent reply. Its inner positive post ID, creation time, and post type
are authoritative; the outer group post ID must never be used as a reply ID or
nested-reply parent. Type zero can navigate to that exact ordinary floor. Type
one can pass only the thread ID and inner child ID to the existing child-only
parent resolver. Unknown types remain non-navigable instead of being guessed.
Pagination ends on an empty raw group list, while duplicate-only or wholly
unusable mapped pages stop local continuation without rewriting prior results.

Anonymous forum-channel requests may contain only the public forum ID, a
type-15 general channel's ID/name/default flag, page size and number, independent
sort value, and the previous page's last thread ID. Server-provided sort menus
must be bounded to 12 entries, reject negative IDs and empty titles, keep only
the first occurrence of an ID, and limit titles to 40 characters. Requests may
send the `-1` no-menu sentinel or an advertised nonnegative raw ID; unknown
nonnegative values must not cause credential or device metadata to be added.
Channel choices remain transient and must not overwrite persistent whole-forum
sort preferences. Requests must not attach account cookies, STOKEN, device
identifiers, or personalized metadata. A rejected minimal request must remain
unsupported rather than broadening that boundary.

Forum, global thread, per-forum post, and user search must use the anonymous
request factory even when an account is active. Search requests may contain
only the submitted public keyword, public forum name, and endpoint-specific
pagination, sorting, or content-filter fields; they must never attach Cookie,
Authorization, BDUSS, STOKEN, a Referer containing device metadata, or a device
identifier.
Global thread sorting and per-forum post sorting must remain separate protocol
types: their user-facing modes overlap, but their wire values do not. Tests must
assert the exact endpoint-specific value without broadening the allowed fields.

Online search suggestions are a distinct opt-in network behavior and must
remain disabled by default. Enabling the setting must not send text already in
the search field; only a subsequent edit that remains valid through the 500 ms
debounce may start a request. The protobuf payload may contain only a trimmed
2-to-100-character, at-most-400-byte public keyword and the fixed string
`isforum = "0"`; it deliberately omits `CommonReq`, account credentials,
cookies, device identifiers, and personalized metadata. The anonymous
ephemeral transport must continue to ignore any response `Set-Cookie`.
Responses are limited to 64 KiB before protobuf decoding, then trimmed,
validated, exactly deduplicated, and bounded to 10 Core results and eight
visible rows. Suggestions and partial queries must not be cached, logged, or
written to search history. Failure is silent and must not retry; only an
explicit suggestion tap or ordinary submission records the final query once.
Disabling the setting, leaving the home flow, or backgrounding the app cancels
and clears local suggestion state. Cancellation cannot retract a request that
has already reached the server.

Hot-topic list and detail requests follow the same anonymous boundary. They may
send only the public topic identifier/name and pagination fields documented by
the endpoint. The detail response can include `tbs`, `user`, and generated
client metadata; these fields must not be persisted, promoted into an account
session, or forwarded into later requests. Topic media must pass the same
HTTPS URL normalization policy as all other remote media.

Hot-thread ranking requests are independent anonymous protobuf calls. Their
protobuf payload may contain only client type/version, the fixed public tab ID,
and a bounded category code; they must not add Cookie, BDUSS, STOKEN, CUID,
advertising IDs, device identifiers, or invented pagination fields. The app may
request `all` or a code from the current bounded server menu, and must preserve
each server title/code pair without inference. Mapped collections are bounded
and deduplicated before display. Any response `Set-Cookie` remains unused
because the anonymous transport does not store or handle cookies. The ranking
is read only and must not expose the reference client's agree or other reaction
writes. Its mapped topic preview comes only from a successful `all` response;
category responses must not replace that snapshot. Rendering the preview must
not eagerly request topic details. The existing anonymous hot-topic boundary is
used only after the user explicitly opens a topic or the complete topic list.

Public forum introductions, rules, and moderator-team requests must remain
credential-free. They may include only the forum identifier and anonymous
client metadata; no future account Cookie, BDUSS, or STOKEN may be attached to
these read-only calls.

Shared-thread origin cards are decoded only from the existing anonymous post
response. They must require the explicit share flag and a positive origin TID
different from the outer thread, and all origin links and media must pass the
same HTTPS normalization used by ordinary post content. Opening an origin uses
the normal credential-free thread request and must not forward response metadata.

Poll result cards are decoded only from the existing anonymous post response.
An ordinary thread may use its mirrored origin object as the poll carrier, but a
shared thread's origin poll must never be attributed to the outer thread. The
anonymous UI is strictly read-only and must not expose selection state, collect
votes, call a submission endpoint, or attach account credentials.

Post author levels, IP locations, and public net approval scores originate in the
anonymous post response. An IP location is server-supplied public author context,
not the device's current location; displaying it must never request Core Location
permission. These values are not persisted in local history. Separately
authenticated approval controls may be attached only to an exact validated topic
or ordinary floor, or to the exact parent and children on the complete nested-
reply page. They must not turn the anonymous score into account state or expose a
`disagree`, downvote, profile-write, or other authenticated action.

Forum-moderator roles come from that same anonymous author object and are
normalized into a closed manager, assistant, or generic-moderator enum. Raw,
empty, oversized, newline-bearing, or unknown role text must never be rendered;
an already flagged unknown role can only produce the fixed generic `吧务` label.
The badge is scoped to the current forum response and must not be promoted to a
global identity, persisted, copied into post text, or used to expose management
requests or authorization decisions.

Inline nested-reply previews are decoded from the existing anonymous post
response. Enabling them adds only the public `with_floor`, `floor_sort_type`, and
bounded `floor_rn` fields to that credential-free request; it must not attach an
account cookie, token, device identifier, or create a second network request.
Preview routing accepts only positive enclosing thread, post, and comment IDs.
The preview is a noninteractive text projection: it does not fetch avatars or
media, expose active external links, put resource URLs on the pasteboard, or
expose an approval control even when the authenticated PB Page mirror already
contains state for that child.
Every child is filtered independently, while filtering must not change the
server reply count or remove access to the complete nested-reply page.

Complete nested-reply content requests remain credential-free. A direct content
request sends only the public thread, parent-post, and page fields; anchored
opening adds the public target-comment field while retaining the parent-post
field. Before any response is displayed or merged, the app requires a matching
positive thread and parent identity and discards nonpositive, cross-thread,
cross-parent, or duplicate child identities. Earlier and later pages must advance
strictly in their requested direction, and an invalid or stalled response must
not mutate the loaded snapshot. The parent floor is projected into a dedicated
model without embedded reply previews, preventing duplicate storage and recursive
entry points. When an account is active, a separate authenticated PB Page plus PB
Floor approval read may mirror only that already validated page descriptor; it
must not add a credential to or otherwise change the anonymous content request.

Earlier-floor thread loading reuses the existing credential-free anonymous PB
request and sends only the public thread ID, adjacent numeric page, active sort,
and only-thread-author flag. It is exposed only for ascending pages whose server
metadata reports a previous page. Before mutation, the app requires the exact
requested page, a matching thread ID, and positive, unique floor IDs owned by
that thread. Malformed, skipped, or nonadvancing responses must not alter the
loaded content, page state, or cursors; a duplicate-only adjacent page may only
close that pagination direction. Prepending must preserve the established tail
page and PID cursor, freeze both pagination directions until leading-floor
restoration is consumed, and suppress history progress writes only during that layout change.
This credential-free pagination path must not attach account fields, persist response metadata,
or synthesize TiebaLite's separate backward-PID request semantics.

The same anonymous post response may expose a dedicated first-floor object
outside the current physical reply page; loading it adds no request fields or
second request. Before presentation, it must have a positive post ID, floor one,
the same thread owner, and the exact declared first-post ID when that ID is
available. A valid in-page first floor takes precedence over the independent
field; malformed candidates are ignored and never enter the reply array. The PB
thread object's `post_id` may be an anchor PID and must not be treated as a
first-post identity fallback. The accepted first floor is filtered independently
and kept outside reply pagination, deduplication, prepend anchors, and PID cursor
selection. Origin-thread and poll
context may be attached only to this validated topic section. The app must not
reconstruct a missing first floor from a thread-list excerpt or persist its
response copy. The anonymous object alone cannot supply account state; an
approval control requires the separate exact-target authenticated validation
described above.

Parent-floor links, media, profiles, and copying reuse the same strict routing,
credential-free media, and text-projection policies as ordinary post content.
Parent and child filtering use one immutable rule snapshot; hiding the parent or
anchor must not expose filtered content, alter pagination identity, or synthesize
a pasteboard value. A visible parent or child may expose only the separately
authenticated, confirmation-gated approval or cancellation control described
above. Reply, `disagree`, downvote, create, edit, delete, report, and all other
authenticated write operations remain unavailable.

Internal navigation uses one strict parser for exact `tieba.baidu.com` HTTP(S)
forum/thread URLs, supported `com.baidu.tieba` forum/thread route text, and the
app-owned `tieba-plus-plus` forum/thread/user scheme. It rejects URL
credentials, nonstandard ports, fragments, extra or empty path components,
ambiguous or valueless state, empty or malformed forum names, and nonpositive
or overflowing identifiers. Supported cleartext HTTP input is converted only
to an internal route and never causes a cleartext network request; all resulting
content loads still use the credential-free HTTPS API client. Unrecognized
links fall through to the external-web policy below.

The external-web preference is evaluated only after that strict internal
router. It defaults to the system browser; the optional in-app path accepts only
an external HTTPS URL with a nonempty host and no URL user or password. External
HTTP links and other system-handled schemes are never passed to SafariServices.
Rich-content URL normalization also rejects embedded credentials and non-Web
schemes before rendering, and returns unchanged HTTP(S) URLs without rebuilding
their query or fragment unless a known host or scheme upgrade is required.
`SFSafariViewController` uses opaque, system-managed SafariServices website data.
It is presented directly with UIKit's default modal presentation and is never
embedded as a child view controller.
The app must not read its page, Cookie state, or navigation history; inject BDUSS,
headers, or scripts; persist the opened URL; or reuse the login Web view. After
presentation, redirects and website interaction are controlled by SafariServices,
not the app's API-host allowlist.

Only the app-owned scheme is registered. The app must not claim Baidu's scheme
or `tieba.baidu.com` Universal Links without domain authorization. It must not
read the clipboard automatically; the home-screen paste action uses the system
paste control and an explicit user gesture. User mentions create only an
app-owned positive-ID route and open the existing credential-free public
profile workflow.

Browsing history, local favorites, global search history, and per-forum search
history are separate versioned JSON archives in Application Support. They use
atomic writes, enforce bounded archive sizes, refuse to overwrite malformed or
future-version data, and are excluded from device backups. They must never
contain account credentials or private server responses. Global search history
stores only the trimmed public query and its local submission time.
An unreadable search-history archive may be deleted only through the explicit,
user-confirmed recovery action for that archive; ordinary reads and writes must
preserve it and must not delete the other search-history domain.

Local favorite pins add only an optional local timestamp to favorite schema v1.
They change presentation order but do not protect an entry from the existing
save-time capacity limit. Older builds that support favorite schema v1 can read
the archive but erase all pin timestamps if they later rewrite it, so downgrade
compatibility must not be described as metadata-preserving. Copying a saved
forum name requires an explicit context-menu action and writes only the
normalized public forum name; this feature must never read the clipboard or
copy account data.

The favorite-thread opening preferences are two default-off UserDefaults
booleans evaluated only after an explicit selection in the local-favorites
list. They may force only-thread-author or descending browse options, but the
resolver must preserve the saved thread identity, public metadata, and
post/floor position and must not rewrite the favorite archive by itself. The
existing thread workflow may subsequently persist the effective browse mode to
both local favorites and browsing history. Other entry points do not evaluate
these booleans directly, but a later history or ordinary opening may resume that
persisted mode; deep links continue to bypass stored snapshots. Turning an
override off is not a rollback operation. The feature must not read account
state or credentials and adds no network request.

The default-off username presentation preference is a local UserDefaults value.
It may display only the public nickname and username already returned by the
current anonymous or public-profile response and must not expose `tiebaUID`,
reply-target identities, account credentials, or add a lookup request. Live
models keep the two identity fields paired; search context fallback must never
combine one author's nickname with another author's username. Thread history
and local-favorite schema v1 records may add the trimmed public username as an
optional field; older records decode it as empty without migration or deletion.
User filter rules may match either exact returned name for the same author, with
user allow rules retaining precedence over user block rules only in that domain.

Local content-filter rules use their own bounded, versioned JSON archive in
Application Support with atomic writes and backup exclusion. It may contain
only user-entered literal keywords, public UID/name identities, display mode,
and the video-topic switch; it must never contain account credentials, cookies,
private responses, or hidden-content copies. Malformed, oversized, or
future-version archives must be preserved and must not be overwritten by
ordinary rule changes. Browsing fails open when the archive cannot be read, so
anonymous content remains available without loading credentials; deletion is
allowed only through the explicit reset action. Keyword matching is currently
case-sensitive and literal. Regular-expression rules must remain unsupported
until their runtime can be bounded or a non-backtracking engine is adopted.
Global thread-search, per-forum post-search, and public-profile thread responses
apply that same fail-open snapshot only after the anonymous response has
arrived. Filtering may annotate a result as visible, placeholder, or hidden,
but must preserve every raw ID, order position, page, and pagination decision.
A hidden final item or fully hidden page must still be able to trigger
pagination through an inaccessible raw-tail sentinel; the app must not reveal
the filtered row or repeatedly request a duplicate-only page. The public search
media marker may be used only to enforce the local video switch and must not add
a media request.

Raw-tail pagination applies only to content hidden by local rules. When a
public-profile response declares its activity hidden, that server privacy state
takes precedence: the UI must not render returned activity or create a sentinel,
and load-more plus retry paths must stop even if the response also contains raw
threads or advertises another page.

Per-forum search must evaluate the matched entity and its displayed topic or
parent-floor context independently. A keyword or user allow match in one field
or identity must not exempt a block match in the other entity, and filtering
must not alter the post or comment target used for navigation. A blocked context
may be replaced or omitted while a visible match remains navigable; a blocked
match must suppress the entire row, including its context. Context payloads do
not expose a video marker, so video blocking applies only to the matched entity.
Forum and user lookup remain outside this filtering boundary.

Remote media uses an ephemeral, credential-free session, rejects cleartext
requests or redirect destinations, and is decoded through ImageIO with a
bounded pixel size and memory cache. Original image dimensions are never
decoded directly into the browsing UI.

The content-media preference applies only to thread previews, rich-content
images, video covers, per-forum search media, and hot-topic images. Automatic
mode preserves unrestricted preview loading. Data-saving mode automatically
loads only while the observed path is available, non-expensive, and
non-constrained; unknown, unavailable, expensive, and Low Data Mode paths are
cache-first and require an explicit tap. Tap-to-load mode always uses that
cache-first behavior. The app uses one process-level path monitor and stores
only a transient availability/cost snapshot; it never reads an SSID, BSSID,
carrier identity, or local-network peer and does not probe a URL to classify
the network.

The image preview-quality preference is independent from that network policy.
Every standard, high-definition, and original candidate is normalized through
the existing HTTPS media policy before it enters the browsing model. Standard
quality remains the default; high-definition can select only the separately
accepted high-definition candidate and otherwise falls back to the accepted
standard candidate. Changing quality changes the existing URL-based request
identity and therefore cannot inherit a manual authorization or failed state
from another source. It does not alter request access flags, byte limits,
decoder bounds, cache keys, or the gallery's fixed
original-then-high-definition-then-standard selection.

A cold manually gated image performs an exact in-memory cache lookup and must
not create or join a network request until the user presses its load control.
That authorization is bound to the current HTTPS URL and requested pixel size;
changing either value or changing the persistent policy revokes it. A path
change alone must not revoke or restart an already authorized request. Once
that request reaches a terminal state, the effective policy is evaluated again:
a path that has become economical may start one restricted automatic attempt,
while a still-gated failure requires another explicit tap. The cache is
process-local and ephemeral, so this setting does not claim persistent offline
media or suppress the page-data requests needed to browse.

Automatic data-saving requests deny cellular, expensive, and constrained
network access on the `URLRequest` itself as well as in the path decision. The
same flags are reapplied after an accepted HTTPS redirect. Explicitly tapped
requests remain unrestricted, and restricted and unrestricted transfers for
the same URL and pixel size use different in-flight keys; the decoded memory
cache remains shared. This prevents a restricted waiter from silently joining
an already unrestricted transfer without fragmenting cached images by network
state.

The independent list-media collapse preference applies only to shared thread
cards and per-forum search media. A collapsed presentation retains only the
media type or full image count, contains no URL, and is selected before any
remote-image view is constructed; it therefore creates no list-preview request.
Collapsing an already rendered row removes that view and its download waiter.
The underlying deduplicated transfer is canceled when its final waiter leaves,
but may continue for another active view that requested the same resource.
Post bodies, hot-topic images, avatars, gallery and export paths, playback, and
page-data requests remain outside this preference. Expanded previews continue
to follow the separate automatic, data-saving, or tap-to-load policy.

Dark-appearance thumbnail dimming is a post-decode visual modifier only. When
enabled, successfully rendered static content images use a fixed 0.4 color
multiplier in dark appearance; light appearance and a disabled setting use the
identity multiplier. The preference must not enter a media URL, fetch policy,
reload ID, transfer key, decoder, or cache key, so changing it or the appearance
can redraw an existing image without creating or canceling a request. Video
covers, avatars, galleries, loading and failure placeholders, compact summaries,
badges, and playback controls remain outside this modifier.

Accent selection is also local presentation state. It stores only one bounded
enum value in UserDefaults and must not enter a request, URL, cookie, account
record, cache key, download policy, or content archive. Every palette entry has
fixed light, dark, and increased-contrast variants; arbitrary input and remote
theme data are unsupported. Semantic warning and destructive colors remain
independent, while image viewers and video overlays keep their explicit white
controls on black. System Web, Safari, and share surfaces continue to manage
their own appearance.

Manual image-cache clearing may evict only the process-local decoded-image
`NSCache`. It must advance a generation barrier so a transfer started before the
clear cannot later repopulate that old cache state. It must not cancel active
transfers, delete temporary download or export leases, clear system photo data,
or touch account, history, favorite, filter, or search archives. Currently
displayed images may remain retained by their views, and a later explicit or
policy-allowed image request may download again.

Avatars remain outside that content-media policy. Gallery originals, video and
voice playback, sharing, and saving already require a separate explicit user
action and retain those user-initiated paths. Rendering a video cover must not
construct an `AVPlayer` or start playback. When an automatic preview without a
manual authorization becomes gated, its content-view waiter is canceled; an
already authorized request keeps that authorization until it finishes. A
deduplicated transfer may continue only when another active, independently
authorized waiter still owns it.

Voice playback accepts only an initial HTTPS URL on the exact
`tiebac.baidu.com/c/p/voice` path, without credentials, an explicit port, or a
fragment. Its query must contain exactly one bounded, nonempty `voice_md5`
value and the fixed `play_from=pb_voice_play` value. The application supplies
no Cookie, Authorization, BDUSS, STOKEN, account identity, device metadata, or
custom request header when it constructs the AVFoundation item. AVFoundation
remains subject to the platform's normal TLS and App Transport Security
handling; no cleartext exception or custom certificate trust is introduced.

Voice sharing revalidates that exact URL and uses a separate ephemeral URLSession
with no Cookie store, URL credential store, cache, authorization field, custom
header, or account data. It rejects every redirect, every status other than 200,
`Content-Range`, non-identity `Content-Encoding`, empty responses, and declared
or observed bodies above 16 MiB. Only default platform server-trust handling is
allowed. Response MIME and suggested filenames are untrusted and ignored.

The completed local file must have MP3, AMR, AMR-WB, or AAC bytes. AMR and
AMR-WB storage files are traversed frame by frame with valid padding and frame-
type lengths to exact EOF. A private extension-hinted copy is then inspected by
AVFoundation with external media references forbidden; it must be playable,
contain audio, contain no video, and have a finite positive duration within 24
hours. The final share filename uses the format's canonical `.mp3`, `.amr`,
`.awb`, or `.aac` suffix. The system share sheet receives only that validated
local copy. A unique lease owns the directory until sharing finishes or is
dismissed, and failure, cancellation, source changes, and view disappearance all
remove it. Voice export is never placed in a persistent cache or log and requests
no Photos permission.

Video playback accepts only an initial absolute HTTPS URL whose complete UTF-8
representation is at most 8,192 bytes and contains no control character. It
must have a nonempty host and no credentials, explicit port, or fragment. The
application adds no Cookie, Authorization, account identity, device metadata,
or custom request header when it constructs the `AVPlayerItem`. This is an
initial-source boundary, not a custom redirect-host allowlist: TLS validation,
App Transport Security, and redirects remain under AVFoundation's normal
platform handling. The app adds no cleartext exception, custom certificate
trust, redirect rewrite, or redirect credential injection.

One main-actor application coordinator issues at most one opaque playback lease
across voice and video. A new voice or video lease is installed before the old
participant is synchronously revoked, and a controller accepts a revocation
only when its exact lease still matches. Each loaded source also receives a
random session identity, while player-item completion and failure events are
matched to the current item. Late lease revocations, progress, completion,
failure, interruption, and native-player state events from a replaced session
therefore cannot mutate or stop its successor. Native AVKit play and pause
controls reacquire or release the same lease instead of bypassing arbitration.

The video controller owns one player and creates it lazily only after a valid,
explicit start; rendering a cover cannot allocate a player or item. Full-screen
presentation uses the same player and tracks entering, presented, exiting, and
inline states with owner and session identities. If the owner disappears or its
source changes during presentation or a transition, playback pauses immediately
but destructive item cleanup remains pending until a transition outcome
confirms the player is inline. Owner and session checks prevent stale callbacks
from cleaning up a replacement session. A cancelled entry confirms inline and
may finish only its matching pending cleanup; a cancelled exit remains
full-screen and keeps cleanup pending. A different video cannot replace the
item while the current player is non-inline. Picture in Picture and automatic
Picture in Picture startup are disabled.

Server-declared and AVFoundation voice durations are accepted only as finite
positive values within a 24-hour presentation bound; elapsed positions and
seeks are clamped to that duration. An inactive app scene atomically clears the
current media lease and pauses its participant. Returning active grants no new
lease and never resumes voice or video automatically. Audio interruptions,
removal of the current output device, or disappearance of the owning control
also pause or reset the applicable session. The target does not declare a
background audio mode, and media is not played automatically or exposed through
lock-screen controls; explicitly shared voice content is temporary and is not
cached persistently or logged.

High-resolution profile-avatar derivation is a source-construction boundary,
not a remote-media redirect-host allowlist. The untrimmed raw source is limited
to 4,096 UTF-8 bytes. After surrounding whitespace is removed, a bare source
must be a 1-through-512 byte ASCII token from `[A-Za-z0-9._~-]` other than `.`
or `..`. A URL-shaped source may use only HTTP, HTTPS, or protocol-relative
syntax; the exact `tb.himg.baidu.com` or `himg.bdimg.com` host; no credentials,
explicit port, or fragment; one of the `/sys/portrait/item/`,
`/sys/portraitn/item/`, or `/sys/portraith/item/` prefixes; and one token path
segment that remains valid after exactly one percent-decoding pass. Either form
may omit a query or carry exactly one cache-buster consisting of `t=` followed
by 1 through 20 ASCII digits. The app strips that query and rebuilds every
accepted source as `https://himg.bdimg.com/sys/portraith/item/<token>`. Encoded
separators, double encoding, malformed percent sequences, other or repeated
queries, unrelated HTTPS media hosts, and all other structures are rejected.
Rejection falls back only to the separately normalized regular portrait. It
does not change the credential-free media transport or broaden/narrow that
transport's existing HTTPS redirect checks. The separately derived large source
is not placed in a remote-image view until the user presses the profile avatar;
sharing and saving remain further explicit actions using the same bounded
original-file exporter.

Thread-list previews and author avatars reuse that same media pipeline. A bare
topic portrait is converted by the existing regular-portrait builder; a
URL-shaped search portrait must pass HTTPS media normalization. Per-forum search
must reject a `mainPost` or `postInfo` whose thread ID differs from the outer
result, then use the portrait belonging to the first matching context
(`mainPost`, then `postInfo`) that supplies the card's author identity, never the
independently matched reply or comment author. A floor portrait may fill a
missing history or favorite portrait only after exact positive thread-author UID,
thread ID, and thread-author-flag checks; a merely valid first-floor identity is
insufficient. Neither a locally hidden/placeholder thread nor a nonvisible floor
may supply that stored fallback.
Metadata badges, portraits, and read-only counters come only from existing
anonymous responses; rendering a card must not introduce a personalized
request, autoplay video, or broaden the media host policy. Author-avatar views
may be constructed only for ordinary, locally visible rows on surfaces that
show the author. Pinned cards request neither an author avatar nor preview media,
and filtered placeholders or hidden rows construct no card content. Public
profile thread lists suppress only the redundant author avatar; their existing
content-preview policy remains unchanged. An invalid media URL remains absent
rather than becoming a fallback cleartext load. Automatic and explicitly
requested content previews have a 16 MiB transfer-time limit; the task
delegate cancels a response as soon as either its declared or observed byte
count exceeds that bound. Explicit higher-resolution image views retain the
80 MiB transfer limit. Deduplicated downloads track active view waiters and are
canceled when the final waiter disappears, so scrolling cannot leave orphaned
preview transfers running in the background.

An image gallery always starts from the already filtered `BrowseContent` array
that owns the tapped image. Whole-thread expansion is available only for an
ordinary topic floor after a fresh local filter snapshot confirms there are no
rules, including allow-only rules, and video-topic blocking is off. Snapshot
read failure is fail-closed. A filter notification, thread-option change,
dismissal, or navigation away cancels the metadata tasks and discards the
session. Nested replies, shared origins, search results, rules, profiles, and
filtered floors must never receive whole-thread context.

Whole-thread metadata uses a signed form POST to the exact HTTPS origin
`c.tieba.baidu.com`. Its fields are limited to public forum/thread/picture
cursors, fixed endpoint mode/version values, and direction counts. It must not
send BDUSS, STOKEN, user ID, cookies, CUID, IMEI, client ID, screen dimensions,
model, timestamp, or network metadata. The ephemeral transport ignores the
response `Set-Cookie`; same-origin HTTPS is the only permitted redirect. The
response is limited to 1 MiB during transfer, then bounded and validated for
forum ownership, total count, ordered global indexes, picture IDs, post IDs,
dimensions, byte counts, blocked flags, and exact known Baidu media hosts.
Observed HTTP media URLs are upgraded only on that exact host allowlist; any
other cleartext or malformed URL is rejected. Repeated picture IDs remain
separate occurrences when their global indexes differ.

Zoom continuity does not broaden that identity or privacy boundary. Within one
gallery context, the view model may emit an explicit local-to-remote migration
only when the complete local snapshot and currently accepted remote window each
contain exactly one occurrence with the same nonempty picture ID and positive
post ID. URLs, source offsets, image ordinals, and list positions must never be
used to guess the relationship; global indexes remain part of remote occurrence
identity, not substitute matching evidence. Ambiguous candidates produce no
initial migration: the local fallback is retained when replacement cannot be
proven, and any otherwise new destination begins at identity rather than receiving
guessed state. Once committed, the mapping remains bound to that explicit remote
occurrence for the gallery context and is not reassigned if a later page repeats
the server representation. An existing destination state takes precedence over a
migrated source state.

The explicit migration map and bounded zoom-state LRU are process-local memory
only. They must not enter requests, logs, analytics, archives, backups, or other
persistence. A gallery-context or local-snapshot replacement, or disabling remote
loading, clears both, and late work from the prior context must not restore either
one. Enabling remote loading from the initial local presentation preserves its
viewer identity so a user interaction can migrate with the accepted occurrence.
If an interactive or programmatic page transition is active, migration, list,
selection, and accessibility metadata changes are coalesced and applied atomically
only after that transition resolves; stale pending work is discarded on reset.

Zoomed-image paging uses one gesture owner for the lifetime of each touch
sequence. After a one-finger drag exceeds the system movement threshold, the
native pan recognizer's dominant axis and direction plus the current clamped
image boundary decide whether the image pan or native pager owns it. An
image-owned drag must not transfer to the pager merely because it reaches a
boundary; ownership changes only after lift or cancellation, so the next
outward drag may page while an inward drag continues panning. Two-finger input
is reserved for image zooming and must never start paging. These rules apply
symmetrically to horizontal and vertical modes; axis changes rebuild the pager
rather than reassigning an in-flight gesture. Pixel-scale edge classification
and recognizer hierarchy are XCTest-covered; real touch sequencing is a device
validation requirement before release.

Gallery progress is derived only from the existing credential-free image
download's observed and declared byte counts. Transfer limits are evaluated
before a progress event is published. A percentage is available only while the
declared length is positive, stable, and no smaller than the observed bytes;
unknown or inconsistent lengths remain indeterminate.
Every physical transfer, repository waiter, and SwiftUI loading attempt has a
separate identity so a canceled same-URL transfer cannot publish into its
replacement. Cache hits publish no fabricated network progress, and clearing
the decoded cache neither cancels nor resets an active transfer's progress.
Sharing and saving are explicit user actions and operate only on the currently
selected HTTPS image. They reuse the credential-free media transport, its HTTPS
redirect and 80 MiB transfer limits, and a private temporary-file lease. Before
the file reaches a system consumer, ImageIO and Uniform Type Identifiers must
confirm a supported image with positive, bounded dimensions. Every frame is
decoded at a small validation size, while the frame count and cumulative pixel
count are also bounded; URL suffixes and response MIME types are not trusted.
Temporary files are excluded from backup and removed after the share sheet or
Photos change finishes.

Saving requests PhotoKit `.addOnly` authorization only after the user presses
the save control. A denied or restricted state must cause no image download, and
the app must not request read access, enumerate the photo library, or persist an
asset identifier. System sharing requires no Photos permission and receives the
validated local original file, not a credential-bearing URL or a downsampled
re-encoding. Gallery export must not add cookies, URL credentials, analytics,
background transfers, or authenticated Tieba fields.

Latest-reply checks are explicit, credential-free requests to the same public
thread endpoint. They use the raw final post ID as pagination state even when
that post is locally hidden, because local filtering must not alter the server
cursor; only the server-issued public ID is sent back, never the hidden content
or local filter rule. The response passes through the existing ownership, ID,
deduplication, and local-filter checks before display. Empty or duplicate-only
responses must not replace the loaded snapshot, and automatic polling remains
unsupported.

Appearance, app text-size adjustment, and forum-sort preferences may store only
bounded, nonsecret local values in UserDefaults. Text-size adjustment is a
presentation-only offset from the current system Dynamic Type category and must
not enter requests, account storage, archives, logs, or exported content. The
no-history control must update the recording flag in
the existing browsing-history archive and must never duplicate that state in a
second store. Full-floor copying is initiated by an explicit user gesture and
may include decoded public textual fragments and fixed non-URL media boundary
markers only; it must not add media URLs, credentials, account responses, or
hidden nested replies to the pasteboard.

The hide-reply-entry preference is a default-off, nonsecret local Boolean and
must not itself issue a request or read account storage. While enabled, topic,
floor, nested-reply, and inbox quick-reply controls are not constructed, and
their actions recheck the current policy before presenting a composer. An inbox
reply intent is rejected before the account vault is read; enabling the setting
also invalidates any pending or resolving intent so a late account result cannot
open a composer. This presentation preference must not hide reply content,
ordinary notification navigation, copying, or agreement controls, and it must
not erase a draft or close a composer that is already open. Account-session
changes retain their stricter existing behavior and may still invalidate an
inbox-originated composer whose credential binding is no longer current.

Home-entry preferences are also nonsecret UserDefaults values. The start target
must resolve through the closed home, post-ranking, hot-topic, local-favorite,
or browsing-history enum, with unknown values falling back to home; it must not
store a URL, query, forum name, content identifier, or account destination. The
resolved value is snapshotted once when the app process starts and must not
redirect an active session. A supported external forum, thread, or user link is
appended above the startup destination through the same strict router. Hiding
the discovery section changes only local home presentation and must not broaden
any destination, request, clipboard, or credential boundary. Its explicit paste
control is not constructed while hidden, and no replacement clipboard read may
be introduced elsewhere.

Automated tests use synthetic fixed-length placeholders only. Real `BDUSS`,
`STOKEN`, `tbs`, cookies, passwords, or private account responses must never be
placed in GitHub Actions secrets or exercised by CI. A write-capable prerelease
must remain identified as a validation build until a disposable test account has
exercised approval and cancellation for a topic, an ordinary post, a complete-
page parent, and a complete-page child. Device validation must cover an already-
settled no-write result, explicit server failure, uncertain transport failure
followed by exactly one readback and no second write, same-account concurrent
targets proving account-level serialization, identical-operation sharing,
opposite-operation reconciliation, logout, a `sessionRevision` rotation, and a
switch to a different UID while reads or writes are in flight. It must also
confirm that shared batch reads do not duplicate requests, scope removal stops
protecting removed targets, a late batch cannot overwrite a confirmed write or a
new account, signed-out browsing makes no authenticated call, inline previews
remain static, and complete-page parent and child controls both require explicit
confirmation. Check-in validation must additionally cover an unfollowed forum,
missing sign state, already-signed idempotence, returned-UID mismatch, and the
same-forum follow/check-in exclusion rule. Cloud-favorite validation must cover
list and thread-detail remove, add, saved-position update, an unresolvable deleted
row, raw thread/forum mismatch, an already-matching no-write result, malformed
or mismatched PB state, valid/random/cross-account/expired STOKEN, a known server
failure, an uncertain write followed by exactly one readback and no second write,
nominal success followed by mandatory readback, identical-operation sharing,
conflicting-operation read-only reconciliation, logout, same-UID session
rotation, and a switch to another UID while either read or write is in flight.

Report security issues privately to the repository owner rather than opening a
public issue.
