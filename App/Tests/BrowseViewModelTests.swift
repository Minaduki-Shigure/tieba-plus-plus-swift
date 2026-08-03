import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class BrowseViewModelTests: XCTestCase {
  func testForumChannelMappingPreservesServerSortMenuAndUnknownRawValue() {
    let mapped = TiebaCoreBrowseService.mapForumChannel(
      TiebaForumChannel(
        id: 81,
        name: "服务端频道",
        isDefault: true,
        sortOptions: [
          TiebaForumChannelSortOption(id: 37, title: "服务器综合排序"),
          TiebaForumChannelSortOption(id: 0, title: "按回复"),
        ]
      )
    )

    XCTAssertEqual(mapped.id, 81)
    XCTAssertEqual(mapped.name, "服务端频道")
    XCTAssertTrue(mapped.isDefault)
    XCTAssertEqual(
      mapped.sortOptions,
      [
        BrowseForumChannelSortOption(id: 37, title: "服务器综合排序"),
        BrowseForumChannelSortOption(id: 0, title: "按回复"),
      ]
    )
    XCTAssertEqual(mapped.sortOptions.first?.sort.rawValue, 37)
  }

  func testThreadMappingPreservesFeedMetadataAndSanitizesMedia() throws {
    let validImage = TiebaImage(
      thumbnailURL: try XCTUnwrap(URL(string: "https://img.example/thumb.jpg")),
      fullSizeURL: try XCTUnwrap(URL(string: "https://img.example/full.jpg")),
      originalURL: nil,
      width: 640,
      height: 480,
      originalByteCount: 0
    )
    let unsafeImage = TiebaImage(
      thumbnailURL: try XCTUnwrap(URL(string: "ftp://img.example/unsafe.jpg")),
      fullSizeURL: nil,
      originalURL: nil,
      width: 100,
      height: 100,
      originalByteCount: 0
    )
    let fallbackImageURL = try XCTUnwrap(URL(string: "https://img.example/fallback.jpg"))
    let recoverableImage = TiebaImage(
      thumbnailURL: try XCTUnwrap(URL(string: "ftp://img.example/bad-thumb.jpg")),
      fullSizeURL: fallbackImageURL,
      originalURL: nil,
      width: 320,
      height: 240,
      originalByteCount: 0
    )
    let video = TiebaVideo(
      streamURL: try XCTUnwrap(URL(string: "https://video.example/stream.mp4")),
      coverURL: try XCTUnwrap(URL(string: "https://img.example/video.jpg")),
      duration: 12,
      width: 1280,
      height: 720,
      viewCount: 30
    )
    let thread = TiebaThread(
      id: 42,
      firstPostID: 43,
      forumID: 7,
      forumName: "swift",
      title: "Rich thread",
      content: TiebaContent(fragments: [
        .text("excerpt"),
        .image(validImage),
        .image(unsafeImage),
        .image(recoverableImage),
        .video(video),
      ]),
      author: nil,
      kind: .video,
      tabID: 9,
      viewCount: 100,
      replyCount: 20,
      shareCount: 5,
      agreeCount: 11,
      disagreeCount: 4,
      createdAt: nil,
      lastReplyAt: nil,
      isPinned: true,
      isFeatured: true,
      isShared: true,
      isHidden: true,
      isLive: false
    )

    let mapped = TiebaCoreBrowseService.mapThread(thread)

    XCTAssertEqual(mapped.id, 42)
    XCTAssertEqual(mapped.firstPostID, 43)
    XCTAssertEqual(mapped.kind, .video)
    XCTAssertEqual(mapped.tabID, 9)
    XCTAssertEqual(mapped.shareCount, 5)
    XCTAssertEqual(mapped.agreeCount, 11)
    XCTAssertEqual(mapped.disagreeCount, 4)
    XCTAssertEqual(mapped.agreeScore, 7)
    XCTAssertTrue(mapped.isPinned)
    XCTAssertTrue(mapped.isFeatured)
    XCTAssertTrue(mapped.isShared)
    XCTAssertTrue(mapped.isServerHidden)
    XCTAssertFalse(mapped.isLive)
    XCTAssertEqual(
      mapped.contents.compactMap { content -> URL? in
        guard case .image(let thumbnail, _, _, _) = content else { return nil }
        return thumbnail
      },
      [
        try XCTUnwrap(URL(string: "https://img.example/thumb.jpg")),
        fallbackImageURL,
      ]
    )
    XCTAssertTrue(
      mapped.contents.contains { content in
        guard case .unsupported(let label) = content else { return false }
        return label == "图片地址不可用"
      }
    )
    XCTAssertTrue(
      mapped.contents.contains { content in
        guard case .video(_, let cover, _, _) = content else { return false }
        return cover?.absoluteString == "https://img.example/video.jpg"
      }
    )
  }

  func testSearchThreadMappingPreservesAvailableCountsAndImages() throws {
    let thumbnailURL = try XCTUnwrap(URL(string: "https://img.example/search.jpg"))
    let fallbackURL = try XCTUnwrap(URL(string: "https://img.example/fallback.jpg"))
    let result = TiebaThreadSearchResult(
      threadID: 50,
      firstPostID: 51,
      forumID: 7,
      forumName: "swift",
      title: "Search result",
      excerpt: "Excerpt",
      authorID: 9,
      authorName: "Author",
      authorPortraitURL: nil,
      replyCount: 10,
      likeCount: 8,
      shareCount: 3,
      createdAt: nil,
      images: [
        TiebaSearchImage(
          thumbnailURL: thumbnailURL,
          fullSizeURL: nil,
          width: 640,
          height: 480
        ),
        TiebaSearchImage(
          thumbnailURL: try XCTUnwrap(URL(string: "ftp://img.example/unsafe.jpg")),
          fullSizeURL: fallbackURL,
          width: 640,
          height: 480
        ),
      ]
    )

    let mapped = TiebaCoreBrowseService.mapThreadSearchResult(result)

    XCTAssertEqual(mapped.firstPostID, 51)
    XCTAssertEqual(mapped.agreeCount, 8)
    XCTAssertEqual(mapped.shareCount, 3)
    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: mapped),
      .images([thumbnailURL, fallbackURL], totalCount: 2)
    )
  }

  func testOriginThreadMappingPreservesFirstPostID() {
    let origin = TiebaOriginThread(
      id: 60,
      firstPostID: 61,
      forumID: 7,
      forumName: "swift",
      title: "Origin",
      content: TiebaContent(fragments: [.text("Excerpt")])
    )

    let mapped = TiebaCoreBrowseService.mapOriginThread(origin)

    XCTAssertEqual(mapped.id, 60)
    XCTAssertEqual(mapped.firstPostID, 61)
    XCTAssertEqual(mapped.contents, [.text("Excerpt")])
  }

  func testPostCursorSelectionRejectsHotRankingPIDs() {
    let pagePostIDs: [Int64] = [10, 20, 30]
    let returnedPostIDs: Set<Int64> = [10, 20]

    XCTAssertEqual(
      TiebaCoreBrowseService.nextPagePostID(
        from: pagePostIDs,
        returnedPostIDs: returnedPostIDs,
        sort: .descending
      ),
      10
    )
    XCTAssertEqual(
      TiebaCoreBrowseService.nextPagePostID(
        from: pagePostIDs,
        returnedPostIDs: returnedPostIDs,
        sort: .ascending
      ),
      30
    )
    XCTAssertNil(
      TiebaCoreBrowseService.nextPagePostID(
        from: pagePostIDs,
        returnedPostIDs: returnedPostIDs,
        sort: .hot
      )
    )
  }

  func testPostCursorReturnedIDsIncludeDedicatedFirstPost() {
    let returnedPostIDs = TiebaCoreBrowseService.returnedPostIDs(
      [20],
      firstPostID: 30
    )

    XCTAssertEqual(returnedPostIDs, [20, 30])
    XCTAssertEqual(
      TiebaCoreBrowseService.nextPagePostID(
        from: [10, 20, 30],
        returnedPostIDs: returnedPostIDs,
        sort: .ascending
      ),
      10
    )
    XCTAssertEqual(
      TiebaCoreBrowseService.nextPagePostID(
        from: [10, 20, 30],
        returnedPostIDs: returnedPostIDs,
        sort: .descending
      ),
      10
    )
    XCTAssertNil(
      TiebaCoreBrowseService.nextPagePostID(
        from: [10, 20, 30],
        returnedPostIDs: returnedPostIDs,
        sort: .hot
      )
    )
  }

  func testPollProgressUsesVoteTotalFallbackAndClampsInvalidRatios() throws {
    let first = BrowsePollOption(id: 0, text: "First", voteCount: 2)
    let second = BrowsePollOption(id: 1, text: "Second", voteCount: 1)
    let fallbackPoll = BrowsePoll(
      title: "Poll",
      isMultipleChoice: true,
      participantCount: 2,
      totalVoteCount: 0,
      options: [first, second]
    )

    XCTAssertEqual(fallbackPoll.progress(for: first), 2.0 / 3.0, accuracy: 0.000_001)
    XCTAssertEqual(fallbackPoll.percentage(for: first), 66)
    XCTAssertEqual(fallbackPoll.percentage(for: second), 33)

    let inconsistentPoll = BrowsePoll(
      title: "Poll",
      isMultipleChoice: false,
      participantCount: -1,
      totalVoteCount: 1,
      options: [BrowsePollOption(id: 0, text: "Too many", voteCount: 4)]
    )
    let option = try XCTUnwrap(inconsistentPoll.options.first)
    XCTAssertEqual(inconsistentPoll.progress(for: option), 1)
    XCTAssertEqual(inconsistentPoll.percentage(for: option), 100)

    let emptyTotalPoll = BrowsePoll(
      title: "Poll",
      isMultipleChoice: false,
      participantCount: 0,
      totalVoteCount: 0,
      options: [BrowsePollOption(id: 0, text: "None", voteCount: 0)]
    )
    let emptyOption = try XCTUnwrap(emptyTotalPoll.options.first)
    XCTAssertEqual(emptyTotalPoll.progress(for: emptyOption), 0)
    XCTAssertEqual(emptyTotalPoll.percentage(for: emptyOption), 0)
  }

  func testBrowseMappingPreservesReadOnlyPostAndCommentMetadata() {
    let author = TiebaUser(
      id: 7,
      username: "author",
      displayName: "Author",
      portrait: "portrait-token",
      level: 12,
      growthLevel: 0,
      gender: .unknown,
      ipLocation: " Shanghai ",
      badges: [],
      isModerator: true,
      isVIP: false,
      isVerifiedCreator: false,
      moderatorRole: .manager
    )
    let post = TiebaPost(
      id: 101,
      threadID: 100,
      floor: 2,
      author: author,
      content: TiebaContent(fragments: [.text("Post")]),
      signature: "",
      comments: [],
      commentCount: 0,
      agreeCount: 7,
      disagreeCount: 2,
      createdAt: nil,
      isThreadAuthor: true,
      isAIMeme: false,
      agreeScore: 5
    )
    let comment = TiebaComment(
      id: 102,
      threadID: 100,
      parentPostID: 101,
      floor: 2,
      author: author,
      replyToUserID: 77,
      content: TiebaContent(fragments: [
        .mention(TiebaMention(text: " @Target User ", userID: 77)),
        .text(" hello"),
      ]),
      agreeCount: 4,
      disagreeCount: 1,
      createdAt: nil,
      isThreadAuthor: true,
      agreeScore: 3,
      replyToUserName: " @Target User "
    )

    let mappedPost = TiebaCoreBrowseService.mapPost(post)
    let mappedComment = TiebaCoreBrowseService.mapComment(comment)

    XCTAssertEqual(mappedPost.authorLevel, 12)
    XCTAssertEqual(mappedPost.authorIPLocation, "Shanghai")
    XCTAssertEqual(mappedPost.moderatorRole, .manager)
    XCTAssertEqual(mappedPost.agreeScore, 5)
    XCTAssertTrue(mappedPost.isThreadAuthor)
    XCTAssertEqual(mappedComment.authorLevel, 12)
    XCTAssertEqual(mappedComment.authorIPLocation, "Shanghai")
    XCTAssertEqual(mappedComment.moderatorRole, .manager)
    XCTAssertEqual(mappedComment.agreeScore, 3)
    XCTAssertTrue(mappedComment.isThreadAuthor)
    XCTAssertEqual(mappedComment.replyToUserID, 77)
    XCTAssertEqual(mappedComment.replyToUserName, "Target User")
    XCTAssertEqual(
      mappedComment.contents,
      [.mention(name: "Target User", userID: 77), .text(" hello")]
    )
    XCTAssertEqual(mappedPost.withLocalVisibility(.hidden).moderatorRole, .manager)
    XCTAssertEqual(mappedComment.withLocalVisibility(.placeholder).moderatorRole, .manager)

    let negativeScorePost = TiebaPost(
      id: 103,
      threadID: 100,
      floor: 3,
      author: author,
      content: TiebaContent(fragments: []),
      signature: "",
      comments: [],
      commentCount: 0,
      agreeCount: 0,
      disagreeCount: 2,
      createdAt: nil,
      isThreadAuthor: false,
      isAIMeme: false,
      agreeScore: -2
    )
    XCTAssertEqual(TiebaCoreBrowseService.mapPost(negativeScorePost).agreeScore, 0)
  }

  func testPostMappingAppliesTheSameLocalFilterUsedByDedicatedFirstPost() {
    let post = TiebaPost(
      id: 109,
      threadID: 100,
      floor: 1,
      author: nil,
      content: TiebaContent(fragments: [.text("blocked first post")]),
      signature: "",
      comments: [],
      commentCount: 0,
      agreeCount: 0,
      disagreeCount: 0,
      createdAt: nil,
      isThreadAuthor: true,
      isAIMeme: false
    )
    let filter = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked", list: .block)]
    )

    XCTAssertEqual(
      TiebaCoreBrowseService.mapPost(post, applying: filter).localVisibility,
      .placeholder
    )
  }

  func testPostMappingBoundsAndValidatesInlineCommentsWithoutReordering() {
    func comment(
      id: Int64,
      threadID: Int64 = 100,
      parentPostID: Int64 = 101
    ) -> TiebaComment {
      TiebaComment(
        id: id,
        threadID: threadID,
        parentPostID: parentPostID,
        floor: 2,
        author: nil,
        replyToUserID: nil,
        content: TiebaContent(fragments: [.text("comment-\(id)")]),
        agreeCount: 0,
        disagreeCount: 0,
        createdAt: nil,
        isThreadAuthor: false
      )
    }
    let post = TiebaPost(
      id: 101,
      threadID: 100,
      floor: 3,
      author: nil,
      content: TiebaContent(fragments: [.text("parent")]),
      signature: "",
      comments: [
        comment(id: 5),
        comment(id: 3),
        comment(id: 5),
        comment(id: 0),
        comment(id: 7, threadID: 999),
        comment(id: 8, parentPostID: 999),
        comment(id: 4),
        comment(id: 2),
        comment(id: 1),
      ],
      commentCount: 2,
      agreeCount: 0,
      disagreeCount: 0,
      createdAt: nil,
      isThreadAuthor: false,
      isAIMeme: false
    )

    let mapped = TiebaCoreBrowseService.mapPost(post)

    XCTAssertEqual(mapped.inlineComments.map(\.id), [5, 3, 4, 2])
    XCTAssertEqual(mapped.inlineComments.map(\.contents), [
      [.text("comment-5")],
      [.text("comment-3")],
      [.text("comment-4")],
      [.text("comment-2")],
    ])
    XCTAssertEqual(mapped.nestedReplyCount, 4)
  }

  func testCommentPageMappingValidatesOwnershipAndFiltersParentAndReplies() throws {
    let author = TiebaUser(
      id: 7,
      username: "author",
      displayName: "Parent Author",
      portrait: "parent-portrait",
      level: 9,
      growthLevel: 0,
      gender: .unknown,
      ipLocation: " Shanghai ",
      badges: [],
      isModerator: true,
      isVIP: false,
      isVerifiedCreator: false,
      moderatorRole: .assistant
    )
    let forum = TiebaForum(
      id: 1,
      name: "swift",
      category: "Technology",
      subcategory: "Programming",
      memberCount: 0,
      threadCount: 0,
      postCount: 0,
      hasModerators: false,
      hasRules: false
    )
    let thread = TiebaThread(
      id: 100,
      firstPostID: 101,
      forumID: 1,
      forumName: "swift",
      title: "Thread",
      content: TiebaContent(fragments: []),
      author: author,
      kind: .article,
      tabID: 0,
      viewCount: 0,
      replyCount: 0,
      shareCount: 0,
      agreeCount: 0,
      disagreeCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      isPinned: false,
      isFeatured: false,
      isShared: false,
      isHidden: false,
      isLive: false
    )
    let parent = TiebaPost(
      id: 201,
      threadID: 100,
      floor: 2,
      author: author,
      content: TiebaContent(fragments: [.text("blocked parent")]),
      signature: "",
      comments: [],
      commentCount: 8,
      agreeCount: 5,
      disagreeCount: 1,
      createdAt: Date(timeIntervalSince1970: 100),
      isThreadAuthor: true,
      isAIMeme: false,
      agreeScore: 4
    )
    func comment(
      id: Int64,
      threadID: Int64 = 100,
      parentPostID: Int64 = 201,
      text: String
    ) -> TiebaComment {
      TiebaComment(
        id: id,
        threadID: threadID,
        parentPostID: parentPostID,
        floor: 2,
        author: nil,
        replyToUserID: nil,
        content: TiebaContent(fragments: [.text(text)]),
        agreeCount: 0,
        disagreeCount: 0,
        createdAt: nil,
        isThreadAuthor: false
      )
    }
    let response = TiebaCommentPage(
      forum: forum,
      thread: thread,
      parentPost: parent,
      comments: [
        comment(id: 301, text: "blocked child"),
        comment(id: 301, text: "duplicate"),
        comment(id: 0, text: "invalid"),
        comment(id: 302, threadID: 999, text: "wrong thread"),
        comment(id: 303, parentPostID: 999, text: "wrong parent"),
        comment(id: 304, text: "ordinary child"),
      ],
      pagination: TiebaPagination(
        pageSize: 20,
        currentPage: 2,
        totalPages: 4,
        totalCount: 10,
        hasMore: true,
        hasPrevious: true
      )
    )
    let filter = ContentFilterSnapshot(
      displayMode: .placeholder,
      blockVideos: false,
      rules: [.keyword("blocked", list: .block)]
    )

    let mapped = try TiebaCoreBrowseService.mapCommentPage(
      response,
      requestedThreadID: 100,
      expectedPostID: 201,
      filter: filter
    )

    XCTAssertEqual(mapped.parentPost.id, 201)
    XCTAssertEqual(mapped.parentPost.floor, 2)
    XCTAssertEqual(mapped.parentPost.authorLevel, 9)
    XCTAssertEqual(mapped.parentPost.authorIPLocation, "Shanghai")
    XCTAssertEqual(mapped.parentPost.moderatorRole, .assistant)
    XCTAssertEqual(
      mapped.parentPost.withLocalVisibility(.hidden).moderatorRole,
      .assistant
    )
    XCTAssertEqual(mapped.parentPost.agreeScore, 4)
    XCTAssertEqual(mapped.parentPost.localVisibility, .placeholder)
    XCTAssertEqual(mapped.comments.map(\.id), [301, 304])
    XCTAssertEqual(mapped.comments.map(\.localVisibility), [.placeholder, .visible])
    XCTAssertEqual(mapped.currentPage, 2)
    XCTAssertTrue(mapped.hasPrevious)
    XCTAssertTrue(mapped.hasMore)
    XCTAssertEqual(mapped.totalPages, 4)
    XCTAssertEqual(mapped.totalCount, 10)

    XCTAssertThrowsError(
      try TiebaCoreBrowseService.mapCommentPage(
        response,
        requestedThreadID: 100,
        expectedPostID: 999,
        filter: filter
      )
    )
    XCTAssertThrowsError(
      try TiebaCoreBrowseService.mapCommentPage(
        response,
        requestedThreadID: 999,
        expectedPostID: 201,
        filter: filter
      )
    )
  }

  @MainActor
  func testMentionLinksUseOnlyExactPositiveInternalUserDestinations() throws {
    let url = try XCTUnwrap(BrowseContentView.mentionURL(for: 77))

    XCTAssertEqual(url.absoluteString, "tieba-plus-plus://user/77")
    XCTAssertEqual(BrowseContentView.mentionUserID(from: url), 77)
    XCTAssertNil(BrowseContentView.mentionURL(for: 0))
    XCTAssertNil(BrowseContentView.mentionURL(for: -1))

    for invalidURL in [
      "https://tieba.baidu.com/home/main?id=77",
      "tieba-plus-plus://other/77",
      "tieba-plus-plus://reader@user/77",
      "tieba-plus-plus://user:8080/77",
      "tieba-plus-plus://user/77/88",
      "tieba-plus-plus://user/77?next=88",
      "tieba-plus-plus://user/77#profile",
      "tieba-plus-plus://user/-1",
    ] {
      XCTAssertNil(BrowseContentView.mentionUserID(from: try XCTUnwrap(URL(string: invalidURL))))
    }

    let linkedText = BrowseContentView.inlineText(
      [.mention(name: "reader", userID: 77), .text(" hello")],
      linksUserMentions: true
    )
    XCTAssertEqual(String(linkedText.characters), "@reader hello")
    XCTAssertEqual(linkedText.runs.compactMap { $0.link }, [url])
  }

  @MainActor
  func testForumInitialLoadSucceeds() async throws {
    let service = ScriptedBrowseService()
    let forum = Fixtures.forum(name: "Swift")
    let threads = [Fixtures.thread(id: 11), Fixtures.thread(id: 12)]
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: threads,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.threads, threads)
    XCTAssertEqual(viewModel.forum, forum)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(
      requests,
      [ThreadRequest(forumName: "Swift", page: 1, pageSize: 30)]
    )
  }

  @MainActor
  func testForumInitialSortOptionIsUsedForFirstRequest() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 13)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let options = ForumBrowseOptions(sort: .creationTime)
    let viewModel = ForumViewModel(
      forumName: "Swift",
      service: service,
      options: options
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.options, options)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(
      requests,
      [ThreadRequest(forumName: "Swift", page: 1, pageSize: 30, options: options)]
    )
  }

  @MainActor
  func testForumInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.failure(StubFailure(message: "forum unavailable")))
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("forum unavailable") }
    XCTAssertTrue(viewModel.threads.isEmpty)
  }

  @MainActor
  func testForumSortChangeReloadsAndRejectsStaleResponse() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.suspended(103))
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 14, title: "按发帖时间")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.reload()
    try await waitUntil { await service.threadRequestCount() == 1 }
    viewModel.setSort(.creationTime)
    try await waitUntil { viewModel.threads.first?.title == "按发帖时间" }

    let resumed = await service.resumeThreads(
      id: 103,
      returning: ThreadPageData(
        forumName: "Swift",
        threads: [Fixtures.thread(id: 13, title: "过期回复")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedThreadRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.threads.map(\.title), ["按发帖时间"])
    XCTAssertEqual(viewModel.options, ForumBrowseOptions(sort: .creationTime))
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.options),
      [ForumBrowseOptions(), ForumBrowseOptions(sort: .creationTime)]
    )
  }

  @MainActor
  func testForumFeaturedFilterIsForwarded() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 15)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.setFeaturedOnly(true)

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.options, ForumBrowseOptions(featuredOnly: true))
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.options), [ForumBrowseOptions(featuredOnly: true)])
  }

  @MainActor
  func testForumFeaturedClassificationReloadsWithServerClassID() async throws {
    let service = ScriptedBrowseService()
    let forum = Fixtures.forum(
      name: "Swift",
      classifications: [BrowseForumClassification(id: 9, name: "教程")]
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: [Fixtures.thread(id: 16)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: [Fixtures.thread(id: 17)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.first?.id == 16 }

    viewModel.setFeaturedClassificationID(9)

    try await waitUntil { viewModel.threads.first?.id == 17 }
    XCTAssertEqual(
      viewModel.options,
      ForumBrowseOptions(featuredOnly: true, featuredClassificationID: 9)
    )
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.options),
      [ForumBrowseOptions(), ForumBrowseOptions(featuredOnly: true, featuredClassificationID: 9)]
    )
  }

  @MainActor
  func testForumPaginationDeduplicatesThreads() async throws {
    let service = ScriptedBrowseService()
    let channel = BrowseForumChannel(id: 7, name: "教程", isDefault: false)
    let firstPage = [
      Fixtures.thread(id: 21, title: "first"),
      Fixtures.thread(
        id: 22,
        title: "original duplicate",
        isPinned: true,
        isFeatured: true
      ),
    ]
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: firstPage,
          currentPage: 1,
          hasMore: true,
          channels: [channel]
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [
            Fixtures.thread(id: 22, title: "replacement duplicate"),
            Fixtures.thread(id: 23, title: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.threads.map(\.id) == [21, 22, 23] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.threads[1].title, "original duplicate")
    XCTAssertTrue(viewModel.threads[1].isPinned)
    XCTAssertTrue(viewModel.threads[1].isFeatured)
    XCTAssertEqual(viewModel.channels, [channel])
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testForumPaginationStillLoadsAfterHiddenFinalThread() async throws {
    let service = ScriptedBrowseService()
    let hiddenTail = Fixtures.thread(id: 25).withLocalVisibility(.hidden)
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 24), hiddenTail],
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 26)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.threads.last?.localVisibility, .hidden)
    viewModel.loadMoreIfNeeded(current: hiddenTail)

    try await waitUntil {
      viewModel.threads.map(\.id) == [24, 25, 26] && !viewModel.isLoadingMore
    }
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testForumChannelUsesFirstServerSortAndUnspecifiedWithoutMenu() async throws {
    let service = ScriptedBrowseService()
    let unknownSortChannel = BrowseForumChannel(
      id: 70,
      name: "综合",
      isDefault: true,
      sortOptions: [
        BrowseForumChannelSortOption(id: 37, title: "服务器综合"),
        BrowseForumChannelSortOption(id: 0, title: "回复"),
      ]
    )
    let noMenuChannel = BrowseForumChannel(id: 71, name: "无排序菜单", isDefault: false)
    let forum = Fixtures.forum(name: "Swift")
    for threadID in [700, 701] {
      await service.enqueueThreads(
        .value(
          ThreadPageData(
            forum: forum,
            threads: [Fixtures.thread(id: Int64(threadID))],
            currentPage: 1,
            hasMore: false,
            channels: [unknownSortChannel, noMenuChannel]
          )
        )
      )
    }
    for threadID in [702, 703] {
      await service.enqueueForumChannelThreads(
        .value(
          ForumChannelPageData(
            threads: [Fixtures.thread(id: Int64(threadID))],
            currentPage: 1,
            hasMore: false,
            nextPageCursor: Int64(threadID)
          )
        )
      )
    }
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.first?.id == 700 }

    viewModel.setChannelID(unknownSortChannel.id)
    try await waitUntil { viewModel.threads.first?.id == 702 }
    XCTAssertEqual(viewModel.selectedChannelSort.rawValue, 37)

    viewModel.setChannelID(nil)
    try await waitUntil { viewModel.threads.first?.id == 701 }
    viewModel.setChannelID(noMenuChannel.id)
    try await waitUntil { viewModel.threads.first?.id == 703 }

    XCTAssertEqual(viewModel.selectedChannelSort, .unspecified)
    let requests = await service.forumChannelRequestSnapshot()
    XCTAssertEqual(requests.map(\.sort.rawValue), [37, -1])
  }

  @MainActor
  func testForumChannelSortMemoryIsIndependentPerChannelAndMainSort() async throws {
    let service = ScriptedBrowseService()
    let first = BrowseForumChannel(
      id: 72,
      name: "第一频道",
      isDefault: true,
      sortOptions: [
        BrowseForumChannelSortOption(id: 0, title: "回复"),
        BrowseForumChannelSortOption(id: 1, title: "发布"),
      ]
    )
    let second = BrowseForumChannel(
      id: 73,
      name: "第二频道",
      isDefault: false,
      sortOptions: [
        BrowseForumChannelSortOption(id: 1, title: "发布"),
        BrowseForumChannelSortOption(id: 0, title: "回复"),
      ]
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: Fixtures.forum(name: "Swift"),
          threads: [Fixtures.thread(id: 710)],
          currentPage: 1,
          hasMore: false,
          channels: [first, second]
        )
      )
    )
    for threadID in 711...716 {
      await service.enqueueForumChannelThreads(
        .value(
          ForumChannelPageData(
            threads: [Fixtures.thread(id: Int64(threadID))],
            currentPage: 1,
            hasMore: false,
            nextPageCursor: Int64(threadID)
          )
        )
      )
    }
    let initialOptions = ForumBrowseOptions(sort: .creationTime)
    let viewModel = ForumViewModel(
      forumName: "Swift",
      service: service,
      options: initialOptions
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.first?.id == 710 }

    viewModel.setChannelID(first.id)
    try await waitUntil { viewModel.threads.first?.id == 711 }
    viewModel.setChannelSort(.creationTime)
    try await waitUntil { viewModel.threads.first?.id == 712 }
    viewModel.setChannelID(second.id)
    try await waitUntil { viewModel.threads.first?.id == 713 }
    viewModel.setChannelSort(.replyTime)
    try await waitUntil { viewModel.threads.first?.id == 714 }
    viewModel.setChannelID(first.id)
    try await waitUntil { viewModel.threads.first?.id == 715 }
    viewModel.setChannelID(second.id)
    try await waitUntil { viewModel.threads.first?.id == 716 }

    viewModel.setSort(.replyTime)
    await drainMainActor()

    XCTAssertEqual(viewModel.selectedChannelSort, .replyTime)
    XCTAssertEqual(viewModel.options, initialOptions)
    let requests = await service.forumChannelRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.sort),
      [.replyTime, .creationTime, .creationTime, .replyTime, .creationTime, .replyTime]
    )
  }

  @MainActor
  func testForumChannelMenuChangeInvalidatesRememberedSortAndUsesNewFirstOption() async throws {
    let service = ScriptedBrowseService()
    let original = BrowseForumChannel(
      id: 74,
      name: "动态菜单",
      isDefault: true,
      sortOptions: [
        BrowseForumChannelSortOption(id: 0, title: "回复"),
        BrowseForumChannelSortOption(id: 1, title: "发布"),
      ]
    )
    let updated = BrowseForumChannel(
      id: 74,
      name: "动态菜单",
      isDefault: true,
      sortOptions: [
        BrowseForumChannelSortOption(id: 37, title: "新综合"),
        BrowseForumChannelSortOption(id: 0, title: "回复"),
      ]
    )
    let forum = Fixtures.forum(name: "Swift")
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: [Fixtures.thread(id: 720)],
          currentPage: 1,
          hasMore: false,
          channels: [original]
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: [Fixtures.thread(id: 723)],
          currentPage: 1,
          hasMore: false,
          channels: [updated]
        )
      )
    )
    for threadID in [721, 722, 724] {
      await service.enqueueForumChannelThreads(
        .value(
          ForumChannelPageData(
            threads: [Fixtures.thread(id: Int64(threadID))],
            currentPage: 1,
            hasMore: false,
            nextPageCursor: Int64(threadID)
          )
        )
      )
    }
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.first?.id == 720 }
    viewModel.setChannelID(original.id)
    try await waitUntil { viewModel.threads.first?.id == 721 }
    viewModel.setChannelSort(.creationTime)
    try await waitUntil { viewModel.threads.first?.id == 722 }

    viewModel.setChannelID(nil)
    try await waitUntil { viewModel.threads.first?.id == 723 }
    XCTAssertEqual(viewModel.channels, [updated])
    viewModel.setChannelID(updated.id)
    try await waitUntil { viewModel.threads.first?.id == 724 }

    XCTAssertEqual(viewModel.selectedChannelSort.rawValue, 37)
    let requests = await service.forumChannelRequestSnapshot()
    XCTAssertEqual(requests.map(\.sort.rawValue), [0, 1, 37])
  }

  @MainActor
  func testForumReplacingResponseFallsBackToAllTopicsWhenChannelDisappears() async throws {
    let service = ScriptedBrowseService()
    let channel = BrowseForumChannel(
      id: 75,
      name: "即将移除",
      isDefault: true,
      sortOptions: [BrowseForumChannelSortOption(id: 37, title: "综合")]
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 730)],
          currentPage: 1,
          hasMore: false,
          channels: [channel]
        )
      )
    )
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: Fixtures.forum(name: "Swift"),
          threads: [Fixtures.thread(id: 731)],
          currentPage: 1,
          hasMore: false,
          channels: []
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.first?.id == 730 }

    viewModel.setChannelID(channel.id)
    try await waitUntil { viewModel.threads.first?.id == 731 }

    XCTAssertTrue(viewModel.channels.isEmpty)
    XCTAssertNil(viewModel.selectedChannelID)
    XCTAssertEqual(viewModel.selectedChannelSort, .unspecified)
    let channelRequestCount = await service.forumChannelRequestCount()
    let threadRequestCount = await service.threadRequestCount()
    XCTAssertEqual(channelRequestCount, 0)
    XCTAssertEqual(threadRequestCount, 2)
  }

  @MainActor
  func testForumChannelSortChangeClearsCursorAndRejectsStaleResponse() async throws {
    let service = ScriptedBrowseService()
    let channel = BrowseForumChannel(
      id: 8,
      name: "问答",
      isDefault: true,
      sortOptions: [
        BrowseForumChannelSortOption(id: ForumChannelSort.replyTime.rawValue, title: "热门回复"),
        BrowseForumChannelSortOption(id: ForumChannelSort.creationTime.rawValue, title: "最新发布"),
      ]
    )
    let forum = Fixtures.forum(name: "Swift")
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: forum,
          threads: [Fixtures.thread(id: 30)],
          currentPage: 1,
          hasMore: false,
          channels: [channel]
        )
      )
    )
    await service.enqueueForumChannelThreads(
      .value(
        ForumChannelPageData(
          threads: [Fixtures.thread(id: 31), Fixtures.thread(id: 32)],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 32
        )
      )
    )
    await service.enqueueForumChannelThreads(
      .suspended(108)
    )
    await service.enqueueForumChannelThreads(
      .value(
        ForumChannelPageData(
          threads: [Fixtures.thread(id: 34)],
          currentPage: 1,
          hasMore: false,
          nextPageCursor: 34
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.threads.map(\.id) == [30] }

    XCTAssertEqual(viewModel.channels, [channel])
    viewModel.setChannelID(channel.id)
    try await waitUntil { viewModel.threads.map(\.id) == [31, 32] }
    XCTAssertEqual(viewModel.selectedChannelSort, .replyTime)

    viewModel.loadMoreIfNeeded(current: viewModel.threads[1])
    try await waitUntil { await service.forumChannelRequestCount() == 2 }

    viewModel.setChannelSort(.creationTime)
    try await waitUntil { viewModel.threads.map(\.id) == [34] }

    let resumed = await service.resumeForumChannel(
      id: 108,
      returning: ForumChannelPageData(
        threads: [Fixtures.thread(id: 33, title: "过期频道回复")],
        currentPage: 2,
        hasMore: false,
        nextPageCursor: 33
      )
    )
    XCTAssertTrue(resumed)
    await drainMainActor()

    viewModel.setSort(.creationTime)
    await drainMainActor()

    XCTAssertEqual(viewModel.selectedChannelID, channel.id)
    XCTAssertEqual(viewModel.selectedChannelSort, .creationTime)
    XCTAssertEqual(viewModel.options, ForumBrowseOptions())
    XCTAssertEqual(viewModel.threads.map(\.id), [34])
    let requests = await service.forumChannelRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        ForumChannelRequest(
          forumID: forum.id,
          forumName: "Swift",
          channel: channel,
          page: 1,
          pageSize: 30,
          sort: ForumChannelSort.replyTime,
          lastThreadID: nil
        ),
        ForumChannelRequest(
          forumID: forum.id,
          forumName: "Swift",
          channel: channel,
          page: 2,
          pageSize: 30,
          sort: ForumChannelSort.replyTime,
          lastThreadID: 32
        ),
        ForumChannelRequest(
          forumID: forum.id,
          forumName: "Swift",
          channel: channel,
          page: 1,
          pageSize: 30,
          sort: ForumChannelSort.creationTime,
          lastThreadID: nil
        ),
      ]
    )
  }

  @MainActor
  func testForumChannelStopsAfterDuplicatePageWithStalledCursor() async throws {
    let service = ScriptedBrowseService()
    let channel = BrowseForumChannel(id: 9, name: "攻略", isDefault: false)
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forum: Fixtures.forum(name: "Swift"),
          threads: [Fixtures.thread(id: 40)],
          currentPage: 1,
          hasMore: false,
          channels: [channel]
        )
      )
    )
    await service.enqueueForumChannelThreads(
      .value(
        ForumChannelPageData(
          threads: [Fixtures.thread(id: 41)],
          currentPage: 1,
          hasMore: true,
          nextPageCursor: 41
        )
      )
    )
    await service.enqueueForumChannelThreads(
      .value(
        ForumChannelPageData(
          threads: [Fixtures.thread(id: 41)],
          currentPage: 2,
          hasMore: true,
          nextPageCursor: 41
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.setChannelID(channel.id)
    try await waitUntil { viewModel.threads.map(\.id) == [41] }

    viewModel.loadMoreIfNeeded(current: viewModel.threads[0])
    try await waitUntil { await service.forumChannelRequestCount() == 2 }
    try await waitUntil { !viewModel.isLoadingMore }
    viewModel.loadMoreIfNeeded(current: viewModel.threads[0])
    await drainMainActor()

    let requestCount = await service.forumChannelRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(viewModel.threads.map(\.id), [41])
    let requests = await service.forumChannelRequestSnapshot()
    XCTAssertEqual(requests.map(\.sort), [.unspecified, .unspecified])
  }

  @MainActor
  func testForumPaginationFailureCanRetry() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.thread(id: 24)]
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueThreads(.failure(StubFailure(message: "next forum page failed")))
    let viewModel = ForumViewModel(forumName: "Swift", service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil {
      viewModel.loadMoreError == "next forum page failed" && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.threads, firstPage)
    XCTAssertEqual(viewModel.state, .loaded)

    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 25)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    viewModel.retryLoadMore()

    try await waitUntil { viewModel.threads.map(\.id) == [24, 25] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  @MainActor
  func testForumReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.suspended(101))
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 32, title: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.reload()
    try await waitUntil { await service.threadRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.threads.first?.title == "fresh" }

    let resumed = await service.resumeThreads(
      id: 101,
      returning: ThreadPageData(
        forumName: "Swift",
        threads: [Fixtures.thread(id: 31, title: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedThreadRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.threads.map(\.title), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testForumReloadIgnoresCancelledURLErrorFromStaleRequest() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueThreads(.suspended(102))
    await service.enqueueThreads(
      .value(
        ThreadPageData(
          forumName: "Swift",
          threads: [Fixtures.thread(id: 33, title: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumViewModel(forumName: "Swift", service: service)

    viewModel.reload()
    try await waitUntil { await service.threadRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.threads.first?.title == "fresh" }

    let cancelled = await service.cancelThreads(id: 102)
    XCTAssertTrue(cancelled)
    try await waitUntil { await service.completedThreadRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.threads.map(\.title), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testThreadInitialLoadSucceedsAndRefreshesThreadMetadata() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 41, title: "placeholder")
    let serverThread = Fixtures.thread(id: 41, title: "server title")
    let posts = [Fixtures.post(id: 411, threadID: 41), Fixtures.post(id: 412, threadID: 41)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: serverThread,
          posts: posts,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.thread, serverThread)
    XCTAssertEqual(viewModel.posts, posts)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests, [PostRequest(threadID: 41, page: 1, pageSize: 30)])
  }

  func testPostPageDataDefaultsToNoDedicatedFirstPost() {
    let page = PostPageData(
      thread: Fixtures.thread(id: 40),
      posts: [],
      currentPage: 1,
      hasMore: false
    )

    XCTAssertNil(page.firstPost)
  }

  @MainActor
  func testThreadSeparatesExplicitFirstPostAndRecognizesItAsAnchor() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 401, firstPostID: 40_101)
    let firstPost = Fixtures.post(id: 40_101, threadID: thread.id, floor: 1)
    let reply = Fixtures.post(id: 40_102, threadID: thread.id, floor: 2)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [reply],
          currentPage: 1,
          hasMore: false,
          firstPost: firstPost
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(firstPost.id)
    )

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertEqual(viewModel.posts, [reply])
    XCTAssertEqual(viewModel.post(withID: firstPost.id), firstPost)
    XCTAssertEqual(viewModel.scrollTargetPostID, firstPost.id)
  }

  @MainActor
  func testThreadExtractsLegacyFirstPostOnlyWithMatchingMetadata() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 402, firstPostID: 40_201)
    let firstPost = Fixtures.post(id: 40_201, threadID: thread.id, floor: 1)
    let reply = Fixtures.post(id: 40_202, threadID: thread.id, floor: 2)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [firstPost, reply],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertEqual(viewModel.posts, [reply])
  }

  @MainActor
  func testThreadDoesNotGuessLegacyFirstPostWithoutMetadata() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 403)
    let ambiguousPost = Fixtures.post(id: 40_301, threadID: thread.id, floor: 1)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [ambiguousPost],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertNil(viewModel.firstPost)
    XCTAssertEqual(viewModel.posts, [ambiguousPost])
  }

  @MainActor
  func testThreadRejectsConflictingExplicitAndLegacyFirstPosts() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 404, firstPostID: 40_401)
    let explicitFirstPost = Fixtures.post(id: 40_401, threadID: thread.id, floor: 1)
    let conflictingFirstPost = Fixtures.post(id: 40_402, threadID: thread.id, floor: 1)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [conflictingFirstPost],
          currentPage: 1,
          hasMore: false,
          firstPost: explicitFirstPost
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    guard case .failed(let message) = viewModel.state else {
      return XCTFail("Expected conflicting first-post response to fail")
    }
    XCTAssertTrue(message.contains("主题首楼"))
    XCTAssertNil(viewModel.firstPost)
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  @MainActor
  func testThreadFirstPostPreservesOnAppendUpdatesWhenPresentAndClearsOnRefresh() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 405, firstPostID: 40_501)
    let initialFirstPost = Fixtures.post(
      id: 40_501,
      threadID: thread.id,
      authorName: "initial first post",
      floor: 1
    )
    let updatedFirstPost = Fixtures.post(
      id: 40_501,
      threadID: thread.id,
      authorName: "updated first post",
      floor: 1
    )
    let firstReply = Fixtures.post(id: 40_502, threadID: thread.id, floor: 2)
    let secondReply = Fixtures.post(id: 40_503, threadID: thread.id, floor: 3)
    let thirdReply = Fixtures.post(id: 40_504, threadID: thread.id, floor: 4)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [firstReply],
          currentPage: 1,
          hasMore: true,
          totalPages: 3,
          firstPost: initialFirstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [secondReply],
          currentPage: 2,
          hasMore: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [thirdReply],
          currentPage: 3,
          hasMore: false,
          totalPages: 3,
          firstPost: updatedFirstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [firstReply],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.firstPost, initialFirstPost)

    viewModel.loadMoreIfNeeded(current: firstReply)
    try await waitUntil { viewModel.posts == [firstReply, secondReply] }
    XCTAssertEqual(viewModel.firstPost, initialFirstPost)

    viewModel.loadMoreIfNeeded(current: secondReply)
    try await waitUntil { viewModel.posts == [firstReply, secondReply, thirdReply] }
    XCTAssertEqual(viewModel.firstPost, updatedFirstPost)

    await viewModel.refresh()
    XCTAssertNil(viewModel.firstPost)
    XCTAssertEqual(viewModel.posts, [firstReply])
  }

  @MainActor
  func testThreadWithOnlyFirstPostCanLoadReplyContinuation() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 406, firstPostID: 40_601)
    let firstPost = Fixtures.post(id: 40_601, threadID: thread.id, floor: 1)
    let reply = Fixtures.post(id: 40_602, threadID: thread.id, floor: 2)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: true,
          totalPages: 2,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [reply],
          currentPage: 2,
          hasMore: false,
          totalPages: 2
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertTrue(viewModel.posts.isEmpty)

    viewModel.loadMoreIfNeeded()
    try await waitUntil { viewModel.posts == [reply] }
    XCTAssertEqual(viewModel.firstPost, firstPost)
  }

  @MainActor
  func testThreadRejectsMalformedDedicatedFirstPostFields() async throws {
    let thread = Fixtures.thread(id: 407, firstPostID: 40_701)
    let malformedFirstPosts = [
      Fixtures.post(id: 0, threadID: thread.id, floor: 1),
      Fixtures.post(id: 40_701, threadID: 999, floor: 1),
      Fixtures.post(id: 40_701, threadID: thread.id, floor: 2),
      Fixtures.post(id: 40_799, threadID: thread.id, floor: 1),
    ]

    for malformedFirstPost in malformedFirstPosts {
      let service = ScriptedBrowseService()
      await service.enqueuePosts(
        .value(
          PostPageData(
            thread: thread,
            posts: [],
            currentPage: 1,
            hasMore: false,
            firstPost: malformedFirstPost
          )
        )
      )
      let viewModel = ThreadViewModel(thread: thread, service: service)

      viewModel.loadIfNeeded()
      await viewModel.waitForCurrentLoad()

      guard case .failed(let message) = viewModel.state else {
        XCTFail("Expected malformed first-post response to fail")
        continue
      }
      XCTAssertTrue(message.contains("主题首楼"))
      XCTAssertNil(viewModel.firstPost)
      XCTAssertTrue(viewModel.posts.isEmpty)
    }
  }

  @MainActor
  func testThreadTailRejectsChangedFirstPostIdentityWithoutMutatingSnapshot() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 408, firstPostID: 40_801)
    let conflictingThread = Fixtures.thread(id: 408, firstPostID: 40_899)
    let firstPost = Fixtures.post(id: 40_801, threadID: thread.id, floor: 1)
    let conflictingFirstPost = Fixtures.post(id: 40_899, threadID: thread.id, floor: 1)
    let currentReply = Fixtures.post(id: 40_802, threadID: thread.id, floor: 2)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentReply],
          currentPage: 1,
          hasMore: true,
          totalPages: 2,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: conflictingThread,
          posts: [Fixtures.post(id: 40_803, threadID: thread.id, floor: 3)],
          currentPage: 2,
          hasMore: false,
          totalPages: 2,
          firstPost: conflictingFirstPost
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: currentReply)
    try await waitUntil { viewModel.loadMoreError != nil && !viewModel.isLoadingMore }

    XCTAssertEqual(viewModel.thread, thread)
    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertEqual(viewModel.posts, [currentReply])
    XCTAssertEqual(viewModel.currentPage, 1)
  }

  @MainActor
  func testThreadPreviousPageRejectsChangedFirstPostIdentityWithoutMutatingSnapshot() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 409, firstPostID: 40_901)
    let conflictingThread = Fixtures.thread(id: 409, firstPostID: 40_999)
    let firstPost = Fixtures.post(id: 40_901, threadID: thread.id, floor: 1)
    let currentReply = Fixtures.post(id: 40_903, threadID: thread.id, floor: 3)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentReply],
          currentPage: 2,
          hasMore: false,
          hasPrevious: true,
          totalPages: 2,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: conflictingThread,
          posts: [Fixtures.post(id: 40_902, threadID: thread.id, floor: 2)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false,
          totalPages: 2
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.loadPrevious(anchorPostID: currentReply.id)
    try await waitUntil {
      viewModel.loadPreviousError != nil && !viewModel.isLoadingPrevious
    }

    XCTAssertEqual(viewModel.thread, thread)
    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertEqual(viewModel.posts, [currentReply])
    XCTAssertEqual(viewModel.currentPage, 2)
    XCTAssertTrue(viewModel.canLoadPrevious)
  }

  @MainActor
  func testDuplicateOnlyPreviousPageDoesNotRefreshDedicatedFirstPost() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 410, firstPostID: 41_001)
    let initialFirstPost = Fixtures.post(
      id: 41_001,
      threadID: thread.id,
      authorName: "initial",
      floor: 1
    )
    let updatedFirstPost = Fixtures.post(
      id: 41_001,
      threadID: thread.id,
      authorName: "should not merge",
      floor: 1
    )
    let currentReply = Fixtures.post(id: 41_003, threadID: thread.id, floor: 3)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentReply],
          currentPage: 2,
          hasMore: false,
          hasPrevious: true,
          totalPages: 2,
          firstPost: initialFirstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentReply],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false,
          totalPages: 2,
          firstPost: updatedFirstPost
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.loadPrevious(anchorPostID: currentReply.id)
    try await waitUntil { !viewModel.isLoadingPrevious }

    XCTAssertEqual(viewModel.firstPost, initialFirstPost)
    XCTAssertEqual(viewModel.posts, [currentReply])
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertFalse(viewModel.isRestoringPrependPosition)
  }

  @MainActor
  func testThreadLinkRouteForwardsAuthorFilterAndPostAnchor() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 42, title: "server title")
    let targetPost = Fixtures.post(id: 99, threadID: 42)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [targetPost],
          currentPage: 3,
          hasMore: true
        )
      )
    )
    let route = TiebaThreadRoute(
      threadID: 42,
      onlyThreadAuthor: true,
      postID: targetPost.id
    )
    let viewModel = ThreadViewModel(
      thread: Fixtures.thread(id: 42, title: "placeholder"),
      service: service,
      options: route.options,
      initialLocation: route.postID.map { ThreadPostLocation.postID($0) }
    )

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.options, ThreadBrowseOptions(onlyThreadAuthor: true))
    XCTAssertEqual(viewModel.scrollTargetPostID, targetPost.id)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(
          threadID: 42,
          page: 1,
          pageSize: 30,
          options: ThreadBrowseOptions(onlyThreadAuthor: true),
          location: .postID(targetPost.id)
        )
      ]
    )
  }

  @MainActor
  func testThreadLinkRouteRetryPreservesPostAnchorUntilSuccessfulLoad() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 43, title: "server title")
    let targetPost = Fixtures.post(id: 199, threadID: 43)
    await service.enqueuePosts(.failure(StubFailure(message: "thread unavailable")))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [targetPost],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let location = ThreadPostLocation.postID(targetPost.id)
    let viewModel = ThreadViewModel(
      thread: Fixtures.thread(id: 43, title: "placeholder"),
      service: service,
      initialLocation: location
    )

    viewModel.loadIfNeeded()
    await viewModel.waitForCurrentLoad()
    XCTAssertEqual(viewModel.state, .failed("thread unavailable"))

    viewModel.reload()
    await viewModel.waitForCurrentLoad()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.scrollTargetPostID, targetPost.id)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(threadID: 43, page: 1, pageSize: 30, location: location),
        PostRequest(threadID: 43, page: 1, pageSize: 30, location: location),
      ]
    )
  }

  @MainActor
  func testThreadOriginContextLoadsAndSurvivesPaginationWithoutRepeat() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 42)
    let origin = Fixtures.thread(id: 900, title: "original", forumName: "Origin")
    let firstPost = Fixtures.post(id: 4_201, threadID: 42, floor: 1)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: true,
          originThread: origin,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 4_202, threadID: 42, floor: 2)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.originThread, origin)
    XCTAssertEqual(viewModel.firstPost, firstPost)

    viewModel.loadMoreIfNeeded()
    try await waitUntil { viewModel.posts.map(\.id) == [4_202] }
    XCTAssertEqual(viewModel.originThread, origin)
  }

  @MainActor
  func testThreadRefreshReplacesStaleOriginContext() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 43)
    let origin = Fixtures.thread(id: 901, title: "original", forumName: "Origin")
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: false,
          originThread: origin,
          firstPost: Fixtures.post(id: 4_301, threadID: 43, floor: 1)
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: false,
          firstPost: Fixtures.post(id: 4_302, threadID: 43, floor: 1)
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.originThread == origin }

    await viewModel.refresh()

    XCTAssertNil(viewModel.originThread)
    XCTAssertEqual(viewModel.firstPost?.id, 4_302)
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  @MainActor
  func testThreadPollLoadsAndSurvivesPaginationWithoutRepeat() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 44)
    let poll = Fixtures.poll()
    let firstPost = Fixtures.post(id: 4_401, threadID: 44, floor: 1)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: true,
          poll: poll,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 4_402, threadID: 44, floor: 2)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.poll, poll)
    XCTAssertEqual(viewModel.firstPost, firstPost)

    viewModel.loadMoreIfNeeded()
    try await waitUntil { viewModel.posts.map(\.id) == [4_402] }
    XCTAssertEqual(viewModel.poll, poll)
  }

  @MainActor
  func testThreadRefreshClearsStalePoll() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 45)
    let poll = Fixtures.poll()
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: false,
          poll: poll,
          firstPost: Fixtures.post(id: 4_501, threadID: 45, floor: 1)
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [],
          currentPage: 1,
          hasMore: false,
          firstPost: Fixtures.post(id: 4_502, threadID: 45, floor: 1)
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.poll == poll }

    await viewModel.refresh()

    XCTAssertNil(viewModel.poll)
    XCTAssertEqual(viewModel.firstPost?.id, 4_502)
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  @MainActor
  func testThreadInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueuePosts(.failure(StubFailure(message: "thread unavailable")))
    let viewModel = ThreadViewModel(thread: Fixtures.thread(id: 51), service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("thread unavailable") }
    XCTAssertTrue(viewModel.posts.isEmpty)
  }

  @MainActor
  func testThreadSortChangeReloadsAndRejectsStaleResponse() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 52)
    await service.enqueuePosts(.suspended(203))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 522, threadID: 52, authorName: "倒序结果")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.reload()
    try await waitUntil { await service.postRequestCount() == 1 }
    viewModel.setSort(.descending)
    try await waitUntil { viewModel.posts.first?.authorName == "倒序结果" }

    let resumed = await service.resumePosts(
      id: 203,
      returning: PostPageData(
        thread: thread,
        posts: [Fixtures.post(id: 521, threadID: 52, authorName: "过期结果")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedPostRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.posts.map(\.authorName), ["倒序结果"])
    XCTAssertEqual(viewModel.options, ThreadBrowseOptions(sort: .descending))
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.options),
      [ThreadBrowseOptions(), ThreadBrowseOptions(sort: .descending)]
    )
  }

  @MainActor
  func testThreadOnlyAuthorFilterAndHotSortAreForwarded() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 53)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 531, threadID: 53)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      options: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: true)
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests.map(\.options),
      [ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: true)]
    )
  }

  @MainActor
  func testThreadResumeForwardsPostIDAndRestoredOptions() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 54)
    let target = Fixtures.post(id: 542, threadID: 54)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 541, threadID: 54), target],
          currentPage: 2,
          hasMore: true,
          totalPages: 5,
          totalCount: 120
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.prepareResume(options: options, postID: target.id)
    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.currentPage, 2)
    XCTAssertEqual(viewModel.totalPages, 5)
    XCTAssertEqual(viewModel.scrollTargetPostID, target.id)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(
          threadID: 54,
          page: 1,
          pageSize: 30,
          options: options,
          location: .postID(target.id)
        )
      ]
    )
  }

  @MainActor
  func testThreadHotResumeRestoresModeWithoutUsingUnstablePostID() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 540)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 54_001, threadID: 540, floor: 0)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: true)
    let viewModel = ThreadViewModel(thread: thread, service: service)

    viewModel.prepareResume(options: options, postID: 99_999)
    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.options, options)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [PostRequest(threadID: 540, page: 1, pageSize: 30, options: options)]
    )
  }

  @MainActor
  func testThreadMissingResumePostFallsBackToOrdinaryFirstPage() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 541, firstPostID: 54_100)
    let missingPostID: Int64 = 54_199
    let firstPost = Fixtures.post(id: 54_100, threadID: 541, floor: 1)
    let locationPage = [Fixtures.post(id: 54_101, threadID: 541, floor: 2)]
    let firstPage = [Fixtures.post(id: 54_102, threadID: 541)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: locationPage,
          currentPage: 2,
          hasMore: true,
          totalPages: 5,
          firstPost: firstPost
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5,
          firstPost: firstPost
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(missingPostID)
    )

    viewModel.loadIfNeeded()

    try await waitUntil {
      let requestCount = await service.postRequestCount()
      return viewModel.state == .loaded && requestCount == 2
    }
    XCTAssertEqual(viewModel.posts, firstPage)
    XCTAssertEqual(viewModel.firstPost, firstPost)
    XCTAssertEqual(viewModel.currentPage, 1)
    XCTAssertNotNil(viewModel.positionNotice)
    XCTAssertEqual(viewModel.scrollTargetPostID, firstPage.first?.id)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(
          threadID: 541,
          page: 1,
          pageSize: 30,
          location: .postID(missingPostID)
        ),
        PostRequest(threadID: 541, page: 1, pageSize: 30),
      ]
    )
  }

  @MainActor
  func testThreadPageJumpReplacesPageAndSetsScrollTarget() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 55)
    let firstPage = [Fixtures.post(id: 551, threadID: 55)]
    let thirdPage = [Fixtures.post(id: 571, threadID: 55), Fixtures.post(id: 572, threadID: 55)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: thirdPage,
          currentPage: 3,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.jump(toPage: 3)

    try await waitUntil { viewModel.currentPage == 3 && !viewModel.isJumping }
    XCTAssertEqual(viewModel.posts, thirdPage)
    XCTAssertEqual(viewModel.scrollTargetPostID, thirdPage.first?.id)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 3])
    XCTAssertNil(requests[0].location)
    XCTAssertEqual(requests[1].location, .pageNumber)

    viewModel.jump(toPage: 6)
    let requestCount = await service.postRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(viewModel.jumpError, "请输入 1 到 5 之间的页码。")
  }

  @MainActor
  func testThreadPageJumpFailureKeepsCurrentPostsAndCanRetry() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 56)
    let firstPage = [Fixtures.post(id: 561, threadID: 56)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "jump failed")))
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.jump(toPage: 2)

    try await waitUntil { viewModel.jumpError == "jump failed" && !viewModel.isJumping }
    XCTAssertEqual(viewModel.posts, firstPage)
    XCTAssertEqual(viewModel.state, .loaded)

    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 562, threadID: 56)],
          currentPage: 2,
          hasMore: true,
          totalPages: 3
        )
      )
    )
    viewModel.retryJump()

    try await waitUntil { viewModel.currentPage == 2 && viewModel.jumpError == nil }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
    XCTAssertNil(requests[0].location)
    XCTAssertEqual(requests[1].location, .pageNumber)
    XCTAssertEqual(requests[2].location, .pageNumber)
  }

  @MainActor
  func testThreadPageJumpClearsPreviousPaginationFailure() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 561)
    let firstPage = [Fixtures.post(id: 56_101, threadID: 561)]
    let secondPage = [Fixtures.post(id: 56_102, threadID: 561)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "next page failed")))
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])
    try await waitUntil { viewModel.loadMoreError == "next page failed" }

    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: secondPage,
          currentPage: 2,
          hasMore: true,
          totalPages: 3
        )
      )
    )
    viewModel.jump(toPage: 2)

    try await waitUntil { viewModel.posts == secondPage && !viewModel.isJumping }
    XCTAssertNil(viewModel.loadMoreError)

    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 56_103, threadID: 561)],
          currentPage: 3,
          hasMore: false,
          totalPages: 3
        )
      )
    )
    viewModel.loadMoreIfNeeded(current: secondPage[0])

    try await waitUntil { viewModel.posts.map(\.id) == [56_102, 56_103] }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2, 3])
    XCTAssertEqual(requests.dropFirst().map(\.location), [.pageNumber, .pageNumber, .pageNumber])
  }

  @MainActor
  func testAscendingAnchorPrependsEarlierPageWithoutChangingTailCursor() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 58)
    let origin = Fixtures.thread(id: 5_800, title: "original", forumName: "Origin")
    let anchoredPosts = [
      Fixtures.post(id: 301, threadID: 58).withLocalVisibility(.placeholder),
      Fixtures.post(id: 302, threadID: 58),
    ]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: anchoredPosts,
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalPages: 5,
          nextPagePostID: 390
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 201, threadID: 58), anchoredPosts[0]],
          currentPage: 2,
          hasMore: true,
          hasPrevious: true,
          totalPages: 5,
          nextPagePostID: 999,
          originThread: origin
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 401, threadID: 58)],
          currentPage: 4,
          hasMore: false,
          hasPrevious: true,
          totalPages: 5
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(302)
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.consumeScrollTarget()

    viewModel.loadPrevious(anchorPostID: anchoredPosts[0].id)
    XCTAssertTrue(viewModel.isAdjustingPrependPosition)

    try await waitUntil { viewModel.posts.map(\.id) == [201, 301, 302] }
    XCTAssertEqual(viewModel.currentPage, 3)
    XCTAssertEqual(viewModel.prependRestorePostID, 301)
    XCTAssertEqual(viewModel.originThread, origin)
    XCTAssertTrue(viewModel.canLoadPrevious)
    XCTAssertTrue(viewModel.isAdjustingPrependPosition)
    viewModel.loadPrevious(anchorPostID: anchoredPosts[0].id)
    viewModel.loadMoreIfNeeded(current: anchoredPosts[1])
    await drainMainActor()
    var requestCount = await service.postRequestCount()
    XCTAssertEqual(requestCount, 2)
    viewModel.consumePrependRestoreTarget()
    XCTAssertFalse(viewModel.isAdjustingPrependPosition)

    viewModel.loadMoreIfNeeded(current: anchoredPosts[1])

    try await waitUntil { viewModel.posts.map(\.id) == [201, 301, 302, 401] }
    let requests = await service.postRequestSnapshot()
    requestCount = requests.count
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(requests.map(\.page), [1, 2, 4])
    XCTAssertEqual(requests[0].location, .postID(302))
    XCTAssertEqual(requests[1].location, .pageNumber)
    XCTAssertEqual(requests[2].location, .pageCursor(390))
  }

  @MainActor
  func testAscendingPreviousPageFailureRetriesWithoutChangingLoadedWindow() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 581)
    let currentPosts = [
      Fixtures.post(id: 201, threadID: 581),
      Fixtures.post(id: 202, threadID: 581),
    ]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: currentPosts,
          currentPage: 2,
          hasMore: false,
          hasPrevious: true,
          totalPages: 2
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "previous post page failed")))
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(202)
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious(anchorPostID: currentPosts[1].id)

    try await waitUntil {
      viewModel.loadPreviousError == "previous post page failed"
        && !viewModel.isLoadingPrevious
    }
    XCTAssertEqual(viewModel.posts, currentPosts)
    XCTAssertEqual(viewModel.currentPage, 2)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 101, threadID: 581)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false,
          totalPages: 2
        )
      )
    )

    viewModel.retryLoadPrevious()

    try await waitUntil { viewModel.posts.map(\.id) == [101, 201, 202] }
    XCTAssertNil(viewModel.loadPreviousError)
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertEqual(viewModel.prependRestorePostID, currentPosts[1].id)
    viewModel.consumePrependRestoreTarget()
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 1])
    XCTAssertEqual(requests.dropFirst().map(\.location), [.pageNumber, .pageNumber])
  }

  @MainActor
  func testAscendingPreviousPageRejectsSkippedPageBeforeMerging() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 582)
    let currentPosts = [Fixtures.post(id: 301, threadID: 582)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: currentPosts,
          currentPage: 3,
          hasMore: false,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 999, threadID: 582)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: true,
          totalPages: 99
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(301)
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious()

    try await waitUntil { !viewModel.isLoadingPrevious }
    XCTAssertEqual(viewModel.posts, currentPosts)
    XCTAssertEqual(viewModel.totalPages, 3)
    XCTAssertTrue(viewModel.canLoadPrevious)
    XCTAssertNil(viewModel.prependRestorePostID)
    XCTAssertNotNil(viewModel.loadPreviousError)
  }

  @MainActor
  func testAscendingPreviousPageRejectsCrossThreadPostBeforeMerging() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 592)
    let currentPost = Fixtures.post(id: 301, threadID: 592)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentPost],
          currentPage: 3,
          hasMore: false,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 201, threadID: 999)],
          currentPage: 2,
          hasMore: true,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious(anchorPostID: currentPost.id)

    try await waitUntil { viewModel.loadPreviousError != nil && !viewModel.isLoadingPrevious }
    XCTAssertEqual(viewModel.posts, [currentPost])
    XCTAssertEqual(viewModel.currentPage, 3)
    XCTAssertTrue(viewModel.canLoadPrevious)
    XCTAssertFalse(viewModel.isRestoringPrependPosition)
  }

  @MainActor
  func testAscendingPreviousPageStopsWhenExactPageContainsOnlyDuplicates() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 584)
    let currentPost = Fixtures.post(id: 301, threadID: 584)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentPost],
          currentPage: 3,
          hasMore: false,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentPost],
          currentPage: 2,
          hasMore: true,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious(anchorPostID: currentPost.id)

    try await waitUntil { !viewModel.isLoadingPrevious }
    XCTAssertEqual(viewModel.posts, [currentPost])
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertFalse(viewModel.isRestoringPrependPosition)
    XCTAssertNil(viewModel.loadPreviousError)
  }

  @MainActor
  func testPreviousPageWithoutRenderedAnchorStillHasExplicitRestorationCycle() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 585)
    let hiddenPost = Fixtures.post(id: 201, threadID: 585).withLocalVisibility(.hidden)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [hiddenPost],
          currentPage: 2,
          hasMore: false,
          hasPrevious: true,
          totalPages: 2
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 101, threadID: 585)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false,
          totalPages: 2
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious(anchorPostID: hiddenPost.id)

    try await waitUntil { viewModel.posts.count == 2 }
    XCTAssertNil(viewModel.prependRestorePostID)
    XCTAssertEqual(viewModel.prependRestoreSequence, 1)
    XCTAssertTrue(viewModel.isRestoringPrependPosition)
    viewModel.cancel()
    XCTAssertFalse(viewModel.isAdjustingPrependPosition)
    XCTAssertEqual(viewModel.posts.map(\.id), [101, 201])
  }

  @MainActor
  func testPreviousPageIsUnavailableOutsideAscendingSort() async throws {
    for sort in [ThreadPostSort.descending, .hot] {
      let service = ScriptedBrowseService()
      let thread = Fixtures.thread(id: sort == .descending ? 586 : 587)
      await service.enqueuePosts(
        .value(
          PostPageData(
            thread: thread,
            posts: [Fixtures.post(id: 301, threadID: thread.id)],
            currentPage: 3,
            hasMore: true,
            hasPrevious: true,
            totalPages: 5
          )
        )
      )
      let viewModel = ThreadViewModel(
        thread: thread,
        service: service,
        options: ThreadBrowseOptions(sort: sort)
      )
      viewModel.loadIfNeeded()
      try await waitUntil { viewModel.state == .loaded }

      XCTAssertFalse(viewModel.canLoadPrevious)
      viewModel.loadPrevious(anchorPostID: viewModel.posts.first?.id)
      await drainMainActor()
      let requestCount = await service.postRequestCount()
      XCTAssertEqual(requestCount, 1)
    }
  }

  @MainActor
  func testThreadDoesNotExposeHiddenAnchoredPostAsScrollTarget() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 588)
    let hiddenPost = Fixtures.post(id: 201, threadID: 588).withLocalVisibility(.hidden)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [hiddenPost],
          currentPage: 2,
          hasMore: false,
          hasPrevious: true,
          totalPages: 2
        )
      )
    )
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(hiddenPost.id)
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertNil(viewModel.scrollTargetPostID)
    XCTAssertEqual(viewModel.positionNotice, "目标楼层已按本地规则隐藏。")
    XCTAssertTrue(viewModel.canLoadPrevious)
  }

  @MainActor
  func testTailCursorResponseMustAdvanceBeforeMerging() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 589)
    let currentPost = Fixtures.post(id: 201, threadID: 589)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentPost],
          currentPage: 2,
          hasMore: true,
          totalPages: 4,
          nextPagePostID: 290
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 299, threadID: 589)],
          currentPage: 2,
          hasMore: true,
          totalPages: 4,
          nextPagePostID: 290
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 298, threadID: 589)],
          currentPage: 1,
          hasMore: true,
          totalPages: 4,
          nextPagePostID: 291
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: currentPost)

    try await waitUntil { viewModel.loadMoreError != nil && !viewModel.isLoadingMore }
    XCTAssertEqual(viewModel.posts, [currentPost])
    XCTAssertEqual(viewModel.currentPage, 2)
    viewModel.retryLoadMore()
    try await waitUntil {
      await service.postRequestCount() == 3
        && viewModel.loadMoreError != nil && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.posts, [currentPost])
    XCTAssertEqual(viewModel.currentPage, 2)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.location), [nil, .pageCursor(290), .pageCursor(290)])
  }

  @MainActor
  func testReloadInvalidatesSuspendedPreviousPageResponse() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 590)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 301, threadID: 590)],
          currentPage: 3,
          hasMore: false,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(.suspended(211))
    let replacementPost = Fixtures.post(id: 101, threadID: 590)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [replacementPost],
          currentPage: 1,
          hasMore: false,
          totalPages: 3
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious(anchorPostID: viewModel.posts.first?.id)
    try await waitUntil { await service.postRequestCount() == 2 }
    viewModel.reload()
    try await waitUntil { viewModel.posts == [replacementPost] }
    let resumed = await service.resumePosts(
      id: 211,
      returning: PostPageData(
        thread: thread,
        posts: [Fixtures.post(id: 201, threadID: 590)],
        currentPage: 2,
        hasMore: true,
        hasPrevious: true,
        totalPages: 3
      )
    )
    XCTAssertTrue(resumed)
    await drainMainActor()
    XCTAssertEqual(viewModel.posts, [replacementPost])
    XCTAssertFalse(viewModel.isAdjustingPrependPosition)
  }

  @MainActor
  func testAscendingPreviousAndTailLoadsCannotOverlap() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 583)
    let currentPost = Fixtures.post(id: 301, threadID: 583)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [currentPost],
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalPages: 5,
          nextPagePostID: 390
        )
      )
    )
    await service.enqueuePosts(.suspended(210))
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      initialLocation: .postID(currentPost.id)
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: currentPost)
    try await waitUntil { await service.postRequestCount() == 2 }
    viewModel.loadPrevious()
    await drainMainActor()

    var requestCount = await service.postRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertTrue(viewModel.isLoadingMore)
    let resumed = await service.resumePosts(
      id: 210,
      returning: PostPageData(
        thread: thread,
        posts: [Fixtures.post(id: 401, threadID: 583)],
        currentPage: 4,
        hasMore: false,
        hasPrevious: true,
        totalPages: 5
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { !viewModel.isLoadingMore }
    requestCount = await service.postRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(viewModel.posts.map(\.id), [301, 401])
    XCTAssertTrue(viewModel.canLoadPrevious)
  }

  @MainActor
  func testDescendingThreadPaginationUsesCursorAndDeduplicatesPosts() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 57)
    let firstPage = [
      Fixtures.post(id: 5_701, threadID: 57, authorName: "first"),
      Fixtures.post(id: 5_702, threadID: 57, authorName: "original duplicate"),
    ]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5,
          nextPagePostID: 5_700
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [
            Fixtures.post(id: 5_702, threadID: 57, authorName: "replacement duplicate"),
            Fixtures.post(id: 5_703, threadID: 57, authorName: "third"),
          ],
          currentPage: 4,
          hasMore: false,
          totalPages: 5
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .descending)
    let viewModel = ThreadViewModel(thread: thread, service: service, options: options)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.posts.map(\.id) == [5_701, 5_702, 5_703] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.posts[1].authorName, "original duplicate")
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(threadID: 57, page: 1, pageSize: 30, options: options),
        PostRequest(
          threadID: 57,
          page: 4,
          pageSize: 30,
          options: options,
          location: .pageCursor(5_700)
        ),
      ]
    )
  }

  @MainActor
  func testDescendingThreadPaginationFallsBackToPreviousPhysicalPageWithoutCursor() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 58)
    let firstPage = [Fixtures.post(id: 5_801, threadID: 58)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 5_802, threadID: 58)],
          currentPage: 4,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .descending)
    let viewModel = ThreadViewModel(thread: thread, service: service, options: options)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil { viewModel.posts.map(\.id) == [5_801, 5_802] }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(threadID: 58, page: 1, pageSize: 30, options: options),
        PostRequest(
          threadID: 58,
          page: 4,
          pageSize: 30,
          options: options,
          location: .pageNumber
        ),
      ]
    )
  }

  @MainActor
  func testAscendingPaginationUsesCursorAndSkipsAWholeDuplicatePage() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 59)
    let firstPage = [Fixtures.post(id: 5_901, threadID: 59)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 3,
          nextPagePostID: 5_900
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 2,
          hasMore: true,
          totalPages: 3,
          nextPagePostID: 5_910
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 5_902, threadID: 59)],
          currentPage: 3,
          hasMore: false,
          totalPages: 3
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil {
      let requestCount = await service.postRequestCount()
      return viewModel.posts.map(\.id) == [5_901, 5_902]
        && requestCount == 3 && !viewModel.isLoadingMore
    }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3])
    XCTAssertNil(requests[0].location)
    XCTAssertEqual(requests[1].location, .pageCursor(5_900))
    XCTAssertEqual(requests[2].location, .pageCursor(5_910))
  }

  @MainActor
  func testDescendingJumpWithoutCursorFallsBackFromJumpedPage() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 590)
    let firstPage = [Fixtures.post(id: 59_001, threadID: 590)]
    let jumpedPage = [Fixtures.post(id: 59_030, threadID: 590)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: jumpedPage,
          currentPage: 3,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 59_020, threadID: 590)],
          currentPage: 2,
          hasMore: false,
          totalPages: 5
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .descending)
    let viewModel = ThreadViewModel(thread: thread, service: service, options: options)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.jump(toPage: 3)
    try await waitUntil { viewModel.posts == jumpedPage && !viewModel.isJumping }
    viewModel.loadMoreIfNeeded(current: jumpedPage[0])

    try await waitUntil { viewModel.posts.map(\.id) == [59_030, 59_020] }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 3, 2])
    XCTAssertNil(requests[0].location)
    XCTAssertEqual(requests[1].location, .pageNumber)
    XCTAssertEqual(requests[2].location, .pageNumber)
  }

  @MainActor
  func testDescendingPIDResumeWithoutCursorFallsBackFromLocatedPage() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 591)
    let target = Fixtures.post(id: 59_140, threadID: 591)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [target],
          currentPage: 4,
          hasMore: true,
          totalPages: 5
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 59_130, threadID: 591)],
          currentPage: 3,
          hasMore: false,
          totalPages: 5
        )
      )
    )
    let options = ThreadBrowseOptions(sort: .descending)
    let viewModel = ThreadViewModel(
      thread: thread,
      service: service,
      options: options,
      initialLocation: .postID(target.id)
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: target)

    try await waitUntil { viewModel.posts.map(\.id) == [59_140, 59_130] }
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 3])
    XCTAssertEqual(requests[0].location, .postID(target.id))
    XCTAssertEqual(requests[1].location, .pageNumber)
  }

  @MainActor
  func testThreadPaginationDeduplicatesPosts() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 61)
    let firstPage = [
      Fixtures.post(id: 611, threadID: 61, authorName: "first"),
      Fixtures.post(id: 612, threadID: 61, authorName: "original duplicate"),
    ]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [
            Fixtures.post(id: 612, threadID: 61, authorName: "replacement duplicate"),
            Fixtures.post(id: 613, threadID: 61, authorName: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.posts.map(\.id) == [611, 612, 613] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.posts[1].authorName, "original duplicate")
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testThreadPaginationFailureRetriesSameDescendingCursorRequest() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 62)
    let firstPage = [Fixtures.post(id: 621, threadID: 62)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: firstPage,
          currentPage: 1,
          hasMore: true,
          totalPages: 5,
          nextPagePostID: 620
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "next post page failed")))
    let options = ThreadBrowseOptions(sort: .descending)
    let viewModel = ThreadViewModel(thread: thread, service: service, options: options)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil {
      viewModel.loadMoreError == "next post page failed" && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.posts, firstPage)
    XCTAssertEqual(viewModel.state, .loaded)

    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [Fixtures.post(id: 622, threadID: 62)],
          currentPage: 4,
          hasMore: false,
          totalPages: 5
        )
      )
    )
    viewModel.retryLoadMore()

    try await waitUntil { viewModel.posts.map(\.id) == [621, 622] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(threadID: 62, page: 1, pageSize: 30, options: options),
        PostRequest(
          threadID: 62,
          page: 4,
          pageSize: 30,
          options: options,
          location: .pageCursor(620)
        ),
        PostRequest(
          threadID: 62,
          page: 4,
          pageSize: 30,
          options: options,
          location: .pageCursor(620)
        ),
      ]
    )
  }

  @MainActor
  func testLatestRepliesUsesHiddenTailCursorAppendsInOrderAndResumesPagination() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 63, title: "initial")
    let updatedThread = Fixtures.thread(id: 63, title: "updated")
    let visiblePost = Fixtures.post(id: 6_301, threadID: 63)
    let hiddenTail = Fixtures.post(id: 6_302, threadID: 63)
      .withLocalVisibility(.hidden)
    let duplicateTail = Fixtures.post(
      id: hiddenTail.id,
      threadID: 63,
      authorName: "server duplicate"
    )
    let laterPost = Fixtures.post(id: 6_304, threadID: 63)
    let duplicateLaterPost = Fixtures.post(
      id: laterPost.id,
      threadID: 63,
      authorName: "later duplicate"
    )
    let earlierPost = Fixtures.post(id: 6_303, threadID: 63)
    let continuationPost = Fixtures.post(id: 6_305, threadID: 63)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: initialThread,
          posts: [visiblePost, hiddenTail],
          currentPage: 2,
          hasMore: false,
          totalPages: 2
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: updatedThread,
          posts: [duplicateTail, laterPost, duplicateLaterPost, earlierPost],
          currentPage: 3,
          hasMore: true,
          totalPages: 4,
          nextPagePostID: 6_399
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: updatedThread,
          posts: [continuationPost],
          currentPage: 4,
          hasMore: false,
          totalPages: 4
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    XCTAssertTrue(viewModel.canCheckLatestReplies)
    viewModel.checkLatestReplies()

    try await waitUntil {
      viewModel.posts.map(\.id) == [6_301, 6_302, 6_304, 6_303]
        && !viewModel.isCheckingLatestReplies
    }
    XCTAssertEqual(viewModel.thread, updatedThread)
    XCTAssertEqual(viewModel.currentPage, 3)
    XCTAssertEqual(viewModel.totalPages, 4)
    XCTAssertEqual(viewModel.posts[1].localVisibility, .hidden)
    XCTAssertNotEqual(viewModel.posts[1].authorName, "server duplicate")
    XCTAssertEqual(viewModel.posts[2].authorName, laterPost.authorName)
    XCTAssertFalse(viewModel.canCheckLatestReplies)
    var requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests,
      [
        PostRequest(threadID: 63, page: 1, pageSize: 30),
        PostRequest(
          threadID: 63,
          page: 1,
          pageSize: 15,
          location: .latestReplies(after: hiddenTail.id)
        ),
      ]
    )

    viewModel.loadMoreIfNeeded(current: earlierPost)

    try await waitUntil { viewModel.posts.last?.id == continuationPost.id }
    requests = await service.postRequestSnapshot()
    XCTAssertEqual(
      requests.last,
      PostRequest(
        threadID: 63,
        page: 4,
        pageSize: 30,
        location: .pageCursor(6_399)
      )
    )
  }

  @MainActor
  func testEmptyLatestRepliesResponsePreservesLoadedSnapshot() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 64, title: "preserved")
    let changedThread = Fixtures.thread(id: 640_000, title: "must not replace")
    let origin = Fixtures.thread(id: 6_400, title: "origin")
    let poll = Fixtures.poll()
    let post = Fixtures.post(id: 6_401, threadID: 64)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [post],
          currentPage: 2,
          hasMore: false,
          totalPages: 2,
          nextPagePostID: 6_499,
          originThread: origin,
          poll: poll
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: changedThread,
          posts: [],
          currentPage: 99,
          hasMore: true,
          totalPages: 99,
          nextPagePostID: 9_999,
          originThread: Fixtures.thread(id: 6_401, title: "changed origin"),
          firstPost: Fixtures.post(id: 640_001, threadID: changedThread.id, floor: 1)
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.checkLatestReplies()
    try await waitUntil { !viewModel.isCheckingLatestReplies }

    XCTAssertEqual(viewModel.thread, thread)
    XCTAssertEqual(viewModel.posts, [post])
    XCTAssertEqual(viewModel.currentPage, 2)
    XCTAssertEqual(viewModel.totalPages, 2)
    XCTAssertEqual(viewModel.originThread, origin)
    XCTAssertEqual(viewModel.poll, poll)
    XCTAssertTrue(viewModel.canCheckLatestReplies)
    XCTAssertNil(viewModel.latestRepliesError)
  }

  @MainActor
  func testDuplicateOnlyLatestRepliesResponsePreservesLoadedSnapshot() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 65, title: "preserved")
    let changedThread = Fixtures.thread(id: 65, title: "must not replace")
    let post = Fixtures.post(id: 6_501, threadID: 65, authorName: "original")
    let duplicate = Fixtures.post(id: post.id, threadID: 65, authorName: "duplicate")
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [post],
          currentPage: 4,
          hasMore: false,
          totalPages: 4
        )
      )
    )
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: changedThread,
          posts: [duplicate],
          currentPage: 5,
          hasMore: true,
          totalPages: 6,
          nextPagePostID: 6_599
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.checkLatestReplies()
    try await waitUntil { !viewModel.isCheckingLatestReplies }

    XCTAssertEqual(viewModel.thread, thread)
    XCTAssertEqual(viewModel.posts, [post])
    XCTAssertEqual(viewModel.currentPage, 4)
    XCTAssertEqual(viewModel.totalPages, 4)
    XCTAssertTrue(viewModel.canCheckLatestReplies)
  }

  @MainActor
  func testLatestRepliesFailurePreservesSnapshotAndRetriesSameCursor() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 66)
    let existing = Fixtures.post(id: 6_601, threadID: 66)
    let fresh = Fixtures.post(id: 6_602, threadID: 66)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [existing],
          currentPage: 1,
          hasMore: false,
          totalPages: 1
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "latest replies failed")))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [fresh],
          currentPage: 2,
          hasMore: false,
          totalPages: 2
        )
      )
    )
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.checkLatestReplies()
    try await waitUntil {
      viewModel.latestRepliesError == "latest replies failed"
        && !viewModel.isCheckingLatestReplies
    }
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    XCTAssertEqual(viewModel.posts, [existing])
    XCTAssertEqual(viewModel.currentPage, 1)

    viewModel.retryLatestReplies()
    try await waitUntil { viewModel.posts == [existing, fresh] }

    XCTAssertNil(viewModel.latestRepliesError)
    let requests = await service.postRequestSnapshot()
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[1].page, 1)
    XCTAssertEqual(requests[1].pageSize, 15)
    XCTAssertEqual(requests[1].location, .latestReplies(after: existing.id))
    XCTAssertEqual(requests[2], requests[1])
  }

  @MainActor
  func testLatestRepliesCheckRequiresAscendingExhaustedNonemptySnapshot() async throws {
    let cases: [(ThreadBrowseOptions, [BrowsePost], Bool)] = [
      (ThreadBrowseOptions(sort: .descending), [Fixtures.post(id: 6_701, threadID: 67)], false),
      (ThreadBrowseOptions(sort: .hot), [Fixtures.post(id: 6_702, threadID: 67)], false),
      (ThreadBrowseOptions(sort: .ascending), [Fixtures.post(id: 6_703, threadID: 67)], true),
      (ThreadBrowseOptions(sort: .ascending), [], false),
    ]

    for (options, posts, hasMore) in cases {
      let service = ScriptedBrowseService()
      let thread = Fixtures.thread(id: 67)
      await service.enqueuePosts(
        .value(
          PostPageData(
            thread: thread,
            posts: posts,
            currentPage: 1,
            hasMore: hasMore,
            totalPages: hasMore ? 2 : 1
          )
        )
      )
      let viewModel = ThreadViewModel(thread: thread, service: service, options: options)
      viewModel.loadIfNeeded()
      try await waitUntil { viewModel.state == .loaded }

      XCTAssertFalse(viewModel.canCheckLatestReplies)
      viewModel.checkLatestReplies()
      await drainMainActor()
      let requestCount = await service.postRequestCount()
      XCTAssertEqual(requestCount, 1)
    }
  }

  @MainActor
  func testLatestRepliesCheckBlocksOtherPaginationAndJumpLoads() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 68)
    let post = Fixtures.post(id: 6_801, threadID: 68)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [post],
          currentPage: 3,
          hasMore: false,
          hasPrevious: true,
          totalPages: 3
        )
      )
    )
    await service.enqueuePosts(.suspended(501))
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.checkLatestReplies()
    try await waitUntil {
      let requestCount = await service.postRequestCount()
      return viewModel.isCheckingLatestReplies && requestCount == 2
    }
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertFalse(viewModel.isLoadingPrevious)
    viewModel.loadPrevious(anchorPostID: post.id)
    viewModel.loadMoreIfNeeded()
    viewModel.jump(toPage: 2)
    viewModel.checkLatestReplies()
    viewModel.retryLatestReplies()
    await drainMainActor()

    let requestCount = await service.postRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(viewModel.currentPage, 3)
    XCTAssertFalse(viewModel.isJumping)
    let resumed = await service.resumePosts(
      id: 501,
      returning: PostPageData(
        thread: thread,
        posts: [],
        currentPage: 3,
        hasMore: false,
        totalPages: 3
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { !viewModel.isCheckingLatestReplies }
  }

  @MainActor
  func testReloadCancelsStaleLatestRepliesAndClearsLatestState() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 69, title: "initial")
    let freshThread = Fixtures.thread(id: 69, title: "fresh")
    let staleThread = Fixtures.thread(id: 69, title: "stale")
    let initialPost = Fixtures.post(id: 6_901, threadID: 69)
    let freshPost = Fixtures.post(id: 6_902, threadID: 69)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: initialThread,
          posts: [initialPost],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    await service.enqueuePosts(.suspended(502))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: freshThread,
          posts: [freshPost],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.checkLatestReplies()
    try await waitUntil {
      let requestCount = await service.postRequestCount()
      return viewModel.isCheckingLatestReplies && requestCount == 2
    }

    viewModel.reload()
    try await waitUntil { viewModel.thread == freshThread && viewModel.state == .loaded }
    let resumed = await service.resumePosts(
      id: 502,
      returning: PostPageData(
        thread: staleThread,
        posts: [Fixtures.post(id: 6_903, threadID: 69)],
        currentPage: 2,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedPostRequestCount() == 3 }
    await drainMainActor()

    XCTAssertEqual(viewModel.thread, freshThread)
    XCTAssertEqual(viewModel.posts, [freshPost])
    XCTAssertFalse(viewModel.isCheckingLatestReplies)
    XCTAssertNil(viewModel.latestRepliesError)
  }

  @MainActor
  func testCancelClearsLatestRepliesActivityAndError() async throws {
    let service = ScriptedBrowseService()
    let thread = Fixtures.thread(id: 70)
    let post = Fixtures.post(id: 7_001, threadID: 70)
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: [post],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    await service.enqueuePosts(.failure(StubFailure(message: "latest failed")))
    await service.enqueuePosts(.suspended(503))
    let viewModel = ThreadViewModel(thread: thread, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.checkLatestReplies()
    try await waitUntil { viewModel.latestRepliesError == "latest failed" }

    viewModel.cancel()

    XCTAssertFalse(viewModel.isCheckingLatestReplies)
    XCTAssertNil(viewModel.latestRepliesError)
    XCTAssertEqual(viewModel.posts, [post])
    viewModel.checkLatestReplies()
    try await waitUntil {
      let requestCount = await service.postRequestCount()
      return viewModel.isCheckingLatestReplies && requestCount == 3
    }

    viewModel.cancel()

    XCTAssertFalse(viewModel.isCheckingLatestReplies)
    XCTAssertNil(viewModel.latestRepliesError)
    XCTAssertEqual(viewModel.posts, [post])
    let resumed = await service.resumePosts(
      id: 503,
      returning: PostPageData(
        thread: thread,
        posts: [Fixtures.post(id: 7_002, threadID: 70)],
        currentPage: 2,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedPostRequestCount() == 3 }
    await drainMainActor()
    XCTAssertEqual(viewModel.posts, [post])
  }

  @MainActor
  func testThreadReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 71, title: "initial")
    let staleThread = Fixtures.thread(id: 71, title: "stale")
    let freshThread = Fixtures.thread(id: 71, title: "fresh")
    await service.enqueuePosts(.suspended(201))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: freshThread,
          posts: [Fixtures.post(id: 712, threadID: 71, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)

    viewModel.reload()
    try await waitUntil { await service.postRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.posts.first?.authorName == "fresh" }

    let resumed = await service.resumePosts(
      id: 201,
      returning: PostPageData(
        thread: staleThread,
        posts: [Fixtures.post(id: 711, threadID: 71, authorName: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedPostRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.thread.title, "fresh")
    XCTAssertEqual(viewModel.posts.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testThreadReloadIgnoresCancelledURLErrorFromStaleRequest() async throws {
    let service = ScriptedBrowseService()
    let initialThread = Fixtures.thread(id: 72, title: "initial")
    let freshThread = Fixtures.thread(id: 72, title: "fresh")
    await service.enqueuePosts(.suspended(202))
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: freshThread,
          posts: [Fixtures.post(id: 722, threadID: 72, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ThreadViewModel(thread: initialThread, service: service)

    viewModel.reload()
    try await waitUntil { await service.postRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.posts.first?.authorName == "fresh" }

    let cancelled = await service.cancelPosts(id: 202)
    XCTAssertTrue(cancelled)
    try await waitUntil { await service.completedPostRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.thread.title, "fresh")
    XCTAssertEqual(viewModel.posts.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
  }

  @MainActor
  func testCommentsInitialLoadSucceeds() async throws {
    let service = ScriptedBrowseService()
    let comments = [Fixtures.comment(id: 81), Fixtures.comment(id: 82)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 80,
          comments: comments,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 8, postID: 80, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.comments, comments)
    XCTAssertEqual(viewModel.parentPost?.id, 80)
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests, [CommentRequest(threadID: 8, postID: 80, page: 1)])
  }

  @MainActor
  func testCommentsCanLoadAroundMatchedNestedReply() async throws {
    let service = ScriptedBrowseService()
    let comments = [Fixtures.comment(id: 8_001), Fixtures.comment(id: 8_002)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: comments,
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(
      threadID: 8,
      postID: 800,
      aroundCommentID: 8_002,
      service: service
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.comments, comments)
    let normalRequests = await service.commentRequestSnapshot()
    let anchoredRequests = await service.aroundCommentRequestSnapshot()
    XCTAssertTrue(normalRequests.isEmpty)
    XCTAssertEqual(
      anchoredRequests,
      [CommentRequest(threadID: 8, postID: 800, page: 1, commentID: 8_002)]
    )
    XCTAssertEqual(viewModel.scrollTargetCommentID, 8_002)
    viewModel.consumeScrollTarget()
    XCTAssertNil(viewModel.scrollTargetCommentID)
  }

  @MainActor
  func testCommentsDoNotScrollWhenAnchoredReplyIsMissing() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: [Fixtures.comment(id: 8_001)],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(
      threadID: 8,
      postID: 800,
      aroundCommentID: 8_002,
      service: service
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertNil(viewModel.scrollTargetCommentID)
    XCTAssertEqual(viewModel.positionNotice, "未能在返回页面中定位目标回复。")
  }

  @MainActor
  func testCommentsDoNotExposeHiddenAnchorAsAScrollTarget() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: [Fixtures.comment(id: 8_002, localVisibility: .hidden)],
          currentPage: 2,
          hasMore: false,
          hasPrevious: true
        )
      )
    )
    let viewModel = CommentsViewModel(
      threadID: 8,
      postID: 800,
      aroundCommentID: 8_002,
      service: service
    )

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertNil(viewModel.scrollTargetCommentID)
    XCTAssertEqual(viewModel.positionNotice, "目标回复已按本地规则隐藏。")
    XCTAssertTrue(viewModel.canLoadPrevious)
    viewModel.dismissPositionNotice()
    XCTAssertNil(viewModel.positionNotice)
  }

  @MainActor
  func testAnchoredCommentsUseResolvedParentPostForSubsequentPages() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.comment(id: 8_001), Fixtures.comment(id: 8_002)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: firstPage,
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalPages: 5,
          totalCount: 5
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: [Fixtures.comment(id: 8_003)],
          currentPage: 4,
          hasMore: false,
          totalCount: 0
        )
      )
    )
    let viewModel = CommentsViewModel(
      threadID: 8,
      postID: 800,
      aroundCommentID: 8_002,
      service: service
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil { viewModel.comments.map(\.id) == [8_001, 8_002, 8_003] }
    XCTAssertEqual(viewModel.totalCount, 5)
    let anchoredRequests = await service.aroundCommentRequestSnapshot()
    let normalRequests = await service.commentRequestSnapshot()
    XCTAssertEqual(
      anchoredRequests,
      [CommentRequest(threadID: 8, postID: 800, page: 1, commentID: 8_002)]
    )
    XCTAssertEqual(
      normalRequests,
      [CommentRequest(threadID: 8, postID: 800, page: 4)]
    )
  }

  @MainActor
  func testAnchoredCommentsCanPrependEarlierPagesAndStopOnDuplicatePage() async throws {
    let service = ScriptedBrowseService()
    let anchoredPage = [Fixtures.comment(id: 301), Fixtures.comment(id: 302)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: anchoredPage,
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalPages: 4,
          totalCount: 4
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: [Fixtures.comment(id: 201), Fixtures.comment(id: 301)],
          currentPage: 2,
          hasMore: true,
          hasPrevious: true,
          totalPages: 4,
          totalCount: 4
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 8,
          postID: 800,
          comments: [Fixtures.comment(id: 201)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false,
          totalPages: 4,
          totalCount: 4
        )
      )
    )
    let viewModel = CommentsViewModel(
      threadID: 8,
      postID: 800,
      aroundCommentID: 302,
      service: service
    )
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    viewModel.consumeScrollTarget()

    viewModel.loadPrevious()

    try await waitUntil {
      viewModel.comments.map(\.id) == [201, 301, 302] && !viewModel.isLoadingPrevious
    }
    XCTAssertEqual(viewModel.prependRestoreCommentID, 301)
    XCTAssertTrue(viewModel.canLoadPrevious)
    viewModel.consumePrependRestoreTarget()

    viewModel.loadPrevious()

    try await waitUntil { !viewModel.canLoadPrevious && !viewModel.isLoadingPrevious }
    XCTAssertEqual(viewModel.comments.map(\.id), [201, 301, 302])
    let anchoredRequests = await service.aroundCommentRequestSnapshot()
    let normalRequests = await service.commentRequestSnapshot()
    XCTAssertEqual(
      anchoredRequests,
      [CommentRequest(threadID: 8, postID: 800, page: 1, commentID: 302)]
    )
    XCTAssertEqual(normalRequests.map(\.page), [2, 1])
    XCTAssertTrue(normalRequests.allSatisfy { $0.postID == 800 && $0.commentID == nil })
  }

  @MainActor
  func testCommentsRejectMismatchedParentWithoutMutatingLoadedPage() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.comment(id: 101)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: firstPage,
          currentPage: 1,
          hasMore: true,
          totalCount: 2
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 999,
          comments: [Fixtures.comment(id: 102)],
          currentPage: 2,
          hasMore: false,
          totalCount: 2
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil { viewModel.loadMoreError != nil && !viewModel.isLoadingMore }
    XCTAssertEqual(viewModel.parentPost?.id, 100)
    XCTAssertEqual(viewModel.comments, firstPage)
    XCTAssertEqual(viewModel.totalCount, 2)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testCommentsFirstPageDropsInvalidAndDuplicateIDsInServerOrder() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [
            Fixtures.comment(id: 2, authorName: "first"),
            Fixtures.comment(id: 0, authorName: "invalid"),
            Fixtures.comment(id: 2, authorName: "duplicate"),
            Fixtures.comment(id: 1, authorName: "second"),
          ],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.comments.map(\.id), [2, 1])
    XCTAssertEqual(viewModel.comments.first?.authorName, "first")
  }

  @MainActor
  func testCommentsInitialLoadReportsError() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.failure(StubFailure(message: "comments unavailable")))
    let viewModel = CommentsViewModel(threadID: 9, postID: 90, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .failed("comments unavailable") }
    XCTAssertTrue(viewModel.comments.isEmpty)
  }

  @MainActor
  func testCommentsPaginationDeduplicatesReplies() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [
      Fixtures.comment(id: 101, authorName: "first"),
      Fixtures.comment(id: 102, authorName: "original duplicate"),
    ]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [
            Fixtures.comment(id: 102, authorName: "replacement duplicate"),
            Fixtures.comment(id: 103, authorName: "third"),
          ],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil {
      viewModel.comments.map(\.id) == [101, 102, 103] && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.comments[1].authorName, "original duplicate")
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testCommentsRejectStalledPreviousPageBeforeMergingNewIDs() async throws {
    let service = ScriptedBrowseService()
    let currentPage = [Fixtures.comment(id: 301), Fixtures.comment(id: 302)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: currentPage,
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalCount: 4
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [Fixtures.comment(id: 999), Fixtures.comment(id: 301)],
          currentPage: 3,
          hasMore: true,
          hasPrevious: true,
          totalCount: 99
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious()

    try await waitUntil { !viewModel.isLoadingPrevious }
    XCTAssertEqual(viewModel.comments, currentPage)
    XCTAssertEqual(viewModel.totalCount, 4)
    XCTAssertNil(viewModel.prependRestoreCommentID)
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertNil(viewModel.loadPreviousError)
  }

  @MainActor
  func testCommentsRejectStalledNextPageBeforeMergingNewIDs() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.comment(id: 101), Fixtures.comment(id: 102)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: firstPage,
          currentPage: 1,
          hasMore: true,
          totalCount: 3
        )
      )
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [Fixtures.comment(id: 102), Fixtures.comment(id: 999)],
          currentPage: 0,
          hasMore: true,
          totalCount: 99
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[1])

    try await waitUntil { !viewModel.isLoadingMore }
    XCTAssertEqual(viewModel.comments, firstPage)
    XCTAssertEqual(viewModel.totalCount, 3)
    XCTAssertNil(viewModel.loadMoreError)
    viewModel.loadMoreIfNeeded(current: firstPage[1])
    await drainMainActor()
    let requestCount = await service.commentRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  @MainActor
  func testCommentsPaginationFailureCanRetry() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.comment(id: 104)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 103,
          comments: firstPage,
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueueComments(.failure(StubFailure(message: "next comment page failed")))
    let viewModel = CommentsViewModel(threadID: 10, postID: 103, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: firstPage[0])

    try await waitUntil {
      viewModel.loadMoreError == "next comment page failed" && !viewModel.isLoadingMore
    }
    XCTAssertEqual(viewModel.comments, firstPage)
    XCTAssertEqual(viewModel.state, .loaded)

    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 103,
          comments: [Fixtures.comment(id: 105)],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    viewModel.retryLoadMore()

    try await waitUntil { viewModel.comments.map(\.id) == [104, 105] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  @MainActor
  func testCommentsPreviousPageFailureCanRetryWithoutChangingCurrentItems() async throws {
    let service = ScriptedBrowseService()
    let currentPage = [Fixtures.comment(id: 201), Fixtures.comment(id: 202)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: currentPage,
          currentPage: 2,
          hasMore: false,
          hasPrevious: true
        )
      )
    )
    await service.enqueueComments(.failure(StubFailure(message: "previous page failed")))
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    viewModel.loadPrevious()

    try await waitUntil {
      viewModel.loadPreviousError == "previous page failed" && !viewModel.isLoadingPrevious
    }
    XCTAssertEqual(viewModel.comments, currentPage)
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [Fixtures.comment(id: 101)],
          currentPage: 1,
          hasMore: true,
          hasPrevious: false
        )
      )
    )

    viewModel.retryLoadPrevious()

    try await waitUntil { viewModel.comments.map(\.id) == [101, 201, 202] }
    XCTAssertNil(viewModel.loadPreviousError)
    XCTAssertFalse(viewModel.canLoadPrevious)
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 1])
  }

  @MainActor
  func testCommentsRefreshPreservesSnapshotOnFailureAndAtomicallyReplacesOnSuccess()
    async throws
  {
    let service = ScriptedBrowseService()
    let originalParent = Fixtures.commentParentPost(
      id: 100,
      threadID: 10,
      authorName: "original parent"
    )
    let freshParent = Fixtures.commentParentPost(
      id: 100,
      threadID: 10,
      authorName: "fresh parent"
    )
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [Fixtures.comment(id: 201, authorName: "original")],
          currentPage: 1,
          hasMore: false,
          totalCount: 5,
          parentPost: originalParent
        )
      )
    )
    await service.enqueueComments(.failure(StubFailure(message: "refresh failed")))
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    await viewModel.refresh()

    XCTAssertEqual(viewModel.parentPost?.authorName, "original parent")
    XCTAssertEqual(viewModel.comments.map(\.authorName), ["original"])
    XCTAssertEqual(viewModel.totalCount, 5)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    XCTAssertEqual(viewModel.state, .loaded)
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: [Fixtures.comment(id: 202, authorName: "fresh")],
          currentPage: 1,
          hasMore: false,
          totalCount: 1,
          parentPost: freshParent
        )
      )
    )

    await viewModel.refresh()

    XCTAssertEqual(viewModel.parentPost?.authorName, "fresh parent")
    XCTAssertEqual(viewModel.comments.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.totalCount, 1)
    XCTAssertNil(viewModel.refreshError)
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testCommentsRefreshBlocksPaginationUntilItsSnapshotCommits() async throws {
    let service = ScriptedBrowseService()
    let oldComments = [Fixtures.comment(id: 201), Fixtures.comment(id: 202)]
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 10,
          postID: 100,
          comments: oldComments,
          currentPage: 2,
          hasMore: true,
          hasPrevious: true,
          totalCount: 4
        )
      )
    )
    await service.enqueueComments(.suspended(303))
    let viewModel = CommentsViewModel(threadID: 10, postID: 100, service: service)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }

    let refreshTask = Task { await viewModel.refresh() }
    try await waitUntil {
      let requestCount = await service.commentRequestCount()
      return viewModel.isRefreshing && requestCount == 2
    }
    viewModel.loadMoreIfNeeded(current: oldComments[1])
    viewModel.loadPrevious()
    await drainMainActor()

    var requestCount = await service.commentRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertTrue(viewModel.isRefreshing)
    let resumed = await service.resumeComments(
      id: 303,
      returning: Fixtures.commentPage(
        threadID: 10,
        postID: 100,
        comments: [Fixtures.comment(id: 101, authorName: "fresh")],
        currentPage: 1,
        hasMore: false,
        totalCount: 1
      )
    )
    XCTAssertTrue(resumed)
    await refreshTask.value

    XCTAssertEqual(viewModel.comments.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.totalCount, 1)
    XCTAssertFalse(viewModel.isRefreshing)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertFalse(viewModel.isLoadingPrevious)
    requestCount = await service.commentRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  @MainActor
  func testCommentsReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.suspended(301))
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 9,
          postID: 91,
          comments: [Fixtures.comment(id: 92, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 9, postID: 91, service: service)

    viewModel.reload()
    try await waitUntil { await service.commentRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.comments.first?.authorName == "fresh" }

    let resumed = await service.resumeComments(
      id: 301,
      returning: Fixtures.commentPage(
        threadID: 9,
        postID: 91,
        comments: [Fixtures.comment(id: 91, authorName: "stale")],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    try await waitUntil { await service.completedCommentRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.comments.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  @MainActor
  func testCommentsReloadIgnoresCancelledURLErrorFromStaleRequest() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.suspended(302))
    await service.enqueueComments(
      .value(
        Fixtures.commentPage(
          threadID: 9,
          postID: 93,
          comments: [Fixtures.comment(id: 94, authorName: "fresh")],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = CommentsViewModel(threadID: 9, postID: 93, service: service)

    viewModel.reload()
    try await waitUntil { await service.commentRequestCount() == 1 }
    viewModel.reload()
    try await waitUntil { viewModel.comments.first?.authorName == "fresh" }

    let cancelled = await service.cancelComments(id: 302)
    XCTAssertTrue(cancelled)
    try await waitUntil { await service.completedCommentRequestCount() == 2 }
    await drainMainActor()

    XCTAssertEqual(viewModel.comments.map(\.authorName), ["fresh"])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
  }
}

private struct ThreadRequest: Equatable, Sendable {
  let forumName: String
  let page: Int
  let pageSize: Int
  let options: ForumBrowseOptions

  init(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions = ForumBrowseOptions()
  ) {
    self.forumName = forumName
    self.page = page
    self.pageSize = pageSize
    self.options = options
  }
}

private struct ForumChannelRequest: Equatable, Sendable {
  let forumID: Int64
  let forumName: String
  let channel: BrowseForumChannel
  let page: Int
  let pageSize: Int
  let sort: ForumChannelSort
  let lastThreadID: Int64?
}

private struct PostRequest: Equatable, Sendable {
  let threadID: Int64
  let page: Int
  let pageSize: Int
  let options: ThreadBrowseOptions
  let location: ThreadPostLocation?

  init(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions = ThreadBrowseOptions(),
    location: ThreadPostLocation? = nil
  ) {
    self.threadID = threadID
    self.page = page
    self.pageSize = pageSize
    self.options = options
    self.location = location
  }
}

private struct CommentRequest: Equatable, Sendable {
  let threadID: Int64
  let postID: Int64
  let page: Int
  let commentID: Int64?

  init(
    threadID: Int64,
    postID: Int64,
    page: Int,
    commentID: Int64? = nil
  ) {
    self.threadID = threadID
    self.postID = postID
    self.page = page
    self.commentID = commentID
  }
}

private struct StubFailure: LocalizedError, Equatable, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private enum Stub<Value: Sendable>: Sendable {
  case value(Value)
  case failure(StubFailure)
  case suspended(Int)
}

private actor ScriptedBrowseService: BrowseService {
  private var threadStubs: [Stub<ThreadPageData>] = []
  private var forumChannelStubs: [Stub<ForumChannelPageData>] = []
  private var postStubs: [Stub<PostPageData>] = []
  private var commentStubs: [Stub<CommentPageData>] = []

  private var threadRequests: [ThreadRequest] = []
  private var forumChannelRequests: [ForumChannelRequest] = []
  private var postRequests: [PostRequest] = []
  private var commentRequests: [CommentRequest] = []
  private var aroundCommentRequests: [CommentRequest] = []

  private var completedThreadRequests = 0
  private var completedPostRequests = 0
  private var completedCommentRequests = 0

  private var pendingThreads: [Int: CheckedContinuation<ThreadPageData, any Error>] = [:]
  private var pendingForumChannels: [
    Int: CheckedContinuation<ForumChannelPageData, any Error>
  ] = [:]
  private var pendingPosts: [Int: CheckedContinuation<PostPageData, any Error>] = [:]
  private var pendingComments: [Int: CheckedContinuation<CommentPageData, any Error>] = [:]

  func enqueueThreads(_ stub: Stub<ThreadPageData>) {
    threadStubs.append(stub)
  }

  func enqueueForumChannelThreads(_ stub: Stub<ForumChannelPageData>) {
    forumChannelStubs.append(stub)
  }

  func enqueuePosts(_ stub: Stub<PostPageData>) {
    postStubs.append(stub)
  }

  func enqueueComments(_ stub: Stub<CommentPageData>) {
    commentStubs.append(stub)
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    threadRequests.append(
      ThreadRequest(forumName: forumName, page: page, pageSize: pageSize, options: options)
    )
    defer { completedThreadRequests += 1 }
    guard !threadStubs.isEmpty else {
      throw StubFailure(message: "Unexpected threads request")
    }

    switch threadStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingThreads[identifier] = continuation
      }
    }
  }

  func forumChannelThreads(
    forumID: Int64,
    forumName: String,
    channel: BrowseForumChannel,
    page: Int,
    pageSize: Int,
    sort: ForumChannelSort,
    lastThreadID: Int64?
  ) async throws -> ForumChannelPageData {
    forumChannelRequests.append(
      ForumChannelRequest(
        forumID: forumID,
        forumName: forumName,
        channel: channel,
        page: page,
        pageSize: pageSize,
        sort: sort,
        lastThreadID: lastThreadID
      )
    )
    guard !forumChannelStubs.isEmpty else {
      throw StubFailure(message: "Unexpected forum channel request")
    }

    switch forumChannelStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingForumChannels[identifier] = continuation
      }
    }
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    postRequests.append(
      PostRequest(
        threadID: threadID,
        page: page,
        pageSize: pageSize,
        options: options,
        location: location
      )
    )
    defer { completedPostRequests += 1 }
    guard !postStubs.isEmpty else {
      throw StubFailure(message: "Unexpected posts request")
    }

    switch postStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingPosts[identifier] = continuation
      }
    }
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    commentRequests.append(CommentRequest(threadID: threadID, postID: postID, page: page))
    defer { completedCommentRequests += 1 }
    guard !commentStubs.isEmpty else {
      throw StubFailure(message: "Unexpected comments request")
    }

    switch commentStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingComments[identifier] = continuation
      }
    }
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    aroundCommentRequests.append(
      CommentRequest(
        threadID: threadID,
        postID: postID,
        page: page,
        commentID: commentID
      )
    )
    defer { completedCommentRequests += 1 }
    guard !commentStubs.isEmpty else {
      throw StubFailure(message: "Unexpected comments request")
    }

    switch commentStubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pendingComments[identifier] = continuation
      }
    }
  }

  func resumeThreads(id: Int, returning value: ThreadPageData) -> Bool {
    guard let continuation = pendingThreads.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func cancelThreads(id: Int) -> Bool {
    guard let continuation = pendingThreads.removeValue(forKey: id) else { return false }
    continuation.resume(throwing: URLError(.cancelled))
    return true
  }

  func resumeForumChannel(id: Int, returning value: ForumChannelPageData) -> Bool {
    guard let continuation = pendingForumChannels.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func resumePosts(id: Int, returning value: PostPageData) -> Bool {
    guard let continuation = pendingPosts.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func cancelPosts(id: Int) -> Bool {
    guard let continuation = pendingPosts.removeValue(forKey: id) else { return false }
    continuation.resume(throwing: URLError(.cancelled))
    return true
  }

  func resumeComments(id: Int, returning value: CommentPageData) -> Bool {
    guard let continuation = pendingComments.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }

  func cancelComments(id: Int) -> Bool {
    guard let continuation = pendingComments.removeValue(forKey: id) else { return false }
    continuation.resume(throwing: URLError(.cancelled))
    return true
  }

  func threadRequestSnapshot() -> [ThreadRequest] { threadRequests }
  func forumChannelRequestSnapshot() -> [ForumChannelRequest] { forumChannelRequests }
  func postRequestSnapshot() -> [PostRequest] { postRequests }
  func commentRequestSnapshot() -> [CommentRequest] { commentRequests }
  func aroundCommentRequestSnapshot() -> [CommentRequest] { aroundCommentRequests }

  func threadRequestCount() -> Int { threadRequests.count }
  func forumChannelRequestCount() -> Int { forumChannelRequests.count }
  func postRequestCount() -> Int { postRequests.count }
  func commentRequestCount() -> Int { commentRequests.count }

  func completedThreadRequestCount() -> Int { completedThreadRequests }
  func completedPostRequestCount() -> Int { completedPostRequests }
  func completedCommentRequestCount() -> Int { completedCommentRequests }
}

private enum Fixtures {
  static func poll() -> BrowsePoll {
    BrowsePoll(
      title: "Favorite language?",
      isMultipleChoice: false,
      participantCount: 10,
      totalVoteCount: 10,
      options: [
        BrowsePollOption(id: 0, text: "Swift", voteCount: 8),
        BrowsePollOption(id: 1, text: "Objective-C", voteCount: 2),
      ]
    )
  }

  static func forum(
    name: String,
    classifications: [BrowseForumClassification] = []
  ) -> BrowseForum {
    BrowseForum(
      id: 100,
      name: name,
      category: "科技",
      subcategory: "编程",
      memberCount: 1_000,
      threadCount: 200,
      postCount: 3_000,
      avatarURL: URL(string: "https://example.com/forum.png"),
      slogan: "Swift forum",
      hasModerators: true,
      hasRules: true,
      featuredClassifications: classifications
    )
  }

  static func thread(
    id: Int64,
    title: String? = nil,
    forumName: String = "Swift",
    firstPostID: Int64 = 0,
    isPinned: Bool = false,
    isFeatured: Bool = false
  ) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 100,
      forumName: forumName,
      title: title ?? "thread-\(id)",
      excerpt: "excerpt-\(id)",
      authorName: "author-\(id)",
      replyCount: 3,
      viewCount: 10,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastReplyAt: Date(timeIntervalSince1970: 1_700_000_100),
      contents: [.text("thread content")],
      firstPostID: firstPostID,
      isPinned: isPinned,
      isFeatured: isFeatured
    )
  }

  static func post(
    id: Int64,
    threadID: Int64,
    authorName: String? = nil,
    floor: Int? = nil
  ) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor ?? Int(id % 100),
      authorID: id + 1_000,
      authorName: authorName ?? "post-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_200),
      nestedReplyCount: 2,
      isThreadAuthor: false,
      contents: [.text("post content")]
    )
  }

  static func comment(
    id: Int64,
    authorName: String? = nil,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: id + 2_000,
      authorName: authorName ?? "comment-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_300),
      contents: [.text("comment content")],
      localVisibility: localVisibility
    )
  }

  static func commentParentPost(
    id: Int64,
    threadID: Int64,
    authorName: String? = nil,
    floor: Int = 2,
    localVisibility: LocalContentVisibility = .visible
  ) -> CommentParentPostContext {
    CommentParentPostContext(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: id + 1_000,
      authorName: authorName ?? "parent-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/parent-\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_200),
      isThreadAuthor: false,
      contents: [.text("parent content")],
      localVisibility: localVisibility
    )
  }

  static func commentPage(
    threadID: Int64,
    postID: Int64,
    comments: [BrowseComment],
    currentPage: Int,
    hasMore: Bool,
    hasPrevious: Bool = false,
    totalPages: Int = 0,
    totalCount: Int = 0,
    parentPost: CommentParentPostContext? = nil
  ) -> CommentPageData {
    CommentPageData(
      parentPost: parentPost ?? commentParentPost(id: postID, threadID: threadID),
      comments: comments,
      currentPage: currentPage,
      hasMore: hasMore,
      hasPrevious: hasPrevious,
      totalPages: totalPages,
      totalCount: totalCount
    )
  }
}

private struct WaitTimeout: Error {}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw WaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func drainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
