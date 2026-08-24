import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension TiebaRequestFactory {
  static let picturePageHost = TiebaPicturePageEndpointPolicy.host

  func picturePage(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    cursor: TiebaPicturePageCursor,
    direction: TiebaPicturePageDirection,
    onlyThreadAuthor: Bool,
    source: TiebaPicturePageSource = .post
  ) throws -> URLRequest {
    try validateConfiguration()
    guard forumID > 0 else {
      throw TiebaClientError.invalidArgument("Forum ID must be positive.")
    }
    guard threadID > 0 else {
      throw TiebaClientError.invalidArgument("Thread ID must be positive.")
    }
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !forumName.isEmpty,
      forumName.count <= 100,
      !forumName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidArgument(
        "Forum name must contain between 1 and 100 non-control characters."
      )
    }
    guard
      TiebaPicturePagePolicy.isValidPictureID(cursor.pictureID),
      (1...TiebaPicturePagePolicy.maximumPictureCount).contains(cursor.overallIndex)
    else {
      throw TiebaClientError.invalidArgument("Picture cursor is invalid.")
    }

    let previousCount = direction == .previous ? TiebaPicturePagePolicy.requestedBatchSize : 0
    let nextCount = direction == .next ? TiebaPicturePagePolicy.requestedBatchSize : 0
    let fields = [
      ("_client_type", "2"),
      ("_client_version", "7.2.0.0"),
      ("forum_id", String(forumID)),
      ("from", "1021636m"),
      ("kw", forumName),
      ("next", String(nextCount)),
      ("not_see_lz", onlyThreadAuthor ? "0" : "1"),
      ("obj_type", source.rawValue),
      ("page_name", "PB"),
      ("pic_id", cursor.pictureID),
      ("pic_index", String(cursor.overallIndex)),
      ("prev", String(previousCount)),
      ("q_type", "2"),
      ("subapp_type", "mini"),
      ("tid", String(threadID)),
    ]
    let signedFields = fields + [("sign", TiebaFormSigner.signature(for: fields))]
    guard let body = TiebaFormSigner.encodedBody(for: signedFields) else {
      throw TiebaClientError.invalidArgument("Unable to encode picture page request.")
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.picturePageHost
    components.path = "/c/f/pb/picpage"
    guard let url = components.url, TiebaPicturePageEndpointPolicy.allows(url) else {
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
