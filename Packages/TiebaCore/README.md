# TiebaCore

`TiebaCore` is the transport and domain layer for anonymous Tieba browsing. It
contains no account state and exposes only `Sendable` values to the app.

```swift
let client = TiebaClient()
let threads = try await client.getThreads(forumName: "swift")
let posts = try await client.getPosts(threadID: threads.threads[0].id)
let comments = try await client.getComments(
    threadID: posts.thread.id,
    postID: posts.posts[0].id
)
```

## Wire assumptions

- Requests use `https://tiebac.baidu.com` exclusively.
- The three supported commands are FRS `301001`, PB `302001`, and floor
  `302002`.
- Requests identify as client type `2` and version `12.64.1.1` by default.
- The first FRS page is encoded as `pn = 0`, matching aiotieba behavior.
- PB asks for at least two posts because the upstream endpoint does not honor a
  request size of one consistently.
- Bodies use the endpoint's multipart `data` part and Protocol Buffer payload.
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
