# Search and inbox release validation

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

The unchanged InboxScopes UI suite is running against this candidate in
[native pagination CI](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37189588806).
Its result is required before treating the structural change as a verified fix.

The forum-search cancellation fix restores the pre-request state when leaving,
including a loaded-empty response and any retry error. Returning resumes an
interrupted first read, preserving the submitted query, sort and filter without
calling the history-recording path. A DEBUG fixture exercises the actual
RootView → ForumView → ForumPostSearchView route and native tab changes, then
delivers the cancelled response after the fresh one to check rejection. It
replaces transport and repositories only; it does not invoke the view model or
inject navigation/activation from the test.

The fixture uses offline, in-memory data and no real account. Native candidate
results, the full new tag's regression, IPA packaging and public source/asset
verification are still publication gates. Simulator success does not replace
iOS 16, LiveContainer or physical-device checks.
