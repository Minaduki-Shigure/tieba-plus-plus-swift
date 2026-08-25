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
    let forumRequests = await service.forumRequestSnapshot()
    XCTAssertTrue(forumRequests.isEmpty)
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

  func testTransportFailureFallsBackToExactForumIdentity() async throws {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .failure(.unavailable),
      forumResult: .success(BrowseForumIdentity(forumID: 19, forumName: "swift"))
    )
    let resolver = CloudFavoriteTargetResolver(service: service)

    let target = try await resolver.resolve(
      cloudFavoriteResolverItem(threadID: 46, forumName: "  swift  ")
    )
    let expectedTarget = try XCTUnwrap(
      ThreadCloudFavoriteTarget(forumID: 19, forumName: "swift", threadID: 46)
    )

    XCTAssertEqual(target, expectedTarget)
    let forumRequests = await service.forumRequestSnapshot()
    XCTAssertEqual(forumRequests, ["swift"])
  }

  func testForumFallbackRejectsMissingOrContradictoryIdentity() async {
    let favorite = cloudFavoriteResolverItem(threadID: 47, forumName: "swift")
    let identities = [
      BrowseForumIdentity(forumID: 0, forumName: "swift"),
      BrowseForumIdentity(forumID: 9, forumName: ""),
      BrowseForumIdentity(forumID: 9, forumName: "ios"),
    ]

    for identity in identities {
      let service = CloudFavoriteTargetBrowseSpy(
        result: .failure(.unavailable),
        forumResult: .success(identity)
      )
      do {
        _ = try await CloudFavoriteTargetResolver(service: service).resolve(favorite)
        XCTFail("Expected forum fallback to fail")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("没有发送删除请求"))
      }
    }
  }

  func testEmptyListForumSkipsFallbackAfterThreadFailure() async {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .failure(.unavailable),
      forumResult: .success(BrowseForumIdentity(forumID: 9, forumName: "swift"))
    )

    do {
      _ = try await CloudFavoriteTargetResolver(service: service).resolve(
        cloudFavoriteResolverItem(threadID: 48, forumName: "", isDeleted: true)
      )
      XCTFail("Expected target resolution to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("主题若已被彻底删除"))
    }

    let forumRequests = await service.forumRequestSnapshot()
    XCTAssertTrue(forumRequests.isEmpty)
  }

  func testSuccessfulButMismatchedThreadIdentityNeverUsesForumFallback() async {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .success(cloudFavoriteIdentity(threadID: 49, forumID: 9, forumName: "ios")),
      forumResult: .success(BrowseForumIdentity(forumID: 10, forumName: "swift"))
    )

    do {
      _ = try await CloudFavoriteTargetResolver(service: service).resolve(
        cloudFavoriteResolverItem(threadID: 49, forumName: "swift")
      )
      XCTFail("Expected contradictory thread identity to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("没有发送删除请求"))
    }

    let forumRequests = await service.forumRequestSnapshot()
    XCTAssertTrue(forumRequests.isEmpty)
  }

  func testRejectedWireIdentityNeverUsesForumFallback() async {
    let service = CloudFavoriteTargetBrowseSpy(
      result: .failure(.unexpected),
      forumResult: .success(BrowseForumIdentity(forumID: 10, forumName: "swift")),
      conflictsThreadRequest: true
    )

    do {
      _ = try await CloudFavoriteTargetResolver(service: service).resolve(
        cloudFavoriteResolverItem(threadID: 52, forumName: "swift")
      )
      XCTFail("Expected conflicting identity to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("相互冲突"))
    }

    let forumRequests = await service.forumRequestSnapshot()
    XCTAssertTrue(forumRequests.isEmpty)
  }

  func testCancellationPropagatesWithoutConvertingToResolutionFailure() async {
    let primaryCancellation = CloudFavoriteTargetBrowseSpy(
      result: .failure(.unexpected),
      cancelsThreadRequest: true
    )
    do {
      _ = try await CloudFavoriteTargetResolver(service: primaryCancellation).resolve(
        cloudFavoriteResolverItem(threadID: 50, forumName: "swift")
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let primaryForumRequests = await primaryCancellation.forumRequestSnapshot()
    XCTAssertTrue(primaryForumRequests.isEmpty)

    let fallbackCancellation = CloudFavoriteTargetBrowseSpy(
      result: .failure(.unavailable),
      cancelsForumRequest: true
    )
    do {
      _ = try await CloudFavoriteTargetResolver(service: fallbackCancellation).resolve(
        cloudFavoriteResolverItem(threadID: 51, forumName: "swift")
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let fallbackForumRequests = await fallbackCancellation.forumRequestSnapshot()
    XCTAssertEqual(fallbackForumRequests, ["swift"])
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
  private let forumResult: Result<BrowseForumIdentity, CloudFavoriteTargetBrowseError>
  private let conflictsThreadRequest: Bool
  private let cancelsThreadRequest: Bool
  private let cancelsForumRequest: Bool
  private var requests: [CloudFavoriteTargetRequest] = []
  private var forumRequests: [String] = []

  init(
    result: Result<BrowseThreadIdentity, CloudFavoriteTargetBrowseError>,
    forumResult: Result<BrowseForumIdentity, CloudFavoriteTargetBrowseError> = .failure(.unexpected),
    conflictsThreadRequest: Bool = false,
    cancelsThreadRequest: Bool = false,
    cancelsForumRequest: Bool = false
  ) {
    self.result = result
    self.forumResult = forumResult
    self.conflictsThreadRequest = conflictsThreadRequest
    self.cancelsThreadRequest = cancelsThreadRequest
    self.cancelsForumRequest = cancelsForumRequest
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
    if conflictsThreadRequest {
      throw BrowseIdentityResolutionError.conflictingThreadIdentity
    }
    if cancelsThreadRequest { throw CancellationError() }
    return try result.get()
  }

  func resolveForumIdentity(forumName: String) async throws -> BrowseForumIdentity {
    forumRequests.append(forumName)
    if cancelsForumRequest { throw CancellationError() }
    return try forumResult.get()
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
  func forumRequestSnapshot() -> [String] { forumRequests }
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
