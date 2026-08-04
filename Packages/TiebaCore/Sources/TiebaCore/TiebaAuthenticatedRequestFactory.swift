import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct TiebaAuthenticatedRequestFactory: Sendable {
  static let appSalt = TiebaFormSigner.appSalt
  static let followClientVersion = "7.2.0.0"
  static let unfollowClientVersion = "11.10.8.6"
  static let checkInClientVersion = "11.10.8.6"
  static let agreementClientVersion = "22.6.5.1"
  static let writeHost = TiebaRequestFactory.serviceHost

  let configuration: TiebaClientConfiguration
  private let agreementCUID: String

  init(
    configuration: TiebaClientConfiguration,
    agreementCUID: String = TiebaGalaxy2CUID.generate()
  ) {
    self.configuration = configuration
    self.agreementCUID = agreementCUID
  }

  func validateAccount(credential: TiebaBDUSSCredential) throws -> URLRequest {
    try validate(credential)
    return try signedFormRequest(
      path: "/c/s/login",
      fields: [
        ("_client_version", configuration.authenticatedClientVersion),
        ("bdusstoken", credential.bduss),
      ]
    )
  }

  func followedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard userID > 0 else {
      throw TiebaClientError.invalidArgument("User ID must be positive.")
    }
    guard (1...Int(Int32.max)).contains(page) else {
      throw TiebaClientError.invalidArgument("Page must be between 1 and \(Int32.max).")
    }
    guard (1...100).contains(pageSize) else {
      throw TiebaClientError.invalidArgument("Page size must be between 1 and 100.")
    }
    return try signedFormRequest(
      path: "/c/f/forum/like",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", configuration.authenticatedClientVersion),
        ("page_no", String(page)),
        ("page_size", String(pageSize)),
        ("uid", String(userID)),
      ]
    )
  }

  func forumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = FrsPageReqIdl.DataReq()
    data.common = common
    data.kw = forumName
    data.rn = 1
    data.rnNeed = 1

    var message = FrsPageReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/frs/page",
      command: 301_001,
      message: message
    )
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    tbs: String,
    isFollowed: Bool
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let clientVersion = isFollowed ? Self.followClientVersion : Self.unfollowClientVersion
    return try signedFormRequest(
      host: Self.writeHost,
      path: isFollowed ? "/c/c/forum/like" : "/c/c/forum/unfavolike",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("fid", String(forumID)),
        ("kw", forumName),
        ("tbs", tbs),
      ],
      userAgent: "bdtb for Android \(clientVersion)",
      clientUserToken: isFollowed ? nil : String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    tbs: String
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/forum/sign",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.checkInClientVersion),
        ("fid", String(forumID)),
        ("kw", forumName),
        ("tbs", tbs),
      ],
      userAgent: "bdtb for Android \(Self.checkInClientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func threadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    try validateThreadAgreementIdentity(
      expectedUserID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = PbPageReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.pid = firstPostID
    data.pn = 0
    data.rn = 2

    var message = PbPageReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/pb/page",
      command: 302_001,
      message: message
    )
  }

  func setThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64,
    tbs: String,
    isAgreed: Bool
  ) throws -> URLRequest {
    try validate(credential)
    try validateThreadAgreementIdentity(
      expectedUserID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let clientVersion = Self.agreementClientVersion
    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/agree/opAgree",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("agree_type", "2"),
        ("cuid", agreementCUID),
        ("obj_type", "3"),
        ("op_type", isAgreed ? "0" : "1"),
        ("post_id", String(firstPostID)),
        ("tbs", tbs),
        ("thread_id", String(threadID)),
      ],
      userAgent: "bdtb for Android \(clientVersion)"
    )
  }

  static func signature(for fields: [(String, String)]) -> String {
    TiebaFormSigner.signature(for: fields)
  }

  private func signedFormRequest(
    host: String = TiebaRequestFactory.serviceHost,
    path: String,
    fields: [(String, String)],
    userAgent: String? = nil,
    clientUserToken: String? = nil,
    cookie: String? = nil
  ) throws -> URLRequest {
    try validateConfiguration()

    var urlComponents = URLComponents()
    urlComponents.scheme = "https"
    urlComponents.host = host
    urlComponents.path = path
    guard let url = urlComponents.url, Self.allows(url, expectedHost: host) else {
      throw TiebaClientError.invalidEndpoint
    }

    let signedFields = fields + [("sign", Self.signature(for: fields))]
    guard let encodedBody = TiebaFormSigner.encodedBody(for: signedFields) else {
      throw TiebaClientError.invalidArgument("Unable to encode authenticated request.")
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = encodedBody
    request.setValue(userAgent ?? configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    if let clientUserToken {
      request.setValue(clientUserToken, forHTTPHeaderField: "client_user_token")
    }
    if let cookie {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    return request
  }

  private func protobufRequest<Message: SwiftProtobuf.Message>(
    path: String,
    command: Int,
    message: Message
  ) throws -> URLRequest {
    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaRequestFactory.serviceHost
    components.path = path
    components.queryItems = [URLQueryItem(name: "cmd", value: String(command))]
    guard
      let url = components.url,
      Self.allows(url, expectedHost: TiebaRequestFactory.serviceHost)
    else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = TiebaRequestFactory.multipartBody(protobuf: try message.serializedData())
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func validate(_ credential: TiebaBDUSSCredential) throws {
    let value = credential.bduss
    guard value.utf8.count == 192 else {
      throw TiebaClientError.invalidArgument("Account credentials have an invalid format.")
    }
    guard
      value.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x21 && scalar.value <= 0x7E
      })
    else {
      throw TiebaClientError.invalidArgument("Account credentials have an invalid format.")
    }
  }

  private func validateIdentity(expectedUserID: Int64, forumID: Int64) throws {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard forumID > 0 else {
      throw TiebaClientError.invalidArgument("Forum ID must be positive.")
    }
  }

  private func validateThreadAgreementIdentity(
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) throws {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard threadID > 0 else {
      throw TiebaClientError.invalidArgument("Thread ID must be positive.")
    }
    guard firstPostID > 0 else {
      throw TiebaClientError.invalidArgument("First post ID must be positive.")
    }
    guard TiebaGalaxy2CUID.isValid(agreementCUID) else {
      throw TiebaClientError.invalidArgument("Agreement client identifier is invalid.")
    }
  }

  func normalizedForumName(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      !value.isEmpty,
      value.count <= 100,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidArgument(
        "Forum name must contain between 1 and 100 non-control characters."
      )
    }
    return value
  }

  static func isValidTBS(_ value: String) -> Bool {
    value.utf8.count == 26
      && value.utf8.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
      }
  }

  private static func allows(_ url: URL, expectedHost: String) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.caseInsensitiveCompare(expectedHost) == .orderedSame
      && (url.port == nil || url.port == 443)
      && url.user == nil
      && url.password == nil
  }

  private func validateConfiguration() throws {
    guard
      !configuration.clientVersion.isEmpty,
      !configuration.clientVersion.contains(where: { $0.isNewline }),
      !configuration.authenticatedClientVersion.isEmpty,
      !configuration.authenticatedClientVersion.contains(where: { $0.isNewline }),
      !configuration.userAgent.isEmpty,
      !configuration.userAgent.contains(where: { $0.isNewline }),
      configuration.requestTimeout.isFinite,
      configuration.requestTimeout > 0
    else {
      throw TiebaClientError.invalidArgument(
        "Client versions and user agent must be non-empty single-line values, and timeout must be positive."
      )
    }
  }
}
