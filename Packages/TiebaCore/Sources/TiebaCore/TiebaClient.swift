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
    userAgent: String = "TiebaPlusPlus/0.52 (iOS)",
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
  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse
}

extension TiebaTransport {
  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let response = try await send(request)
    if let maximumBodyBytes, response.body.count > maximumBodyBytes {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return response
  }
}

enum TiebaRedirectPolicy: Sendable {
  case sameOrigin
  case rejectAll

  func allows(from source: URL?, to destination: URL?) -> Bool {
    switch self {
    case .sameOrigin:
      TiebaEndpointPolicy.allowsRedirect(from: source, to: destination)
        || TiebaPicturePageEndpointPolicy.allowsRedirect(from: source, to: destination)
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
  private let redirectPolicy: TiebaRedirectPolicy
  private let session: URLSession

  init(
    redirectPolicy: TiebaRedirectPolicy = .sameOrigin,
    configuration: URLSessionConfiguration = .ephemeral
  ) {
    let configuration = Self.hardenedConfiguration(from: configuration)
    let delegate = HTTPSOnlySessionDelegate(redirectPolicy: redirectPolicy)
    self.delegate = delegate
    self.redirectPolicy = redirectPolicy
    self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    let (body, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw TiebaClientError.invalidHTTPResponse
    }
    return TiebaHTTPResponse(body: body, statusCode: response.statusCode)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    guard let maximumBodyBytes else { return try await send(request) }
    guard maximumBodyBytes >= 0 else {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }

    let taskDelegate = BoundedTiebaResponseTaskDelegate(
      maximumResponseBytes: Int64(maximumBodyBytes),
      redirectPolicy: redirectPolicy
    )
    let temporaryURL: URL
    let response: URLResponse
    do {
      (temporaryURL, response) = try await session.download(
        for: request,
        delegate: taskDelegate
      )
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      if taskDelegate.exceededResponseLimit {
        throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
      }
      throw error
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else {
      throw TiebaClientError.invalidHTTPResponse
    }
    if BoundedTiebaResponseTaskDelegate.exceedsLimit(
      totalBytesWritten: 0,
      totalBytesExpected: response.expectedContentLength,
      maximumResponseBytes: Int64(maximumBodyBytes)
    ) {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }

    let fileSize: Int
    do {
      guard
        let measuredSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        measuredSize >= 0
      else {
        throw TiebaClientError.transportFailure
      }
      fileSize = measuredSize
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.transportFailure
    }
    guard fileSize <= maximumBodyBytes else {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    try Task.checkCancellation()

    let body: Data
    do {
      body = try Data(contentsOf: temporaryURL)
    } catch {
      throw TiebaClientError.transportFailure
    }
    try Task.checkCancellation()
    guard body.count <= maximumBodyBytes else {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return TiebaHTTPResponse(body: body, statusCode: response.statusCode)
  }

  private static func hardenedConfiguration(
    from configuration: URLSessionConfiguration
  ) -> URLSessionConfiguration {
    let hardened = URLSessionConfiguration.ephemeral
    hardened.protocolClasses = configuration.protocolClasses
    hardened.httpCookieStorage = nil
    hardened.urlCredentialStorage = nil
    hardened.httpShouldSetCookies = false
    hardened.httpCookieAcceptPolicy = .never
    hardened.urlCache = nil
    hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
    hardened.httpAdditionalHeaders = nil
    return hardened
  }
}

final class BoundedTiebaResponseTaskDelegate: NSObject,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var responseLimitExceeded = false

    func markResponseLimitExceeded() {
      lock.lock()
      responseLimitExceeded = true
      lock.unlock()
    }

    func readResponseLimitExceeded() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return responseLimitExceeded
    }
  }

  private let maximumResponseBytes: Int64
  private let redirectPolicy: TiebaRedirectPolicy
  private let state = State()

  var exceededResponseLimit: Bool { state.readResponseLimitExceeded() }

  init(maximumResponseBytes: Int64, redirectPolicy: TiebaRedirectPolicy) {
    self.maximumResponseBytes = maximumResponseBytes
    self.redirectPolicy = redirectPolicy
  }

  static func exceedsLimit(
    totalBytesWritten: Int64,
    totalBytesExpected: Int64,
    maximumResponseBytes: Int64
  ) -> Bool {
    totalBytesWritten < 0
      || totalBytesWritten > maximumResponseBytes
      || totalBytesExpected > maximumResponseBytes
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

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if Self.exceedsLimit(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpected: totalBytesExpectedToWrite,
      maximumResponseBytes: maximumResponseBytes
    ) {
      state.markResponseLimitExceeded()
      downloadTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
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

  public func getForumChannelThreads(
    forumID: Int64,
    forumName: String,
    channel: TiebaForumChannel,
    page: Int = 1,
    pageSize: Int = 30,
    sort: TiebaForumChannelSort? = nil,
    lastThreadID: Int64? = nil
  ) async throws -> TiebaForumChannelPage {
    let normalizedForumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedForumName.isEmpty else {
      throw TiebaClientError.invalidArgument("Forum name must not be empty.")
    }
    let resolvedSort = sort
      ?? channel.sortOptions.first.map { TiebaForumChannelSort(rawValue: $0.id) }
      ?? .unspecified
    let request = try requestFactory.forumChannelThreads(
      forumID: forumID,
      channel: channel,
      page: page,
      pageSize: pageSize,
      sort: resolvedSort,
      lastThreadID: lastThreadID
    )
    let body = try await send(request)
    let response: GeneralTabListResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.forumChannelPage(
      response.data,
      forumID: forumID,
      forumName: normalizedForumName,
      channel: channel,
      requestedPage: page,
      pageSize: pageSize
    )
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

  public func getPicturePage(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    cursor: TiebaPicturePageCursor,
    direction: TiebaPicturePageDirection = .next,
    onlyThreadAuthor: Bool = false
  ) async throws -> TiebaPicturePage {
    let request = try requestFactory.picturePage(
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      cursor: cursor,
      direction: direction,
      onlyThreadAuthor: onlyThreadAuthor
    )
    let body = try await send(
      request,
      maximumBodyBytes: TiebaPicturePagePolicy.maximumResponseBodyBytes
    )
    return try TiebaPicturePageDecoder.page(from: body, expectedForumID: forumID)
  }

  public func getComments(
    threadID: Int64,
    postID: Int64,
    page: Int = 1
  ) async throws -> TiebaCommentPage {
    try await getComments(
      threadID: threadID,
      postID: postID,
      page: page,
      commentID: nil
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

  public func searchSuggestions(query: String) async throws -> [String] {
    let request = try requestFactory.searchSuggestions(query: query)
    let body = try await send(
      request,
      maximumBodyBytes: TiebaSearchSuggestionPolicy.maximumResponseBodyBytes
    )
    let response: SearchSugResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.searchSuggestions(response.data)
  }

  public func getHotTopics() async throws -> [TiebaHotTopic] {
    let request = try requestFactory.hotTopics()
    let body = try await send(request)
    return try TiebaHotTopicDecoder.topics(from: body)
  }

  public func getHotThreadRanking(
    categoryCode: String = "all"
  ) async throws -> TiebaHotThreadRanking {
    let request = try requestFactory.hotThreadRanking(categoryCode: categoryCode)
    let body = try await send(request)
    let response: HotThreadListResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.hotThreadRanking(response.data)
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
    pageSize: Int = 20,
    sort: TiebaGlobalThreadSearchSort = .newest
  ) async throws -> TiebaThreadSearchPage {
    let request = try requestFactory.searchThreads(
      query: query,
      page: page,
      pageSize: pageSize,
      sort: sort
    )
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
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int = 1
  ) async throws -> TiebaCommentPage {
    try await getComments(
      threadID: threadID,
      postID: postID,
      page: page,
      commentID: commentID
    )
  }

  private func getComments(
    threadID: Int64,
    postID: Int64,
    page: Int,
    commentID: Int64?
  ) async throws -> TiebaCommentPage {
    let request = try requestFactory.comments(
      threadID: threadID,
      postID: postID,
      aroundCommentID: commentID,
      page: page
    )
    let body = try await send(request)
    let response: PbFloorResIdl = try decode(body)
    try checkServerError(code: response.error.errorno, message: response.error.errmsg)
    return TiebaProtoMapper.commentPage(response.data)
  }

  private func send(
    _ request: URLRequest,
    maximumBodyBytes: Int? = nil
  ) async throws -> Data {
    let response: TiebaHTTPResponse
    do {
      response = try await transport.send(
        request,
        maximumBodyBytes: maximumBodyBytes
      )
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
    if let maximumBodyBytes, response.body.count > maximumBodyBytes {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
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
