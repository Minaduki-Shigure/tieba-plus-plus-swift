import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaNotificationAccountMappingTests: XCTestCase {
  func testMapsInboxUnreadSummaryAndKeepsFanCountSeparateFromInboxTotal() throws {
    let mapped = try TiebaCoreAccountService.inboxUnreadSummaryData(
      TiebaInboxUnreadSummary(userID: 7, replyCount: 3, mentionCount: 4, fanCount: 5),
      expectedUserID: 7
    )

    XCTAssertEqual(mapped.userID, 7)
    XCTAssertEqual(mapped.replyCount, 3)
    XCTAssertEqual(mapped.mentionCount, 4)
    XCTAssertEqual(mapped.fanCount, 5)
    XCTAssertEqual(mapped.totalCount, 7)
  }

  func testRejectsCrossAccountAndInvalidInboxUnreadSummaries() {
    XCTAssertThrowsError(
      try TiebaCoreAccountService.inboxUnreadSummaryData(
        TiebaInboxUnreadSummary(userID: 8, replyCount: 1, mentionCount: 2),
        expectedUserID: 7
      )
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "贴吧返回了不匹配的未读消息摘要，请重新加载后再试。"
      )
    }

    XCTAssertThrowsError(
      try TiebaCoreAccountService.inboxUnreadSummaryData(
        TiebaInboxUnreadSummary(userID: 7, replyCount: -1, mentionCount: 2),
        expectedUserID: 7
      )
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "贴吧返回了无效的未读消息计数，请重新加载后再试。"
      )
    }
  }

  func testMapsIdentityKindPageSendersAndNavigationFields() throws {
    let corePage = page(
      userID: 7,
      kind: .mentions,
      items: [
        item(
          postID: 101,
          isFloorReply: false,
          isFirstPost: true,
          quotedUser: sender(id: 9, name: "quoted")
        )
      ],
      currentPage: 2,
      hasMore: true
    )

    let mapped = try TiebaCoreAccountService.inboxPageData(
      corePage,
      expectedUserID: 7,
      expectedKind: .mentions,
      requestedPage: 2
    )

    XCTAssertEqual(mapped.userID, 7)
    XCTAssertEqual(mapped.kind, .mentions)
    XCTAssertEqual(mapped.currentPage, 2)
    XCTAssertTrue(mapped.hasMore)
    let message = try XCTUnwrap(mapped.messages.first)
    XCTAssertEqual(message.id, 101)
    XCTAssertEqual(message.threadID, 1_101)
    XCTAssertEqual(message.postID, 101)
    XCTAssertEqual(message.quotedPostID, 91)
    XCTAssertEqual(message.sender.id, 8)
    XCTAssertEqual(message.sender.preferredName, "Sender")
    XCTAssertEqual(message.quotedUser?.id, 9)
    XCTAssertEqual(
      message.sender.portraitURL?.absoluteString,
      "https://himg.bdimg.com/sys/portraitn/item/portrait-token"
    )
    XCTAssertEqual(message.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertTrue(message.isFirstPost)
    guard case .thread(let route) = message.navigationTarget else {
      return XCTFail("Expected a thread notification target")
    }
    XCTAssertEqual(route.threadID, 1_101)
    XCTAssertEqual(route.postID, 101)
  }

  func testFloorReplyRouteUsesMessagePostIDAsCommentIDAndIgnoresQuotedPostID() throws {
    let quotedPostIDs: [Int64?] = [nil, 91, 103]
    for (coreKind, inboxKind) in [
      (TiebaNotificationKind.replies, InboxKind.replies),
      (.mentions, .mentions),
    ] {
      for quotedPostID in quotedPostIDs {
        let mapped = try TiebaCoreAccountService.inboxPageData(
          page(
            userID: 7,
            kind: coreKind,
            items: [
              item(
                postID: 102,
                isFloorReply: true,
                isFirstPost: false,
                quotedPostID: quotedPostID
              )
            ],
            currentPage: 1,
            hasMore: false
          ),
          expectedUserID: 7,
          expectedKind: inboxKind,
          requestedPage: 1
        )

        let message = try XCTUnwrap(mapped.messages.first)
        guard case .comment(let threadID, let commentID) = message.navigationTarget else {
          return XCTFail("Expected a nested-reply notification target")
        }
        XCTAssertEqual(threadID, 1_102)
        XCTAssertEqual(commentID, 102)
        XCTAssertEqual(message.quotedPostID, quotedPostID)
      }
    }
  }

  func testRejectsCrossAccountKindAndPageResponses() {
    let corePage = page(
      userID: 8,
      kind: .mentions,
      items: [item(postID: 101, isFloorReply: false, isFirstPost: false)],
      currentPage: 3,
      hasMore: false
    )

    XCTAssertThrowsError(
      try TiebaCoreAccountService.inboxPageData(
        corePage,
        expectedUserID: 7,
        expectedKind: .replies,
        requestedPage: 2
      )
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "贴吧返回了不匹配的账户消息，请重新加载后再试。"
      )
    }
  }

  func testRejectsDuplicatePostIDsAndInvalidTimestamp() {
    let duplicate = item(postID: 101, isFloorReply: false, isFirstPost: false)
    XCTAssertThrowsError(
      try TiebaCoreAccountService.inboxPageData(
        page(
          userID: 7,
          kind: .replies,
          items: [duplicate, duplicate],
          currentPage: 1,
          hasMore: false
        ),
        expectedUserID: 7,
        expectedKind: .replies,
        requestedPage: 1
      )
    )

    XCTAssertThrowsError(
      try TiebaCoreAccountService.inboxPageData(
        page(
          userID: 7,
          kind: .replies,
          items: [
            item(
              postID: 102,
              isFloorReply: false,
              isFirstPost: false,
              timestamp: Int64.max
            )
          ],
          currentPage: 1,
          hasMore: false
        ),
        expectedUserID: 7,
        expectedKind: .replies,
        requestedPage: 1
      )
    ) { error in
      XCTAssertEqual(error.localizedDescription, "贴吧返回了无效的消息时间，请重新加载后再试。")
    }
  }

  private func page(
    userID: Int64,
    kind: TiebaNotificationKind,
    items: [TiebaNotificationItem],
    currentPage: Int,
    hasMore: Bool
  ) -> TiebaNotificationPage {
    TiebaNotificationPage(
      userID: userID,
      kind: kind,
      items: items,
      pagination: TiebaPagination(
        pageSize: items.count,
        currentPage: currentPage,
        totalPages: 0,
        totalCount: 0,
        hasMore: hasMore,
        hasPrevious: currentPage > 1
      )
    )
  }

  private func item(
    postID: Int64,
    isFloorReply: Bool,
    isFirstPost: Bool,
    quotedUser: TiebaNotificationSender? = nil,
    quotedPostID: Int64? = 91,
    timestamp: Int64 = 1_700_000_000
  ) -> TiebaNotificationItem {
    TiebaNotificationItem(
      sender: sender(id: 8, name: "Sender"),
      quotedUser: quotedUser,
      threadID: 1_000 + postID,
      postID: postID,
      quotedPostID: quotedPostID,
      title: "Topic",
      content: "Message",
      quotedContent: "Quoted",
      forumName: "swift",
      timestamp: timestamp,
      isFloorReply: isFloorReply,
      isFirstPost: isFirstPost,
      isUnread: true,
      threadType: 0
    )
  }

  private func sender(id: Int64, name: String) -> TiebaNotificationSender {
    TiebaNotificationSender(
      id: id,
      username: "user-\(id)",
      displayName: name,
      portrait: id == 8 ? "portrait-token" : "",
      isFriend: id == 8,
      isFan: false
    )
  }
}
