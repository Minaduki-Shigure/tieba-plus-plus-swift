import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class PollVoteAccountServiceTests: XCTestCase {
  func testReadUsesFullCredentialAndMapsExactAuthoritativeState() async throws {
    let corePoll = poll(isPolled: true, selectedOptionIDs: [20])
    let client = PollVoteAccountClientSpy(readState: state(poll: corePoll))
    let service = TiebaCoreAccountService(client: client)

    let result = try await service.pollState(
      session: session(cookieName: .bdussBFESS),
      forumID: 42,
      threadID: 100
    )

    XCTAssertEqual(result.userID, 7)
    XCTAssertEqual(result.forumID, 42)
    XCTAssertEqual(result.threadID, 100)
    XCTAssertEqual(result.poll.options.map(\.id), [10, 20])
    XCTAssertEqual(result.poll.selectedOptionIDs, [20])
    XCTAssertTrue(result.poll.isPolled)
    let requests = await client.readRequests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.userID, 7)
    XCTAssertEqual(request.forumID, 42)
    XCTAssertEqual(request.threadID, 100)
    XCTAssertEqual(request.selectedOptionIDs, nil)
    XCTAssertEqual(request.bdussBytes, 192)
    XCTAssertEqual(request.stokenBytes, 64)
    XCTAssertEqual(request.cookieName, .bdussBFESS)
  }

  func testReadRequiresFullCredentialAndValidTargetBeforeCallingCore() async {
    let client = PollVoteAccountClientSpy(readState: state(poll: poll()))
    let service = TiebaCoreAccountService(client: client)

    await assertPollVoteError(.fullCredentialsRequired) {
      try await service.pollState(
        session: session(stoken: nil),
        forumID: 42,
        threadID: 100
      )
    }
    await assertPollVoteError(.unavailable("投票所属的贴吧或主题无效。")) {
      try await service.pollState(session: session(), forumID: 0, threadID: 100)
    }

    let count = await client.readRequestCount()
    XCTAssertEqual(count, 0)
  }

  func testReadAndWriteRejectEveryMismatchedCoreContext() async {
    let mismatches = [
      state(userID: 8, poll: poll()),
      state(forumID: 43, poll: poll()),
      state(threadID: 101, poll: poll()),
    ]

    for mismatch in mismatches {
      let readService = TiebaCoreAccountService(
        client: PollVoteAccountClientSpy(readState: mismatch)
      )
      await assertPollVoteError(
        .unavailable("贴吧返回了不匹配的投票状态，请重新加载后再试。")
      ) {
        try await readService.pollState(session: session(), forumID: 42, threadID: 100)
      }

      let writeService = TiebaCoreAccountService(
        client: PollVoteAccountClientSpy(writeState: mismatch)
      )
      await assertPollVoteError(
        .unavailable("贴吧返回了不匹配的投票状态，请重新加载后再试。")
      ) {
        try await writeService.submitPollVote(
          session: session(),
          forumID: 42,
          threadID: 100,
          selectedOptionIDs: [10]
        )
      }
    }
  }

  func testWriteSortsSelectionAndMapsVerifiedReadback() async throws {
    let verified = poll(
      isMultipleChoice: true,
      isPolled: true,
      selectedOptionIDs: [10, 20]
    )
    let client = PollVoteAccountClientSpy(writeState: state(poll: verified))
    let service = TiebaCoreAccountService(client: client)

    let result = try await service.submitPollVote(
      session: session(cookieName: .bdussBFESS),
      forumID: 42,
      threadID: 100,
      selectedOptionIDs: [20, 10]
    )

    XCTAssertEqual(result.poll.selectedOptionIDs, [10, 20])
    let requests = await client.writeRequests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.selectedOptionIDs, [10, 20])
    XCTAssertEqual(request.cookieName, .bdussBFESS)
  }

  func testWriteRejectsInvalidSelectionBeforeCallingCore() async {
    let client = PollVoteAccountClientSpy(writeState: state(poll: poll()))
    let service = TiebaCoreAccountService(client: client)

    for selectedOptionIDs in [Set<Int32>(), [0], [-1]] {
      await assertPollVoteError(.invalidSelection) {
        try await service.submitPollVote(
          session: session(),
          forumID: 42,
          threadID: 100,
          selectedOptionIDs: selectedOptionIDs
        )
      }
    }

    let count = await client.writeRequestCount()
    XCTAssertEqual(count, 0)
  }

  func testCoreOutcomeUnknownAndInvalidArgumentRemainDistinctAppErrors() async {
    let unknown = TiebaCoreAccountService(
      client: PollVoteAccountClientSpy(writeError: .pollOutcomeUnknown)
    )
    await assertPollVoteError(.outcomeUnknown) {
      try await unknown.submitPollVote(
        session: session(),
        forumID: 42,
        threadID: 100,
        selectedOptionIDs: [10]
      )
    }

    let invalid = TiebaCoreAccountService(
      client: PollVoteAccountClientSpy(writeError: .invalidArgument("unknown option"))
    )
    await assertPollVoteError(.invalidSelection) {
      try await invalid.submitPollVote(
        session: session(),
        forumID: 42,
        threadID: 100,
        selectedOptionIDs: [10]
      )
    }
  }
}

private struct PollVoteAccountClientRequest: Equatable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let selectedOptionIDs: [Int32]?
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
}

private enum PollVoteAccountClientError: Error, Sendable {
  case unexpectedCall
}

private actor PollVoteAccountClientSpy: TiebaAuthenticatedAccountClient {
  private let readState: TiebaPollState?
  private let writeState: TiebaPollState?
  private let readError: TiebaClientError?
  private let writeError: TiebaClientError?
  private var recordedReads: [PollVoteAccountClientRequest] = []
  private var recordedWrites: [PollVoteAccountClientRequest] = []

  init(
    readState: TiebaPollState? = nil,
    writeState: TiebaPollState? = nil,
    readError: TiebaClientError? = nil,
    writeError: TiebaClientError? = nil
  ) {
    self.readState = readState
    self.writeState = writeState
    self.readError = readError
    self.writeError = writeError
  }

  func getPollState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaPollState {
    recordedReads.append(
      request(
        credential: credential,
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: nil
      )
    )
    if let readError { throw readError }
    guard let readState else { throw PollVoteAccountClientError.unexpectedCall }
    return readState
  }

  func submitPollVote(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]
  ) async throws -> TiebaPollState {
    recordedWrites.append(
      request(
        credential: credential,
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: selectedOptionIDs
      )
    )
    if let writeError { throw writeError }
    guard let writeState else { throw PollVoteAccountClientError.unexpectedCall }
    return writeState
  }

  func readRequests() -> [PollVoteAccountClientRequest] { recordedReads }
  func writeRequests() -> [PollVoteAccountClientRequest] { recordedWrites }
  func readRequestCount() -> Int { recordedReads.count }
  func writeRequestCount() -> Int { recordedWrites.count }

  private func request(
    credential: TiebaSessionCredential,
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]?
  ) -> PollVoteAccountClientRequest {
    PollVoteAccountClientRequest(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: selectedOptionIDs,
      bdussBytes: credential.bduss.utf8.count,
      stokenBytes: credential.stoken.utf8.count,
      cookieName: credential.bdussCookieName
    )
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw PollVoteAccountClientError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw PollVoteAccountClientError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw PollVoteAccountClientError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw PollVoteAccountClientError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw PollVoteAccountClientError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw PollVoteAccountClientError.unexpectedCall
  }
}

private func poll(
  isMultipleChoice: Bool = false,
  isPolled: Bool = false,
  selectedOptionIDs: Set<Int32> = []
) -> TiebaPoll {
  TiebaPoll(
    title: "poll",
    isMultipleChoice: isMultipleChoice,
    isPolled: isPolled,
    selectedOptionIDs: selectedOptionIDs,
    tips: "choose",
    endTimestamp: 2_000,
    status: 0,
    participantCount: isPolled ? 1 : 0,
    totalVoteCount: Int64(selectedOptionIDs.count),
    options: [
      TiebaPollOption(id: 10, text: "first", voteCount: 0),
      TiebaPollOption(id: 20, text: "second", voteCount: 0),
    ]
  )
}

private func state(
  userID: Int64 = 7,
  forumID: Int64 = 42,
  threadID: Int64 = 100,
  poll: TiebaPoll
) -> TiebaPollState {
  TiebaPollState(userID: userID, forumID: forumID, threadID: threadID, poll: poll)
}

private func session(
  userID: Int64 = 7,
  stoken: String? = String(repeating: "s", count: 64),
  cookieName: AccountBDUSSCookieName = .bduss
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
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

private func assertPollVoteError<T>(
  _ expected: PollVoteError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected PollVoteError", file: file, line: line)
  } catch let error as PollVoteError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Expected PollVoteError, got \(error)", file: file, line: line)
  }
}
