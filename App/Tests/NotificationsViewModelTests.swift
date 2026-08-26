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
    let replyIntent = try XCTUnwrap(
      viewModel.replyIntent(for: try XCTUnwrap(viewModel.messages.first))
    )
    XCTAssertEqual(replyIntent.userID, active.id)
    XCTAssertEqual(replyIntent.sessionRevision, active.sessionRevision)
    XCTAssertEqual(replyIntent.threadID, 1_011)
    XCTAssertEqual(replyIntent.target, .post(id: 11))
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.messages.last))
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [11, 12, 13] }

    XCTAssertFalse(viewModel.isLoadingMore)
    XCTAssertNil(viewModel.loadMoreError)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.requestedPage), [1, 2])
    XCTAssertEqual(requests.map(\.kind), [.replies, .replies])
  }

  func testReplyIntentRequiresExactRetainedMessageAndLoadedSessionLease() async throws {
    let oldSession = session(userID: 7, revision: uuid(7))
    let newSession = session(userID: 8, revision: uuid(8))
    let vault = NotificationsVaultSpy(session: oldSession)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: false))
        ],
        .init(userID: 8, kind: .replies, requestedPage: 1): [
          .init(
            page: page(userID: 8, kind: .replies, ids: [81], page: 1, hasMore: false),
            delayNanoseconds: 120_000_000
          )
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)

    await viewModel.refresh()
    let retained = try XCTUnwrap(viewModel.messages.first)
    XCTAssertNotNil(viewModel.replyIntent(for: retained))
    XCTAssertNil(viewModel.replyIntent(for: message(id: 99)))

    let forgedSameID = InboxMessage(
      id: retained.id,
      sender: InboxSender(
        id: retained.sender.id + 1,
        username: "forged",
        displayName: "Forged",
        portraitURL: nil,
        isFriend: false,
        isFan: false
      ),
      quotedUser: retained.quotedUser,
      threadID: retained.threadID,
      postID: retained.postID,
      quotedPostID: retained.quotedPostID,
      title: retained.title,
      content: retained.content,
      quotedContent: retained.quotedContent,
      forumName: retained.forumName,
      createdAt: retained.createdAt,
      isFloorReply: retained.isFloorReply,
      isFirstPost: retained.isFirstPost,
      isUnread: retained.isUnread,
      threadType: retained.threadType
    )
    XCTAssertNil(viewModel.replyIntent(for: forgedSameID))

    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange()
    XCTAssertNil(viewModel.replyIntent(for: retained))
    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertEqual(viewModel.state, .loading)
    viewModel.cancel()
  }

  func testHiddenAccountChangeClearsSnapshotWithoutStartingPrivateRequest() async throws {
    let oldSession = session(userID: 7, revision: uuid(7))
    let newSession = session(userID: 8, revision: uuid(8))
    let vault = NotificationsVaultSpy(session: oldSession)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [71], page: 1, hasMore: false))
        ],
        .init(userID: 8, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 8, kind: .replies, ids: [81], page: 1, hasMore: false))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)
    await viewModel.refresh()

    await vault.replaceActive(with: newSession)
    viewModel.accountSessionDidChange(loadImmediately: false)

    XCTAssertTrue(viewModel.messages.isEmpty)
    XCTAssertEqual(viewModel.state, .idle)
    let hiddenRequestCount = await service.requestCount()
    XCTAssertEqual(hiddenRequestCount, 1)

    viewModel.loadIfNeeded()
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [81] }
    let visibleRequestCount = await service.requestCount()
    XCTAssertEqual(visibleRequestCount, 2)
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

  func testInitialRefreshResolvesBlockedSnapshotBeforePublishingMessages() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let blocked = message(id: 11, content: "blocked notification")
    let snapshot = filterSnapshot(displayMode: .placeholder, blockedKeyword: "blocked")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [.gated(snapshot)]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(
              userID: 7,
              kind: .replies,
              messages: [blocked],
              page: 1,
              hasMore: false
            )
          )
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )

    let refresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await repository.readCount() == 1 }

    XCTAssertEqual(viewModel.state, .loading)
    XCTAssertTrue(viewModel.isResolvingContentFilter)
    XCTAssertTrue(viewModel.messages.isEmpty)
    let pendingRequestCount = await service.requestCount()
    XCTAssertEqual(pendingRequestCount, 0)

    await repository.releaseNextGatedSnapshot()
    await refresh.value

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertFalse(viewModel.isResolvingContentFilter)
    XCTAssertEqual(viewModel.messages, [blocked])
    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.placeholder])
    let completedRequestCount = await service.requestCount()
    XCTAssertEqual(completedRequestCount, 1)
  }

  func testLateCancelledReplacementCannotRestoreFilterLoadingState() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let staleSnapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "Message")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .gated(staleSnapshot),
        .snapshot(.empty),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [12], page: 1, hasMore: false))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )

    let staleRefresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await repository.readCount() == 1 }
    XCTAssertTrue(viewModel.isResolvingContentFilter)

    await viewModel.refresh()
    XCTAssertEqual(viewModel.messages.map(\.id), [12])
    XCTAssertFalse(viewModel.isResolvingContentFilter)

    await repository.releaseNextGatedSnapshot()
    await staleRefresh.value

    XCTAssertEqual(viewModel.messages.map(\.id), [12])
    XCTAssertFalse(viewModel.isResolvingContentFilter)
    XCTAssertEqual(viewModel.contentFilterSnapshot, .empty)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testInitialFilterGateReadsLatestAccountBeforePrivateRequest() async throws {
    let oldSession = session(userID: 7, revision: uuid(7))
    let newSession = session(userID: 8, revision: uuid(8))
    let vault = NotificationsVaultSpy(session: oldSession)
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [.gated(.empty)]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 8, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 8, kind: .replies, ids: [81], page: 1, hasMore: false))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )

    let refresh = Task { await viewModel.refresh() }
    try await waitForNotificationsTest { await repository.readCount() == 1 }
    await vault.replaceActive(with: newSession)

    let requestCountBeforeRelease = await service.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 0)
    await repository.releaseNextGatedSnapshot()
    await refresh.value

    XCTAssertEqual(viewModel.messages.map(\.id), [81])
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [8])
  }

  func testPlaceholderAndHiddenProjectionPreserveRawPaginationTail() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let visible = message(id: 11, content: "ordinary notification")
    let blockedTail = message(id: 12, content: "blocked-tail notification")
    let placeholderSnapshot = filterSnapshot(
      displayMode: .placeholder,
      blockedKeyword: "blocked-tail"
    )
    let hiddenSnapshot = filterSnapshot(
      displayMode: .hidden,
      blockedKeyword: "blocked-tail"
    )
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(placeholderSnapshot),
        .snapshot(hiddenSnapshot),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(
              userID: 7,
              kind: .replies,
              messages: [visible, blockedTail],
              page: 1,
              hasMore: true
            )
          )
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )

    await viewModel.refresh()

    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.visible, .placeholder])
    XCTAssertEqual(viewModel.displayableMessages.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.paginationTail?.id, 12)

    viewModel.contentFilterDidChange()
    try await waitForNotificationsTest {
      await repository.readCount() == 2 && !viewModel.isResolvingContentFilter
    }

    XCTAssertEqual(viewModel.messages.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.visible, .hidden])
    XCTAssertEqual(viewModel.displayableMessages.map(\.id), [11])
    XCTAssertEqual(viewModel.paginationTail?.id, 12)
  }

  func testSenderProfileRouteRequiresVisibleMessageAndPositiveSenderID() throws {
    let message = message(id: 11, senderID: 711)
    let visible = InboxMessagePresentation(message: message, visibility: .visible)

    let route = try XCTUnwrap(NotificationSenderProfileRoute(presentation: visible))

    XCTAssertEqual(route.userID, 711)
    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      XCTAssertNil(
        NotificationSenderProfileRoute(
          presentation: InboxMessagePresentation(message: message, visibility: visibility)
        )
      )
    }
    for invalidSenderID in [Int64.zero, -1] {
      XCTAssertNil(
        NotificationSenderProfileRoute(
          presentation: InboxMessagePresentation(
            message: self.message(id: 12, senderID: invalidSenderID),
            visibility: .visible
          )
        )
      )
    }
  }

  func testSenderProfileRouteProjectionDoesNotChangePaginationOrRequests() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11, 12], page: 1, hasMore: true))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(service: service, vault: vault)
    await viewModel.refresh()
    let rawTail = try XCTUnwrap(viewModel.paginationTail)
    let messageTargets = viewModel.messages.map(\.navigationTarget)
    let requestsBeforeProjection = await service.requestsSnapshot()

    let senderRoutes = viewModel.messagePresentations.compactMap {
      NotificationSenderProfileRoute(presentation: $0)
    }
    let requestsAfterProjection = await service.requestsSnapshot()

    XCTAssertEqual(senderRoutes.map(\.userID), [111, 112])
    XCTAssertEqual(viewModel.messages.map(\.navigationTarget), messageTargets)
    XCTAssertEqual(viewModel.paginationTail, rawTail)
    XCTAssertEqual(requestsAfterProjection, requestsBeforeProjection)
  }

  func testAllHiddenInitialPageWaitsForExplicitContinuationBeforeLoadingNextPage() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let snapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "Message")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [.snapshot(snapshot)]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11, 12], page: 1, hasMore: true))
        ],
        .init(userID: 7, kind: .replies, requestedPage: 2): [
          .init(page: page(userID: 7, kind: .replies, ids: [13], page: 2, hasMore: false))
        ],
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )

    await viewModel.refresh()

    XCTAssertTrue(viewModel.displayableMessages.isEmpty)
    XCTAssertTrue(viewModel.requiresExplicitPagination)
    XCTAssertEqual(viewModel.paginationTail?.id, 12)
    let initialRequestCount = await service.requestCount()
    XCTAssertEqual(initialRequestCount, 1)

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.paginationTail))
    for _ in 0..<20 { await Task.yield() }
    let requestCountAfterAutomaticAttempt = await service.requestCount()
    XCTAssertEqual(requestCountAfterAutomaticAttempt, 1)

    viewModel.continuePagination()
    try await waitForNotificationsTest { viewModel.messages.map(\.id) == [11, 12, 13] }

    XCTAssertTrue(viewModel.displayableMessages.isEmpty)
    XCTAssertFalse(viewModel.requiresExplicitPagination)
    let requests = await service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.requestedPage), [1, 2])
  }

  func testFilterChangeOnlyReprojectsAndPausesAutomaticPagination() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let changedSnapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "Message 12")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(.empty),
        .snapshot(changedSnapshot),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11, 12], page: 1, hasMore: true))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )
    await viewModel.refresh()
    let rawTail = try XCTUnwrap(viewModel.paginationTail)

    viewModel.contentFilterDidChange()
    try await waitForNotificationsTest {
      await repository.readCount() == 2 && !viewModel.isResolvingContentFilter
    }

    XCTAssertEqual(viewModel.messages.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.displayableMessages.map(\.id), [11])
    XCTAssertEqual(viewModel.paginationTail, rawTail)
    XCTAssertTrue(viewModel.pausesAutomaticPagination)
    XCTAssertTrue(viewModel.requiresExplicitPagination)
    let requestCountAfterReprojection = await service.requestCount()
    XCTAssertEqual(requestCountAfterReprojection, 1)

    viewModel.loadMoreIfNeeded(current: rawTail)
    for _ in 0..<20 { await Task.yield() }

    let requestCountAfterAutomaticAttempt = await service.requestCount()
    XCTAssertEqual(requestCountAfterAutomaticAttempt, 1)
  }

  func testReentryPausesPaginationOnlyWhenRereadSnapshotChanged() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let changedSnapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "Message 12")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(.empty),
        .snapshot(changedSnapshot),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11, 12], page: 1, hasMore: true))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )
    await viewModel.refresh()

    viewModel.loadIfNeeded()
    try await waitForNotificationsTest {
      await repository.readCount() == 2 && !viewModel.isResolvingContentFilter
    }

    XCTAssertEqual(viewModel.messages.map(\.id), [11, 12])
    XCTAssertEqual(viewModel.displayableMessages.map(\.id), [11])
    XCTAssertTrue(viewModel.pausesAutomaticPagination)
    XCTAssertTrue(viewModel.requiresExplicitPagination)
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.paginationTail))
    for _ in 0..<20 { await Task.yield() }
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testReentryWithUnchangedSnapshotKeepsAutomaticPaginationEnabled() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(.empty),
        .snapshot(.empty),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: true))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )
    await viewModel.refresh()

    viewModel.loadIfNeeded()
    try await waitForNotificationsTest {
      await repository.readCount() == 2 && !viewModel.isResolvingContentFilter
    }

    XCTAssertFalse(viewModel.pausesAutomaticPagination)
    XCTAssertFalse(viewModel.requiresExplicitPagination)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testPlaceholderAndHiddenMessagesCannotCreateReplyIntent() async throws {
    let active = session(userID: 7)
    let blocked = message(id: 11, content: "blocked notification")

    for displayMode in [ContentFilterDisplayMode.placeholder, .hidden] {
      let vault = NotificationsVaultSpy(session: active)
      let snapshot = filterSnapshot(displayMode: displayMode, blockedKeyword: "blocked")
      let repository = NotificationsContentFilterRepositorySpy(
        scripts: [.snapshot(snapshot)]
      )
      let service = NotificationsServiceSpy(
        scripts: [
          .init(userID: 7, kind: .replies, requestedPage: 1): [
            .init(
              page: page(
                userID: 7,
                kind: .replies,
                messages: [blocked],
                page: 1,
                hasMore: false
              )
            )
          ]
        ]
      )
      let viewModel = NotificationsViewModel(
        service: service,
        vault: vault,
        contentFilterRepository: repository
      )

      await viewModel.refresh()

      XCTAssertEqual(viewModel.messagePresentations.first?.visibility, displayMode.visibility)
      XCTAssertNil(viewModel.replyIntent(for: blocked))
    }
  }

  func testSnapshotReadFailurePreservesLastKnownGoodProjection() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let snapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "blocked")
    let blocked = message(id: 11, content: "blocked notification")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(snapshot),
        .failure,
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(
            page: page(
              userID: 7,
              kind: .replies,
              messages: [blocked],
              page: 1,
              hasMore: false
            )
          )
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )
    await viewModel.refresh()

    viewModel.contentFilterDidChange()
    try await waitForNotificationsTest {
      await repository.readCount() == 2 && !viewModel.isResolvingContentFilter
    }

    XCTAssertEqual(viewModel.contentFilterSnapshot, snapshot)
    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.hidden])
    XCTAssertTrue(viewModel.displayableMessages.isEmpty)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testLateRuleSnapshotCannotOverwriteNewerProjection() async throws {
    let active = session(userID: 7)
    let vault = NotificationsVaultSpy(session: active)
    let staleSnapshot = filterSnapshot(displayMode: .hidden, blockedKeyword: "Message")
    let newestSnapshot = filterSnapshot(displayMode: .placeholder, blockedKeyword: "Message 11")
    let repository = NotificationsContentFilterRepositorySpy(
      scripts: [
        .snapshot(.empty),
        .gated(staleSnapshot),
        .snapshot(newestSnapshot),
      ]
    )
    let service = NotificationsServiceSpy(
      scripts: [
        .init(userID: 7, kind: .replies, requestedPage: 1): [
          .init(page: page(userID: 7, kind: .replies, ids: [11], page: 1, hasMore: false))
        ]
      ]
    )
    let viewModel = NotificationsViewModel(
      service: service,
      vault: vault,
      contentFilterRepository: repository
    )
    await viewModel.refresh()

    viewModel.contentFilterDidChange()
    try await waitForNotificationsTest { await repository.readCount() == 2 }
    viewModel.contentFilterDidChange()
    try await waitForNotificationsTest {
      await repository.readCount() == 3 && !viewModel.isResolvingContentFilter
    }

    XCTAssertEqual(viewModel.contentFilterSnapshot, newestSnapshot)
    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.placeholder])
    await repository.releaseNextGatedSnapshot()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(viewModel.contentFilterSnapshot, newestSnapshot)
    XCTAssertEqual(viewModel.messagePresentations.map(\.visibility), [.placeholder])
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testHiddenPreferenceCancelsPendingReplyRoute() throws {
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(id: 11),
        userID: 7,
        sessionRevision: uuid(7)
      )
    )
    var route = NotificationsReplyRouteState()

    route.present(intent)

    XCTAssertTrue(route.isPresented)
    XCTAssertFalse(route.isEstablished)
    XCTAssertTrue(route.cancelPending())
    XCTAssertFalse(route.isPresented)
    XCTAssertNil(route.intent)
  }

  func testHiddenPreferencePreservesEstablishedReplyRouteUntilDismissed() throws {
    let intent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(id: 11),
        userID: 7,
        sessionRevision: uuid(7)
      )
    )
    var route = NotificationsReplyRouteState()
    route.present(intent)
    route.markEstablished(intent)

    XCTAssertFalse(route.cancelPending())
    XCTAssertEqual(route.intent, intent)
    XCTAssertTrue(route.isEstablished)

    route.dismiss()

    XCTAssertFalse(route.isPresented)
    XCTAssertFalse(route.isEstablished)
  }

  func testStaleDestinationCannotEstablishReplacementReplyRoute() throws {
    let staleIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(id: 11),
        userID: 7,
        sessionRevision: uuid(7)
      )
    )
    let currentIntent = try XCTUnwrap(
      InboxReplyIntent(
        message: message(id: 12),
        userID: 7,
        sessionRevision: uuid(7)
      )
    )
    var route = NotificationsReplyRouteState()
    route.present(staleIntent)
    route.present(currentIntent)

    route.markEstablished(staleIntent)

    XCTAssertEqual(route.intent, currentIntent)
    XCTAssertFalse(route.isEstablished)
    XCTAssertTrue(route.cancelPending())
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
    page pageNumber: Int,
    hasMore: Bool
  ) -> InboxPage {
    page(
      userID: userID,
      kind: kind,
      messages: ids.map { message(id: $0) },
      page: pageNumber,
      hasMore: hasMore
    )
  }

  private func page(
    userID: Int64,
    kind: InboxKind,
    messages: [InboxMessage],
    page: Int,
    hasMore: Bool
  ) -> InboxPage {
    InboxPage(
      userID: userID,
      kind: kind,
      messages: messages,
      currentPage: page,
      hasMore: hasMore
    )
  }

  private func message(
    id: Int64,
    content: String? = nil,
    senderID: Int64? = nil,
    senderUsername: String? = nil,
    senderDisplayName: String? = nil
  ) -> InboxMessage {
    InboxMessage(
      id: id,
      sender: InboxSender(
        id: senderID ?? 100 + id,
        username: senderUsername ?? "sender-\(id)",
        displayName: senderDisplayName ?? "Sender \(id)",
        portraitURL: nil,
        isFriend: false,
        isFan: false
      ),
      quotedUser: nil,
      threadID: 1_000 + id,
      postID: id,
      quotedPostID: nil,
      title: "Thread \(id)",
      content: content ?? "Message \(id)",
      quotedContent: "",
      forumName: "swift",
      createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
      isFloorReply: false,
      isFirstPost: false,
      isUnread: true,
      threadType: 0
    )
  }

  private func filterSnapshot(
    displayMode: ContentFilterDisplayMode,
    blockedKeyword: String
  ) -> ContentFilterSnapshot {
    ContentFilterSnapshot(
      displayMode: displayMode,
      blockVideos: false,
      rules: [.keyword(blockedKeyword, list: .block)]
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

private extension ContentFilterDisplayMode {
  var visibility: LocalContentVisibility {
    switch self {
    case .placeholder:
      .placeholder
    case .hidden:
      .hidden
    }
  }
}

private enum NotificationsContentFilterScript: Sendable {
  case snapshot(ContentFilterSnapshot)
  case gated(ContentFilterSnapshot)
  case failure
}

private actor NotificationsContentFilterRepositorySpy: ContentFilterRepository {
  private var scripts: [NotificationsContentFilterScript]
  private var gatedSnapshots: [(
    ContentFilterSnapshot,
    CheckedContinuation<ContentFilterSnapshot, Never>
  )] = []
  private var reads = 0

  init(scripts: [NotificationsContentFilterScript]) {
    self.scripts = scripts
  }

  func snapshot() async throws -> ContentFilterSnapshot {
    reads += 1
    guard !scripts.isEmpty else {
      throw NotificationsTestFailure(message: "Missing content filter script")
    }
    let script = scripts.removeFirst()
    switch script {
    case .snapshot(let snapshot):
      return snapshot
    case .gated(let snapshot):
      return await withCheckedContinuation { continuation in
        gatedSnapshots.append((snapshot, continuation))
      }
    case .failure:
      throw NotificationsTestFailure(message: "Content filter read failed")
    }
  }

  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func delete(id: UUID) async throws {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func deleteAll(in list: ContentFilterList) async throws {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func setBlockVideos(_ blockVideos: Bool) async throws {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func reset() async throws {
    throw NotificationsTestFailure(message: "Unexpected content filter mutation")
  }

  func readCount() -> Int { reads }

  func releaseNextGatedSnapshot() {
    guard !gatedSnapshots.isEmpty else { return }
    let (snapshot, continuation) = gatedSnapshots.removeFirst()
    continuation.resume(returning: snapshot)
  }
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
