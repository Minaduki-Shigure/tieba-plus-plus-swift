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
Liked forums embedded in that public response are a bounded preview only. The
app must not call the login-required full-list endpoint, infer hidden entries,
or describe an empty or partial preview as the user's complete forum list.

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

Post author levels, IP locations, and net approval scores are also read only from
the anonymous post response. An IP location is server-supplied public author
context, not the device's current location; displaying it must never request
Core Location permission. These values are not persisted in local history, and
their static labels must not call an agree, disagree, or profile-write endpoint.

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
media, expose active external links, or put resource URLs on the pasteboard.
Every child is filtered independently, while filtering must not change the
server reply count or remove access to the complete nested-reply page.

Complete nested-reply requests remain credential-free. A direct request sends
only the public thread, parent-post, and page fields; anchored opening adds the
public target-comment field while retaining the parent-post field. Before any
response is displayed or merged, the app requires a matching positive thread and
parent identity and discards nonpositive, cross-thread, cross-parent, or duplicate
child identities. Earlier and later pages must advance strictly in their requested
direction, and an invalid or stalled response must not mutate the loaded snapshot.
The parent floor is projected into a dedicated model without embedded reply
previews, preventing duplicate storage and recursive entry points.

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
This read-only path must not attach account fields, persist response metadata,
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
reconstruct a missing first floor from a thread-list excerpt, persist its
response copy, or use it to expose filtered content or authenticated actions.

Parent-floor links, media, profiles, and copying reuse the same strict routing,
credential-free media, and text-projection policies as ordinary post content.
Parent and child filtering use one immutable rule snapshot; hiding the parent or
anchor must not expose filtered content, alter pagination identity, or synthesize
a pasteboard value. The page remains read only and must not expose reply, like,
delete, report, or other authenticated write operations.

Internal navigation uses one strict parser for exact `tieba.baidu.com` HTTP(S)
forum/thread URLs, supported `com.baidu.tieba` forum/thread route text, and the
app-owned `tieba-plus-plus` forum/thread/user scheme. It rejects URL
credentials, nonstandard ports, fragments, extra or empty path components,
ambiguous or valueless state, empty or malformed forum names, and nonpositive
or overflowing identifiers. Supported cleartext HTTP input is converted only
to an internal route and never causes a cleartext network request; all resulting
content loads still use the credential-free HTTPS API client. Unknown HTTPS
links continue through the normal system action.

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
Global thread-search results apply that same fail-open snapshot only after the
anonymous response has arrived. Filtering may annotate a result as visible,
placeholder, or hidden, but must preserve every raw ID, order position, page,
and pagination decision. A hidden final item or fully hidden page must still be
able to trigger pagination through an inaccessible raw-tail sentinel; the app
must not reveal the filtered row or repeatedly request a duplicate-only page.
The public search media marker may be used only to enforce the local video
switch and must not add a media request. Forum and user lookup plus per-forum
post search remain outside this filtering boundary.

Remote media uses an ephemeral, credential-free session, rejects cleartext
requests or redirect destinations, and is decoded through ImageIO with a
bounded pixel size and memory cache. Original image dimensions are never
decoded directly into the browsing UI.

The content-media preference applies only to thread previews, rich-content
images, video covers, per-forum search media, and hot-topic images. In
tap-to-load mode, a cold image performs an exact in-memory cache lookup and
must not create or join a network request until the user presses its load
control. That authorization is bound to the current HTTPS URL and requested
pixel size; changing either value or changing the policy revokes it. A failed
manual request is retried only by another explicit tap. The cache is
process-local and ephemeral, so this setting does not claim persistent offline
media or suppress the page-data requests needed to browse.

Avatars remain outside that content-media policy. Gallery originals, video and
voice playback, sharing, and saving already require a separate explicit user
action and retain those user-initiated paths. Rendering a video cover must not
construct an `AVPlayer` or start playback. Switching from automatic to
tap-to-load cancels the content view's waiter; a deduplicated transfer may
continue only when another active, independently authorized waiter still owns
it.

Thread-list previews reuse that same media pipeline. Metadata badges and
read-only counters come only from existing anonymous responses; rendering a
card must not introduce a personalized request, autoplay video, or broaden the
media host policy. Pinned cards intentionally make no preview request, and an
invalid media URL remains an unsupported fragment rather than a fallback
cleartext load. Automatic and explicitly requested content previews have a
16 MiB transfer-time limit; the task
delegate cancels a response as soon as either its declared or observed byte
count exceeds that bound. Explicit higher-resolution image views retain the
80 MiB transfer limit. Deduplicated downloads track active view waiters and are
canceled when the final waiter disappears, so scrolling cannot leave orphaned
preview transfers running in the background.

An image gallery is built only from the already filtered `BrowseContent` array
that owns the tapped image. It must not rescan a raw response, cross a floor or
origin-card boundary, merge repeated URLs, or reveal a locally hidden fragment.
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

Appearance and forum-sort preferences may store only bounded, nonsecret local
values in UserDefaults. The no-history control must update the recording flag in
the existing browsing-history archive and must never duplicate that state in a
second store. Full-floor copying is initiated by an explicit user gesture and
may include decoded public textual fragments and fixed non-URL media boundary
markers only; it must not add media URLs, credentials, account responses, or
hidden nested replies to the pasteboard.

Automated tests use synthetic fixed-length placeholders only. Real `BDUSS`,
`STOKEN`, `tbs`, cookies, passwords, or private account responses must never be
placed in GitHub Actions secrets or exercised by CI. Authenticated releases need
manual device validation with a disposable test account before write features
can be enabled.

Report security issues privately to the repository owner rather than opening a
public issue.
