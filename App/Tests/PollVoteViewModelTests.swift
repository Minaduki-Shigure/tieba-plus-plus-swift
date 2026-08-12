import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class PollVoteViewModelTests: XCTestCase {
  func testSignedOutUsesAnonymousReadOnlySnapshotAndAcceptsFallbackRefresh() async {
    let service = PollVoteServiceSpy()
    let viewModel = makeViewModel(vault: PollVoteVaultSpy(session: nil), service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .signedOut)
    XCTAssertEqual(viewModel.displayedPoll.title, "anonymous")
    XCTAssertFalse(viewModel.isSelectionEnabled)
    viewModel.toggleSelection(optionID: 10)
    XCTAssertTrue(viewModel.selectedOptionIDs.isEmpty)

    let refreshed = poll(title: "refreshed", optionIDs: [30, 40])
    viewModel.replaceAnonymousSnapshot(refreshed)
    XCTAssertEqual(viewModel.displayedPoll, refreshed)
    let readCount = await service.readRequestCount()
    XCTAssertEqual(readCount, 0)
  }

  func testLoadRequiresFullCredentialsAndRejectsMismatchedOrMalformedState() async {
    let legacy = session(userID: 1, revision: uuid(1), hasFullCredentials: false)
    let legacyService = PollVoteServiceSpy()
    let legacyViewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: legacy),
      service: legacyService
    )

    await legacyViewModel.loadIfNeeded()

    XCTAssertEqual(legacyViewModel.state, .failed(previous: anonymousPoll))
    XCTAssertEqual(
      legacyViewModel.errorMessage,
      PollVoteError.fullCredentialsRequired.localizedDescription
    )
    let legacyReadCount = await legacyService.readRequestCount()
    XCTAssertEqual(legacyReadCount, 0)

    let active = session(userID: 1, revision: uuid(2))
    let service = PollVoteServiceSpy(reads: [
      active.sessionRevision: [
        .value(data(userID: 2, poll: poll())),
        .value(data(userID: 1, poll: poll(optionIDs: [10, 10]))),
      ]
    ])
    let viewModel = makeViewModel(vault: PollVoteVaultSpy(session: active), service: service)

    for _ in 0..<2 {
      await viewModel.reload()
      XCTAssertEqual(viewModel.state, .failed(previous: anonymousPoll))
      XCTAssertFalse(viewModel.isSelectionEnabled)
    }
  }

  func testSingleAndMultipleChoiceSelectionOnlyUseAuthoritativeOptionIDs() async {
    let singleSession = session(userID: 1, revision: uuid(1))
    let singlePoll = poll(optionIDs: [10, 20])
    let singleService = PollVoteServiceSpy(reads: [
      singleSession.sessionRevision: [.value(data(userID: 1, poll: singlePoll))]
    ])
    let single = makeViewModel(
      vault: PollVoteVaultSpy(session: singleSession),
      service: singleService
    )
    await single.loadIfNeeded()

    single.toggleSelection(optionID: 999)
    XCTAssertTrue(single.selectedOptionIDs.isEmpty)
    single.toggleSelection(optionID: 10)
    single.toggleSelection(optionID: 20)
    XCTAssertEqual(single.selectedOptionIDs, [20])
    XCTAssertTrue(single.canSubmit)

    let multipleSession = session(userID: 2, revision: uuid(2))
    let multiplePoll = poll(isMultipleChoice: true, optionIDs: [10, 20, 30])
    let multipleService = PollVoteServiceSpy(reads: [
      multipleSession.sessionRevision: [.value(data(userID: 2, poll: multiplePoll))]
    ])
    let multiple = makeViewModel(
      vault: PollVoteVaultSpy(session: multipleSession),
      service: multipleService
    )
    await multiple.loadIfNeeded()

    multiple.toggleSelection(optionID: 10)
    multiple.toggleSelection(optionID: 20)
    XCTAssertEqual(multiple.selectedOptionIDs, [10, 20])
    multiple.toggleSelection(optionID: 10)
    XCTAssertEqual(multiple.selectedOptionIDs, [20])
  }

  func testExpiredOrAlreadyPolledSnapshotCannotBeSelectedOrSubmitted() async {
    for (revision, authoritative) in [
      (uuid(1), poll(endTimestamp: 999)),
      (uuid(2), poll(isPolled: true, selectedOptionIDs: [10])),
      (uuid(3), poll(status: 1)),
    ] {
      let active = session(userID: 1, revision: revision)
      let service = PollVoteServiceSpy(reads: [
        revision: [.value(data(userID: 1, poll: authoritative))]
      ])
      let viewModel = makeViewModel(
        vault: PollVoteVaultSpy(session: active),
        service: service,
        now: Date(timeIntervalSince1970: 1_000)
      )
      await viewModel.loadIfNeeded()

      viewModel.toggleSelection(optionID: 10)
      await viewModel.submitSelection()

      XCTAssertFalse(viewModel.isSelectionEnabled)
      XCTAssertFalse(viewModel.canSubmit)
      let writeCount = await service.writeRequestCount()
      XCTAssertEqual(writeCount, 0)
    }
  }

  func testConcurrentSubmitTapsIssueExactlyOneWriteAndPublishVerifiedSelection() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(optionIDs: [10, 20])
    let after = poll(isPolled: true, selectedOptionIDs: [20], optionIDs: [10, 20])
    let service = PollVoteServiceSpy(
      reads: [active.sessionRevision: [.value(data(userID: 1, poll: before))]],
      writes: [active.sessionRevision: [.suspended(id: 1, data: data(userID: 1, poll: after))]]
    )
    addTeardownBlock { await service.releaseAll() }
    let viewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 20)

    let first = Task { await viewModel.submitSelection() }
    try await waitForPollVoteTest { await service.writeRequestCount() == 1 }
    await viewModel.submitSelection()

    var writeCount = await service.writeRequestCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(
      viewModel.state,
      .submitting(previous: before, selectedOptionIDs: [20])
    )
    await service.release(id: 1)
    await first.value

    XCTAssertEqual(viewModel.state, .ready(after))
    XCTAssertEqual(viewModel.selectedOptionIDs, [20])
    XCTAssertNil(viewModel.errorMessage)
    let readCount = await service.readRequestCount()
    writeCount = await service.writeRequestCount()
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(writeCount, 1)
  }

  func testOutcomeUnknownLocksInteractionUntilExplicitReloadWithoutRetryingWrite() async {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(optionIDs: [10, 20])
    let service = PollVoteServiceSpy(
      reads: [active.sessionRevision: [
        .value(data(userID: 1, poll: before)),
        .value(data(userID: 1, poll: before)),
      ]],
      writes: [active.sessionRevision: [.outcomeUnknown]]
    )
    let viewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)

    await viewModel.submitSelection()

    XCTAssertEqual(viewModel.state, .outcomeUnknown(previous: before))
    XCTAssertFalse(viewModel.isSelectionEnabled)
    XCTAssertFalse(viewModel.canSubmit)
    viewModel.toggleSelection(optionID: 20)
    await viewModel.submitSelection()
    await viewModel.loadIfNeeded()
    var writeCount = await service.writeRequestCount()
    var readCount = await service.readRequestCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(readCount, 1)

    await viewModel.reload()

    XCTAssertEqual(viewModel.state, .ready(before))
    XCTAssertTrue(viewModel.isSelectionEnabled)
    readCount = await service.readRequestCount()
    writeCount = await service.writeRequestCount()
    XCTAssertEqual(readCount, 2)
    XCTAssertEqual(writeCount, 1)
  }

  func testUnverifiedReturnedSelectionPublishesSnapshotButDoesNotReportSuccess() async {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(optionIDs: [10, 20])
    let conflicting = poll(isPolled: true, selectedOptionIDs: [20], optionIDs: [10, 20])
    let service = PollVoteServiceSpy(
      reads: [active.sessionRevision: [.value(data(userID: 1, poll: before))]],
      writes: [active.sessionRevision: [.value(data(userID: 1, poll: conflicting))]]
    )
    let viewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)

    await viewModel.submitSelection()

    XCTAssertEqual(viewModel.state, .failed(previous: conflicting))
    XCTAssertEqual(viewModel.displayedPoll, conflicting)
    XCTAssertNotNil(viewModel.errorMessage)
    let writeCount = await service.writeRequestCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testAccountSwitchSuppressesLateWriteAndPublishesNewLeaseSnapshot() async throws {
    let oldSession = session(userID: 1, revision: uuid(1), credential: "a")
    let newSession = session(userID: 2, revision: uuid(2), credential: "b")
    let oldBefore = poll(title: "old", optionIDs: [10, 20])
    let oldAfter = poll(
      title: "stale",
      isPolled: true,
      selectedOptionIDs: [10],
      optionIDs: [10, 20]
    )
    let newPoll = poll(title: "new", optionIDs: [30, 40])
    let service = PollVoteServiceSpy(
      reads: [
        oldSession.sessionRevision: [.value(data(userID: 1, poll: oldBefore))],
        newSession.sessionRevision: [.value(data(userID: 2, poll: newPoll))],
      ],
      writes: [
        oldSession.sessionRevision: [
          .suspended(id: 1, data: data(userID: 1, poll: oldAfter))
        ]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = PollVoteVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)

    let oldWrite = Task { await viewModel.submitSelection() }
    try await waitForPollVoteTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await service.release(id: 1)
    await oldWrite.value

    XCTAssertEqual(viewModel.state, .ready(newPoll))
    XCTAssertEqual(viewModel.displayedPoll.title, "new")
    XCTAssertTrue(viewModel.selectedOptionIDs.isEmpty)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testSameUserNewRevisionSuppressesOldWriteAndKeepsNewLeaseSnapshot() async throws {
    let oldSession = session(userID: 1, revision: uuid(1), credential: "a")
    let newSession = session(userID: 1, revision: uuid(2), credential: "b")
    let oldBefore = poll(title: "old", optionIDs: [10, 20])
    let staleResult = poll(
      title: "stale",
      isPolled: true,
      selectedOptionIDs: [10],
      optionIDs: [10, 20]
    )
    let newSnapshot = poll(title: "new-revision", optionIDs: [10, 20])
    let service = PollVoteServiceSpy(
      reads: [
        oldSession.sessionRevision: [.value(data(userID: 1, poll: oldBefore))],
        newSession.sessionRevision: [.value(data(userID: 1, poll: newSnapshot))],
      ],
      writes: [
        oldSession.sessionRevision: [
          .suspended(id: 1, data: data(userID: 1, poll: staleResult))
        ]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = PollVoteVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)

    let oldWrite = Task { await viewModel.submitSelection() }
    try await waitForPollVoteTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await service.release(id: 1)
    await oldWrite.value

    XCTAssertEqual(viewModel.state, .ready(newSnapshot))
    XCTAssertEqual(viewModel.displayedPoll.title, "new-revision")
    XCTAssertTrue(viewModel.selectedOptionIDs.isEmpty)
    let requests = await service.readRequestsSnapshot()
    XCTAssertEqual(requests.map(\.sessionRevision), [uuid(1), uuid(2)])
  }

  func testAnonymousRefreshAndDisappearCannotPolluteOrPublishInFlightWrite() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(title: "authoritative", optionIDs: [10, 20])
    let after = poll(
      title: "late",
      isPolled: true,
      selectedOptionIDs: [10],
      optionIDs: [10, 20]
    )
    let service = PollVoteServiceSpy(
      reads: [active.sessionRevision: [.value(data(userID: 1, poll: before))]],
      writes: [active.sessionRevision: [.suspended(id: 1, data: data(userID: 1, poll: after))]]
    )
    addTeardownBlock { await service.releaseAll() }
    let viewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)

    let write = Task { await viewModel.submitSelection() }
    try await waitForPollVoteTest { await service.writeRequestCount() == 1 }
    viewModel.replaceAnonymousSnapshot(poll(title: "fallback-refresh", optionIDs: [50, 60]))
    XCTAssertEqual(viewModel.displayedPoll.title, "authoritative")
    viewModel.presentationDidDisappear()
    await service.release(id: 1)
    await write.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.displayedPoll.title, "fallback-refresh")
    XCTAssertNil(viewModel.errorMessage)
  }

  func testDisappearDuringBlockedSubmissionPreflightCancelsBeforeServiceCall() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(optionIDs: [10, 20])
    let service = PollVoteServiceSpy(reads: [
      active.sessionRevision: [.value(data(userID: 1, poll: before))]
    ])
    let vault = PollVoteVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)
    await vault.suspendNextRead(id: 1)

    viewModel.beginSubmitSelection()
    try await waitForPollVoteTest { await vault.hasSuspendedRead(id: 1) }
    viewModel.presentationDidDisappear()
    await vault.releaseRead(id: 1)
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(viewModel.state, .idle)
    let writeCount = await service.writeRequestCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testAccountChangeDuringBlockedSubmissionPreflightNeverCallsOldWrite() async throws {
    let oldSession = session(userID: 1, revision: uuid(1), credential: "a")
    let newSession = session(userID: 2, revision: uuid(2), credential: "b")
    let oldPoll = poll(title: "old", optionIDs: [10, 20])
    let newPoll = poll(title: "new", optionIDs: [30, 40])
    let service = PollVoteServiceSpy(reads: [
      oldSession.sessionRevision: [.value(data(userID: 1, poll: oldPoll))],
      newSession.sessionRevision: [.value(data(userID: 2, poll: newPoll))],
    ])
    let vault = PollVoteVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    viewModel.toggleSelection(optionID: 10)
    await vault.suspendNextRead(id: 1)

    viewModel.beginSubmitSelection()
    try await waitForPollVoteTest { await vault.hasSuspendedRead(id: 1) }
    await vault.replaceActive(with: newSession)
    let token = viewModel.invalidateForAccountSessionChange()
    await vault.releaseRead(id: 1)
    await viewModel.reloadAfterAccountSessionChange(ifCurrent: token)
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(viewModel.state, .ready(newPoll))
    let writeCount = await service.writeRequestCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testQueuedAccountReloadCannotRestartAfterPresentationDisappears() async {
    let active = session(userID: 1, revision: uuid(1))
    let before = poll(optionIDs: [10, 20])
    let service = PollVoteServiceSpy(reads: [
      active.sessionRevision: [.value(data(userID: 1, poll: before))]
    ])
    let viewModel = makeViewModel(
      vault: PollVoteVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()

    let token = viewModel.invalidateForAccountSessionChange()
    viewModel.presentationDidDisappear()
    await viewModel.reloadAfterAccountSessionChange(ifCurrent: token)

    XCTAssertEqual(viewModel.state, .idle)
    let readCount = await service.readRequestCount()
    XCTAssertEqual(readCount, 1)
  }

  private var anonymousPoll: BrowsePoll {
    poll(title: "anonymous", optionIDs: [10, 20])
  }

  private func makeViewModel(
    vault: PollVoteVaultSpy,
    service: PollVoteServiceSpy,
    now: Date = Date(timeIntervalSince1970: 100)
  ) -> PollVoteViewModel {
    PollVoteViewModel(
      anonymousPoll: anonymousPoll,
      forumID: 42,
      threadID: 100,
      access: AccountAccess(vault: vault, service: service),
      now: { now }
    )
  }

  private func session(
    userID: Int64,
    revision: UUID,
    credential: Character = "s",
    hasFullCredentials: Bool = true
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait",
      bduss: String(repeating: credential, count: 192),
      stoken: hasFullCredentials ? String(repeating: credential, count: 64) : nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func data(
    userID: Int64,
    forumID: Int64 = 42,
    threadID: Int64 = 100,
    poll: BrowsePoll
  ) -> PollVoteData {
    PollVoteData(userID: userID, forumID: forumID, threadID: threadID, poll: poll)
  }

  private func poll(
    title: String = "poll",
    isMultipleChoice: Bool = false,
    isPolled: Bool = false,
    selectedOptionIDs: Set<Int32> = [],
    optionIDs: [Int32] = [10, 20],
    endTimestamp: Int64 = 0,
    status: Int32 = 0
  ) -> BrowsePoll {
    BrowsePoll(
      title: title,
      isMultipleChoice: isMultipleChoice,
      participantCount: isPolled ? 1 : 0,
      totalVoteCount: Int64(selectedOptionIDs.count),
      options: optionIDs.map {
        BrowsePollOption(id: $0, text: "option-\($0)", voteCount: 0)
      },
      isPolled: isPolled,
      selectedOptionIDs: selectedOptionIDs,
      endTimestamp: endTimestamp,
      status: status
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct PollVoteRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
  let forumID: Int64
  let threadID: Int64
  let selectedOptionIDs: Set<Int32>?
}

private enum PollVoteReadScript: Sendable {
  case value(PollVoteData)
  case failure(String)
  case suspended(id: Int, data: PollVoteData)
}

private enum PollVoteWriteScript: Sendable {
  case value(PollVoteData)
  case failure(String)
  case outcomeUnknown
  case cancelled
  case suspended(id: Int, data: PollVoteData)
}

private struct PollVoteTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor PollVoteServiceSpy: AccountService {
  private var reads: [UUID: [PollVoteReadScript]]
  private var writes: [UUID: [PollVoteWriteScript]]
  private var readRequests: [PollVoteRequest] = []
  private var writeRequests: [PollVoteRequest] = []
  private var suspended:
    [Int: (CheckedContinuation<PollVoteData, Never>, PollVoteData)] = [:]

  init(
    reads: [UUID: [PollVoteReadScript]] = [:],
    writes: [UUID: [PollVoteWriteScript]] = [:]
  ) {
    self.reads = reads
    self.writes = writes
  }

  func pollState(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64
  ) async throws -> PollVoteData {
    readRequests.append(
      PollVoteRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: nil
      )
    )
    guard var scripts = reads[session.sessionRevision], !scripts.isEmpty else {
      throw PollVoteTestFailure(message: "Unexpected poll read")
    }
    let script = scripts.removeFirst()
    reads[session.sessionRevision] = scripts
    switch script {
    case .value(let data):
      return data
    case .failure(let message):
      throw PollVoteTestFailure(message: message)
    case .suspended(let id, let data):
      return await withCheckedContinuation { suspended[id] = ($0, data) }
    }
  }

  func submitPollVote(
    session: StoredAccountSession,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: Set<Int32>
  ) async throws -> PollVoteData {
    writeRequests.append(
      PollVoteRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: selectedOptionIDs
      )
    )
    guard var scripts = writes[session.sessionRevision], !scripts.isEmpty else {
      throw PollVoteTestFailure(message: "Unexpected poll write")
    }
    let script = scripts.removeFirst()
    writes[session.sessionRevision] = scripts
    switch script {
    case .value(let data):
      return data
    case .failure(let message):
      throw PollVoteTestFailure(message: message)
    case .outcomeUnknown:
      throw PollVoteError.outcomeUnknown
    case .cancelled:
      throw CancellationError()
    case .suspended(let id, let data):
      return await withCheckedContinuation { suspended[id] = ($0, data) }
    }
  }

  func release(id: Int) {
    guard let (continuation, data) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(returning: data)
  }

  func releaseAll() {
    let entries = suspended.values
    suspended.removeAll()
    entries.forEach { continuation, data in continuation.resume(returning: data) }
  }

  func readRequestCount() -> Int { readRequests.count }
  func writeRequestCount() -> Int { writeRequests.count }
  func readRequestsSnapshot() -> [PollVoteRequest] { readRequests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw PollVoteTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw PollVoteTestFailure(message: "Unexpected followed-forum read")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw PollVoteTestFailure(message: "Unexpected forum-membership read")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw PollVoteTestFailure(message: "Unexpected forum-account-state read")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw PollVoteTestFailure(message: "Unexpected forum-membership write")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw PollVoteTestFailure(message: "Unexpected forum check-in")
  }
}

private actor PollVoteVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var nextSuspendedReadID: Int?
  private var suspendedReads:
    [Int: (CheckedContinuation<StoredAccountSession?, Never>, StoredAccountSession?)] = [:]

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func suspendNextRead(id: Int) {
    nextSuspendedReadID = id
  }

  func hasSuspendedRead(id: Int) -> Bool {
    suspendedReads[id] != nil
  }

  func releaseRead(id: Int) {
    guard let (continuation, value) = suspendedReads.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? {
    guard let id = nextSuspendedReadID else { return session }
    nextSuspendedReadID = nil
    let value = session
    return await withCheckedContinuation { suspendedReads[id] = ($0, value) }
  }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

@MainActor
private func waitForPollVoteTest(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      XCTFail("Timed out waiting for poll-vote state")
      return
    }
    await Task.yield()
  }
}
