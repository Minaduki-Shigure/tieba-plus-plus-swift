import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ForumMembershipViewModelTests: XCTestCase {
  func testInvalidForumNeverReadsAccountOrCallsService() async {
    let vault = MembershipVaultSpy(session: session(userID: 1))
    let service = MembershipServiceSpy()
    let viewModel = makeViewModel(forumID: 0, vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .idle)
    let activeSessionReads = await vault.activeSessionReadCount()
    let membershipRequests = await service.membershipRequestCount()
    XCTAssertEqual(activeSessionReads, 0)
    XCTAssertEqual(membershipRequests, 0)
  }

  func testMembershipChangeNotificationParsesRevisionAndKeepsLegacyCompatibility() throws {
    let revision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    )
    let fields: [AnyHashable: Any] = [
      "accountID": NSNumber(value: 1),
      "forumID": NSNumber(value: 100),
      "isFollowed": NSNumber(value: false),
    ]
    var revisionFields = fields
    revisionFields["sessionRevision"] = revision.uuidString

    XCTAssertEqual(
      ForumMembershipChange(
        Notification(name: .forumMembershipDidChange, userInfo: revisionFields)
      ),
      ForumMembershipChange(
        accountID: 1,
        sessionRevision: revision,
        forumID: 100,
        isFollowed: false
      )
    )
    XCTAssertEqual(
      ForumMembershipChange(Notification(name: .forumMembershipDidChange, userInfo: fields)),
      ForumMembershipChange(accountID: 1, forumID: 100, isFollowed: false)
    )
    revisionFields["sessionRevision"] = "not-a-uuid"
    XCTAssertNil(
      ForumMembershipChange(
        Notification(name: .forumMembershipDidChange, userInfo: revisionFields)
      )
    )
  }

  func testSignedOutStateNeverCallsMembershipService() async {
    let vault = MembershipVaultSpy()
    let service = MembershipServiceSpy()
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .signedOut)
    let membershipRequests = await service.membershipRequestCount()
    XCTAssertEqual(membershipRequests, 0)
  }

  func testLoadsAuthoritativeMembershipForActiveSession() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertNil(viewModel.errorMessage)
  }

  func testLeaseReadFailureStopsWithoutRecursiveMembershipRequests() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active, failsOnEvenReads: true)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    await viewModel.loadIfNeeded()
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: nil))
    XCTAssertEqual(viewModel.errorMessage, "无法读取当前账户，请稍后重试。")
    let activeSessionReads = await vault.activeSessionReadCount()
    let membershipRequests = await service.membershipRequestCount()
    XCTAssertEqual(activeSessionReads, 2)
    XCTAssertEqual(membershipRequests, 1)
  }

  func testReloadFailureRetainsLastKnownMembershipForRetry() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      membershipSequences: [
        1: [
          .success(membership(userID: 1, isFollowed: true)),
          .failure(MembershipTestFailure(message: "read failed")),
        ]
      ]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.reload()

    XCTAssertEqual(viewModel.state, .failed(previouslyFollowed: true))
    XCTAssertEqual(viewModel.errorMessage, "read failed")
  }

  func testFollowSuccessUsesServerStateAndRejectsDuplicateTap() async throws {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: false))],
      mutations: [1: .success(membership(userID: 1, isFollowed: true))],
      suspendedMutationUsers: [1]
    )
    addTeardownBlock { _ = await service.releaseMutation(userID: 1) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let firstMutation = Task { await viewModel.setFollowed(true) }
    await service.waitUntilMutationSuspended(userID: 1)
    await viewModel.setFollowed(true)
    let released = await service.releaseMutation(userID: 1)
    XCTAssertTrue(released)
    await firstMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(mutationRequests, 1)
  }

  func testMatchingMutationNotificationDoesNotReloadBeforeCoordinatorReturns() async throws {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: false))],
      mutations: [1: .success(membership(userID: 1, isFollowed: true))],
      suspendedMutationUsers: [1]
    )
    addTeardownBlock { _ = await service.releaseMutation(userID: 1) }
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let mutation = Task { await viewModel.setFollowed(true) }
    await service.waitUntilMutationSuspended(userID: 1)
    await viewModel.forumMembershipDidChange(
      ForumMembershipChange(
        accountID: active.id,
        sessionRevision: active.sessionRevision,
        forumID: 100,
        isFollowed: true
      )
    )
    XCTAssertEqual(
      viewModel.state,
      .mutating(previouslyFollowed: false, targetFollowed: true)
    )

    let released = await service.releaseMutation(userID: 1)
    XCTAssertTrue(released)
    await mutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    let membershipRequests = await service.membershipRequestCount()
    XCTAssertEqual(membershipRequests, 1)
  }

  func testMutationFailureRestoresPriorStateAndReportsError() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))],
      mutations: [1: .failure(MembershipTestFailure(message: "write failed"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(false)

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertEqual(viewModel.errorMessage, "write failed")
  }

  func testMutationFailureReconcilesServerSideSuccessWithoutRetryingWrite() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      membershipSequences: [
        1: [
          .success(membership(userID: 1, isFollowed: false)),
          .success(membership(userID: 1, isFollowed: true)),
        ]
      ],
      mutations: [1: .failure(MembershipTestFailure(message: "response lost"))]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    await viewModel.setFollowed(true)

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    XCTAssertEqual(viewModel.errorMessage, "response lost")
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(membershipRequests, 2)
    XCTAssertEqual(mutationRequests, 1)
  }

  func testLateLoadFromOldAccountCannotOverwriteNewAccount() async throws {
    let vault = MembershipVaultSpy(session: session(userID: 1, updatedAt: 1))
    let service = MembershipServiceSpy(
      memberships: [
        1: .success(membership(userID: 1, isFollowed: false)),
        2: .success(membership(userID: 2, isFollowed: true)),
      ],
      membershipDelays: [1: 150_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)

    let oldLoad = Task { await viewModel.reload() }
    try await waitForMembershipTest { await service.membershipRequestCount() == 1 }
    await vault.replaceActive(with: session(userID: 2, updatedAt: 2))
    await viewModel.accountSessionDidChange()
    await oldLoad.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    let requestedUserIDs = await service.membershipRequestedUserIDs()
    XCTAssertEqual(requestedUserIDs, [1, 2])
  }

  func testOldAccountMutationCannotOverwriteNewAccountState() async throws {
    let vault = MembershipVaultSpy(session: session(userID: 1, updatedAt: 1))
    let service = MembershipServiceSpy(
      memberships: [
        1: .success(membership(userID: 1, isFollowed: false)),
        2: .success(membership(userID: 2, isFollowed: false)),
      ],
      mutations: [1: .success(membership(userID: 1, isFollowed: true))],
      mutationDelays: [1: 150_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldMutation = Task { await viewModel.setFollowed(true) }
    try await waitForMembershipTest { await service.mutationRequestCount() == 1 }
    await vault.replaceActive(with: session(userID: 2, updatedAt: 2))
    await viewModel.accountSessionDidChange()
    await oldMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: false))
    XCTAssertNil(viewModel.errorMessage)
    let requestedUserIDs = await service.membershipRequestedUserIDs()
    XCTAssertEqual(requestedUserIDs, [1, 2])
  }

  func testSameUserNewRevisionRejectsOldMutationResult() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000011")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000012")
    )
    let oldSession = session(userID: 1, sessionRevision: oldRevision)
    let newSession = session(userID: 1, sessionRevision: newRevision)
    let vault = MembershipVaultSpy(session: oldSession)
    let service = MembershipServiceSpy(
      membershipSequences: [
        1: [
          .success(membership(userID: 1, isFollowed: false)),
          .success(membership(userID: 1, isFollowed: false)),
        ]
      ],
      mutations: [1: .success(membership(userID: 1, isFollowed: true))],
      mutationDelays: [1: 150_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let oldMutation = Task { await viewModel.setFollowed(true) }
    try await waitForMembershipTest { await service.mutationRequestCount() == 1 }
    await vault.replaceActive(with: newSession)
    await viewModel.accountSessionDidChange()
    await oldMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: false))
    XCTAssertNil(viewModel.errorMessage)
  }

  func testCoordinatorPreflightsWritesOnceAndPostsRevisionForDuplicateCallers() async throws {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))],
      mutations: [1: .success(membership(userID: 1, isFollowed: false))],
      suspendedMutationUsers: [1]
    )
    addTeardownBlock { _ = await service.releaseMutation(userID: 1) }
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let request = mutationRequest(session: active)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let first = Task { await coordinator.setFollowed(request) }
    await service.waitUntilMutationSuspended(userID: 1)
    let second = Task { await coordinator.setFollowed(request) }
    try await waitForMembershipTest {
      await coordinator.sharedWaiterCount(
        lease: request.expectedLease,
        forumID: request.forumID
      ) == 1
    }
    let released = await service.releaseMutation(userID: 1)
    XCTAssertTrue(released)
    let firstOutcome = await first.value
    let secondOutcome = await second.value
    let outcomes = [firstOutcome, secondOutcome]

    for outcome in outcomes {
      guard case .confirmed(let confirmation) = outcome else {
        return XCTFail("Expected a confirmed mutation, got \(outcome)")
      }
      XCTAssertEqual(confirmation.source, .writeResponse)
      XCTAssertEqual(confirmation.leaseState, .current)
      XCTAssertEqual(confirmation.change.sessionRevision, active.sessionRevision)
      XCTAssertFalse(confirmation.change.isFollowed)
    }
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestSnapshot()
    XCTAssertEqual(membershipRequests, 1)
    XCTAssertEqual(
      mutationRequests,
      [MembershipMutationRequest(userID: 1, forumID: 100, forumName: "Swift", isFollowed: false)]
    )
    XCTAssertEqual(
      recorder.snapshot(),
      [
        ForumMembershipChange(
          accountID: 1,
          sessionRevision: active.sessionRevision,
          forumID: 100,
          isFollowed: false
        )
      ]
    )
  }

  func testCoordinatorConfirmsServerSideSuccessByOneReadWithoutRetryingWrite() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      membershipSequences: [
        1: [
          .success(membership(userID: 1, isFollowed: true)),
          .success(membership(userID: 1, isFollowed: false)),
        ]
      ],
      mutations: [1: .failure(MembershipTestFailure(message: "response lost"))]
    )
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = await coordinator.setFollowed(mutationRequest(session: active))

    guard case .confirmed(let confirmation) = outcome else {
      return XCTFail("Expected reconciliation to confirm success, got \(outcome)")
    }
    XCTAssertEqual(confirmation.source, .reconciliation)
    XCTAssertEqual(confirmation.warning, "response lost")
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(membershipRequests, 2)
    XCTAssertEqual(mutationRequests, 1)
    XCTAssertEqual(recorder.snapshot().count, 1)
  }

  func testCoordinatorKeepsPriorStateWhenFailureReadStillShowsFollowed() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))],
      mutations: [1: .failure(MembershipTestFailure(message: "write failed"))]
    )
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = await coordinator.setFollowed(mutationRequest(session: active))

    XCTAssertEqual(outcome, .unchanged(isFollowed: true, message: "write failed"))
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(membershipRequests, 2)
    XCTAssertEqual(mutationRequests, 1)
    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testCoordinatorDoesNotAcceptMismatchedWriteResponseAsSuccess() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let mismatched = ForumMembershipData(
      userID: 1,
      forumID: 999,
      forumName: "Swift",
      isFollowed: false
    )
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))],
      mutations: [1: .success(mismatched)]
    )
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = await coordinator.setFollowed(mutationRequest(session: active))

    XCTAssertEqual(
      outcome,
      .unchanged(
        isFollowed: true,
        message: "贴吧返回了不匹配的关注状态，请重新加载后再试。"
      )
    )
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(mutationRequests, 1)
    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testCoordinatorKeepsPriorStateWhenWriteAndReconciliationBothFail() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      membershipSequences: [
        1: [
          .success(membership(userID: 1, isFollowed: true)),
          .failure(MembershipTestFailure(message: "readback failed")),
        ]
      ],
      mutations: [1: .failure(MembershipTestFailure(message: "write failed"))]
    )
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = await coordinator.setFollowed(mutationRequest(session: active))

    XCTAssertEqual(
      outcome,
      .unavailable(previouslyFollowed: true, message: "write failed")
    )
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(membershipRequests, 2)
    XCTAssertEqual(mutationRequests, 1)
    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testCoordinatorPreflightRemovesStaleListRowWithoutSendingWrite() async {
    let active = session(userID: 1)
    let vault = MembershipVaultSpy(session: active)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: false))]
    )
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: active.sessionRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = await coordinator.setFollowed(mutationRequest(session: active))

    guard case .confirmed(let confirmation) = outcome else {
      return XCTFail("Expected preflight confirmation, got \(outcome)")
    }
    XCTAssertEqual(confirmation.source, .preflight)
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(mutationRequests, 0)
    XCTAssertEqual(recorder.snapshot(), [confirmation.change])
  }

  func testCoordinatorRejectsRevisionRotationWhilePreflightIsSuspended() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000051")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000052")
    )
    let oldSession = session(userID: 1, sessionRevision: oldRevision)
    let newSession = session(userID: 1, sessionRevision: newRevision)
    let vault = MembershipVaultSpy(session: oldSession)
    let service = MembershipServiceSpy(
      memberships: [1: .success(membership(userID: 1, isFollowed: true))],
      mutations: [1: .success(membership(userID: 1, isFollowed: false))],
      suspendedMembershipUsers: [1]
    )
    addTeardownBlock { _ = await service.releaseMembership(userID: 1) }
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)
    let recorder = ForumMembershipNotificationRecorder()
    let token = membershipNotificationToken(
      sessionRevision: oldRevision,
      recorder: recorder
    )
    defer { NotificationCenter.default.removeObserver(token) }

    let operation = Task {
      await coordinator.setFollowed(mutationRequest(session: oldSession))
    }
    await service.waitUntilMembershipSuspended(userID: 1)
    await vault.replaceActive(with: newSession)
    let released = await service.releaseMembership(userID: 1)
    XCTAssertTrue(released)
    let outcome = await operation.value

    XCTAssertEqual(outcome, .sessionChanged)
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(mutationRequests, 0)
    XCTAssertTrue(recorder.snapshot().isEmpty)
  }

  func testCoordinatorRejectsChangedRevisionBeforeAnyMembershipRequest() async throws {
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000031")
    )
    let newRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000032")
    )
    let oldSession = session(userID: 1, sessionRevision: oldRevision)
    let vault = MembershipVaultSpy(session: session(userID: 1, sessionRevision: newRevision))
    let service = MembershipServiceSpy()
    let coordinator = ForumMembershipMutationCoordinator(vault: vault, service: service)

    let outcome = await coordinator.setFollowed(mutationRequest(session: oldSession))

    XCTAssertEqual(outcome, .sessionChanged)
    let membershipRequests = await service.membershipRequestCount()
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(membershipRequests, 0)
    XCTAssertEqual(mutationRequests, 0)
  }

  private func mutationRequest(
    session: StoredAccountSession
  ) -> ForumMembershipMutationRequest {
    ForumMembershipMutationRequest(
      forumID: 100,
      forumName: "Swift",
      previouslyFollowed: true,
      targetFollowed: false,
      expectedLease: AccountSessionLease(session),
      verifiesCurrentState: true
    )
  }

  private func membershipNotificationToken(
    sessionRevision: UUID,
    recorder: ForumMembershipNotificationRecorder
  ) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: .forumMembershipDidChange,
      object: nil,
      queue: nil
    ) { notification in
      guard
        let change = ForumMembershipChange(notification),
        change.sessionRevision == sessionRevision,
        change.forumID == 100
      else { return }
      recorder.record(change)
    }
  }

  private func makeViewModel(
    forumID: Int64 = 100,
    vault: MembershipVaultSpy,
    service: MembershipServiceSpy
  ) -> ForumMembershipViewModel {
    ForumMembershipViewModel(
      forumID: forumID,
      forumName: "Swift",
      access: AccountAccess(vault: vault, service: service)
    )
  }

  private func session(
    userID: Int64,
    updatedAt: TimeInterval = 1,
    sessionRevision: UUID = UUID()
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      sessionRevision: sessionRevision
    )
  }

  private func membership(userID: Int64, isFollowed: Bool) -> ForumMembershipData {
    ForumMembershipData(
      userID: userID,
      forumID: 100,
      forumName: "Swift",
      isFollowed: isFollowed
    )
  }
}

private struct MembershipTestFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private struct MembershipMutationRequest: Equatable, Sendable {
  let userID: Int64
  let forumID: Int64
  let forumName: String
  let isFollowed: Bool
}

private final class ForumMembershipNotificationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [ForumMembershipChange] = []

  func record(_ change: ForumMembershipChange) {
    lock.withLock { changes.append(change) }
  }

  func snapshot() -> [ForumMembershipChange] {
    lock.withLock { changes }
  }
}

private actor MembershipServiceSpy: AccountService {
  private var memberships: [Int64: [Result<ForumMembershipData, MembershipTestFailure>]]
  private let mutations: [Int64: Result<ForumMembershipData, MembershipTestFailure>]
  private let membershipDelays: [Int64: UInt64]
  private let mutationDelays: [Int64: UInt64]
  private var suspendedMembershipUsers: Set<Int64>
  private var suspendedMutationUsers: Set<Int64>
  private var membershipUsers: [Int64] = []
  private var mutationUsers: [Int64] = []
  private var mutationRequests: [MembershipMutationRequest] = []
  private var membershipContinuations: [Int64: CheckedContinuation<Void, Never>] = [:]
  private var mutationContinuations: [Int64: CheckedContinuation<Void, Never>] = [:]
  private var membershipSuspensions = Set<Int64>()
  private var mutationSuspensions = Set<Int64>()
  private var membershipSuspensionWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
  private var mutationSuspensionWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

  init(
    memberships: [Int64: Result<ForumMembershipData, MembershipTestFailure>] = [:],
    membershipSequences: [
      Int64: [Result<ForumMembershipData, MembershipTestFailure>]
    ] = [:],
    mutations: [Int64: Result<ForumMembershipData, MembershipTestFailure>] = [:],
    membershipDelays: [Int64: UInt64] = [:],
    mutationDelays: [Int64: UInt64] = [:],
    suspendedMembershipUsers: Set<Int64> = [],
    suspendedMutationUsers: Set<Int64> = []
  ) {
    var membershipScripts = memberships.mapValues { [$0] }
    for (userID, sequence) in membershipSequences {
      membershipScripts[userID] = sequence
    }
    self.memberships = membershipScripts
    self.mutations = mutations
    self.membershipDelays = membershipDelays
    self.mutationDelays = mutationDelays
    self.suspendedMembershipUsers = suspendedMembershipUsers
    self.suspendedMutationUsers = suspendedMutationUsers
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw MembershipTestFailure(message: "unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw MembershipTestFailure(message: "unexpected followed-forum request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    membershipUsers.append(session.id)
    if suspendedMembershipUsers.remove(session.id) != nil {
      await withCheckedContinuation { continuation in
        membershipContinuations[session.id] = continuation
        membershipSuspensions.insert(session.id)
        let waiters = membershipSuspensionWaiters.removeValue(forKey: session.id) ?? []
        waiters.forEach { $0.resume() }
      }
    }
    if let delay = membershipDelays[session.id] {
      try await Task.sleep(nanoseconds: delay)
    }
    guard var results = memberships[session.id], let result = results.first else {
      throw MembershipTestFailure(message: "unexpected membership request")
    }
    if results.count > 1 {
      results.removeFirst()
      memberships[session.id] = results
    }
    return try result.get()
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw MembershipTestFailure(message: "unexpected forum-account-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    mutationUsers.append(session.id)
    mutationRequests.append(
      MembershipMutationRequest(
        userID: session.id,
        forumID: forumID,
        forumName: forumName,
        isFollowed: isFollowed
      )
    )
    if suspendedMutationUsers.remove(session.id) != nil {
      await withCheckedContinuation { continuation in
        mutationContinuations[session.id] = continuation
        mutationSuspensions.insert(session.id)
        let waiters = mutationSuspensionWaiters.removeValue(forKey: session.id) ?? []
        waiters.forEach { $0.resume() }
      }
    }
    if let delay = mutationDelays[session.id] {
      try await Task.sleep(nanoseconds: delay)
    }
    guard let result = mutations[session.id] else {
      throw MembershipTestFailure(message: "unexpected membership mutation")
    }
    return try result.get()
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw MembershipTestFailure(message: "unexpected forum-check-in mutation")
  }

  func membershipRequestCount() -> Int { membershipUsers.count }
  func mutationRequestCount() -> Int { mutationUsers.count }
  func mutationRequestSnapshot() -> [MembershipMutationRequest] { mutationRequests }
  func membershipRequestedUserIDs() -> [Int64] { membershipUsers }

  func waitUntilMembershipSuspended(userID: Int64) async {
    if membershipSuspensions.contains(userID) { return }
    await withCheckedContinuation { continuation in
      membershipSuspensionWaiters[userID, default: []].append(continuation)
    }
  }

  func waitUntilMutationSuspended(userID: Int64) async {
    if mutationSuspensions.contains(userID) { return }
    await withCheckedContinuation { continuation in
      mutationSuspensionWaiters[userID, default: []].append(continuation)
    }
  }

  func releaseMembership(userID: Int64) -> Bool {
    guard let continuation = membershipContinuations.removeValue(forKey: userID) else {
      return false
    }
    membershipSuspensions.remove(userID)
    continuation.resume()
    return true
  }

  func releaseMutation(userID: Int64) -> Bool {
    guard let continuation = mutationContinuations.removeValue(forKey: userID) else {
      return false
    }
    mutationSuspensions.remove(userID)
    continuation.resume()
    return true
  }
}

private actor MembershipVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private let failsOnEvenReads: Bool
  private var activeReads = 0

  init(session: StoredAccountSession? = nil, failsOnEvenReads: Bool = false) {
    self.session = session
    self.failsOnEvenReads = failsOnEvenReads
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    if failsOnEvenReads, activeReads.isMultiple(of: 2) {
      throw MembershipTestFailure(message: "account vault unavailable")
    }
    return session
  }

  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func activeSessionReadCount() -> Int { activeReads }
}

@MainActor
private func waitForMembershipTest(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      throw MembershipTestFailure(message: "timed out waiting for membership state")
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
