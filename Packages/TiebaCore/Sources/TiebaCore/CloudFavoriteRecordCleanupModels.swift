import Foundation

/// A cloud-list record is identified by its owner and TID, independently of the
/// original forum or marked floor. This does not relax normal favorite targets.
public struct TiebaCloudFavoriteRecordTarget: Sendable, Hashable, Codable {
  public let userID: Int64
  public let threadID: Int64

  public init(userID: Int64, threadID: Int64) {
    self.userID = userID
    self.threadID = threadID
  }
}

public enum TiebaCloudFavoriteRecordCleanupOutcome: Sendable, Hashable, Codable {
  /// The dispatch hook completed, but cancellation was observed before the
  /// transport was invoked. The caller may safely discard its prepared intent.
  case notDispatched
  /// The server acknowledged the request; membership must still be read back.
  case acceptedAwaitingVerification
  case rejected(code: Int32, message: String)
  /// Dispatch may have happened. Retrying a write is not a verification strategy.
  case unknown
}

public struct TiebaCloudFavoriteRecordCleanupReceipt: Sendable, Hashable, Codable {
  public let target: TiebaCloudFavoriteRecordTarget
  public let outcome: TiebaCloudFavoriteRecordCleanupOutcome

  public init(
    target: TiebaCloudFavoriteRecordTarget,
    outcome: TiebaCloudFavoriteRecordCleanupOutcome
  ) {
    self.target = target
    self.outcome = outcome
  }
}

public enum TiebaCloudFavoriteRecordScanIssue: Sendable, Hashable, Codable {
  case duplicateRecord
  case changedBetweenScans
  case limitExceeded
  case deadlineExceeded
  case unreadablePage
}

/// Presence needs one exact record. Absence needs two matching, complete offset
/// scans, which are observations rather than a server snapshot or atomic proof.
/// The API advertises neither a revision nor a total.
public enum TiebaCloudFavoriteRecordObservation: Sendable, Hashable {
  case observedAbsent
  case observedPresent
  case inconclusive(TiebaCloudFavoriteRecordScanIssue)
}

/// These failures occur before dispatch, so they are distinct from an unknown
/// receipt. Errors thrown by the caller's beforeDispatch hook propagate unchanged.
public enum TiebaCloudFavoriteRecordCleanupError: Error, Sendable, Equatable {
  case writeConflict
  case recordNotPresent
  case inconclusive(TiebaCloudFavoriteRecordScanIssue)
}
