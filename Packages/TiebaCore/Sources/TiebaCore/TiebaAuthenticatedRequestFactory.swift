import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct TiebaAuthenticatedRequestFactory: Sendable {
  static let appSalt = TiebaFormSigner.appSalt

  let configuration: TiebaClientConfiguration

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

  static func signature(for fields: [(String, String)]) -> String {
    TiebaFormSigner.signature(for: fields)
  }

  private func signedFormRequest(
    path: String,
    fields: [(String, String)]
  ) throws -> URLRequest {
    try validateConfiguration()

    var urlComponents = URLComponents()
    urlComponents.scheme = "https"
    urlComponents.host = TiebaRequestFactory.serviceHost
    urlComponents.path = path
    guard let url = urlComponents.url, TiebaEndpointPolicy.allows(url) else {
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
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
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

  private func validateConfiguration() throws {
    guard
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
