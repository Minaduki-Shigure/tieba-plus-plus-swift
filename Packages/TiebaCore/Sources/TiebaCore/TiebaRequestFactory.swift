import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum TiebaEndpointPolicy {
  static let serviceHost = "tiebac.baidu.com"

  static func allows(_ url: URL?) -> Bool {
    url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == serviceHost
  }
}

struct TiebaRequestFactory: Sendable {
  static let serviceHost = TiebaEndpointPolicy.serviceHost
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

  private func request(path: String, command: Int, protobuf: Data) throws -> URLRequest {
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
}
