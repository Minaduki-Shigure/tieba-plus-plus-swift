import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaPollVoteTests: XCTestCase, @unchecked Sendable {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let threadID: Int64 = 100

  func testAuthoritativeDecoderPreservesPollContract() throws {
    let state = try TiebaAuthenticatedDecoder.pollState(
      from: pollPage(isPolled: true, selected: "1,2"),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )

    XCTAssertEqual(state.userID, userID)
    XCTAssertEqual(state.forumID, forumID)
    XCTAssertEqual(state.threadID, threadID)
    XCTAssertEqual(state.poll.type, 3)
    XCTAssertTrue(state.poll.isMultipleChoice)
    XCTAssertTrue(state.poll.isPolled)
    XCTAssertEqual(state.poll.selectedOptionIDs, [1, 2])
    XCTAssertEqual(state.poll.tips, "Choose carefully")
    XCTAssertEqual(state.poll.endTimestamp, 2_000_000_000)
    XCTAssertEqual(state.poll.status, 0)
    XCTAssertEqual(state.poll.lastTimestamp, 1_900_000_000)
    XCTAssertEqual(state.poll.participantCount, 9)
    XCTAssertEqual(state.poll.totalVoteCount, 12)
    XCTAssertEqual(
      state.poll.options,
      [
        TiebaPollOption(id: 1, text: "One", voteCount: 7, image: "https://img/1"),
        TiebaPollOption(id: 2, text: "Two", voteCount: 5, image: "https://img/2"),
      ]
    )
  }

  func testAuthoritativeDecoderAllowsOnlyMatchingOrdinaryMirrorPoll() throws {
    var mirrored = pollPage()
    let poll = mirrored.data.thread.pollInfo
    mirrored.data.thread.clearPollInfo()
    mirrored.data.thread.originThreadInfo.tid = " 100 "
    mirrored.data.thread.originThreadInfo.pollInfo = poll

    let mirroredState = try TiebaAuthenticatedDecoder.pollState(
      from: mirrored,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )
    XCTAssertEqual(mirroredState.poll.options.map(\.id), [1, 2])

    var missingMirrorThreadID = mirrored
    missingMirrorThreadID.data.thread.originThreadInfo.tid = ""
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.pollState(
        from: missingMirrorThreadID,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var mismatchedMirrorThreadID = mirrored
    mismatchedMirrorThreadID.data.thread.originThreadInfo.tid = "101"
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.pollState(
        from: mismatchedMirrorThreadID,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var shared = mirrored
    shared.data.thread.isShareThread = 1
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.pollState(
        from: shared,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var sharedWithDirectPoll = pollPage()
    sharedWithDirectPoll.data.thread.isShareThread = 1
    let directState = try TiebaAuthenticatedDecoder.pollState(
      from: sharedWithDirectPoll,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )
    XCTAssertEqual(directState.poll.options.map(\.id), [1, 2])
  }

  func testAuthoritativeDecoderRejectsIdentityAndMalformedOptionState() throws {
    var wrongUser = pollPage()
    wrongUser.data.user.id += 1
    var wrongForum = pollPage()
    wrongForum.data.forum.id += 1
    var wrongThread = pollPage()
    wrongThread.data.thread.id += 1
    var signedOut = pollPage()
    signedOut.data.user.isLogin = 0
    var duplicateOption = pollPage()
    duplicateOption.data.thread.pollInfo.options[1].id = 1
    var missingOptionID = pollPage()
    missingOptionID.data.thread.pollInfo.options[0].id = 0
    let unknownSelection = pollPage(isPolled: true, selected: "99")
    let duplicateSelection = pollPage(isPolled: true, selected: "1,1")
    let unpolledSelection = pollPage(isPolled: false, selected: "1")
    var singleChoiceMultipleSelection = pollPage(isPolled: true, selected: "1,2")
    singleChoiceMultipleSelection.data.thread.pollInfo.isMulti = 0
    var wrongCount = pollPage()
    wrongCount.data.thread.pollInfo.optionsCount = 3

    for response in [
      wrongUser, wrongForum, wrongThread, signedOut, duplicateOption, missingOptionID,
      unknownSelection,
      duplicateSelection, unpolledSelection, singleChoiceMultipleSelection, wrongCount,
    ] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.pollState(
          from: response,
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
  }

  func testPollWriteResponseChecksBothErrorEnvelopes() throws {
    var outerFailure = AddPollPostResIdl()
    outerFailure.error.errorno = 41
    outerFailure.error.errmsg = "outer denied"
    XCTAssertThrowsError(try TiebaAuthenticatedDecoder.checkPollWriteResponse(outerFailure)) {
      XCTAssertEqual($0 as? TiebaClientError, .server(code: 41, message: "outer denied"))
    }

    var innerFailure = AddPollPostResIdl()
    innerFailure.data.errorCode = 42
    innerFailure.data.errorMsg = "inner denied"
    XCTAssertThrowsError(try TiebaAuthenticatedDecoder.checkPollWriteResponse(innerFailure)) {
      XCTAssertEqual($0 as? TiebaClientError, .server(code: 42, message: "inner denied"))
    }

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkPollWriteResponse(AddPollPostResIdl())
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    var readFailure = pollPage()
    readFailure.error.errorno = 43
    readFailure.error.errmsg = "read denied"
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.pollState(
        from: readFailure,
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: 43, message: "read denied")) }
  }

  func testPollReadAndWriteRequestsUseMinimalBoundFields() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let credential = sessionCredential()
    let read = try factory.pollState(
      credential: credential,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID
    )
    let readFields = try multipartScalarFields(read)
    let readMessage = try PbPageReqIdl(serializedBytes: try protobufPayload(read))

    XCTAssertEqual(
      read.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/pb/page?cmd=302001&format=protobuf"
    )
    XCTAssertEqual(read.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(read.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      read.value(forHTTPHeaderField: "User-Agent"),
      "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.52.1.0"
    )
    XCTAssertEqual(readFields, ["stoken": credential.stoken])
    XCTAssertEqual(readMessage.data.kz, threadID)
    XCTAssertEqual(readMessage.data.forumID, forumID)
    XCTAssertEqual(readMessage.data.pn, 1)
    XCTAssertEqual(readMessage.data.rn, 2)
    XCTAssertEqual(readMessage.data.common.bduss, credential.bduss)
    XCTAssertEqual(readMessage.data.common.stoken, credential.stoken)
    XCTAssertEqual(readMessage.data.common.clientType, 2)
    XCTAssertEqual(
      readMessage.data.common.clientVersion,
      "12.52.1.0"
    )
    XCTAssertEqual(
      readMessage.data.common.userAgent,
      "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.52.1.0"
    )
    XCTAssertEqual(readMessage.data.common.cuid, "")
    XCTAssertEqual(readMessage.data.common.phoneImei, "")
    XCTAssertEqual(readMessage.data.common.androidID, "")
    XCTAssertEqual(readMessage.data.common.idfv, "")

    let write = try factory.submitPollVote(
      credential: credential,
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: [2, 1]
    )
    let writeFields = try multipartScalarFields(write)
    let writeMessage = try AddPollPostReqIdl(serializedBytes: try protobufPayload(write))
    let signedFields = [
      ("BDUSS", credential.bduss),
      ("_client_type", "2"),
      ("_client_version", "11.10.8.6"),
      ("stoken", credential.stoken),
    ]

    XCTAssertEqual(
      write.url?.absoluteString,
      "https://tiebac.baidu.com/c/c/post/addPollPost?cmd=309006&format=protobuf"
    )
    XCTAssertEqual(write.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(write.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      write.value(forHTTPHeaderField: "User-Agent"),
      "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.35.1.0"
    )
    XCTAssertEqual(Set(writeFields.keys), ["BDUSS", "_client_type", "_client_version", "stoken", "sign"])
    XCTAssertEqual(writeFields["BDUSS"], credential.bduss)
    XCTAssertEqual(writeFields["stoken"], credential.stoken)
    XCTAssertEqual(writeFields["_client_version"], "11.10.8.6")
    XCTAssertEqual(writeFields["sign"], TiebaAuthenticatedRequestFactory.signature(for: signedFields))
    XCTAssertEqual(writeMessage.data.threadID, UInt64(threadID))
    XCTAssertEqual(writeMessage.data.forumID, UInt64(forumID))
    XCTAssertEqual(writeMessage.data.options, "1,2")
  }

  func testPollWriteArgumentValidationRejectsMalformedSelections() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let selections: [[Int32]] = [[], [0], [-1], [1, 1]]
    for selection in selections {
      XCTAssertThrowsError(
        try factory.submitPollVote(
          credential: sessionCredential(),
          expectedUserID: userID,
          forumID: forumID,
          threadID: threadID,
          selectedOptionIDs: selection
        )
      ) { error in
        guard case .invalidArgument = error as? TiebaClientError else {
          return XCTFail("Expected invalidArgument, got \(error)")
        }
      }
    }
  }

  func testSubmissionPreflightsWritesOnceAndRequiresExactReadback() async throws {
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try successfulWriteResponse().serializedData()),
        .data(try pollPage(isPolled: true, selected: "1,2").serializedData()),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.submitPollVote(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: [2, 1]
    )

    XCTAssertEqual(result.poll.selectedOptionIDs, [1, 2])
    let requests = await transport.requests()
    XCTAssertEqual(requests.map { $0.url?.path }, ["/c/f/pb/page", "/c/c/post/addPollPost", "/c/f/pb/page"])
    XCTAssertEqual(requests.filter { $0.url?.path == "/c/c/post/addPollPost" }.count, 1)
  }

  func testLostWriteResponseCanBeReconciledButNeverRetried() async throws {
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .failure(.transportFailure),
        .data(try pollPage(isPolled: true, selected: "1").serializedData()),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.submitPollVote(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: [1]
    )

    XCTAssertEqual(result.poll.selectedOptionIDs, [1])
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testServerRejectedAcknowledgementStillPerformsOneConfirmingReadback() async throws {
    var rejected = AddPollPostResIdl()
    rejected.data.errorCode = 340_006
    rejected.data.errorMsg = "denied"
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try rejected.serializedData()),
        .data(try pollPage(isPolled: true, selected: "2").serializedData()),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.submitPollVote(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: [2]
    )

    XCTAssertEqual(result.poll.selectedOptionIDs, [2])
    let requestCount = await transport.requestCount()
    let writeCount = await transport.writeCount()
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(writeCount, 1)
  }

  func testAlreadyVotedExactSelectionReturnsPreflightWithoutWriting() async throws {
    let transport = PollStubTransport(
      responses: [.data(try pollPage(isPolled: true, selected: "1,2").serializedData())]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.submitPollVote(
      credential: sessionCredential(),
      expectedUserID: userID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: [2, 1]
    )

    XCTAssertEqual(result.poll.selectedOptionIDs, [1, 2])
    let requestCount = await transport.requestCount()
    let writeCount = await transport.writeCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(writeCount, 0)
  }

  func testAlreadyVotedDifferentSelectionFailsPreflightWithoutWriting() async throws {
    let transport = PollStubTransport(
      responses: [.data(try pollPage(isPolled: true, selected: "1").serializedData())]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    do {
      _ = try await client.submitPollVote(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: [2]
      )
      XCTFail("Expected an already-voted error")
    } catch let error as TiebaClientError {
      guard case .invalidArgument = error else {
        return XCTFail("Expected invalidArgument, got \(error)")
      }
    }
    let requestCount = await transport.requestCount()
    let writeCount = await transport.writeCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(writeCount, 0)
  }

  func testUnverifiableReadbackReturnsDedicatedUnknownErrorWithoutRetry() async throws {
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .failure(.transportFailure),
        .data(try pollPage().serializedData()),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.pollOutcomeUnknown) {
      _ = try await client.submitPollVote(
        credential: sessionCredential(),
        expectedUserID: userID,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: [1]
      )
    }
    let writeCount = await transport.writeCount()
    let requestCount = await transport.requestCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(requestCount, 3)
  }

  func testIdenticalConcurrentSubmissionsShareOneFlight() async throws {
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try successfulWriteResponse().serializedData()),
        .data(try pollPage(isPolled: true, selected: "1,2").serializedData()),
      ],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1, 2]
      )
    }
    guard await transport.waitUntilRequestCount(1) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for preflight")
    }
    let second = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [2, 1]
      )
    }
    guard await waitUntil({ await client.pollWaiterCount(
      expectedUserID: self.userID, forumID: self.forumID, threadID: self.threadID
    ) == 2 }) else {
      first.cancel()
      second.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for equivalent callers")
    }
    await transport.releaseBlockedRequest()

    let firstValue = try await first.value
    let secondValue = try await second.value
    let values = [firstValue, secondValue]
    XCTAssertTrue(values.allSatisfy { $0.poll.selectedOptionIDs == [1, 2] })
    let writeCount = await transport.writeCount()
    let requestCount = await transport.requestCount()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(requestCount, 3)
  }

  func testConflictingConcurrentSubmissionWaitsThenOnlyReads() async throws {
    let voted = try pollPage(isPolled: true, selected: "1").serializedData()
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try successfulWriteResponse().serializedData()),
        .data(voted),
        .data(voted),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1]
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for write")
    }
    let conflicting = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [2]
      )
    }
    await transport.releaseBlockedRequest()

    let firstValue = try await first.value
    let conflictingValue = try await conflicting.value
    let writeCount = await transport.writeCount()
    let requestCount = await transport.requestCount()
    XCTAssertEqual(firstValue.poll.selectedOptionIDs, [1])
    XCTAssertEqual(conflictingValue.poll.selectedOptionIDs, [1])
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(requestCount, 4)
  }

  func testCredentialRotationWaitsThenOnlyReadsWithRotatedSession() async throws {
    let voted = try pollPage(isPolled: true, selected: "1").serializedData()
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try successfulWriteResponse().serializedData()),
        .data(voted),
        .data(voted),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let original = sessionCredential()
    let rotated = TiebaSessionCredential(
      bduss: String(repeating: "C", count: 192),
      stoken: String(repeating: "d", count: 64),
      bdussCookieName: .bdussBFESS
    )
    let first = Task {
      try await client.submitPollVote(
        credential: original, expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1]
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for original-session write")
    }
    let rotatedCaller = Task {
      try await client.submitPollVote(
        credential: rotated, expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1]
      )
    }
    await transport.releaseBlockedRequest()

    _ = try await first.value
    _ = try await rotatedCaller.value
    let requests = await transport.requests()
    XCTAssertEqual(requests.filter { $0.url?.path == "/c/c/post/addPollPost" }.count, 1)
    XCTAssertEqual(requests.count, 4)
    XCTAssertEqual(try multipartScalarFields(requests[3])["stoken"], rotated.stoken)
  }

  func testDifferentAccountOrThreadCanReachWritesInParallel() async throws {
    for (otherUserID, otherThreadID) in [
      (userID + 1, threadID),
      (userID, threadID + 1),
    ] {
      let transport = PollStubTransport(
        responses: [
          .data(try pollPage().serializedData()),
          .data(try successfulWriteResponse().serializedData()),
          .data(
            try pollPage(userID: otherUserID, threadID: otherThreadID).serializedData()
          ),
          .data(try successfulWriteResponse().serializedData()),
          .data(
            try pollPage(
              userID: otherUserID,
              threadID: otherThreadID,
              isPolled: true,
              selected: "2"
            ).serializedData()
          ),
          .data(try pollPage(isPolled: true, selected: "1").serializedData()),
        ],
        blockedRequestIndex: 1
      )
      let client = TiebaAuthenticatedClient(transport: transport)
      let first = Task {
        try await client.submitPollVote(
          credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
          threadID: threadID, selectedOptionIDs: [1]
        )
      }
      guard await transport.waitUntilRequestCount(2) else {
        first.cancel()
        await transport.releaseBlockedRequest()
        return XCTFail("Timed out waiting for first write")
      }
      let second = Task {
        try await client.submitPollVote(
          credential: sessionCredential(), expectedUserID: otherUserID, forumID: forumID,
          threadID: otherThreadID, selectedOptionIDs: [2]
        )
      }
      guard await transport.waitUntilRequestCount(5) else {
        first.cancel()
        second.cancel()
        await transport.releaseBlockedRequest()
        return XCTFail("Different poll resource did not proceed in parallel")
      }

      let secondValue = try await second.value
      XCTAssertEqual(secondValue.poll.selectedOptionIDs, [2])
      await transport.releaseBlockedRequest()
      let firstValue = try await first.value
      XCTAssertEqual(firstValue.poll.selectedOptionIDs, [1])
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 2)
    }
  }

  func testCancellationDuringPreflightPreventsWrite() async throws {
    let transport = PollStubTransport(
      responses: [.data(try pollPage().serializedData())],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let caller = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1]
      )
    }
    guard await transport.waitUntilRequestCount(1) else {
      caller.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for preflight")
    }
    caller.cancel()
    do {
      _ = try await caller.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    await transport.releaseBlockedRequest()
    guard await waitUntil({
      !(await client.pollFlightExists(
        expectedUserID: self.userID,
        forumID: self.forumID,
        threadID: self.threadID
      ))
    }) else {
      return XCTFail("Cancelled preflight flight was not cleared")
    }
    let requestCount = await transport.requestCount()
    let writeCount = await transport.writeCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(writeCount, 0)
  }

  func testCancellingAWaiterDoesNotCancelDispatchedWrite() async throws {
    let transport = PollStubTransport(
      responses: [
        .data(try pollPage().serializedData()),
        .data(try successfulWriteResponse().serializedData()),
        .data(try pollPage(isPolled: true, selected: "1").serializedData()),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let caller = Task {
      try await client.submitPollVote(
        credential: sessionCredential(), expectedUserID: userID, forumID: forumID,
        threadID: threadID, selectedOptionIDs: [1]
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      caller.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("Timed out waiting for write")
    }
    caller.cancel()
    do {
      _ = try await caller.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    await transport.releaseBlockedRequest()
    let completedReadback = await transport.waitUntilRequestCount(3)
    XCTAssertTrue(completedReadback)
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  private func pollPage(
    userID: Int64? = nil,
    forumID: Int64? = nil,
    threadID: Int64? = nil,
    isPolled: Bool = false,
    selected: String = ""
  ) -> PbPageResIdl {
    let userID = userID ?? self.userID
    let forumID = forumID ?? self.forumID
    let threadID = threadID ?? self.threadID
    var user = User()
    user.id = userID
    user.isLogin = 1
    var forum = SimpleForum()
    forum.id = forumID
    var first = PollInfo.PollOption()
    first.id = 1
    first.num = 7
    first.text = "One"
    first.image = "https://img/1"
    var second = PollInfo.PollOption()
    second.id = 2
    second.num = 5
    second.text = "Two"
    second.image = "https://img/2"
    var poll = PollInfo()
    poll.type = 3
    poll.isMulti = 1
    poll.totalNum = 9
    poll.optionsCount = 2
    poll.isPolled = isPolled ? 1 : 0
    poll.polledValue = selected
    poll.tips = "Choose carefully"
    poll.endTime = 2_000_000_000
    poll.options = [first, second]
    poll.status = 0
    poll.totalPoll = 12
    poll.title = "A poll"
    poll.lastTime = 1_900_000_000
    var thread = ThreadInfo()
    thread.id = threadID
    thread.fid = forumID
    thread.pollInfo = poll
    var data = PbPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.thread = thread
    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private func successfulWriteResponse() -> AddPollPostResIdl {
    var response = AddPollPostResIdl()
    response.data = AddPollPostResIdl.DataRes()
    return response
  }

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "A", count: 192),
      stoken: String(repeating: "b", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func assertError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected TiebaClientError")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await predicate() { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return await predicate()
  }
}

private actor PollStubTransport: TiebaTransport {
  enum Response: Sendable {
    case data(Data)
    case failure(TiebaClientError)
  }

  private let responses: [Response]
  private let blockedRequestIndex: Int?
  private var capturedRequests = [URLRequest]()
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var isReleased = false

  init(responses: [Response], blockedRequestIndex: Int? = nil) {
    self.responses = responses
    self.blockedRequestIndex = blockedRequestIndex
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let index = capturedRequests.count
    guard responses.indices.contains(index) else { throw TiebaClientError.transportFailure }
    capturedRequests.append(request)
    if index == blockedRequestIndex, !isReleased {
      await withCheckedContinuation { continuation in
        if isReleased { continuation.resume() } else { blockedContinuation = continuation }
      }
    }
    switch responses[index] {
    case .data(let body):
      if let maximumBodyBytes, body.count > maximumBodyBytes {
        throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
      }
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .failure(let error):
      throw error
    }
  }

  func releaseBlockedRequest() {
    isReleased = true
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }

  func waitUntilRequestCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while capturedRequests.count < count, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return capturedRequests.count >= count
  }

  func requests() -> [URLRequest] { capturedRequests }
  func requestCount() -> Int { capturedRequests.count }
  func writeCount() -> Int {
    capturedRequests.filter { $0.url?.path == "/c/c/post/addPollPost" }.count
  }
}

private func multipartScalarFields(_ request: URLRequest) throws -> [String: String] {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  let marker = Data(
    "--\(TiebaRequestFactory.multipartBoundary)\r\n"
      .appending("Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n")
      .utf8
  )
  guard let dataRange = body.range(of: marker) else { throw TiebaClientError.transportFailure }
  let scalarBytes = body[..<dataRange.lowerBound]
  guard let text = String(data: scalarBytes, encoding: .utf8) else {
    throw TiebaClientError.transportFailure
  }
  let namePrefix = "Content-Disposition: form-data; name=\""
  let nameSuffix = "\"\r\n\r\n"
  var result = [String: String]()
  for part in text.components(separatedBy: "--\(TiebaRequestFactory.multipartBoundary)\r\n") {
    guard part.hasPrefix(namePrefix), let nameEnd = part.range(of: nameSuffix) else { continue }
    let nameStart = part.index(part.startIndex, offsetBy: namePrefix.count)
    let name = String(part[nameStart..<nameEnd.lowerBound])
    result[name] = String(part[nameEnd.upperBound...]).trimmingCharacters(in: .newlines)
  }
  return result
}

private func protobufPayload(_ request: URLRequest) throws -> Data {
  guard let body = request.httpBody else { throw TiebaClientError.transportFailure }
  let marker = Data(
    "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
  )
  let suffix = Data("\r\n---*_r1999--\r\n".utf8)
  guard let range = body.range(of: marker), body.suffix(suffix.count) == suffix else {
    throw TiebaClientError.transportFailure
  }
  return body.subdata(in: range.upperBound..<(body.count - suffix.count))
}
