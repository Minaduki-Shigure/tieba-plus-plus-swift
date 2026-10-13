# TiebaLite reachable-workflow spot audit

## Scope and evidence boundary

This is a source-based spot audit of selected local-settings, search, discovery,
and creation workflows, with targeted checks of topic details and picture
paging. It is **not a complete audit of TiebaLite or Tieba++**. It traces reachable
UI actions into their implementation instead of treating resource strings,
protocol declarations, or unused classes as completed upstream features.

The snapshots compared on 2026-10-13 are:

- TiebaLite `4.0-dev`, commit
  [`9701bfb6aaf261cc37b20b5793a8404261077f49`](https://github.com/zzc10086/TiebaLite/tree/9701bfb6aaf261cc37b20b5793a8404261077f49).
- Tieba++ `main`, commit `f595d1d84e023c005edd2724037c6507d4d765b8`, after
  publication of `v0.65.0-alpha.48`. The local implementation paths below refer
  to this snapshot; subsequent work may change their status or line numbers.

No real account, server write, physical device, or LiveContainer interaction was
tested for this audit. Existing tests and release records are separate evidence;
this document does not claim new runtime validation.

## Confirmed gaps at the audited snapshot

### Official service-center entry

TiebaLite exposes “服务中心” when an account is present. Its
[UserPage.kt, lines 378–389][service-center] opens `WebViewPageDestination` at
`/mo/q/hybrid-main-service/uegServiceCenter`, with client/CUID/timestamp parameters.
This is a reachable official-web workflow, not merely a help-page resource.

At the audited Tieba++ snapshot, [AccountView.swift](../App/Sources/AccountView.swift)
has account/profile actions and a separate official username-management handoff,
but no service-center entry; the service-center route is also absent from
`App/Sources`. Existing login or reporting facilities do not themselves complete
this workflow. A separate implementation has been assigned and is in progress;
it is **not counted as implemented by this audit**.

Implementation must distinguish an official-web handoff from a native service
center, define browser/session ownership and account switching, and avoid
exporting Keychain credentials into a general browser. The upstream URL alone
does not prove that the page works with a given iOS or LiveContainer session.

### Inline classic-emoticon rendering while composing

TiebaLite's shared reply/topic editor renders inserted classic-emoticon tokens
as images inside the editable text. [ReplyPage.kt, lines 248–268][composer-insert]
calls `StringUtil.getEmoticonContent` when restoring text and after inserting an
emoticon; [lines 535–565][composer-initial] also apply it to initial editor text.
[StringUtil.kt, lines 30–64][emoticon-spans] finds the token range and attaches an
`EmoticonSpanV2`, retaining the underlying text.

Tieba++ already supports selecting, drafting, submitting, and reading classic
emoticons. The remaining difference is the **editable body presentation**:
[ComposerTextEditor.swift](../App/Sources/ComposerTextEditor.swift), lines 101–114
and 142–144, uses plain `UITextView.text`.
[ReplyComposerView.swift](../App/Sources/ReplyComposerView.swift), lines 951–966,
and [NewThreadComposerView.swift](../App/Sources/NewThreadComposerView.swift),
lines 1008–1022, insert canonical text tokens. Images in the picker do not provide
inline rendering in the body being edited.

A bounded implementation could reuse the existing 126-name catalog and shared
editor without changing the draft or wire format. It must preserve canonical
tokens as the stored/submitted source, correctly map source text and displayed
selection, respect Chinese input-method composition, and support deletion,
replacement, copy/paste, undo/redo, accessibility, and draft restoration.
Native editor tests and device checks are required before claiming completion.
This is a real authoring difference, but not evidence that an entire creation
module is missing.

## Proposed gaps rejected by implementation evidence

| Candidate | Upstream behavior | Existing iOS behavior or conclusion |
| --- | --- | --- |
| Multiple keywords must all match | The [resource text][block-tip] says “含有全部关键词”, and [BlockListPage.kt:91–100][block-input] splits input into a list. [BlockListViewModel.kt:51–60][block-store] persists that list. However, the actual [BlockManager.kt:53–82][block-match] uses `getKeywords().any` for both allow and block rules: matching is OR, not AND. | [ContentFilter.swift](../App/Sources/ContentFilter.swift):516–541 splits batch input, and 1199–1238 implements OR matching with allow precedence. [ContentFilterView.swift](../App/Sources/ContentFilterView.swift):269–292 describes it explicitly. AND groups are not a missing upstream behavior and must not silently replace current batch semantics. |
| Recommendation refresh discards the old feed | [PersonalizedViewModel.kt:287–299][feed-refresh] prepends and deduplicates new data while retaining old data. | [PersonalizedFeedViewModel.swift](../App/Sources/PersonalizedFeedViewModel.swift):686–706 already merges new items before retained items, with an overlap frontier for later pagination. The upstream new/old boundary hint is a presentation difference, not a missing retained-feed workflow. |
| Picture viewing is limited to the currently loaded floor | [PhotoViewActivity.kt:137–158][picture-paging] requests previous/next picture pages at the gallery edges. | [ThreadImageGalleryViewModel.swift](../App/Sources/ThreadImageGalleryViewModel.swift):389–449 already has previous/next requests. [ThreadView.swift](../App/Sources/ThreadView.swift):1805–1828 connects the actual gallery route and current whole-thread-gallery policy. This is not only an unused service declaration. |
| The custom upstream undo/redo menu proves a complete missing workflow | [UndoableEditText.java:42–81][undo-menu] exposes methods and inflates menu entries, but its `onActionItemClicked` returns `false` without dispatching either action. No caller of those custom methods was found in the reviewed source. | The class/menu names alone do not establish a working upstream custom undo flow. Tieba++ uses native `UITextView`; whether programmatic token insertion preserves native undo correctly needs a separate runtime test. This audit neither proves that defect nor credits the upstream custom menu as a complete workflow. |

The targeted topic-detail comparison also found no missing multi-scope feature:
[TopicDetailPage.kt:271–355][topic-detail] displays related forums and one related
thread list, with pagination. [HotTopicDetailView.swift](../App/Sources/HotTopicDetailView.swift):70–124
and [HotTopicDetailViewModel.swift](../App/Sources/HotTopicDetailViewModel.swift):129–169
provide the corresponding workflow. Differences in header collapse are not an
absent second result channel.

## Interpreting the old parity estimate

The existing [ROADMAP capability table](../ROADMAP.md) assigns weights to broad
areas and totals **80–82 out of 100**. That is a coarse weighted estimate, not a
count of reachable menus, not a claim that 18–20% of upstream menu actions are
missing, and not a physical-device-validation percentage. This spot audit does
not add points or replace that estimate.

In particular, unimplemented product ideas must not automatically become
mandatory TiebaLite parity work:

- Voice **creation** is not established by voice playback support: the actual
  [ReplyPage voice button, lines 633–642][voice-button] is commented out.
- A [disagree API implementation][disagree-api] exists, but no reachable caller
  was found in the reviewed page/widget flows. It is not the same action as the
  implemented personalized-recommendation “不感兴趣” feedback.
- A generic “moderation/administration” label does not establish an upstream
  reachable workflow. Specific UI, permissions, request semantics, and results
  must be identified before treating a missing moderation operation as a parity
  requirement. This does not discount the concrete deletion/owner-management
  workflows that Tieba++ already implements, nor claim a full audit of every
  possible upstream administrator path.

Correcting the overall estimate requires a fresh, full inventory of reachable
upstream workflows, a consistent distinction between implementation and runtime
validation, and an explicit weighting method. The two confirmed gaps and the
rejected candidates above are inputs to that review, not a new percentage.

[service-center]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/main/user/UserPage.kt#L378-L389
[composer-insert]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/reply/ReplyPage.kt#L248-L268
[composer-initial]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/reply/ReplyPage.kt#L535-L565
[emoticon-spans]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/utils/StringUtil.kt#L30-L64
[block-tip]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/res/values/strings.xml#L397
[block-input]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/settings/block/blocklist/BlockListPage.kt#L91-L100
[block-store]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/settings/block/blocklist/BlockListViewModel.kt#L51-L60
[block-match]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/utils/BlockManager.kt#L53-L82
[feed-refresh]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/main/explore/personalized/PersonalizedViewModel.kt#L287-L299
[picture-paging]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/photoview/PhotoViewActivity.kt#L137-L158
[undo-menu]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/widgets/edittext/widget/UndoableEditText.java#L42-L81
[topic-detail]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/hottopic/detail/TopicDetailPage.kt#L271-L355
[voice-button]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/reply/ReplyPage.kt#L633-L642
[disagree-api]: https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/api/interfaces/impls/MixedTiebaApiImpl.kt#L211-L238
