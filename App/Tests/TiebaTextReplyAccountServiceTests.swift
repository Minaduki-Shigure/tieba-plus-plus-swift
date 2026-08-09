import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaTextReplyAccountServiceTests: XCTestCase {
  func testReplyRequiresFullCredentialsBeforeCallingCore() async throws {
    let spy = TextReplyAccountClientSpy(
      outcome: .confirmed(.post(postID: 701, floor: 2))
    )
    let service = TiebaCoreAccountService(client: spy)
    let submission = try appReplySubmission()

    await assertTextReplyAccountError(.fullCredentialsRequired) {
      try await service.submitTextReply(
        session: textReplyAccountSession(stoken: nil),
        submission: submission
      )
    }
    await assertTextReplyAccountError(.fullCredentialsRequired) {
      try await service.submitTextReply(
        session: textReplyAccountSession(userID: 0),
        submission: submission
      )
    }
    let count = await spy.requestCount()
    XCTAssertEqual(count, 0)
  }

  func testReplyMapsCredentialsTargetsContentAndOutcomesExactly() async throws {
    let cases: [TextReplyMappingCase] = [
      TextReplyMappingCase(
        destination: .thread(firstPostID: 700),
        coreTarget: .thread(firstPostID: 700),
        coreOutcome: .confirmed(.post(postID: 701, floor: 2)),
        appOutcome: .confirmed(.post(postID: 701, floor: 2))
      ),
      TextReplyMappingCase(
        destination: .post(postID: 701),
        coreTarget: .post(postID: 701),
        coreOutcome: .acceptedAwaitingVisibility(
          .subpost(parentPostID: 701, subpostID: 703)
        ),
        appOutcome: .acceptedAwaitingVisibility(
          .subpost(parentPostID: 701, subpostID: 703)
        )
      ),
      TextReplyMappingCase(
        destination: .subpost(parentPostID: 701, subpostID: 702),
        coreTarget: .subpost(parentPostID: 701, subpostID: 702),
        coreOutcome: .confirmed(.subpost(parentPostID: 701, subpostID: 703)),
        appOutcome: .confirmed(.subpost(parentPostID: 701, subpostID: 703))
      ),
    ]

    for (index, mapping) in cases.enumerated() {
      let spy = TextReplyAccountClientSpy(outcome: mapping.coreOutcome)
      let service = TiebaCoreAccountService(client: spy)
      let id = textReplyAccountUUID(UInt8(index + 1))
      let submission = try appReplySubmission(
        id: id,
        destination: mapping.destination,
        content: "  原样正文\n第 \(index) 条  "
      )
      let session = textReplyAccountSession(cookieName: .bdussBFESS)

      let result = try await service.submitTextReply(
        session: session,
        submission: submission
      )

      XCTAssertEqual(result.submissionID, id)
      XCTAssertEqual(result.userID, session.id)
      XCTAssertEqual(result.target, submission.target)
      XCTAssertEqual(result.outcome, mapping.appOutcome)
      let requests = await spy.requests()
      let request = try XCTUnwrap(requests.count == 1 ? requests[0] : nil)
      XCTAssertEqual(request.expectedUserID, session.id)
      XCTAssertEqual(request.submissionID, id)
      XCTAssertEqual(request.forumID, 7)
      XCTAssertEqual(request.forumName, "swift")
      XCTAssertEqual(request.threadID, 70)
      XCTAssertEqual(request.target, mapping.coreTarget)
      XCTAssertEqual(request.content, submission.content)
      XCTAssertEqual(request.bdussByteCount, AccountCredentialFormat.bdussLength)
      XCTAssertEqual(request.stokenByteCount, AccountCredentialFormat.stokenLength)
      XCTAssertEqual(request.cookieName, .bdussBFESS)
    }
  }

  func testEveryCoreIdentityMismatchBecomesUnknownOutcome() async throws {
    let mismatches: [TextReplyCoreMismatch] = [
      .submissionID,
      .userID,
      .forumID,
      .threadID,
      .target,
      .outcome,
    ]
    let submission = try appReplySubmission()

    for mismatch in mismatches {
      let spy = TextReplyAccountClientSpy(
        outcome: .confirmed(.post(postID: 701, floor: 2)),
        mismatch: mismatch
      )
      let service = TiebaCoreAccountService(client: spy)
      await assertTextReplyAccountError(.outcomeUnknown) {
        try await service.submitTextReply(
          session: textReplyAccountSession(),
          submission: submission
        )
      }
      let count = await spy.requestCount()
      XCTAssertEqual(count, 1, "Mismatch \(mismatch) should issue exactly one request")
    }
  }

  func testCoreReplyErrorsMapToTypedRedactedApplicationErrors() async throws {
    let cases: [(TextReplyCoreFailure, TextReplySubmissionError)] = [
      (.core(.replyChallengeRequired(message: "secret challenge")), .challengeRequired),
      (.core(.replyOutcomeUnknown), .outcomeUnknown),
      (.core(.replySubmissionIDConflict), .submissionConflict),
      (.core(.server(code: 123, message: "secret server message")), .server(code: 123)),
      (.core(.invalidArgument("secret argument")), .invalidSubmission),
      (.core(.network(code: -1009)), .unavailable),
      (.other, .unavailable),
    ]
    let submission = try appReplySubmission()

    for (failure, expected) in cases {
      let spy = TextReplyAccountClientSpy(
        outcome: .confirmed(.post(postID: 701, floor: 2)),
        failure: failure
      )
      let service = TiebaCoreAccountService(client: spy)
      var captured: TextReplySubmissionError?
      do {
        _ = try await service.submitTextReply(
          session: textReplyAccountSession(),
          submission: submission
        )
        XCTFail("Expected mapped reply error")
      } catch let error as TextReplySubmissionError {
        captured = error
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(captured, expected)
      XCTAssertFalse(captured?.localizedDescription.contains("secret") ?? true)
    }
  }

  func testCoreCancellationRemainsCancellation() async throws {
    let spy = TextReplyAccountClientSpy(
      outcome: .confirmed(.post(postID: 701, floor: 2)),
      failure: .cancellation
    )
    let service = TiebaCoreAccountService(client: spy)

    do {
      _ = try await service.submitTextReply(
        session: textReplyAccountSession(),
        submission: appReplySubmission()
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }
}

private struct TextReplyMappingCase {
  let destination: TextReplyTarget.Destination
  let coreTarget: TiebaTextReplyTarget
  let coreOutcome: TiebaTextReplyOutcome
  let appOutcome: TextReplyOutcome
}

private struct TextReplyCoreRequest: Sendable {
  let expectedUserID: Int64
  let submissionID: UUID
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let target: TiebaTextReplyTarget
  let content: String
  let bdussByteCount: Int
  let stokenByteCount: Int
  let cookieName: TiebaBDUSSCookieName
}

private enum TextReplyCoreMismatch: Sendable, Equatable {
  case none
  case submissionID
  case userID
  case forumID
  case threadID
  case target
  case outcome
}

private enum TextReplyCoreFailure: Sendable {
  case none
  case core(TiebaClientError)
  case cancellation
  case other
}

private enum TextReplyAccountSpyError: Error, Sendable {
  case unexpectedCall
}

private actor TextReplyAccountClientSpy: TiebaAuthenticatedAccountClient {
  private let outcome: TiebaTextReplyOutcome
  private let mismatch: TextReplyCoreMismatch
  private let failure: TextReplyCoreFailure
  private var recordedRequests: [TextReplyCoreRequest] = []

  init(
    outcome: TiebaTextReplyOutcome,
    mismatch: TextReplyCoreMismatch = .none,
    failure: TextReplyCoreFailure = .none
  ) {
    self.outcome = outcome
    self.mismatch = mismatch
    self.failure = failure
  }

  func submitTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    recordedRequests.append(
      TextReplyCoreRequest(
        expectedUserID: expectedUserID,
        submissionID: submission.submissionID,
        forumID: submission.forumID,
        forumName: submission.forumName,
        threadID: submission.threadID,
        target: submission.target,
        content: submission.content,
        bdussByteCount: credential.bduss.utf8.count,
        stokenByteCount: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName
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
      throw TextReplyAccountSpyError.unexpectedCall
    }

    let responseSubmissionID = mismatch == .submissionID
      ? textReplyAccountUUID(250)
      : submission.submissionID
    let responseUserID = mismatch == .userID ? expectedUserID + 1 : expectedUserID
    let responseForumID = mismatch == .forumID ? submission.forumID + 1 : submission.forumID
    let responseThreadID = mismatch == .threadID ? submission.threadID + 1 : submission.threadID
    let responseTarget: TiebaTextReplyTarget = mismatch == .target
      ? .post(postID: 999)
      : submission.target
    let responseOutcome: TiebaTextReplyOutcome = mismatch == .outcome
      ? .confirmed(.post(postID: 700, floor: 1))
      : outcome
    return TiebaTextReplyResult(
      submissionID: responseSubmissionID,
      userID: responseUserID,
      forumID: responseForumID,
      threadID: responseThreadID,
      target: responseTarget,
      outcome: responseOutcome
    )
  }

  func requests() -> [TextReplyCoreRequest] { recordedRequests }
  func requestCount() -> Int { recordedRequests.count }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw TextReplyAccountSpyError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw TextReplyAccountSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw TextReplyAccountSpyError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw TextReplyAccountSpyError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw TextReplyAccountSpyError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw TextReplyAccountSpyError.unexpectedCall
  }
}

private func appReplySubmission(
  id: UUID = textReplyAccountUUID(1),
  destination: TextReplyTarget.Destination = .thread(firstPostID: 700),
  content: String = "正文"
) throws -> TextReplySubmission {
  let target = try XCTUnwrap(
    TextReplyTarget(
      forumID: 7,
      forumName: "swift",
      threadID: 70,
      firstPostID: 700,
      destination: destination
    )
  )
  return try XCTUnwrap(TextReplySubmission(id: id, target: target, content: content))
}

private func textReplyAccountSession(
  userID: Int64 = 9,
  stoken: String? = String(repeating: "s", count: AccountCredentialFormat.stokenLength),
  cookieName: AccountBDUSSCookieName = .bduss,
  revision: UUID = textReplyAccountUUID(200)
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: stoken,
    bdussCookieName: cookieName,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func textReplyAccountUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func assertTextReplyAccountError<T: Sendable>(
  _ expected: TextReplySubmissionError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as TextReplySubmissionError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
