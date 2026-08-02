import Foundation
import TiebaCore

struct TiebaCoreAccountService: AccountService {
  private let client: TiebaAuthenticatedClient

  init(client: TiebaAuthenticatedClient = TiebaAuthenticatedClient()) {
    self.client = client
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

  static func accountError(_ error: Error) -> BrowseError {
    guard let error = error as? TiebaClientError else {
      return .unavailable("账户请求失败，请稍后重试。")
    }

    let message: String
    switch error {
    case .invalidArgument:
      message = "账户凭据格式无效。"
    case .invalidEndpoint:
      message = "无法建立安全的账户请求。"
    case .network:
      message = "网络连接失败，请检查网络后重试。"
    case .transportFailure, .invalidHTTPResponse:
      message = "网络响应异常，请稍后重试。"
    case .httpStatus(let status):
      message = "贴吧服务暂时不可用（HTTP \(status)）。"
    case .invalidProtobuf, .invalidJSON:
      message = "贴吧返回了无法识别的数据，接口可能已经更新。"
    case .server(let code, _):
      message = "账户验证失败（错误码 \(code)）。"
    @unknown default:
      message = "账户请求失败，请稍后重试。"
    }
    return .unavailable(message)
  }
}
