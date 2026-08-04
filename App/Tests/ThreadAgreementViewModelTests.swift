import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ThreadAgreementViewModelTests: XCTestCase {
  func testInvalidTargetNeverReadsAccountOrService() async {
    let vault = ThreadAgreementVaultSpy(session: session())
    let service = ThreadAgreementServiceSpy()
    let viewModel = makeViewModel(
      forumID: 0,
      vault: vault,
      service: service
    )

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .idle)
    let activeSessionReads = await vault.activeSessionReadCount()
    let agreementReads = await service.readRequestCount()
    XCTAssertEqual(activeSessionReads, 0)
    XCTAssertEqual(agreementReads, 0)
  }

  func testSignedOutKeepsFallbackScoreAndDoesNotCallService() async {
    let vault = ThreadAgreementVaultSpy()
    let service = ThreadAgreementServiceSpy()
    let viewModel = makeViewModel(
      fallbackAgreeScore: 7,
      vault: vault,
      service: service
    )

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .signedOut)
    XCTAssertEqual(viewModel.displayedAgreeScore, 7)
    viewModel.updateFallbackAgreeScore(9)
    XCTAssertEqual(viewModel.displayedAgreeScore, 9)
    let agreementReads = await service.readRequestCount()
    XCTAssertEqual(agreementReads, 0)
  }

  func testLoadsAuthoritativeStateForCurrentSession() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [.success(agreement(isAgreed: true, score: 12))]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 12))
    )
    XCTAssertNil(viewModel.errorMessage)
    let agreementReads = await service.readRequestCount()
    XCTAssertEqual(agreementReads, 1)
  }

  func testOldReloadSuspendedAtInitialVaultReadCannotStartOldServiceRequest() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000021")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000022")
    )
    let oldSession = session(revision: oldRevision)
    let newSession = session(revision: newRevision)
    let vault = ThreadAgreementVaultSpy(
      session: oldSession,
      activeSessionDelaysByRead: [1: 150_000_000]
    )
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        oldRevision: [.success(agreement(isAgreed: false, score: 1))],
        newRevision: [.success(agreement(isAgreed: true, score: 8))],
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    let oldLoad = Task { await viewModel.reload() }
    try await waitForThreadAgreementTest { await vault.activeSessionReadCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await oldLoad.value

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 8))
    )
    let readRevisions = await service.readRevisions()
    XCTAssertEqual(readRevisions, [newRevision])
  }

  func testOldReloadSuspendedAtLeaseValidationCannotOverwriteNewState() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000031")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000032")
    )
    let oldSession = session(revision: oldRevision)
    let newSession = session(revision: newRevision)
    let vault = ThreadAgreementVaultSpy(
      session: oldSession,
      activeSessionDelaysByRead: [2: 150_000_000]
    )
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        oldRevision: [.success(agreement(isAgreed: false, score: 1))],
        newRevision: [.success(agreement(isAgreed: true, score: 8))],
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    let oldLoad = Task { await viewModel.reload() }
    try await waitForThreadAgreementTest { await vault.activeSessionReadCount() == 2 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await oldLoad.value

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 8))
    )
    let readRevisions = await service.readRevisions()
    XCTAssertEqual(readRevisions, [oldRevision, newRevision])
  }

  func testSuccessfulWriteUsesServerSnapshotRejectsDuplicateTapAndPostsRevision() async throws {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [.success(agreement(isAgreed: false, score: 4))]
      ],
      writesByRevision: [
        active.sessionRevision: .success(agreement(isAgreed: true, score: 5))
      ],
      writeDelaysByRevision: [active.sessionRevision: 120_000_000]
    )
    let recorder = ThreadAgreementNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadAgreementDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadAgreementChange(notification),
        change.sessionRevision == active.sessionRevision,
        change.threadID == 200,
        change.firstPostID == 201
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let firstWrite = Task { await viewModel.setAgreed(true) }
    try await waitForThreadAgreementTest { await service.writeRequestCount() == 1 }
    await viewModel.setAgreed(true)
    await firstWrite.value

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 5))
    )
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementWrites, 1)
    XCTAssertEqual(
      recorder.snapshot(),
      [
        ThreadAgreementChange(
          accountID: active.id,
          sessionRevision: active.sessionRevision,
          forumID: 100,
          threadID: 200,
          firstPostID: 201,
          isAgreed: true,
          agreeScore: 5
        )
      ]
    )
  }

  func testSuccessfulUnlikeRequiresOppositeServerState() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [.success(agreement(isAgreed: true, score: 5))]
      ],
      writesByRevision: [
        active.sessionRevision: .success(agreement(isAgreed: false, score: 4))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setAgreed(false)

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: false, agreeScore: 4))
    )
    let writes = await service.writeTargets()
    XCTAssertEqual(writes, [false])
  }

  func testFailedWriteReconcilesServerSuccessOnceWithoutRetryingWrite() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [
          .success(agreement(isAgreed: false, score: 4)),
          .success(agreement(isAgreed: true, score: 5)),
        ]
      ],
      writesByRevision: [
        active.sessionRevision: .failure(ThreadAgreementTestFailure(message: "response lost"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setAgreed(true)

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 5))
    )
    XCTAssertNil(viewModel.errorMessage)
    let agreementReads = await service.readRequestCount()
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementReads, 2)
    XCTAssertEqual(agreementWrites, 1)
  }

  func testFailedWriteWithUnchangedReadbackRestoresServerStateAndReportsError() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [
          .success(agreement(isAgreed: false, score: 4)),
          .success(agreement(isAgreed: false, score: 4)),
        ]
      ],
      writesByRevision: [
        active.sessionRevision: .failure(ThreadAgreementTestFailure(message: "write failed"))
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setAgreed(true)

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: false, agreeScore: 4))
    )
    XCTAssertEqual(viewModel.errorMessage, "write failed")
    let agreementReads = await service.readRequestCount()
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementReads, 2)
    XCTAssertEqual(agreementWrites, 1)
  }

  func testCancelledWriteAlsoPerformsOneReadbackWithoutRetryingWrite() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [
          .success(agreement(isAgreed: false, score: 4)),
          .success(agreement(isAgreed: true, score: 5)),
        ]
      ],
      cancelledWriteRevisions: [active.sessionRevision]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setAgreed(true)

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 5))
    )
    XCTAssertNil(viewModel.errorMessage)
    let agreementReads = await service.readRequestCount()
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementReads, 2)
    XCTAssertEqual(agreementWrites, 1)
  }

  func testRevisionChangeBeforeWritePreflightNeverCallsMutation() async {
    let oldSession = session()
    let vault = ThreadAgreementVaultSpy(session: oldSession)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        oldSession.sessionRevision: [.success(agreement(isAgreed: false, score: 4))]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()
    await vault.replaceActive(with: session())

    await viewModel.setAgreed(true)

    XCTAssertEqual(viewModel.state, .idle)
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementWrites, 0)
  }

  func testSameUserNewRevisionCanWriteWhileOldWriteIsSuspendedAndRejectsOldResult() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000101")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000102")
    )
    let oldSession = session(revision: oldRevision, credentialComponent: "a")
    let newSession = session(revision: newRevision, credentialComponent: "b")
    let vault = ThreadAgreementVaultSpy(session: oldSession)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        oldRevision: [.success(agreement(isAgreed: false, score: 4))],
        newRevision: [.success(agreement(isAgreed: false, score: 4))],
      ],
      writesByRevision: [
        oldRevision: .success(agreement(isAgreed: true, score: 99)),
        newRevision: .success(agreement(isAgreed: true, score: 5)),
      ],
      writeDelaysByRevision: [oldRevision: 180_000_000]
    )
    let recorder = ThreadAgreementNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadAgreementDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadAgreementChange(notification),
        change.sessionRevision == oldRevision || change.sessionRevision == newRevision,
        change.threadID == 200,
        change.firstPostID == 201
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldWrite = Task { await viewModel.setAgreed(true) }
    try await waitForThreadAgreementTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()

    let newWrite = Task { await viewModel.setAgreed(true) }
    try await waitForThreadAgreementTest { await service.writeRequestCount() == 2 }
    await newWrite.value
    await oldWrite.value

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 5))
    )
    let writeRevisions = await service.writeRevisions()
    XCTAssertEqual(writeRevisions, [oldRevision, newRevision])
    XCTAssertEqual(recorder.snapshot().map(\.sessionRevision), [newRevision])
  }

  func testSwitchAwayAndBackToSameRevisionStillSuppressesOldWriteNotification() async throws {
    let revision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000151")
    )
    let active = session(revision: revision)
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        revision: [
          .success(agreement(isAgreed: false, score: 4)),
          .success(agreement(isAgreed: false, score: 4)),
        ]
      ],
      writesByRevision: [
        revision: .success(agreement(isAgreed: true, score: 99))
      ],
      writeDelaysByRevision: [revision: 180_000_000]
    )
    let recorder = ThreadAgreementNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadAgreementDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadAgreementChange(notification),
        change.sessionRevision == revision,
        change.threadID == 200,
        change.firstPostID == 201
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldWrite = Task { await viewModel.setAgreed(true) }
    try await waitForThreadAgreementTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: nil)
    await viewModel.accountSessionDidChange()
    XCTAssertEqual(viewModel.state, .signedOut)
    await vault.replaceActive(with: active)
    await viewModel.accountSessionDidChange()
    await oldWrite.value

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: false, agreeScore: 4))
    )
    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testDisappearedPresentationCannotPublishSuspendedWriteResult() async throws {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [.success(agreement(isAgreed: false, score: 4))]
      ],
      writesByRevision: [
        active.sessionRevision: .success(agreement(isAgreed: true, score: 5))
      ],
      writeDelaysByRevision: [active.sessionRevision: 150_000_000]
    )
    let recorder = ThreadAgreementNotificationRecorder()
    let token = NotificationCenter.default.addObserver(
      forName: .threadAgreementDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ThreadAgreementChange(notification),
        change.sessionRevision == active.sessionRevision,
        change.threadID == 200,
        change.firstPostID == 201
      else { return }
      recorder.record(change)
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let write = Task { await viewModel.setAgreed(true) }
    try await waitForThreadAgreementTest { await service.writeRequestCount() == 1 }
    viewModel.presentationDidDisappear()
    await write.value

    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testRetainedViewModelReloadsLeaseWhenPresentationReappears() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [
          .success(agreement(isAgreed: false, score: 4)),
          .success(agreement(isAgreed: true, score: 5)),
        ]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    viewModel.presentationDidDisappear()
    XCTAssertEqual(viewModel.state, .idle)
    await viewModel.loadIfNeeded()

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 5))
    )
    let agreementReads = await service.readRequestCount()
    XCTAssertEqual(agreementReads, 2)
  }

  func testQueuedAccountReloadCannotRestartAfterPresentationDisappears() async {
    let active = session()
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        active.sessionRevision: [.success(agreement(isAgreed: false, score: 4))]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let token = viewModel.invalidateForAccountSessionChange()
    viewModel.presentationDidDisappear()
    await viewModel.reloadAfterAccountSessionChange(ifCurrent: token)

    XCTAssertEqual(viewModel.state, .idle)
    let agreementReads = await service.readRequestCount()
    XCTAssertEqual(agreementReads, 1)
  }

  func testNotificationOnlyAppliesToCurrentRevisionAndExactTarget() async throws {
    let revision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000201")
    )
    let active = session(revision: revision)
    let vault = ThreadAgreementVaultSpy(session: active)
    let service = ThreadAgreementServiceSpy(
      readsByRevision: [
        revision: [.success(agreement(isAgreed: false, score: 2))]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.threadAgreementDidChange(
      ThreadAgreementChange(
        accountID: 1,
        sessionRevision: UUID(),
        forumID: 100,
        threadID: 200,
        firstPostID: 201,
        isAgreed: true,
        agreeScore: 99
      )
    )
    await viewModel.threadAgreementDidChange(
      ThreadAgreementChange(
        accountID: 1,
        sessionRevision: revision,
        forumID: 100,
        threadID: 999,
        firstPostID: 201,
        isAgreed: true,
        agreeScore: 98
      )
    )
    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: false, agreeScore: 2))
    )

    await viewModel.threadAgreementDidChange(
      ThreadAgreementChange(
        accountID: 1,
        sessionRevision: revision,
        forumID: 100,
        threadID: 200,
        firstPostID: 201,
        isAgreed: true,
        agreeScore: 3
      )
    )

    XCTAssertEqual(
      viewModel.state,
      .ready(ThreadAgreementSnapshot(isAgreed: true, agreeScore: 3))
    )
    let agreementWrites = await service.writeRequestCount()
    XCTAssertEqual(agreementWrites, 0)
  }

  func testNotificationParserRejectsMissingRevisionAndInvalidBooleanAndClampsNegativeScore() {
    let revision = UUID()
    let validInfo: [AnyHashable: Any] = [
      "accountID": NSNumber(value: 1),
      "sessionRevision": revision.uuidString,
      "forumID": NSNumber(value: 100),
      "threadID": NSNumber(value: 200),
      "firstPostID": NSNumber(value: 201),
      "isAgreed": NSNumber(value: 1),
      "agreeScore": NSNumber(value: 3),
    ]
    XCTAssertNotNil(
      ThreadAgreementChange(
        Notification(name: .threadAgreementDidChange, userInfo: validInfo)
      )
    )

    var missingRevision = validInfo
    missingRevision.removeValue(forKey: "sessionRevision")
    XCTAssertNil(
      ThreadAgreementChange(
        Notification(name: .threadAgreementDidChange, userInfo: missingRevision)
      )
    )

    var invalidBoolean = validInfo
    invalidBoolean["isAgreed"] = NSNumber(value: 2)
    XCTAssertNil(
      ThreadAgreementChange(
        Notification(name: .threadAgreementDidChange, userInfo: invalidBoolean)
      )
    )

    var negativeScore = validInfo
    negativeScore["agreeScore"] = NSNumber(value: -1)
    XCTAssertEqual(
      ThreadAgreementChange(
        Notification(name: .threadAgreementDidChange, userInfo: negativeScore)
      )?.agreeScore,
      0
    )

    var fractionalScore = validInfo
    fractionalScore["agreeScore"] = NSNumber(value: 1.5)
    XCTAssertNil(
      ThreadAgreementChange(
        Notification(name: .threadAgreementDidChange, userInfo: fractionalScore)
      )
    )
  }

  func testOnlyCanonicalFirstPostProducesWritableTarget() {
    let thread = browseThread(agreeCount: 9, disagreeCount: 2)
    let canonical = browsePost(id: 201, threadID: 200, floor: 1, agreeScore: 99)

    let target = ThreadAgreementTarget(thread: thread, firstPost: canonical)
    XCTAssertEqual(target?.forumID, 100)
    XCTAssertEqual(target?.forumName, "Swift")
    XCTAssertEqual(target?.threadID, 200)
    XCTAssertEqual(target?.firstPostID, 201)
    XCTAssertEqual(
      ThreadAgreementContext(thread: thread, firstPost: canonical)?.fallbackAgreeScore,
      7
    )
    XCTAssertNil(
      ThreadAgreementTarget(
        thread: thread,
        firstPost: browsePost(id: 202, threadID: 200, floor: 2)
      )
    )
    XCTAssertNil(
      ThreadAgreementTarget(
        thread: thread,
        firstPost: browsePost(id: 201, threadID: 200, floor: 2)
      )
    )
    XCTAssertNil(
      ThreadAgreementTarget(
        thread: thread,
        firstPost: browsePost(id: 201, threadID: 999, floor: 1)
      )
    )
  }

  private func makeViewModel(
    forumID: Int64 = 100,
    fallbackAgreeScore: Int = 0,
    vault: ThreadAgreementVaultSpy,
    service: ThreadAgreementServiceSpy
  ) -> ThreadAgreementViewModel {
    ThreadAgreementViewModel(
      forumID: forumID,
      forumName: "Swift",
      threadID: 200,
      firstPostID: 201,
      fallbackAgreeScore: fallbackAgreeScore,
      access: AccountAccess(vault: vault, service: service)
    )
  }

  private func session(
    revision: UUID = UUID(),
    credentialComponent: Character = "a"
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: 1,
      username: "user-1",
      displayName: "User 1",
      portrait: "portrait-1",
      bduss: String(repeating: credentialComponent, count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      sessionRevision: revision
    )
  }

  private func agreement(isAgreed: Bool, score: Int) -> ThreadAgreementData {
    ThreadAgreementData(
      userID: 1,
      forumID: 100,
      threadID: 200,
      firstPostID: 201,
      isAgreed: isAgreed,
      agreeScore: score
    )
  }

  private func browseThread(
    agreeCount: Int = 0,
    disagreeCount: Int = 0
  ) -> BrowseThread {
    BrowseThread(
      id: 200,
      forumID: 100,
      forumName: "Swift",
      title: "Thread",
      excerpt: "",
      authorName: "Author",
      replyCount: 1,
      viewCount: 2,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      firstPostID: 201,
      agreeCount: agreeCount,
      disagreeCount: disagreeCount
    )
  }

  private func browsePost(
    id: Int64,
    threadID: Int64,
    floor: Int,
    agreeScore: Int = 0
  ) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: 1,
      authorName: "Author",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: true,
      contents: [],
      agreeScore: agreeScore
    )
  }
}

private struct ThreadAgreementTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private struct ThreadAgreementWriteRequest: Equatable, Sendable {
  let sessionRevision: UUID
  let targetAgreed: Bool
}

private final class ThreadAgreementNotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = [ThreadAgreementChange]()

  func record(_ change: ThreadAgreementChange) {
    lock.withLock { changes.append(change) }
  }

  func snapshot() -> [ThreadAgreementChange] {
    lock.withLock { changes }
  }
}

private actor ThreadAgreementServiceSpy: AccountService {
  private var readsByRevision: [
    UUID: [Result<ThreadAgreementData, ThreadAgreementTestFailure>]
  ]
  private let writesByRevision: [
    UUID: Result<ThreadAgreementData, ThreadAgreementTestFailure>
  ]
  private let writeDelaysByRevision: [UUID: UInt64]
  private let cancelledWriteRevisions: Set<UUID>
  private var readRequests = [UUID]()
  private var writeRequests = [ThreadAgreementWriteRequest]()

  init(
    readsByRevision: [
      UUID: [Result<ThreadAgreementData, ThreadAgreementTestFailure>]
    ] = [:],
    writesByRevision: [
      UUID: Result<ThreadAgreementData, ThreadAgreementTestFailure>
    ] = [:],
    writeDelaysByRevision: [UUID: UInt64] = [:],
    cancelledWriteRevisions: Set<UUID> = []
  ) {
    self.readsByRevision = readsByRevision
    self.writesByRevision = writesByRevision
    self.writeDelaysByRevision = writeDelaysByRevision
    self.cancelledWriteRevisions = cancelledWriteRevisions
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ThreadAgreementTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ThreadAgreementTestFailure(message: "unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ThreadAgreementTestFailure(message: "unexpected forum-membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ThreadAgreementTestFailure(message: "unexpected forum-account-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ThreadAgreementTestFailure(message: "unexpected forum-membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ThreadAgreementTestFailure(message: "unexpected forum-check-in mutation")
  }

  func threadAgreement(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> ThreadAgreementData {
    readRequests.append(session.sessionRevision)
    guard var results = readsByRevision[session.sessionRevision], let result = results.first else {
      throw ThreadAgreementTestFailure(message: "unexpected agreement read")
    }
    if results.count > 1 {
      results.removeFirst()
      readsByRevision[session.sessionRevision] = results
    }
    return try result.get()
  }

  func setThreadAgreed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> ThreadAgreementData {
    writeRequests.append(
      ThreadAgreementWriteRequest(
        sessionRevision: session.sessionRevision,
        targetAgreed: isAgreed
      )
    )
    if let delay = writeDelaysByRevision[session.sessionRevision] {
      try await Task.sleep(nanoseconds: delay)
    }
    if cancelledWriteRevisions.contains(session.sessionRevision) {
      throw CancellationError()
    }
    guard let result = writesByRevision[session.sessionRevision] else {
      throw ThreadAgreementTestFailure(message: "unexpected agreement mutation")
    }
    return try result.get()
  }

  func readRequestCount() -> Int { readRequests.count }
  func readRevisions() -> [UUID] { readRequests }
  func writeRequestCount() -> Int { writeRequests.count }
  func writeRevisions() -> [UUID] { writeRequests.map(\.sessionRevision) }
  func writeTargets() -> [Bool] { writeRequests.map(\.targetAgreed) }
}

private actor ThreadAgreementVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private let activeSessionDelaysByRead: [Int: UInt64]
  private var activeSessionReads = 0

  init(
    session: StoredAccountSession? = nil,
    activeSessionDelaysByRead: [Int: UInt64] = [:]
  ) {
    self.session = session
    self.activeSessionDelaysByRead = activeSessionDelaysByRead
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeSessionReads += 1
    let readNumber = activeSessionReads
    let result = session
    if let delay = activeSessionDelaysByRead[readNumber] {
      try await Task.sleep(nanoseconds: delay)
    }
    return result
  }

  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSessionReadCount() -> Int { activeSessionReads }
}

@MainActor
private func waitForThreadAgreementTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw ThreadAgreementTestFailure(message: "timed out waiting for agreement state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
