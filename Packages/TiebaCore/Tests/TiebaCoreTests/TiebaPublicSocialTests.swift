import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaPublicSocialRequestFactoryTests: XCTestCase {
  private let factory = TiebaRequestFactory(configuration: .init())

  func testFollowingRequestUsesExactAnonymousSignedFieldSet() throws {
    let request = try factory.userRelations(userID: 957_339_815, kind: .following, page: 2)

    try assertAnonymousRequest(
      request,
      path: "/c/u/follow/followList",
      expectedUserID: 957_339_815,
      expectedPage: 2,
      expectedSignature: "b24c226211cab53db4a79b71b40b832c"
    )
  }

  func testFollowersRequestUsesExactAnonymousSignedFieldSet() throws {
    let request = try factory.userRelations(userID: 4_954_297_652, kind: .followers, page: 3)

    try assertAnonymousRequest(
      request,
      path: "/c/u/fans/page",
      expectedUserID: 4_954_297_652,
      expectedPage: 3,
      expectedSignature: "752bb85241d283c864b2f45dccf56263"
    )
  }

  func testPublicSocialRequestUsesFixedVersionInsteadOfConfiguredClientVersions() throws {
    let customizedFactory = TiebaRequestFactory(
      configuration: .init(
        clientVersion: "99.99.99",
        authenticatedClientVersion: "88.88.88"
      )
    )

    for kind in [TiebaUserRelationKind.following, .followers] {
      let request = try customizedFactory.userRelations(userID: 1, kind: kind, page: 1)
      let fields = try formFields(request)
      XCTAssertEqual(fields["_client_version"], "22.6.5.1")
      XCTAssertEqual(Set(fields.keys), Set(["_client_version", "pn", "uid", "sign"]))
    }
  }

  func testRelationRequestRejectsInvalidContextAndHeaderInjection() throws {
    for userID in [Int64.min, -1, 0] {
      XCTAssertThrowsError(
        try factory.userRelations(userID: userID, kind: .following, page: 1)
      ) { error in
        guard case .invalidArgument = error as? TiebaClientError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
    for page in [Int.min, -1, 0, Int(Int32.max) + 1] {
      XCTAssertThrowsError(
        try factory.userRelations(userID: 1, kind: .followers, page: page)
      ) { error in
        guard case .invalidArgument = error as? TiebaClientError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }

    let injected = TiebaRequestFactory(
      configuration: .init(userAgent: "test\r\nCookie: secret")
    )
    XCTAssertThrowsError(
      try injected.userRelations(userID: 1, kind: .following, page: 1)
    ) { error in
      guard case .invalidArgument = error as? TiebaClientError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func assertAnonymousRequest(
    _ request: URLRequest,
    path: String,
    expectedUserID: Int64,
    expectedPage: Int,
    expectedSignature: String
  ) throws {
    XCTAssertEqual(request.url?.scheme, "https")
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
    XCTAssertEqual(request.url?.path, path)
    XCTAssertNil(request.url?.query)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "x_bd_data_type"))

    let fields = try formFields(request)
    XCTAssertEqual(Set(fields.keys), Set(["_client_version", "pn", "uid", "sign"]))
    XCTAssertEqual(fields["_client_version"], "22.6.5.1")
    XCTAssertEqual(fields["pn"], String(expectedPage))
    XCTAssertEqual(fields["uid"], String(expectedUserID))
    XCTAssertEqual(fields["sign"], expectedSignature)
    let unsigned = fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    XCTAssertEqual(fields["sign"], TiebaFormSigner.signature(for: unsigned))

    let forbidden = [
      "BDUSS", "BDUSS_BFESS", "STOKEN", "bdusstoken", "Cookie", "Authorization",
      "_client_type", "CUID", "cuid", "tieba_cuid", "IMEI", "imei", "phone_imei",
      "client_id", "client_user_token", "user_id", "model", "net_type", "scr_h", "scr_w",
    ]
    for field in forbidden {
      XCTAssertNil(fields[field], field)
    }
  }
}

final class TiebaPublicSocialDecoderTests: XCTestCase {
  func testFollowingDecodesMixedUserFieldsDeduplicatesAndStripsPortraitQueries() throws {
    let users: [[String: Any]] = [
      [
        "id": 101,
        "name": " first-user ",
        "name_show": " First User ",
        "portrait": "tb.1.first?t=123",
        "intro": " First introduction ",
        "has_concerned": 1,
        "is_fans": 1,
        "is_followed": 1,
        "is_friend": 1,
      ],
      [
        "id": "102",
        "name": "second-user",
        "name_show": "",
        "portrait": "https://example.test/avatar.jpg?size=large",
        "intro": "Second introduction",
      ],
      ["id": "101", "name": "duplicate", "name_show": "Duplicate"],
      ["id": 0, "name": "invalid", "name_show": "Invalid"],
      ["id": 103, "name": "", "name_show": ""],
      ["id": 103, "name": "valid-after-empty", "name_show": "Valid After Empty"],
    ]
    let body = try followingBody(
      users: users,
      page: "2",
      hasMore: "1",
      totalCount: "42",
      visibilitySwitch: "1",
      notice: " Public list "
    )

    let result = try TiebaPublicSocialDecoder.page(
      from: body,
      requestedUserID: 999,
      kind: .following,
      requestedPage: 2
    )

    XCTAssertEqual(result.requestedUserID, 999)
    XCTAssertEqual(result.kind, .following)
    XCTAssertEqual(result.users.map(\.id), [101, 102, 103])
    XCTAssertEqual(result.users.first?.username, "first-user")
    XCTAssertEqual(result.users.first?.displayName, "First User")
    XCTAssertEqual(result.users.first?.portrait, "tb.1.first")
    XCTAssertEqual(result.users.first?.introduction, "First introduction")
    XCTAssertEqual(result.users.first?.concernState, .following)
    let second = try XCTUnwrap(result.users.first(where: { $0.id == 102 }))
    XCTAssertEqual(second.preferredName, "second-user")
    XCTAssertEqual(second.portrait, "https://example.test/avatar.jpg")
    XCTAssertNil(second.concernState)
    XCTAssertEqual(result.users.last?.preferredName, "Valid After Empty")
    XCTAssertEqual(result.pagination.pageSize, 20)
    XCTAssertEqual(result.pagination.currentPage, 2)
    XCTAssertEqual(result.pagination.totalPages, 0)
    XCTAssertEqual(result.pagination.totalCount, 42)
    XCTAssertTrue(result.pagination.hasMore)
    XCTAssertTrue(result.pagination.hasPrevious)
    XCTAssertEqual(result.notice, "Public list")
    XCTAssertEqual(result.visibilitySwitch, 1)
  }

  func testFollowingLossilyDecodesConcernStateAndPreservesUnknownRawValues() throws {
    let users: [[String: Any]] = [
      ["id": 1, "name": "user-1", "has_concerned": 0],
      ["id": 2, "name": "user-2", "has_concerned": " 1 "],
      ["id": 3, "name": "user-3", "has_concerned": 2],
      ["id": 4, "name": "user-4", "has_concerned": "2"],
      ["id": 5, "name": "user-5", "has_concerned": String(Int64.max)],
      ["id": 6, "name": "user-6"],
      ["id": 7, "name": "user-7", "has_concerned": NSNull()],
      ["id": 8, "name": "user-8", "has_concerned": true],
      ["id": 9, "name": "user-9", "has_concerned": ["invalid"]],
      ["id": 10, "name": "user-10", "has_concerned": ["invalid": 2]],
      ["id": 11, "name": "user-11", "has_concerned": "2.0"],
    ]

    let result = try decode(
      followingBody(users: users, totalCount: users.count),
      kind: .following
    )

    XCTAssertEqual(result.users.map(\.id), (1...11).map { Int64($0) })
    XCTAssertEqual(
      result.users.map(\.concernState),
      [
        .notFollowing,
        .following,
        .mutual,
        .mutual,
        .unknown(Int64.max),
        nil,
        nil,
        nil,
        nil,
        nil,
        nil,
      ]
    )

    for rawValue in [Int64.min, -1, 3, Int64.max] {
      let state = TiebaRelatedUserConcernState(rawValue: rawValue)
      XCTAssertEqual(state, .unknown(rawValue))
      XCTAssertEqual(state.rawValue, rawValue)
    }
    XCTAssertEqual(TiebaRelatedUserConcernState(rawValue: 2), .mutual)
    XCTAssertNotEqual(TiebaRelatedUserConcernState(rawValue: 1), .mutual)
  }

  func testFollowingCompensatesForFalseServerFlagOnFullPage() throws {
    let users: [[String: Any]] = (1...TiebaPublicSocialPolicy.followingPageSize).map {
      ["id": String($0), "name": "user-\($0)", "name_show": "User \($0)"]
    }
    let body = try followingBody(users: users, hasMore: 0, totalCount: 21)

    let result = try TiebaPublicSocialDecoder.page(
      from: body,
      requestedUserID: 1,
      kind: .following,
      requestedPage: 1
    )

    XCTAssertEqual(result.users.count, 20)
    XCTAssertTrue(result.pagination.hasMore)
    XCTAssertEqual(result.pagination.nextPage, 2)
  }

  func testFollowingPartialAndEmptyPagesRespectServerFlagButEmptyAlwaysStops() throws {
    let oneUser: [[String: Any]] = [["id": 1, "name": "user", "name_show": "User"]]
    let partialWithoutMore = try followingBody(users: oneUser, hasMore: 0, totalCount: 1)
    let partialWithMore = try followingBody(users: oneUser, hasMore: 1, totalCount: 2)
    let emptyWithMore = try followingBody(users: [], hasMore: 1, totalCount: 20)

    XCTAssertFalse(
      try decode(partialWithoutMore, kind: .following).pagination.hasMore
    )
    XCTAssertTrue(
      try decode(partialWithMore, kind: .following).pagination.hasMore
    )
    let empty = try decode(emptyWithMore, kind: .following)
    XCTAssertTrue(empty.users.isEmpty)
    XCTAssertFalse(empty.pagination.hasMore)
    XCTAssertNil(empty.pagination.nextPage)
  }

  func testFollowersDecodeNestedPaginationAndMixedIntegers() throws {
    let body = try followersBody(
      users: [
        [
          "id": "201", "name": "fan-one", "name_show": "Fan One",
          "portrait": "fan-one?timestamp=1", "intro": "One",
        ],
        ["id": 202, "name": "fan-two", "name_show": "Fan Two"],
        ["id": "201", "name": "duplicate", "name_show": "Duplicate"],
      ],
      pageSize: "100",
      currentPage: "2",
      totalCount: "101",
      totalPage: "2",
      hasMore: "0",
      hasPrevious: "1",
      visibilitySwitch: "1",
      notice: " Only normal accounts "
    )

    let result = try TiebaPublicSocialDecoder.page(
      from: body,
      requestedUserID: 999,
      kind: .followers,
      requestedPage: 2
    )

    XCTAssertEqual(result.requestedUserID, 999)
    XCTAssertEqual(result.kind, .followers)
    XCTAssertEqual(result.users.map(\.id), [201, 202])
    XCTAssertEqual(result.users.first?.portrait, "fan-one")
    XCTAssertEqual(result.pagination.pageSize, 100)
    XCTAssertEqual(result.pagination.currentPage, 2)
    XCTAssertEqual(result.pagination.totalPages, 2)
    XCTAssertEqual(result.pagination.totalCount, 101)
    XCTAssertFalse(result.pagination.hasMore)
    XCTAssertTrue(result.pagination.hasPrevious)
    XCTAssertEqual(result.notice, "Only normal accounts")
    XCTAssertEqual(result.visibilitySwitch, 1)
  }

  func testFollowersEmptyPageAlwaysStopsEvenWhenServerFlagIsSet() throws {
    let body = try followersBody(
      users: [],
      pageSize: 100,
      currentPage: 1,
      totalCount: 100,
      totalPage: 2,
      hasMore: 1,
      hasPrevious: 0
    )

    let result = try decode(body, kind: .followers)

    XCTAssertTrue(result.users.isEmpty)
    XCTAssertFalse(result.pagination.hasMore)
  }

  func testFollowersAllowsEmptyProbePastReportedLastPageAndStops() throws {
    let body = try followersBody(
      users: [],
      pageSize: "100",
      currentPage: "18",
      totalCount: "1695",
      totalPage: "17",
      hasMore: "0",
      hasPrevious: "1"
    )

    let result = try decode(body, kind: .followers, page: 18)

    XCTAssertEqual(result.pagination.currentPage, 18)
    XCTAssertEqual(result.pagination.totalPages, 17)
    XCTAssertTrue(result.pagination.hasPrevious)
    XCTAssertFalse(result.pagination.hasMore)
  }

  func testDecoderRejectsWrongPageInvalidFlagsAndMalformedUserTypes() throws {
    let user: [[String: Any]] = [["id": 1, "name": "user", "name_show": "User"]]
    let wrongPage = try followingBody(users: user, page: 2)
    let invalidFlag = try followingBody(users: user, hasMore: 2)
    let malformedUser = try followingBody(
      users: [["id": "not-an-id", "name": "user", "name_show": "User"]]
    )
    let malformedName = try followingBody(
      users: [["id": 1, "name": 42, "name_show": "User"]]
    )

    for body in [wrongPage, invalidFlag, malformedUser, malformedName] {
      XCTAssertThrowsError(try decode(body, kind: .following)) { error in
        XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
      }
    }

    let followersWrongPage = try followersBody(
      users: user,
      pageSize: 100,
      currentPage: 2,
      totalCount: 1,
      totalPage: 2,
      hasMore: 0,
      hasPrevious: 1
    )
    XCTAssertThrowsError(try decode(followersWrongPage, kind: .followers)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let followersWrongPreviousFlag = try followersBody(
      users: user,
      pageSize: 100,
      currentPage: 1,
      totalCount: 1,
      totalPage: 1,
      hasMore: 0,
      hasPrevious: 1
    )
    XCTAssertThrowsError(try decode(followersWrongPreviousFlag, kind: .followers)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let followersZeroPageSizeWithItems = try followersBody(
      users: user,
      pageSize: 0,
      currentPage: 1,
      totalCount: 1,
      totalPage: 1,
      hasMore: 0,
      hasPrevious: 0
    )
    XCTAssertThrowsError(try decode(followersZeroPageSizeWithItems, kind: .followers)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
  }

  func testDecoderEnforcesArrayAndStringBounds() throws {
    let excessiveUsers: [[String: Any]] =
      (1...(TiebaPublicSocialPolicy.maximumResponseUserCount + 1)).map {
        ["id": $0, "name": "user-\($0)", "name_show": "User \($0)"]
    }
    let excessiveBody = try followingBody(users: excessiveUsers)
    XCTAssertThrowsError(try decode(excessiveBody, kind: .following)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let longName = String(repeating: "a", count: TiebaPublicSocialPolicy.maximumNameBytes + 1)
    let longNameBody = try followingBody(
      users: [["id": 1, "name": longName, "name_show": "User"]]
    )
    XCTAssertThrowsError(try decode(longNameBody, kind: .following)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let longNotice = String(repeating: "a", count: TiebaPublicSocialPolicy.maximumNoticeBytes + 1)
    let longNoticeBody = try followingBody(users: [], notice: longNotice)
    XCTAssertThrowsError(try decode(longNoticeBody, kind: .following)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let longErrorBody = try jsonData([
      "error_code": 1,
      "error_msg": String(
        repeating: "a",
        count: TiebaPublicSocialPolicy.maximumNoticeBytes + 1
      ),
    ])
    XCTAssertThrowsError(try decode(longErrorBody, kind: .following)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
  }

  func testDecoderMapsServerErrorsAndRejectsMissingOrMalformedEnvelopes() throws {
    let serverError = try jsonData(["error_code": "300003", "error_msg": "not available"])
    XCTAssertThrowsError(try decode(serverError, kind: .following)) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .server(code: 300003, message: "not available")
      )
    }

    for body in [
      Data("not-json".utf8),
      try jsonData(["error_code": 0]),
      try jsonData(["error_code": true]),
      try jsonData(["error_code": 0, "follow_list": true]),
    ] {
      XCTAssertThrowsError(try decode(body, kind: .following)) { error in
        XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
      }
    }
  }

  private func decode(
    _ body: Data,
    kind: TiebaUserRelationKind,
    userID: Int64 = 1,
    page: Int = 1
  ) throws -> TiebaUserRelationPage {
    try TiebaPublicSocialDecoder.page(
      from: body,
      requestedUserID: userID,
      kind: kind,
      requestedPage: page
    )
  }
}

final class TiebaPublicSocialClientTests: XCTestCase {
  func testClientUsesBoundedAnonymousTransportAndPreservesRequestContext() async throws {
    let body = try followingBody(
      users: [["id": 7, "name": "user", "name_show": "User"]],
      totalCount: 1
    )
    let transport = PublicSocialCapturingTransport(body: body)
    let client = TiebaClient(transport: transport)

    let page = try await client.getUserRelations(userID: 44, kind: .following, page: 1)

    XCTAssertEqual(page.requestedUserID, 44)
    XCTAssertEqual(page.kind, .following)
    XCTAssertEqual(page.users.map(\.id), [7])
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.maximumBodyBytes, [1 * 1_024 * 1_024])
    XCTAssertEqual(snapshot.requests.count, 1)
    XCTAssertEqual(snapshot.requests.first?.url?.path, "/c/u/follow/followList")
    XCTAssertNil(snapshot.requests.first?.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(snapshot.requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testClientRejectsResponseOverOneMiB() async {
    let maximumBytes = TiebaPublicSocialPolicy.maximumResponseBodyBytes
    let client = TiebaClient(
      transport: PublicSocialUnboundedStubTransport(body: Data(count: maximumBytes + 1))
    )

    do {
      _ = try await client.getUserRelations(userID: 1, kind: .followers)
      XCTFail("Expected oversized response rejection")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, .responseTooLarge(maximumBytes: maximumBytes))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor PublicSocialCapturingTransport: TiebaTransport {
  struct Snapshot: Sendable {
    let requests: [URLRequest]
    let maximumBodyBytes: [Int?]
  }

  private let body: Data
  private var requests = [URLRequest]()
  private var maximumBodyBytes = [Int?]()

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests, maximumBodyBytes: maximumBodyBytes)
  }
}

private struct PublicSocialUnboundedStubTransport: TiebaTransport, Sendable {
  let body: Data

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    TiebaHTTPResponse(body: body, statusCode: 200)
  }
}

private func followingBody(
  users: [[String: Any]],
  page: Any = 1,
  hasMore: Any = 0,
  totalCount: Any = 0,
  visibilitySwitch: Any = 1,
  notice: String = ""
) throws -> Data {
  try jsonData([
    "error_code": 0,
    "error_msg": "",
    "follow_list": users,
    "pn": page,
    "has_more": hasMore,
    "total_follow_num": totalCount,
    "follow_list_switch": visibilitySwitch,
    "tips_text": notice,
  ])
}

private func followersBody(
  users: [[String: Any]],
  pageSize: Any,
  currentPage: Any,
  totalCount: Any,
  totalPage: Any,
  hasMore: Any,
  hasPrevious: Any,
  visibilitySwitch: Any = 1,
  notice: String = "Only normal accounts"
) throws -> Data {
  try jsonData([
    "error_code": "0",
    "error_msg": NSNull(),
    "user_list": users,
    "follow_list_switch": visibilitySwitch,
    "tips_text": notice,
    "page": [
      "page_size": pageSize,
      "current_page": currentPage,
      "total_count": totalCount,
      "total_page": totalPage,
      "has_more": hasMore,
      "has_prev": hasPrevious,
    ],
  ])
}

private func jsonData(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
