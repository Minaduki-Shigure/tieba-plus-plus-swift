# Search and inbox release validation

[Alpha.48/build 126](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/releases/tag/v0.65.0-alpha.48)
was published on 2026-10-04 at 12:54:32 UTC. Its [full tagged run](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37198478997)
passed all 2,695 App tests, 27 phone UI tests and three iPad UI tests, with zero
failures or skips, plus Core and anonymous integration. Both jobs in the
[IPA build and publication run](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37203176210)
succeeded. The public source now serves alpha.48/build 126 at source commit
`e457a73dfbe5edfd14318702f320298b92658d1f`.

The published IPA is 7,508,780 bytes, with SHA-256
`687de314d988caa3280955e6b37bb25ebc3719726201adeccf85f6240ac4c5b1`.
The downloaded archive passed integrity checks and matches the source's size
and hash. Its unsigned app has version `0.65.0`, build `126`, minimum iOS `16.0`
and bundle identifier `io.github.minaduki.tieba-plus-plus`. The subsequent
[source-validation job](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37203742112/job/111440528389)
passed both **Validate source metadata** and **Verify published IPA**. This
confirms those publication checks; the same main workflow's additional repeat
Core/App jobs were still running at this verification point.

The [alpha.47 full run](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37193998175)
passed all 2,695 App tests, three iPad UI tests and 25 of 26 phone UI tests, with no skips. All four
inbox regressions passed. The remaining failure was search thread pagination;
it was a separate real product issue and the candidate was withheld. Its
[downstream IPA build](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37198311023)
was skipped by the failed-CI gate.

The search recording shows titles 17–19 at video PTS 73.3 seconds with one thread
request, then titles 36–39 at 73.8 seconds with two requests. Roughly nineteen
200 pt rows moved in half a second, while the ongoing 250 pt/s drag accounts
for only about 125 pt. The corrected viewport helper never observed title 21
in this run. This is different from alpha.45's separately documented viewport
threshold mistake; extending the swipe loop would not fix the product jump.

Search still used a transparent pagination row whose identity changed with its
tail, count and request epoch, plus a loading row removed after each request.
Alpha.48 removes the transparent row and keeps the loading row mounted.
It uses actual visible result rows to request the raw server tail, including a
hidden raw tail; the existing all-hidden status row retains continuation for
fully hidden results. Query/result identities, active-scope checks and the model's
request/error guards still apply. Completion and reactivation reevaluate the
visible tail without replacing a layout anchor.

The original three SearchScopes tests remain unchanged. A new native fixture
holds page two at the service boundary, records title 20's settled position,
then releases only the service response. Without another gesture, title 20 must
stay within 3 pt before the test scrolls to title 21. The request log must contain
exactly pages one and two. The [focused alpha.48 candidate](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37198420318)
passed this test and all three unchanged SearchScopes workflows on iPhone 16 Pro
/ iOS 18.5: four passed, zero failures or skips. The before/after hierarchy records
title 20 at Y=568.7 pt in both states, a 0 pt displacement; the test then reads
title 21 and confirms exactly the two thread requests. Artifact `11301772560`
contains the summary, raw log and screen/hierarchy evidence. The same candidate's
three unchanged suggestion/forum-search integration tests also passed without
a retry; artifact `11302072320` contains their separate summary, log and
attachments. The two summaries independently report 4/0/0 and 3/0/0
(passed/failed/skipped): seven focused UI tests passed. These focused counts are
separate from the complete tagged release result above.

The alpha.45 tag's [full regression](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37184079790)
passed all 2,677 App tests, three iPad UI workflows, Core and anonymous integration.
The phone run passed 22 of 24 UI workflows and failed two. Its IPA publication
was correctly skipped; the public source retained alpha.44/build 122.

The exported native recordings distinguish the two failures:

- Inbox page two actually loaded, but during the same slow drag the visible
  messages jumped from 17–20 to 30–33. Between video 48.5 and 48.7 seconds the
  fixture's page-two count changed from zero to one. A 250 pt/s drag can move
  about 50 pt in that interval, not thirteen rows. The failure therefore exposed
  an actual reading-position jump, not merely a missing fixture response.
- Global search also loaded page two. Its title 21 was fully visible below the
  sort picker, but the test rejected it because it was above an arbitrary 35%
  screen-height boundary. Another full swipe then moved past it. The test now
  uses the real list viewport below the picker, with bounded corrective drags.
  Request-count assertions and the existing 3 pt position assertions remain.

The inbox candidate places the stable message `ForEach` directly in `List` and
uses actual message-row appearance for pagination. It removes the invisible
footer whose identity changed with each page's tail/count/epoch. Returning to a
retained list or completing account/filter validation reevaluates its visible
tail. All-hidden or explicitly paused pagination still requires its existing
Continue control; it cannot automatically drain hidden pages.

The unchanged InboxScopes UI suite passed all three tests with zero failures or
skips in [native pagination CI](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37189588806).
The recording/logs show title 21 actually becoming visible; the original less
than 3 pt position assertions and exact page/refresh counts passed. No retry or
test adjustment was needed for this inbox result.

Independent review found another boundary: a new page can contain only hidden
messages while earlier visible messages remain. Its existing visible tail then
has no new appearance callback. The final candidate also reevaluates pagination
when loading finishes, subject to the same account/activity/error/has-more
guards. A separate fixture holds pages two and three at the transport boundary,
hides page two through the real filter repository, and requires continuation
without another drag plus a stable page-one tail before reading page three.
The [first dedicated native run](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37190333135)
passed the three unchanged inbox workflows but failed the new hidden-page case.
Automatic continuation correctly requested page three exactly once, but title
20 moved from Y=716.67 to Y=810 while that response was still held. The native
video shows the displacement after page two completes, not during the fixture
button tap. Its strict 3 pt assertion therefore catches a real position change.

The next candidate keeps one measured loading-status row mounted whenever the
list has messages. It changes the spinner's opacity rather than removing and
reinserting that row between requests or when pagination ends. Idle status is
hidden from accessibility and hit testing; a retry error can still grow to fit
its text. Account and filtering checks retain their existing privacy behavior.
The [fixed native candidate](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37192652980)
passed the unchanged hidden-page regression: one test, zero failures, skips or
expected failures on iPhone 16 Pro / iOS 18.5. It verifies the original tail stays
within 3 pt both while page three is pending and after its visible rows append,
then reads title 41 with exactly pages 1, 2 and 3 requested and no hidden content
exposed. The same runner then reused the compiled candidate to run the three
original inbox workflows: all three passed, with zero failures, skips or
expected failures. The two exported summaries independently require 1/0/0 and
3/0/0 (passed/failed/skipped), so the complete focused result is four passing
tests. The hidden-page test and all three original tests were unchanged by the
footer fix. Artifacts `11299479000` and `11300083321` contain the summaries,
raw logs and final screen/hierarchy attachments.

The alpha.46 tag's [full CI](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37190889950)
had passed 2,695 App tests with zero failures or skips, plus Core and anonymous
integration, when the separate hidden-page failure was confirmed. The still
running UI gate was cancelled intentionally; alpha.46 is not a passing release
candidate and no IPA was published for it. The public source retained alpha.44
until alpha.48 completed all publication gates.

The forum-search cancellation fix restores the pre-request state when leaving,
including a loaded-empty response and any retry error. Returning resumes an
interrupted first read, preserving the submitted query, sort and filter without
calling the history-recording path. A DEBUG fixture exercises the actual
RootView → ForumView → ForumPostSearchView route and native tab changes, then
delivers the cancelled response after the fresh one to check rejection. It
replaces transport and repositories only; it does not invoke the view model or
inject navigation/activation from the test. Its
[native candidate](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37189754514)
passed all 35 model tests and six UI workflows with zero failures or skips.
The latter include the new resume flow, the three corrected SearchScopes tests
and both suggestion flows. The held old response did not replace the new result,
and returning again did not create another request or history write.

The fixtures use offline, in-memory data and no real account. The ordered-history
and suggestion integration also passed [90 model tests and two UI workflows](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37188924914);
its evidence is recorded in [search history ordering](search-history-ordering.md).
These focused suites overlap and must not be added together as a full-suite
test count. Alpha.48's complete release and public source/IPA verification are
recorded above. Simulator success does not replace iOS 16, LiveContainer or
physical-device checks.
