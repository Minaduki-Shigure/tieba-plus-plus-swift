import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaCoreAccountServiceTests: XCTestCase {
  func testValidationAndMembershipMapCoreResponsesWithoutChangingAccountIdentity() async throws {
    let client = AccountClientSpy(
      validation: TiebaAuthenticatedAccount(
        userID: 7,
        username: "validated-user",
        portrait: "portrait-token"
      ),
      membership: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    )
    let service = TiebaCoreAccountService(client: client)

    let account = try await service.validate(
      credential: AccountCredentials(bduss: String(repeating: "b", count: 192))
    )
    let membership = try await service.forumMembership(
      session: session(),
      forumID: 42,
      forumName: "swift"
    )

    XCTAssertEqual(account.userID, 7)
    XCTAssertEqual(account.username, "validated-user")
    XCTAssertEqual(account.portrait, "portrait-token")
    XCTAssertEqual(
      membership,
      ForumMembershipData(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    )
    let snapshot = await client.snapshot()
    XCTAssertEqual(snapshot.validationCredentialByteCounts, [192])
    XCTAssertEqual(
      snapshot.membershipRequests,
      [
        AccountClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          desiredState: nil
        )
      ]
    )
  }

  func testConcurrentIdenticalForumWritesShareOneCoreTask() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()

    let first = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let second = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    for _ in 0..<50 { await Task.yield() }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseMutation()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(firstResult, secondResult)
    XCTAssertTrue(firstResult.isFollowed)
    let finalRequestCount = await client.mutationRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testOppositeForumWriteIsRejectedWhileFirstWriteContinues() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let first = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    do {
      _ = try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: false
      )
      XCTFail("Expected the opposite in-flight mutation to be rejected")
    } catch let error as BrowseError {
      XCTAssertEqual(error.errorDescription, "该贴吧的关注状态正在更新，请稍后再试。")
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))")
    }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseMutation()
    let firstResult = try await first.value
    XCTAssertTrue(firstResult.isFollowed)
    let finalRequestCount = await client.mutationRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testRotatedSessionNeverJoinsAnOlderCredentialWrite() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let oldSession = session(updatedAt: 1)
    let rotatedSession = session(updatedAt: 2)
    let first = Task {
      try await service.setForumFollowed(
        session: oldSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    do {
      _ = try await service.setForumFollowed(
        session: rotatedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
      XCTFail("Expected a rotated session not to join the older credential task")
    } catch let error as BrowseError {
      XCTAssertEqual(error.errorDescription, "该贴吧的关注状态正在更新，请稍后再试。")
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))")
    }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseMutation()
    _ = try await first.value
  }

  func testCancellationAfterForumWriteStartsDoesNotDiscardConfirmedResult() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let write = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    write.cancel()
    await client.releaseMutation()
    let result = try await write.value

    XCTAssertTrue(result.isFollowed)
    let requestCount = await client.mutationRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testForumWritePassesExpectedIdentityAndMapsAuthoritativeResult() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "Swift 语言",
        isFollowed: false
      )
    )
    let service = TiebaCoreAccountService(client: client)

    let membership = try await service.setForumFollowed(
      session: session(),
      forumID: 42,
      forumName: "swift",
      isFollowed: false
    )

    XCTAssertEqual(
      membership,
      ForumMembershipData(
        userID: 7,
        forumID: 42,
        forumName: "Swift 语言",
        isFollowed: false
      )
    )
    let snapshot = await client.snapshot()
    let requests = snapshot.mutationRequests
    XCTAssertEqual(
      requests,
      [
        AccountClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          desiredState: false
        )
      ]
    )
  }

  func testServerErrorDoesNotExposeResponseMessage() throws {
    let secret = String(repeating: "b", count: 192)
    let error = TiebaCoreAccountService.accountError(
      TiebaClientError.server(code: 1, message: "request bdusstoken=\(secret)")
    )

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户请求失败（错误码 1）。")
    XCTAssertFalse(message.contains(secret))
    XCTAssertFalse(message.contains("bdusstoken"))
  }

  func testUnknownErrorDoesNotExposeLocalizedDescription() throws {
    let secret = "sensitive diagnostic"
    let error = TiebaCoreAccountService.accountError(SensitiveAccountError(message: secret))

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户请求失败，请稍后重试。")
    XCTAssertFalse(message.contains(secret))
  }

  func testAccountErrorUsesOnlyFixedMessagesAndNumericStatus() throws {
    let cases: [(TiebaClientError, String)] = [
      (.invalidArgument("secret"), "账户请求参数无效。"),
      (.invalidEndpoint, "无法建立安全的账户请求。"),
      (.network(code: -1009), "网络连接失败，请检查网络后重试。"),
      (.transportFailure, "网络响应异常，请稍后重试。"),
      (.invalidHTTPResponse, "网络响应异常，请稍后重试。"),
      (.httpStatus(503), "贴吧服务暂时不可用（HTTP 503）。"),
      (.responseTooLarge(maximumBytes: 65_536), "贴吧返回的数据过大，请稍后重试。"),
      (.invalidProtobuf, "贴吧返回了无法识别的数据，接口可能已经更新。"),
      (.invalidJSON, "贴吧返回了无法识别的数据，接口可能已经更新。"),
      (
        .invalidAuthenticatedResponse,
        "账户凭据与贴吧响应不一致，请重新登录后再试。"
      ),
    ]

    for (source, expected) in cases {
      XCTAssertEqual(
        TiebaCoreAccountService.accountError(source).errorDescription,
        expected
      )
    }
  }

  func testForumMutationServerErrorIsSanitizedByService() async throws {
    let secret = String(repeating: "t", count: 26)
    let client = AccountClientSpy(
      mutationError: .server(code: 340006, message: "invalid tbs=\(secret)")
    )
    let service = TiebaCoreAccountService(client: client)

    do {
      _ = try await service.setForumFollowed(
        session: session(),
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
      XCTFail("Expected a sanitized server error")
    } catch let error as BrowseError {
      let message = try XCTUnwrap(error.errorDescription)
      XCTAssertEqual(message, "账户请求失败（错误码 340006）。")
      XCTAssertFalse(message.contains(secret))
      XCTAssertFalse(message.contains("tbs"))
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))")
    }
  }

  private func session(updatedAt: TimeInterval = 1) -> StoredAccountSession {
    StoredAccountSession(
      id: 7,
      username: "account",
      displayName: "Account",
      portrait: "portrait-token",
      bduss: String(repeating: "b", count: 192),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }
}

private struct SensitiveAccountError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private struct AccountClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String
  let desiredState: Bool?
}

private struct AccountClientSnapshot: Sendable {
  let validationCredentialByteCounts: [Int]
  let membershipRequests: [AccountClientRequest]
  let mutationRequests: [AccountClientRequest]
}

private enum AccountClientSpyError: Error, Sendable {
  case unexpectedCall
}

private actor AccountClientSpy: TiebaAuthenticatedAccountClient {
  private let validation: TiebaAuthenticatedAccount?
  private let membership: TiebaForumMembership?
  private let mutation: TiebaForumMembership?
  private let mutationError: TiebaClientError?
  private let suspendsMutation: Bool
  private var validationCredentialByteCounts: [Int] = []
  private var membershipRequests: [AccountClientRequest] = []
  private var mutationRequests: [AccountClientRequest] = []
  private var mutationIsReleased = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    validation: TiebaAuthenticatedAccount? = nil,
    membership: TiebaForumMembership? = nil,
    mutation: TiebaForumMembership? = nil,
    mutationError: TiebaClientError? = nil,
    suspendsMutation: Bool = false
  ) {
    self.validation = validation
    self.membership = membership
    self.mutation = mutation
    self.mutationError = mutationError
    self.suspendsMutation = suspendsMutation
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    validationCredentialByteCounts.append(credential.bduss.utf8.count)
    guard let validation else { throw AccountClientSpyError.unexpectedCall }
    return validation
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw AccountClientSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    membershipRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: nil
      )
    )
    guard let membership else { throw AccountClientSpyError.unexpectedCall }
    return membership
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    mutationRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: isFollowed
      )
    )
    if suspendsMutation, !mutationIsReleased {
      await withCheckedContinuation { mutationWaiters.append($0) }
    }
    if let mutationError { throw mutationError }
    guard let mutation else { throw AccountClientSpyError.unexpectedCall }
    return mutation
  }

  func releaseMutation() {
    mutationIsReleased = true
    let waiters = mutationWaiters
    mutationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func mutationRequestCount() -> Int { mutationRequests.count }

  func snapshot() -> AccountClientSnapshot {
    AccountClientSnapshot(
      validationCredentialByteCounts: validationCredentialByteCounts,
      membershipRequests: membershipRequests,
      mutationRequests: mutationRequests
    )
  }
}

private func waitForAccountServiceTest(
  timeout: TimeInterval = 2,
  condition: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw AccountClientSpyError.unexpectedCall }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
