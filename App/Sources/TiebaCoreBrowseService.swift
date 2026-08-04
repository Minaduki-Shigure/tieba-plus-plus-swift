import Foundation
import TiebaCore

struct TiebaCoreBrowseService: BrowseService, SearchService, ForumPostSearchService,
  SearchSuggestionService, HotTopicService, HotThreadService, UserProfileService,
  ForumInformationService, ThreadPictureGalleryService
{
  private let client: TiebaClient
  private let contentFilterRepository: any ContentFilterRepository

  init(
    client: TiebaClient = TiebaClient(),
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository()
  ) {
    self.client = client
    self.contentFilterRepository = contentFilterRepository
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
        onlyThreadAuthor: request.context.onlyThreadAuthor
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
    let returnedPostIDs = Self.returnedPostIDs(
      response.posts.map(\.id),
      firstPostID: response.firstPost?.id
    )
    return PostPageData(
      thread: Self.mapThread(response.thread),
      posts: response.posts.map { Self.mapPost($0, applying: filter) },
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
      firstPost: response.firstPost.map { Self.mapPost($0, applying: filter) }
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
      isVIP: response.user.isVIP,
      isVerifiedCreator: response.user.isVerifiedCreator,
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

  private static func mapPoll(_ poll: TiebaPoll) -> BrowsePoll {
    BrowsePoll(
      title: poll.title,
      isMultipleChoice: poll.isMultipleChoice,
      participantCount: max(poll.participantCount, 0),
      totalVoteCount: max(poll.totalVoteCount, 0),
      options: poll.options.enumerated().map { index, option in
        BrowsePollOption(
          id: index,
          text: option.text,
          voteCount: max(option.voteCount, 0)
        )
      }
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
      shareCount: max(result.shareCount, 0),
      agreeCount: max(result.likeCount, 0)
    )
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
    let mainPostContext = matchingSearchContext(result.mainPost, threadID: result.threadID)
    let postInfoContext = matchingSearchContext(result.postInfo, threadID: result.threadID)
    let threadContext = mainPostContext ?? postInfoContext
    let displayContext = postInfoContext ?? mainPostContext
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
    let target = mapForumPostSearchTarget(result.target)
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
      context: displayContext.map {
        ForumPostSearchSummary(
          postID: $0.postID ?? 0,
          title: $0.title,
          excerpt: $0.excerpt,
          authorID: $0.authorID,
          authorName: $0.authorName,
          authorUsername: $0.authorUsername
        )
      },
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
    expectedPostID: Int64,
    filter: ContentFilterSnapshot
  ) throws -> CommentPageData {
    let parentPost = response.parentPost
    guard
      requestedThreadID > 0,
      expectedPostID > 0,
      response.thread.id == requestedThreadID,
      parentPost.id > 0,
      parentPost.threadID == requestedThreadID,
      expectedPostID == parentPost.id
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
    return CommentPageData(
      parentPost: filter.applying(to: mapCommentParentPost(parentPost)),
      comments: comments,
      currentPage: response.pagination.currentPage,
      hasMore: response.pagination.hasMore,
      hasPrevious: response.pagination.hasPrevious,
      totalPages: response.pagination.totalPages,
      totalCount: max(
        max(response.pagination.totalCount, parentPost.commentCount),
        comments.count
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
      )
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
      message = "贴吧返回了无法识别的搜索数据，接口可能已经更新。"
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
            image.originalURL
          )
        else {
          return .unsupported(label: "图片地址不可用")
        }
        return .image(
          thumbnail: thumbnail,
          fullSize: firstSecureMediaURL(image.fullSizeURL),
          original: firstSecureMediaURL(image.originalURL),
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
          height: video.height
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

  static func largePortrait(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    guard rawValue.utf8.count <= 4_096 else { return nil }
    let portrait = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !portrait.isEmpty else { return nil }

    let token: String
    if portrait.hasPrefix("//") || portrait.contains("://") {
      guard let parsedToken = strictPortraitToken(from: portrait) else { return nil }
      token = parsedToken
    } else {
      guard let parsedToken = strictBarePortraitToken(from: portrait) else { return nil }
      token = parsedToken
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "himg.bdimg.com"
    components.path = "/sys/portraith/item/\(token)"
    return components.url
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
    guard let url else { return nil }
    return normalized(url, allowHTTPUpgradeOnly: true)
  }

  static func media(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else { return nil }
    let absoluteValue =
      trimmedValue.hasPrefix("//")
      ? "https:\(trimmedValue)"
      : trimmedValue
    return media(URL(string: absoluteValue))
  }

  static func web(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return normalized(url, allowHTTPUpgradeOnly: false)
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
      requiresRebuild = true
    case "http" where !allowHTTPUpgradeOnly:
      break
    default:
      return nil
    }
    return requiresRebuild ? components.url : url
  }

  private static func isUpgradeable(_ host: String) -> Bool {
    upgradeableHostSuffixes.contains { suffix in
      host == suffix || host.hasSuffix(".\(suffix)")
    }
  }
}
