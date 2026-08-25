import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class OwnedContentDeletionAccountServiceTests: XCTestCase {
  func testSuccessfulDeletionMapsTargetsCredentialsAndReceiptExactly() async throws {
    let cases: [(OwnedContentDeletionTarget, TiebaOwnedContentDeletionTarget)] = [
      (
        try deletionAccountTarget(kind: .topic, objectID: 101, floor: 1),
        .thread(firstPostID: 101)
      ),
      (
        try deletionAccountTarget(kind: .post, objectID: 102, floor: 2),
        .post(postID: 102)
      ),
    ]

    for (index, mapping) in cases.enumerated() {
      let spy = OwnedContentDeletionAccountClientSpy()
      let service = TiebaCoreAccountService(client: spy)
      let revision = deletionAccountUUID(UInt8(index + 1))
      let cookieName: AccountBDUSSCookieName = index == 0 ? .bduss : .bdussBFESS
      let expectedCoreCookieName: TiebaBDUSSCookieName =
        index == 0 ? .bduss : .bdussBFESS
      let session = deletionAccountSession(
        cookieName: cookieName,
        revision: revision
      )

      let receipt = try await service.deleteOwnedContent(
        session: session,
        target: mapping.0
      )

      XCTAssertEqual(receipt.accountID, session.id)
      XCTAssertEqual(receipt.sessionRevision, revision)
      XCTAssertEqual(receipt.target, mapping.0)
      let requests = await spy.requests()
      let request = try XCTUnwrap(requests.count == 1 ? requests[0] : nil)
      XCTAssertEqual(request.expectedUserID, session.id)
      XCTAssertEqual(request.forumID, mapping.0.forumID)
      XCTAssertEqual(request.forumName, mapping.0.forumName)
      XCTAssertEqual(request.threadID, mapping.0.threadID)
      XCTAssertEqual(request.target, mapping.1)
      XCTAssertEqual(request.bduss, session.bduss)
      XCTAssertEqual(request.stoken, try XCTUnwrap(session.stoken))
      XCTAssertEqual(request.cookieName, expectedCoreCookieName)
    }
  }

  func testMissingInvalidOrWrongAccountCredentialsFailBeforeCallingCore() async throws {
    let target = try deletionAccountTarget()
    let cases: [(String, StoredAccountSession)] = [
      ("missing stoken", deletionAccountSession(stoken: nil)),
      ("invalid bduss", deletionAccountSession(bduss: "short")),
      ("invalid stoken", deletionAccountSession(stoken: "short")),
      ("wrong account", deletionAccountSession(userID: target.authorID + 1)),
    ]

    for (name, session) in cases {
      let spy = OwnedContentDeletionAccountClientSpy()
      let service = TiebaCoreAccountService(client: spy)

      await assertDeletionAccountError(.definitelyNotAccepted, message: name) {
        try await service.deleteOwnedContent(session: session, target: target)
      }
      let requestCount = await spy.requestCount()
      XCTAssertEqual(requestCount, 0, name)
    }
  }

  func testDefinitiveCoreFailuresMapWithoutLeakingMessages() async throws {
    let cases: [(OwnedContentDeletionAccountFailure, DeletionAccountErrorClass)] = [
      (
        .core(.server(code: 340_006, message: "secret server message")),
        .rejected(code: 340_006)
      ),
      (
        .core(.invalidArgument("secret invalid target")),
        .definitelyNotAccepted
      ),
      (.core(.invalidAuthenticatedResponse), .definitelyNotAccepted),
    ]

    for (failure, expected) in cases {
      let spy = OwnedContentDeletionAccountClientSpy(failure: failure)
      let service = TiebaCoreAccountService(client: spy)

      let error = await captureDeletionAccountError {
        try await service.deleteOwnedContent(
          session: deletionAccountSession(),
          target: try deletionAccountTarget()
        )
      }
      XCTAssertEqual(error.map(DeletionAccountErrorClass.init), expected)
      XCTAssertFalse(error?.localizedDescription.contains("secret") ?? true)
      let requestCount = await spy.requestCount()
      XCTAssertEqual(requestCount, 1)
    }
  }

  func testCancellationAndIndeterminateCoreFailuresBecomeOutcomeUnknown() async throws {
    let cases: [OwnedContentDeletionAccountFailure] = [
      .cancellation,
      .core(.ownedContentDeletionWriteConflict),
      .core(.ownedContentDeletionOutcomeUnknown),
      .core(.network(code: -1_009)),
      .core(.transportFailure),
      .other,
    ]

    for failure in cases {
      let spy = OwnedContentDeletionAccountClientSpy(failure: failure)
      let service = TiebaCoreAccountService(client: spy)

      await assertDeletionAccountError(.outcomeUnknown, message: "\(failure)") {
        try await service.deleteOwnedContent(
          session: deletionAccountSession(),
          target: try deletionAccountTarget()
        )
      }
      let requestCount = await spy.requestCount()
      XCTAssertEqual(requestCount, 1, "\(failure)")
    }
  }

  func testEveryReceiptBindingMismatchBecomesOutcomeUnknown() async throws {
    for mismatch in OwnedContentDeletionReceiptMismatch.allCases {
      let spy = OwnedContentDeletionAccountClientSpy(mismatch: mismatch)
      let service = TiebaCoreAccountService(client: spy)

      await assertDeletionAccountError(.outcomeUnknown, message: "\(mismatch)") {
        try await service.deleteOwnedContent(
          session: deletionAccountSession(),
          target: try deletionAccountTarget()
        )
      }
      let requestCount = await spy.requestCount()
      XCTAssertEqual(requestCount, 1, "\(mismatch)")
    }
  }
}

private struct OwnedContentDeletionAccountRequest: Equatable, Sendable {
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let target: TiebaOwnedContentDeletionTarget
  let bduss: String
  let stoken: String
  let cookieName: TiebaBDUSSCookieName
}

private enum OwnedContentDeletionReceiptMismatch: CaseIterable, Equatable, Sendable {
  case userID
  case forumID
  case threadID
  case target
}

private enum OwnedContentDeletionAccountFailure: Sendable {
  case none
  case cancellation
  case core(TiebaClientError)
  case other
}

private enum OwnedContentDeletionAccountSpyError: Error, Sendable {
  case unexpectedCall
}

private actor OwnedContentDeletionAccountClientSpy: TiebaAuthenticatedAccountClient {
  private let mismatch: OwnedContentDeletionReceiptMismatch?
  private let failure: OwnedContentDeletionAccountFailure
  private var recordedRequests: [OwnedContentDeletionAccountRequest] = []

  init(
    mismatch: OwnedContentDeletionReceiptMismatch? = nil,
    failure: OwnedContentDeletionAccountFailure = .none
  ) {
    self.mismatch = mismatch
    self.failure = failure
  }

  func deleteOwnedContent(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaOwnedContentDeletionTarget
  ) async throws -> TiebaOwnedContentDeletionReceipt {
    recordedRequests.append(
      OwnedContentDeletionAccountRequest(
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        bduss: credential.bduss,
        stoken: credential.stoken,
        cookieName: credential.bdussCookieName
      )
    )

    switch failure {
    case .none:
      break
    case .cancellation:
      throw CancellationError()
    case .core(let error):
      throw error
    case .other:
      throw OwnedContentDeletionAccountSpyError.unexpectedCall
    }

    return TiebaOwnedContentDeletionReceipt(
      userID: mismatch == .userID ? expectedUserID + 1 : expectedUserID,
      forumID: mismatch == .forumID ? forumID + 1 : forumID,
      threadID: mismatch == .threadID ? threadID + 1 : threadID,
      target: mismatch == .target ? mismatchedDeletionTarget(target) : target
    )
  }

  func requests() -> [OwnedContentDeletionAccountRequest] { recordedRequests }
  func requestCount() -> Int { recordedRequests.count }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw OwnedContentDeletionAccountSpyError.unexpectedCall
  }
}

private enum DeletionAccountErrorClass: Equatable {
  case definitelyNotAccepted
  case rejected(code: Int32)
  case unavailable
  case outcomeUnknown

  init(_ error: OwnedContentDeletionError) {
    switch error {
    case .definitelyNotAccepted:
      self = .definitelyNotAccepted
    case .rejected(let code):
      self = .rejected(code: code)
    case .unavailable:
      self = .unavailable
    case .outcomeUnknown:
      self = .outcomeUnknown
    }
  }
}

private func mismatchedDeletionTarget(
  _ target: TiebaOwnedContentDeletionTarget
) -> TiebaOwnedContentDeletionTarget {
  switch target {
  case .thread(let firstPostID):
    .thread(firstPostID: firstPostID + 1)
  case .post(let postID):
    .post(postID: postID + 1)
  }
}

private func deletionAccountTarget(
  kind: OwnedContentDeletionKind = .post,
  objectID: Int64 = 102,
  floor: Int = 2
) throws -> OwnedContentDeletionTarget {
  try XCTUnwrap(
    OwnedContentDeletionTarget(
      kind: kind,
      forumID: 42,
      forumName: "swift",
      threadID: 100,
      objectID: objectID,
      authorID: 7,
      floor: floor
    )
  )
}

private func deletionAccountSession(
  userID: Int64 = 7,
  bduss: String = String(repeating: "b", count: AccountCredentialFormat.bdussLength),
  stoken: String? = String(repeating: "s", count: AccountCredentialFormat.stokenLength),
  cookieName: AccountBDUSSCookieName = .bduss,
  revision: UUID = deletionAccountUUID(200)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: bduss,
    stoken: stoken,
    bdussCookieName: cookieName,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    sessionRevision: revision
  )
}

private func deletionAccountUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func captureDeletionAccountError<T: Sendable>(
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async -> OwnedContentDeletionError? {
  do {
    _ = try await operation()
    XCTFail("Expected owned-content deletion error", file: file, line: line)
    return nil
  } catch let error as OwnedContentDeletionError {
    return error
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
    return nil
  }
}

private func assertDeletionAccountError<T: Sendable>(
  _ expected: DeletionAccountErrorClass,
  message: String,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let error = await captureDeletionAccountError(
    operation: operation,
    file: file,
    line: line
  )
  XCTAssertEqual(
    error.map(DeletionAccountErrorClass.init),
    expected,
    message,
    file: file,
    line: line
  )
}
