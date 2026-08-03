# Protocol definition attribution

Most Protocol Buffer definitions under `Protos/`, including the base anonymous
forum-detail and moderator-list schemas, are copied from
[aiotieba](https://github.com/lumina37/aiotieba) at commit
`bae68256fd250d5178e1447899ffa155c77eda38`.

aiotieba is authored by lumina37 and contributors and is released under the
Unlicense. A copy of that license is included in `LICENSE.aiotieba`.

The forum-detail response's rich `content` field and the minimal forum-rule
request and response schemas are adapted from
[TiebaLite](https://github.com/zzc10086/TiebaLite) at commit
`5545326b2a8e0d784b2f3dfbcb219c7b121e61c2`, specifically its
`RecommendForumInfo.proto`, `ForumRule.proto`, and `ForumRuleDetail/` schema
closure. TiebaLite is authored by zzc10086 and contributors and is released
under GPL-3.0; this project is distributed under the same license.

The `Agree.diff_agree_num` field used for read-only post score display is
adapted from TiebaLite commit `b8409486a2f7bd85881835163bd2c1ebe4fed7f7`.
The additional `FrsTabInfo` discriminator and `SortButton` menu fields, the
minimal `GeneralTabList` request/response closure used for anonymous forum
channels, the `PbPageResIdl.DataRes.first_floor_post` field used to preserve
first-floor topic context, and the `PbPageReqIdl.DataReq.last_pid` field used to
request replies after a known post are adapted from the same TiebaLite commit.
Device, account, advertising, write, and reaction fields outside the implemented
read-only contract are intentionally omitted.

Only the dependency closure needed by the implemented anonymous endpoints is
included here. The schemas document an unofficial Baidu Tieba wire protocol and
do not imply endorsement by or affiliation with Baidu.
