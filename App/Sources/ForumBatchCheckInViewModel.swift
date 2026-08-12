import Combine
import Foundation

enum ForumBatchCheckInEntryOutcome: Equatable, Sendable {
  case pending
  case inProgress
  case succeeded
  case failed(message: String)
  case skipped(message: String)
  case stopped
}

struct ForumBatchCheckInEntry: Equatable, Identifiable, Sendable {
  let id: Int64
  let forumName: String
  let level: Int
  var outcome: ForumBatchCheckInEntryOutcome
}

struct ForumBatchCheckInSummary: Equatable, Sendable {
  let total: Int
  let eligible: Int
  let pending: Int
  let processed: Int
  let succeeded: Int
  let failed: Int
  let skipped: Int
  let stopped: Int
}

struct ForumBatchCheckInProgress: Equatable, Sendable {
  let total: Int
  let pending: Int
  let processed: Int
  let succeeded: Int
  let failed: Int
  let skipped: Int
  let stopped: Int
  let currentForumName: String?
}

struct ForumBatchCheckInConfirmation: Equatable, Sendable {
  let targetCount: Int
  let officialBatchEligibleCount: Int
  let minimumOfficialLevel: Int?
  let maximumOfficialCount: Int?
}

enum ForumBatchCheckInState: Equatable, Sendable {
  case idle
  case signedOut
  case loading
  case ready(summary: ForumBatchCheckInSummary)
  case running(progress: ForumBatchCheckInProgress)
  case stopping(progress: ForumBatchCheckInProgress)
  case completed(summary: ForumBatchCheckInSummary)
  case failed(summary: ForumBatchCheckInSummary?)
}

@MainActor
final class ForumBatchCheckInViewModel: ObservableObject {
  private static let maximumForumNameUTF8ByteCount = 1_024
  private static let maximumOfficialBatchCount = 100

  @Published private(set) var state: ForumBatchCheckInState = .idle
  @Published private(set) var pendingConfirmation: ForumBatchCheckInConfirmation?
  @Published private(set) var entries: [ForumBatchCheckInEntry] = []
  @Published private(set) var errorMessage: String?

  private let access: AccountAccess
  private let interRequestDelay: @Sendable () async -> Void
  private var catalog: ForumCheckInCatalogData?
  private var currentLease: ForumBatchCheckInSessionLease?
  private var operation: ForumBatchCheckInOperation?
  private var generation = 0

  init(
    access: AccountAccess,
    interRequestDelay: @escaping @Sendable () async -> Void = {
      try? await Task.sleep(nanoseconds: 4_000_000_000)
    }
  ) {
    self.access = access
    self.interRequestDelay = interRequestDelay
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    default:
      return
    }
  }

  func reload() async {
    guard operation == nil else { return }
    generation &+= 1
    let requestGeneration = generation
    pendingConfirmation = nil
    currentLease = nil
    catalog = nil
    entries = []
    errorMessage = nil
    state = .loading

    do {
      guard let session = try await access.vault.activeSession() else {
        guard requestGeneration == generation else { return }
        state = .signedOut
        return
      }
      let lease = ForumBatchCheckInSessionLease(session)
      let loaded = try await access.service.checkInCatalog(session: session)
      let normalized = try normalizedCatalog(loaded, lease: lease)
      guard requestGeneration == generation else { return }
      switch await leaseState(lease) {
      case .current:
        catalog = normalized
        currentLease = lease
        entries = normalized.targets.compactMap { target in
          if target.status == .checkedIn { return nil }
          if target.isForbidden {
            return ForumBatchCheckInEntry(
              id: target.forumID,
              forumName: target.forumName,
              level: target.level,
              outcome: .skipped(message: "贴吧标记该目标禁止签到，已跳过。")
            )
          }
          switch target.status {
          case .checkedIn:
            return nil
          case .pending:
            return ForumBatchCheckInEntry(
              id: target.forumID,
              forumName: target.forumName,
              level: target.level,
              outcome: .pending
            )
          case .unknown:
            return ForumBatchCheckInEntry(
              id: target.forumID,
              forumName: target.forumName,
              level: target.level,
              outcome: .skipped(message: "贴吧未提供可确认的签到状态，已跳过。")
            )
          }
        }
        state = .ready(summary: summary())
      case .changed:
        state = .idle
      case .unavailable:
        failForUnreadableAccount(summary: nil)
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      state = .idle
    } catch {
      guard requestGeneration == generation else { return }
      state = .failed(summary: nil)
      errorMessage = error.localizedDescription
    }
  }

  func requestStartConfirmation() {
    guard
      case .ready = state,
      pendingConfirmation == nil,
      let catalog,
      currentLease != nil,
      entries.contains(where: { $0.outcome == .pending })
    else { return }
    let policy = catalog.officialBatchPolicy
    pendingConfirmation = ForumBatchCheckInConfirmation(
      targetCount: entries.filter { $0.outcome == .pending }.count,
      officialBatchEligibleCount: officialBatchEligibleTargets().count,
      minimumOfficialLevel: policy?.minimumLevel,
      maximumOfficialCount: policy?.maximumForumCount
    )
  }

  func cancelStartConfirmation() {
    pendingConfirmation = nil
  }

  func confirmStart() async {
    guard
      pendingConfirmation != nil,
      case .ready = state,
      let expectedLease = currentLease,
      catalog != nil,
      operation == nil,
      entries.contains(where: { $0.outcome == .pending })
    else {
      pendingConfirmation = nil
      return
    }
    pendingConfirmation = nil

    let session: StoredAccountSession
    do {
      guard
        let activeSession = try await access.vault.activeSession(),
        ForumBatchCheckInSessionLease(activeSession) == expectedLease
      else {
        resetForChangedAccount()
        return
      }
      session = activeSession
    } catch {
      failForUnreadableAccount(summary: summary())
      return
    }

    generation &+= 1
    let requestGeneration = generation
    let activeOperation = ForumBatchCheckInOperation(lease: expectedLease)
    operation = activeOperation
    if Task.isCancelled { activeOperation.requestStop() }
    state = .running(progress: progress())
    defer {
      if operation?.id == activeOperation.id {
        operation = nil
      }
    }

    if !officialBatchEligibleTargets().isEmpty {
      guard !activeOperation.shouldStop() else {
        finishStopped(operation: activeOperation, generation: requestGeneration)
        return
      }
      let service = access.service
      let batchWrite = Task.detached {
        try await service.batchCheckIn(session: session)
      }
      let result = await batchWrite.result
      if Task.isCancelled { activeOperation.requestStop() }
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      guard await keepCurrentLease(expectedLease, operation: activeOperation) else { return }
      if case .success(let batch) = result {
        applyConfirmedBatchResults(batch, lease: expectedLease)
      }
      updateRunningState(operation: activeOperation)
    }

    while let index = entries.firstIndex(where: { $0.outcome == .pending }) {
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      if Task.isCancelled { activeOperation.requestStop() }
      if activeOperation.shouldStop() {
        finishStopped(operation: activeOperation, generation: requestGeneration)
        return
      }
      guard await keepCurrentLease(expectedLease, operation: activeOperation) else { return }

      let target = entries[index]
      entries[index].outcome = .inProgress
      updateRunningState(operation: activeOperation)
      let service = access.service
      let singleWrite = Task.detached {
        try await service.checkInToForum(
          session: session,
          forumID: target.id,
          forumName: target.forumName
        )
      }
      let result = await singleWrite.result
      if Task.isCancelled { activeOperation.requestStop() }
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      guard await keepCurrentLease(expectedLease, operation: activeOperation) else { return }

      var didSucceed = false
      switch result {
      case .success(let accountState):
        if confirmedSingleResult(accountState, target: target, lease: expectedLease) {
          entries[index].outcome = .succeeded
          didSucceed = true
          if let checkIn = accountState.checkIn {
            postCheckInChange(checkIn, target: target, lease: expectedLease)
          }
        } else {
          entries[index].outcome = .failed(message: "贴吧没有确认签到结果。")
        }
      case .failure(let error):
        didSucceed = await reconcileSingleFailure(
          error,
          session: session,
          target: target,
          entryIndex: index,
          lease: expectedLease,
          operation: activeOperation,
          generation: requestGeneration
        )
        guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      }

      updateRunningState(operation: activeOperation)
      if case .failed = entries[index].outcome {
        markPendingStopped()
        errorMessage = "一键签到在首个单吧失败后停止，未自动重试。"
        finish(operation: activeOperation, generation: requestGeneration)
        return
      }
      if didSucceed,
        !activeOperation.shouldStop(),
        entries.contains(where: { $0.outcome == .pending })
      {
        let delay = interRequestDelay
        await Task.detached { await delay() }.value
        if Task.isCancelled { activeOperation.requestStop() }
        guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      }
    }

    finish(operation: activeOperation, generation: requestGeneration)
  }

  func requestStop() {
    guard let operation else { return }
    operation.requestStop()
    state = .stopping(progress: progress())
  }

  func accountSessionDidChange() async {
    operation?.requestStop()
    operation = nil
    generation &+= 1
    resetForChangedAccount()
    await reload()
  }

  func cancel() {
    requestStop()
  }

  func dismissError() {
    errorMessage = nil
  }

  private func normalizedCatalog(
    _ data: ForumCheckInCatalogData,
    lease: ForumBatchCheckInSessionLease
  ) throws -> ForumCheckInCatalogData {
    guard data.userID == lease.userID, data.targets.count <= 10_000 else {
      throw BrowseError.unavailable("贴吧返回了不匹配的一键签到列表。")
    }
    var seen = Set<Int64>()
    let targets = try data.targets.map { target -> ForumCheckInCatalogTarget in
      guard
        let name = normalizedForumName(target.forumName),
        target.forumID > 0,
        target.level >= 0,
        seen.insert(target.forumID).inserted
      else {
        throw BrowseError.unavailable("贴吧返回了无效的一键签到目标。")
      }
      return ForumCheckInCatalogTarget(
        forumID: target.forumID,
        forumName: name,
        level: target.level,
        status: target.status,
        isForbidden: target.isForbidden
      )
    }
    if let policy = data.officialBatchPolicy,
      policy.minimumLevel < 0
        || !(1...Self.maximumOfficialBatchCount).contains(policy.maximumForumCount)
    {
      throw BrowseError.unavailable("贴吧返回了无效的官方批量签到规则。")
    }
    return ForumCheckInCatalogData(
      userID: data.userID,
      targets: targets,
      officialBatchPolicy: data.officialBatchPolicy
    )
  }

  private func officialBatchEligibleTargets() -> [ForumBatchCheckInEntry] {
    guard let policy = catalog?.officialBatchPolicy, policy.maximumForumCount > 0 else { return [] }
    return Array(
      entries.lazy
        .filter { $0.outcome == .pending && $0.level >= policy.minimumLevel }
        .prefix(policy.maximumForumCount)
    )
  }

  private func applyConfirmedBatchResults(
    _ data: ForumBatchCheckInData,
    lease: ForumBatchCheckInSessionLease
  ) {
    guard data.userID == lease.userID else { return }
    var seen = Set<Int64>()
    for result in data.results {
      guard
        result.forumID > 0,
        seen.insert(result.forumID).inserted,
        case .confirmedSigned = result.outcome,
        let resultForumName = normalizedForumName(result.forumName),
        let index = entries.firstIndex(where: {
          $0.id == result.forumID
            && $0.forumName == resultForumName
            && $0.outcome == .pending
        })
      else { continue }
      entries[index].outcome = .succeeded
    }
  }

  private func confirmedSingleResult(
    _ data: ForumAccountStateData,
    target: ForumBatchCheckInEntry,
    lease: ForumBatchCheckInSessionLease
  ) -> Bool {
    data.membership.userID == lease.userID
      && data.membership.forumID == target.id
      && normalizedForumName(data.membership.forumName) == target.forumName
      && data.membership.isFollowed
      && data.checkIn?.isCheckedIn == true
  }

  private func confirmedUnsignedSingleResult(
    _ data: ForumAccountStateData,
    target: ForumBatchCheckInEntry,
    lease: ForumBatchCheckInSessionLease
  ) -> Bool {
    data.membership.userID == lease.userID
      && data.membership.forumID == target.id
      && normalizedForumName(data.membership.forumName) == target.forumName
      && data.membership.isFollowed
      && data.checkIn?.isCheckedIn == false
  }

  private func normalizedForumName(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      !value.isEmpty,
      value.utf8.count <= Self.maximumForumNameUTF8ByteCount,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return value
  }

  private func reconcileSingleFailure(
    _ writeError: any Error,
    session: StoredAccountSession,
    target: ForumBatchCheckInEntry,
    entryIndex: Int,
    lease: ForumBatchCheckInSessionLease,
    operation expectedOperation: ForumBatchCheckInOperation,
    generation expectedGeneration: Int
  ) async -> Bool {
    let service = access.service
    let readback = Task.detached {
      try await service.forumAccountState(
        session: session,
        forumID: target.id,
        forumName: target.forumName
      )
    }
    let result = await readback.result
    guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return false }
    guard await keepCurrentLease(lease, operation: expectedOperation) else { return false }
    guard entries.indices.contains(entryIndex), entries[entryIndex].id == target.id else { return false }

    switch result {
    case .success(let state):
      if confirmedSingleResult(state, target: target, lease: lease) {
        entries[entryIndex].outcome = .succeeded
        if let checkIn = state.checkIn {
          postCheckInChange(checkIn, target: target, lease: lease)
        }
        return true
      }
      if confirmedUnsignedSingleResult(state, target: target, lease: lease) {
        entries[entryIndex].outcome = .failed(message: singleFailureMessage(writeError))
      } else {
        entries[entryIndex].outcome = .failed(message: singleOutcomeUnknownMessage)
      }
    case .failure:
      entries[entryIndex].outcome = .failed(message: singleOutcomeUnknownMessage)
    }
    return false
  }

  private func postCheckInChange(
    _ checkIn: ForumCheckInData,
    target: ForumBatchCheckInEntry,
    lease: ForumBatchCheckInSessionLease
  ) {
    AccountChangeNotifications.postForumCheckInChange(
      ForumCheckInChange(
        accountID: lease.userID,
        sessionRevision: lease.sessionRevision,
        forumID: target.id,
        consecutiveDays: checkIn.consecutiveDays,
        rank: checkIn.rank
      )
    )
  }

  private var singleOutcomeUnknownMessage: String {
    "签到请求已派发，但贴吧未能确认结果。请先重新进入该吧核对，勿立即重试。"
  }

  private func singleFailureMessage(_ error: any Error) -> String {
    if error is CancellationError {
      return "贴吧未能确认已派发的签到结果。"
    }
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "签到失败。" : message
  }

  private func summary() -> ForumBatchCheckInSummary {
    var pending = 0
    var succeeded = 0
    var failed = 0
    var skipped = 0
    var stopped = 0
    for entry in entries {
      switch entry.outcome {
      case .pending, .inProgress:
        pending += 1
      case .succeeded:
        succeeded += 1
      case .failed:
        failed += 1
      case .skipped:
        skipped += 1
      case .stopped:
        stopped += 1
      }
    }
    return ForumBatchCheckInSummary(
      total: catalog?.targets.count ?? entries.count,
      eligible: officialBatchEligibleCountForSummary,
      pending: pending,
      processed: succeeded + failed,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
      stopped: stopped
    )
  }

  private var officialBatchEligibleCountForSummary: Int {
    guard let catalog, let policy = catalog.officialBatchPolicy else { return 0 }
    return min(
      catalog.targets.filter {
        $0.status == .pending && !$0.isForbidden && $0.level >= policy.minimumLevel
      }.count,
      policy.maximumForumCount
    )
  }

  private func progress() -> ForumBatchCheckInProgress {
    let summary = summary()
    return ForumBatchCheckInProgress(
      total: entries.filter {
        if case .skipped = $0.outcome { return false }
        return true
      }.count,
      pending: summary.pending,
      processed: summary.processed,
      succeeded: summary.succeeded,
      failed: summary.failed,
      skipped: summary.skipped,
      stopped: summary.stopped,
      currentForumName: entries.first(where: { $0.outcome == .inProgress })?.forumName
    )
  }

  private func updateRunningState(operation: ForumBatchCheckInOperation) {
    state = operation.shouldStop()
      ? .stopping(progress: progress())
      : .running(progress: progress())
  }

  private func markPendingStopped() {
    for index in entries.indices where entries[index].outcome == .pending {
      entries[index].outcome = .stopped
    }
  }

  private func finishStopped(operation: ForumBatchCheckInOperation, generation: Int) {
    guard operationIsCurrent(operation, generation: generation) else { return }
    markPendingStopped()
    finish(operation: operation, generation: generation)
  }

  private func finish(operation: ForumBatchCheckInOperation, generation: Int) {
    guard operationIsCurrent(operation, generation: generation) else { return }
    state = .completed(summary: summary())
  }

  private func operationIsCurrent(
    _ expected: ForumBatchCheckInOperation,
    generation expectedGeneration: Int
  ) -> Bool {
    generation == expectedGeneration && operation?.id == expected.id
  }

  private func keepCurrentLease(
    _ lease: ForumBatchCheckInSessionLease,
    operation expectedOperation: ForumBatchCheckInOperation
  ) async -> Bool {
    switch await leaseState(lease) {
    case .current:
      return operation?.id == expectedOperation.id
    case .changed:
      resetForChangedAccount()
    case .unavailable:
      failForUnreadableAccount(summary: summary())
    }
    operation = nil
    return false
  }

  private func leaseState(
    _ lease: ForumBatchCheckInSessionLease
  ) async -> ForumBatchCheckInSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return ForumBatchCheckInSessionLease(session) == lease ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func resetForChangedAccount() {
    pendingConfirmation = nil
    currentLease = nil
    catalog = nil
    entries = []
    errorMessage = nil
    state = .idle
  }

  private func failForUnreadableAccount(summary: ForumBatchCheckInSummary?) {
    pendingConfirmation = nil
    currentLease = nil
    catalog = nil
    state = .failed(summary: summary)
    errorMessage = "无法读取当前账户，请稍后重试。"
  }
}

private enum ForumBatchCheckInSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct ForumBatchCheckInSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

private final class ForumBatchCheckInOperation: @unchecked Sendable {
  let id = UUID()
  let lease: ForumBatchCheckInSessionLease

  private let lock = NSLock()
  private var stopRequested = false

  init(lease: ForumBatchCheckInSessionLease) {
    self.lease = lease
  }

  func requestStop() {
    lock.withLock { stopRequested = true }
  }

  func shouldStop() -> Bool {
    lock.withLock { stopRequested }
  }
}
