import Combine
import Foundation

enum FollowedForumCheckInProjectionState: Equatable, Sendable {
  case idle
  case loading
  case ready
  case signedOut
  case unavailable
}

private struct FollowedForumCheckInProjectionEntry: Equatable, Sendable {
  let normalizedForumName: String
  var status: ForumCheckInCatalogStatus
}

struct FollowedForumCheckInProjectionSnapshot: Equatable, Sendable {
  static let maximumTargetCount = 10_000

  let lease: AccountSessionLease
  let loadedAt: Date
  private var entriesByForumID: [Int64: FollowedForumCheckInProjectionEntry]

  init?(
    catalog: ForumCheckInCatalogData,
    lease: AccountSessionLease,
    loadedAt: Date
  ) {
    guard
      lease.userID > 0,
      catalog.userID == lease.userID,
      catalog.targets.count <= Self.maximumTargetCount,
      loadedAt.timeIntervalSinceReferenceDate.isFinite
    else { return nil }

    var entries = [Int64: FollowedForumCheckInProjectionEntry]()
    entries.reserveCapacity(catalog.targets.count)
    for target in catalog.targets {
      guard
        target.forumID > 0,
        target.level >= 0,
        entries[target.forumID] == nil,
        let normalizedForumName = FollowedForumPin.normalizedForumName(target.forumName)
      else { return nil }
      entries[target.forumID] = FollowedForumCheckInProjectionEntry(
        normalizedForumName: normalizedForumName,
        status: target.status
      )
    }

    self.lease = lease
    self.loadedAt = loadedAt
    entriesByForumID = entries
  }

  func isCheckedIn(_ forum: FollowedForumItem) -> Bool {
    guard
      let normalizedForumName = FollowedForumPin.normalizedForumName(forum.name),
      let entry = entriesByForumID[forum.id]
    else { return false }
    return entry.normalizedForumName == normalizedForumName
      && entry.status == .checkedIn
  }

  mutating func markCheckedIn(forumID: Int64) {
    guard entriesByForumID[forumID] != nil else { return }
    entriesByForumID[forumID]?.status = .checkedIn
  }

  mutating func markCheckedIn(forumIDs: Set<Int64>) {
    for forumID in forumIDs {
      markCheckedIn(forumID: forumID)
    }
  }

  mutating func markCheckedIn(targets: [ForumBatchCheckInTarget]) {
    for target in targets {
      guard
        let normalizedForumName = FollowedForumPin.normalizedForumName(target.forumName),
        let entry = entriesByForumID[target.forumID],
        entry.normalizedForumName == normalizedForumName
      else { continue }
      entriesByForumID[target.forumID]?.status = .checkedIn
    }
  }

  mutating func retainCheckedInStatuses(
    from previous: FollowedForumCheckInProjectionSnapshot
  ) {
    guard previous.lease == lease else { return }
    for (forumID, previousEntry) in previous.entriesByForumID
    where previousEntry.status == .checkedIn {
      guard
        let entry = entriesByForumID[forumID],
        entry.normalizedForumName == previousEntry.normalizedForumName
      else { continue }
      entriesByForumID[forumID]?.status = .checkedIn
    }
  }
}

@MainActor
final class FollowedForumCheckInStore: ObservableObject {
  typealias CatalogLoader = @Sendable (StoredAccountSession) async throws
    -> ForumCheckInCatalogData
  typealias ExpirationSleeper = @Sendable (UInt64) async throws -> Void

  @Published private(set) var state: FollowedForumCheckInProjectionState = .idle
  @Published private(set) var snapshot: FollowedForumCheckInProjectionSnapshot?

  private let vault: any AccountVault
  private let catalogLoader: CatalogLoader
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let expirationSleeper: ExpirationSleeper
  private let minimumForegroundRefreshInterval: TimeInterval
  private var loadTask: Task<Void, Never>?
  private var expirationTask: Task<Void, Never>?
  private var generation = 0
  private var expirationGeneration = 0
  private var requestLease: AccountSessionLease?
  private var lastLoadStartedAt: Date?
  private var confirmedLease: AccountSessionLease?
  private var confirmedAt: Date?
  private var confirmedForumIDs = Set<Int64>()
  private var confirmedTargetNamesByForumID = [Int64: String]()

  init(
    vault: any AccountVault,
    catalogLoader: @escaping CatalogLoader,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = FollowedForumCheckInStore.tiebaCalendar,
    minimumForegroundRefreshInterval: TimeInterval = 300,
    expirationSleeper: @escaping ExpirationSleeper = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.vault = vault
    self.catalogLoader = catalogLoader
    self.now = now
    self.calendar = calendar
    self.minimumForegroundRefreshInterval = minimumForegroundRefreshInterval.isFinite
      ? max(0, minimumForegroundRefreshInterval)
      : 300
    self.expirationSleeper = expirationSleeper
  }

  func loadIfNeeded() {
    discardExpiredProjectionIfNeeded()
    if snapshot != nil { return }
    guard loadTask == nil else { return }
    startLoad()
  }

  func refresh() async {
    discardExpiredProjectionIfNeeded()
    startLoad()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange(loadImmediately: Bool) {
    invalidateLoad()
    clearProjection()
    clearConfirmedCheckIns()
    lastLoadStartedAt = nil
    state = .idle
    if loadImmediately {
      startLoad()
    }
  }

  func forumCheckInDidChange(_ change: ForumCheckInChange) {
    discardExpiredProjectionIfNeeded()
    guard
      change.accountID > 0,
      change.forumID > 0,
      change.consecutiveDays >= 0,
      change.rank >= 0,
      let lease = knownLease,
      lease.userID == change.accountID,
      lease.sessionRevision == change.sessionRevision
    else { return }

    recordConfirmedCheckIn(forumID: change.forumID, lease: lease)
    guard var snapshot, snapshot.lease == lease else { return }
    snapshot.markCheckedIn(forumID: change.forumID)
    publish(snapshot)
  }

  func forumCheckInCatalogDidChange(
    _ change: ForumCheckInCatalogChange,
    loadImmediately: Bool
  ) {
    discardExpiredProjectionIfNeeded()
    guard
      change.accountID > 0,
      let confirmedTargets = normalizedConfirmedTargets(change.confirmedTargets)
    else { return }
    let changedLease = AccountSessionLease(
      userID: change.accountID,
      sessionRevision: change.sessionRevision
    )
    if let knownLease, knownLease != changedLease { return }
    recordConfirmedCheckIns(targets: confirmedTargets, lease: changedLease)

    if var snapshot, snapshot.lease == changedLease {
      snapshot.markCheckedIn(targets: confirmedTargets)
      publish(snapshot)
    }
    if loadImmediately {
      startLoad()
    }
  }

  private func normalizedConfirmedTargets(
    _ targets: [ForumBatchCheckInTarget]
  ) -> [ForumBatchCheckInTarget]? {
    guard
      (1...ForumCheckInCatalogChange.maximumConfirmedTargetCount).contains(targets.count)
    else { return nil }
    var seen = Set<Int64>()
    var normalized = [ForumBatchCheckInTarget]()
    normalized.reserveCapacity(targets.count)
    for target in targets {
      guard
        target.forumID > 0,
        seen.insert(target.forumID).inserted,
        let forumName = FollowedForumPin.normalizedForumName(target.forumName)
      else { return nil }
      normalized.append(
        ForumBatchCheckInTarget(forumID: target.forumID, forumName: forumName)
      )
    }
    return normalized
  }

  func isCheckedInToday(
    _ forum: FollowedForumItem,
    forumLease: FollowedForumsSessionLease?
  ) -> Bool {
    guard
      let forumLease,
      let snapshot,
      snapshot.lease == forumLease,
      calendar.isDate(snapshot.loadedAt, inSameDayAs: now())
    else { return false }
    return snapshot.isCheckedIn(forum)
  }

  func sceneActivityDidChange(isActive: Bool, shouldLoad: Bool) {
    if isActive {
      if shouldLoad {
        discardExpiredProjectionIfNeeded()
        if let snapshot {
          let freshnessAnchor = lastLoadStartedAt.map { max(snapshot.loadedAt, $0) }
            ?? snapshot.loadedAt
          let elapsed = now().timeIntervalSince(freshnessAnchor)
          let isStale = !elapsed.isFinite || elapsed < 0
            || elapsed >= minimumForegroundRefreshInterval
          if isStale {
            startLoad()
          }
        } else {
          loadIfNeeded()
        }
      }
    } else {
      cancel()
    }
  }

  func significantTimeDidChange(shouldLoad: Bool) {
    discardExpiredProjectionIfNeeded()
    if let snapshot {
      scheduleExpiration(for: snapshot)
    } else if shouldLoad {
      loadIfNeeded()
    }
  }

  func cancel() {
    invalidateLoad()
    discardExpiredProjectionIfNeeded()
    state = snapshot == nil ? .idle : .ready
  }

  private var knownLease: AccountSessionLease? {
    requestLease ?? snapshot?.lease
  }

  private func startLoad() {
    invalidateLoad()
    generation &+= 1
    let requestGeneration = generation
    let requestStartedAt = now()
    lastLoadStartedAt = requestStartedAt
    state = .loading
    let vault = vault
    let catalogLoader = catalogLoader
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if requestGeneration == generation {
          requestLease = nil
          loadTask = nil
        }
      }
      do {
        guard let session = try await vault.activeSession() else {
          guard requestGeneration == generation else { return }
          clearProjection()
          clearConfirmedCheckIns()
          state = .signedOut
          return
        }
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        let lease = AccountSessionLease(session)
        requestLease = lease
        retainConfirmedCheckIns(onlyFor: lease, at: requestStartedAt)
        guard session.credentials != nil else {
          clearProjection()
          clearConfirmedCheckIns()
          state = .unavailable
          return
        }

        let catalog = try await catalogLoader(session)
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          resetAfterChangedLease()
          return
        }
        let completedAt = now()
        guard calendar.isDate(requestStartedAt, inSameDayAs: completedAt) else {
          clearProjection()
          requestLease = nil
          retainConfirmedCheckIns(onlyFor: lease, at: completedAt)
          state = .idle
          startLoad()
          return
        }
        guard var loaded = FollowedForumCheckInProjectionSnapshot(
          catalog: catalog,
          lease: lease,
          loadedAt: completedAt
        ) else {
          finishUnavailable(lease: lease)
          return
        }
        if let snapshot, snapshot.lease == lease,
          calendar.isDate(snapshot.loadedAt, inSameDayAs: loaded.loadedAt)
        {
          loaded.retainCheckedInStatuses(from: snapshot)
        }
        if confirmedLease == lease,
          let confirmedAt,
          calendar.isDate(confirmedAt, inSameDayAs: loaded.loadedAt)
        {
          loaded.markCheckedIn(forumIDs: confirmedForumIDs)
          loaded.markCheckedIn(
            targets: confirmedTargetNamesByForumID.map {
              ForumBatchCheckInTarget(forumID: $0.key, forumName: $0.value)
            }
          )
        }
        publish(loaded)
        state = snapshot == nil ? .idle : .ready
      } catch is CancellationError {
        return
      } catch {
        guard requestGeneration == generation else { return }
        finishUnavailable(lease: requestLease)
      }
    }
  }

  private func finishUnavailable(lease: AccountSessionLease?) {
    if
      let lease,
      let snapshot,
      snapshot.lease == lease,
      calendar.isDate(snapshot.loadedAt, inSameDayAs: now())
    {
      state = .ready
    } else {
      clearProjection()
      state = .unavailable
    }
  }

  private func resetAfterChangedLease() {
    clearProjection()
    requestLease = nil
    clearConfirmedCheckIns()
    lastLoadStartedAt = nil
    state = .idle
  }

  private func recordConfirmedCheckIn(forumID: Int64, lease: AccountSessionLease) {
    let date = now()
    retainConfirmedCheckIns(onlyFor: lease, at: date)
    confirmedLease = lease
    confirmedAt = date
    confirmedForumIDs.insert(forumID)
  }

  private func recordConfirmedCheckIns(
    targets: [ForumBatchCheckInTarget],
    lease: AccountSessionLease
  ) {
    let date = now()
    retainConfirmedCheckIns(onlyFor: lease, at: date)
    confirmedLease = lease
    confirmedAt = date
    for target in targets {
      confirmedTargetNamesByForumID[target.forumID] = target.forumName
    }
  }

  private func retainConfirmedCheckIns(onlyFor lease: AccountSessionLease, at date: Date) {
    guard
      confirmedLease == lease,
      let confirmedAt,
      calendar.isDate(confirmedAt, inSameDayAs: date)
    else {
      clearConfirmedCheckIns()
      return
    }
  }

  private func discardExpiredProjectionIfNeeded() {
    let date = now()
    if let snapshot, !calendar.isDate(snapshot.loadedAt, inSameDayAs: date) {
      clearProjection()
      if state == .ready { state = .idle }
    }
    if let confirmedAt, !calendar.isDate(confirmedAt, inSameDayAs: date) {
      clearConfirmedCheckIns()
    }
  }

  private func clearConfirmedCheckIns() {
    confirmedLease = nil
    confirmedAt = nil
    confirmedForumIDs = []
    confirmedTargetNamesByForumID = [:]
  }

  private func publish(_ snapshot: FollowedForumCheckInProjectionSnapshot) {
    self.snapshot = snapshot
    scheduleExpiration(for: snapshot)
  }

  private func clearProjection() {
    expirationGeneration &+= 1
    expirationTask?.cancel()
    expirationTask = nil
    snapshot = nil
  }

  private func scheduleExpiration(
    for expectedSnapshot: FollowedForumCheckInProjectionSnapshot
  ) {
    expirationGeneration &+= 1
    let expectedExpirationGeneration = expirationGeneration
    expirationTask?.cancel()
    expirationTask = nil
    let startOfDay = calendar.startOfDay(for: expectedSnapshot.loadedAt)
    guard
      let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
    else { return }
    let delay = nextDay.timeIntervalSince(now())
    guard delay.isFinite, delay > 0 else {
      clearProjection()
      clearConfirmedCheckIns()
      if state == .ready { state = .idle }
      return
    }
    let nanoseconds = UInt64(min(delay, 172_800) * 1_000_000_000)
    let expirationSleeper = expirationSleeper
    expirationTask = Task { [weak self] in
      do {
        try await expirationSleeper(nanoseconds)
      } catch {
        return
      }
      guard
        let self,
        self.expirationGeneration == expectedExpirationGeneration,
        self.snapshot?.lease == expectedSnapshot.lease,
        self.snapshot?.loadedAt == expectedSnapshot.loadedAt
      else { return }
      self.expirationTask = nil
      self.discardExpiredProjectionIfNeeded()
      if let snapshot = self.snapshot,
        snapshot.lease == expectedSnapshot.lease,
        snapshot.loadedAt == expectedSnapshot.loadedAt
      {
        self.scheduleExpiration(for: snapshot)
      }
    }
  }

  private func invalidateLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    requestLease = nil
  }

  private static var tiebaCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    return calendar
  }
}
