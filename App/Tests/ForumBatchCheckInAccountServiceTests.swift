import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ForumBatchCheckInAccountServiceTests: XCTestCase {
  func testBatchCheckInNormalizesAndPassesAuthorizedTargets() async throws {
    let client = OfficialBatchBridgeClient(
      behavior: .result(TiebaOfficialBatchCheckInResult(userID: 7, items: []))
    )
    let service = TiebaCoreAccountService(client: client)

    let result = try await service.batchCheckIn(
      session: session(),
      authorizedTargets: [
        ForumBatchCheckInTarget(forumID: 42, forumName: "  e\u{301}  ")
      ]
    )

    XCTAssertEqual(result, ForumBatchCheckInData(userID: 7, results: []))
    let requests = await client.batchRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].expectedUserID, 7)
    XCTAssertEqual(requests[0].bdussBytes, 192)
    XCTAssertEqual(requests[0].stokenBytes, 64)
    XCTAssertEqual(requests[0].cookieName, .bduss)
    XCTAssertEqual(
      requests[0].targets,
      [TiebaOfficialBatchCheckInTarget(forumID: 42, canonicalForumName: "e\u{301}".precomposedStringWithCanonicalMapping)]
    )
  }

  func testBatchCheckInMapsAuthorizationChanged() async throws {
    let service = TiebaCoreAccountService(
      client: OfficialBatchBridgeClient(behavior: .authorizationChanged)
    )
    do {
      _ = try await service.batchCheckIn(
        session: session(),
        authorizedTargets: [ForumBatchCheckInTarget(forumID: 42, forumName: "swift")]
      )
      XCTFail("Expected authorization change")
    } catch let error as ForumBatchCheckInError {
      XCTAssertEqual(error, .authorizationChanged)
    }
  }

  func testBatchCheckInMapsExactOutcomeUnknownTargets() async throws {
    let dispatched = [
      TiebaOfficialBatchCheckInTarget(forumID: 42, canonicalForumName: "swift"),
      TiebaOfficialBatchCheckInTarget(forumID: 84, canonicalForumName: "ios"),
    ]
    let service = TiebaCoreAccountService(
      client: OfficialBatchBridgeClient(behavior: .outcomeUnknown(dispatched))
    )
    do {
      _ = try await service.batchCheckIn(
        session: session(),
        authorizedTargets: dispatched.map {
          ForumBatchCheckInTarget(forumID: $0.forumID, forumName: $0.canonicalForumName)
        }
      )
      XCTFail("Expected unknown outcome")
    } catch let error as ForumBatchCheckInError {
      XCTAssertEqual(
        error,
        .outcomeUnknown(
          dispatchedTargets: [
            ForumBatchCheckInTarget(forumID: 42, forumName: "swift"),
            ForumBatchCheckInTarget(forumID: 84, forumName: "ios"),
          ]
        )
      )
    }
  }

  func testBatchCheckInKeepsMalformedOutcomeUnknownFailClosed() async throws {
    let service = TiebaCoreAccountService(
      client: OfficialBatchBridgeClient(
        behavior: .outcomeUnknown([
          TiebaOfficialBatchCheckInTarget(forumID: 0, canonicalForumName: "swift")
        ])
      )
    )
    do {
      _ = try await service.batchCheckIn(
        session: session(),
        authorizedTargets: [ForumBatchCheckInTarget(forumID: 42, forumName: "swift")]
      )
      XCTFail("Expected unknown outcome")
    } catch let error as ForumBatchCheckInError {
      XCTAssertEqual(error, .outcomeUnknown(dispatchedTargets: []))
    }
  }

  func testBatchCheckInPropagatesPreflightCancellation() async throws {
    let client = OfficialBatchBridgeClient(behavior: .waitForCancellation)
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let task = Task {
      try await service.batchCheckIn(
        session: storedSession,
        authorizedTargets: [ForumBatchCheckInTarget(forumID: 42, forumName: "swift")]
      )
    }
    try await waitUntil { await client.batchRequests().count == 1 }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      let observedCancellation = await client.didObserveCancellation()
      XCTAssertTrue(observedCancellation)
    }
  }

  func testCompletionWindowCannotStartASecondIdenticalBatchWrite() async throws {
    let result = TiebaOfficialBatchCheckInResult(userID: 7, items: [])
    let client = OfficialBatchBridgeClient(behavior: .completionWindow(result))
    let service = TiebaCoreAccountService(client: client)
    let session = session()
    let targets = [ForumBatchCheckInTarget(forumID: 42, forumName: "swift")]
    defer { Task { await client.releaseCompletionWindow() } }

    let owner = Task { try await service.batchCheckIn(session: session, authorizedTargets: targets) }
    try await waitUntil {
      let requestCount = await client.batchRequests().count
      let waiterCount = await client.completionWindowWaiterCount()
      return requestCount == 1 && waiterCount == 1
    }
    let joined = Task { try await service.batchCheckIn(session: session, authorizedTargets: targets) }
    try await waitUntil {
      let joinCount = await client.joinRequestCount()
      let waiterCount = await client.completionWindowWaiterCount()
      return joinCount == 1 && waiterCount == 2
    }

    await client.settleSimulatedCoreFlight()
    let late = Task { try await service.batchCheckIn(session: session, authorizedTargets: targets) }
    try await waitUntil { await client.joinMissCount() == 1 }
    let writeCountInCompletionWindow = await client.batchRequests().count
    XCTAssertEqual(writeCountInCompletionWindow, 1)

    await client.releaseCompletionWindow()
    let ownerResult = try await owner.value
    let joinedResult = try await joined.value
    let expected = ForumBatchCheckInData(userID: 7, results: [])
    XCTAssertEqual(ownerResult, expected)
    XCTAssertEqual(joinedResult, expected)
    do {
      _ = try await late.value
      XCTFail("Expected the late completion-window caller to require a fresh read")
    } catch let error as BrowseError {
      XCTAssertEqual(
        error.errorDescription,
        "先前的贴吧账户操作已结束，请重新读取签到状态。"
      )
    }
    let finalWriteCount = await client.batchRequests().count
    XCTAssertEqual(finalWriteCount, 1)
  }

  func testCatalogRejectsControlCharactersAndOversizedNames() async throws {
    for invalidName in ["swift\u{0000}", String(repeating: "a", count: 1_025)] {
      let catalog = TiebaOfficialCheckInCatalog(
        userID: 7,
        forums: [
          TiebaOfficialCheckInForum(
            id: 42,
            name: invalidName,
            level: 1,
            avatar: "",
            checkInStatus: .pending,
            isForbidden: false
          )
        ],
        minimumBatchLevel: 1,
        maximumBatchCount: 50,
        isBatchCheckInAvailable: true
      )
      let service = TiebaCoreAccountService(
        client: OfficialBatchBridgeClient(behavior: .catalog(catalog))
      )
      do {
        _ = try await service.checkInCatalog(session: session())
        XCTFail("Expected invalid catalog name to be rejected")
      } catch let error as BrowseError {
        XCTAssertEqual(
          error.errorDescription,
          "贴吧返回了无效的一键签到目标，请重新加载后再试。"
        )
      }
    }
  }

  private func session() -> StoredAccountSession {
    StoredAccountSession(
      id: 7,
      username: "account",
      displayName: "Account",
      portrait: "portrait",
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
      guard Date() < deadline else { throw OfficialBatchBridgeClientError.unexpectedCall }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private struct OfficialBatchBridgeRequest: Sendable {
  let expectedUserID: Int64
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
  let targets: [TiebaOfficialBatchCheckInTarget]
}

private enum OfficialBatchBridgeBehavior: Sendable {
  case result(TiebaOfficialBatchCheckInResult)
  case authorizationChanged
  case outcomeUnknown([TiebaOfficialBatchCheckInTarget])
  case waitForCancellation
  case completionWindow(TiebaOfficialBatchCheckInResult)
  case catalog(TiebaOfficialCheckInCatalog)
}

private enum OfficialBatchBridgeClientError: Error, Sendable {
  case unexpectedCall
}

private actor OfficialBatchBridgeClient: TiebaAuthenticatedAccountClient {
  private let behavior: OfficialBatchBridgeBehavior
  private var requests: [OfficialBatchBridgeRequest] = []
  private var observedCancellation = false
  private var simulatedCoreFlightActive = false
  private var completionWindowReleased = false
  private var completionWindowWaiters: [CheckedContinuation<Void, Never>] = []
  private var joinRequests = 0
  private var joinMisses = 0

  init(behavior: OfficialBatchBridgeBehavior) {
    self.behavior = behavior
  }

  func getOfficialCheckInCatalog(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) async throws -> TiebaOfficialCheckInCatalog {
    guard case .catalog(let catalog) = behavior else {
      throw OfficialBatchBridgeClientError.unexpectedCall
    }
    return catalog
  }

  func performOfficialBatchCheckIn(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult {
    requests.append(
      OfficialBatchBridgeRequest(
        expectedUserID: expectedUserID,
        bdussBytes: credential.bduss.utf8.count,
        stokenBytes: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName,
        targets: authorizedTargets
      )
    )
    switch behavior {
    case .result(let result):
      return result
    case .authorizationChanged:
      throw TiebaClientError.officialBatchCheckInAuthorizationChanged
    case .outcomeUnknown(let targets):
      throw TiebaClientError.officialBatchCheckInOutcomeUnknown(dispatchedTargets: targets)
    case .waitForCancellation:
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw OfficialBatchBridgeClientError.unexpectedCall
      } catch is CancellationError {
        observedCancellation = true
        throw CancellationError()
      }
    case .completionWindow(let result):
      simulatedCoreFlightActive = true
      await waitForCompletionWindowRelease()
      return result
    case .catalog:
      throw OfficialBatchBridgeClientError.unexpectedCall
    }
  }

  func joinOfficialBatchCheckInIfInFlight(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult? {
    guard case .completionWindow(let result) = behavior else { return nil }
    joinRequests += 1
    guard simulatedCoreFlightActive else {
      joinMisses += 1
      return nil
    }
    await waitForCompletionWindowRelease()
    return result
  }

  private func waitForCompletionWindowRelease() async {
    guard !completionWindowReleased else { return }
    await withCheckedContinuation { completionWindowWaiters.append($0) }
  }

  func settleSimulatedCoreFlight() { simulatedCoreFlightActive = false }

  func releaseCompletionWindow() {
    completionWindowReleased = true
    let waiters = completionWindowWaiters
    completionWindowWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func batchRequests() -> [OfficialBatchBridgeRequest] { requests }
  func didObserveCancellation() -> Bool { observedCancellation }
  func completionWindowWaiterCount() -> Int { completionWindowWaiters.count }
  func joinRequestCount() -> Int { joinRequests }
  func joinMissCount() -> Int { joinMisses }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential, userID: Int64, page: Int, pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64,
    forumName: String, isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential, expectedUserID: Int64, forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw OfficialBatchBridgeClientError.unexpectedCall
  }
}
