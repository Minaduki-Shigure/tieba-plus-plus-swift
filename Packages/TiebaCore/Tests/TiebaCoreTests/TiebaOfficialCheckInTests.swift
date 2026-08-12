import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaOfficialCheckInTests: XCTestCase {
  private let userID: Int64 = 957_339_815
  private let tbs = "91be894d01799c4991be894d01"

  func testRequestFactoryUsesMinimalSignedHTTPSContracts() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let credential = sessionCredential()

    let eligibility = try factory.officialCheckInEligibility(
      credential: credential,
      expectedUserID: userID
    )
    XCTAssertEqual(
      eligibility.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/forum/getforumlist"
    )
    XCTAssertEqual(eligibility.httpMethod, "POST")
    XCTAssertFalse(eligibility.httpShouldHandleCookies)
    XCTAssertEqual(eligibility.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      eligibility.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 11.10.8.6"
    )
    let eligibilityFields = try formFields(eligibility)
    XCTAssertEqual(
      Set(eligibilityFields.keys),
      ["BDUSS", "_client_version", "sign", "stoken", "user_id"]
    )
    XCTAssertEqual(eligibilityFields["BDUSS"], credential.bduss)
    XCTAssertEqual(eligibilityFields["stoken"], credential.stoken)
    XCTAssertEqual(eligibilityFields["user_id"], String(userID))
    assertSignature(in: eligibilityFields)

    let guide = try factory.officialCheckInGuide(
      credential: credential,
      expectedUserID: userID,
      tbs: tbs,
      page: 2,
      pageSize: 50
    )
    XCTAssertEqual(guide.url?.absoluteString, "https://tiebac.baidu.com/c/f/forum/forumGuide")
    XCTAssertEqual(guide.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      guide.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1"
    )
    let guideFields = try formFields(guide)
    XCTAssertEqual(
      Set(guideFields.keys),
      [
        "BDUSS", "_client_version", "call_from", "page_no", "res_num", "sign",
        "sort_type", "stoken", "tbs", "top_forum_num",
      ]
    )
    XCTAssertEqual(guideFields["page_no"], "2")
    XCTAssertEqual(guideFields["res_num"], "50")
    XCTAssertEqual(guideFields["call_from"], "3")
    XCTAssertEqual(guideFields["sort_type"], "3")
    XCTAssertEqual(guideFields["top_forum_num"], "0")
    XCTAssertEqual(guideFields["tbs"], tbs)
    assertSignature(in: guideFields)

    let batch = try factory.officialBatchCheckIn(
      credential: credential,
      expectedUserID: userID,
      tbs: tbs,
      forumIDs: [3, 1, 2]
    )
    XCTAssertEqual(batch.url?.absoluteString, "https://tiebac.baidu.com/c/c/forum/msign")
    XCTAssertEqual(batch.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(
      batch.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 11.10.8.6"
    )
    let batchFields = try formFields(batch)
    XCTAssertEqual(
      Set(batchFields.keys),
      [
        "BDUSS", "_client_version", "authsid", "forum_ids", "sign", "stoken", "tbs",
        "user_id",
      ]
    )
    XCTAssertEqual(batchFields["forum_ids"], "3,1,2")
    XCTAssertEqual(batchFields["authsid"], "null")
    XCTAssertEqual(batchFields["user_id"], String(userID))
    assertSignature(in: batchFields)

    for request in [eligibility, guide, batch] {
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertFalse(request.url?.absoluteString.contains(credential.bduss) ?? true)
      XCTAssertFalse(request.url?.absoluteString.contains(credential.stoken) ?? true)
      let fields = try formFields(request)
      for forbidden in [
        "_client_id", "_phone_imei", "android_id", "baiduid", "brand", "cuid", "model",
        "oaid", "sample_id", "timestamp",
      ] {
        XCTAssertNil(fields[forbidden])
      }
    }
  }

  func testRequestFactoryRejectsInvalidIdentityTBSAndBatchIDs() throws {
    let factory = TiebaAuthenticatedRequestFactory(configuration: .init())
    let credential = sessionCredential()
    XCTAssertThrowsError(
      try factory.officialCheckInEligibility(credential: credential, expectedUserID: 0)
    )
    XCTAssertThrowsError(
      try factory.officialCheckInGuide(
        credential: credential, expectedUserID: userID, tbs: "short", page: 1, pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.officialCheckInGuide(
        credential: credential, expectedUserID: userID, tbs: tbs, page: 0, pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.officialCheckInGuide(
        credential: credential, expectedUserID: userID, tbs: tbs, page: 1, pageSize: 101
      )
    )
    for ids in [[], [0], [1, 1], Array(1...101).map(Int64.init)] {
      XCTAssertThrowsError(
        try factory.officialBatchCheckIn(
          credential: credential,
          expectedUserID: userID,
          tbs: tbs,
          forumIDs: ids
        )
      )
    }
  }

  func testBatchIdentityDoesNotLeakCredentialsThroughDescriptionOrReflection() {
    let credential = sessionCredential()
    let values = TiebaAuthenticatedClient.officialBatchCheckInIdentityDebugValues(
      credential: credential
    )
    XCTAssertFalse(values.description.contains(credential.bduss))
    XCTAssertFalse(values.description.contains(credential.stoken))
    XCTAssertFalse(values.reflection.contains(credential.bduss))
    XCTAssertFalse(values.reflection.contains(credential.stoken))
    XCTAssertEqual(values.mirrorChildCount, 0)
  }

  func testCatalogContextDoesNotReflectFreshTBS() {
    let catalog = TiebaOfficialCheckInCatalog(
      userID: userID,
      forums: [],
      minimumBatchLevel: 4,
      maximumBatchCount: 5,
      isBatchCheckInAvailable: true
    )
    let context = TiebaOfficialCheckInCatalogContext(catalog: catalog, tbs: tbs)
    XCTAssertFalse(String(describing: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(
      Array(context.customMirror.children).contains { String(reflecting: $0.value).contains(tbs) }
    )
  }

  func testSessionContextBindsExpectedUserAndKeepsTBSPrivate() throws {
    let context = try TiebaOfficialCheckInDecoder.sessionContext(
      from: loginJSON(),
      expectedUserID: userID
    )
    XCTAssertEqual(context.userID, userID)
    XCTAssertFalse(String(describing: context).contains(tbs))
    XCTAssertFalse(String(reflecting: context).contains(tbs))
    XCTAssertFalse(
      Array(context.customMirror.children).contains { String(reflecting: $0.value).contains(tbs) }
    )

    XCTAssertThrowsError(
      try TiebaOfficialCheckInDecoder.sessionContext(
        from: loginJSON(userID: userID + 1),
        expectedUserID: userID
      )
    )
    XCTAssertThrowsError(
      try TiebaOfficialCheckInDecoder.sessionContext(
        from: loginJSON(tbs: String(repeating: "A", count: 26)),
        expectedUserID: userID
      )
    )
  }

  func testEligibilityRequiresBoundedStrictPolicyFields() throws {
    let value = try TiebaOfficialCheckInDecoder.eligibility(
      from: eligibilityJSON(minimumLevel: 4, maximumCount: 2)
    )
    XCTAssertEqual(value.minimumLevel, 4)
    XCTAssertEqual(value.maximumCount, 2)
    XCTAssertTrue(value.isAvailable)

    let disabled = try TiebaOfficialCheckInDecoder.eligibility(
      from: eligibilityJSON(minimumLevel: 4, maximumCount: 2, canUse: 0)
    )
    XCTAssertFalse(disabled.isAvailable)

    for body in [
      eligibilityJSON(minimumLevel: -1, maximumCount: 2),
      eligibilityJSON(minimumLevel: 4, maximumCount: 101),
      eligibilityJSON(minimumLevel: 4, maximumCount: 2, canUse: 2),
      Data(#"{"error_code":"0","level":"4"}"#.utf8),
    ] {
      XCTAssertThrowsError(
        try TiebaOfficialCheckInDecoder.eligibility(from: body)
      )
    }
  }

  func testGuideMapsTriStateAndRejectsDuplicateOrUnsafeEntries() throws {
    let page = try TiebaOfficialCheckInDecoder.guidePage(
      from: guideJSON(
        forums: [
          forumJSON(id: 1, name: " one ", level: 5, status: 0),
          forumJSON(id: 2, name: "two", level: 6, status: 1),
          forumJSON(id: 3, name: "three", level: 7, status: -1, forbidden: 1),
        ],
        hasMore: true,
        minimumLevel: 4
      ),
      expectedUserID: userID,
      requestedPage: 1,
      pageSize: 50
    )
    XCTAssertTrue(page.hasMore)
    XCTAssertTrue(page.isBatchCheckInAvailable)
    XCTAssertEqual(page.advertisedMinimumLevel, 4)
    XCTAssertEqual(page.forums.map(\.id), [1, 2, 3])
    XCTAssertEqual(page.forums.map(\.checkInStatus), [.pending, .checkedIn, .unknown])
    XCTAssertEqual(page.forums.first?.name, "one")
    XCTAssertTrue(page.forums.last?.isForbidden == true)

    for body in [
      guideJSON(forums: [forumJSON(id: 1), forumJSON(id: 1)]),
      guideJSON(forums: [forumJSON(id: 0)]),
      guideJSON(forums: [forumJSON(id: 1, name: "bad\nname")]),
      guideJSON(forums: [forumJSON(id: 1, status: 2)]),
      guideJSON(forums: [forumJSON(id: 1)], isLogin: 0),
    ] {
      XCTAssertThrowsError(
        try TiebaOfficialCheckInDecoder.guidePage(
          from: body,
          expectedUserID: userID,
          requestedPage: 1,
          pageSize: 50
        )
      )
    }
  }

  func testCatalogClientPaginatesDeduplicatesAndUsesResponseLimits() async throws {
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(minimumLevel: 4, maximumCount: 2)),
        .init(
          body: guideJSON(
            forums: [forumJSON(id: 1, level: 5), forumJSON(id: 2, level: 3)],
            hasMore: true,
            minimumLevel: 4
          )
        ),
        .init(
          body: guideJSON(
            forums: [forumJSON(id: 3, level: 6, status: 1)],
            minimumLevel: 4
          )
        ),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let catalog = try await client.getOfficialCheckInCatalog(
      credential: sessionCredential(),
      expectedUserID: userID
    )

    XCTAssertEqual(catalog.userID, userID)
    XCTAssertEqual(catalog.forums.map(\.id), [1, 2, 3])
    XCTAssertEqual(catalog.minimumBatchLevel, 4)
    XCTAssertEqual(catalog.maximumBatchCount, 2)
    XCTAssertEqual(catalog.batchEligibleForums.map(\.id), [1])
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 4)
    XCTAssertEqual(try formFields(snapshot.requests[2])["page_no"], "1")
    XCTAssertEqual(try formFields(snapshot.requests[3])["page_no"], "2")
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.officialCheckInSessionResponseMaximumBytes,
        TiebaAuthenticatedClient.officialCheckInEligibilityResponseMaximumBytes,
        TiebaAuthenticatedClient.officialCheckInGuideResponseMaximumBytes,
        TiebaAuthenticatedClient.officialCheckInGuideResponseMaximumBytes,
      ]
    )
  }

  func testCatalogRejectsCrossPageDuplicatesAndEmptyContinuingPage() async throws {
    for pages in [
      [
        guideJSON(forums: [forumJSON(id: 1)], hasMore: true),
        guideJSON(forums: [forumJSON(id: 1)]),
      ],
      [guideJSON(forums: [], hasMore: true)],
    ] {
      let transport = OfficialCheckInQueueTransport(
        responses: [
          .init(body: loginJSON()),
          .init(body: eligibilityJSON()),
        ] + pages.map { .init(body: $0) }
      )
      let client = TiebaAuthenticatedClient(transport: transport)
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await client.getOfficialCheckInCatalog(
          credential: self.sessionCredential(),
          expectedUserID: self.userID
        )
      }
    }
  }

  func testBatchClientSelectsStableEligiblePrefixAndOrdersStrictResults() async throws {
    let guide = guideJSON(
      forums: [
        forumJSON(id: 9, name: "unknown", level: 9, status: -1),
        forumJSON(id: 3, name: "first", level: 5),
        forumJSON(id: 4, name: "low", level: 3),
        forumJSON(id: 7, name: "forbidden", level: 9, forbidden: 1),
        forumJSON(id: 2, name: "second", level: 7),
        forumJSON(id: 8, name: "third", level: 8),
      ]
    )
    let batch = batchJSON(
      items: [
        batchItemJSON(id: 2, name: "second", signed: 0, errorCode: 123),
        batchItemJSON(id: 3, name: "first", signed: 1),
      ]
    )
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(minimumLevel: 4, maximumCount: 2)),
        .init(body: guide),
        .init(body: batch),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.performOfficialBatchCheckIn(
      credential: sessionCredential(),
      expectedUserID: userID
    )

    XCTAssertEqual(result.userID, userID)
    XCTAssertEqual(result.items.map(\.forumID), [3, 2])
    XCTAssertTrue(result.items[0].isConfirmed)
    XCTAssertFalse(result.items[1].isConfirmed)
    XCTAssertEqual(
      result.items[1].disposition,
      .rejected(code: 123, message: "rejected")
    )
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 4)
    XCTAssertEqual(try formFields(snapshot.requests[3])["forum_ids"], "3,2")
    XCTAssertEqual(
      snapshot.maximumBodyBytes.last,
      TiebaAuthenticatedClient.officialBatchCheckInResponseMaximumBytes
    )
  }

  func testBatchWithNoEligibleTargetReturnsEmptyWithoutWrite() async throws {
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(minimumLevel: 5, maximumCount: 2)),
        .init(
          body: guideJSON(
            forums: [
              forumJSON(id: 1, level: 4),
              forumJSON(id: 2, level: 9, status: 1),
              forumJSON(id: 3, level: 9, status: -1),
            ]
          )
        ),
      ]
    )
    let client = TiebaAuthenticatedClient(transport: transport)

    let result = try await client.performOfficialBatchCheckIn(
      credential: sessionCredential(),
      expectedUserID: userID
    )

    XCTAssertTrue(result.items.isEmpty)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 3)
    XCTAssertFalse(snapshot.requests.contains { $0.url?.path == "/c/c/forum/msign" })
  }

  func testBatchDecoderRejectsMissingExtraDuplicateAndMismatchedResults() throws {
    let requested = [
      officialForum(id: 1, name: "one"),
      officialForum(id: 2, name: "two"),
    ]
    let invalidBodies = [
      batchJSON(items: [batchItemJSON(id: 1, name: "one")]),
      batchJSON(
        items: [batchItemJSON(id: 1, name: "one"), batchItemJSON(id: 3, name: "three")]
      ),
      batchJSON(
        items: [batchItemJSON(id: 1, name: "one"), batchItemJSON(id: 1, name: "one")]
      ),
      batchJSON(
        items: [batchItemJSON(id: 1, name: "wrong"), batchItemJSON(id: 2, name: "two")]
      ),
      batchJSON(
        items: [
          batchItemJSON(id: 1, name: "one", signed: 2),
          batchItemJSON(id: 2, name: "two"),
        ]
      ),
      batchJSON(
        items: [
          batchItemJSON(id: 1, name: "one", signed: 1, errorCode: 9),
          batchItemJSON(id: 2, name: "two"),
        ]
      ),
    ]
    for body in invalidBodies {
      XCTAssertThrowsError(
        try TiebaOfficialCheckInDecoder.batchResult(
          from: body,
          expectedUserID: userID,
          requestedForums: requested
        )
      )
    }
  }

  func testCredentialRotationWaitsThenStartsIndependentBatchFlight() async throws {
    let firstCredential = sessionCredential(marker: "b")
    let secondCredential = sessionCredential(marker: "c")
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(maximumCount: 1)),
        .init(body: guideJSON(forums: [forumJSON(id: 1, name: "one", level: 5)])),
        .init(body: batchJSON(items: [batchItemJSON(id: 1, name: "one")])),
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(maximumCount: 1)),
        .init(body: guideJSON(forums: [forumJSON(id: 2, name: "two", level: 5)])),
        .init(body: batchJSON(items: [batchItemJSON(id: 2, name: "two")])),
      ],
      blockedRequestIndex: 3
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let expectedUserID = userID

    let firstTask = Task {
      try await client.performOfficialBatchCheckIn(
        credential: firstCredential,
        expectedUserID: expectedUserID
      )
    }
    guard await transport.waitUntilRequestCount(4) else {
      return XCTFail("First batch write did not start")
    }
    let secondTask = Task {
      try await client.performOfficialBatchCheckIn(
        credential: secondCredential,
        expectedUserID: expectedUserID
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    let blockedRequestCount = await transport.requestCount()
    XCTAssertEqual(blockedRequestCount, 4)
    await transport.releaseBlockedRequest()

    let first = try await firstTask.value
    let second = try await secondTask.value

    XCTAssertEqual(first.items.map(\.forumID), [1])
    XCTAssertEqual(second.items.map(\.forumID), [2])
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 8)
    XCTAssertEqual(try formFields(snapshot.requests[0])["stoken"], firstCredential.stoken)
    XCTAssertEqual(try formFields(snapshot.requests[4])["stoken"], secondCredential.stoken)
  }

  func testEquivalentConcurrentBatchCallsShareOneCatalogAndWrite() async throws {
    let credential = sessionCredential()
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(body: eligibilityJSON(maximumCount: 1)),
        .init(body: guideJSON(forums: [forumJSON(id: 1, name: "one", level: 5)])),
        .init(body: batchJSON(items: [batchItemJSON(id: 1, name: "one")])),
      ],
      blockedRequestIndex: 3
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let expectedUserID = userID
    let first = Task {
      try await client.performOfficialBatchCheckIn(
        credential: credential,
        expectedUserID: expectedUserID
      )
    }
    guard await transport.waitUntilRequestCount(4) else {
      first.cancel()
      await transport.releaseBlockedRequest()
      return XCTFail("First batch write did not start")
    }
    let joined = Task {
      try await client.performOfficialBatchCheckIn(
        credential: credential,
        expectedUserID: expectedUserID
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    let blockedCount = await transport.requestCount()
    XCTAssertEqual(blockedCount, 4)
    await transport.releaseBlockedRequest()

    let firstResult = try await first.value
    let joinedResult = try await joined.value
    XCTAssertEqual(firstResult, joinedResult)
    XCTAssertEqual(firstResult.items.map(\.forumID), [1])
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.count, 4)
    XCTAssertEqual(snapshot.requests.filter { $0.url?.path == "/c/c/forum/msign" }.count, 1)
  }

  func testSingleForumCheckInWaitsForBatchFlightBeforeItsPreflight() async throws {
    let batchCredential = sessionCredential()
    let singleCredential = batchCredential.bdussCredential
    let responses: [OfficialCheckInQueueTransport.Response] = [
      .init(body: loginJSON()),
      .init(body: eligibilityJSON(maximumCount: 1)),
      .init(body: guideJSON(forums: [forumJSON(id: 1, name: "one", level: 5)])),
      .init(body: batchJSON(items: [batchItemJSON(id: 1, name: "one")])),
      .init(body: try forumAccountStateJSON(forumID: 2, name: "two", isCheckedIn: false)),
      .init(body: singleCheckInJSON()),
    ]
    let transport = OfficialCheckInQueueTransport(responses: responses, blockedRequestIndex: 3)
    let client = TiebaAuthenticatedClient(transport: transport)
    let expectedUserID = userID
    let batchTask = Task {
      try await client.performOfficialBatchCheckIn(
        credential: batchCredential,
        expectedUserID: expectedUserID
      )
    }
    guard await transport.waitUntilRequestCount(4) else {
      return XCTFail("Batch write did not start")
    }
    let singleTask = Task {
      try await client.checkInToForum(
        credential: singleCredential,
        expectedUserID: expectedUserID,
        forumID: 2,
        forumName: "two"
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    let blockedCount = await transport.requestCount()
    XCTAssertEqual(blockedCount, 4)
    await transport.releaseBlockedRequest()

    _ = try await batchTask.value
    let state = try await singleTask.value
    XCTAssertTrue(state.checkIn?.isCheckedIn == true)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, [
      "/c/s/login", "/c/f/forum/getforumlist", "/c/f/forum/forumGuide",
      "/c/c/forum/msign", "/c/f/frs/page", "/c/c/forum/sign",
    ])
  }

  func testBatchFlightWaitsForSingleForumCheckInBeforeRefreshingCatalog() async throws {
    let singleCredential = sessionCredential().bdussCredential
    let responses: [OfficialCheckInQueueTransport.Response] = [
      .init(body: try forumAccountStateJSON(forumID: 2, name: "two", isCheckedIn: false)),
      .init(body: singleCheckInJSON()),
      .init(body: loginJSON()),
      .init(body: eligibilityJSON(maximumCount: 1)),
      .init(body: guideJSON(forums: [forumJSON(id: 1, name: "one", level: 5)])),
      .init(body: batchJSON(items: [batchItemJSON(id: 1, name: "one")])),
    ]
    let transport = OfficialCheckInQueueTransport(responses: responses, blockedRequestIndex: 1)
    let client = TiebaAuthenticatedClient(transport: transport)
    let batchCredential = sessionCredential()
    let expectedUserID = userID
    let singleTask = Task {
      try await client.checkInToForum(
        credential: singleCredential,
        expectedUserID: expectedUserID,
        forumID: 2,
        forumName: "two"
      )
    }
    guard await transport.waitUntilRequestCount(2) else {
      return XCTFail("Single-forum write did not start")
    }
    let batchTask = Task {
      try await client.performOfficialBatchCheckIn(
        credential: batchCredential,
        expectedUserID: expectedUserID
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    let blockedCount = await transport.requestCount()
    XCTAssertEqual(blockedCount, 2)
    await transport.releaseBlockedRequest()

    _ = try await singleTask.value
    let result = try await batchTask.value
    XCTAssertEqual(result.items.map(\.forumID), [1])
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, [
      "/c/f/frs/page", "/c/c/forum/sign", "/c/s/login", "/c/f/forum/getforumlist",
      "/c/f/forum/forumGuide", "/c/c/forum/msign",
    ])
  }

  func testOversizedCatalogResponseUsesBoundedTransport() async throws {
    let transport = OfficialCheckInQueueTransport(
      responses: [
        .init(body: loginJSON()),
        .init(
          body: Data(
            repeating: 0,
            count: TiebaAuthenticatedClient.officialCheckInEligibilityResponseMaximumBytes + 1
          )
        ),
      ],
      enforcesMaximumBodyBytes: true
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.officialCheckInEligibilityResponseMaximumBytes
      )
    ) {
      _ = try await client.getOfficialCheckInCatalog(
        credential: self.sessionCredential(),
        expectedUserID: self.userID
      )
    }
  }

  private func sessionCredential(marker: Character = "b") -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: marker, count: 192),
      stoken: String(repeating: marker, count: 64),
      bdussCookieName: .bduss
    )
  }

  private func officialForum(id: Int64, name: String) -> TiebaOfficialCheckInForum {
    TiebaOfficialCheckInForum(
      id: id,
      name: name,
      level: 5,
      avatar: "",
      checkInStatus: .pending,
      isForbidden: false
    )
  }

  private func loginJSON(userID: Int64? = nil, tbs: String? = nil) -> Data {
    jsonData([
      "error_code": "0",
      "anti": ["tbs": tbs ?? self.tbs],
      "user": [
        "id": String(userID ?? self.userID),
        "name": "account",
        "portrait": "portrait",
      ],
    ])
  }

  private func eligibilityJSON(
    minimumLevel: Int = 4,
    maximumCount: Int = 5,
    canUse: Int = 1,
    valid: Int = 1
  ) -> Data {
    jsonData([
      "error_code": "0",
      "error": ["errno": "0", "errmsg": "", "usermsg": ""],
      "level": String(minimumLevel),
      "msign_step_num": String(maximumCount),
      "can_use": String(canUse),
      "valid": String(valid),
    ])
  }

  private func forumJSON(
    id: Int64,
    name: String = "forum",
    level: Int = 5,
    status: Int = 0,
    forbidden: Int = 0
  ) -> [String: Any] {
    [
      "forum_id": id,
      "forum_name": name,
      "level_id": level,
      "avatar": "avatar",
      "is_sign": status,
      "is_forbidden": forbidden,
    ]
  }

  private func guideJSON(
    forums: [[String: Any]],
    hasMore: Bool = false,
    minimumLevel: Int = 4,
    isLogin: Int = 1,
    batchValid: Int = 1
  ) -> Data {
    jsonData([
      "error_code": 0,
      "error_msg": "",
      "like_forum": forums,
      "like_forum_has_more": hasMore,
      "is_login": isLogin,
      "msign_valid": batchValid,
      "msign_level": minimumLevel,
    ])
  }

  private func batchItemJSON(
    id: Int64,
    name: String,
    signed: Int = 1,
    errorCode: Int = 0
  ) -> [String: Any] {
    [
      "forum_id": String(id),
      "forum_name": name,
      "signed": String(signed),
      "is_filter": "0",
      "is_on": "1",
      "cur_score": "10",
      "sign_day_count": "3",
      "error": [
        "err_no": String(errorCode),
        "errmsg": errorCode == 0 ? "" : "rejected",
        "usermsg": errorCode == 0 ? "" : "rejected",
      ],
    ]
  }

  private func batchJSON(items: [[String: Any]]) -> Data {
    jsonData([
      "error_code": "0",
      "error": ["errno": "0", "errmsg": "", "usermsg": ""],
      "ctime": 1,
      "time": 1,
      "logid": 1,
      "server_time": "1",
      "is_timeout": "0",
      "show_dialog": "0",
      "sign_notice": "",
      "timeout_notice": "",
      "info": items,
    ])
  }

  private func forumAccountStateJSON(
    forumID: Int64,
    name: String,
    isCheckedIn: Bool
  ) throws -> Data {
    var user = User()
    user.id = userID
    var signUser = FrsPageResIdl.DataRes.ForumInfo.SignInfo.SignUser()
    signUser.userID = userID
    signUser.isSignIn = isCheckedIn ? 1 : 0
    var signInfo = FrsPageResIdl.DataRes.ForumInfo.SignInfo()
    signInfo.userInfo = signUser
    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = forumID
    forum.name = name
    forum.isLike = 1
    forum.signInInfo = signInfo
    var anti = FrsPageResIdl.DataRes.Anti()
    anti.tbs = tbs
    var data = FrsPageResIdl.DataRes()
    data.user = user
    data.forum = forum
    data.anti = anti
    var response = FrsPageResIdl()
    response.data = data
    return try response.serializedData()
  }

  private func singleCheckInJSON() -> Data {
    jsonData([
      "error_code": "0",
      "user_info": [
        "user_id": String(userID),
        "is_sign_in": "1",
        "cont_sign_num": "3",
        "user_sign_rank": "7",
      ],
    ])
  }

  private func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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

  private func assertSignature(
    in fields: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let unsigned = fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(for: unsigned),
      file: file,
      line: line
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
}

private actor OfficialCheckInQueueTransport: TiebaTransport {
  struct Response: Sendable {
    let body: Data
    let statusCode: Int

    init(body: Data, statusCode: Int = 200) {
      self.body = body
      self.statusCode = statusCode
    }
  }

  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let responses: [Response]
  private let enforcesMaximumBodyBytes: Bool
  private let blockedRequestIndex: Int?
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()
  private var isBlockedRequestReleased = false
  private var blockedContinuation: CheckedContinuation<Void, Never>?

  init(
    responses: [Response],
    enforcesMaximumBodyBytes: Bool = false,
    blockedRequestIndex: Int? = nil
  ) {
    self.responses = responses
    self.enforcesMaximumBodyBytes = enforcesMaximumBodyBytes
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
    if enforcesMaximumBodyBytes,
      let maximumBodyBytes,
      response.body.count > maximumBodyBytes
    {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }

  func requestCount() -> Int { requests.count }

  func waitUntilRequestCount(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while requests.count < count, clock.now < deadline {
      await Task.yield()
    }
    return requests.count >= count
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }
}
