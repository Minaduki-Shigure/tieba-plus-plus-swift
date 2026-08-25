import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaCoreLinkPreviewServiceTests: XCTestCase {
  func testForumPreviewUsesBoundedReplyTimeRequestAndSanitizesSlogan() async throws {
    let rawSlogan = "  First\u{0000}\n\tSecond  " + String(repeating: "x", count: 200)
    let client = TiebaLinkPreviewClientSpy(
      forumPage: makeThreadPage(
        forum: makeForum(name: "swift", slogan: rawSlogan)
      )
    )
    let service = TiebaCoreBrowseService(linkPreviewClient: client)

    let candidate = try await service.preview(for: .forum("Swift"))
    let metadata = try XCTUnwrap(candidate)

    XCTAssertEqual(metadata.title, "Swift吧")
    XCTAssertEqual(metadata.subtitle.count, 160)
    XCTAssertTrue(metadata.subtitle.hasPrefix("First Second "))
    XCTAssertFalse(metadata.subtitle.contains("  "))
    XCTAssertFalse(
      metadata.subtitle.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
      }
    )

    let snapshot = await client.snapshot()
    XCTAssertEqual(
      snapshot.forumRequests,
      [
        TiebaLinkPreviewForumRequest(
          forumName: "Swift",
          page: 1,
          pageSize: 1,
          sort: .replyTime,
          featuredOnly: false,
          featuredClassificationID: nil
        )
      ]
    )
    XCTAssertTrue(snapshot.threadRequests.isEmpty)
  }

  func testForumPreviewFallsBackToCountsWhenSloganHasNoDisplayableText() async throws {
    let client = TiebaLinkPreviewClientSpy(
      forumPage: makeThreadPage(
        forum: makeForum(
          name: "Swift",
          memberCount: 12,
          threadCount: 34,
          slogan: "\u{0000}\n\t"
        )
      )
    )
    let service = TiebaCoreBrowseService(linkPreviewClient: client)

    let candidate = try await service.preview(for: .forum("Swift"))
    let metadata = try XCTUnwrap(candidate)

    XCTAssertEqual(metadata.title, "Swift吧")
    XCTAssertEqual(metadata.subtitle, "12 位关注 · 34 个主题")
  }

  func testPreviewTextAlsoBoundsUTF8ForOneHugeCombiningCharacter() {
    let source = "a" + String(repeating: "\u{0301}", count: 10_000)

    let result = TiebaCoreBrowseService.previewText(
      source,
      maximumCharacterCount: 120
    )

    XCTAssertLessThan(result.utf8.count, source.utf8.count)
    XCTAssertLessThanOrEqual(result.utf8.count, 120 * 4)
    XCTAssertLessThanOrEqual(result.count, 120)
  }

  func testThreadPreviewUsesBoundedRequestPreservesRouteAndSanitizesMetadata() async throws {
    let rawTitle = "  First\u{0000}\n\tSecond  " + String(repeating: "x", count: 200)
    let thread = makeThread(
      id: 42,
      forumName: "  Swift\n iOS\t",
      title: rawTitle,
      author: makeUser(displayName: "  Alice\u{0007}\nBob  "),
      replyCount: 42
    )
    let client = TiebaLinkPreviewClientSpy(postPage: makePostPage(thread: thread))
    let service = TiebaCoreBrowseService(linkPreviewClient: client)
    let route = TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 999)

    let candidate = try await service.preview(for: .thread(route))
    let metadata = try XCTUnwrap(candidate)

    let expectedTitle = String(
      ("First Second " + String(repeating: "x", count: 200)).prefix(120)
    )
    XCTAssertEqual(metadata.title, expectedTitle)
    XCTAssertEqual(metadata.title.count, 120)
    XCTAssertEqual(
      metadata.subtitle,
      "Swift iOS吧 · 作者 Alice Bob · 42 条回复 · 只看楼主 · 定位到回复 999"
    )
    XCTAssertFalse(
      (metadata.title + metadata.subtitle).unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
      }
    )

    let snapshot = await client.snapshot()
    XCTAssertTrue(snapshot.forumRequests.isEmpty)
    XCTAssertEqual(
      snapshot.threadRequests,
      [
        TiebaLinkPreviewThreadRequest(
          threadID: 42,
          page: 1,
          pageSize: 2,
          sort: .ascending,
          onlyThreadAuthor: true,
          location: nil,
          includeComments: false,
          commentsSortedByAgree: true,
          commentPageSize: 1
        )
      ]
    )
  }

  func testUserPreviewDoesNotIssueAnonymousForumOrThreadRequest() async throws {
    let client = TiebaLinkPreviewClientSpy()
    let service = TiebaCoreBrowseService(linkPreviewClient: client)

    let metadata = try await service.preview(for: .user(7))

    XCTAssertNil(metadata)
    let snapshot = await client.snapshot()
    XCTAssertTrue(snapshot.forumRequests.isEmpty)
    XCTAssertTrue(snapshot.threadRequests.isEmpty)
  }

  func testForumPreviewRejectsInvalidIdentityAndUnexpectedPage() async throws {
    let scenarios: [(label: String, forum: TiebaForum, currentPage: Int)] = [
      ("invalid forum id", makeForum(id: 0, name: "Swift"), 1),
      ("mismatched forum name", makeForum(name: "Objective-C"), 1),
      ("unexpected page", makeForum(name: "Swift"), 2),
    ]

    for scenario in scenarios {
      let client = TiebaLinkPreviewClientSpy(
        forumPage: makeThreadPage(
          forum: scenario.forum,
          currentPage: scenario.currentPage
        )
      )
      let service = TiebaCoreBrowseService(linkPreviewClient: client)

      let metadata = try await service.preview(for: .forum("Swift"))

      XCTAssertNil(metadata, scenario.label)
    }
  }

  func testThreadPreviewRejectsMismatchedIdentityAndUnexpectedPage() async throws {
    let scenarios: [(label: String, threadID: Int64, currentPage: Int)] = [
      ("mismatched thread id", 43, 1),
      ("unexpected page", 42, 2),
    ]

    for scenario in scenarios {
      let client = TiebaLinkPreviewClientSpy(
        postPage: makePostPage(
          thread: makeThread(id: scenario.threadID),
          currentPage: scenario.currentPage
        )
      )
      let service = TiebaCoreBrowseService(linkPreviewClient: client)

      let metadata = try await service.preview(
        for: .thread(TiebaThreadRoute(threadID: 42))
      )

      XCTAssertNil(metadata, scenario.label)
    }
  }

  func testThreadPreviewDoesNotExposeLocallyPlaceholderOrHiddenThread() async throws {
    for mode in [ContentFilterDisplayMode.placeholder, .hidden] {
      let client = TiebaLinkPreviewClientSpy(
        postPage: makePostPage(
          thread: makeThread(id: 42, title: "private marker")
        )
      )
      let repository = LinkPreviewContentFilterRepository(
        value: ContentFilterSnapshot(
          displayMode: mode,
          blockVideos: false,
          rules: [.keyword("private marker", list: .block)]
        )
      )
      let service = TiebaCoreBrowseService(
        linkPreviewClient: client,
        contentFilterRepository: repository
      )

      let metadata = try await service.preview(
        for: .thread(TiebaThreadRoute(threadID: 42))
      )

      XCTAssertNil(metadata, "Filtered content must not leak in \(mode.rawValue) mode")
    }
  }

  func testThreadPreviewDoesNotExposeServerHiddenThread() async throws {
    let client = TiebaLinkPreviewClientSpy(
      postPage: makePostPage(
        thread: makeThread(id: 42, title: "server private", isHidden: true)
      )
    )
    let service = TiebaCoreBrowseService(linkPreviewClient: client)

    let metadata = try await service.preview(
      for: .thread(TiebaThreadRoute(threadID: 42))
    )

    XCTAssertNil(metadata)
  }

  func testThreadPreviewFailsClosedWhenLocalFilterCannotBeRead() async throws {
    let client = TiebaLinkPreviewClientSpy(
      postPage: makePostPage(
        thread: makeThread(id: 42, title: "must remain generic")
      )
    )
    let service = TiebaCoreBrowseService(
      linkPreviewClient: client,
      contentFilterRepository: FailingLinkPreviewContentFilterRepository()
    )

    let metadata = try await service.preview(
      for: .thread(TiebaThreadRoute(threadID: 42))
    )

    XCTAssertNil(metadata)
  }
}

private struct TiebaLinkPreviewForumRequest: Equatable, Sendable {
  let forumName: String
  let page: Int
  let pageSize: Int
  let sort: TiebaThreadSort
  let featuredOnly: Bool
  let featuredClassificationID: Int?
}

private struct TiebaLinkPreviewThreadRequest: Equatable, Sendable {
  let threadID: Int64
  let page: Int
  let pageSize: Int
  let sort: TiebaPostSort
  let onlyThreadAuthor: Bool
  let location: TiebaPostLocation?
  let includeComments: Bool
  let commentsSortedByAgree: Bool
  let commentPageSize: Int
}

private struct TiebaLinkPreviewClientSnapshot: Sendable {
  let forumRequests: [TiebaLinkPreviewForumRequest]
  let threadRequests: [TiebaLinkPreviewThreadRequest]
}

private struct TiebaLinkPreviewUnexpectedRequest: Error, Sendable {}

private actor TiebaLinkPreviewClientSpy: TiebaLinkPreviewClient {
  private let forumPage: TiebaThreadPage?
  private let postPage: TiebaPostPage?
  private var forumRequests: [TiebaLinkPreviewForumRequest] = []
  private var threadRequests: [TiebaLinkPreviewThreadRequest] = []

  init(
    forumPage: TiebaThreadPage? = nil,
    postPage: TiebaPostPage? = nil
  ) {
    self.forumPage = forumPage
    self.postPage = postPage
  }

  func getThreads(
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: TiebaThreadSort,
    featuredOnly: Bool,
    featuredClassificationID: Int?
  ) async throws -> TiebaThreadPage {
    forumRequests.append(
      TiebaLinkPreviewForumRequest(
        forumName: forumName,
        page: page,
        pageSize: pageSize,
        sort: sort,
        featuredOnly: featuredOnly,
        featuredClassificationID: featuredClassificationID
      )
    )
    guard let forumPage else { throw TiebaLinkPreviewUnexpectedRequest() }
    return forumPage
  }

  func getPosts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeComments: Bool,
    commentsSortedByAgree: Bool,
    commentPageSize: Int
  ) async throws -> TiebaPostPage {
    threadRequests.append(
      TiebaLinkPreviewThreadRequest(
        threadID: threadID,
        page: page,
        pageSize: pageSize,
        sort: sort,
        onlyThreadAuthor: onlyThreadAuthor,
        location: location,
        includeComments: includeComments,
        commentsSortedByAgree: commentsSortedByAgree,
        commentPageSize: commentPageSize
      )
    )
    guard let postPage else { throw TiebaLinkPreviewUnexpectedRequest() }
    return postPage
  }

  func snapshot() -> TiebaLinkPreviewClientSnapshot {
    TiebaLinkPreviewClientSnapshot(
      forumRequests: forumRequests,
      threadRequests: threadRequests
    )
  }
}

private struct LinkPreviewContentFilterRepository: ContentFilterRepository {
  let value: ContentFilterSnapshot

  func snapshot() async throws -> ContentFilterSnapshot { value }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func reset() async throws {
    throw ContentFilterStoreError.unavailable
  }
}

private struct FailingLinkPreviewContentFilterRepository: ContentFilterRepository {
  func snapshot() async throws -> ContentFilterSnapshot {
    throw ContentFilterStoreError.readFailed
  }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw ContentFilterStoreError.unavailable
  }

  func delete(id: UUID) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func deleteAll(in list: ContentFilterList) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw ContentFilterStoreError.unavailable
  }

  func reset() async throws {
    throw ContentFilterStoreError.unavailable
  }
}

private func makeForum(
  id: Int64 = 1,
  name: String = "Swift",
  memberCount: Int = 0,
  threadCount: Int = 0,
  slogan: String = ""
) -> TiebaForum {
  TiebaForum(
    id: id,
    name: name,
    category: "Technology",
    subcategory: "Programming",
    memberCount: memberCount,
    threadCount: threadCount,
    postCount: 0,
    hasModerators: false,
    hasRules: false,
    slogan: slogan
  )
}

private func makeUser(displayName: String) -> TiebaUser {
  TiebaUser(
    id: 7,
    username: "alice",
    displayName: displayName,
    portrait: "",
    level: 1,
    growthLevel: 0,
    gender: .unknown,
    ipLocation: "",
    badges: [],
    isModerator: false,
    isVIP: false,
    isVerifiedCreator: false
  )
}

private func makeThread(
  id: Int64,
  forumName: String = "Swift",
  title: String = "Preview title",
  author: TiebaUser? = nil,
  replyCount: Int = 0,
  isHidden: Bool = false
) -> TiebaThread {
  TiebaThread(
    id: id,
    firstPostID: id + 1,
    forumID: 1,
    forumName: forumName,
    title: title,
    content: TiebaContent(fragments: [.text("Preview body")]),
    author: author,
    kind: .article,
    tabID: 0,
    viewCount: 0,
    replyCount: replyCount,
    shareCount: 0,
    agreeCount: 0,
    disagreeCount: 0,
    createdAt: nil,
    lastReplyAt: nil,
    isPinned: false,
    isFeatured: false,
    isShared: false,
    isHidden: isHidden,
    isLive: false
  )
}

private func makePagination(currentPage: Int) -> TiebaPagination {
  TiebaPagination(
    pageSize: 2,
    currentPage: currentPage,
    totalPages: 1,
    totalCount: 1,
    hasMore: false,
    hasPrevious: false
  )
}

private func makeThreadPage(
  forum: TiebaForum,
  currentPage: Int = 1
) -> TiebaThreadPage {
  TiebaThreadPage(
    forum: forum,
    threads: [],
    pagination: makePagination(currentPage: currentPage),
    tabs: [:]
  )
}

private func makePostPage(
  thread: TiebaThread,
  currentPage: Int = 1
) -> TiebaPostPage {
  TiebaPostPage(
    forum: makeForum(name: thread.forumName),
    thread: thread,
    posts: [],
    pagination: makePagination(currentPage: currentPage)
  )
}
