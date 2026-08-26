import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaSessionAndCloudFavoritesTests: XCTestCase {
  private let userID: Int64 = 957_339_815

  func testSessionCredentialIsRedactedAndRetainsOnlyExplicitCookieName() {
    let credential = sessionCredential(cookieName: .bdussBFESS)

    XCTAssertEqual(credential.bdussCookieName, .bdussBFESS)
    XCTAssertEqual(credential.bdussCredential.bduss, credential.bduss)
    XCTAssertFalse(String(describing: credential).contains(credential.bduss))
    XCTAssertFalse(String(reflecting: credential).contains(credential.stoken))
    XCTAssertTrue(Array(credential.customMirror.children).isEmpty)
  }

  func testSessionAppProbeUsesOnlySignedPairFields() throws {
    let credential = sessionCredential()
    let request = try factory().validateSessionApp(credential: credential)
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/s/login")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      Set(fields.keys),
      [
        "_client_version", "authsid", "bdusstoken", "channel_id", "channel_uid",
        "stoken", "sign",
      ]
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 11.10.8.6")
    XCTAssertEqual(fields["_client_version"], "11.10.8.6")
    XCTAssertEqual(fields["authsid"], "null")
    XCTAssertEqual(fields["bdusstoken"], "\(credential.bduss)|")
    XCTAssertEqual(fields["channel_id"], "")
    XCTAssertEqual(fields["channel_uid"], "")
    XCTAssertEqual(fields["stoken"], credential.stoken)
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("_client_version", "11.10.8.6"),
          ("authsid", "null"),
          ("bdusstoken", "\(credential.bduss)|"),
          ("channel_id", ""),
          ("channel_uid", ""),
          ("stoken", credential.stoken),
        ]
      )
    )
  }

  func testWebProbeUsesExactHTTPSURLActualBDUSSNameAndMinimalCookiePair() throws {
    let credential = sessionCredential(cookieName: .bdussBFESS)
    let request = try factory().validateSessionWeb(credential: credential)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tieba.baidu.com/mo/q/newmoindex?need_user=1"
    )
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Cookie"),
      "BDUSS_BFESS=\(credential.bduss); STOKEN=\(credential.stoken)"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertFalse(request.url?.absoluteString.contains(credential.bduss) ?? true)
    XCTAssertFalse(request.url?.absoluteString.contains(credential.stoken) ?? true)
  }

  func testCloudFavoritesRequestUsesExactMinimalSignedContract() throws {
    let credential = sessionCredential()
    let request = try factory().cloudFavorites(
      credential: credential,
      expectedUserID: userID,
      offset: 40,
      pageSize: 20
    )
    let fields = try formFields(request)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/f/post/threadstore"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 11.10.8.6")
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "offset", "rn", "stoken", "user_id", "sign"]
    )
    XCTAssertEqual(fields["BDUSS"], credential.bduss)
    XCTAssertEqual(fields["_client_version"], "11.10.8.6")
    XCTAssertEqual(fields["offset"], "40")
    XCTAssertEqual(fields["rn"], "20")
    XCTAssertEqual(fields["stoken"], credential.stoken)
    XCTAssertEqual(fields["user_id"], String(userID))
    XCTAssertEqual(
      fields["sign"],
      TiebaAuthenticatedRequestFactory.signature(
        for: [
          ("BDUSS", credential.bduss),
          ("_client_version", "11.10.8.6"),
          ("offset", "40"),
          ("rn", "20"),
          ("stoken", credential.stoken),
          ("user_id", String(userID)),
        ]
      )
    )
    for forbidden in [
      "tbs", "cuid", "CUID", "imei", "IMEI", "oaid", "android_id", "model",
      "timestamp", "_timestamp", "client_id", "client_type", "_client_type",
    ] {
      XCTAssertNil(fields[forbidden])
    }
  }

  func testRejectsMalformedSessionCredentialsAndPagination() throws {
    let invalidCharacters = [" ", "\"", ",", ";", "\\", "\n", "\u{00E9}"]
    for invalidCharacter in invalidCharacters {
      let invalidBDUSS = String(repeating: "b", count: 191) + invalidCharacter
      XCTAssertThrowsError(
        try factory().validateSessionApp(
          credential: TiebaSessionCredential(
            bduss: invalidBDUSS,
            stoken: String(repeating: "s", count: 64),
            bdussCookieName: .bduss
          )
        )
      )

      let invalidSTOKEN = String(repeating: "s", count: 63) + invalidCharacter
      XCTAssertThrowsError(
        try factory().validateSessionWeb(
          credential: TiebaSessionCredential(
            bduss: String(repeating: "b", count: 192),
            stoken: invalidSTOKEN,
            bdussCookieName: .bduss
          )
        )
      )
    }
    XCTAssertThrowsError(
      try factory().validateSessionApp(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "b", count: 191),
          stoken: String(repeating: "s", count: 64),
          bdussCookieName: .bduss
        )
      )
    )
    XCTAssertThrowsError(
      try factory().cloudFavorites(
        credential: sessionCredential(), expectedUserID: 0, offset: 0, pageSize: 20
      )
    )
    XCTAssertThrowsError(
      try factory().cloudFavorites(
        credential: sessionCredential(), expectedUserID: userID, offset: -1, pageSize: 20
      )
    )
    XCTAssertThrowsError(
      try factory().cloudFavorites(
        credential: sessionCredential(), expectedUserID: userID, offset: 0, pageSize: 101
      )
    )
  }

  func testValidateSessionRequiresMatchingAppAndWebUserIDs() async throws {
    let transport = SessionQueueTransport(responses: [
      .init(body: appAccountBody()),
      .init(body: webAccountBody(userID: userID)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    let account = try await client.validateSession(credential: sessionCredential())

    XCTAssertEqual(account.userID, userID)
    XCTAssertEqual(account.username, "account-name")
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, ["/c/s/login", "/mo/q/newmoindex"])
    XCTAssertEqual(snapshot.requests.map(\.httpMethod), ["POST", "GET"])
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [
        TiebaAuthenticatedClient.accountResponseMaximumBytes,
        TiebaAuthenticatedClient.webSessionResponseMaximumBytes,
      ]
    )

    let mismatchClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: appAccountBody()),
        .init(body: webAccountBody(userID: userID + 1)),
      ])
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await mismatchClient.validateSession(credential: sessionCredential())
    }
  }

  func testValidateSessionRejectsMalformedFailedAndOversizedWebProbe() async {
    let invalidJSONClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: appAccountBody()),
        .init(body: Data("not-json".utf8)),
      ])
    )
    await assertError(.invalidJSON) {
      _ = try await invalidJSONClient.validateSession(credential: sessionCredential())
    }

    let malformedClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: appAccountBody()),
        .init(body: Data("{\"no\":0,\"data\":{}}".utf8)),
      ])
    )
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await malformedClient.validateSession(credential: sessionCredential())
    }

    let serverErrorClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: appAccountBody()),
        .init(body: Data("{\"no\":1,\"error\":\"not logged in\"}".utf8)),
      ])
    )
    await assertError(.server(code: 1, message: "not logged in")) {
      _ = try await serverErrorClient.validateSession(credential: sessionCredential())
    }

    let oversizedClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: appAccountBody()),
        .init(
          body: Data(
            repeating: 0,
            count: TiebaAuthenticatedClient.webSessionResponseMaximumBytes + 1
          )
        ),
      ])
    )
    await assertError(
      .responseTooLarge(maximumBytes: TiebaAuthenticatedClient.webSessionResponseMaximumBytes)
    ) {
      _ = try await oversizedClient.validateSession(credential: sessionCredential())
    }
  }

  func testCloudFavoritesDecodeBindsUserPaginationAndPreservesDuplicates() async throws {
    let body = cloudFavoritesBody(items: [favoriteObject(), favoriteObject(title: "Duplicate")])
    let transport = SessionQueueTransport(responses: [.init(body: body)])
    let client = TiebaAuthenticatedClient(transport: transport)

    let page = try await client.getCloudFavorites(
      credential: sessionCredential(),
      expectedUserID: userID,
      offset: 20,
      pageSize: 2
    )

    XCTAssertEqual(page.requestedUserID, userID)
    XCTAssertEqual(page.offset, 20)
    XCTAssertEqual(page.pageSize, 2)
    XCTAssertEqual(page.nextOffset, 22)
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.favorites.map(\.id), [42, 42])
    XCTAssertEqual(page.favorites.map(\.title), ["Saved thread", "Duplicate"])
    let favorite = try XCTUnwrap(page.favorites.first)
    XCTAssertEqual(favorite.forumName, "swift")
    XCTAssertEqual(favorite.author.userID, 123)
    XCTAssertEqual(favorite.author.username, "author-name")
    XCTAssertEqual(favorite.author.displayName, "Display Name")
    XCTAssertEqual(favorite.author.portrait, "portrait-token")
    XCTAssertEqual(favorite.author.preferredName, "Display Name")
    XCTAssertFalse(favorite.isDeleted)
    XCTAssertEqual(favorite.lastTimestamp, 1_700_000_000)
    XCTAssertEqual(favorite.maximumPostID, 999)
    XCTAssertEqual(favorite.minimumPostID, 100)
    XCTAssertEqual(favorite.markedPostID, 500)
    XCTAssertEqual(favorite.markStatus, 1)
    XCTAssertEqual(favorite.postNumber, 3)
    XCTAssertEqual(favorite.postNumberMessage, "3 new replies")
    XCTAssertEqual(favorite.updateCount, 4)

    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.maximumBodyBytes,
      [TiebaAuthenticatedClient.cloudFavoritesResponseMaximumBytes]
    )
  }

  func testCloudFavoritesEmptyPageHasNoMoreAndMalformedItemsFailClosed() throws {
    let empty = try TiebaAuthenticatedDecoder.cloudFavorites(
      from: cloudFavoritesBody(items: []),
      expectedUserID: userID,
      offset: 0,
      pageSize: 20
    )
    XCTAssertTrue(empty.favorites.isEmpty)
    XCTAssertFalse(empty.hasMore)

    for invalidEmptyShape: [String: Any] in [
      ["error_code": "0"],
      ["error_code": "0", "store_thread": NSNull()],
    ] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.cloudFavorites(
          from: try JSONSerialization.data(withJSONObject: invalidEmptyShape),
          expectedUserID: userID,
          offset: 0,
          pageSize: 20
        )
      )
    }
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.cloudFavorites(
        from: try JSONSerialization.data(withJSONObject: [
          "error_code": "0", "store_thread": "not-an-array",
        ]),
        expectedUserID: userID,
        offset: 0,
        pageSize: 20
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    var deleted = favoriteObject(title: "")
    deleted["forum_name"] = ""
    deleted["is_deleted"] = "1"
    let deletedPage = try TiebaAuthenticatedDecoder.cloudFavorites(
      from: cloudFavoritesBody(items: [deleted]),
      expectedUserID: userID,
      offset: 0,
      pageSize: 20
    )
    XCTAssertEqual(deletedPage.favorites.first?.title, "")
    XCTAssertEqual(deletedPage.favorites.first?.forumName, "")
    XCTAssertTrue(deletedPage.favorites.first?.isDeleted ?? false)
    XCTAssertEqual(deletedPage.favorites.first?.author.userID, 123)
    XCTAssertEqual(deletedPage.favorites.first?.author.username, "author-name")
    XCTAssertEqual(deletedPage.favorites.first?.author.displayName, "Display Name")
    XCTAssertEqual(deletedPage.favorites.first?.author.portrait, "portrait-token")

    let routelessAuthors = [
      favoriteObject(authorID: nil),
      favoriteObject(authorID: NSNull()),
      favoriteObject(authorID: ""),
      favoriteObject(authorID: "0"),
    ]
    for object in routelessAuthors {
      let page = try TiebaAuthenticatedDecoder.cloudFavorites(
        from: cloudFavoritesBody(items: [object]),
        expectedUserID: userID,
        offset: 0,
        pageSize: 20
      )
      XCTAssertNil(page.favorites.first?.author.userID)
    }

    for invalidAuthorID in ["-1", "not-a-user-id"] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.cloudFavorites(
          from: cloudFavoritesBody(items: [favoriteObject(authorID: invalidAuthorID)]),
          expectedUserID: userID,
          offset: 0,
          pageSize: 20
        )
      ) { error in
        XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
      }
    }

    var malformed = favoriteObject()
    malformed.removeValue(forKey: "mark_pid")
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.cloudFavorites(
        from: cloudFavoritesBody(items: [malformed]),
        expectedUserID: userID,
        offset: 0,
        pageSize: 20
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    malformed = favoriteObject()
    malformed["is_deleted"] = "2"
    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.cloudFavorites(
        from: cloudFavoritesBody(items: [malformed]),
        expectedUserID: userID,
        offset: 0,
        pageSize: 20
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.cloudFavorites(
        from: cloudFavoritesBody(items: [favoriteObject(), favoriteObject()]),
        expectedUserID: userID,
        offset: 0,
        pageSize: 1
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidAuthenticatedResponse)
    }
  }

  func testCloudFavoritesShortNonemptyPageAdvancesByRequestedPageSize() throws {
    let page = try TiebaAuthenticatedDecoder.cloudFavorites(
      from: cloudFavoritesBody(items: [favoriteObject()]),
      expectedUserID: userID,
      offset: 20,
      pageSize: 20
    )

    XCTAssertEqual(page.favorites.count, 1)
    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.nextOffset, 40)
  }

  func testCloudFavoritesRejectsServerErrorAndOversizedResponse() async {
    let serverClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(body: Data("{\"error_code\":7,\"error_msg\":\"denied\"}".utf8))
      ])
    )
    await assertError(.server(code: 7, message: "denied")) {
      _ = try await serverClient.getCloudFavorites(
        credential: sessionCredential(), expectedUserID: userID
      )
    }

    let oversizedClient = TiebaAuthenticatedClient(
      transport: SessionQueueTransport(responses: [
        .init(
          body: Data(
            repeating: 0,
            count: TiebaAuthenticatedClient.cloudFavoritesResponseMaximumBytes + 1
          )
        )
      ])
    )
    await assertError(
      .responseTooLarge(
        maximumBytes: TiebaAuthenticatedClient.cloudFavoritesResponseMaximumBytes
      )
    ) {
      _ = try await oversizedClient.getCloudFavorites(
        credential: sessionCredential(), expectedUserID: userID
      )
    }
  }

  func testAuthenticatedTransportPolicyRejectsSessionAndCloudRedirects() {
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tieba.baidu.com/mo/q/newmoindex?need_user=1"),
        to: URL(string: "https://tieba.baidu.com/mo/q/newmoindex?need_user=1&redirected=1")
      )
    )
    XCTAssertFalse(
      TiebaRedirectPolicy.rejectAll.allows(
        from: URL(string: "https://tiebac.baidu.com/c/f/post/threadstore"),
        to: URL(string: "https://example.com/")
      )
    )
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func sessionCredential(
    cookieName: TiebaBDUSSCookieName = .bduss
  ) -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: cookieName
    )
  }

  private func appAccountBody() -> Data {
    Data(
      """
      {
        "error_code": 0,
        "user": {
          "id": "\(userID)",
          "name": "account-name",
          "portrait": "portrait-token"
        }
      }
      """.utf8
    )
  }

  private func webAccountBody(userID: Int64) -> Data {
    Data("{\"no\":0,\"data\":{\"id\":\"\(userID)\"}}".utf8)
  }

  private func favoriteObject(
    title: String = "Saved thread",
    authorID: Any? = "123"
  ) -> [String: Any] {
    var author: [String: Any] = [
      "name": "author-name",
      "name_show": "Display Name",
      "user_portrait": "portrait-token",
    ]
    if let authorID {
      author["lz_uid"] = authorID
    }
    return [
      "thread_id": "42",
      "title": title,
      "forum_name": "swift",
      "author": author,
      "is_deleted": "0",
      "last_time": "1700000000",
      "type": "1",
      "status": "0",
      "max_pid": "999",
      "min_pid": "100",
      "mark_pid": "500",
      "mark_status": "1",
      "post_no": "3",
      "post_no_msg": "3 new replies",
      "count": "4",
    ]
  }

  private func cloudFavoritesBody(items: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "error_code": "0",
      "store_thread": items,
    ])
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

private actor SessionQueueTransport: TiebaTransport {
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
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(responses: [Response]) {
    self.responses = responses
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
    if let maximumBodyBytes, response.body.count > maximumBodyBytes {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return TiebaHTTPResponse(body: response.body, statusCode: response.statusCode)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}
