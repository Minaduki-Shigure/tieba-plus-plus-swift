import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ThreadAuthorAvatarResolverTests: XCTestCase {
  func testMappedThreadAvatarTakesPriorityOverFloorCandidates() throws {
    let threadAvatarURL = try secureURL("thread")
    let floorAvatarURL = try secureURL("floor")
    let thread = makeThread(authorID: 7, authorAvatarURL: threadAvatarURL)
    let firstPost = makePost(
      id: 101,
      floor: 1,
      threadID: thread.id,
      authorID: thread.authorID,
      isThreadAuthor: true,
      authorPortraitURL: floorAvatarURL
    )

    XCTAssertEqual(
      ThreadAuthorAvatarResolver.resolve(thread: thread, firstPost: firstPost, posts: []),
      threadAvatarURL
    )
  }

  func testFirstPostAvatarRequiresExactThreadAuthorIdentity() throws {
    let avatarURL = try secureURL("first-floor")
    let thread = makeThread(authorID: 7)
    let firstPost = makePost(
      id: 101,
      floor: 1,
      threadID: thread.id,
      authorID: thread.authorID,
      isThreadAuthor: true,
      authorPortraitURL: avatarURL
    )

    XCTAssertEqual(
      ThreadAuthorAvatarResolver.resolve(thread: thread, firstPost: firstPost, posts: []),
      avatarURL
    )
  }

  func testRejectsMismatchedAnonymousAndUnverifiedFloorAuthors() throws {
    let avatarURL = try secureURL("untrusted")
    let thread = makeThread(authorID: 7)
    let candidates = [
      makePost(
        id: 101,
        floor: 1,
        threadID: thread.id + 1,
        authorID: thread.authorID,
        isThreadAuthor: true,
        authorPortraitURL: avatarURL
      ),
      makePost(
        id: 102,
        floor: 1,
        threadID: thread.id,
        authorID: thread.authorID + 1,
        isThreadAuthor: true,
        authorPortraitURL: avatarURL
      ),
      makePost(
        id: 103,
        floor: 1,
        threadID: thread.id,
        authorID: thread.authorID,
        isThreadAuthor: false,
        authorPortraitURL: avatarURL
      ),
      makePost(
        id: 104,
        floor: 2,
        threadID: thread.id,
        authorID: thread.authorID,
        isThreadAuthor: true,
        authorPortraitURL: avatarURL
      ),
    ]

    for candidate in candidates {
      XCTAssertNil(
        ThreadAuthorAvatarResolver.resolve(thread: thread, firstPost: candidate, posts: [])
      )
    }
    XCTAssertNil(
      ThreadAuthorAvatarResolver.resolve(
        thread: makeThread(authorID: 0),
        firstPost: candidates[0],
        posts: candidates
      )
    )
    XCTAssertNil(
      ThreadAuthorAvatarResolver.resolve(
        thread: makeThread(
          authorID: thread.authorID,
          authorAvatarURL: avatarURL,
          localVisibility: .placeholder
        ),
        firstPost: nil,
        posts: []
      )
    )

    let hiddenPost = makePost(
      id: 105,
      floor: 1,
      threadID: thread.id,
      authorID: thread.authorID,
      isThreadAuthor: true,
      authorPortraitURL: avatarURL,
      localVisibility: .hidden
    )
    XCTAssertNil(
      ThreadAuthorAvatarResolver.resolve(thread: thread, firstPost: hiddenPost, posts: [])
    )
  }

  func testFallsBackToFirstMatchingLoadedThreadAuthorPost() throws {
    let avatarURL = try secureURL("loaded-post")
    let thread = makeThread(authorID: 7)
    let wrongAuthor = makePost(
      id: 201,
      floor: 2,
      threadID: thread.id,
      authorID: 8,
      isThreadAuthor: true,
      authorPortraitURL: try secureURL("wrong-author")
    )
    let matchingAuthor = makePost(
      id: 202,
      floor: 3,
      threadID: thread.id,
      authorID: thread.authorID,
      isThreadAuthor: true,
      authorPortraitURL: avatarURL
    )

    XCTAssertEqual(
      ThreadAuthorAvatarResolver.resolve(
        thread: thread,
        firstPost: nil,
        posts: [wrongAuthor, matchingAuthor]
      ),
      avatarURL
    )
  }

  func testRejectsUnsafeMatchingFloorAvatarURL() throws {
    let unsafeURL = try XCTUnwrap(URL(string: "http://example.com/avatar.jpg"))
    let thread = makeThread(authorID: 7)
    let post = makePost(
      id: 101,
      floor: 1,
      threadID: thread.id,
      authorID: thread.authorID,
      isThreadAuthor: true,
      authorPortraitURL: unsafeURL
    )

    XCTAssertNil(
      ThreadAuthorAvatarResolver.resolve(thread: thread, firstPost: post, posts: [post])
    )
  }

  private func makeThread(
    authorID: Int64,
    authorAvatarURL: URL? = nil,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowseThread {
    BrowseThread(
      id: 42,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "Excerpt",
      authorName: "Author",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      authorID: authorID,
      authorAvatarURL: authorAvatarURL,
      localVisibility: localVisibility
    )
  }

  private func makePost(
    id: Int64,
    floor: Int,
    threadID: Int64,
    authorID: Int64,
    isThreadAuthor: Bool,
    authorPortraitURL: URL?,
    localVisibility: LocalContentVisibility = .visible
  ) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: authorID,
      authorName: "Author",
      authorPortraitURL: authorPortraitURL,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: isThreadAuthor,
      contents: [],
      localVisibility: localVisibility
    )
  }

  private func secureURL(_ token: String) throws -> URL {
    try XCTUnwrap(URL(string: "https://himg.bdimg.com/sys/portraitn/item/\(token)"))
  }
}
