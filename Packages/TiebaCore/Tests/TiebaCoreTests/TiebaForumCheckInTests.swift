import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaForumCheckInTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let forumID: Int64 = 42
  private let forumName = "swift"
  private let tbs = "91be894d01799c4991be894d01"

  func testCheckInRequestUsesExactMinimalSignedFormAndHeaders() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let request = try factory.checkInToForum(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: "  \(forumName)  ",
      tbs: tbs
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/forum/sign")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 11.10.8.6"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "fid", "kw", "tbs", "sign"]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "11.10.8.6")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["kw"], forumName)
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["sign"], "d4b44e7b2b55ba55c74dc5c3f56c49d2")
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential().bduss),
          ("_client_version", "11.10.8.6"),
          ("fid", String(forumID)),
          ("kw", forumName),
          ("tbs", tbs),
        ]
      )
    )
  }

  func testAccountStateMapsAuthoritativeCheckInAndLegacyMembershipStillWorks() async throws {
    let body = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: 6,
      rank: 43
    ).serializedData()
    let transport = CheckInStubTransport(steps: [.response(body)])
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.getForumAccountState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertEqual(
      state.membership,
      TiebaForumMembership(
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        isFollowed: true
      )
    )
    XCTAssertEqual(
      state.checkIn,
      TiebaForumCheckIn(isCheckedIn: false, consecutiveDays: 6, rank: 43)
    )
    XCTAssertFalse(String(describing: state).contains(tbs))
    XCTAssertFalse(String(reflecting: state).contains(tbs))

    let legacyTransport = CheckInStubTransport(steps: [.response(body)])
    let legacyClient = TiebaAuthenticatedClient(transport: legacyTransport)
    let membership = try await legacyClient.getForumMembership(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )
    XCTAssertEqual(membership, state.membership)
  }

  func testLegacyMembershipAndFollowIgnoreMalformedOptionalCheckInMetadata() async throws {
    let malformed = accountStateResponse(
      isFollowed: false,
      isCheckedIn: false,
      signUserID: userID + 1
    )
    let body = try malformed.serializedData()

    let decoded = try TiebaAuthenticatedDecoder.forumMembership(
      from: malformed,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )
    XCTAssertFalse(decoded.membership.isFollowed)
    XCTAssertNil(decoded.state.checkIn)

    let membershipClient = TiebaAuthenticatedClient(
      transport: CheckInStubTransport(steps: [.response(body)])
    )
    let membership = try await membershipClient.getForumMembership(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )
    XCTAssertFalse(membership.isFollowed)

    let followTransport = CheckInStubTransport(
      steps: [
        .response(body),
        .response(Data(#"{"error_code":"0"}"#.utf8)),
      ]
    )
    let followClient = TiebaAuthenticatedClient(transport: followTransport)
    let followed = try await followClient.setForumFollowState(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      isFollowed: true
    )
    XCTAssertTrue(followed.isFollowed)
    let followSnapshot = await followTransport.snapshot()
    XCTAssertEqual(followSnapshot.requests.count, 2)

    let accountStateClient = TiebaAuthenticatedClient(
      transport: CheckInStubTransport(steps: [.response(body)])
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await accountStateClient.getForumAccountState(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }

    let checkInTransport = CheckInStubTransport(steps: [.response(body)])
    let checkInClient = TiebaAuthenticatedClient(transport: checkInTransport)
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await checkInClient.checkInToForum(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }
    let checkInSnapshot = await checkInTransport.snapshot()
    XCTAssertEqual(checkInSnapshot.requests.count, 1)
  }

  func testMissingSignInfoMapsToUnavailableCheckInState() throws {
    let response = accountStateResponse(isFollowed: true, isCheckedIn: nil)
    let context = try TiebaAuthenticatedDecoder.forumAccountState(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertNil(context.state.checkIn)
    XCTAssertFalse(String(describing: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(
      Array(context.customMirror.children).contains { String(reflecting: $0.value).contains(tbs) }
    )
  }

  func testProbeRejectsMismatchedOrMalformedSignUser() {
    let mismatched = accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      signUserID: userID + 1
    )
    assertProbeError(.invalidAuthenticatedResponse, response: mismatched)

    let invalidFlag = accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      rawIsCheckedIn: 2
    )
    assertProbeError(.invalidAuthenticatedResponse, response: invalidFlag)

    let negativeDays = accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: -1
    )
    assertProbeError(.invalidAuthenticatedResponse, response: negativeDays)

    let negativeRank = accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      rank: -1
    )
    assertProbeError(.invalidAuthenticatedResponse, response: negativeRank)
  }

  func testCheckInRejectsForumThatIsNotFollowedWithoutWriting() async throws {
    let probe = try accountStateResponse(
      isFollowed: false,
      isCheckedIn: false
    ).serializedData()
    let transport = CheckInStubTransport(steps: [.response(probe)])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.forumNotFollowed) {
      _ = try await client.checkInToForum(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(snapshot.requests.first?.url?.path, "/c/f/frs/page")
  }

  func testCheckInRejectsUnavailableStateWithoutWriting() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: nil
    ).serializedData()
    let transport = CheckInStubTransport(steps: [.response(probe)])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.forumCheckInUnavailable) {
      _ = try await client.checkInToForum(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
  }

  func testCheckInIsIdempotentWhenProbeSaysAlreadyCheckedIn() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: true,
      consecutiveDays: 7,
      rank: 42
    ).serializedData()
    let transport = CheckInStubTransport(steps: [.response(probe)])
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.checkInToForum(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertEqual(
      state.checkIn,
      TiebaForumCheckIn(isCheckedIn: true, consecutiveDays: 7, rank: 42)
    )
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes]
    )
  }

  func testCheckInProbesThenSendsOneBoundedWriteAndReturnsServerState() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: 6,
      rank: 43,
      level: 12,
      levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
      currentExperience: 345,
      targetExperience: 500
    ).serializedData()
    let success = checkInJSON(consecutiveDays: 7, rank: 42)
    let transport = CheckInStubTransport(
      steps: [.response(probe), .response(success)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let state = try await client.checkInToForum(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName
    )

    XCTAssertTrue(state.membership.isFollowed)
    XCTAssertEqual(
      state.checkIn,
      TiebaForumCheckIn(isCheckedIn: true, consecutiveDays: 7, rank: 42)
    )
    XCTAssertEqual(
      state.levelProgress,
      TiebaForumLevelProgress(
        level: 12,
        levelName: "\u{6d77}\u{7eb3}\u{767e}\u{5ddd}",
        currentExperience: 345,
        targetExperience: 500
      )
    )
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
    XCTAssertEqual(snapshot.requests.last?.url?.path, "/c/c/forum/sign")
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.forumCheckInResponseMaximumBytes,
      ]
    )
  }

  func testCheckInDecoderRejectsIdentityAndUnconfirmedSignIn() throws {
    let mismatched = checkInJSON(userID: userID + 1)
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumCheckIn(from: mismatched, expectedUserID: userID)
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }

    let notCheckedIn = checkInJSON(isCheckedIn: 0)
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumCheckIn(from: notCheckedIn, expectedUserID: userID)
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testCheckInDecoderRejectsMalformedBooleanFractionOverflowAndNegativeValues() {
    let malformedBodies = [
      #"{"error_code":0,"user_info":{"user_id":"957339815","is_sign_in":true,"cont_sign_num":7,"user_sign_rank":42}}"#,
      #"{"error_code":0,"user_info":{"user_id":"957339815","is_sign_in":1,"cont_sign_num":1.5,"user_sign_rank":42}}"#,
      #"{"error_code":0,"user_info":{"user_id":"9223372036854775808","is_sign_in":1,"cont_sign_num":7,"user_sign_rank":42}}"#,
      #"{"error_code":0,"user_info":{"user_id":"957339815","is_sign_in":1,"cont_sign_num":-1,"user_sign_rank":42}}"#,
      #"{"error_code":0,"user_info":{"user_id":"957339815","is_sign_in":1,"cont_sign_num":7,"user_sign_rank":-1}}"#,
    ]

    for body in malformedBodies {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.forumCheckIn(
          from: Data(body.utf8),
          expectedUserID: userID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    }
  }

  func testCheckInDecoderRejectsTopLevelAndNestedServerErrors() {
    let failures: [(Data, TiebaClientError)] = [
      (
        Data(#"{"error_code":"340006","error_msg":"denied"}"#.utf8),
        .server(code: 340_006, message: "denied")
      ),
      (
        Data(#"{"error_code":0,"error":{"errno":"110001","errmsg":"login"}}"#.utf8),
        .server(code: 110_001, message: "login")
      ),
    ]

    for (body, expected) in failures {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.forumCheckIn(from: body, expectedUserID: userID)
      ) { XCTAssertEqual($0 as? TiebaClientError, expected) }
    }
  }

  func testCheckInResponseIsBoundedAt64KiBWithoutRetry() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false
    ).serializedData()
    let oversized = Data(
      repeating: 0,
      count: TiebaAuthenticatedClient.forumCheckInResponseMaximumBytes + 1
    )
    let transport = CheckInStubTransport(
      steps: [.response(probe), .response(oversized)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.forumCheckInResponseMaximumBytes)
    ) {
      _ = try await client.checkInToForum(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
  }

  func testCheckInTransportFailureAfterWriteAttemptIsNotRetried() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false
    ).serializedData()
    let transport = CheckInStubTransport(
      steps: [.response(probe), .failure(.transportFailure)]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.transportFailure) {
      _ = try await client.checkInToForum(
        credential: credential(),
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 2)
    XCTAssertEqual(snapshot.requests.last?.url?.path, "/c/c/forum/sign")
  }

  func testConcurrentEquivalentCheckInsShareOneProbeAndOneWrite() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: 6,
      rank: 43
    ).serializedData()
    let transport = GatedCheckInTransport(
      responses: [probe, checkInJSON(consecutiveDays: 7, rank: 42)],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName

    let first = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: "  \(targetForumName)  "
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    guard firstRequestStarted else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first check-in probe")
      return
    }
    let second = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let didJoin = await waitUntilForumCheckInWaiterCounts(
      client: client,
      shared: 1,
      conflict: 0
    )
    guard didJoin else {
      second.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await second.result
      XCTFail("Timed out waiting for the equivalent check-in to join")
      return
    }

    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await transport.releaseBlockedRequest()
    let firstState = try await first.value
    let secondState = try await second.value

    XCTAssertEqual(firstState, secondState)
    XCTAssertEqual(
      firstState.checkIn,
      TiebaForumCheckIn(isCheckedIn: true, consecutiveDays: 7, rank: 42)
    )
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      ["/c/f/frs/page", "/c/c/forum/sign"]
    )
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.forumMembershipResponseMaximumBytes,
        TiebaAuthenticatedClient.forumCheckInResponseMaximumBytes,
      ]
    )
  }

  func testCancellingJoinedEquivalentCallerKeepsSharedCheckInAndResult() async throws {
    let probe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: 6,
      rank: 43
    ).serializedData()
    let transport = GatedCheckInTransport(
      responses: [probe, checkInJSON(consecutiveDays: 7, rank: 42)],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName

    let first = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    guard firstRequestStarted else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first cancellable probe")
      return
    }
    let joined = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: " \(targetForumName) "
      )
    }
    let didJoin = await waitUntilForumCheckInWaiterCounts(
      client: client,
      shared: 1,
      conflict: 0
    )
    guard didJoin else {
      joined.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await joined.result
      XCTFail("Timed out waiting for the cancellable caller to join")
      return
    }

    joined.cancel()
    XCTAssertTrue(joined.isCancelled)
    let countsAfterCancellation = await client.forumCheckInWaiterCounts(
      expectedUserID: expectedUserID,
      forumID: targetForumID
    )
    XCTAssertEqual(countsAfterCancellation.shared, 1)
    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)

    await transport.releaseBlockedRequest()
    let firstState = try await first.value
    let joinedState = try await joined.value

    XCTAssertEqual(firstState, joinedState)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      ["/c/f/frs/page", "/c/c/forum/sign"]
    )
    let finalCounts = await client.forumCheckInWaiterCounts(
      expectedUserID: expectedUserID,
      forumID: targetForumID
    )
    XCTAssertEqual(finalCounts.shared, 0)
    XCTAssertEqual(finalCounts.conflict, 0)
  }

  func testConcurrentEquivalentCheckInFailuresShareOneProbeAndError() async throws {
    let transport = GatedCheckInTransport(
      responses: [Data([0x0A])],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = credential()
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName

    let first = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    guard firstRequestStarted else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first failing probe")
      return
    }
    let second = Task {
      try await client.checkInToForum(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: " \(targetForumName) "
      )
    }
    let didJoin = await waitUntilForumCheckInWaiterCounts(
      client: client,
      shared: 1,
      conflict: 0
    )
    guard didJoin else {
      second.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await second.result
      XCTFail("Timed out waiting for the failing check-in to join")
      return
    }

    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await transport.releaseBlockedRequest()
    var errors = [TiebaClientError]()
    for task in [first, second] {
      do {
        _ = try await task.value
        XCTFail("Expected invalid protobuf")
      } catch let error as TiebaClientError {
        errors.append(error)
      } catch {
        XCTFail("Unexpected error type: \(error)")
      }
    }
    XCTAssertEqual(errors, [.invalidProtobuf, .invalidProtobuf])
    let finalRequestCount = await transport.requestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testRotatedCredentialWaitsThenPerformsIndependentProbeWithoutSecondWrite() async throws {
    let unsignedProbe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false,
      consecutiveDays: 6,
      rank: 43
    ).serializedData()
    let rotatedProbe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: true,
      consecutiveDays: 8,
      rank: 99
    ).serializedData()
    let transport = GatedCheckInTransport(
      responses: [
        unsignedProbe,
        checkInJSON(consecutiveDays: 7, rank: 42),
        rotatedProbe,
      ],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let oldCredential = credential("b")
    let rotatedCredential = credential("c")
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName

    let first = Task {
      try await client.checkInToForum(
        credential: oldCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    guard firstRequestStarted else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the old-credential probe")
      return
    }
    let rotated = Task {
      try await client.checkInToForum(
        credential: rotatedCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let didWaitForOldFlight = await waitUntilForumCheckInWaiterCounts(
      client: client,
      shared: 0,
      conflict: 1
    )
    guard didWaitForOldFlight else {
      rotated.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await rotated.result
      XCTFail("Timed out waiting for the rotated credential to serialize")
      return
    }

    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await transport.releaseBlockedRequest()
    let firstState = try await first.value
    let rotatedState = try await rotated.value

    XCTAssertEqual(firstState.checkIn?.rank, 42)
    XCTAssertEqual(rotatedState.checkIn?.rank, 99)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      ["/c/f/frs/page", "/c/c/forum/sign", "/c/f/frs/page"]
    )
    XCTAssertEqual(
      try probeCredential(from: snapshot.requests[0]),
      oldCredential.bduss
    )
    XCTAssertEqual(
      try probeCredential(from: snapshot.requests[2]),
      rotatedCredential.bduss
    )
  }

  func testCancelledRotatedCredentialWaiterDoesNotStartOrLeakARequest() async throws {
    let unsignedProbe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: false
    ).serializedData()
    let laterProbe = try accountStateResponse(
      isFollowed: true,
      isCheckedIn: true,
      consecutiveDays: 8,
      rank: 99
    ).serializedData()
    let transport = GatedCheckInTransport(
      responses: [
        unsignedProbe,
        checkInJSON(),
        laterProbe,
      ],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let oldCredential = credential("b")
    let rotatedCredential = credential("c")
    let expectedUserID = userID
    let targetForumID = forumID
    let targetForumName = forumName

    let first = Task {
      try await client.checkInToForum(
        credential: oldCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(1)
    guard firstRequestStarted else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the old-credential probe")
      return
    }
    let cancelled = Task {
      try await client.checkInToForum(
        credential: rotatedCredential,
        expectedUserID: expectedUserID,
        forumID: targetForumID,
        forumName: targetForumName
      )
    }
    let didRegisterWaiter = await waitUntilForumCheckInWaiterCounts(
      client: client,
      shared: 0,
      conflict: 1
    )
    guard didRegisterWaiter else {
      cancelled.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await cancelled.result
      XCTFail("Timed out waiting for the cancellable conflict waiter")
      return
    }
    cancelled.cancel()

    do {
      _ = try await cancelled.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
    let waiterCountsAfterCancellation = await client.forumCheckInWaiterCounts(
      expectedUserID: expectedUserID,
      forumID: targetForumID
    )
    XCTAssertEqual(waiterCountsAfterCancellation.conflict, 0)
    let requestCountBeforeRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)

    await transport.releaseBlockedRequest()
    _ = try await first.value
    let later = try await client.checkInToForum(
      credential: rotatedCredential,
      expectedUserID: expectedUserID,
      forumID: targetForumID,
      forumName: targetForumName
    )
    XCTAssertEqual(later.checkIn?.rank, 99)
    let finalRequestCount = await transport.requestCount()
    XCTAssertEqual(finalRequestCount, 3)
  }

  private func waitUntilForumCheckInWaiterCounts(
    client: TiebaAuthenticatedClient,
    shared: Int,
    conflict: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let counts = await client.forumCheckInWaiterCounts(
        expectedUserID: userID,
        forumID: forumID
      )
      if counts.shared == shared && counts.conflict == conflict {
        return true
      }
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return false
  }

  private func credential(_ component: String = "b") -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: component, count: 192))
  }

  private func accountStateResponse(
    isFollowed: Bool,
    isCheckedIn: Bool?,
    signUserID: Int64? = nil,
    rawIsCheckedIn: Int32? = nil,
    consecutiveDays: Int32 = 0,
    rank: Int32 = 0,
    level: Int32 = 0,
    levelName: String = "",
    currentExperience: Int32 = 0,
    targetExperience: Int32 = 0
  ) -> FrsPageResIdl {
    var user = User()
    user.id = userID

    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID
    forum.name = forumName
    forum.isLike = isFollowed ? 1 : 0
    forum.userLevel = level
    forum.levelName = levelName
    forum.curScore = currentExperience
    forum.levelupScore = targetExperience
    if let isCheckedIn {
      var signUser = FrsPageResIdl.DataRes.ForumInfo.SignInfo.SignUser()
      signUser.userID = signUserID ?? userID
      signUser.isSignIn = rawIsCheckedIn ?? (isCheckedIn ? 1 : 0)
      signUser.contSignNum = consecutiveDays
      signUser.userSignRank = rank

      var signInfo = FrsPageResIdl.DataRes.ForumInfo.SignInfo()
      signInfo.userInfo = signUser
      forum.signInInfo = signInfo
    }

    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs

    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti

    var response = FrsPageResIdl()
    response.data = data
    return response
  }

  private func checkInJSON(
    userID: Int64? = nil,
    isCheckedIn: Int = 1,
    consecutiveDays: Int = 7,
    rank: Int = 42
  ) -> Data {
    Data(
      """
      {"error_code":"0","user_info":{"user_id":"\(userID ?? self.userID)","is_sign_in":"\(isCheckedIn)","cont_sign_num":"\(consecutiveDays)","user_sign_rank":"\(rank)"}}
      """.utf8
    )
  }

  private func assertProbeError(
    _ expected: TiebaClientError,
    response: FrsPageResIdl,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.forumAccountState(
        from: response,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName
      ),
      file: file,
      line: line
    ) { XCTAssertEqual($0 as? TiebaClientError, expected, file: file, line: line) }
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    return Dictionary(
      uniqueKeysWithValues: components.queryItems?.compactMap { item in
        item.value.map { (item.name, $0) }
      } ?? []
    )
  }

  private func probeCredential(from request: URLRequest) throws -> String {
    let body = try XCTUnwrap(request.httpBody)
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    XCTAssertTrue(body.starts(with: prefix))
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    let payload = body.subdata(in: prefix.count..<(body.count - suffix.count))
    return try FrsPageReqIdl(serializedBytes: payload).data.common.bduss
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
      XCTFail("Unexpected error type: \(error)")
    }
  }
}

private actor CheckInStubTransport: TiebaTransport {
  enum Step: Sendable {
    case response(Data)
    case failure(TiebaClientError)
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let steps: [Step]
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(steps: [Step]) {
    self.steps = steps
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let index = requests.count
    guard steps.indices.contains(index) else {
      throw TiebaClientError.transportFailure
    }
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)

    switch steps[index] {
    case .response(let body):
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .failure(let error):
      throw error
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}

private actor GatedCheckInTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Data]
  private let blockedRequestIndex: Int
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

  init(responses: [Data], blockedRequestIndex: Int) {
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
    let index = requests.count
    guard responses.indices.contains(index) else {
      throw TiebaClientError.transportFailure
    }
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)

    if index == blockedRequestIndex && !isBlockedRequestReleased {
      await withCheckedContinuation { continuation in
        if isBlockedRequestReleased {
          continuation.resume()
        } else {
          blockedContinuation = continuation
        }
      }
    }
    return TiebaHTTPResponse(body: responses[index], statusCode: 200)
  }

  func waitUntilRequestCount(
    _ count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while requests.count < count, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return requests.count >= count
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }

  func requestCount() -> Int {
    requests.count
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}
