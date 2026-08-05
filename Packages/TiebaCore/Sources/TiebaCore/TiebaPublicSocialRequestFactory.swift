import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension TiebaRequestFactory {
  static let publicSocialClientVersion = "22.6.5.1"

  func userRelations(
    userID: Int64,
    kind: TiebaUserRelationKind,
    page: Int
  ) throws -> URLRequest {
    try validateConfiguration()
    guard userID > 0 else {
      throw TiebaClientError.invalidArgument("User ID must be positive.")
    }
    guard page >= 1, page <= Int(Int32.max) else {
      throw TiebaClientError.invalidArgument("Page must be between 1 and \(Int32.max).")
    }

    let fields = [
      ("_client_version", Self.publicSocialClientVersion),
      ("pn", String(page)),
      ("uid", String(userID)),
    ]
    let signedFields = fields + [("sign", TiebaFormSigner.signature(for: fields))]
    guard let body = TiebaFormSigner.encodedBody(for: signedFields) else {
      throw TiebaClientError.invalidArgument("Unable to encode public user relation request.")
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.serviceHost
    switch kind {
    case .following:
      components.path = "/c/u/follow/followList"
    case .followers:
      components.path = "/c/u/fans/page"
    }
    guard let url = components.url, TiebaEndpointPolicy.allows(url) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = body
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }
}
