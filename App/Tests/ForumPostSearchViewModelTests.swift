import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ForumPostSearchViewModelTests: XCTestCase {
  func testCoreMapperKeepsThreadAndImmediateCommentContextsSeparate() throws {
    let mainPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 100,
      title: "Opening topic",
      excerpt: "Opening content",
      authorID: 1,
      authorName: "topic author",
      authorUsername: "topic-account",
      authorPortraitURL: nil,
      replyCount: 89,
      likeCount: 12,
      shareCount: 3
    )
    let parentPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 202,
      title: "Parent floor",
      excerpt: "Parent content",
      authorID: 2,
      authorName: "parent author",
      authorUsername: "parent-account",
      authorPortraitURL: nil
    )
    let coreResult = TiebaThreadSearchResult(
      threadID: 42,
      firstPostID: 202,
      forumID: 7,
      forumName: "swift",
      title: "Nested match",
      excerpt: "Matched comment",
      authorID: 3,
      authorName: "matched author",
      authorUsername: "matched-account",
      authorPortraitURL: URL(string: "https://himg.bdimg.com/avatar.png"),
      replyCount: 8,
      likeCount: 4,
      shareCount: 2,
      createdAt: Date(timeIntervalSince1970: 100),
      images: [],
      target: .comment(postID: 202, commentID: 301),
      mainPost: mainPost,
      postInfo: parentPost
    )

    let mapped = TiebaCoreBrowseService.mapForumPostSearchResult(coreResult)

    XCTAssertEqual(mapped.id, "42:comment:202:301")
    XCTAssertEqual(mapped.target, .comment(postID: 202, commentID: 301))
    XCTAssertEqual(mapped.thread.title, "Opening topic")
    XCTAssertEqual(mapped.thread.excerpt, "Opening content")
    XCTAssertEqual(mapped.thread.authorName, "topic author")
    XCTAssertEqual(mapped.thread.authorUsername, "topic-account")
    XCTAssertEqual(mapped.thread.authorID, 1)
    XCTAssertEqual(mapped.thread.replyCount, 89)
    XCTAssertEqual(mapped.replyCount, 8)
    XCTAssertEqual(mapped.context?.postID, 202)
    XCTAssertEqual(mapped.context?.title, "Parent floor")
    XCTAssertEqual(mapped.context?.authorUsername, "parent-account")
    XCTAssertEqual(mapped.matchedTitle, "Nested match")
    XCTAssertEqual(mapped.matchedAuthorUsername, "matched-account")
    XCTAssertEqual(
      mapped.matchedAuthorPortraitURL?.absoluteString,
      "https://himg.bdimg.com/avatar.png"
    )
  }

  func testCoreMapperDoesNotPairMatchedUsernameWithContextAuthorName() {
    let mainPost = TiebaSearchPostContext(
      threadID: 42,
      postID: 100,
      title: "Opening topic",
      excerpt: "Opening content",
      authorID: 1,
      authorName: "topic author",
      authorPortraitURL: nil
    )
    let coreResult = TiebaThreadSearchResult(
      threadID: 42,
      firstPostID: 202,
      forumID: 7,
      forumName: "swift",
      title: "Reply match",
      excerpt: "Matched reply",
      authorID: 2,
      authorName: "reply author",
      authorUsername: "reply-account",
      authorPortraitURL: nil,
      replyCount: 1,
      likeCount: 0,
      shareCount: 0,
      createdAt: nil,
      images: [],
      target: .post(202),
      mainPost: mainPost
    )

    let mapped = TiebaCoreBrowseService.mapForumPostSearchResult(coreResult)

    XCTAssertEqual(mapped.thread.authorName, "topic author")
    XCTAssertEqual(mapped.thread.authorUsername, "")
    XCTAssertEqual(mapped.matchedAuthorUsername, "reply-account")
  }

  func testCoreMapperPreservesBothSearchPreviewQualitiesAndGalleryFallback() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://img.example/standard.jpg"))
    let fullSize = try XCTUnwrap(URL(string: "https://img.example/high-definition.jpg"))
    let coreResult = TiebaThreadSearchResult(
      threadID: 42,
      firstPostID: 100,
      forumID: 7,
      forumName: "swift",
      title: "Image match",
      excerpt: "Matched post",
      authorID: 1,
      authorName: "author",
      authorPortraitURL: nil,
      replyCount: 1,
      likeCount: 0,
      shareCount: 0,
      createdAt: nil,
      images: [
        TiebaSearchImage(
          thumbnailURL: thumbnail,
          fullSizeURL: fullSize,
          width: 640,
          height: 480
        )
      ]
    )

    let mapped = TiebaCoreBrowseService.mapForumPostSearchResult(coreResult)

    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(
        contents: mapped.matchedContents,
        hidesMedia: false,
        quality: .standard
      ),
      .expanded(imageURLs: [thumbnail], totalCount: 1)
    )
    XCTAssertEqual(
      ForumPostSearchMediaPresentation.resolve(
        contents: mapped.matchedContents,
        hidesMedia: false,
        quality: .highDefinition
      ),
      .expanded(imageURLs: [fullSize], totalCount: 1)
    )
    XCTAssertEqual(
      ImageGalleryPresentation(
        contents: mapped.matchedContents,
        selectedContentOffset: 0
      )?.items.map(\.url),
      [fullSize]
    )
  }

  @MainActor
  func testHistoryLoadsWithoutIssuingSearchAndSubmissionIsRecorded() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await history.seed(
      ForumSearchHistoryEntry(
        forumName: "swift",
        query: "actors",
        searchedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let result = ForumPostSearchFixtures.item(threadID: 10, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [result], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: " swift ",
      service: service,
      historyRepository: history
    )

    await viewModel.loadHistoryIfNeeded()

    XCTAssertEqual(viewModel.history.map(\.query), ["actors"])
    XCTAssertTrue(viewModel.isShowingHistory)
    let initialRequests = await service.requestSnapshot()
    XCTAssertEqual(initialRequests, [])

    viewModel.submit(" async ")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    try await forumPostSearchWaitUntil { viewModel.history.first?.query == "async" }

    XCTAssertEqual(viewModel.submittedQuery, "async")
    XCTAssertEqual(viewModel.results, [result])
    let submittedRequests = await service.requestSnapshot()
    XCTAssertEqual(
      submittedRequests,
      [
        ForumPostSearchRequest(
          query: "async",
          forumName: "swift",
          page: 1,
          pageSize: 20,
          sort: .newest,
          filter: .all
        )
      ]
    )
  }

  @MainActor
  func testExplicitHistoryResetClearsTheRepository() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await history.seed(
      ForumSearchHistoryEntry(
        forumName: "swift",
        query: "actors",
        searchedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    await viewModel.loadHistoryIfNeeded()

    await viewModel.resetHistory()

    let stored = try await history.entries(forumName: "swift")
    XCTAssertTrue(viewModel.history.isEmpty)
    XCTAssertNil(viewModel.historyError)
    XCTAssertTrue(stored.isEmpty)
  }

  @MainActor
  func testSameThreadReplyMatchesRemainDistinctAndPaginationDeduplicatesByTarget() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let topic = ForumPostSearchFixtures.item(threadID: 10, target: .thread)
    let reply = ForumPostSearchFixtures.item(threadID: 10, target: .post(101))
    let comment = ForumPostSearchFixtures.item(
      threadID: 10,
      target: .comment(postID: 101, commentID: 1_001)
    )
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [topic, reply],
          currentPage: 1,
          hasMore: true
        )
      )
    )
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [reply, comment],
          currentPage: 2,
          hasMore: false
        )
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("actor")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: reply)
    try await forumPostSearchWaitUntil { viewModel.results.count == 3 }

    XCTAssertEqual(viewModel.results.map(\.id), [topic.id, reply.id, comment.id])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  @MainActor
  func testOptionChangeRejectsStaleResponseAndForwardsNewOptions() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(.suspended(101))
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { await service.requestSnapshot().count == 1 }

    let relevant = ForumPostSearchFixtures.item(threadID: 20, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [relevant], currentPage: 1, hasMore: false))
    )
    viewModel.setSort(.relevance)
    try await forumPostSearchWaitUntil { viewModel.results == [relevant] }

    let stale = ForumPostSearchFixtures.item(threadID: 99, target: .thread)
    let resumed = await service.resume(
      id: 101,
      returning: ForumPostSearchPageData(results: [stale], currentPage: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.results, [relevant])
    XCTAssertEqual(viewModel.sort, .relevance)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.sort), [.newest, .relevance])
    XCTAssertEqual(requests.map(\.filter), [.all, .all])
  }

  @MainActor
  func testFilterChangeRestartsFirstPage() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [ForumPostSearchFixtures.item(threadID: 1, target: .post(11))],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let topic = ForumPostSearchFixtures.item(threadID: 2, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [topic], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    viewModel.setFilter(.threadsOnly)
    try await forumPostSearchWaitUntil { viewModel.results == [topic] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.filter), [.all, .threadsOnly])
  }

  @MainActor
  func testPaginationFailureCanRetryAndDuplicateOnlyPageStopsFurtherRequests() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 1, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(.failure(ForumPostSearchFailure(message: "page failed")))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 2, hasMore: true))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil {
      viewModel.loadMoreError == "page failed" && !viewModel.isLoadingMore
    }
    viewModel.retryLoadMore()
    try await forumPostSearchWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 3 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: first)
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.results, [first])
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  @MainActor
  func testDisplayableResultsKeepPlaceholdersAndExcludeHiddenItems() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let visible = ForumPostSearchFixtures.item(threadID: 31, target: .thread)
    let placeholder = ForumPostSearchFixtures.item(
      threadID: 32,
      target: .post(320),
      localVisibility: .placeholder
    )
    let hidden = ForumPostSearchFixtures.item(
      threadID: 33,
      target: .comment(postID: 330, commentID: 331),
      localVisibility: .hidden
    )
    await service.enqueue(
      .value(
        ForumPostSearchPageData(
          results: [visible, placeholder, hidden],
          currentPage: 1,
          hasMore: false
        )
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("actors")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.results, [visible, placeholder, hidden])
    XCTAssertEqual(viewModel.displayableResults, [visible, placeholder])
    XCTAssertTrue(viewModel.hasDisplayableResults)
  }

  @MainActor
  func testHiddenRawTailPaginatesAfterFirstPageReplacementAdvancesEpoch() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let visible = ForumPostSearchFixtures.item(threadID: 41, target: .thread)
    let hiddenTail = ForumPostSearchFixtures.item(
      threadID: 42,
      target: .post(420),
      localVisibility: .hidden
    )
    let firstPage = ForumPostSearchPageData(
      results: [visible, hiddenTail],
      currentPage: 1,
      hasMore: true
    )
    let next = ForumPostSearchFixtures.item(threadID: 43, target: .thread)
    await service.enqueue(.value(firstPage))
    await service.enqueue(.value(firstPage))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [next], currentPage: 2, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("actors")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    let firstEpoch = viewModel.resultPaginationEpoch

    await viewModel.refresh()

    XCTAssertGreaterThan(viewModel.resultPaginationEpoch, firstEpoch)
    XCTAssertEqual(viewModel.displayableResults, [visible])
    viewModel.loadMoreIfNeeded(current: hiddenTail)
    try await forumPostSearchWaitUntil { viewModel.results == [visible, hiddenTail, next] }
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2])
  }

  @MainActor
  func testAllHiddenPagesCanBeTriggeredUntilAVisibleResultArrives() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(
      threadID: 51,
      target: .thread,
      localVisibility: .hidden
    )
    let second = ForumPostSearchFixtures.item(
      threadID: 52,
      target: .post(520),
      localVisibility: .hidden
    )
    let visible = ForumPostSearchFixtures.item(threadID: 53, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [second], currentPage: 2, hasMore: true))
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [visible], currentPage: 3, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("actors")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    XCTAssertFalse(viewModel.hasDisplayableResults)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.results.last))
    try await forumPostSearchWaitUntil { viewModel.results == [first, second] }
    XCTAssertFalse(viewModel.hasDisplayableResults)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.results.last))
    try await forumPostSearchWaitUntil { viewModel.results == [first, second, visible] }
    XCTAssertEqual(viewModel.displayableResults, [visible])
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 3])
  }

  @MainActor
  func testContentFilterChangeReloadsFirstPageWithoutRewritingHistory() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let old = ForumPostSearchFixtures.item(threadID: 61, target: .thread)
    let reloaded = ForumPostSearchFixtures.item(
      threadID: 62,
      target: .post(620),
      localVisibility: .placeholder
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [old], currentPage: 4, hasMore: true))
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [reloaded], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.setSort(.relevance)
    viewModel.setFilter(.threadsOnly)
    viewModel.submit("actors")
    try await forumPostSearchWaitUntil { viewModel.results == [old] }
    try await forumPostSearchWaitUntil {
      let entries = try? await history.entries(forumName: "swift")
      return entries?.count == 1
    }
    let historyBeforeReload = try await history.entries(forumName: "swift")

    viewModel.reloadAfterContentFilterChange()

    XCTAssertTrue(viewModel.results.isEmpty)
    try await forumPostSearchWaitUntil { viewModel.results == [reloaded] }
    let historyAfterReload = try await history.entries(forumName: "swift")
    let recordedQueryCount = await history.recordCount()
    XCTAssertEqual(historyAfterReload, historyBeforeReload)
    XCTAssertEqual(recordedQueryCount, 1)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertEqual(requests.map(\.sort), [.relevance, .relevance])
    XCTAssertEqual(requests.map(\.filter), [.threadsOnly, .threadsOnly])
  }

  @MainActor
  func testContentFilterChangeRejectsLateResponseFromCancelledRefresh() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let initial = ForumPostSearchFixtures.item(threadID: 71, target: .thread)
    let filtered = ForumPostSearchFixtures.item(
      threadID: 72,
      target: .post(720),
      localVisibility: .hidden
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [initial], currentPage: 1, hasMore: false))
    )
    await service.enqueue(.suspended(701))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [filtered], currentPage: 1, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("actors")
    try await forumPostSearchWaitUntil { viewModel.results == [initial] }

    let refreshTask = Task { @MainActor in await viewModel.refresh() }
    try await forumPostSearchWaitUntil {
      let requests = await service.requestSnapshot()
      return requests.count == 2 && viewModel.state == .loading
    }
    XCTAssertEqual(viewModel.results, [initial])

    viewModel.reloadAfterContentFilterChange()
    XCTAssertTrue(viewModel.results.isEmpty)
    try await forumPostSearchWaitUntil { viewModel.results == [filtered] }

    let stale = ForumPostSearchFixtures.item(threadID: 79, target: .thread)
    let resumed = await service.resume(
      id: 701,
      returning: ForumPostSearchPageData(results: [stale], currentPage: 1, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await refreshTask.value
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.results, [filtered])
    XCTAssertFalse(viewModel.hasDisplayableResults)
  }

  @MainActor
  func testContentFilterChangeWhileShowingHistoryDoesNotSearch() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await history.seed(
      ForumSearchHistoryEntry(
        forumName: "swift",
        query: "actors",
        searchedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    await viewModel.loadHistoryIfNeeded()

    viewModel.reloadAfterContentFilterChange()
    await forumPostSearchDrainMainActor()

    XCTAssertTrue(viewModel.isShowingHistory)
    XCTAssertEqual(viewModel.history.map(\.query), ["actors"])
    let requests = await service.requestSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor
  func testRefreshFailurePreservesPaginationAndRearmsRawTail() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 1, target: .thread)
    let second = ForumPostSearchFixtures.item(threadID: 2, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(.failure(ForumPostSearchFailure(message: "refresh failed")))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [second], currentPage: 2, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    let epochBeforeRefresh = viewModel.resultPaginationEpoch

    await viewModel.refresh()

    XCTAssertEqual(viewModel.results, [first])
    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.refreshError, "refresh failed")
    XCTAssertGreaterThan(viewModel.resultPaginationEpoch, epochBeforeRefresh)
    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)

    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil { viewModel.results == [first, second] }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2])
  }

  @MainActor
  func testCancellingRefreshPreservesPaginationAndRearmsRawTail() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 11, target: .thread)
    let second = ForumPostSearchFixtures.item(threadID: 12, target: .thread)
    let third = ForumPostSearchFixtures.item(threadID: 13, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [second], currentPage: 2, hasMore: true))
    )
    await service.enqueue(.suspended(303))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [third], currentPage: 3, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil { viewModel.results == [first, second] }
    let epochBeforeRefresh = viewModel.resultPaginationEpoch

    let refreshTask = Task { @MainActor in await viewModel.refresh() }
    try await forumPostSearchWaitUntil {
      await service.requestSnapshot().count == 3 && viewModel.state == .loading
    }
    viewModel.cancel()

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.results, [first, second])
    XCTAssertGreaterThan(viewModel.resultPaginationEpoch, epochBeforeRefresh)

    viewModel.loadMoreIfNeeded(current: second)
    try await forumPostSearchWaitUntil { viewModel.results == [first, second, third] }

    let resumed = await service.resume(
      id: 303,
      returning: ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true)
    )
    XCTAssertTrue(resumed)
    await refreshTask.value

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 1, 3])
  }

  @MainActor
  func testCancellingLoadMoreRearmsRawTailWithoutAdvancingPage() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let first = ForumPostSearchFixtures.item(threadID: 21, target: .thread)
    let second = ForumPostSearchFixtures.item(threadID: 22, target: .thread)
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [first], currentPage: 1, hasMore: true))
    )
    await service.enqueue(.suspended(404))
    await service.enqueue(
      .value(ForumPostSearchPageData(results: [second], currentPage: 2, hasMore: false))
    )
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit("async")
    try await forumPostSearchWaitUntil { viewModel.state == .loaded }
    let epochBeforeLoadMore = viewModel.resultPaginationEpoch
    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil {
      await service.requestSnapshot().count == 2 && viewModel.isLoadingMore
    }

    viewModel.cancel()

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertGreaterThan(viewModel.resultPaginationEpoch, epochBeforeLoadMore)
    viewModel.loadMoreIfNeeded(current: first)
    try await forumPostSearchWaitUntil { viewModel.results == [first, second] }

    let resumed = await service.resume(
      id: 404,
      returning: ForumPostSearchPageData(results: [second], currentPage: 2, hasMore: false)
    )
    XCTAssertTrue(resumed)
    await forumPostSearchDrainMainActor()

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2])
  }

  @MainActor
  func testClearingQueryCancelsPendingSearchAndReturnsToHistory() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    await service.enqueue(.suspended(202))
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )
    viewModel.submit("async")
    try await forumPostSearchWaitUntil { await service.requestSnapshot().count == 1 }

    viewModel.clearSearch()
    XCTAssertTrue(viewModel.isShowingHistory)
    XCTAssertEqual(viewModel.state, .idle)

    let resumed = await service.resume(
      id: 202,
      returning: ForumPostSearchPageData(
        results: [ForumPostSearchFixtures.item(threadID: 99, target: .thread)],
        currentPage: 1,
        hasMore: false
      )
    )
    XCTAssertTrue(resumed)
    await forumPostSearchDrainMainActor()

    XCTAssertTrue(viewModel.results.isEmpty)
    XCTAssertTrue(viewModel.isShowingHistory)
  }

  @MainActor
  func testOverlongQueryIsRejectedBeforeHistoryOrNetworkMutation() async throws {
    let service = ScriptedForumPostSearchService()
    let history = MemoryForumSearchHistoryRepository()
    let viewModel = ForumPostSearchViewModel(
      forumName: "swift",
      service: service,
      historyRepository: history
    )

    viewModel.submit(String(repeating: "a", count: 101))
    viewModel.retry()
    viewModel.setSort(.relevance)
    viewModel.setFilter(.threadsOnly)
    viewModel.reloadAfterContentFilterChange()
    await forumPostSearchDrainMainActor()

    XCTAssertEqual(viewModel.state, .failed("搜索关键词不能超过 100 个字符。"))
    let requests = await service.requestSnapshot()
    let historyEntries = try await history.entries(forumName: "swift")
    XCTAssertTrue(requests.isEmpty)
    XCTAssertTrue(historyEntries.isEmpty)
  }
}

private struct ForumPostSearchRequest: Equatable, Sendable {
  let query: String
  let forumName: String
  let page: Int
  let pageSize: Int
  let sort: ForumPostSearchSort
  let filter: ForumPostSearchFilter
}

private struct ForumPostSearchFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum ForumPostSearchStub: Sendable {
  case value(ForumPostSearchPageData)
  case failure(ForumPostSearchFailure)
  case suspended(Int)
}

private actor ScriptedForumPostSearchService: ForumPostSearchService {
  private var stubs: [ForumPostSearchStub] = []
  private var requests: [ForumPostSearchRequest] = []
  private var pending: [Int: CheckedContinuation<ForumPostSearchPageData, any Error>] = [:]

  func enqueue(_ stub: ForumPostSearchStub) {
    stubs.append(stub)
  }

  func searchForumPosts(
    query: String,
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) async throws -> ForumPostSearchPageData {
    requests.append(
      ForumPostSearchRequest(
        query: query,
        forumName: forumName,
        page: page,
        pageSize: pageSize,
        sort: sort,
        filter: filter
      )
    )
    guard !stubs.isEmpty else {
      throw ForumPostSearchFailure(message: "Unexpected search request")
    }
    switch stubs.removeFirst() {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pending[identifier] = continuation
      }
    }
  }

  func requestSnapshot() -> [ForumPostSearchRequest] {
    requests
  }

  func resume(id: Int, returning value: ForumPostSearchPageData) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: value)
    return true
  }
}

private actor MemoryForumSearchHistoryRepository: ForumSearchHistoryRepository {
  private var storedEntries: [ForumSearchHistoryEntry] = []
  private var recordedQueryCount = 0

  func seed(_ entry: ForumSearchHistoryEntry) {
    storedEntries.append(entry)
  }

  func entries(forumName: String) async throws -> [ForumSearchHistoryEntry] {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    return storedEntries
      .filter {
        ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key
      }
      .sorted { $0.searchedAt > $1.searchedAt }
  }

  func record(query: String, forumName: String, at date: Date) async throws {
    recordedQueryCount += 1
    let entry = ForumSearchHistoryEntry(forumName: forumName, query: query, searchedAt: date)
    storedEntries.removeAll { $0.id == entry.id }
    storedEntries.append(entry)
  }

  func delete(id: String) async throws {
    storedEntries.removeAll { $0.id == id }
  }

  func deleteAll(forumName: String) async throws {
    let key = ForumSearchHistoryEntry.normalizedIdentityComponent(forumName)
    storedEntries.removeAll {
      ForumSearchHistoryEntry.normalizedIdentityComponent($0.forumName) == key
    }
  }

  func reset() async throws {
    storedEntries = []
  }

  func recordCount() -> Int {
    recordedQueryCount
  }
}

private enum ForumPostSearchFixtures {
  static func item(
    threadID: Int64,
    target: ForumPostSearchTarget,
    localVisibility: LocalContentVisibility = .visible
  ) -> ForumPostSearchItem {
    ForumPostSearchItem(
      thread: BrowseThread(
        id: threadID,
        forumID: 7,
        forumName: "swift",
        title: "Thread \(threadID)",
        excerpt: "Thread excerpt",
        authorName: "thread author",
        replyCount: 3,
        viewCount: 0,
        createdAt: Date(timeIntervalSince1970: 100),
        lastReplyAt: nil,
        contents: []
      ),
      target: target,
      matchedTitle: "Match",
      matchedExcerpt: "Matched excerpt",
      matchedAuthorID: 8,
      matchedAuthorName: "matched author",
      matchedAuthorPortraitURL: nil,
      matchedAt: Date(timeIntervalSince1970: 100),
      replyCount: 3,
      likeCount: 2,
      shareCount: 1,
      matchedContents: [],
      context: nil,
      localVisibility: localVisibility
    )
  }
}

@MainActor
private func forumPostSearchWaitUntil(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    if Date() >= deadline {
      XCTFail("Timed out waiting for forum post search state")
      return
    }
    await Task.yield()
  }
}

@MainActor
private func forumPostSearchDrainMainActor() async {
  for _ in 0..<20 {
    await Task.yield()
  }
}
