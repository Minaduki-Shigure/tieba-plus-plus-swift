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

The `Agree.diff_agree_num` field used for post score display is adapted from
TiebaLite commit `b8409486a2f7bd85881835163bd2c1ebe4fed7f7`.
The minimal `HotThreadList` request/response and `RecommendTopicList` schemas,
together with the `FrsTabInfo.tab_code`, `ThreadInfo.thread_id`, and
`ThreadInfo.hot_num` fields used for the anonymous server-defined hot ranking,
are adapted from the same TiebaLite commit.
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
`FrsPageResIdl.DataRes.user`, `forum.is_like`, and `anti.tbs` are adapted from
TiebaLite commit `268f388c7824ae2c8f6ed549827a943ec8a7f352`. They are used only
to bind a short-lived write request to the expected account and forum; `tbs` is
not exposed by the public model or persisted.
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
The Galaxy2 CUID framing and Helios checksum implementation in
`TiebaGalaxy2CUID.swift` are adapted from TiebaLite's `CuidUtils` and
`utils/helios` helpers at that commit. This implementation deliberately replaces
TiebaLite's device-derived prefix with a random client-lifetime prefix that is
neither hardware-derived nor persisted.

Only the dependency closure needed by the implemented endpoints is included
here. The schemas document an unofficial Baidu Tieba wire protocol and do not
imply endorsement by or affiliation with Baidu.
