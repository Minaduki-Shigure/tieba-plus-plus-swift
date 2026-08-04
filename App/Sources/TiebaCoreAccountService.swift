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
  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership
}

extension TiebaAuthenticatedClient: TiebaAuthenticatedAccountClient {}

struct TiebaCoreAccountService: AccountService {
  private let client: any TiebaAuthenticatedAccountClient
  private let followWriteCoordinator: ForumFollowWriteCoordinator

  init(client: any TiebaAuthenticatedAccountClient = TiebaAuthenticatedClient()) {
    self.client = client
    self.followWriteCoordinator = ForumFollowWriteCoordinator(client: client)
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

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    let response: TiebaForumMembership
    do {
      response = try await followWriteCoordinator.setForumFollowed(
        session: session,
        forumID: forumID,
        forumName: forumName,
        isFollowed: isFollowed
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch ForumFollowWriteCoordinatorError.operationInProgress {
      throw BrowseError.unavailable("该贴吧的关注状态正在更新，请稍后再试。")
    } catch {
      throw Self.accountError(error)
    }
    return Self.membershipData(response)
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
    case .server(let code, _):
      message = "账户请求失败（错误码 \(code)）。"
    @unknown default:
      message = "账户请求失败，请稍后重试。"
    }
    return .unavailable(message)
  }
}

private enum ForumFollowWriteCoordinatorError: Error, Sendable {
  case operationInProgress
}

private actor ForumFollowWriteCoordinator {
  private struct Key: Hashable, Sendable {
    let userID: Int64
    let forumID: Int64
  }

  private struct Entry: Sendable {
    let id: UUID
    let sessionUpdatedAt: Date
    let desiredState: Bool
    let task: Task<TiebaForumMembership, Error>
  }

  private let client: any TiebaAuthenticatedAccountClient
  private var inFlight: [Key: Entry] = [:]

  init(client: any TiebaAuthenticatedAccountClient) {
    self.client = client
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    try Task.checkCancellation()
    let expectedUserID = session.id
    let key = Key(userID: expectedUserID, forumID: forumID)
    if let entry = inFlight[key] {
      guard entry.sessionUpdatedAt == session.updatedAt else {
        throw ForumFollowWriteCoordinatorError.operationInProgress
      }
      guard entry.desiredState == isFollowed else {
        throw ForumFollowWriteCoordinatorError.operationInProgress
      }
      return try await entry.task.value
    }

    let client = client
    let credential = TiebaBDUSSCredential(bduss: session.bduss)
    let entryID = UUID()
    let task = Task.detached {
      try await client.setForumFollowState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        isFollowed: isFollowed
      )
    }
    inFlight[key] = Entry(
      id: entryID,
      sessionUpdatedAt: session.updatedAt,
      desiredState: isFollowed,
      task: task
    )
    defer { clearEntry(for: key, id: entryID) }
    return try await task.value
  }

  private func clearEntry(for key: Key, id: UUID) {
    guard inFlight[key]?.id == id else { return }
    inFlight.removeValue(forKey: key)
  }
}
