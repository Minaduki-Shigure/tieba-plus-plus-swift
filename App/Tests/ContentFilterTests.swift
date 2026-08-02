import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ContentFilterTests: XCTestCase {
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
    authorName: String = "Author"
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
      authorID: authorID
    )
  }

  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("TiebaPlusPlus-ContentFilterTests-\(UUID().uuidString)")
      .appendingPathComponent("content-filters.json")
  }
}
