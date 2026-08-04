import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaAuthenticatedRequestFactoryTests: XCTestCase {
  private let factory = TiebaAuthenticatedRequestFactory(configuration: .init())

  func testSignatureMatchesKnownSortedFixture() {
    XCTAssertEqual(
      TiebaAuthenticatedRequestFactory.signature(for: [("b", "2"), ("a", "1")]),
      "42961b9881c2d7cb297e9498f9767789"
    )
  }

  func testAccountValidationUsesCredentialIsolatedHTTPSFormRequest() throws {
    let request = try factory.validateAccount(credential: credential())
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/s/login")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(fields["_client_version"], "22.6.5.1")
    XCTAssertEqual(fields["bdusstoken"]?.count, 192)
    XCTAssertEqual(fields["sign"], "dc626459550a91aee38a92511106d15a")
    XCTAssertNil(fields["stoken"])
    XCTAssertNil(fields["BDUSS"])
  }

  func testFollowedForumsRequestIncludesOnlyRequiredAccountFields() throws {
    let request = try factory.followedForums(
      credential: credential(),
      userID: 957_339_815,
      page: 2,
      pageSize: 50
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/f/forum/like")
    XCTAssertEqual(fields["BDUSS"]?.count, 192)
    XCTAssertEqual(fields["uid"], "957339815")
    XCTAssertEqual(fields["page_no"], "2")
    XCTAssertEqual(fields["page_size"], "50")
    XCTAssertEqual(fields["sign"], "fdf04b89deda3f026ee4ee32575b5d72")
    XCTAssertNil(fields["stoken"])
    XCTAssertNil(fields["friend_uid"])
    XCTAssertNil(fields["is_guest"])
    XCTAssertNil(fields["Cookie"])
  }

  func testRejectsMalformedCredentialsArgumentsAndHeaderInjection() throws {
    XCTAssertThrowsError(
      try factory.validateAccount(
        credential: TiebaBDUSSCredential(bduss: "short")
      )
    )
    XCTAssertThrowsError(
      try factory.validateAccount(
        credential: TiebaBDUSSCredential(
          bduss: String(repeating: "b", count: 191) + "\u{7F}"
        )
      )
    )
    XCTAssertThrowsError(
      try factory.followedForums(
        credential: credential(), userID: 0, page: 1, pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.followedForums(
        credential: credential(), userID: 1, page: 0, pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.followedForums(
        credential: credential(), userID: 1, page: 1, pageSize: 101
      )
    )

    let injected = TiebaAuthenticatedRequestFactory(
      configuration: .init(userAgent: "client\r\nCookie: secret")
    )
    XCTAssertThrowsError(try injected.validateAccount(credential: credential()))
  }

  func testCredentialDescriptionsAndMirrorsNeverExposeSecrets() {
    let credential = credential()
    for output in [String(describing: credential), String(reflecting: credential)] {
      XCTAssertFalse(output.contains(credential.bduss))
    }
    XCTAssertTrue(Array(credential.customMirror.children).isEmpty)
  }

  func testFormEncodingPreservesLiteralPlusInCredentials() throws {
    let credential = TiebaBDUSSCredential(
      bduss: String(repeating: "b", count: 191) + "+"
    )
    let request = try factory.validateAccount(credential: credential)
    let rawBody = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

    XCTAssertTrue(rawBody.contains("%2B"))
    XCTAssertFalse(rawBody.contains(String(repeating: "b", count: 191) + "+"))
    XCTAssertEqual(try formFields(request)["bdusstoken"], credential.bduss)
  }

  private func credential() -> TiebaBDUSSCredential {
    TiebaBDUSSCredential(bduss: String(repeating: "b", count: 192))
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
}
