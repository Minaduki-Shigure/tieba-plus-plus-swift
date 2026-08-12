import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserRelationshipViewModelTests: XCTestCase {
  func testInvalidTargetIsHiddenWithoutReadingAccountOrCallingService() async {
    let vault = RelationshipVaultSpy(session: session(userID: 1, revision: uuid(1)))
    let service = RelationshipServiceSpy()
    let viewModel = makeViewModel(targetUserID: 0, vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .hidden)
    let activeSessionReads = await vault.activeSessionReadCount()
    let readRequests = await service.readRequestCount()
    XCTAssertEqual(activeSessionReads, 0)
    XCTAssertEqual(readRequests, 0)
  }

  func testSignedOutAndOwnProfileHideRelationshipWithoutCallingService() async {
    let signedOutVault = RelationshipVaultSpy(session: nil)
    let ownProfileVault = RelationshipVaultSpy(session: session(userID: 7, revision: uuid(1)))
    let service = RelationshipServiceSpy()
    let signedOut = makeViewModel(vault: signedOutVault, service: service)
    let ownProfile = makeViewModel(targetUserID: 7, vault: ownProfileVault, service: service)

    await signedOut.loadIfNeeded()
    await ownProfile.loadIfNeeded()

    XCTAssertEqual(signedOut.state, .signedOut)
    XCTAssertEqual(ownProfile.state, .hidden)
    let readRequests = await service.readRequestCount()
    XCTAssertEqual(readRequests, 0)
  }

  func testFullCredentialsAreRequiredBeforeRelationshipRead() async {
    let active = session(userID: 1, revision: uuid(1), hasFullCredentials: false)
    let vault = RelationshipVaultSpy(session: active)
    let service = RelationshipServiceSpy()
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: nil))
    XCTAssertEqual(viewModel.errorMessage, "此账户需要重新登录，才能读取用户关注状态。")
    let readRequests = await service.readRequestCount()
    XCTAssertEqual(readRequests, 0)
  }

  func testLoadsBoundRelationshipAndPreservesItAcrossReadFailures() async {
    let active = session(userID: 1, revision: uuid(1))
    let initial = relationship(userID: 1, isFollowed: true)
    let service = RelationshipServiceSpy(reads: [
      active.sessionRevision: [
        .value(initial),
        .failure("read unavailable"),
        .value(relationship(userID: 2, isFollowed: false)),
        .value(relationship(userID: 1, targetUserID: 100, isFollowed: false)),
      ]
    ])
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))

    await viewModel.reload()
    XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: true))
    XCTAssertEqual(viewModel.errorMessage, "read unavailable")

    for _ in 0..<2 {
      await viewModel.reload()
      XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: true))
      XCTAssertEqual(
        viewModel.errorMessage,
        "贴吧返回了不匹配的用户关注状态，请重新加载后再试。"
      )
    }

    let requests = await service.readRequestsSnapshot()
    XCTAssertEqual(requests.map(\.userID), [1, 1, 1, 1])
    XCTAssertEqual(requests.map(\.targetUserID), [99, 99, 99, 99])
  }

  func testPostRequestLeaseChangeDiscardsResultWithoutNotification() async throws {
    let oldSession = session(userID: 1, revision: uuid(1))
    let newSession = session(userID: 2, revision: uuid(2))
    let service = RelationshipServiceSpy(reads: [
      oldSession.sessionRevision: [
        .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
      ]
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)

    let load = Task { await viewModel.reload() }
    try await waitForRelationshipTest { await service.readRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await service.releaseRead(id: 1)
    await load.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testSameUserCredentialRotationInvalidatesOldLoadAndPublishesNewLease() async throws {
    let oldSession = session(userID: 1, revision: uuid(1), credential: "a")
    let newSession = session(userID: 1, revision: uuid(2), credential: "b")
    let stale = relationship(userID: 1, isFollowed: true)
    let replacement = relationship(userID: 1, isFollowed: false)
    let service = RelationshipServiceSpy(reads: [
      oldSession.sessionRevision: [.suspended(id: 1, value: stale)],
      newSession.sessionRevision: [.value(replacement)],
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)

    let oldLoad = Task { await viewModel.reload() }
    try await waitForRelationshipTest { await service.readRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await service.releaseRead(id: 1)
    await oldLoad.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: false))
    XCTAssertNil(viewModel.errorMessage)
    let revisions = await service.readRequestsSnapshot().map(\.sessionRevision)
    XCTAssertEqual(revisions, [oldSession.sessionRevision, newSession.sessionRevision])
  }

  func testNoOpAndConcurrentTapsNeverIssueMoreThanOneMutation() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let service = RelationshipServiceSpy(
      reads: [active.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))]],
      writes: [
        active.sessionRevision: [
          .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
        ]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(false)
    var writeRequests = await service.writeRequestCount()
    XCTAssertEqual(writeRequests, 0)

    let first = Task { await viewModel.setFollowed(true) }
    try await waitForRelationshipTest { await service.writeRequestCount() == 1 }
    await viewModel.setFollowed(true)
    await viewModel.setFollowed(false)
    writeRequests = await service.writeRequestCount()
    XCTAssertEqual(writeRequests, 1)

    await service.releaseWrite(id: 1)
    await first.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertNil(viewModel.errorMessage)
    writeRequests = await service.writeRequestCount()
    XCTAssertEqual(writeRequests, 1)
  }

  func testMutationUsesReturnedReadbackStateWithoutIssuingAnotherRead() async {
    let active = session(userID: 1, revision: uuid(1))
    let service = RelationshipServiceSpy(
      reads: [active.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))]],
      writes: [
        active.sessionRevision: [.value(relationship(userID: 1, isFollowed: true))]
      ]
    )
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(true)

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertNil(viewModel.errorMessage)
    let readRequests = await service.readRequestCount()
    let writeRequests = await service.writeRequestCount()
    XCTAssertEqual(readRequests, 1)
    XCTAssertEqual(writeRequests, 1)
  }

  func testUnchangedMutationReadbackPublishesServerStateAndVisibleError() async {
    let active = session(userID: 1, revision: uuid(1))
    let service = RelationshipServiceSpy(
      reads: [active.sessionRevision: [.value(relationship(userID: 1, isFollowed: true))]],
      writes: [
        active.sessionRevision: [.value(relationship(userID: 1, isFollowed: true))]
      ]
    )
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(false)

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertEqual(
      viewModel.errorMessage,
      "贴吧没有确认新的用户关注状态，请重新加载后再试。"
    )
    let readRequests = await service.readRequestCount()
    let writeRequests = await service.writeRequestCount()
    XCTAssertEqual(readRequests, 1)
    XCTAssertEqual(writeRequests, 1)
  }

  func testFailedMutationKeepsPreviousStateWithoutAppLevelReadback() async {
    let active = session(userID: 1, revision: uuid(1))
    let service = RelationshipServiceSpy(
      reads: [active.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))]],
      writes: [active.sessionRevision: [.failure("readback failed")]]
    )
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(true)

    XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: false))
    XCTAssertEqual(viewModel.errorMessage, "readback failed")
    let readRequests = await service.readRequestCount()
    let writeRequests = await service.writeRequestCount()
    XCTAssertEqual(readRequests, 1)
    XCTAssertEqual(writeRequests, 1)
  }

  func testAccountSwitchBeforeFailedMutationReturnsCannotPublishOldFailure() async throws {
    let oldSession = session(userID: 1, revision: uuid(1))
    let newSession = session(userID: 2, revision: uuid(2))
    let service = RelationshipServiceSpy(
      reads: [
        oldSession.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))]
      ],
      writes: [
        oldSession.sessionRevision: [.suspendedFailure(id: 1, message: "old failure")]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldMutation = Task { await viewModel.setFollowed(true) }
    try await waitForRelationshipTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await service.releaseWriteFailure(id: 1)
    await oldMutation.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.errorMessage)
    let writeRequests = await service.writeRequestCount()
    XCTAssertEqual(writeRequests, 1)
  }

  func testAccountSwitchDuringMutationRejectsOldResultAndLoadsNewAccount() async throws {
    let oldSession = session(userID: 1, revision: uuid(1))
    let newSession = session(userID: 2, revision: uuid(2))
    let service = RelationshipServiceSpy(
      reads: [
        oldSession.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))],
        newSession.sessionRevision: [.value(relationship(userID: 2, isFollowed: false))],
      ],
      writes: [
        oldSession.sessionRevision: [
          .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
        ]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldMutation = Task { await viewModel.setFollowed(true) }
    try await waitForRelationshipTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await viewModel.setFollowed(true)
    let writesWhileOldRequestIsRunning = await service.writeRequestCount()
    XCTAssertEqual(writesWhileOldRequestIsRunning, 1)
    await service.releaseWrite(id: 1)
    await oldMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: false))
    XCTAssertNil(viewModel.errorMessage)
    let readRevisions = await service.readRequestsSnapshot().map(\.sessionRevision)
    XCTAssertEqual(readRevisions, [oldSession.sessionRevision, newSession.sessionRevision])
    let writeRequests = await service.writeRequestCount()
    XCTAssertEqual(writeRequests, 1)
  }

  func testSameUserReloginDuringMutationRejectsOldRevisionResult() async throws {
    let oldSession = session(userID: 1, revision: uuid(1), credential: "a")
    let newSession = session(userID: 1, revision: uuid(2), credential: "b")
    let service = RelationshipServiceSpy(
      reads: [
        oldSession.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))],
        newSession.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))],
      ],
      writes: [
        oldSession.sessionRevision: [
          .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
        ]
      ]
    )
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: oldSession)
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldMutation = Task { await viewModel.setFollowed(true) }
    try await waitForRelationshipTest { await service.writeRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await service.releaseWrite(id: 1)
    await oldMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: false))
    XCTAssertNil(viewModel.errorMessage)
    let revisions = await service.readRequestsSnapshot().map(\.sessionRevision)
    XCTAssertEqual(revisions, [oldSession.sessionRevision, newSession.sessionRevision])
  }

  func testLogoutInvalidatesSuspendedReadAndPublishesSignedOutState() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let service = RelationshipServiceSpy(reads: [
      active.sessionRevision: [
        .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
      ]
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = RelationshipVaultSpy(session: active)
    let viewModel = makeViewModel(vault: vault, service: service)

    let oldLoad = Task { await viewModel.reload() }
    try await waitForRelationshipTest { await service.readRequestCount() == 1 }
    await vault.replaceActive(with: nil)
    await viewModel.accountSessionDidChange()
    await service.releaseRead(id: 1)
    await oldLoad.value

    XCTAssertEqual(viewModel.state, .signedOut)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testCancelSuppressesUncooperativeLateLoadAndMutationResults() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let loadService = RelationshipServiceSpy(reads: [
      active.sessionRevision: [
        .suspended(id: 1, value: relationship(userID: 1, isFollowed: true))
      ]
    ])
    addTeardownBlock { await loadService.releaseAll() }
    let loadViewModel = makeViewModel(
      vault: RelationshipVaultSpy(session: active),
      service: loadService
    )

    let lateLoad = Task { await loadViewModel.reload() }
    try await waitForRelationshipTest { await loadService.readRequestCount() == 1 }
    loadViewModel.cancel()
    await loadService.releaseRead(id: 1)
    await lateLoad.value
    XCTAssertEqual(loadViewModel.state, .idle)
    XCTAssertNil(loadViewModel.errorMessage)

    let mutationService = RelationshipServiceSpy(
      reads: [active.sessionRevision: [.value(relationship(userID: 1, isFollowed: false))]],
      writes: [
        active.sessionRevision: [
          .suspended(id: 2, value: relationship(userID: 1, isFollowed: true))
        ]
      ]
    )
    addTeardownBlock { await mutationService.releaseAll() }
    let mutationViewModel = makeViewModel(
      vault: RelationshipVaultSpy(session: active),
      service: mutationService
    )
    await mutationViewModel.loadIfNeeded()

    let lateMutation = Task { await mutationViewModel.setFollowed(true) }
    try await waitForRelationshipTest { await mutationService.writeRequestCount() == 1 }
    mutationViewModel.cancel()
    await mutationService.releaseWrite(id: 2)
    await lateMutation.value

    XCTAssertEqual(mutationViewModel.state, .idle)
    XCTAssertNil(mutationViewModel.errorMessage)
  }

  private func makeViewModel(
    targetUserID: Int64 = 99,
    vault: RelationshipVaultSpy,
    service: RelationshipServiceSpy
  ) -> UserRelationshipViewModel {
    UserRelationshipViewModel(
      targetUserID: targetUserID,
      access: AccountAccess(vault: vault, service: service)
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
      portrait: "portrait-\(userID)",
      bduss: String(repeating: credential, count: 192),
      stoken: hasFullCredentials ? String(repeating: credential, count: 64) : nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func relationship(
    userID: Int64,
    targetUserID: Int64 = 99,
    isFollowed: Bool
  ) -> UserRelationshipData {
    UserRelationshipData(
      userID: userID,
      targetUserID: targetUserID,
      isFollowed: isFollowed
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct RelationshipRequest: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID
  let targetUserID: Int64
  let targetFollowed: Bool?
}

private enum RelationshipReadScript: Sendable {
  case value(UserRelationshipData)
  case failure(String)
  case suspended(id: Int, value: UserRelationshipData)
}

private enum RelationshipWriteScript: Sendable {
  case value(UserRelationshipData)
  case failure(String)
  case cancelled
  case suspended(id: Int, value: UserRelationshipData)
  case suspendedFailure(id: Int, message: String)
}

private struct RelationshipTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor RelationshipServiceSpy: AccountService {
  private var reads: [UUID: [RelationshipReadScript]]
  private var writes: [UUID: [RelationshipWriteScript]]
  private var readRequests: [RelationshipRequest] = []
  private var writeRequests: [RelationshipRequest] = []
  private var suspendedReads:
    [Int: (CheckedContinuation<UserRelationshipData, Never>, UserRelationshipData)] = [:]
  private var suspendedWrites:
    [Int: (CheckedContinuation<UserRelationshipData, Never>, UserRelationshipData)] = [:]
  private var suspendedWriteFailures:
    [Int: (CheckedContinuation<Void, Never>, String)] = [:]

  init(
    reads: [UUID: [RelationshipReadScript]] = [:],
    writes: [UUID: [RelationshipWriteScript]] = [:]
  ) {
    self.reads = reads
    self.writes = writes
  }

  func userRelationship(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserRelationshipData {
    readRequests.append(
      RelationshipRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        targetUserID: targetUserID,
        targetFollowed: nil
      )
    )
    guard var scripts = reads[session.sessionRevision], !scripts.isEmpty else {
      throw RelationshipTestFailure(message: "Unexpected relationship read")
    }
    let script = scripts.removeFirst()
    reads[session.sessionRevision] = scripts
    switch script {
    case .value(let relationship):
      return relationship
    case .failure(let message):
      throw RelationshipTestFailure(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedReads[id] = ($0, value) }
    }
  }

  func setUserFollowed(
    session: StoredAccountSession,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> UserRelationshipData {
    writeRequests.append(
      RelationshipRequest(
        userID: session.id,
        sessionRevision: session.sessionRevision,
        targetUserID: targetUserID,
        targetFollowed: isFollowed
      )
    )
    guard var scripts = writes[session.sessionRevision], !scripts.isEmpty else {
      throw RelationshipTestFailure(message: "Unexpected relationship write")
    }
    let script = scripts.removeFirst()
    writes[session.sessionRevision] = scripts
    switch script {
    case .value(let relationship):
      return relationship
    case .failure(let message):
      throw RelationshipTestFailure(message: message)
    case .cancelled:
      throw CancellationError()
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedWrites[id] = ($0, value) }
    case .suspendedFailure(let id, let message):
      await withCheckedContinuation { suspendedWriteFailures[id] = ($0, message) }
      throw RelationshipTestFailure(message: message)
    }
  }

  func releaseRead(id: Int) {
    guard let (continuation, value) = suspendedReads.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func releaseWrite(id: Int) {
    guard let (continuation, value) = suspendedWrites.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func releaseWriteFailure(id: Int) {
    guard let (continuation, _) = suspendedWriteFailures.removeValue(forKey: id) else { return }
    continuation.resume()
  }

  func releaseAll() {
    let reads = suspendedReads.values
    let writes = suspendedWrites.values
    let writeFailures = suspendedWriteFailures.values
    suspendedReads.removeAll()
    suspendedWrites.removeAll()
    suspendedWriteFailures.removeAll()
    reads.forEach { continuation, value in continuation.resume(returning: value) }
    writes.forEach { continuation, value in continuation.resume(returning: value) }
    writeFailures.forEach { continuation, _ in continuation.resume() }
  }

  func readRequestCount() -> Int { readRequests.count }
  func writeRequestCount() -> Int { writeRequests.count }
  func readRequestsSnapshot() -> [RelationshipRequest] { readRequests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw RelationshipTestFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw RelationshipTestFailure(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw RelationshipTestFailure(message: "Unexpected forum membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw RelationshipTestFailure(message: "Unexpected forum account state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw RelationshipTestFailure(message: "Unexpected forum mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw RelationshipTestFailure(message: "Unexpected check-in request")
  }
}

private actor RelationshipVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var activeReads = 0

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    return session
  }

  func activeSessionReadCount() -> Int { activeReads }
  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
}

@MainActor
private func waitForRelationshipTest(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    if Date() >= deadline {
      XCTFail("Timed out waiting for user relationship state")
      return
    }
    await Task.yield()
  }
}
