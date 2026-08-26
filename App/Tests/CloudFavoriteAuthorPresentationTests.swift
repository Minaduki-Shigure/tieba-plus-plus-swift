import Foundation
import XCTest

@testable import TiebaPlusPlus

final class CloudFavoriteAuthorPresentationTests: XCTestCase {
  func testPositiveAuthorIDCreatesExactProfileRouteAndPreservesIdentity() throws {
    let portraitURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/author-token")
    )
    let author = CloudFavoriteAuthor(
      userID: 42,
      username: "author-account",
      displayName: "作者昵称",
      portraitURL: portraitURL
    )
    let thread = cloudFavoriteAuthorThread(author: author)
    let interactions = CloudFavoriteRowInteractionPolicy(
      thread: thread,
      overrides: FavoriteThreadOpenOverrides()
    )

    XCTAssertEqual(author.userID, 42)
    XCTAssertEqual(author.username, "author-account")
    XCTAssertEqual(author.displayName, "作者昵称")
    XCTAssertEqual(author.portraitURL, portraitURL)
    XCTAssertEqual(interactions.authorRoute, CloudFavoriteAuthorProfileRoute(userID: 42))
    XCTAssertNotNil(interactions.threadNavigation)

    let preferredOnly = CloudFavoriteAuthorPresentation(
      thread: thread,
      showsBothNames: false
    )
    XCTAssertEqual(preferredOnly.displayName, "作者昵称")
    XCTAssertEqual(preferredOnly.portraitURL, portraitURL)
    XCTAssertTrue(preferredOnly.isVisible)

    let bothNames = CloudFavoriteAuthorPresentation(
      thread: thread,
      showsBothNames: true
    )
    XCTAssertEqual(bothNames.displayName, "作者昵称(author-account)")
    XCTAssertEqual(bothNames.profileAccessibilityLabel, "查看 作者昵称(author-account) 的主页")
  }

  func testProfileRouteRejectsMissingAndNonpositiveAuthorIDs() {
    let invalidUserIDs: [Int64?] = [nil, 0, -1]
    for userID in invalidUserIDs {
      let author = CloudFavoriteAuthor(
        userID: userID,
        username: "author-account",
        displayName: "作者昵称",
        portraitURL: nil
      )
      let thread = cloudFavoriteAuthorThread(author: author)
      let presentation = CloudFavoriteAuthorPresentation(
        thread: thread,
        showsBothNames: false
      )
      let interactions = CloudFavoriteRowInteractionPolicy(
        thread: thread,
        overrides: FavoriteThreadOpenOverrides()
      )

      XCTAssertNil(author.userID)
      XCTAssertNil(CloudFavoriteAuthorProfileRoute(userID: userID))
      XCTAssertNil(thread.authorProfileRoute)
      XCTAssertNil(interactions.authorRoute)
      XCTAssertNotNil(interactions.threadNavigation)
      XCTAssertTrue(presentation.isVisible)
      XCTAssertEqual(presentation.displayName, "作者昵称")
    }
  }

  func testNameAndPortraitCannotInventAProfileRoute() throws {
    let portraitURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/author-token")
    )
    let first = CloudFavoriteAuthor(
      userID: nil,
      username: "account-a",
      displayName: "昵称 A",
      portraitURL: portraitURL
    )
    let second = CloudFavoriteAuthor(
      userID: nil,
      username: "account-b",
      displayName: "昵称 B",
      portraitURL: nil
    )

    XCTAssertNil(cloudFavoriteAuthorThread(author: first).authorProfileRoute)
    XCTAssertNil(cloudFavoriteAuthorThread(author: second).authorProfileRoute)
  }

  func testAuthorIdentityDoesNotChangeThreadNavigation() throws {
    let first = cloudFavoriteAuthorThread(
      author: CloudFavoriteAuthor(
        userID: 7,
        username: "first-account",
        displayName: "第一位作者",
        portraitURL: try XCTUnwrap(URL(string: "https://example.com/first.png"))
      )
    )
    let second = cloudFavoriteAuthorThread(
      author: CloudFavoriteAuthor(
        userID: 8,
        username: "second-account",
        displayName: "第二位作者",
        portraitURL: try XCTUnwrap(URL(string: "https://example.com/second.png"))
      )
    )
    let overrides = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    )

    let firstInteractions = CloudFavoriteRowInteractionPolicy(
      thread: first,
      overrides: overrides
    )
    let secondInteractions = CloudFavoriteRowInteractionPolicy(
      thread: second,
      overrides: overrides
    )

    XCTAssertNotEqual(firstInteractions.authorRoute, secondInteractions.authorRoute)
    XCTAssertEqual(firstInteractions.threadNavigation, secondInteractions.threadNavigation)
  }

  func testDeletedThreadRetainsAuthorRouteAndEmptyIdentityDegradesSafely() {
    let deleted = cloudFavoriteAuthorThread(
      author: CloudFavoriteAuthor(
        userID: 77,
        username: "",
        displayName: "",
        portraitURL: nil
      ),
      isDeleted: true
    )
    let deletedPresentation = CloudFavoriteAuthorPresentation(
      thread: deleted,
      showsBothNames: true
    )
    let deletedInteractions = CloudFavoriteRowInteractionPolicy(
      thread: deleted,
      overrides: FavoriteThreadOpenOverrides()
    )

    XCTAssertTrue(deleted.isDeleted)
    XCTAssertEqual(deletedInteractions.authorRoute?.userID, 77)
    XCTAssertNil(deletedInteractions.threadNavigation)
    XCTAssertEqual(deletedPresentation.displayName, "贴吧用户")
    XCTAssertTrue(deletedPresentation.isVisible)

    let missing = cloudFavoriteAuthorThread(
      author: CloudFavoriteAuthor(
        userID: nil,
        username: "",
        displayName: "",
        portraitURL: nil
      )
    )
    let missingPresentation = CloudFavoriteAuthorPresentation(
      thread: missing,
      showsBothNames: true
    )
    let missingInteractions = CloudFavoriteRowInteractionPolicy(
      thread: missing,
      overrides: FavoriteThreadOpenOverrides()
    )
    XCTAssertFalse(missingPresentation.isVisible)
    XCTAssertNil(missingInteractions.authorRoute)
    XCTAssertNotNil(missingInteractions.threadNavigation)
  }
}

private func cloudFavoriteAuthorThread(
  author: CloudFavoriteAuthor,
  isDeleted: Bool = false
) -> CloudFavoriteThread {
  CloudFavoriteThread(
    id: 100,
    title: "收藏主题",
    forumName: "swift",
    author: author,
    markPostID: 101,
    latestPostID: 102,
    latestFloor: 3,
    hasUpdates: true,
    isDeleted: isDeleted,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}
