import Foundation

public struct TiebaHotTopic: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let description: String
  public let imageURL: URL?
  public let discussionCount: Int64
  public let rank: Int
  public let tag: Int

  public init(
    id: Int64,
    name: String,
    description: String,
    imageURL: URL?,
    discussionCount: Int64,
    rank: Int,
    tag: Int
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.imageURL = imageURL
    self.discussionCount = discussionCount
    self.rank = rank
    self.tag = tag
  }
}

public struct TiebaHotThreadCategory: Identifiable, Sendable, Hashable {
  public let serverID: Int32
  public let code: String
  public let title: String

  public var id: String { code }

  public init(serverID: Int32, code: String, title: String) {
    self.serverID = serverID
    self.code = code
    self.title = title
  }
}

public struct TiebaHotThreadRankItem: Identifiable, Sendable, Hashable {
  public let rank: Int
  public let hotScore: Int
  public let thread: TiebaThread

  public var id: Int64 { thread.id }

  public init(rank: Int, hotScore: Int, thread: TiebaThread) {
    self.rank = rank
    self.hotScore = hotScore
    self.thread = thread
  }
}

public struct TiebaHotThreadRanking: Sendable, Hashable {
  public let topics: [TiebaHotTopic]
  public let categories: [TiebaHotThreadCategory]
  public let items: [TiebaHotThreadRankItem]

  public init(
    topics: [TiebaHotTopic],
    categories: [TiebaHotThreadCategory],
    items: [TiebaHotThreadRankItem]
  ) {
    self.topics = topics
    self.categories = categories
    self.items = items
  }
}

public struct TiebaHotTopicForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let avatarURL: URL?
  public let description: String
  public let memberCount: Int
  public let threadCount: Int
  public let postCount: Int

  public init(
    id: Int64,
    name: String,
    avatarURL: URL?,
    description: String,
    memberCount: Int,
    threadCount: Int,
    postCount: Int
  ) {
    self.id = id
    self.name = name
    self.avatarURL = avatarURL
    self.description = description
    self.memberCount = memberCount
    self.threadCount = threadCount
    self.postCount = postCount
  }
}

public struct TiebaHotTopicPage: Sendable, Hashable {
  public let topic: TiebaHotTopic
  public let relatedForums: [TiebaHotTopicForum]
  public let threads: [TiebaThreadSearchResult]
  public let pagination: TiebaPagination
  public let nextPageCursor: Int64?

  public init(
    topic: TiebaHotTopic,
    relatedForums: [TiebaHotTopicForum],
    threads: [TiebaThreadSearchResult],
    pagination: TiebaPagination,
    nextPageCursor: Int64?
  ) {
    self.topic = topic
    self.relatedForums = relatedForums
    self.threads = threads
    self.pagination = pagination
    self.nextPageCursor = nextPageCursor
  }
}
