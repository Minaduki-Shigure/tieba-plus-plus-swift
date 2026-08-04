import Foundation
import TiebaCore

protocol TiebaAuthenticatedAccountClient: Sendable {
  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount
  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage
  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership
  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState
  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership
  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState
}

extension TiebaAuthenticatedClient: TiebaAuthenticatedAccountClient {}

struct TiebaCoreAccountService: AccountService {
  private let client: any TiebaAuthenticatedAccountClient
  private let forumWriteCoordinator: ForumAccountWriteCoordinator

  init(client: any TiebaAuthenticatedAccountClient = TiebaAuthenticatedClient()) {
    self.client = client
    self.forumWriteCoordinator = ForumAccountWriteCoordinator(client: client)
  }

  func forumWriteConflictWaiterCount() async -> Int {
    await forumWriteCoordinator.conflictWaiterCount()
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    let response: TiebaAuthenticatedAccount
    do {
      response = try await client.validateAccount(
        credential: TiebaBDUSSCredential(bduss: credential.bduss)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return ValidatedAccount(
      userID: response.userID,
      username: response.username,
      portrait: response.portrait
    )
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    let response: TiebaFollowedForumPage
    do {
      response = try await client.getFollowedForums(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        userID: session.id,
        page: page,
        pageSize: pageSize
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return FollowedForumPageData(
      forums: response.forums.map {
        FollowedForumItem(
          id: $0.id,
          name: $0.name,
          level: $0.level,
          experience: $0.experience
        )
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore
    )
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    let response: TiebaForumMembership
    do {
      response = try await client.getForumMembership(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id,
        forumID: forumID,
        forumName: forumName
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return Self.membershipData(response)
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    let response: TiebaForumAccountState
    do {
      response = try await client.getForumAccountState(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id,
        forumID: forumID,
        forumName: forumName
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return Self.accountStateData(response)
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    let response: TiebaForumMembership
    do {
      let result = try await forumWriteCoordinator.perform(
        session: session,
        forumID: forumID,
        forumName: forumName,
        operation: .follow(isFollowed)
      )
      guard case .membership(let membership) = result else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      response = membership
    } catch is CancellationError {
      throw CancellationError()
    } catch ForumAccountWriteCoordinatorError.conflictingOperationSettled {
      throw BrowseError.unavailable("先前的贴吧账户操作已结束，请重新读取当前状态。")
    } catch {
      throw Self.accountError(error)
    }
    return Self.membershipData(response)
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    let response: TiebaForumAccountState
    do {
      let result = try await forumWriteCoordinator.perform(
        session: session,
        forumID: forumID,
        forumName: forumName,
        operation: .checkIn
      )
      guard case .accountState(let accountState) = result else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      response = accountState
    } catch is CancellationError {
      throw CancellationError()
    } catch ForumAccountWriteCoordinatorError.conflictingOperationSettled {
      throw BrowseError.unavailable("先前的贴吧账户操作已结束，请重新读取当前状态。")
    } catch {
      throw Self.accountError(error)
    }
    return Self.accountStateData(response)
  }

  private static func membershipData(
    _ membership: TiebaForumMembership
  ) -> ForumMembershipData {
    ForumMembershipData(
      userID: membership.userID,
      forumID: membership.forumID,
      forumName: membership.forumName,
      isFollowed: membership.isFollowed
    )
  }

  private static func accountStateData(
    _ state: TiebaForumAccountState
  ) -> ForumAccountStateData {
    ForumAccountStateData(
      membership: membershipData(state.membership),
      checkIn: state.checkIn.map {
        ForumCheckInData(
          isCheckedIn: $0.isCheckedIn,
          consecutiveDays: $0.consecutiveDays,
          rank: $0.rank
        )
      }
    )
  }

  static func accountError(_ error: Error) -> BrowseError {
    guard let error = error as? TiebaClientError else {
      return .unavailable("账户请求失败，请稍后重试。")
    }

    let message: String
    switch error {
    case .invalidArgument:
      message = "账户请求参数无效。"
    case .invalidEndpoint:
      message = "无法建立安全的账户请求。"
    case .network:
      message = "网络连接失败，请检查网络后重试。"
    case .transportFailure, .invalidHTTPResponse:
      message = "网络响应异常，请稍后重试。"
    case .httpStatus(let status):
      message = "贴吧服务暂时不可用（HTTP \(status)）。"
    case .responseTooLarge:
      message = "贴吧返回的数据过大，请稍后重试。"
    case .invalidProtobuf, .invalidJSON:
      message = "贴吧返回了无法识别的数据，接口可能已经更新。"
    case .invalidAuthenticatedResponse:
      message = "账户凭据与贴吧响应不一致，请重新登录后再试。"
    case .forumNotFollowed:
      message = "请先关注该贴吧后再签到。"
    case .forumCheckInUnavailable:
      message = "该贴吧当前无法签到。"
    case .server(let code, _):
      message = "账户请求失败（错误码 \(code)）。"
    @unknown default:
      message = "账户请求失败，请稍后重试。"
    }
    return .unavailable(message)
  }
}

private enum ForumAccountWriteCoordinatorError: Error, Sendable {
  case conflictingOperationSettled
}

private enum ForumAccountWriteOperation: Hashable, Sendable {
  case follow(Bool)
  case checkIn
}

private enum ForumAccountWriteResult: Sendable {
  case membership(TiebaForumMembership)
  case accountState(TiebaForumAccountState)
}

private struct ForumAccountWriteIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let sessionRevision: UUID
  let forumName: String
  private let bduss: String

  init(session: StoredAccountSession, forumName: String) {
    sessionRevision = session.sessionRevision
    self.forumName = forumName
    bduss = session.bduss
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionRevision == rhs.sessionRevision
      && lhs.forumName == rhs.forumName
      && lhs.bduss == rhs.bduss
  }

  var description: String { "ForumAccountWriteIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "sessionRevision": sessionRevision,
        "forumName": forumName,
      ],
      displayStyle: .struct
    )
  }
}

private actor ForumAccountWriteCoordinator {
  private struct Key: Hashable, Sendable {
    let userID: Int64
    let forumID: Int64
  }

  private struct Entry: Sendable {
    let id: UUID
    let identity: ForumAccountWriteIdentity
    let operation: ForumAccountWriteOperation
    let task: Task<ForumAccountWriteResult, Error>
  }

  private let client: any TiebaAuthenticatedAccountClient
  private var inFlight: [Key: Entry] = [:]
  private var conflictWaiters = 0

  init(client: any TiebaAuthenticatedAccountClient) {
    self.client = client
  }

  func perform(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    operation: ForumAccountWriteOperation
  ) async throws -> ForumAccountWriteResult {
    try Task.checkCancellation()
    let expectedUserID = session.id
    let key = Key(userID: expectedUserID, forumID: forumID)
    let normalizedForumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let identity = ForumAccountWriteIdentity(
      session: session,
      forumName: normalizedForumName
    )
    if let entry = inFlight[key] {
      if entry.identity == identity, entry.operation == operation {
        return try await entry.task.value
      }
      conflictWaiters += 1
      defer { conflictWaiters -= 1 }
      _ = await entry.task.result
      throw ForumAccountWriteCoordinatorError.conflictingOperationSettled
    }

    let client = client
    let credential = TiebaBDUSSCredential(bduss: session.bduss)
    let entryID = UUID()
    let task = Task.detached { () async throws -> ForumAccountWriteResult in
      switch operation {
      case .follow(let isFollowed):
        return .membership(
          try await client.setForumFollowState(
            credential: credential,
            expectedUserID: expectedUserID,
            forumID: forumID,
            forumName: normalizedForumName,
            isFollowed: isFollowed
          )
        )
      case .checkIn:
        return .accountState(
          try await client.checkInToForum(
            credential: credential,
            expectedUserID: expectedUserID,
            forumID: forumID,
            forumName: normalizedForumName
          )
        )
      }
    }
    inFlight[key] = Entry(
      id: entryID,
      identity: identity,
      operation: operation,
      task: task
    )
    defer { clearEntry(for: key, id: entryID) }
    return try await task.value
  }

  func conflictWaiterCount() -> Int {
    conflictWaiters
  }

  private func clearEntry(for key: Key, id: UUID) {
    guard inFlight[key]?.id == id else { return }
    inFlight.removeValue(forKey: key)
  }
}
