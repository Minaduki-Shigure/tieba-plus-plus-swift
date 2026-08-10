import Foundation
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
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
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
