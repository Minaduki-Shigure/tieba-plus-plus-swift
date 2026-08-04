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
      mutationDelays: [1: 120_000_000]
    )
    let viewModel = makeViewModel(vault: vault, service: service)
    await viewModel.loadIfNeeded()

    let firstMutation = Task { await viewModel.setFollowed(true) }
    try await waitForMembershipTest { await service.mutationRequestCount() == 1 }
    await viewModel.setFollowed(true)
    await firstMutation.value

    XCTAssertEqual(viewModel.state, .ready(isFollowed: true))
    let mutationRequests = await service.mutationRequestCount()
    XCTAssertEqual(mutationRequests, 1)
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

private actor MembershipServiceSpy: AccountService {
  private var memberships: [Int64: [Result<ForumMembershipData, MembershipTestFailure>]]
  private let mutations: [Int64: Result<ForumMembershipData, MembershipTestFailure>]
  private let membershipDelays: [Int64: UInt64]
  private let mutationDelays: [Int64: UInt64]
  private var membershipUsers: [Int64] = []
  private var mutationUsers: [Int64] = []

  init(
    memberships: [Int64: Result<ForumMembershipData, MembershipTestFailure>] = [:],
    membershipSequences: [
      Int64: [Result<ForumMembershipData, MembershipTestFailure>]
    ] = [:],
    mutations: [Int64: Result<ForumMembershipData, MembershipTestFailure>] = [:],
    membershipDelays: [Int64: UInt64] = [:],
    mutationDelays: [Int64: UInt64] = [:]
  ) {
    var membershipScripts = memberships.mapValues { [$0] }
    for (userID, sequence) in membershipSequences {
      membershipScripts[userID] = sequence
    }
    self.memberships = membershipScripts
    self.mutations = mutations
    self.membershipDelays = membershipDelays
    self.mutationDelays = mutationDelays
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
  func membershipRequestedUserIDs() -> [Int64] { membershipUsers }
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
