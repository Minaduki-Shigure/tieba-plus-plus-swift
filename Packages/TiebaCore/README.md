# TiebaCore

`TiebaCore` is the transport and domain layer for anonymous Tieba browsing. It
contains no account state and exposes only `Sendable` values to the app.

```swift
let client = TiebaClient()
let search = try await client.searchThreads(query: "swift")
let threads = try await client.getThreads(forumName: "swift")
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

## Wire assumptions

- Protocol Buffer requests use `https://tiebac.baidu.com`; anonymous JSON
  search uses `https://tieba.baidu.com`. Redirects must remain on the request's
  original HTTPS host.
- Forum and post browsing use FRS `301001`, PB `302001`, and floor `302002`.
- Public profiles use Profile `303012` with explicit guest fields; public user
  threads use UserPost `303002` and terminate pagination on an empty page.
- Search supports `/mo/q/search/forum` and `/mo/q/search/thread`; thread search
  is restricted to topic results and relevance sorting.
- Requests identify as client type `2` and version `12.64.1.1` by default.
- The first FRS page is encoded as `pn = 0`, matching aiotieba behavior.
- PB asks for at least two posts because the upstream endpoint does not honor a
  request size of one consistently.
- Browsing bodies use the endpoint's multipart `data` part and Protocol Buffer
  payload. Search requests use percent-encoded GET query items and JSON.
- No Cookie, Authorization, BDUSS, STOKEN, device identifier, or TLS override is
  used by this package.

These are unofficial APIs and may change without notice. Authentication and
write operations intentionally remain outside this package.

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
