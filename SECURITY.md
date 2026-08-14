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
operation. Forum and user follow/unfollow, user interaction-permission, and
check-in writes may carry the fixed, noncredential header `Cookie: ka=open`;
they must not attach a stored cookie jar.
Authenticated account, followed-forum, forum-state probe, and write responses
have endpoint-specific transfer limits before decoding. MD5 is used only for
compatibility with the unofficial request signature protocol, not for password
storage or verification.

The current, not-yet-tagged self-profile summary requires a complete validated
BDUSS/STOKEN session. It sends one HTTPS Protobuf request to the exact
`tiebac.baidu.com/c/u/user/profile` path with command `303012`. The outer
multipart body contains only STOKEN and the protobuf file; the inner common
message contains only BDUSS, STOKEN, client type, and the fixed V12 client
version. The request carries the expected UID in `client_user_token` and only
the fixed noncredential value `ka=open` in the Cookie header. It must not add a
CUID, IMEI, Android ID, IDFV, hardware/install identifier, model, screen,
location, advertising value, stored cookie jar, or Authorization header.
Responses are limited to 2 MiB and must contain the exact positive requested
UID. Text and count fields are bounded before reaching the App, and portrait
values pass through the existing secure portrait URL builder. The App reads the
active Keychain session before and after transport and publishes only while the
exact `userID + sessionRevision` lease remains current. The summary is memory
only: it is not written back to Keychain, local preferences, caches, analytics,
or logs. Failure may retain a snapshot only for that same lease; logout,
switching, or same-UID credential rotation clears it synchronously. Successful
minimal-field compatibility and server-side account binding remain physical-
device validation questions; CI uses synthetic credentials and fixtures only.

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

Optional followed-forum avatars and slogans are decoded only inside the same
bounded authenticated response; displaying them does not issue a second metadata
request. Core trims and bounds both fields and drops control-bearing values. The
App normalizes an avatar through the shared media URL boundary, then exposes it
to the remote-image pipeline only when it is HTTPS, credential-free, uses the
default HTTPS port, and belongs to an exact Baidu CDN suffix allowlist. A rejected
or missing avatar falls back locally. Every redirect and the final response URL
must satisfy that same scoped policy; a disallowed redirect is not followed.
Scoped avatar requests cannot reuse or populate the generic persistent image
cache; decoded in-memory entries and in-flight work are isolated by policy. An
absent slogan leaves the existing level and experience presentation intact.
Neither field affects forum identity,
pagination, recommendation filtering, navigation, or any account write.

These surfaces remain read only with respect to Tieba: displaying, paginating,
or locally reordering them must not follow, unfollow, check in, or issue another
account request automatically. Their context menus may update only the separate
local pin archive or explicitly copy the public forum name; they offer no inline
server unfollow or batch check-in control. The endpoint response does
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
stored values are replaced locally. Responses are limited to 4 MiB. Because a
short raw page can be followed by later nonempty pages, every nonempty page may
continue, but an empty page stops immediately. Each explicit action may cross at
most five consecutive pages whose raw entries all fail mapping before another
explicit continuation is required. A refresh may traverse duplicate-only pages
up to the page frontier already reached by that client; beyond it, at most one
additional duplicate-only page may advance before a second stops the request
chain. The default-off followed-forum filter never adds
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

A floor-level cloud-favorite action is derived only from a retained public post
whose positive ID, positive floor, thread ID, and local visible state match the
current thread target. Its confirmation captures the complete authoritative
pre-mutation snapshot. Immediately before dispatch, the App and Store both
require that exact target and snapshot still be current; add and update also
require the identical retained post ID and floor. The Store repeats this check
after its asynchronous account-session preflight and rejects a competing
mutation flight. A stale confirmation therefore performs no write and cannot
remove or overwrite a marker changed by another surface. Loading, mutating,
failed, signed-out, locally filtered, and pure-reading floor presentations offer
no mutation action. The floor marker is read-only presentation derived from the
authoritative or last confirmed snapshot; the requested write PID is never used
optimistically.

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

Inbox filtering is a local presentation projection over the retained private
response. It may inspect only `message.content` and the sender's UID, nickname,
and username. The title, quoted content or author, forum label, `quote_pid`, and
other routing fields must not participate. A placeholder may disclose only a
generic blocked-message label and must construct neither a navigation
destination nor a reply control; a hidden message must construct no row. The
original message IDs, order, current page, and has-more state remain authoritative.
A rule-change notification may only reread the local archive and reproject the
already loaded array; it must not refetch those pages. If another page exists,
automatic pagination pauses until the user explicitly continues. A failed reread
retains the last successfully accepted in-memory snapshot, while a first-load
failure uses the empty snapshot. This fail-open behavior is a presentation
preference, not a confidentiality or access-control boundary.

The foreground unread summary uses a separate signed HTTPS `/c/s/msg` form that
contains only BDUSS, `_client_version=8.2.2`, `bookmark=1`, and `sign`. It sends
no Cookie, STOKEN, client UID header, CUID, hardware identifier, model, screen
metadata, or telemetry. The response is capped at 64 KiB and must contain a zero
error code plus bounded nonnegative integer `replyme` and `atme` values;
`fans` is optional, remains unavailable when absent or null, and is validated
when present. It is excluded from the message badge and may only drive a
separate fan-reminder presentation for the same active account.
Because the envelope does not independently identify the account, its UID is
request context rather than server proof. The App checks the same
`userID + sessionRevision` lease before and after the request and synchronously clears the
snapshot on logout, switching, or same-UID credential rotation. The inbox
performs no background polling, explicit mark-read request, or local badge
clearing. The fan-reminder entry opens the existing credential-free public
follower list, not an authenticated notification endpoint; opening it does not
locally clear `fans`. No baseline is persisted or compared, and the App does not
claim that a reminder count identifies new followers or that a profile-count
change identifies follows or unfollows. An implicit server-side unread change
caused by summary or list retrieval remains a documented real-device validation
question. Local inbox filtering must not alter the raw `replyme + atme` summary,
the optional `fans` value, or either badge.

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

Follow, unfollow, check-in, poll voting, topic, post, or nested-reply approval or
cancellation, and each supported text/classic-emoticon topic, floor, or nested-reply
submission, plus equivalent new-topic creation, all require explicit user
confirmation. For reply and new-topic creation, this confirmation must bind an
immutable target-and-content snapshot immediately before dispatch. Editing,
dismissing the confirmation, changing the account session, or leaving the page
invalidates that snapshot. The configurable composer-entry risk notice is
advisory and must never satisfy this confirmation requirement. Automatic,
scheduled, and batch check-in are deliberately unsupported. `disagree` or
downvote, rich-media topic/reply creation, editing, deletion, native reporting, and
every other authenticated content write remain unsupported and must not be
inferred from the approval, reply, or new-topic endpoints.

Text and fixed-catalog classic-emoticon replies use only the existing signed
protobuf `309731` endpoint for topic, ordinary-floor, and nested-reply targets.
The composer accepts ordinary text plus exact `#(name)` tokens from the compiled
50-name catalog; unknown, malformed, nested, image, `reply`, and every other
user-supplied rich marker fail closed before a request is built. A visible inline
nested-reply preview can open the same composer only after the current post
snapshot rebinds one unique visible comment to its thread and parent IDs. For a
nested write, the protocol-owned `reply` marker is built only from freshly read
target identity fields, and marker separators or parentheses in those fields
invalidate the response rather than being interpolated. A positive receipt is
confirmed by one exact-ID readback whose text bytes and type-2/type-11 emoticon
tokens match the frozen submission; text that merely resembles an emoticon is
not equivalent. No dispatched write is automatically retried.

Poll voting requires a complete validated BDUSS/STOKEN session and a separate
authenticated PB Page read. That response, rather than the anonymous result card,
must bind the expected account UID, forum ID, and thread ID and supply the
authoritative poll state. Every option ID must be positive and unique; returned
selected IDs must be a subset of those real option IDs and must agree with the
single- or multiple-choice flag. The App may construct a vote only while the
authoritative poll is open, the account has not already voted, and the requested
selection has legal cardinality and contains only those IDs. Option position,
label text, vote count, and anonymous presentation state must never become a
write target.

After explicit confirmation, Core may send at most one PB POST to
`https://tiebac.baidu.com/c/c/post/addPollPost?cmd=309006&format=protobuf`.
The authenticated state read uses the `12.52.1.0` PB Page protocol family. The
write multipart request contains only the PB payload plus `BDUSS`, `_client_type`,
`_client_version=11.10.8.6`, and `stoken`, with the endpoint's Mozilla-style
`tieba/12.35.1.0` user agent; it must not add CUID, IMEI, Android ID, OAID,
IDFV, advertising ID, model, hardware, installation, location, screen, or other
telemetry fields. The payload carries the exact forum and thread IDs plus a
canonical list of real selected option IDs. Redirects remain rejected and the
ordinary TLS and response-size boundaries remain in force.

A poll write response is only an acknowledgement. Every dispatched vote,
including one followed by a server, decode, cancellation, or transport error,
must perform exactly one authoritative authenticated PB readback. The write is
never retried. The authenticated client may single-flight the entire operation
only for the same resource, credential, and canonical selection. A different
selection or credential waits for the active flight and then performs only that
read; it must not enqueue a second vote. The App additionally binds reads,
writes, and publication to the initiating `userID + sessionRevision` lease and
discards results after logout, account switching, or same-UID credential
rotation. Until a disposable account validates minimal-field acceptance and the
success, rejection, uncertain, concurrency, cancellation, and lease-race cases,
poll voting remains a validation-build feature.

Text and fixed-catalog classic-emoticon new-topic creation requires a validated complete BDUSS/STOKEN session
and a fresh authenticated FRS preflight binding the exact UID, positive forum ID,
canonical forum name, trusted display name, and valid TBS. It may then send at
most one signed HTTPS POST to `https://tiebac.baidu.com/c/c/thread/add`. The form
uses the observed fixed mini-client fields plus only the credential, forum,
title, body, display name, and TBS needed by that endpoint. The contract's
`cuid_gid` and `z_id` values remain empty; it must not add an IMEI, Android ID,
OAID, nonempty CUID/ZID, model, screen, location, installation history,
advertising data, or randomized telemetry, and every redirect is rejected.

Titles are optional and bounded to 31 Swift characters and 124 UTF-8 bytes;
bodies use the reply policy's 10,000-character and 32 KiB wire-text limits. Titles reject
control characters and all markers; bodies preserve CR, LF, and tab while rejecting other
unsupported controls. Only the fixed compiled classic-emoticon catalog may emit
complete `#(name)` tokens. Unknown, malformed, nested, image, `reply`, and every
other user-supplied rich-content marker are rejected without normalization. The
catalog contains names only: no remote or copied emoticon artwork is bundled or
downloaded. An identical submission
UUID shares one owner, conflicting reuse fails, and all new-topic writes for one
UID are serialized. Cancellation before dispatch performs no write. Once the
write is dispatched, it is never automatically retried: an unparseable receipt,
transport loss, or mismatched authenticated readback becomes an unknown outcome.
A positive TID/PID is confirmed only by an exact account, forum, thread, first-
floor author, explicit-title, and structured text/emoticon body match. A missing first floor remains
accepted-awaiting-visibility; an untitled topic may accept a server-generated
display title only when every other proof matches.

The App stores new-topic drafts in a bounded, versioned atomic archive keyed by
the account UID and exact forum identity. The archive contains title, body,
submission state, receipt when available, and timestamps, but no credential,
TBS, trusted display name, or private response. It is excluded from backup and
uses iOS file protection. A submission-pending marker must reach disk before the
write. Challenge, accepted, and unknown states are non-sendable across
navigation and restart; an explicit new login is required to unlock a challenge.
A confirmed submission is retained as a bounded receipt tombstone until the user
explicitly starts another topic in that forum. The App must not clear it merely
because the write task returned: a crash before the success navigation became
visible would otherwise restore an apparently sendable old body.

Current `main` also contains a non-user-facing static-image creation foundation.
The App accepts only bounded, single-frame JPEG, PNG, HEIC, or HEIF input and
always redraws it onto an 8-bit controlled sRGB surface before producing a new
JPEG. Standard output is bounded to a 1,080-pixel longest side and 5 MiB; high-
quality output has a 4,096-pixel longest-side ceiling and 10 MiB byte ceiling,
while a separate total-pixel budget may reduce either dimension to keep decoding
and redraw memory bounded. Alpha is flattened onto white. The encoded JPEG is
accepted only after a marker-level dimension check, metadata-segment stripping,
ImageIO property inspection, and a bounded full decode.

Attachment metadata stores only a random UUID filename, SHA-256, byte count,
dimensions, encoding, and local quality choice. Source paths, filenames, Photos
asset identifiers, URLs, and image metadata are not retained. Files live below a
trusted Application Support root, are excluded from backup, use complete file
protection, and are read through a no-follow regular-file descriptor with size,
inode, digest, JPEG, and dimension validation. Directory-chain checks reject
symbolic-link redirection. Publication and deletion still use Foundation path
operations, so a hostile writer already executing inside the same App sandbox
could race those checks; eliminating that residual threat requires a future
directory-descriptor `openat`/`renameat`/`unlinkat` store.

Core's draft upload contract sends sequential 512,000-byte multipart chunks only
to the exact `https://tiebac.baidu.com/c/s/uploadPicture` origin. It validates the
complete BDUSS/STOKEN session with independent same-UID App and Web probes,
single-flights only an identical full credential and upload identity, uses a
per-request boundary that cannot occur in scalar values or binary content, and
limits every response to 64 KiB. The signed scalar set contains no CUID, IMEI,
Android ID, OAID, IDFV, model, hardware, location, or advertising identifier.
Once a chunk is dispatched, cancellation cannot cause an automatic resend; an
ambiguous transport or response failure becomes an outcome-unknown result. A
decoded receipt is only syntactically valid until it is rebound to the original
bytes, upload UUID, expected UID, canonical forum, options, digest, resource ID,
uploaded dimensions, byte count, and chunk count. That rebinding cannot by itself
authenticate a format-valid replacement of server-originated `picID`, width, or
height after persistence; the current App neither persists nor consumes these
receipts, and the future durable transaction must address that server-result
integrity boundary before compiling an image marker.

None of this code is reachable from a composer yet. There is no picker, durable
upload ledger, protocol-owned image-marker compiler, final post snapshot, or
restart recovery path, so `main` must continue to reject user-supplied image
markers and rich-media creation remains unsupported until the complete workflow
and its disposable-account validation are present.

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
app must not infer hidden entries or describe an empty or partial preview as the
user's complete forum list.

The separate complete liked-forum list is an authenticated, read-only
`POST https://tiebac.baidu.com/c/f/forum/like` request. Before signing, a self
request contains exactly BDUSS, `_client_version`, one-based `page_no`, bounded
`page_size`, and the active account `uid`; the final form adds only `sign`. An
other-user request adds exactly the positive target `friend_uid` and
`is_guest=1`, while `uid` must remain the active account. Neither form may add
STOKEN, Cookie, Authorization, CUID, IMEI, Android ID, model, screen, network, or
another device or account field. Responses are limited to 2 MiB. When present,
`has_more` must be binary; an omitted flag uses the endpoint schema's final-page
default. Known forum groups remain bounded and rows require valid positive
identities.

Core's account and target IDs on a returned page are request context carried by
the client, not server proof of identity. The App must bind every page to the
active account UID, `sessionRevision`, target UID, and requested page, read the
vault before and after transport, and discard results after logout, account
switching, or credential rotation. This list remains memory only, initiates no
write, and must never populate or mutate the global current-account followed-
forum index used by home and recommendation filtering. Missing login state sends
no request. Physical-device validation must cover self and other-user pages,
pagination termination, empty/privacy responses, expired credentials, account
switching, and absence of follow, check-in, or other side effects.

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
mirror is authoritative only when its decimal TID exactly matches the requested
outer thread. A missing, malformed, mismatched, or shared origin poll must never
be attributed to that outer thread. The
anonymous UI is strictly read-only and must not expose account selection state,
collect votes, call a submission endpoint, or attach account credentials. Any
interactive control must be backed by the separate authenticated state and vote
contract above; the anonymous object can provide presentation fallback only and
must never authorize or target the write.
Pure-reading mode renders only that anonymous result snapshot: entering it
cancels and clears the presentation's authenticated poll task, account changes
cannot restart that task while the mode remains active, and leaving the mode is
required before a fresh account-bound poll read can begin.

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

Parent-floor links, media, profiles, and text selection/copying reuse the same
strict routing, credential-free media, transient selection panel, and
text-projection policies as ordinary post content.
The report entry is not an authenticated App write. For an exact visible topic,
floor, or nested reply, the anonymous client may POST only `category=1` and the
positive post ID to the exact HTTPS `checkjubao` endpoint with cookies disabled,
a 64 KiB response limit, and no redirects. The response URL must remain bound to
that ID and is rebuilt from exact `tieba.baidu.com` host, report path, and fixed
query fields as HTTPS. It opens only in `SFSafariViewController`; the App does
not inject BDUSS/STOKEN, read browser cookies, inspect the page, infer a submit,
or retry a report. It also cannot verify that Safari's Baidu account matches the
active App account; the user must check the identity on the official page. A
browser login, captcha, or SMS challenge may still be required. Image and
private-message evidence remain outside this boundary.
Parent and child filtering use one immutable rule snapshot; hiding the parent or
anchor must not expose filtered content, alter pagination identity, or synthesize
a pasteboard value. A visible parent or child may expose only the separately
authenticated, confirmation-gated approval or cancellation control described
above. Reply, `disagree`, downvote, create, edit, delete, native report
submission, and all other authenticated write operations remain unavailable.

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
The About page may expose only the code-defined, credential-free
`https://github.com/Minaduki-Shigure/tieba-plus-plus-swift` target after an
explicit tap. It must validate that exact HTTPS host and path, use the same
external-Web preference, and pass only the validated URL to either browser path.
The destination must not be derived from Bundle metadata, account state, remote
data, a deep link, or user input; opening the About page itself must not issue a
request or read account storage.

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

Followed-forum pins use a separate schema-v1 JSON archive. Each record contains
only a positive account UID, positive forum ID, normalized bounded public forum
name, and local pin timestamp. The archive is size- and count-bounded, written by
atomic replacement, excluded from backup, protected after first device unlock on
iOS, and refuses to overwrite malformed or future-schema data. Projection requires
the same account plus an exact forum ID and normalized name already present in the
loaded authenticated snapshot. Missing, renamed, or not-yet-loaded rows are not
fabricated and do not trigger pagination or metadata requests. Pin mutations are
serialized; account/session changes clear visible pin state synchronously, and a
late old-account result cannot publish into the new account. Confirmed unfollow
removes only the matching account/forum record. Copying remains an explicit write
of the public forum name to the pasteboard and never reads existing clipboard data.

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
a media request. The foreground inbox is intentionally stricter after a rule
change: it retains the same raw pagination state but requires an explicit user
action before another private page request.

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
decoded directly into the browsing UI. System HTTP caching remains disabled.
After successful ImageIO validation, HTTPS image bytes fetched without account
Cookie or Authorization headers may enter a separate application cache in
`Library/Caches`; account responses, cookies,
headers, credentials, voice, and export temporary files never enter it.

The persistent cache uses a SHA-256 key for the exact requested URL and never
writes the URL, query, MIME type, response filename, or headers to metadata.
Fragment-bearing or over-8-KiB URLs are rejected from persistence. Metadata is
versioned and contains only a random entry identifier, byte count, payload
SHA-256, and creation/access timestamps. Entries expire after seven days and are
bounded to 256 MiB and 1,024 records. Every read rejects symlinks, nonregular
files, unexpected byte counts, digest changes, nonfinite or expired timestamps,
and the wrong preview/original size class. Finite timestamps are normalized to
milliseconds; clock-skewed future access times are clamped to the current time and
the stored time is clamped no later than that access. A successful hit writes the
clamped values back, so a wall-clock rollback cannot make an entry immortal. A hit
is copied to an independent UUID temporary lease and revalidated before ImageIO,
sharing, or PhotoKit use.

An observed `dynamic` URL is an independently normalized media candidate, not
an animation flag. Animation requires ImageIO to identify a supported real
multi-frame GIF, WebP, or HEIC/HEIF sequence from the downloaded bytes. A
single-frame container, ordinary multi-image HEIF, unknown type, malformed
frame, more than 500 frame metadata entries, or an input that cannot fit the
16 MiB decoded-frame bound must fall back to a bounded static poster. Invalid,
nonfinite, nonpositive, or sub-20 ms frame delays normalize to 100 ms. Later
frames are decoded on demand through at most two concurrent ImageIO operations
and enter one process-wide cache capped at 64 MiB and 1,000 entries, costed by
`bytesPerRow * height`.

Animation playback is presentation state and must not enter the URL, transfer,
manual authorization, retry, or cache identity. It runs only while the view is
attached, the scene is active, Reduce Motion is disabled, and its surface owns
playback. The zoom gallery grants ownership only to its visible page, retains
the starting page through an interactive transition, and transfers ownership
only after completion. Leaving the view, cancelling a page transition,
backgrounding, or disabling playback invalidates the display clock and prevents
elapsed background time from being replayed as a frame burst. Animation is not
added to the voice/video playback coordinator.

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
Every standard, high-definition, dynamic, and original candidate is normalized
through the existing HTTPS media policy before it enters the browsing model. Standard
quality remains the default; high-definition can select only the separately
accepted high-definition candidate, then the accepted dynamic candidate, and
otherwise falls back to the accepted standard candidate. Changing quality
changes the existing URL-based request identity and therefore cannot inherit a
manual authorization or failed state
from another source. It does not alter request access flags, byte limits,
decoder bounds, cache keys, or the gallery's fixed
original-then-dynamic-then-high-definition-then-standard selection.

A cold manually gated image performs exact in-memory and persistent cache lookups
and must not create or join a network request until the user presses its load control.
That authorization is bound to the current HTTPS URL and requested pixel size;
changing either value or changing the persistent policy revokes it. A path
change alone must not revoke or restart an already authorized request. Once
that request reaches a terminal state, the effective policy is evaluated again:
a path that has become economical may start one restricted automatic attempt,
while a still-gated failure requires another explicit tap. The decoded cache is
process-local; validated image bytes fetched without account headers can survive
a restart in the bounded
disk cache. This is opportunistic media reuse, not offline browsing: page data is
not persisted, entries expire or may be evicted, and a miss remains gated without
network access.

Disk-cache clearing advances a generation before deleting entries. A validated
download can publish only with the generation token captured by its live waiter;
late pre-clear and older out-of-order stores are rejected. The image repository
bypasses cache reads and publications for the whole cross-actor clear operation
and evicts decoded state again before lifting that barrier. Active animations and
system exports retain independent leases, so logical clearing does not mutate
bytes already being consumed. The settings UI therefore does not represent the
removed logical byte total as immediately reclaimed physical space. Cache files
are browsing traces even without plaintext URLs; users can inspect and clear the
logical cache, and a LiveContainer host with access to the guest sandbox remains
outside the app's trust boundary.

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
enabled, successfully rendered content images use a fixed 0.4 color
multiplier in dark appearance; light appearance and a disabled setting use the
identity multiplier. The preference must not enter a media URL, fetch policy,
reload ID, transfer key, decoder, or cache key, so changing it or the appearance
can redraw an existing image without creating or canceling a request. Video
covers, avatars, galleries, loading and failure placeholders, compact summaries,
badges, and playback controls remain outside this modifier.

Accent selection is also local presentation state. UserDefaults may contain only
one closed preset identifier or a length-bounded canonical `custom:RRGGBB` token;
the optional retained custom editor seed uses that same ASCII, opaque, 24-bit
sRGB grammar. An unknown, malformed, non-ASCII, alpha-bearing, or future active
selection string must resolve read-only to the existing Tieba blue without being
rewritten during parsing. An invalid retained editor seed is ignored, so the
editor starts from the current valid selection instead. Neither value may enter
a request, URL, cookie, account record, cache key, download policy, content
archive, analytics, or log.

The native picker binds an in-memory CGColor draft with opacity disabled.
Conversion accepts only finite, bounded RGB or monochrome input that can be
converted to extended sRGB, explicitly clips and quantizes it to opaque 8-bit
sRGB, and fails closed for non-opaque, patterned, color-space-free, unsupported,
unconvertible, or non-finite colors. Cancel, interactive dismissal, and restoring
the editor's opening value must write nothing. Apply first stores the
self-contained active selection token, then updates the optional retained editor
seed; interruption between those writes cannot change or corrupt the active color.

Every custom base deterministically derives independent light, dark,
increased-contrast-light, and increased-contrast-dark values. Before use, the
whole palette must satisfy the same tested semantic-surface thresholds as the
curated presets: at least 4.5:1 in ordinary appearance, 7:1 with increased
contrast, and 4.5:1 for the on-accent foreground. A derivation or validation
failure falls back as one complete palette to the existing Tieba blue. The
dynamic UIColor provider captures only that immutable validated palette and
must not reread preferences. Remote theme data, alpha, wallpaper extraction,
toolbar or status-bar theming, and archived Color or UIColor values remain
unsupported. Semantic warning and destructive colors remain independent, while
image viewers and video overlays keep their explicit white controls on black.
System Web, Safari, and share surfaces continue to manage their own appearance.

Manual image-cache clearing may evict only the process-local decoded-image and
animation-frame `NSCache` instances. It must advance both generation barriers so a transfer
started before the clear cannot later repopulate that old cache state. It must not cancel active
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

The separate video landing-page fallback is never passed to AVFoundation. Core
accepts it only from the existing anonymous `PbContent.type == 5` text field and
requires a credential-free HTTP(S) URL with a nonempty host, no control
characters, and at most 8,192 UTF-8 bytes; protocol-relative values are upgraded
to HTTPS. The App revalidates it and also rejects percent-decoded control
characters before presenting an action. Rendering never fetches, persists,
copies, or opens the landing page. A valid stream remains primary; missing or
rejected media can expose a user-tapped Web action, and playback failure can
expose a separate user-tapped fallback without automatic navigation. Supported
Tieba destinations use the strict internal router, external HTTPS follows the
selected browser policy, and HTTP is delegated to the system rather than
embedded in Safari.

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

Appearance, app text-size adjustment, forum-sort, and forum primary-action
preferences may store only bounded, nonsecret local values in UserDefaults.
Changing the forum primary action must not read account storage, issue a request,
or authorize a write. The selected toolbar action must recheck current page
capability when pressed; selecting hidden removes only that shortcut, while
new-topic creation remains governed by the existing target validation,
account-session lease, draft isolation, and explicit submission confirmation.
Text-size adjustment is a
presentation-only offset from the current system Dynamic Type category and must
not enter requests, account storage, archives, logs, or exported content. The
no-history control must update the recording flag in
the existing browsing-history archive and must never duplicate that state in a
second store. Selecting or copying a visible topic or ordinary floor, an inline
nested-reply preview, or a parent or child row on the full nested-reply page is
initiated by an explicit user gesture and opens one transient, in-memory panel.
Presenting or dismissing that panel must not issue a request, read account
storage, persist or log its text, read the clipboard, or write the pasteboard.
Only an explicit system selection-copy command or the panel's Copy All action may
write the selected or complete projection. That projection may contain decoded
public textual fragments and fixed non-URL media boundary markers only; it must
not add media URLs, credentials, authenticated or private responses, locally
filtered content, or replies outside the selected item. A content-filter change
must synchronously revoke an open selection panel before starting the page reload.

The hide-reply-entry preference is a default-off, nonsecret local Boolean and
must not itself issue a request or read account storage. While enabled, topic,
floor, nested-reply, and inbox quick-reply controls are not constructed, and
their actions recheck the current policy before presenting a composer. An inbox
reply intent is rejected before the account vault is read; enabling the setting
also invalidates any pending or resolving intent so a late account result cannot
open a composer. This presentation preference must not hide reply content,
ordinary notification navigation, text selection/copying, or agreement controls,
and it must not erase a draft or close a composer that is already open.
Account-session changes retain their stricter existing behavior and may still
invalidate an inbox-originated composer whose credential binding is no longer
current.

The post-and-reply risk-notice preference is a default-on, nonsecret local
Boolean in UserDefaults. Reading or changing the preference, presenting the
notice, or choosing to continue editing must not itself resolve a target,
perform submission preflight, delete a draft, or authorize an account request;
the composer's ordinary account binding and draft lifecycle remain independent.
Returning dismisses the composer through that ordinary lifecycle and must
preserve, rather than delete, the restored draft. Disabling or acknowledging the
notice must not bypass, pre-authorize, or weaken the final immutable-snapshot
confirmation, account and target rebinding, session-lease checks, or no-retry
boundary.

Home-entry preferences are also nonsecret UserDefaults values. The start target
must resolve through the closed home, post-ranking, hot-topic, inbox, local-
favorite, or browsing-history enum, with unknown values falling back to home; it must not
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
expose no approval mutation, and complete-page parent and child controls both
require explicit confirmation. Check-in validation must additionally cover an unfollowed forum,
missing sign state, already-signed idempotence, returned-UID mismatch, and the
same-forum follow/check-in exclusion rule. Cloud-favorite validation must cover
list and thread-detail remove, add, saved-position update, an unresolvable deleted
row, raw thread/forum mismatch, an already-matching no-write result, malformed
or mismatched PB state, valid/random/cross-account/expired STOKEN, a known server
failure, an uncertain write followed by exactly one readback and no second write,
nominal success followed by mandatory readback, identical-operation sharing,
conflicting-operation read-only reconciliation, logout, same-UID session
  rotation, and a switch to another UID while either read or write is in flight.
Text/classic-emoticon new-topic validation must additionally cover titled and untitled
topics, Chinese/Unicode/newline/form-reserved characters, all 50 catalog names,
type-2/type-11 structured readback, exact forum and author
binding, server-generated untitled display titles, challenge and moderation
delay, pre-dispatch cancellation, post-dispatch transport loss, foreground and
background transitions, same-UID credential rotation, account switching, and
proof that every submission dispatches at most one write.
Text/classic-emoticon reply validation must cover all three targets, the inline
preview entry, current-snapshot rebinding, all 50 catalog names, type-2/type-11
structured readback, type-0 lookalikes, unsafe reply-marker identity fields,
pre-dispatch cancellation, uncertain transport failure followed by exactly one
readback and no second write, session rotation, and account switching.
Poll validation must additionally cover authoritative option IDs and selection
state, single- and multiple-choice cardinality, open, closed, and already-voted
polls, malformed or changed options, minimum-field command `309006` acceptance,
known server rejection, uncertain post-dispatch failure followed by exactly one
readback and no retry, identical-selection sharing, conflicting-selection and
rotated-credential read-only recovery, cancellation, logout, and account
switching. Synthetic CI fixtures are not proof of successful real-account voting;
the feature remains gated on one disposable account exercised on a physical
device.

User relationship mutation requires a complete validated BDUSS/STOKEN session
and is unavailable on the active account's own profile. Its preflight and
readback use the fixed HTTPS `tiebac.baidu.com/c/u/user/profile` protobuf command
`303012`, binding the account UID as `uid` and the distinct target UID as
`friend_uid`. The response must echo the target UID, expose only relationship
values `0`, `1`, or mutual `2`, contain a bounded portrait token, and supply a
valid short-lived `anti_stat.tbs`. Portrait and `tbs` never leave Core. A changed
state sends at most one signed HTTPS request to `/c/c/user/follow` or
`/c/c/user/unfollow`, without CUID, IMEI, Android ID, advertising ID, model,
hardware, or install identifiers. Its target-less JSON acknowledgement is only
an acknowledgement; one mandatory authenticated profile readback is the final
relationship truth. Identical writes may share a flight, conflicting calls may
only read after it settles, and an uncertain failure must never automatically
dispatch another write. Until a disposable account validates both directions,
server errors, rate limits, expiry, cancellation, and minimal-field acceptance,
the control remains an explicitly confirmed validation-build feature.

Server-side user interaction restrictions require the same complete session and
a distinct positive target UID. They are independent from the app's local user
block/allow lists. Before the private permission read, Core performs the existing
authenticated profile probe and requires the exact target UID; the subsequent
`/c/u/user/getUserBlackInfo` JSON response does not echo the account or target,
so those IDs are caller-bound context and not server identity assertions. The
read form contains only BDUSS, STOKEN, `black_uid`, client type/version, and the
signature. The write to `/c/c/user/setUserBlack` additionally contains one fresh
validated `tbs` and a compact `perm_list` JSON object. Both requests use fixed
client version `12.41.7.1`, fixed user agent `bdtb for Android 12.41.7.1`, the
fixed noncredential `Cookie: ka=open`, and no
CUID, IMEI, Android ID, IDFV, advertising, hardware, install, model, screen,
location, stored-cookie-jar, or Authorization data.

The decoder requires an exact integer zero error code and exact integer `0` or
`1` values for `follow`, `interact`, and `chat`; booleans, floating-point values,
missing members, and other values fail closed. Zero means allowed and one means
blocked. The unverified `is_black_white` metadata is ignored. A changed state
uses a fresh profile/TBS probe and sends at most one write. Its acknowledgement
is not authoritative: exactly one raw permission readback follows every
dispatched attempt, including transport or decode failure, and a missing or
nonmatching readback becomes a typed outcome-unknown result without retry.
Equivalent changes may share a bounded flight; conflicting states or credentials
wait and then read only. A permission write and user follow write for the same
account/target pair cannot overlap, and the later operation reads rather than
dispatching after the first settles. The App opens the editor lazily, requires
explicit confirmation, and accepts results only for the initiating
`userID + sessionRevision`; an unknown outcome locks mutation until an explicit
reload. Disposable-account validation must cover the minimal-field contract,
all three bit directions, idempotence, cross-operation exclusion, known and
uncertain failures, cancellation, logout, account switching, and same-UID
credential rotation before this leaves validation builds.

Report security issues privately to the repository owner rather than opening a
public issue.
