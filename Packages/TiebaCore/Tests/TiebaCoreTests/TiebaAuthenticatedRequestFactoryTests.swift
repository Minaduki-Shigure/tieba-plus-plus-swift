import Foundation
import SwiftProtobuf
import TiebaProto
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

  func testOwnFollowingUsesExactAccountBoundFieldSetWithoutTargetUID() throws {
    let request = try factory.ownFollowing(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      page: 2
    )
    let fields = try formFields(request)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/u/follow/followList"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 12.41.7.1")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_type", "_client_version", "pn", "sign"]
    )
    XCTAssertEqual(fields["BDUSS"]?.count, 192)
    XCTAssertEqual(fields["_client_type"], "2")
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["pn"], "2")
    XCTAssertEqual(fields["sign"], "c1631a39f03300bc1336bb22d6f0c97b")
    XCTAssertNil(fields["uid"])
    XCTAssertNil(fields["user_id"])
    XCTAssertNil(fields["stoken"])
    XCTAssertNil(fields["CUID"])
    XCTAssertNil(fields["cuid"])
    XCTAssertNil(fields["phone_imei"])
    let unsigned = fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    XCTAssertEqual(fields["sign"], TiebaFormSigner.signature(for: unsigned))

    let customized = TiebaAuthenticatedRequestFactory(
      configuration: .init(
        clientVersion: "99.99.99",
        authenticatedClientVersion: "88.88.88",
        userAgent: "custom-agent"
      )
    )
    let customizedRequest = try customized.ownFollowing(
      credential: sessionCredential(),
      expectedUserID: 957_339_815,
      page: 2
    )
    XCTAssertEqual(customizedRequest.httpBody, request.httpBody)
    XCTAssertEqual(
      customizedRequest.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1"
    )
  }

  func testSelfLikedForumsRequestPreservesFollowedForumsWireFields() throws {
    let request = try factory.likedForums(
      credential: credential(),
      accountUserID: 957_339_815,
      targetUserID: 957_339_815,
      page: 2,
      pageSize: 50
    )
    let compatibilityRequest = try factory.followedForums(
      credential: credential(),
      userID: 957_339_815,
      page: 2,
      pageSize: 50
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/f/forum/like")
    XCTAssertEqual(request.httpBody, compatibilityRequest.httpBody)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(fields["BDUSS"]?.count, 192)
    XCTAssertEqual(fields["uid"], "957339815")
    XCTAssertEqual(fields["page_no"], "2")
    XCTAssertEqual(fields["page_size"], "50")
    XCTAssertEqual(fields["sign"], "fdf04b89deda3f026ee4ee32575b5d72")
    XCTAssertNil(fields["stoken"])
    XCTAssertNil(fields["friend_uid"])
    XCTAssertNil(fields["is_guest"])
    XCTAssertNil(fields["Cookie"])
    XCTAssertEqual(
      Set(fields.keys),
      ["BDUSS", "_client_version", "page_no", "page_size", "sign", "uid"]
    )
  }

  func testOtherUserLikedForumsRequestSeparatesAccountAndTargetFields() throws {
    let request = try factory.likedForums(
      credential: credential(),
      accountUserID: 957_339_815,
      targetUserID: 123_456_789,
      page: 2,
      pageSize: 50
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://tiebac.baidu.com/c/f/forum/like")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(fields["BDUSS"]?.count, 192)
    XCTAssertEqual(fields["uid"], "957339815")
    XCTAssertEqual(fields["friend_uid"], "123456789")
    XCTAssertEqual(fields["is_guest"], "1")
    XCTAssertEqual(fields["page_no"], "2")
    XCTAssertEqual(fields["page_size"], "50")
    XCTAssertEqual(fields["sign"], "6258dd406a4aeb85485175cf1aafb6a3")
    XCTAssertNil(fields["stoken"])
    XCTAssertNil(fields["Cookie"])
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"))
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "friend_uid", "is_guest", "page_no", "page_size",
        "sign", "uid",
      ]
    )
  }

  func testSelfProfileUsesMinimalBoundAuthenticatedProtobufRequest() throws {
    let userID: Int64 = 957_339_815
    let credential = sessionCredential()
    let request = try factory.selfProfile(
      credential: credential,
      expectedUserID: userID
    )
    let fields = try multipartScalarFields(request)
    let message = try ProfileReqIdl(serializedBytes: try protobufPayload(request))

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/u/user/profile?cmd=303012&format=protobuf"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      TiebaAuthenticatedRequestFactory.selfProfileUserAgent
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_type"), "2")
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(userID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "x_bd_data_type"), "protobuf")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)"
    )
    XCTAssertEqual(
      Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
      [
        "accept-encoding", "client_type", "client_user_token", "content-type", "cookie",
        "user-agent", "x_bd_data_type",
      ]
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "CUID"))
    XCTAssertNil(request.value(forHTTPHeaderField: "CUID_Galaxy2"))
    XCTAssertNil(request.value(forHTTPHeaderField: "CUID_Galaxy3"))
    XCTAssertNil(request.value(forHTTPHeaderField: "TBBRAND"))
    XCTAssertEqual(Set(fields.keys), ["stoken"])
    XCTAssertEqual(fields["stoken"], credential.stoken)

    XCTAssertTrue(message.hasData)
    XCTAssertEqual(message.data.uid, userID)
    XCTAssertEqual(message.data.friendUid, 0)
    XCTAssertEqual(message.data.friendUidPortrait, "")
    XCTAssertEqual(message.data.isGuest, 0)
    XCTAssertEqual(message.data.needPostCount, 1)
    XCTAssertEqual(message.data.pn, 1)
    XCTAssertEqual(message.data.rn, 20)
    XCTAssertEqual(message.data.hasPlist_p, 1)
    XCTAssertEqual(message.data.isFromUsercenter, 1)
    XCTAssertEqual(message.data.page, 1)
    XCTAssertEqual(message.data.common.clientType, 2)
    XCTAssertEqual(
      message.data.common.clientVersion,
      TiebaAuthenticatedRequestFactory.selfProfileClientVersion
    )
    XCTAssertEqual(message.data.common.bduss, credential.bduss)
    XCTAssertEqual(message.data.common.stoken, credential.stoken)
    var expectedCommon = CommonReq()
    expectedCommon.clientType = 2
    expectedCommon.clientVersion = TiebaAuthenticatedRequestFactory.selfProfileClientVersion
    expectedCommon.bduss = credential.bduss
    expectedCommon.stoken = credential.stoken
    XCTAssertEqual(message.data.common, expectedCommon)
  }

  func testUserRelationshipUsesBoundTargetProfileFieldsWithoutDeviceIdentifiers() throws {
    let accountID: Int64 = 957_339_815
    let targetID: Int64 = 123_456_789
    let credential = sessionCredential()
    let request = try factory.userRelationship(
      credential: credential,
      expectedUserID: accountID,
      targetUserID: targetID
    )
    let fields = try multipartScalarFields(request)
    let message = try ProfileReqIdl(serializedBytes: try protobufPayload(request))

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://tiebac.baidu.com/c/u/user/profile?cmd=303012&format=protobuf"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "client_user_token"), String(accountID))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(Set(fields.keys), ["stoken"])
    XCTAssertEqual(message.data.uid, accountID)
    XCTAssertEqual(message.data.friendUid, targetID)
    XCTAssertEqual(message.data.isGuest, 1)
    XCTAssertEqual(message.data.needPostCount, 1)
    XCTAssertEqual(message.data.pn, 1)
    XCTAssertEqual(message.data.rn, 20)
    XCTAssertEqual(message.data.hasPlist_p, 1)
    XCTAssertEqual(message.data.isFromUsercenter, 1)
    XCTAssertEqual(message.data.page, 1)
    XCTAssertEqual(message.data.common.bduss, credential.bduss)
    XCTAssertEqual(message.data.common.stoken, credential.stoken)
    XCTAssertNil(request.value(forHTTPHeaderField: "CUID"))
    XCTAssertNil(request.value(forHTTPHeaderField: "CUID_Galaxy2"))
    XCTAssertNil(request.value(forHTTPHeaderField: "TBBRAND"))
  }

  func testUserFollowRequestsUseMinimalHTTPSFieldsAndExactOperationShape() throws {
    let accountID: Int64 = 957_339_815
    let targetID: Int64 = 123_456_789
    let credential = sessionCredential()
    let tbs = "91be894d01799c4991be894d01"

    let follow = try factory.setUserFollowState(
      credential: credential,
      expectedUserID: accountID,
      targetUserID: targetID,
      targetPortrait: "target-portrait",
      tbs: tbs,
      isFollowed: true
    )
    let followFields = try formFields(follow)
    XCTAssertEqual(follow.url?.absoluteString, "https://tiebac.baidu.com/c/c/user/follow")
    XCTAssertEqual(follow.value(forHTTPHeaderField: "Cookie"), "ka=open")
    XCTAssertEqual(follow.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 11.10.8.6")
    XCTAssertEqual(
      Set(followFields.keys),
      [
        "BDUSS", "_client_version", "authsid", "from_type", "in_live", "portrait",
        "sign", "stoken", "tbs",
      ]
    )
    XCTAssertEqual(followFields["portrait"], "target-portrait")
    XCTAssertEqual(followFields["stoken"], credential.stoken)
    XCTAssertNil(followFields["timestamp"])
    XCTAssertNil(followFields["cuid"])
    XCTAssertNil(followFields["_phone_imei"])

    let unfollow = try factory.setUserFollowState(
      credential: credential,
      expectedUserID: accountID,
      targetUserID: targetID,
      targetPortrait: "target-portrait",
      tbs: tbs,
      isFollowed: false,
      timestampMilliseconds: 1_723_456_789_012
    )
    let unfollowFields = try formFields(unfollow)
    XCTAssertEqual(unfollow.url?.absoluteString, "https://tiebac.baidu.com/c/c/user/unfollow")
    XCTAssertEqual(unfollowFields["timestamp"], "1723456789012")
    XCTAssertEqual(Set(unfollowFields.keys), Set(followFields.keys).union(["timestamp"]))
  }

  func testUserRelationshipAndFollowRejectInvalidIdentityContext() throws {
    for targetID in [Int64(0), 957_339_815] {
      XCTAssertThrowsError(
        try factory.userRelationship(
          credential: sessionCredential(),
          expectedUserID: 957_339_815,
          targetUserID: targetID
        )
      )
    }
    for portrait in ["", "target?t=1", "target#fragment", "unsafe\nportrait"] {
      XCTAssertThrowsError(
        try factory.setUserFollowState(
          credential: sessionCredential(),
          expectedUserID: 957_339_815,
          targetUserID: 123_456_789,
          targetPortrait: portrait,
          tbs: "91be894d01799c4991be894d01",
          isFollowed: true
        )
      )
    }
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
      try factory.ownFollowing(
        credential: sessionCredential(), expectedUserID: 0, page: 1
      )
    )
    XCTAssertThrowsError(
      try factory.ownFollowing(
        credential: sessionCredential(), expectedUserID: 1, page: 0
      )
    )
    XCTAssertThrowsError(
      try factory.ownFollowing(
        credential: sessionCredential(), expectedUserID: 1, page: Int(Int32.max) + 1
      )
    )
    XCTAssertThrowsError(
      try factory.ownFollowing(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "b", count: 192),
          stoken: "short",
          bdussCookieName: .bduss
        ),
        expectedUserID: 1,
        page: 1
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
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 0,
        targetUserID: 1,
        page: 1,
        pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.selfProfile(
        credential: sessionCredential(),
        expectedUserID: 0
      )
    )
    XCTAssertThrowsError(
      try factory.selfProfile(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "b", count: 192),
          stoken: "short",
          bdussCookieName: .bduss
        ),
        expectedUserID: 1
      )
    )
    XCTAssertThrowsError(
      try factory.selfProfile(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "b", count: 192),
          stoken: String(repeating: "s", count: 63) + "\n",
          bdussCookieName: .bduss
        ),
        expectedUserID: 1
      )
    )
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 0,
        page: 1,
        pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2,
        page: 0,
        pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2,
        page: Int(Int32.max) + 1,
        pageSize: 50
      )
    )
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2,
        page: 1,
        pageSize: 0
      )
    )
    XCTAssertThrowsError(
      try factory.likedForums(
        credential: credential(),
        accountUserID: 1,
        targetUserID: 2,
        page: 1,
        pageSize: 101
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

  private func sessionCredential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func multipartScalarFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    let dataPartMarker = Data(
      "--\(TiebaRequestFactory.multipartBoundary)\r\n"
        .appending("Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n")
        .utf8
    )
    let dataPartRange = try XCTUnwrap(body.range(of: dataPartMarker))
    let scalarBytes = body[..<dataPartRange.lowerBound]
    let fieldNamePrefix = "Content-Disposition: form-data; name=\""
    let fieldNameSuffix = "\"\r\n\r\n"
    let text = try XCTUnwrap(String(data: scalarBytes, encoding: .utf8))
    var fields = [String: String]()
    for part in text.components(separatedBy: "--\(TiebaRequestFactory.multipartBoundary)\r\n") {
      guard
        part.hasPrefix(fieldNamePrefix),
        let nameEnd = part.range(of: fieldNameSuffix)
      else { continue }
      let nameStart = part.index(part.startIndex, offsetBy: fieldNamePrefix.count)
      let name = String(part[nameStart..<nameEnd.lowerBound])
      let valueStart = nameEnd.upperBound
      let value = String(part[valueStart...]).trimmingCharacters(in: .newlines)
      XCTAssertNil(fields[name], "Duplicate multipart scalar field: \(name)")
      fields[name] = value
    }
    return fields
  }

  private func protobufPayload(_ request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let marker = Data(
      "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    let range = try XCTUnwrap(body.range(of: marker))
    XCTAssertEqual(body.suffix(suffix.count), suffix)
    return body.subdata(in: range.upperBound..<(body.count - suffix.count))
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
