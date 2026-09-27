import Foundation

struct InboxNotificationSnapshot: Codable, Equatable, Sendable {
  let version: Int
  let userID: Int64
  let sessionRevision: UUID
  var replies: Int
  var mentions: Int

  init(
    userID: Int64, sessionRevision: UUID, replies: Int, mentions: Int, version: Int = 1
  ) {
    self.version = version
    self.userID = userID
    self.sessionRevision = sessionRevision
    self.replies = replies
    self.mentions = mentions
  }

  var isValid: Bool {
    version == 1 && userID > 0 && Self.validCount(replies) && Self.validCount(mentions)
  }

  fileprivate static func validCount(_ value: Int) -> Bool {
    (0...Int(Int32.max)).contains(value)
  }

  fileprivate func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }

  fileprivate subscript(_ kind: InboxKind) -> Int {
    get { kind == .replies ? replies : mentions }
    set {
      if kind == .replies { replies = newValue } else { mentions = newValue }
    }
  }
}

@MainActor
protocol InboxNotificationStateStoring {
  func load() throws -> InboxNotificationSnapshot?
  func save(_ snapshot: InboxNotificationSnapshot?) throws
}

@MainActor
protocol InboxNotificationDelivering {
  func isAuthorized() async -> Bool
  func deliver(kind: InboxKind, count: Int, totalCount: Int, sessionRevision: UUID) async throws
  func clear(kind: InboxKind)
  func clearAll()
  func setBadgeCount(_ count: Int)
}

/// Owns only aggregate unread counts. It never fetches message bodies or writes read receipts.
@MainActor
final class InboxNotificationCoordinator {
  enum Outcome: Equatable {
    case disabled, busy, notAuthorized, noAccount, invalidResponse, failed, cancelled
    case baselineEstablished, refreshed, foregroundObserved
  }

  private(set) var lastOutcome: Outcome = .disabled
  private(set) var isEnabled = false
  private(set) var isRunning = false

  private let service: any AccountService
  private let vault: any AccountVault
  private let store: any InboxNotificationStateStoring
  private let delivery: any InboxNotificationDelivering
  private var generation = 0
  private var needsBaselineReset = false
  private var desiredBadgeCount = 0

  init(
    service: any AccountService,
    vault: any AccountVault,
    store: any InboxNotificationStateStoring,
    delivery: any InboxNotificationDelivering
  ) {
    self.service = service
    self.vault = vault
    self.store = store
    self.delivery = delivery
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    if !enabled {
      invalidateBaseline()
      lastOutcome = .disabled
    }
  }

  func accountSessionDidChange() {
    invalidateBaseline()
  }

  /// Invalidates a suspended read or delivery without discarding the last confirmed counts.
  /// The owner also cancels its task so URLSession can stop promptly on BG expiration.
  func cancelRefresh() {
    generation &+= 1
    clearDeliveredNotifications()
    lastOutcome = .cancelled
  }

  /// Runs in the caller's task: expiration cancellation reaches the actual service request.
  /// Keep the gate held even when an uncooperative dependency ignores cancellation. Otherwise
  /// its eventual notification completion could clear a newer run's fixed notification IDs.
  func runRefresh() async -> Bool {
    guard isEnabled else { lastOutcome = .disabled; return false }
    guard !isRunning else { lastOutcome = .busy; return false }
    let requestGeneration = generation
    isRunning = true
    var pendingDelivery: InboxKind?
    defer {
      if let pendingDelivery {
        delivery.clear(kind: pendingDelivery)
        delivery.setBadgeCount(desiredBadgeCount)
      }
      if Task.isCancelled || generation != requestGeneration {
        clearDeliveredNotifications()
      }
      isRunning = false
    }

    do {
      try requireCurrent(requestGeneration)
      let authorized = await delivery.isAuthorized()
      try requireCurrent(requestGeneration)
      guard authorized else { lastOutcome = .notAuthorized; return false }

      guard let session = try await vault.activeSession() else {
        try requireCurrent(requestGeneration)
        invalidateBaseline()
        lastOutcome = .noAccount
        return false
      }
      try requireCurrent(requestGeneration)
      guard session.id > 0, AccountCredentialFormat.isValidBDUSS(session.bduss) else {
        lastOutcome = .failed
        return false
      }
      if needsBaselineReset {
        try store.save(nil)
        needsBaselineReset = false
      }
      let stored = try store.load()
      let baseline = stored.flatMap { $0.isValid && $0.matches(session) ? $0 : nil }
      if let baseline { desiredBadgeCount = baseline.replies + baseline.mentions }
      if stored != nil && baseline == nil {
        desiredBadgeCount = 0
        clearDeliveredNotifications()
      }

      // Exactly one bounded, read-only server request per refresh.
      let summary = try await service.inboxUnreadSummary(session: session)
      try await requireSession(session, generation: requestGeneration)
      guard Self.valid(summary, userID: session.id) else {
        lastOutcome = .invalidResponse
        return false
      }
      let current = InboxNotificationSnapshot(
        userID: session.id, sessionRevision: session.sessionRevision,
        replies: summary.replyCount, mentions: summary.mentionCount
      )

      guard var persisted = baseline else {
        // Opting in or changing accounts must not announce an existing backlog as new.
        try store.save(current)
        desiredBadgeCount = summary.totalCount
        clearDeliveredNotifications()
        lastOutcome = .baselineEstablished
        return true
      }

      for kind in InboxKind.allCases {
        try requireCurrent(requestGeneration)
        if current[kind] > persisted[kind] {
          let stillAuthorized = await delivery.isAuthorized()
          try requireCurrent(requestGeneration)
          guard stillAuthorized else { lastOutcome = .notAuthorized; return false }
          try await requireSession(session, generation: requestGeneration)
          // A writable baseline is required before a side effect; this also catches storage
          // protection failures without creating an alert we cannot deduplicate on relaunch.
          try store.save(persisted)
          pendingDelivery = kind
          try await delivery.deliver(
            kind: kind, count: current[kind], totalCount: summary.totalCount,
            sessionRevision: session.sessionRevision
          )
          try await requireSession(session, generation: requestGeneration)
        }
        if current[kind] < persisted[kind] { delivery.clear(kind: kind) }
        if current[kind] != persisted[kind] {
          persisted[kind] = current[kind]
          // Commit each delivered channel separately: failure of the second channel must
          // not cause the already delivered first channel to be announced again on retry.
          do { try store.save(persisted) } catch {
            delivery.clear(kind: kind)
            throw error
          }
          desiredBadgeCount = persisted.replies + persisted.mentions
        }
        pendingDelivery = nil
        if current[kind] == 0 { delivery.clear(kind: kind) }
      }
      desiredBadgeCount = summary.totalCount
      delivery.setBadgeCount(desiredBadgeCount)
      lastOutcome = .refreshed
      return true
    } catch is CancellationError {
      if generation == requestGeneration { lastOutcome = .cancelled }
      return false
    } catch {
      if generation == requestGeneration {
        lastOutcome = Task.isCancelled ? .cancelled : .failed
      }
      return false
    }
  }

  /// The foreground model supplies its already verified summary and credential revision.
  /// Revalidate attribution after the actor hop before replacing the persistent baseline.
  func observeForeground(summary: InboxUnreadSummary, sessionRevision: UUID) async {
    guard isEnabled, !Task.isCancelled else { return }
    // Assign ordering before the vault await: only the newest foreground observation can
    // commit, even if a prior vault read returns later than a newer one.
    generation &+= 1
    let observedGeneration = generation
    do {
      guard let session = try await vault.activeSession() else { return }
      try requireCurrent(observedGeneration)
      guard session.sessionRevision == sessionRevision,
        AccountCredentialFormat.isValidBDUSS(session.bduss),
        Self.valid(summary, userID: session.id)
      else { return }
      // The old BG operation remains serialized until its eventual completion. Its cleanup
      // restores this foreground badge instead of publishing or erasing stale account data.
      clearDeliveredNotifications()
      try store.save(InboxNotificationSnapshot(
        userID: session.id, sessionRevision: sessionRevision,
        replies: summary.replyCount, mentions: summary.mentionCount
      ))
      needsBaselineReset = false
      desiredBadgeCount = summary.totalCount
      delivery.setBadgeCount(desiredBadgeCount)
      lastOutcome = .foregroundObserved
    } catch {
      if generation == observedGeneration {
        lastOutcome = .failed
      }
    }
  }

  private func requireCurrent(_ requestGeneration: Int) throws {
    try Task.checkCancellation()
    guard isEnabled, generation == requestGeneration else { throw CancellationError() }
  }

  private func requireSession(_ expected: StoredAccountSession, generation: Int) async throws {
    try requireCurrent(generation)
    let current = try await vault.activeSession()
    try requireCurrent(generation)
    guard let current, current.id == expected.id,
      current.sessionRevision == expected.sessionRevision
    else {
      invalidateBaseline()
      throw CancellationError()
    }
  }

  private func invalidateBaseline() {
    generation &+= 1
    desiredBadgeCount = 0
    clearDeliveredNotifications()
    needsBaselineReset = true
    do {
      try store.save(nil)
      needsBaselineReset = false
    } catch {
      // Never reload an old baseline after a failed deletion. Retry deletion before reading.
      lastOutcome = .failed
    }
  }

  private func clearDeliveredNotifications() {
    delivery.clearAll()
    delivery.setBadgeCount(desiredBadgeCount)
  }

  private static func valid(_ summary: InboxUnreadSummary, userID: Int64) -> Bool {
    userID > 0 && summary.userID == userID
      && InboxNotificationSnapshot.validCount(summary.replyCount)
      && InboxNotificationSnapshot.validCount(summary.mentionCount)
  }
}
