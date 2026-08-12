import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserInteractionRestrictionsViewModelTests: XCTestCase {
  func testInvalidSignedOutOwnProfileAndLegacySessionNeverCallService() async {
    let service = InteractionPermissionServiceSpy()

    let invalidVault = InteractionPermissionVaultSpy(session: session(userID: 1))
    let invalid = makeViewModel(targetUserID: 0, vault: invalidVault, service: service)
    await invalid.loadIfNeeded()
    XCTAssertEqual(invalid.state, .hidden)
    let invalidVaultReads = await invalidVault.readCount()
    XCTAssertEqual(invalidVaultReads, 0)

    let signedOut = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: nil),
      service: service
    )
    await signedOut.loadIfNeeded()
    XCTAssertEqual(signedOut.state, .signedOut)

    let ownProfile = makeViewModel(
      targetUserID: 1,
      vault: InteractionPermissionVaultSpy(session: session(userID: 1)),
      service: service
    )
    await ownProfile.loadIfNeeded()
    XCTAssertEqual(ownProfile.state, .hidden)

    let legacy = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: session(userID: 1, full: false)),
      service: service
    )
    await legacy.loadIfNeeded()
    XCTAssertEqual(legacy.state, .failed(previous: nil))
    XCTAssertEqual(
      legacy.errorMessage,
      UserInteractionPermissionError.fullCredentialsRequired.localizedDescription
    )
    let serviceReads = await service.readCount()
    XCTAssertEqual(serviceReads, 0)
  }

  func testLoadMapsAuthoritativeDraftAndRejectsMismatchedContext() async {
    let active = session(userID: 1, revision: uuid(1))
    let expected = permissions(follow: true, interaction: false, chat: true)
    let service = InteractionPermissionServiceSpy(reads: [
      active.sessionRevision: [
        .value(data(userID: 1, permissions: expected)),
        .value(data(userID: 2, permissions: .unrestricted)),
        .value(data(userID: 1, targetUserID: 100, permissions: .unrestricted)),
      ]
    ])
    let viewModel = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )

    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.state, .ready(expected))
    XCTAssertEqual(viewModel.draft, expected)
    XCTAssertFalse(viewModel.hasUnsavedChanges)

    viewModel.setBlocksInteraction(true)
    XCTAssertTrue(viewModel.hasUnsavedChanges)
    for _ in 0..<2 {
      await viewModel.reload()
      XCTAssertEqual(viewModel.state, .failed(previous: expected))
      XCTAssertEqual(viewModel.draft, expected)
      XCTAssertFalse(viewModel.hasUnsavedChanges)
      XCTAssertEqual(
        viewModel.errorMessage,
        "贴吧返回了不匹配的互动权限，请重新加载后再试。"
      )
    }
  }

  func testDraftNeedsConfirmationAndCancelDoesNotWrite() async {
    let active = session(userID: 1, revision: uuid(1))
    let initial = UserInteractionPermissions.unrestricted
    let service = InteractionPermissionServiceSpy(reads: [
      active.sessionRevision: [.value(data(userID: 1, permissions: initial))]
    ])
    let viewModel = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()

    viewModel.setBlocksFollow(true)
    viewModel.setBlocksInteraction(true)
    viewModel.setBlocksChat(true)
    XCTAssertTrue(viewModel.hasUnsavedChanges)
    XCTAssertTrue(viewModel.canRequestSave)
    var writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)

    viewModel.requestSaveConfirmation()
    XCTAssertEqual(viewModel.pendingConfirmation, viewModel.draft)
    XCTAssertFalse(viewModel.isEditingEnabled)
    writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 0)
    viewModel.cancelSaveConfirmation()
    XCTAssertNil(viewModel.pendingConfirmation)
    XCTAssertTrue(viewModel.isEditingEnabled)

    viewModel.setBlocksFollow(false)
    viewModel.setBlocksInteraction(false)
    viewModel.setBlocksChat(false)
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    XCTAssertFalse(viewModel.canRequestSave)
  }

  func testConfirmedSaveIsSingleFlightAndNeedsExactReturnedState() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let initial = UserInteractionPermissions.unrestricted
    let desired = permissions(follow: true, interaction: true, chat: false)
    let service = InteractionPermissionServiceSpy(
      reads: [active.sessionRevision: [.value(data(userID: 1, permissions: initial))]],
      writes: [active.sessionRevision: [
        .suspended(id: 1, data: data(userID: 1, permissions: desired))
      ]]
    )
    addTeardownBlock { await service.releaseAll() }
    let viewModel = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.setBlocksFollow(true)
    viewModel.setBlocksInteraction(true)
    viewModel.requestSaveConfirmation()

    let save = Task { await viewModel.confirmSave() }
    try await waitForInteractionPermissionTest { await service.writeCount() == 1 }
    XCTAssertEqual(viewModel.state, .mutating(previous: initial, requested: desired))
    XCTAssertTrue(viewModel.preventsInteractiveDismiss)
    await viewModel.confirmSave()
    var writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)

    await service.release(id: 1)
    await save.value
    XCTAssertEqual(viewModel.state, .ready(desired))
    XCTAssertEqual(viewModel.draft, desired)
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    let readCount = await service.readCount()
    XCTAssertEqual(readCount, 1)
  }

  func testConflictingReadbackPublishesServerStateAsFailed() async {
    let active = session(userID: 1, revision: uuid(1))
    let initial = UserInteractionPermissions.unrestricted
    let desired = permissions(follow: true, interaction: false, chat: false)
    let server = permissions(follow: false, interaction: true, chat: false)
    let service = InteractionPermissionServiceSpy(
      reads: [active.sessionRevision: [.value(data(userID: 1, permissions: initial))]],
      writes: [active.sessionRevision: [.value(data(userID: 1, permissions: server))]]
    )
    let viewModel = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.setBlocksFollow(true)
    XCTAssertEqual(viewModel.draft, desired)
    viewModel.requestSaveConfirmation()
    await viewModel.confirmSave()

    XCTAssertEqual(viewModel.state, .failed(previous: server))
    XCTAssertEqual(viewModel.draft, server)
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    let writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testKnownFailureKeepsDraftRetryableButOutcomeUnknownLocksUntilReload() async {
    let active = session(userID: 1, revision: uuid(1))
    let initial = UserInteractionPermissions.unrestricted
    let desired = permissions(follow: false, interaction: false, chat: true)
    let service = InteractionPermissionServiceSpy(
      reads: [active.sessionRevision: [
        .value(data(userID: 1, permissions: initial)),
        .value(data(userID: 1, permissions: desired)),
      ]],
      writes: [active.sessionRevision: [.failure("server rejected"), .outcomeUnknown]]
    )
    let viewModel = makeViewModel(
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )
    await viewModel.loadIfNeeded()
    viewModel.setBlocksChat(true)
    viewModel.requestSaveConfirmation()
    await viewModel.confirmSave()

    XCTAssertEqual(viewModel.state, .failed(previous: initial))
    XCTAssertEqual(viewModel.draft, desired)
    XCTAssertTrue(viewModel.canRequestSave)
    XCTAssertEqual(viewModel.errorMessage, "server rejected")

    viewModel.requestSaveConfirmation()
    await viewModel.confirmSave()
    XCTAssertEqual(viewModel.state, .outcomeUnknown(previous: initial))
    XCTAssertEqual(viewModel.draft, initial)
    XCTAssertFalse(viewModel.isEditingEnabled)
    XCTAssertFalse(viewModel.canRequestSave)
    var writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 2)

    await viewModel.loadIfNeeded()
    let readCount = await service.readCount()
    XCTAssertEqual(readCount, 1)
    await viewModel.reload()
    XCTAssertEqual(viewModel.state, .ready(desired))
    XCTAssertTrue(viewModel.isEditingEnabled)
    writeCount = await service.writeCount()
    XCTAssertEqual(writeCount, 2)
  }

  func testAccountRotationSynchronouslyInvalidatesAndDropsLateResult() async throws {
    let old = session(userID: 1, revision: uuid(1), credential: "a")
    let rotated = session(userID: 1, revision: uuid(2), credential: "b")
    let stale = permissions(follow: true, interaction: true, chat: true)
    let service = InteractionPermissionServiceSpy(reads: [
      old.sessionRevision: [.suspended(id: 1, data: data(userID: 1, permissions: stale))]
    ])
    addTeardownBlock { await service.releaseAll() }
    let vault = InteractionPermissionVaultSpy(session: old)
    let viewModel = makeViewModel(vault: vault, service: service)

    let load = Task { await viewModel.reload() }
    try await waitForInteractionPermissionTest { await service.readCount() == 1 }
    await vault.replace(with: rotated)
    viewModel.invalidateForAccountSessionChange()
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.draft, .unrestricted)

    await service.release(id: 1)
    await load.value
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.errorMessage)
  }

  func testPresentationDisappearCancelsWaiterAndTargetStateDoesNotLeak() async throws {
    let active = session(userID: 1, revision: uuid(1))
    let stale = permissions(follow: true, interaction: false, chat: true)
    let service = InteractionPermissionServiceSpy(reads: [
      active.sessionRevision: [.suspended(id: 1, data: data(userID: 1, permissions: stale))]
    ])
    addTeardownBlock { await service.releaseAll() }
    let first = makeViewModel(
      targetUserID: 99,
      vault: InteractionPermissionVaultSpy(session: active),
      service: service
    )
    let load = Task { await first.reload() }
    try await waitForInteractionPermissionTest { await service.readCount() == 1 }
    first.presentationDidDisappear()
    await service.release(id: 1)
    await load.value
    XCTAssertEqual(first.state, .idle)
    XCTAssertEqual(first.draft, .unrestricted)

    let secondService = InteractionPermissionServiceSpy(reads: [
      active.sessionRevision: [
        .value(data(userID: 1, targetUserID: 100, permissions: .unrestricted))
      ]
    ])
    let second = makeViewModel(
      targetUserID: 100,
      vault: InteractionPermissionVaultSpy(session: active),
      service: secondService
    )
    await second.loadIfNeeded()
    XCTAssertEqual(second.state, .ready(.unrestricted))
  }

  private func makeViewModel(
    targetUserID: Int64 = 99,
    vault: InteractionPermissionVaultSpy,
    service: InteractionPermissionServiceSpy
  ) -> UserInteractionRestrictionsViewModel {
    UserInteractionRestrictionsViewModel(
      targetUserID: targetUserID,
      access: AccountAccess(vault: vault, service: service)
    )
  }

  private func data(
    userID: Int64,
    targetUserID: Int64 = 99,
    permissions: UserInteractionPermissions
  ) -> UserInteractionPermissionData {
    UserInteractionPermissionData(
      userID: userID,
      targetUserID: targetUserID,
      permissions: permissions
    )
  }

  private func permissions(
    follow: Bool,
    interaction: Bool,
    chat: Bool
  ) -> UserInteractionPermissions {
    UserInteractionPermissions(
      blocksFollow: follow,
      blocksInteraction: interaction,
      blocksChat: chat
    )
  }

  private func session(
    userID: Int64,
    revision: UUID = UUID(),
    credential: Character = "s",
    full: Bool = true
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait",
      bduss: String(repeating: credential, count: 192),
      stoken: full ? String(repeating: credential, count: 64) : nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct InteractionPermissionRequest: Equatable, Sendable {
  let userID: Int64
  let revision: UUID
  let targetUserID: Int64
  let permissions: UserInteractionPermissions?
}

private enum InteractionPermissionReadScript: Sendable {
  case value(UserInteractionPermissionData)
  case suspended(id: Int, data: UserInteractionPermissionData)
}

private enum InteractionPermissionWriteScript: Sendable {
  case value(UserInteractionPermissionData)
  case failure(String)
  case outcomeUnknown
  case suspended(id: Int, data: UserInteractionPermissionData)
}

private struct InteractionPermissionFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor InteractionPermissionServiceSpy: AccountService {
  private var reads: [UUID: [InteractionPermissionReadScript]]
  private var writes: [UUID: [InteractionPermissionWriteScript]]
  private var readRequests: [InteractionPermissionRequest] = []
  private var writeRequests: [InteractionPermissionRequest] = []
  private var suspended:
    [Int: (CheckedContinuation<UserInteractionPermissionData, Never>, UserInteractionPermissionData)] = [:]

  init(
    reads: [UUID: [InteractionPermissionReadScript]] = [:],
    writes: [UUID: [InteractionPermissionWriteScript]] = [:]
  ) {
    self.reads = reads
    self.writes = writes
  }

  func userInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64
  ) async throws -> UserInteractionPermissionData {
    readRequests.append(request(session, targetUserID, nil))
    guard var scripts = reads[session.sessionRevision], !scripts.isEmpty else {
      throw InteractionPermissionFailure(message: "Unexpected interaction permission read")
    }
    let script = scripts.removeFirst()
    reads[session.sessionRevision] = scripts
    switch script {
    case .value(let data):
      return data
    case .suspended(let id, let data):
      return await withCheckedContinuation { suspended[id] = ($0, data) }
    }
  }

  func setUserInteractionPermissions(
    session: StoredAccountSession,
    targetUserID: Int64,
    permissions: UserInteractionPermissions
  ) async throws -> UserInteractionPermissionData {
    writeRequests.append(request(session, targetUserID, permissions))
    guard var scripts = writes[session.sessionRevision], !scripts.isEmpty else {
      throw InteractionPermissionFailure(message: "Unexpected interaction permission write")
    }
    let script = scripts.removeFirst()
    writes[session.sessionRevision] = scripts
    switch script {
    case .value(let data):
      return data
    case .failure(let message):
      throw InteractionPermissionFailure(message: message)
    case .outcomeUnknown:
      throw UserInteractionPermissionError.outcomeUnknown
    case .suspended(let id, let data):
      return await withCheckedContinuation { suspended[id] = ($0, data) }
    }
  }

  func readCount() -> Int { readRequests.count }
  func writeCount() -> Int { writeRequests.count }

  func release(id: Int) {
    guard let (continuation, data) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(returning: data)
  }

  func releaseAll() {
    let values = suspended.values
    suspended.removeAll()
    values.forEach { continuation, data in continuation.resume(returning: data) }
  }

  private func request(
    _ session: StoredAccountSession,
    _ targetUserID: Int64,
    _ permissions: UserInteractionPermissions?
  ) -> InteractionPermissionRequest {
    InteractionPermissionRequest(
      userID: session.id,
      revision: session.sessionRevision,
      targetUserID: targetUserID,
      permissions: permissions
    )
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw InteractionPermissionFailure(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw InteractionPermissionFailure(message: "Unexpected followed forums")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw InteractionPermissionFailure(message: "Unexpected membership")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw InteractionPermissionFailure(message: "Unexpected state")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw InteractionPermissionFailure(message: "Unexpected follow")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw InteractionPermissionFailure(message: "Unexpected check in")
  }
}

private actor InteractionPermissionVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var reads = 0

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func activeSession() async throws -> StoredAccountSession? {
    reads += 1
    return session
  }

  func replace(with session: StoredAccountSession?) {
    self.session = session
  }

  func readCount() -> Int { reads }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}
}

@MainActor
private func waitForInteractionPermissionTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw InteractionPermissionFailure(message: "Timed out")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
