import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaNewThreadAccountServiceTests: XCTestCase {
  func testVisibilityVerificationRequiresFullCredentialsBeforeCallingCore() async throws {
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
      visibilityReceipt: TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)
    )
    let service = TiebaCoreAccountService(client: spy)
    let submission = try appNewThreadSubmission()

    for session in [
      newThreadAccountSession(stoken: nil),
      newThreadAccountSession(stoken: "short"),
      newThreadAccountSession(bduss: "short"),
      newThreadAccountSession(userID: 0),
    ] {
      await assertNewThreadAccountError(.fullCredentialsRequired) {
        try await service.verifyNewThreadVisibility(
          session: session,
          submission: submission,
          receipt: receipt
        )
      }
    }

    let requestCount = await spy.visibilityRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testVisibilityVerificationMapsAllInputsAndBuildsExactConfirmation() async throws {
    let cases: [(String?, String, Int64, Int64)] = [
      ("  标题  ", "  原样正文\n第一条  ", 70, 700),
      (nil, "无标题正文", 71, 701),
    ]

    for (index, testCase) in cases.enumerated() {
      let (title, content, threadID, firstPostID) = testCase
      let coreReceipt = TiebaNewThreadReceipt(
        threadID: threadID,
        firstPostID: firstPostID
      )
      let spy = NewThreadAccountClientSpy(
        outcome: .confirmed(coreReceipt),
        visibilityReceipt: coreReceipt
      )
      let service = TiebaCoreAccountService(client: spy)
      let submission = try appNewThreadSubmission(
        id: newThreadAccountUUID(UInt8(index + 20)),
        title: title,
        content: content
      )
      let receipt = try XCTUnwrap(
        NewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
      )
      let session = newThreadAccountSession(cookieName: .bdussBFESS)

      let verified = try await service.verifyNewThreadVisibility(
        session: session,
        submission: submission,
        receipt: receipt
      )
      let confirmation = try XCTUnwrap(verified)

      XCTAssertEqual(confirmation.receipt, receipt)
      XCTAssertEqual(confirmation.target, submission.target)
      XCTAssertEqual(confirmation.authorUserID, session.id)
      XCTAssertEqual(confirmation.title, submission.title)
      XCTAssertEqual(confirmation.content, submission.content)

      let requests = await spy.visibilityRequests()
      let request = try XCTUnwrap(requests.count == 1 ? requests[0] : nil)
      XCTAssertEqual(request.expectedUserID, session.id)
      XCTAssertEqual(request.submissionID, submission.id)
      XCTAssertEqual(request.forumID, submission.target.forumID)
      XCTAssertEqual(request.forumName, submission.target.forumName)
      XCTAssertEqual(request.title, submission.title ?? "")
      XCTAssertEqual(request.content, submission.content)
      XCTAssertEqual(request.threadID, receipt.threadID)
      XCTAssertEqual(request.firstPostID, receipt.firstPostID)
      XCTAssertEqual(request.bdussByteCount, AccountCredentialFormat.bdussLength)
      XCTAssertEqual(request.stokenByteCount, AccountCredentialFormat.stokenLength)
      XCTAssertEqual(request.cookieName, .bdussBFESS)
    }
  }

  func testVisibilityVerificationKeepsCoreNotVisibleAsNil() async throws {
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700))
    )
    let service = TiebaCoreAccountService(client: spy)
    let result = try await service.verifyNewThreadVisibility(
      session: newThreadAccountSession(),
      submission: appNewThreadSubmission(),
      receipt: try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    )

    XCTAssertNil(result)
    let requestCount = await spy.visibilityRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testVisibilityVerificationRejectsMismatchedCoreReceiptAsUnavailable() async throws {
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
      visibilityReceipt: TiebaNewThreadReceipt(threadID: 71, firstPostID: 701)
    )
    let service = TiebaCoreAccountService(client: spy)

    await assertNewThreadAccountError(.unavailable) {
      try await service.verifyNewThreadVisibility(
        session: newThreadAccountSession(),
        submission: appNewThreadSubmission(),
        receipt: try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
      )
    }
  }

  func testVisibilityVerificationRedactsErrorsAndPreservesCancellation() async throws {
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let submission = try appNewThreadSubmission()
    let failures: [NewThreadCoreFailure] = [
      .core(.server(code: 123, message: "secret server message")),
      .core(.invalidArgument("secret argument")),
      .other,
    ]

    for failure in failures {
      let spy = NewThreadAccountClientSpy(
        outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
        visibilityFailure: failure
      )
      let service = TiebaCoreAccountService(client: spy)
      await assertNewThreadAccountError(.unavailable) {
        try await service.verifyNewThreadVisibility(
          session: newThreadAccountSession(),
          submission: submission,
          receipt: receipt
        )
      }
    }

    let cancellationSpy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
      visibilityFailure: .cancellation
    )
    let service = TiebaCoreAccountService(client: cancellationSpy)
    do {
      _ = try await service.verifyNewThreadVisibility(
        session: newThreadAccountSession(),
        submission: submission,
        receipt: receipt
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testSubmissionRequiresFullCredentialsBeforeCallingCore() async throws {
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700))
    )
    let service = TiebaCoreAccountService(client: spy)
    let submission = try appNewThreadSubmission()

    await assertNewThreadAccountError(.fullCredentialsRequired) {
      try await service.submitNewThread(
        session: newThreadAccountSession(stoken: nil),
        submission: submission
      )
    }
    await assertNewThreadAccountError(.fullCredentialsRequired) {
      try await service.submitNewThread(
        session: newThreadAccountSession(stoken: "short"),
        submission: submission
      )
    }
    await assertNewThreadAccountError(.fullCredentialsRequired) {
      try await service.submitNewThread(
        session: newThreadAccountSession(bduss: "short"),
        submission: submission
      )
    }
    await assertNewThreadAccountError(.fullCredentialsRequired) {
      try await service.submitNewThread(
        session: newThreadAccountSession(userID: 0),
        submission: submission
      )
    }
    let requestCount = await spy.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testSubmissionMapsCredentialsTargetContentAndOutcomesExactly() async throws {
    let cases: [(TiebaNewThreadOutcome, NewThreadOutcome)] = [
      (
        .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
        .confirmed(try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700)))
      ),
      (
        .acceptedAwaitingVisibility(TiebaNewThreadReceipt(threadID: 71, firstPostID: 701)),
        .acceptedAwaitingVisibility(
          try XCTUnwrap(NewThreadReceipt(threadID: 71, firstPostID: 701))
        )
      ),
    ]

    for (index, mapping) in cases.enumerated() {
      let spy = NewThreadAccountClientSpy(outcome: mapping.0)
      let service = TiebaCoreAccountService(client: spy)
      let title = index == 0 ? "  标题 \(index)  " : nil
      let submission = try appNewThreadSubmission(
        id: newThreadAccountUUID(UInt8(index + 1)),
        title: title,
        content: "  原样正文\n第 \(index) 条  "
      )
      let session = newThreadAccountSession(cookieName: .bdussBFESS)

      let result = try await service.submitNewThread(session: session, submission: submission)

      XCTAssertEqual(result.submissionID, submission.id)
      XCTAssertEqual(result.userID, session.id)
      XCTAssertEqual(result.target, submission.target)
      XCTAssertEqual(result.outcome, mapping.1)
      let requests = await spy.requests()
      let request = try XCTUnwrap(requests.count == 1 ? requests[0] : nil)
      XCTAssertEqual(request.expectedUserID, session.id)
      XCTAssertEqual(request.submissionID, submission.id)
      XCTAssertEqual(request.forumID, submission.target.forumID)
      XCTAssertEqual(request.forumName, submission.target.forumName)
      XCTAssertEqual(request.title, submission.title ?? "")
      XCTAssertEqual(request.content, submission.content)
      XCTAssertEqual(request.bdussByteCount, AccountCredentialFormat.bdussLength)
      XCTAssertEqual(request.stokenByteCount, AccountCredentialFormat.stokenLength)
      XCTAssertEqual(request.cookieName, .bdussBFESS)
    }
  }

  func testEveryCoreIdentityOrReceiptMismatchBecomesUnknownOutcome() async throws {
    let mismatches: [NewThreadCoreMismatch] = [
      .submissionID,
      .userID,
      .forumID,
      .forumName,
      .invalidThreadID,
      .invalidFirstPostID,
    ]
    let submission = try appNewThreadSubmission()

    for mismatch in mismatches {
      let spy = NewThreadAccountClientSpy(
        outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
        mismatch: mismatch
      )
      let service = TiebaCoreAccountService(client: spy)
      await assertNewThreadAccountError(.outcomeUnknown) {
        try await service.submitNewThread(
          session: newThreadAccountSession(),
          submission: submission
        )
      }
      let requestCount = await spy.requestCount()
      XCTAssertEqual(requestCount, 1, "Mismatch \(mismatch) should issue exactly one request")
    }
  }

  func testCoreErrorsMapToTypedRedactedApplicationErrors() async throws {
    let cases: [(NewThreadCoreFailure, NewThreadSubmissionError)] = [
      (.core(.newThreadChallengeRequired(message: "secret challenge")), .challengeRequired),
      (.core(.newThreadOutcomeUnknown), .outcomeUnknown),
      (.core(.newThreadSubmissionIDConflict), .submissionConflict),
      (.core(.server(code: 123, message: "secret server message")), .server(code: 123)),
      (.core(.invalidArgument("secret argument")), .invalidSubmission),
      (.core(.network(code: -1009)), .unavailable),
      (.other, .unavailable),
    ]
    let submission = try appNewThreadSubmission()

    for (failure, expected) in cases {
      let spy = NewThreadAccountClientSpy(
        outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
        failure: failure
      )
      let service = TiebaCoreAccountService(client: spy)
      var captured: NewThreadSubmissionError?
      do {
        _ = try await service.submitNewThread(
          session: newThreadAccountSession(),
          submission: submission
        )
        XCTFail("Expected mapped new-thread error")
      } catch let error as NewThreadSubmissionError {
        captured = error
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(captured, expected)
      XCTAssertFalse(captured?.localizedDescription.contains("secret") ?? true)
    }
  }

  func testCoreCancellationRemainsCancellation() async throws {
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700)),
      failure: .cancellation
    )
    let service = TiebaCoreAccountService(client: spy)

    do {
      _ = try await service.submitNewThread(
        session: newThreadAccountSession(),
        submission: appNewThreadSubmission()
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testDiagnosticDescriptionsDoNotExposeCredentialsOrSubmissionText() async throws {
    let title = "private title"
    let content = "private body"
    let forumName = "private-forum"
    let target = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: forumName))
    let submission = try XCTUnwrap(
      NewThreadSubmission(target: target, title: title, content: content)
    )
    let session = newThreadAccountSession()
    let spy = NewThreadAccountClientSpy(
      outcome: .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 700))
    )
    let service = TiebaCoreAccountService(client: spy)

    _ = try await service.submitNewThread(session: session, submission: submission)

    let requests = await spy.requests()
    let diagnostics = try XCTUnwrap(requests.first).diagnostics
    for secret in [session.bduss, session.stoken ?? "", forumName, title, content] {
      XCTAssertFalse(diagnostics.contains(secret))
    }
  }
}

private struct NewThreadCoreRequest: Sendable {
  let expectedUserID: Int64
  let submissionID: UUID
  let forumID: Int64
  let forumName: String
  let title: String
  let content: String
  let bdussByteCount: Int
  let stokenByteCount: Int
  let cookieName: TiebaBDUSSCookieName
  let diagnostics: String
}

private struct NewThreadVisibilityCoreRequest: Sendable {
  let expectedUserID: Int64
  let submissionID: UUID
  let forumID: Int64
  let forumName: String
  let title: String
  let content: String
  let threadID: Int64
  let firstPostID: Int64
  let bdussByteCount: Int
  let stokenByteCount: Int
  let cookieName: TiebaBDUSSCookieName
}

private enum NewThreadCoreMismatch: Sendable, Equatable {
  case none
  case submissionID
  case userID
  case forumID
  case forumName
  case invalidThreadID
  case invalidFirstPostID
}

private enum NewThreadCoreFailure: Sendable {
  case none
  case core(TiebaClientError)
  case cancellation
  case other
}

private enum NewThreadAccountSpyError: Error, Sendable {
  case unexpectedCall
}

private actor NewThreadAccountClientSpy: TiebaAuthenticatedAccountClient {
  private let outcome: TiebaNewThreadOutcome
  private let mismatch: NewThreadCoreMismatch
  private let failure: NewThreadCoreFailure
  private let visibilityReceipt: TiebaNewThreadReceipt?
  private let visibilityFailure: NewThreadCoreFailure
  private var recordedRequests: [NewThreadCoreRequest] = []
  private var recordedVisibilityRequests: [NewThreadVisibilityCoreRequest] = []

  init(
    outcome: TiebaNewThreadOutcome,
    mismatch: NewThreadCoreMismatch = .none,
    failure: NewThreadCoreFailure = .none,
    visibilityReceipt: TiebaNewThreadReceipt? = nil,
    visibilityFailure: NewThreadCoreFailure = .none
  ) {
    self.outcome = outcome
    self.mismatch = mismatch
    self.failure = failure
    self.visibilityReceipt = visibilityReceipt
    self.visibilityFailure = visibilityFailure
  }

  func submitNewThread(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission
  ) async throws -> TiebaNewThreadResult {
    recordedRequests.append(
      NewThreadCoreRequest(
        expectedUserID: expectedUserID,
        submissionID: submission.submissionID,
        forumID: submission.forumID,
        forumName: submission.forumName,
        title: submission.title,
        content: submission.content,
        bdussByteCount: credential.bduss.utf8.count,
        stokenByteCount: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName,
        diagnostics: [
          String(describing: credential),
          String(reflecting: credential),
          String(describing: submission),
          String(reflecting: submission),
        ].joined(separator: "|")
      )
    )
    switch failure {
    case .none:
      break
    case .core(let error):
      throw error
    case .cancellation:
      throw CancellationError()
    case .other:
      throw NewThreadAccountSpyError.unexpectedCall
    }

    let responseSubmissionID = mismatch == .submissionID
      ? newThreadAccountUUID(250)
      : submission.submissionID
    let responseUserID = mismatch == .userID ? expectedUserID + 1 : expectedUserID
    let responseForumID = mismatch == .forumID ? submission.forumID + 1 : submission.forumID
    let responseForumName = mismatch == .forumName ? "other-forum" : submission.forumName
    let responseOutcome: TiebaNewThreadOutcome = switch mismatch {
    case .invalidThreadID:
      .confirmed(TiebaNewThreadReceipt(threadID: 0, firstPostID: 700))
    case .invalidFirstPostID:
      .confirmed(TiebaNewThreadReceipt(threadID: 70, firstPostID: 0))
    default:
      outcome
    }
    return TiebaNewThreadResult(
      submissionID: responseSubmissionID,
      userID: responseUserID,
      forumID: responseForumID,
      forumName: responseForumName,
      outcome: responseOutcome
    )
  }

  func requests() -> [NewThreadCoreRequest] { recordedRequests }
  func requestCount() -> Int { recordedRequests.count }

  func verifyNewThreadVisibility(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission,
    receipt: TiebaNewThreadReceipt
  ) async throws -> TiebaNewThreadReceipt? {
    recordedVisibilityRequests.append(
      NewThreadVisibilityCoreRequest(
        expectedUserID: expectedUserID,
        submissionID: submission.submissionID,
        forumID: submission.forumID,
        forumName: submission.forumName,
        title: submission.title,
        content: submission.content,
        threadID: receipt.threadID,
        firstPostID: receipt.firstPostID,
        bdussByteCount: credential.bduss.utf8.count,
        stokenByteCount: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName
      )
    )
    switch visibilityFailure {
    case .none:
      return visibilityReceipt
    case .core(let error):
      throw error
    case .cancellation:
      throw CancellationError()
    case .other:
      throw NewThreadAccountSpyError.unexpectedCall
    }
  }

  func visibilityRequests() -> [NewThreadVisibilityCoreRequest] {
    recordedVisibilityRequests
  }

  func visibilityRequestCount() -> Int { recordedVisibilityRequests.count }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw NewThreadAccountSpyError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw NewThreadAccountSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw NewThreadAccountSpyError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw NewThreadAccountSpyError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw NewThreadAccountSpyError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw NewThreadAccountSpyError.unexpectedCall
  }
}

private func appNewThreadSubmission(
  id: UUID = newThreadAccountUUID(1),
  title: String? = "标题",
  content: String = "正文"
) throws -> NewThreadSubmission {
  let target = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift"))
  return try XCTUnwrap(
    NewThreadSubmission(id: id, target: target, title: title, content: content)
  )
}

private func newThreadAccountSession(
  userID: Int64 = 9,
  bduss: String = String(repeating: "b", count: AccountCredentialFormat.bdussLength),
  stoken: String? = String(repeating: "s", count: AccountCredentialFormat.stokenLength),
  cookieName: AccountBDUSSCookieName = .bduss,
  revision: UUID = newThreadAccountUUID(200)
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
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func newThreadAccountUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func assertNewThreadAccountError<T: Sendable>(
  _ expected: NewThreadSubmissionError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as NewThreadSubmissionError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
