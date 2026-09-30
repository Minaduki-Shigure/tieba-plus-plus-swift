import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaOwnActivityAccountServiceTests: XCTestCase {
  func testOwnThreadAndReplyPagesUseFullCredentialsAndPreserveMappedNavigation() async throws {
    let client = OwnActivityAccountClient()
    let service = TiebaCoreAccountService(client: client)
    let session = ownServiceSession()
    let threads = try await service.ownActivity(
      session: session, kind: .threads, page: 1, pageSize: 20)
    let replies = try await service.ownActivity(
      session: session, kind: .replies, page: 1, pageSize: 20)
    XCTAssertEqual(threads.accountUserID, 7)
    XCTAssertEqual(threads.threads.map(\.id), [100])
    XCTAssertEqual(threads.threads.first?.title, "private topic")
    XCTAssertTrue(threads.replies.isEmpty)
    XCTAssertEqual(replies.accountUserID, 7)
    XCTAssertEqual(replies.replies.first?.postID, 101)
    XCTAssertEqual(replies.replies.first?.target, .comment)
    XCTAssertTrue(replies.threads.isEmpty)
    let requests = await client.requests
    XCTAssertEqual(requests.map(\.kind), [.threads, .replies])
    XCTAssertTrue(
      requests.allSatisfy {
        $0.userID == 7 && $0.page == 1 && $0.pageSize == 20 && $0.hasFullCredentials
      })
  }

  func testInvalidSessionAndPaginationNeverReachCore() async throws {
    let client = OwnActivityAccountClient()
    let service = TiebaCoreAccountService(client: client)
    for (session, page, pageSize) in [
      (ownServiceSession(stoken: nil), 1, 20), (ownServiceSession(userID: 0), 1, 20),
      (ownServiceSession(), 0, 20), (ownServiceSession(), Int.max, 20),
      (ownServiceSession(), 1, 0), (ownServiceSession(), 1, 51),
    ] {
      do {
        _ = try await service.ownActivity(
          session: session, kind: .threads, page: page, pageSize: pageSize)
        XCTFail("Expected invalid authenticated activity context to be rejected")
      } catch is BrowseError {}
    }
    let requests = await client.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMismatchedCoreAccountOrPageIsRejectedForBothActivityKinds() async throws {
    for kind in OwnActivityKind.allCases {
      for (userID, page) in [(Int64(8), 1), (Int64(7), 2)] {
        let client = OwnActivityAccountClient(userID: userID, page: page)
        let service = TiebaCoreAccountService(client: client)
        do {
          _ = try await service.ownActivity(
            session: ownServiceSession(), kind: kind, page: 1, pageSize: 20)
          XCTFail("Expected mismatched core identity/page to be rejected")
        } catch is BrowseError {}
      }
    }
  }

  func testHiddenResponseRemainsHiddenWithoutAnonymousFallbackOrPersistentSnapshot() async throws {
    let client = OwnActivityAccountClient(hidden: true)
    let service = TiebaCoreAccountService(client: client)
    for kind in OwnActivityKind.allCases {
      let result = try await service.ownActivity(
        session: ownServiceSession(), kind: kind, page: 1, pageSize: 20)
      XCTAssertTrue(result.isHidden)
      XCTAssertTrue(result.threads.isEmpty)
      XCTAssertTrue(result.replies.isEmpty)
    }
    let requests = await client.requests
    XCTAssertEqual(requests.count, 2)
  }
}

private struct OwnServiceRequest: Sendable {
  let kind: OwnActivityKind
  let userID: Int64
  let page: Int
  let pageSize: Int
  let hasFullCredentials: Bool
}

private actor OwnActivityAccountClient: TiebaAuthenticatedAccountClient {
  let userID: Int64
  let page: Int
  let hidden: Bool
  private(set) var requests: [OwnServiceRequest] = []
  init(userID: Int64 = 7, page: Int = 1, hidden: Bool = false) {
    self.userID = userID
    self.page = page
    self.hidden = hidden
  }

  func getOwnThreads(
    credential: TiebaSessionCredential, expectedUserID: Int64, page: Int, pageSize: Int
  ) async throws -> TiebaUserThreadPage {
    record(
      .threads, credential: credential, expectedUserID: expectedUserID, page: page,
      pageSize: pageSize)
    let thread = TiebaThread(
      id: 100, firstPostID: 101, forumID: 8, forumName: "forum", title: "private topic",
      content: TiebaContent(fragments: []), author: nil, kind: .article, tabID: 0, viewCount: 0,
      replyCount: 0, shareCount: 0, agreeCount: 0, disagreeCount: 0, createdAt: nil,
      lastReplyAt: nil, isPinned: false, isFeatured: false, isShared: false, isHidden: false,
      isLive: false)
    return TiebaUserThreadPage(
      userID: userID, threads: hidden ? [] : [thread], pagination: pagination(pageSize),
      isHidden: hidden)
  }

  func getOwnReplies(
    credential: TiebaSessionCredential, expectedUserID: Int64, page: Int, pageSize: Int
  ) async throws -> TiebaUserReplyPage {
    record(
      .replies, credential: credential, expectedUserID: expectedUserID, page: page,
      pageSize: pageSize)
    let reply = TiebaUserReply(
      threadID: 100, forumID: 8, forumName: "forum", threadTitle: "private topic", postID: 101,
      createdAt: nil, content: TiebaContent(fragments: []), author: nil, target: .comment)
    return TiebaUserReplyPage(
      userID: userID, replies: hidden ? [] : [reply], pagination: pagination(pageSize),
      isHidden: hidden)
  }

  private func pagination(_ size: Int) -> TiebaPagination {
    TiebaPagination(
      pageSize: size, currentPage: page, totalPages: 1, totalCount: hidden ? 0 : 1, hasMore: false,
      hasPrevious: false)
  }
  private func record(
    _ kind: OwnActivityKind, credential: TiebaSessionCredential, expectedUserID: Int64, page: Int,
    pageSize: Int
  ) {
    requests.append(
      .init(
        kind: kind, userID: expectedUserID, page: page, pageSize: pageSize,
        hasFullCredentials: credential.bduss.utf8.count == 192
          && credential.stoken.utf8.count == 64))
  }

  func validateAccount(credential: TiebaBDUSSCredential) async throws -> TiebaAuthenticatedAccount {
    throw TiebaClientError.invalidAuthenticatedResponse
  }
  func getFollowedForums(credential: TiebaBDUSSCredential, userID: Int64, page: Int, pageSize: Int)
    async throws -> TiebaFollowedForumPage
  { throw TiebaClientError.invalidAuthenticatedResponse }
  func getForumMembership(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumMembership { throw TiebaClientError.invalidAuthenticatedResponse }
  func getForumAccountState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw TiebaClientError.invalidAuthenticatedResponse }
  func setForumFollowState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership { throw TiebaClientError.invalidAuthenticatedResponse }
  func checkInToForum(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64, forumName: String
  ) async throws -> TiebaForumAccountState { throw TiebaClientError.invalidAuthenticatedResponse }
}

private func ownServiceSession(
  userID: Int64 = 7, stoken: String? = String(repeating: "s", count: 64)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID, username: "user", displayName: "User", portrait: "portrait",
    bduss: String(repeating: "b", count: 192), stoken: stoken,
    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID())
}
