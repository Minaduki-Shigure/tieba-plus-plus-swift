import Foundation

enum AutomaticForumCheckInTargetPhase: String, Codable, Equatable, Sendable {
  case outcomeUnknown
  case confirmed
  case failed
}

enum AutomaticForumCheckInDayState: String, Codable, Equatable, Sendable {
  case inProgress
  case completed
  case needsReview
  case paused
}

struct AutomaticForumCheckInTargetResult: Equatable, Sendable {
  let target: ForumBatchCheckInTarget
  let phase: AutomaticForumCheckInTargetPhase
}

struct AutomaticForumCheckInLedgerEntry: Codable, Equatable, Sendable {
  let forumID: Int64
  let forumName: String
  let runID: UUID
  fileprivate(set) var phase: AutomaticForumCheckInTargetPhase
  // A claim is already an unknown outcome after a crash. Only the same live run,
  // with positive evidence that it never dispatched, may release an unsettled claim.
  fileprivate(set) var isSettled: Bool
  let createdAtMilliseconds: Int64
  fileprivate(set) var updatedAtMilliseconds: Int64

  var target: ForumBatchCheckInTarget {
    ForumBatchCheckInTarget(forumID: forumID, forumName: forumName)
  }
  var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1_000) }
  var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMilliseconds) / 1_000) }
}

struct AutomaticForumCheckInDayRecord: Codable, Equatable, Sendable {
  let userID: Int64
  let day: String
  fileprivate(set) var runID: UUID
  fileprivate(set) var state: AutomaticForumCheckInDayState
  fileprivate(set) var pausedReason: String?
  fileprivate(set) var entries: [AutomaticForumCheckInLedgerEntry]
  fileprivate(set) var updatedAtMilliseconds: Int64

  var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMilliseconds) / 1_000) }
  var confirmedCount: Int { entries.filter { $0.phase == .confirmed }.count }
  var failedCount: Int { entries.filter { $0.phase == .failed }.count }
  var unconfirmedCount: Int { entries.filter { $0.phase == .outcomeUnknown }.count }
}

enum AutomaticForumCheckInLedgerError: LocalizedError, Equatable, Sendable {
  case invalidTarget
  case invalidDay
  case expiredDay
  case targetConflict
  case alreadyClaimed
  case recordNotFound
  case operationMismatch
  case invalidTransition
  case corruptedArchive
  case authenticationFailed
  case authenticationUnavailable
  case unsupportedSchemaVersion(Int)
  case capacityExceeded
  case unsafeStorage
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidTarget: "自动签到的目标无效。"
    case .invalidDay: "自动签到日期无效或已跨日，请重新读取状态。"
    case .expiredDay: "该日期早于自动签到记录的保留范围，不能重新派发。"
    case .targetConflict: "同一贴吧的签到记录名称不一致，已停止自动签到。"
    case .alreadyClaimed: "该贴吧今天已有签到派发记录，不会自动重复发送。"
    case .recordNotFound: "未找到自动签到记录。"
    case .operationMismatch: "自动签到结果与派发记录不匹配。"
    case .invalidTransition: "自动签到记录不能进行此状态变更。"
    case .corruptedArchive: "自动签到记录损坏，已停止派发且未覆盖记录。"
    case .authenticationFailed: "自动签到记录未通过完整性验证，已停止派发。"
    case .authenticationUnavailable: "暂时无法验证自动签到记录，请解锁后重新打开应用。"
    case .unsupportedSchemaVersion: "自动签到记录来自更新版本，当前版本不会修改它。"
    case .capacityExceeded: "自动签到记录超过安全容量，已停止派发。"
    case .unsafeStorage: "自动签到记录的存储位置不安全。"
    case .readFailed: "无法读取自动签到记录，已停止派发。"
    case .writeFailed: "无法安全保存自动签到记录，已停止派发。"
    }
  }
}

protocol AutomaticForumCheckInLedgerRepository: Sendable {
  func load(userID: Int64, day: String) async throws -> AutomaticForumCheckInDayRecord?
  func claimTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord
  func settleResults(
    userID: Int64, day: String, runID: UUID, results: [AutomaticForumCheckInTargetResult],
    at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord
  func releaseUndispatchedTargets(
    userID: Int64, day: String, runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord
  func confirmReadBack(
    userID: Int64, day: String, targets: [ForumBatchCheckInTarget], at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord
  func finishDay(
    userID: Int64, day: String, runID: UUID, state: AutomaticForumCheckInDayState,
    pausedReason: String?, at date: Date
  ) async throws -> AutomaticForumCheckInDayRecord
}

// Mutations operate on a local archive copy. The file repository publishes the
// entire copy under a cross-process lock before returning permission to dispatch.
struct AutomaticForumCheckInLedgerArchive: Codable, Equatable, Sendable {
  let schemaVersion: Int
  var oldestPermittedDay: String?
  var days: [AutomaticForumCheckInDayRecord]

  static let empty = Self(schemaVersion: 1, oldestPermittedDay: nil, days: [])
}

enum AutomaticForumCheckInLedgerModel {
  static let maximumClaimTargetCount = 100
  static let maximumDayRecordCount = 4_096
  static let retainedDayCount = 31
  private static let maximumTimestampMilliseconds = 253_402_271_999_000.0

  static func dayStart(_ day: String) -> Date? {
    guard day.utf8.count == 10 else { return nil }
    let parts = day.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
      let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
      let date = AutomaticForumCheckInSchedule.calendar.date(
        from: DateComponents(year: year, month: month, day: dayOfMonth)
      ),
      AutomaticForumCheckInSchedule.dayKey(at: date) == day
    else { return nil }
    return date
  }

  static func milliseconds(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 * 1_000).rounded()
    guard value.isFinite, abs(value) <= maximumTimestampMilliseconds else {
      throw AutomaticForumCheckInLedgerError.invalidDay
    }
    return Int64(value)
  }

  static func canonicalTarget(_ target: ForumBatchCheckInTarget) throws
    -> ForumBatchCheckInTarget
  {
    let name = target.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard target.forumID > 0, !name.isEmpty, name.utf8.count <= 1_024,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw AutomaticForumCheckInLedgerError.invalidTarget }
    return ForumBatchCheckInTarget(forumID: target.forumID, forumName: name)
  }

  static func validateKey(userID: Int64, day: String) throws {
    guard userID > 0 else { throw AutomaticForumCheckInLedgerError.invalidTarget }
    guard dayStart(day) != nil else { throw AutomaticForumCheckInLedgerError.invalidDay }
  }

  static func load(
    _ archive: AutomaticForumCheckInLedgerArchive, userID: Int64, day: String
  ) throws -> AutomaticForumCheckInDayRecord? {
    try validateKey(userID: userID, day: day)
    if let floor = archive.oldestPermittedDay, day < floor {
      throw AutomaticForumCheckInLedgerError.expiredDay
    }
    return archive.days.first { $0.userID == userID && $0.day == day }
  }

  static func claim(
    _ archive: inout AutomaticForumCheckInLedgerArchive, userID: Int64, day: String,
    runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) throws -> AutomaticForumCheckInDayRecord {
    try requireCurrentDay(userID: userID, day: day, at: date)
    let targets = try validatedTargets(targets)
    var record =
      try load(archive, userID: userID, day: day)
      ?? newDay(userID: userID, day: day, runID: runID, at: date)
    guard record.state != .completed else { throw AutomaticForumCheckInLedgerError.alreadyClaimed }
    for target in targets {
      if let previous = record.entries.first(where: { $0.forumID == target.forumID }) {
        guard previous.forumName == target.forumName else {
          throw AutomaticForumCheckInLedgerError.targetConflict
        }
        throw AutomaticForumCheckInLedgerError.alreadyClaimed
      }
    }
    // Recheck inside the durable transaction: another process may have paused
    // this account/day or dispatched since the caller read its earlier snapshot.
    guard record.state != .paused, record.entries.allSatisfy({ $0.phase == .confirmed }) else {
      throw AutomaticForumCheckInLedgerError.invalidTransition
    }
    let now = try milliseconds(date)
    record.entries.append(
      contentsOf: targets.map {
        AutomaticForumCheckInLedgerEntry(
          forumID: $0.forumID, forumName: $0.forumName, runID: runID,
          phase: .outcomeUnknown, isSettled: false,
          createdAtMilliseconds: now, updatedAtMilliseconds: now
        )
      })
    record.entries.sort { $0.forumID < $1.forumID }
    record.runID = runID
    record.state = .inProgress
    record.pausedReason = nil
    record.updatedAtMilliseconds = max(record.updatedAtMilliseconds, now)
    try advanceRetention(&archive, at: date)
    replace(&archive, record)
    return record
  }

  static func settle(
    _ archive: inout AutomaticForumCheckInLedgerArchive, userID: Int64, day: String,
    runID: UUID, results: [AutomaticForumCheckInTargetResult], at date: Date
  ) throws -> AutomaticForumCheckInDayRecord {
    let targets = try validatedTargets(results.map(\.target))
    var record = try requiredDay(archive, userID: userID, day: day)
    let now = try milliseconds(date)
    for (target, result) in zip(targets, results) {
      let index = try entryIndex(record, target: target, runID: runID)
      let previous = record.entries[index].phase
      guard previous == .outcomeUnknown || previous == result.phase else {
        throw AutomaticForumCheckInLedgerError.invalidTransition
      }
      record.entries[index].phase = result.phase
      record.entries[index].isSettled = true
      record.entries[index].updatedAtMilliseconds = max(
        record.entries[index].updatedAtMilliseconds, now)
    }
    record.updatedAtMilliseconds = max(record.updatedAtMilliseconds, now)
    replace(&archive, record)
    return record
  }

  static func releaseUndispatched(
    _ archive: inout AutomaticForumCheckInLedgerArchive, userID: Int64, day: String,
    runID: UUID, targets: [ForumBatchCheckInTarget], at date: Date
  ) throws -> AutomaticForumCheckInDayRecord {
    let targets = try validatedTargets(targets)
    var record = try requiredDay(archive, userID: userID, day: day)
    for target in targets {
      let index = try entryIndex(record, target: target, runID: runID)
      guard !record.entries[index].isSettled,
        record.entries[index].phase == .outcomeUnknown
      else { throw AutomaticForumCheckInLedgerError.invalidTransition }
    }
    let releasedIDs = Set(targets.map(\.forumID))
    record.entries.removeAll { releasedIDs.contains($0.forumID) }
    record.updatedAtMilliseconds = max(record.updatedAtMilliseconds, try milliseconds(date))
    replace(&archive, record)
    return record
  }

  static func confirmReadBack(
    _ archive: inout AutomaticForumCheckInLedgerArchive, userID: Int64, day: String,
    targets: [ForumBatchCheckInTarget], at date: Date
  ) throws -> AutomaticForumCheckInDayRecord {
    // Tomorrow's "checked in" state is not evidence of yesterday's write.
    try requireCurrentDay(userID: userID, day: day, at: date)
    let targets = try validatedTargets(targets)
    var record = try requiredDay(archive, userID: userID, day: day)
    let now = try milliseconds(date)
    for target in targets {
      let index = try entryIndex(record, target: target, runID: nil)
      guard record.entries[index].phase != .failed else {
        throw AutomaticForumCheckInLedgerError.invalidTransition
      }
      record.entries[index].phase = .confirmed
      record.entries[index].isSettled = true
      record.entries[index].updatedAtMilliseconds = max(
        record.entries[index].updatedAtMilliseconds, now)
    }
    record.updatedAtMilliseconds = max(record.updatedAtMilliseconds, now)
    replace(&archive, record)
    return record
  }

  static func finishDay(
    _ archive: inout AutomaticForumCheckInLedgerArchive, userID: Int64, day: String,
    runID: UUID, state: AutomaticForumCheckInDayState, pausedReason: String?, at date: Date
  ) throws -> AutomaticForumCheckInDayRecord {
    try validateKey(userID: userID, day: day)
    guard validReason(pausedReason),
      state == .paused || state == .needsReview || pausedReason == nil
    else {
      throw AutomaticForumCheckInLedgerError.invalidTransition
    }
    var record: AutomaticForumCheckInDayRecord
    if let existing = try load(archive, userID: userID, day: day) {
      record = existing
    } else {
      try requireCurrentDay(userID: userID, day: day, at: date)
      record = try newDay(userID: userID, day: day, runID: runID, at: date)
    }
    guard state != .completed || record.entries.allSatisfy({ $0.phase == .confirmed }) else {
      throw AutomaticForumCheckInLedgerError.invalidTransition
    }
    guard record.state != .completed || state == .completed else {
      throw AutomaticForumCheckInLedgerError.invalidTransition
    }
    guard record.state != .paused || state == .paused,
      state != .inProgress || record.entries.allSatisfy({ $0.phase == .confirmed })
    else { throw AutomaticForumCheckInLedgerError.invalidTransition }
    record.runID = runID
    record.state = state
    record.pausedReason = state == .paused ? record.pausedReason ?? pausedReason : pausedReason
    record.updatedAtMilliseconds = max(record.updatedAtMilliseconds, try milliseconds(date))
    // A late result can close an old day but must not erase newer retained data.
    try advanceRetention(&archive, at: date)
    guard archive.oldestPermittedDay.map({ day >= $0 }) ?? true else {
      throw AutomaticForumCheckInLedgerError.expiredDay
    }
    replace(&archive, record)
    return record
  }

  static func validate(_ archive: AutomaticForumCheckInLedgerArchive, maximumEntries: Int) throws {
    guard archive.schemaVersion == 1 else {
      throw AutomaticForumCheckInLedgerError.unsupportedSchemaVersion(archive.schemaVersion)
    }
    guard archive.days.count <= maximumDayRecordCount,
      archive.days.reduce(0, { $0 + $1.entries.count }) <= maximumEntries
    else { throw AutomaticForumCheckInLedgerError.capacityExceeded }
    if let floor = archive.oldestPermittedDay, dayStart(floor) == nil {
      throw AutomaticForumCheckInLedgerError.corruptedArchive
    }
    var keys = Set<String>()
    for record in archive.days {
      guard record.userID > 0, dayStart(record.day) != nil,
        archive.oldestPermittedDay.map({ record.day >= $0 }) ?? false,
        keys.insert("\(record.userID):\(record.day)").inserted,
        validTimestamp(record.updatedAtMilliseconds), validReason(record.pausedReason),
        record.state == .paused || record.state == .needsReview || record.pausedReason == nil,
        record.state != .completed || record.entries.allSatisfy({ $0.phase == .confirmed })
      else { throw AutomaticForumCheckInLedgerError.corruptedArchive }
      var ids = Set<Int64>()
      for entry in record.entries {
        guard let canonical = try? canonicalTarget(entry.target),
          canonical.forumName.utf8.elementsEqual(entry.forumName.utf8),
          ids.insert(entry.forumID).inserted,
          validTimestamp(entry.createdAtMilliseconds), validTimestamp(entry.updatedAtMilliseconds),
          entry.createdAtMilliseconds <= entry.updatedAtMilliseconds,
          entry.updatedAtMilliseconds <= record.updatedAtMilliseconds,
          entry.isSettled || entry.phase == .outcomeUnknown,
          AutomaticForumCheckInSchedule.dayKey(at: entry.createdAt) == record.day
        else { throw AutomaticForumCheckInLedgerError.corruptedArchive }
      }
    }
  }

  static func sort(_ archive: inout AutomaticForumCheckInLedgerArchive) {
    archive.days.sort { ($0.userID, $0.day) < ($1.userID, $1.day) }
    for index in archive.days.indices {
      archive.days[index].entries.sort { $0.forumID < $1.forumID }
    }
  }

  private static func validatedTargets(_ targets: [ForumBatchCheckInTarget]) throws
    -> [ForumBatchCheckInTarget]
  {
    guard !targets.isEmpty, targets.count <= maximumClaimTargetCount else {
      throw AutomaticForumCheckInLedgerError.invalidTarget
    }
    let canonical = try targets.map(canonicalTarget)
    guard Set(canonical.map(\.forumID)).count == canonical.count else {
      throw AutomaticForumCheckInLedgerError.targetConflict
    }
    return canonical
  }

  private static func validReason(_ reason: String?) -> Bool {
    guard let reason else { return true }
    return !reason.isEmpty && reason.utf8.count <= 512
      && !reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validTimestamp(_ value: Int64) -> Bool {
    abs(Double(value)) <= maximumTimestampMilliseconds
  }

  private static func requireCurrentDay(userID: Int64, day: String, at date: Date) throws {
    try validateKey(userID: userID, day: day)
    guard AutomaticForumCheckInSchedule.dayKey(at: date) == day else {
      throw AutomaticForumCheckInLedgerError.invalidDay
    }
  }

  private static func requiredDay(
    _ archive: AutomaticForumCheckInLedgerArchive, userID: Int64, day: String
  ) throws -> AutomaticForumCheckInDayRecord {
    guard let record = try load(archive, userID: userID, day: day) else {
      throw AutomaticForumCheckInLedgerError.recordNotFound
    }
    return record
  }

  private static func newDay(userID: Int64, day: String, runID: UUID, at date: Date) throws
    -> AutomaticForumCheckInDayRecord
  {
    AutomaticForumCheckInDayRecord(
      userID: userID, day: day, runID: runID, state: .inProgress, pausedReason: nil,
      entries: [], updatedAtMilliseconds: try milliseconds(date)
    )
  }

  private static func entryIndex(
    _ record: AutomaticForumCheckInDayRecord, target: ForumBatchCheckInTarget, runID: UUID?
  ) throws -> Int {
    guard let index = record.entries.firstIndex(where: { $0.forumID == target.forumID }) else {
      throw AutomaticForumCheckInLedgerError.recordNotFound
    }
    guard record.entries[index].forumName == target.forumName else {
      throw AutomaticForumCheckInLedgerError.targetConflict
    }
    if let runID, record.entries[index].runID != runID {
      throw AutomaticForumCheckInLedgerError.operationMismatch
    }
    return index
  }

  private static func replace(
    _ archive: inout AutomaticForumCheckInLedgerArchive, _ record: AutomaticForumCheckInDayRecord
  ) {
    archive.days.removeAll { $0.userID == record.userID && $0.day == record.day }
    archive.days.append(record)
  }

  private static func advanceRetention(
    _ archive: inout AutomaticForumCheckInLedgerArchive, at date: Date
  ) throws {
    guard let currentDay = AutomaticForumCheckInSchedule.dayKey(at: date),
      let currentStart = dayStart(currentDay),
      let floorDate = AutomaticForumCheckInSchedule.calendar.date(
        byAdding: .day, value: -(retainedDayCount - 1), to: currentStart
      ),
      let candidate = AutomaticForumCheckInSchedule.dayKey(at: floorDate)
    else { throw AutomaticForumCheckInLedgerError.invalidDay }
    let floor = max(archive.oldestPermittedDay ?? candidate, candidate)
    archive.oldestPermittedDay = floor
    archive.days.removeAll { $0.day < floor }
  }
}
