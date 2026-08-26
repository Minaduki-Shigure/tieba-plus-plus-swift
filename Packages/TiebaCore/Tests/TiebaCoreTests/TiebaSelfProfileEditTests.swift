import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaSelfProfileEditTests: XCTestCase, @unchecked Sendable {
  private let accountID: Int64 = 957_339_815
  private let birthday = TiebaSelfProfileBirthday(
    timeMilliseconds: 946_684_800_000,
    showsConstellationOnly: true
  )
  private let authenticatedProfileReadPaths = [
    "/c/s/login", "/mo/q/newmoindex", "/c/u/user/profile",
  ]
  private let authenticatedProfileMutationPaths = [
    "/c/s/login", "/mo/q/newmoindex", "/c/u/user/profile",
    "/c/c/profile/modify", "/c/u/user/profile",
  ]

  func testWriteRequestUsesExactMinimalSignedTiebaLiteContract() throws {
    let credential = sessionCredential()
    let edit = targetEdit()
    let request = try TiebaAuthenticatedRequestFactory(configuration: .init())
      .editSelfProfile(
        credential: credential,
        expectedUserID: accountID,
        edit: edit,
        birthday: birthday
      )
    let fields = try formFields(request)
    let unsigned = [
      ("BDUSS", credential.bduss),
      ("_client_type", "2"),
      ("_client_version", "12.41.7.1"),
      ("birthday_show_status", "1"),
      ("birthday_time", "946684800"),
      ("intro", edit.biography),
      ("sex", "1"),
      ("nick_name", edit.displayName),
      ("stoken", credential.stoken),
      ("cam", ""),
      ("need_cam_decrypt", "1"),
      ("need_keep_nickname_flag", "0"),
    ]

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/profile/modify")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1"
    )
    XCTAssertEqual(Set(fields.keys), Set(unsigned.map(\.0)).union(["sign"]))
    XCTAssertEqual(fields["sign"], TiebaFormSigner.signature(for: unsigned))
    XCTAssertNil(fields["uid"])
    XCTAssertNil(fields["cuid"])
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testEditPolicyAndFactoryRejectUnsafeOrUnboundInputs() throws {
    let redactedEdit = TiebaSelfProfileEdit(
      displayName: "private nickname",
      biography: "private biography",
      sex: .female
    )
    XCTAssertFalse(String(describing: redactedEdit).contains("private"))
    XCTAssertFalse(String(reflecting: redactedEdit).contains("private"))
    XCTAssertFalse(redactedEdit.customMirror.children.compactMap(\.label).contains("sex"))
    XCTAssertTrue(
      TiebaSelfProfileEditPolicy.isValidBiography(
        String(repeating: "字 ", count: 500)
      )
    )
    XCTAssertFalse(
      TiebaSelfProfileEditPolicy.isValidBiography(
        String(repeating: "字", count: 501)
      )
    )
    XCTAssertFalse(
      TiebaSelfProfileEditPolicy.isValidBiography(
        "x" + String(repeating: "\u{0301}", count: 5_000)
      )
    )
    for name in ["", "  \n ", "unsafe\nname", "unsafe\u{2028}name"] {
      XCTAssertFalse(TiebaSelfProfileEditPolicy.isValidDisplayName(name))
    }
    XCTAssertFalse(
      TiebaSelfProfileEditPolicy.isValidDisplayName(String(repeating: "n", count: 65))
    )
    XCTAssertFalse(
      TiebaSelfProfileEditPolicy.isValidDisplayName(String(repeating: "🇨🇳", count: 64))
    )

    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    XCTAssertThrowsError(
      try factory.editSelfProfile(
        credential: sessionCredential(),
        expectedUserID: 0,
        edit: targetEdit(),
        birthday: birthday
      )
    )
    XCTAssertThrowsError(
      try factory.editSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: TiebaSelfProfileEdit(displayName: "\n", biography: "", sex: .female),
        birthday: birthday
      )
    )
    XCTAssertThrowsError(
      try factory.editSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: targetEdit(),
        birthday: TiebaSelfProfileBirthday(
          timeMilliseconds: 946_684_800_001,
          showsConstellationOnly: false
        )
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testDecoderMapsBirthdaySexEditableBiographyAndNicknameReviewState() async throws {
    var response = profile(
      displayName: "Public Name",
      editableBiography: "Editable introduction",
      sex: .female,
      birthday: birthday
    )
    response.data.user.displayIntro = "Moderated public introduction"
    response.data.user.isNicknameEditing = 1
    response.data.user.editingNickname = "Pending Name"

    let summary = try await staticClient(response).getSelfProfile(
      credential: sessionCredential(),
      expectedUserID: accountID
    )

    XCTAssertEqual(summary.biography, "Moderated public introduction")
    XCTAssertEqual(summary.editableBiography, "Editable introduction")
    XCTAssertEqual(summary.sex, .female)
    XCTAssertEqual(summary.birthday, birthday)
    XCTAssertTrue(summary.isNicknameEditing)
    XCTAssertEqual(summary.editingNickname, "Pending Name")
  }

  func testDecoderAllowsReviewFlagWithoutPendingNicknameButRejectsInvalidSnapshots() async throws {
    var missingPending = profile()
    missingPending.data.user.isNicknameEditing = 1
    missingPending.data.user.editingNickname = ""
    let readable = try await staticClient(missingPending).getSelfProfile(
      credential: sessionCredential(),
      expectedUserID: accountID
    )
    XCTAssertTrue(readable.isNicknameEditing)
    XCTAssertNil(readable.editingNickname)
    let pendingTransport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try missingPending.serializedData())
    ])
    await assertError(
      .invalidArgument("The profile nickname is already being reviewed.")
    ) {
      _ = try await TiebaAuthenticatedClient(transport: pendingTransport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: TiebaSelfProfileEdit(
            displayName: missingPending.data.user.nameShow,
            biography: missingPending.data.user.intro,
            sex: .female
          )
        )
    }
    let pendingPaths = await pendingTransport.paths()
    XCTAssertEqual(pendingPaths, authenticatedProfileReadPaths)

    var invalidBirthday = profile()
    invalidBirthday.data.user.birthdayInfo.birthdayShowStatus = 2
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.staticClient(invalidBirthday).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID
      )
    }

    var invalidSex = profile()
    invalidSex.data.user.sex = 3
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.staticClient(invalidSex).getSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID
      )
    }
  }

  func testNoChangeSkipsWriteAndMissingBirthdayFailsClosedOnlyWhenChangeNeeded() async throws {
    let edit = targetEdit()
    var unchangedWithoutBirthday = profile(
      displayName: edit.displayName,
      editableBiography: edit.biography,
      sex: edit.sex,
      birthday: birthday
    )
    unchangedWithoutBirthday.data.user.clearBirthdayInfo()
    let noChangeTransport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try unchangedWithoutBirthday.serializedData())
    ])
    let noChange = try await TiebaAuthenticatedClient(transport: noChangeTransport)
      .updateSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: edit
      )
    XCTAssertNil(noChange.birthday)
    let noChangePaths = await noChangeTransport.paths()
    XCTAssertEqual(noChangePaths, authenticatedProfileReadPaths)

    var changedWithoutBirthday = profile()
    changedWithoutBirthday.data.user.clearBirthdayInfo()
    let changedTransport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try changedWithoutBirthday.serializedData())
    ])
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(transport: changedTransport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: edit
        )
    }
    let changedPaths = await changedTransport.paths()
    XCTAssertEqual(changedPaths, authenticatedProfileReadPaths)
  }

  func testCredentialOwnerMismatchStopsBeforeProfileReadOrWrite() async {
    let transport = ProfileEditTransport(
      authenticatedUserID: accountID + 1,
      responses: []
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(transport: transport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: self.targetEdit()
        )
    }

    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/c/s/login", "/mo/q/newmoindex"])
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testNicknameReviewStatePreventsMutation() async throws {
    var pending = profile()
    pending.data.user.isNicknameEditing = 1
    pending.data.user.editingNickname = "Another pending nickname"
    let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try pending.serializedData())
    ])
    await assertError(
      .invalidArgument("The profile nickname is already being reviewed.")
    ) {
      _ = try await TiebaAuthenticatedClient(transport: transport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: self.targetEdit()
        )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths, authenticatedProfileReadPaths)
  }

  func testACKIsNotAuthoritativeAndPendingNicknameReadbackConfirmsEdit() async throws {
    let edit = targetEdit()
    var reconciled = profile(
      displayName: "Old Name",
      editableBiography: edit.biography,
      sex: edit.sex,
      birthday: birthday
    )
    reconciled.data.user.isNicknameEditing = 1
    reconciled.data.user.editingNickname = edit.displayName
    let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile().serializedData()),
      .init(body: Data(#"{"error_code":0}"#.utf8)),
      .init(body: try reconciled.serializedData()),
    ])

    let result = try await TiebaAuthenticatedClient(transport: transport)
      .updateSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: edit
      )

    XCTAssertTrue(result.isNicknameEditing)
    XCTAssertEqual(result.editingNickname, edit.displayName)
    let paths = await transport.paths()
    XCTAssertEqual(paths, authenticatedProfileMutationPaths)
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
    let limits = await transport.maximumBodyBytes()
    XCTAssertEqual(limits, [
      TiebaAuthenticatedClient.accountResponseMaximumBytes,
      TiebaAuthenticatedClient.webSessionResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileEditResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileResponseMaximumBytes,
    ])
  }

  func testLostWriteResponseStillUsesOneReadbackAndNeverRetries() async throws {
    let edit = targetEdit()
    let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile().serializedData()),
      .init(error: .transportFailure),
      .init(body: try profile(
        displayName: edit.displayName,
        editableBiography: edit.biography,
        sex: edit.sex,
        birthday: birthday
      ).serializedData()),
    ])
    let result = try await TiebaAuthenticatedClient(transport: transport)
      .updateSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: edit
      )
    XCTAssertEqual(result.displayName, edit.displayName)
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testMismatchedOrBirthdayChangingReadbackIsUnknownAndNeverRetries() async throws {
    let edit = targetEdit()
    let changedBirthday = TiebaSelfProfileBirthday(
      timeMilliseconds: birthday.timeMilliseconds + 86_400_000,
      showsConstellationOnly: birthday.showsConstellationOnly
    )
    let readbacks = [
      profile(birthday: birthday),
      profile(
        displayName: edit.displayName,
        editableBiography: edit.biography,
        sex: edit.sex,
        birthday: changedBirthday
      ),
    ]
    for readback in readbacks {
      let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
        .init(body: try profile().serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try readback.serializedData()),
      ])
      await assertError(.selfProfileEditOutcomeUnknown) {
        _ = try await TiebaAuthenticatedClient(transport: transport)
          .updateSelfProfile(
            credential: self.sessionCredential(),
            expectedUserID: self.accountID,
            edit: edit
          )
      }
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 1)
    }
  }

  func testFailedReadbackIsUnknownAndNeverRetries() async throws {
    let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile().serializedData()),
      .init(body: Data(#"{"error_code":0}"#.utf8)),
      .init(error: .transportFailure),
    ])
    await assertError(.selfProfileEditOutcomeUnknown) {
      _ = try await TiebaAuthenticatedClient(transport: transport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: self.targetEdit()
        )
    }
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testServerRejectionIsReturnedAfterMandatoryReadback() async throws {
    let transport = ProfileEditTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile().serializedData()),
      .init(body: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
      .init(body: try profile().serializedData()),
    ])
    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await TiebaAuthenticatedClient(transport: transport)
        .updateSelfProfile(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          edit: self.targetEdit()
        )
    }
    let paths = await transport.paths()
    XCTAssertEqual(paths, authenticatedProfileMutationPaths)
  }

  func testEquivalentConcurrentEditsShareFlightAndConflictIsRejectedImmediately() async throws {
    let edit = targetEdit()
    let transport = ProfileEditTransport(
      authenticatedUserID: accountID,
      responses: [
        .init(body: try profile().serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try profile(
          displayName: edit.displayName,
          editableBiography: edit.biography,
          sex: edit.sex,
          birthday: birthday
        ).serializedData()),
      ],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.updateSelfProfile(
        credential: sessionCredential(), expectedUserID: accountID, edit: edit
      )
    }
    let firstRequestStarted = await transport.waitUntilRequestCount(3)
    XCTAssertTrue(firstRequestStarted)
    let equivalent = Task {
      try await client.updateSelfProfile(
        credential: sessionCredential(), expectedUserID: accountID, edit: edit
      )
    }
    let didShareFlight = await waitUntilWaiterCount(client: client, count: 2)
    XCTAssertTrue(didShareFlight)
    await assertError(.selfProfileEditWriteConflict) {
      _ = try await client.updateSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        edit: TiebaSelfProfileEdit(
          displayName: "Conflicting Name",
          biography: edit.biography,
          sex: edit.sex
        )
      )
    }
    await transport.releaseBlockedRequest()
    _ = try await first.value
    _ = try await equivalent.value
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testCancelledJoinedWaiterDoesNotCancelDispatchedSharedWrite() async throws {
    let edit = targetEdit()
    let transport = ProfileEditTransport(
      authenticatedUserID: accountID,
      responses: [
        .init(body: try profile().serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try profile(
          displayName: edit.displayName,
          editableBiography: edit.biography,
          sex: edit.sex,
          birthday: birthday
        ).serializedData()),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task {
      try await client.updateSelfProfile(
        credential: sessionCredential(), expectedUserID: accountID, edit: edit
      )
    }
    let writeStarted = await transport.waitUntilRequestCount(4)
    XCTAssertTrue(writeStarted)
    let joined = Task {
      try await client.updateSelfProfile(
        credential: sessionCredential(), expectedUserID: accountID, edit: edit
      )
    }
    let didShareFlight = await waitUntilWaiterCount(client: client, count: 2)
    XCTAssertTrue(didShareFlight)
    joined.cancel()
    switch await joined.result {
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    case .success: XCTFail("Expected the joined waiter to be cancelled")
    }
    await transport.releaseBlockedRequest()
    _ = try await first.value
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testCancellingOnlyCallerDuringPreflightPreventsWriteAndCleansFlight() async throws {
    let transport = ProfileEditTransport(
      authenticatedUserID: accountID,
      responses: [.init(body: try profile().serializedData())],
      blockedRequestIndex: 0
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let edit = targetEdit()
    let task = Task {
      try await client.updateSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: edit
      )
    }
    let readStarted = await transport.waitUntilRequestCount(3)
    XCTAssertTrue(readStarted)
    let waiterRegistered = await waitUntilWaiterCount(client: client, count: 1)
    XCTAssertTrue(waiterRegistered)

    task.cancel()
    let waiterRemoved = await waitUntilWaiterCount(client: client, count: 0)
    XCTAssertTrue(waiterRemoved)
    await transport.releaseBlockedRequest()
    switch await task.result {
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    case .success: XCTFail("Expected preflight cancellation")
    }
    let flightWasCleaned = await waitUntilFlightState(client: client, exists: false)
    XCTAssertTrue(flightWasCleaned)
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testCancelledPreflightCanBeRetriedImmediatelyBeforeOldTaskFinishes() async throws {
    let edits = [
      targetEdit(),
      TiebaSelfProfileEdit(
        displayName: "Different retry",
        biography: "Different biography",
        sex: .unspecified
      ),
    ]
    for retryEdit in edits {
      let transport = ProfileEditTransport(
        authenticatedUserID: accountID,
        responses: [
          .init(body: try profile().serializedData()),
          .init(body: profileEditAppAccountBody(userID: accountID)),
          .init(body: profileEditWebAccountBody(userID: accountID)),
          .init(body: try profile().serializedData()),
          .init(body: Data(#"{"error_code":0}"#.utf8)),
          .init(body: try profile(
            displayName: retryEdit.displayName,
            editableBiography: retryEdit.biography,
            sex: retryEdit.sex,
            birthday: birthday
          ).serializedData()),
        ],
        blockedRequestIndex: 0
      )
      let client = TiebaAuthenticatedClient(transport: transport)
      let first = Task {
        try await client.updateSelfProfile(
          credential: sessionCredential(),
          expectedUserID: accountID,
          edit: targetEdit()
        )
      }
      let oldReadStarted = await transport.waitUntilRequestCount(3)
      XCTAssertTrue(oldReadStarted)
      let oldWaiterRegistered = await waitUntilWaiterCount(client: client, count: 1)
      XCTAssertTrue(oldWaiterRegistered)

      first.cancel()
      switch await first.result {
      case .failure(let error): XCTAssertTrue(error is CancellationError)
      case .success: XCTFail("Expected the old preflight caller to be cancelled")
      }
      let oldFlightDetached = await waitUntilFlightState(client: client, exists: false)
      XCTAssertTrue(oldFlightDetached)

      let retry = Task {
        try await client.updateSelfProfile(
          credential: sessionCredential(),
          expectedUserID: accountID,
          edit: retryEdit
        )
      }
      let retryDispatchedBeforeOldReadWasReleased = await transport.waitUntilRequestCount(8)
      XCTAssertTrue(retryDispatchedBeforeOldReadWasReleased)
      if !retryDispatchedBeforeOldReadWasReleased {
        await transport.releaseBlockedRequest()
      }
      let retryOutcome = await retry.result
      await transport.releaseBlockedRequest()

      switch retryOutcome {
      case .success(let result):
        XCTAssertEqual(result.displayName, retryEdit.displayName)
        XCTAssertEqual(result.editableBiography, retryEdit.biography)
        XCTAssertEqual(result.sex, retryEdit.sex)
      case .failure(let error):
        XCTFail("Immediate retry inherited the cancelled flight: \(error)")
      }
      let paths = await transport.paths()
      XCTAssertEqual(paths, [
        "/c/s/login", "/mo/q/newmoindex", "/c/u/user/profile",
        "/c/s/login", "/mo/q/newmoindex", "/c/u/user/profile",
        "/c/c/profile/modify", "/c/u/user/profile",
      ])
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 1)
      let newFlightCleaned = await waitUntilFlightState(client: client, exists: false)
      XCTAssertTrue(newFlightCleaned)
    }
  }

  func testPreCancelledCallerPerformsNoTransport() async {
    let transport = ProfileEditTransport(responses: [])
    let client = TiebaAuthenticatedClient(transport: transport)
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.updateSelfProfile(
        credential: sessionCredential(),
        expectedUserID: accountID,
        edit: targetEdit()
      )
    }.result

    switch result {
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    case .success: XCTFail("Expected the pre-cancelled edit to stop")
    }
    let paths = await transport.paths()
    XCTAssertTrue(paths.isEmpty)
  }

  private func targetEdit() -> TiebaSelfProfileEdit {
    TiebaSelfProfileEdit(
      displayName: "Updated Name",
      biography: "Updated\nintroduction",
      sex: .male
    )
  }

  private func profile(
    displayName: String = "Profile User",
    editableBiography: String = "Legacy introduction",
    sex: TiebaSelfProfileSex = .female,
    birthday: TiebaSelfProfileBirthday? = TiebaSelfProfileBirthday(
      timeMilliseconds: 946_684_800_000,
      showsConstellationOnly: true
    )
  ) -> ProfileResIdl {
    var response = ProtoFixtures.userProfile()
    response.data.user.nameShow = displayName
    response.data.user.displayIntro = editableBiography
    response.data.user.intro = editableBiography
    response.data.user.sex = sex.rawValue
    response.data.user.isNicknameEditing = 0
    response.data.user.editingNickname = ""
    if let birthday {
      response.data.user.birthdayInfo = BirthdayInfo.with {
        $0.birthdayTime = birthday.timeMilliseconds / 1_000
        $0.birthdayShowStatus = birthday.showsConstellationOnly ? 1 : 0
      }
    } else {
      response.data.user.clearBirthdayInfo()
    }
    return response
  }

  private func staticClient(_ response: ProfileResIdl) throws -> TiebaAuthenticatedClient {
    TiebaAuthenticatedClient(
      transport: ProfileEditTransport(responses: [
        .init(body: try response.serializedData())
      ])
    )
  }

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    let text = try XCTUnwrap(String(data: body, encoding: .utf8))
    var components = URLComponents()
    components.query = text
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
      ($0.name, $0.value ?? "")
    })
  }

  private func waitUntilWaiterCount(
    client: TiebaAuthenticatedClient,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await client.selfProfileEditWaiterCount(expectedUserID: accountID) == count {
        return true
      }
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return false
  }

  private func waitUntilFlightState(
    client: TiebaAuthenticatedClient,
    exists: Bool,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await client.selfProfileEditFlightExists(expectedUserID: accountID) == exists {
        return true
      }
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return false
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

private func profileEditAppAccountBody(userID: Int64) -> Data {
  Data(
    (
      "{\"error_code\":0,\"user\":{\"id\":\"\(userID)\","
        + "\"name\":\"account-name\",\"portrait\":\"portrait-token\"}}"
    ).utf8
  )
}

private func profileEditWebAccountBody(userID: Int64) -> Data {
  Data("{\"no\":0,\"data\":{\"id\":\"\(userID)\"}}".utf8)
}

private actor ProfileEditTransport: TiebaTransport {
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

  private let responses: [Response]
  private let blockedRequestIndex: Int?
  private var requests = [URLRequest]()
  private var limits = [Int?]()
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

  init(responses: [Response], blockedRequestIndex: Int? = nil) {
    self.responses = responses
    self.blockedRequestIndex = blockedRequestIndex
  }

  init(
    authenticatedUserID: Int64,
    responses: [Response],
    blockedRequestIndex: Int? = nil
  ) {
    self.responses = [
      Response(body: profileEditAppAccountBody(userID: authenticatedUserID)),
      Response(body: profileEditWebAccountBody(userID: authenticatedUserID)),
    ] + responses
    self.blockedRequestIndex = blockedRequestIndex.map { $0 + 2 }
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
    limits.append(maximumBodyBytes)
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

  func waitUntilRequestCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while requests.count < count, clock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return requests.count >= count
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }

  func paths() -> [String] {
    requests.map { $0.url?.path ?? "" }
  }

  func writeCount() -> Int {
    requests.filter { $0.url?.path == "/c/c/profile/modify" }.count
  }

  func maximumBodyBytes() -> [Int?] { limits }
}
