# TiebaCore

`TiebaCore` is the transport and domain layer for Tieba browsing. `TiebaClient`
is strictly anonymous. `TiebaAuthenticatedClient` is separate, requires
credentials explicitly, exposes only `Sendable` values to the app, and retains
only bounded in-flight coordination state for supported authenticated writes.
It does not persist credentials or account state.

```swift
let client = TiebaClient()
let personalized = try await client.getPersonalizedThreads()
let hotThreads = try await client.getHotThreadRanking()
if let category = hotThreads.categories.first {
    let categoryRanking = try await client.getHotThreadRanking(categoryCode: category.code)
}
let topics = try await client.getHotTopics()
let topic = try await client.getHotTopic(
  topicID: topics[0].id,
  topicName: topics[0].name
)
let search = try await client.searchThreads(query: "swift", sort: .newest)
let suggestions = try await client.searchSuggestions(query: "swift")
let scopedSearch = try await client.searchForumPosts(
  query: "async",
  forumName: "swift",
  sort: .newest,
  filter: .all
)
let users = try await client.searchUsers(query: "swift")
let threads = try await client.getThreads(forumName: "swift")
if let channel = threads.channels.first {
    let channelThreads = try await client.getForumChannelThreads(
        forumID: threads.forum.id,
        forumName: threads.forum.name,
        channel: channel
    )
}
let posts = try await client.getPosts(threadID: threads.threads[0].id)
if let imageURL = posts.posts.lazy.flatMap({ $0.content.images }).compactMap({
    $0.originalURL ?? $0.dynamicURL ?? $0.fullSizeURL ?? $0.thumbnailURL
}).first,
   let cursor = TiebaPicturePageCursor(imageURL: imageURL) {
    let pictures = try await client.getPicturePage(
        forumID: posts.forum.id,
        forumName: posts.forum.name,
        threadID: posts.thread.id,
        cursor: cursor
    )
}
let comments = try await client.getComments(
    threadID: posts.thread.id,
    postID: posts.posts[0].id
)
if let userID = posts.posts[0].author?.id {
    let profile = try await client.getUserProfile(userID: userID)
    let publicThreads = try await client.getUserThreads(userID: userID)
    let following = try await client.getUserRelations(userID: userID, kind: .following)
    let followers = try await client.getUserRelations(userID: userID, kind: .followers)
}
```

The authenticated client supports BDUSS-only identity validation, full-session
UID-consistency probes, followed and target-user liked forums, an account-bound concern feed,
Tieba cloud-favorite reads and guarded thread-detail mutations, authoritative
per-forum follow/check-in state, confirmed forum and user follow/unfollow,
target-bound server interaction restrictions, explicit single-forum and official
batch check-in, and guarded account-bound poll voting. It also exposes
guarded text and fixed-catalog classic-emoticon reply and new-topic creation for
validation builds. Core
single-flights equivalent check-in, cloud-favorite, interaction-permission, and
poll-vote calls and
serializes conflicting identities for the same resource. The
app's Keychain and account-service layers own persistence, credential-rotation
leases, and mutual exclusion between follow and check-in. A conflicting App
call waits for the active write to settle and then reconciles by reading; it is
not queued as another write:

```swift
let authenticatedClient = TiebaAuthenticatedClient()
let credential = TiebaBDUSSCredential(bduss: bduss)
let account = try await authenticatedClient.validateAccount(credential: credential)
let followed = try await authenticatedClient.getFollowedForums(
    credential: credential,
    userID: account.userID
)
let targetUserID = account.userID
let likedForums = try await authenticatedClient.getLikedForums(
    credential: credential,
    accountUserID: account.userID,
    targetUserID: targetUserID
)
if let forum = followed.forums.first {
    let forumState = try await authenticatedClient.getForumAccountState(
        credential: credential,
        expectedUserID: account.userID,
        forumID: forum.id,
        forumName: forum.name
    )
    if forumState.membership.isFollowed,
       forumState.checkIn?.isCheckedIn == false {
        _ = try await authenticatedClient.checkInToForum(
            credential: credential,
            expectedUserID: account.userID,
            forumID: forumState.membership.forumID,
            forumName: forumState.membership.forumName
        )
    }
}
```

A newly captured web login can be bound before persistence, then used for the
cloud-favorites list and exact thread state:

```swift
let sessionCredential = TiebaSessionCredential(
    bduss: bduss,
    stoken: stoken,
    bdussCookieName: .bduss
)
let sessionAccount = try await authenticatedClient.validateSession(
    credential: sessionCredential
)
let cloudFavorites = try await authenticatedClient.getCloudFavorites(
    credential: sessionCredential,
    expectedUserID: sessionAccount.userID
)
let favoriteForumID: Int64 = 42
let favoriteThreadID: Int64 = 8_675_309
let threadFavorite = try await authenticatedClient.getThreadCloudFavoriteState(
    credential: sessionCredential,
    expectedUserID: sessionAccount.userID,
    forumID: favoriteForumID,
    threadID: favoriteThreadID
)
let concern = try await authenticatedClient.getConcernFeed(
    credential: sessionCredential,
    expectedUserID: sessionAccount.userID
)
let newThread = try await authenticatedClient.submitNewThread(
    credential: sessionCredential,
    expectedUserID: sessionAccount.userID,
    submission: TiebaNewThreadSubmission(
        submissionID: UUID(),
        forumID: favoriteForumID,
        forumName: "swift",
        title: "Optional title",
        content: "Text body #(呵呵)"
    )
)
```

Core also exposes the lower-level static-image upload transaction needed by a
future composer. The current App does not call it. A caller must retain the exact
validated bytes and upload identity, treat a dispatched unknown outcome as
non-resendable in its own durable state, and rebind a decoded receipt before use:

```swift
let upload = TiebaStaticImageUpload(
    uploadID: UUID(),
    forumName: "swift",
    encodedBytes: metadataStrippedJPEG,
    pixelWidth: width,
    pixelHeight: height,
    preservesOriginal: true
)
let receipt = try await authenticatedClient.uploadStaticImage(
    credential: sessionCredential,
    expectedUserID: sessionAccount.userID,
    upload: upload
)
guard receipt.isBound(to: upload, expectedUserID: sessionAccount.userID) else {
    throw TiebaClientError.invalidAuthenticatedResponse
}
```

The client coalesces an identical upload ID within one bounded in-memory flight
window and never automatically retries a dispatched chunk. That is not a
cross-restart ledger: persistence and final post-transaction recovery belong to
the App layer before image creation becomes user-visible.

`getForumMembership` remains available for callers that need only
`TiebaForumMembership`. `getForumAccountState` returns that membership plus an
optional `TiebaForumCheckIn` containing the server-authoritative sign state,
consecutive-day count, and rank. A missing check-in value means the probe did
not advertise a usable sign state; it is not permission to attempt a write.

## Wire assumptions

- Protocol Buffer requests use `https://tiebac.baidu.com`; anonymous JSON
  search uses `https://tieba.baidu.com`. Redirects must remain on the request's
  original HTTPS host.
- Whole-thread picture metadata uses a minimal signed form request to the exact
  HTTPS origin `c.tieba.baidu.com`. It sends no account or device identifiers,
  accepts only strict Baidu picture URLs/cursors, limits the response to 1 MiB
  during transfer, and normalizes observed cleartext media only for exact known
  Baidu image hosts.
- Forum and post browsing use FRS `301001`, GeneralTab `309622`, PB `302001`,
  and floor `302002`. GeneralTab receives only a public forum ID, a validated
  type-15 channel, its independent server-advertised sort value, and pagination
  cursor. FRS sort menus are bounded to 12 unique nonnegative IDs with 40-character
  titles; GeneralTab sends an advertised raw ID or `-1` when no menu is present.
  Omitting the public client argument selects the first advertised entry, then
  falls back to `-1` only for an empty menu.
- Public profiles use Profile `303012` with explicit guest fields; public user
  threads use UserPost `303002` and terminate pagination on an empty page. A
  profile's liked-forum array is a limited public preview rather than a complete
  anonymous followed-forum list. The separate authenticated
  `getLikedForums` read keeps `uid` bound to the active account and, only for a
  different target, adds `friend_uid` plus `is_guest=1`; it uses no STOKEN or
  device metadata, carries both requested identities as context, and has a 2 MiB
  response limit. Read-only following and follower lists use the
  HTTPS form endpoints `/c/u/follow/followList` and `/c/u/fans/page`; each signed
  request contains only fixed client version `22.6.5.1`, one-based page, target
  UID, and signature, with no account credential or device field. The two
  endpoints retain their distinct validated pagination semantics and share a
  1 MiB response limit.
- Search supports `/mo/q/search/forum`, `/mo/q/search/thread`, and
  `/mo/q/search/user`; global thread search is restricted to topic results and
  supports newest/oldest/relevance sorting with endpoint-specific wire values,
  while per-forum search supports newest/relevance sorting, topic-only/all-content
  filters, and numeric pagination. Global results preserve the public `flash`
  or `video` media marker independently from cover URL validation so clients can
  apply a local video policy. User search is a single nonpaginated request.
- Search suggestions use protobuf command `309438`. Their minimal anonymous
  request contains only a 2-to-100-character public keyword and fixed
  `isforum = "0"`; it omits `CommonReq`, credentials, cookies, and device
  metadata. Responses are limited to 64 KiB before decoding, normalized, and
  bounded to 10 unique values.
- Hot-topic discovery uses the credential-free `/mo/q/hotMessage/list` and
  `/mo/q/newtopic/topicDetail` Web endpoints. Detail pagination forwards both
  the numeric page/offset and the previous page's final feed cursor.
- The anonymous hot-thread ranking uses protobuf command `309661` with fixed
  `tab_id = "1"` and either `tab_code = "all"` or an opaque server-advertised
  category code. It is a complete replacement snapshot with no page, size,
  cursor, or load-more contract. Category titles remain bound to their exact
  server codes rather than being inferred from those codes. Mapped collections
  are bounded to 20 topics, 20 unique categories, and 100 unique valid threads.
- Personalized discovery uses protobuf command `309264`, fixed client version
  `12.52.1.0`, and one stable random UUID supplied as `CommonReq.cuid`. The UUID
  is not a hardware or account identifier; the app persists its generated value
  only to keep refresh and page requests in one recommendation session. No
  Cookie, credential, client ID, signature, IMEI, OAID, Android ID, IDFV,
  location, screen, model, or brand field is sent. Responses are limited to
  4 MiB. Because the endpoint has no authoritative `has_more` and can return a
  short page before later nonempty pages, any nonempty raw page allows
  continuation. The App stops an empty page immediately, probes across at most
  five consecutive mapped-empty pages per explicit action before requiring an
  explicit continuation, traverses the server pages reached before a refresh,
  and then permits only one additional duplicate-only overlap page.
- The authenticated concern feed uses protobuf command `309474`, fixed client
  version `11.10.8.6`, and a random process-local UUID distinct from anonymous
  personalization. Its protobuf common data carries the full session; the outer
  multipart carries only `BDUSS`, `_client_version`, `stoken`, `sign`, and the
  protobuf file, with the expected UID in `client_user_token`. It sends no Cookie
  or hardware-derived identifier, rejects every redirect, and limits responses
  to 4 MiB. Refresh uses an empty page tag and a prior server timestamp or zero;
  load-more preserves that timestamp and returns only a validated advancing
  opaque cursor. A zero-error login-prompt envelope requires the independent
  same-UID session probes before it is accepted as an empty page.
- Requests identify as client type `2` and version `12.64.1.1` by default.
- Account validation and several authenticated reads use version `22.6.5.1`;
  endpoint-specific exceptions are documented below.
- Full-session validation signs an HTTPS `/c/s/login` request containing the
  192-byte BDUSS and 64-byte STOKEN, then independently reads
  `https://tieba.baidu.com/mo/q/newmoindex?need_user=1` with only the captured
  `BDUSS` or `BDUSS_BFESS` cookie and `STOKEN`. Both responses must identify the
  same positive user ID. Because both probes carry BDUSS, this does not by itself
  prove rejection of a wrong STOKEN; negative cases remain a physical-device
  validation requirement. The web response is limited to 256 KiB, cookie and
  credential storage are disabled, and every redirect is rejected.
- Static-image upload uses only the exact HTTPS
  `tiebac.baidu.com/c/s/uploadPicture` endpoint after full-session same-UID
  validation. It sends sequential 512,000-byte chunks with a per-request
  collision-checked multipart boundary, limits responses to 64 KiB, and omits
  device, installation, advertising, model, screen, and location identifiers.
  A schema-versioned receipt separately retains the uploaded dimensions and the
  server's origin-picture dimensions; decoding proves structure only, while
  `isBound(to:expectedUserID:)` recomputes the request-side SHA-256, protocol MD5
  resource ID, byte/chunk counts, canonical forum, options, dimensions, UUID, and
  account binding.
- Read-only cloud favorites use fixed client version `11.10.8.6` and an HTTPS
  POST to `/c/f/post/threadstore`. The form contains only `BDUSS`,
  `_client_version`, `offset`, `rn`, `stoken`, `user_id`, and `sign`, with the
  expected UID in `client_user_token` and only `ka=open` in the Cookie header.
  Responses are limited to 2 MiB. The returned model labels the requesting UID
  as context; the endpoint response itself contains no UID assertion.
- List-level removal target resolution uses an anonymous PB Page request and
  validates the raw requested thread ID, positive forum ID, thread `fid`, and
  canonical forum names before returning a candidate identity. The authenticated
  state preflight remains authoritative; Core provides no `fid=null` fallback.
- Thread-detail cloud-favorite state uses an authenticated PB Page read that
  binds the logged-in UID, forum ID, thread ID, strict collect status, positive
  marker, and fresh internal `tbs`. Add/update and remove use one signed HTTPS
  `addstore` or `rmstore` request with fixed version `12.41.7.1`, the exact
  minimum attributed form fields, no device identifier, and a 64 KiB response
  limit. A matching pre-read is idempotent. Every sent write is followed by one
  read-only reconciliation, and an uncertain failure never retries the write.
  Failure to verify the requested final marker returns the typed
  `threadCloudFavoriteOutcomeUnknown` error.
  Equivalent operations share one task; conflicting credentials or markers wait
  and then only reread.
- Poll voting first uses an authenticated PB Page read with fixed client version
  `12.52.1.0`; both the protobuf common block and HTTP header carry the matching
  fixed user agent. The read binds the expected account UID, forum ID, thread ID,
  real positive option IDs, selection mode, previous selection, and open state.
  It prefers a direct poll and permits the ordinary thread's mirrored origin only
  when that carrier's TID exactly matches the requested thread; an unbound or
  shared origin poll is never attributed to the outer thread. A legal explicitly
  confirmed selection sends one HTTPS
  protobuf command `309006` with only the complete session, client type/version,
  signature, forum/thread IDs, and canonical selected IDs. Hardware,
  installation, advertising, location, and screen identifiers are omitted.
  Identical account/thread/selection calls share one flight; conflicts wait and
  only reread. Every dispatched write receives exactly one authenticated
  readback, is never retried, and reports an unknown outcome unless the requested
  selection is verified.
- The authenticated FRS forum-state probe binds the returned user ID, forum ID,
  normalized forum name, follow state, optional sign-user ID, and 26-character
  lowercase hexadecimal `tbs` to the request. The `tbs` remains internal and is
  never returned in a public model or retained by the client.
- Single-forum check-in first performs a fresh forum-state probe. It rejects an
  unfollowed forum or missing sign state and sends no write when the server
  already reports the account as checked in. Otherwise it sends one signed
  HTTPS POST to `/c/c/forum/sign`; the form contains exactly six fields:
  `BDUSS`, `_client_version`, `fid`, `kw`, `tbs`, and `sign`.
  `_client_version` is fixed to `11.10.8.6`, with the expected UID in
  `client_user_token`, `Cookie: ka=open`, and the matching fixed-version user
  agent. It sends no STOKEN or device fields, rejects redirects, limits the
  response to 64 KiB, and never retries a write.
- Equivalent concurrent check-ins on one client share a single Core task.
  Different credentials or normalized names for the same account and forum are
  serialized and never share a result. After an uncertain write failure, a
  direct Core caller is responsible for a read-only reconciliation only when its
  credential is still the active account session; the App enforces that lease.
- The first FRS page is encoded as `pn = 0`, matching aiotieba behavior.
- PB asks for at least two posts because the upstream endpoint does not honor a
  request size of one consistently.
- PB pagination exposes the server's previous-page flag. The app uses it only
  for an exact adjacent numeric page in ascending anchored windows; descending
  and hot response directions are not inferred from that flag.
- PB post responses expose a validated first floor independently from the
  current physical reply page. It must have a positive ID, floor one, matching
  thread ownership, and the declared first-post ID when present; it is removed
  from the reply array so pagination cannot duplicate it. A PB page's `post_id`
  may be the current anchor and is never used as a fallback first-post identity.
- Post pages expose a shared-thread origin only when the explicit share flag is
  set and the origin TID is positive and distinct from the outer thread. The
  origin reuses the normal rich-content and media mapping path.
- Anonymous post pages expose read-only poll results. Observed ordinary poll
  pages carry the poll in their mirrored origin object, while a shared thread's
  origin poll remains owned by the original thread. A direct thread poll, when
  present, is authoritative for the outer thread; the ordinary mirror is its
  compatibility fallback.
- Post and nested-reply agreement summaries use `diff_agree_num` when present,
  falling back to the difference between raw agree and disagree counts for
  older responses. Author forum levels, bounded moderator roles, and IP locations
  come from the same anonymous response and do not require a separate profile
  request.
- Nested-reply content is lossless. Reply-target metadata recognizes both a
  direct leading mention and the legacy `reply + mention` prefix without
  removing the corresponding content fragments.
- Browsing bodies use the endpoint's multipart `data` part and Protocol Buffer
  payload. Search requests use percent-encoded GET query items and JSON.
- Anonymous requests contain no Cookie, Authorization, BDUSS, STOKEN,
  hardware-derived identifier, or TLS override. Personalized discovery's one
  documented app-generated random UUID is the only stable anonymous session ID.
- Authenticated requests use a separate request factory and ephemeral transport,
  disable cookie and credential storage, and put only the endpoint's required
  account fields in the signed HTTPS form body. Their transport rejects every
  redirect rather than replaying a credential-bearing POST.
- Neither client persists account credentials or retains them beyond an active
  request or bounded write flight. Credential values are redacted from public
  debug descriptions and mirrors, and the FRS anti-CSRF value is not exposed by
  the public API.
- Text and fixed-catalog classic-emoticon new topics use one signed HTTPS
  `/c/c/thread/add` form only after a
  fresh FRS response binds the expected UID, forum ID/name, trusted display name,
  and valid TBS. Titles are capped at 31 Swift characters and 124 UTF-8 bytes;
  bodies use the 10,000-character/32 KiB reply bounds. Bodies may contain only
  ordinary text and exact tokens from the compiled 50-name classic-emoticon
  catalog; titles and all unsupported rich markers are rejected. Unsupported
  control characters are also rejected. The minimal form omits
  hardware-derived and advertising fields,
  rejects every redirect, and has a 128 KiB response limit. Per-account writes
  are serialized; equal submission UUIDs share a flight, conflicting reuse is
  rejected, cancellation before dispatch sends no write, and a dispatched write
  is never retried. Positive TID/PID receipts receive one authenticated first-
  floor readback; exact matches confirm, temporary absence remains accepted, and
  mismatches or lost receipts become an unknown outcome.

The account unread summary uses `POST https://tiebac.baidu.com/c/s/msg` with a
signed form restricted to BDUSS, `_client_version=8.2.2`, and `bookmark=1` plus
the generated signature. It sends no Cookie, STOKEN, UID header, or Android
device and telemetry fields. The JSON body is limited to 64 KiB and strictly
decodes bounded integer `replyme`, `atme`, and optional `fans` values; an absent
or null `fans` field remains unavailable rather than becoming zero. The returned
UID is explicitly the caller's expected-UID context because this
response does not independently prove an account identity; the application must
still bind the result to its current session lease.

These are unofficial APIs and may change without notice. Per-forum
follow/unfollow, explicit single-forum and official batch check-in,
and explicit topic, post, and subpost approval writes are implemented.
Thread-detail cloud-favorite add,
saved-position update, and removal plus verified single-item list removal are
experimental validation-build features; notifications remain read-only.
Background scheduling and automatic check-in orchestration, unverified list
deletion, bulk synchronization, rich-media topic/reply creation, and moderation
remain unsupported. Server-side
user interaction restrictions are experimental: Core first binds the target with
an authenticated profile probe, strictly decodes the three `0`/`1` permission
bits, and follows any one-shot changed-state write with exactly one raw readback.
It never retries an uncertain mutation, and it excludes a concurrent user-follow
write for the same account and target.

The permission read posts to `/c/u/user/getUserBlackInfo`; the write posts to
`/c/c/user/setUserBlack`. Both use fixed client version `12.41.7.1`, user agent
`bdtb for Android 12.41.7.1`, `Cookie: ka=open`, a 64 KiB response limit, and no
hardware or install identifier. Read fields are limited to BDUSS, STOKEN,
`black_uid`, client type/version, and `sign`. Write adds a fresh validated `tbs`
and structured `perm_list` JSON containing exact integer `0`/`1` members
`follow`, `interact`, and `chat`. Once dispatched, the write is followed by one
raw permission readback even when its acknowledgement fails; a mismatch is a
typed unknown result, not a retry. The bounded interaction-permission flight and
the existing user-follow flight are mutually exclusive for one account/target.

## Tests

Run deterministic fixtures and request compatibility tests with:

```sh
swift test
```

The live anonymous flow is opt-in:

```sh
TIEBA_LIVE_TESTS=1 swift test --filter TiebaLiveTests
```

The Protocol Buffer definitions are a minimal dependency closure copied from
aiotieba. See `Sources/TiebaProto/NOTICE.md` and `LICENSE.aiotieba`.
The authenticated form fields and response shapes were independently
implemented after cross-checking aiotieba commit
`bae68256fd250d5178e1447899ffa155c77eda38` (Unlicense) and TiebaLite commit
`5545326b2a8e0d784b2f3dfbcb219c7b121e61c2` (GPL-3.0). The per-forum sign-state
schema and check-in contract were cross-checked against TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352` (GPL-3.0).
