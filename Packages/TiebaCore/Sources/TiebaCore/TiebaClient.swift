import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TiebaClientConfiguration: Sendable, Hashable {
  public var clientVersion: String
  public var userAgent: String
  public var requestTimeout: TimeInterval

  public init(
    clientVersion: String = "12.64.1.1",
    userAgent: String = "TiebaPlusPlus/0.1 (iOS)",
    requestTimeout: TimeInterval = 30
  ) {
    self.clientVersion = clientVersion
    self.userAgent = userAgent
    self.requestTimeout = requestTimeout
  }
}

struct TiebaHTTPResponse: Sendable {
  let body: Data
  let statusCode: Int
}

protocol TiebaTransport: Sendable {
  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse
}

final class HTTPSOnlySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      TiebaEndpointPolicy.allowsRedirect(from: response.url, to: request.url) ? request : nil
    )
  }
}

final class URLSessionTiebaTransport: TiebaTransport, @unchecked Sendable {
  private let delegate: HTTPSOnlySessionDelegate
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = HTTPSOnlySessionDelegate()
    self.delegate = delegate
    self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    let (body, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw TiebaClientError.invalidHTTPResponse
    }
    return TiebaHTTPResponse(body: body, statusCode: response.statusCode)
  }
}

public actor TiebaClient {
  private let requestFactory: TiebaRequestFactory
  private let transport: any TiebaTransport

  public init(configuration: TiebaClientConfiguration = .init()) {
    self.requestFactory = TiebaRequestFactory(configuration: configuration)
    self.transport = URLSessionTiebaTransport()
  }

  init(
    configuration: TiebaClientConfiguration = .init(),
    transport: any TiebaTransport
  ) {
    self.requestFactory = TiebaRequestFactory(configuration: configuration)
    self.transport = transport
  }

  public func getThreads(
    forumName: String,
    page: Int = 1,
    pageSize: Int = 30,
    sort: TiebaThreadSort = .replyTime,
    featuredOnly: Bool = false
  ) async throws -> TiebaThreadPage {
    let request = try requestFactory.threads(
      forumName: forumName,
      page: page,
      pageSize: pageSize,
      sort: sort,
      featuredOnly: featuredOnly
    )
    let body = try await send(request)
    let response: FrsPageResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.threadPage(response.data)
  }

  public func getPosts(
    threadID: Int64,
    page: Int = 1,
    pageSize: Int = 30,
    sort: TiebaPostSort = .ascending,
    onlyThreadAuthor: Bool = false,
    includeComments: Bool = false,
    commentsSortedByAgree: Bool = true,
    commentPageSize: Int = 4
  ) async throws -> TiebaPostPage {
    let request = try requestFactory.posts(
      threadID: threadID,
      page: page,
      pageSize: pageSize,
      sort: sort,
      onlyThreadAuthor: onlyThreadAuthor,
      includeComments: includeComments,
      commentsSortedByAgree: commentsSortedByAgree,
      commentPageSize: commentPageSize
    )
    let body = try await send(request)
    let response: PbPageResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.postPage(response.data)
  }

  public func getComments(
    threadID: Int64,
    postID: Int64,
    page: Int = 1
  ) async throws -> TiebaCommentPage {
    try await getComments(
      threadID: threadID,
      anchorID: postID,
      page: page,
      anchorIsComment: false
    )
  }

  public func searchForums(query: String) async throws -> TiebaForumSearchResults {
    let request = try requestFactory.searchForums(query: query)
    let body = try await send(request)
    return try TiebaSearchDecoder.forums(from: body)
  }

  public func searchThreads(
    query: String,
    page: Int = 1,
    pageSize: Int = 20
  ) async throws -> TiebaThreadSearchPage {
    let request = try requestFactory.searchThreads(query: query, page: page, pageSize: pageSize)
    let body = try await send(request)
    return try TiebaSearchDecoder.threads(
      from: body,
      requestedPage: page,
      pageSize: pageSize
    )
  }

  public func getComments(
    threadID: Int64,
    aroundCommentID commentID: Int64,
    page: Int = 1
  ) async throws -> TiebaCommentPage {
    try await getComments(
      threadID: threadID,
      anchorID: commentID,
      page: page,
      anchorIsComment: true
    )
  }

  private func getComments(
    threadID: Int64,
    anchorID: Int64,
    page: Int,
    anchorIsComment: Bool
  ) async throws -> TiebaCommentPage {
    let request = try requestFactory.comments(
      threadID: threadID,
      anchorID: anchorID,
      page: page,
      anchorIsComment: anchorIsComment
    )
    let body = try await send(request)
    let response: PbFloorResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.commentPage(response.data)
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let response: TiebaHTTPResponse
    do {
      response = try await transport.send(request)
    } catch let error as TiebaClientError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw TiebaClientError.network(code: error.errorCode)
    } catch {
      throw TiebaClientError.transportFailure
    }

    guard (200..<300).contains(response.statusCode) else {
      throw TiebaClientError.httpStatus(response.statusCode)
    }
    return response.body
  }

  private func decode<Message: SwiftProtobuf.Message>(_ body: Data) throws -> Message {
    do {
      return try Message(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
  }

  private func checkServerError(code: Int32, message: String) throws {
    guard code == 0 else {
      throw TiebaClientError.server(code: code, message: message)
    }
  }
}
