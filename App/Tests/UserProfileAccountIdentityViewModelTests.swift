import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserProfileAccountIdentityViewModelTests: XCTestCase {
  func testSignedOutIsResolvedWithoutUserID() async {
    let viewModel = UserProfileAccountIdentityViewModel()
    await viewModel.resolve(
      access: AccountAccess(
        vault: ProfileAccountIdentityVault(session: nil),
        service: ProfileAccountIdentityService()
      )
    )

    XCTAssertTrue(viewModel.isResolved)
    XCTAssertNil(viewModel.userID)
  }

  func testLaterGenerationWinsOverUncooperativeEarlierRead() async throws {
    let old = profileIdentitySession(userID: 1, revision: profileIdentityUUID(1))
    let current = profileIdentitySession(userID: 2, revision: profileIdentityUUID(2))
    let vault = ProfileAccountIdentityVault(session: old)
    let access = AccountAccess(vault: vault, service: ProfileAccountIdentityService())
    let viewModel = UserProfileAccountIdentityViewModel()

    await vault.suspendNextRead(id: 1)
    let oldToken = viewModel.beginResolution()
    let oldRead = Task { await viewModel.resolve(access: access, ifCurrent: oldToken) }
    try await waitForProfileIdentityTest { await vault.hasSuspendedRead(id: 1) }

    await vault.replace(with: current)
    let newToken = viewModel.beginResolution()
    await viewModel.resolve(access: access, ifCurrent: newToken)
    XCTAssertEqual(viewModel.userID, 2)
    XCTAssertTrue(viewModel.isResolved)

    await vault.releaseRead(id: 1)
    await oldRead.value
    XCTAssertEqual(viewModel.userID, 2)
    XCTAssertTrue(viewModel.isResolved)
  }

  func testInvalidateDiscardsLateReadAndClearsEligibility() async throws {
    let vault = ProfileAccountIdentityVault(
      session: profileIdentitySession(userID: 1, revision: profileIdentityUUID(1))
    )
    let access = AccountAccess(vault: vault, service: ProfileAccountIdentityService())
    let viewModel = UserProfileAccountIdentityViewModel()
    await vault.suspendNextRead(id: 1)
    let read = Task { await viewModel.resolve(access: access) }
    try await waitForProfileIdentityTest { await vault.hasSuspendedRead(id: 1) }

    viewModel.invalidate()
    XCTAssertFalse(viewModel.isResolved)
    XCTAssertNil(viewModel.userID)
    await vault.releaseRead(id: 1)
    await read.value

    XCTAssertFalse(viewModel.isResolved)
    XCTAssertNil(viewModel.userID)
  }
}

private struct ProfileAccountIdentityFailure: Error, Sendable {}

private actor ProfileAccountIdentityVault: AccountVault {
  private var session: StoredAccountSession?
  private var nextSuspendedID: Int?
  private var suspended:
    [Int: (CheckedContinuation<StoredAccountSession?, Never>, StoredAccountSession?)] = [:]

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func suspendNextRead(id: Int) {
    nextSuspendedID = id
  }

  func hasSuspendedRead(id: Int) -> Bool { suspended[id] != nil }

  func replace(with session: StoredAccountSession?) {
    self.session = session
  }

  func releaseRead(id: Int) {
    guard let (continuation, value) = suspended.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func activeSession() async throws -> StoredAccountSession? {
    guard let id = nextSuspendedID else { return session }
    nextSuspendedID = nil
    let value = session
    return await withCheckedContinuation { suspended[id] = ($0, value) }
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func upsert(_ session: StoredAccountSession) async throws {}
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws {}
  func removeAll() async throws {}
}

private actor ProfileAccountIdentityService: AccountService {
  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw ProfileAccountIdentityFailure()
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw ProfileAccountIdentityFailure()
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw ProfileAccountIdentityFailure()
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ProfileAccountIdentityFailure()
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw ProfileAccountIdentityFailure()
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw ProfileAccountIdentityFailure()
  }
}

private func profileIdentitySession(userID: Int64, revision: UUID) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "user-\(userID)",
    displayName: "User \(userID)",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    stoken: String(repeating: "s", count: 64),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func profileIdentityUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func waitForProfileIdentityTest(
  timeout: TimeInterval = 2,
  condition: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw ProfileAccountIdentityFailure() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
