# Search and inbox release validation

Alpha.47/build 125 is the replacement release candidate. Its focused native
checks below have passed; full tagged CI, IPA packaging/publication and final
public source/asset verification remain pending. No full-suite result or
published IPA is claimed by these candidate results.

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
candidate and no IPA was published for it. The public source remains alpha.44
until the replacement candidate completes all publication gates.

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
test count. Alpha.47's full regression, IPA packaging/publication and public
source/asset verification remain pending. Simulator success does not replace
iOS 16, LiveContainer or physical-device checks.
