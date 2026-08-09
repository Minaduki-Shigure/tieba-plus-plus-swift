import Foundation

public struct TiebaRecommendationReason: Identifiable, Sendable, Hashable {
  public let id: UInt32
  public let title: String
  public let extra: String

  public init(id: UInt32, title: String, extra: String) {
    self.id = id
    self.title = title
    self.extra = extra
  }
}

public struct TiebaRecommendedThread: Identifiable, Sendable, Hashable {
  public var id: Int64 { thread.id }

  public let thread: TiebaThread
  public let reasons: [TiebaRecommendationReason]

  public init(thread: TiebaThread, reasons: [TiebaRecommendationReason]) {
    self.thread = thread
    self.reasons = reasons
  }
}

public struct TiebaPersonalizedPage: Sendable, Hashable {
  public let items: [TiebaRecommendedThread]
  public let currentPage: Int
  public let hasMore: Bool

  public init(items: [TiebaRecommendedThread], currentPage: Int, hasMore: Bool) {
    self.items = items
    self.currentPage = currentPage
    self.hasMore = hasMore
  }
}
