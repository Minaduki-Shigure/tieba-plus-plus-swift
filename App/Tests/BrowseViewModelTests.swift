import Foundation
import XCTest

@testable import TiebaPlusPlus

final class BrowseViewModelTests: XCTestCase {
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
    let firstPage = [
      Fixtures.thread(id: 21, title: "first"),
      Fixtures.thread(id: 22, title: "original duplicate"),
    ]
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
    let requests = await service.threadRequestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
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
    let thread = Fixtures.thread(id: 541)
    let missingPostID: Int64 = 54_199
    let locationPage = [Fixtures.post(id: 54_101, threadID: 541)]
    let firstPage = [Fixtures.post(id: 54_102, threadID: 541)]
    await service.enqueuePosts(
      .value(
        PostPageData(
          thread: thread,
          posts: locationPage,
          currentPage: 2,
          hasMore: true,
          totalPages: 5
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
          totalPages: 5
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
    XCTAssertEqual(viewModel.currentPage, 1)
    XCTAssertNotNil(viewModel.positionNotice)
    XCTAssertNotEqual(viewModel.scrollTargetPostID, missingPostID)
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
      .value(CommentPageData(comments: comments, currentPage: 1, hasMore: false))
    )
    let viewModel = CommentsViewModel(threadID: 8, postID: 80, service: service)

    viewModel.loadIfNeeded()

    try await waitUntil { viewModel.state == .loaded }
    XCTAssertEqual(viewModel.comments, comments)
    let requests = await service.commentRequestSnapshot()
    XCTAssertEqual(requests, [CommentRequest(threadID: 8, postID: 80, page: 1)])
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
      .value(CommentPageData(comments: firstPage, currentPage: 1, hasMore: true))
    )
    await service.enqueueComments(
      .value(
        CommentPageData(
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
  func testCommentsPaginationFailureCanRetry() async throws {
    let service = ScriptedBrowseService()
    let firstPage = [Fixtures.comment(id: 104)]
    await service.enqueueComments(
      .value(CommentPageData(comments: firstPage, currentPage: 1, hasMore: true))
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
        CommentPageData(
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
  func testCommentsReloadDoesNotAllowCancelledResponseToOverwriteFreshData() async throws {
    let service = ScriptedBrowseService()
    await service.enqueueComments(.suspended(301))
    await service.enqueueComments(
      .value(
        CommentPageData(
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
      returning: CommentPageData(
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
        CommentPageData(
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
  private var postStubs: [Stub<PostPageData>] = []
  private var commentStubs: [Stub<CommentPageData>] = []

  private var threadRequests: [ThreadRequest] = []
  private var postRequests: [PostRequest] = []
  private var commentRequests: [CommentRequest] = []

  private var completedThreadRequests = 0
  private var completedPostRequests = 0
  private var completedCommentRequests = 0

  private var pendingThreads: [Int: CheckedContinuation<ThreadPageData, any Error>] = [:]
  private var pendingPosts: [Int: CheckedContinuation<PostPageData, any Error>] = [:]
  private var pendingComments: [Int: CheckedContinuation<CommentPageData, any Error>] = [:]

  func enqueueThreads(_ stub: Stub<ThreadPageData>) {
    threadStubs.append(stub)
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
  func postRequestSnapshot() -> [PostRequest] { postRequests }
  func commentRequestSnapshot() -> [CommentRequest] { commentRequests }

  func threadRequestCount() -> Int { threadRequests.count }
  func postRequestCount() -> Int { postRequests.count }
  func commentRequestCount() -> Int { commentRequests.count }

  func completedThreadRequestCount() -> Int { completedThreadRequests }
  func completedPostRequestCount() -> Int { completedPostRequests }
  func completedCommentRequestCount() -> Int { completedCommentRequests }
}

private enum Fixtures {
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
    forumName: String = "Swift"
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
      contents: [.text("thread content")]
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

  static func comment(id: Int64, authorName: String? = nil) -> BrowseComment {
    BrowseComment(
      id: id,
      authorID: id + 2_000,
      authorName: authorName ?? "comment-author-\(id)",
      authorPortraitURL: URL(string: "https://example.com/avatar/\(id).png"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_300),
      contents: [.text("comment content")]
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
