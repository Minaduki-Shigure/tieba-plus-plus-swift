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

public actor TiebaAuthenticatedClient {
  static let accountResponseMaximumBytes = 512 * 1_024
  static let webSessionResponseMaximumBytes = 256 * 1_024
  static let followedForumsResponseMaximumBytes = 2 * 1_024 * 1_024
  static let cloudFavoritesResponseMaximumBytes = 2 * 1_024 * 1_024
  static let concernResponseMaximumBytes = 4 * 1_024 * 1_024
  static let notificationResponseMaximumBytes = 2 * 1_024 * 1_024
  static let forumMembershipResponseMaximumBytes = 512 * 1_024
  static let forumFollowWriteResponseMaximumBytes = 64 * 1_024
  static let forumCheckInResponseMaximumBytes = 64 * 1_024
  static let agreementPageResponseMaximumBytes = 8 * 1_024 * 1_024
  static let subpostAgreementPageResponseMaximumBytes = 4 * 1_024 * 1_024
  static let threadAgreementWriteResponseMaximumBytes = 64 * 1_024

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
