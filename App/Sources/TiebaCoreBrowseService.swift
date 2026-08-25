import Foundation
import TiebaCore

protocol TiebaLinkPreviewClient: Sendable {
  func getThreads(
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: TiebaThreadSort,
    featuredOnly: Bool,
    featuredClassificationID: Int?
  ) async throws -> TiebaThreadPage
  func getPosts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeComments: Bool,
    commentsSortedByAgree: Bool,
    commentPageSize: Int
  ) async throws -> TiebaPostPage
}

extension TiebaClient: TiebaLinkPreviewClient {}

struct TiebaCoreBrowseService: BrowseService, SearchService, ForumPostSearchService,
  SearchSuggestionService, HotTopicService, HotThreadService, UserProfileService,
  PersonalizedFeedService, ForumInformationService, ThreadPictureGalleryService,
  ContentReportService, TiebaLinkPreviewService
{
  private let client: TiebaClient
  private let linkPreviewClient: any TiebaLinkPreviewClient
  private let authenticatedClient: TiebaAuthenticatedClient?
  private let contentFilterRepository: any ContentFilterRepository

  init(
    client: TiebaClient = TiebaClient(),
    linkPreviewClient: (any TiebaLinkPreviewClient)? = nil,
    authenticatedClient: TiebaAuthenticatedClient? = nil,
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository()
  ) {
    self.client = client
    self.linkPreviewClient = linkPreviewClient ?? client
    self.authenticatedClient = authenticatedClient
    self.contentFilterRepository = contentFilterRepository
  }

  func reportPageURL(postID: Int64) async throws -> URL {
    do {
      return try await client.getReportPage(postID: postID).url
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
  }

  func pictureIdentifier(for imageURL: URL) -> String? {
    TiebaPicturePageCursor(imageURL: imageURL)?.pictureID
  }

  func picturePage(for request: ThreadPicturePageRequest) async throws -> ThreadPicturePage {
    let cursor: TiebaPicturePageCursor?
    let direction: TiebaPicturePageDirection
    switch request.direction {
    case .bootstrap:
      cursor = TiebaPicturePageCursor(
        imageURL: request.anchorURL,
        overallIndex: request.anchorIndex
      )
      direction = .next
    case .previous:
      cursor = TiebaPicturePageCursor(
        serverPictureID: request.anchorPictureID,
        overallIndex: request.anchorIndex
      )
      direction = .previous
    case .next:
      cursor = TiebaPicturePageCursor(
        serverPictureID: request.anchorPictureID,
        overallIndex: request.anchorIndex
      )
      direction = .next
    }
    guard let cursor else {
      throw BrowseError.unavailable("图片游标无效，已保留本楼图片。")
    }

    let response: TiebaPicturePage
    do {
      response = try await client.getPicturePage(
        forumID: request.context.forumID,
        forumName: request.context.forumName,
        threadID: request.context.threadID,
        cursor: cursor,
        direction: direction,
        onlyThreadAuthor: request.context.onlyThreadAuthor,
        source: Self.mapPicturePageSource(request.context.source)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }

    let occurrences = response.pictures.compactMap { picture -> ThreadPictureOccurrence? in
      guard
        let postID = picture.postID,
        postID > 0,
        let url = SecureTiebaURL.media(picture.originalURL)
      else { return nil }
      return ThreadPictureOccurrence(
        remoteURL: url,
        pictureID: picture.pictureID,
        postID: postID,
        overallIndex: picture.overallIndex,
        width: picture.width,
        height: picture.height
      )
    }
    return ThreadPicturePage(
      occurrences: occurrences,
      totalCount: response.totalPictureCount
    )
  }

  static func mapPicturePageSource(
    _ source: ThreadPictureGalleryContext.Source
  ) -> TiebaPicturePageSource {
    switch source {
    case .post:
      .post
    case .forum:
      .forum
    case .index:
      .index
    }
  }

  func threads(
    forumName: String,
    page: Int,
    pageSize: Int,
    options: ForumBrowseOptions
  ) async throws -> ThreadPageData {
    let response: TiebaThreadPage
    do {
      response = try await client.getThreads(
        forumName: forumName,
        page: page,
        pageSize: pageSize,
        sort: Self.threadSort(options.sort),
        featuredOnly: options.featuredOnly,
        featuredClassificationID: options.featuredClassificationID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return ThreadPageData(
      forum: Self.mapForum(response.forum, fallbackName: forumName),
      threads: response.threads.map { filter.applying(to: Self.mapThread($0)) },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      channels: response.channels.map(Self.mapForumChannel)
    )
  }

  func forumChannelThreads(
    forumID: Int64,
    forumName: String,
    channel: BrowseForumChannel,
    page: Int,
    pageSize: Int,
    sort: ForumChannelSort,
    lastThreadID: Int64?
  ) async throws -> ForumChannelPageData {
    let response: TiebaForumChannelPage
    do {
      response = try await client.getForumChannelThreads(
        forumID: forumID,
        forumName: forumName,
        channel: TiebaForumChannel(
          id: channel.id,
          name: channel.name,
          isDefault: channel.isDefault,
          sortOptions: channel.sortOptions.map {
            TiebaForumChannelSortOption(id: $0.id, title: $0.title)
          }
        ),
        page: page,
        pageSize: pageSize,
        sort: TiebaForumChannelSort(rawValue: sort.rawValue),
        lastThreadID: lastThreadID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return ForumChannelPageData(
      threads: response.threads.map { filter.applying(to: Self.mapThread($0)) },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      nextPageCursor: response.nextPageCursor
    )
  }

  func posts(
    threadID: Int64,
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) async throws -> PostPageData {
    let response: TiebaPostPage
    do {
      response = try await client.getPosts(
        threadID: threadID,
        page: page,
        pageSize: pageSize,
        sort: Self.postSort(options.sort),
        onlyThreadAuthor: options.onlyThreadAuthor,
        location: Self.postLocation(location),
        includeComments: true,
        commentsSortedByAgree: true,
        commentPageSize: 4
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    let mappedThread = Self.mapThread(response.thread, applying: filter)
    let mappedPosts = response.posts.map { Self.mapPost($0, applying: filter) }
    let mappedFirstPost = response.firstPost.map { Self.mapPost($0, applying: filter) }
    let returnedPostIDs = Self.returnedPostIDs(
      response.posts.map(\.id),
      firstPostID: response.firstPost?.id
    )
    return PostPageData(
      thread: mappedThread,
      posts: mappedPosts,
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      hasPrevious: response.pagination.hasPrevious,
      totalPages: response.pagination.totalPages,
      totalCount: response.pagination.totalCount,
      nextPagePostID: Self.nextPagePostID(
        from: response.thread.pagePostIDs,
        returnedPostIDs: returnedPostIDs,
        sort: options.sort
      ),
      originThread: response.originThread.map {
        filter.applying(to: Self.mapOriginThread($0))
      },
      poll: response.poll.map(Self.mapPoll),
      firstPost: mappedFirstPost,
      agreementReadDescriptor: Self.postAgreementDescriptor(
        thread: mappedThread,
        firstPost: mappedFirstPost,
        posts: mappedPosts,
        page: page,
        pageSize: pageSize,
        options: options,
        location: location
      )
    )
  }

  func preview(for target: TiebaLinkTarget) async throws -> TiebaLinkPreviewMetadata? {
    do {
      switch target {
      case .forum(let requestedName):
        let response = try await linkPreviewClient.getThreads(
          forumName: requestedName,
          page: 1,
          pageSize: 1,
          sort: .replyTime,
          featuredOnly: false,
          featuredClassificationID: nil
        )
        guard
          response.pagination.currentPage == 1,
          response.forum.id > 0,
          Self.previewIdentity(response.forum.name) == Self.previewIdentity(requestedName)
        else { return nil }
        return Self.forumPreviewMetadata(response.forum, requestedName: requestedName)

      case .thread(let route):
        let response = try await linkPreviewClient.getPosts(
          threadID: route.threadID,
          page: 1,
          pageSize: 2,
          sort: .ascending,
          onlyThreadAuthor: route.onlyThreadAuthor,
          location: nil,
          includeComments: false,
          commentsSortedByAgree: true,
          commentPageSize: 1
        )
        guard response.pagination.currentPage == 1, response.thread.id == route.threadID else {
          return nil
        }
        let filter: ContentFilterSnapshot
        do {
          filter = try await contentFilterRepository.snapshot()
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          return nil
        }
        let thread = Self.mapThread(response.thread, applying: filter)
        guard thread.localVisibility == .visible, !thread.isServerHidden else { return nil }
        return Self.threadPreviewMetadata(thread, route: route)

      case .user:
        return nil
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
  }

  func resolveThreadIdentity(
    threadID: Int64,
    expectedForumName: String
  ) async throws -> BrowseThreadIdentity {
    let response: TiebaThreadIdentity
    do {
      response = try await client.resolveThreadIdentity(
        threadID: threadID,
        expectedForumName: expectedForumName
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TiebaClientError where error == .threadIdentityConflict {
      throw BrowseIdentityResolutionError.conflictingThreadIdentity
    } catch {
      throw Self.browseError(error)
    }
    return BrowseThreadIdentity(
      threadID: response.threadID,
      forumID: response.forumID,
      forumName: response.forumName
    )
  }

  func resolveForumIdentity(forumName: String) async throws -> BrowseForumIdentity {
    let trimmedForumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedForumName.utf8.count <= 400 else {
      throw BrowseError.invalidForumName
    }
    let expectedForumName = trimmedForumName
      .precomposedStringWithCanonicalMapping
    guard
      !expectedForumName.isEmpty,
      expectedForumName.count <= 100,
      expectedForumName.utf8.count <= 400,
      !expectedForumName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw BrowseError.invalidForumName
    }

    let response: TiebaThreadPage
    do {
      response = try await linkPreviewClient.getThreads(
        forumName: expectedForumName,
        page: 1,
        pageSize: 1,
        sort: .replyTime,
        featuredOnly: false,
        featuredClassificationID: nil
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }

    let rawResolvedForumName = response.forum.name
    guard
      rawResolvedForumName.utf8.count <= 400,
      !rawResolvedForumName.unicodeScalars.contains(
        where: CharacterSet.controlCharacters.contains
      )
    else {
      throw BrowseError.unavailable("贴吧没有返回可验证的身份信息。")
    }
    let resolvedForumName = rawResolvedForumName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      response.pagination.currentPage == 1,
      response.forum.id > 0,
      !resolvedForumName.isEmpty,
      resolvedForumName.count <= 100,
      resolvedForumName.utf8.count <= 400,
      resolvedForumName == expectedForumName
    else {
      throw BrowseError.unavailable("贴吧没有返回可验证的身份信息。")
    }
    return BrowseForumIdentity(
      forumID: response.forum.id,
      forumName: resolvedForumName
    )
  }

  func comments(threadID: Int64, postID: Int64, page: Int) async throws -> CommentPageData {
    let response: TiebaCommentPage
    do {
      response = try await client.getComments(
        threadID: threadID,
        postID: postID,
        page: page
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return try Self.mapCommentPage(
      response,
      requestedThreadID: threadID,
      expectedPostID: postID,
      requestedPage: page,
      aroundCommentID: nil,
      filter: filter
    )
  }

  func comments(
    threadID: Int64,
    postID: Int64,
    aroundCommentID commentID: Int64,
    page: Int
  ) async throws -> CommentPageData {
    let response: TiebaCommentPage
    do {
      response = try await client.getComments(
        threadID: threadID,
        postID: postID,
        aroundCommentID: commentID,
        page: page
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return try Self.mapCommentPage(
      response,
      requestedThreadID: threadID,
      expectedPostID: postID,
      requestedPage: page,
      aroundCommentID: commentID,
      filter: filter
    )
  }

  func comments(
    threadID: Int64,
    resolvingCommentID commentID: Int64
  ) async throws -> CommentPageData {
    let response: TiebaCommentPage
    do {
      response = try await client.getComments(
        threadID: threadID,
        resolvingCommentID: commentID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return try Self.mapCommentPage(
      response,
      requestedThreadID: threadID,
      expectedPostID: nil,
      requestedPage: 1,
      aroundCommentID: commentID,
      filter: filter
    )
  }

  func searchForums(query: String) async throws -> ForumSearchData {
    let response: TiebaForumSearchResults
    do {
      response = try await client.searchForums(query: query)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return ForumSearchData(
      exactMatch: response.exactMatch.map(Self.mapForumSearchResult),
      related: response.fuzzyMatches.map(Self.mapForumSearchResult)
    )
  }

  func searchUsers(query: String) async throws -> UserSearchData {
    let response: TiebaUserSearchResults
    do {
      response = try await client.searchUsers(query: query)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return UserSearchData(
      exactMatch: response.exactMatch.map(Self.mapUserSearchResult),
      related: response.fuzzyMatches.map(Self.mapUserSearchResult)
    )
  }

  func searchSuggestions(query: String) async throws -> [String] {
    do {
      return try await client.searchSuggestions(query: query)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
  }

  func searchThreads(
    query: String,
    page: Int,
    pageSize: Int,
    sort: GlobalThreadSearchSort
  ) async throws
    -> ThreadSearchPageData
  {
    let response: TiebaThreadSearchPage
    do {
      response = try await client.searchThreads(
        query: query,
        page: page,
        pageSize: pageSize,
        sort: Self.mapGlobalThreadSearchSort(sort)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return Self.mapGlobalThreadSearchPage(response, applying: filter)
  }

  func searchForumPosts(
    query: String,
    forumName: String,
    page: Int,
    pageSize: Int,
    sort: ForumPostSearchSort,
    filter: ForumPostSearchFilter
  ) async throws -> ForumPostSearchPageData {
    let response: TiebaThreadSearchPage
    do {
      response = try await client.searchForumPosts(
        query: query,
        forumName: forumName,
        page: page,
        pageSize: pageSize,
        sort: Self.mapForumPostSearchSort(sort),
        filter: Self.mapForumPostSearchFilter(filter)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let contentFilter = await contentFilterSnapshot()
    return ForumPostSearchPageData(
      results: response.results.map {
        Self.mapForumPostSearchResult($0, applying: contentFilter)
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore
    )
  }

  func hotTopics() async throws -> [HotTopicItem] {
    let response: [TiebaHotTopic]
    do {
      response = try await client.getHotTopics()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return response.map(Self.mapHotTopic)
  }

  func hotTopic(
    id: Int64,
    name: String,
    page: Int,
    pageSize: Int,
    lastID: Int64?
  ) async throws -> HotTopicPageData {
    let response: TiebaHotTopicPage
    do {
      response = try await client.getHotTopic(
        topicID: id,
        topicName: name,
        page: page,
        pageSize: pageSize,
        lastID: lastID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return HotTopicPageData(
      topic: Self.mapHotTopic(response.topic),
      relatedForums: response.relatedForums.map(Self.mapHotTopicForum),
      threads: response.threads.map(Self.mapThreadSearchResult),
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      nextPageCursor: response.nextPageCursor
    )
  }

  func hotThreads(categoryCode: String) async throws -> HotThreadFeedData {
    let response: TiebaHotThreadRanking
    do {
      response = try await client.getHotThreadRanking(categoryCode: categoryCode)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let filter = await contentFilterSnapshot()
    return HotThreadFeedData(
      topics: response.topics.map(Self.mapHotTopic),
      categories: response.categories.map(Self.mapHotThreadCategory),
      items: response.items.map { Self.mapHotThreadRankItem($0, applying: filter) }
    )
  }

  func personalizedThreads(page: Int) async throws -> PersonalizedFeedPageData {
    let response: TiebaPersonalizedPage
    do {
      response = try await client.getPersonalizedThreads(page: page)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return await personalizedPageData(response)
  }

  func personalizedThreads(
    page: Int,
    session: StoredAccountSession
  ) async throws -> PersonalizedFeedPageData {
    guard let authenticatedClient else {
      throw BrowseError.unavailable("当前推荐服务不支持账号个性。")
    }
    guard session.id > 0, let credentials = session.credentials else {
      throw BrowseError.unavailable("所选账号需要重新登录，才能用于个性推荐。")
    }
    let cookieName: TiebaBDUSSCookieName
    switch credentials.bdussCookieName {
    case .bduss:
      cookieName = .bduss
    case .bdussBFESS:
      cookieName = .bdussBFESS
    }
    let response: TiebaPersonalizedPage
    do {
      response = try await authenticatedClient.getPersonalizedThreads(
        credential: TiebaSessionCredential(
          bduss: credentials.bduss,
          stoken: credentials.stoken,
          bdussCookieName: cookieName
        ),
        expectedUserID: session.id,
        page: page
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return await personalizedPageData(response)
  }

  private func personalizedPageData(
    _ response: TiebaPersonalizedPage
  ) async -> PersonalizedFeedPageData {
    let filter = await contentFilterSnapshot()
    return PersonalizedFeedPageData(
      items: response.items.map { item in
        PersonalizedFeedItem(
          thread: filter.applying(to: Self.mapThread(item.thread)),
          feedbackReasons: item.reasons.map {
            PersonalizedFeedbackReason(id: $0.id, title: $0.title, extra: $0.extra)
          }
        )
      },
      currentPage: response.currentPage,
      hasMore: response.hasMore
    )
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    let response: TiebaUserProfile
    do {
      response = try await client.getUserProfile(userID: userID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return Self.mapUserProfile(response)
  }

  static func mapUserProfile(_ response: TiebaUserProfile) -> BrowseUserProfile {
    BrowseUserProfile(
      id: response.user.id,
      tiebaUID: response.tiebaUID,
      username: response.user.username,
      displayName: response.user.displayName,
      portraitURL: SecureTiebaURL.portrait(response.user.portrait),
      largePortraitURL: SecureTiebaURL.largePortrait(response.portraitSource),
      growthLevel: response.user.growthLevel,
      gender: Self.mapGender(response.user.gender),
      ipLocation: response.user.ipLocation,
      badges: response.user.badges,
      biography: response.biography,
      tiebaAge: response.tiebaAge,
      threadCount: response.threadCount,
      postCount: response.postCount,
      followerCount: response.followerCount,
      followingCount: response.followingCount,
      followedForumCount: max(response.followedForumCount, response.likedForums.count),
      likedForums: response.likedForums.map {
        BrowseProfileForum(id: $0.id, name: $0.name)
      },
      totalAgreeCount: response.totalAgreeCount,
      isModerator: response.user.isModerator,
      moderatorRole: mapModeratorRole(response.user.moderatorRole),
      isVIP: response.user.isVIP,
      isVerifiedCreator: response.user.isVerifiedCreator,
      verifiedCreatorField: response.user.verifiedCreatorField,
      isBlocked: response.isBlocked
    )
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  {
    let response: TiebaUserThreadPage
    do {
      response = try await client.getUserThreads(
        userID: userID,
        page: page,
        pageSize: pageSize
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let contentFilter = await contentFilterSnapshot()
    return Self.mapUserThreadPage(response, applying: contentFilter)
  }

  static func mapUserThreadPage(
    _ response: TiebaUserThreadPage,
    applying filter: ContentFilterSnapshot = .empty
  ) -> UserThreadPageData {
    UserThreadPageData(
      threads: response.threads.map { thread in
        let mapped = mapThread(thread)
        return filter.applying(
          to: mapped,
          hasKnownVideo: mapped.kind == .video
        )
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      isHidden: response.isHidden
    )
  }

  func userReplies(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserReplyPageData
  {
    let response: TiebaUserReplyPage
    do {
      response = try await client.getUserReplies(
        userID: userID,
        page: page,
        pageSize: pageSize
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    let contentFilter = await contentFilterSnapshot()
    return Self.mapUserReplyPage(response, applying: contentFilter)
  }

  static func mapUserReplyPage(
    _ response: TiebaUserReplyPage,
    applying filter: ContentFilterSnapshot = .empty
  ) -> UserReplyPageData {
    UserReplyPageData(
      replies: response.replies.map { reply in
        let mapped = BrowseUserReply(
          threadID: reply.threadID,
          postID: reply.postID,
          forumID: reply.forumID,
          forumName: reply.forumName,
          threadTitle: reply.threadTitle,
          excerpt: summary(for: reply.content),
          createdAt: reply.createdAt,
          authorID: reply.author?.id ?? 0,
          authorName: authorName(reply.author),
          authorUsername: authorUsername(reply.author),
          target: mapUserReplyTarget(reply.target)
        )
        return filter.applying(to: mapped)
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      isHidden: response.isHidden
    )
  }

  func userRelations(userID: Int64, kind: UserRelationKind, page: Int) async throws
    -> UserRelationPageData
  {
    let coreKind = Self.mapUserRelationKind(kind)
    let response: TiebaUserRelationPage
    do {
      response = try await client.getUserRelations(
        userID: userID,
        kind: coreKind,
        page: page
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    try Self.validateUserRelationPageContext(
      response,
      expectedUserID: userID,
      expectedKind: kind
    )
    let contentFilter = await contentFilterSnapshot()
    return try Self.mapUserRelationPage(
      response,
      expectedUserID: userID,
      expectedKind: kind,
      applying: contentFilter
    )
  }

  static func mapUserRelationPage(
    _ response: TiebaUserRelationPage,
    expectedUserID: Int64,
    expectedKind: UserRelationKind,
    applying filter: ContentFilterSnapshot = .empty
  ) throws -> UserRelationPageData {
    try validateUserRelationPageContext(
      response,
      expectedUserID: expectedUserID,
      expectedKind: expectedKind
    )

    return UserRelationPageData(
      users: response.users.map { user in
        filter.applying(
          to: BrowseRelatedUser(
            id: user.id,
            username: user.username,
            displayName: user.displayName,
            portraitURL: SecureTiebaURL.portrait(user.portrait),
            introduction: user.introduction,
            concernState: mapRelatedUserConcernState(user.concernState)
          )
        )
      },
      currentPage: response.pagination.currentPage,
      totalCount: response.pagination.totalCount,
      hasMore: response.pagination.hasMore,
      notice: response.notice,
      visibilitySwitch: response.visibilitySwitch
    )
  }

  private static func validateUserRelationPageContext(
    _ response: TiebaUserRelationPage,
    expectedUserID: Int64,
    expectedKind: UserRelationKind
  ) throws {
    guard
      expectedUserID > 0,
      response.requestedUserID == expectedUserID,
      response.kind == mapUserRelationKind(expectedKind)
    else {
      throw BrowseError.unavailable("用户关系列表响应与请求不匹配。")
    }
  }

  private static func mapUserRelationKind(
    _ kind: UserRelationKind
  ) -> TiebaUserRelationKind {
    switch kind {
    case .following:
      .following
    case .followers:
      .followers
    }
  }

  private static func mapRelatedUserConcernState(
    _ state: TiebaRelatedUserConcernState?
  ) -> BrowseRelatedUserConcernState? {
    guard let state else { return nil }
    switch state {
    case .notFollowing:
      return .notFollowing
    case .following:
      return .following
    case .mutual:
      return .mutual
    case .unknown(let rawValue):
      return .unknown(rawValue)
    }
  }

  private static func mapUserReplyTarget(
    _ target: TiebaUserReplyTarget
  ) -> BrowseUserReplyTarget {
    switch target {
    case .post:
      .post
    case .comment:
      .comment
    case .unsupported(let rawType):
      .unsupported(rawType: rawType)
    }
  }

  func forumOverview(forumID: Int64) async throws -> BrowseForumOverview {
    let response: TiebaForumOverview
    do {
      response = try await client.getForumOverview(forumID: forumID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return BrowseForumOverview(
      forum: Self.mapForum(response.forum, fallbackName: response.forum.name),
      introduction: response.introduction,
      originalAvatarURL: SecureTiebaURL.media(response.originalAvatar)
    )
  }

  func forumModeratorRoles(forumID: Int64) async throws -> [BrowseForumModeratorRole] {
    let response: [TiebaForumModeratorRole]
    do {
      response = try await client.getForumModerators(forumID: forumID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return response.enumerated().map { index, role in
      BrowseForumModeratorRole(
        id: index,
        name: role.name,
        moderators: role.moderators.map(Self.mapForumModerator)
      )
    }
  }

  func forumRules(forumID: Int64) async throws -> BrowseForumRules {
    let response: TiebaForumRules
    do {
      response = try await client.getForumRules(forumID: forumID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.browseError(error)
    }
    return BrowseForumRules(
      title: response.title,
      preface: response.preface,
      rules: response.rules.enumerated().map { index, rule in
        BrowseForumRule(
          id: index,
          title: rule.title,
          contents: Self.mapContent(rule.content)
        )
      },
      publishTime: response.publishTime,
      author: response.author.map(Self.mapForumModerator)
    )
  }

  static func mapThread(_ thread: TiebaThread) -> BrowseThread {
    BrowseThread(
      id: thread.id,
      forumID: thread.forumID,
      forumName: thread.forumName,
      title: thread.title,
      excerpt: summary(for: thread.content),
      authorName: authorName(thread.author),
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      createdAt: thread.createdAt,
      lastReplyAt: thread.lastReplyAt,
      contents: mapContent(thread.content),
      authorID: thread.author?.id ?? 0,
      authorUsername: authorUsername(thread.author),
      authorAvatarURL: SecureTiebaURL.portrait(thread.author?.portrait),
      firstPostID: thread.firstPostID,
      contentPostID: summaryContentPostID(for: thread),
      shareCount: max(thread.shareCount, 0),
      agreeCount: max(thread.agreeCount, 0),
      disagreeCount: max(thread.disagreeCount, 0),
      kind: mapThreadKind(thread.kind),
      tabID: thread.tabID,
      isPinned: thread.isPinned,
      isFeatured: thread.isFeatured,
      isShared: thread.isShared,
      isServerHidden: thread.isHidden,
      isLive: thread.isLive
    )
  }

  static func summaryContentPostID(for thread: TiebaThread) -> Int64 {
    let images = thread.content.images
    guard !images.isEmpty else { return max(thread.firstPostID, 0) }
    let knownPostIDs = images.compactMap(\.postID)
    guard
      !knownPostIDs.isEmpty,
      knownPostIDs.count == images.count,
      Set(knownPostIDs).count == 1
    else { return 0 }
    return knownPostIDs[0]
  }

  static func mapThread(
    _ thread: TiebaThread,
    applying filter: ContentFilterSnapshot
  ) -> BrowseThread {
    filter.applying(to: mapThread(thread))
  }

  static func mapForumChannel(_ channel: TiebaForumChannel) -> BrowseForumChannel {
    BrowseForumChannel(
      id: channel.id,
      name: channel.name,
      isDefault: channel.isDefault,
      sortOptions: channel.sortOptions.map {
        BrowseForumChannelSortOption(id: $0.id, title: $0.title)
      }
    )
  }

  static func mapHotThreadCategory(_ category: TiebaHotThreadCategory) -> HotThreadCategory {
    HotThreadCategory(
      serverID: category.serverID,
      code: category.code,
      title: category.title
    )
  }

  static func mapHotThreadRankItem(
    _ item: TiebaHotThreadRankItem,
    applying filter: ContentFilterSnapshot = .empty
  ) -> HotThreadRankItem {
    HotThreadRankItem(
      rank: item.rank,
      hotScore: max(item.hotScore, 0),
      thread: filter.applying(to: mapThread(item.thread))
    )
  }

  private static func mapThreadKind(_ kind: TiebaThreadKind) -> BrowseThreadKind {
    switch kind {
    case .article:
      .article
    case .album:
      .album
    case .externalShare:
      .externalShare
    case .voice:
      .voice
    case .cloudDrive:
      .cloudDrive
    case .story:
      .story
    case .video:
      .video
    case .live:
      .live
    case .help:
      .help
    case .vote:
      .vote
    case .lottery:
      .lottery
    case .unknown(let rawValue):
      .unknown(rawValue)
    }
  }

  static func mapOriginThread(_ thread: TiebaOriginThread) -> BrowseThread {
    BrowseThread(
      id: thread.id,
      forumID: thread.forumID,
      forumName: thread.forumName,
      title: thread.title,
      excerpt: summary(for: thread.content),
      authorName: "",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: mapContent(thread.content),
      firstPostID: thread.firstPostID
    )
  }

  static func mapPoll(_ poll: TiebaPoll) -> BrowsePoll {
    BrowsePoll(
      title: poll.title,
      isMultipleChoice: poll.isMultipleChoice,
      participantCount: max(poll.participantCount, 0),
      totalVoteCount: max(poll.totalVoteCount, 0),
      options: poll.options.map { option in
        BrowsePollOption(
          id: option.id,
          text: option.text,
          voteCount: max(option.voteCount, 0),
          imageURL: SecureTiebaURL.media(option.image)
        )
      },
      isPolled: poll.isPolled,
      selectedOptionIDs: poll.selectedOptionIDs,
      tips: poll.tips,
      endTimestamp: poll.endTimestamp,
      status: poll.status
    )
  }

  private static func mapForum(_ forum: TiebaForum, fallbackName: String) -> BrowseForum {
    BrowseForum(
      id: forum.id,
      name: forum.name.isEmpty ? fallbackName : forum.name,
      category: forum.category,
      subcategory: forum.subcategory,
      memberCount: forum.memberCount,
      threadCount: forum.threadCount,
      postCount: forum.postCount,
      avatarURL: SecureTiebaURL.media(forum.avatar),
      slogan: forum.slogan,
      hasModerators: forum.hasModerators,
      hasRules: forum.hasRules,
      featuredClassifications: forum.featuredClassifications.map {
        BrowseForumClassification(id: $0.id, name: $0.name)
      }
    )
  }

  private static func mapForumModerator(
    _ moderator: TiebaForumModerator
  ) -> BrowseForumModerator {
    BrowseForumModerator(
      id: moderator.id,
      username: moderator.username,
      displayName: moderator.displayName,
      portraitURL: SecureTiebaURL.portrait(moderator.portrait),
      level: moderator.level,
      roleName: moderator.roleName
    )
  }

  private static func mapForumSearchResult(_ result: TiebaForumSearchResult) -> ForumSearchItem {
    let summary = result.slogan.isEmpty ? result.introduction : result.slogan
    return ForumSearchItem(
      id: result.id,
      name: result.name,
      displayName: result.displayName,
      avatarURL: SecureTiebaURL.media(result.avatarURL),
      postCount: result.postCount,
      memberCount: result.memberCount,
      summary: summary
    )
  }

  private static func mapUserSearchResult(_ result: TiebaUserSearchResult) -> UserSearchItem {
    UserSearchItem(
      id: result.id,
      username: result.username,
      displayName: result.displayName,
      portraitURL: SecureTiebaURL.portrait(result.portrait),
      introduction: result.introduction
    )
  }

  static func mapHotTopic(_ topic: TiebaHotTopic) -> HotTopicItem {
    HotTopicItem(
      id: topic.id,
      name: topic.name,
      summary: topic.description,
      imageURL: SecureTiebaURL.media(topic.imageURL),
      discussionCount: topic.discussionCount,
      rank: topic.rank,
      tag: topic.tag
    )
  }

  private static func mapHotTopicForum(_ forum: TiebaHotTopicForum) -> ForumSearchItem {
    ForumSearchItem(
      id: forum.id,
      name: forum.name,
      displayName: forum.name,
      avatarURL: SecureTiebaURL.media(forum.avatarURL),
      postCount: forum.postCount,
      memberCount: forum.memberCount,
      summary: forum.description
    )
  }

  static func mapThreadSearchResult(_ result: TiebaThreadSearchResult) -> BrowseThread {
    let images: [BrowseContent] = result.images.compactMap { image in
      guard
        let thumbnail = firstSecureMediaURL(image.thumbnailURL, image.fullSizeURL)
      else { return nil }
      return .image(
        thumbnail: thumbnail,
        fullSize: SecureTiebaURL.media(image.fullSizeURL),
        original: nil,
        width: image.width,
        height: image.height
      )
    }
    return BrowseThread(
      id: result.threadID,
      forumID: result.forumID,
      forumName: result.forumName,
      title: result.title,
      excerpt: result.excerpt,
      authorName: result.authorName,
      replyCount: result.replyCount,
      viewCount: 0,
      createdAt: result.createdAt,
      lastReplyAt: nil,
      contents: [.text(result.excerpt)] + images,
      authorID: result.authorID,
      authorUsername: result.authorUsername,
      authorAvatarURL: SecureTiebaURL.media(result.authorPortraitURL),
      firstPostID: result.firstPostID,
      contentPostID: summaryContentPostID(for: result),
      shareCount: max(result.shareCount, 0),
      agreeCount: max(result.likeCount, 0)
    )
  }

  private static func summaryContentPostID(for result: TiebaThreadSearchResult) -> Int64 {
    switch result.target {
    case .thread:
      max(result.firstPostID, 0)
    case .post(let postID):
      max(postID, 0)
    case .comment:
      0
    }
  }

  static func mapGlobalThreadSearchPage(
    _ response: TiebaThreadSearchPage,
    applying filter: ContentFilterSnapshot = .empty
  ) -> ThreadSearchPageData {
    ThreadSearchPageData(
      threads: response.results.map {
        mapGlobalThreadSearchResult($0, applying: filter)
      },
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore
    )
  }

  static func mapGlobalThreadSearchResult(
    _ result: TiebaThreadSearchResult,
    applying filter: ContentFilterSnapshot = .empty
  ) -> BrowseThread {
    filter.applying(
      to: mapThreadSearchResult(result),
      hasKnownVideo: result.hasVideo
    )
  }

  static func mapForumPostSearchResult(
    _ result: TiebaThreadSearchResult,
    applying filter: ContentFilterSnapshot = .empty
  ) -> ForumPostSearchItem {
    let target = mapForumPostSearchTarget(result.target)
    let mainPostContext = matchingMainPostContext(
      result.mainPost,
      threadID: result.threadID,
      firstPostID: result.firstPostID
    )
    let parentPostContext: TiebaSearchPostContext?
    if case .comment(let parentPostID, _) = target {
      parentPostContext = matchingParentPostContext(
        result.postInfo,
        threadID: result.threadID,
        parentPostID: parentPostID
      )
    } else {
      parentPostContext = nil
    }
    let threadContext = mainPostContext ?? parentPostContext
    let displayContexts: [ForumPostSearchContext]
    switch target {
    case .thread:
      displayContexts = []
    case .post:
      displayContexts = mainPostContext.map {
        [mapForumPostSearchContext($0, target: .mainPost(threadID: $0.threadID))]
      } ?? []
    case .comment(let parentPostID, _):
      var contexts: [ForumPostSearchContext] = []
      if let parentPostContext {
        contexts.append(
          mapForumPostSearchContext(
            parentPostContext,
            target: .parentPost(
              threadID: parentPostContext.threadID,
              postID: parentPostID
            )
          )
        )
      }
      if let mainPostContext {
        contexts.append(
          mapForumPostSearchContext(
            mainPostContext,
            target: .mainPost(threadID: mainPostContext.threadID)
          )
        )
      }
      displayContexts = contexts
    }
    let contextTitle = threadContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let contextExcerpt = threadContext?.excerpt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let threadTitle = contextTitle.isEmpty ? result.title : contextTitle
    let threadExcerpt = contextExcerpt.isEmpty ? result.excerpt : contextExcerpt
    let threadAuthorName: String
    let threadAuthorUsername: String
    let threadAuthorAvatarURL: URL?
    if let threadContext {
      let contextAuthorName = threadContext.authorName.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let contextAuthorUsername = threadContext.authorUsername.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      threadAuthorName = contextAuthorName.isEmpty
        ? (contextAuthorUsername.isEmpty ? "匿名用户" : contextAuthorUsername)
        : contextAuthorName
      threadAuthorUsername = contextAuthorUsername
      threadAuthorAvatarURL = SecureTiebaURL.media(threadContext.authorPortraitURL)
    } else {
      threadAuthorName = result.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
      threadAuthorUsername = result.authorUsername.trimmingCharacters(in: .whitespacesAndNewlines)
      threadAuthorAvatarURL = SecureTiebaURL.media(result.authorPortraitURL)
    }
    let matchedContents = mapSearchImages(result.images)
    let threadReplyCount = target == .thread ? result.replyCount : threadContext?.replyCount ?? 0

    let mapped = ForumPostSearchItem(
      thread: BrowseThread(
        id: result.threadID,
        forumID: result.forumID,
        forumName: result.forumName,
        title: threadTitle,
        excerpt: threadExcerpt,
        authorName: threadAuthorName,
        replyCount: threadReplyCount,
        viewCount: 0,
        createdAt: target == .thread ? result.createdAt : nil,
        lastReplyAt: nil,
        contents: threadExcerpt.isEmpty ? [] : [.text(threadExcerpt)],
        authorID: threadContext?.authorID ?? result.authorID,
        authorUsername: threadAuthorUsername,
        authorAvatarURL: threadAuthorAvatarURL
      ),
      target: target,
      matchedTitle: result.title,
      matchedExcerpt: result.excerpt,
      matchedAuthorID: result.authorID,
      matchedAuthorName: result.authorName,
      matchedAuthorPortraitURL: SecureTiebaURL.media(result.authorPortraitURL),
      matchedAt: result.createdAt,
      replyCount: result.replyCount,
      likeCount: result.likeCount,
      shareCount: result.shareCount,
      matchedContents: matchedContents,
      contexts: displayContexts,
      matchedAuthorUsername: result.authorUsername
    )
    return filter.applying(to: mapped, hasKnownVideo: result.hasVideo)
  }

  private static func matchingSearchContext(
    _ context: TiebaSearchPostContext?,
    threadID: Int64
  ) -> TiebaSearchPostContext? {
    guard threadID > 0, context?.threadID == threadID else { return nil }
    return context
  }

  private static func matchingMainPostContext(
    _ context: TiebaSearchPostContext?,
    threadID: Int64,
    firstPostID: Int64
  ) -> TiebaSearchPostContext? {
    guard let context = matchingSearchContext(context, threadID: threadID) else { return nil }
    let contextPostID = context.postID ?? 0
    guard contextPostID <= 0 || firstPostID <= 0 || contextPostID == firstPostID else {
      return nil
    }
    return context
  }

  private static func matchingParentPostContext(
    _ context: TiebaSearchPostContext?,
    threadID: Int64,
    parentPostID: Int64
  ) -> TiebaSearchPostContext? {
    guard
      parentPostID > 0,
      let context = matchingSearchContext(context, threadID: threadID),
      context.postID == parentPostID
    else { return nil }
    return context
  }

  private static func mapForumPostSearchContext(
    _ context: TiebaSearchPostContext,
    target: ForumPostSearchContextTarget
  ) -> ForumPostSearchContext {
    ForumPostSearchContext(
      target: target,
      summary: ForumPostSearchSummary(
        postID: context.postID ?? 0,
        title: context.title,
        excerpt: context.excerpt,
        authorID: context.authorID,
        authorName: context.authorName,
        authorUsername: context.authorUsername
      )
    )
  }

  private static func mapForumPostSearchTarget(
    _ target: TiebaThreadSearchTarget
  ) -> ForumPostSearchTarget {
    switch target {
    case .thread:
      .thread
    case .post(let postID):
      .post(postID)
    case .comment(let postID, let commentID):
      .comment(postID: postID, commentID: commentID)
    @unknown default:
      .thread
    }
  }

  private static func mapSearchImages(_ images: [TiebaSearchImage]) -> [BrowseContent] {
    images.compactMap { image in
      guard
        let thumbnail = firstSecureMediaURL(image.thumbnailURL, image.fullSizeURL)
      else { return nil }
      return .image(
        thumbnail: thumbnail,
        fullSize: SecureTiebaURL.media(image.fullSizeURL),
        original: nil,
        width: image.width,
        height: image.height
      )
    }
  }

  static func mapPost(_ post: TiebaPost) -> BrowsePost {
    let inlineComments = mapInlineComments(post.comments, enclosingPost: post)
    return BrowsePost(
      id: post.id,
      threadID: post.threadID,
      floor: post.floor,
      authorID: post.author?.id ?? 0,
      authorName: authorName(post.author),
      authorPortraitURL: SecureTiebaURL.portrait(post.author?.portrait),
      createdAt: post.createdAt,
      nestedReplyCount: max(max(post.commentCount, 0), inlineComments.count),
      isThreadAuthor: post.isThreadAuthor,
      contents: mapContent(post.content),
      authorUsername: authorUsername(post.author),
      authorLevel: max(post.author?.level ?? 0, 0),
      authorIPLocation: (post.author?.ipLocation ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      moderatorRole: mapModeratorRole(post.author?.moderatorRole),
      agreeScore: max(post.agreeScore, 0),
      inlineComments: inlineComments
    )
  }

  static func mapPost(
    _ post: TiebaPost,
    applying filter: ContentFilterSnapshot
  ) -> BrowsePost {
    filter.applying(to: mapPost(post))
  }

  static func mapCommentPage(
    _ response: TiebaCommentPage,
    requestedThreadID: Int64,
    expectedPostID: Int64?,
    requestedPage: Int = 1,
    aroundCommentID: Int64? = nil,
    filter: ContentFilterSnapshot
  ) throws -> CommentPageData {
    let parentPost = response.parentPost
    let hasValidParentAnchor: Bool
    if let expectedPostID {
      hasValidParentAnchor = expectedPostID > 0 && expectedPostID == parentPost.id
    } else {
      hasValidParentAnchor = aroundCommentID.map({ $0 > 0 }) ?? false
    }
    guard
      requestedThreadID > 0,
      hasValidParentAnchor,
      response.thread.id == requestedThreadID,
      parentPost.id > 0,
      parentPost.threadID == requestedThreadID
    else {
      throw BrowseError.unavailable("贴吧返回的楼中楼归属异常，未显示该响应。")
    }

    var seen = Set<Int64>()
    let comments = response.comments.compactMap { comment -> BrowseComment? in
      guard
        comment.id > 0,
        comment.threadID == requestedThreadID,
        comment.parentPostID == parentPost.id,
        seen.insert(comment.id).inserted
      else { return nil }
      return filter.applying(to: mapComment(comment))
    }
    if expectedPostID == nil, let aroundCommentID,
      !comments.contains(where: { $0.id == aroundCommentID })
    {
      throw BrowseError.unavailable("贴吧未返回要定位的楼中楼回复，未显示该响应。")
    }
    let mappedThread = mapThread(response.thread, applying: filter)
    let mappedParentPost = filter.applying(to: mapCommentParentPost(parentPost))
    return CommentPageData(
      parentPost: mappedParentPost,
      comments: comments,
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      hasPrevious: response.pagination.hasPrevious,
      totalPages: response.pagination.totalPages,
      totalCount: max(
        max(response.pagination.totalCount, parentPost.commentCount),
        comments.count
      ),
      thread: mappedThread,
      agreementReadDescriptor: subpostAgreementDescriptor(
        thread: mappedThread,
        parentPost: mappedParentPost,
        comments: comments,
        requestedPage: requestedPage,
        aroundCommentID: aroundCommentID
      )
    )
  }

  static func mapCommentParentPost(_ post: TiebaPost) -> CommentParentPostContext {
    CommentParentPostContext(
      id: post.id,
      threadID: post.threadID,
      floor: post.floor,
      authorID: post.author?.id ?? 0,
      authorName: authorName(post.author),
      authorPortraitURL: SecureTiebaURL.portrait(post.author?.portrait),
      createdAt: post.createdAt,
      isThreadAuthor: post.isThreadAuthor,
      contents: mapContent(post.content),
      authorUsername: authorUsername(post.author),
      authorLevel: max(post.author?.level ?? 0, 0),
      authorIPLocation: (post.author?.ipLocation ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      moderatorRole: mapModeratorRole(post.author?.moderatorRole),
      agreeScore: max(post.agreeScore, 0)
    )
  }

  private static func mapInlineComments(
    _ comments: [TiebaComment],
    enclosingPost post: TiebaPost
  ) -> [BrowseComment] {
    var seen = Set<Int64>()
    var result: [BrowseComment] = []
    result.reserveCapacity(min(comments.count, 4))
    for comment in comments {
      guard
        comment.id > 0,
        comment.threadID == post.threadID,
        comment.parentPostID == post.id,
        seen.insert(comment.id).inserted
      else { continue }
      result.append(mapComment(comment))
      if result.count == 4 { break }
    }
    return result
  }

  static func mapComment(_ comment: TiebaComment) -> BrowseComment {
    BrowseComment(
      id: comment.id,
      authorID: comment.author?.id ?? 0,
      authorName: authorName(comment.author),
      authorPortraitURL: SecureTiebaURL.portrait(comment.author?.portrait),
      createdAt: comment.createdAt,
      contents: mapContent(comment.content),
      authorUsername: authorUsername(comment.author),
      authorLevel: max(comment.author?.level ?? 0, 0),
      authorIPLocation: (comment.author?.ipLocation ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      moderatorRole: mapModeratorRole(comment.author?.moderatorRole),
      agreeScore: max(comment.agreeScore, 0),
      isThreadAuthor: comment.isThreadAuthor,
      replyToUserID: comment.replyToUserID.flatMap { $0 > 0 ? $0 : nil },
      replyToUserName: comment.replyToUserName.trimmingCharacters(
        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))
      ),
      threadID: comment.threadID,
      parentPostID: comment.parentPostID
    )
  }

  static func postAgreementDescriptor(
    thread: BrowseThread,
    firstPost: BrowsePost?,
    posts: [BrowsePost],
    page: Int,
    pageSize: Int,
    options: ThreadBrowseOptions,
    location: ThreadPostLocation?
  ) -> ContentAgreementReadDescriptor? {
    guard let request = ContentAgreementPostPageRequest(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      page: page,
      pageSize: pageSize,
      options: options,
      location: location
    ) else { return nil }

    var targets = Set<ContentAgreementTarget>()
    for post in [firstPost].compactMap({ $0 }) + posts {
      if let target = ContentAgreementTarget(thread: thread, post: post) {
        targets.insert(target)
      }
    }
    return ContentAgreementReadDescriptor(
      request: .postPage(request),
      expectedTargets: targets
    )
  }

  private static func subpostAgreementDescriptor(
    thread: BrowseThread,
    parentPost: CommentParentPostContext,
    comments: [BrowseComment],
    requestedPage: Int,
    aroundCommentID: Int64?
  ) -> ContentAgreementReadDescriptor? {
    guard let request = ContentAgreementSubpostPageRequest(
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      parentPostID: parentPost.id,
      aroundSubpostID: aroundCommentID,
      page: requestedPage
    ) else { return nil }

    var targets = Set<ContentAgreementTarget>()
    if let parentTarget = ContentAgreementTarget(thread: thread, parentPost: parentPost) {
      targets.insert(parentTarget)
    }
    for comment in comments {
      if let target = ContentAgreementTarget(
        thread: thread,
        parentPostID: parentPost.id,
        comment: comment
      ) {
        targets.insert(target)
      }
    }
    return ContentAgreementReadDescriptor(
      request: .subpostPage(request),
      expectedTargets: targets
    )
  }

  private static func authorName(_ author: TiebaUser?) -> String {
    guard let author else { return "匿名用户" }
    let displayName = author.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !displayName.isEmpty { return displayName }
    let username = author.username.trimmingCharacters(in: .whitespacesAndNewlines)
    return username.isEmpty ? "匿名用户" : username
  }

  private static func authorUsername(_ author: TiebaUser?) -> String {
    (author?.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func contentFilterSnapshot() async -> ContentFilterSnapshot {
    (try? await contentFilterRepository.snapshot()) ?? .empty
  }

  static func forumPreviewMetadata(
    _ forum: TiebaForum,
    requestedName: String
  ) -> TiebaLinkPreviewMetadata {
    let slogan = previewText(forum.slogan, maximumCharacterCount: 160)
    let subtitle: String
    if !slogan.isEmpty {
      subtitle = slogan
    } else {
      var parts: [String] = []
      if forum.memberCount > 0 {
        parts.append("\(forum.memberCount.formatted()) 位关注")
      }
      if forum.threadCount > 0 {
        parts.append("\(forum.threadCount.formatted()) 个主题")
      }
      subtitle = parts.isEmpty ? "贴吧主页" : parts.joined(separator: " · ")
    }
    return TiebaLinkPreviewMetadata(
      title: "\(requestedName)吧",
      subtitle: subtitle
    )
  }

  static func threadPreviewMetadata(
    _ thread: BrowseThread,
    route: TiebaThreadRoute
  ) -> TiebaLinkPreviewMetadata {
    let sanitizedTitle = previewText(thread.title, maximumCharacterCount: 120)
    var parts: [String] = []
    let forumName = previewText(thread.forumName, maximumCharacterCount: 100)
    if !forumName.isEmpty {
      parts.append("\(forumName)吧")
    }
    let authorName = previewText(thread.authorName, maximumCharacterCount: 80)
    if !authorName.isEmpty {
      parts.append("作者 \(authorName)")
    }
    if thread.replyCount >= 0 {
      parts.append("\(thread.replyCount.formatted()) 条回复")
    }
    if route.onlyThreadAuthor {
      parts.append("只看楼主")
    }
    if let postID = route.postID {
      parts.append("定位到回复 \(postID)")
    }
    return TiebaLinkPreviewMetadata(
      title: sanitizedTitle.isEmpty ? "帖子 \(route.threadID)" : sanitizedTitle,
      subtitle: parts.isEmpty ? "贴吧帖子" : parts.joined(separator: " · ")
    )
  }

  static func previewIdentity(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
      .lowercased()
  }

  static func previewText(
    _ value: String,
    maximumCharacterCount: Int
  ) -> String {
    let characterLimit = max(maximumCharacterCount, 0)
    guard characterLimit > 0 else { return "" }
    let (calculatedByteLimit, overflow) = characterLimit.multipliedReportingOverflow(by: 4)
    let byteLimit = overflow ? Int.max : calculatedByteLimit
    let (calculatedInspectionLimit, inspectionOverflow) =
      byteLimit.multipliedReportingOverflow(by: 4)
    let inspectionLimit = inspectionOverflow ? 4_096 : min(calculatedInspectionLimit, 4_096)

    var output = ""
    output.reserveCapacity(min(byteLimit, 640))
    var byteCount = 0
    var inspectedScalarCount = 0
    var pendingSpace = false

    for scalar in value.unicodeScalars {
      guard inspectedScalarCount < inspectionLimit else { break }
      inspectedScalarCount += 1
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.controlCharacters.contains(scalar)
      {
        pendingSpace = !output.isEmpty
        continue
      }

      let scalarText = String(scalar)
      let scalarByteCount = scalarText.utf8.count
      let spaceByteCount = pendingSpace ? 1 : 0
      guard byteCount <= byteLimit - spaceByteCount - scalarByteCount else { break }
      if pendingSpace {
        output.append(" ")
        byteCount += 1
        pendingSpace = false
      }
      output.append(scalarText)
      byteCount += scalarByteCount
    }
    return String(output.prefix(characterLimit))
  }

  private static func mapGender(_ gender: TiebaGender) -> BrowseGender {
    switch gender {
    case .male:
      .male
    case .female:
      .female
    case .unknown:
      .unknown
    @unknown default:
      .unknown
    }
  }

  private static func mapModeratorRole(
    _ role: TiebaModeratorRole?
  ) -> BrowseModeratorRole? {
    guard let role else { return nil }
    switch role {
    case .manager:
      return .manager
    case .assistant:
      return .assistant
    case .moderator:
      return .moderator
    @unknown default:
      return .moderator
    }
  }

  private static func threadSort(_ sort: ForumThreadSort) -> TiebaThreadSort {
    switch sort {
    case .replyTime:
      .replyTime
    case .creationTime:
      .creationTime
    }
  }

  private static func postSort(_ sort: ThreadPostSort) -> TiebaPostSort {
    switch sort {
    case .ascending:
      .ascending
    case .descending:
      .descending
    case .hot:
      .hot
    }
  }

  private static func postLocation(_ location: ThreadPostLocation?) -> TiebaPostLocation? {
    switch location {
    case .postID(let postID):
      .postID(postID)
    case .pageNumber:
      .pageNumber
    case .pageCursor(let postID):
      .pageCursor(postID)
    case .latestReplies(after: let postID):
      .latestReplies(after: postID)
    case nil:
      nil
    }
  }

  private static func mapForumPostSearchSort(
    _ sort: ForumPostSearchSort
  ) -> TiebaThreadSearchSort {
    switch sort {
    case .newest:
      .newest
    case .relevance:
      .relevance
    }
  }

  private static func mapGlobalThreadSearchSort(
    _ sort: GlobalThreadSearchSort
  ) -> TiebaGlobalThreadSearchSort {
    switch sort {
    case .newest:
      .newest
    case .oldest:
      .oldest
    case .relevance:
      .relevance
    }
  }

  private static func mapForumPostSearchFilter(
    _ filter: ForumPostSearchFilter
  ) -> TiebaThreadSearchFilter {
    switch filter {
    case .all:
      .all
    case .threadsOnly:
      .threadsOnly
    }
  }

  static func nextPagePostID(
    from pagePostIDs: [Int64],
    returnedPostIDs: Set<Int64>,
    sort: ThreadPostSort
  ) -> Int64? {
    switch sort {
    case .descending:
      return pagePostIDs.first(where: { $0 > 0 })
    case .hot:
      return nil
    case .ascending:
      return pagePostIDs.last(where: { $0 > 0 && !returnedPostIDs.contains($0) })
    }
  }

  static func returnedPostIDs(_ postIDs: [Int64], firstPostID: Int64?) -> Set<Int64> {
    var result = Set(postIDs)
    if let firstPostID {
      result.insert(firstPostID)
    }
    return result
  }

  static func browseError(_ error: Error) -> BrowseError {
    guard let error = error as? TiebaClientError else {
      return .unavailable(error.localizedDescription)
    }
    let message: String
    switch error {
    case .invalidArgument:
      message = "请求参数无效。"
    case .invalidEndpoint:
      message = "无法建立安全的贴吧请求。"
    case .network:
      message = "网络连接失败，请检查网络后重试。"
    case .transportFailure, .invalidHTTPResponse:
      message = "网络响应异常，请稍后重试。"
    case .httpStatus(let status):
      message = "贴吧服务暂时不可用（HTTP \(status)）。"
    case .responseTooLarge:
      message = "贴吧返回的数据过大，请稍后重试。"
    case .invalidProtobuf:
      message = "贴吧返回了无法识别的数据，协议可能已经更新。"
    case .invalidJSON:
      message = "贴吧返回了无法识别的数据，接口可能已经更新。"
    case .invalidAuthenticatedResponse:
      message = "贴吧返回了不匹配的账户数据，请重新登录后再试。"
    case .threadIdentityConflict:
      message = "贴吧返回了相互冲突的主题与贴吧身份。"
    case .forumNotFollowed:
      message = "请先关注该贴吧后再试。"
    case .forumCheckInUnavailable:
      message = "该贴吧当前无法签到。"
    case .threadAgreementWriteConflict:
      message = "先前的主题点赞操作已结束，请重新读取当前状态。"
    case .server(let code, let serverMessage):
      message = serverMessage.isEmpty ? "贴吧返回错误 \(code)。" : serverMessage
    @unknown default:
      message = error.localizedDescription
    }
    return .unavailable(message)
  }

  private static func summary(for content: TiebaContent) -> String {
    let text = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      return text
    }
    if !content.images.isEmpty {
      return "[图片]"
    }
    if content.fragments.contains(where: {
      if case .video = $0 { return true }
      return false
    }) {
      return "[视频]"
    }
    if content.fragments.contains(where: {
      if case .voice = $0 { return true }
      return false
    }) {
      return "[语音]"
    }
    return ""
  }

  private static func mapContent(_ content: TiebaContent) -> [BrowseContent] {
    content.fragments.map { fragment in
      switch fragment {
      case .text(let text):
        return .text(text)
      case .emoji(let identifier, let description):
        let label = description.isEmpty ? identifier : description
        return .emoticon(name: label, url: nil)
      case .image(let image):
        guard
          let thumbnail = firstSecureMediaURL(
            image.thumbnailURL,
            image.fullSizeURL,
            image.dynamicURL,
            image.originalURL
          )
        else {
          return .unsupported(label: "图片地址不可用")
        }
        return .image(
          thumbnail: thumbnail,
          fullSize: firstSecureMediaURL(image.fullSizeURL),
          original: firstSecureMediaURL(image.originalURL),
          dynamic: firstSecureMediaURL(image.dynamicURL),
          width: image.width,
          height: image.height
        )
      case .mention(let mention):
        let name = mention.text.trimmingCharacters(
          in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))
        )
        return .mention(
          name: name.isEmpty ? String(mention.userID) : name,
          userID: mention.userID)
      case .link(let link):
        guard let url = SecureTiebaURL.web(link.url) else {
          return .text(link.title.isEmpty ? link.text : link.title)
        }
        return .link(label: link.title.isEmpty ? link.text : link.title, url: url)
      case .video(let video):
        return .video(
          url: SecureTiebaURL.media(video.streamURL),
          cover: SecureTiebaURL.media(video.coverURL),
          width: video.width,
          height: video.height,
          pageURL: SecureTiebaURL.videoPage(video.pageURL)
        )
      case .voice(let voice):
        guard let url = SecureTiebaURL.voice(md5: voice.md5) else {
          return .unsupported(label: "语音地址不可用")
        }
        return .voice(url: url, duration: max(0, Int(voice.duration.rounded())))
      case .tiebaPlus(let description, let url):
        let label = description.isEmpty ? "贴吧组件" : description
        guard let url = SecureTiebaURL.web(url) else {
          return .unsupported(label: label)
        }
        return .link(label: label, url: url)
      case .unknown(let type, let text):
        return text.isEmpty ? .unsupported(label: "暂不支持的内容（类型 \(type)）") : .text(text)
      }
    }
  }

  private static func firstSecureMediaURL(_ candidates: URL?...) -> URL? {
    candidates.lazy.compactMap { SecureTiebaURL.media($0) }.first
  }
}

enum SecureTiebaURL {
  static let maximumVideoPageURLBytes = 8_192

  private static let upgradeableHostSuffixes = [
    "baidu.com",
    "bdimg.com",
    "bdstatic.com",
    "bcebos.com",
    "baidubce.com",
  ]

  static func portrait(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let portrait = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !portrait.isEmpty else { return nil }

    if portrait.contains("://") || portrait.hasPrefix("//") {
      return media(URL(string: portrait.hasPrefix("//") ? "https:\(portrait)" : portrait))
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "himg.bdimg.com"
    components.path = "/sys/portraitn/item/\(portrait)"
    return components.url
  }

  static func strictPortrait(_ rawValue: String?) -> URL? {
    guard let token = validatedStrictPortraitToken(rawValue) else { return nil }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "himg.bdimg.com"
    components.path = "/sys/portraitn/item/\(token)"
    return components.url
  }

  static func largePortrait(_ rawValue: String?) -> URL? {
    guard let token = validatedStrictPortraitToken(rawValue) else { return nil }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "himg.bdimg.com"
    components.path = "/sys/portraith/item/\(token)"
    return components.url
  }

  private static func validatedStrictPortraitToken(_ rawValue: String?) -> String? {
    guard let rawValue, rawValue.utf8.count <= 4_096 else { return nil }
    let portrait = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !portrait.isEmpty else { return nil }

    if portrait.hasPrefix("//") || portrait.contains("://") {
      return strictPortraitToken(from: portrait)
    }
    return strictBarePortraitToken(from: portrait)
  }

  private static func strictPortraitToken(from rawValue: String) -> String? {
    let absoluteValue = rawValue.hasPrefix("//") ? "https:\(rawValue)" : rawValue
    guard
      let components = URLComponents(string: absoluteValue),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      isAllowedPortraitCacheBuster(components.percentEncodedQuery),
      components.percentEncodedFragment == nil,
      let host = components.host?.lowercased(),
      host == "tb.himg.baidu.com" || host == "himg.bdimg.com",
      strictPortraitAuthority(from: absoluteValue)?.lowercased() == host
    else { return nil }

    let prefixes = [
      "/sys/portrait/item/",
      "/sys/portraitn/item/",
      "/sys/portraith/item/",
    ]
    let encodedPath = components.percentEncodedPath
    guard let prefix = prefixes.first(where: { encodedPath.hasPrefix($0) }) else { return nil }
    let encodedToken = String(encodedPath.dropFirst(prefix.count))
    guard
      !encodedToken.isEmpty,
      let token = encodedToken.removingPercentEncoding,
      isStrictPortraitToken(token)
    else { return nil }
    return token
  }

  private static func strictBarePortraitToken(from source: String) -> String? {
    guard !source.contains("#") else { return nil }
    let parts = source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    guard
      parts.count == 1 || (parts.count == 2 && isAllowedPortraitCacheBuster(String(parts[1]))),
      let tokenPart = parts.first
    else { return nil }
    let token = String(tokenPart)
    return isStrictPortraitToken(token) ? token : nil
  }

  private static func isAllowedPortraitCacheBuster(_ query: String?) -> Bool {
    guard let query else { return true }
    guard query.hasPrefix("t=") else { return false }
    let digits = query.utf8.dropFirst(2)
    return (1...20).contains(digits.count)
      && digits.allSatisfy { (48...57).contains($0) }
  }

  private static func strictPortraitAuthority(from absoluteValue: String) -> Substring? {
    // The raw authority also exposes empty ports and encoded hosts that URLComponents normalizes.
    guard let separator = absoluteValue.range(of: "://") else { return nil }
    let remainder = absoluteValue[separator.upperBound...]
    let authorityEnd = remainder.firstIndex { character in
      character == "/" || character == "?" || character == "#"
    } ?? remainder.endIndex
    return remainder[..<authorityEnd]
  }

  private static func isStrictPortraitToken(_ token: String) -> Bool {
    guard
      !token.isEmpty,
      token.utf8.count <= 512,
      token != ".",
      token != ".."
    else { return false }
    let allowedCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"
    )
    return token.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
  }

  static func media(_ url: URL?) -> URL? {
    TiebaMediaURLPolicy.normalizedURL(url)
  }

  static func media(_ rawValue: String?) -> URL? {
    TiebaMediaURLPolicy.normalizedURL(from: rawValue)
  }

  static func web(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return normalized(url, allowHTTPUpgradeOnly: false)
  }

  static func videoPage(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let absoluteString = url.absoluteString
    guard
      absoluteString.utf8.count <= maximumVideoPageURLBytes,
      !containsControlCharacters(absoluteString),
      let decodedAbsoluteString = absoluteString.removingPercentEncoding,
      !containsControlCharacters(decodedAbsoluteString)
    else { return nil }
    return web(url)
  }

  static func voice(md5: String) -> URL? {
    let md5 = md5.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !md5.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tiebac.baidu.com"
    components.path = "/c/p/voice"
    components.queryItems = [
      URLQueryItem(name: "voice_md5", value: md5),
      URLQueryItem(name: "play_from", value: "pb_voice_play"),
    ]
    return components.url
  }

  private static func normalized(_ url: URL, allowHTTPUpgradeOnly: Bool) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    guard components.user == nil, components.password == nil else { return nil }

    let scheme = components.scheme?.lowercased()
    let host = components.host?.lowercased()
    guard let host, !host.isEmpty else { return nil }

    var requiresRebuild = false
    if host == "tb.himg.baidu.com" {
      components.host = "himg.bdimg.com"
      requiresRebuild = true
    }

    switch scheme {
    case "https":
      break
    case "http" where isUpgradeable(host):
      components.scheme = "https"
      if components.port == 80 {
        components.port = nil
      }
      requiresRebuild = true
    case "http" where !allowHTTPUpgradeOnly:
      break
    default:
      return nil
    }
    return requiresRebuild ? components.url : url
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func isUpgradeable(_ host: String) -> Bool {
    upgradeableHostSuffixes.contains { suffix in
      host == suffix || host.hasSuffix(".\(suffix)")
    }
  }
}
