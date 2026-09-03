import Foundation
import XCTest

@testable import TiebaCore

private enum TiebaLiveSearchRetryPolicy {
  static let errorDelays: [Duration] = [.seconds(5), .seconds(15)]
  static let emptyResultDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

  static func delay(afterTransientEmptyResult failedAttempt: Int) -> Duration? {
    guard failedAttempt > 0, failedAttempt <= emptyResultDelays.count else { return nil }
    return emptyResultDelays[failedAttempt - 1]
  }

  static func delay(after error: Error, failedAttempt: Int) -> Duration? {
    guard
      failedAttempt > 0,
      failedAttempt <= errorDelays.count,
      let clientError = error as? TiebaClientError,
      case .server(let code, let message) = clientError,
      code == 300_003,
      message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "internal error"
    else {
      return nil
    }
    return errorDelays[failedAttempt - 1]
  }
}

final class TiebaLiveTests: XCTestCase {
  func testLiveSearchRetryPolicyIsNarrowAndBounded() {
    let transientError = TiebaClientError.server(
      code: 300_003,
      message: " Internal Error "
    )

    XCTAssertEqual(
      TiebaLiveSearchRetryPolicy.delay(after: transientError, failedAttempt: 1),
      .seconds(5)
    )
    XCTAssertEqual(
      TiebaLiveSearchRetryPolicy.delay(after: transientError, failedAttempt: 2),
      .seconds(15)
    )
    XCTAssertNil(
      TiebaLiveSearchRetryPolicy.delay(after: transientError, failedAttempt: 3)
    )
    XCTAssertEqual(
      TiebaLiveSearchRetryPolicy.delay(afterTransientEmptyResult: 1),
      .seconds(2)
    )
    XCTAssertEqual(
      TiebaLiveSearchRetryPolicy.delay(afterTransientEmptyResult: 2),
      .seconds(5)
    )
    XCTAssertEqual(
      TiebaLiveSearchRetryPolicy.delay(afterTransientEmptyResult: 3),
      .seconds(10)
    )
    XCTAssertNil(
      TiebaLiveSearchRetryPolicy.delay(afterTransientEmptyResult: 4)
    )
    XCTAssertNil(
      TiebaLiveSearchRetryPolicy.delay(
        after: TiebaClientError.server(code: 300_003, message: "search unavailable"),
        failedAttempt: 1
      )
    )
    XCTAssertNil(
      TiebaLiveSearchRetryPolicy.delay(
        after: TiebaClientError.server(code: 300_004, message: "internal error"),
        failedAttempt: 1
      )
    )
    XCTAssertNil(
      TiebaLiveSearchRetryPolicy.delay(
        after: TiebaClientError.network(code: -1_001),
        failedAttempt: 1
      )
    )
  }

  func testAnonymousPersonalizedFeedUsesAppScopedUUIDAndPaginates() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(
        userAgent: "TiebaPlusPlus/0.60 integration-test",
        personalizedCUID: "28f1c3b4-786a-4abd-8e41-65339f4a2d5f"
      )
    )
    let firstPage = try await client.getPersonalizedThreads()

    XCTAssertEqual(firstPage.currentPage, 1)
    XCTAssertFalse(firstPage.items.isEmpty)
    XCTAssertEqual(Set(firstPage.items.map(\.id)).count, firstPage.items.count)
    XCTAssertTrue(firstPage.items.allSatisfy {
      $0.id > 0 && $0.thread.forumID > 0 && !$0.thread.forumName.isEmpty
    })
    let firstIDs = Set(firstPage.items.map(\.id))

    XCTAssertTrue(firstPage.hasMore)
    let secondPage = try await client.getPersonalizedThreads(page: 2)
    XCTAssertEqual(secondPage.currentPage, 2)
    if !secondPage.hasMore {
      XCTAssertTrue(secondPage.items.isEmpty)
      throw XCTSkip("The live recommendation session ended before page 3.")
    }
    XCTAssertTrue(secondPage.items.allSatisfy {
      $0.id > 0 && $0.thread.forumID > 0 && !$0.thread.forumName.isEmpty
    })
    let thirdPage = try await client.getPersonalizedThreads(page: 3)
    XCTAssertEqual(thirdPage.currentPage, 3)
    if !thirdPage.hasMore {
      XCTAssertTrue(thirdPage.items.isEmpty)
    }
    XCTAssertTrue(thirdPage.items.allSatisfy {
      $0.id > 0 && $0.thread.forumID > 0 && !$0.thread.forumName.isEmpty
    })
    let laterItems = secondPage.items + thirdPage.items
    if !laterItems.isEmpty {
      XCTAssertTrue(laterItems.contains { !firstIDs.contains($0.id) })
    }
  }

  func testAnonymousPicturePageMatchesPBImageCursor() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    var sample: (
      page: TiebaPostPage,
      postID: Int64,
      cursor: TiebaPicturePageCursor
    )?

    search: for threadID: Int64 in [6_639_694_648, 1_978_273_802] {
      guard let postPage = try? await client.getPosts(threadID: threadID, pageSize: 30) else {
        continue
      }
      let posts = (postPage.firstPost.map { [$0] } ?? []) + postPage.posts
      for post in posts {
        for (imageIndex, image) in post.content.images.enumerated() {
          for url in [
            image.originalURL,
            image.fullSizeURL,
            image.dynamicURL,
            image.thumbnailURL,
          ].compactMap({ $0 }) {
            if let cursor = TiebaPicturePageCursor(
              imageURL: url,
              overallIndex: imageIndex + 1
            ) {
              sample = (postPage, post.id, cursor)
              break search
            }
          }
        }
      }
    }

    guard let sample else {
      throw XCTSkip("The fixed public picture threads no longer expose a parseable PB image.")
    }
    let picturePage = try await client.getPicturePage(
      forumID: sample.page.forum.id,
      forumName: sample.page.forum.name,
      threadID: sample.page.thread.id,
      cursor: sample.cursor
    )
    let matchedPicture = try XCTUnwrap(
      picturePage.pictures.first(where: {
        $0.pictureID == sample.cursor.pictureID
          && ($0.postID == nil || $0.postID == sample.postID)
      })
    )

    XCTAssertEqual(matchedPicture.cursor.pictureID, sample.cursor.pictureID)
    if let responsePostID = matchedPicture.postID {
      XCTAssertEqual(responsePostID, sample.postID)
    }
    XCTAssertGreaterThanOrEqual(picturePage.totalPictureCount, picturePage.pictures.count)
    XCTAssertLessThanOrEqual(
      picturePage.pictures.count,
      TiebaPicturePagePolicy.maximumResponsePictureCount
    )
  }

  func testAnonymousForumPostAndCommentFlow() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let threads = try await client.getThreads(forumName: "starry", pageSize: 10)
    XCTAssertFalse(threads.threads.isEmpty)

    let creationSorted = try await client.getThreads(
      forumName: "starry",
      pageSize: 5,
      sort: .creationTime
    )
    XCTAssertFalse(creationSorted.threads.isEmpty)

    if let classification = threads.forum.featuredClassifications.first {
      _ = try await client.getThreads(
        forumName: "starry",
        pageSize: 5,
        featuredOnly: true,
        featuredClassificationID: classification.id
      )
    } else {
      _ = try await client.getThreads(
        forumName: "starry",
        pageSize: 5,
        featuredOnly: true
      )
    }

    let thread = try XCTUnwrap(threads.threads.max { $0.replyCount < $1.replyCount })
    let posts = try await client.getPosts(threadID: thread.id, pageSize: 10)
    XCTAssertFalse(posts.posts.isEmpty)

    let resumePost = try XCTUnwrap(posts.posts.last)
    let resumedPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      location: .postID(resumePost.id)
    )
    XCTAssertTrue(resumedPosts.posts.contains(where: { $0.id == resumePost.id }))

    let middlePage = try await client.getPosts(
      threadID: thread.id,
      page: 2,
      pageSize: 10,
      location: .pageNumber
    )
    let middlePost = try XCTUnwrap(middlePage.posts.last)
    let anchoredMiddlePage = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      location: .postID(middlePost.id)
    )
    XCTAssertTrue(anchoredMiddlePage.posts.contains(where: { $0.id == middlePost.id }))
    XCTAssertGreaterThan(anchoredMiddlePage.pagination.currentPage, 1)
    XCTAssertTrue(anchoredMiddlePage.pagination.hasPrevious)
    let anchoredFirstPost = try XCTUnwrap(anchoredMiddlePage.firstPost)
    XCTAssertGreaterThan(anchoredMiddlePage.thread.firstPostID, 0)
    XCTAssertEqual(anchoredFirstPost.id, anchoredMiddlePage.thread.firstPostID)
    XCTAssertEqual(anchoredFirstPost.threadID, anchoredMiddlePage.thread.id)
    XCTAssertEqual(anchoredFirstPost.floor, 1)
    XCTAssertFalse(anchoredMiddlePage.posts.contains {
      $0.floor == 1 || $0.id == anchoredFirstPost.id
    })
    let earlierPage = try await client.getPosts(
      threadID: thread.id,
      page: anchoredMiddlePage.pagination.currentPage - 1,
      pageSize: 10,
      location: .pageNumber
    )
    XCTAssertEqual(
      earlierPage.pagination.currentPage,
      anchoredMiddlePage.pagination.currentPage - 1
    )
    let anchoredIDs = Set(anchoredMiddlePage.posts.map(\.id))
    let uniqueEarlierPosts = earlierPage.posts.filter { !anchoredIDs.contains($0.id) }
    XCTAssertFalse(uniqueEarlierPosts.isEmpty)
    if let earlierFloor = uniqueEarlierPosts.map(\.floor).filter({ $0 > 0 }).max(),
      let anchoredFloor = anchoredMiddlePage.posts.map(\.floor).filter({ $0 > 0 }).max()
    {
      XCTAssertLessThan(earlierFloor, anchoredFloor)
    }

    // Leave more than one reply page after the separately returned first floor.
    let descendingPageSize = 5
    let descendingPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: descendingPageSize,
      sort: .descending
    )
    XCTAssertFalse(descendingPosts.posts.isEmpty)
    let descendingFloors = descendingPosts.posts.map(\.floor).filter { $0 > 0 }
    XCTAssertGreaterThan(descendingFloors.count, 1)
    XCTAssertGreaterThan(
      try XCTUnwrap(descendingFloors.first),
      try XCTUnwrap(descendingFloors.last)
    )
    XCTAssertTrue(
      zip(descendingFloors, descendingFloors.dropFirst()).allSatisfy { pair in
        pair.0 >= pair.1
      }
    )

    XCTAssertGreaterThan(descendingPosts.pagination.totalPages, 1)
    let cursor = try XCTUnwrap(descendingPosts.thread.pagePostIDs.first)
    let continuationPage = max(
      descendingPosts.pagination.totalPages - descendingPosts.pagination.currentPage,
      0
    )
    let continuedPosts = try await client.getPosts(
      threadID: thread.id,
      page: continuationPage,
      pageSize: descendingPageSize,
      sort: .descending,
      location: .pageCursor(cursor)
    )
    XCTAssertFalse(continuedPosts.posts.isEmpty)
    let continuedFloors = continuedPosts.posts.map(\.floor).filter { $0 > 0 }
    XCTAssertGreaterThan(continuedFloors.count, 1)
    XCTAssertTrue(
      zip(continuedFloors, continuedFloors.dropFirst()).allSatisfy { pair in
        pair.0 >= pair.1
      }
    )
    let initialPostIDs = Set(descendingPosts.posts.map(\.id))
    let uniqueContinuedPosts = continuedPosts.posts.filter { !initialPostIDs.contains($0.id) }
    XCTAssertFalse(uniqueContinuedPosts.isEmpty)
    if let initialNewestFloor = descendingFloors.max(),
      let continuedNewestFloor = uniqueContinuedPosts.map(\.floor).filter({ $0 > 0 }).max()
    {
      XCTAssertLessThan(continuedNewestFloor, initialNewestFloor)
    }

    let hotAuthorPosts = try await client.getPosts(
      threadID: thread.id,
      pageSize: 10,
      sort: .hot,
      onlyThreadAuthor: true
    )
    let hotAuthorFirstPost = try XCTUnwrap(hotAuthorPosts.firstPost)
    XCTAssertEqual(hotAuthorFirstPost.id, hotAuthorPosts.thread.firstPostID)
    XCTAssertTrue(hotAuthorFirstPost.isThreadAuthor)
    XCTAssertTrue(hotAuthorPosts.posts.allSatisfy(\.isThreadAuthor))

    guard let post = posts.posts.first(where: { $0.commentCount > 0 }) else {
      throw XCTSkip("The sampled live posts have no nested comments.")
    }
    let comments = try await client.getComments(threadID: thread.id, postID: post.id)
    XCTAssertEqual(comments.thread.id, thread.id)
    XCTAssertEqual(comments.parentPost.id, post.id)
  }

  func testAnonymousForumChannelsSortAndCursorPagination() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let forumPage = try await client.getThreads(forumName: "minecraft", pageSize: 10)
    let channel = try XCTUnwrap(
      forumPage.channels.first(where: { $0.name == "图文攻略" })
        ?? forumPage.channels.first
    )
    XCTAssertGreaterThan(channel.id, 0)
    XCTAssertFalse(channel.name.isEmpty)
    XCTAssertLessThanOrEqual(channel.sortOptions.count, 12)
    XCTAssertTrue(channel.sortOptions.allSatisfy {
      $0.id >= 0 && !$0.title.isEmpty && $0.title.count <= 40
    })

    let advertisedSorts = channel.sortOptions.prefix(3).map {
      TiebaForumChannelSort(rawValue: $0.id)
    }
    let sorts = advertisedSorts.isEmpty
      ? [TiebaForumChannelSort.unspecified]
      : advertisedSorts
    for (sortIndex, sort) in sorts.enumerated() {
      let firstPage = try await client.getForumChannelThreads(
        forumID: forumPage.forum.id,
        forumName: forumPage.forum.name,
        channel: channel,
        page: 1,
        pageSize: 20,
        sort: sort
      )
      XCTAssertEqual(firstPage.channel, channel)
      XCTAssertEqual(firstPage.pagination.currentPage, 1)
      XCTAssertFalse(firstPage.threads.isEmpty)
      XCTAssertTrue(firstPage.threads.allSatisfy {
        $0.id > 0 && $0.forumID == forumPage.forum.id && !$0.forumName.isEmpty
      })

      guard sortIndex == 0, firstPage.pagination.hasMore else { continue }
      let cursor = try XCTUnwrap(firstPage.nextPageCursor)
      let secondPage = try await client.getForumChannelThreads(
        forumID: forumPage.forum.id,
        forumName: forumPage.forum.name,
        channel: channel,
        page: 2,
        pageSize: 20,
        sort: sort,
        lastThreadID: cursor
      )
      XCTAssertEqual(secondPage.pagination.currentPage, 2)
      XCTAssertFalse(secondPage.threads.isEmpty)
      let firstPageIDs = Set(firstPage.threads.map(\.id))
      XCTAssertTrue(secondPage.threads.contains { !firstPageIDs.contains($0.id) })
    }
  }

  func testAnonymousForumAndThreadSearch() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let forums = try await retryingTransientLiveSearch("forum search") {
      try await client.searchForums(query: "swift")
    }
    XCTAssertFalse(forums.isLoggedIn)
    XCTAssertTrue(forums.exactMatch != nil || !forums.fuzzyMatches.isEmpty)

    for sort in TiebaGlobalThreadSearchSort.allCases {
      let threads = try await retryingTransientLiveSearch(
        "global thread search (\(sort))",
        retryingResult: {
          !$0.isLoggedIn
            && $0.pagination.currentPage == 1
            && !$0.pagination.hasPrevious
            && $0.results.isEmpty
        }
      ) {
        try await client.searchThreads(query: "贴吧", pageSize: 5, sort: sort)
      }
      XCTAssertFalse(threads.isLoggedIn)
      XCTAssertFalse(threads.results.isEmpty, "Expected anonymous results for \(sort)")
      XCTAssertEqual(threads.pagination.currentPage, 1)
      XCTAssertTrue(threads.results.allSatisfy { $0.threadID > 0 })
    }

    let scopedThreads = try await retryingTransientLiveSearch("scoped thread search") {
      try await client.searchForumPosts(
        query: "游戏",
        forumName: "minecraft",
        pageSize: 5,
        sort: .relevance,
        filter: .threadsOnly
      )
    }
    XCTAssertFalse(scopedThreads.isLoggedIn)
    XCTAssertFalse(scopedThreads.results.isEmpty)
    XCTAssertEqual(scopedThreads.pagination.currentPage, 1)
    XCTAssertTrue(scopedThreads.results.allSatisfy { $0.target == .thread })

    let scopedAllContent = try await retryingTransientLiveSearch(
      "scoped all-content search"
    ) {
      try await client.searchForumPosts(
        query: "游戏",
        forumName: "minecraft",
        pageSize: 20,
        sort: .newest,
        filter: .all
      )
    }
    XCTAssertFalse(scopedAllContent.results.isEmpty)
    let containsReply = scopedAllContent.results.contains(where: { result in
      if case .post = result.target { return true }
      return false
    })
    XCTAssertTrue(containsReply)

    if scopedThreads.pagination.hasMore {
      let nextScopedPage = try await retryingTransientLiveSearch(
        "scoped thread search page 2"
      ) {
        try await client.searchForumPosts(
          query: "游戏",
          forumName: "minecraft",
          page: 2,
          pageSize: 5,
          sort: .relevance,
          filter: .threadsOnly
        )
      }
      XCTAssertEqual(nextScopedPage.pagination.currentPage, 2)
      XCTAssertFalse(nextScopedPage.results.isEmpty)
    }

    let users = try await retryingTransientLiveSearch("user search") {
      try await client.searchUsers(query: "swift")
    }
    XCTAssertTrue(users.exactMatch != nil || !users.fuzzyMatches.isEmpty)
    XCTAssertTrue(users.fuzzyMatches.allSatisfy { $0.id > 0 && !$0.preferredName.isEmpty })
  }

  func testAnonymousSharedThreadOriginContext() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let feed = try await client.getThreads(forumName: "steam", pageSize: 100)
    let candidates = feed.threads.filter(\.isShared)
    guard !candidates.isEmpty else {
      throw XCTSkip("The current public feed contains no shared-thread sample.")
    }

    for candidate in candidates.prefix(5) {
      guard let page = try? await client.getPosts(threadID: candidate.id, pageSize: 2),
        let origin = page.originThread
      else { continue }
      XCTAssertGreaterThan(origin.id, 0)
      XCTAssertNotEqual(origin.id, candidate.id)
      XCTAssertTrue(!origin.title.isEmpty || !origin.content.fragments.isEmpty)
      return
    }
    XCTFail("Public shared-thread candidates did not expose a valid distinct origin context.")
  }

  func testAnonymousPostAuthorContextAndAgreementScore() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let page = try await client.getPosts(threadID: 8_211_419_000, pageSize: 2)
    let firstPost = try XCTUnwrap(page.firstPost)
    let author = try XCTUnwrap(firstPost.author)

    XCTAssertEqual(firstPost.id, page.thread.firstPostID)
    XCTAssertEqual(firstPost.threadID, page.thread.id)
    XCTAssertEqual(firstPost.floor, 1)
    XCTAssertFalse(page.posts.contains { $0.floor == 1 || $0.id == firstPost.id })
    XCTAssertGreaterThan(author.level, 0)
    XCTAssertFalse(author.ipLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertGreaterThan(firstPost.agreeScore, 0)
    XCTAssertEqual(firstPost.agreeScore, firstPost.agreeCount - firstPost.disagreeCount)

    let latestSeedPage = try await client.getPosts(
      threadID: page.thread.id,
      pageSize: 100,
      sort: .ascending
    )
    let terminalPage: TiebaPostPage
    if latestSeedPage.pagination.hasMore {
      terminalPage = try await client.getPosts(
        threadID: page.thread.id,
        page: max(latestSeedPage.pagination.totalPages, 1),
        pageSize: 100,
        sort: .ascending,
        location: .pageNumber
      )
    } else {
      terminalPage = latestSeedPage
    }
    XCTAssertFalse(terminalPage.pagination.hasMore)
    let terminalPost = try XCTUnwrap(terminalPage.posts.last)
    let terminalPostIDs = Set(terminalPage.posts.map(\.id))
    let latestReplies = try await client.getPosts(
      threadID: page.thread.id,
      page: 1,
      pageSize: 15,
      sort: .ascending,
      location: .latestReplies(after: terminalPost.id)
    )
    XCTAssertTrue(latestReplies.posts.allSatisfy { post in
      post.threadID == page.thread.id && !terminalPostIDs.contains(post.id)
    })
    XCTAssertFalse(latestReplies.posts.contains { $0.floor == 1 })
  }

  func testAnonymousDirectReplyMentionContextIsPreserved() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let page = try await client.getComments(
      threadID: 7_763_274_602,
      postID: 143_493_604_437
    )
    let comment = try XCTUnwrap(page.comments.first)
    let replyToUserID = try XCTUnwrap(comment.replyToUserID)

    XCTAssertEqual(replyToUserID, 4_136_442_250)
    XCTAssertEqual(comment.replyToUserName, "深水行军铲")
    XCTAssertEqual(comment.content.plainText, "@深水行军铲 测试")
    XCTAssertTrue(comment.content.fragments.contains { fragment in
      guard case .mention(let mention) = fragment else { return false }
      return mention.userID == replyToUserID
    })

    let anchoredPage = try await client.getComments(
      threadID: 7_763_274_602,
      postID: 143_493_604_437,
      aroundCommentID: comment.id
    )
    XCTAssertEqual(anchoredPage.parentPost.id, 143_493_604_437)
    XCTAssertTrue(anchoredPage.comments.contains(where: { $0.id == comment.id }))

    let resolvedPage = try await client.getComments(
      threadID: 7_763_274_602,
      resolvingCommentID: comment.id
    )
    XCTAssertEqual(resolvedPage.parentPost.id, 143_493_604_437)
    XCTAssertTrue(resolvedPage.comments.contains(where: { $0.id == comment.id }))
  }

  func testAnonymousChildOnlyResolverTargetsKnownLaterPage() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.59 integration-test")
    )
    let targetCommentID: Int64 = 152_676_987_419
    let resolvedPage = try await client.getComments(
      threadID: 9_916_162_412,
      resolvingCommentID: targetCommentID
    )

    XCTAssertEqual(resolvedPage.parentPost.id, 152_445_649_580)
    XCTAssertGreaterThan(resolvedPage.pagination.currentPage, 1)
    XCTAssertTrue(resolvedPage.comments.contains(where: { $0.id == targetCommentID }))
  }

  func testAnonymousInlineNestedReplyPreview() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let threadID: Int64 = 7_763_274_602
    let postID: Int64 = 143_493_604_437
    let page = try await client.getPosts(
      threadID: threadID,
      pageSize: 2,
      location: .postID(postID),
      includeComments: true,
      commentsSortedByAgree: true,
      commentPageSize: 4
    )
    let post = try XCTUnwrap(page.posts.first(where: { $0.id == postID }))
    let commentIDs = post.comments.map(\.id)

    XCTAssertGreaterThan(post.commentCount, 0)
    XCTAssertFalse(commentIDs.isEmpty)
    XCTAssertLessThanOrEqual(commentIDs.count, 4)
    XCTAssertTrue(commentIDs.allSatisfy { $0 > 0 })
    XCTAssertEqual(Set(commentIDs).count, commentIDs.count)
    XCTAssertTrue(post.comments.allSatisfy {
      $0.threadID == threadID && $0.parentPostID == postID
    })
  }

  func testAnonymousPollResultsAndSharedOriginOwnership() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let feed = try await client.getThreads(forumName: "starry", pageSize: 100)
    var candidateIDs = feed.threads.compactMap { thread -> Int64? in
      if case .vote = thread.kind { return thread.id }
      return nil
    }
    candidateIDs.append(contentsOf: [9_222_422_736, 8_211_419_000])

    var mappedPoll: TiebaPoll?
    for threadID in candidateIDs {
      guard let page = try? await client.getPosts(threadID: threadID, pageSize: 2),
        let poll = page.poll
      else { continue }
      mappedPoll = poll
      break
    }
    let poll = try XCTUnwrap(mappedPoll)
    XCTAssertGreaterThanOrEqual(poll.options.count, 2)
    XCTAssertEqual(
      poll.options.reduce(Int64(0)) { $0 + $1.voteCount },
      poll.totalVoteCount
    )
    XCTAssertGreaterThanOrEqual(poll.participantCount, 0)
    XCTAssertTrue(poll.options.allSatisfy { $0.voteCount >= 0 })

    let sharedPage = try await client.getPosts(threadID: 8_213_449_397, pageSize: 2)
    XCTAssertNil(sharedPage.poll)
    let origin = try XCTUnwrap(sharedPage.originThread)
    XCTAssertEqual(origin.id, 8_211_419_000)
    let originPoll = try XCTUnwrap(origin.poll)
    XCTAssertFalse(originPoll.options.isEmpty)
  }

  func testAnonymousHotThreadRankingAndAdvertisedCategories() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let ranking = try await client.getHotThreadRanking()

    XCTAssertFalse(ranking.items.isEmpty)
    XCTAssertFalse(ranking.categories.isEmpty)
    XCTAssertLessThanOrEqual(ranking.topics.count, 20)
    XCTAssertLessThanOrEqual(ranking.categories.count, 20)
    XCTAssertLessThanOrEqual(ranking.items.count, 100)
    XCTAssertEqual(ranking.items.map(\.rank), ranking.items.indices.map { $0 + 1 })
    XCTAssertEqual(Set(ranking.items.map(\.id)).count, ranking.items.count)
    XCTAssertEqual(Set(ranking.categories.map(\.code)).count, ranking.categories.count)
    XCTAssertTrue(
      ranking.items.allSatisfy {
        $0.id > 0 && $0.hotScore >= 0 && $0.thread.forumID > 0 && !$0.thread.forumName.isEmpty
      }
    )

    for category in ranking.categories.prefix(2) {
      let categoryRanking = try await client.getHotThreadRanking(categoryCode: category.code)
      XCTAssertLessThanOrEqual(categoryRanking.items.count, 100)
      XCTAssertEqual(
        categoryRanking.items.map(\.rank),
        categoryRanking.items.indices.map { $0 + 1 }
      )
      XCTAssertTrue(categoryRanking.items.allSatisfy { $0.id > 0 && $0.hotScore >= 0 })
    }
  }

  func testAnonymousHotTopicListDetailAndPagination() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let topics = try await client.getHotTopics()
    let topic = try XCTUnwrap(topics.first)
    XCTAssertGreaterThan(topic.id, 0)
    XCTAssertFalse(topic.name.isEmpty)
    XCTAssertGreaterThan(topic.rank, 0)

    let firstPage = try await client.getHotTopic(
      topicID: topic.id,
      topicName: topic.name,
      pageSize: 10
    )
    XCTAssertEqual(firstPage.topic.id, topic.id)
    XCTAssertFalse(firstPage.topic.name.isEmpty)
    XCTAssertFalse(firstPage.threads.isEmpty && firstPage.relatedForums.isEmpty)
    XCTAssertTrue(firstPage.threads.allSatisfy { $0.threadID > 0 })

    if firstPage.pagination.hasMore, let cursor = firstPage.nextPageCursor {
      let secondPage = try await client.getHotTopic(
        topicID: topic.id,
        topicName: topic.name,
        page: 2,
        pageSize: 10,
        lastID: cursor
      )
      XCTAssertEqual(secondPage.pagination.currentPage, 2)
      XCTAssertTrue(secondPage.threads.allSatisfy { $0.threadID > 0 })
    }
  }

  func testAnonymousPublicUserProfileAndThreads() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let userID: Int64 = 957_339_815
    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )

    let profile = try await client.getUserProfile(userID: userID)
    XCTAssertEqual(profile.user.id, userID)
    XCTAssertFalse(profile.user.preferredName.isEmpty)
    XCTAssertFalse(profile.user.portrait.isEmpty)
    XCTAssertFalse(profile.likedForums.isEmpty)
    XCTAssertGreaterThanOrEqual(profile.followedForumCount, profile.likedForums.count)
    XCTAssertTrue(profile.likedForums.allSatisfy { $0.id > 0 && !$0.name.isEmpty })
    XCTAssertEqual(Set(profile.likedForums.map(\.id)).count, profile.likedForums.count)

    let activity = try await client.getUserThreads(userID: userID, page: 1, pageSize: 20)
    XCTAssertEqual(activity.userID, userID)
    XCTAssertEqual(activity.pagination.currentPage, 1)
    XCTAssertFalse(activity.isHidden)
    XCTAssertFalse(activity.threads.isEmpty)
    XCTAssertTrue(activity.threads.allSatisfy { $0.id > 0 && $0.forumID > 0 })
  }

  func testAnonymousPublicUserRepliesUseEndpointCompatibleProtocol() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let userID: Int64 = 4_954_297_652
    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )

    let activity = try await client.getUserReplies(userID: userID, page: 1, pageSize: 20)

    XCTAssertEqual(activity.userID, userID)
    XCTAssertEqual(activity.pagination.currentPage, 1)
    XCTAssertFalse(activity.isHidden)
    XCTAssertFalse(activity.replies.isEmpty)
    XCTAssertTrue(
      activity.replies.allSatisfy {
        $0.threadID > 0 && $0.postID > 0 && $0.forumID >= 0
      }
    )
  }

  func testAnonymousPublicUserRelationsUseCredentialFreeSignedForms() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let configuredUserID = ProcessInfo.processInfo.environment["TIEBA_LIVE_RELATION_USER_ID"]
      .flatMap { Int64($0) }
    let userID = configuredUserID ?? 957_339_815
    guard userID > 0 else {
      throw XCTSkip("TIEBA_LIVE_RELATION_USER_ID must be a positive decimal UID.")
    }
    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )

    for kind in [TiebaUserRelationKind.following, .followers] {
      let relations = try await client.getUserRelations(userID: userID, kind: kind)
      XCTAssertEqual(relations.requestedUserID, userID)
      XCTAssertEqual(relations.kind, kind)
      XCTAssertEqual(relations.pagination.currentPage, 1)
      XCTAssertFalse(relations.pagination.hasPrevious)
      XCTAssertLessThanOrEqual(
        relations.users.count,
        TiebaPublicSocialPolicy.maximumResponseUserCount
      )
      XCTAssertEqual(Set(relations.users.map(\.id)).count, relations.users.count)
      XCTAssertTrue(
        relations.users.allSatisfy {
          $0.id > 0
            && !$0.preferredName.isEmpty
            && !$0.portrait.contains("?")
        }
      )
    }
  }

  func testAnonymousPublicForumOverviewModeratorsAndRules() async throws {
    guard ProcessInfo.processInfo.environment["TIEBA_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set TIEBA_LIVE_TESTS=1 to exercise the unofficial live API.")
    }

    let client = TiebaClient(
      configuration: .init(userAgent: "TiebaPlusPlus/0.56 integration-test")
    )
    let forumID: Int64 = 2_432_903

    let overview = try await client.getForumOverview(forumID: forumID)
    XCTAssertEqual(overview.forum.id, forumID)
    XCTAssertEqual(overview.forum.name.lowercased(), "minecraft")
    XCTAssertFalse(overview.introduction.isEmpty)
    XCTAssertGreaterThan(overview.forum.memberCount, 0)

    let moderatorRoles = try await client.getForumModerators(forumID: forumID)
    XCTAssertFalse(moderatorRoles.isEmpty)
    XCTAssertTrue(moderatorRoles.contains { !$0.moderators.isEmpty })

    let rules = try await client.getForumRules(forumID: forumID)
    XCTAssertEqual(rules.forum.id, forumID)
    XCTAssertFalse(rules.title.isEmpty)
    XCTAssertFalse(rules.rules.isEmpty)
    XCTAssertTrue(rules.rules.contains { !$0.content.fragments.isEmpty })
  }

  private func retryingTransientLiveSearch<Value>(
    _ operationName: String,
    retryingResult shouldRetryResult: (Value) -> Bool = { _ in false },
    operation: () async throws -> Value
  ) async throws -> Value {
    var failedAttempt = 1
    while true {
      do {
        let value = try await operation()
        guard shouldRetryResult(value) else { return value }
        guard
          let delay = TiebaLiveSearchRetryPolicy.delay(
            afterTransientEmptyResult: failedAttempt
          )
        else {
          return value
        }
        print(
          "Retrying \(operationName) after a transient empty Tieba search response "
            + "(failed attempt \(failedAttempt))."
        )
        try await Task.sleep(for: delay)
        failedAttempt += 1
      } catch {
        guard
          let delay = TiebaLiveSearchRetryPolicy.delay(
            after: error,
            failedAttempt: failedAttempt
          )
        else {
          throw error
        }
        print(
          "Retrying \(operationName) after transient Tieba search failure "
            + "(failed attempt \(failedAttempt))."
        )
        try await Task.sleep(for: delay)
        failedAttempt += 1
      }
    }
  }
}
