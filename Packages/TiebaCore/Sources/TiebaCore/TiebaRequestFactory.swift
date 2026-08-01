import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum TiebaEndpointPolicy {
  static let protobufHost = "tiebac.baidu.com"
  static let webHost = "tieba.baidu.com"
  static let allowedHosts: Set<String> = [protobufHost, webHost]

  static func allows(_ url: URL?) -> Bool {
    guard
      url?.scheme?.lowercased() == "https",
      let host = url?.host?.lowercased()
    else { return false }
    return allowedHosts.contains(host)
  }

  static func allowsRedirect(from source: URL?, to destination: URL?) -> Bool {
    guard allows(source), allows(destination) else { return false }
    return source?.host?.caseInsensitiveCompare(destination?.host ?? "") == .orderedSame
  }
}

struct TiebaRequestFactory: Sendable {
  static let serviceHost = TiebaEndpointPolicy.protobufHost
  static let webHost = TiebaEndpointPolicy.webHost
  static let multipartBoundary = "-*_r1999"

  let configuration: TiebaClientConfiguration

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: TiebaThreadSort,
    featuredOnly: Bool
  ) throws -> URLRequest {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else {
      throw TiebaClientError.invalidArgument("Forum name must not be empty.")
    }
    try validate(page: page)
    try validate(pageSize: pageSize, maximum: 100)

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion

    var data = FrsPageReqIdl.DataReq()
    data.common = common
    data.kw = forumName
    data.pn = Int32(page == 1 ? 0 : page)
    data.rn = Int32(pageSize)
    data.rnNeed = Int32(pageSize + 5)
    data.isGood = featuredOnly ? 1 : 0
    data.sortType = sort.rawValue

    var message = FrsPageReqIdl()
    message.data = data
    return try request(
      path: "/c/f/frs/page",
      command: 301_001,
      protobuf: message.serializedData()
    )
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    includeComments: Bool,
    commentsSortedByAgree: Bool,
    commentPageSize: Int
  ) throws -> URLRequest {
    try validate(identifier: threadID, name: "Thread ID")
    try validate(page: page)
    try validate(pageSize: pageSize, maximum: 100)
    try validate(pageSize: commentPageSize, maximum: 50, name: "Comment page size")

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion

    var data = PbPageReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.pn = Int32(page)
    data.rn = Int32(max(pageSize, 2))
    data.r = sort.rawValue
    data.lz = onlyThreadAuthor ? 1 : 0
    if includeComments {
      data.withFloor = 1
      data.floorSortType = commentsSortedByAgree ? 1 : 0
      data.floorRn = Int32(commentPageSize)
    }

    var message = PbPageReqIdl()
    message.data = data
    return try request(
      path: "/c/f/pb/page",
      command: 302_001,
      protobuf: message.serializedData()
    )
  }

  func comments(
    threadID: Int64,
    anchorID: Int64,
    page: Int,
    anchorIsComment: Bool
  ) throws -> URLRequest {
    try validate(identifier: threadID, name: "Thread ID")
    try validate(identifier: anchorID, name: anchorIsComment ? "Comment ID" : "Post ID")
    try validate(page: page)

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion

    var data = PbFloorReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    if anchorIsComment {
      data.spid = anchorID
    } else {
      data.pid = anchorID
    }
    data.pn = Int32(page)

    var message = PbFloorReqIdl()
    message.data = data
    return try request(
      path: "/c/f/pb/floor",
      command: 302_002,
      protobuf: message.serializedData()
    )
  }

  func searchForums(query: String) throws -> URLRequest {
    let query = try validatedSearchQuery(query)
    return try webRequest(
      path: "/mo/q/search/forum",
      queryItems: [URLQueryItem(name: "word", value: query)]
    )
  }

  func searchThreads(query: String, page: Int, pageSize: Int) throws -> URLRequest {
    let query = try validatedSearchQuery(query)
    try validate(page: page)
    try validate(pageSize: pageSize, maximum: 50)
    return try webRequest(
      path: "/mo/q/search/thread",
      queryItems: [
        URLQueryItem(name: "word", value: query),
        URLQueryItem(name: "pn", value: String(page)),
        URLQueryItem(name: "rn", value: String(pageSize)),
        URLQueryItem(name: "st", value: "2"),
        URLQueryItem(name: "tt", value: "1"),
        URLQueryItem(name: "ct", value: "1"),
        URLQueryItem(name: "is_use_zonghe", value: "1"),
        URLQueryItem(name: "cv", value: "99.9.101"),
      ]
    )
  }

  private func request(path: String, command: Int, protobuf: Data) throws -> URLRequest {
    try validateConfiguration()

    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.serviceHost
    components.path = path
    components.queryItems = [URLQueryItem(name: "cmd", value: String(command))]

    guard
      let url = components.url,
      TiebaEndpointPolicy.allows(url)
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
    request.httpBody = Self.multipartBody(protobuf: protobuf)
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(
      "multipart/form-data; boundary=\(Self.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func webRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
    try validateConfiguration()

    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.webHost
    components.path = path
    components.queryItems = queryItems

    guard let url = components.url, TiebaEndpointPolicy.allows(url) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  static func multipartBody(protobuf: Data) -> Data {
    var body = Data()
    body.append(Data("--\(multipartBoundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8))
    body.append(protobuf)
    body.append(Data("\r\n--\(multipartBoundary)--\r\n".utf8))
    return body
  }

  private func validate(page: Int) throws {
    guard page >= 1, page <= Int(Int32.max) else {
      throw TiebaClientError.invalidArgument("Page must be between 1 and \(Int32.max).")
    }
  }

  private func validate(pageSize: Int, maximum: Int, name: String = "Page size") throws {
    guard (1...maximum).contains(pageSize) else {
      throw TiebaClientError.invalidArgument("\(name) must be between 1 and \(maximum).")
    }
  }

  private func validate(identifier: Int64, name: String) throws {
    guard identifier > 0 else {
      throw TiebaClientError.invalidArgument("\(name) must be positive.")
    }
  }

  private func validatedSearchQuery(_ rawValue: String) throws -> String {
    let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 100 else {
      throw TiebaClientError.invalidArgument(
        "Search query must contain between 1 and 100 characters."
      )
    }
    return query
  }

  private func validateConfiguration() throws {
    guard
      !configuration.clientVersion.isEmpty,
      !configuration.clientVersion.contains(where: { $0.isNewline }),
      !configuration.userAgent.isEmpty,
      !configuration.userAgent.contains(where: { $0.isNewline }),
      configuration.requestTimeout.isFinite,
      configuration.requestTimeout > 0
    else {
      throw TiebaClientError.invalidArgument(
        "Client version and user agent must be non-empty single-line values, and timeout must be positive."
      )
    }
  }
}
