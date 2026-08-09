import XCTest

@testable import TiebaPlusPlus

final class CommentsReplyEntryVisibilityTests: XCTestCase {
  @MainActor
  func testHiddenIncomingReplyIntentDoesNotReadAccountVault() async throws {
    let vault = CommentsReplyEntryVaultSpy()
    let intent = try XCTUnwrap(makeCommentsReplyEntryIntent())

    let session = try await InboxReplyIntentAdmissionPolicy.activeSession(
      for: intent,
      hidesReplyEntryPoints: true,
      vault: vault
    )

    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertNil(session)
    XCTAssertEqual(activeSessionReads, 0)
  }

  @MainActor
  func testVisibleIncomingReplyIntentReadsAccountVaultOnce() async throws {
    let expectedSession = makeCommentsReplyEntrySession()
    let vault = CommentsReplyEntryVaultSpy(activeSession: expectedSession)
    let intent = try XCTUnwrap(makeCommentsReplyEntryIntent(session: expectedSession))

    let session = try await InboxReplyIntentAdmissionPolicy.activeSession(
      for: intent,
      hidesReplyEntryPoints: false,
      vault: vault
    )

    let activeSessionReads = await vault.activeSessionReadCount()
    XCTAssertEqual(session?.id, expectedSession.id)
    XCTAssertEqual(activeSessionReads, 1)
  }
}

private actor CommentsReplyEntryVaultSpy: AccountVault {
  private let storedActiveSession: StoredAccountSession?
  private var activeSessionReads = 0

  init(activeSession: StoredAccountSession? = nil) {
    storedActiveSession = activeSession
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeSessionReads += 1
    return storedActiveSession
  }

  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}

  func activeSessionReadCount() -> Int { activeSessionReads }
}

private func makeCommentsReplyEntryIntent(
  session: StoredAccountSession = makeCommentsReplyEntrySession()
) -> InboxReplyIntent? {
  InboxReplyIntent(
    message: InboxMessage(
      id: 702,
      sender: InboxSender(
        id: 9,
        username: "sender",
        displayName: "Sender",
        portraitURL: nil,
        isFriend: false,
        isFan: false
      ),
      quotedUser: nil,
      threadID: 70,
      postID: 702,
      quotedPostID: 701,
      title: "Thread",
      content: "Reply",
      quotedContent: "Parent",
      forumName: "Swift",
      createdAt: nil,
      isFloorReply: true,
      isFirstPost: false,
      isUnread: true,
      threadType: 0
    ),
    session: session
  )
}

private func makeCommentsReplyEntrySession() -> StoredAccountSession {
  StoredAccountSession(
    id: 41,
    username: "account",
    displayName: "Account",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    stoken: String(repeating: "s", count: 64),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  )
}
