import Foundation

enum TiebaSearchDecoder {
  static func forums(from body: Data) throws -> TiebaForumSearchResults {
    let envelope: SearchEnvelope<ForumSearchPayload> = try decode(body)
    try checkServerError(envelope)
    guard let data = envelope.data else {
      return TiebaForumSearchResults(exactMatch: nil, fuzzyMatches: [], isLoggedIn: false)
    }

    let exactMatch = data.exactMatch.values.compactMap(mapForum).first
    let exactID = exactMatch?.id
    var seen = Set<Int64>()
    if let exactID { seen.insert(exactID) }
    let fuzzyMatches = data.fuzzyMatch.values.compactMap(mapForum).filter {
      seen.insert($0.id).inserted
    }
    return TiebaForumSearchResults(
      exactMatch: exactMatch,
      fuzzyMatches: fuzzyMatches,
      isLoggedIn: data.isLoggedIn.value != 0
    )
  }

  static func threads(
    from body: Data,
    requestedPage: Int,
    pageSize: Int
  ) throws -> TiebaThreadSearchPage {
    let envelope: SearchEnvelope<ThreadSearchPayload> = try decode(body)
    try checkServerError(envelope)
    let data = envelope.data
    let results = (data?.postList ?? []).compactMap(mapThread)
    let reportedPage = data?.currentPage.value ?? 0
    let currentPage = reportedPage > 0 ? clampedInt(reportedPage) : max(1, requestedPage)
    let hasMore = (data?.hasMore.value ?? 0) != 0
    return TiebaThreadSearchPage(
      results: results,
      pagination: TiebaPagination(
        pageSize: pageSize,
        currentPage: currentPage,
        totalPages: 0,
        totalCount: 0,
        hasMore: hasMore,
        hasPrevious: currentPage > 1
      ),
      isLoggedIn: (data?.isLoggedIn.value ?? 0) != 0
    )
  }

  static func users(from body: Data) throws -> TiebaUserSearchResults {
    let envelope: SearchEnvelope<UserSearchPayload> = try decode(body)
    try checkServerError(envelope)
    guard let data = envelope.data else {
      return TiebaUserSearchResults(exactMatch: nil, fuzzyMatches: [])
    }

    let exactMatch = data.exactMatch.values.compactMap(mapUser).first
    let exactID = exactMatch?.id
    var seen = Set<Int64>()
    if let exactID { seen.insert(exactID) }
    let fuzzyMatches = data.fuzzyMatch.values.compactMap(mapUser).filter {
      seen.insert($0.id).inserted
    }
    return TiebaUserSearchResults(exactMatch: exactMatch, fuzzyMatches: fuzzyMatches)
  }

  private static func mapForum(_ payload: ForumPayload) -> TiebaForumSearchResult? {
    let id = payload.forumID.value
    let name = payload.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard id > 0, !name.isEmpty else { return nil }
    let displayName = payload.forumDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return TiebaForumSearchResult(
      id: id,
      name: name,
      displayName: displayName.isEmpty ? name : displayName,
      avatarURL: remoteURL(payload.avatar),
      postCount: clampedInt(max(payload.postCount.value, 0)),
      memberCount: clampedInt(max(payload.memberCount.value, 0)),
      introduction: payload.introduction,
      slogan: payload.slogan
    )
  }

  private static func mapThread(_ payload: ThreadPayload) -> TiebaThreadSearchResult? {
    let threadID = payload.threadID.value
    guard threadID > 0 else { return nil }
    let hasVideo = payload.media.contains {
      let type = $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return type == "flash" || type == "video"
    }
    let authorName = payload.user?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = payload.user?.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let mainPost = payload.mainPost.map { mapPostContext($0, fallbackThreadID: threadID) }
    let postInfo = payload.postInfo.map { mapPostContext($0, fallbackThreadID: threadID) }
    let postID = max(payload.postID.value, 0)
    let commentID = max(payload.commentID.value, 0)
    let target: TiebaThreadSearchTarget
    if payload.postInfo != nil, commentID > 0 {
      let contextPostID = max(payload.postInfo?.postID.value ?? 0, 0)
      let parentPostID = contextPostID > 0 ? contextPostID : postID
      target = parentPostID > 0
        ? .comment(postID: parentPostID, commentID: commentID)
        : .thread
    } else if payload.mainPost != nil, postID > 0 {
      target = .post(postID)
    } else {
      target = .thread
    }
    let firstPostID: Int64
    switch target {
    case .thread:
      firstPostID = postID
    case .post, .comment:
      firstPostID = mainPost?.postID ?? 0
    }
    return TiebaThreadSearchResult(
      threadID: threadID,
      firstPostID: firstPostID,
      matchedPostID: postID,
      forumID: max(payload.forumID.value, 0),
      forumName: payload.forumName,
      title: payload.title,
      excerpt: payload.content,
      authorID: max(payload.user?.userID.value ?? 0, 0),
      authorName: nonempty(authorName) ?? nonempty(username) ?? "匿名用户",
      authorUsername: nonempty(username) ?? "",
      authorPortraitURL: remoteURL(payload.user?.portrait),
      replyCount: clampedInt(max(payload.replyCount.value, 0)),
      likeCount: clampedInt(max(payload.likeCount.value, 0)),
      shareCount: clampedInt(max(payload.shareCount.value, 0)),
      createdAt: date(seconds: payload.createdAt.value),
      images: payload.media.compactMap(mapImage),
      hasVideo: hasVideo,
      target: target,
      mainPost: mainPost,
      postInfo: postInfo
    )
  }

  private static func mapPostContext(
    _ payload: SearchPostContextPayload,
    fallbackThreadID: Int64
  ) -> TiebaSearchPostContext {
    let displayName = payload.user?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = payload.user?.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let postID = payload.postID.value > 0 ? payload.postID.value : nil
    return TiebaSearchPostContext(
      threadID: payload.threadID.value > 0 ? payload.threadID.value : fallbackThreadID,
      postID: postID,
      title: payload.title,
      excerpt: payload.content,
      authorID: max(payload.user?.userID.value ?? 0, 0),
      authorName: nonempty(displayName) ?? nonempty(username) ?? "匿名用户",
      authorUsername: nonempty(username) ?? "",
      authorPortraitURL: remoteURL(payload.user?.portrait),
      replyCount: clampedInt(max(payload.replyCount.value, 0)),
      likeCount: clampedInt(max(payload.likeCount.value, 0)),
      shareCount: clampedInt(max(payload.shareCount.value, 0))
    )
  }

  private static func mapUser(_ payload: UserPayload) -> TiebaUserSearchResult? {
    let id = payload.userID.value
    guard id > 0 else { return nil }
    let username = payload.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName =
      nonempty(payload.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
      ?? nonempty(payload.alternateDisplayName.trimmingCharacters(in: .whitespacesAndNewlines))
      ?? username
    guard !displayName.isEmpty else { return nil }
    return TiebaUserSearchResult(
      id: id,
      username: username,
      displayName: displayName,
      portrait: payload.portrait?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      introduction: payload.introduction.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private static func mapImage(_ payload: SearchMediaPayload) -> TiebaSearchImage? {
    guard payload.type == "pic" else { return nil }
    let thumbnail = remoteURL(payload.smallPicture ?? payload.waterPicture ?? payload.bigPicture)
    let fullSize = remoteURL(payload.bigPicture ?? payload.waterPicture)
    guard thumbnail != nil || fullSize != nil else { return nil }
    return TiebaSearchImage(
      thumbnailURL: thumbnail ?? fullSize,
      fullSizeURL: fullSize,
      width: clampedInt(max(payload.width.value, 0)),
      height: clampedInt(max(payload.height.value, 0))
    )
  }

  private static func decode<Payload: Decodable>(_ body: Data) throws -> Payload {
    do {
      return try JSONDecoder().decode(Payload.self, from: body)
    } catch {
      throw TiebaClientError.invalidJSON
    }
  }

  private static func checkServerError<Payload: Decodable>(
    _ envelope: SearchEnvelope<Payload>
  ) throws {
    let code = envelope.code.value
    guard code == 0 else {
      let clampedCode = Int32(clamping: code)
      throw TiebaClientError.server(code: clampedCode, message: envelope.error)
    }
  }

  private static func date(seconds: Int64) -> Date? {
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }

  private static func remoteURL(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let absoluteValue = value.hasPrefix("//") ? "https:\(value)" : value
    guard
      let url = URL(string: absoluteValue),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else { return nil }
    return url
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func clampedInt(_ value: Int64) -> Int {
    Int(clamping: value)
  }
}

private struct SearchEnvelope<Payload: Decodable>: Decodable {
  let code: FlexibleInteger
  let error: String
  let data: Payload?

  enum CodingKeys: String, CodingKey {
    case code = "no"
    case error
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(FlexibleInteger.self, forKey: .code)
    error = (try? container.decode(String.self, forKey: .error)) ?? ""
    if code.value == 0 {
      data = try container.decodeIfPresent(Payload.self, forKey: .data)
    } else {
      data = nil
    }
  }
}

private struct ForumSearchPayload: Decodable {
  let exactMatch: ForumCollection
  let fuzzyMatch: ForumCollection
  let isLoggedIn: FlexibleInteger

  enum CodingKeys: String, CodingKey {
    case exactMatch
    case fuzzyMatch
    case isLoggedIn = "is_login"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    exactMatch = (try? container.decode(ForumCollection.self, forKey: .exactMatch)) ?? .empty
    fuzzyMatch = (try? container.decode(ForumCollection.self, forKey: .fuzzyMatch)) ?? .empty
    isLoggedIn =
      (try? container.decode(FlexibleInteger.self, forKey: .isLoggedIn)) ?? .zero
  }
}

private struct ThreadSearchPayload: Decodable {
  let hasMore: FlexibleInteger
  let currentPage: FlexibleInteger
  let isLoggedIn: FlexibleInteger
  let postList: [ThreadPayload]

  enum CodingKeys: String, CodingKey {
    case hasMore = "has_more"
    case currentPage = "current_page"
    case isLoggedIn = "is_login"
    case postList = "post_list"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hasMore = (try? container.decode(FlexibleInteger.self, forKey: .hasMore)) ?? .zero
    currentPage =
      (try? container.decode(FlexibleInteger.self, forKey: .currentPage)) ?? .zero
    isLoggedIn =
      (try? container.decode(FlexibleInteger.self, forKey: .isLoggedIn)) ?? .zero
    postList = (try? container.decodeIfPresent([ThreadPayload].self, forKey: .postList)) ?? []
  }
}

private struct UserSearchPayload: Decodable {
  let exactMatch: UserCollection
  let fuzzyMatch: UserCollection

  enum CodingKeys: String, CodingKey {
    case exactMatch
    case fuzzyMatch
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    exactMatch = try container.decodeIfPresent(UserCollection.self, forKey: .exactMatch) ?? .empty
    fuzzyMatch = try container.decodeIfPresent(UserCollection.self, forKey: .fuzzyMatch) ?? .empty
  }
}

private struct ForumPayload: Decodable {
  let forumID: FlexibleInteger
  let forumName: String
  let forumDisplayName: String
  let avatar: String?
  let postCount: FlexibleInteger
  let memberCount: FlexibleInteger
  let introduction: String
  let slogan: String

  enum CodingKeys: String, CodingKey {
    case forumID = "forum_id"
    case forumName = "forum_name"
    case forumDisplayName = "forum_name_show"
    case avatar
    case postCount = "post_num_ori"
    case memberCount = "concern_num_ori"
    case introduction = "intro"
    case slogan
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    forumID = (try? container.decode(FlexibleInteger.self, forKey: .forumID)) ?? .zero
    forumName = (try? container.decode(String.self, forKey: .forumName)) ?? ""
    forumDisplayName =
      (try? container.decode(String.self, forKey: .forumDisplayName)) ?? ""
    avatar = try? container.decodeIfPresent(String.self, forKey: .avatar)
    postCount = (try? container.decode(FlexibleInteger.self, forKey: .postCount)) ?? .zero
    memberCount =
      (try? container.decode(FlexibleInteger.self, forKey: .memberCount)) ?? .zero
    introduction = (try? container.decode(String.self, forKey: .introduction)) ?? ""
    slogan = (try? container.decode(String.self, forKey: .slogan)) ?? ""
  }
}

private struct ForumCollection: Decodable {
  static let empty = ForumCollection(values: [])

  let values: [ForumPayload]

  private init(values: [ForumPayload]) {
    self.values = values
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      values = []
    } else if let array = try? container.decode([ForumPayload].self) {
      values = array
    } else if let dictionary = try? container.decode([String: ForumPayload].self) {
      values = dictionary.sorted { lhs, rhs in
        (Int(lhs.key) ?? .max, lhs.key) < (Int(rhs.key) ?? .max, rhs.key)
      }.map(\.value)
    } else if let value = try? container.decode(ForumPayload.self) {
      values = [value]
    } else {
      values = []
    }
  }
}

private struct UserPayload: Decodable {
  let userID: FlexibleInteger
  let username: String
  let displayName: String
  let alternateDisplayName: String
  let portrait: String?
  let introduction: String

  enum CodingKeys: String, CodingKey {
    case userID = "id"
    case username = "name"
    case displayName = "show_nickname"
    case alternateDisplayName = "user_nickname"
    case portrait
    case introduction = "intro"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userID = (try? container.decode(FlexibleInteger.self, forKey: .userID)) ?? .zero
    username = (try? container.decode(String.self, forKey: .username)) ?? ""
    displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
    alternateDisplayName =
      (try? container.decode(String.self, forKey: .alternateDisplayName)) ?? ""
    portrait = try? container.decodeIfPresent(String.self, forKey: .portrait)
    introduction = (try? container.decode(String.self, forKey: .introduction)) ?? ""
  }
}

private struct UserCollection: Decodable {
  static let empty = UserCollection(values: [])

  let values: [UserPayload]

  private init(values: [UserPayload]) {
    self.values = values
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      values = []
    } else if let array = try? container.decode([UserPayload].self) {
      values = array
    } else if let dictionary = try? container.decode([String: UserPayload].self) {
      values = dictionary.sorted { lhs, rhs in
        (Int(lhs.key) ?? .max, lhs.key) < (Int(rhs.key) ?? .max, rhs.key)
      }.map(\.value)
    } else if let value = try? container.decode(UserPayload.self) {
      values = [value]
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected a user, user array, or keyed user collection."
      )
    }
  }
}

private struct ThreadPayload: Decodable {
  let threadID: FlexibleInteger
  let postID: FlexibleInteger
  let commentID: FlexibleInteger
  let forumID: FlexibleInteger
  let forumName: String
  let title: String
  let content: String
  let createdAt: FlexibleInteger
  let replyCount: FlexibleInteger
  let likeCount: FlexibleInteger
  let shareCount: FlexibleInteger
  let user: SearchUserPayload?
  let media: [SearchMediaPayload]
  let mainPost: SearchPostContextPayload?
  let postInfo: SearchPostContextPayload?

  enum CodingKeys: String, CodingKey {
    case threadID = "tid"
    case postID = "pid"
    case commentID = "cid"
    case forumID = "forum_id"
    case forumName = "forum_name"
    case title
    case content
    case createdAt = "time"
    case replyCount = "post_num"
    case likeCount = "like_num"
    case shareCount = "share_num"
    case user
    case media
    case mainPost = "main_post"
    case postInfo = "post_info"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    threadID = (try? container.decode(FlexibleInteger.self, forKey: .threadID)) ?? .zero
    postID = (try? container.decode(FlexibleInteger.self, forKey: .postID)) ?? .zero
    commentID = (try? container.decode(FlexibleInteger.self, forKey: .commentID)) ?? .zero
    forumID = (try? container.decode(FlexibleInteger.self, forKey: .forumID)) ?? .zero
    forumName = (try? container.decode(String.self, forKey: .forumName)) ?? ""
    title = (try? container.decode(String.self, forKey: .title)) ?? ""
    content = (try? container.decode(String.self, forKey: .content)) ?? ""
    createdAt = (try? container.decode(FlexibleInteger.self, forKey: .createdAt)) ?? .zero
    replyCount =
      (try? container.decode(FlexibleInteger.self, forKey: .replyCount)) ?? .zero
    likeCount = (try? container.decode(FlexibleInteger.self, forKey: .likeCount)) ?? .zero
    shareCount =
      (try? container.decode(FlexibleInteger.self, forKey: .shareCount)) ?? .zero
    user = try? container.decodeIfPresent(SearchUserPayload.self, forKey: .user)
    media = (try? container.decodeIfPresent([SearchMediaPayload].self, forKey: .media)) ?? []
    mainPost = try? container.decodeIfPresent(SearchPostContextPayload.self, forKey: .mainPost)
    postInfo = try? container.decodeIfPresent(SearchPostContextPayload.self, forKey: .postInfo)
  }
}

private struct SearchPostContextPayload: Decodable {
  let threadID: FlexibleInteger
  let postID: FlexibleInteger
  let title: String
  let content: String
  let user: SearchUserPayload?
  let replyCount: FlexibleInteger
  let likeCount: FlexibleInteger
  let shareCount: FlexibleInteger

  enum CodingKeys: String, CodingKey {
    case threadID = "tid"
    case postID = "pid"
    case title
    case content
    case user
    case replyCount = "post_num"
    case likeCount = "like_num"
    case shareCount = "share_num"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    threadID = (try? container.decode(FlexibleInteger.self, forKey: .threadID)) ?? .zero
    postID = (try? container.decode(FlexibleInteger.self, forKey: .postID)) ?? .zero
    title = (try? container.decode(String.self, forKey: .title)) ?? ""
    content = (try? container.decode(String.self, forKey: .content)) ?? ""
    user = try? container.decodeIfPresent(SearchUserPayload.self, forKey: .user)
    replyCount = (try? container.decode(FlexibleInteger.self, forKey: .replyCount)) ?? .zero
    likeCount = (try? container.decode(FlexibleInteger.self, forKey: .likeCount)) ?? .zero
    shareCount = (try? container.decode(FlexibleInteger.self, forKey: .shareCount)) ?? .zero
  }
}

private struct SearchUserPayload: Decodable {
  let userID: FlexibleInteger
  let username: String
  let displayName: String
  let portrait: String?

  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case username = "user_name"
    case displayName = "show_nickname"
    case portrait
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userID = (try? container.decode(FlexibleInteger.self, forKey: .userID)) ?? .zero
    username = (try? container.decode(String.self, forKey: .username)) ?? ""
    displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
    portrait = try? container.decodeIfPresent(String.self, forKey: .portrait)
  }
}

private struct SearchMediaPayload: Decodable {
  let type: String
  let width: FlexibleInteger
  let height: FlexibleInteger
  let waterPicture: String?
  let smallPicture: String?
  let bigPicture: String?

  enum CodingKeys: String, CodingKey {
    case type
    case width
    case height
    case waterPicture = "water_pic"
    case smallPicture = "small_pic"
    case bigPicture = "big_pic"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = (try? container.decode(String.self, forKey: .type)) ?? ""
    width = (try? container.decode(FlexibleInteger.self, forKey: .width)) ?? .zero
    height = (try? container.decode(FlexibleInteger.self, forKey: .height)) ?? .zero
    waterPicture = try? container.decodeIfPresent(String.self, forKey: .waterPicture)
    smallPicture = try? container.decodeIfPresent(String.self, forKey: .smallPicture)
    bigPicture = try? container.decodeIfPresent(String.self, forKey: .bigPicture)
  }
}

private struct FlexibleInteger: Decodable {
  static let zero = FlexibleInteger(value: 0)

  let value: Int64

  private init(value: Int64) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let integer = try? container.decode(Int64.self) {
      value = integer
    } else if let string = try? container.decode(String.self),
      let integer = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      value = integer
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an integer or a decimal integer string."
      )
    }
  }
}
