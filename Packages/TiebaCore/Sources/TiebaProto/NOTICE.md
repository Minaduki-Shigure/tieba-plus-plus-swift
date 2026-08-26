# Protocol and implementation attribution

Most Protocol Buffer definitions under `Protos/`, including the base anonymous
forum-detail and moderator-list schemas, are copied from
[aiotieba](https://github.com/lumina37/aiotieba) at commit
`bae68256fd250d5178e1447899ffa155c77eda38`.

This includes the minimal authenticated `ReplyMeReqIdl` and `ReplyMeResIdl`
schemas used for the read-only ReplyMe notification list. Device and STOKEN
fields are deliberately left unset in its `CommonReq`.

aiotieba is authored by lumina37 and contributors and is released under the
Unlicense. A copy of that license is included in `LICENSE.aiotieba`.

The forum-detail response's rich `content` field and the minimal forum-rule
request and response schemas are adapted from
[TiebaLite](https://github.com/zzc10086/TiebaLite) at commit
`5545326b2a8e0d784b2f3dfbcb219c7b121e61c2`, specifically its
`RecommendForumInfo.proto`, `ForumRule.proto`, and `ForumRuleDetail/` schema
closure. TiebaLite is authored by zzc10086 and contributors and is released
under GPL-3.0; this project is distributed under the same license.

The response-only `PbContent.dynamic`, `PbContent.big_src`,
`PbContent.cdn_src_active`, and `Media.dynamic_pic` fields used to preserve
server-provided image source URLs, together with the `Media.post_id` field used
to bind a list image to its owning post, are adapted from TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`, specifically its
`PbContent.proto` and `Media.proto` definitions.

The `Agree.diff_agree_num` field used for post score display is adapted from
TiebaLite commit `b8409486a2f7bd85881835163bd2c1ebe4fed7f7`.
The minimal `HotThreadList` request/response and `RecommendTopicList` schemas,
together with the `FrsTabInfo.tab_code`, `ThreadInfo.thread_id`, and
`ThreadInfo.hot_num` fields used for the anonymous server-defined hot ranking,
are adapted from the same TiebaLite commit.
The minimal `PersonalizedReqIdl` and `PersonalizedResIdl` schemas, together with
the `ThreadInfo.ala_info` marker used to exclude live cards, are adapted from
TiebaLite commit `268f388c7824ae2c8f6ed549827a943ec8a7f352`, specifically its
`Personalized.proto` dependency closure. Account, advertising, Android device,
location, and screen fields are omitted. The implemented anonymous request uses
only the endpoint business fields and one app-generated random UUID in
`CommonReq.cuid`; live protocol probes confirmed that no account credential or
hardware-derived identifier is required.
The minimal authenticated `UserLikeReqIdl` and `UserLikeResIdl` schemas used for
the foreground concern feed are adapted from the same TiebaLite commit. The
additional response-only `user_tips`, `last_tips`, and `user_tips_type` field
numbers were cross-checked against
[`tbclient.protobuf`](https://github.com/clb-128258/tbclient.protobuf) commit
`f6eed3691d2c72304f58c348aa8f90855d2d495a`. Unused recommendation-user,
story, live, advertising, app-list, and layout fields are omitted. Android
hardware, installation, location, and screen fields are not implemented.
The minimal `SearchSug` request/response schemas used for anonymous search
suggestions are also adapted from the same TiebaLite commit. The request's
`CommonReq` field is deliberately omitted because this endpoint accepts the
minimal anonymous contract. Account, device, forum-card, live-card, and
ranking-card fields are intentionally omitted.
The additional `FrsTabInfo` discriminator and `SortButton` menu fields, the
minimal `GeneralTabList` request/response closure used for anonymous forum
channels, the `PbPageResIdl.DataRes.first_floor_post` field used to preserve
first-floor topic context, and the `PbPageReqIdl.DataReq.last_pid` field used to
request replies after a known post are adapted from the same TiebaLite commit.
Device, advertising, account, write, and reaction fields outside the explicitly
implemented contracts are intentionally omitted.

The authenticated forum-membership probe fields
`FrsPageResIdl.DataRes.user`, `forum.is_like`, `forum.user_level`,
`forum.level_name`, `forum.cur_score`, `forum.levelup_score`, and `anti.tbs` are
adapted from TiebaLite commit `268f388c7824ae2c8f6ed549827a943ec8a7f352`.
The membership fields bind the result to the expected account and forum; the
level fields expose a validated, read-only level-up progress value. `tbs` is
used only for a short-lived write request and is not exposed by the public
model or persisted.
The `ThreadInfo.collect_status` and `ThreadInfo.collect_mark_pid` fields used to
read an account-scoped thread cloud-favorite marker, together with the
`/c/c/post/addstore` and `/c/c/post/rmstore` form contracts used to add, update,
and remove that marker, are adapted from TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`. The authenticated `PbPage`
response supplies a short-lived `anti.tbs` value for the immediately following
remove request; it is not exposed by the public model or persisted.
The complete `PollInfo`/`PollOption` response fields and the minimal
`AddPollPostReqIdl`/`AddPollPostResIdl` schemas used for account-bound poll
submission are adapted from TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`. Tieba++ sends only credentials,
forum/thread IDs, and selected option IDs; Android hardware, installation,
advertising, location, and screen fields are omitted. Every write is preceded
and followed by an authenticated, identity-bound `PbPage` read and is never
retried automatically. The authenticated state read uses TiebaLite's
`12.52.1.0` PB Page protocol family. The write multipart body preserves the
effective `11.10.8.6` client-version field while its Mozilla-style request user
agent identifies the endpoint's `12.35.1.0` protocol family.
The minimal `AddPostReqIdl` and `AddPostResIdl` schemas, their response-only
anti-abuse dependency closure, and the three text-body reply field layouts for
`/c/c/post/add?cmd=309731&format=protobuf` are adapted from TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`, specifically
`AddPostRequestData.proto`, `AddPostResponseData.proto`, `ReplyPage.kt`, and
`MixedTiebaApiImpl.kt`. The request uses the observed `12.35.1.0` protocol
version and a short-lived `anti.tbs` value from an immediately preceding,
account-bound `PbPage` or `PbFloor` read. Android hardware, installation,
location, advertising, OAID, ZID, and screen fields are deliberately omitted.
The fixed 50-name classic-emoticon wire catalog and `#(name)` insertion behavior
are adapted from TiebaLite's `EmoticonManager.kt` and `ReplyPage.kt` at that same
commit. No TiebaLite or Baidu emoticon bitmap is copied or downloaded. Unknown,
malformed, nested, image, `reply`, and every other user-supplied rich-content
marker are rejected; the nested-reply prefix remains protocol-owned and is
derived only from the freshly read target user. A valid server receipt is
followed only by an exact-ID, structured-token readback and is never retried as
a write.
The minimal `forum.sign_in_info` and nested `SignInfo.user_info` fields used to
read server-authoritative per-forum check-in state are adapted from the same
TiebaLite commit.
The `Agree.has_agree`, `agree_type`, and `lz_agree` fields used to read
account-scoped topic, ordinary-post, and subpost approval state are adapted from
the same TiebaLite commit. The authenticated `PbPage` additions (`user`, `anti`,
and request `forum_id`), authenticated `PbFloor` additions (`anti`, request
`forum_id`, and its forum/thread/post/subpost response closure), `User.is_login`,
and the embedded `Post.SubPost.pid` parent identifier used to bind those states
are also adapted from TiebaLite commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`.
The authenticated self-profile request polarity (`uid`, omitted `friend_uid`,
`is_guest = 0`, `need_post_count`, and the page-one profile flags) and its
minimal `User` summary fields are adapted from `UserViewModel` and
`MixedTiebaApiImpl.userProfileFlow` at that same commit. Tieba++ deliberately
omits Android hardware, installation, advertising, location, screen, and CUID
fields; it sends only the account-bound UID and credentials required by this
read and never persists the returned summary.
The response-only `BirthdayInfo` schema plus `User.birthday_info`,
`User.is_nickname_editing`, and `User.editing_nickname` fields used to preserve
hidden profile state and recognize nickname review are adapted from TiebaLite's
`BirthdayInfo.proto`, `User.proto`, and `EditProfileViewModel` at commit
`268f388c7824ae2c8f6ed549827a943ec8a7f352`. The corresponding
`/c/c/profile/modify` field contract is adapted from `OfficialTiebaApi` and
`MixedTiebaApiImpl` at that commit. Tieba++ exposes no birthday editor, copies
only a validated preflight birthday snapshot into one explicit write, omits
Android device and installation metadata, and requires one account-bound
profile readback without automatically retrying the mutation.
The authenticated target-profile polarity (`uid`, `friend_uid`, `is_guest = 1`),
the response-only `User.has_concerned` and `anti.tbs` fields, and the explicit
`/c/c/user/follow` and `/c/c/user/unfollow` form contracts are adapted from
TiebaLite's `UserProfileViewModel`, `MixedTiebaApiImpl.userProfileFlow`, and
`OfficialTiebaApi` at that same commit. Tieba++ uses HTTPS and omits Android
device and installation identifiers. The target portrait and short-lived `tbs`
are consumed only by the immediate write, whose result is read back exactly
once and is never retried as a write.
The Galaxy2 CUID framing and Helios checksum implementation in
`TiebaGalaxy2CUID.swift` are adapted from TiebaLite's `CuidUtils` and
`utils/helios` helpers at that commit. This implementation deliberately replaces
TiebaLite's device-derived prefix with a random client-lifetime prefix that is
neither hardware-derived nor persisted.

Only the dependency closure needed by the implemented endpoints is included
here. The schemas document an unofficial Baidu Tieba wire protocol and do not
imply endorsement by or affiliation with Baidu.
