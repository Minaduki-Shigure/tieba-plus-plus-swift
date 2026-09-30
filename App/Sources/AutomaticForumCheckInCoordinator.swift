import Combine
import Foundation

/// One application-wide execution owner. Scheduling decides when to call this;
/// this boundary owns account attribution, durable dispatch claims and recovery.
@MainActor
final class AutomaticForumCheckInCoordinator: ObservableObject {
  enum Outcome: Equatable, Sendable {
    case finishedForToday, needsResume, needsReview, notStarted
  }

  @Published private(set) var isRunning = false
  @Published private(set) var statusMessage = "尚未执行自动签到。"
  @Published private(set) var summary: ForumBatchCheckInSummary?
  @Published private(set) var entries: [ForumBatchCheckInEntry] = []
  @Published private(set) var resultDay: String?

  private let access: AccountAccess
  private let journal: any AutomaticForumCheckInLedgerRepository
  private let now: @MainActor () -> Date
  private let interRequestDelay: @Sendable (ForumBatchCheckInDelayMode) async -> Void
  private var generation = 0
  private var worker: ForumBatchCheckInViewModel?
  private var observation: AnyCancellable?

  init(
    access: AccountAccess,
    journal: any AutomaticForumCheckInLedgerRepository,
    now: @escaping @MainActor () -> Date = Date.init,
    interRequestDelay: @escaping @Sendable (ForumBatchCheckInDelayMode) async -> Void = { mode in
      let milliseconds = UInt64.random(in: mode.delayMillisecondsRange)
      try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
  ) {
    self.access = access
    self.journal = journal
    self.now = now
    self.interRequestDelay = interRequestDelay
  }

  func run(
    policy: ForumBatchCheckInExecutionPolicy,
    authorization: @escaping @MainActor () -> Bool
  ) async -> Outcome {
    await perform(policy: policy, authorization: authorization)
  }

  /// Explicit inspection is always read-only, even when it resolves every unknown.
  func reconcile(
    authorization: @escaping @MainActor () -> Bool = { true }
  ) async -> Outcome {
    await perform(policy: nil, authorization: authorization)
  }

  func cancel() {
    generation &+= 1
    worker?.requestStop()
    if isRunning { statusMessage = "已停止后续签到，正在保留已发出请求的结果。" }
    // Keep the execution gate until the old request and its durable settlement
    // finish, including dependencies that ignore task cancellation.
  }

  func accountSessionDidChange() {
    cancel()
    entries = []
    summary = nil
    resultDay = nil
    statusMessage = "账户已变化，将按当前账户重新检查自动签到。"
  }

  private func perform(
    policy: ForumBatchCheckInExecutionPolicy?,
    authorization: @escaping @MainActor () -> Bool
  ) async -> Outcome {
    guard !isRunning else { return .needsResume }
    guard authorization(), !Task.isCancelled,
      let day = AutomaticForumCheckInSchedule.dayKey(at: now())
    else { return .notStarted }
    isRunning = true
    entries = []
    summary = nil
    resultDay = day
    let runGeneration = generation
    let runID = UUID()
    defer {
      observation = nil
      worker = nil
      isRunning = false
    }

    do {
      let availableSession: StoredAccountSession?
      do {
        availableSession = try await access.vault.activeSession()
      } catch {
        if generation == runGeneration { statusMessage = "暂时无法读取账户，请解锁后再试。" }
        return .needsResume
      }
      guard let session = availableSession, session.id > 0,
        session.credentials != nil
      else {
        if generation == runGeneration { statusMessage = "请先登录后再自动签到。" }
        return .notStarted
      }
      try await requireCurrent(
        session: session, day: day, generation: runGeneration, authorization: authorization
      )
      var record = try await journal.load(userID: session.id, day: day)
      try await requireCurrent(
        session: session, day: day, generation: runGeneration, authorization: authorization
      )
      if let record { publish(record: record) }
      if record?.state == .completed {
        statusMessage = "该日的自动签到已完成。"
        return .finishedForToday
      }

      if let prior = record, prior.entries.contains(where: { $0.phase == .outcomeUnknown }) {
        statusMessage = "正在只读核对先前未确认的签到结果。"
        for entry in prior.entries where entry.phase == .outcomeUnknown {
          try await requireCurrent(
            session: session, day: day, generation: runGeneration, authorization: authorization
          )
          do {
            let state = try await access.service.forumAccountState(
              session: session, forumID: entry.target.forumID, forumName: entry.target.forumName
            )
            try await requireCurrent(
              session: session, day: day, generation: runGeneration, authorization: authorization
            )
            if Self.isConfirmed(state, session: session, target: entry.target) {
              record = try await journal.confirmReadBack(
                userID: session.id, day: day, targets: [entry.target], at: now()
              )
            }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // A failed read, unsigned response or unrelated identity cannot clear
            // a dispatch claim or permit another write to this target today.
          }
        }
        record = try await journal.load(userID: session.id, day: day)
        try await requireCurrent(
          session: session, day: day, generation: runGeneration, authorization: authorization
        )
        if let record { publish(record: record) }
      }

      if let record,
        record.state == .paused || record.entries.contains(where: { $0.phase != .confirmed })
      {
        statusMessage = record.pausedReason ?? "部分签到失败或结果待确认，该日不会自动重发。"
        return .needsReview
      }
      guard let policy else {
        statusMessage = "已完成只读核对；尚未派发的贴吧会在下次自动运行时继续。"
        return .needsResume
      }

      let historical = record
      let hooks = makeHooks(
        session: session, day: day, runID: runID, generation: runGeneration,
        authorization: authorization
      )
      let model = ForumBatchCheckInViewModel(
        access: access,
        executionHooks: hooks,
        excludedAutomaticTargetIDs: Set(record?.entries.map { $0.target.forumID } ?? []),
        interRequestDelay: interRequestDelay
      )
      worker = model
      observation = Publishers.CombineLatest(model.$entries, model.$state).sink {
        [weak self] currentEntries, currentState in
        guard let self, generation == runGeneration else { return }
        guard AutomaticForumCheckInSchedule.dayKey(at: now()) == day else {
          entries = []
          summary = nil
          return
        }
        publish(record: historical, currentEntries: currentEntries, state: currentState)
      }
      statusMessage = "正在读取当前账户的签到列表。"
      await model.reload()
      try await requireCurrent(
        session: session, day: day, generation: runGeneration, authorization: authorization
      )
      guard case .ready = model.state, let catalog = model.loadedCatalog else {
        statusMessage = model.errorMessage ?? "暂时无法读取签到列表，将在下次机会重试读取。"
        return .needsResume
      }
      // An ID must never be silently rebound to a different forum name while
      // excluding previously dispatched targets from a newly fetched catalog.
      if let record {
        let names = Dictionary(
          uniqueKeysWithValues: catalog.targets.map { ($0.forumID, $0.forumName) })
        guard
          record.entries.allSatisfy({ entry in
            guard let name = names[entry.target.forumID] else { return true }
            return name == entry.target.forumName
          })
        else {
          _ = try await journal.finishDay(
            userID: session.id, day: day, runID: runID, state: .paused,
            pausedReason: "签到列表中的贴吧身份发生变化，请手动检查。", at: now()
          )
          statusMessage = "签到列表中的贴吧身份发生变化，自动签到已暂停。"
          return .needsReview
        }
      }

      // Unattended runs always stop at the first failure, including risk-control
      // responses. Manual confirmation retains the user's original preference.
      let automaticPolicy = ForumBatchCheckInExecutionPolicy(
        delayMode: policy.delayMode, usesOfficialBatch: policy.usesOfficialBatch,
        stopsAfterSingleFailure: true
      )
      model.requestStartConfirmation(policy: automaticPolicy)
      if model.pendingConfirmation != nil {
        statusMessage = "正在自动签到。"
        await model.confirmStart()
      }
      record = try await journal.load(userID: session.id, day: day)
      // Settlement has already happened inside hooks, even if this run's UI has
      // been invalidated by account switching, cancellation or midnight.
      guard generation == runGeneration, authorization(), !Task.isCancelled,
        AutomaticForumCheckInSchedule.dayKey(at: now()) == day
      else { return .needsResume }
      try await requireCurrent(
        session: session, day: day, generation: runGeneration, authorization: authorization
      )
      if let observed = record,
        observed.state == .paused || observed.entries.contains(where: { $0.phase != .confirmed })
      {
        let paused = observed.state == .paused || observed.entries.contains { $0.phase == .failed }
        record = try await journal.finishDay(
          userID: session.id, day: day, runID: runID,
          state: paused ? .paused : .needsReview,
          pausedReason: paused
            ? observed.pausedReason ?? "有贴吧未签到成功，该日已停止自动签到。" : nil, at: now()
        )
        publish(record: record, currentEntries: model.entries, state: model.state)
        statusMessage =
          paused
          ? "有贴吧未签到成功，该日已停止自动签到。"
          : "部分请求结果待确认，已停止后续签到且不会自动重发。"
        return .needsReview
      }
      if case .needsReview = model.state {
        statusMessage = model.errorMessage ?? "自动签到需要检查，未继续发送请求。"
        return .needsReview
      }
      let hasUnstarted = model.entries.contains {
        $0.outcome == .pending || $0.outcome == .inProgress || $0.outcome == .stopped
      }
      record = try await journal.finishDay(
        userID: session.id, day: day, runID: runID,
        state: hasUnstarted ? .inProgress : .completed, pausedReason: nil, at: now()
      )
      publish(record: record, currentEntries: model.entries, state: model.state)
      statusMessage =
        hasUnstarted
        ? "已保存签到进度，下次机会继续尚未派发的贴吧。"
        : "该日的自动签到已完成。"
      return hasUnstarted ? .needsResume : .finishedForToday
    } catch is CancellationError {
      if generation == runGeneration { statusMessage = "自动签到已暂停，已派发的请求不会重复发送。" }
      return .needsResume
    } catch AutomaticForumCheckInLedgerError.authenticationUnavailable {
      if generation == runGeneration {
        statusMessage = "签到记录暂时不可读取，请解锁后再试。"
      }
      return .needsResume
    } catch {
      if generation == runGeneration {
        statusMessage = "无法安全读取或保存自动签到记录，已停止自动签到。"
      }
      return .needsReview
    }
  }

  private func makeHooks(
    session: StoredAccountSession,
    day: String,
    runID: UUID,
    generation runGeneration: Int,
    authorization: @escaping @MainActor () -> Bool
  ) -> ForumBatchCheckInExecutionHooks {
    let journal = journal
    return ForumBatchCheckInExecutionHooks(
      allowsContinuation: { [self] in
        generation == runGeneration && authorization() && !Task.isCancelled
          && AutomaticForumCheckInSchedule.dayKey(at: now()) == day
      },
      beforeDispatch: { [self] supplied, targets in
        guard Self.sameSession(supplied, session) else { throw CancellationError() }
        try await requireCurrent(
          session: session, day: day, generation: runGeneration, authorization: authorization
        )
        _ = try await journal.claimTargets(
          userID: session.id, day: day, runID: runID, targets: targets, at: now()
        )
        do {
          try await requireCurrent(
            session: session, day: day, generation: runGeneration, authorization: authorization
          )
        } catch {
          _ = try await Task { @MainActor [self] in
            try await journal.releaseUndispatchedTargets(
              userID: session.id, day: day, runID: runID, targets: targets, at: now()
            )
          }.value
          throw error
        }
      },
      releaseUndispatched: { [self] supplied, targets in
        guard Self.sameSession(supplied, session) else { throw CancellationError() }
        _ = try await Task { @MainActor [self] in
          try await journal.releaseUndispatchedTargets(
            userID: session.id, day: day, runID: runID, targets: targets, at: now()
          )
        }.value
      },
      settleBatch: { [self] supplied, targets, result in
        guard Self.sameSession(supplied, session) else { throw CancellationError() }
        // Cancellation stops dispatch; it must not abort saving an already
        // received result while waiting for the journal's cross-process lock.
        try await Task { @MainActor [self] in
          try await settleBatch(result, targets: targets, session: session, day: day, runID: runID)
        }.value
      },
      settleSingle: { [self] supplied, target, result in
        guard Self.sameSession(supplied, session) else { throw CancellationError() }
        let phase: AutomaticForumCheckInTargetPhase
        if case .success(let state) = result,
          Self.matches(state, session: session, target: target), let checkIn = state.checkIn
        {
          phase = checkIn.isCheckedIn ? .confirmed : .failed
        } else {
          phase = .outcomeUnknown
        }
        _ = try await Task { @MainActor [self] in
          try await journal.settleResults(
            userID: session.id, day: day, runID: runID,
            results: [.init(target: target, phase: phase)], at: now()
          )
        }.value
      },
      observeReadback: { [self] supplied, target, state in
        guard Self.sameSession(supplied, session),
          AutomaticForumCheckInSchedule.dayKey(at: now()) == day,
          Self.isConfirmed(state, session: session, target: target)
        else { return }
        _ = try await Task { @MainActor [self] in
          try await journal.confirmReadBack(
            userID: session.id, day: day, targets: [target], at: now()
          )
        }.value
      }
    )
  }

  private func settleBatch(
    _ result: Result<ForumBatchCheckInData, Error>,
    targets: [ForumBatchCheckInTarget],
    session: StoredAccountSession,
    day: String,
    runID: UUID
  ) async throws {
    let authorized = Dictionary(uniqueKeysWithValues: targets.map { ($0.forumID, $0) })
    switch result {
    case .success(let data):
      var seen = Set<Int64>()
      guard data.userID == session.id, data.results.count <= 100,
        data.results.allSatisfy({ item in
          seen.insert(item.forumID).inserted
            && authorized[item.forumID]?.forumName == Self.canonicalName(item.forumName)
        })
      else {
        try await settleUnknown(targets, session: session, day: day, runID: runID)
        return
      }
      let results = data.results.map { item in
        AutomaticForumCheckInTargetResult(
          target: authorized[item.forumID]!,
          phase: item.outcome == .confirmedSigned ? .confirmed : .failed
        )
      }
      if !results.isEmpty {
        _ = try await journal.settleResults(
          userID: session.id, day: day, runID: runID, results: results, at: now()
        )
      }
      let unstarted = targets.filter { !seen.contains($0.forumID) }
      if !unstarted.isEmpty {
        _ = try await journal.releaseUndispatchedTargets(
          userID: session.id, day: day, runID: runID, targets: unstarted, at: now()
        )
      }
    case .failure(ForumBatchCheckInError.outcomeUnknown(let dispatched)):
      var seen = Set<Int64>()
      guard !dispatched.isEmpty, dispatched.count <= 100,
        dispatched.allSatisfy({ target in
          seen.insert(target.forumID).inserted
            && authorized[target.forumID]?.forumName == Self.canonicalName(target.forumName)
        })
      else {
        try await settleUnknown(targets, session: session, day: day, runID: runID)
        return
      }
      try await settleUnknown(
        targets.filter { seen.contains($0.forumID) }, session: session, day: day, runID: runID
      )
      let unstarted = targets.filter { !seen.contains($0.forumID) }
      if !unstarted.isEmpty {
        _ = try await journal.releaseUndispatchedTargets(
          userID: session.id, day: day, runID: runID, targets: unstarted, at: now()
        )
      }
    case .failure(ForumBatchCheckInError.authorizationChanged):
      _ = try await journal.releaseUndispatchedTargets(
        userID: session.id, day: day, runID: runID, targets: targets, at: now()
      )
      _ = try await journal.finishDay(
        userID: session.id, day: day, runID: runID, state: .paused,
        pausedReason: "签到目标的授权已变化，请手动检查。", at: now()
      )
    case .failure:
      try await settleUnknown(targets, session: session, day: day, runID: runID)
    }
  }

  private func settleUnknown(
    _ targets: [ForumBatchCheckInTarget], session: StoredAccountSession, day: String, runID: UUID
  ) async throws {
    _ = try await journal.settleResults(
      userID: session.id, day: day, runID: runID,
      results: targets.map { .init(target: $0, phase: .outcomeUnknown) }, at: now()
    )
  }

  private func requireCurrent(
    session: StoredAccountSession, day: String, generation expectedGeneration: Int,
    authorization: @MainActor () -> Bool
  ) async throws {
    try Task.checkCancellation()
    guard generation == expectedGeneration, authorization(),
      AutomaticForumCheckInSchedule.dayKey(at: now()) == day
    else { throw CancellationError() }
    let currentSession: StoredAccountSession?
    do { currentSession = try await access.vault.activeSession() } catch {
      throw CancellationError()
    }
    guard let current = currentSession, Self.sameSession(current, session)
    else { throw CancellationError() }
    try Task.checkCancellation()
    guard generation == expectedGeneration, authorization(),
      AutomaticForumCheckInSchedule.dayKey(at: now()) == day
    else { throw CancellationError() }
  }

  private static func sameSession(_ lhs: StoredAccountSession, _ rhs: StoredAccountSession) -> Bool
  {
    lhs.id == rhs.id && lhs.sessionRevision == rhs.sessionRevision
  }

  private static func canonicalName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
  }

  private static func matches(
    _ state: ForumAccountStateData, session: StoredAccountSession, target: ForumBatchCheckInTarget
  ) -> Bool {
    state.membership.userID == session.id && state.membership.forumID == target.forumID
      && canonicalName(state.membership.forumName) == target.forumName
      && state.membership.isFollowed
  }

  private static func isConfirmed(
    _ state: ForumAccountStateData, session: StoredAccountSession, target: ForumBatchCheckInTarget
  ) -> Bool {
    matches(state, session: session, target: target) && state.checkIn?.isCheckedIn == true
  }

  private func publish(
    record: AutomaticForumCheckInDayRecord?,
    currentEntries: [ForumBatchCheckInEntry] = [],
    state: ForumBatchCheckInState? = nil
  ) {
    let historical = record?.entries ?? []
    let historicalIDs = Set(historical.map { $0.target.forumID })
    let historicRows = historical.map { entry -> ForumBatchCheckInEntry in
      let outcome: ForumBatchCheckInEntryOutcome =
        switch entry.phase {
        case .confirmed: .succeeded
        case .failed: .failed(message: "该日的自动签到未成功，未自动重试。")
        case .outcomeUnknown: .unconfirmed(message: "先前请求结果待确认，未自动重试。")
        }
      return ForumBatchCheckInEntry(
        id: entry.target.forumID, forumName: entry.target.forumName, level: 0, outcome: outcome
      )
    }
    entries = historicRows + currentEntries.filter { !historicalIDs.contains($0.id) }
    var total = entries.count
    var eligible = 0
    if let state {
      switch state {
      case .ready(let value), .completed(let value), .needsReview(let value):
        total = max(total, value.total)
        eligible = value.eligible
      case .failed(let value):
        total = max(total, value?.total ?? 0)
        eligible = value?.eligible ?? 0
      default: break
      }
    }
    var succeeded = 0
    var failed = 0
    var unconfirmed = 0
    var skipped = 0
    var stopped = 0
    var pending = 0
    for entry in entries {
      switch entry.outcome {
      case .succeeded: succeeded += 1
      case .failed: failed += 1
      case .unconfirmed: unconfirmed += 1
      case .skipped: skipped += 1
      case .stopped: stopped += 1
      case .pending, .inProgress: pending += 1
      }
    }
    summary = ForumBatchCheckInSummary(
      total: total, eligible: eligible, pending: pending,
      processed: succeeded + failed + unconfirmed, succeeded: succeeded, failed: failed,
      unconfirmed: unconfirmed, skipped: skipped, stopped: stopped
    )
  }
}
