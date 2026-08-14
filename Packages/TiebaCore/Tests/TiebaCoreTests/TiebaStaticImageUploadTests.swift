import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaStaticImageUploadRequestTests: XCTestCase {
  private let factory = TiebaAuthenticatedRequestFactory(configuration: .init())

  func testEndpointPolicyAllowsOnlyExactHTTPSUploadEndpoint() {
    XCTAssertTrue(
      TiebaStaticImageUploadEndpointPolicy.allows(
        URL(string: "https://tiebac.baidu.com/c/s/uploadPicture")
      )
    )
    for rawValue in [
      "http://tiebac.baidu.com/c/s/uploadPicture",
      "https://tiebac.baidu.com:443/c/s/uploadPicture",
      "https://user@tiebac.baidu.com/c/s/uploadPicture",
      "https://tiebac.baidu.com.evil.example/c/s/uploadPicture",
      "https://tiebac.baidu.com/c/s/uploadPicture/extra",
      "https://tiebac.baidu.com/c/s/uploadPicture?x=1",
      "https://tiebac.baidu.com/c/s/uploadPicture#fragment",
      "https://tiebac.baidu.com/c/s/%75ploadPicture",
    ] {
      XCTAssertFalse(TiebaStaticImageUploadEndpointPolicy.allows(URL(string: rawValue)), rawValue)
    }
  }

  func testRequestUsesExactHTTPSScalarContractAndExcludesBinaryFromSignature() throws {
    let upload = makeStaticImageUpload(
      bytes: Data("abc".utf8),
      forumName: " swift ",
      width: 1_920,
      height: 1_080,
      preservesOriginal: true,
      watermark: .username
    )
    let credential = staticImageCredential()
    let plan = try factory.validateStaticImageUploadArguments(
      credential: credential,
      expectedUserID: 1_001,
      upload: upload
    )
    let request = try factory.staticImageUploadChunk(
      credential: credential,
      expectedUserID: 1_001,
      plan: plan,
      chunkNumber: 1
    )
    let parsed = try parseStaticImageMultipart(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/s/uploadPicture")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=\(parsed.boundary)"
    )
    XCTAssertTrue(parsed.boundary.hasPrefix("TiebaPlusPlusBoundary-"))
    XCTAssertNil(upload.encodedBytes.range(of: Data(parsed.boundary.utf8)))
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    for forbiddenHeader in [
      "CUID", "cuid_galaxy2", "cuid_gid", "cuid_galaxy3", "client_logid", "model",
      "_phone_imei", "oaid",
    ] {
      XCTAssertNil(
        request.value(forHTTPHeaderField: forbiddenHeader),
        "Unexpected device header: \(forbiddenHeader)"
      )
    }
    XCTAssertEqual(parsed.chunk, upload.encodedBytes)
    XCTAssertEqual(
      Set(parsed.fields.keys),
      Set([
        "BDUSS", "_client_type", "_client_version", "alt", "chunkNo", "forum_name",
        "groupId", "height", "isFinish", "is_bjh", "pic_water_type", "resourceId",
        "saveOrigin", "sign", "size", "small_flow_fname", "width",
      ])
    )
    XCTAssertEqual(parsed.fields["BDUSS"], credential.bduss)
    XCTAssertEqual(parsed.fields["_client_type"], "2")
    XCTAssertEqual(parsed.fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(parsed.fields["alt"], "json")
    XCTAssertEqual(parsed.fields["chunkNo"], "1")
    XCTAssertEqual(parsed.fields["forum_name"], "swift")
    XCTAssertEqual(parsed.fields["groupId"], "1")
    XCTAssertEqual(parsed.fields["height"], "1080")
    XCTAssertEqual(parsed.fields["isFinish"], "1")
    XCTAssertEqual(parsed.fields["is_bjh"], "0")
    XCTAssertEqual(parsed.fields["pic_water_type"], "1")
    XCTAssertEqual(
      parsed.fields["resourceId"],
      "900150983cd24fb0d6963f7d28e17f72512000"
    )
    XCTAssertEqual(plan.resourceID, parsed.fields["resourceId"])
    XCTAssertEqual(
      plan.contentSHA256,
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    XCTAssertEqual(parsed.fields["saveOrigin"], "1")
    XCTAssertEqual(parsed.fields["size"], "3")
    XCTAssertEqual(parsed.fields["small_flow_fname"], "swift")
    XCTAssertEqual(parsed.fields["width"], "1920")

    let unsigned = parsed.fields
      .filter { $0.key != "sign" }
      .map { ($0.key, $0.value) }
    XCTAssertEqual(parsed.fields["sign"], TiebaFormSigner.signature(for: unsigned))
    for forbidden in [
      "stoken", "CUID", "cuid", "cuid_galaxy2", "cuid_gid", "IMEI", "_phone_imei",
      "model", "brand", "android_id", "oaid", "timestamp", "_timestamp", "client_id",
      "_client_id", "device_score", "scr_h", "scr_w", "net_type",
    ] {
      XCTAssertNil(parsed.fields[forbidden], "Unexpected device field: \(forbidden)")
    }
    XCTAssertTrue(parsed.fields.values.allSatisfy { !$0.contains(parsed.boundary) })
  }

  func testChunkBoundariesAreSequentialAndExact() throws {
    for (byteCount, expectedChunkSizes) in [
      (511_999, [511_999]),
      (512_000, [512_000]),
      (512_001, [512_000, 1]),
    ] {
      var bytes = Data(repeating: 0xA5, count: byteCount)
      if byteCount > TiebaStaticImageUploadPolicy.chunkSize {
        bytes[TiebaStaticImageUploadPolicy.chunkSize] = 0x5A
      }
      let upload = makeStaticImageUpload(bytes: bytes)
      let plan = try validatedPlan(upload)
      XCTAssertEqual(plan.chunkCount, expectedChunkSizes.count)
      var reconstructed = Data()
      for chunkNumber in 1...plan.chunkCount {
        let request = try factory.staticImageUploadChunk(
          credential: staticImageCredential(),
          expectedUserID: 1_001,
          plan: plan,
          chunkNumber: chunkNumber
        )
        let parsed = try parseStaticImageMultipart(request)
        XCTAssertEqual(parsed.chunk.count, expectedChunkSizes[chunkNumber - 1])
        XCTAssertEqual(parsed.fields["chunkNo"], String(chunkNumber))
        XCTAssertEqual(
          parsed.fields["isFinish"],
          chunkNumber == plan.chunkCount ? "1" : "0"
        )
        XCTAssertEqual(parsed.fields["resourceId"], plan.resourceID)
        reconstructed.append(parsed.chunk)
      }
      XCTAssertEqual(reconstructed, upload.encodedBytes)
    }
  }

  func testMultipartBoundaryIsPerRequestAndCannotBeTerminatedByChunkBytes() throws {
    let legacyBoundary = "--------7da3d81520810*"
    let bytes = Data(
      "prefix\r\n--\(legacyBoundary)\r\nContent-Disposition: form-data; name=\"chunkNo\"\r\n\r\n999"
        .utf8
    )
    let plan = try validatedPlan(makeStaticImageUpload(bytes: bytes))
    let firstRequest = try factory.staticImageUploadChunk(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      plan: plan,
      chunkNumber: 1
    )
    let secondRequest = try factory.staticImageUploadChunk(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      plan: plan,
      chunkNumber: 1
    )

    let first = try parseStaticImageMultipart(firstRequest)
    let second = try parseStaticImageMultipart(secondRequest)
    XCTAssertEqual(first.chunk, bytes)
    XCTAssertEqual(second.chunk, bytes)
    XCTAssertNotEqual(first.boundary, legacyBoundary)
    XCTAssertNotEqual(first.boundary, second.boundary)
    XCTAssertNil(bytes.range(of: Data(first.boundary.utf8)))
    XCTAssertNil(bytes.range(of: Data(second.boundary.utf8)))
    XCTAssertEqual(first.fields["chunkNo"], "1")
  }

  func testInputAndChunkValidationRejectsUnsafeValuesBeforeNetwork() throws {
    assertStaticImageClientError(.invalidArgument("Image data must not be empty.")) {
      _ = try validatedPlan(makeStaticImageUpload(bytes: Data()))
    }
    assertStaticImageClientError(
      .invalidArgument(
        "Image data exceeds the \(TiebaStaticImageUploadPolicy.maximumStandardImageBytes)-byte upload limit."
      )
    ) {
      _ = try validatedPlan(
        makeStaticImageUpload(
          bytes: Data(
            repeating: 0,
            count: TiebaStaticImageUploadPolicy.maximumStandardImageBytes + 1
          )
        )
      )
    }
    XCTAssertNoThrow(
      try validatedPlan(
        makeStaticImageUpload(
          bytes: Data(
            repeating: 0,
            count: TiebaStaticImageUploadPolicy.maximumStandardImageBytes
          )
        )
      )
    )
    XCTAssertNoThrow(
      try validatedPlan(
        makeStaticImageUpload(
          bytes: Data(
            repeating: 0,
            count: TiebaStaticImageUploadPolicy.maximumStandardImageBytes + 1
          ),
          preservesOriginal: true
        )
      )
    )
    assertStaticImageClientError(
      .invalidArgument(
        "Image data exceeds the \(TiebaStaticImageUploadPolicy.maximumOriginalImageBytes)-byte upload limit."
      )
    ) {
      _ = try validatedPlan(
        makeStaticImageUpload(
          bytes: Data(
            repeating: 0,
            count: TiebaStaticImageUploadPolicy.maximumOriginalImageBytes + 1
          ),
          preservesOriginal: true
        )
      )
    }
    XCTAssertNoThrow(
      try validatedPlan(
        makeStaticImageUpload(
          bytes: Data(
            repeating: 0,
            count: TiebaStaticImageUploadPolicy.maximumOriginalImageBytes
          ),
          preservesOriginal: true
        )
      )
    )
    for dimensions in [
      (0, 1),
      (1, 0),
      (TiebaStaticImageUploadPolicy.maximumPixelDimension + 1, 1),
      (1, TiebaStaticImageUploadPolicy.maximumPixelDimension + 1),
    ] {
      assertStaticImageClientError(
        .invalidArgument(
          "Image dimensions must be between 1 and \(TiebaStaticImageUploadPolicy.maximumPixelDimension) pixels."
        )
      ) {
        _ = try validatedPlan(
          makeStaticImageUpload(bytes: Data([1]), width: dimensions.0, height: dimensions.1)
        )
      }
    }
    assertStaticImageClientError(
      .invalidArgument("Forum name must contain between 1 and 100 non-control characters.")
    ) {
      _ = try validatedPlan(makeStaticImageUpload(bytes: Data([1]), forumName: " \n "))
    }

    let plan = try validatedPlan(makeStaticImageUpload(bytes: Data([1])))
    for chunkNumber in [0, 2] {
      assertStaticImageClientError(
        .invalidArgument("Image chunk number must be between 1 and 1.")
      ) {
        _ = try factory.staticImageUploadChunk(
          credential: staticImageCredential(),
          expectedUserID: 1_001,
          plan: plan,
          chunkNumber: chunkNumber
        )
      }
    }
  }

  private func validatedPlan(
    _ upload: TiebaStaticImageUpload
  ) throws -> TiebaStaticImageUploadPlan {
    try factory.validateStaticImageUploadArguments(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )
  }
}

final class TiebaStaticImageUploadDecoderTests: XCTestCase {
  private let factory = TiebaAuthenticatedRequestFactory(configuration: .init())

  func testDecoderBindsEveryChunkAndRequiresStrictFinalReceipt() throws {
    let upload = makeStaticImageUpload(
      bytes: Data(repeating: 0x11, count: 512_001),
      forumName: " swift ",
      width: 1_920,
      height: 1_080,
      preservesOriginal: true,
      watermark: .username
    )
    let plan = try factory.validateStaticImageUploadArguments(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )
    XCTAssertEqual(
      try TiebaStaticImageUploadDecoder.decodeChunkResponse(
        from: staticImageResponse(resourceID: plan.resourceID, chunkNumber: 1, isFinal: false),
        plan: plan,
        chunkNumber: 1
      ),
      .accepted
    )
    let result = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
      from: staticImageResponse(resourceID: plan.resourceID, chunkNumber: 2, isFinal: true),
      plan: plan,
      chunkNumber: 2
    )
    guard case .completed(let receipt) = result else {
      return XCTFail("Expected final image receipt")
    }
    XCTAssertEqual(receipt.uploadID, upload.uploadID)
    XCTAssertEqual(receipt.schemaVersion, TiebaStaticImageUploadReceipt.currentSchemaVersion)
    XCTAssertEqual(receipt.contentSHA256, plan.contentSHA256)
    XCTAssertEqual(receipt.userID, 1_001)
    XCTAssertEqual(receipt.forumName, "swift")
    XCTAssertTrue(receipt.preservesOriginal)
    XCTAssertEqual(receipt.watermark, .username)
    XCTAssertEqual(receipt.uploadedPixelWidth, upload.pixelWidth)
    XCTAssertEqual(receipt.uploadedPixelHeight, upload.pixelHeight)
    XCTAssertEqual(receipt.resourceID, plan.resourceID)
    XCTAssertEqual(receipt.picID, String(repeating: "a", count: 40))
    XCTAssertEqual(receipt.width, 640)
    XCTAssertEqual(receipt.height, 480)
    XCTAssertEqual(receipt.byteCount, 512_001)
    XCTAssertEqual(receipt.chunkCount, 2)
    XCTAssertTrue(receipt.isBound(to: upload, expectedUserID: 1_001))

    let encoded = try JSONEncoder().encode(receipt)
    XCTAssertEqual(
      try JSONDecoder().decode(TiebaStaticImageUploadReceipt.self, from: encoded), receipt)
  }

  func testDecoderRejectsMalformedTypesBindingsAndFinalFields() throws {
    let upload = makeStaticImageUpload(bytes: Data([1]))
    let plan = try factory.validateStaticImageUploadArguments(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )
    let invalidObjects: [[String: Any]] = [
      ["error_code": 0, "error_msg": "", "resourceId": plan.resourceID, "chunkNo": "1"],
      ["error_code": "00", "error_msg": "", "resourceId": plan.resourceID, "chunkNo": "1"],
      ["error_code": "0", "error_msg": "", "resourceId": "wrong", "chunkNo": "1"],
      ["error_code": "0", "error_msg": "", "resourceId": plan.resourceID, "chunkNo": "01"],
      [
        "error_code": "340006", "error_msg": "rejected", "resourceId": "wrong",
        "chunkNo": "1",
      ],
      [
        "error_code": "340006", "error_msg": "rejected", "resourceId": plan.resourceID,
        "chunkNo": "2",
      ],
      finalStaticImageObject(resourceID: plan.resourceID, picID: "1"),
      finalStaticImageObject(resourceID: plan.resourceID, width: 0),
      finalStaticImageObject(
        resourceID: plan.resourceID,
        height: TiebaStaticImageUploadPolicy.maximumPixelDimension + 1
      ),
      [
        "error_code": "0", "error_msg": "", "resourceId": plan.resourceID,
        "chunkNo": "1", "picId": String(repeating: "a", count: 40),
      ],
    ]
    for object in invalidObjects {
      assertStaticImageClientError(.invalidAuthenticatedResponse) {
        _ = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
          from: try JSONSerialization.data(withJSONObject: object),
          plan: plan,
          chunkNumber: 1
        )
      }
    }
    assertStaticImageClientError(.invalidJSON) {
      _ = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
        from: Data("{".utf8),
        plan: plan,
        chunkNumber: 1
      )
    }
    assertStaticImageClientError(
      .responseTooLarge(maximumBytes: TiebaStaticImageUploadPolicy.maximumResponseBodyBytes)
    ) {
      _ = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
        from: Data(
          repeating: 0,
          count: TiebaStaticImageUploadPolicy.maximumResponseBodyBytes + 1
        ),
        plan: plan,
        chunkNumber: 1
      )
    }
  }

  func testDecoderPreservesDefinitiveServerError() throws {
    let plan = try factory.validateStaticImageUploadArguments(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: makeStaticImageUpload(bytes: Data([1]))
    )
    let errorObjects: [[String: Any]] = [
      ["error_code": "340006", "error_msg": "upload rejected"],
      [
        "error_code": "340006", "error_msg": "upload rejected",
        "resourceId": NSNull(), "chunkNo": NSNull(),
      ],
      [
        "error_code": "340006", "error_msg": "upload rejected",
        "resourceId": plan.resourceID,
      ],
      [
        "error_code": "340006", "error_msg": "upload rejected",
        "resourceId": plan.resourceID, "chunkNo": "1",
      ],
    ]
    for object in errorObjects {
      assertStaticImageClientError(.server(code: 340_006, message: "upload rejected")) {
        _ = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
          from: try JSONSerialization.data(withJSONObject: object),
          plan: plan,
          chunkNumber: 1
        )
      }
    }
  }

  func testReceiptCodableRejectsTamperedCheckpoint() throws {
    let valid: [String: Any] = [
      "schemaVersion": TiebaStaticImageUploadReceipt.currentSchemaVersion,
      "uploadID": UUID().uuidString,
      "contentSHA256": String(repeating: "c", count: 64),
      "userID": 1_001,
      "forumName": "swift",
      "preservesOriginal": true,
      "watermark": "2",
      "uploadedPixelWidth": 640,
      "uploadedPixelHeight": 480,
      "resourceID": String(repeating: "b", count: 32) + "512000",
      "picID": String(repeating: "a", count: 40),
      "width": 640,
      "height": 480,
      "byteCount": 512_001,
      "chunkCount": 2,
    ]
    XCTAssertNoThrow(
      try JSONDecoder().decode(
        TiebaStaticImageUploadReceipt.self,
        from: JSONSerialization.data(withJSONObject: valid)
      )
    )
    for mutation in [
      ["schemaVersion": TiebaStaticImageUploadReceipt.currentSchemaVersion + 1],
      ["contentSHA256": String(repeating: "C", count: 64)],
      ["contentSHA256": String(repeating: "c", count: 63)],
      ["userID": 0],
      ["forumName": " swift"],
      ["forumName": "e\u{301}"],
      ["watermark": "9"],
      ["uploadedPixelWidth": 0],
      ["uploadedPixelHeight": TiebaStaticImageUploadPolicy.maximumPixelDimension + 1],
      ["resourceID": "invalid"],
      ["picID": String(repeating: "A", count: 40)],
      ["width": 0],
      ["byteCount": 512_001, "chunkCount": 1],
    ] {
      var object = valid
      for (key, value) in mutation { object[key] = value }
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          TiebaStaticImageUploadReceipt.self,
          from: JSONSerialization.data(withJSONObject: object)
        )
      )
    }

    var oversizedStandard = valid
    oversizedStandard["preservesOriginal"] = false
    oversizedStandard["byteCount"] =
      TiebaStaticImageUploadPolicy.maximumStandardImageBytes + 1
    oversizedStandard["chunkCount"] =
      (TiebaStaticImageUploadPolicy.maximumStandardImageBytes
        / TiebaStaticImageUploadPolicy.chunkSize) + 1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        TiebaStaticImageUploadReceipt.self,
        from: JSONSerialization.data(withJSONObject: oversizedStandard)
      )
    )

    var missingSchema = valid
    missingSchema.removeValue(forKey: "schemaVersion")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        TiebaStaticImageUploadReceipt.self,
        from: JSONSerialization.data(withJSONObject: missingSchema)
      )
    )
  }

  func testReceiptSemanticBindingRejectsStructurallyValidFieldReplacement() throws {
    let upload = makeStaticImageUpload(
      bytes: Data(repeating: 0x11, count: 512_001),
      forumName: " swift ",
      preservesOriginal: true,
      watermark: .forumName
    )
    let plan = try factory.validateStaticImageUploadArguments(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )
    let result = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
      from: staticImageResponse(resourceID: plan.resourceID, chunkNumber: 2, isFinal: true),
      plan: plan,
      chunkNumber: 2
    )
    guard case .completed(let receipt) = result else {
      return XCTFail("Expected final image receipt")
    }
    XCTAssertTrue(receipt.isBound(to: upload, expectedUserID: 1_001))
    XCTAssertFalse(receipt.isBound(to: upload, expectedUserID: 2_002))

    let encoded = try JSONEncoder().encode(receipt)
    let valid = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let replacements: [[String: Any]] = [
      ["uploadID": UUID().uuidString],
      ["contentSHA256": String(repeating: "d", count: 64)],
      ["userID": 2_002],
      ["forumName": "other-forum"],
      ["preservesOriginal": false],
      ["watermark": TiebaStaticImageWatermark.username.rawValue],
      ["uploadedPixelWidth": upload.pixelWidth + 1],
      ["uploadedPixelHeight": upload.pixelHeight + 1],
      ["resourceID": String(repeating: "a", count: 32) + "512000"],
      ["byteCount": 512_000, "chunkCount": 1],
    ]
    for replacement in replacements {
      var object = valid
      for (key, value) in replacement { object[key] = value }
      let decoded = try JSONDecoder().decode(
        TiebaStaticImageUploadReceipt.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
      XCTAssertFalse(decoded.isBound(to: upload, expectedUserID: 1_001), "\(replacement)")
    }
  }
}

final class TiebaStaticImageUploadClientTests: XCTestCase, @unchecked Sendable {
  func testCallerCancelledBeforeFlightRegistrationNeverDispatches() async {
    let gate = StaticImageStartGate()
    let transport = StaticImageUploadTransport()
    let client = TiebaAuthenticatedClient(transport: transport)
    let upload = makeStaticImageUpload(bytes: Data([1]))
    let caller = Task {
      await gate.wait()
      return try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: upload
      )
    }

    caller.cancel()
    await gate.release()
    do {
      _ = try await caller.value
      XCTFail("Expected pre-registration cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let snapshot = await transport.snapshot()
    let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
    XCTAssertTrue(snapshot.requests.isEmpty)
    XCTAssertTrue(snapshot.preflightRequests.isEmpty)
    XCTAssertEqual(retainedFlightCount, 0)
  }

  func testPreflightAccountMismatchNeverDispatchesAnUploadChunk() async {
    let transport = StaticImageUploadTransport(sessionUserID: 2_002)
    let client = TiebaAuthenticatedClient(transport: transport)
    let upload = makeStaticImageUpload(bytes: Data([1]))

    await assertStaticImageAsyncClientError(.invalidAuthenticatedResponse) {
      _ = try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: upload
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertTrue(snapshot.requests.isEmpty)
    XCTAssertEqual(
      snapshot.preflightRequests.map { $0.url?.path },
      ["/c/s/login", "/mo/q/newmoindex"]
    )
    let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
    XCTAssertEqual(retainedFlightCount, 0)
  }

  func testLastWaiterCancellationDuringPreflightCancelsBeforeUploadDispatch() async {
    let transport = StaticImageUploadTransport(behavior: .blockedPreflight)
    let client = TiebaAuthenticatedClient(transport: transport)
    let upload = makeStaticImageUpload(bytes: Data([1]))
    let caller = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: upload
      )
    }
    guard
      await eventuallyStaticImage({
        let snapshot = await transport.snapshot()
        let waiterCount = await client.staticImageUploadWaiterCount(uploadID: upload.uploadID)
        return snapshot.preflightRequests.count == 1 && waiterCount == 1
      })
    else {
      caller.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Image upload did not enter preflight")
    }

    caller.cancel()
    do {
      _ = try await caller.value
      XCTFail("Expected preflight cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    await transport.releaseBlockedRequests()
    guard
      await eventuallyStaticImage({
        await transport.snapshot().preflightRequests.count == 1
      })
    else {
      return XCTFail("Cancelled preflight unexpectedly continued")
    }
    let snapshot = await transport.snapshot()
    XCTAssertTrue(snapshot.requests.isEmpty)
    let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
    XCTAssertEqual(retainedFlightCount, 0)
  }

  func testClientUploadsSequentialChunksWithBoundedResponsesAndRetainsReceipt() async throws {
    let transport = StaticImageUploadTransport()
    let client = TiebaAuthenticatedClient(transport: transport)
    let upload = makeStaticImageUpload(bytes: Data(repeating: 0x4A, count: 512_001))

    let first = try await client.uploadStaticImage(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )
    let retained = try await client.uploadStaticImage(
      credential: staticImageCredential(),
      expectedUserID: 1_001,
      upload: upload
    )

    XCTAssertEqual(first, retained)
    XCTAssertEqual(first.uploadID, upload.uploadID)
    XCTAssertEqual(first.userID, 1_001)
    XCTAssertEqual(first.forumName, "swift")
    XCTAssertEqual(first.contentSHA256.utf8.count, 64)
    XCTAssertEqual(first.picID, String(repeating: "a", count: 40))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.preflightRequests.map { $0.url?.path },
      ["/c/s/login", "/mo/q/newmoindex"]
    )
    XCTAssertEqual(
      snapshot.preflightMaximumBodyBytes.compactMap { $0 },
      [
        TiebaAuthenticatedClient.accountResponseMaximumBytes,
        TiebaAuthenticatedClient.webSessionResponseMaximumBytes,
      ]
    )
    XCTAssertEqual(snapshot.requests.count, 2)
    XCTAssertEqual(snapshot.chunkNumbers, [1, 2])
    XCTAssertEqual(snapshot.chunkByteCounts, [512_000, 1])
    XCTAssertEqual(
      snapshot.maximumBodyBytes.compactMap { $0 },
      [
        TiebaAuthenticatedClient.staticImageUploadResponseMaximumBytes,
        TiebaAuthenticatedClient.staticImageUploadResponseMaximumBytes,
      ]
    )
    let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
    XCTAssertEqual(retainedFlightCount, 1)
  }

  func testPostDispatchFailuresAreUnknownAndNeverRetried() async {
    let cases: [(StaticImageUploadTransport.Behavior, Int, Int)] = [
      (.networkFailure(chunk: 1), 1, 1),
      (.malformedResponse(chunk: 1), 1, 1),
      (.oversizedResponse(chunk: 1), 1, 1),
      (.malformedResponse(chunk: 2), 2, 2),
    ]
    for (behavior, failedChunk, expectedRequestCount) in cases {
      let transport = StaticImageUploadTransport(behavior: behavior)
      let client = TiebaAuthenticatedClient(transport: transport)
      let upload = makeStaticImageUpload(bytes: Data(repeating: 0x7A, count: 512_001))
      let expected = TiebaClientError.staticImageUploadOutcomeUnknown(
        uploadID: upload.uploadID,
        dispatchedChunk: failedChunk
      )
      for _ in 0..<2 {
        await assertStaticImageAsyncClientError(expected) {
          _ = try await client.uploadStaticImage(
            credential: staticImageCredential(),
            expectedUserID: 1_001,
            upload: upload
          )
        }
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.requests.count, expectedRequestCount)
      let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
      XCTAssertEqual(retainedFlightCount, 1)
    }
  }

  func testDefinitiveServerFailureIsNotRetained() async {
    let transport = StaticImageUploadTransport(behavior: .serverFailure(chunk: 1))
    let client = TiebaAuthenticatedClient(transport: transport)
    let upload = makeStaticImageUpload(bytes: Data([1]))
    for _ in 0..<2 {
      await assertStaticImageAsyncClientError(.server(code: 340_006, message: "rejected")) {
        _ = try await client.uploadStaticImage(
          credential: staticImageCredential(),
          expectedUserID: 1_001,
          upload: upload
        )
      }
    }
    let requestCount = await transport.snapshot().requests.count
    let retainedFlightCount = await client.staticImageUploadRetainedFlightCountForTests()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(retainedFlightCount, 0)
  }

  func testEquivalentCallersShareFlightConflictIsRejectedAndCancellationKeepsDispatchAlive()
    async throws
  {
    let transport = StaticImageUploadTransport(behavior: .blocked(chunk: 1))
    let client = TiebaAuthenticatedClient(transport: transport)
    let uploadID = UUID()
    let upload = makeStaticImageUpload(id: uploadID, bytes: Data(repeating: 1, count: 64))
    let first = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: upload
      )
    }
    guard await eventuallyStaticImage({ await transport.snapshot().requests.count == 1 }) else {
      first.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Image upload was not dispatched")
    }
    let joined = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: upload
      )
    }
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadWaiterCount(uploadID: uploadID) == 2
      })
    else {
      first.cancel()
      joined.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Equivalent image upload did not join the flight")
    }

    await assertStaticImageAsyncClientError(.staticImageUploadIDConflict) {
      _ = try await client.uploadStaticImage(
        credential: staticImageCredential(stokenSeed: "t"),
        expectedUserID: 1_001,
        upload: upload
      )
    }
    await assertStaticImageAsyncClientError(.staticImageUploadIDConflict) {
      _ = try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: makeStaticImageUpload(id: uploadID, bytes: Data(repeating: 2, count: 64))
      )
    }

    first.cancel()
    do {
      _ = try await first.value
      XCTFail("Expected the first waiter to be cancelled")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let requestCountWhileBlocked = await transport.snapshot().requests.count
    XCTAssertEqual(requestCountWhileBlocked, 1)

    await transport.releaseBlockedRequests()
    let receipt = try await joined.value
    XCTAssertEqual(receipt.uploadID, uploadID)
    let completedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(completedRequestCount, 1)
  }

  func testLastWaiterCancellationAfterDispatchKeepsAccountLeaseUntilCompletion() async throws {
    let transport = StaticImageUploadTransport(behavior: .blocked(chunk: 1))
    let client = TiebaAuthenticatedClient(transport: transport)
    let firstUpload = makeStaticImageUpload(bytes: Data([1]))
    let nextUpload = makeStaticImageUpload(bytes: Data([2]))
    let first = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: firstUpload
      )
    }
    guard await eventuallyStaticImage({ await transport.snapshot().requests.count == 1 }) else {
      first.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("First upload was not dispatched")
    }

    first.cancel()
    do {
      _ = try await first.value
      XCTFail("Expected the sole waiter to be cancelled")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let next = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: nextUpload
      )
    }
    guard
      await eventuallyStaticImage({
        let queuedLeaseCount = await client.staticImageUploadQueuedLeaseCountForTests()
        let requestCount = await transport.snapshot().requests.count
        return queuedLeaseCount == 1 && requestCount == 1
      })
    else {
      next.cancel()
      await transport.releaseBlockedRequests()
      _ = try? await next.value
      return XCTFail("Next upload bypassed the in-flight post-dispatch owner")
    }

    await transport.releaseBlockedRequests()
    let receipt = try await next.value
    XCTAssertEqual(receipt.uploadID, nextUpload.uploadID)
    let completedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(completedRequestCount, 2)
  }

  func testSameAccountLeaseSerializesAndQueuedCancellationAllowsSafeSameIDRetry() async throws {
    let transport = StaticImageUploadTransport(behavior: .blocked(chunk: 1))
    let client = TiebaAuthenticatedClient(transport: transport)
    let firstUpload = makeStaticImageUpload(bytes: Data([1]))
    let queuedUpload = makeStaticImageUpload(bytes: Data([2]))
    let first = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: firstUpload
      )
    }
    guard await eventuallyStaticImage({ await transport.snapshot().requests.count == 1 }) else {
      first.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("First upload did not acquire the account lease")
    }
    let queued = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: queuedUpload
      )
    }
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadWaiterCount(uploadID: queuedUpload.uploadID) == 1
      })
    else {
      first.cancel()
      queued.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Second upload was not queued")
    }
    let queuedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(queuedRequestCount, 1)

    queued.cancel()
    do {
      _ = try await queued.value
      XCTFail("Expected queued upload cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let replacement = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: queuedUpload
      )
    }
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadWaiterCount(uploadID: queuedUpload.uploadID) == 1
      })
    else {
      first.cancel()
      replacement.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Same-ID retry joined the cancelled flight")
    }
    let replacementQueuedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(replacementQueuedRequestCount, 1)

    await transport.releaseBlockedRequests()
    _ = try await first.value
    let replacementReceipt = try await replacement.value
    XCTAssertEqual(replacementReceipt.uploadID, queuedUpload.uploadID)
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadWaiterCount(uploadID: queuedUpload.uploadID) == 0
      })
    else {
      return XCTFail("Cancelled queued flight was not cleared")
    }
    let completedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(completedRequestCount, 2)
  }

  func testRepeatedQueuedCancellationImmediatelyRemovesLeaseAndPayloadState() async throws {
    let transport = StaticImageUploadTransport(behavior: .blocked(chunk: 1))
    let client = TiebaAuthenticatedClient(transport: transport)
    let firstUpload = makeStaticImageUpload(bytes: Data([1]))
    let first = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: firstUpload
      )
    }
    guard await eventuallyStaticImage({ await transport.snapshot().requests.count == 1 }) else {
      first.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("First upload did not acquire the account lease")
    }

    for index in 0..<8 {
      let byteCount = 128 * 1_024
      let upload = makeStaticImageUpload(
        bytes: Data(repeating: UInt8(index + 2), count: byteCount)
      )
      let queued = Task {
        try await client.uploadStaticImage(
          credential: staticImageCredential(),
          expectedUserID: 1_001,
          upload: upload
        )
      }
      guard
        await eventuallyStaticImage({
          let queuedLeaseCount = await client.staticImageUploadQueuedLeaseCountForTests()
          let activeFlightCount = await client.staticImageUploadActiveFlightCountForTests()
          return queuedLeaseCount == 1 && activeFlightCount == 2
        })
      else {
        queued.cancel()
        first.cancel()
        await transport.releaseBlockedRequests()
        return XCTFail("Upload \(index) did not enter the account lease queue")
      }

      queued.cancel()
      do {
        _ = try await queued.value
        XCTFail("Expected queued upload cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected CancellationError, got \(error)")
      }
      guard
        await eventuallyStaticImage({
          let queuedLeaseCount = await client.staticImageUploadQueuedLeaseCountForTests()
          let activeFlightCount = await client.staticImageUploadActiveFlightCountForTests()
          let activeByteCount = await client.staticImageUploadActiveFlightByteCountForTests()
          return queuedLeaseCount == 0
            && activeFlightCount == 1
            && activeByteCount == firstUpload.encodedBytes.count
        })
      else {
        first.cancel()
        await transport.releaseBlockedRequests()
        return XCTFail("Cancelled upload \(index) retained queued payload state")
      }
    }

    let requestCountBeforeRelease = await transport.snapshot().requests.count
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await transport.releaseBlockedRequests()
    _ = try await first.value
  }

  func testCancellationCrossingLeaseGrantReleasesOwnerForNextUpload() async throws {
    let firstUpload = makeStaticImageUpload(bytes: Data([1]))
    let crossingUpload = makeStaticImageUpload(bytes: Data([2]))
    let nextUpload = makeStaticImageUpload(bytes: Data([3]))
    let grantGate = StaticImageLeaseGrantGate(targetUploadID: crossingUpload.uploadID)
    let transport = StaticImageUploadTransport(behavior: .blocked(chunk: 1))
    let client = TiebaAuthenticatedClient(
      transport: transport,
      staticImageUploadLeaseAcquired: { uploadID in
        await grantGate.pauseIfTarget(uploadID)
      }
    )
    let first = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: firstUpload
      )
    }
    guard await eventuallyStaticImage({ await transport.snapshot().requests.count == 1 }) else {
      first.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("First upload did not acquire the account lease")
    }
    let crossing = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: crossingUpload
      )
    }
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadQueuedLeaseCountForTests() == 1
      })
    else {
      first.cancel()
      crossing.cancel()
      await transport.releaseBlockedRequests()
      return XCTFail("Crossing upload did not enter the account lease queue")
    }

    await transport.releaseBlockedRequests()
    guard await eventuallyStaticImage({ await grantGate.hasEntered }) else {
      crossing.cancel()
      await grantGate.release()
      _ = try? await first.value
      _ = try? await crossing.value
      return XCTFail("Crossing upload was not paused after lease grant")
    }
    crossing.cancel()
    let next = Task {
      try await client.uploadStaticImage(
        credential: staticImageCredential(),
        expectedUserID: 1_001,
        upload: nextUpload
      )
    }
    guard
      await eventuallyStaticImage({
        await client.staticImageUploadQueuedLeaseCountForTests() == 1
      })
    else {
      next.cancel()
      await grantGate.release()
      _ = try? await first.value
      _ = try? await crossing.value
      _ = try? await next.value
      return XCTFail("Next upload did not wait behind the granted flight")
    }
    await grantGate.release()
    do {
      _ = try await crossing.value
      XCTFail("Expected crossing upload cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    _ = try await first.value
    let receipt = try await next.value
    XCTAssertEqual(receipt.uploadID, nextUpload.uploadID)
    let completedRequestCount = await transport.snapshot().requests.count
    XCTAssertEqual(completedRequestCount, 2)
    let didSettle = await eventuallyStaticImage({
      let queuedLeaseCount = await client.staticImageUploadQueuedLeaseCountForTests()
      let activeFlightCount = await client.staticImageUploadActiveFlightCountForTests()
      return queuedLeaseCount == 0 && activeFlightCount == 0
    })
    XCTAssertTrue(didSettle)
  }
}

private actor StaticImageStartGate {
  private var isReleased = false
  private var waiters = [CheckedContinuation<Void, Never>]()

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      if isReleased {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func release() {
    isReleased = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor StaticImageLeaseGrantGate {
  private let targetUploadID: UUID
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var hasEntered = false
  private var isReleased = false

  init(targetUploadID: UUID) {
    self.targetUploadID = targetUploadID
  }

  func pauseIfTarget(_ uploadID: UUID) async {
    guard uploadID == targetUploadID, !isReleased else { return }
    hasEntered = true
    await withCheckedContinuation { continuation in
      if isReleased {
        continuation.resume()
      } else {
        self.continuation = continuation
      }
    }
  }

  func release() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}

private actor StaticImageUploadTransport: TiebaTransport {
  enum Behavior: Sendable {
    case success
    case blockedPreflight
    case networkFailure(chunk: Int)
    case malformedResponse(chunk: Int)
    case oversizedResponse(chunk: Int)
    case serverFailure(chunk: Int)
    case blocked(chunk: Int)
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
    let chunkNumbers: [Int]
    let chunkByteCounts: [Int]
    let preflightRequests: [URLRequest]
    let preflightMaximumBodyBytes: [Int?]
  }

  private let behavior: Behavior
  private let sessionUserID: Int64
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()
  private var chunkNumbers = [Int]()
  private var chunkByteCounts = [Int]()
  private var preflightRequests = [URLRequest]()
  private var preflightMaximumBodyBytes = [Int?]()
  private var blockedContinuations = [CheckedContinuation<Void, Never>]()
  private var releasesBlockedRequests = false

  init(behavior: Behavior = .success, sessionUserID: Int64 = 1_001) {
    self.behavior = behavior
    self.sessionUserID = sessionUserID
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    if request.url?.path == "/c/s/login" || request.url?.path == "/mo/q/newmoindex" {
      preflightRequests.append(request)
      preflightMaximumBodyBytes.append(maximumBodyBytes)
      if case .blockedPreflight = behavior, !releasesBlockedRequests {
        await withCheckedContinuation { continuation in
          if releasesBlockedRequests {
            continuation.resume()
          } else {
            blockedContinuations.append(continuation)
          }
        }
      }
      let body =
        request.url?.path == "/c/s/login"
        ? staticImageAppAccountResponse(userID: sessionUserID)
        : staticImageWebAccountResponse(userID: sessionUserID)
      return TiebaHTTPResponse(body: body, statusCode: 200)
    }

    let parsed = try parseStaticImageMultipart(request)
    guard
      let rawChunkNumber = parsed.fields["chunkNo"],
      let chunkNumber = Int(rawChunkNumber),
      let resourceID = parsed.fields["resourceId"]
    else {
      throw StaticImageTestError.malformedMultipart
    }
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    chunkNumbers.append(chunkNumber)
    chunkByteCounts.append(parsed.chunk.count)

    if case .blocked(let blockedChunk) = behavior,
      blockedChunk == chunkNumber,
      !releasesBlockedRequests
    {
      await withCheckedContinuation { continuation in
        if releasesBlockedRequests {
          continuation.resume()
        } else {
          blockedContinuations.append(continuation)
        }
      }
    }

    switch behavior {
    case .networkFailure(let failedChunk) where failedChunk == chunkNumber:
      throw URLError(.timedOut)
    case .malformedResponse(let failedChunk) where failedChunk == chunkNumber:
      return TiebaHTTPResponse(body: Data("{".utf8), statusCode: 200)
    case .oversizedResponse(let failedChunk) where failedChunk == chunkNumber:
      return TiebaHTTPResponse(
        body: Data(repeating: 0, count: (maximumBodyBytes ?? 65_536) + 1),
        statusCode: 200
      )
    case .serverFailure(let failedChunk) where failedChunk == chunkNumber:
      return TiebaHTTPResponse(
        body: try JSONSerialization.data(
          withJSONObject: [
            "error_code": "340006",
            "error_msg": "rejected",
            "resourceId": resourceID,
            "chunkNo": String(chunkNumber),
          ]
        ),
        statusCode: 200
      )
    default:
      return TiebaHTTPResponse(
        body: staticImageResponse(
          resourceID: resourceID,
          chunkNumber: chunkNumber,
          isFinal: parsed.fields["isFinish"] == "1"
        ),
        statusCode: 200
      )
    }
  }

  func releaseBlockedRequests() {
    releasesBlockedRequests = true
    let continuations = blockedContinuations
    blockedContinuations.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      requests: requests,
      maximumBodyBytes: maximumBodyBytes,
      chunkNumbers: chunkNumbers,
      chunkByteCounts: chunkByteCounts,
      preflightRequests: preflightRequests,
      preflightMaximumBodyBytes: preflightMaximumBodyBytes
    )
  }
}

private struct ParsedStaticImageMultipart {
  let boundary: String
  let fields: [String: String]
  let chunk: Data
}

private enum StaticImageTestError: Error {
  case malformedMultipart
}

private func parseStaticImageMultipart(_ request: URLRequest) throws -> ParsedStaticImageMultipart {
  let contentTypePrefix = "multipart/form-data; boundary="
  guard
    let body = request.httpBody,
    let contentType = request.value(forHTTPHeaderField: "Content-Type"),
    contentType.hasPrefix(contentTypePrefix)
  else { throw StaticImageTestError.malformedMultipart }
  let boundary = String(contentType.dropFirst(contentTypePrefix.count))
  guard
    !boundary.isEmpty,
    !boundary.contains("\r"),
    !boundary.contains("\n"),
    body.starts(with: Data("--\(boundary)\r\n".utf8))
  else { throw StaticImageTestError.malformedMultipart }
  let chunkMarker = Data(
    "--\(boundary)\r\n"
      .appending("Content-Disposition: form-data; name=\"chunk\"; filename=\"file\"\r\n\r\n")
      .utf8
  )
  let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
  guard
    let chunkMarkerRange = body.range(of: chunkMarker),
    body.suffix(suffix.count) == suffix,
    let scalarText = String(data: body[..<chunkMarkerRange.lowerBound], encoding: .utf8)
  else {
    throw StaticImageTestError.malformedMultipart
  }
  let fieldNamePrefix = "Content-Disposition: form-data; name=\""
  let fieldNameSuffix = "\"\r\n\r\n"
  var fields = [String: String]()
  for part in scalarText.components(separatedBy: "--\(boundary)\r\n") {
    if part.isEmpty { continue }
    guard
      part.hasPrefix(fieldNamePrefix),
      let nameEnd = part.range(of: fieldNameSuffix),
      part.hasSuffix("\r\n")
    else { throw StaticImageTestError.malformedMultipart }
    let nameStart = part.index(part.startIndex, offsetBy: fieldNamePrefix.count)
    let name = String(part[nameStart..<nameEnd.lowerBound])
    guard fields[name] == nil else { throw StaticImageTestError.malformedMultipart }
    fields[name] = String(part[nameEnd.upperBound...].dropLast())
  }
  let chunkEnd = body.count - suffix.count
  return ParsedStaticImageMultipart(
    boundary: boundary,
    fields: fields,
    chunk: body.subdata(in: chunkMarkerRange.upperBound..<chunkEnd)
  )
}

private func makeStaticImageUpload(
  id: UUID = UUID(),
  bytes: Data,
  forumName: String = "swift",
  width: Int = 640,
  height: Int = 480,
  preservesOriginal: Bool = false,
  watermark: TiebaStaticImageWatermark = .forumName
) -> TiebaStaticImageUpload {
  TiebaStaticImageUpload(
    uploadID: id,
    forumName: forumName,
    encodedBytes: bytes,
    pixelWidth: width,
    pixelHeight: height,
    preservesOriginal: preservesOriginal,
    watermark: watermark
  )
}

private func staticImageCredential(
  _ seed: Character = "b",
  stokenSeed: Character = "s"
) -> TiebaSessionCredential {
  TiebaSessionCredential(
    bduss: String(repeating: seed, count: 192),
    stoken: String(repeating: stokenSeed, count: 64),
    bdussCookieName: .bduss
  )
}

private func staticImageResponse(
  resourceID: String,
  chunkNumber: Int,
  isFinal: Bool
) -> Data {
  let object: [String: Any]
  if isFinal {
    object = finalStaticImageObject(resourceID: resourceID, chunkNumber: chunkNumber)
  } else {
    object = [
      "error_code": "0",
      "error_msg": "",
      "resourceId": resourceID,
      "chunkNo": String(chunkNumber),
    ]
  }
  return try! JSONSerialization.data(withJSONObject: object)
}

private func staticImageAppAccountResponse(userID: Int64) -> Data {
  try! JSONSerialization.data(withJSONObject: [
    "error_code": 0,
    "user": [
      "id": String(userID),
      "name": "account-name",
      "portrait": "portrait-token",
    ],
  ])
}

private func staticImageWebAccountResponse(userID: Int64) -> Data {
  try! JSONSerialization.data(withJSONObject: [
    "no": 0,
    "data": ["id": String(userID)],
  ])
}

private func finalStaticImageObject(
  resourceID: String,
  chunkNumber: Int = 1,
  picID: String = String(repeating: "a", count: 40),
  width: Int = 640,
  height: Int = 480
) -> [String: Any] {
  [
    "error_code": "0",
    "error_msg": "",
    "resourceId": resourceID,
    "chunkNo": String(chunkNumber),
    "picId": picID,
    "picInfo": [
      "originPic": [
        "width": String(width),
        "height": String(height),
        "type": "jpg",
        "picUrl": "https://tiebapic.baidu.com/forum/pic/item/\(picID).jpg",
      ]
    ],
  ]
}

private func assertStaticImageClientError(
  _ expected: TiebaClientError,
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () throws -> Void
) {
  do {
    try operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as TiebaClientError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Expected TiebaClientError, got \(error)", file: file, line: line)
  }
}

private func assertStaticImageAsyncClientError(
  _ expected: TiebaClientError,
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as TiebaClientError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Expected TiebaClientError, got \(error)", file: file, line: line)
  }
}

private func eventuallyStaticImage(
  _ condition: () async -> Bool,
  timeout: Duration = .seconds(2)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    await Task.yield()
  }
  return await condition()
}
