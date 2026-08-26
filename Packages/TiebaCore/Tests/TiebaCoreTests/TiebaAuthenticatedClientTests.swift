import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaAuthenticatedClientTests: XCTestCase {
  func testValidatesAccountAndMapsIdentityWithoutReturningCredentials() async throws {
    let body = Data(
      """
      {
        "error_code": "0",
        "anti": {"tbs": "91be894d01799c4991be894d01"},
        "user": {
          "id": "957339815",
          "name": "account-name",
          "portrait": "portrait-token"
        }
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let account = try await client.validateAccount(credential: credential())

    XCTAssertEqual(account.userID, 957_339_815)
    XCTAssertEqual(account.username, "account-name")
    XCTAssertEqual(account.portrait, "portrait-token")
    XCTAssertEqual(Array(account.customMirror.children).count, 2)
  }

  func testSelfProfileMapsBoundedAuthenticatedSummary() async throws {
    var response = ProtoFixtures.userProfile()
    response.data.user.isLogin = 0
    response.data.user.name = " profile-user "
    response.data.user.nameShow = " Profile User "
    response.data.user.displayIntro = " Line one\r\nLine two "
    let client = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: try response.serializedData())
    )

    let summary = try await client.getSelfProfile(
      credential: sessionCredential(),
      expectedUserID: 957_339_815
    )

    XCTAssertEqual(summary.userID, 957_339_815)
    XCTAssertEqual(summary.username, "profile-user")
    XCTAssertEqual(summary.displayName, "Profile User")
    XCTAssertEqual(summary.preferredName, "Profile User")
    XCTAssertEqual(summary.portrait, "profile-portrait")
    XCTAssertEqual(summary.biography, "Line one\nLine two")
    XCTAssertEqual(summary.editableBiography, "Legacy introduction")
    XCTAssertEqual(summary.sex, .female)
    XCTAssertEqual(
      summary.birthday,
      TiebaSelfProfileBirthday(
        timeMilliseconds: 946_684_800_000,
        showsConstellationOnly: true
      )
    )
    XCTAssertFalse(summary.isNicknameEditing)
    XCTAssertNil(summary.editingNickname)
    XCTAssertEqual(summary.followingCount, 67)
    XCTAssertEqual(summary.followerCount, 345)
    XCTAssertEqual(summary.postCount, 890)
  }

  func testSelfProfileModelsRedactPrivateTextAndBirthdayFromDiagnostics() {
    let privateBirthday = TiebaSelfProfileBirthday(
      timeMilliseconds: 631_123_200_000,
      showsConstellationOnly: true
    )
    let summary = TiebaSelfProfileSummary(
      userID: 957_339_815,
      username: "private-username-sentinel",
      displayName: "private-display-name-sentinel",
      portrait: "private-portrait-sentinel",
      biography: "private-public-biography-sentinel",
      followingCount: 1,
      followerCount: 2,
      postCount: 3,
      sex: .female,
      birthday: privateBirthday,
      isNicknameEditing: true,
      editingNickname: "private-pending-nickname-sentinel",
      editableBiography: "private-editable-biography-sentinel"
    )

    let diagnosticValues = [String(describing: summary), String(reflecting: summary)]
    for value in diagnosticValues {
      XCTAssertFalse(value.contains("private-"))
      XCTAssertFalse(value.contains("631123200000"))
    }
    let reflectedValues = summary.customMirror.children.map { String(reflecting: $0.value) }
    let reflectedLabels = summary.customMirror.children.compactMap(\.label)
    XCTAssertFalse(reflectedValues.contains { $0.contains("private-") })
    XCTAssertFalse(reflectedValues.contains { $0.contains("631123200000") })
    XCTAssertFalse(reflectedLabels.contains("sex"))
    XCTAssertEqual(String(describing: privateBirthday), "TiebaSelfProfileBirthday(redacted)")
    XCTAssertTrue(Array(privateBirthday.customMirror.children).isEmpty)
  }

  func testSelfProfileRejectsMismatchedMalformedAndOversizedPayloads() async throws {
    var mismatched = ProtoFixtures.userProfile()
    mismatched.data.user.id = 123
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(
        transport: AuthStubTransport(body: try mismatched.serializedData())
      ).getSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var invalidCount = ProtoFixtures.userProfile()
    invalidCount.data.user.fansNum = -1
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(
        transport: AuthStubTransport(body: try invalidCount.serializedData())
      ).getSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var oversizedBiography = ProtoFixtures.userProfile()
    oversizedBiography.data.user.displayIntro = String(
      repeating: "a",
      count: TiebaAuthenticatedDecoder.selfProfileBiographyMaximumBytes + 1
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(
        transport: AuthStubTransport(body: try oversizedBiography.serializedData())
      ).getSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var controlName = ProtoFixtures.userProfile()
    controlName.data.user.nameShow = "unsafe\nname"
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(
        transport: AuthStubTransport(body: try controlName.serializedData())
      ).getSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }
  }

  func testSelfProfileRejectsServerEnvelopeMissingIdentityAndUnsafeText() async throws {
    var serverError = ProtoFixtures.userProfile()
    serverError.error.errorno = 123
    serverError.error.errmsg = "private response"
    await assertError(.server(code: 123, message: "private response")) {
      _ = try await self.profileClient(serverError).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var missingData = ProfileResIdl()
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(missingData).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    missingData.data = ProfileResIdl.DataRes()
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(missingData).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var emptyNames = ProtoFixtures.userProfile()
    emptyNames.data.user.name = "   "
    emptyNames.data.user.nameShow = ""
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(emptyNames).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var oversizedName = ProtoFixtures.userProfile()
    oversizedName.data.user.nameShow = String(
      repeating: "n",
      count: TiebaAuthenticatedDecoder.selfProfileNameMaximumBytes + 1
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(oversizedName).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var oversizedPortrait = ProtoFixtures.userProfile()
    oversizedPortrait.data.user.portrait = String(
      repeating: "p",
      count: TiebaAuthenticatedDecoder.selfProfilePortraitMaximumBytes + 1
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(oversizedPortrait).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    var unsafeBiography = ProtoFixtures.userProfile()
    unsafeBiography.data.user.displayIntro = "unsafe\tbiography"
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.profileClient(unsafeBiography).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    for portrait in ["profile-portrait?evil=1", "profile-portrait?t=", "profile-portrait#fragment"] {
      var unsafePortrait = ProtoFixtures.userProfile()
      unsafePortrait.data.user.portrait = portrait
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await self.profileClient(unsafePortrait).getSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: 957_339_815
        )
      }
    }
  }

  func testSelfProfileFallsBackToLegacyBiography() async throws {
    var response = ProtoFixtures.userProfile()
    response.data.user.displayIntro = " \n "
    response.data.user.intro = " Legacy biography\rline two "

    let summary = try await profileClient(response).getSelfProfile(
      credential: sessionCredential(),
      expectedUserID: 957_339_815
    )

    XCTAssertEqual(summary.biography, "Legacy biography\nline two")
  }

  func testUserRelationshipMapsFollowedAndMutualStatesAndKeepsContextPrivate() async throws {
    let targetID: Int64 = 123_456_789
    for rawState in [Int32(1), 2] {
      let response = ProtoFixtures.userRelationship(
        targetUserID: targetID,
        isFollowed: rawState
      )
      let relationship = try await profileClient(response).getUserRelationship(
        credential: sessionCredential(),
        expectedUserID: 957_339_815,
        targetUserID: targetID
      )
      XCTAssertEqual(
        relationship,
        TiebaUserRelationship(
          userID: 957_339_815,
          targetUserID: targetID,
          isFollowed: true
        )
      )
      XCTAssertFalse(String(reflecting: relationship).contains("91be894d01799c4991be894d01"))
    }

    let notFollowed = ProtoFixtures.userRelationship(targetUserID: targetID, isFollowed: 0)
    let relationship = try await profileClient(notFollowed).getUserRelationship(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID
    )
    XCTAssertFalse(relationship.isFollowed)
  }

  func testUserRelationshipRejectsMismatchedTargetInvalidStatesPortraitAndTBS() async throws {
    let targetID: Int64 = 123_456_789
    var responses = [ProfileResIdl]()
    responses.append(ProtoFixtures.userRelationship(targetUserID: targetID + 1))
    responses.append(ProtoFixtures.userRelationship(targetUserID: targetID, isFollowed: -1))
    responses.append(ProtoFixtures.userRelationship(targetUserID: targetID, isFollowed: 3))
    responses.append(ProtoFixtures.userRelationship(targetUserID: targetID, tbs: "short"))
    var emptyPortrait = ProtoFixtures.userRelationship(targetUserID: targetID)
    emptyPortrait.data.user.portrait = ""
    responses.append(emptyPortrait)

    for response in responses {
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await self.profileClient(response).getUserRelationship(
          credential: self.sessionCredential(),
          expectedUserID: 957_339_815,
          targetUserID: targetID
        )
      }
    }
  }

  func testUserFollowSkipsWriteWhenRelationshipAlreadyMatches() async throws {
    let targetID: Int64 = 123_456_789
    let current = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 2
    ).serializedData()
    let transport = UserFollowStubTransport(responses: [.init(body: current)])
    let result = try await TiebaAuthenticatedClient(transport: transport).setUserFollowState(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID,
      isFollowed: true
    )

    XCTAssertTrue(result.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(snapshot.requests.first?.url?.path, "/c/u/user/profile")
  }

  func testUserFollowTreatsACKOnlyAsAcknowledgementAndRequiresMatchingReadback() async throws {
    let targetID: Int64 = 123_456_789
    let initial = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let readback = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: initial),
        .init(body: Data(#"{"error_code":0,"status":"success"}"#.utf8)),
        .init(body: readback),
      ]
    )
    let result = try await TiebaAuthenticatedClient(transport: transport).setUserFollowState(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID,
      isFollowed: true
    )

    XCTAssertTrue(result.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, [
      "/c/u/user/profile", "/c/c/user/follow", "/c/u/user/profile",
    ])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.userRelationshipResponseMaximumBytes,
      TiebaAuthenticatedClient.userFollowWriteResponseMaximumBytes,
      TiebaAuthenticatedClient.userRelationshipResponseMaximumBytes,
    ])
  }

  func testUserFollowReturnsAuthoritativeUnchangedReadbackWithoutSecondWrite() async throws {
    let targetID: Int64 = 123_456_789
    let unchanged = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: unchanged),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: unchanged),
      ]
    )
    let result = try await TiebaAuthenticatedClient(transport: transport).setUserFollowState(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID,
      isFollowed: true
    )
    XCTAssertFalse(result.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count, 1)
  }

  func testUserFollowTransportFailurePerformsOneReadbackAndNeverRetriesWrite() async throws {
    let targetID: Int64 = 123_456_789
    let initial = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let reconciled = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: initial),
        .init(error: .transportFailure),
        .init(body: reconciled),
      ]
    )
    let result = try await TiebaAuthenticatedClient(transport: transport).setUserFollowState(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID,
      isFollowed: true
    )
    XCTAssertTrue(result.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count, 1)
    XCTAssertEqual(snapshot.requests.count, 3)
  }

  func testUserFollowServerErrorStillReturnsAuthoritativeReadbackWithoutRetry() async throws {
    let targetID: Int64 = 123_456_789
    let unchanged = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: unchanged),
        .init(body: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
        .init(body: unchanged),
      ]
    )

    let result = try await TiebaAuthenticatedClient(transport: transport).setUserFollowState(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      targetUserID: targetID,
      isFollowed: true
    )

    XCTAssertFalse(result.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 3)
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count, 1)
  }

  func testConcurrentEquivalentUserFollowsShareFlightAndCancellationKeepsWriteAlive() async throws {
    let targetID: Int64 = 123_456_789
    let initial = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let readback = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: initial),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: readback),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = sessionCredential()
    let expectedUserID: Int64 = 957_339_815

    let first = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first follow write")
      return
    }
    let joined = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await waitUntilUserFollowWaiterCount(
      client: client,
      expectedUserID: expectedUserID,
      targetUserID: targetID,
      count: 2
    ) else {
      joined.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await joined.result
      XCTFail("Timed out waiting for the equivalent follow caller to join")
      return
    }

    joined.cancel()
    do {
      _ = try await joined.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
    let waiterCountAfterCancellation = await client.userFollowWaiterCount(
      expectedUserID: expectedUserID,
      targetUserID: targetID
    )
    XCTAssertEqual(waiterCountAfterCancellation, 1)
    let requestCountAfterCancellation = await transport.requestCount()
    XCTAssertEqual(requestCountAfterCancellation, 2)

    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    XCTAssertTrue(firstResult.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      ["/c/u/user/profile", "/c/c/user/follow", "/c/u/user/profile"]
    )
    XCTAssertEqual(
      snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count,
      1
    )
    let finalWaiterCount = await client.userFollowWaiterCount(
      expectedUserID: expectedUserID,
      targetUserID: targetID
    )
    XCTAssertEqual(finalWaiterCount, 0)
  }

  func testConflictingUserUnfollowWaitsThenOnlyReadsFinalState() async throws {
    let targetID: Int64 = 123_456_789
    let initial = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let followed = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: initial),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: followed),
        .init(body: followed),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = sessionCredential()
    let expectedUserID: Int64 = 957_339_815

    let first = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first follow write")
      return
    }
    let conflicting = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: false
      )
    }
    guard await waitUntilUserFollowWaiterCount(
      client: client,
      expectedUserID: expectedUserID,
      targetUserID: targetID,
      count: 2
    ) else {
      conflicting.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await conflicting.result
      XCTFail("Timed out waiting for the conflicting follow caller")
      return
    }
    let requestCountBeforeConflictRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeConflictRelease, 2)

    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    let conflictingResult = try await conflicting.value
    XCTAssertTrue(firstResult.isFollowed)
    XCTAssertTrue(conflictingResult.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.requests.map(\.url?.path),
      [
        "/c/u/user/profile", "/c/c/user/follow", "/c/u/user/profile",
        "/c/u/user/profile",
      ]
    )
    XCTAssertEqual(
      snapshot.requests.filter {
        $0.url?.path == "/c/c/user/follow" || $0.url?.path == "/c/c/user/unfollow"
      }.count,
      1
    )
  }

  func testRotatedCredentialWaitsThenOnlyReadsWithoutSecondWrite() async throws {
    let targetID: Int64 = 123_456_789
    let initial = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 0
    ).serializedData()
    let followed = try ProtoFixtures.userRelationship(
      targetUserID: targetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: initial),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: followed),
        .init(body: followed),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let oldCredential = sessionCredential(stokenCharacter: "s")
    let rotatedCredential = sessionCredential(stokenCharacter: "t")
    let expectedUserID: Int64 = 957_339_815

    let first = Task {
      try await client.setUserFollowState(
        credential: oldCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the old-credential follow write")
      return
    }
    let rotated = Task {
      try await client.setUserFollowState(
        credential: rotatedCredential,
        expectedUserID: expectedUserID,
        targetUserID: targetID,
        isFollowed: true
      )
    }
    guard await waitUntilUserFollowWaiterCount(
      client: client,
      expectedUserID: expectedUserID,
      targetUserID: targetID,
      count: 2
    ) else {
      rotated.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await rotated.result
      XCTFail("Timed out waiting for the rotated credential caller")
      return
    }
    let requestCountBeforeRotationRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeRotationRelease, 2)

    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    let rotatedResult = try await rotated.value
    XCTAssertTrue(firstResult.isFollowed)
    XCTAssertTrue(rotatedResult.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 4)
    XCTAssertEqual(
      snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count,
      1
    )
  }

  func testDifferentUserFollowTargetsCanProgressInParallel() async throws {
    let firstTargetID: Int64 = 123_456_789
    let secondTargetID: Int64 = 987_654_321
    let firstInitial = try ProtoFixtures.userRelationship(
      targetUserID: firstTargetID,
      isFollowed: 0
    ).serializedData()
    let firstFollowed = try ProtoFixtures.userRelationship(
      targetUserID: firstTargetID,
      isFollowed: 1
    ).serializedData()
    let secondInitial = try ProtoFixtures.userRelationship(
      targetUserID: secondTargetID,
      isFollowed: 0
    ).serializedData()
    let secondFollowed = try ProtoFixtures.userRelationship(
      targetUserID: secondTargetID,
      isFollowed: 1
    ).serializedData()
    let transport = UserFollowStubTransport(
      responses: [
        .init(body: firstInitial),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: secondInitial),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: secondFollowed),
        .init(body: firstFollowed),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let requestCredential = sessionCredential()
    let expectedUserID: Int64 = 957_339_815

    let first = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: firstTargetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      XCTFail("Timed out waiting for the first target write")
      return
    }
    let second = Task {
      try await client.setUserFollowState(
        credential: requestCredential,
        expectedUserID: expectedUserID,
        targetUserID: secondTargetID,
        isFollowed: true
      )
    }
    guard await transport.waitUntilRequestCount(5) else {
      second.cancel()
      await transport.releaseBlockedRequest()
      _ = await first.result
      _ = await second.result
      XCTFail("Second target did not complete while the first target was blocked")
      return
    }

    let secondResult = try await second.value
    XCTAssertTrue(secondResult.isFollowed)
    let requestCountBeforeFirstRelease = await transport.requestCount()
    XCTAssertEqual(requestCountBeforeFirstRelease, 5)
    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    XCTAssertTrue(firstResult.isFollowed)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 6)
    XCTAssertEqual(
      snapshot.requests.filter { $0.url?.path == "/c/c/user/follow" }.count,
      2
    )
  }

  func testMapsBothFollowedForumGroupsAndDeduplicatesIDs() async throws {
    let body = Data(
      """
      {
        "error_code": 0,
        "has_more": "1",
        "forum_list": {
          "non-gconforum": [
            {"id": "42", "name": "swift", "level_id": "12", "cur_score": "345"}
          ],
          "gconforum": [
            {"id": 42, "name": "duplicate", "level_id": 1, "cur_score": 2},
            {"id": 43, "name": "ios", "level_id": 8, "cur_score": 123}
          ]
        }
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getFollowedForums(
      credential: credential(),
      userID: 957_339_815,
      page: 2,
      pageSize: 50
    )

    XCTAssertEqual(page.forums.map(\.id), [42, 43])
    XCTAssertEqual(page.forums.map(\.name), ["swift", "ios"])
    XCTAssertEqual(page.forums[0].level, 12)
    XCTAssertEqual(page.forums[0].experience, 345)
    XCTAssertEqual(page.forums[0].avatar, "")
    XCTAssertEqual(page.forums[0].slogan, "")
    XCTAssertEqual(page.accountUserID, 957_339_815)
    XCTAssertEqual(page.targetUserID, 957_339_815)
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertTrue(page.pagination.hasMore)
    XCTAssertTrue(page.pagination.hasPrevious)
  }

  func testMapsAuthenticatedOwnFollowingAndCarriesExpectedAccountContext() async throws {
    let body = Data(
      """
      {
        "error_code": 0,
        "pn": 2,
        "has_more": 0,
        "total_follow_num": 1,
        "follow_list": [
          {
            "id": 42,
            "name": "mutual-user",
            "name_show": "Mutual User",
            "has_concerned": 2
          }
        ]
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getOwnFollowing(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      page: 2
    )

    XCTAssertEqual(page.requestedUserID, 957_339_815)
    XCTAssertEqual(page.kind, .following)
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertEqual(page.pagination.totalCount, 1)
    XCTAssertFalse(page.pagination.hasMore)
    XCTAssertEqual(page.users.map(\.id), [42])
    XCTAssertEqual(page.users.first?.concernState, .mutual)
  }

  func testAuthenticatedOwnFollowingRejectsMismatchedPageContext() async {
    let body = Data(
      """
      {
        "error_code": 0,
        "pn": 1,
        "has_more": 0,
        "total_follow_num": 0,
        "follow_list": []
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    await assertError(.invalidJSON) {
      _ = try await client.getOwnFollowing(
        credential: sessionCredential(),
        expectedUserID: 957_339_815,
        page: 2
      )
    }
  }

  func testAuthenticatedOwnFollowingPreservesServerAndMalformedResponseErrors() async {
    let serverClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data("{\"error_code\":4,\"error_msg\":\"login required\"}".utf8)
      )
    )
    await assertError(.server(code: 4, message: "login required")) {
      _ = try await serverClient.getOwnFollowing(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    let malformedClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: Data("not-json".utf8))
    )
    await assertError(.invalidJSON) {
      _ = try await malformedClient.getOwnFollowing(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }
  }

  func testDoesNotMixFrequentlyVisitedForumsIntoFollowedForums() async throws {
    let body = Data(
      """
      {
        "error_code": "0",
        "has_more": "0",
        "forum_list": {
          "non-gconforum": [{"id": "42", "name": "followed", "level_id": "1"}]
        },
        "common_forum_list": {
          "non-gconforum": [{"id": "99", "name": "visited", "level_id": "0"}]
        }
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getFollowedForums(
      credential: credential(),
      userID: 957_339_815
    )

    XCTAssertEqual(page.forums.map(\.id), [42])
    XCTAssertEqual(page.accountUserID, 957_339_815)
    XCTAssertEqual(page.targetUserID, 957_339_815)
  }

  func testMapsOtherUsersLikedForumsAndCarriesBothRequestIdentities() async throws {
    let body = Data(
      """
      {
        "error_code": 0,
        "has_more": "0",
        "forum_list": {
          "non-gconforum": [
            {
              "id": "42",
              "name": " swift ",
              "level_id": "12",
              "cur_score": "345",
              "avatar": " https://example.baidu.com/forum.png ",
              "slogan": " Swift community "
            }
          ]
        }
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getLikedForums(
      credential: credential(),
      accountUserID: 957_339_815,
      targetUserID: 123_456_789,
      page: 3,
      pageSize: 50
    )

    XCTAssertEqual(page.accountUserID, 957_339_815)
    XCTAssertEqual(page.targetUserID, 123_456_789)
    XCTAssertEqual(page.pagination.currentPage, 3)
    XCTAssertFalse(page.pagination.hasMore)
    XCTAssertEqual(page.forums.map(\.id), [42])
    XCTAssertEqual(page.forums.map(\.name), ["swift"])
    XCTAssertEqual(page.forums.first?.avatar, "https://example.baidu.com/forum.png")
    XCTAssertEqual(page.forums.first?.slogan, "Swift community")
  }

  func testLikedForumsDropsUnsafeOptionalMetadataWithoutDroppingForum() async throws {
    let oversizedAvatar = String(
      repeating: "a",
      count: TiebaAuthenticatedDecoder.followedForumAvatarMaximumBytes + 1
    )
    let body = try JSONSerialization.data(
      withJSONObject: [
        "error_code": 0,
        "has_more": "0",
        "forum_list": [
          "non-gconforum": [
            [
              "id": "42",
              "name": "swift",
              "avatar": oversizedAvatar,
              "slogan": "unsafe\u{0007}slogan",
            ]
          ]
        ],
      ]
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getLikedForums(
      credential: credential(),
      accountUserID: 1,
      targetUserID: 2
    )

    XCTAssertEqual(page.forums.count, 1)
    XCTAssertEqual(page.forums.first?.avatar, "")
    XCTAssertEqual(page.forums.first?.slogan, "")
  }

  func testLikedForumsTreatsMissingPaginationFlagAsFinalPage() async throws {
    let body = Data("{\"error_code\":0,\"forum_list\":{}}".utf8)
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getLikedForums(
      credential: credential(),
      accountUserID: 1,
      targetUserID: 2
    )

    XCTAssertFalse(page.pagination.hasMore)
    XCTAssertTrue(page.forums.isEmpty)
  }

  func testLikedForumsRejectsNonbinaryPaginationFlag() async {
    let body = Data(
      "{\"error_code\":0,\"has_more\":\"2\",\"forum_list\":{}}".utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))
    await assertError(.invalidJSON) {
      _ = try await client.getLikedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2
      )
    }
  }

  func testLikedForumsAllowsOnePageSizePerKnownForumGroup() async throws {
    let body = Data(
      """
      {
        "error_code": 0,
        "has_more": "0",
        "forum_list": {
          "non-gconforum": [{"id": "1", "name": "one"}],
          "gconforum": [{"id": "2", "name": "two"}]
        }
      }
      """.utf8
    )
    let client = TiebaAuthenticatedClient(transport: AuthStubTransport(body: body))

    let page = try await client.getLikedForums(
      credential: credential(),
      accountUserID: 1,
      targetUserID: 2,
      pageSize: 1
    )

    XCTAssertEqual(page.forums.map(\.id), [1, 2])
  }

  func testLikedForumsRejectsMalformedOrOversizedPageRows() async throws {
    let malformedBody = Data(
      "{\"error_code\":0,\"has_more\":\"0\",\"forum_list\":{\"non-gconforum\":{}}}".utf8
    )
    let malformedClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: malformedBody)
    )
    await assertError(.invalidJSON) {
      _ = try await malformedClient.getLikedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2
      )
    }

    let invalidRowBody = Data(
      """
      {
        "error_code": 0,
        "has_more": "0",
        "forum_list": {"non-gconforum": [{"id": "1", "name": "   "}]}
      }
      """.utf8
    )
    let invalidRowClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: invalidRowBody)
    )
    await assertError(.invalidJSON) {
      _ = try await invalidRowClient.getLikedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2
      )
    }

    let oversizedBody = try JSONSerialization.data(
      withJSONObject: [
        "error_code": 0,
        "has_more": "0",
        "forum_list": [
          "non-gconforum": [
            ["id": "1", "name": "one"],
            ["id": "2", "name": "two"],
            ["id": "3", "name": "three"],
          ],
        ],
      ]
    )
    let oversizedClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: oversizedBody)
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await oversizedClient.getLikedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2,
        pageSize: 1
      )
    }
  }

  func testMapsAuthenticatedServerAndInvalidJSONErrors() async throws {
    let serverClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data("{\"error_code\":1,\"error_msg\":\"not logged in\"}".utf8)
      )
    )
    await assertError(.server(code: 1, message: "not logged in")) {
      _ = try await serverClient.validateAccount(credential: credential())
    }

    let malformedClient = TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: Data("not-json".utf8))
    )
    await assertError(.invalidJSON) {
      _ = try await malformedClient.validateAccount(credential: credential())
    }
  }

  func testAuthenticatedResponsesAreBoundedBeforeDecoding() async {
    let oversizedAccount = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.accountResponseMaximumBytes + 1
        )
      )
    )
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.accountResponseMaximumBytes)
    ) {
      _ = try await oversizedAccount.validateAccount(credential: credential())
    }

    let oversizedForums = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.followedForumsResponseMaximumBytes + 1
        )
      )
    )
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.followedForumsResponseMaximumBytes)
    ) {
      _ = try await oversizedForums.getLikedForums(
        credential: credential(),
        accountUserID: 957_339_815,
        targetUserID: 123_456_789
      )
    }

    let oversizedProfile = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.selfProfileResponseMaximumBytes + 1
        )
      )
    )
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.selfProfileResponseMaximumBytes)
    ) {
      _ = try await oversizedProfile.getSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }

    let oversizedFollowing = TiebaAuthenticatedClient(
      transport: AuthStubTransport(
        body: Data(
          repeating: 0,
          count: TiebaAuthenticatedClient.ownFollowingResponseMaximumBytes + 1
        )
      )
    )
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.ownFollowingResponseMaximumBytes)
    ) {
      _ = try await oversizedFollowing.getOwnFollowing(
        credential: sessionCredential(),
        expectedUserID: 957_339_815
      )
    }
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
  }

  private func sessionCredential(
    bdussCharacter: String = "b",
    stokenCharacter: String = "s"
  ) -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: bdussCharacter, count: 192),
      stoken: String(repeating: stokenCharacter, count: 64),
      bdussCookieName: .bduss
    )
  }

  private func waitUntilUserFollowWaiterCount(
    client: TiebaAuthenticatedClient,
    expectedUserID: Int64,
    targetUserID: Int64,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let actual = await client.userFollowWaiterCount(
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
      if actual == count { return true }
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return false
      }
    }
    return false
  }

  private func profileClient(_ response: ProfileResIdl) throws -> TiebaAuthenticatedClient {
    TiebaAuthenticatedClient(
      transport: AuthStubTransport(body: try response.serializedData())
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
      XCTFail("Unexpected error type")
    }
  }
}

private actor AuthStubTransport: TiebaTransport {
  let body: Data
  let statusCode: Int

  init(body: Data, statusCode: Int = 200) {
    self.body = body
    self.statusCode = statusCode
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    TiebaHTTPResponse(body: body, statusCode: statusCode)
  }
}

private actor UserFollowStubTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int
    let error: TiebaClientError?

    init(
      body: Data = Data(),
      statusCode: Int = 200,
      error: TiebaClientError? = nil
    ) {
      self.body = body
      self.statusCode = statusCode
      self.error = error
    }
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Response]
  private let blockedRequestIndex: Int?
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

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
    let index = requests.count
    guard responses.indices.contains(index) else {
      throw TiebaClientError.transportFailure
    }
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    let response = responses[index]
    if index == blockedRequestIndex, !isBlockedRequestReleased {
      await withCheckedContinuation { continuation in
        if isBlockedRequestReleased {
          continuation.resume()
        } else {
          blockedContinuation = continuation
        }
      }
    }
    if let error = response.error { throw error }
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
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
