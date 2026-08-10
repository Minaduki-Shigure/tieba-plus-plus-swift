import Foundation
import TiebaCore

protocol TiebaAuthenticatedAccountClient: Sendable {
  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount
  func validateSession(
    credential: TiebaSessionCredential
  ) async throws -> TiebaAuthenticatedAccount
  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage
  func getLikedForums(
    credential: TiebaBDUSSCredential,
    accountUserID: Int64,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage
  func getCloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int,
    pageSize: Int
  ) async throws -> TiebaCloudFavoritePage
  func getThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteState
  func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState
  func submitTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult
  func getConcernFeed(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> TiebaConcernPage
  func getNotifications(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    kind: TiebaNotificationKind,
    page: Int
  ) async throws -> TiebaNotificationPage
  func getInboxUnreadSummary(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64
  ) async throws -> TiebaInboxUnreadSummary
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
  func getThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement
  func setThreadAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement
  func getAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) async throws -> TiebaAgreementState
  func getAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeSubposts: Bool,
    subpostsSortedByAgree: Bool,
    subpostPageSize: Int
  ) async throws -> TiebaAgreementPage
  func getSubpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64?,
    page: Int
  ) async throws -> TiebaAgreementPage
  func setAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState
}

extension TiebaAuthenticatedAccountClient {
  func getLikedForums(
    credential: TiebaBDUSSCredential,
    accountUserID: Int64,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    if accountUserID == targetUserID {
      return try await getFollowedForums(
        credential: credential,
        userID: accountUserID,
        page: page,
        pageSize: pageSize
      )
    }
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getConcernFeed(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> TiebaConcernPage {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func validateSession(
    credential: TiebaSessionCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getCloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int,
    pageSize: Int
  ) async throws -> TiebaCloudFavoritePage {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteState {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func submitTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getNotifications(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    kind: TiebaNotificationKind,
    page: Int
  ) async throws -> TiebaNotificationPage {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getInboxUnreadSummary(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64
  ) async throws -> TiebaInboxUnreadSummary {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func setThreadAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) async throws -> TiebaAgreementState {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeSubposts: Bool,
    subpostsSortedByAgree: Bool,
    subpostPageSize: Int
  ) async throws -> TiebaAgreementPage {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func getSubpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64?,
    page: Int
  ) async throws -> TiebaAgreementPage {
    throw TiebaClientError.invalidAuthenticatedResponse
  }

  func setAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    throw TiebaClientError.invalidAuthenticatedResponse
  }
}

extension TiebaAuthenticatedClient: TiebaAuthenticatedAccountClient {}

struct TiebaCoreAccountService: AccountService {
  private let client: any TiebaAuthenticatedAccountClient
  private let contentFilterRepository: any ContentFilterRepository
  private let threadCloudFavoriteWriteCoordinator: ThreadCloudFavoriteWriteCoordinator
  private let forumWriteCoordinator: ForumAccountWriteCoordinator
  private let threadAgreementWriteCoordinator: ThreadAgreementWriteCoordinator
  private let contentAgreementWriteCoordinator: ContentAgreementWriteCoordinator

  init(
    client: any TiebaAuthenticatedAccountClient = TiebaAuthenticatedClient(),
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository()
  ) {
    self.client = client
    self.contentFilterRepository = contentFilterRepository
    self.threadCloudFavoriteWriteCoordinator = ThreadCloudFavoriteWriteCoordinator(client: client)
    self.forumWriteCoordinator = ForumAccountWriteCoordinator(client: client)
    self.threadAgreementWriteCoordinator = ThreadAgreementWriteCoordinator(client: client)
    self.contentAgreementWriteCoordinator = ContentAgreementWriteCoordinator(client: client)
  }

  func forumWriteConflictWaiterCount() async -> Int {
    await forumWriteCoordinator.conflictWaiterCount()
  }

  func threadCloudFavoriteWriteConflictWaiterCount() async -> Int {
    await threadCloudFavoriteWriteCoordinator.conflictWaiterCount()
  }

  func threadAgreementWriteConflictWaiterCount() async -> Int {
    await threadAgreementWriteCoordinator.conflictWaiterCount()
  }

  func contentAgreementWriteConflictWaiterCount() async -> Int {
    await contentAgreementWriteCoordinator.conflictWaiterCount()
  }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    let response: TiebaAuthenticatedAccount
    do {
      response = try await client.validateSession(
        credential: Self.coreSessionCredential(credential)
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

  func cloudFavorites(
    session: StoredAccountSession,
    offset: Int,
    pageSize: Int
  ) async throws -> CloudFavoritePage {
    guard let credentials = session.credentials else {
      throw BrowseError.unavailable("此账户需要重新登录，才能安全读取贴吧收藏。")
    }
    let response: TiebaCloudFavoritePage
    do {
      response = try await client.getCloudFavorites(
        credential: Self.coreSessionCredential(credentials),
        expectedUserID: session.id,
        offset: offset,
        pageSize: pageSize
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    guard
      response.requestedUserID == session.id,
      response.offset == offset,
      response.pageSize == pageSize,
      response.favorites.count <= pageSize,
      response.nextOffset == offset + pageSize,
      response.hasMore == !response.favorites.isEmpty
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户收藏，请重新加载后再试。")
    }
    return CloudFavoritePage(
      userID: response.requestedUserID,
      items: response.favorites.map { favorite in
        CloudFavoriteThread(
          id: favorite.id,
          title: favorite.title,
          forumName: favorite.forumName,
          authorName: favorite.author.preferredName,
          markPostID: favorite.markedPostID > 0 ? favorite.markedPostID : nil,
          latestPostID: favorite.maximumPostID > 0 ? favorite.maximumPostID : nil,
          latestFloor: favorite.postNumber > 0 ? favorite.postNumber : nil,
          hasUpdates: favorite.updateCount > 0 && favorite.postNumber > 0,
          isDeleted: favorite.isDeleted,
          updatedAt: Self.cloudFavoriteDate(favorite.lastTimestamp)
        )
      },
      nextOffset: response.hasMore ? response.nextOffset : nil,
      hasMore: response.hasMore
    )
  }

  func submitTextReply(
    session: StoredAccountSession,
    submission: TextReplySubmission
  ) async throws -> TextReplyResult {
    guard session.id > 0, let credentials = session.credentials else {
      throw TextReplySubmissionError.fullCredentialsRequired
    }
    let coreTarget = Self.coreTextReplyTarget(submission.target.destination)
    let coreSubmission = TiebaTextReplySubmission(
      submissionID: submission.id,
      forumID: submission.target.forumID,
      forumName: submission.target.forumName,
      threadID: submission.target.threadID,
      target: coreTarget,
      content: submission.content
    )
    let response: TiebaTextReplyResult
    do {
      response = try await client.submitTextReply(
        credential: Self.coreSessionCredential(credentials),
        expectedUserID: session.id,
        submission: coreSubmission
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TiebaClientError {
      throw Self.textReplyError(error)
    } catch {
      throw TextReplySubmissionError.unavailable
    }

    guard
      response.submissionID == submission.id,
      response.userID == session.id,
      response.forumID == submission.target.forumID,
      response.threadID == submission.target.threadID,
      response.target == coreTarget,
      let outcome = Self.textReplyOutcome(
        response.outcome,
        expectedTarget: submission.target
      ),
      let result = TextReplyResult(
        submissionID: response.submissionID,
        userID: response.userID,
        target: submission.target,
        outcome: outcome
      )
    else {
      throw TextReplySubmissionError.outcomeUnknown
    }
    return result
  }

  func threadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteData {
    guard session.id > 0, let credentials = session.credentials else {
      throw BrowseError.unavailable("此账户需要重新登录，才能安全读取主题收藏状态。")
    }
    let response: TiebaThreadCloudFavoriteState
    do {
      response = try await client.getThreadCloudFavoriteState(
        credential: Self.coreSessionCredential(credentials),
        expectedUserID: session.id,
        forumID: target.forumID,
        threadID: target.threadID
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return try Self.threadCloudFavoriteData(
      response,
      expectedUserID: session.id,
      expectedTarget: target
    )
  }

  func setThreadCloudFavorite(
    session: StoredAccountSession,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteData {
    guard ThreadCloudFavoriteSnapshot(markedPostID: markedPostID) != nil else {
      throw BrowseError.unavailable("收藏楼层标识无效。")
    }
    guard session.id > 0, let credentials = session.credentials else {
      throw BrowseError.unavailable("此账户需要重新登录，才能安全更新主题收藏。")
    }

    let outcome: ThreadCloudFavoriteWriteOutcome
    do {
      outcome = try await threadCloudFavoriteWriteCoordinator.perform(
        session: session,
        credential: Self.coreSessionCredential(credentials),
        target: target,
        markedPostID: markedPostID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
    let data = try Self.threadCloudFavoriteData(
      outcome.state,
      expectedUserID: session.id,
      expectedTarget: target
    )
    guard data.snapshot.markedPostID == markedPostID else {
      switch outcome {
      case .mutated:
        throw BrowseError.unavailable("贴吧没有确认新的主题收藏状态，请重新加载后再试。")
      case .reconciled:
        throw BrowseError.unavailable(
          "先前的云端收藏操作已结束，已重新读取当前状态；请确认后再操作。"
        )
      }
    }
    return data
  }

  func concernFeed(
    session: StoredAccountSession,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) async throws -> ConcernFeedPageData {
    guard let credentials = session.credentials else {
      throw BrowseError.unavailable("此账户需要重新登录，才能安全读取关注动态。")
    }
    let response: TiebaConcernPage
    do {
      response = try await client.getConcernFeed(
        credential: Self.coreSessionCredential(credentials),
        expectedUserID: session.id,
        pageTag: pageTag,
        lastRequestUnix: lastRequestUnix
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    guard response.requestedUserID == session.id else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户动态，请重新加载后再试。")
    }
    let filter = (try? await contentFilterRepository.snapshot()) ?? .empty
    return ConcernFeedPageData(
      userID: response.requestedUserID,
      threads: response.threads.map {
        let mapped = TiebaCoreBrowseService.mapThread($0)
        return filter.applying(to: mapped, hasKnownVideo: mapped.kind == .video)
      },
      nextPageTag: response.nextPageTag,
      hasMore: response.hasMore,
      requestUnix: response.requestUnix
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

  func likedForums(
    session: StoredAccountSession,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> UserLikedForumPageData {
    let response: TiebaFollowedForumPage
    do {
      response = try await client.getLikedForums(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        accountUserID: session.id,
        targetUserID: targetUserID,
        page: page,
        pageSize: pageSize
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    guard
      response.accountUserID == session.id,
      response.targetUserID == targetUserID,
      response.pagination.currentPage == page,
      response.pagination.pageSize == pageSize
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的用户贴吧列表，请重新加载后再试。")
    }
    return UserLikedForumPageData(
      accountUserID: response.accountUserID,
      targetUserID: response.targetUserID,
      forums: response.forums.map {
        FollowedForumItem(
          id: $0.id,
          name: $0.name,
          level: $0.level,
          experience: $0.experience,
          avatarURL: SecureTiebaURL.media($0.avatar),
          slogan: $0.slogan
        )
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore
    )
  }

  func notifications(
    session: StoredAccountSession,
    kind: InboxKind,
    page: Int
  ) async throws -> InboxPage {
    let response: TiebaNotificationPage
    do {
      response = try await client.getNotifications(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id,
        kind: Self.coreNotificationKind(kind),
        page: page
      )
      try Task.checkCancellation()
      return try Self.inboxPageData(
        response,
        expectedUserID: session.id,
        expectedKind: kind,
        requestedPage: page
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
  }

  func inboxUnreadSummary(
    session: StoredAccountSession
  ) async throws -> InboxUnreadSummary {
    let response: TiebaInboxUnreadSummary
    do {
      response = try await client.getInboxUnreadSummary(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id
      )
      try Task.checkCancellation()
      return try Self.inboxUnreadSummaryData(response, expectedUserID: session.id)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
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

  func threadAgreement(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> ThreadAgreementData {
    let response: TiebaThreadAgreement
    do {
      response = try await client.getThreadAgreement(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.accountError(error)
    }
    return Self.threadAgreementData(response)
  }

  func setThreadAgreed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> ThreadAgreementData {
    let response: TiebaThreadAgreement
    do {
      response = try await threadAgreementWriteCoordinator.perform(
        session: session,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: isAgreed
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch ThreadAgreementWriteCoordinatorError.conflictingOperationSettled {
      throw BrowseError.unavailable("先前的主题点赞操作已结束，请重新读取当前状态。")
    } catch {
      throw Self.accountError(error)
    }
    return Self.threadAgreementData(response)
  }

  func contentAgreement(
    session: StoredAccountSession,
    target: ContentAgreementTarget
  ) async throws -> ContentAgreementData {
    let response: TiebaAgreementState
    do {
      response = try await client.getAgreement(
        credential: TiebaBDUSSCredential(bduss: session.bduss),
        expectedUserID: session.id,
        forumID: target.forumID,
        threadID: target.threadID,
        target: Self.coreAgreementTarget(target)
      )
      try Task.checkCancellation()
      return try Self.contentAgreementData(
        response,
        expectedUserID: session.id,
        expectedTarget: target
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
  }

  func contentAgreements(
    session: StoredAccountSession,
    descriptor: ContentAgreementReadDescriptor
  ) async throws -> ContentAgreementPageData {
    let response: TiebaAgreementPage
    do {
      switch descriptor.request {
      case .postPage(let request):
        response = try await client.getAgreementPage(
          credential: TiebaBDUSSCredential(bduss: session.bduss),
          expectedUserID: session.id,
          forumID: request.forumID,
          threadID: request.threadID,
          page: request.page,
          pageSize: request.pageSize,
          sort: Self.corePostSort(request.options.sort),
          onlyThreadAuthor: request.options.onlyThreadAuthor,
          location: Self.corePostLocation(request.location),
          includeSubposts: request.includesSubposts,
          subpostsSortedByAgree: request.subpostsSortedByAgree,
          subpostPageSize: request.subpostPageSize
        )
      case .subpostPage(let request):
        response = try await client.getSubpostAgreementPage(
          credential: TiebaBDUSSCredential(bduss: session.bduss),
          expectedUserID: session.id,
          forumID: request.forumID,
          threadID: request.threadID,
          parentPostID: request.parentPostID,
          aroundSubpostID: request.aroundSubpostID,
          page: request.page
        )
      }
      try Task.checkCancellation()
      return try Self.contentAgreementPageData(
        response,
        expectedUserID: session.id,
        descriptor: descriptor
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
  }

  func setContentAgreed(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> ContentAgreementData {
    let response: TiebaAgreementState
    do {
      response = try await contentAgreementWriteCoordinator.perform(
        session: session,
        target: target,
        isAgreed: isAgreed
      )
      try Task.checkCancellation()
      let agreement = try Self.contentAgreementData(
        response,
        expectedUserID: session.id,
        expectedTarget: target
      )
      guard agreement.snapshot.isAgreed == isAgreed else {
        throw BrowseError.unavailable("贴吧没有确认新的点赞状态，请重新加载后再试。")
      }
      return agreement
    } catch is CancellationError {
      throw CancellationError()
    } catch ContentAgreementWriteCoordinatorError.conflictingOperationSettled {
      throw BrowseError.unavailable("先前的内容点赞操作已结束，请重新读取当前状态。")
    } catch let error as BrowseError {
      throw error
    } catch {
      throw Self.accountError(error)
    }
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

  private static func coreSessionCredential(
    _ credential: AccountCredentials
  ) -> TiebaSessionCredential {
    let cookieName: TiebaBDUSSCookieName = switch credential.bdussCookieName {
    case .bduss: .bduss
    case .bdussBFESS: .bdussBFESS
    }
    return TiebaSessionCredential(
      bduss: credential.bduss,
      stoken: credential.stoken,
      bdussCookieName: cookieName
    )
  }

  private static func cloudFavoriteDate(_ timestamp: Int64) -> Date? {
    guard timestamp > 0, timestamp <= 253_402_300_799 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
  }

  private static func threadCloudFavoriteData(
    _ state: TiebaThreadCloudFavoriteState,
    expectedUserID: Int64,
    expectedTarget: ThreadCloudFavoriteTarget
  ) throws -> ThreadCloudFavoriteData {
    guard
      expectedUserID > 0,
      state.userID == expectedUserID,
      state.forumID == expectedTarget.forumID,
      state.threadID == expectedTarget.threadID,
      let snapshot = ThreadCloudFavoriteSnapshot(markedPostID: state.markedPostID)
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的主题收藏状态，请重新加载后再试。")
    }
    return ThreadCloudFavoriteData(
      userID: state.userID,
      target: expectedTarget,
      snapshot: snapshot
    )
  }

  static func inboxPageData(
    _ page: TiebaNotificationPage,
    expectedUserID: Int64,
    expectedKind: InboxKind,
    requestedPage: Int
  ) throws -> InboxPage {
    guard
      expectedUserID > 0,
      requestedPage > 0,
      page.userID == expectedUserID,
      notificationKind(page.kind) == expectedKind,
      page.pagination.currentPage == requestedPage,
      page.pagination.hasPrevious == (requestedPage > 1),
      page.pagination.pageSize == page.items.count,
      !page.pagination.hasMore || !page.items.isEmpty
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户消息，请重新加载后再试。")
    }

    var seenPostIDs = Set<Int64>()
    let messages = try page.items.map { item -> InboxMessage in
      guard
        item.id == item.postID,
        item.postID > 0,
        item.threadID > 0,
        item.sender.id > 0,
        item.quotedUser.map({ $0.id > 0 }) ?? true,
        item.quotedPostID.map({ $0 > 0 }) ?? true,
        item.threadType >= 0,
        seenPostIDs.insert(item.postID).inserted
      else {
        throw BrowseError.unavailable("贴吧返回了无效或重复的消息标识，请重新加载后再试。")
      }
      return InboxMessage(
        id: item.postID,
        sender: inboxSender(item.sender),
        quotedUser: item.quotedUser.map(inboxSender),
        threadID: item.threadID,
        postID: item.postID,
        quotedPostID: item.quotedPostID,
        title: item.title,
        content: item.content,
        quotedContent: item.quotedContent,
        forumName: item.forumName,
        createdAt: try notificationDate(item.timestamp),
        isFloorReply: item.isFloorReply,
        isFirstPost: item.isFirstPost,
        isUnread: item.isUnread,
        threadType: item.threadType
      )
    }
    return InboxPage(
      userID: page.userID,
      kind: expectedKind,
      messages: messages,
      currentPage: page.pagination.currentPage,
      hasMore: page.pagination.hasMore
    )
  }

  static func inboxUnreadSummaryData(
    _ summary: TiebaInboxUnreadSummary,
    expectedUserID: Int64
  ) throws -> InboxUnreadSummary {
    guard summary.userID == expectedUserID, expectedUserID > 0 else {
      throw BrowseError.unavailable("贴吧返回了不匹配的未读消息摘要，请重新加载后再试。")
    }
    let counts = [summary.replyCount, summary.mentionCount, summary.fanCount]
    guard counts.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
      throw BrowseError.unavailable("贴吧返回了无效的未读消息计数，请重新加载后再试。")
    }
    return InboxUnreadSummary(
      userID: summary.userID,
      replyCount: summary.replyCount,
      mentionCount: summary.mentionCount,
      fanCount: summary.fanCount
    )
  }

  private static func coreNotificationKind(_ kind: InboxKind) -> TiebaNotificationKind {
    switch kind {
    case .replies: .replies
    case .mentions: .mentions
    }
  }

  private static func notificationKind(_ kind: TiebaNotificationKind) -> InboxKind {
    switch kind {
    case .replies: .replies
    case .mentions: .mentions
    }
  }

  private static func inboxSender(_ sender: TiebaNotificationSender) -> InboxSender {
    InboxSender(
      id: sender.id,
      username: sender.username,
      displayName: sender.displayName,
      portraitURL: SecureTiebaURL.portrait(sender.portrait),
      isFriend: sender.isFriend,
      isFan: sender.isFan
    )
  }

  private static func notificationDate(_ timestamp: Int64) throws -> Date? {
    guard timestamp != 0 else { return nil }
    guard timestamp > 0, timestamp <= 253_402_300_799 else {
      throw BrowseError.unavailable("贴吧返回了无效的消息时间，请重新加载后再试。")
    }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
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

  private static func threadAgreementData(
    _ agreement: TiebaThreadAgreement
  ) -> ThreadAgreementData {
    ThreadAgreementData(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: agreement.firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: max(agreement.agreeScore, 0)
    )
  }

  private static func coreAgreementTarget(
    _ target: ContentAgreementTarget
  ) -> TiebaAgreementTarget {
    switch target.kind {
    case .topic:
      .thread(firstPostID: target.objectID)
    case .post:
      .post(postID: target.objectID)
    case .subpost:
      .subpost(parentPostID: target.parentPostID ?? 0, subpostID: target.objectID)
    }
  }

  private static func contentAgreementTarget(
    _ target: TiebaAgreementTarget,
    forumID: Int64,
    forumName: String,
    threadID: Int64
  ) throws -> ContentAgreementTarget {
    let mapped: ContentAgreementTarget?
    switch target {
    case .thread(let firstPostID):
      mapped = ContentAgreementTarget(
        kind: .topic,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        objectID: firstPostID
      )
    case .post(let postID):
      mapped = ContentAgreementTarget(
        kind: .post,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        objectID: postID
      )
    case .subpost(let parentPostID, let subpostID):
      mapped = ContentAgreementTarget(
        kind: .subpost,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        parentPostID: parentPostID,
        objectID: subpostID
      )
    }
    guard let mapped else {
      throw BrowseError.unavailable("贴吧返回了无效的点赞对象标识，请重新加载后再试。")
    }
    return mapped
  }

  private static func contentAgreementData(
    _ agreement: TiebaAgreementState,
    expectedUserID: Int64,
    expectedTarget: ContentAgreementTarget
  ) throws -> ContentAgreementData {
    guard
      agreement.userID == expectedUserID,
      agreement.forumID == expectedTarget.forumID,
      agreement.threadID == expectedTarget.threadID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的点赞状态，请重新加载后再试。")
    }
    let target = try contentAgreementTarget(
      agreement.target,
      forumID: agreement.forumID,
      forumName: expectedTarget.forumName,
      threadID: agreement.threadID
    )
    guard target == expectedTarget else {
      throw BrowseError.unavailable("贴吧返回了不匹配的点赞对象，请重新加载后再试。")
    }
    return ContentAgreementData(
      userID: agreement.userID,
      target: target,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  private static func contentAgreementPageData(
    _ page: TiebaAgreementPage,
    expectedUserID: Int64,
    descriptor: ContentAgreementReadDescriptor
  ) throws -> ContentAgreementPageData {
    let request = descriptor.request
    guard
      page.userID == expectedUserID,
      page.forumID == request.forumID,
      page.threadID == request.threadID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的批量点赞状态，请重新加载后再试。")
    }
    var seen = Set<ContentAgreementTarget>()
    let expectedCoreTargets = Set(descriptor.expectedTargets.map(coreAgreementTarget))
    var agreements: [ContentAgreementData] = []
    agreements.reserveCapacity(min(page.agreements.count, descriptor.expectedTargets.count))
    for agreement in page.agreements {
      guard
        agreement.userID == expectedUserID,
        agreement.forumID == request.forumID,
        agreement.threadID == request.threadID
      else {
        throw BrowseError.unavailable("贴吧返回了跨账户或跨主题的点赞状态。")
      }
      guard expectedCoreTargets.contains(agreement.target) else { continue }
      let target = try contentAgreementTarget(
        agreement.target,
        forumID: request.forumID,
        forumName: request.forumName,
        threadID: request.threadID
      )
      guard descriptor.expectedTargets.contains(target) else { continue }
      guard seen.insert(target).inserted else {
        throw BrowseError.unavailable("贴吧返回了重复的点赞对象状态。")
      }
      agreements.append(
        ContentAgreementData(
          userID: agreement.userID,
          target: target,
          isAgreed: agreement.isAgreed,
          agreeScore: agreement.agreeScore
        )
      )
    }
    return ContentAgreementPageData(
      userID: page.userID,
      forumID: page.forumID,
      threadID: page.threadID,
      agreements: agreements
    )
  }

  private static func corePostSort(_ sort: ThreadPostSort) -> TiebaPostSort {
    switch sort {
    case .ascending: .ascending
    case .descending: .descending
    case .hot: .hot
    }
  }

  private static func coreTextReplyTarget(
    _ target: TextReplyTarget.Destination
  ) -> TiebaTextReplyTarget {
    switch target {
    case .thread(let firstPostID):
      .thread(firstPostID: firstPostID)
    case .post(let postID):
      .post(postID: postID)
    case .subpost(let parentPostID, let subpostID):
      .subpost(parentPostID: parentPostID, subpostID: subpostID)
    }
  }

  private static func textReplyOutcome(
    _ outcome: TiebaTextReplyOutcome,
    expectedTarget: TextReplyTarget
  ) -> TextReplyOutcome? {
    let mapped: TextReplyOutcome
    switch outcome {
    case .confirmed(let created):
      let mappedCreated: CreatedTextReply = switch created {
      case .post(let postID, let floor):
        .post(postID: postID, floor: floor)
      case .subpost(let parentPostID, let subpostID):
        .subpost(parentPostID: parentPostID, subpostID: subpostID)
      }
      mapped = .confirmed(mappedCreated)
    case .acceptedAwaitingVisibility(let receipt):
      let mappedReceipt: TextReplyReceipt = switch receipt {
      case .post(let postID):
        .post(postID: postID)
      case .subpost(let parentPostID, let subpostID):
        .subpost(parentPostID: parentPostID, subpostID: subpostID)
      }
      mapped = .acceptedAwaitingVisibility(mappedReceipt)
    }

    switch mapped {
    case .confirmed(let created):
      return created.belongs(to: expectedTarget) ? mapped : nil
    case .acceptedAwaitingVisibility(let receipt):
      return receipt.belongs(to: expectedTarget) ? mapped : nil
    }
  }

  private static func textReplyError(_ error: TiebaClientError) -> TextReplySubmissionError {
    switch error {
    case .invalidArgument:
      .invalidSubmission
    case .replyChallengeRequired:
      .challengeRequired
    case .replyOutcomeUnknown:
      .outcomeUnknown
    case .replySubmissionIDConflict:
      .submissionConflict
    case .server(let code, _):
      .server(code: code)
    default:
      .unavailable
    }
  }

  private static func corePostLocation(
    _ location: ThreadPostLocation?
  ) -> TiebaPostLocation? {
    switch location {
    case .postID(let postID): .postID(postID)
    case .pageNumber: .pageNumber
    case .pageCursor(let postID): .pageCursor(postID)
    case .latestReplies(let postID): .latestReplies(after: postID)
    case nil: nil
    }
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
    case .threadAgreementWriteConflict:
      message = "先前的主题点赞操作已结束，请重新读取当前状态。"
    case .threadCloudFavoriteOutcomeUnknown:
      message = "云端收藏结果尚未确认；再次操作时会先重新读取状态，不会自动重发请求。"
    case .replyChallengeRequired, .replyOutcomeUnknown, .replySubmissionIDConflict:
      message = "账户请求失败，请稍后重试。"
    case .server(let code, _):
      message = "账户请求失败（错误码 \(code)）。"
    @unknown default:
      message = "账户请求失败，请稍后重试。"
    }
    return .unavailable(message)
  }
}

private enum ThreadCloudFavoriteWriteOutcome: Sendable {
  case mutated(TiebaThreadCloudFavoriteState)
  case reconciled(TiebaThreadCloudFavoriteState)

  var state: TiebaThreadCloudFavoriteState {
    switch self {
    case .mutated(let state), .reconciled(let state): state
    }
  }
}

private struct ThreadCloudFavoriteWriteIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let sessionRevision: UUID
  let forumName: String
  private let bduss: String
  private let stoken: String
  private let cookieName: TiebaBDUSSCookieName

  init(
    session: StoredAccountSession,
    credential: TiebaSessionCredential,
    target: ThreadCloudFavoriteTarget
  ) {
    sessionRevision = session.sessionRevision
    forumName = target.forumName
    bduss = credential.bduss
    stoken = credential.stoken
    cookieName = credential.bdussCookieName
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionRevision == rhs.sessionRevision
      && lhs.forumName == rhs.forumName
      && lhs.bduss == rhs.bduss
      && lhs.stoken == rhs.stoken
      && lhs.cookieName == rhs.cookieName
  }

  var description: String { "ThreadCloudFavoriteWriteIdentity(redacted)" }
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

private actor ThreadCloudFavoriteWriteCoordinator {
  private struct Key: Hashable, Sendable {
    let userID: Int64
    let forumID: Int64
    let threadID: Int64

    init(userID: Int64, target: ThreadCloudFavoriteTarget) {
      self.userID = userID
      forumID = target.forumID
      threadID = target.threadID
    }
  }

  private struct Entry: Sendable {
    let id: UUID
    let identity: ThreadCloudFavoriteWriteIdentity
    let markedPostID: Int64?
    let task: Task<TiebaThreadCloudFavoriteState, Error>
  }

  private let client: any TiebaAuthenticatedAccountClient
  private var inFlight: [Key: Entry] = [:]
  private var conflictWaiters = 0

  init(client: any TiebaAuthenticatedAccountClient) {
    self.client = client
  }

  func perform(
    session: StoredAccountSession,
    credential: TiebaSessionCredential,
    target: ThreadCloudFavoriteTarget,
    markedPostID: Int64?
  ) async throws -> ThreadCloudFavoriteWriteOutcome {
    try Task.checkCancellation()
    let key = Key(userID: session.id, target: target)
    let identity = ThreadCloudFavoriteWriteIdentity(
      session: session,
      credential: credential,
      target: target
    )
    if let entry = inFlight[key] {
      if entry.identity == identity, entry.markedPostID == markedPostID {
        return .mutated(try await entry.task.value)
      }
      conflictWaiters += 1
      defer { conflictWaiters -= 1 }
      _ = await entry.task.result
      try Task.checkCancellation()
      let reconciled = try await client.getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: session.id,
        forumID: target.forumID,
        threadID: target.threadID
      )
      return .reconciled(reconciled)
    }

    let client = client
    let expectedUserID = session.id
    let entryID = UUID()
    let task = Task.detached { () async throws -> TiebaThreadCloudFavoriteState in
      try await client.setThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: target.forumID,
        threadID: target.threadID,
        markedPostID: markedPostID
      )
    }
    inFlight[key] = Entry(
      id: entryID,
      identity: identity,
      markedPostID: markedPostID,
      task: task
    )
    defer { clearEntry(for: key, id: entryID) }
    return .mutated(try await task.value)
  }

  func conflictWaiterCount() -> Int {
    conflictWaiters
  }

  private func clearEntry(for key: Key, id: UUID) {
    guard inFlight[key]?.id == id else { return }
    inFlight.removeValue(forKey: key)
  }
}

private enum ThreadAgreementWriteCoordinatorError: Error, Sendable {
  case conflictingOperationSettled
}

private struct ThreadAgreementWriteIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let sessionRevision: UUID
  let forumID: Int64
  let forumName: String
  private let bduss: String

  init(session: StoredAccountSession, forumID: Int64, forumName: String) {
    sessionRevision = session.sessionRevision
    self.forumID = forumID
    self.forumName = forumName
    bduss = session.bduss
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionRevision == rhs.sessionRevision
      && lhs.forumID == rhs.forumID
      && lhs.forumName == rhs.forumName
      && lhs.bduss == rhs.bduss
  }

  var description: String { "ThreadAgreementWriteIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "sessionRevision": sessionRevision,
        "forumID": forumID,
        "forumName": forumName,
      ],
      displayStyle: .struct
    )
  }
}

private actor ThreadAgreementWriteCoordinator {
  private struct Key: Hashable, Sendable {
    let userID: Int64
    let threadID: Int64
    let firstPostID: Int64
  }

  private struct Entry: Sendable {
    let id: UUID
    let identity: ThreadAgreementWriteIdentity
    let targetAgreed: Bool
    let task: Task<TiebaThreadAgreement, Error>
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
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    try Task.checkCancellation()
    let normalizedForumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let key = Key(userID: session.id, threadID: threadID, firstPostID: firstPostID)
    let identity = ThreadAgreementWriteIdentity(
      session: session,
      forumID: forumID,
      forumName: normalizedForumName
    )
    if let entry = inFlight[key] {
      if entry.identity == identity, entry.targetAgreed == isAgreed {
        return try await entry.task.value
      }
      conflictWaiters += 1
      defer { conflictWaiters -= 1 }
      _ = await entry.task.result
      try Task.checkCancellation()
      throw ThreadAgreementWriteCoordinatorError.conflictingOperationSettled
    }

    let client = client
    let credential = TiebaBDUSSCredential(bduss: session.bduss)
    let expectedUserID = session.id
    let entryID = UUID()
    let task = Task.detached { () async throws -> TiebaThreadAgreement in
      try await client.setThreadAgreementState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: normalizedForumName,
        threadID: threadID,
        firstPostID: firstPostID,
        isAgreed: isAgreed
      )
    }
    inFlight[key] = Entry(
      id: entryID,
      identity: identity,
      targetAgreed: isAgreed,
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

private enum ContentAgreementWriteCoordinatorError: Error, Sendable {
  case conflictingOperationSettled
}

private actor ContentAgreementWriteCoordinator {
  private struct Key: Hashable, Sendable {
    let userID: Int64
    let forumID: Int64
    let threadID: Int64
    let kind: ContentAgreementKind
    let parentPostID: Int64?
    let objectID: Int64

    init(userID: Int64, target: ContentAgreementTarget) {
      self.userID = userID
      forumID = target.forumID
      threadID = target.threadID
      kind = target.kind
      parentPostID = target.parentPostID
      objectID = target.objectID
    }
  }

  private struct Entry: Sendable {
    let id: UUID
    let identity: ThreadAgreementWriteIdentity
    let targetAgreed: Bool
    let task: Task<TiebaAgreementState, Error>
  }

  private let client: any TiebaAuthenticatedAccountClient
  private var inFlight: [Key: Entry] = [:]
  private var conflictWaiters = 0

  init(client: any TiebaAuthenticatedAccountClient) {
    self.client = client
  }

  func perform(
    session: StoredAccountSession,
    target: ContentAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    try Task.checkCancellation()
    let key = Key(userID: session.id, target: target)
    let identity = ThreadAgreementWriteIdentity(
      session: session,
      forumID: target.forumID,
      forumName: target.forumName
    )
    if let entry = inFlight[key] {
      if entry.identity == identity, entry.targetAgreed == isAgreed {
        return try await entry.task.value
      }
      conflictWaiters += 1
      defer { conflictWaiters -= 1 }
      _ = await entry.task.result
      try Task.checkCancellation()
      throw ContentAgreementWriteCoordinatorError.conflictingOperationSettled
    }

    let client = client
    let credential = TiebaBDUSSCredential(bduss: session.bduss)
    let expectedUserID = session.id
    let coreTarget: TiebaAgreementTarget
    switch target.kind {
    case .topic:
      coreTarget = .thread(firstPostID: target.objectID)
    case .post:
      coreTarget = .post(postID: target.objectID)
    case .subpost:
      coreTarget = .subpost(
        parentPostID: target.parentPostID ?? 0,
        subpostID: target.objectID
      )
    }
    let entryID = UUID()
    let task = Task.detached { () async throws -> TiebaAgreementState in
      try await client.setAgreementState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: target.forumID,
        forumName: target.forumName,
        threadID: target.threadID,
        target: coreTarget,
        isAgreed: isAgreed
      )
    }
    inFlight[key] = Entry(
      id: entryID,
      identity: identity,
      targetAgreed: isAgreed,
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
