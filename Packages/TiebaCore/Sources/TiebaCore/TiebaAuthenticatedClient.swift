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

private struct TiebaThreadAgreementResourceKey: Hashable, Sendable {
  let userID: Int64
  let threadID: Int64
  let firstPostID: Int64
}

private struct TiebaThreadAgreementIdentity:
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

  var description: String { "TiebaThreadAgreementIdentity(redacted)" }
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

private struct TiebaThreadAgreementFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaThreadAgreementIdentity
  let targetAgreed: Bool
  let task: Task<TiebaThreadAgreement, Swift.Error>

  var description: String { "TiebaThreadAgreementFlight(redacted)" }
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

public actor TiebaAuthenticatedClient {
  static let accountResponseMaximumBytes = 512 * 1_024
  static let followedForumsResponseMaximumBytes = 2 * 1_024 * 1_024
  static let forumMembershipResponseMaximumBytes = 512 * 1_024
  static let forumFollowWriteResponseMaximumBytes = 64 * 1_024
  static let forumCheckInResponseMaximumBytes = 64 * 1_024
  static let threadAgreementResponseMaximumBytes = 512 * 1_024
  static let threadAgreementWriteResponseMaximumBytes = 64 * 1_024

  private let requestFactory: TiebaAuthenticatedRequestFactory
  private let transport: any TiebaTransport
  private var forumCheckInFlights = [TiebaForumCheckInResourceKey: TiebaForumCheckInFlight]()
  private var forumCheckInSharedWaiterCounts = [UUID: Int]()
  private var forumCheckInConflictWaiters = [
    TiebaForumCheckInResourceKey: [UUID: CheckedContinuation<Void, Never>]
  ]()
  private var threadAgreementFlights = [
    TiebaThreadAgreementResourceKey: TiebaThreadAgreementFlight
  ]()
  private var threadAgreementSharedWaiterCounts = [UUID: Int]()
  private var threadAgreementConflictWaiterCounts = [TiebaThreadAgreementResourceKey: Int]()

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
    _ = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    return try await getThreadAgreementSnapshot(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID
    )
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
    try Task.checkCancellation()
    let forumName = try requestFactory.normalizedForumName(forumName)
    let resourceKey = TiebaThreadAgreementResourceKey(
      userID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    let identity = TiebaThreadAgreementIdentity(
      credential: credential,
      forumID: forumID,
      forumName: forumName
    )

    if let flight = threadAgreementFlights[resourceKey] {
      if flight.identity == identity, flight.targetAgreed == isAgreed {
        registerSharedThreadAgreementWaiter(flightID: flight.id)
        defer { unregisterSharedThreadAgreementWaiter(flightID: flight.id) }
        return try await flight.task.value
      }

      registerConflictingThreadAgreementWaiter(resourceKey: resourceKey)
      defer { unregisterConflictingThreadAgreementWaiter(resourceKey: resourceKey) }
      _ = await flight.task.result
      try Task.checkCancellation()
      throw TiebaClientError.threadAgreementWriteConflict
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let task: Task<TiebaThreadAgreement, Swift.Error> = Task.detached { [self] in
      try await performThreadAgreementWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: isAgreed
      )
    }
    threadAgreementFlights[resourceKey] = TiebaThreadAgreementFlight(
      id: flightID,
      identity: identity,
      targetAgreed: isAgreed,
      task: task
    )
    defer { clearThreadAgreementFlight(resourceKey: resourceKey, flightID: flightID) }
    return try await task.value
  }

  private func performThreadAgreementWrite(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    let current = try await getThreadAgreementSnapshot(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    let forumContext = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    guard current.isAgreed != isAgreed else { return current }

    let request = try requestFactory.setThreadAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID,
      tbs: forumContext.tbs,
      isAgreed: isAgreed
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.threadAgreementWriteResponseMaximumBytes
    )
    let responseScore = try TiebaAuthenticatedDecoder.threadAgreementWriteScore(from: body)
    return TiebaThreadAgreement(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: isAgreed,
      agreeScore: responseScore ?? adjustedAgreementScore(current.agreeScore, isAgreed: isAgreed)
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

  private func getThreadAgreementSnapshot(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement {
    let request = try requestFactory.threadAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.threadAgreementResponseMaximumBytes
    )
    let response: PbPageResIdl
    do {
      response = try PbPageResIdl(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
    return try TiebaAuthenticatedDecoder.threadAgreement(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID
    )
  }

  private func adjustedAgreementScore(_ score: Int, isAgreed: Bool) -> Int {
    let delta = isAgreed ? 1 : -1
    let (adjusted, overflow) = score.addingReportingOverflow(delta)
    guard !overflow else { return isAgreed ? Int.max : Int.min }
    return adjusted
  }

  func threadAgreementWaiterCounts(
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaThreadAgreementResourceKey(
      userID: expectedUserID,
      threadID: threadID,
      firstPostID: firstPostID
    )
    let shared: Int
    if let flightID = threadAgreementFlights[resourceKey]?.id {
      shared = threadAgreementSharedWaiterCounts[flightID] ?? 0
    } else {
      shared = 0
    }
    return (
      shared: shared,
      conflict: threadAgreementConflictWaiterCounts[resourceKey] ?? 0
    )
  }

  private func registerSharedThreadAgreementWaiter(flightID: UUID) {
    threadAgreementSharedWaiterCounts[flightID, default: 0] += 1
  }

  private func unregisterSharedThreadAgreementWaiter(flightID: UUID) {
    guard let count = threadAgreementSharedWaiterCounts[flightID] else { return }
    if count <= 1 {
      threadAgreementSharedWaiterCounts.removeValue(forKey: flightID)
    } else {
      threadAgreementSharedWaiterCounts[flightID] = count - 1
    }
  }

  private func registerConflictingThreadAgreementWaiter(
    resourceKey: TiebaThreadAgreementResourceKey
  ) {
    threadAgreementConflictWaiterCounts[resourceKey, default: 0] += 1
  }

  private func unregisterConflictingThreadAgreementWaiter(
    resourceKey: TiebaThreadAgreementResourceKey
  ) {
    guard let count = threadAgreementConflictWaiterCounts[resourceKey] else { return }
    if count <= 1 {
      threadAgreementConflictWaiterCounts.removeValue(forKey: resourceKey)
    } else {
      threadAgreementConflictWaiterCounts[resourceKey] = count - 1
    }
  }

  private func clearThreadAgreementFlight(
    resourceKey: TiebaThreadAgreementResourceKey,
    flightID: UUID
  ) {
    guard threadAgreementFlights[resourceKey]?.id == flightID else { return }
    threadAgreementFlights.removeValue(forKey: resourceKey)
    threadAgreementSharedWaiterCounts.removeValue(forKey: flightID)
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
