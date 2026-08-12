import Foundation

public enum TiebaOfficialCheckInStatus: Sendable, Hashable {
  case unknown
  case pending
  case checkedIn
}

public struct TiebaOfficialCheckInForum: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let name: String
  public let level: Int
  public let avatar: String
  public let checkInStatus: TiebaOfficialCheckInStatus
  public let isForbidden: Bool

  public init(
    id: Int64,
    name: String,
    level: Int,
    avatar: String,
    checkInStatus: TiebaOfficialCheckInStatus,
    isForbidden: Bool
  ) {
    self.id = id
    self.name = name
    self.level = level
    self.avatar = avatar
    self.checkInStatus = checkInStatus
    self.isForbidden = isForbidden
  }
}

public struct TiebaOfficialBatchCheckInTarget: Sendable, Hashable {
  public let forumID: Int64
  public let canonicalForumName: String

  public init(forumID: Int64, canonicalForumName: String) {
    self.forumID = forumID
    self.canonicalForumName = canonicalForumName
  }
}

public struct TiebaOfficialCheckInCatalog: Sendable, Hashable {
  public let userID: Int64
  public let forums: [TiebaOfficialCheckInForum]
  public let minimumBatchLevel: Int
  public let maximumBatchCount: Int
  public let isBatchCheckInAvailable: Bool

  public init(
    userID: Int64,
    forums: [TiebaOfficialCheckInForum],
    minimumBatchLevel: Int,
    maximumBatchCount: Int,
    isBatchCheckInAvailable: Bool
  ) {
    self.userID = userID
    self.forums = forums
    self.minimumBatchLevel = minimumBatchLevel
    self.maximumBatchCount = maximumBatchCount
    self.isBatchCheckInAvailable = isBatchCheckInAvailable
  }

  public var batchEligibleForums: [TiebaOfficialCheckInForum] {
    guard isBatchCheckInAvailable, maximumBatchCount > 0 else { return [] }
    return Array(
      forums.lazy.filter {
        $0.checkInStatus == .pending
          && !$0.isForbidden
          && $0.level >= minimumBatchLevel
      }.prefix(maximumBatchCount)
    )
  }

  public var batchEligibleTargets: [TiebaOfficialBatchCheckInTarget] {
    batchEligibleForums.map {
      TiebaOfficialBatchCheckInTarget(forumID: $0.id, canonicalForumName: $0.name)
    }
  }

  public var actionableCheckInTargets: [TiebaOfficialBatchCheckInTarget] {
    forums.filter {
      $0.checkInStatus == .pending && !$0.isForbidden
    }.map {
      TiebaOfficialBatchCheckInTarget(forumID: $0.id, canonicalForumName: $0.name)
    }
  }
}

public enum TiebaOfficialBatchCheckInDisposition: Sendable, Hashable {
  case confirmed
  case rejected(code: Int32, message: String)
}

public struct TiebaOfficialBatchCheckInItem: Identifiable, Sendable, Hashable {
  public var id: Int64 { forumID }

  public let forumID: Int64
  public let forumName: String
  public let disposition: TiebaOfficialBatchCheckInDisposition
  public let currentExperience: Int
  public let consecutiveDays: Int
  public let isFiltered: Bool
  public let isEnabled: Bool

  public init(
    forumID: Int64,
    forumName: String,
    disposition: TiebaOfficialBatchCheckInDisposition,
    currentExperience: Int,
    consecutiveDays: Int,
    isFiltered: Bool,
    isEnabled: Bool
  ) {
    self.forumID = forumID
    self.forumName = forumName
    self.disposition = disposition
    self.currentExperience = currentExperience
    self.consecutiveDays = consecutiveDays
    self.isFiltered = isFiltered
    self.isEnabled = isEnabled
  }

  public var isConfirmed: Bool {
    if case .confirmed = disposition { return true }
    return false
  }
}

public struct TiebaOfficialBatchCheckInResult: Sendable, Hashable {
  public let userID: Int64
  public let items: [TiebaOfficialBatchCheckInItem]

  public init(userID: Int64, items: [TiebaOfficialBatchCheckInItem]) {
    self.userID = userID
    self.items = items
  }
}
