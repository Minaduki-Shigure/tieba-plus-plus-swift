import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TiebaClientConfiguration: Sendable, Hashable {
  public var clientVersion: String
  public var authenticatedClientVersion: String
  public var userAgent: String
  public var requestTimeout: TimeInterval

  public init(
    clientVersion: String = "12.64.1.1",
    authenticatedClientVersion: String = "22.6.5.1",
    userAgent: String = "TiebaPlusPlus/0.10 (iOS)",
    requestTimeout: TimeInterval = 30
  ) {
    self.clientVersion = clientVersion
    self.authenticatedClientVersion = authenticatedClientVersion
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

enum TiebaRedirectPolicy: Sendable {
  case sameOrigin
  case rejectAll

  func allows(from source: URL?, to destination: URL?) -> Bool {
    switch self {
    case .sameOrigin:
      TiebaEndpointPolicy.allowsRedirect(from: source, to: destination)
    case .rejectAll:
      false
    }
  }
}

final class HTTPSOnlySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let redirectPolicy: TiebaRedirectPolicy

  init(redirectPolicy: TiebaRedirectPolicy) {
    self.redirectPolicy = redirectPolicy
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      redirectPolicy.allows(from: response.url, to: request.url) ? request : nil
    )
  }
}

final class URLSessionTiebaTransport: TiebaTransport, @unchecked Sendable {
  private let delegate: HTTPSOnlySessionDelegate
  private let session: URLSession

  init(redirectPolicy: TiebaRedirectPolicy = .sameOrigin) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = HTTPSOnlySessionDelegate(redirectPolicy: redirectPolicy)
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
    featuredOnly: Bool = false,
    featuredClassificationID: Int? = nil
  ) async throws -> TiebaThreadPage {
    let request = try requestFactory.threads(
      forumName: forumName,
      page: page,
      pageSize: pageSize,
      sort: sort,
      featuredOnly: featuredOnly,
      featuredClassificationID: featuredClassificationID
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
    location: TiebaPostLocation? = nil,
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
      location: location,
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

  public func getUserProfile(userID: Int64) async throws -> TiebaUserProfile {
    let request = try requestFactory.userProfile(userID: userID)
    let body = try await send(request)
    let response: ProfileResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    guard let profile = TiebaProtoMapper.userProfile(response.data) else {
      throw TiebaClientError.invalidProtobuf
    }
    return profile
  }

  public func getUserThreads(
    userID: Int64,
    page: Int = 1,
    pageSize: Int = 20
  ) async throws -> TiebaUserThreadPage {
    let request = try requestFactory.userThreads(
      userID: userID,
      page: page,
      pageSize: pageSize
    )
    let body = try await send(request)
    let response: UserPostResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.userThreadPage(
      response.data,
      userID: userID,
      requestedPage: page,
      pageSize: pageSize
    )
  }

  public func getForumOverview(forumID: Int64) async throws -> TiebaForumOverview {
    let request = try requestFactory.forumOverview(forumID: forumID)
    let body = try await send(request)
    let response: GetForumDetailResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    guard let overview = TiebaProtoMapper.forumOverview(response.data) else {
      throw TiebaClientError.invalidProtobuf
    }
    return overview
  }

  public func getForumModerators(
    forumID: Int64
  ) async throws -> [TiebaForumModeratorRole] {
    let request = try requestFactory.forumModerators(forumID: forumID)
    let body = try await send(request)
    let response: GetBawuInfoResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.forumModeratorRoles(response.data)
  }

  public func getForumRules(forumID: Int64) async throws -> TiebaForumRules {
    let request = try requestFactory.forumRules(forumID: forumID)
    let body = try await send(request)
    let response: ForumRuleDetailResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.forumRules(response.data, requestedForumID: forumID)
  }

  public func searchForums(query: String) async throws -> TiebaForumSearchResults {
    let request = try requestFactory.searchForums(query: query)
    let body = try await send(request)
    return try TiebaSearchDecoder.forums(from: body)
  }

  public func getHotTopics() async throws -> [TiebaHotTopic] {
    let request = try requestFactory.hotTopics()
    let body = try await send(request)
    return try TiebaHotTopicDecoder.topics(from: body)
  }

  public func getHotTopic(
    topicID: Int64,
    topicName: String,
    page: Int = 1,
    pageSize: Int = 10,
    lastID: Int64? = nil
  ) async throws -> TiebaHotTopicPage {
    let request = try requestFactory.hotTopic(
      topicID: topicID,
      topicName: topicName,
      page: page,
      pageSize: pageSize,
      lastID: lastID
    )
    let body = try await send(request)
    return try TiebaHotTopicDecoder.page(
      from: body,
      requestedTopicID: topicID,
      requestedTopicName: topicName.trimmingCharacters(in: .whitespacesAndNewlines),
      requestedPage: page,
      pageSize: pageSize
    )
  }

  public func searchUsers(query: String) async throws -> TiebaUserSearchResults {
    let request = try requestFactory.searchUsers(query: query)
    let body = try await send(request)
    return try TiebaSearchDecoder.users(from: body)
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

  public func searchForumPosts(
    query: String,
    forumName: String,
    page: Int = 1,
    pageSize: Int = 20,
    sort: TiebaThreadSearchSort = .newest,
    filter: TiebaThreadSearchFilter = .all
  ) async throws -> TiebaThreadSearchPage {
    let request = try requestFactory.searchForumPosts(
      query: query,
      forumName: forumName,
      page: page,
      pageSize: pageSize,
      sort: sort,
      filter: filter
    )
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
