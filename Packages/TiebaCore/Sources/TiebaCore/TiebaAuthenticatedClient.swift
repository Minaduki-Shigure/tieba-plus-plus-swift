import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct TiebaForumCheckInResourceKey: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
}

private struct TiebaForumCheckInIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaBDUSSCredential
  let forumName: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss && lhs.forumName == rhs.forumName
  }

  var description: String { "TiebaForumCheckInIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["forumName": forumName], displayStyle: .struct)
  }
}

private struct TiebaForumCheckInFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaForumCheckInIdentity
  let task: Task<TiebaForumAccountState, Swift.Error>

  var description: String { "TiebaForumCheckInFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["id": id, "identity": identity], displayStyle: .struct)
  }
}

private struct TiebaAgreementResourceKey: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let target: TiebaAgreementTarget
}

private struct TiebaAgreementIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaBDUSSCredential
  let forumID: Int64
  let forumName: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.forumID == rhs.forumID
      && lhs.forumName == rhs.forumName
  }

  var description: String { "TiebaAgreementIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "forumID": forumID,
        "forumName": forumName,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaAgreementFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaAgreementIdentity
  let targetAgreed: Bool
  let task: Task<TiebaAgreementState, Swift.Error>

  var description: String { "TiebaAgreementFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "targetAgreed": targetAgreed,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaAgreementAccountTail: Sendable {
  let id: UUID
  let task: Task<Void, Never>
}

private struct TiebaThreadCloudFavoriteResourceKey: Hashable, Sendable {
  let userID: Int64
  let threadID: Int64
}

private struct TiebaThreadCloudFavoriteIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaSessionCredential
  let forumID: Int64

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.credential.stoken == rhs.credential.stoken
      && lhs.credential.bdussCookieName == rhs.credential.bdussCookieName
      && lhs.forumID == rhs.forumID
  }

  var description: String { "TiebaThreadCloudFavoriteIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["forumID": forumID], displayStyle: .struct)
  }
}

private struct TiebaThreadCloudFavoriteFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaThreadCloudFavoriteIdentity
  let markedPostID: Int64?
  let task: Task<TiebaThreadCloudFavoriteState, Swift.Error>

  var description: String { "TiebaThreadCloudFavoriteFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "markedPostID": markedPostID as Any,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaThreadCloudFavoriteWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaTextReplyFlightIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let expectedUserID: Int64
  let submission: TiebaTextReplySubmission
  let normalizedForumName: String
  private let bduss: String
  private let stoken: String
  private let cookieName: TiebaBDUSSCookieName

  init(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) {
    self.expectedUserID = expectedUserID
    self.submission = submission
    self.normalizedForumName = normalizedForumName
    self.bduss = credential.bduss
    self.stoken = credential.stoken
    self.cookieName = credential.bdussCookieName
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.expectedUserID == rhs.expectedUserID
      && lhs.submission == rhs.submission
      && lhs.normalizedForumName == rhs.normalizedForumName
      && lhs.bduss == rhs.bduss
      && lhs.stoken == rhs.stoken
      && lhs.cookieName == rhs.cookieName
  }

  var description: String { "TiebaTextReplyFlightIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "expectedUserID": expectedUserID,
        "submissionID": submission.submissionID,
        "forumID": submission.forumID,
        "threadID": submission.threadID,
        "target": submission.target,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaTextReplyFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let identity: TiebaTextReplyFlightIdentity
  let task: Task<TiebaTextReplyResult, Swift.Error>
  var stage: TiebaTextReplyFlightStage

  var isCompleted: Bool { stage == .completed }

  var description: String { "TiebaTextReplyFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "identity": identity,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaTextReplyFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private struct TiebaTextReplyAccountTail: Sendable {
  let submissionID: UUID
  let task: Task<Void, Never>
}

private enum TiebaTextReplyWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

public actor TiebaAuthenticatedClient {
  static let accountResponseMaximumBytes = 512 * 1_024
  static let webSessionResponseMaximumBytes = 256 * 1_024
  static let followedForumsResponseMaximumBytes = 2 * 1_024 * 1_024
  static let cloudFavoritesResponseMaximumBytes = 2 * 1_024 * 1_024
  static let threadCloudFavoriteStateResponseMaximumBytes = 4 * 1_024 * 1_024
  static let threadCloudFavoriteWriteResponseMaximumBytes = 64 * 1_024
  static let concernResponseMaximumBytes = 4 * 1_024 * 1_024
  static let notificationResponseMaximumBytes = 2 * 1_024 * 1_024
  static let inboxUnreadSummaryResponseMaximumBytes = 64 * 1_024
  static let forumMembershipResponseMaximumBytes = 512 * 1_024
  static let forumFollowWriteResponseMaximumBytes = 64 * 1_024
  static let forumCheckInResponseMaximumBytes = 64 * 1_024
  static let agreementPageResponseMaximumBytes = 8 * 1_024 * 1_024
  static let subpostAgreementPageResponseMaximumBytes = 4 * 1_024 * 1_024
  static let threadAgreementWriteResponseMaximumBytes = 64 * 1_024
  static let textReplyWriteResponseMaximumBytes = 128 * 1_024
  static let retainedTextReplySubmissionLimit = 64

  private let requestFactory: TiebaAuthenticatedRequestFactory
  private let transport: any TiebaTransport
  private var forumCheckInFlights = [TiebaForumCheckInResourceKey: TiebaForumCheckInFlight]()
  private var forumCheckInSharedWaiterCounts = [UUID: Int]()
  private var forumCheckInConflictWaiters = [
    TiebaForumCheckInResourceKey: [UUID: CheckedContinuation<Void, Never>]
  ]()
  private var agreementFlights = [
    TiebaAgreementResourceKey: TiebaAgreementFlight
  ]()
  private var agreementSharedWaiterCounts = [UUID: Int]()
  private var agreementConflictWaiterCounts = [TiebaAgreementResourceKey: Int]()
  private var agreementAccountTails = [Int64: TiebaAgreementAccountTail]()
  private var threadCloudFavoriteFlights = [
    TiebaThreadCloudFavoriteResourceKey: TiebaThreadCloudFavoriteFlight
  ]()
  private var threadCloudFavoriteSharedWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaThreadCloudFavoriteWaitOutcome, Never>]
  ]()
  private var threadCloudFavoriteConflictWaiters = [
    TiebaThreadCloudFavoriteResourceKey: [
      UUID: CheckedContinuation<TiebaThreadCloudFavoriteWaitOutcome, Never>
    ]
  ]()
  private var textReplyFlights = [UUID: TiebaTextReplyFlight]()
  private var textReplyFlightOrder = [UUID]()
  private var textReplyAccountTails = [Int64: TiebaTextReplyAccountTail]()
  private var textReplyWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaTextReplyWaitOutcome, Never>]
  ]()

  public init(configuration: TiebaClientConfiguration = .init()) {
    self.requestFactory = TiebaAuthenticatedRequestFactory(configuration: configuration)
    self.transport = URLSessionTiebaTransport(redirectPolicy: .rejectAll)
  }

  init(
    configuration: TiebaClientConfiguration = .init(),
    transport: any TiebaTransport
  ) {
    self.requestFactory = TiebaAuthenticatedRequestFactory(configuration: configuration)
    self.transport = transport
  }

  public func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    let request = try requestFactory.validateAccount(credential: credential)
    let body = try await send(
      request,
      maximumBodyBytes: Self.accountResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.account(from: body)
  }

  public func validateSession(
    credential: TiebaSessionCredential
  ) async throws -> TiebaAuthenticatedAccount {
    let appRequest = try requestFactory.validateSessionApp(credential: credential)
    let appBody = try await send(
      appRequest,
      maximumBodyBytes: Self.accountResponseMaximumBytes
    )
    let account = try TiebaAuthenticatedDecoder.account(from: appBody)
    try Task.checkCancellation()

    let webRequest = try requestFactory.validateSessionWeb(credential: credential)
    let webBody = try await send(
      webRequest,
      maximumBodyBytes: Self.webSessionResponseMaximumBytes
    )
    let webUserID = try TiebaAuthenticatedDecoder.webAccountID(from: webBody)
    try Task.checkCancellation()
    guard webUserID == account.userID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return account
  }

  public func getCloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int = 0,
    pageSize: Int = 20
  ) async throws -> TiebaCloudFavoritePage {
    let request = try requestFactory.cloudFavorites(
      credential: credential,
      expectedUserID: expectedUserID,
      offset: offset,
      pageSize: pageSize
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.cloudFavoritesResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.cloudFavorites(
      from: body,
      expectedUserID: expectedUserID,
      offset: offset,
      pageSize: pageSize
    )
  }

  public func getThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteState {
    try await getThreadCloudFavoriteContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    ).state
  }

  public func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    try Task.checkCancellation()
    try requestFactory.validateThreadCloudFavoriteWriteArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID
    )

    let resourceKey = TiebaThreadCloudFavoriteResourceKey(
      userID: expectedUserID,
      threadID: threadID
    )
    let identity = TiebaThreadCloudFavoriteIdentity(
      credential: credential,
      forumID: forumID
    )
    if let flight = threadCloudFavoriteFlights[resourceKey] {
      if flight.identity == identity, flight.markedPostID == markedPostID {
        try await waitForSharedThreadCloudFavoriteFlight(
          resourceKey: resourceKey,
          flightID: flight.id
        )
        return try await flight.task.value
      }

      try await waitForConflictingThreadCloudFavoriteFlight(
        resourceKey: resourceKey,
        flightID: flight.id
      )
      return try await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let task: Task<TiebaThreadCloudFavoriteState, Swift.Error> = Task.detached { [self] in
      try await performThreadCloudFavoriteWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      )
    }
    threadCloudFavoriteFlights[resourceKey] = TiebaThreadCloudFavoriteFlight(
      id: flightID,
      identity: identity,
      markedPostID: markedPostID,
      task: task
    )
    defer { clearThreadCloudFavoriteFlight(resourceKey: resourceKey, flightID: flightID) }
    return try await task.value
  }

  public func submitTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    try Task.checkCancellation()
    let normalizedForumName = try requestFactory.validateTextReplyArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    let identity = TiebaTextReplyFlightIdentity(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName
    )
    if let flight = textReplyFlights[submission.submissionID] {
      guard flight.identity == identity else {
        throw TiebaClientError.replySubmissionIDConflict
      }
      return try await waitForTextReplyFlight(
        submissionID: submission.submissionID,
        task: flight.task
      )
    }

    let predecessor = textReplyAccountTails[expectedUserID]?.task
    let task: Task<TiebaTextReplyResult, Swift.Error> = Task.detached { [self] in
      if let predecessor {
        await predecessor.value
      }
      try Task.checkCancellation()
      return try await performTextReplySubmission(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission,
        normalizedForumName: normalizedForumName
      )
    }
    textReplyFlights[submission.submissionID] = TiebaTextReplyFlight(
      identity: identity,
      task: task,
      stage: .queued
    )
    textReplyFlightOrder.append(submission.submissionID)

    let tail = Task.detached { [self] in
      await finishTextReplyFlight(
        submissionID: submission.submissionID,
        expectedUserID: expectedUserID,
        task: task
      )
    }
    textReplyAccountTails[expectedUserID] = TiebaTextReplyAccountTail(
      submissionID: submission.submissionID,
      task: tail
    )
    return try await waitForTextReplyFlight(
      submissionID: submission.submissionID,
      task: task
    )
  }

  public func getConcernFeed(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    pageTag: String? = nil,
    lastRequestUnix: UInt64 = 0
  ) async throws -> TiebaConcernPage {
    let request = try requestFactory.concernFeed(
      credential: credential,
      expectedUserID: expectedUserID,
      pageTag: pageTag,
      lastRequestUnix: lastRequestUnix
    )
    let response: UserLikeResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.concernResponseMaximumBytes
    )
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    let page = try TiebaProtoMapper.concernPage(
      response.data,
      expectedUserID: expectedUserID,
      requestedPageTag: pageTag
    )
    guard Self.concernResponseRequestsSessionValidation(response.data, page: page) else {
      return page
    }

    do {
      let account = try await validateSession(credential: credential)
      guard account.userID == expectedUserID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return page
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TiebaClientError {
      switch error {
      case .server, .invalidAuthenticatedResponse:
        throw TiebaClientError.invalidAuthenticatedResponse
      default:
        throw error
      }
    }
  }

  public func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int = 1,
    pageSize: Int = 50
  ) async throws -> TiebaFollowedForumPage {
    let request = try requestFactory.followedForums(
      credential: credential,
      userID: userID,
      page: page,
      pageSize: pageSize
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.followedForumsResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.followedForums(
      from: body,
      page: page,
      pageSize: pageSize
    )
  }

  public func getNotifications(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    kind: TiebaNotificationKind,
    page: Int = 1
  ) async throws -> TiebaNotificationPage {
    let request = try requestFactory.notifications(
      credential: credential,
      expectedUserID: expectedUserID,
      kind: kind,
      page: page
    )
    switch kind {
    case .replies:
      let response: ReplyMeResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.notificationResponseMaximumBytes
      )
      return try TiebaNotificationDecoder.replyPage(
        from: response,
        expectedUserID: expectedUserID,
        requestedPage: page
      )
    case .mentions:
      let body = try await send(
        request,
        maximumBodyBytes: Self.notificationResponseMaximumBytes
      )
      return try TiebaNotificationDecoder.mentionPage(
        from: body,
        expectedUserID: expectedUserID,
        requestedPage: page
      )
    }
  }

  public func getInboxUnreadSummary(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64
  ) async throws -> TiebaInboxUnreadSummary {
    let request = try requestFactory.inboxUnreadSummary(
      credential: credential,
      expectedUserID: expectedUserID
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.inboxUnreadSummaryResponseMaximumBytes
    )
    return try TiebaInboxUnreadSummaryDecoder.summary(
      from: body,
      expectedUserID: expectedUserID
    )
  }

  public func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    ).membership
  }

  public func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: true
    ).state
  }

  public func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    let context = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    guard context.membership.isFollowed != isFollowed else {
      return context.membership
    }

    let request = try requestFactory.setForumFollowState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: context.membership.forumName,
      tbs: context.tbs,
      isFollowed: isFollowed
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumFollowWriteResponseMaximumBytes
    )
    try TiebaAuthenticatedDecoder.checkForumFollowWriteResponse(body)
    return TiebaForumMembership(
      userID: context.membership.userID,
      forumID: context.membership.forumID,
      forumName: context.membership.forumName,
      isFollowed: isFollowed
    )
  }

  public func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    try Task.checkCancellation()
    let forumName = try requestFactory.normalizedForumName(forumName)
    let resourceKey = TiebaForumCheckInResourceKey(
      userID: expectedUserID,
      forumID: forumID
    )
    let identity = TiebaForumCheckInIdentity(
      credential: credential,
      forumName: forumName
    )

    while let flight = forumCheckInFlights[resourceKey] {
      if flight.identity == identity {
        registerSharedForumCheckInWaiter(flightID: flight.id)
        defer { unregisterSharedForumCheckInWaiter(flightID: flight.id) }
        return try await flight.task.value
      }
      try await waitForForumCheckInFlight(
        resourceKey: resourceKey,
        flightID: flight.id
      )
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let task: Task<TiebaForumAccountState, Swift.Error> = Task.detached { [self] in
      try await performForumCheckIn(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    }
    forumCheckInFlights[resourceKey] = TiebaForumCheckInFlight(
      id: flightID,
      identity: identity,
      task: task
    )
    defer { clearForumCheckInFlight(resourceKey: resourceKey, flightID: flightID) }
    return try await task.value
  }

  public func getThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement {
    let agreement = try await getAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID)
    )
    return TiebaThreadAgreement(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  public func getAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) async throws -> TiebaAgreementState {
    switch target {
    case .thread(let firstPostID):
      let page = try await awaitAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        location: .postID(firstPostID)
      )
      return try uniqueAgreement(target, in: page)
    case .post(let postID):
      let page = try await awaitAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        location: .postID(postID)
      )
      return try uniqueAgreement(target, in: page)
    case .subpost(let parentPostID, let subpostID):
      let page = try await getSubpostAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: parentPostID,
        aroundSubpostID: subpostID,
        page: 1
      )
      return try uniqueAgreement(target, in: page)
    }
  }

  public func getAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int = 1,
    pageSize: Int = 30,
    sort: TiebaPostSort = .ascending,
    onlyThreadAuthor: Bool = false,
    location: TiebaPostLocation? = nil,
    includeSubposts: Bool = true,
    subpostsSortedByAgree: Bool = true,
    subpostPageSize: Int = 4
  ) async throws -> TiebaAgreementPage {
    let request = try requestFactory.agreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      page: page,
      pageSize: pageSize,
      sort: sort,
      onlyThreadAuthor: onlyThreadAuthor,
      location: location,
      includeSubposts: includeSubposts,
      subpostsSortedByAgree: subpostsSortedByAgree,
      subpostPageSize: subpostPageSize
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.agreementPageResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.agreementPage(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
  }

  public func getSubpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64? = nil,
    page: Int = 1
  ) async throws -> TiebaAgreementPage {
    let parentProbe = try await awaitAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      location: .postID(parentPostID)
    )
    let matchingParentTargets = parentProbe.agreements.compactMap { agreement in
      switch agreement.target {
      case .thread(let firstPostID) where firstPostID == parentPostID:
        agreement.target
      case .post(let postID) where postID == parentPostID:
        agreement.target
      default:
        nil
      }
    }
    guard matchingParentTargets.count == 1, let parentTarget = matchingParentTargets.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let request = try requestFactory.subpostAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: parentPostID,
      aroundSubpostID: aroundSubpostID,
      page: page
    )
    let response: PbFloorResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
    )
    let page = try TiebaAuthenticatedDecoder.subpostAgreementPage(
      from: response,
      validatedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: parentPostID,
      requiredSubpostID: aroundSubpostID
    )
    guard page.agreements.lazy.filter({ $0.target == parentTarget }).count == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return page
  }

  public func setThreadAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    let agreement = try await setAgreementState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      isAgreed: isAgreed
    )
    return TiebaThreadAgreement(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  public func setAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    try Task.checkCancellation()
    let forumName = try requestFactory.normalizedForumName(forumName)
    let resourceKey = TiebaAgreementResourceKey(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    let identity = TiebaAgreementIdentity(
      credential: credential,
      forumID: forumID,
      forumName: forumName
    )

    if let flight = agreementFlights[resourceKey] {
      if flight.identity == identity, flight.targetAgreed == isAgreed {
        registerSharedAgreementWaiter(flightID: flight.id)
        defer { unregisterSharedAgreementWaiter(flightID: flight.id) }
        return try await flight.task.value
      }

      registerConflictingAgreementWaiter(resourceKey: resourceKey)
      defer { unregisterConflictingAgreementWaiter(resourceKey: resourceKey) }
      _ = await flight.task.result
      try Task.checkCancellation()
      return try await getAgreement(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target
      )
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let predecessor = agreementAccountTails[expectedUserID]?.task
    let task: Task<TiebaAgreementState, Swift.Error> = Task.detached { [self] in
      await predecessor?.value
      return try await performAgreementWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        isAgreed: isAgreed
      )
    }
    agreementFlights[resourceKey] = TiebaAgreementFlight(
      id: flightID,
      identity: identity,
      targetAgreed: isAgreed,
      task: task
    )
    let tailID = UUID()
    let tailTask = Task.detached { _ = await task.result }
    agreementAccountTails[expectedUserID] = TiebaAgreementAccountTail(id: tailID, task: tailTask)
    defer {
      clearAgreementFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        userID: expectedUserID,
        tailID: tailID
      )
    }
    return try await task.value
  }

  private func performAgreementWrite(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    let current = try await getAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    guard current.isAgreed != isAgreed else { return current }
    let forumContext = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    let request = try requestFactory.setAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target,
      tbs: forumContext.tbs,
      isAgreed: isAgreed
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.threadAgreementWriteResponseMaximumBytes
      )
      let responseScore = try TiebaAuthenticatedDecoder.agreementWriteScore(from: body)
      return TiebaAgreementState(
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target,
        isAgreed: isAgreed,
        agreeScore: responseScore
          ?? adjustedAgreementScore(current.agreeScore, isAgreed: isAgreed)
      )
    } catch {
      guard isUncertainAgreementWriteError(error) else { throw error }
      if let reconciled = try? await getAgreement(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target
      ), reconciled.isAgreed == isAgreed {
        return reconciled
      }
      throw error
    }
  }

  private func performThreadCloudFavoriteWrite(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    let current = try await getThreadCloudFavoriteContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    guard current.state.markedPostID != markedPostID else { return current.state }

    let request = try requestFactory.setThreadCloudFavoriteState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      tbs: current.tbs,
      markedPostID: markedPostID
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.threadCloudFavoriteWriteResponseMaximumBytes
      )
      try TiebaAuthenticatedDecoder.checkThreadCloudFavoriteWriteResponse(body)
    } catch {
      guard isUncertainThreadCloudFavoriteWriteError(error) else { throw error }
      if let reconciled = try? await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      ), reconciled.markedPostID == markedPostID {
        return reconciled
      }
      throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
    }

    do {
      let reconciled = try await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
      guard reconciled.markedPostID == markedPostID else {
        throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
      }
      return reconciled
    } catch {
      throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
    }
  }

  private func performTextReplySubmission(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) async throws -> TiebaTextReplyResult {
    setTextReplyFlightStage(submissionID: submission.submissionID, stage: .preflight)
    let context = try await getTextReplyContext(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName
    )
    try Task.checkCancellation()
    let request = try requestFactory.textReply(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName,
      tbs: context.tbs,
      accountDisplayName: context.accountDisplayName,
      replyUserID: context.replyUserID,
      replyUserDisplayName: context.replyUserDisplayName,
      replyUserPortrait: context.replyUserPortrait
    )
    try Task.checkCancellation()
    setTextReplyFlightStage(submissionID: submission.submissionID, stage: .writeDispatched)

    let body: Data
    do {
      body = try await send(
        request,
        maximumBodyBytes: Self.textReplyWriteResponseMaximumBytes
      )
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }

    let receipt: TiebaTextReplyReceipt
    do {
      receipt = try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: body,
        submission: submission
      )
    } catch let error as TiebaClientError {
      switch error {
      case .replyChallengeRequired, .server:
        throw error
      default:
        throw TiebaClientError.replyOutcomeUnknown
      }
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }

    let outcome: TiebaTextReplyOutcome
    do {
      if let created = try await verifiedTextReply(
        credential: credential,
        expectedUserID: expectedUserID,
        context: context,
        submission: submission,
        receipt: receipt
      ) {
        outcome = .confirmed(created)
      } else {
        outcome = .acceptedAwaitingVisibility(receipt)
      }
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }
    return TiebaTextReplyResult(
      submissionID: submission.submissionID,
      userID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      target: submission.target,
      outcome: outcome
    )
  }

  private func performForumCheckIn(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    let context = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: true
    )
    guard context.state.membership.isFollowed else {
      throw TiebaClientError.forumNotFollowed
    }
    guard let currentCheckIn = context.state.checkIn else {
      throw TiebaClientError.forumCheckInUnavailable
    }
    guard !currentCheckIn.isCheckedIn else {
      return context.state
    }

    let request = try requestFactory.checkInToForum(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: context.state.membership.forumName,
      tbs: context.tbs
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumCheckInResponseMaximumBytes
    )
    let checkIn = try TiebaAuthenticatedDecoder.forumCheckIn(
      from: body,
      expectedUserID: expectedUserID
    )
    return TiebaForumAccountState(
      membership: context.state.membership,
      checkIn: checkIn
    )
  }

  private func awaitAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    location: TiebaPostLocation
  ) async throws -> TiebaAgreementPage {
    try await getAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      page: 1,
      pageSize: 2,
      location: location,
      includeSubposts: false
    )
  }

  private func uniqueAgreement(
    _ target: TiebaAgreementTarget,
    in page: TiebaAgreementPage
  ) throws -> TiebaAgreementState {
    let matches = page.agreements.filter { $0.target == target }
    guard matches.count == 1, let agreement = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return agreement
  }

  private func sendProtobuf<Message: SwiftProtobuf.Message>(
    _ request: URLRequest,
    maximumBodyBytes: Int
  ) async throws -> Message {
    let body = try await send(request, maximumBodyBytes: maximumBodyBytes)
    do {
      return try Message(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
  }

  private static func concernResponseRequestsSessionValidation(
    _ data: UserLikeResIdl.DataRes,
    page: TiebaConcernPage
  ) -> Bool {
    guard
      page.threads.isEmpty,
      !page.hasMore,
      data.userTipsType == 1
    else { return false }
    let tip = data.userTips.trimmingCharacters(in: .whitespacesAndNewlines)
    return tip.contains("登录") || tip.lowercased().contains("login")
  }

  private func isUncertainThreadCloudFavoriteWriteError(_ error: Swift.Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? TiebaClientError else { return true }
    switch error {
    case .invalidArgument, .invalidEndpoint, .server:
      return false
    default:
      return true
    }
  }

  func threadCloudFavoriteWaiterCounts(
    expectedUserID: Int64,
    threadID: Int64
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaThreadCloudFavoriteResourceKey(
      userID: expectedUserID,
      threadID: threadID
    )
    let shared = threadCloudFavoriteFlights[resourceKey].flatMap {
      threadCloudFavoriteSharedWaiters[$0.id]?.count
    } ?? 0
    return (
      shared: shared,
      conflict: threadCloudFavoriteConflictWaiters[resourceKey]?.count ?? 0
    )
  }

  private func waitForSharedThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          threadCloudFavoriteFlights[resourceKey]?.id == flightID
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaThreadCloudFavoriteWaitOutcome.cancelled
              : TiebaThreadCloudFavoriteWaitOutcome.completed
          )
          return
        }
        threadCloudFavoriteSharedWaiters[flightID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelSharedThreadCloudFavoriteWaiter(
          flightID: flightID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func waitForConflictingThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          threadCloudFavoriteFlights[resourceKey]?.id == flightID
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaThreadCloudFavoriteWaitOutcome.cancelled
              : TiebaThreadCloudFavoriteWaitOutcome.completed
          )
          return
        }
        threadCloudFavoriteConflictWaiters[resourceKey, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelConflictingThreadCloudFavoriteWaiter(
          resourceKey: resourceKey,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func cancelSharedThreadCloudFavoriteWaiter(
    flightID: UUID,
    waiterID: UUID
  ) {
    guard var waiters = threadCloudFavoriteSharedWaiters[flightID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      threadCloudFavoriteSharedWaiters.removeValue(forKey: flightID)
    } else {
      threadCloudFavoriteSharedWaiters[flightID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func cancelConflictingThreadCloudFavoriteWaiter(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    waiterID: UUID
  ) {
    guard var waiters = threadCloudFavoriteConflictWaiters[resourceKey] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      threadCloudFavoriteConflictWaiters.removeValue(forKey: resourceKey)
    } else {
      threadCloudFavoriteConflictWaiters[resourceKey] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func clearThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) {
    guard threadCloudFavoriteFlights[resourceKey]?.id == flightID else { return }
    threadCloudFavoriteFlights.removeValue(forKey: resourceKey)
    let sharedWaiters = threadCloudFavoriteSharedWaiters.removeValue(forKey: flightID) ?? [:]
    let conflictWaiters =
      threadCloudFavoriteConflictWaiters.removeValue(forKey: resourceKey) ?? [:]
    for continuation in sharedWaiters.values {
      continuation.resume(returning: .completed)
    }
    for continuation in conflictWaiters.values {
      continuation.resume(returning: .completed)
    }
  }

  private func waitForTextReplyFlight(
    submissionID: UUID,
    task: Task<TiebaTextReplyResult, Swift.Error>
  ) async throws -> TiebaTextReplyResult {
    try Task.checkCancellation()
    if textReplyFlights[submissionID]?.isCompleted != false {
      return try await task.value
    }

    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          textReplyFlights[submissionID]?.isCompleted == false
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaTextReplyWaitOutcome.cancelled
              : TiebaTextReplyWaitOutcome.completed
          )
          return
        }
        textReplyWaiters[submissionID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelTextReplyWaiter(
          submissionID: submissionID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    return try await task.value
  }

  private func cancelTextReplyWaiter(
    submissionID: UUID,
    waiterID: UUID
  ) {
    guard var waiters = textReplyWaiters[submissionID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      textReplyWaiters.removeValue(forKey: submissionID)
      if let flight = textReplyFlights[submissionID],
        flight.stage == .queued || flight.stage == .preflight
      {
        flight.task.cancel()
      }
    } else {
      textReplyWaiters[submissionID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func finishTextReplyFlight(
    submissionID: UUID,
    expectedUserID: Int64,
    task: Task<TiebaTextReplyResult, Swift.Error>
  ) async {
    let result = await task.result
    guard var flight = textReplyFlights[submissionID] else { return }
    flight.stage = .completed

    let retainsSubmission: Bool
    switch result {
    case .success:
      retainsSubmission = true
    case .failure(let error):
      retainsSubmission = (error as? TiebaClientError) == .replyOutcomeUnknown
    }
    if retainsSubmission {
      textReplyFlights[submissionID] = flight
    } else {
      textReplyFlights.removeValue(forKey: submissionID)
      textReplyFlightOrder.removeAll { $0 == submissionID }
    }
    if textReplyAccountTails[expectedUserID]?.submissionID == submissionID {
      textReplyAccountTails.removeValue(forKey: expectedUserID)
    }

    let waiters = textReplyWaiters.removeValue(forKey: submissionID) ?? [:]
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
    pruneRetainedTextReplyFlights()
  }

  private func pruneRetainedTextReplyFlights() {
    var completedCount = textReplyFlights.values.lazy.filter(\.isCompleted).count
    guard completedCount > Self.retainedTextReplySubmissionLimit else { return }
    var retainedOrder = [UUID]()
    retainedOrder.reserveCapacity(textReplyFlightOrder.count)
    for submissionID in textReplyFlightOrder {
      if completedCount > Self.retainedTextReplySubmissionLimit,
        textReplyFlights[submissionID]?.isCompleted == true
      {
        textReplyFlights.removeValue(forKey: submissionID)
        completedCount -= 1
      } else if textReplyFlights[submissionID] != nil {
        retainedOrder.append(submissionID)
      }
    }
    textReplyFlightOrder = retainedOrder
  }

  private func setTextReplyFlightStage(
    submissionID: UUID,
    stage: TiebaTextReplyFlightStage
  ) {
    guard var flight = textReplyFlights[submissionID], !flight.isCompleted else { return }
    flight.stage = stage
    textReplyFlights[submissionID] = flight
  }

  func textReplyWaiterCount(submissionID: UUID) -> Int {
    textReplyWaiters[submissionID]?.count ?? 0
  }

  func textReplyWaiterCountForTests() -> Int {
    textReplyWaiters.values.reduce(0) { $0 + $1.count }
  }

  private func adjustedAgreementScore(_ score: Int, isAgreed: Bool) -> Int {
    let delta = isAgreed ? 1 : -1
    let (adjusted, overflow) = score.addingReportingOverflow(delta)
    guard !overflow else { return isAgreed ? Int.max : Int.min }
    return adjusted
  }

  private func isUncertainAgreementWriteError(_ error: Swift.Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? TiebaClientError else { return true }
    switch error {
    case .invalidArgument, .invalidEndpoint, .server:
      return false
    default:
      return true
    }
  }

  func threadAgreementWaiterCounts(
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) -> (shared: Int, conflict: Int) {
    let target = TiebaAgreementTarget.thread(firstPostID: firstPostID)
    let keys = agreementFlights.keys.filter {
      $0.userID == expectedUserID && $0.threadID == threadID && $0.target == target
    }
    return keys.reduce(into: (shared: 0, conflict: 0)) { result, key in
      if let flightID = agreementFlights[key]?.id {
        result.shared += agreementSharedWaiterCounts[flightID] ?? 0
      }
      result.conflict += agreementConflictWaiterCounts[key] ?? 0
    }
  }

  func agreementWaiterCounts(
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaAgreementResourceKey(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    let shared = agreementFlights[resourceKey].flatMap {
      agreementSharedWaiterCounts[$0.id]
    } ?? 0
    return (shared, agreementConflictWaiterCounts[resourceKey] ?? 0)
  }

  private func registerSharedAgreementWaiter(flightID: UUID) {
    agreementSharedWaiterCounts[flightID, default: 0] += 1
  }

  private func unregisterSharedAgreementWaiter(flightID: UUID) {
    guard let count = agreementSharedWaiterCounts[flightID] else { return }
    if count <= 1 {
      agreementSharedWaiterCounts.removeValue(forKey: flightID)
    } else {
      agreementSharedWaiterCounts[flightID] = count - 1
    }
  }

  private func registerConflictingAgreementWaiter(
    resourceKey: TiebaAgreementResourceKey
  ) {
    agreementConflictWaiterCounts[resourceKey, default: 0] += 1
  }

  private func unregisterConflictingAgreementWaiter(
    resourceKey: TiebaAgreementResourceKey
  ) {
    guard let count = agreementConflictWaiterCounts[resourceKey] else { return }
    if count <= 1 {
      agreementConflictWaiterCounts.removeValue(forKey: resourceKey)
    } else {
      agreementConflictWaiterCounts[resourceKey] = count - 1
    }
  }

  private func clearAgreementFlight(
    resourceKey: TiebaAgreementResourceKey,
    flightID: UUID,
    userID: Int64,
    tailID: UUID
  ) {
    if agreementFlights[resourceKey]?.id == flightID {
      agreementFlights.removeValue(forKey: resourceKey)
      agreementSharedWaiterCounts.removeValue(forKey: flightID)
    }
    if agreementAccountTails[userID]?.id == tailID {
      agreementAccountTails.removeValue(forKey: userID)
    }
  }

  private func getThreadCloudFavoriteContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteContext {
    let request = try requestFactory.threadCloudFavoriteState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.threadCloudFavoriteStateResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.threadCloudFavoriteContext(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
  }

  private func getTextReplyContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) async throws -> TiebaTextReplyContext {
    let parentPostID: Int64
    switch submission.target {
    case .thread(let firstPostID):
      parentPostID = firstPostID
    case .post(let postID):
      parentPostID = postID
    case .subpost(let postID, _):
      parentPostID = postID
    }
    let pageRequest = try requestFactory.agreementPage(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      page: 1,
      pageSize: 2,
      sort: .ascending,
      onlyThreadAuthor: false,
      location: .postID(parentPostID),
      includeSubposts: false,
      subpostsSortedByAgree: true,
      subpostPageSize: 4
    )
    let pageResponse: PbPageResIdl = try await sendProtobuf(
      pageRequest,
      maximumBodyBytes: Self.agreementPageResponseMaximumBytes
    )
    let parentContext = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: pageResponse,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      forumName: normalizedForumName,
      threadID: submission.threadID,
      target: submission.target
    )
    guard case .subpost(let targetParentPostID, let subpostID) = submission.target else {
      return parentContext
    }

    try Task.checkCancellation()
    let floorRequest = try requestFactory.subpostAgreementPage(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      parentPostID: targetParentPostID,
      aroundSubpostID: subpostID,
      page: 1
    )
    let floorResponse: PbFloorResIdl = try await sendProtobuf(
      floorRequest,
      maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.textReplySubpostContext(
      from: floorResponse,
      parentContext: parentContext,
      subpostID: subpostID
    )
  }

  private func verifiedTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    context: TiebaTextReplyContext,
    submission: TiebaTextReplySubmission,
    receipt: TiebaTextReplyReceipt
  ) async throws -> TiebaCreatedReply? {
    switch receipt {
    case .post(let postID):
      guard case .thread = submission.target else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let request = try requestFactory.agreementPage(
        credential: credential.bdussCredential,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        threadID: submission.threadID,
        page: 1,
        pageSize: 2,
        sort: .ascending,
        onlyThreadAuthor: false,
        location: .postID(postID),
        includeSubposts: false,
        subpostsSortedByAgree: true,
        subpostPageSize: 4
      )
      let response: PbPageResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.agreementPageResponseMaximumBytes
      )
      return try TiebaAuthenticatedDecoder.verifiedTextReplyPost(
        from: response,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        forumName: context.forumName,
        threadID: submission.threadID,
        postID: postID,
        content: submission.content
      )
    case .subpost(let parentPostID, let subpostID):
      switch submission.target {
      case .post(let targetPostID) where targetPostID == parentPostID:
        break
      case .subpost(let targetPostID, _) where targetPostID == parentPostID:
        break
      default:
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let request = try requestFactory.subpostAgreementPage(
        credential: credential.bdussCredential,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        threadID: submission.threadID,
        parentPostID: parentPostID,
        aroundSubpostID: subpostID,
        page: 1
      )
      let response: PbFloorResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
      )
      return try TiebaAuthenticatedDecoder.verifiedTextReplySubpost(
        from: response,
        context: context,
        newSubpostID: subpostID,
        content: submission.content
      )
    }
  }

  private func getForumMembershipContext(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    validatesCheckInMetadata: Bool
  ) async throws -> TiebaForumMembershipContext {
    let request = try requestFactory.forumMembership(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumMembershipResponseMaximumBytes
    )
    let response: FrsPageResIdl
    do {
      response = try FrsPageResIdl(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
    if validatesCheckInMetadata {
      return try TiebaAuthenticatedDecoder.forumAccountState(
        from: response,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    } else {
      return try TiebaAuthenticatedDecoder.forumMembership(
        from: response,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    }
  }

  private func waitForForumCheckInFlight(
    resourceKey: TiebaForumCheckInResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          forumCheckInFlights[resourceKey]?.id == flightID
        else {
          continuation.resume()
          return
        }
        forumCheckInConflictWaiters[resourceKey, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelForumCheckInWaiter(
          resourceKey: resourceKey,
          waiterID: waiterID
        )
      }
    }
    try Task.checkCancellation()
  }

  func forumCheckInWaiterCounts(
    expectedUserID: Int64,
    forumID: Int64
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaForumCheckInResourceKey(
      userID: expectedUserID,
      forumID: forumID
    )
    let shared: Int
    if let flightID = forumCheckInFlights[resourceKey]?.id {
      shared = forumCheckInSharedWaiterCounts[flightID] ?? 0
    } else {
      shared = 0
    }
    return (
      shared: shared,
      conflict: forumCheckInConflictWaiters[resourceKey]?.count ?? 0
    )
  }

  private func registerSharedForumCheckInWaiter(flightID: UUID) {
    forumCheckInSharedWaiterCounts[flightID, default: 0] += 1
  }

  private func unregisterSharedForumCheckInWaiter(flightID: UUID) {
    guard let count = forumCheckInSharedWaiterCounts[flightID] else { return }
    if count <= 1 {
      forumCheckInSharedWaiterCounts.removeValue(forKey: flightID)
    } else {
      forumCheckInSharedWaiterCounts[flightID] = count - 1
    }
  }

  private func cancelForumCheckInWaiter(
    resourceKey: TiebaForumCheckInResourceKey,
    waiterID: UUID
  ) {
    guard var waiters = forumCheckInConflictWaiters[resourceKey] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      forumCheckInConflictWaiters.removeValue(forKey: resourceKey)
    } else {
      forumCheckInConflictWaiters[resourceKey] = waiters
    }
    continuation?.resume()
  }

  private func clearForumCheckInFlight(
    resourceKey: TiebaForumCheckInResourceKey,
    flightID: UUID
  ) {
    guard forumCheckInFlights[resourceKey]?.id == flightID else { return }
    forumCheckInFlights.removeValue(forKey: resourceKey)
    let waiters = forumCheckInConflictWaiters.removeValue(forKey: resourceKey) ?? [:]
    for continuation in waiters.values {
      continuation.resume()
    }
  }

  private func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> Data {
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
    guard response.body.count <= maximumBodyBytes else {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return response.body
  }
}
