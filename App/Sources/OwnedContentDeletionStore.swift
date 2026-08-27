import Combine
import SwiftUI

enum OwnedContentDeletionEntryState: Equatable {
  case resolvingAccount
  case signedOut
  case unavailable
  case ready(AccountSessionLease)
  case deleting(AccountSessionLease)
  case accepted(OwnedContentDeletionReceipt)
  case failed(AccountSessionLease, message: String)
  case outcomeUnknown(AccountSessionLease, message: String)
}

@MainActor
final class OwnedContentDeletionEntry: ObservableObject {
  let target: OwnedContentDeletionTarget
  @Published private(set) var state: OwnedContentDeletionEntryState = .resolvingAccount

  init(target: OwnedContentDeletionTarget) {
    self.target = target
  }

  fileprivate func setState(_ state: OwnedContentDeletionEntryState) {
    self.state = state
  }
}

struct PendingOwnedContentDeletion: Equatable, Sendable {
  let target: OwnedContentDeletionTarget
  let lease: AccountSessionLease

  var confirmationTitle: String {
    switch target.kind {
    case .topic:
      "删除这个主题？"
    case .post:
      "删除第 \(target.floor) 楼？"
    }
  }

  var actionTitle: String {
    switch target.kind {
    case .topic: "删除主题"
    case .post: "删除本楼"
    }
  }

  var confirmationMessage: String {
    switch target.kind {
    case .topic:
      "将使用当前贴吧账户永久删除你发布的主题；成功后整个帖子将无法继续浏览。此操作无法撤销。"
    case .post:
      "将永久删除你发布的第 \(target.floor) 楼及其楼中楼回复。此操作无法撤销。"
    }
  }
}

@MainActor
final class OwnedContentDeletionStore {
  private struct OperationKey: Hashable {
    let lease: AccountSessionLease
    let target: OwnedContentDeletionTarget
  }

  private enum Terminal {
    case accepted(OwnedContentDeletionTarget)
    case outcomeUnknown(OwnedContentDeletionTarget, String)

    var target: OwnedContentDeletionTarget {
      switch self {
      case .accepted(let target), .outcomeUnknown(let target, _):
        target
      }
    }
  }

  private enum PersistedDeletionOutcome: Sendable {
    case accepted(OwnedContentDeletionReceipt)
    case retryAllowed(OwnedContentDeletionError, refreshSession: Bool)
    case outcomeUnknown

    var refreshesSession: Bool {
      if case .retryAllowed(_, refreshSession: true) = self { return true }
      return false
    }
  }

  private struct Flight {
    let id: UUID
    let lease: AccountSessionLease
    let target: OwnedContentDeletionTarget
    let finalizer: Task<PersistedDeletionOutcome, Never>
  }

  private let access: AccountAccess
  private let ledger: any OwnedContentDeletionLedgerRepository
  private var entries: [OwnedContentDeletionTarget: OwnedContentDeletionEntry] = [:]
  private var currentSession: StoredAccountSession?
  private var hasResolvedSession = false
  private var hasResolvedLedger = false
  private var ledgerIsAvailable = false
  private var ledgerLoadTask: Task<[OwnedContentDeletionLedgerRecord], Error>?
  private var sessionReloadTask: Task<Void, Never>?
  private var sessionReloadRequested = false
  private var flights: [OwnedContentDeletionLedgerKey: Flight] = [:]
  // Keep irreversible terminal outcomes bound to stable content, not display metadata
  // or a replaceable session lease.
  private var terminals: [OwnedContentDeletionLedgerKey: Terminal] = [:]
  private var failures: [OperationKey: String] = [:]
  private var sessionChangeCancellable: AnyCancellable?

  init(
    access: AccountAccess,
    ledger: any OwnedContentDeletionLedgerRepository,
    observesAccountSessionChanges: Bool = true
  ) {
    self.access = access
    self.ledger = ledger
    if observesAccountSessionChanges {
      sessionChangeCancellable = NotificationCenter.default.publisher(for: .accountSessionDidChange)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            await self?.reloadActiveSession()
          }
        }
    }
    Task { @MainActor [weak self] in
      await self?.reloadActiveSession()
    }
  }

  func entry(for target: OwnedContentDeletionTarget) -> OwnedContentDeletionEntry {
    if let entry = entries[target] { return entry }
    let entry = OwnedContentDeletionEntry(target: target)
    entries[target] = entry
    applyCurrentState(to: entry)
    return entry
  }

  func pendingRequest(for target: OwnedContentDeletionTarget) -> PendingOwnedContentDeletion? {
    let entry = entry(for: target)
    switch entry.state {
    case .ready(let lease), .failed(let lease, _):
      return PendingOwnedContentDeletion(target: target, lease: lease)
    case .resolvingAccount, .signedOut, .unavailable, .deleting, .accepted,
      .outcomeUnknown:
      return nil
    }
  }

  func outcomeUnknownTarget(threadID: Int64) -> OwnedContentDeletionTarget? {
    terminals.values.compactMap { terminal -> OwnedContentDeletionTarget? in
      guard terminal.target.threadID == threadID else { return nil }
      if case .outcomeUnknown(let target, _) = terminal { return target }
      return nil
    }
    .sorted { lhs, rhs in
      if lhs.floor != rhs.floor { return lhs.floor < rhs.floor }
      return lhs.objectID < rhs.objectID
    }
    .first
  }

  func restoredTargets(
    threadID: Int64
  ) async -> (accepted: [OwnedContentDeletionTarget], outcomeUnknown: OwnedContentDeletionTarget?) {
    await restoreLedgerIfNeeded()
    guard ledgerIsAvailable else { return ([], nil) }
    let accepted = terminals.values.compactMap { terminal -> OwnedContentDeletionTarget? in
      guard terminal.target.threadID == threadID else { return nil }
      if case .accepted(let target) = terminal { return target }
      return nil
    }
    .sorted(by: Self.targetAppearsEarlier)
    return (accepted, outcomeUnknownTarget(threadID: threadID))
  }

  @discardableResult
  func delete(
    _ pending: PendingOwnedContentDeletion
  ) async throws -> OwnedContentDeletionReceipt {
    guard hasResolvedLedger, ledgerIsAvailable else {
      throw OwnedContentDeletionError.unavailable(
        "无法读取删除安全记录，未发送请求。请检查本机存储后再试。"
      )
    }
    guard
      pending.target.authorID == pending.lease.userID,
      let resourceKey = OwnedContentDeletionLedgerKey(
        userID: pending.lease.userID,
        target: pending.target
      )
    else {
      throw OwnedContentDeletionError.unavailable("删除目标不属于当前账户。")
    }
    let operationKey = OperationKey(lease: pending.lease, target: pending.target)
    if let terminal = terminals[resourceKey] {
      return try terminalReceipt(terminal, for: pending)
    }
    if let flight = flights[resourceKey] {
      guard flight.lease == pending.lease, flight.target == pending.target else {
        throw OwnedContentDeletionError.unavailable(
          "同一内容已有其他账户会话或元数据发起的删除操作。"
        )
      }
      return try await consume(flight)
    }

    try Task.checkCancellation()
    failures.removeValue(forKey: operationKey)
    entry(for: pending.target).setState(.deleting(pending.lease))
    let flightID = UUID()
    let operationID = UUID()
    let access = access
    let ledger = ledger
    // This task is owned by the Store rather than by any caller awaiting delete().
    // It therefore publishes the durable outcome and clears the flight even when
    // the initiating view task is cancelled or disappears.
    let finalizer = Task.detached { [self] in
      let outcome = await Self.performPersistedDeletion(
        pending: pending,
        resourceKey: resourceKey,
        operationID: operationID,
        access: access,
        ledger: ledger
      )
      if outcome.refreshesSession {
        await self.reloadActiveSession()
      }
      return await self.finalize(
        outcome,
        flightID: flightID,
        resourceKey: resourceKey,
        pending: pending
      )
    }
    let flight = Flight(
      id: flightID,
      lease: pending.lease,
      target: pending.target,
      finalizer: finalizer
    )
    flights[resourceKey] = flight
    return try await consume(flight)
  }

  func reloadActiveSession() async {
    await restoreLedgerIfNeeded()
    sessionReloadRequested = true
    if sessionReloadTask == nil {
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.drainSessionReloads()
      }
      sessionReloadTask = task
    }

    while let sessionReloadTask {
      await sessionReloadTask.value
    }
  }

  private func drainSessionReloads() async {
    while sessionReloadRequested {
      sessionReloadRequested = false
      let resolvedSession: StoredAccountSession?
      do {
        resolvedSession = try await access.vault.activeSession()
      } catch {
        resolvedSession = nil
      }
      guard !sessionReloadRequested else { continue }
      currentSession = resolvedSession
      hasResolvedSession = true
      for entry in entries.values {
        applyCurrentState(to: entry)
      }
    }
    sessionReloadTask = nil
  }

  private func applyCurrentState(to entry: OwnedContentDeletionEntry) {
    guard hasResolvedSession, hasResolvedLedger else {
      entry.setState(.resolvingAccount)
      return
    }
    guard ledgerIsAvailable else {
      entry.setState(.unavailable)
      return
    }
    guard let session = currentSession else {
      entry.setState(.signedOut)
      return
    }
    let lease = AccountSessionLease(session)
    guard session.id == entry.target.authorID, session.credentials != nil else {
      entry.setState(.unavailable)
      return
    }
    guard
      let resourceKey = OwnedContentDeletionLedgerKey(
        userID: session.id,
        target: entry.target
      )
    else {
      entry.setState(.unavailable)
      return
    }
    let operationKey = OperationKey(lease: lease, target: entry.target)
    if let terminal = terminals[resourceKey] {
      guard terminal.target == entry.target else {
        entry.setState(.unavailable)
        return
      }
      switch terminal {
      case .accepted(let target):
        entry.setState(
          .accepted(
            OwnedContentDeletionReceipt(
              accountID: lease.userID,
              sessionRevision: lease.sessionRevision,
              target: target
            )
          )
        )
      case .outcomeUnknown(_, let message):
        entry.setState(.outcomeUnknown(lease, message: message))
      }
    } else if let flight = flights[resourceKey] {
      entry.setState(
        flight.lease == lease && flight.target == entry.target ? .deleting(lease) : .unavailable
      )
    } else if let message = failures[operationKey] {
      entry.setState(.failed(lease, message: message))
    } else {
      entry.setState(.ready(lease))
    }
  }

  private func restoreLedgerIfNeeded() async {
    guard !hasResolvedLedger else { return }
    let task: Task<[OwnedContentDeletionLedgerRecord], Error>
    if let ledgerLoadTask {
      task = ledgerLoadTask
    } else {
      let ledger = ledger
      let created = Task.detached { try await ledger.records() }
      ledgerLoadTask = created
      task = created
    }

    do {
      let records = try await task.value
      guard !hasResolvedLedger else { return }
      var restored: [OwnedContentDeletionLedgerKey: Terminal] = [:]
      restored.reserveCapacity(records.count)
      for record in records {
        let target = try record.reconstructedTarget()
        let terminal: Terminal = switch record.restoredTerminal {
        case .accepted:
          .accepted(target)
        case .outcomeUnknown:
          .outcomeUnknown(
            target,
            OwnedContentDeletionError.outcomeUnknown.localizedDescription
          )
        }
        guard restored.updateValue(terminal, forKey: record.key) == nil else {
          throw OwnedContentDeletionLedgerError.corruptedArchive
        }
      }
      terminals = restored
      ledgerIsAvailable = true
    } catch {
      terminals.removeAll(keepingCapacity: false)
      ledgerIsAvailable = false
    }
    hasResolvedLedger = true
    ledgerLoadTask = nil
    for entry in entries.values {
      applyCurrentState(to: entry)
    }
  }

  private func consume(
    _ flight: Flight
  ) async throws -> OwnedContentDeletionReceipt {
    try Task.checkCancellation()
    switch await flight.finalizer.value {
    case .accepted(let receipt):
      return receipt
    case .retryAllowed(let error, _):
      throw error
    case .outcomeUnknown:
      throw OwnedContentDeletionError.outcomeUnknown
    }
  }

  private func finalize(
    _ outcome: PersistedDeletionOutcome,
    flightID: UUID,
    resourceKey: OwnedContentDeletionLedgerKey,
    pending: PendingOwnedContentDeletion
  ) -> PersistedDeletionOutcome {
    guard flights[resourceKey]?.id == flightID else {
      return .outcomeUnknown
    }

    let finalized: PersistedDeletionOutcome
    switch outcome {
    case .accepted(let receipt):
      guard
        receipt.accountID == pending.lease.userID,
        receipt.sessionRevision == pending.lease.sessionRevision,
        receipt.target == pending.target
      else {
        terminals[resourceKey] = .outcomeUnknown(
          pending.target,
          OwnedContentDeletionError.outcomeUnknown.localizedDescription
        )
        finalized = .outcomeUnknown
        break
      }
      terminals[resourceKey] = .accepted(pending.target)
      failures.removeValue(forKey: OperationKey(lease: pending.lease, target: pending.target))
      finalized = .accepted(receipt)
    case .retryAllowed(let error, let refreshSession):
      failures[OperationKey(lease: pending.lease, target: pending.target)] =
        error.localizedDescription
      finalized = .retryAllowed(error, refreshSession: refreshSession)
    case .outcomeUnknown:
      terminals[resourceKey] = .outcomeUnknown(
        pending.target,
        OwnedContentDeletionError.outcomeUnknown.localizedDescription
      )
      finalized = .outcomeUnknown
    }

    flights.removeValue(forKey: resourceKey)
    applyCurrentStateToEntries(for: resourceKey)
    return finalized
  }

  private func terminalReceipt(
    _ terminal: Terminal,
    for pending: PendingOwnedContentDeletion
  ) throws -> OwnedContentDeletionReceipt {
    guard terminal.target == pending.target else {
      throw OwnedContentDeletionError.unavailable(
        "删除目标的元数据与已有安全记录不一致，未发送请求。"
      )
    }
    switch terminal {
    case .accepted:
      return OwnedContentDeletionReceipt(
        accountID: pending.lease.userID,
        sessionRevision: pending.lease.sessionRevision,
        target: pending.target
      )
    case .outcomeUnknown:
      throw OwnedContentDeletionError.outcomeUnknown
    }
  }

  private func applyCurrentStateToEntries(for resourceKey: OwnedContentDeletionLedgerKey) {
    for entry in entries.values {
      guard
        let entryKey = OwnedContentDeletionLedgerKey(
          userID: resourceKey.userID,
          target: entry.target
        ),
        entryKey == resourceKey
      else { continue }
      applyCurrentState(to: entry)
    }
  }

  private nonisolated static func performPersistedDeletion(
    pending: PendingOwnedContentDeletion,
    resourceKey: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    access: AccountAccess,
    ledger: any OwnedContentDeletionLedgerRepository
  ) async -> PersistedDeletionOutcome {
    let session: StoredAccountSession
    do {
      guard
        let activeSession = try await access.vault.activeSession(),
        pending.lease.matches(activeSession),
        activeSession.credentials != nil
      else {
        return .retryAllowed(
          .unavailable("当前账户已经变化，未发送删除请求。请重新确认后再试。"),
          refreshSession: true
        )
      }
      session = activeSession
    } catch {
      return .retryAllowed(
        .unavailable("无法验证当前账户，未发送删除请求。请重新加载后再试。"),
        refreshSession: true
      )
    }

    do {
      _ = try await ledger.prepare(
        target: pending.target,
        accountID: session.id,
        sessionRevision: session.sessionRevision,
        operationID: operationID,
        at: Date()
      )
    } catch {
      return await outcomeAfterPrepareFailure(
        pending: pending,
        resourceKey: resourceKey,
        operationID: operationID,
        ledger: ledger
      )
    }

    let dispatchSession: StoredAccountSession
    do {
      guard
        let activeSession = try await access.vault.activeSession(),
        pending.lease.matches(activeSession),
        activeSession.credentials != nil
      else {
        return await removeMarkerAfterKnownNoDeletion(
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger,
          retryError: .unavailable(
            "当前账户在发送前已经变化，未发送删除请求。请重新确认后再试。"
          ),
          refreshSession: true
        )
      }
      dispatchSession = activeSession
    } catch {
      return await removeMarkerAfterKnownNoDeletion(
        resourceKey: resourceKey,
        operationID: operationID,
        ledger: ledger,
        retryError: .unavailable(
          "发送前无法再次验证当前账户，未发送删除请求。请重新加载后再试。"
        ),
        refreshSession: true
      )
    }

    do {
      let receipt = try await access.service.deleteOwnedContent(
        session: dispatchSession,
        target: pending.target
      )
      guard
        receipt.accountID == pending.lease.userID,
        receipt.sessionRevision == pending.lease.sessionRevision,
        receipt.target == pending.target
      else {
        await lockOutcomeUnknown(
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger
        )
        return .outcomeUnknown
      }
      do {
        _ = try await ledger.markAccepted(
          for: resourceKey,
          operationID: operationID
        )
        return .accepted(receipt)
      } catch {
        return await outcomeAfterAcceptedTransitionFailure(
          receipt: receipt,
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger
        )
      }
    } catch OwnedContentDeletionError.outcomeUnknown {
      await lockOutcomeUnknown(
        resourceKey: resourceKey,
        operationID: operationID,
        ledger: ledger
      )
      return .outcomeUnknown
    } catch let error as OwnedContentDeletionError {
      switch error {
      case .definitelyNotAccepted, .rejected:
        return await removeMarkerAfterKnownNoDeletion(
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger,
          retryError: error,
          refreshSession: false
        )
      case .unavailable, .outcomeUnknown:
        await lockOutcomeUnknown(
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger
        )
        return .outcomeUnknown
      }
    } catch {
      await lockOutcomeUnknown(
        resourceKey: resourceKey,
        operationID: operationID,
        ledger: ledger
      )
      return .outcomeUnknown
    }
  }

  private nonisolated static func outcomeAfterPrepareFailure(
    pending: PendingOwnedContentDeletion,
    resourceKey: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    ledger: any OwnedContentDeletionLedgerRepository
  ) async -> PersistedDeletionOutcome {
    do {
      guard let record = try await ledger.record(for: resourceKey) else {
        return .retryAllowed(
          .unavailable("无法建立删除安全记录，未发送请求。请检查本机存储后再试。"),
          refreshSession: false
        )
      }
      if record.operationID == operationID {
        if
          record.phase == .accepted,
          record.originSessionRevision == pending.lease.sessionRevision,
          try record.reconstructedTarget() == pending.target
        {
          return .accepted(
            OwnedContentDeletionReceipt(
              accountID: pending.lease.userID,
              sessionRevision: pending.lease.sessionRevision,
              target: pending.target
            )
          )
        }
        await lockOutcomeUnknown(
          resourceKey: resourceKey,
          operationID: operationID,
          ledger: ledger
        )
      }
      return .outcomeUnknown
    } catch {
      // A failed read cannot prove that prepare did not durably publish its marker.
      return .outcomeUnknown
    }
  }

  private nonisolated static func removeMarkerAfterKnownNoDeletion(
    resourceKey: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    ledger: any OwnedContentDeletionLedgerRepository,
    retryError: OwnedContentDeletionError,
    refreshSession: Bool
  ) async -> PersistedDeletionOutcome {
    do {
      try await ledger.removeAfterDefiniteFailure(
        for: resourceKey,
        operationID: operationID
      )
      return .retryAllowed(retryError, refreshSession: refreshSession)
    } catch {
      do {
        guard let record = try await ledger.record(for: resourceKey) else {
          return .retryAllowed(retryError, refreshSession: refreshSession)
        }
        if record.operationID == operationID {
          await lockOutcomeUnknown(
            resourceKey: resourceKey,
            operationID: operationID,
            ledger: ledger
          )
        }
      } catch {
        // Without a readable ledger, retain the in-memory fail-closed terminal.
      }
      return .outcomeUnknown
    }
  }

  private nonisolated static func outcomeAfterAcceptedTransitionFailure(
    receipt: OwnedContentDeletionReceipt,
    resourceKey: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    ledger: any OwnedContentDeletionLedgerRepository
  ) async -> PersistedDeletionOutcome {
    do {
      if
        let record = try await ledger.record(for: resourceKey),
        record.operationID == operationID,
        record.originSessionRevision == receipt.sessionRevision,
        record.phase == .accepted,
        try record.reconstructedTarget() == receipt.target
      {
        return .accepted(receipt)
      }
    } catch {
      // The service write may have succeeded, so an unreadable ledger is unknown.
    }
    await lockOutcomeUnknown(
      resourceKey: resourceKey,
      operationID: operationID,
      ledger: ledger
    )
    return .outcomeUnknown
  }

  private nonisolated static func lockOutcomeUnknown(
    resourceKey: OwnedContentDeletionLedgerKey,
    operationID: UUID,
    ledger: any OwnedContentDeletionLedgerRepository
  ) async {
    _ = try? await ledger.markOutcomeUnknown(
      for: resourceKey,
      operationID: operationID
    )
  }

  private nonisolated static func targetAppearsEarlier(
    _ lhs: OwnedContentDeletionTarget,
    _ rhs: OwnedContentDeletionTarget
  ) -> Bool {
    if lhs.floor != rhs.floor { return lhs.floor < rhs.floor }
    return lhs.objectID < rhs.objectID
  }
}

struct OwnedContentDeletionMenuSlot: View {
  let store: OwnedContentDeletionStore?
  let target: OwnedContentDeletionTarget?
  let requestDeletion: (PendingOwnedContentDeletion) -> Void

  @ViewBuilder
  var body: some View {
    if let store, let target {
      OwnedContentDeletionObservedMenuItem(
        entry: store.entry(for: target),
        store: store,
        requestDeletion: requestDeletion
      )
    }
  }
}

private struct OwnedContentDeletionObservedMenuItem: View {
  @ObservedObject private var entry: OwnedContentDeletionEntry
  let store: OwnedContentDeletionStore
  let requestDeletion: (PendingOwnedContentDeletion) -> Void

  init(
    entry: OwnedContentDeletionEntry,
    store: OwnedContentDeletionStore,
    requestDeletion: @escaping (PendingOwnedContentDeletion) -> Void
  ) {
    _entry = ObservedObject(wrappedValue: entry)
    self.store = store
    self.requestDeletion = requestDeletion
  }

  @ViewBuilder
  var body: some View {
    switch entry.state {
    case .ready, .failed:
      Button(role: .destructive) {
        if let pending = store.pendingRequest(for: entry.target) {
          requestDeletion(pending)
        }
      } label: {
        Label(actionTitle, systemImage: "trash")
      }
      .accessibilityIdentifier("delete-owned-content-\(entry.target.objectID)")
    case .deleting:
      Button {} label: {
        Label("正在删除", systemImage: "hourglass")
      }
      .disabled(true)
    case .resolvingAccount, .signedOut, .unavailable, .accepted, .outcomeUnknown:
      EmptyView()
    }
  }

  private var actionTitle: String {
    switch entry.target.kind {
    case .topic: "删除主题"
    case .post: "删除第 \(entry.target.floor) 楼"
    }
  }
}
