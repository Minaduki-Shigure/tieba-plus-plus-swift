import Foundation

enum TiebaHotTopicDecoder {
  static func topics(from body: Data) throws -> [TiebaHotTopic] {
    let envelope: HotTopicEnvelope<HotTopicListPayload> = try decode(body)
    try checkServerError(envelope)
    guard let data = envelope.data else { return [] }

    var seen = Set<Int64>()
    return data.list.items.enumerated().compactMap { index, payload in
      guard let topic = mapTopic(payload, fallbackRank: index + 1) else { return nil }
      return seen.insert(topic.id).inserted ? topic : nil
    }
  }

  static func page(
    from body: Data,
    requestedTopicID: Int64,
    requestedTopicName: String,
    requestedPage: Int,
    pageSize: Int
  ) throws -> TiebaHotTopicPage {
    let envelope: HotTopicEnvelope<HotTopicDetailPayload> = try decode(body)
    try checkServerError(envelope)
    guard let data = envelope.data else { throw TiebaClientError.invalidJSON }

    let topic = mapTopicInfo(
      data.topicInfo,
      requestedTopicID: requestedTopicID,
      requestedTopicName: requestedTopicName
    )
    var seenForums = Set<Int64>()
    let relatedForums = data.relatedForums.compactMap(mapForum).filter {
      seenForums.insert($0.id).inserted
    }

    var seenThreads = Set<Int64>()
    let mappedThreads = data.relatedThreads.items.compactMap(mapThread).filter {
      seenThreads.insert($0.thread.id).inserted
    }
    let threads = mappedThreads.map(\.thread)
    let reportedPage = data.request.currentPage.value
    let currentPage = reportedPage > 0 ? clampedInt(reportedPage) : max(1, requestedPage)
    let hasMore = data.hasMore.value && !threads.isEmpty
    return TiebaHotTopicPage(
      topic: topic,
      relatedForums: relatedForums,
      threads: threads,
      pagination: TiebaPagination(
        pageSize: pageSize,
        currentPage: currentPage,
        totalPages: 0,
        totalCount: 0,
        hasMore: hasMore,
        hasPrevious: currentPage > 1
      ),
      nextPageCursor: mappedThreads.last?.cursor
    )
  }

  private static func mapTopic(
    _ payload: HotTopicListItemPayload,
    fallbackRank: Int
  ) -> TiebaHotTopic? {
    let id = payload.topicID.value
    let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard id > 0, !name.isEmpty else { return nil }
    let rank = payload.info.rank.value > 0 ? clampedInt(payload.info.rank.value) : fallbackRank
    return TiebaHotTopic(
      id: id,
      name: name,
      description: payload.info.description.trimmingCharacters(in: .whitespacesAndNewlines),
      imageURL: remoteURL(
        nonempty(payload.info.headPicture)
          ?? nonempty(payload.info.desktopPicture)
          ?? nonempty(payload.info.sharePicture)
      ),
      discussionCount: max(payload.info.discussionCount.value, 0),
      rank: max(rank, 0),
      tag: clampedInt(max(payload.info.tag.value, 0))
    )
  }

  private static func mapTopicInfo(
    _ payload: HotTopicInfoPayload,
    requestedTopicID: Int64,
    requestedTopicName: String
  ) -> TiebaHotTopic {
    let responseID = payload.topicID.value
    let responseName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return TiebaHotTopic(
      id: responseID > 0 ? responseID : requestedTopicID,
      name: responseName.isEmpty ? requestedTopicName : responseName,
      description: payload.description.trimmingCharacters(in: .whitespacesAndNewlines),
      imageURL: remoteURL(payload.image),
      discussionCount: max(payload.discussionCount.value, 0),
      rank: clampedInt(max(payload.rank.value, 0)),
      tag: 0
    )
  }

  private static func mapForum(_ payload: HotTopicForumPayload) -> TiebaHotTopicForum? {
    let id = payload.forumID.value
    let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard id > 0, !name.isEmpty else { return nil }
    return TiebaHotTopicForum(
      id: id,
      name: name,
      avatarURL: remoteURL(payload.avatar),
      description: payload.description.trimmingCharacters(in: .whitespacesAndNewlines),
      memberCount: clampedInt(max(payload.memberCount.value, 0)),
      threadCount: clampedInt(max(payload.threadCount.value, 0)),
      postCount: clampedInt(max(payload.postCount.value, 0))
    )
  }

  private static func mapThread(
    _ payload: HotTopicThreadPayload
  ) -> (thread: TiebaThreadSearchResult, cursor: Int64)? {
    let info = payload.info
    let threadID = info.threadID.value > 0 ? info.threadID.value : payload.feedID.value
    guard threadID > 0 else { return nil }
    let cursor = payload.feedID.value > 0 ? payload.feedID.value : threadID
    let displayName = info.author.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let alternateName = info.author.alternateDisplayName.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let username = info.author.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorName = nonempty(displayName) ?? nonempty(alternateName) ?? nonempty(username)
      ?? "\u{533f}\u{540d}\u{7528}\u{6237}"
    return (
      TiebaThreadSearchResult(
        threadID: threadID,
        firstPostID: max(info.firstPostID.value, 0),
        forumID: max(info.forumID.value, 0),
        forumName: info.forumName,
        title: info.title,
        excerpt: info.abstract,
        authorID: max(info.author.userID.value, 0),
        authorName: authorName,
        authorPortraitURL: remoteURL(info.author.portrait),
        replyCount: clampedInt(max(info.replyCount.value, 0)),
        likeCount: clampedInt(max(info.likeCount.value, 0)),
        shareCount: clampedInt(max(info.shareCount.value, 0)),
        createdAt: date(seconds: info.createdAt.value),
        images: info.media.compactMap(mapImage)
      ),
      cursor
    )
  }

  private static func mapImage(_ payload: HotTopicMediaPayload) -> TiebaSearchImage? {
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
    _ envelope: HotTopicEnvelope<Payload>
  ) throws {
    guard envelope.code.value == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: envelope.code.value),
        message: envelope.error
      )
    }
  }

  private static func date(seconds: Int64) -> Date? {
    seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
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
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func clampedInt(_ value: Int64) -> Int {
    Int(clamping: value)
  }
}

private struct HotTopicEnvelope<Payload: Decodable>: Decodable {
  let code: HotFlexibleInteger
  let error: String
  let data: Payload?

  enum CodingKeys: String, CodingKey {
    case code = "no"
    case error
    case data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(HotFlexibleInteger.self, forKey: .code)
    error = (try? container.decode(String.self, forKey: .error)) ?? ""
    if code.value == 0 {
      data = try container.decodeIfPresent(Payload.self, forKey: .data)
    } else {
      data = nil
    }
  }
}

private struct HotTopicListPayload: Decodable {
  let list: HotTopicListContainer

  enum CodingKeys: String, CodingKey {
    case list
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    list = try container.decodeIfPresent(HotTopicListContainer.self, forKey: .list) ?? .empty
  }
}

private struct HotTopicListContainer: Decodable {
  static let empty = HotTopicListContainer(items: [])

  let items: [HotTopicListItemPayload]

  private init(items: [HotTopicListItemPayload]) {
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case items = "ret"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decodeIfPresent([HotTopicListItemPayload].self, forKey: .items) ?? []
  }
}

private struct HotTopicListItemPayload: Decodable {
  let topicID: HotFlexibleInteger
  let name: String
  let info: HotTopicListInfoPayload

  enum CodingKeys: String, CodingKey {
    case topicID = "mul_id"
    case name = "mul_name"
    case info = "topic_info"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    topicID = (try? container.decode(HotFlexibleInteger.self, forKey: .topicID)) ?? .zero
    name = (try? container.decode(String.self, forKey: .name)) ?? ""
    info = try container.decodeIfPresent(HotTopicListInfoPayload.self, forKey: .info) ?? .empty
  }
}

private struct HotTopicListInfoPayload: Decodable {
  static let empty = HotTopicListInfoPayload()

  let description: String
  let headPicture: String
  let desktopPicture: String
  let sharePicture: String
  let discussionCount: HotFlexibleInteger
  let tag: HotFlexibleInteger
  let rank: HotFlexibleInteger

  enum CodingKeys: String, CodingKey {
    case description = "topic_desc"
    case headPicture = "head_pic"
    case desktopPicture = "pc_hpic"
    case sharePicture = "share_pic"
    case discussionCount = "real_discuss_num"
    case tag = "topic_tag"
    case rank = "idx_bang"
  }

  private init() {
    description = ""
    headPicture = ""
    desktopPicture = ""
    sharePicture = ""
    discussionCount = .zero
    tag = .zero
    rank = .zero
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    description = (try? container.decode(String.self, forKey: .description)) ?? ""
    headPicture = (try? container.decode(String.self, forKey: .headPicture)) ?? ""
    desktopPicture = (try? container.decode(String.self, forKey: .desktopPicture)) ?? ""
    sharePicture = (try? container.decode(String.self, forKey: .sharePicture)) ?? ""
    discussionCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .discussionCount)) ?? .zero
    tag = (try? container.decode(HotFlexibleInteger.self, forKey: .tag)) ?? .zero
    rank = (try? container.decode(HotFlexibleInteger.self, forKey: .rank)) ?? .zero
  }
}

private struct HotTopicDetailPayload: Decodable {
  let topicInfo: HotTopicInfoPayload
  let relatedForums: [HotTopicForumPayload]
  let relatedThreads: HotTopicThreadListPayload
  let hasMore: HotFlexibleBool
  let request: HotTopicRequestEchoPayload

  enum CodingKeys: String, CodingKey {
    case topicInfo = "topic_info"
    case relatedForums = "relate_forum"
    case relatedThreads = "relate_thread"
    case hasMore = "has_more"
    case request = "wreq"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    topicInfo = try container.decode(HotTopicInfoPayload.self, forKey: .topicInfo)
    relatedForums =
      try container.decodeIfPresent([HotTopicForumPayload].self, forKey: .relatedForums) ?? []
    relatedThreads =
      try container.decodeIfPresent(HotTopicThreadListPayload.self, forKey: .relatedThreads)
      ?? .empty
    hasMore = (try? container.decode(HotFlexibleBool.self, forKey: .hasMore)) ?? .falseValue
    request =
      try container.decodeIfPresent(HotTopicRequestEchoPayload.self, forKey: .request) ?? .empty
  }
}

private struct HotTopicInfoPayload: Decodable {
  let topicID: HotFlexibleInteger
  let name: String
  let description: String
  let discussionCount: HotFlexibleInteger
  let image: String
  let rank: HotFlexibleInteger

  enum CodingKeys: String, CodingKey {
    case topicID = "topic_id"
    case name = "topic_name"
    case description = "topic_desc"
    case discussionCount = "discuss_num"
    case image = "topic_image"
    case rank = "idx_num"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    topicID = (try? container.decode(HotFlexibleInteger.self, forKey: .topicID)) ?? .zero
    name = (try? container.decode(String.self, forKey: .name)) ?? ""
    description = (try? container.decode(String.self, forKey: .description)) ?? ""
    discussionCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .discussionCount)) ?? .zero
    image = (try? container.decode(String.self, forKey: .image)) ?? ""
    rank = (try? container.decode(HotFlexibleInteger.self, forKey: .rank)) ?? .zero
  }
}

private struct HotTopicForumPayload: Decodable {
  let forumID: HotFlexibleInteger
  let name: String
  let avatar: String
  let description: String
  let memberCount: HotFlexibleInteger
  let threadCount: HotFlexibleInteger
  let postCount: HotFlexibleInteger

  enum CodingKeys: String, CodingKey {
    case forumID = "forum_id"
    case name = "forum_name"
    case avatar
    case description = "desc"
    case memberCount = "member_num"
    case threadCount = "thread_num"
    case postCount = "post_num"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    forumID = (try? container.decode(HotFlexibleInteger.self, forKey: .forumID)) ?? .zero
    name = (try? container.decode(String.self, forKey: .name)) ?? ""
    avatar = (try? container.decode(String.self, forKey: .avatar)) ?? ""
    description = (try? container.decode(String.self, forKey: .description)) ?? ""
    memberCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .memberCount)) ?? .zero
    threadCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .threadCount)) ?? .zero
    postCount = (try? container.decode(HotFlexibleInteger.self, forKey: .postCount)) ?? .zero
  }
}

private struct HotTopicThreadListPayload: Decodable {
  static let empty = HotTopicThreadListPayload(items: [])

  let items: [HotTopicThreadPayload]

  private init(items: [HotTopicThreadPayload]) {
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case items = "thread_list"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decodeIfPresent([HotTopicThreadPayload].self, forKey: .items) ?? []
  }
}

private struct HotTopicThreadPayload: Decodable {
  let feedID: HotFlexibleInteger
  let info: HotTopicThreadInfoPayload

  enum CodingKeys: String, CodingKey {
    case feedID = "feed_id"
    case info = "thread_info"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    feedID = (try? container.decode(HotFlexibleInteger.self, forKey: .feedID)) ?? .zero
    info = try container.decodeIfPresent(HotTopicThreadInfoPayload.self, forKey: .info) ?? .empty
  }
}

private struct HotTopicThreadInfoPayload: Decodable {
  static let empty = HotTopicThreadInfoPayload()

  let threadID: HotFlexibleInteger
  let firstPostID: HotFlexibleInteger
  let forumID: HotFlexibleInteger
  let forumName: String
  let title: String
  let abstract: String
  let createdAt: HotFlexibleInteger
  let replyCount: HotFlexibleInteger
  let likeCount: HotFlexibleInteger
  let shareCount: HotFlexibleInteger
  let author: HotTopicAuthorPayload
  let media: [HotTopicMediaPayload]

  enum CodingKeys: String, CodingKey {
    case threadID = "tid"
    case firstPostID = "first_post_id"
    case forumID = "forum_id"
    case forumName = "forum_name"
    case title
    case abstract
    case createdAt = "create_time"
    case replyCount = "reply_num"
    case likeCount = "agree_num"
    case shareCount = "share_num"
    case author
    case media
  }

  private init() {
    threadID = .zero
    firstPostID = .zero
    forumID = .zero
    forumName = ""
    title = ""
    abstract = ""
    createdAt = .zero
    replyCount = .zero
    likeCount = .zero
    shareCount = .zero
    author = .empty
    media = []
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    threadID = (try? container.decode(HotFlexibleInteger.self, forKey: .threadID)) ?? .zero
    firstPostID =
      (try? container.decode(HotFlexibleInteger.self, forKey: .firstPostID)) ?? .zero
    forumID = (try? container.decode(HotFlexibleInteger.self, forKey: .forumID)) ?? .zero
    forumName = (try? container.decode(String.self, forKey: .forumName)) ?? ""
    title = (try? container.decode(String.self, forKey: .title)) ?? ""
    abstract = (try? container.decode(String.self, forKey: .abstract)) ?? ""
    createdAt = (try? container.decode(HotFlexibleInteger.self, forKey: .createdAt)) ?? .zero
    replyCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .replyCount)) ?? .zero
    likeCount = (try? container.decode(HotFlexibleInteger.self, forKey: .likeCount)) ?? .zero
    shareCount =
      (try? container.decode(HotFlexibleInteger.self, forKey: .shareCount)) ?? .zero
    author = try container.decodeIfPresent(HotTopicAuthorPayload.self, forKey: .author) ?? .empty
    media = try container.decodeIfPresent([HotTopicMediaPayload].self, forKey: .media) ?? []
  }
}

private struct HotTopicAuthorPayload: Decodable {
  static let empty = HotTopicAuthorPayload()

  let userID: HotFlexibleInteger
  let username: String
  let displayName: String
  let alternateDisplayName: String
  let portrait: String

  enum CodingKeys: String, CodingKey {
    case userID = "id"
    case username = "name"
    case displayName = "show_nickname"
    case alternateDisplayName = "name_show"
    case portrait
  }

  private init() {
    userID = .zero
    username = ""
    displayName = ""
    alternateDisplayName = ""
    portrait = ""
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userID = (try? container.decode(HotFlexibleInteger.self, forKey: .userID)) ?? .zero
    username = (try? container.decode(String.self, forKey: .username)) ?? ""
    displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
    alternateDisplayName =
      (try? container.decode(String.self, forKey: .alternateDisplayName)) ?? ""
    portrait = (try? container.decode(String.self, forKey: .portrait)) ?? ""
  }
}

private struct HotTopicMediaPayload: Decodable {
  let type: String
  let width: HotFlexibleInteger
  let height: HotFlexibleInteger
  let smallPicture: String?
  let bigPicture: String?
  let waterPicture: String?

  enum CodingKeys: String, CodingKey {
    case type
    case width
    case height
    case smallPicture = "small_pic"
    case bigPicture = "big_pic"
    case waterPicture = "water_pic"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = (try? container.decode(String.self, forKey: .type)) ?? ""
    width = (try? container.decode(HotFlexibleInteger.self, forKey: .width)) ?? .zero
    height = (try? container.decode(HotFlexibleInteger.self, forKey: .height)) ?? .zero
    smallPicture = try? container.decodeIfPresent(String.self, forKey: .smallPicture)
    bigPicture = try? container.decodeIfPresent(String.self, forKey: .bigPicture)
    waterPicture = try? container.decodeIfPresent(String.self, forKey: .waterPicture)
  }
}

private struct HotTopicRequestEchoPayload: Decodable {
  static let empty = HotTopicRequestEchoPayload(currentPage: .zero)

  let currentPage: HotFlexibleInteger

  private init(currentPage: HotFlexibleInteger) {
    self.currentPage = currentPage
  }

  enum CodingKeys: String, CodingKey {
    case currentPage = "pn"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    currentPage =
      (try? container.decode(HotFlexibleInteger.self, forKey: .currentPage)) ?? .zero
  }
}

private struct HotFlexibleInteger: Decodable {
  static let zero = HotFlexibleInteger(value: 0)

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

private struct HotFlexibleBool: Decodable {
  static let falseValue = HotFlexibleBool(value: false)

  let value: Bool

  private init(value: Bool) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let boolean = try? container.decode(Bool.self) {
      value = boolean
    } else if let integer = try? container.decode(Int64.self) {
      value = integer != 0
    } else if let string = try? container.decode(String.self) {
      let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if normalized == "true" || normalized == "1" {
        value = true
      } else if normalized == "false" || normalized == "0" || normalized.isEmpty {
        value = false
      } else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected a boolean value."
        )
      }
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected a boolean value."
      )
    }
  }
}
