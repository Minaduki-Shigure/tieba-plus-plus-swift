# TiebaCore

`TiebaCore` is the transport and domain layer for Tieba browsing. `TiebaClient`
is strictly anonymous. `TiebaAuthenticatedClient` is a separate, stateless
client whose methods require credentials explicitly and expose only `Sendable`
values to the app.

```swift
let client = TiebaClient()
let topics = try await client.getHotTopics()
let topic = try await client.getHotTopic(
  topicID: topics[0].id,
  topicName: topics[0].name
)
let search = try await client.searchThreads(query: "swift", sort: .newest)
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
let comments = try await client.getComments(
    threadID: posts.thread.id,
    postID: posts.posts[0].id
)
if let userID = posts.posts[0].author?.id {
    let profile = try await client.getUserProfile(userID: userID)
    let publicThreads = try await client.getUserThreads(userID: userID)
}
```

The authenticated client currently supports identity validation and a
read-only followed-forum list. Account persistence belongs to the app's
Keychain vault, not this package:

```swift
let authenticatedClient = TiebaAuthenticatedClient()
let credential = TiebaBDUSSCredential(bduss: bduss)
let account = try await authenticatedClient.validateAccount(credential: credential)
let followed = try await authenticatedClient.getFollowedForums(
    credential: credential,
    userID: account.userID
)
```

## Wire assumptions

- Protocol Buffer requests use `https://tiebac.baidu.com`; anonymous JSON
  search uses `https://tieba.baidu.com`. Redirects must remain on the request's
  original HTTPS host.
- Forum and post browsing use FRS `301001`, GeneralTab `309622`, PB `302001`,
  and floor `302002`. GeneralTab receives only a public forum ID, a validated
  type-15 channel, its independent sort value, and pagination cursor.
- Public profiles use Profile `303012` with explicit guest fields; public user
  threads use UserPost `303002` and terminate pagination on an empty page. A
  profile's liked-forum array is a limited public preview rather than a complete
  anonymous followed-forum list.
- Search supports `/mo/q/search/forum`, `/mo/q/search/thread`, and
  `/mo/q/search/user`; global thread search is restricted to topic results and
  supports newest/oldest/relevance sorting with endpoint-specific wire values,
  while per-forum search supports newest/relevance sorting, topic-only/all-content
  filters, and numeric pagination. User search is a single nonpaginated request.
- Hot-topic discovery uses the credential-free `/mo/q/hotMessage/list` and
  `/mo/q/newtopic/topicDetail` Web endpoints. Detail pagination forwards both
  the numeric page/offset and the previous page's final feed cursor.
- Requests identify as client type `2` and version `12.64.1.1` by default.
- Account validation and authenticated read requests use version `22.6.5.1`.
- The first FRS page is encoded as `pn = 0`, matching aiotieba behavior.
- PB asks for at least two posts because the upstream endpoint does not honor a
  request size of one consistently.
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
  older responses. Author forum levels and IP locations come from the same
  anonymous response and do not require a separate profile request.
- Nested-reply content is lossless. Reply-target metadata recognizes both a
  direct leading mention and the legacy `reply + mention` prefix without
  removing the corresponding content fragments.
- Browsing bodies use the endpoint's multipart `data` part and Protocol Buffer
  payload. Search requests use percent-encoded GET query items and JSON.
- Anonymous requests contain no Cookie, Authorization, BDUSS, STOKEN, device
  identifier, or TLS override.
- Authenticated requests use a separate request factory and ephemeral transport,
  disable cookie and credential storage, and put only the endpoint's required
  account fields in the signed HTTPS form body. Their transport rejects every
  redirect rather than replaying a credential-bearing POST.
- Neither client retains account credentials. Credential values are redacted
  from their public debug descriptions, and the login response's anti-CSRF
  value is not exposed by this read-only API.

These are unofficial APIs and may change without notice. Authenticated write
operations intentionally remain unsupported.

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
`5545326b2a8e0d784b2f3dfbcb219c7b121e61c2` (GPL-3.0).
