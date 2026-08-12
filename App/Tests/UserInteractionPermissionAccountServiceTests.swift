import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class UserInteractionPermissionAccountServiceTests: XCTestCase {
  func testReadUsesFullCredentialAndMapsExactContext() async throws {
    let expected = coreState(follow: true, interaction: false, chat: true)
    let client = UserInteractionPermissionClientSpy(readResult: .success(expected))
    let service = TiebaCoreAccountService(client: client)

    let result = try await service.userInteractionPermissions(
      session: session(cookieName: .bdussBFESS),
      targetUserID: 9
    )

    XCTAssertEqual(result.userID, 7)
    XCTAssertEqual(result.targetUserID, 9)
    XCTAssertEqual(
      result.permissions,
      UserInteractionPermissions(
        blocksFollow: true,
        blocksInteraction: false,
        blocksChat: true
      )
    )
    let requests = await client.readRequestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        UserInteractionPermissionClientRequest(
          userID: 7,
          targetUserID: 9,
          permissions: nil,
          bdussBytes: 192,
          stokenBytes: 64,
          cookieName: .bdussBFESS
        )
      ]
    )
  }

  func testReadAndWriteRejectInvalidInputBeforeCore() async {
    let client = UserInteractionPermissionClientSpy()
    let service = TiebaCoreAccountService(client: client)

    for target in [Int64(0), 7] {
      await assertInteractionPermissionError {
        try await service.userInteractionPermissions(session: session(), targetUserID: target)
      }
      await assertInteractionPermissionError {
        try await service.setUserInteractionPermissions(
          session: session(),
          targetUserID: target,
          permissions: .unrestricted
        )
      }
    }

    await assertInteractionPermissionError(.fullCredentialsRequired) {
      try await service.userInteractionPermissions(
        session: session(stoken: nil),
        targetUserID: 9
      )
    }
    let readCount = await client.readRequestCount()
    let writeCount = await client.writeRequestCount()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(writeCount, 0)
  }

  func testReadAndWriteRejectMismatchedCoreContext() async {
    let mismatches = [
      coreState(userID: 8),
      coreState(targetUserID: 10),
    ]
    for mismatch in mismatches {
      let read = TiebaCoreAccountService(
        client: UserInteractionPermissionClientSpy(readResult: .success(mismatch))
      )
      await assertInteractionPermissionError(
        .unavailable("贴吧返回了不匹配的互动权限，请重新加载后再试。")
      ) {
        try await read.userInteractionPermissions(session: session(), targetUserID: 9)
      }

      let write = TiebaCoreAccountService(
        client: UserInteractionPermissionClientSpy(writeResult: .success(mismatch))
      )
      await assertInteractionPermissionError(
        .unavailable("贴吧返回了不匹配的互动权限，请重新加载后再试。")
      ) {
        try await write.setUserInteractionPermissions(
          session: session(),
          targetUserID: 9,
          permissions: .unrestricted
        )
      }
    }
  }

  func testWriteMapsEveryDesiredBitAndVerifiedResult() async throws {
    let desired = UserInteractionPermissions(
      blocksFollow: false,
      blocksInteraction: true,
      blocksChat: true
    )
    let client = UserInteractionPermissionClientSpy(
      writeResult: .success(coreState(follow: false, interaction: true, chat: true))
    )
    let service = TiebaCoreAccountService(client: client)

    let result = try await service.setUserInteractionPermissions(
      session: session(),
      targetUserID: 9,
      permissions: desired
    )

    XCTAssertEqual(result.permissions, desired)
    let requests = await client.writeRequestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(
      requests.first?.permissions,
      TiebaUserInteractionPermissions(
        blocksFollow: false,
        blocksInteraction: true,
        blocksChat: true
      )
    )
  }

  func testCoreOutcomeUnknownIsDistinctFromKnownFailure() async {
    let unknown = TiebaCoreAccountService(
      client: UserInteractionPermissionClientSpy(
        writeResult: .failure(.userInteractionPermissionsOutcomeUnknown)
      )
    )
    await assertInteractionPermissionError(.outcomeUnknown) {
      try await unknown.setUserInteractionPermissions(
        session: session(),
        targetUserID: 9,
        permissions: .unrestricted
      )
    }

    let known = TiebaCoreAccountService(
      client: UserInteractionPermissionClientSpy(
        writeResult: .failure(.server(code: 403, message: "rejected"))
      )
    )
    await assertInteractionPermissionError(.unavailable("账户请求失败（错误码 403）。")) {
      try await known.setUserInteractionPermissions(
        session: session(),
        targetUserID: 9,
        permissions: .unrestricted
      )
    }
  }
}

private struct UserInteractionPermissionClientRequest: Equatable, Sendable {
  let userID: Int64
  let targetUserID: Int64
  let permissions: TiebaUserInteractionPermissions?
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
}

private enum UserInteractionPermissionClientFailure: Error, Sendable {
  case unexpectedCall
}

private actor UserInteractionPermissionClientSpy: TiebaAuthenticatedAccountClient {
  private let readResult: Result<TiebaUserInteractionPermissionState, TiebaClientError>?
  private let writeResult: Result<TiebaUserInteractionPermissionState, TiebaClientError>?
  private var reads: [UserInteractionPermissionClientRequest] = []
  private var writes: [UserInteractionPermissionClientRequest] = []

  init(
    readResult: Result<TiebaUserInteractionPermissionState, TiebaClientError>? = nil,
    writeResult: Result<TiebaUserInteractionPermissionState, TiebaClientError>? = nil
  ) {
    self.readResult = readResult
    self.writeResult = writeResult
  }

  func getUserInteractionPermissionState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) async throws -> TiebaUserInteractionPermissionState {
    reads.append(request(credential, expectedUserID, targetUserID, nil))
    guard let readResult else { throw UserInteractionPermissionClientFailure.unexpectedCall }
    return try readResult.get()
  }

  func setUserInteractionPermissions(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    permissions: TiebaUserInteractionPermissions
  ) async throws -> TiebaUserInteractionPermissionState {
    writes.append(request(credential, expectedUserID, targetUserID, permissions))
    guard let writeResult else { throw UserInteractionPermissionClientFailure.unexpectedCall }
    return try writeResult.get()
  }

  func readRequestsSnapshot() -> [UserInteractionPermissionClientRequest] { reads }
  func writeRequestsSnapshot() -> [UserInteractionPermissionClientRequest] { writes }
  func readRequestCount() -> Int { reads.count }
  func writeRequestCount() -> Int { writes.count }

  private func request(
    _ credential: TiebaSessionCredential,
    _ userID: Int64,
    _ targetUserID: Int64,
    _ permissions: TiebaUserInteractionPermissions?
  ) -> UserInteractionPermissionClientRequest {
    UserInteractionPermissionClientRequest(
      userID: userID,
      targetUserID: targetUserID,
      permissions: permissions,
      bdussBytes: credential.bduss.utf8.count,
      stokenBytes: credential.stoken.utf8.count,
      cookieName: credential.bdussCookieName
    )
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw UserInteractionPermissionClientFailure.unexpectedCall
  }
}

private func coreState(
  userID: Int64 = 7,
  targetUserID: Int64 = 9,
  follow: Bool = false,
  interaction: Bool = false,
  chat: Bool = false
) -> TiebaUserInteractionPermissionState {
  TiebaUserInteractionPermissionState(
    userID: userID,
    targetUserID: targetUserID,
    permissions: TiebaUserInteractionPermissions(
      blocksFollow: follow,
      blocksInteraction: interaction,
      blocksChat: chat
    )
  )
}

private func session(
  stoken: String? = String(repeating: "s", count: 64),
  cookieName: AccountBDUSSCookieName = .bduss
) -> StoredAccountSession {
  StoredAccountSession(
    id: 7,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: String(repeating: "b", count: 192),
    stoken: stoken,
    bdussCookieName: cookieName,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2)
  )
}

private func assertInteractionPermissionError<T>(
  _ expected: UserInteractionPermissionError? = nil,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected UserInteractionPermissionError", file: file, line: line)
  } catch let error as UserInteractionPermissionError {
    if let expected {
      XCTAssertEqual(error, expected, file: file, line: line)
    }
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
