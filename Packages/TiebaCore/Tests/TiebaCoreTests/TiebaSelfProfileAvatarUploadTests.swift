import Foundation
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaSelfProfileAvatarUploadTests: XCTestCase, @unchecked Sendable {
  private let accountID: Int64 = 957_339_815
  private let pixelSize = 256

  func testEndpointPolicyAllowsOnlyExactHTTPSAvatarEndpoint() {
    XCTAssertTrue(
      TiebaSelfProfileAvatarUploadEndpointPolicy.allows(
        URL(string: "https://tiebac.baidu.com/c/c/img/portrait")
      )
    )
    for rawValue in [
      "http://tiebac.baidu.com/c/c/img/portrait",
      "https://tiebac.baidu.com:443/c/c/img/portrait",
      "https://user@tiebac.baidu.com/c/c/img/portrait",
      "https://tiebac.baidu.com.evil.example/c/c/img/portrait",
      "https://tiebac.baidu.com/c/c/img/portrait/extra",
      "https://tiebac.baidu.com/c/c/img/portrait?x=1",
      "https://tiebac.baidu.com/c/c/img/portrait#fragment",
    ] {
      XCTAssertFalse(
        TiebaSelfProfileAvatarUploadEndpointPolicy.allows(URL(string: rawValue)),
        rawValue
      )
    }
  }

  func testRequestUsesMinimalSignedMultipartContract() throws {
    let credential = sessionCredential()
    let upload = avatarUpload()
    let request = try TiebaAuthenticatedRequestFactory(configuration: .init())
      .uploadSelfProfileAvatar(
        credential: credential,
        expectedUserID: accountID,
        upload: upload
      )
    let parsed = try parseAvatarMultipart(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/c/img/portrait")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.52.1.0"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=\(parsed.boundary)"
    )
    XCTAssertTrue(parsed.boundary.hasPrefix("TiebaPlusPlusAvatarBoundary-"))
    XCTAssertEqual(parsed.jpegData, upload.jpegData)
    XCTAssertEqual(
      Set(parsed.fields.keys),
      Set(["BDUSS", "_client_type", "_client_version", "sign"])
    )
    XCTAssertEqual(parsed.fields["BDUSS"], credential.bduss)
    XCTAssertEqual(parsed.fields["_client_type"], "2")
    XCTAssertEqual(parsed.fields["_client_version"], "12.52.1.0")
    let unsigned = parsed.fields
      .filter { $0.key != "sign" }
      .map { ($0.key, $0.value) }
    XCTAssertEqual(parsed.fields["sign"], TiebaFormSigner.signature(for: unsigned))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    for forbidden in [
      "stoken", "tbs", "uid", "CUID", "cuid", "cuid_galaxy2", "cuid_gid",
      "_phone_imei", "model", "brand", "android_id", "oaid", "timestamp",
    ] {
      XCTAssertNil(parsed.fields[forbidden], "Unexpected field: \(forbidden)")
      XCTAssertNil(request.value(forHTTPHeaderField: forbidden))
    }
  }

  func testUploadPolicyRequiresBoundedSquareSOFDimensions() {
    XCTAssertEqual(TiebaSelfProfileAvatarUploadPolicy.maximumJPEGByteCount, 2 * 1_024 * 1_024)
    XCTAssertTrue(TiebaSelfProfileAvatarUploadPolicy.isValid(avatarUpload()))

    for size in [63, 1_025] {
      XCTAssertFalse(
        TiebaSelfProfileAvatarUploadPolicy.isValid(
          TiebaSelfProfileAvatarUpload(jpegData: makeJPEG(size: size), squarePixelSize: size)
        )
      )
    }
    XCTAssertFalse(
      TiebaSelfProfileAvatarUploadPolicy.isValid(
        TiebaSelfProfileAvatarUpload(
          jpegData: makeJPEG(width: pixelSize, height: pixelSize - 1),
          squarePixelSize: pixelSize
        )
      )
    )
    XCTAssertFalse(
      TiebaSelfProfileAvatarUploadPolicy.isValid(
        TiebaSelfProfileAvatarUpload(
          jpegData: makeJPEG(size: pixelSize),
          squarePixelSize: pixelSize + 1
        )
      )
    )
    XCTAssertFalse(
      TiebaSelfProfileAvatarUploadPolicy.isValid(
        TiebaSelfProfileAvatarUpload(
          jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
          squarePixelSize: pixelSize
        )
      )
    )
    for marker in [UInt8(0xE1), UInt8(0xEF), UInt8(0xFE)] {
      var metadataBearing = makeJPEG(size: pixelSize)
      metadataBearing.insert(contentsOf: [0xFF, marker, 0x00, 0x04, 0x00, 0x00], at: 2)
      XCTAssertFalse(
        TiebaSelfProfileAvatarUploadPolicy.isValid(
          TiebaSelfProfileAvatarUpload(
            jpegData: metadataBearing,
            squarePixelSize: pixelSize
          )
        )
      )
    }
    var unsupportedPrecision = makeJPEG(size: pixelSize)
    unsupportedPrecision[24] = 12
    XCTAssertFalse(
      TiebaSelfProfileAvatarUploadPolicy.isValid(
        TiebaSelfProfileAvatarUpload(
          jpegData: unsupportedPrecision,
          squarePixelSize: pixelSize
        )
      )
    )
    var oversized = makeJPEG(size: pixelSize)
    oversized.insert(
      contentsOf: repeatElement(
        UInt8.zero,
        count: TiebaSelfProfileAvatarUploadPolicy.maximumJPEGByteCount
      ),
      at: oversized.count - 2
    )
    XCTAssertFalse(
      TiebaSelfProfileAvatarUploadPolicy.isValid(
        TiebaSelfProfileAvatarUpload(jpegData: oversized, squarePixelSize: pixelSize)
      )
    )
  }

  func testUploadDescriptionAndReflectionRedactJPEGBytes() {
    let upload = avatarUpload()
    XCTAssertFalse(String(describing: upload).contains("JFIF"))
    XCTAssertFalse(String(reflecting: upload).contains("JFIF"))
    XCTAssertFalse(upload.customMirror.children.compactMap(\.label).contains("jpegData"))
  }

  func testProfileDecoderPreservesStrictPortraitVersionAndMapsPermission() throws {
    var response = profile(portrait: "profile-token?t=1234567890", canModifyAvatar: 1)
    response.data.user.modifyAvatarDesc = "not exposed when allowed"
    let summary = try TiebaAuthenticatedDecoder.selfProfile(
      from: response,
      expectedUserID: accountID
    )
    XCTAssertEqual(summary.portrait, "profile-token")
    XCTAssertEqual(summary.portraitSource, "profile-token?t=1234567890")
    XCTAssertEqual(summary.avatarModificationPermission, .allowed)

    response.data.user.canModifyAvatar = 0
    response.data.user.modifyAvatarDesc = "  头像正在审核\r\n请稍后  "
    let denied = try TiebaAuthenticatedDecoder.selfProfile(
      from: response,
      expectedUserID: accountID
    )
    XCTAssertEqual(
      denied.avatarModificationPermission,
      .denied(message: "头像正在审核\n请稍后")
    )
  }

  func testProfileDecoderCanonicalizesEquivalentPortraitRepresentations() throws {
    for source in [
      "profile-token?t=000123",
      "http://tb.himg.baidu.com/sys/portrait/item/profile-token?t=123",
      "HTTPS://HIMG.BDIMG.COM/sys/portraith/item/profile-token?t=123",
      "//himg.bdimg.com/sys/portraitn/item/profile-token?t=123",
    ] {
      let summary = try TiebaAuthenticatedDecoder.selfProfile(
        from: profile(portrait: source, canModifyAvatar: 1),
        expectedUserID: accountID
      )
      XCTAssertEqual(summary.portrait, "profile-token")
      XCTAssertEqual(summary.portraitSource, "profile-token?t=123")
    }
  }

  func testProfileDecoderRejectsUnsafePortraitVersionAndUnknownPermission() {
    for portrait in [
      "profile-token?x=1", "profile-token?t=", "profile-token?t=12x",
      "profile-token?t=123456789012345678901", "profile-token#fragment",
      "profile token?t=1", "file:///tmp/profile-token", "https://example.com/profile-token",
      "https://himg.bdimg.com/sys/portrait/item/../profile-token?t=1",
    ] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.selfProfile(
          from: profile(portrait: portrait, canModifyAvatar: 1),
          expectedUserID: accountID
        )
      ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
    }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.selfProfile(
        from: profile(canModifyAvatar: 2),
        expectedUserID: accountID
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidAuthenticatedResponse) }
  }

  func testAcknowledgementDistinguishesAcceptedPendingAndFailures() throws {
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.selfProfileAvatarUploadAcknowledgement(
        from: Data(#"{"error_code":0,"error_msg":"accepted"}"#.utf8)
      ),
      .accepted(message: "accepted")
    )
    XCTAssertEqual(
      try TiebaAuthenticatedDecoder.selfProfileAvatarUploadAcknowledgement(
        from: Data(#"{"errno":"300003","errmsg":"under review"}"#.utf8)
      ),
      .acceptedPendingReview(message: "under review")
    )
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.selfProfileAvatarUploadAcknowledgement(
        from: Data(#"{"error_code":0,"errno":300003}"#.utf8)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .invalidJSON) }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.selfProfileAvatarUploadAcknowledgement(
        from: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)
      )
    ) { XCTAssertEqual($0 as? TiebaClientError, .server(code: 340_006, message: "denied")) }
  }

  func testChangedPortraitVersionConfirmsAfterExactlyOneWriteAndReadback() async throws {
    let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile(portrait: "portrait?t=1").serializedData()),
      .init(body: Data(#"{"error_code":0}"#.utf8)),
      .init(body: try profile(portrait: "portrait?t=2").serializedData()),
    ])
    let result = try await client(transport).uploadSelfProfileAvatar(
      credential: sessionCredential(),
      expectedUserID: accountID,
      upload: avatarUpload()
    )

    XCTAssertEqual(result.disposition, .confirmed)
    XCTAssertEqual(result.latestProfile.portrait, "portrait")
    XCTAssertEqual(result.latestProfile.portraitSource, "portrait?t=2")
    let paths = await transport.paths()
    let writeCount = await transport.writeCount()
    let limits = await transport.maximumBodyBytes()
    XCTAssertEqual(paths, authenticatedMutationPaths)
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(limits, [
      TiebaAuthenticatedClient.accountResponseMaximumBytes,
      TiebaAuthenticatedClient.webSessionResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileAvatarUploadResponseMaximumBytes,
      TiebaAuthenticatedClient.selfProfileResponseMaximumBytes,
    ])
  }

  func testAcceptedButUnchangedReadbackIsPendingRatherThanLocallyConfirmed() async throws {
    for acknowledgement in [
      #"{"error_code":0,"error_msg":"accepted"}"#,
      #"{"error_code":300003,"error_msg":"under review"}"#,
    ] {
      let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(body: Data(acknowledgement.utf8)),
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
      ])
      let result = try await client(transport).uploadSelfProfileAvatar(
        credential: sessionCredential(),
        expectedUserID: accountID,
        upload: avatarUpload()
      )
      let expectedMessage = acknowledgement.contains("300003") ? "under review" : "accepted"
      XCTAssertEqual(
        result.disposition,
        .acceptedPendingReview(message: expectedMessage)
      )
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 1)
    }
  }

  func testLostWriteResponseRemainsUnknownEvenWhenReadbackChanges() async throws {
    let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile(portrait: "portrait?t=1").serializedData()),
      .init(error: .transportFailure),
      .init(body: try profile(portrait: "new-portrait?t=2").serializedData()),
    ])
    await assertError(.selfProfileAvatarOutcomeUnknown) {
      _ = try await self.client(transport).uploadSelfProfileAvatar(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        upload: self.avatarUpload()
      )
    }
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testUnverifiableWriteOrReadbackIsUnknownAndNeverRetries() async throws {
    let scenarios: [[AvatarTransport.Response]] = [
      [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(error: .transportFailure),
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
      ],
      [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(error: .transportFailure),
      ],
    ]
    for responses in scenarios {
      let transport = AvatarTransport(authenticatedUserID: accountID, responses: responses)
      await assertError(.selfProfileAvatarOutcomeUnknown) {
        _ = try await self.client(transport).uploadSelfProfileAvatar(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          upload: self.avatarUpload()
        )
      }
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 1)
    }
  }

  func testServerRejectionIsPreservedEvenWhenReadbackChanges() async throws {
    for portrait in ["portrait?t=1", "portrait?t=2"] {
      let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(body: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
        .init(body: try profile(portrait: portrait).serializedData()),
      ])
      await assertError(.server(code: 340_006, message: "denied")) {
        _ = try await self.client(transport).uploadSelfProfileAvatar(
          credential: self.sessionCredential(),
          expectedUserID: self.accountID,
          upload: self.avatarUpload()
        )
      }
      let writeCount = await transport.writeCount()
      XCTAssertEqual(writeCount, 1)
    }
  }

  func testEquivalentPortraitRepresentationDoesNotFalselyConfirmUpload() async throws {
    let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
      .init(body: try profile(portrait: "portrait?t=001").serializedData()),
      .init(body: Data(#"{"error_code":0,"error_msg":"accepted"}"#.utf8)),
      .init(
        body: try profile(
          portrait: "HTTPS://HIMG.BDIMG.COM/sys/portraith/item/portrait?t=1"
        ).serializedData()
      ),
    ])

    let result = try await client(transport).uploadSelfProfileAvatar(
      credential: sessionCredential(),
      expectedUserID: accountID,
      upload: avatarUpload()
    )

    XCTAssertEqual(result.disposition, .acceptedPendingReview(message: "accepted"))
    XCTAssertEqual(result.latestProfile.portraitSource, "portrait?t=1")
  }

  func testDeniedPermissionStopsBeforeUpload() async throws {
    var denied = profile(canModifyAvatar: 0)
    denied.data.user.modifyAvatarDesc = "本月修改次数已用尽"
    let transport = AvatarTransport(authenticatedUserID: accountID, responses: [
      .init(body: try denied.serializedData())
    ])
    await assertError(
      .selfProfileAvatarModificationUnavailable(message: "本月修改次数已用尽")
    ) {
      _ = try await self.client(transport).uploadSelfProfileAvatar(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        upload: self.avatarUpload()
      )
    }
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 0)
  }

  func testEquivalentConcurrentUploadsShareFlightAndDifferentUploadConflicts() async throws {
    let upload = avatarUpload()
    let transport = AvatarTransport(
      authenticatedUserID: accountID,
      responses: [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try profile(portrait: "portrait?t=2").serializedData()),
      ],
      blockedRequestIndex: 1
    )
    let client = client(transport)
    let first = Task {
      try await client.uploadSelfProfileAvatar(
        credential: sessionCredential(), expectedUserID: accountID, upload: upload
      )
    }
    let writeStarted = await transport.waitUntilRequestCount(4)
    XCTAssertTrue(writeStarted)
    let equivalent = Task {
      try await client.uploadSelfProfileAvatar(
        credential: sessionCredential(), expectedUserID: accountID, upload: upload
      )
    }
    let didShareFlight = await waitUntilAvatarWaiterCount(client, count: 2)
    XCTAssertTrue(didShareFlight)
    await assertError(.selfProfileAvatarWriteConflict) {
      _ = try await client.uploadSelfProfileAvatar(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        upload: self.avatarUpload(id: UUID())
      )
    }
    await assertError(.selfProfileAvatarWriteConflict) {
      _ = try await client.uploadSelfProfileAvatar(
        credential: self.sessionCredential(component: "c"),
        expectedUserID: self.accountID,
        upload: upload
      )
    }
    await transport.releaseBlockedRequest()
    let firstResult = try await first.value
    let equivalentResult = try await equivalent.value
    XCTAssertEqual(firstResult.disposition, .confirmed)
    XCTAssertEqual(equivalentResult.disposition, .confirmed)
    let writeCount = await transport.writeCount()
    XCTAssertEqual(writeCount, 1)
  }

  func testCancellingCallerAfterWriteStillFinishesOneReadbackWithoutRetry() async throws {
    let transport = AvatarTransport(
      authenticatedUserID: accountID,
      responses: [
        .init(body: try profile(portrait: "portrait?t=1").serializedData()),
        .init(body: Data(#"{"error_code":0}"#.utf8)),
        .init(body: try profile(portrait: "portrait?t=2").serializedData()),
      ],
      blockedRequestIndex: 2
    )
    let client = client(transport)
    let caller = Task {
      try await client.uploadSelfProfileAvatar(
        credential: sessionCredential(),
        expectedUserID: accountID,
        upload: avatarUpload()
      )
    }
    let readbackStarted = await transport.waitUntilRequestCount(5)
    XCTAssertTrue(readbackStarted)

    caller.cancel()
    let waiterWasRemoved = await waitUntilAvatarWaiterCount(client, count: 0)
    XCTAssertTrue(waiterWasRemoved)
    let flightContinuesReadback = await client.selfProfileAvatarUploadFlightExists(
      expectedUserID: accountID
    )
    XCTAssertTrue(flightContinuesReadback)
    await transport.releaseBlockedRequest()

    switch await caller.result {
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    case .success: XCTFail("A cancelled caller must not receive the late result")
    }
    let flightFinished = await waitUntilAvatarFlightExists(client, expected: false)
    XCTAssertTrue(flightFinished)
    let paths = await transport.paths()
    let writeCount = await transport.writeCount()
    XCTAssertEqual(paths, authenticatedMutationPaths)
    XCTAssertEqual(writeCount, 1)
  }

  func testProfileEditAndAvatarUploadRejectCrossMutationFlights() async throws {
    let avatarTransport = AvatarTransport(
      authenticatedUserID: accountID,
      responses: [.init(body: try profile().serializedData())],
      blockedRequestIndex: 0
    )
    let avatarClient = client(avatarTransport)
    let avatarTask = Task {
      try await avatarClient.uploadSelfProfileAvatar(
        credential: sessionCredential(), expectedUserID: accountID, upload: avatarUpload()
      )
    }
    let avatarReadStarted = await avatarTransport.waitUntilRequestCount(3)
    XCTAssertTrue(avatarReadStarted)
    await assertError(.selfProfileEditWriteConflict) {
      _ = try await avatarClient.updateSelfProfile(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        edit: self.profileEdit()
      )
    }
    avatarTask.cancel()
    _ = await avatarTask.result
    await avatarTransport.releaseBlockedRequest()

    let editTransport = AvatarTransport(
      authenticatedUserID: accountID,
      responses: [.init(body: try profile().serializedData())],
      blockedRequestIndex: 0
    )
    let editClient = client(editTransport)
    let editTask = Task {
      try await editClient.updateSelfProfile(
        credential: sessionCredential(), expectedUserID: accountID, edit: profileEdit()
      )
    }
    let editReadStarted = await editTransport.waitUntilRequestCount(3)
    XCTAssertTrue(editReadStarted)
    await assertError(.selfProfileAvatarWriteConflict) {
      _ = try await editClient.uploadSelfProfileAvatar(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        upload: self.avatarUpload()
      )
    }
    editTask.cancel()
    _ = await editTask.result
    await editTransport.releaseBlockedRequest()
  }

  func testPreCancelledCallerPerformsNoTransport() async {
    let transport = AvatarTransport(responses: [])
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await self.client(transport).uploadSelfProfileAvatar(
        credential: self.sessionCredential(),
        expectedUserID: self.accountID,
        upload: self.avatarUpload()
      )
    }.result
    switch result {
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    case .success: XCTFail("Expected cancellation")
    }
    let paths = await transport.paths()
    XCTAssertTrue(paths.isEmpty)
  }

  private var authenticatedMutationPaths: [String] {
    [
      "/c/s/login", "/mo/q/newmoindex", "/c/u/user/profile",
      "/c/c/img/portrait", "/c/u/user/profile",
    ]
  }

  private func client(_ transport: AvatarTransport) -> TiebaAuthenticatedClient {
    TiebaAuthenticatedClient(transport: transport)
  }

  private func avatarUpload(id: UUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)
    -> TiebaSelfProfileAvatarUpload
  {
    TiebaSelfProfileAvatarUpload(
      uploadID: id,
      jpegData: makeJPEG(size: pixelSize),
      squarePixelSize: pixelSize
    )
  }

  private func profile(
    portrait: String = "portrait?t=1",
    canModifyAvatar: Int32 = 1
  ) -> ProfileResIdl {
    var response = ProtoFixtures.userProfile()
    response.data.user.portrait = portrait
    response.data.user.canModifyAvatar = canModifyAvatar
    response.data.user.modifyAvatarDesc = ""
    return response
  }

  private func profileEdit() -> TiebaSelfProfileEdit {
    TiebaSelfProfileEdit(
      displayName: "Updated Name",
      biography: "Updated introduction",
      sex: .male
    )
  }

  private func sessionCredential(component: String = "b") -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: component, count: 192),
      stoken: String(repeating: component == "b" ? "s" : component, count: 64),
      bdussCookieName: .bduss
    )
  }

  private func waitUntilAvatarWaiterCount(
    _ client: TiebaAuthenticatedClient,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await client.selfProfileAvatarUploadWaiterCount(expectedUserID: accountID) == count {
        return true
      }
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return false
  }

  private func waitUntilAvatarFlightExists(
    _ client: TiebaAuthenticatedClient,
    expected: Bool,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await client.selfProfileAvatarUploadFlightExists(expectedUserID: accountID) == expected {
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

private func makeJPEG(size: Int) -> Data {
  makeJPEG(width: size, height: size)
}

private func makeJPEG(width: Int, height: Int) -> Data {
  let width = UInt16(clamping: width)
  let height = UInt16(clamping: height)
  return Data([
    0xFF, 0xD8,
    0xFF, 0xE0, 0x00, 0x10,
    0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xC0, 0x00, 0x11, 0x08,
    UInt8(height >> 8), UInt8(height & 0xFF),
    UInt8(width >> 8), UInt8(width & 0xFF),
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
    0x00, 0xFF, 0xD9,
  ])
}

private struct ParsedAvatarMultipart {
  let boundary: String
  let fields: [String: String]
  let jpegData: Data
}

private enum AvatarMultipartError: Swift.Error {
  case malformed
}

private func parseAvatarMultipart(_ request: URLRequest) throws -> ParsedAvatarMultipart {
  let contentTypePrefix = "multipart/form-data; boundary="
  guard
    let body = request.httpBody,
    let contentType = request.value(forHTTPHeaderField: "Content-Type"),
    contentType.hasPrefix(contentTypePrefix)
  else { throw AvatarMultipartError.malformed }
  let boundary = String(contentType.dropFirst(contentTypePrefix.count))
  let fileMarker = Data(
    "--\(boundary)\r\n"
      .appending("Content-Disposition: form-data; name=\"pic\"; filename=\"file\"\r\n\r\n")
      .utf8
  )
  let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
  guard
    !boundary.isEmpty,
    !boundary.contains("\r"),
    !boundary.contains("\n"),
    let fileMarkerRange = body.range(of: fileMarker),
    body.suffix(suffix.count) == suffix,
    let scalarText = String(data: body[..<fileMarkerRange.lowerBound], encoding: .utf8)
  else { throw AvatarMultipartError.malformed }

  let namePrefix = "Content-Disposition: form-data; name=\""
  let nameSuffix = "\"\r\n\r\n"
  var fields = [String: String]()
  for part in scalarText.components(separatedBy: "--\(boundary)\r\n") where !part.isEmpty {
    guard
      part.hasPrefix(namePrefix),
      let nameEnd = part.range(of: nameSuffix),
      part.hasSuffix("\r\n")
    else { throw AvatarMultipartError.malformed }
    let nameStart = part.index(part.startIndex, offsetBy: namePrefix.count)
    let name = String(part[nameStart..<nameEnd.lowerBound])
    guard fields[name] == nil else { throw AvatarMultipartError.malformed }
    fields[name] = String(part[nameEnd.upperBound...].dropLast())
  }
  return ParsedAvatarMultipart(
    boundary: boundary,
    fields: fields,
    jpegData: body.subdata(
      in: fileMarkerRange.upperBound..<(body.count - suffix.count)
    )
  )
}

private func avatarAppAccountBody(userID: Int64) -> Data {
  Data(
    (
      "{\"error_code\":0,\"user\":{\"id\":\"\(userID)\","
        + "\"name\":\"account-name\",\"portrait\":\"portrait-token\"}}"
    ).utf8
  )
}

private func avatarWebAccountBody(userID: Int64) -> Data {
  Data("{\"no\":0,\"data\":{\"id\":\"\(userID)\"}}".utf8)
}

private actor AvatarTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int
    let error: TiebaClientError?

    init(body: Data = Data(), statusCode: Int = 200, error: TiebaClientError? = nil) {
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
      .init(body: avatarAppAccountBody(userID: authenticatedUserID)),
      .init(body: avatarWebAccountBody(userID: authenticatedUserID)),
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
    requests.filter { $0.url?.path == "/c/c/img/portrait" }.count
  }

  func maximumBodyBytes() -> [Int?] { limits }
}
