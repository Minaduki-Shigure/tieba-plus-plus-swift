import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension TiebaRequestFactory {
  func reportPage(postID: Int64) throws -> URLRequest {
    try validateConfiguration()
    guard postID > 0 else {
      throw TiebaClientError.invalidArgument("Post ID must be positive.")
    }
    guard
      let body = TiebaFormSigner.encodedBody(for: [
        ("category", "1"),
        ("pid", String(postID)),
      ])
    else {
      throw TiebaClientError.invalidArgument("Unable to encode report page request.")
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaReportPagePolicy.endpointHost
    components.path = TiebaReportPagePolicy.endpointPath
    guard let url = components.url, TiebaReportPagePolicy.allowsEndpoint(url) else {
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
    request.setValue(
      "application/json, application/x-javascript",
      forHTTPHeaderField: "Accept"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }
}
