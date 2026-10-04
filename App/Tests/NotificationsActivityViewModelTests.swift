import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class NotificationsActivityViewModelTests: XCTestCase {
  func testInactivePagesCannotReadEvenThroughRefreshRetryOrPagination() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model

    model.select(.mentions)
    model.contentFilterDidChange()
    model.accountSessionDidChange()
    for kind in InboxKind.allCases {
      let page = model.model(for: kind)
      page.reload()
      await page.refresh()
      page.retryLoadMore()
      page.continuePagination()
      page.loadMoreIfNeeded(current: inboxActivityMessage(11))
      await model.refresh(kind: kind)
      XCTAssertFalse(page.isActive)
    }
    await inboxActivityDrain()
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertTrue(requests.isEmpty)

    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    XCTAssertTrue(model.repliesModel.messages.isEmpty)
    let activeRequests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(activeRequests.map(\.kind), [.mentions])
  }

  func testChannelsKeepIndependentPagesAndCacheActivationDoesNotReadAgain() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    model.repliesModel.loadMoreIfNeeded(current: try XCTUnwrap(model.repliesModel.paginationTail))
    try await fixture.waitForRequestCount(2)
    await fixture.service.succeed(1, ids: [12], hasMore: true)
    try await inboxActivityWait { model.repliesModel.messages.count == 2 }

    model.select(.mentions)
    try await fixture.waitForRequestCount(3)
    await fixture.service.succeed(2, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    model.select(.replies)
    XCTAssertTrue(model.repliesModel.isResolvingSession)
    XCTAssertNil(model.repliesModel.replyIntent(for: inboxActivityMessage(11)))
    try await fixture.waitForLoaded(.replies)
    XCTAssertEqual(model.repliesModel.messages.map(\.id), [11, 12])
    XCTAssertEqual(model.mentionsModel.messages.map(\.id), [21])
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 1])
    XCTAssertEqual(requests.map(\.kind), [.replies, .replies, .mentions])
    XCTAssertEqual(
      fixture.callbackRevisions, [fixture.session.sessionRevision, fixture.session.sessionRevision])

    model.repliesModel.loadMoreIfNeeded(current: try XCTUnwrap(model.repliesModel.paginationTail))
    try await fixture.waitForRequestCount(4)
    await fixture.service.succeed(3, ids: [13])
    try await inboxActivityWait { model.repliesModel.messages.map(\.id) == [11, 12, 13] }
    let lastRequest = await fixture.service.requestsSnapshot().last
    XCTAssertEqual(lastRequest?.page, 3)
  }

  func testCancelledInitialResponseCannotPublishOrClearItsReplacementTask() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    model.select(.mentions)
    XCTAssertEqual(model.repliesModel.state, .idle)
    try await fixture.waitForRequestCount(2)
    await fixture.service.succeed(1, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    model.select(.replies)
    try await fixture.waitForRequestCount(3)

    await fixture.service.succeed(0, ids: [99])
    await inboxActivityDrain()
    XCTAssertTrue(model.repliesModel.messages.isEmpty)
    XCTAssertEqual(model.repliesModel.state, .loading)
    let waiter = Task { await model.refresh(kind: .replies) }
    await inboxActivityDrain()
    let requestCount = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(requestCount, 3)
    await fixture.service.succeed(2, ids: [11])
    try await fixture.waitForLoaded(.replies)
    await waiter.value
    XCTAssertEqual(model.repliesModel.messages.map(\.id), [11])
    XCTAssertEqual(fixture.callbackRevisions.count, 2)
  }

  func testCancelledPaginationRestoresFailureAndRetriesTheSameCursor() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    let replies = model.repliesModel
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    replies.loadMoreIfNeeded(current: try XCTUnwrap(replies.paginationTail))
    try await fixture.waitForRequestCount(2)
    await fixture.service.fail(1, message: "page two failed")
    try await inboxActivityWait { replies.loadMoreError == "page two failed" }
    replies.retryLoadMore()
    try await fixture.waitForRequestCount(3)
    model.select(.mentions)
    XCTAssertEqual(replies.loadMoreError, "page two failed")
    XCTAssertEqual(replies.messages.map(\.id), [11])
    try await fixture.waitForRequestCount(4)
    await fixture.service.succeed(3, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    await fixture.service.succeed(2, ids: [99])
    model.select(.replies)
    try await fixture.waitForLoaded(.replies)
    replies.loadMoreIfNeeded(current: try XCTUnwrap(replies.paginationTail))
    await inboxActivityDrain()
    let countBeforeRetry = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(countBeforeRetry, 4)
    replies.retryLoadMore()
    try await fixture.waitForRequestCount(5)
    await fixture.service.succeed(4, ids: [12])
    try await inboxActivityWait { replies.messages.map(\.id) == [11, 12] }
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 2, 1, 2])
    XCTAssertNil(replies.loadMoreError)
  }

  func testBusyRefreshesJoinAndFailurePreservesSnapshotCursorAndPagingError() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    let replies = model.repliesModel
    model.activate()
    let initialWaiter = Task { await model.refresh(kind: .replies) }
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    await initialWaiter.value
    replies.loadMoreIfNeeded(current: try XCTUnwrap(replies.paginationTail))
    try await fixture.waitForRequestCount(2)
    let paginationWaiter = Task { await model.refresh(kind: .replies) }
    await inboxActivityDrain()
    await fixture.service.fail(1, message: "page two failed")
    try await inboxActivityWait { replies.loadMoreError == "page two failed" }
    await paginationWaiter.value

    let first = Task { await model.refresh(kind: .replies) }
    try await fixture.waitForRequestCount(3)
    let second = Task { await model.refresh(kind: .replies) }
    first.cancel()
    await inboxActivityDrain()
    XCTAssertEqual(replies.messages.map(\.id), [11])
    let busyCount = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(busyCount, 3)
    await fixture.service.fail(2, message: "refresh failed")
    try await inboxActivityWait { replies.refreshError == "refresh failed" }
    await first.value
    await second.value
    XCTAssertEqual(replies.state, .loaded)
    XCTAssertEqual(replies.messages.map(\.id), [11])
    XCTAssertEqual(replies.loadMoreError, "page two failed")
    XCTAssertTrue(replies.hasNextPage)
    replies.clearRefreshError()
    XCTAssertNil(replies.refreshError)
    replies.retryLoadMore()
    try await fixture.waitForRequestCount(4)
    await fixture.service.succeed(3, ids: [12])
    try await inboxActivityWait { replies.messages.map(\.id) == [11, 12] }
    let next = Task { await model.refresh(kind: .replies) }
    try await fixture.waitForRequestCount(5)
    await fixture.service.succeed(4, ids: [13])
    try await inboxActivityWait { replies.messages.map(\.id) == [13] }
    await next.value
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2, 1, 2, 1])
    XCTAssertEqual(fixture.callbackRevisions.count, 2)
  }

  func testAccountChangeClearsBothChannelsSynchronouslyAndLoadsOnlyCurrentKind() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11])
    try await fixture.waitForLoaded(.replies)
    model.select(.mentions)
    try await fixture.waitForRequestCount(2)
    await fixture.service.succeed(1, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    let refresh = Task { await model.refresh(kind: .mentions) }
    try await fixture.waitForRequestCount(3)

    let replacement = inboxActivitySession()
    await fixture.vault.replaceActive(with: replacement)
    let oldReplyEpoch = model.repliesModel.paginationEpoch
    let oldMentionEpoch = model.mentionsModel.paginationEpoch
    model.accountSessionDidChange()
    XCTAssertTrue(model.repliesModel.messages.isEmpty)
    XCTAssertTrue(model.mentionsModel.messages.isEmpty)
    XCTAssertEqual(model.repliesModel.state, .idle)
    XCTAssertGreaterThan(model.repliesModel.paginationEpoch, oldReplyEpoch)
    XCTAssertGreaterThan(model.mentionsModel.paginationEpoch, oldMentionEpoch)
    try await fixture.waitForRequestCount(4)
    await fixture.service.succeed(2, ids: [99])
    await inboxActivityDrain()
    XCTAssertTrue(model.mentionsModel.messages.isEmpty)
    await fixture.service.succeed(3, ids: [22])
    try await fixture.waitForLoaded(.mentions)
    await refresh.value
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.kind), [.replies, .mentions, .mentions, .mentions])
    XCTAssertEqual(requests.last?.revision, replacement.sessionRevision)
    XCTAssertEqual(fixture.callbackRevisions.last, replacement.sessionRevision)
    XCTAssertEqual(fixture.callbackRevisions.count, 3)

    model.deactivate()
    await fixture.vault.replaceActive(with: nil)
    model.accountSessionDidChange()
    XCTAssertTrue(model.mentionsModel.messages.isEmpty)
    await inboxActivityDrain()
    let hiddenCount = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(hiddenCount, 4)
  }

  func testUnannouncedSameUserRotationIsGatedBeforeCachedActivationReadsReplacement() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11])
    try await fixture.waitForLoaded(.replies)
    model.deactivate()
    let replacement = inboxActivitySession()
    await fixture.vault.replaceActive(with: replacement)
    model.activate()
    XCTAssertTrue(model.repliesModel.isResolvingSession)
    XCTAssertNil(model.repliesModel.replyIntent(for: inboxActivityMessage(11)))
    try await fixture.waitForRequestCount(2)
    XCTAssertTrue(model.repliesModel.messages.isEmpty)
    await fixture.service.succeed(1, ids: [12])
    try await fixture.waitForLoaded(.replies)
    XCTAssertEqual(model.repliesModel.messages.map(\.id), [12])
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(
      requests.map(\.revision), [fixture.session.sessionRevision, replacement.sessionRevision])
    XCTAssertEqual(
      fixture.callbackRevisions, [fixture.session.sessionRevision, replacement.sessionRevision])
  }

  func testRefreshFailureAfterUnannouncedRotationCannotKeepTheOldAccountSnapshot() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11])
    try await fixture.waitForLoaded(.replies)
    let refresh = Task { await model.refresh(kind: .replies) }
    try await fixture.waitForRequestCount(2)
    await fixture.vault.replaceActive(with: inboxActivitySession())
    await fixture.service.fail(1, message: "old account failure")
    try await inboxActivityWait { model.repliesModel.messages.isEmpty }
    await refresh.value
    XCTAssertEqual(model.repliesModel.state, .idle)
    XCTAssertNil(model.repliesModel.refreshError)
    XCTAssertEqual(fixture.callbackRevisions.count, 1)
  }

  func testCacheActivationRechecksLeaseAfterSuspendedLocalFilterRead() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    model.deactivate()
    await fixture.filters.holdNextRead()
    model.activate()
    try await inboxActivityWait { await fixture.filters.hasPendingRead() }
    XCTAssertTrue(model.repliesModel.isResolvingSession)
    XCTAssertTrue(model.repliesModel.isResolvingContentFilter)
    model.repliesModel.loadMoreIfNeeded(current: try XCTUnwrap(model.repliesModel.paginationTail))
    await fixture.vault.replaceActive(with: inboxActivitySession())
    await fixture.filters.releaseRead()
    try await fixture.waitForRequestCount(2)
    XCTAssertTrue(model.repliesModel.messages.isEmpty)
    await fixture.service.succeed(1, ids: [12])
    try await fixture.waitForLoaded(.replies)
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1])
    XCTAssertNotEqual(requests[0].revision, requests[1].revision)
  }

  func testLocalFilterChangeOnCachedReentryPreservesRawCursorAndRequiresContinuation() async throws
  {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11, 12], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    model.deactivate()
    await fixture.filters.replace(
      with: ContentFilterSnapshot(
        displayMode: .hidden, blockVideos: false, rules: [.keyword("Message 12", list: .block)]
      ))
    model.activate()
    try await fixture.waitForLoaded(.replies)
    XCTAssertEqual(model.repliesModel.displayableMessages.map(\.id), [11])
    XCTAssertEqual(model.repliesModel.paginationTail?.id, 12)
    XCTAssertTrue(model.repliesModel.requiresExplicitPagination)
    model.repliesModel.loadMoreIfNeeded(current: try XCTUnwrap(model.repliesModel.paginationTail))
    await inboxActivityDrain()
    let countBeforeContinue = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(countBeforeContinue, 1)
    model.repliesModel.continuePagination()
    try await fixture.waitForRequestCount(2)
    await fixture.service.succeed(1, ids: [13])
    try await inboxActivityWait { model.repliesModel.messages.count == 3 }
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 2])
  }

  func testAllHiddenPageAndInactiveRawTailRequireVisibleExplicitContinuation() async throws {
    let fixture = InboxActivityFixture(
      filter: ContentFilterSnapshot(
        displayMode: .hidden, blockVideos: false,
        rules: [.keyword("Message", list: .block)]
      )
    )
    defer { fixture.cleanup() }
    let model = fixture.model
    let replies = model.repliesModel
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.succeed(0, ids: [11], hasMore: true)
    try await fixture.waitForLoaded(.replies)
    XCTAssertTrue(replies.displayableMessages.isEmpty)
    XCTAssertTrue(replies.requiresExplicitPagination)
    replies.loadMoreIfNeeded(current: try XCTUnwrap(replies.paginationTail))
    model.select(.mentions)
    try await fixture.waitForRequestCount(2)
    replies.continuePagination()
    replies.reload()
    await replies.refresh()
    await fixture.service.succeed(1, ids: [21])
    try await fixture.waitForLoaded(.mentions)
    model.select(.replies)
    XCTAssertTrue(replies.isResolvingSession)
    replies.continuePagination()
    try await fixture.waitForLoaded(.replies)
    XCTAssertTrue(replies.requiresExplicitPagination)
    replies.loadMoreIfNeeded(current: try XCTUnwrap(replies.paginationTail))
    await inboxActivityDrain()
    let countBeforeContinue = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(countBeforeContinue, 2)
    replies.continuePagination()
    try await fixture.waitForRequestCount(3)
    await fixture.service.succeed(2, ids: [12])
    try await inboxActivityWait { replies.messages.map(\.id) == [11, 12] }
    let requests = await fixture.service.requestsSnapshot()
    XCTAssertEqual(requests.map(\.page), [1, 1, 2])
  }

  func testCancelledActivationAndFailedFirstPageRemainRetryableWithoutHiddenReads() async throws {
    let fixture = InboxActivityFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      model.activate()
      await model.refresh(kind: .replies)
    }
    await cancelled.value
    XCTAssertFalse(model.isActive)
    let initialCount = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(initialCount, 0)
    model.activate()
    try await fixture.waitForRequestCount(1)
    await fixture.service.fail(0, message: "initial failure")
    try await inboxActivityWait { model.repliesModel.state == .failed("initial failure") }
    model.deactivate()
    model.repliesModel.reload()
    await model.refresh(kind: .replies)
    await inboxActivityDrain()
    let hiddenCount = await fixture.service.requestsSnapshot().count
    XCTAssertEqual(hiddenCount, 1)
    model.activate()
    model.repliesModel.reload()
    try await fixture.waitForRequestCount(2)
    await fixture.service.succeed(1, ids: [11])
    try await fixture.waitForLoaded(.replies)
  }
}

@MainActor
private final class InboxActivityFixture {
  let session = inboxActivitySession()
  let service = SuspendedInboxActivityService()
  let vault: NotificationsVaultSpy
  let filters: InboxActivityFilterRepository
  let model: NotificationsActivityViewModel
  private let callbacks: InboxActivityCallbacks

  var callbackRevisions: [UUID] { callbacks.revisions }

  init(filter: ContentFilterSnapshot = .empty) {
    let vault = NotificationsVaultSpy(session: session)
    self.vault = vault
    let callbacks = InboxActivityCallbacks()
    self.callbacks = callbacks
    let filters = InboxActivityFilterRepository(value: filter)
    self.filters = filters
    model = NotificationsActivityViewModel(
      service: service, vault: vault,
      contentFilterRepository: filters,
      onValidatedFirstPage: { callbacks.revisions.append($0) }
    )
  }

  func waitForRequestCount(_ count: Int) async throws {
    try await inboxActivityWait { await self.service.requestsSnapshot().count >= count }
  }

  func waitForLoaded(_ kind: InboxKind) async throws {
    try await inboxActivityWait {
      let page = self.model.model(for: kind)
      return page.state == .loaded && !page.isResolvingSession && !page.isResolvingContentFilter
        && !page.isLoadingMore
    }
  }

  func cleanup() {
    model.deactivate()
    let service = service
    let filters = filters
    Task {
      await service.finishAll()
      await filters.releaseRead()
    }
  }
}

@MainActor
private final class InboxActivityCallbacks {
  var revisions: [UUID] = []
}

private struct InboxActivityRequest: Sendable {
  let userID: Int64
  let revision: UUID
  let kind: InboxKind
  let page: Int
}

private struct InboxActivityFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor SuspendedInboxActivityService: AccountService {
  private var requests: [InboxActivityRequest] = []
  private var pending: [Int: CheckedContinuation<InboxPage, Error>] = [:]

  func notifications(session: StoredAccountSession, kind: InboxKind, page: Int) async throws
    -> InboxPage
  {
    let index = requests.count
    requests.append(
      InboxActivityRequest(
        userID: session.id, revision: session.sessionRevision, kind: kind, page: page
      ))
    // Deliberately ignore cancellation so generation/lease rejection, rather
    // than transport cooperation, determines whether stale results publish.
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }

  func requestsSnapshot() -> [InboxActivityRequest] { requests }

  func succeed(_ index: Int, ids: [Int64], hasMore: Bool = false) {
    guard requests.indices.contains(index), let continuation = pending.removeValue(forKey: index)
    else { return }
    let request = requests[index]
    continuation.resume(
      returning: InboxPage(
        userID: request.userID, kind: request.kind, messages: ids.map(inboxActivityMessage),
        currentPage: request.page, hasMore: hasMore
      ))
  }

  func fail(_ index: Int, message: String) {
    pending.removeValue(forKey: index)?.resume(throwing: InboxActivityFailure(message: message))
  }

  func finishAll() {
    let continuations = Array(pending.values)
    pending.removeAll()
    for continuation in continuations { continuation.resume(throwing: CancellationError()) }
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw InboxActivityFailure(message: "Unexpected validation")
  }
  func followedForums(session: StoredAccountSession, page: Int, pageSize: Int) async throws
    -> FollowedForumPageData
  {
    throw InboxActivityFailure(message: "Unexpected followed forums")
  }
  func forumMembership(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws -> ForumMembershipData
  {
    throw InboxActivityFailure(message: "Unexpected membership")
  }
  func forumAccountState(session: StoredAccountSession, forumID: Int64, forumName: String)
    async throws -> ForumAccountStateData
  {
    throw InboxActivityFailure(message: "Unexpected account state")
  }
  func setForumFollowed(
    session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw InboxActivityFailure(message: "Unexpected write")
  }
  func checkInToForum(session: StoredAccountSession, forumID: Int64, forumName: String) async throws
    -> ForumAccountStateData
  {
    throw InboxActivityFailure(message: "Unexpected write")
  }
}

private actor InboxActivityFilterRepository: ContentFilterRepository {
  private var value: ContentFilterSnapshot
  private var holdsNextRead = false
  private var pending: CheckedContinuation<ContentFilterSnapshot, Never>?
  init(value: ContentFilterSnapshot) { self.value = value }
  func snapshot() async throws -> ContentFilterSnapshot {
    if holdsNextRead {
      holdsNextRead = false
      return await withCheckedContinuation { pending = $0 }
    }
    return value
  }
  func replace(with value: ContentFilterSnapshot) { self.value = value }
  func holdNextRead() { holdsNextRead = true }
  func hasPendingRead() -> Bool { pending != nil }
  func releaseRead() {
    let continuation = pending
    pending = nil
    continuation?.resume(returning: value)
  }
  func add(_ rule: ContentFilterRule) async throws -> ContentFilterRule {
    throw CancellationError()
  }
  func delete(id: UUID) async throws { throw CancellationError() }
  func deleteAll(in list: ContentFilterList) async throws { throw CancellationError() }
  func setDisplayMode(_ mode: ContentFilterDisplayMode) async throws { throw CancellationError() }
  func setBlockVideos(_ blockVideos: Bool) async throws { throw CancellationError() }
  func reset() async throws { throw CancellationError() }
}

private func inboxActivitySession() -> StoredAccountSession {
  StoredAccountSession(
    id: 7, username: "user-7", displayName: "User 7", portrait: "portrait-7",
    bduss: String(repeating: "b", count: 192), createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2), sessionRevision: UUID()
  )
}

private func inboxActivityMessage(_ id: Int64) -> InboxMessage {
  InboxMessage(
    id: id,
    sender: InboxSender(
      id: 100 + id, username: "sender-\(id)", displayName: "Sender \(id)", portraitURL: nil,
      isFriend: false, isFan: false),
    quotedUser: nil, threadID: 1_000 + id, postID: id, quotedPostID: nil,
    title: "Thread \(id)", content: "Message \(id)", quotedContent: "", forumName: "swift",
    createdAt: Date(timeIntervalSince1970: TimeInterval(id)), isFloorReply: false,
    isFirstPost: false, isUnread: true, threadType: 0
  )
}

@MainActor
private func inboxActivityDrain() async {
  for _ in 0..<30 { await Task.yield() }
}

@MainActor
private func inboxActivityWait(
  file: StaticString = #filePath, line: UInt = #line,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while !(await condition()) {
    guard ContinuousClock.now < deadline else {
      XCTFail("Timed out waiting for inbox activity state", file: file, line: line)
      throw InboxActivityFailure(message: "Bounded test wait expired")
    }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}
