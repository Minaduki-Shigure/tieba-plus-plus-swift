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
      _ = try await oversizedForums.getFollowedForums(
        credential: credential(),
        userID: 957_339_815
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
