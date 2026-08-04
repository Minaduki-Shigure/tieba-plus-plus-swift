import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaNotificationAccountMappingTests: XCTestCase {
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
    XCTAssertEqual(message.threadRoute.threadID, 1_101)
    XCTAssertEqual(message.threadRoute.postID, 101)
  }

  func testFloorReplyRouteIgnoresQuotedAndMessagePostIDs() throws {
    let mapped = try TiebaCoreAccountService.inboxPageData(
      page(
        userID: 7,
        kind: .replies,
        items: [item(postID: 102, isFloorReply: true, isFirstPost: false)],
        currentPage: 1,
        hasMore: false
      ),
      expectedUserID: 7,
      expectedKind: .replies,
      requestedPage: 1
    )

    let route = try XCTUnwrap(mapped.messages.first).threadRoute
    XCTAssertEqual(route.threadID, 1_102)
    XCTAssertNil(route.postID)
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
    timestamp: Int64 = 1_700_000_000
  ) -> TiebaNotificationItem {
    TiebaNotificationItem(
      sender: sender(id: 8, name: "Sender"),
      quotedUser: quotedUser,
      threadID: 1_000 + postID,
      postID: postID,
      quotedPostID: 91,
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
