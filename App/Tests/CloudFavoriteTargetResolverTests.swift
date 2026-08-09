import Foundation
import XCTest

@testable import TiebaPlusPlus

final class CloudFavoriteTargetResolverTests: XCTestCase {
  func testResolvesExactThreadAndCanonicalForumName() async throws {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .success(cloudFavoriteIdentity(threadID: 41, forumID: 9, forumName: "swift"))
    )
    let resolver = CloudFavoriteTargetResolver(service: service)

    let target = try await resolver.resolve(
      cloudFavoriteResolverItem(threadID: 41, forumName: "  swift  ")
    )

    XCTAssertEqual(target.forumID, 9)
    XCTAssertEqual(target.forumName, "swift")
    XCTAssertEqual(target.threadID, 41)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [.init(threadID: 41, expectedForumName: "  swift  ")])
  }

  func testDeletedItemWithEmptyListForumUsesAuthoritativeThreadForum() async throws {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .success(cloudFavoriteIdentity(threadID: 42, forumID: 10, forumName: "ios"))
    )
    let resolver = CloudFavoriteTargetResolver(service: service)

    let target = try await resolver.resolve(
      cloudFavoriteResolverItem(threadID: 42, forumName: "", isDeleted: true)
    )

    XCTAssertEqual(target.forumID, 10)
    XCTAssertEqual(target.forumName, "ios")
    XCTAssertEqual(target.threadID, 42)
  }

  func testRejectsMismatchedThreadForumAndInvalidForumIdentity() async {
    let favorite = cloudFavoriteResolverItem(threadID: 43, forumName: "swift")
    let identities = [
      cloudFavoriteIdentity(threadID: 44, forumID: 9, forumName: "swift"),
      cloudFavoriteIdentity(threadID: 43, forumID: 9, forumName: "ios"),
      cloudFavoriteIdentity(threadID: 43, forumID: 0, forumName: "swift"),
      cloudFavoriteIdentity(threadID: 43, forumID: 9, forumName: ""),
    ]

    for identity in identities {
      let resolver = CloudFavoriteTargetResolver(
        service: CloudFavoriteTargetBrowseSpy(result: .success(identity))
      )
      do {
        _ = try await resolver.resolve(favorite)
        XCTFail("Expected target resolution to fail")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("没有发送删除请求"))
      }
    }
  }

  func testTransportFailureDoesNotProduceWriteTarget() async {
    let resolver = CloudFavoriteTargetResolver(
      service: CloudFavoriteTargetBrowseSpy(result: .failure(.unavailable))
    )

    do {
      _ = try await resolver.resolve(cloudFavoriteResolverItem(threadID: 45, forumName: "swift"))
      XCTFail("Expected target resolution to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("主题若已被彻底删除"))
    }
  }
}

private struct CloudFavoriteTargetRequest: Equatable, Sendable {
  let threadID: Int64
  let expectedForumName: String
}

private enum CloudFavoriteTargetBrowseError: LocalizedError, Sendable {
  case unavailable
  case unexpected

  var errorDescription: String? { "unavailable" }
}

private actor CloudFavoriteTargetBrowseSpy: BrowseService {
  private let result: Result<BrowseThreadIdentity, CloudFavoriteTargetBrowseError>
  private var requests: [CloudFavoriteTargetRequest] = []

  init(result: Result<BrowseThreadIdentity, CloudFavoriteTargetBrowseError>) {
    self.result = result
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    throw CloudFavoriteTargetBrowseError.unexpected
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    throw CloudFavoriteTargetBrowseError.unexpected
  }

  func resolveThreadIdentity(
    threadID: Int64,
    expectedForumName: String
  ) async throws -> BrowseThreadIdentity {
    requests.append(.init(threadID: threadID, expectedForumName: expectedForumName))
    return try result.get()
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    throw CloudFavoriteTargetBrowseError.unexpected
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    throw CloudFavoriteTargetBrowseError.unexpected
  }

  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData {
    throw CloudFavoriteTargetBrowseError.unexpected
  }

  func requestSnapshot() -> [CloudFavoriteTargetRequest] { requests }
}

private func cloudFavoriteIdentity(
  threadID: Int64,
  forumID: Int64,
  forumName: String
) -> BrowseThreadIdentity {
  BrowseThreadIdentity(
    threadID: threadID,
    forumID: forumID,
    forumName: forumName
  )
}

private func cloudFavoriteResolverItem(
  threadID: Int64,
  forumName: String,
  isDeleted: Bool = false
) -> CloudFavoriteThread {
  CloudFavoriteThread(
    id: threadID,
    title: "Thread \(threadID)",
    forumName: forumName,
    authorName: "author",
    markPostID: threadID + 100,
    latestPostID: threadID + 200,
    latestFloor: 2,
    hasUpdates: false,
    isDeleted: isDeleted,
    updatedAt: nil
  )
}
