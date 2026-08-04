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

  func testVideoSwitchBlocksOnlyThreadsContainingVideo() {
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

  func testForumPostSearchModelsDefaultVisibleAndCopyLosslessly() {
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

    let annotatedSummary = summary.withLocalVisibility(.hidden)
    XCTAssertEqual(annotatedSummary.localVisibility, .hidden)
    XCTAssertEqual(annotatedSummary.withLocalVisibility(.visible), summary)

    let annotatedItem = item.withLocalPresentation(
      visibility: .placeholder,
      thread: item.thread.withLocalVisibility(.hidden),
      context: annotatedSummary
    )
    XCTAssertEqual(annotatedItem.localVisibility, .placeholder)
    XCTAssertEqual(annotatedItem.thread.localVisibility, .hidden)
    XCTAssertEqual(annotatedItem.context?.localVisibility, .hidden)
    XCTAssertEqual(
      annotatedItem.withLocalPresentation(
        visibility: item.localVisibility,
        thread: item.thread,
        context: item.context
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
        filtered.context?.localVisibility,
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
    XCTAssertEqual(contextFiltered.context?.localVisibility, .placeholder)

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
    XCTAssertEqual(filtered.context?.localVisibility, .hidden)
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
    XCTAssertEqual(filtered.context?.localVisibility, .visible)
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
      context: context,
      matchedAuthorUsername: "matched-account"
    )
  }

  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("TiebaPlusPlus-ContentFilterTests-\(UUID().uuidString)")
      .appendingPathComponent("content-filters.json")
  }
}
