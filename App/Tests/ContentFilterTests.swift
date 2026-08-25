import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ContentFilterTests: XCTestCase {
  func testWholeThreadPictureGalleryRequiresAnUnfilteredSnapshot() {
    XCTAssertTrue(ContentFilterSnapshot.empty.allowsWholeThreadPictureGallery)

    XCTAssertFalse(
      ContentFilterSnapshot(
        displayMode: .placeholder,
        blockVideos: true,
        rules: []
      ).allowsWholeThreadPictureGallery
    )
    XCTAssertFalse(
      ContentFilterSnapshot(
        displayMode: .hidden,
        blockVideos: false,
        rules: [.keyword("blocked", list: .block)]
      ).allowsWholeThreadPictureGallery
    )
    XCTAssertFalse(
      ContentFilterSnapshot(
        displayMode: .placeholder,
        blockVideos: false,
        rules: [.user(id: 7, name: "allowed", list: .allow)]
      ).allowsWholeThreadPictureGallery
    )
  }

  func testKeywordAllowListAppliesPerFieldAndRemainsCaseSensitive() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .keyword("广告", list: .block),
        .keyword("可信广告", list: .allow),
        .keyword("SPAM", list: .block),
      ]
    )

    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信广告", excerpt: "ordinary")),
      .visible
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信广告", excerpt: "仍有广告")),
      .placeholder
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "spam", excerpt: "ordinary")),
      .visible
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "SPAM", excerpt: "ordinary")),
      .placeholder
    )
  }

  func testRegularExpressionRulesMatchTheSupportedUnicodeSubset() throws {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        try .regularExpression(
          #"^(可信|普通)\s+广告\d{2,4}$"#,
          list: .block
        )
      ]
    )

    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信 广告2026", excerpt: "ordinary")),
      .placeholder
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信 广告20A6", excerpt: "ordinary")),
      .visible
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "前缀 可信 广告2026", excerpt: "ordinary")),
      .visible
    )
  }

  func testRegularExpressionAllowListRemainsScopedToOneInspectedField() throws {
    let snapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [
        try .regularExpression(#"广告\d+"#, list: .block),
        try .regularExpression(#"^可信广告\d+$"#, list: .allow),
      ]
    )

    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信广告2026", excerpt: "ordinary")),
      .visible
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "可信广告2026", excerpt: "另有广告7")),
      .hidden
    )
  }

  func testLiteralRuleStillTreatsRegularExpressionMetacharactersLiterally() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("广告.*推广", list: .block)]
    )

    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "广告.*推广", excerpt: "ordinary")),
      .placeholder
    )
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "广告很多推广", excerpt: "ordinary")),
      .visible
    )
  }

  func testRegularExpressionValidationRejectsUnsupportedOrUnboundedSyntax() throws {
    let invalidPatterns = [
      #"(?=广告)"#,
      #"(广告)\1"#,
      #"广告+?"#,
      #"[广告"#,
      #"广告{257}"#,
    ]

    for pattern in invalidPatterns {
      XCTAssertNotNil(
        ContentFilterKeywordPatternPolicy.validationMessage(
          for: pattern,
          mode: .regularExpression
        ),
        "Expected pattern to be rejected: \(pattern)"
      )
    }

    XCTAssertEqual(
      try ContentFilterKeywordPatternPolicy.validated(
        "  literal  ",
        mode: .literal
      ),
      "literal"
    )
    XCTAssertEqual(
      try ContentFilterKeywordPatternPolicy.validated(
        "^ literal $",
        mode: .regularExpression
      ),
      "^ literal $"
    )
  }

  func testNestedQuantifiersHaveBoundedNonBacktrackingExecution() throws {
    let expression = try SafeContentFilterRegex(#"^(a+)+$"#)
    let adversarial = String(repeating: "a", count: 8_192) + "!"

    XCTAssertFalse(expression.matches(in: adversarial))
  }

  func testRegularExpressionInputLimitDoesNotFabricateEndOrBoundary() throws {
    let prefixMatch = try SafeContentFilterRegex("广告")
    let endMatch = try SafeContentFilterRegex("广告$")
    let boundaryMatch = try SafeContentFilterRegex(#"广告\b"#)
    let longWord = String(repeating: "a", count: 8_190) + "广告" + "x"

    XCTAssertTrue(prefixMatch.matches(in: longWord))
    XCTAssertFalse(endMatch.matches(in: longWord))
    XCTAssertFalse(boundaryMatch.matches(in: longWord))
    XCTAssertTrue(boundaryMatch.matches(in: String(repeating: "a", count: 8_190) + "广告!"))
  }

  func testRegularExpressionBudgetExhaustionFailsOpenBeforeBlocking() throws {
    let expensiveExpression = try SafeContentFilterRegex(#"(a?){126}z"#)
    let input = SafeContentFilterRegex.Input(String(repeating: "a", count: 8_192))
    var workspace = SafeContentFilterRegex.Workspace()
    var budget = ContentFilterSnapshot.regularExpressionStepBudgetPerField
    XCTAssertEqual(
      expensiveExpression.match(
        in: input,
        workspace: &workspace,
        remainingSteps: &budget
      ),
      .budgetExhausted
    )

    let snapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [
        try .regularExpression(#"(a?){126}z"#, list: .allow),
        .keyword("a", list: .block),
      ]
    )

    XCTAssertEqual(
      snapshot.visibility(
        for: thread(
          title: String(repeating: "a", count: 8_192),
          excerpt: "text"
        )
      ),
      .visible
    )
  }

  func testRegularExpressionWorkspaceCanBeReusedAfterBudgetExhaustion() throws {
    let expression = try SafeContentFilterRegex("a+z")
    var workspace = SafeContentFilterRegex.Workspace()
    var exhaustedBudget = 1

    XCTAssertEqual(
      expression.match(
        in: SafeContentFilterRegex.Input("aaaa"),
        workspace: &workspace,
        remainingSteps: &exhaustedBudget
      ),
      .budgetExhausted
    )

    var sufficientBudget = 1_000
    XCTAssertEqual(
      expression.match(
        in: SafeContentFilterRegex.Input("aaaz"),
        workspace: &workspace,
        remainingSteps: &sufficientBudget
      ),
      .matched
    )
  }

  func testUserAllowListWinsForIdentityButDoesNotExemptBlockedText() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .user(id: 7, name: "Blocked User", list: .block),
        .user(id: 7, name: "Trusted User", list: .allow),
        .keyword("广告", list: .block),
      ]
    )

    XCTAssertEqual(
      snapshot.visibility(
        for: thread(title: "ordinary", excerpt: "ordinary", authorID: 7, authorName: "Other")
      ),
      .visible
    )
    XCTAssertEqual(
      snapshot.visibility(
        for: thread(title: "广告", excerpt: "ordinary", authorID: 7, authorName: "Other")
      ),
      .placeholder
    )
    XCTAssertEqual(
      snapshot.visibility(
        for: thread(title: "ordinary", excerpt: "ordinary", authorID: 8, authorName: "Blocked User")
      ),
      .placeholder
    )
  }

  func testUserRulesMatchPreferredNameOrRealUsernameAndPreserveUsername() {
    let blockedByUsername = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.user(id: 0, name: "real_username", list: .block)]
    )
    let author = thread(
      title: "ordinary",
      excerpt: "ordinary",
      authorName: "Display Name",
      authorUsername: "real_username"
    )

    XCTAssertEqual(blockedByUsername.visibility(for: author), .placeholder)
    XCTAssertEqual(
      blockedByUsername.applying(to: author).authorUsername,
      "real_username"
    )

    let allowedByUsername = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .user(id: 0, name: "Display Name", list: .block),
        .user(id: 0, name: "real_username", list: .allow),
      ]
    )
    XCTAssertEqual(allowedByUsername.visibility(for: author), .visible)
  }

  func testInboxMessageContentUsesConfiguredDisplayModeAndIgnoresVideoSwitch() {
    let placeholder = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked content", list: .block)]
    )
    let hidden = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [.keyword("blocked content", list: .block)]
    )
    let videoOnly = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: true,
      rules: []
    )

    XCTAssertEqual(
      placeholder.visibility(for: inboxMessage(content: "contains blocked content")),
      .placeholder
    )
    XCTAssertEqual(
      hidden.visibility(for: inboxMessage(content: "contains blocked content")),
      .hidden
    )
    XCTAssertEqual(
      placeholder.visibility(for: inboxMessage(content: "ordinary content")),
      .visible
    )
    XCTAssertEqual(
      videoOnly.visibility(for: inboxMessage(content: "[视频]", threadType: 40)),
      .visible
    )
  }

  func testInboxMessageSenderRulesMatchUIDDisplayNameAndUsername() {
    let message = inboxMessage(
      senderID: 7,
      senderDisplayName: "Sender Display",
      senderUsername: "sender-account"
    )
    let cases: [(ContentFilterRule, String)] = [
      (.user(id: 7, name: "", list: .block), "UID"),
      (.user(id: nil, name: "Sender Display", list: .block), "display name"),
      (.user(id: nil, name: "sender-account", list: .block), "username"),
    ]

    for (rule, field) in cases {
      let snapshot = ContentFilterSnapshot(
        displayMode: .placeholder,
        blockVideos: false,
        rules: [rule]
      )
      XCTAssertEqual(
        snapshot.visibility(for: message),
        .placeholder,
        "Expected sender \(field) to match"
      )
    }
  }

  func testInboxMessageAllowRulesRemainIsolatedToKeywordAndSenderDomains() {
    let keywordAllowed = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .keyword("广告", list: .block),
        .keyword("可信广告", list: .allow),
      ]
    )
    XCTAssertEqual(
      keywordAllowed.visibility(for: inboxMessage(content: "可信广告")),
      .visible
    )

    let senderAllowed = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .user(id: nil, name: "Blocked Display", list: .block),
        .user(id: nil, name: "trusted-account", list: .allow),
      ]
    )
    let trustedSender = inboxMessage(
      senderDisplayName: "Blocked Display",
      senderUsername: "trusted-account"
    )
    XCTAssertEqual(senderAllowed.visibility(for: trustedSender), .visible)

    let userAllowDoesNotExemptContent = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [
        .user(id: 7, name: "", list: .allow),
        .keyword("blocked content", list: .block),
      ]
    )
    XCTAssertEqual(
      userAllowDoesNotExemptContent.visibility(
        for: inboxMessage(senderID: 7, content: "blocked content")
      ),
      .hidden
    )

    let keywordAllowDoesNotExemptSender = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [
        .keyword("trusted content", list: .allow),
        .user(id: 7, name: "", list: .block),
      ]
    )
    XCTAssertEqual(
      keywordAllowDoesNotExemptSender.visibility(
        for: inboxMessage(senderID: 7, content: "trusted content")
      ),
      .hidden
    )
  }

  func testInboxMessageExcludesContextAndQuotedUserFromFiltering() {
    let keywordSnapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [.keyword("excluded sentinel", list: .block)]
    )
    let keywordCases: [(InboxMessage, String)] = [
      (inboxMessage(title: "excluded sentinel"), "title"),
      (inboxMessage(quotedContent: "excluded sentinel"), "quoted content"),
      (inboxMessage(forumName: "excluded sentinel"), "forum name"),
    ]
    for (message, field) in keywordCases {
      XCTAssertEqual(
        keywordSnapshot.visibility(for: message),
        .visible,
        "Expected \(field) to stay outside keyword matching"
      )
    }

    let quotedUser = inboxSender(
      id: 91,
      displayName: "Quoted Display",
      username: "quoted-account"
    )
    let quotedUserRules: [(ContentFilterRule, String)] = [
      (.user(id: 91, name: "", list: .block), "quoted user UID"),
      (.user(id: nil, name: "Quoted Display", list: .block), "quoted display name"),
      (.user(id: nil, name: "quoted-account", list: .block), "quoted username"),
    ]
    for (rule, field) in quotedUserRules {
      let snapshot = ContentFilterSnapshot(
        displayMode: .hidden,
        blockVideos: false,
        rules: [rule]
      )
      XCTAssertEqual(
        snapshot.visibility(for: inboxMessage(quotedUser: quotedUser)),
        .visible,
        "Expected \(field) to stay outside sender matching"
      )
    }
  }

  func testInboxMessageEmptySenderNamesDoNotMatchSynthesizedPreferredName() {
    let message = inboxMessage(
      senderID: 7,
      senderDisplayName: "",
      senderUsername: ""
    )
    XCTAssertEqual(message.sender.preferredName, "用户 7")

    let syntheticName = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.user(id: nil, name: "用户 7", list: .block)]
    )
    XCTAssertEqual(syntheticName.visibility(for: message), .visible)

    let exactUID = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.user(id: 7, name: "", list: .block)]
    )
    XCTAssertEqual(exactUID.visibility(for: message), .placeholder)
  }

  func testPostAndCommentUseLosslessVisiblePlainText() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [.keyword("@Target继续", list: .block)]
    )
    let post = BrowsePost(
      id: 1,
      threadID: 2,
      floor: 1,
      authorID: 3,
      authorName: "Author",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: true,
      contents: [.mention(name: "Target", userID: 4), .text("继续")]
    )
    let comment = BrowseComment(
      id: 5,
      authorID: 6,
      authorName: "Commenter",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.mention(name: "Target", userID: 4), .text("继续")]
    )

    XCTAssertEqual(snapshot.applying(to: post).localVisibility, .hidden)
    XCTAssertEqual(snapshot.applying(to: comment).localVisibility, .hidden)
    XCTAssertEqual(snapshot.applying(to: post).id, post.id)
    XCTAssertEqual(snapshot.applying(to: comment).id, comment.id)
  }

  func testPostFilteringAnnotatesInlineCommentsWithoutChangingTheirOrderOrParent() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked child", list: .block)]
    )
    let blocked = BrowseComment(
      id: 11,
      authorID: 21,
      authorName: "Blocked commenter",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("blocked child")]
    )
    let visible = BrowseComment(
      id: 12,
      authorID: 22,
      authorName: "Visible commenter",
      authorPortraitURL: nil,
      createdAt: nil,
      contents: [.text("ordinary child")]
    )
    let post = BrowsePost(
      id: 10,
      threadID: 2,
      floor: 3,
      authorID: 20,
      authorName: "Parent author",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 8,
      isThreadAuthor: false,
      contents: [.text("ordinary parent")],
      inlineComments: [blocked, visible]
    )

    let filtered = snapshot.applying(to: post)

    XCTAssertEqual(filtered.localVisibility, .visible)
    XCTAssertEqual(filtered.nestedReplyCount, 8)
    XCTAssertEqual(filtered.inlineComments.map(\.id), [11, 12])
    XCTAssertEqual(filtered.inlineComments.map(\.localVisibility), [.placeholder, .visible])
    XCTAssertEqual(
      filtered.withLocalVisibility(.hidden).inlineComments,
      filtered.inlineComments
    )
  }

  func testVideoSwitchBlocksOnlyThreadsContainingVideo() throws {
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/author-token")
    )
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: true,
      rules: []
    )
    let videoThread = BrowseThread(
      id: 1,
      forumID: 2,
      forumName: "swift",
      title: "Video",
      excerpt: "",
      authorName: "Author",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.video(url: nil, cover: nil, width: 0, height: 0)],
      authorAvatarURL: authorAvatarURL,
      firstPostID: 11,
      shareCount: 3,
      agreeCount: 8,
      disagreeCount: 2,
      kind: .video,
      tabID: 9,
      isPinned: true,
      isFeatured: true,
      isShared: true,
      isServerHidden: true,
      isLive: true
    )
    let textThread = thread(title: "Text", excerpt: "ordinary")

    XCTAssertEqual(snapshot.visibility(for: videoThread), .placeholder)
    XCTAssertEqual(snapshot.visibility(for: textThread), .visible)
    let filtered = snapshot.applying(to: videoThread)
    XCTAssertEqual(filtered.firstPostID, videoThread.firstPostID)
    XCTAssertEqual(filtered.contents, videoThread.contents)
    XCTAssertEqual(filtered.authorAvatarURL, authorAvatarURL)
    XCTAssertEqual(filtered.kind, videoThread.kind)
    XCTAssertEqual(filtered.shareCount, videoThread.shareCount)
    XCTAssertEqual(filtered.agreeScore, videoThread.agreeScore)
    XCTAssertEqual(filtered.tabID, videoThread.tabID)
    XCTAssertEqual(filtered.isPinned, videoThread.isPinned)
    XCTAssertEqual(filtered.isFeatured, videoThread.isFeatured)
    XCTAssertEqual(filtered.isShared, videoThread.isShared)
    XCTAssertEqual(filtered.isServerHidden, videoThread.isServerHidden)
    XCTAssertEqual(filtered.isLive, videoThread.isLive)
  }

  func testKnownVideoBlocksSearchResultWithoutSyntheticVideoContent() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: true,
      rules: [
        .keyword("Trusted video", list: .allow),
        .user(id: 7, name: "Trusted author", list: .allow),
      ]
    )
    let result = thread(
      title: "Trusted video",
      excerpt: "ordinary",
      authorID: 7,
      authorName: "Trusted author"
    )

    XCTAssertFalse(
      result.contents.contains { content in
        guard case .video = content else { return false }
        return true
      }
    )
    XCTAssertEqual(snapshot.visibility(for: result), .visible)
    XCTAssertEqual(
      snapshot.visibility(for: result, hasKnownVideo: true),
      .placeholder
    )
    XCTAssertEqual(
      snapshot.applying(to: result, hasKnownVideo: true).localVisibility,
      .placeholder
    )
  }

  func testKnownVideoUsesHiddenDisplayMode() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: true,
      rules: []
    )

    XCTAssertEqual(
      snapshot.visibility(
        for: thread(title: "Video search result", excerpt: "ordinary"),
        hasKnownVideo: true
      ),
      .hidden
    )
  }

  func testForumPostSearchModelsDefaultVisibleAndCopyLosslessly() throws {
    let summary = ForumPostSearchSummary(
      postID: 41,
      title: "Context title",
      excerpt: "Context excerpt",
      authorID: 42,
      authorName: "Context display name",
      authorUsername: "context-account"
    )
    let item = forumPostSearchItem(
      threadAuthorID: 11,
      matchedAuthorID: 22,
      context: summary,
      matchedContents: [.text("Matched body")]
    )

    XCTAssertEqual(summary.localVisibility, .visible)
    XCTAssertEqual(item.localVisibility, .visible)
    XCTAssertEqual(
      item.contexts.map(\.target),
      [.parentPost(threadID: 1, postID: 41)]
    )

    let context = try XCTUnwrap(item.contexts.first)
    let annotatedContext = context.withLocalVisibility(.hidden)
    XCTAssertEqual(annotatedContext.summary.localVisibility, .hidden)
    XCTAssertEqual(annotatedContext.withLocalVisibility(.visible), context)

    let annotatedItem = item.withLocalPresentation(
      visibility: .placeholder,
      thread: item.thread.withLocalVisibility(.hidden),
      contexts: [annotatedContext]
    )
    XCTAssertEqual(annotatedItem.localVisibility, .placeholder)
    XCTAssertEqual(annotatedItem.thread.localVisibility, .hidden)
    XCTAssertEqual(annotatedItem.contexts.first?.summary.localVisibility, .hidden)
    XCTAssertEqual(annotatedItem.contexts.first?.target, context.target)
    XCTAssertEqual(
      annotatedItem.withLocalPresentation(
        visibility: item.localVisibility,
        thread: item.thread,
        contexts: item.contexts
      ),
      item
    )
  }

  func testForumPostSearchAuthorsAreFilteredIndependently() {
    let item = forumPostSearchItem(
      threadAuthorID: 11,
      matchedAuthorID: 22,
      context: ForumPostSearchSummary(
        postID: 31,
        title: "ordinary context",
        excerpt: "ordinary context excerpt",
        authorID: 33,
        authorName: "Context author"
      )
    )
    let cases: [(Int64, LocalContentVisibility, LocalContentVisibility, LocalContentVisibility)] = [
      (11, .visible, .placeholder, .visible),
      (22, .placeholder, .visible, .visible),
      (33, .visible, .visible, .placeholder),
    ]

    for (blockedID, expectedItem, expectedThread, expectedContext) in cases {
      let snapshot = ContentFilterSnapshot(
        displayMode: .placeholder,
        blockVideos: false,
        rules: [.user(id: blockedID, name: "", list: .block)]
      )
      let filtered = snapshot.applying(to: item)

      XCTAssertEqual(filtered.localVisibility, expectedItem, "blocked ID: \(blockedID)")
      XCTAssertEqual(
        filtered.thread.localVisibility,
        expectedThread,
        "blocked ID: \(blockedID)"
      )
      XCTAssertEqual(
        filtered.contexts.first?.summary.localVisibility,
        expectedContext,
        "blocked ID: \(blockedID)"
      )
    }
  }

  func testForumPostSearchKeywordAllowListIsScopedToEachFieldAndLayer() {
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [
        .keyword("广告", list: .block),
        .keyword("可信广告", list: .allow),
      ]
    )
    let blockedExcerpt = forumPostSearchItem(
      matchedTitle: "可信广告",
      matchedExcerpt: "这里仍有广告"
    )
    let blockedContext = forumPostSearchItem(
      matchedTitle: "可信广告",
      matchedExcerpt: "ordinary match",
      context: ForumPostSearchSummary(
        postID: 31,
        title: "可信广告",
        excerpt: "上下文仍有广告",
        authorID: 33,
        authorName: "Context author"
      )
    )
    let allowedContents = forumPostSearchItem(
      matchedTitle: "ordinary match",
      matchedExcerpt: "ordinary match excerpt",
      matchedContents: [.text("可信广告中含有广告")]
    )

    XCTAssertEqual(snapshot.applying(to: blockedExcerpt).localVisibility, .placeholder)

    let contextFiltered = snapshot.applying(to: blockedContext)
    XCTAssertEqual(contextFiltered.localVisibility, .visible)
    XCTAssertEqual(contextFiltered.thread.localVisibility, .visible)
    XCTAssertEqual(contextFiltered.contexts.first?.summary.localVisibility, .placeholder)

    XCTAssertEqual(snapshot.applying(to: allowedContents).localVisibility, .visible)
  }

  func testForumPostSearchContextCanHideWithoutHidingMainResult() {
    let item = forumPostSearchItem(
      context: ForumPostSearchSummary(
        postID: 31,
        title: "ordinary context",
        excerpt: "ordinary context excerpt",
        authorID: 33,
        authorName: "Blocked context"
      )
    )
    let snapshot = ContentFilterSnapshot(
      displayMode: .hidden,
      blockVideos: false,
      rules: [.user(id: 33, name: "", list: .block)]
    )

    let filtered = snapshot.applying(to: item)

    XCTAssertEqual(filtered.localVisibility, .visible)
    XCTAssertEqual(filtered.thread.localVisibility, .visible)
    XCTAssertEqual(filtered.contexts.first?.summary.localVisibility, .hidden)
  }

  func testForumPostSearchParentAndMainContextsAreFilteredIndependently() throws {
    let parent = ForumPostSearchContext(
      target: .parentPost(threadID: 1, postID: 31),
      summary: ForumPostSearchSummary(
        postID: 31,
        title: "Parent",
        excerpt: "Parent content",
        authorID: 33,
        authorName: "Blocked parent"
      )
    )
    let main = ForumPostSearchContext(
      target: .mainPost(threadID: 1),
      summary: ForumPostSearchSummary(
        postID: 10,
        title: "Topic",
        excerpt: "Topic content",
        authorID: 44,
        authorName: "Visible topic"
      )
    )
    let item = forumPostSearchItem(context: nil, contexts: [parent, main])
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.user(id: 33, name: "", list: .block)]
    )

    let filtered = snapshot.applying(to: item)

    XCTAssertEqual(filtered.contexts.map(\.target), [parent.target, main.target])
    XCTAssertEqual(
      filtered.contexts.map(\.summary.localVisibility),
      [.placeholder, .visible]
    )
    let filteredParent = try XCTUnwrap(filtered.contexts.first)
    let filteredMain = try XCTUnwrap(filtered.contexts.dropFirst().first)
    XCTAssertNil(
      ForumPostSearchNavigationPolicy.contextDestination(
        for: filtered,
        context: filteredParent
      )
    )
    XCTAssertEqual(
      ForumPostSearchNavigationPolicy.contextDestination(
        for: filtered,
        context: filteredMain
      ),
      .thread(thread: filtered.thread, route: TiebaThreadRoute(threadID: 1))
    )
  }

  func testForumPostSearchKnownVideoOnlyAnnotatesMainResultWithoutSynthesizingMedia() {
    let item = forumPostSearchItem(matchedContents: [])
    let snapshot = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: true,
      rules: []
    )

    let filtered = snapshot.applying(to: item, hasKnownVideo: true)

    XCTAssertEqual(filtered.localVisibility, .placeholder)
    XCTAssertEqual(filtered.thread.localVisibility, .visible)
    XCTAssertEqual(filtered.contexts.first?.summary.localVisibility, .visible)
    XCTAssertEqual(filtered.matchedContents, item.matchedContents)
    XCTAssertFalse(
      filtered.matchedContents.contains { content in
        guard case .video = content else { return false }
        return true
      }
    )

    let explicitVideo = forumPostSearchItem(
      matchedContents: [.video(url: nil, cover: nil, width: 0, height: 0)]
    )
    XCTAssertEqual(snapshot.applying(to: explicitVideo).localVisibility, .placeholder)
  }

  func testFileStoreNormalizesPersistsAndRejectsDuplicates() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL, maximumRules: 3)
    let saved = try await store.add(
      .keyword(
        "  广告  ",
        list: .block,
        createdAt: Date(timeIntervalSince1970: 1)
      )
    )

    XCTAssertEqual(saved.keyword, "广告")
    try await store.setDisplayMode(.hidden)
    try await store.setBlockVideos(true)
    var snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.displayMode, .hidden)
    XCTAssertTrue(snapshot.blockVideos)
    XCTAssertEqual(snapshot.rules, [saved])
    let settingsReload = try await FileContentFilterStore(fileURL: fileURL).snapshot()
    XCTAssertEqual(settingsReload.displayMode, .hidden)
    XCTAssertTrue(settingsReload.blockVideos)
    XCTAssertEqual(settingsReload.rules, [saved])

    do {
      _ = try await store.add(.keyword("广告", list: .block))
      XCTFail("Expected duplicate rule to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .duplicateRule)
    }

    let user = try await store.add(
      .user(
        id: 7,
        name: " User ",
        list: .allow,
        createdAt: Date(timeIntervalSince1970: 2)
      )
    )
    XCTAssertEqual(user.username, "User")
    snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.rules.count, 2)

    try await store.delete(id: saved.id)
    snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.rules, [user])
    try await store.deleteAll(in: .allow)
    snapshot = try await store.snapshot()
    XCTAssertTrue(snapshot.rules.isEmpty)
    let finalReload = try await FileContentFilterStore(fileURL: fileURL).snapshot()
    XCTAssertTrue(finalReload.rules.isEmpty)
    XCTAssertEqual(finalReload.displayMode, .hidden)
    XCTAssertTrue(finalReload.blockVideos)
  }

  func testFileStorePersistsRegularExpressionsAndSeparatesMatchModeIdentity() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL)
    let literal = try await store.add(
      .keyword(
        "广告.+",
        list: .block,
        createdAt: Date(timeIntervalSince1970: 1)
      )
    )
    let expression = try await store.add(
      try .regularExpression(
        "广告.+",
        list: .block,
        createdAt: Date(timeIntervalSince1970: 2)
      )
    )

    let reloadedStore = FileContentFilterStore(fileURL: fileURL)
    let snapshot = try await reloadedStore.snapshot()
    XCTAssertEqual(snapshot.rules.count, 2)
    XCTAssertTrue(snapshot.rules.contains(literal))
    XCTAssertTrue(snapshot.rules.contains(expression))
    XCTAssertEqual(
      snapshot.visibility(for: thread(title: "广告内容", excerpt: "ordinary")),
      .placeholder
    )

    do {
      _ = try await store.add(
        try .regularExpression("广告.+", list: .block)
      )
      XCTFail("Expected duplicate regular expression to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .duplicateRule)
    }
  }

  func testFileStoreRejectsInvalidAndExcessRegularExpressions() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(
      fileURL: fileURL,
      maximumRegularExpressionRules: 1
    )

    XCTAssertThrowsError(
      try ContentFilterRule.regularExpression(#"(?=unsafe)"#, list: .block)
    )

    _ = try await store.add(try .regularExpression("first.+", list: .block))
    do {
      _ = try await store.add(try .regularExpression("second.+", list: .block))
      XCTFail("Expected regular-expression limit to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .tooManyRegularExpressions)
    }
  }

  func testVersionOneArchiveMigratesWithoutLosingLiteralRules() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let ruleID = UUID()
    let legacyArchive: [String: Any] = [
      "schemaVersion": 1,
      "displayMode": "placeholder",
      "blockVideos": false,
      "rules": [
        [
          "id": ruleID.uuidString,
          "list": "block",
          "kind": "keyword",
          "keyword": "广告",
          "keywordMatchMode": "literal",
          "username": "",
          "createdAt": 1_000,
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: legacyArchive).write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    var snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.rules.map(\.id), [ruleID])
    XCTAssertEqual(snapshot.rules.map(\.keywordMatchMode), [.literal])

    _ = try await store.add(
      try .regularExpression("推广.+", list: .block)
    )
    snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.rules.count, 2)
    let persisted = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(persisted["schemaVersion"] as? Int, 2)
  }

  func testCorruptedArchiveIsPreservedUntilExplicitReset() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let original = Data("not-json".utf8)
    try original.write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected corrupted archive")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    do {
      _ = try await store.add(.keyword("广告", list: .block))
      XCTFail("Expected ordinary write to preserve corrupted archive")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)

    try await store.reset()
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    let resetSnapshot = try await store.snapshot()
    XCTAssertEqual(resetSnapshot, .empty)
  }

  func testMutationRevalidatesDiskInsteadOfOverwritingACachedSnapshot() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL)
    _ = try await store.add(.keyword("first", list: .block))
    let cachedSnapshot = try await store.snapshot()
    XCTAssertEqual(cachedSnapshot.rules.map(\.keyword), ["first"])

    let replacement = Data("not-json".utf8)
    try replacement.write(to: fileURL)
    do {
      _ = try await store.add(.keyword("second", list: .block))
      XCTFail("Expected the current disk archive to be revalidated")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), replacement)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected the failed mutation to invalidate the stale cache")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
  }

  func testStoreRejectsEmptyInvalidAndExcessRules() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL, maximumRules: 1)

    do {
      _ = try await store.add(.keyword("   ", list: .block))
      XCTFail("Expected empty keyword to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .invalidRule)
    }
    do {
      _ = try await store.add(.user(id: 0, name: "", list: .block))
      XCTFail("Expected invalid user to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .invalidRule)
    }

    _ = try await store.add(.keyword("first", list: .block))
    do {
      _ = try await store.add(.keyword("second", list: .block))
      XCTFail("Expected rule limit to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .tooManyRules)
    }
  }

  func testFutureArchiveVersionIsRejected() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{\"schemaVersion\":99}".utf8).write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected future archive version to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .unsupportedSchemaVersion(99))
    }
  }

  func testArchiveContainingAnInvalidRegularExpressionIsPreserved() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let archive: [String: Any] = [
      "schemaVersion": 2,
      "displayMode": "placeholder",
      "blockVideos": false,
      "rules": [
        [
          "id": UUID().uuidString,
          "list": "block",
          "kind": "keyword",
          "keyword": "(?=unsafe)",
          "keywordMatchMode": "regular-expression",
          "username": "",
          "createdAt": 1_000,
        ]
      ],
    ]
    let original = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
    try original.write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected invalid regular expression archive to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
  }

  func testVersionTwoArchiveCannotSilentlyDowngradeAMissingMatchMode() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let archive: [String: Any] = [
      "schemaVersion": 2,
      "displayMode": "placeholder",
      "blockVideos": false,
      "rules": [
        [
          "id": UUID().uuidString,
          "list": "block",
          "kind": "keyword",
          "keyword": "广告.+",
          "username": "",
          "createdAt": 1_000,
        ]
      ],
    ]
    let original = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
    try original.write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected missing v2 match mode to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
  }

  func testVersionOneArchiveCannotSmuggleARegularExpression() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let archive: [String: Any] = [
      "schemaVersion": 1,
      "displayMode": "placeholder",
      "blockVideos": false,
      "rules": [
        [
          "id": UUID().uuidString,
          "list": "block",
          "kind": "keyword",
          "keyword": "广告.+",
          "keywordMatchMode": "regular-expression",
          "username": "",
          "createdAt": 1_000,
        ]
      ],
    ]
    let original = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
    try original.write(to: fileURL)
    let store = FileContentFilterStore(fileURL: fileURL)

    do {
      _ = try await store.snapshot()
      XCTFail("Expected forged v1 regular expression to fail")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
  }

  private func thread(
    title: String,
    excerpt: String,
    authorID: Int64 = 0,
    authorName: String = "Author",
    authorUsername: String = ""
  ) -> BrowseThread {
    BrowseThread(
      id: 1,
      forumID: 2,
      forumName: "swift",
      title: title,
      excerpt: excerpt,
      authorName: authorName,
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      authorID: authorID,
      authorUsername: authorUsername
    )
  }

  private func inboxMessage(
    senderID: Int64 = 7,
    senderDisplayName: String = "Sender Display",
    senderUsername: String = "sender-account",
    title: String = "Thread title",
    content: String = "ordinary content",
    quotedContent: String = "quoted content",
    forumName: String = "swift",
    quotedUser: InboxSender? = nil,
    threadType: Int = 0
  ) -> InboxMessage {
    InboxMessage(
      id: 101,
      sender: inboxSender(
        id: senderID,
        displayName: senderDisplayName,
        username: senderUsername
      ),
      quotedUser: quotedUser,
      threadID: 201,
      postID: 101,
      quotedPostID: quotedUser == nil ? nil : 99,
      title: title,
      content: content,
      quotedContent: quotedContent,
      forumName: forumName,
      createdAt: Date(timeIntervalSince1970: 100),
      isFloorReply: false,
      isFirstPost: false,
      isUnread: true,
      threadType: threadType
    )
  }

  private func inboxSender(
    id: Int64,
    displayName: String,
    username: String
  ) -> InboxSender {
    InboxSender(
      id: id,
      username: username,
      displayName: displayName,
      portraitURL: nil,
      isFriend: false,
      isFan: false
    )
  }

  private func forumPostSearchItem(
    threadAuthorID: Int64 = 11,
    matchedAuthorID: Int64 = 22,
    matchedTitle: String = "ordinary match",
    matchedExcerpt: String = "ordinary match excerpt",
    context: ForumPostSearchSummary? = ForumPostSearchSummary(
      postID: 31,
      title: "ordinary context",
      excerpt: "ordinary context excerpt",
      authorID: 33,
      authorName: "Context author"
    ),
    contexts: [ForumPostSearchContext]? = nil,
    matchedContents: [BrowseContent] = []
  ) -> ForumPostSearchItem {
    ForumPostSearchItem(
      thread: BrowseThread(
        id: 1,
        forumID: 2,
        forumName: "swift",
        title: "ordinary thread",
        excerpt: "ordinary thread excerpt",
        authorName: "Thread author",
        replyCount: 3,
        viewCount: 4,
        createdAt: Date(timeIntervalSince1970: 100),
        lastReplyAt: Date(timeIntervalSince1970: 200),
        contents: [.text("ordinary thread contents")],
        authorID: threadAuthorID,
        authorUsername: "thread-account",
        firstPostID: 10,
        shareCount: 5,
        agreeCount: 6,
        disagreeCount: 1,
        kind: .article,
        tabID: 7,
        isPinned: true,
        isFeatured: true,
        isShared: true,
        isServerHidden: true,
        isLive: true
      ),
      target: .comment(postID: 31, commentID: 32),
      matchedTitle: matchedTitle,
      matchedExcerpt: matchedExcerpt,
      matchedAuthorID: matchedAuthorID,
      matchedAuthorName: "Matched author",
      matchedAuthorPortraitURL: URL(string: "https://example.com/matched.png"),
      matchedAt: Date(timeIntervalSince1970: 300),
      replyCount: 8,
      likeCount: 9,
      shareCount: 10,
      matchedContents: matchedContents,
      contexts: contexts ?? context.map {
        [
          ForumPostSearchContext(
            target: .parentPost(threadID: 1, postID: $0.postID),
            summary: $0
          )
        ]
      } ?? [],
      matchedAuthorUsername: "matched-account"
    )
  }

  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("TiebaPlusPlus-ContentFilterTests-\(UUID().uuidString)")
      .appendingPathComponent("content-filters.json")
  }
}
