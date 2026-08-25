import Combine
import Foundation

enum ForumBatchCheckInEntryOutcome: Equatable, Sendable {
  case pending
  case inProgress
  case succeeded
  case failed(message: String)
  case unconfirmed(message: String)
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
  let unconfirmed: Int
  let skipped: Int
  let stopped: Int
}

struct ForumBatchCheckInProgress: Equatable, Sendable {
  let total: Int
  let pending: Int
  let processed: Int
  let succeeded: Int
  let failed: Int
  let unconfirmed: Int
  let skipped: Int
  let stopped: Int
  let currentForumName: String?
}

struct ForumBatchCheckInConfirmation: Equatable, Sendable {
  let targetCount: Int
  let officialBatchEligibleCount: Int
  let minimumOfficialLevel: Int?
  let maximumOfficialCount: Int?
  let executionPolicy: ForumBatchCheckInExecutionPolicy

  init(
    targetCount: Int,
    officialBatchEligibleCount: Int,
    minimumOfficialLevel: Int?,
    maximumOfficialCount: Int?,
    executionPolicy: ForumBatchCheckInExecutionPolicy = .defaultValue
  ) {
    self.targetCount = targetCount
    self.officialBatchEligibleCount = officialBatchEligibleCount
    self.minimumOfficialLevel = minimumOfficialLevel
    self.maximumOfficialCount = maximumOfficialCount
    self.executionPolicy = executionPolicy
  }
}

struct ForumBatchCheckInExecutionPolicy: Equatable, Sendable {
  let delayMode: ForumBatchCheckInDelayMode
  let usesOfficialBatch: Bool
  let stopsAfterSingleFailure: Bool

  static let defaultValue = Self(
    delayMode: .defaultValue,
    usesOfficialBatch: AppPreferenceDefaults.forumBatchCheckInUsesOfficialBatch,
    stopsAfterSingleFailure: AppPreferenceDefaults.forumBatchCheckInStopsAfterSingleFailure
  )
}

enum ForumBatchCheckInState: Equatable, Sendable {
  case idle
  case signedOut
  case loading
  case ready(summary: ForumBatchCheckInSummary)
  case running(progress: ForumBatchCheckInProgress)
  case stopping(progress: ForumBatchCheckInProgress)
  case completed(summary: ForumBatchCheckInSummary)
  case needsReview(summary: ForumBatchCheckInSummary)
  case failed(summary: ForumBatchCheckInSummary?)
}

private enum ForumBatchResultApplication {
  case accepted(
    hasRejection: Bool,
    confirmedTargets: [ForumBatchCheckInTarget]
  )
  case invalid
}

private enum ForumSingleResultApplication {
  case succeeded
  case definitiveFailure
  case unconfirmed
}

private struct ForumBatchCheckInTask {
  let operationID: UUID
  let task: Task<ForumBatchCheckInData, Error>
}

private struct ForumBatchCheckInDelayTask {
  let operationID: UUID
  let task: Task<Void, Never>
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
  private let interRequestDelay: @Sendable (ForumBatchCheckInDelayMode) async -> Void
  private var catalog: ForumCheckInCatalogData?
  private var currentLease: ForumBatchCheckInSessionLease?
  private var operation: ForumBatchCheckInOperation?
  private var batchTask: ForumBatchCheckInTask?
  private var delayTask: ForumBatchCheckInDelayTask?
  private var generation = 0

  init(
    access: AccountAccess,
    interRequestDelay: @escaping @Sendable (ForumBatchCheckInDelayMode) async -> Void = { mode in
      let milliseconds = UInt64.random(in: mode.delayMillisecondsRange)
      try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
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

  func requestStartConfirmation(
    policy: ForumBatchCheckInExecutionPolicy = .defaultValue
  ) {
    guard
      case .ready = state,
      pendingConfirmation == nil,
      let catalog,
      currentLease != nil,
      entries.contains(where: { $0.outcome == .pending })
    else { return }
    let officialPolicy = catalog.officialBatchPolicy
    pendingConfirmation = ForumBatchCheckInConfirmation(
      targetCount: entries.filter { $0.outcome == .pending }.count,
      officialBatchEligibleCount: policy.usesOfficialBatch
        ? officialBatchEligibleTargets().count
        : 0,
      minimumOfficialLevel: officialPolicy?.minimumLevel,
      maximumOfficialCount: officialPolicy?.maximumForumCount,
      executionPolicy: policy
    )
  }

  func cancelStartConfirmation() {
    pendingConfirmation = nil
  }

  func confirmStart() async {
    guard
      let confirmation = pendingConfirmation,
      case .ready = state,
      let expectedLease = currentLease,
      catalog != nil,
      operation == nil,
      entries.contains(where: { $0.outcome == .pending })
    else {
      pendingConfirmation = nil
      return
    }
    let executionPolicy = confirmation.executionPolicy
    let initialOfficialTargets = executionPolicy.usesOfficialBatch
      ? officialBatchEligibleTargets().map {
        ForumBatchCheckInTarget(forumID: $0.id, forumName: $0.forumName)
      }
      : []
    let initialOfficialTargetIDs = Set(initialOfficialTargets.map(\.forumID))
    pendingConfirmation = nil

    generation &+= 1
    let requestGeneration = generation
    let activeOperation = ForumBatchCheckInOperation(lease: expectedLease)
    operation = activeOperation
    if Task.isCancelled { activeOperation.requestStop() }
    state = .running(progress: progress())
    defer {
      if operation?.id == activeOperation.id {
        clearBatchTask(for: activeOperation.id)
        clearDelayTask(for: activeOperation.id)
        operation = nil
      }
    }

    let session: StoredAccountSession
    do {
      guard let activeSession = try await access.vault.activeSession() else {
        guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
        resetForChangedAccount()
        return
      }
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      guard ForumBatchCheckInSessionLease(activeSession) == expectedLease else {
        resetForChangedAccount()
        return
      }
      session = activeSession
    } catch {
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      failForUnreadableAccount(summary: summary())
      return
    }
    if Task.isCancelled { activeOperation.requestStop() }
    if activeOperation.shouldStop() {
      finishStopped(operation: activeOperation, generation: requestGeneration)
      return
    }

    if !initialOfficialTargetIDs.isEmpty {
      guard !activeOperation.shouldStop() else {
        finishStopped(operation: activeOperation, generation: requestGeneration)
        return
      }
      let service = access.service
      let batchWrite = Task {
        try await service.batchCheckIn(
          session: session,
          authorizedTargets: initialOfficialTargets
        )
      }
      batchTask = ForumBatchCheckInTask(
        operationID: activeOperation.id,
        task: batchWrite
      )
      let result = await withTaskCancellationHandler {
        await batchWrite.result
      } onCancel: {
        activeOperation.requestStop()
        batchWrite.cancel()
      }
      clearBatchTask(for: activeOperation.id)
      if Task.isCancelled { activeOperation.requestStop() }
      guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      guard await keepCurrentLease(expectedLease, operation: activeOperation) else { return }
      switch result {
      case .success(let batch):
        switch applyBatchResults(
          batch,
          lease: expectedLease,
          authorizedTargets: initialOfficialTargets,
          initialOfficialTargetIDs: initialOfficialTargetIDs
        ) {
        case .accepted(let hasRejection, let confirmedTargets):
          if !confirmedTargets.isEmpty {
            AccountChangeNotifications.postForumCheckInCatalogChange(
              ForumCheckInCatalogChange(
                accountID: expectedLease.userID,
                sessionRevision: expectedLease.sessionRevision,
                confirmedTargets: confirmedTargets
              )
            )
          }
          if hasRejection {
            markPendingStopped()
            errorMessage = "官方批量签到有目标未成功，已停止后续单吧签到且未自动重试。"
            finish(operation: activeOperation, generation: requestGeneration)
            return
          }
        case .invalid:
          failClosedUnknownBatch(
            authorizedTargets: initialOfficialTargets,
            operation: activeOperation,
            generation: requestGeneration
          )
          return
        }
      case .failure(let error as ForumBatchCheckInError):
        switch error {
        case .authorizationChanged:
          markPendingStopped()
          errorMessage = error.localizedDescription
          state = .failed(summary: summary())
          return
        case .outcomeUnknown(let dispatchedTargets):
          await reconcileUnknownBatchOutcome(
            dispatchedTargets: dispatchedTargets,
            authorizedTargets: initialOfficialTargets,
            session: session,
            lease: expectedLease,
            operation: activeOperation,
            generation: requestGeneration
          )
          return
        }
      case .failure(let error):
        markPendingStopped()
        if error is CancellationError, activeOperation.shouldStop() || Task.isCancelled {
          finish(operation: activeOperation, generation: requestGeneration)
        } else {
          errorMessage = singleFailureMessage(error)
          state = .failed(summary: summary())
        }
        return
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
      if Task.isCancelled { activeOperation.requestStop() }
      if activeOperation.shouldStop() {
        finishStopped(operation: activeOperation, generation: requestGeneration)
        return
      }

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

      let application: ForumSingleResultApplication
      switch result {
      case .success(let accountState):
        if confirmedSingleResult(accountState, target: target, lease: expectedLease) {
          entries[index].outcome = .succeeded
          application = .succeeded
          if let checkIn = accountState.checkIn {
            postCheckInChange(checkIn, target: target, lease: expectedLease)
          }
        } else if confirmedUnsignedSingleResult(
          accountState,
          target: target,
          lease: expectedLease
        ) {
          entries[index].outcome = .failed(message: "贴吧没有确认签到成功。")
          application = .definitiveFailure
        } else {
          entries[index].outcome = .unconfirmed(message: singleOutcomeUnknownMessage)
          application = .unconfirmed
        }
      case .failure(let error):
        if error is CancellationError {
          activeOperation.requestStop()
        }
        application = await reconcileSingleFailure(
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
      switch application {
      case .unconfirmed:
        markPendingStopped()
        errorMessage = singleOutcomeUnknownMessage
        state = .needsReview(summary: summary())
        return
      case .definitiveFailure where executionPolicy.stopsAfterSingleFailure:
        markPendingStopped()
        errorMessage = "一键签到在首个单吧失败后停止，未自动重试。"
        finish(operation: activeOperation, generation: requestGeneration)
        return
      case .succeeded, .definitiveFailure:
        break
      }
      if !activeOperation.shouldStop(),
        entries.contains(where: { $0.outcome == .pending })
      {
        let delay = interRequestDelay
        let pacingTask = Task.detached { await delay(executionPolicy.delayMode) }
        delayTask = ForumBatchCheckInDelayTask(
          operationID: activeOperation.id,
          task: pacingTask
        )
        await withTaskCancellationHandler {
          await pacingTask.value
        } onCancel: {
          activeOperation.requestStop()
          pacingTask.cancel()
        }
        clearDelayTask(for: activeOperation.id)
        if Task.isCancelled { activeOperation.requestStop() }
        guard operationIsCurrent(activeOperation, generation: requestGeneration) else { return }
      }
    }

    finish(operation: activeOperation, generation: requestGeneration)
  }

  func requestStop() {
    guard let operation else { return }
    operation.requestStop()
    if batchTask?.operationID == operation.id {
      batchTask?.task.cancel()
    }
    if delayTask?.operationID == operation.id {
      delayTask?.task.cancel()
    }
    state = .stopping(progress: progress())
  }

  func accountSessionDidChange() async {
    operation?.requestStop()
    batchTask?.task.cancel()
    delayTask?.task.cancel()
    batchTask = nil
    delayTask = nil
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

  private func applyBatchResults(
    _ data: ForumBatchCheckInData,
    lease: ForumBatchCheckInSessionLease,
    authorizedTargets: [ForumBatchCheckInTarget],
    initialOfficialTargetIDs: Set<Int64>
  ) -> ForumBatchResultApplication {
    guard data.userID == lease.userID, data.results.count <= Self.maximumOfficialBatchCount else {
      return .invalid
    }
    let authorized = Dictionary(
      uniqueKeysWithValues: authorizedTargets.map { ($0.forumID, $0.forumName) }
    )
    var seen = Set<Int64>()
    var mapped = [(index: Int, outcome: ForumBatchCheckInOutcome)]()
    for result in data.results {
      guard
        result.forumID > 0,
        seen.insert(result.forumID).inserted,
        initialOfficialTargetIDs.contains(result.forumID),
        let resultForumName = normalizedForumName(result.forumName),
        authorized[result.forumID] == resultForumName,
        let index = entries.firstIndex(where: {
          $0.id == result.forumID
            && $0.forumName == resultForumName
            && $0.outcome == .pending
        })
      else { return .invalid }
      mapped.append((index, result.outcome))
    }

    var hasRejection = false
    var confirmedTargets = [ForumBatchCheckInTarget]()
    for item in mapped {
      switch item.outcome {
      case .confirmedSigned:
        entries[item.index].outcome = .succeeded
        confirmedTargets.append(
          ForumBatchCheckInTarget(
            forumID: entries[item.index].id,
            forumName: entries[item.index].forumName
          )
        )
      case .rejected(let message):
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[item.index].outcome = .failed(
          message: message.isEmpty ? "官方批量签到未确认成功。" : message
        )
        hasRejection = true
      }
    }
    for index in entries.indices
    where initialOfficialTargetIDs.contains(entries[index].id) && entries[index].outcome == .pending {
      entries[index].outcome = .stopped
    }
    return .accepted(
      hasRejection: hasRejection,
      confirmedTargets: confirmedTargets
    )
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

  private func reconcileUnknownBatchOutcome(
    dispatchedTargets: [ForumBatchCheckInTarget],
    authorizedTargets: [ForumBatchCheckInTarget],
    session: StoredAccountSession,
    lease: ForumBatchCheckInSessionLease,
    operation expectedOperation: ForumBatchCheckInOperation,
    generation expectedGeneration: Int
  ) async {
    let authorized = Dictionary(
      uniqueKeysWithValues: authorizedTargets.map { ($0.forumID, $0.forumName) }
    )
    var seen = Set<Int64>()
    var normalizedDispatched = [ForumBatchCheckInTarget]()
    var payloadIsValid = !dispatchedTargets.isEmpty
      && dispatchedTargets.count <= Self.maximumOfficialBatchCount
    for target in dispatchedTargets {
      guard
        target.forumID > 0,
        seen.insert(target.forumID).inserted,
        let name = normalizedForumName(target.forumName),
        authorized[target.forumID] == name
      else {
        payloadIsValid = false
        break
      }
      normalizedDispatched.append(
        ForumBatchCheckInTarget(forumID: target.forumID, forumName: name)
      )
    }

    guard payloadIsValid, normalizedDispatched.count == dispatchedTargets.count else {
      failClosedUnknownBatch(
        authorizedTargets: authorizedTargets,
        operation: expectedOperation,
        generation: expectedGeneration
      )
      return
    }

    markPendingStopped()
    let service = access.service
    for target in normalizedDispatched {
      guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return }
      guard await keepCurrentLease(lease, operation: expectedOperation) else { return }
      let readback = Task.detached {
        try await service.forumAccountState(
          session: session,
          forumID: target.forumID,
          forumName: target.forumName
        )
      }
      let result = await readback.result
      guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return }
      guard await keepCurrentLease(lease, operation: expectedOperation) else { return }
      guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return }
      guard let index = entries.firstIndex(where: {
        $0.id == target.forumID
          && $0.forumName == target.forumName
          && $0.outcome == .stopped
      }) else { return }
      let entry = entries[index]
      switch result {
      case .success(let state) where confirmedSingleResult(
        state,
        target: entry,
        lease: lease
      ):
        entries[index].outcome = .succeeded
        if let checkIn = state.checkIn {
          postCheckInChange(checkIn, target: entry, lease: lease)
        }
      default:
        entries[index].outcome = .unconfirmed(message: batchOutcomeUnknownMessage)
      }
    }

    guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return }
    guard await keepCurrentLease(lease, operation: expectedOperation) else { return }
    if entries.contains(where: {
      if case .unconfirmed = $0.outcome { return true }
      return false
    }) {
      errorMessage = batchOutcomeUnknownMessage
      state = .needsReview(summary: summary())
    } else {
      finish(operation: expectedOperation, generation: expectedGeneration)
    }
  }

  private var batchOutcomeUnknownMessage: String {
    "官方批量签到已发送，但该贴吧的结果无法权威确认。应用没有自动重试，请重新读取状态。"
  }

  private func failClosedUnknownBatch(
    authorizedTargets: [ForumBatchCheckInTarget],
    operation expectedOperation: ForumBatchCheckInOperation,
    generation expectedGeneration: Int
  ) {
    guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else { return }
    markPendingStopped()
    let authorizedIDs = Set(authorizedTargets.map(\.forumID))
    for index in entries.indices where authorizedIDs.contains(entries[index].id) {
      entries[index].outcome = .unconfirmed(message: batchOutcomeUnknownMessage)
    }
    errorMessage = batchOutcomeUnknownMessage
    state = .needsReview(summary: summary())
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
  ) async -> ForumSingleResultApplication {
    let service = access.service
    let readback = Task.detached {
      try await service.forumAccountState(
        session: session,
        forumID: target.id,
        forumName: target.forumName
      )
    }
    let result = await readback.result
    guard operationIsCurrent(expectedOperation, generation: expectedGeneration) else {
      return .unconfirmed
    }
    guard await keepCurrentLease(lease, operation: expectedOperation) else { return .unconfirmed }
    guard entries.indices.contains(entryIndex), entries[entryIndex].id == target.id else {
      return .unconfirmed
    }

    switch result {
    case .success(let state):
      if confirmedSingleResult(state, target: target, lease: lease) {
        entries[entryIndex].outcome = .succeeded
        if let checkIn = state.checkIn {
          postCheckInChange(checkIn, target: target, lease: lease)
        }
        return .succeeded
      }
      if confirmedUnsignedSingleResult(state, target: target, lease: lease) {
        entries[entryIndex].outcome = .failed(
          message: definitiveSingleFailureMessage(writeError)
        )
        return .definitiveFailure
      } else {
        entries[entryIndex].outcome = .unconfirmed(message: singleOutcomeUnknownMessage)
      }
    case .failure:
      entries[entryIndex].outcome = .unconfirmed(message: singleOutcomeUnknownMessage)
    }
    return .unconfirmed
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

  private func definitiveSingleFailureMessage(_ error: any Error) -> String {
    if error is CancellationError {
      return "签到请求已停止；贴吧确认该吧仍未签到。"
    }
    return singleFailureMessage(error)
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
    var unconfirmed = 0
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
      case .unconfirmed:
        unconfirmed += 1
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
      processed: succeeded + failed + unconfirmed,
      succeeded: succeeded,
      failed: failed,
      unconfirmed: unconfirmed,
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
      unconfirmed: summary.unconfirmed,
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
    let state = await leaseState(lease)
    guard operation?.id == expectedOperation.id else { return false }
    switch state {
    case .current:
      return true
    case .changed:
      resetForChangedAccount()
    case .unavailable:
      failForUnreadableAccount(summary: summary())
    }
    operation = nil
    return false
  }

  private func clearBatchTask(for operationID: UUID) {
    guard batchTask?.operationID == operationID else { return }
    batchTask = nil
  }

  private func clearDelayTask(for operationID: UUID) {
    guard delayTask?.operationID == operationID else { return }
    delayTask = nil
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
