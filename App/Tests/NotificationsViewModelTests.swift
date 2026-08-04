import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class NotificationsViewModelTests: XCTestCase {
  func testInitialLoadAndNextPageDeduplicateMessagesWhileAdvancingStrictly() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11, 12], page: 1, hasMore: true))
        ],
        .init(userID: 7, kind: .replies, requestedPage: 2): [
          .init(page: page(userID: 7, kind: .replies, ids: [12, 13], page: 2, hasMore: false))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.messages.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.state, .loaded)
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.messages.last))
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [11, 12, 13] }

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.requestedPage), [1, 2])
    XCTAssertEqual(requests.map(\.kind), [.replies, .replies])
  }

  func testSelectingMentionsStartsIsolatedFirstPageLoad() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: false))
        ],
        .init(userID: 7, kind: .mentions, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .mentions, ids: [21], page: 1, hasMore: false))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.select(.mentions)
    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [21] }

    XCTAssertEqual(viewModel.selectedKind, .mentions)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.kind), [.replies, .mentions])
    XCTAssertEqual(requests.map(\.requestedPage), [1, 1])
  }

  func testNewRefreshCannotBeOverwrittenByLateResponseFromOldRefresh() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: false),
            delayNanoseconds: 120_000_000
          ),
          .init(page: page(userID: 7, kind: .replies, ids: [12], page: 1, hasMore: false)),
        ]
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    let oldRefresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await service.requestCount() == 1 }
    await viewModel.refresh()
    await oldRefresh.value

    XCTAssertEqual(viewModel.messages.map(\.id), [12])
    XCTAssertEqual(viewModel.state, .loaded)
  }

  func testAccountChangeImmediatelyClearsAndLateOldAccountResponseIsDiscarded() async throws {
    let oldSession = session(userID: 7, revision: uuid(7))
    let newSession = session(userID: 8, revision: uuid(8))
    let vault = NotificationsVaultSpy(session: oldSession)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(userID: 7, kind: .replies, ids: [71], page: 1, hasMore: false),
            delayNanoseconds: 120_000_000
          )
        ],
        .init(userID: 8, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 8, kind: .replies, ids: [81], page: 1, hasMore: false))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    let oldRefresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()

    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [81] }
    await oldRefresh.value

    XCTAssertEqual(viewModel.messages.map(\.id), [81])
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [7, 8])
  }

  func testSameUserNewSessionRevisionDiscardsOldResponse() async throws {
    let oldSession = session(userID: 7, revision: uuid(7))
    let newSession = session(userID: 7, revision: uuid(8))
    let vault = NotificationsVaultSpy(session: oldSession)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(userID: 7, kind: .replies, ids: [71], page: 1, hasMore: false),
            delayNanoseconds: 120_000_000
          ),
          .init(page: page(userID: 7, kind: .replies, ids: [72], page: 1, hasMore: false)),
        ]
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    let oldRefresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await service.requestCount() == 1 }
    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [72] }
    await oldRefresh.value

    XCTAssertEqual(viewModel.messages.map(\.id), [72])
  }

  func testMismatchedNextPageDoesNotAdvanceOrReplaceExistingMessages() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: true))
        ],
        .init(userID: 7, kind: .replies, requestedPage: 2): [
          .init(page: page(userID: 7, kind: .replies, ids: [12], page: 1, hasMore: true)),
          .init(page: page(userID: 7, kind: .replies, ids: [13], page: 2, hasMore: false)),
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)
    await viewModel.refresh()

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.messages.last))
    try await waitForNotificationsTest { viewModel.loadMoreError != nil }

    XCTAssertEqual(viewModel.messages.map(\.id), [11])
    XCTAssertEqual(viewModel.loadMoreError, "贴吧返回了异常的消息页码，请重新加载后再试。")
    viewModel.retryLoadMore()
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [11, 13] }
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.requestedPage), [1, 2, 2])
  }

  func testDuplicateOnlyNextPageStopsFurtherPagination() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: true))
        ],
        .init(userID: 7, kind: .replies, requestedPage: 2): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 2, hasMore: true))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)
    await viewModel.refresh()
    let last = try XCTUnwrap(viewModel.messages.last)

    viewModel.loadMoreIfNeeded(current: last)
    try await waitForNotificationsTest {
      await service.requestCount() == 2 && !viewModel.isLoadingMore
    }
    viewModel.loadMoreIfNeeded(current: last)
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(viewModel.messages.map(\.id), [11])
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testMismatchedUserOrKindFailsInitialLoad() async {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 8, kind: .mentions, ids: [11], page: 1, hasMore: false))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    await viewModel.refresh()

    XCTAssertEqual(
      viewModel.state,
      .failed("贴吧返回了不匹配的账户消息，请重新加载后再试。")
    )
    XCTAssertTrue(viewModel.messages.isEmpty)
  }

  private func session(
    userID: Int64,
    revision: UUID = UUID()
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func page(
    userID: Int64,
    kind: InboxKind,
    ids: [Int64],
    page: Int,
    hasMore: Bool
  ) -> InboxPage {
    InboxPage(
      userID: userID,
      kind: kind,
      messages: ids.map(message),
      currentPage: page,
      hasMore: hasMore
    )
  }

  private func message(id: Int64) -> InboxMessage {
    InboxMessage(
      id: id,
      sender: InboxSender(
        id: 100 + id,
        username: "sender-\(id)",
        displayName: "Sender \(id)",
        portraitURL: nil,
        isFriend: false,
        isFan: false
      ),
      quotedUser: nil,
      threadID: 1_000 + id,
      postID: id,
      quotedPostID: nil,
      title: "Thread \(id)",
      content: "Message \(id)",
      quotedContent: "",
      forumName: "swift",
      createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
      isFloorReply: false,
      isFirstPost: false,
      isUnread: true,
      threadType: 0
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct NotificationsRequestKey: Hashable, Sendable {
  let userID: Int64
  let kind: InboxKind
  let requestedPage: Int
}

private struct NotificationsResponseScript: Sendable {
  let page: InboxPage
  let delayNanoseconds: UInt64

  init(page: InboxPage, delayNanoseconds: UInt64 = 0) {
    self.page = page
    self.delayNanoseconds = delayNanoseconds
  }
}

private struct NotificationsTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor NotificationsServiceSpy: AccountService {
  private var scripts: [NotificationsRequestKey: [NotificationsResponseScript]]
  private var requests: [NotificationsRequestKey] = []

  init(scripts: [NotificationsRequestKey: [NotificationsResponseScript]]) {
    self.scripts = scripts
  }

  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage {
    let key = NotificationsRequestKey(userID: session.id, kind: kind, requestedPage: page)
    requests.append(key)
    guard var pending = scripts[key], !pending.isEmpty else {
      throw NotificationsTestFailure(message: "Missing notification script")
    }
    let script = pending.removeFirst()
    scripts[key] = pending
    if script.delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: script.delayNanoseconds)
    }
    return script.page
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw NotificationsTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw NotificationsTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw NotificationsTestFailure(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw NotificationsTestFailure(message: "Unexpected account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw NotificationsTestFailure(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw NotificationsTestFailure(message: "Unexpected check-in")
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [NotificationsRequestKey] { requests }
}

private actor NotificationsVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? { session }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

@MainActor
private func waitForNotificationsTest(
  timeoutNanoseconds: UInt64 = 1_000_000_000,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
  while !(await condition()) {
    if ContinuousClock.now >= deadline {
      XCTFail("Timed out waiting for notification test condition")
      return
    }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
