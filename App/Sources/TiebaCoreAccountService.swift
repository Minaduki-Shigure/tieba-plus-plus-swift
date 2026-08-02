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
      throw TiebaCoreBrowseService.browseError(error)
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
      throw TiebaCoreBrowseService.browseError(error)
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
}
